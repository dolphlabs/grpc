import "builder";
import "strings";

fn max_descriptor_fields() -> int {
    return 100000;
}

gc struct WireField {
    number: int,
    wire: int,
    value: u64,
    raw: bytes
}

gc struct WireCursor {
    pos: int
}

fn slice_bytes(src: bytes, start: int, end: int) -> bytes {
    let n = end - start;
    if n <= 0 { return b""; }
    let out = strings.bytes_zero(n);
    let _copied = strings.copy_into(out, 0, src, start, end);
    return out;
}

fn read_varint(raw: bytes, cur: WireCursor) -> result[u64, str] {
    let value: u64 = 0 as u64;
    let shift = 0;
    while shift <= 63 {
        if cur.pos >= len(raw) {
            return err("truncated varint");
        }
        let b = raw[cur.pos];
        cur.pos = cur.pos + 1;
        if shift == 63 && b > 1 {
            return err("varint overflows uint64");
        }
        value = value | (((b & 127) as u64) << (shift as u64));
        if b < 128 {
            if shift > 0 && b == 0 {
                return err("non-canonical varint");
            }
            return ok(value);
        }
        shift = shift + 7;
    }
    return err("varint exceeds ten bytes");
}

fn parse_wire(raw: bytes) -> result[[WireField], str] {
    let out: [WireField] = [];
    let cur = WireCursor { pos: 0 };
    let cap = max_descriptor_fields();
    while cur.pos < len(raw) {
        let tag_res = read_varint(raw, cur);
        guard let tag = tag_res else let e = err_of(tag_res) { return err(e); }
        let number = (tag >> (3 as u64)) as int;
        let wire = (tag & (7 as u64)) as int;
        if number < 1 || number > 536870911 {
            return err("invalid field number " + to_str(number));
        }
        let f = WireField { number: number, wire: wire, value: 0 as u64, raw: b"" };
        if wire == 0 {
            let vr = read_varint(raw, cur);
            guard let v = vr else let e = err_of(vr) {
                return err("field " + to_str(number) + ": " + e);
            }
            f.value = v;
        } else if wire == 1 {
            if len(raw) - cur.pos < 8 {
                return err("field " + to_str(number) + ": truncated fixed64");
            }
            f.raw = slice_bytes(raw, cur.pos, cur.pos + 8);
            cur.pos = cur.pos + 8;
        } else if wire == 2 {
            let nr = read_varint(raw, cur);
            guard let n_u = nr else let e = err_of(nr) {
                return err("field " + to_str(number) + ": " + e);
            }
            let rem = (len(raw) - cur.pos) as u64;
            if n_u > rem {
                return err("field " + to_str(number) + ": length exceeds remaining bytes");
            }
            let n = n_u as int;
            f.raw = slice_bytes(raw, cur.pos, cur.pos + n);
            cur.pos = cur.pos + n;
        } else if wire == 5 {
            if len(raw) - cur.pos < 4 {
                return err("field " + to_str(number) + ": truncated fixed32");
            }
            f.raw = slice_bytes(raw, cur.pos, cur.pos + 4);
            cur.pos = cur.pos + 4;
        } else {
            return err("field " + to_str(number) + ": unsupported protobuf wire type " + to_str(wire));
        }
        if len(out) >= cap {
            return err("descriptor exceeds " + to_str(cap) + " fields");
        }
        push(out, f);
    }
    return ok(out);
}

fn append_varint(out: builder.Bytes, value: u64) {
    let v = value;
    while v > (127 as u64) {
        out.write_byte(((v & (127 as u64)) as int) | 128);
        v = v >> (7 as u64);
    }
    out.write_byte(v as int);
}

fn append_bytes_field(out: builder.Bytes, number: int, value: bytes) {
    append_varint(out, ((number as u64) << (3 as u64)) | (2 as u64));
    append_varint(out, len(value) as u64);
    out.write(value);
}

fn append_string_field(out: builder.Bytes, number: int, value: str) {
    append_bytes_field(out, number, to_bytes(value));
}

fn append_varint_field(out: builder.Bytes, number: int, value: u64) {
    append_varint(out, (number as u64) << (3 as u64));
    append_varint(out, value);
}
