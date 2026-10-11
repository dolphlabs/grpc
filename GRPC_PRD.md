# grpc package PRD

Status: v1 implementation and interoperability checks are in place; comparative
codec performance measurement remains pending.
Date: 2026-10-11

## Goal

Build a standalone `grpc` slang package with a separate `protoc-gen-slang`
tool. Generated messages are ordinary statically typed slang structs with
direct protobuf codecs. The runtime package owns protobuf wire primitives,
gRPC message framing, metadata validation, status mapping, and unary call
helpers. The compiler and generic HTTP/2 package own no protobuf or gRPC
semantics.

This design avoids reflection, dynamic message trees, closures, and compiler
changes. Applications can inspect generated source and use their normal
slang structs, functions, and `result` values. The Zokor integration can be a
thin adapter after the standalone package is stable.

## V1 scope

- Proto3 messages and enums; scalar numeric/bool/string/bytes fields; nested
  messages; optional presence; repeated fields with packed and unpacked wire
  forms; and protobuf maps to slang maps where the key/value types are
  representable.
- A Go `protoc-gen-slang` plugin under `cmd/protoc-gen-slang/`, consuming
  standard `CodeGeneratorRequest` descriptors and emitting one slang source
  file per input proto. Unsupported constructs fail with the file, type, and
  field or RPC name plus the construct to remove or change.
- Bounded protobuf reader/writer primitives. Generated decoders skip unknown
  fields, reject malformed tags/lengths/wire types, and enforce a total
  message-size and nesting limit. Generated encoders omit proto3 defaults and
  use packed encoding for packable repeated fields.
- Unary RPC request/response envelopes and gRPC HTTP/2 metadata/status helpers.
  Calls use `POST`, `application/grpc`, `te: trailers`, and a five-byte message
  prefix. Compressed requests are rejected until a bounded compression API is
  designed. `grpc-status` in trailing headers determines RPC success.
- TLS with ALPN `h2` for production and h2c prior knowledge for local
  interoperability tests. Use slang's generic HTTP/2 transport; it must remain
  protocol agnostic. If generic HTTP/2 client streams are missing, add that
  API independently in slang before package client calls depend on it.
- Unary request/response service functions and clients. No bidirectional,
  client, or server streaming; no reflection service; no dynamic descriptors.

## Type and code generation rules

- Preserve proto field names as snake_case slang fields. Protobuf enum fields
  use `int` plus generated named integer constants so unknown proto3 enum
  numbers round-trip unchanged; slang enums cannot represent arbitrary future
  values. Generate one `encode_<Type>` and one
  `decode_<Type>` function per message.
- Map fields to native slang lists/maps and optional fields to `opt[T]`.
  Allocate only the output values needed by the decoded message; keep unknown
  length-delimited fields as input slices while skipping them.
- Emit direct field-number switches in decoders and a builder-backed encoder;
  no per-field interface or reflection dispatch.
- Keep generated names deterministic and escape reserved slang identifiers.
  Reject collisions instead of silently renaming two source declarations to
  the same slang symbol.
- The plugin accepts only unary RPC declarations in v1. Generate typed
  request/response codec and service path constants; application handlers are
  ordinary named functions passed to generic unary helpers.

## Bounds and security

- Default maximum protobuf message size: 4 MiB; hard maximum: 64 MiB.
  `Limits` can lower or raise the default up to the hard maximum.
- Cap nesting depth at 64 and decoded fields/elements at 100,000 by default;
  limits are validated before allocation and checked for every nested value.
- Reject varints longer than ten bytes, overflow in uint64/length values,
  field number zero or above 2^29-1, illegal wire types, truncated packed
  values, invalid UTF-8 strings, and malformed submessage boundaries.
- Unknown fields are skipped by wire type with bounds checks. Groups (wire
  types 3/4) are rejected rather than recursively accepted.
- Reject duplicate singular fields and duplicate map keys only if the selected
  proto semantics require unambiguous decoding; otherwise generated decoders
  follow protobuf's last-value-wins singular/map rule and append repeated
  values. This behavior must be covered by Go interoperability fixtures.
- Validate HTTP/2 pseudo headers, method/path, content type, `te`, metadata
  names/values, timeout grammar, and trailer status. Never log request or
  response bodies or metadata values by default.
- Never retry a unary request automatically: the server may have processed a
  request before a connection failure.

## Performance and validation

- Consumer compile and generated-source tests for every supported field kind,
  packed/unpacked repeated data, nested messages, maps, optional presence,
  enums, and unary service descriptors.
- Independent `google.golang.org/protobuf` and Go `golang.org/x/net/http2`
  interoperability in both directions for unary h2c and TLS/ALPN `h2`.
- Malformed-wire tests for every overflow/bounds case, plus GC-minor verifier
  runs for decoded nested/repeated messages.
- Compare protobuf codec throughput, p50/p99 latency, allocations, and peak
  RSS against Go's protobuf implementation with identical fixtures. Run
  performance comparisons on the configured cloud benchmark environment,
  using randomized ABBA order; local runs are correctness/smoke checks only.
- Full slang `make test`, warning sweep, package consumer test, generated-file
  determinism check, and Go plugin tests before release.

## Release boundary

The package remains source-only under `src/grpc`. The Go plugin is excluded
from dependency downloads along with benchmarks. Applications importing only
`grpc` need the package source and a slang compiler with the generic HTTP/2
client-stream and response-trailer APIs. The plugin is built separately with
Go and protoc; it is not in a request's runtime dependency graph.
