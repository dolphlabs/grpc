import "builder";
import "encoding";
import "strings";

// Protobuf wire types supported by proto3. Groups are deliberately rejected.
pub let PROTO_VARINT = 0;
pub let PROTO_FIXED64 = 1;
pub let PROTO_BYTES = 2;
pub let PROTO_FIXED32 = 5;
pub let PROTO_MAX_FIELD = 536870911;
pub let PROTO_DEFAULT_MAX_BYTES = 4194304;
pub let PROTO_HARD_MAX_BYTES = 67108864;
pub let PROTO_DEFAULT_MAX_DEPTH = 32;
pub let PROTO_HARD_MAX_DEPTH = 64;
pub let PROTO_DEFAULT_MAX_VALUES = 100000;
pub let PROTO_HARD_MAX_VALUES = 1000000;

pub gc struct Limits {
    max_message_bytes: int,
    max_depth: int,
    max_values: int
}

pub struct Tag {
    field_number: int,
    wire_type: int
}

gc struct Budget {
    values: int,
    max_values: int
}

// Reader ranges share one input byte string and one aggregate value budget.
// A nested message therefore adds a small reader object, not a copy of its
// full payload, and cannot evade limits by nesting sub-readers.
pub gc struct Reader {
    data: bytes,
    pos: int,
    end: int,
    depth: int,
    limits: Limits,
    budget: Budget
}

pub gc struct Writer {
    out: builder.Bytes,
    limits: Limits
}

pub fn proto_default_limits() -> Limits {
    return Limits {
        max_message_bytes: PROTO_DEFAULT_MAX_BYTES,
        max_depth: PROTO_DEFAULT_MAX_DEPTH,
        max_values: PROTO_DEFAULT_MAX_VALUES
    };
}

pub fn proto_new_limits(max_message_bytes: int, max_depth: int,
                        max_values: int) -> result[Limits, str] {
    if max_message_bytes < 1 || max_message_bytes > PROTO_HARD_MAX_BYTES {
        return err("grpc.proto limits: message bytes must be 1..67108864");
    }
    if max_depth < 1 || max_depth > PROTO_HARD_MAX_DEPTH {
        return err("grpc.proto limits: depth must be 1..64");
    }
    if max_values < 1 || max_values > PROTO_HARD_MAX_VALUES {
        return err("grpc.proto limits: values must be 1..1000000");
    }
    return ok(Limits {
        max_message_bytes: max_message_bytes,
        max_depth: max_depth,
        max_values: max_values
    });
}

pub fn proto_reader(raw: bytes, limits: Limits) -> result[Reader, str] {
    if !proto_limits_valid(limits) {
        return err("grpc.proto reader: invalid limits");
    }
    if len(raw) > limits.max_message_bytes {
        return err("grpc.proto reader: message exceeds configured byte limit");
    }
    let budget = Budget { values: 0, max_values: limits.max_values };
    return ok(Reader {
        data: raw,
        pos: 0,
        end: len(raw),
        depth: 0,
        limits: limits,
        budget: budget
    });
}

fn proto_limits_valid(limits: Limits) -> bool {
    return limits.max_message_bytes >= 1 &&
           limits.max_message_bytes <= PROTO_HARD_MAX_BYTES &&
           limits.max_depth >= 1 && limits.max_depth <= PROTO_HARD_MAX_DEPTH &&
           limits.max_values >= 1 && limits.max_values <= PROTO_HARD_MAX_VALUES;
}

pub fn proto_reader_done(r: Reader) -> bool {
    return r.pos == r.end;
}

pub fn proto_reader_remaining(r: Reader) -> int {
    return r.end - r.pos;
}

// Charge packed repeated values as well as top-level tags against one budget.
pub fn proto_reader_charge(r: Reader) -> result[bool, str] {
    if r.budget.values >= r.budget.max_values {
        return err("grpc.proto reader: value count exceeds configured limit");
    }
    r.budget.values = r.budget.values + 1;
    return ok(true);
}

pub fn proto_reader_tag(r: Reader) -> result[opt[Tag], str] {
    if r.pos == r.end {
        return ok(none);
    }
    let charged = proto_reader_charge(r);
    guard let _c = charged else let e = err_of(charged) { return err(e); }
    let value_result = proto_reader_varint(r);
    guard let value = value_result else let e = err_of(value_result) {
        return err("grpc.proto tag: " + e);
    }
    let number = value >> 3;
    if number == 0 || number > PROTO_MAX_FIELD as u64 {
        return err("grpc.proto tag: field number is outside 1..536870911");
    }
    let wire = (value & 7) as int;
    if wire != PROTO_VARINT && wire != PROTO_FIXED64 &&
       wire != PROTO_BYTES && wire != PROTO_FIXED32 {
        return err("grpc.proto tag: unsupported wire type");
    }
    return ok(some(Tag { field_number: number as int, wire_type: wire }));
}

// Read at most ten bytes. The tenth byte may carry only bit zero; accepting
// any other bits wraps uint64 and can alias malformed tags or lengths.
pub fn proto_reader_varint(r: Reader) -> result[u64, str] {
    let value: u64 = 0;
    let shift = 0;
    while shift <= 63 {
        if r.pos >= r.end {
            return err("truncated varint");
        }
        let b = r.data[r.pos];
        r.pos = r.pos + 1;
        if shift == 63 && b > 1 {
            return err("varint overflows uint64");
        }
        value = value | (((b & 127) as u64) << shift);
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

pub fn proto_reader_fixed32(r: Reader) -> result[u32, str] {
    if r.end - r.pos < 4 {
        return err("truncated fixed32");
    }
    let value = (r.data[r.pos] as u32) |
                ((r.data[r.pos + 1] as u32) << 8) |
                ((r.data[r.pos + 2] as u32) << 16) |
                ((r.data[r.pos + 3] as u32) << 24);
    r.pos = r.pos + 4;
    return ok(value);
}

pub fn proto_reader_fixed64(r: Reader) -> result[u64, str] {
    if r.end - r.pos < 8 {
        return err("truncated fixed64");
    }
    let value: u64 = 0;
    let i = 0;
    while i < 8 {
        value = value | ((r.data[r.pos + i] as u64) << (i * 8));
        i = i + 1;
    }
    r.pos = r.pos + 8;
    return ok(value);
}

fn proto_reader_length(r: Reader) -> result[int, str] {
    let length_result = proto_reader_varint(r);
    guard let length = length_result else let e = err_of(length_result) {
        return err("length: " + e);
    }
    if length > r.limits.max_message_bytes as u64 {
        return err("length exceeds configured message limit");
    }
    if length > (r.end - r.pos) as u64 {
        return err("length exceeds remaining message bytes");
    }
    return ok(length as int);
}

// Returns one owned field value. Use proto_reader_submessage for nested
// messages so their input bytes are shared until individual fields are read.
pub fn proto_reader_bytes(r: Reader) -> result[bytes, str] {
    let length_result = proto_reader_length(r);
    guard let length = length_result else let e = err_of(length_result) {
        return err("grpc.proto bytes: " + e);
    }
    let start = r.pos;
    r.pos = r.pos + length;
    return ok(r.data[start..r.pos]);
}

pub fn proto_reader_string(r: Reader) -> result[str, str] {
    let length_result = proto_reader_length(r);
    guard let length = length_result else let e = err_of(length_result) {
        return err("grpc.proto string: " + e);
    }
    let start = r.pos;
    let end = start + length;
    if !proto_utf8_valid(r.data, start, end) {
        return err("grpc.proto string: invalid UTF-8");
    }
    if proto_has_nul(r.data, start, end) {
        return err("grpc.proto string: embedded NUL cannot be represented by slang str");
    }
    r.pos = end;
    return ok(strings.from_bytes(r.data, start, end));
}

fn proto_has_nul(raw: bytes, start: int, end: int) -> bool {
    let i = start;
    while i < end {
        if raw[i] == 0 { return true; }
        i = i + 1;
    }
    return false;
}

// Protobuf strings must be valid UTF-8. Validate the original bytes before
// converting because slang str is NUL-terminated and strings.from_bytes is
// intentionally a raw byte copy, not a validating decoder.
fn proto_utf8_valid(raw: bytes, start: int, end: int) -> bool {
    let i = start;
    while i < end {
        let a = raw[i];
        if a <= 0x7f {
            i = i + 1;
            continue;
        }
        if a >= 0xc2 && a <= 0xdf {
            if i + 1 >= end || raw[i + 1] < 0x80 || raw[i + 1] > 0xbf {
                return false;
            }
            i = i + 2;
            continue;
        }
        if a == 0xe0 {
            if i + 2 >= end || raw[i + 1] < 0xa0 || raw[i + 1] > 0xbf ||
               raw[i + 2] < 0x80 || raw[i + 2] > 0xbf { return false; }
            i = i + 3;
            continue;
        }
        if (a >= 0xe1 && a <= 0xec) || (a >= 0xee && a <= 0xef) {
            if i + 2 >= end || raw[i + 1] < 0x80 || raw[i + 1] > 0xbf ||
               raw[i + 2] < 0x80 || raw[i + 2] > 0xbf { return false; }
            i = i + 3;
            continue;
        }
        if a == 0xed {
            if i + 2 >= end || raw[i + 1] < 0x80 || raw[i + 1] > 0x9f ||
               raw[i + 2] < 0x80 || raw[i + 2] > 0xbf { return false; }
            i = i + 3;
            continue;
        }
        if a == 0xf0 {
            if i + 3 >= end || raw[i + 1] < 0x90 || raw[i + 1] > 0xbf ||
               raw[i + 2] < 0x80 || raw[i + 2] > 0xbf ||
               raw[i + 3] < 0x80 || raw[i + 3] > 0xbf { return false; }
            i = i + 4;
            continue;
        }
        if a >= 0xf1 && a <= 0xf3 {
            if i + 3 >= end || raw[i + 1] < 0x80 || raw[i + 1] > 0xbf ||
               raw[i + 2] < 0x80 || raw[i + 2] > 0xbf ||
               raw[i + 3] < 0x80 || raw[i + 3] > 0xbf { return false; }
            i = i + 4;
            continue;
        }
        if a == 0xf4 {
            if i + 3 >= end || raw[i + 1] < 0x80 || raw[i + 1] > 0x8f ||
               raw[i + 2] < 0x80 || raw[i + 2] > 0xbf ||
               raw[i + 3] < 0x80 || raw[i + 3] > 0xbf { return false; }
            i = i + 4;
            continue;
        }
        return false;
    }
    return true;
}

pub fn proto_reader_submessage(r: Reader) -> result[Reader, str] {
    if r.depth >= r.limits.max_depth {
        return err("grpc.proto submessage: nesting exceeds configured limit");
    }
    let length_result = proto_reader_length(r);
    guard let length = length_result else let e = err_of(length_result) {
        return err("grpc.proto submessage: " + e);
    }
    let start = r.pos;
    r.pos = r.pos + length;
    return ok(Reader {
        data: r.data,
        pos: start,
        end: start + length,
        depth: r.depth + 1,
        limits: r.limits,
        budget: r.budget
    });
}

// Skip one unknown field's value after its tag has been read. Lengths are
// checked against both the shared message budget and the current submessage.
pub fn proto_reader_skip(r: Reader, wire_type: int) -> result[bool, str] {
    if wire_type == PROTO_VARINT {
        let value_result = proto_reader_varint(r);
        guard let _value = value_result else let e = err_of(value_result) {
            return err("grpc.proto skip: " + e);
        }
        return ok(true);
    }
    if wire_type == PROTO_FIXED64 {
        if r.end - r.pos < 8 { return err("grpc.proto skip: truncated fixed64"); }
        r.pos = r.pos + 8;
        return ok(true);
    }
    if wire_type == PROTO_BYTES {
        let length_result = proto_reader_length(r);
        guard let length = length_result else let e = err_of(length_result) {
            return err("grpc.proto skip: " + e);
        }
        r.pos = r.pos + length;
        return ok(true);
    }
    if wire_type == PROTO_FIXED32 {
        if r.end - r.pos < 4 { return err("grpc.proto skip: truncated fixed32"); }
        r.pos = r.pos + 4;
        return ok(true);
    }
    return err("grpc.proto skip: unsupported wire type");
}


// IEEE-754 codecs use slang's generic binary64 byte helpers. Protobuf float
// (binary32) is converted explicitly with round-to-nearest, ties-to-even so
// host endianness and the C compiler's numeric casts never affect the wire.
pub fn proto_reader_double(r: Reader) -> result[float, str] {
    let bits_result = proto_reader_fixed64(r);
    guard let bits = bits_result else let e = err_of(bits_result) { return err(e); }
    let decoded = encoding.float64_from_le(proto_u64_le(bits));
    guard let value = decoded else let e = err_of(decoded) {
        return err("grpc.proto double: " + e);
    }
    return ok(value);
}

pub fn proto_writer_double(w: Writer, value: float) -> result[bool, str] {
    let raw = encoding.float64_to_le(value);
    let bits: u64 = 0;
    let i = 0;
    while i < 8 {
        bits = bits | ((raw[i] as u64) << (i * 8));
        i = i + 1;
    }
    return proto_writer_fixed64(w, bits);
}

pub fn proto_reader_float(r: Reader) -> result[float, str] {
    let bits_result = proto_reader_fixed32(r);
    guard let bits = bits_result else let e = err_of(bits_result) { return err(e); }
    let sign = ((bits >> 31) as u64) << 63;
    let exponent = ((bits >> 23) & 255) as int;
    let fraction = bits & 0x7fffff;
    let bits64: u64 = 0;
    if exponent == 255 {
        bits64 = sign | (2047 as u64 << 52) | ((fraction as u64) << 29);
    } else {
        if exponent == 0 {
            if fraction == 0 {
                bits64 = sign;
            } else {
                let high = 22;
                while high >= 0 && ((fraction >> high) & 1) == 0 {
                    high = high - 1;
                }
                let unbiased = high - 149;
                let exp64 = (unbiased + 1023) as u64;
                let rest = (fraction - (1 as u32 << high)) as u64;
                bits64 = sign | (exp64 << 52) | (rest << (52 - high));
            }
        } else {
            let exp64 = (exponent - 127 + 1023) as u64;
            bits64 = sign | (exp64 << 52) | ((fraction as u64) << 29);
        }
    }
    let decoded = encoding.float64_from_le(proto_u64_le(bits64));
    guard let value = decoded else let e = err_of(decoded) {
        return err("grpc.proto float: " + e);
    }
    return ok(value);
}

pub fn proto_writer_float(w: Writer, value: float) -> result[bool, str] {
    let raw = encoding.float64_to_le(value);
    let bits: u64 = 0;
    let i = 0;
    while i < 8 {
        bits = bits | ((raw[i] as u64) << (i * 8));
        i = i + 1;
    }
    let sign = ((bits >> 63) as u32) << 31;
    let exp64 = ((bits >> 52) & 2047) as int;
    let fraction64 = bits & 4503599627370495 as u64;
    let out_bits: u32 = sign;
    if exp64 == 2047 {
        let fraction32: u32 = 0;
        if fraction64 != 0 { fraction32 = 0x400000; }
        out_bits = sign | (255 as u32 << 23) | fraction32;
    } else {
        if exp64 != 0 {
            let exponent = exp64 - 1023;
            let mantissa = (1 as u64 << 52) | fraction64;
            if exponent > 127 {
                out_bits = sign | (255 as u32 << 23);
            } else {
                if exponent >= -126 {
                    let rounded = proto_round_shift(mantissa, 29);
                    let exp32 = exponent + 127;
                    if rounded == (1 as u64 << 24) {
                        if exp32 >= 254 {
                            out_bits = sign | (255 as u32 << 23);
                        } else {
                            out_bits = sign | ((exp32 + 1) as u32 << 23);
                        }
                    } else {
                        out_bits = sign | ((exp32 as u32) << 23) |
                                 ((rounded as u32) & (0x7fffff as u32));
                    }
                } else {
                    if exponent >= -150 {
                        let shift = -exponent - 97;
                        let rounded = proto_round_shift(mantissa, shift);
                        if rounded >= (1 as u64 << 23) {
                            out_bits = sign | (1 as u32 << 23);
                        } else {
                            out_bits = sign | rounded as u32;
                        }
                    }
                }
            }
        }
    }
    return proto_writer_fixed32(w, out_bits);
}

fn proto_round_shift(value: u64, shift: int) -> u64 {
    let quotient = value >> shift;
    let mask = (1 as u64 << shift) - 1;
    let remainder = value & mask;
    let half = 1 as u64 << (shift - 1);
    if remainder > half || (remainder == half && (quotient & 1) != 0) {
        return quotient + 1;
    }
    return quotient;
}

fn proto_u64_le(value: u64) -> bytes {
    let raw = b"\x00\x00\x00\x00\x00\x00\x00\x00";
    let i = 0;
    while i < 8 {
        raw[i] = ((value >> (i * 8)) & 255) as int;
        i = i + 1;
    }
    return raw;
}

pub fn proto_writer(limits: Limits) -> result[Writer, str] {
    if !proto_limits_valid(limits) {
        return err("grpc.proto writer: invalid limits");
    }
    return ok(Writer { out: builder.new_bytes(), limits: limits });
}

pub fn proto_writer_size(w: Writer) -> int {
    return w.out.size();
}

pub fn proto_writer_varint(w: Writer, value: u64) -> result[bool, str] {
    let n = proto_varint_size(value);
    if w.out.size() > w.limits.max_message_bytes - n {
        return err("grpc.proto writer: message exceeds configured byte limit");
    }
    let rest = value;
    while rest > 127 {
        w.out.write_byte(((rest & 127) as int) | 128);
        rest = rest >> 7;
    }
    w.out.write_byte(rest as int);
    return ok(true);
}

fn proto_varint_size(value: u64) -> int {
    let n = 1;
    let rest = value;
    while rest > 127 {
        rest = rest >> 7;
        n = n + 1;
    }
    return n;
}

pub fn proto_writer_tag(w: Writer, field_number: int,
                        wire_type: int) -> result[bool, str] {
    if field_number < 1 || field_number > PROTO_MAX_FIELD {
        return err("grpc.proto writer tag: field number is outside 1..536870911");
    }
    if wire_type != PROTO_VARINT && wire_type != PROTO_FIXED64 &&
       wire_type != PROTO_BYTES && wire_type != PROTO_FIXED32 {
        return err("grpc.proto writer tag: unsupported wire type");
    }
    let tag = ((field_number as u64) << 3) | wire_type as u64;
    return proto_writer_varint(w, tag);
}

pub fn proto_writer_bytes(w: Writer, value: bytes) -> result[bool, str] {
    let size = len(value);
    let length_size = proto_varint_size(size as u64);
    if size > w.limits.max_message_bytes ||
       w.out.size() > w.limits.max_message_bytes - size - length_size {
        return err("grpc.proto writer: message exceeds configured byte limit");
    }
    let encoded_length = proto_writer_varint(w, size as u64);
    guard let _length = encoded_length else let e = err_of(encoded_length) {
        return err(e);
    }
    w.out.write(value);
    return ok(true);
}

pub fn proto_writer_fixed32(w: Writer, value: u32) -> result[bool, str] {
    if w.out.size() > w.limits.max_message_bytes - 4 {
        return err("grpc.proto writer: message exceeds configured byte limit");
    }
    let i = 0;
    while i < 4 {
        w.out.write_byte(((value >> (8 * i)) & 255) as int);
        i = i + 1;
    }
    return ok(true);
}

pub fn proto_writer_fixed64(w: Writer, value: u64) -> result[bool, str] {
    if w.out.size() > w.limits.max_message_bytes - 8 {
        return err("grpc.proto writer: message exceeds configured byte limit");
    }
    let i = 0;
    while i < 8 {
        w.out.write_byte(((value >> (8 * i)) & 255) as int);
        i = i + 1;
    }
    return ok(true);
}

pub fn proto_writer_finish(w: Writer) -> bytes {
    return w.out.finish();
}

// Packed fields are length-delimited subranges but do not consume a protobuf
// nesting level. They share the same aggregate value budget as their parent.
pub fn proto_reader_packed(r: Reader) -> result[Reader, str] {
    let length_result = proto_reader_length(r);
    guard let length = length_result else let e = err_of(length_result) {
        return err("grpc.proto packed field: " + e);
    }
    let start = r.pos;
    r.pos = r.pos + length;
    return ok(Reader {
        data: r.data,
        pos: start,
        end: start + length,
        depth: r.depth,
        limits: r.limits,
        budget: r.budget
    });
}

pub fn proto_int32_from_wire(value: u64) -> int {
    return ((value as u32) as i32) as int;
}

pub fn proto_int32_wire_valid(value: u64) -> bool {
    return value <= 4294967295 || value >= 18446744071562067968;
}

pub fn proto_int32_to_wire(value: int) -> u64 {
    return ((value as i32) as int) as u64;
}

pub fn proto_sint32_from_wire(value: u64) -> int {
    let decoded = (value >> 1) ^ (0 as u64 - (value & 1));
    return ((decoded as u32) as i32) as int;
}

pub fn proto_sint32_to_wire(value: int) -> u64 {
    let bits = (value as i32) as u32;
    let sign: u32 = 0;
    if (bits & 0x80000000) != 0 { sign = 0xffffffff; }
    return ((bits << 1) ^ sign) as u64;
}

pub fn proto_sint64_from_wire(value: u64) -> int {
    return ((value >> 1) ^ (0 as u64 - (value & 1))) as int;
}

pub fn proto_sint64_to_wire(value: int) -> u64 {
    let bits = value as u64;
    return (bits << 1) ^ (0 as u64 - (bits >> 63));
}

pub fn proto_writer_string(w: Writer, value: str) -> result[bool, str] {
    let size = len(value);
    let length_size = proto_varint_size(size as u64);
    if size > w.limits.max_message_bytes ||
       w.out.size() > w.limits.max_message_bytes - size - length_size {
        return err("grpc.proto writer: message exceeds configured byte limit");
    }
    let encoded_length = proto_writer_varint(w, size as u64);
    guard let _length = encoded_length else let e = err_of(encoded_length) {
        return err(e);
    }
    w.out.write_str(value);
    return ok(true);
}
