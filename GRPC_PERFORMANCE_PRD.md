# gRPC codec performance PRD

Status: generated codec optimization implemented and locally measured.
Date: 2026-10-11

## Problem

The original generated protobuf round trip was far behind Go and allocated
heavily. A one-worker CPU comparison on a 1,866-byte generated `User` message
measured about 10.2k round trips/s, 83 µs p50, 218 µs p99, 68.3 KB and 862
Slang GC objects per operation. Most generated fields called fallible
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
- All 15 Slang runtime tests pass normally and under
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
It uses the same generated fixture and one worker for Slang and Go. Three
interleaved ABBA rounds produced six samples per implementation. Throughput
runs perform 20,000 Slang or 100,000 Go round trips; latency runs sample
10,000 operations. The reported values are medians. Slang GC allocation
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
