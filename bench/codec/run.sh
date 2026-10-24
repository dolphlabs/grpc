#!/bin/sh
# Codec cost per operation: time and GC allocations, for encode and decode
# of the consumer fixture's User.
#   bench/codec/run.sh                 report
#   bench/codec/run.sh --check         also fail above the allocation budgets
# Allocations are exact and machine-independent, so they are the budget;
# time is reported only.
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
slangc=${SLANGC:-slangc}
iterations=${ITERATIONS:-100000}
# Per operation. Before the zero-allocation codec: 125 and 212.
encode_budget=16
decode_budget=34

run_dir=$(mktemp -d "${TMPDIR:-/tmp}/grpc-codec-bench.XXXXXX")
trap 'rm -rf "$run_dir"' EXIT HUP INT TERM
cp "$repo/bench/codec/main.sl" "$repo/tests/consumer/codec.pb.sl" "$run_dir/"
mkdir "$run_dir/grpc"
# rpc.sl is not needed by the codec and needs the HTTP/2 client API.
cp "$repo/src/grpc/proto.sl" "$repo/src/grpc/grpc.sl" "$run_dir/grpc/"
(cd "$run_dir" && "$slangc" main.sl -o codec >/dev/null)

status=0
for mode in encode decode; do
    out=$(cd "$run_dir" && SLANG_GC_STAT=1 ./codec "$mode" "$iterations" 2>"$run_dir/stat")
    allocs=$(grep -oE 'allocs=[0-9]+' "$run_dir/stat" | head -1 | cut -d= -f2)
    bytes=$(grep -oE 'alloc_bytes=[0-9]+' "$run_dir/stat" | head -1 | cut -d= -f2)
    per_op=$((allocs / iterations))
    printf '%s, %s allocs/op, %s bytes/op\n' "$out" "$per_op" "$((bytes / iterations))"
    if [ "${1:-}" = "--check" ]; then
        budget=$encode_budget
        [ "$mode" = decode ] && budget=$decode_budget
        if [ "$per_op" -gt "$budget" ]; then
            echo "FAIL $mode: $per_op allocations per operation, budget $budget" >&2
            status=1
        fi
    fi
done
exit $status
