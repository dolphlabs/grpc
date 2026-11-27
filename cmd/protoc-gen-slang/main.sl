import "builder";
import "fs";
import "io";

fn max_plugin_bytes() -> int {
    return 67108864;
}

fn encode_response(files: [GeneratedFile], err_msg: str) -> bytes {
    let out = builder.new_bytes();
    if len(err_msg) > 0 {
        append_string_field(out, 1, err_msg);
        append_varint_field(out, 2, 1 as u64); // FEATURE_PROTO3_OPTIONAL
        return out.finish();
    }
    append_varint_field(out, 2, 1 as u64); // FEATURE_PROTO3_OPTIONAL
    for i in 0..len(files) {
        let file = files[i];
        let entry = builder.new_bytes();
        append_string_field(entry, 1, file.name);
        append_string_field(entry, 15, file.content);
        append_bytes_field(out, 15, entry.finish());
    }
    return out.finish();
}

fn run_plugin(input: bytes) -> bytes {
    if len(input) > max_plugin_bytes() {
        return encode_response([], "CodeGeneratorRequest exceeds 64 MiB");
    }
    let req_res = parse_request(input);
    guard let req = req_res else let e = err_of(req_res) {
        return encode_response([], e);
    }
    let gen_res = generate(req.files_to_generate, req.files);
    guard let files = gen_res else let e = err_of(gen_res) {
        return encode_response([], e);
    }
    return encode_response(files, "");
}

fn write_all_fd(fd: int, data: bytes) -> result[bool, str] {
    let off = 0;
    while off < len(data) {
        let chunk = data;
        if off > 0 {
            chunk = slice_bytes(data, off, len(data));
        }
        let wr = fs.write(fd, chunk);
        guard let n = wr else let e = err_of(wr) { return err(e); }
        if n <= 0 {
            return err("short write to stdout");
        }
        off = off + n;
    }
    return ok(true);
}

fn plugin_entry() -> int {
    let rr = io.read_all();
    guard let input = rr else let e = err_of(rr) {
        let resp = encode_response([], "read stdin: " + e);
        let _w = write_all_fd(1, resp);
        return 0;
    }
    let resp = run_plugin(input);
    let wr = write_all_fd(1, resp);
    guard let _wok = wr else let e = err_of(wr) {
        io.eprintln("protoc-gen-slang: " + e);
        return 1;
    }
    return 0;
}

exit(plugin_entry());
