fn grpc_proto_expect(ok: bool, message: str) {
    if !ok { panic("grpc proto test: " + message); }
}

// The code a failed read reported, or 0 when it succeeded.
fn grpc_proto_code_of[T](r: result[T, int]) -> int {
    if let _v = r {
        return 0;
    } else let code = err_of(r) {
        return code;
    }
    return -1;
}

fn grpc_proto_test_varints() -> str {
    let limits = proto_default_limits();
    let writer = proto_writer();
    proto_write_varint(writer, 0);
    proto_write_varint(writer, 127);
    proto_write_varint(writer, 128);
    proto_write_varint(writer, 300);
    proto_write_varint(writer, 18446744073709551615 as u64);
    grpc_proto_expect(proto_writer_size(writer) == 16, "varint writer size");
    let encoded = proto_writer_finish(writer);
    grpc_proto_expect(encoded == b"\x00\x7f\x80\x01\xac\x02\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01",
                      "varint writer bytes differ from protobuf vectors");
    grpc_proto_expect(proto_size_varint(0) == 1 && proto_size_varint(127) == 1 &&
                      proto_size_varint(128) == 2 && proto_size_varint(300) == 2 &&
                      proto_size_varint(18446744073709551615 as u64) == 10,
                      "varint sizes");

    let reader_result = proto_reader(encoded, limits);
    guard let reader = reader_result else let error = err_of(reader_result) {
        return error;
    }
    let values: [u64] = [0 as u64, 127 as u64, 128 as u64, 300 as u64, 18446744073709551615 as u64];
    let i = 0;
    while i < len(values) {
        let got = proto_reader_varint(reader);
        guard let value = got else let code = err_of(got) { return proto_error_text(code); }
        grpc_proto_expect(value == values[i], "varint decoder value mismatch");
        i = i + 1;
    }
    grpc_proto_expect(proto_reader_done(reader), "varint reader left bytes");
    return "";
}

fn grpc_proto_test_keys_and_skip() -> str {
    let raw = b"\x08\x96\x01\x11\x01\x02\x03\x04\x05\x06\x07\x08\x1a\x03abc\x25\x09\x0a\x0b\x0c";
    let made = proto_reader(raw, proto_default_limits());
    guard let reader = made else let e = err_of(made) { return e; }
    let first_result = proto_reader_key(reader);
    guard let first = first_result else let code = err_of(first_result) { return proto_error_text(code); }
    grpc_proto_expect(first >> 3 == 1 && (first & 7) == PROTO_VARINT, "wrong varint key");
    let number = proto_reader_varint(reader);
    guard let n = number else let code = err_of(number) { return proto_error_text(code); }
    grpc_proto_expect(n == 150, "key value mismatch");

    let expected_fields = [2, 3, 4];
    let expected_wires = [PROTO_FIXED64, PROTO_BYTES, PROTO_FIXED32];
    let i = 0;
    while i < 3 {
        let next = proto_reader_key(reader);
        guard let key = next else let code = err_of(next) { return proto_error_text(code); }
        grpc_proto_expect(key >> 3 == expected_fields[i] &&
                          (key & 7) == expected_wires[i], "unknown key mismatch");
        let skipped = proto_reader_skip(reader, key & 7);
        guard let _ok = skipped else let code = err_of(skipped) { return proto_error_text(code); }
        i = i + 1;
    }
    grpc_proto_expect(proto_reader_done(reader), "unknown fields left bytes");
    let end = proto_reader_key(reader);
    grpc_proto_expect((end ?? -1) == 0, "key at end of message is not 0");
    return "";
}

fn grpc_proto_test_rejects_bad_varints() -> str {
    let bad: [bytes] = [b"\x80", b"\x80\x80\x80\x80\x80\x80\x80\x80\x80\x02",
                        b"\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x00", b"\x80\x00"];
    // An eleven-byte varint fails at its tenth byte, whose continuation bit
    // is already more than uint64 can hold.
    let codes = [PROTO_ERR_TRUNCATED, PROTO_ERR_VARINT_OVERFLOW,
                 PROTO_ERR_VARINT_OVERFLOW, PROTO_ERR_VARINT_NONCANONICAL];
    let i = 0;
    while i < len(bad) {
        let made = proto_reader(bad[i], proto_default_limits());
        guard let reader = made else let e = err_of(made) { return e; }
        let got = grpc_proto_code_of(proto_reader_varint(reader));
        if got != codes[i] {
            return "malformed varint " + to_str(i) + ": want code " + to_str(codes[i]) +
                   ", got " + to_str(got);
        }
        i = i + 1;
    }
    let zero_field = proto_reader(b"\x00", proto_default_limits());
    guard let zr = zero_field else let e = err_of(zero_field) { return e; }
    grpc_proto_expect(grpc_proto_code_of(proto_reader_key(zr)) == PROTO_ERR_FIELD_NUMBER,
                      "field number zero accepted");
    let group = proto_reader(b"\x0b", proto_default_limits());
    guard let gr = group else let e = err_of(group) { return e; }
    grpc_proto_expect(grpc_proto_code_of(proto_reader_key(gr)) == PROTO_ERR_WIRE_TYPE,
                      "group wire type accepted");
    return "";
}

fn grpc_proto_test_bounds_and_submessages() -> str {
    let limits_result = proto_new_limits(32, 1, 3);
    guard let limits = limits_result else let e = err_of(limits_result) { return e; }
    let raw = b"\x0a\x02\x08\x01\x10\x05";
    let made = proto_reader(raw, limits);
    guard let reader = made else let e = err_of(made) { return e; }
    let key_result = proto_reader_key(reader);
    guard let key = key_result else let code = err_of(key_result) { return proto_error_text(code); }
    grpc_proto_expect((key & 7) == PROTO_BYTES, "outer wire type");
    let entered = proto_reader_enter(reader);
    guard let outer = entered else let code = err_of(entered) { return proto_error_text(code); }
    let child_key_result = proto_reader_key(reader);
    guard let child_key = child_key_result else let code = err_of(child_key_result) { return proto_error_text(code); }
    grpc_proto_expect(child_key >> 3 == 1, "child field number");
    let child_value = proto_reader_varint(reader);
    guard let value = child_value else let code = err_of(child_value) { return proto_error_text(code); }
    grpc_proto_expect(value == 1, "child field value");
    grpc_proto_expect((proto_reader_key(reader) ?? -1) == 0, "child range did not end");
    let left = proto_reader_leave(reader, outer);
    guard let _left = left else let code = err_of(left) { return proto_error_text(code); }
    let after = proto_reader_key(reader);
    guard let next = after else let code = err_of(after) { return proto_error_text(code); }
    grpc_proto_expect(next >> 3 == 2, "parent did not resume after the child");

    // Leaving a nested message before reading all of it is malformed input,
    // not a reason to resynchronise.
    let partial_result = proto_reader(b"\x0a\x02\x08\x01", proto_default_limits());
    guard let partial = partial_result else let e = err_of(partial_result) { return e; }
    let pk = proto_reader_key(partial);
    guard let _pk = pk else let code = err_of(pk) { return proto_error_text(code); }
    let pe = proto_reader_enter(partial);
    guard let partial_outer = pe else let code = err_of(pe) { return proto_error_text(code); }
    grpc_proto_expect(grpc_proto_code_of(proto_reader_leave(partial, partial_outer)) ==
                      PROTO_ERR_NOT_CONSUMED, "accepted a partly read submessage");

    // A length that runs past its enclosing message.
    let long_result = proto_reader(b"\x0a\x05\x08\x01", proto_default_limits());
    guard let long_reader = long_result else let e = err_of(long_result) { return e; }
    let lk = proto_reader_key(long_reader);
    guard let _lk = lk else let code = err_of(lk) { return proto_error_text(code); }
    grpc_proto_expect(grpc_proto_code_of(proto_reader_enter(long_reader)) ==
                      PROTO_ERR_LENGTH_REMAINING, "accepted an overlong length");
    return "";
}

fn grpc_proto_test_packed() -> str {
    let made = proto_reader(b"\x0a\x03\x01\x96\x01", proto_default_limits());
    guard let reader = made else let e = err_of(made) { return e; }
    let k = proto_reader_key(reader);
    guard let _k = k else let code = err_of(k) { return proto_error_text(code); }
    let entered = proto_reader_enter_packed(reader);
    guard let outer = entered else let code = err_of(entered) { return proto_error_text(code); }
    let got: [u64] = [];
    while !proto_reader_done(reader) {
        let v = proto_reader_varint(reader);
        guard let value = v else let code = err_of(v) { return proto_error_text(code); }
        push(got, value);
    }
    let left = proto_reader_leave_packed(reader, outer);
    guard let _left = left else let code = err_of(left) { return proto_error_text(code); }
    grpc_proto_expect(len(got) == 2 && got[0] == 1 && got[1] == 150, "packed values");
    grpc_proto_expect(proto_reader_done(reader) && reader.depth == 0, "packed range is not a level");
    return "";
}

fn grpc_proto_test_message_envelope() -> str {
    let limits = grpc_default_limits();
    let framed_result = grpc_frame_message(b"\x08\x96\x01", limits);
    guard let framed = framed_result else let e = err_of(framed_result) { return e; }
    grpc_proto_expect(framed == b"\x00\x00\x00\x00\x03\x08\x96\x01",
                      "message envelope mismatch");
    // A second frame must not see the first one's length: the prefix is a
    // fresh buffer on every call.
    let second_result = grpc_frame_message(b"\x08", limits);
    guard let second = second_result else let e = err_of(second_result) { return e; }
    grpc_proto_expect(second == b"\x00\x00\x00\x00\x01\x08", "second envelope mismatch");
    grpc_proto_expect(framed == b"\x00\x00\x00\x00\x03\x08\x96\x01", "first envelope changed");
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

fn test_grpc_proto_varints() {
    let e = grpc_proto_test_varints();
    if e != "" { panic(e); }
}

fn test_grpc_proto_keys_and_skip() {
    let e = grpc_proto_test_keys_and_skip();
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

fn test_grpc_proto_packed() {
    let e = grpc_proto_test_packed();
    if e != "" { panic(e); }
}

fn test_grpc_message_envelope() {
    let e = grpc_proto_test_message_envelope();
    if e != "" { panic(e); }
}

fn grpc_proto_test_float_codecs() -> str {
    let limits = proto_default_limits();
    let writer = proto_writer();
    proto_write_float(writer, 1.0);
    proto_write_float(writer, -2.5);
    proto_write_double(writer, 1.5);
    let raw = proto_writer_finish(writer);
    grpc_proto_expect(raw == b"\x00\x00\x80\x3f\x00\x00\x20\xc0\x00\x00\x00\x00\x00\x00\xf8\x3f",
                      "float/double encodings differ from IEEE-754 vectors");
    let reader_result = proto_reader(raw, limits);
    guard let reader = reader_result else let e = err_of(reader_result) { return e; }
    let f1_result = proto_reader_float(reader);
    guard let f1 = f1_result else let code = err_of(f1_result) { return proto_error_text(code); }
    grpc_proto_expect(f1 == 1.0, "float 1.0 decode");
    let f2_result = proto_reader_float(reader);
    guard let f2 = f2_result else let code = err_of(f2_result) { return proto_error_text(code); }
    grpc_proto_expect(f2 == -2.5, "float -2.5 decode");
    let d_result = proto_reader_double(reader);
    guard let d = d_result else let code = err_of(d_result) { return proto_error_text(code); }
    grpc_proto_expect(d == 1.5 && proto_reader_done(reader), "double decode");
    return "";
}

fn grpc_proto_test_utf8_and_limits() -> str {
    let bad_utf8_result = proto_reader(b"\x0a\x01\xff", proto_default_limits());
    guard let bad_utf8 = bad_utf8_result else let e = err_of(bad_utf8_result) { return e; }
    let bad_key = proto_reader_key(bad_utf8);
    guard let _bad_key = bad_key else let code = err_of(bad_key) { return proto_error_text(code); }
    grpc_proto_expect(grpc_proto_code_of(proto_reader_string_end(bad_utf8)) == PROTO_ERR_UTF8,
                      "accepted invalid UTF-8");

    let nul_result = proto_reader(b"\x0a\x03a\x00b", proto_default_limits());
    guard let nul_reader = nul_result else let e = err_of(nul_result) { return e; }
    let nul_key = proto_reader_key(nul_reader);
    guard let _nul_key = nul_key else let code = err_of(nul_key) { return proto_error_text(code); }
    grpc_proto_expect(grpc_proto_code_of(proto_reader_string_end(nul_reader)) == PROTO_ERR_NUL,
                      "accepted embedded NUL in slang str");

    let text_result = proto_reader(b"\x0a\x03\xc3\xa9x", proto_default_limits());
    guard let text_reader = text_result else let e = err_of(text_result) { return e; }
    let text_key = proto_reader_key(text_reader);
    guard let _text_key = text_key else let code = err_of(text_key) { return proto_error_text(code); }
    let text_end = proto_reader_string_end(text_reader);
    guard let end = text_end else let code = err_of(text_end) { return proto_error_text(code); }
    grpc_proto_expect(proto_reader_take_string(text_reader, end) == "éx", "UTF-8 string value");

    let depth_limits_result = proto_new_limits(32, 1, 16);
    guard let depth_limits = depth_limits_result else let e = err_of(depth_limits_result) { return e; }
    let depth_result = proto_reader(b"\x0a\x02\x0a\x00", depth_limits);
    guard let parent = depth_result else let e = err_of(depth_result) { return e; }
    let pt = proto_reader_key(parent);
    guard let _pt = pt else let code = err_of(pt) { return proto_error_text(code); }
    let first_level = proto_reader_enter(parent);
    guard let _outer = first_level else let code = err_of(first_level) { return proto_error_text(code); }
    let ct = proto_reader_key(parent);
    guard let _ct = ct else let code = err_of(ct) { return proto_error_text(code); }
    grpc_proto_expect(grpc_proto_code_of(proto_reader_enter(parent)) == PROTO_ERR_DEPTH,
                      "accepted excessive nesting");

    let value_limits_result = proto_new_limits(32, 4, 1);
    guard let value_limits = value_limits_result else let e = err_of(value_limits_result) { return e; }
    let fields_result = proto_reader(b"\x08\x01\x10\x01", value_limits);
    guard let fields = fields_result else let e = err_of(fields_result) { return e; }
    let first = proto_reader_key(fields);
    guard let _first = first else let code = err_of(first) { return proto_error_text(code); }
    let value = proto_reader_varint(fields);
    guard let _value = value else let code = err_of(value) { return proto_error_text(code); }
    grpc_proto_expect(grpc_proto_code_of(proto_reader_key(fields)) == PROTO_ERR_VALUES,
                      "accepted values beyond configured aggregate limit");
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
    grpc_proto_expect(proto_int32_in_range(2147483647) && !proto_int32_in_range(2147483648) &&
                      proto_int32_in_range(-2147483648) && !proto_int32_in_range(-2147483649),
                      "int32 range bounds");
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
