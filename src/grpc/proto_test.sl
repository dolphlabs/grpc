fn grpc_proto_expect(ok: bool, message: str) {
    if !ok { panic("grpc proto test: " + message); }
}

fn grpc_proto_test_varints() -> str {
    let limits = proto_default_limits();
    let made = proto_writer(limits);
    guard let writer = made else let e = err_of(made) { return e; }
    let a = proto_writer_varint(writer, 0);
    guard let _a = a else let e = err_of(a) { return e; }
    let b = proto_writer_varint(writer, 127);
    guard let _b = b else let e = err_of(b) { return e; }
    let c = proto_writer_varint(writer, 128);
    guard let _c = c else let e = err_of(c) { return e; }
    let d = proto_writer_varint(writer, 300);
    guard let _d = d else let e = err_of(d) { return e; }
    let e = proto_writer_varint(writer, 18446744073709551615 as u64);
    guard let _e = e else let error = err_of(e) { return error; }
    let encoded = proto_writer_finish(writer);
    grpc_proto_expect(encoded == b"\x00\x7f\x80\x01\xac\x02\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01",
                      "varint writer bytes differ from protobuf vectors");

    let reader_result = proto_reader(encoded, limits);
    guard let reader = reader_result else let error = err_of(reader_result) {
        return error;
    }
    let values: [u64] = [0 as u64, 127 as u64, 128 as u64, 300 as u64, 18446744073709551615 as u64];
    let i = 0;
    while i < len(values) {
        let got = proto_reader_varint(reader);
        guard let value = got else let error = err_of(got) { return error; }
        grpc_proto_expect(value == values[i], "varint decoder value mismatch");
        i = i + 1;
    }
    grpc_proto_expect(proto_reader_done(reader), "varint reader left bytes");
    return "";
}

fn grpc_proto_test_tags_and_skip() -> str {
    let raw = b"\x08\x96\x01\x11\x01\x02\x03\x04\x05\x06\x07\x08\x1a\x03abc\x25\x09\x0a\x0b\x0c";
    let made = proto_reader(raw, proto_default_limits());
    guard let reader = made else let e = err_of(made) { return e; }
    let first_result = proto_reader_tag(reader);
    guard let first = first_result else let e = err_of(first_result) { return e; }
    guard let first_tag = first else { return "first tag missing"; }
    grpc_proto_expect(first_tag.field_number == 1 && first_tag.wire_type == PROTO_VARINT,
                      "wrong varint tag");
    let number = proto_reader_varint(reader);
    guard let n = number else let e = err_of(number) { return e; }
    grpc_proto_expect(n == 150, "tag value mismatch");

    let expected_fields = [2, 3, 4];
    let expected_wires = [PROTO_FIXED64, PROTO_BYTES, PROTO_FIXED32];
    let i = 0;
    while i < 3 {
        let next = proto_reader_tag(reader);
        guard let got = next else let e = err_of(next) { return e; }
        guard let tag = got else { return "unknown field tag missing"; }
        grpc_proto_expect(tag.field_number == expected_fields[i] &&
                          tag.wire_type == expected_wires[i], "unknown tag mismatch");
        let skipped = proto_reader_skip(reader, tag.wire_type);
        guard let _ok = skipped else let e = err_of(skipped) { return e; }
        i = i + 1;
    }
    grpc_proto_expect(proto_reader_done(reader), "unknown fields left bytes");
    return "";
}

fn grpc_proto_test_rejects_bad_varints() -> str {
    let bad: [bytes] = [b"\x80", b"\x80\x80\x80\x80\x80\x80\x80\x80\x80\x02",
                        b"\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x00"];
    let i = 0;
    while i < len(bad) {
        let made = proto_reader(bad[i], proto_default_limits());
        guard let reader = made else let e = err_of(made) { return e; }
        let value = proto_reader_varint(reader);
        if let _v = value { return "accepted malformed varint"; }
        i = i + 1;
    }
    return "";
}

fn grpc_proto_test_bounds_and_submessages() -> str {
    let limits_result = proto_new_limits(32, 1, 2);
    guard let limits = limits_result else let e = err_of(limits_result) { return e; }
    let raw = b"\x0a\x02\x08\x01";
    let made = proto_reader(raw, limits);
    guard let reader = made else let e = err_of(made) { return e; }
    let tag_result = proto_reader_tag(reader);
    guard let tag_opt = tag_result else let e = err_of(tag_result) { return e; }
    guard let tag = tag_opt else { return "outer tag missing"; }
    grpc_proto_expect(tag.wire_type == PROTO_BYTES, "outer wire type");
    let child_result = proto_reader_submessage(reader);
    guard let child = child_result else let e = err_of(child_result) { return e; }
    let child_tag_result = proto_reader_tag(child);
    guard let child_tag_opt = child_tag_result else let e = err_of(child_tag_result) { return e; }
    guard let child_tag = child_tag_opt else { return "child tag missing"; }
    grpc_proto_expect(child_tag.field_number == 1, "child field number");
    let child_value = proto_reader_varint(child);
    guard let value = child_value else let e = err_of(child_value) { return e; }
    grpc_proto_expect(value == 1, "child field value");
    let third_result = proto_reader_tag(reader);
    guard let third = third_result else let e = err_of(third_result) { return e; }
    if let _t = third { return "parent reader skipped bytes inconsistently"; }
    return "";
}

fn grpc_proto_test_message_envelope() -> str {
    let limits = grpc_default_limits();
    let framed_result = grpc_frame_message(b"\x08\x96\x01", limits);
    guard let framed = framed_result else let e = err_of(framed_result) { return e; }
    grpc_proto_expect(framed == b"\x00\x00\x00\x00\x03\x08\x96\x01",
                      "message envelope mismatch");
    let parsed_result = grpc_parse_message(framed, limits);
    guard let parsed = parsed_result else let e = err_of(parsed_result) { return e; }
    grpc_proto_expect(grpc_message_size(parsed) == 3, "envelope size");
    grpc_proto_expect(grpc_message_bytes(parsed) == b"\x08\x96\x01", "envelope view");
    let compressed = grpc_parse_message(b"\x01\x00\x00\x00\x00", limits);
    if let _c = compressed { return "accepted compressed message"; }
    let mismatch = grpc_parse_message(b"\x00\x00\x00\x00\x02\x08", limits);
    if let _m = mismatch { return "accepted mismatched envelope length"; }
    let trailing = grpc_parse_message(b"\x00\x00\x00\x00\x01\x08\x00", limits);
    if let _t = trailing { return "accepted trailing envelope bytes"; }
    return "";
}

fn grpc_proto_test_all() -> str {
    let a = grpc_proto_test_varints();
    if a != "" { return a; }
    let b = grpc_proto_test_tags_and_skip();
    if b != "" { return b; }
    let c = grpc_proto_test_rejects_bad_varints();
    if c != "" { return c; }
    let d = grpc_proto_test_bounds_and_submessages();
    if d != "" { return d; }
    let e = grpc_proto_test_message_envelope();
    if e != "" { return e; }
    return "";
}

fn test_grpc_proto_varints() {
    let e = grpc_proto_test_varints();
    if e != "" { panic(e); }
}

fn test_grpc_proto_tags_and_skip() {
    let e = grpc_proto_test_tags_and_skip();
    if e != "" { panic(e); }
}

fn test_grpc_proto_rejects_bad_varints() {
    let e = grpc_proto_test_rejects_bad_varints();
    if e != "" { panic(e); }
}

fn test_grpc_proto_bounds_and_submessages() {
    let e = grpc_proto_test_bounds_and_submessages();
    if e != "" { panic(e); }
}

fn test_grpc_message_envelope() {
    let e = grpc_proto_test_message_envelope();
    if e != "" { panic(e); }
}

fn grpc_proto_test_float_codecs() -> str {
    let limits = proto_default_limits();
    let made = proto_writer(limits);
    guard let writer = made else let e = err_of(made) { return e; }
    let a = proto_writer_float(writer, 1.0);
    guard let _a = a else let e = err_of(a) { return e; }
    let b = proto_writer_float(writer, -2.5);
    guard let _b = b else let e = err_of(b) { return e; }
    let c = proto_writer_double(writer, 1.5);
    guard let _c = c else let e = err_of(c) { return e; }
    let raw = proto_writer_finish(writer);
    grpc_proto_expect(raw == b"\x00\x00\x80\x3f\x00\x00\x20\xc0\x00\x00\x00\x00\x00\x00\xf8\x3f",
                      "float/double encodings differ from IEEE-754 vectors");
    let reader_result = proto_reader(raw, limits);
    guard let reader = reader_result else let e = err_of(reader_result) { return e; }
    let f1_result = proto_reader_float(reader);
    guard let f1 = f1_result else let e = err_of(f1_result) { return e; }
    grpc_proto_expect(f1 == 1.0, "float 1.0 decode");
    let f2_result = proto_reader_float(reader);
    guard let f2 = f2_result else let e = err_of(f2_result) { return e; }
    grpc_proto_expect(f2 == -2.5, "float -2.5 decode");
    let d_result = proto_reader_double(reader);
    guard let d = d_result else let e = err_of(d_result) { return e; }
    grpc_proto_expect(d == 1.5 && proto_reader_done(reader), "double decode");
    return "";
}

fn grpc_proto_test_utf8_and_limits() -> str {
    let bad_utf8_result = proto_reader(b"\x0a\x01\xff", proto_default_limits());
    guard let bad_utf8 = bad_utf8_result else let e = err_of(bad_utf8_result) { return e; }
    let bad_tag = proto_reader_tag(bad_utf8);
    guard let _bad_tag = bad_tag else let e = err_of(bad_tag) { return e; }
    let invalid = proto_reader_string(bad_utf8);
    if let _text = invalid { return "accepted invalid UTF-8"; }

    let nul_result = proto_reader(b"\x0a\x01\x00", proto_default_limits());
    guard let nul_reader = nul_result else let e = err_of(nul_result) { return e; }
    let nul_tag = proto_reader_tag(nul_reader);
    guard let _nul_tag = nul_tag else let e = err_of(nul_tag) { return e; }
    let nul = proto_reader_string(nul_reader);
    if let _text = nul { return "accepted embedded NUL in slang str"; }

    let depth_limits_result = proto_new_limits(32, 1, 16);
    guard let depth_limits = depth_limits_result else let e = err_of(depth_limits_result) { return e; }
    let depth_result = proto_reader(b"\x0a\x02\x0a\x00", depth_limits);
    guard let parent = depth_result else let e = err_of(depth_result) { return e; }
    let pt = proto_reader_tag(parent);
    guard let _pt = pt else let e = err_of(pt) { return e; }
    let child_result = proto_reader_submessage(parent);
    guard let child = child_result else let e = err_of(child_result) { return e; }
    let ct = proto_reader_tag(child);
    guard let _ct = ct else let e = err_of(ct) { return e; }
    let too_deep = proto_reader_submessage(child);
    if let _deep = too_deep { return "accepted excessive nesting"; }

    let value_limits_result = proto_new_limits(32, 4, 1);
    guard let value_limits = value_limits_result else let e = err_of(value_limits_result) { return e; }
    let fields_result = proto_reader(b"\x08\x01\x10\x01", value_limits);
    guard let fields = fields_result else let e = err_of(fields_result) { return e; }
    let first = proto_reader_tag(fields);
    guard let _first = first else let e = err_of(first) { return e; }
    let value = proto_reader_varint(fields);
    guard let _value = value else let e = err_of(value) { return e; }
    let second = proto_reader_tag(fields);
    if let _second = second { return "accepted values beyond configured aggregate limit"; }
    return "";
}

fn test_grpc_proto_float_codecs() {
    let e = grpc_proto_test_float_codecs();
    if e != "" { panic(e); }
}

fn test_grpc_proto_utf8_and_limits() {
    let e = grpc_proto_test_utf8_and_limits();
    if e != "" { panic(e); }
}

fn grpc_proto_test_signed_varints() -> str {
    let values = [-2147483648, -1, 0, 1, 2147483647];
    let i = 0;
    while i < len(values) {
        let zig32 = proto_sint32_to_wire(values[i]);
        grpc_proto_expect(proto_sint32_from_wire(zig32) == values[i], "sint32 round trip");
        let int32 = proto_int32_to_wire(values[i]);
        grpc_proto_expect(proto_int32_from_wire(int32) == values[i], "int32 round trip");
        i = i + 1;
    }
    let wide = [-9223372036854775807 - 1, -1, 0, 1, 9223372036854775807];
    let j = 0;
    while j < len(wide) {
        let encoded = proto_sint64_to_wire(wide[j]);
        grpc_proto_expect(proto_sint64_from_wire(encoded) == wide[j], "sint64 round trip");
        j = j + 1;
    }
    return "";
}

fn test_grpc_proto_signed_varints() {
    let e = grpc_proto_test_signed_varints();
    if e != "" { panic(e); }
}
