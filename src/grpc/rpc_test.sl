import "encoding";
import "http2";

fn test_grpc_method_paths_and_request_headers() {
    assert(grpc_valid_method_path("/sample.UserService/Get"),
           "valid unary method path");
    assert(!grpc_valid_method_path("/sample.UserService/Get/extra"),
           "extra path segment rejected");
    assert(!grpc_valid_method_path("/sample..Service/Get"),
           "empty service segment rejected");
    let metadata: [http2.Header] = [
        http2.Header { name: "x-request-id", value: "req-17" }
    ];
    let built = grpc_request_headers("HTTPS", "api.example:443",
                                     "/sample.UserService/Get", metadata);
    guard let hs = built else let e = err_of(built) { panic(e); }
    assert(len(hs) == 7, "gRPC pseudo and metadata headers");
    assert(hs[0].name == ":method" && hs[0].value == "POST",
           "POST pseudo header");
    assert(hs[1].name == ":scheme" && hs[1].value == "https",
           "normalized scheme");
    assert(hs[5].name == "te" && hs[5].value == "trailers",
           "gRPC trailer negotiation");
    assert(hs[6].name == "x-request-id", "user metadata retained");
    let bad = grpc_request_headers("ftp", "api.example", "/S/M", []);
    assert(is_err(bad), "unsupported scheme rejected");
}

fn test_grpc_metadata_limits_and_reserved_names() {
    let binary = encoding.base64_encode(b"\x00\xff");
    let ok_headers: [http2.Header] = [
        http2.Header { name: "x-request-id", value: "a-1" },
        http2.Header { name: "trace-bin", value: binary }
    ];
    let accepted = grpc_validate_metadata(ok_headers);
    assert(is_ok(accepted), "valid text and binary metadata");
    let upper: [http2.Header] = [
        http2.Header { name: "X-Trace", value: "x" }
    ];
    assert(is_err(grpc_validate_metadata(upper)), "uppercase metadata key rejected");
    let reserved: [http2.Header] = [
        http2.Header { name: "grpc-timeout", value: "1S" }
    ];
    assert(is_err(grpc_validate_metadata(reserved)), "reserved gRPC metadata rejected");
    let bad_binary: [http2.Header] = [
        http2.Header { name: "trace-bin", value: "not base64!" }
    ];
    assert(is_err(grpc_validate_metadata(bad_binary)), "invalid binary metadata rejected");
    let injected: [http2.Header] = [
        http2.Header { name: "x-trace", value: "ok\r\ninjected: yes" }
    ];
    assert(is_err(grpc_validate_metadata(injected)), "line breaks rejected");
    let many: [http2.Header] = [];
    for i in 0..GRPC_DEFAULT_MAX_METADATA_FIELDS + 1 {
        push(many, http2.Header { name: "x-field", value: "v" });
    }
    assert(is_err(grpc_validate_metadata(many)), "metadata field cap enforced");
}

fn test_grpc_request_requires_one_uncompressed_message() {
    let limits = grpc_default_limits();
    let empty_frame = grpc_frame_message(b"", limits);
    guard let frame = empty_frame else let e = err_of(empty_frame) { panic(e); }
    let req = http2.Req {
        stream: 1,
        method: "POST",
        path: "/sample.EmptyService/Call",
        scheme: "https",
        authority: "api.example:443",
        headers: [
            http2.Header { name: "content-type", value: "application/grpc+proto" },
            http2.Header { name: "te", value: "trailers" },
            http2.Header { name: "content-length", value: "5" },
            http2.Header { name: "grpc-timeout", value: "10S" },
            http2.Header { name: "x-request-id", value: "r1" }
        ],
        body: frame
    };
    let parsed = grpc_request(req, limits);
    guard let rpc = parsed else let e = err_of(parsed) { panic(e); }
    assert(rpc.stream == 1 && rpc.path == req.path, "request route retained");
    guard let timeout = rpc.timeout_ns else { panic("gRPC timeout missing"); }
    assert(timeout == 10000000000, "request timeout parsed");
    assert(grpc_message_size(rpc.message) == 0, "empty protobuf message");
    let compressed = http2.Req {
        stream: 3,
        method: "POST",
        path: "/sample.EmptyService/Call",
        scheme: "https",
        authority: "api.example:443",
        headers: [
            http2.Header { name: "content-type", value: "application/grpc" },
            http2.Header { name: "te", value: "trailers" },
            http2.Header { name: "grpc-encoding", value: "gzip" }
        ],
        body: frame
    };
    assert(is_err(grpc_request(compressed, limits)), "compression rejected");
    let missing_te = http2.Req {
        stream: 5,
        method: "POST",
        path: "/sample.EmptyService/Call",
        scheme: "https",
        authority: "api.example:443",
        headers: [http2.Header { name: "content-type", value: "application/grpc" }],
        body: frame
    };
    assert(is_err(grpc_request(missing_te, limits)), "missing te rejected");
}

fn test_grpc_status_trailers_and_response_message() {
    let parsed = grpc_status_from_trailers([
        http2.Header { name: "grpc-status", value: "13" },
        http2.Header { name: "grpc-message", value: "internal%20error%25" }
    ]);
    guard let status = parsed else let e = err_of(parsed) { panic(e); }
    assert(status.code == GRPC_STATUS_INTERNAL, "status code parsed");
    assert(status.message == "internal error%", "percent-decoded status message");
    assert(is_err(grpc_status_from_trailers([])), "status is mandatory");
    assert(is_err(grpc_status_from_trailers([
        http2.Header { name: "grpc-status", value: "00" }
    ])), "noncanonical status rejected");
    assert(is_err(grpc_status_from_trailers([
        http2.Header { name: "grpc-status", value: "1" },
        http2.Header { name: "grpc-message", value: "bad%Q0" }
    ])), "malformed percent escape rejected");
    let limits = grpc_default_limits();
    let response = grpc_response_msg(1, b"ok", limits, GRPC_STATUS_OK, "");
    guard let msg = response else let e = err_of(response) { panic(e); }
    assert(msg.kind == http2.W_TRAILERS, "response closes with gRPC trailers");
    let body = grpc_parse_message(msg.body, limits);
    guard let envelope = body else let e = err_of(body) { panic(e); }
    assert(grpc_message_bytes(envelope) == b"ok", "response has framed protobuf");
    assert(is_err(grpc_response_msg(1, b"", limits, 17, "bad")),
           "invalid response status rejected");
    assert(is_err(grpc_response_msg(1, b"payload", limits,
                                    GRPC_STATUS_INTERNAL, "failed")),
           "non-OK response cannot silently discard protobuf data");
}

fn test_grpc_timeout_units_and_bounds() {
    let encoded = grpc_timeout_header(10000000000);
    guard let value = encoded else let e = err_of(encoded) { panic(e); }
    assert(value == "10S", "timeout uses a compact exact unit");
    let parsed = grpc_parse_timeout("250m");
    guard let timeout_ns = parsed else let e = err_of(parsed) { panic(e); }
    assert(timeout_ns == 250000000, "millisecond timeout parsed");
    assert(is_err(grpc_parse_timeout("123456789S")), "more than eight digits rejected");
    assert(is_err(grpc_parse_timeout("2s")), "unknown unit rejected");
    assert(is_err(grpc_parse_timeout("99999999H")), "nanosecond overflow rejected");
    assert(is_err(grpc_timeout_header(-1)), "negative timeout rejected");
}

fn is_err[T](value: result[T, str]) -> bool {
    if let _ok = value { return false; }
    return true;
}

fn is_ok[T](value: result[T, str]) -> bool {
    if let _ok = value { return true; }
    return false;
}
