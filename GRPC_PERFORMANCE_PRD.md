# gRPC codec performance PRD

Status: superseded by the zero-allocation codec (see "Follow-up" below);
the design section describes the 2026-10-11 codec.
Date: 2026-10-11

## Problem

The original generated protobuf round trip was far behind Go and allocated
heavily. A one-worker CPU comparison on a 1,866-byte generated `User` message
measured about 10.2k round trips/s, 83 µs p50, 218 µs p99, 68.3 KB and 862
slang GC objects per operation. Most generated fields called fallible
`result`-returning primitives even when decoding valid input, and nested map
entries and messages created temporary writers and byte strings.

## Design delivered

- Generated decoders use direct-return bounded primitives. They keep the first
  parse error in request-local state and allocate one public `result` only at
  the outer `decode_<Message>` boundary.
- Nested messages and map entries temporarily narrow the same reader's byte
  range and restore it after decoding. They share the aggregate value budget
  without allocating a child reader object for each entry.
- Generated encoders compute nested payload lengths, then write nested fields
  and map entries directly into the parent writer. This removes temporary
  writers, result boxes, and byte copies from those paths. Public
  `encode_<Message>` and `decode_<Message>` signatures remain fallible.
- Packed repeated fields retain their bounded temporary writer because the
  measured size-pass alternative was slower. Limits, wire checks, contextual
  errors, unknown-field skipping, and public hand-written codec helpers remain
  in place.

## Validation

- Go generator tests, `go vet`, and deterministic generated-fixture checks
  pass.
- The generated consumer round-trips scalars, strings/bytes, packed and
  unpacked lists, optional values, nested messages, and maps. It also checks
  generated size calculations against output bytes, including default-valued
  map entries.
- All 15 slang runtime tests pass normally and under
  `SLANG_GC_VERIFY_MINOR=1 SLANG_GC_NURSERY_KB=16`; the verifier reports
  `missed=0`. The generated consumer also passes minor-GC verification with
  `missed=0`.
- The test runner reaches the generated consumer successfully. Its TLS/HTTP2
  interoperability stage cannot bind `127.0.0.1:18443` in this sandbox, so
  transport interoperability was not verified in this run.
- Against the original package code on the same laptop, a separate three-cycle
  ABBA comparison improved median throughput from 10,159 to 14,495 round
  trips/s (+42.7%), p50 from 83 to 60 µs (-27.7%), and p99 from 218 to 154 µs
  (-29.4%). Allocation fell from 68.3 to 12.7 KB/op (-81%) and from 862 to
  69 objects/op (-92%).

## Current local comparison

This is a CPU-only microbenchmark, not a gRPC server or HTTP/2/TLS benchmark.
It uses the same generated fixture and one worker for slang and Go. Three
interleaved ABBA rounds produced six samples per implementation. Throughput
runs perform 20,000 slang or 100,000 Go round trips; latency runs sample
10,000 operations. The reported values are medians. slang GC allocation
accounting and Go runtime allocation accounting are directional comparisons.

| Implementation | Throughput | p50 | p99 | Allocated bytes/op | Objects/op |
|---|---:|---:|---:|---:|---:|
| slang generated codec | 16,056 ops/s | 60.0 µs | 129 µs | 12.7 KB | 69 |
| Go `google.golang.org/protobuf` v1.36.12 | 148,933 ops/s | 5.96 µs | 23.37 µs | 4.98 KB | 44 |

The current codec remains about 9.3x behind Go in throughput, 10.1x in p50,
and 5.5x in p99. The allocation reduction is substantial, but this is not
parity. The next performance work should profile the generated C and runtime
calls on a stable Linux host, then target the largest remaining instruction
and allocation costs. Peak RSS and real RPC throughput remain unmeasured.

## Non-goals

No wire format or generated public message API changes, no reflection, no
unbounded input, and no parity claim from codec-only measurements.

## Follow-up: zero-allocation codec (2026-10-24)

The `*_fast` primitives, their request-local error state and the packed
temporary writer are replaced by one design: reader primitives return
`result[T, int]` error codes (a result with no GC-pointer payload is a plain
value, so a successful read allocates nothing), one `Reader` is narrowed for
nested messages, packed fields and map entries, and encoders run a pure
`size_<M>` pass, then a `write_<M>` pass into one builder, with `check_<M>`
naming a failing field only after `size_<M>` reports one. Sizing is
recomputed once per nesting level.

Same 139-byte consumer fixture, same laptop and compiler (slangc 0.2.3),
`bench/codec/run.sh`:

| Codec | Encode | Decode |
|---|---:|---:|
| 2026-10-11 (`_fast` primitives) | 9.6 us, 22 allocations | 8.1 us, 31 allocations |
| zero-allocation codec | 6.8 us, 15 allocations | 5.3 us, 33 allocations |
| Go google.golang.org/protobuf v1.36.12 | 1.3 us, 7 allocations | 1.45 us, 19 allocations |

Encoded bytes are byte-identical to Go's `proto.Marshal`
(`bench/codec/compare-go.sh`). `tests/run.sh` enforces 16 and 34
allocations. The consumer keeps this PRD's size and default-valued map
checks. With slang's perf/cache-current-task (dev, 2026-10-24) the same
codec measured 4.7 us encode and 4.0 us decode.
