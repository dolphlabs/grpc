# grpc

`grpc` is a standalone unary gRPC package for slang. It provides bounded
Protocol Buffers wire codecs, gRPC message and metadata handling, a Go
`protoc-gen-slang` generator, and unary calls over slang's protocol-neutral
HTTP/2 client. Generated messages are ordinary slang structs; runtime
encoding uses direct field-number switches and has no reflection or dynamic
message tree.

## Generate typed messages

Build the generator with Go and `protoc`, then generate the slang source next
to the application's `.proto` files:

```sh
go build -o ./bin/protoc-gen-slang ./cmd/protoc-gen-slang
protoc --plugin=protoc-gen-slang=./bin/protoc-gen-slang \
  --proto_path=proto --slang_out=src/generated proto/user.proto
```

Import the generated file and the package from application code:

```slang
import "grpc";
import "generated/user.pb";

let user = new_User();
user.id = 17;
user.name = "Ada";
let encoded_result = encode_User(user, grpc.proto_default_limits());
guard let encoded = encoded_result else let e = err_of(encoded_result) {
    log.error(e);
    return;
}
```

The generator emits `new_<Message>`, `encode_<Message>`, and
`decode_<Message>` for each message, named integer constants for enum values,
and `<SERVICE>_<METHOD>_PATH` constants for unary RPCs. Codec functions
return `result` and take explicit protobuf limits. Keep generated source in
the application repository so builds do not need `protoc` or Go.

V1 supports proto3 scalar numbers, booleans, strings and bytes; nested
messages; enums; optional presence; repeated and packed fields; maps; and
unary services. Proto3 enum fields use `int`, preserving unknown numeric
values. Unsupported declarations produce a generator error naming the
construct to change. Streaming RPCs, `oneof`, groups, extensions, custom
options, and dynamic reflection are outside v1.

## Unary client

The application owns DNS, TLS, certificate verification, ALPN, connection
lifetime, and the writer task. Negotiate `h2` before starting the HTTP/2
preface. `grpc_unary_call` sends one request and waits for its complete
response, including the final gRPC status trailers:

```slang
let transport = http2.transport_tls(ssl);
let reader = http2.reader_new();
let conn = http2.conn_new();
let writer: chan[http2.WMsg] = make_chan(16);
let h2_limits = http2.default_limits();
spawn http2.writer_task(transport, writer, h2_limits.write);
guard let _started = grpc.grpc_client_start(
        conn, reader, transport, writer, h2_limits) else { return; }

let wire = encode_User(user, grpc.proto_default_limits());
guard let protobuf = wire else { return; }
let response = grpc.grpc_unary_call(
    conn, reader, transport, writer, 1, "https", "api.example:443",
    SAMPLE_USERSERVICE_GET_PATH, [], protobuf,
    grpc.grpc_default_limits(), 2000000000);
guard let call = response else let e = err_of(response) {
    log.error(e);
    return;
}
if call.status.code != grpc.GRPC_STATUS_OK {
    log.error(call.status.message);
    return;
}
guard let message = call.message else { return; }
let decoded = decode_User(grpc.grpc_message_bytes(message),
                           grpc.proto_default_limits());
```

The HTTP/2 reader is single-consumer: only one task may read a response from
it at a time. Stream IDs must be odd and increase on a connection. The
package does not retry calls; a transport error can happen after the server
has already performed the operation. Reuse a live HTTP/2 connection only
when the application controls those stream and reader rules.

## Concurrent calls on one connection

`grpc_unary_call` above carries one stream at a time. For many calls at
once, start an `http2.Client` on the connection and call `grpc_call` from
as many tasks as you like: each call is its own HTTP/2 stream with its own
deadline, the client respects the server's concurrent-stream limit, and a
call past its deadline is cancelled (RST_STREAM) and answers
`DEADLINE_EXCEEDED`:

```slang
let started = http2.client_start(http2.transport_tls(ssl), http2.default_limits());
guard let client = started else let e = err_of(started) { return; }
let r = grpc.grpc_call(client, "https", "api.example:443",
                       SAMPLE_USERSERVICE_GET_PATH, [], protobuf,
                       grpc.grpc_default_limits(), 2000000000);
guard let call = r else let e = err_of(r) { return; }
http2.client_close(client);
```

`tests/interop/client.sl` runs ten such calls at once against Go's
`net/http` HTTP/2 server over TLS. A trailers-only response (an error
status with no message, in one header block) is read the same way.

## Server helpers

Pass each `http2.Req` to `grpc_request` to validate the unary request
envelope and retain its protobuf message as a view into the HTTP body. Decode
it with the generated codec, run the handler, encode a response, and return
`grpc_response_msg` through the normal HTTP/2 writer. The response helper
places `grpc-status` and an optional percent-encoded `grpc-message` in
trailers. A non-OK status requires an empty protobuf payload.

`grpc_request` checks `POST`, the `/service/method` path, gRPC content type,
exactly one `te: trailers`, identity encoding, timeout grammar, content
length, metadata bounds and the five-byte uncompressed message envelope.
Use the ordinary HTTP/2 server deadlines and request-body cap as well; the
gRPC package does not own sockets or scheduling.

## Codec performance

Generated codecs decode nested messages and map entries in place, and encode
nested values directly into the parent writer. In a local one-worker CPU
microbenchmark of a 1,866-byte `User` round trip, slang measured 16,056 ops/s,
60 µs p50 and 129 µs p99; Go's protobuf implementation measured 148,933 ops/s,
5.96 µs p50 and 23.37 µs p99. The optimized codec allocates about 12.7 KB and
69 GC objects per operation, down from 68.3 KB and 862 objects in the original
implementation. It remains slower than Go, and these figures do not measure a
server, HTTP/2, TLS or peak RSS. The method and A/B results are in
[GRPC_PERFORMANCE_PRD.md](GRPC_PERFORMANCE_PRD.md).

## Limits and errors

Default maximum message size is 4 MiB; the hard maximum is 64 MiB. The
protobuf reader also defaults to depth 32 and 100,000 decoded values, with
hard caps of depth 64 and 1,000,000 values. Set lower limits for the service's
actual schema and request budget. Encoders omit proto3 defaults; decoders
skip unknown fields and reject malformed tags, overflowed lengths, invalid
UTF-8, truncated values, unsupported compression, and limit violations.
Nested messages share the original input buffer, and a parsed gRPC message
is a view until `grpc_message_bytes` is requested.

## Cost

Decoding walks one reader over the whole message tree and allocates only
the decoded values: strings, bytes, lists, maps and one result per
message. Encoding sizes the message first, checks the total against the
limit once, then writes every field into one buffer. For the 139-byte,
21-field fixture in `tests/consumer`, `bench/codec/run.sh` reports 15
allocations per encode and 33 per decode (125 and 212 before this
design), about 1.6 KB and 2.6 KB allocated, and 2.0x and 2.4x the
speed (6.8 and 5.3 us, from 13.5 and 12.5, on an Intel laptop).
`tests/run.sh` fails above 16 and 34. `bench/codec/compare-go.sh` runs the
same fixture through google.golang.org/protobuf: the bytes are identical, and
Go is still 5.1x faster to encode and 3.6x to decode. Sizing is recomputed per nesting
level, so a message nested d levels deep has its innermost fields sized d
times; generated structs carry no size cache.

## Package layout

- `src/grpc`: slang runtime package and focused unit tests.
- `cmd/protoc-gen-slang`: standalone Go generator, excluded from package
  downloads.
- `tests`: generator fixtures, generated consumer, and independent Go TLS /
  HTTP/2 interoperability server; excluded from package downloads.
- `bench`: benchmark programs; excluded from package downloads.

Run `sh tests/run.sh` for Go generator checks, deterministic fixture
generation, generated-code compilation, codec cases, and the Go TLS/ALPN
HTTP/2 unary interoperability test. Run slang package tests with
`slangc test src/grpc -v`.
