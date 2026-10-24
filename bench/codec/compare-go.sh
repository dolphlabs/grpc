#!/bin/sh
# The same User fixture through google.golang.org/protobuf: checks that Go's
# encoding is byte-identical to slang's and that Go decodes slang's bytes,
# then reports Go's encode and decode cost next to bench/codec/run.sh's.
# Needs Go and protoc; the Go bindings are generated into a temp directory.
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
slangc=${SLANGC:-slangc}
run_dir=$(mktemp -d "${TMPDIR:-/tmp}/grpc-codec-go.XXXXXX")
trap 'rm -rf "$run_dir"' EXIT HUP INT TERM

cp -R "$repo/bench/codec/go" "$run_dir/go"
mkdir "$run_dir/go/codecpb"
(cd "$run_dir/go" && go build -o "$run_dir/protoc-gen-go" google.golang.org/protobuf/cmd/protoc-gen-go)
(cd "$repo/tests/proto" && protoc --plugin=protoc-gen-go="$run_dir/protoc-gen-go" \
    --proto_path=. --go_out="$run_dir/go/codecpb" --go_opt=paths=source_relative \
    --go_opt=Mcodec.proto=github.com/dolphlabs/grpc/bench/codec/go/codecpb codec.proto)

# slang's bytes for the same fixture, as written by bench/codec/main.sl.
mkdir -p "$run_dir/slang/grpc"
cp "$repo/bench/codec/main.sl" "$repo/tests/consumer/codec.pb.sl" "$run_dir/slang/"
cp "$repo/src/grpc/proto.sl" "$repo/src/grpc/grpc.sl" "$run_dir/slang/grpc/"
(cd "$run_dir/slang" && "$slangc" main.sl -o codec >/dev/null && ./codec wire "$run_dir/user.bin")

(cd "$run_dir/go" && go build -o "$run_dir/gobench" . && "$run_dir/gobench" "$run_dir/user.bin")
