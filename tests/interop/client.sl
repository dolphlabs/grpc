import "grpc";
import "http2";
import "net";
import "proc";

fn require(ok: bool, message: str) {
    if !ok { panic("gRPC Go interop failed: " + message); }
}

let cert_result = proc.getenv("GRPC_TEST_CERT");
guard let cert = cert_result else { panic("GRPC_TEST_CERT is required"); }
let context_result = net.tls_client_ctx(cert);
guard let context = context_result else let e = err_of(context_result) { panic(e); }
let alpn_result = net.tls_ctx_alpn(context, "h2");
guard let _alpn = alpn_result else let e = err_of(alpn_result) { panic(e); }
let dial_result = net.tls_dial("localhost", 18443, context);
guard let ssl = dial_result else let e = err_of(dial_result) { panic(e); }
require(http2.alpn_is_h2(net.tls_alpn(ssl)), "TLS chose h2");

let transport = http2.transport_tls(ssl);
let reader = http2.reader_new();
let conn = http2.conn_new();
let writer: chan[http2.WMsg] = make_chan(16);
let h2_limits = http2.default_limits();
spawn http2.writer_task(transport, writer, h2_limits.write);
let started = grpc.grpc_client_start(reader, transport, writer, h2_limits);
guard let _started = started else let e = err_of(started) { panic(e); }

let user = new_User();
user.id = 17;
user.name = "Ada";
let codec_limits = grpc.proto_default_limits();
let encoded_result = encode_User(user, codec_limits);
guard let encoded = encoded_result else let e = err_of(encoded_result) { panic(e); }
let call_result = grpc.grpc_unary_call(
    conn, reader, transport, writer, 1, "https", "localhost:18443",
    "/sample.UserService/Get",
    [http2.Header { name: "x-request-id", value: "rpc-1" }],
    encoded, grpc.grpc_default_limits(), 2000000000);
guard let call = call_result else let e = err_of(call_result) { panic(e); }
require(call.status.code == grpc.GRPC_STATUS_OK, "RPC status");
require(call.status.message == "interop ok", "percent-decoded status message");
guard let response_message = call.message else { panic("response message is missing"); }
let decoded_result = decode_User(grpc.grpc_message_bytes(response_message), codec_limits);
guard let decoded = decoded_result else let e = err_of(decoded_result) { panic(e); }
require(decoded.id == 17 && decoded.name == "Ada", "generated protobuf round trip");
net.tls_close(ssl);
chan_close(writer);
println("Go TLS HTTP/2 unary gRPC interop passed");
