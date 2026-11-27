import "builder";
import "strings";

fn bslice(vals: [int]) -> bytes {
    let b = builder.new_bytes();
    for i in 0..len(vals) {
        b.write_byte(vals[i]);
    }
    return b.finish();
}

fn make_empty_file(name: str, pkg: str, syntax: str) -> FileDesc {
    return FileDesc {
        name: name,
        pkg: pkg,
        syntax: syntax,
        messages: [],
        enums: [],
        services: []
    };
}

fn test_parse_wire_rejects_malformed_fields() {
    let cases = [
        bslice([0]),
        bslice([136, 0, 0]),
        bslice([11]),
        bslice([10, 2, 1])
    ];
    let wants = [
        "invalid field number",
        "non-canonical varint",
        "unsupported protobuf wire type",
        "length exceeds remaining bytes"
    ];
    for i in 0..len(cases) {
        let pr = parse_wire(cases[i]);
        if let _ok = pr {
            panic("expected parse_wire error containing " + wants[i]);
        } else let e = err_of(pr) {
            assert(strings.contains(e, wants[i]), "parseWire error: " + e);
        }
    }
}

fn test_parse_wire_caps_descriptor_field_count() {
    let b = builder.new_bytes();
    let cap = max_descriptor_fields();
    for i in 0..(cap + 1) {
        b.write_byte(8);
        b.write_byte(0);
    }
    let pr = parse_wire(b.finish());
    if let _ok = pr {
        panic("expected descriptor field cap error");
    } else let e = err_of(pr) {
        assert(strings.contains(e, "descriptor exceeds"), "descriptor cap error: " + e);
    }
}

fn test_parse_file_uses_package_independent_of_wire_order() {
    let msg = builder.new_bytes();
    append_string_field(msg, 1, "User");

    let raw = builder.new_bytes();
    append_bytes_field(raw, 4, msg.finish());
    append_string_field(raw, 2, "example.v1");
    append_string_field(raw, 1, "user.proto");
    append_string_field(raw, 12, "proto3");

    let fr = parse_file(raw.finish());
    guard let file = fr else let e = err_of(fr) {
        panic("parse_file failed: " + e);
    }
    assert(len(file.messages) == 1 && file.messages[0].full_name == "example.v1.User",
           "message full name: " + file.messages[0].full_name);
}

fn test_generate_rejects_unsafe_and_duplicate_inputs() {
    let bad_names = [
        "../escape.proto",
        "dir/../escape.proto",
        "/absolute.proto",
        "bad\\path.proto",
        "bad\nname.proto"
    ];
    for i in 0..len(bad_names) {
        let name = bad_names[i];
        let gr = generate([name], [make_empty_file(name, "", "proto3")]);
        if let _ok = gr {
            panic("expected unsafe path error for " + name);
        } else let e = err_of(gr) {
            assert(strings.contains(e, "safe relative path"), "unsafe path error: " + e);
        }
    }
    let f = make_empty_file("user.proto", "", "proto3");
    let dup_req = generate(["user.proto", "user.proto"], [f]);
    if let _ok = dup_req {
        panic("expected duplicate requested input error");
    } else let e = err_of(dup_req) {
        assert(strings.contains(e, "more than once"), "dup req error: " + e);
    }

    let dup_desc = generate(["user.proto"], [make_empty_file("user.proto", "", "proto3"), make_empty_file("user.proto", "", "proto3")]);
    if let _ok = dup_desc {
        panic("expected duplicate descriptor error");
    } else let e = err_of(dup_desc) {
        assert(strings.contains(e, "duplicate descriptor"), "dup desc error: " + e);
    }
}

fn test_parse_enum_allows_declared_aliases() {
    let zero = builder.new_bytes();
    append_string_field(zero, 1, "COLOR_UNSPECIFIED");
    append_varint_field(zero, 2, 0 as u64);

    let one = builder.new_bytes();
    append_string_field(one, 1, "COLOR_RED");
    append_varint_field(one, 2, 1 as u64);

    let alias = builder.new_bytes();
    append_string_field(alias, 1, "COLOR_CRIMSON");
    append_varint_field(alias, 2, 1 as u64);

    let options = builder.new_bytes();
    append_varint_field(options, 2, 1 as u64);

    let raw = builder.new_bytes();
    append_string_field(raw, 1, "Color");
    append_bytes_field(raw, 2, zero.finish());
    append_bytes_field(raw, 2, one.finish());
    append_bytes_field(raw, 2, alias.finish());
    append_bytes_field(raw, 3, options.finish());

    let er = parse_enum(raw.finish(), "example", []);
    guard let e = er else let err_msg = err_of(er) {
        panic("parse_enum failed: " + err_msg);
    }
    assert(e.allow_alias && len(e.values) == 3 && e.values[1].number == e.values[2].number,
           "alias descriptor preserved");
}

fn test_run_plugin_empty_request_emits_error_and_feature_flags() {
    let resp = run_plugin(b"");
    let wr = parse_wire(resp);
    guard let fields = wr else let e = err_of(wr) {
        panic("response decode failed: " + e);
    }
    assert(len(fields) == 2, "error response fields");
    assert(fields[0].number == 1 && fields[0].wire == 2, "error string field");
    assert(strings.contains(bytes_to_str(fields[0].raw), "no input files"), "error text");
    assert(fields[1].number == 2 && fields[1].value == (1 as u64), "proto3 optional feature");
}
