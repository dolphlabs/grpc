import "builder";
import "encoding";
import "http2";
import "strings";

pub let GRPC_DEFAULT_MAX_METADATA_FIELDS = 64;
pub let GRPC_DEFAULT_MAX_METADATA_BYTES = 8192;
pub let GRPC_MAX_STATUS_MESSAGE_BYTES = 4096;

pub gc struct GrpcStatus {
    code: int,
    message: str
}

pub gc struct GrpcRequest {
    stream: int,
    path: str,
    timeout_ns: opt[int],
    message: GrpcMessage
}

pub gc struct GrpcCallResponse {
    status: GrpcStatus,
    message: opt[GrpcMessage]
}

pub fn grpc_valid_method_path(path: str) -> bool {
    let path_bytes = to_bytes(path);
    if len(path) < 4 || len(path) > 1024 || path_bytes[0] != 47 {
        return false;
    }
    let tail = strings.slice(path, 1, len(path));
    let slash_tail = strings.find(tail, "/");
    if slash_tail < 1 { return false; }
    let slash = slash_tail + 1;
    if slash >= len(path) - 1 ||
       strings.find(strings.slice(path, slash + 1, len(path)), "/") >= 0 {
        return false;
    }
    let service = strings.slice(path, 1, slash);
    let method = strings.slice(path, slash + 1, len(path));
    if !grpc_valid_dotted_name(service) || !grpc_valid_identifier(method) {
        return false;
    }
    return true;
}

pub fn grpc_validate_metadata(metadata: [http2.Header]) -> result[bool, str] {
    if len(metadata) > GRPC_DEFAULT_MAX_METADATA_FIELDS {
        return err("grpc metadata: too many fields (limit 64)");
    }
    let total = 0;
    for i in 0..len(metadata) {
        let name = metadata[i].name;
        let value = metadata[i].value;
        if !grpc_valid_metadata_name(name) {
            return err("grpc metadata: invalid lowercase key");
        }
        if strings.has_prefix(name, "grpc-") || name == "content-type" ||
           name == "te" || name == "content-length" ||
           name == "connection" || name == "keep-alive" ||
           name == "proxy-connection" || name == "transfer-encoding" ||
           name == "upgrade" {
            return err("grpc metadata: key is reserved by the protocol");
        }
        if len(name) > 128 || len(value) > GRPC_DEFAULT_MAX_METADATA_BYTES {
            return err("grpc metadata: key or value exceeds its byte limit");
        }
        total = total + len(name) + len(value);
        if total > GRPC_DEFAULT_MAX_METADATA_BYTES {
            return err("grpc metadata: total bytes exceed 8192");
        }
        if strings.has_suffix(name, "-bin") {
            if !grpc_base64_text(value) {
                return err("grpc metadata: binary values must be base64 text");
            }
        } else if !grpc_header_value(value) {
            return err("grpc metadata: text value contains a forbidden byte");
        }
    }
    return ok(true);
}

pub fn grpc_request_headers(scheme: str, authority: str, path: str,
                            metadata: [http2.Header])
                            -> result[[http2.Header], str] {
    let lower_scheme = grpc_ascii_lower(scheme);
    if lower_scheme != "https" && lower_scheme != "http" {
        return err("grpc request: scheme must be http or https");
    }
    if !grpc_valid_authority(authority) {
        return err("grpc request: invalid authority");
    }
    if !grpc_valid_method_path(path) {
        return err("grpc request: path must be /service/method");
    }
    let valid = grpc_validate_metadata(metadata);
    guard let _valid = valid else let e = err_of(valid) { return err(e); }
    let headers: [http2.Header] = [
        http2.Header { name: ":method", value: "POST" },
        http2.Header { name: ":scheme", value: lower_scheme },
        http2.Header { name: ":authority", value: authority },
        http2.Header { name: ":path", value: path },
        http2.Header { name: "content-type", value: "application/grpc" },
        http2.Header { name: "te", value: "trailers" }
    ];
    return ok(headers + metadata);
}

// Validate a generic HTTP/2 request as one uncompressed unary gRPC request.
// The HTTP/2 body remains the backing store for the returned message view.
pub fn grpc_request(req: http2.Req, limits: GrpcLimits)
                     -> result[GrpcRequest, str] {
    if req.method != "POST" {
        return err("grpc request: method must be POST");
    }
    if !grpc_valid_method_path(req.path) {
        return err("grpc request: path must be /service/method");
    }
    if (req.scheme != "http" && req.scheme != "https") ||
       !grpc_valid_authority(req.authority) {
        return err("grpc request: invalid scheme or authority");
    }
    let content_type = "";
    let content_type_count = 0;
    let te_count = 0;
    let encoding_count = 0;
    let timeout_count = 0;
    let timeout_ns: opt[int] = none;
    let content_length = -1;
    let metadata: [http2.Header] = [];
    for i in 0..len(req.headers) {
        let header = req.headers[i];
        if header.name == "content-type" {
            content_type = header.value;
            content_type_count = content_type_count + 1;
        } else if header.name == "te" {
            te_count = te_count + 1;
            if grpc_ascii_lower(header.value) != "trailers" {
                return err("grpc request: te must be trailers");
            }
        } else if header.name == "grpc-encoding" {
            encoding_count = encoding_count + 1;
            if grpc_ascii_lower(header.value) != "identity" {
                return err("grpc request: compressed messages are not supported");
            }
        } else if header.name == "grpc-timeout" {
            timeout_count = timeout_count + 1;
            if timeout_count > 1 {
                return err("grpc request: duplicate grpc-timeout");
            }
            let parsed_timeout = grpc_parse_timeout(header.value);
            guard let parsed_ns = parsed_timeout else let e = err_of(parsed_timeout) {
                return err("grpc request: invalid grpc-timeout: " + e);
            }
            timeout_ns = some(parsed_ns);
        } else if header.name == "content-length" {
            if content_length >= 0 {
                return err("grpc request: duplicate content-length");
            }
            let parsed = grpc_parse_decimal(header.value, len(req.body));
            guard let n = parsed else let e = err_of(parsed) { return err(e); }
            content_length = n;
        } else if strings.has_prefix(header.name, "grpc-") {
            if !grpc_valid_metadata_name(header.name) ||
               !grpc_header_value(header.value) {
                return err("grpc request: invalid gRPC metadata header");
            }
        } else {
            metadata = metadata + [header];
        }
    }
    if content_type_count != 1 || !grpc_is_content_type(content_type) {
        return err("grpc request: content-type must be application/grpc");
    }
    if te_count != 1 {
        return err("grpc request: exactly one te: trailers field is required");
    }
    if encoding_count > 1 {
        return err("grpc request: duplicate grpc-encoding");
    }
    if content_length >= 0 && content_length != len(req.body) {
        return err("grpc request: content-length does not match body");
    }
    let metadata_result = grpc_validate_metadata(metadata);
    guard let _metadata_ok = metadata_result else let e = err_of(metadata_result) {
        return err(e);
    }
    let message_result = grpc_parse_message(req.body, limits);
    guard let message = message_result else let e = err_of(message_result) {
        return err(e);
    }
    return ok(GrpcRequest { stream: req.stream, path: req.path,
                            timeout_ns: timeout_ns, message: message });
}

pub fn grpc_timeout_header(timeout_ns: int) -> result[str, str] {
    if timeout_ns < 0 {
        return err("grpc timeout: duration cannot be negative");
    }
    let units: [int] = [3600000000000, 60000000000, 1000000000,
                        1000000, 1000, 1];
    let suffixes: [str] = ["H", "M", "S", "m", "u", "n"];
    for i in 0..len(units) {
        if timeout_ns % units[i] == 0 {
            let count = timeout_ns / units[i];
            if count <= 99999999 {
                return ok(to_str(count) + suffixes[i]);
            }
        }
    }
    return err("grpc timeout: duration cannot be represented in eight digits");
}

pub fn grpc_client_start(cn: http2.Conn, reader: http2.Reader,
                         transport: http2.Transport,
                         writer: chan[http2.WMsg], limits: http2.Limits)
                         -> result[bool, str] {
    return http2.client_preface(cn, reader, transport, writer, limits);
}

// The HTTP/2 request fields and framed body for one unary call.
gc struct GrpcPrepared {
    headers: [http2.Header],
    body: bytes
}

fn grpc_prepare(scheme: str, authority: str, path: str,
                metadata: [http2.Header], protobuf: bytes,
                limits: GrpcLimits, timeout_ns: int)
                -> result[GrpcPrepared, str] {
    if limits.max_message_bytes < 1 ||
       limits.max_message_bytes > GRPC_HARD_MAX_MESSAGE_BYTES ||
       timeout_ns <= 0 {
        return err("grpc call: invalid message limit or timeout");
    }
    let checked = grpc_request_headers(scheme, authority, path, metadata);
    guard let _checked_headers = checked else let e = err_of(checked) {
        return err(e);
    }
    let timeout = grpc_timeout_header(timeout_ns);
    guard let timeout_value = timeout else let e = err_of(timeout) {
        return err(e);
    }
    let framed = grpc_frame_message(protobuf, limits);
    guard let body = framed else let e = err_of(framed) { return err(e); }
    let headers: [http2.Header] = [
        http2.Header { name: "content-type", value: "application/grpc" },
        http2.Header { name: "te", value: "trailers" },
        http2.Header { name: "grpc-timeout", value: timeout_value }
    ];
    return ok(GrpcPrepared { headers: headers + metadata, body: body });
}

// Send one unary request on an already-started generic HTTP/2 client
// connection that carries one stream at a time. The caller owns TLS/ALPN
// setup, the writer task and stream IDs; for concurrent calls on one
// connection use grpc_call with an http2.Client.
pub fn grpc_unary_call(cn: http2.Conn, reader: http2.Reader,
                       transport: http2.Transport, writer: chan[http2.WMsg],
                       stream: int, scheme: str, authority: str, path: str,
                       metadata: [http2.Header], protobuf: bytes,
                       limits: GrpcLimits, timeout_ns: int)
                       -> result[GrpcCallResponse, str] {
    let prepared = grpc_prepare(scheme, authority, path, metadata, protobuf,
                                limits, timeout_ns);
    guard let req = prepared else let e = err_of(prepared) { return err(e); }
    let request_result = http2.client_request_msg(
        cn, stream, "POST", scheme, authority, path, req.headers, req.body);
    guard let request = request_result else let e = err_of(request_result) {
        return err(e);
    }
    chan_send(writer, request);
    let response_result = http2.client_read_response(
        cn, reader, transport, writer, stream, timeout_ns,
        limits.max_message_bytes + 5);
    guard let response = response_result else let e = err_of(response_result) {
        return err(e);
    }
    return grpc_call_response(response, limits);
}

// One unary call on a shared http2.Client: safe from any number of tasks,
// each on its own stream of the same connection, each with its own
// deadline. Not retried; a transport error can follow the server acting.
pub fn grpc_call(client: http2.Client, scheme: str, authority: str,
                 path: str, metadata: [http2.Header], protobuf: bytes,
                 limits: GrpcLimits, timeout_ns: int)
                 -> result[GrpcCallResponse, str] {
    let prepared = grpc_prepare(scheme, authority, path, metadata, protobuf,
                                limits, timeout_ns);
    guard let req = prepared else let e = err_of(prepared) { return err(e); }
    let response_result = http2.client_call(
        client, "POST", grpc_ascii_lower(scheme), authority, path,
        req.headers, req.body, timeout_ns, limits.max_message_bytes + 5);
    guard let response = response_result else let e = err_of(response_result) {
        if e == "timeout" {
            return ok(GrpcCallResponse {
                status: GrpcStatus { code: GRPC_STATUS_DEADLINE_EXCEEDED,
                                     message: "deadline exceeded" },
                message: none
            });
        }
        return err(e);
    }
    return grpc_call_response(response, limits);
}

// A gRPC unary response: HTTP 200, one gRPC content type, a grpc-status
// trailer, and at most one length-prefixed message.
fn grpc_call_response(response: http2.Response, limits: GrpcLimits)
                      -> result[GrpcCallResponse, str] {
    if response.status != "200" {
        return err("grpc call: HTTP status was " + response.status);
    }
    let content_type = "";
    let content_type_count = 0;
    for i in 0..len(response.headers) {
        if response.headers[i].name == "content-type" {
            content_type = response.headers[i].value;
            content_type_count = content_type_count + 1;
        }
    }
    if content_type_count != 1 || !grpc_is_content_type(content_type) {
        return err("grpc call: response content-type must be application/grpc");
    }
    // A trailers-only response (an error status with no message) carries
    // grpc-status in its one header block instead of in trailers.
    let status_source = response.trailers;
    if len(status_source) == 0 {
        status_source = response.headers;
    }
    let status_result = grpc_status_from_trailers(status_source);
    guard let status = status_result else let e = err_of(status_result) {
        return err(e);
    }
    if len(response.body) == 0 {
        if status.code == GRPC_STATUS_OK {
            return err("grpc call: successful unary response has no message");
        }
        return ok(GrpcCallResponse { status: status, message: none });
    }
    let message_result = grpc_parse_message(response.body, limits);
    guard let message = message_result else let e = err_of(message_result) {
        return err(e);
    }
    return ok(GrpcCallResponse { status: status, message: some(message) });
}

pub fn grpc_status_from_trailers(trailers: [http2.Header])
                                 -> result[GrpcStatus, str] {
    let raw_code = "";
    let message = "";
    let code_count = 0;
    let message_count = 0;
    for i in 0..len(trailers) {
        let h = trailers[i];
        if h.name == "grpc-status" {
            raw_code = h.value;
            code_count = code_count + 1;
        }
        if h.name == "grpc-message" {
            message = h.value;
            message_count = message_count + 1;
        }
    }
    if code_count != 1 {
        return err("grpc trailers: exactly one grpc-status is required");
    }
    if message_count > 1 {
        return err("grpc trailers: duplicate grpc-message");
    }
    let code_result = grpc_parse_decimal(raw_code, 16);
    guard let code = code_result else let e = err_of(code_result) {
        return err("grpc trailers: invalid grpc-status: " + e);
    }
    let decoded = grpc_percent_decode(message);
    guard let text = decoded else let e = err_of(decoded) {
        return err("grpc trailers: invalid grpc-message: " + e);
    }
    return ok(GrpcStatus { code: code, message: text });
}

pub fn grpc_response_msg(stream: int, protobuf: bytes, limits: GrpcLimits,
                         code: int, message: str)
                         -> result[http2.WMsg, str] {
    if code < GRPC_STATUS_OK || code > GRPC_STATUS_UNAUTHENTICATED {
        return err("grpc response: status must be 0..16");
    }
    if len(message) > GRPC_MAX_STATUS_MESSAGE_BYTES {
        return err("grpc response: status message exceeds 4096 bytes");
    }
    let body = b"";
    if code == GRPC_STATUS_OK {
        let framed = grpc_frame_message(protobuf, limits);
        guard let framed_bytes = framed else let e = err_of(framed) { return err(e); }
        body = framed_bytes;
    } else if len(protobuf) > 0 {
        return err("grpc response: protobuf message requires status OK");
    }
    let initial: [http2.Header] = [
        http2.Header { name: "content-type", value: "application/grpc" }
    ];
    let trailers: [http2.Header] = [
        http2.Header { name: "grpc-status", value: to_str(code) }
    ];
    if len(message) > 0 {
        trailers = trailers + [http2.Header {
            name: "grpc-message", value: encoding.url_encode(message)
        }];
    }
    return http2.response_trailers_msg(stream, "200", initial, body, trailers);
}

fn grpc_is_content_type(value: str) -> bool {
    let lower = grpc_ascii_lower(value);
    if lower == "application/grpc" { return true; }
    if len(lower) <= 16 || strings.slice(lower, 0, 16) != "application/grpc" {
        return false;
    }
    let raw = to_bytes(lower);
    return raw[16] == 43 || raw[16] == 59;
}

fn grpc_valid_metadata_name(name: str) -> bool {
    if len(name) < 1 || len(name) > 128 { return false; }
    let raw = to_bytes(name);
    for i in 0..len(name) {
        let c = raw[i];
        if !(c >= 97 && c <= 122) && !(c >= 48 && c <= 57) &&
           c != 45 && c != 95 && c != 46 {
            return false;
        }
    }
    return true;
}

fn grpc_valid_identifier(name: str) -> bool {
    if len(name) == 0 { return false; }
    let raw = to_bytes(name);
    for i in 0..len(name) {
        let c = raw[i];
        let letter = (c >= 97 && c <= 122) || (c >= 65 && c <= 90);
        if i == 0 {
            if !letter && c != 95 { return false; }
        } else if !letter && !(c >= 48 && c <= 57) && c != 95 {
            return false;
        }
    }
    return true;
}

fn grpc_valid_dotted_name(name: str) -> bool {
    let raw = to_bytes(name);
    let start = 0;
    for i in 0..len(name) {
        if raw[i] == 46 {
            if i == start || !grpc_valid_identifier(strings.slice(name, start, i)) {
                return false;
            }
            start = i + 1;
        }
    }
    return start < len(name) &&
           grpc_valid_identifier(strings.slice(name, start, len(name)));
}

fn grpc_header_value(value: str) -> bool {
    let raw = to_bytes(value);
    for i in 0..len(value) {
        let c = raw[i];
        if c != 9 && (c < 32 || c > 126) { return false; }
    }
    return true;
}

fn grpc_valid_authority(value: str) -> bool {
    if len(value) < 1 || len(value) > 255 || !grpc_header_value(value) ||
       strings.find(value, " ") >= 0 || strings.find(value, "\t") >= 0 ||
       strings.find(value, "@") >= 0 || strings.find(value, "/") >= 0 {
        return false;
    }
    return true;
}

fn grpc_base64_text(value: str) -> bool {
    let padding = 0;
    let saw_padding = false;
    let raw = to_bytes(value);
    for i in 0..len(value) {
        let c = raw[i];
        let alpha = (c >= 65 && c <= 90) ||
                    (c >= 97 && c <= 122) ||
                    (c >= 48 && c <= 57) || c == 43 || c == 47;
        if alpha {
            if saw_padding { return false; }
        } else if c == 61 {
            saw_padding = true;
            padding = padding + 1;
            if padding > 2 { return false; }
        } else {
            return false;
        }
    }
    if len(value) % 4 == 1 { return false; }
    if padding > 0 && len(value) % 4 != 0 { return false; }
    if padding == 1 && len(value) % 4 != 0 { return false; }
    if padding == 2 && len(value) % 4 != 0 { return false; }
    return true;
}

fn grpc_parse_decimal(value: str, max: int) -> result[int, str] {
    if len(value) == 0 || len(value) > 10 ||
       (len(value) > 1 && to_bytes(value)[0] == 48) {
        return err("expected a canonical decimal integer");
    }
    let n = 0;
    let raw = to_bytes(value);
    for i in 0..len(value) {
        let c = raw[i];
        if c < 48 || c > 57 { return err("expected decimal digits"); }
        let digit = c - 48;
        if n > max / 10 || (n == max / 10 && digit > max % 10) {
            return err("value is out of range");
        }
        n = n * 10 + digit;
    }
    return ok(n);
}

fn grpc_parse_timeout(value: str) -> result[int, str] {
    if len(value) < 2 || len(value) > 9 {
        return err("expected one to eight digits and a unit");
    }
    let raw = to_bytes(value);
    let count = 0;
    for i in 0..len(raw) - 1 {
        if raw[i] < 48 || raw[i] > 57 {
            return err("expected decimal digits before the unit");
        }
        count = count * 10 + raw[i] - 48;
    }
    let multiplier = 0;
    let unit = raw[len(raw) - 1];
    if unit == 72 { multiplier = 3600000000000; }
    else if unit == 77 { multiplier = 60000000000; }
    else if unit == 83 { multiplier = 1000000000; }
    else if unit == 109 { multiplier = 1000000; }
    else if unit == 117 { multiplier = 1000; }
    else if unit == 110 { multiplier = 1; }
    else { return err("unit must be H, M, S, m, u, or n"); }
    if count > 9223372036854775807 / multiplier {
        return err("duration exceeds slang's nanosecond range");
    }
    return ok(count * multiplier);
}

fn grpc_percent_decode(value: str) -> result[str, str] {
    if len(value) > GRPC_MAX_STATUS_MESSAGE_BYTES * 3 {
        return err("encoded message exceeds 12288 bytes");
    }
    let out = builder.new_bytes();
    let raw_value = to_bytes(value);
    let i = 0;
    while i < len(value) {
        let c = raw_value[i];
        if c == 37 {
            if i + 2 >= len(value) {
                return err("truncated percent escape");
            }
            let hi = grpc_hex(raw_value[i + 1]);
            let lo = grpc_hex(raw_value[i + 2]);
            if hi < 0 || lo < 0 { return err("invalid percent escape"); }
            out.write_byte(hi * 16 + lo);
            i = i + 3;
        } else {
            out.write_byte(c);
            i = i + 1;
        }
        if out.size() > GRPC_MAX_STATUS_MESSAGE_BYTES {
            return err("decoded message exceeds 4096 bytes");
        }
    }
    let raw = out.finish();
    if proto_has_nul(raw, 0, len(raw)) || !proto_utf8_valid(raw, 0, len(raw)) {
        return err("message is not valid UTF-8 text");
    }
    return ok(strings.from_bytes(raw, 0, len(raw)));
}

fn grpc_hex(c: int) -> int {
    if c >= 48 && c <= 57 { return c - 48; }
    if c >= 97 && c <= 102 { return c - 97 + 10; }
    if c >= 65 && c <= 70 { return c - 65 + 10; }
    return -1;
}

fn grpc_ascii_lower(value: str) -> str {
    return strings.to_lower(value);
}
