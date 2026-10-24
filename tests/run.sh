#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
slangc=${SLANGC:-slangc}
run_dir=$(mktemp -d "${TMPDIR:-/tmp}/grpc-test.XXXXXX")
server_pid=
trap 'kill "${server_pid:-}" 2>/dev/null || true; rm -rf "$run_dir"' EXIT HUP INT TERM

(cd "$repo/cmd/protoc-gen-slang" && go test ./... && go vet ./... &&
    go build -o "$run_dir/protoc-gen-slang" .)
mkdir "$run_dir/generated"
(cd "$repo/tests/proto" && protoc \
    --plugin=protoc-gen-slang="$run_dir/protoc-gen-slang" \
    --proto_path=. --slang_out="$run_dir/generated" codec.proto)
cmp "$repo/tests/consumer/codec.pb.sl" "$run_dir/generated/codec.pb.sl"

mkdir "$run_dir/consumer"
cp "$repo/tests/consumer/main.sl" "$repo/tests/consumer/codec.pb.sl" \
    "$run_dir/consumer/"
ln -s "$repo/src/grpc" "$run_dir/consumer/grpc"
actual=$(cd "$run_dir/consumer" && "$slangc" main.sl --run)
expected=$(cat "$repo/tests/consumer/expected.txt")
if [ "$actual" != "$expected" ]; then
    printf '%s\n' "gRPC consumer output mismatch" >&2
    printf '%s\n' "--- expected ---" "$expected" "--- actual ---" "$actual" >&2
    exit 1
fi
printf '%s\n' "$actual"

# The codec's allocation budget: a regression that boxes a value per field
# again fails here rather than in a benchmark nobody reran.
SLANGC="$slangc" ITERATIONS=20000 "$repo/bench/codec/run.sh" --check

go build -o "$run_dir/interop-server" "$repo/tests/interop/server.go"
"$run_dir/interop-server" "$run_dir/cert.pem" &
server_pid=$!
i=0
while [ "$i" -lt 100 ]; do
    if nc -z 127.0.0.1 18443 2>/dev/null; then break; fi
    i=$((i + 1))
    sleep 0.1
done
if [ "$i" -ge 100 ]; then
    echo "gRPC Go interop server did not start" >&2
    exit 1
fi

mkdir "$run_dir/interop-client"
cp "$repo/tests/interop/client.sl" "$repo/tests/consumer/codec.pb.sl" \
    "$run_dir/interop-client/"
ln -s "$repo/src/grpc" "$run_dir/interop-client/grpc"
actual=$(cd "$run_dir/interop-client" && \
    GRPC_TEST_CERT="$run_dir/cert.pem" "$slangc" client.sl --run)
printf '%s\n' "$actual"
