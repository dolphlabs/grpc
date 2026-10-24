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

// Reader failures are integer codes, not strings: a result whose payloads
// hold no GC pointer is a plain value, while a result[T, str] is a heap
// object on every successful call. Decoding a message makes one such call
// per field, so the text is built only on the failure path, with
// proto_error_text, by the caller that knows the field's name.
pub let PROTO_ERR_TRUNCATED = 1;
pub let PROTO_ERR_VARINT_OVERFLOW = 2;
pub let PROTO_ERR_VARINT_NONCANONICAL = 3;
pub let PROTO_ERR_VARINT_TOO_LONG = 4;
pub let PROTO_ERR_FIELD_NUMBER = 5;
pub let PROTO_ERR_WIRE_TYPE = 6;
pub let PROTO_ERR_LENGTH_LIMIT = 7;
pub let PROTO_ERR_LENGTH_REMAINING = 8;
pub let PROTO_ERR_UTF8 = 9;
pub let PROTO_ERR_NUL = 10;
pub let PROTO_ERR_DEPTH = 11;
pub let PROTO_ERR_VALUES = 12;
pub let PROTO_ERR_NOT_CONSUMED = 13;
pub let PROTO_ERR_FLOAT = 14;

pub gc struct Limits {
    max_message_bytes: int,
    max_depth: int,
    max_values: int
}

// One reader walks a whole message tree. A length-delimited value narrows
// `end` with proto_reader_enter and widens it again with proto_reader_leave,
// so a nested message, packed field or map entry costs no reader object and
// no copy, and the value budget is shared by construction.
pub gc struct Reader {
    data: bytes,
    pos: int,
    end: int,
    depth: int,
    limits: Limits,
    values: int
}

// Encoders size a message first (generated size_<Message> functions), check
// the total against the limit once, then write the whole tree into this one
// builder. Writes therefore cannot fail and return nothing.
pub gc struct Writer {
    out: builder.Bytes
}

pub fn proto_error_text(code: int) -> str {
    switch code {
      case 1 { return "truncated value"; }
      case 2 { return "varint overflows uint64"; }
      case 3 { return "non-canonical varint"; }
      case 4 { return "varint exceeds ten bytes"; }
      case 5 { return "field number is outside 1..536870911"; }
      case 6 { return "unsupported wire type"; }
      case 7 { return "length exceeds configured message limit"; }
      case 8 { return "length exceeds remaining message bytes"; }
      case 9 { return "invalid UTF-8"; }
      case 10 { return "embedded NUL cannot be represented by slang str"; }
      case 11 { return "nesting exceeds configured limit"; }
      case 12 { return "value count exceeds configured limit"; }
      case 13 { return "submessage was not fully consumed"; }
      case 14 { return "invalid floating-point value"; }
      default { return "unknown protobuf error " + to_str(code); }
    }
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
    return ok(Reader {
        data: raw,
        pos: 0,
        end: len(raw),
        depth: 0,
        limits: limits,
        values: 0
    });
}

pub fn proto_limits_valid(limits: Limits) -> bool {
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

// Charge packed repeated values as well as top-level keys against one budget.
pub fn proto_reader_charge(r: Reader) -> result[bool, int] {
    if r.values >= r.limits.max_values {
        return err(PROTO_ERR_VALUES);
    }
    r.values = r.values + 1;
    return ok(true);
}

// The next field's key, `field_number << 3 | wire_type`, or 0 at the end of
// the current message. Zero is never a valid key: field number zero is
// rejected, so it can mark the end without an opt.
pub fn proto_reader_key(r: Reader) -> result[int, int] {
    if r.pos == r.end {
        return ok(0);
    }
    if r.values >= r.limits.max_values {
        return err(PROTO_ERR_VALUES);
    }
    r.values = r.values + 1;
    let read = proto_reader_varint(r);
    guard let value = read else let code = err_of(read) {
        return err(code);
    }
    let number = value >> 3;
    if number == 0 || number > PROTO_MAX_FIELD as u64 {
        return err(PROTO_ERR_FIELD_NUMBER);
    }
    let wire = (value & 7) as int;
    if wire != PROTO_VARINT && wire != PROTO_FIXED64 &&
       wire != PROTO_BYTES && wire != PROTO_FIXED32 {
        return err(PROTO_ERR_WIRE_TYPE);
    }
    return ok(value as int);
}

// Read at most ten bytes. The tenth byte may carry only bit zero; accepting
// any other bits wraps uint64 and can alias malformed tags or lengths.
pub fn proto_reader_varint(r: Reader) -> result[u64, int] {
    if r.pos < r.end && r.data[r.pos] < 128 {
        let one = r.data[r.pos] as u64;
        r.pos = r.pos + 1;
        return ok(one);
    }
    let value: u64 = 0;
    let shift = 0;
    while shift <= 63 {
        if r.pos >= r.end {
            return err(PROTO_ERR_TRUNCATED);
        }
        let b = r.data[r.pos];
        r.pos = r.pos + 1;
        if shift == 63 && b > 1 {
            return err(PROTO_ERR_VARINT_OVERFLOW);
        }
        value = value | (((b & 127) as u64) << shift);
        if b < 128 {
            if shift > 0 && b == 0 {
                return err(PROTO_ERR_VARINT_NONCANONICAL);
            }
            return ok(value);
        }
        shift = shift + 7;
    }
    return err(PROTO_ERR_VARINT_TOO_LONG);
}

pub fn proto_reader_fixed32(r: Reader) -> result[u32, int] {
    if r.end - r.pos < 4 {
        return err(PROTO_ERR_TRUNCATED);
    }
    let value = (r.data[r.pos] as u32) |
                ((r.data[r.pos + 1] as u32) << 8) |
                ((r.data[r.pos + 2] as u32) << 16) |
                ((r.data[r.pos + 3] as u32) << 24);
    r.pos = r.pos + 4;
    return ok(value);
}

pub fn proto_reader_fixed64(r: Reader) -> result[u64, int] {
    if r.end - r.pos < 8 {
        return err(PROTO_ERR_TRUNCATED);
    }
    let p = r.pos;
    let value = (r.data[p] as u64) |
                ((r.data[p + 1] as u64) << 8) |
                ((r.data[p + 2] as u64) << 16) |
                ((r.data[p + 3] as u64) << 24) |
                ((r.data[p + 4] as u64) << 32) |
                ((r.data[p + 5] as u64) << 40) |
                ((r.data[p + 6] as u64) << 48) |
                ((r.data[p + 7] as u64) << 56);
    r.pos = p + 8;
    return ok(value);
}

// Reads a length prefix and returns where the value ends, leaving `pos` at
// its first byte.
pub fn proto_reader_open(r: Reader) -> result[int, int] {
    let read = proto_reader_varint(r);
    guard let length = read else let code = err_of(read) {
        return err(code);
    }
    if length > r.limits.max_message_bytes as u64 {
        return err(PROTO_ERR_LENGTH_LIMIT);
    }
    if length > (r.end - r.pos) as u64 {
        return err(PROTO_ERR_LENGTH_REMAINING);
    }
    return ok(r.pos + length as int);
}

// A bytes field: the copy from `pos` to `end` (from proto_reader_open).
pub fn proto_reader_take_bytes(r: Reader, end: int) -> bytes {
    let start = r.pos;
    r.pos = end;
    return r.data[start..end];
}

// A string field's end, after checking its bytes are UTF-8 a slang str can
// hold. Take it with proto_reader_take_string.
pub fn proto_reader_string_end(r: Reader) -> result[int, int] {
    let opened = proto_reader_open(r);
    guard let end = opened else let code = err_of(opened) {
        return err(code);
    }
    let bad = proto_text_error(r.data, r.pos, end);
    if bad != 0 {
        return err(bad);
    }
    return ok(end);
}

pub fn proto_reader_take_string(r: Reader, end: int) -> str {
    let start = r.pos;
    r.pos = end;
    return strings.from_bytes(r.data, start, end);
}

// Narrows the reader to a nested message or map entry and returns the outer
// end to give back to proto_reader_leave.
pub fn proto_reader_enter(r: Reader) -> result[int, int] {
    if r.depth >= r.limits.max_depth {
        return err(PROTO_ERR_DEPTH);
    }
    let opened = proto_reader_open(r);
    guard let end = opened else let code = err_of(opened) {
        return err(code);
    }
    let outer = r.end;
    r.end = end;
    r.depth = r.depth + 1;
    return ok(outer);
}

pub fn proto_reader_leave(r: Reader, outer: int) -> result[bool, int] {
    if r.pos != r.end {
        return err(PROTO_ERR_NOT_CONSUMED);
    }
    r.end = outer;
    r.depth = r.depth - 1;
    return ok(true);
}

// Packed fields are length-delimited ranges but not a nesting level. Their
// elements are charged against the same value budget as their parent.
pub fn proto_reader_enter_packed(r: Reader) -> result[int, int] {
    let opened = proto_reader_open(r);
    guard let end = opened else let code = err_of(opened) {
        return err(code);
    }
    let outer = r.end;
    r.end = end;
    return ok(outer);
}

pub fn proto_reader_leave_packed(r: Reader, outer: int) -> result[bool, int] {
    if r.pos != r.end {
        return err(PROTO_ERR_NOT_CONSUMED);
    }
    r.end = outer;
    return ok(true);
}

// Skip one unknown field's value after its key has been read. Lengths are
// checked against both the message limit and the current range.
pub fn proto_reader_skip(r: Reader, wire_type: int) -> result[bool, int] {
    if wire_type == PROTO_VARINT {
        let read = proto_reader_varint(r);
        guard let _value = read else let code = err_of(read) {
            return err(code);
        }
        return ok(true);
    }
    if wire_type == PROTO_FIXED64 {
        if r.end - r.pos < 8 { return err(PROTO_ERR_TRUNCATED); }
        r.pos = r.pos + 8;
        return ok(true);
    }
    if wire_type == PROTO_BYTES {
        let opened = proto_reader_open(r);
        guard let end = opened else let code = err_of(opened) {
            return err(code);
        }
        r.pos = end;
        return ok(true);
    }
    if wire_type == PROTO_FIXED32 {
        if r.end - r.pos < 4 { return err(PROTO_ERR_TRUNCATED); }
        r.pos = r.pos + 4;
        return ok(true);
    }
    return err(PROTO_ERR_WIRE_TYPE);
}

// 0 when raw[start..end] is UTF-8 without NUL, else PROTO_ERR_UTF8 or
// PROTO_ERR_NUL. One pass over the bytes: a slang str is NUL-terminated and
// strings.from_bytes is a raw copy, not a validating decoder.
fn proto_text_error(raw: bytes, start: int, end: int) -> int {
    let i = start;
    while i < end {
        let a = raw[i];
        if a == 0 {
            return PROTO_ERR_NUL;
        }
        if a <= 0x7f {
            i = i + 1;
            continue;
        }
        if a >= 0xc2 && a <= 0xdf {
            if i + 1 >= end || raw[i + 1] < 0x80 || raw[i + 1] > 0xbf {
                return PROTO_ERR_UTF8;
            }
            i = i + 2;
            continue;
        }
        if a == 0xe0 {
            if i + 2 >= end || raw[i + 1] < 0xa0 || raw[i + 1] > 0xbf ||
               raw[i + 2] < 0x80 || raw[i + 2] > 0xbf { return PROTO_ERR_UTF8; }
            i = i + 3;
            continue;
        }
        if (a >= 0xe1 && a <= 0xec) || (a >= 0xee && a <= 0xef) {
            if i + 2 >= end || raw[i + 1] < 0x80 || raw[i + 1] > 0xbf ||
               raw[i + 2] < 0x80 || raw[i + 2] > 0xbf { return PROTO_ERR_UTF8; }
            i = i + 3;
            continue;
        }
        if a == 0xed {
            if i + 2 >= end || raw[i + 1] < 0x80 || raw[i + 1] > 0x9f ||
               raw[i + 2] < 0x80 || raw[i + 2] > 0xbf { return PROTO_ERR_UTF8; }
            i = i + 3;
            continue;
        }
        if a == 0xf0 {
            if i + 3 >= end || raw[i + 1] < 0x90 || raw[i + 1] > 0xbf ||
               raw[i + 2] < 0x80 || raw[i + 2] > 0xbf ||
               raw[i + 3] < 0x80 || raw[i + 3] > 0xbf { return PROTO_ERR_UTF8; }
            i = i + 4;
            continue;
        }
        if a >= 0xf1 && a <= 0xf3 {
            if i + 3 >= end || raw[i + 1] < 0x80 || raw[i + 1] > 0xbf ||
               raw[i + 2] < 0x80 || raw[i + 2] > 0xbf ||
               raw[i + 3] < 0x80 || raw[i + 3] > 0xbf { return PROTO_ERR_UTF8; }
            i = i + 4;
            continue;
        }
        if a == 0xf4 {
            if i + 3 >= end || raw[i + 1] < 0x80 || raw[i + 1] > 0x8f ||
               raw[i + 2] < 0x80 || raw[i + 2] > 0xbf ||
               raw[i + 3] < 0x80 || raw[i + 3] > 0xbf { return PROTO_ERR_UTF8; }
            i = i + 4;
            continue;
        }
        return PROTO_ERR_UTF8;
    }
    return 0;
}

// Kept for rpc.sl's metadata checks, which want the two answers apart.
fn proto_has_nul(raw: bytes, start: int, end: int) -> bool {
    let i = start;
    while i < end {
        if raw[i] == 0 { return true; }
        i = i + 1;
    }
    return false;
}

fn proto_utf8_valid(raw: bytes, start: int, end: int) -> bool {
    return proto_text_error(raw, start, end) != PROTO_ERR_UTF8;
}

// IEEE-754 codecs use slang's generic binary64 byte helpers. Protobuf float
// (binary32) is converted explicitly with round-to-nearest, ties-to-even so
// host endianness and the C compiler's numeric casts never affect the wire.
pub fn proto_reader_double(r: Reader) -> result[float, int] {
    let read = proto_reader_fixed64(r);
    guard let bits = read else let code = err_of(read) { return err(code); }
    let decoded = encoding.float64_from_le(proto_u64_le(bits));
    guard let value = decoded else { return err(PROTO_ERR_FLOAT); }
    return ok(value);
}

pub fn proto_reader_float(r: Reader) -> result[float, int] {
    let read = proto_reader_fixed32(r);
    guard let bits = read else let code = err_of(read) { return err(code); }
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
    guard let value = decoded else { return err(PROTO_ERR_FLOAT); }
    return ok(value);
}

fn proto_double_bits(value: float) -> u64 {
    let raw = encoding.float64_to_le(value);
    let bits: u64 = 0;
    let i = 0;
    while i < 8 {
        bits = bits | ((raw[i] as u64) << (i * 8));
        i = i + 1;
    }
    return bits;
}

fn proto_float_bits(value: float) -> u32 {
    let bits = proto_double_bits(value);
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
    return out_bits;
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

pub fn proto_writer() -> Writer {
    return Writer { out: builder.new_bytes() };
}

pub fn proto_writer_size(w: Writer) -> int {
    return w.out.size();
}

pub fn proto_writer_finish(w: Writer) -> bytes {
    return w.out.take();
}

// Encoded sizes, for the generated size_<Message> pass.
pub fn proto_size_varint(value: u64) -> int {
    let n = 1;
    let rest = value;
    while rest > 127 {
        rest = rest >> 7;
        n = n + 1;
    }
    return n;
}

pub fn proto_size_key(field_number: int) -> int {
    return proto_size_varint((field_number as u64) << 3);
}

// A length-delimited value of `size` bytes, with its length prefix.
pub fn proto_size_delimited(size: int) -> int {
    return proto_size_varint(size as u64) + size;
}

pub fn proto_write_varint(w: Writer, value: u64) {
    let rest = value;
    while rest > 127 {
        w.out.write_byte(((rest & 127) as int) | 128);
        rest = rest >> 7;
    }
    w.out.write_byte(rest as int);
}

// Field numbers and wire types come from generated code, which only emits
// valid ones; the generator rejects the rest.
pub fn proto_write_key(w: Writer, field_number: int, wire_type: int) {
    proto_write_varint(w, ((field_number as u64) << 3) | wire_type as u64);
}

pub fn proto_write_bytes(w: Writer, value: bytes) {
    proto_write_varint(w, len(value) as u64);
    w.out.write(value);
}

pub fn proto_write_string(w: Writer, value: str) {
    proto_write_varint(w, len(value) as u64);
    w.out.write_str(value);
}

pub fn proto_write_bool(w: Writer, value: bool) {
    if value {
        w.out.write_byte(1);
    } else {
        w.out.write_byte(0);
    }
}

pub fn proto_write_fixed32(w: Writer, value: u32) {
    w.out.write_byte((value & 255) as int);
    w.out.write_byte(((value >> 8) & 255) as int);
    w.out.write_byte(((value >> 16) & 255) as int);
    w.out.write_byte(((value >> 24) & 255) as int);
}

pub fn proto_write_fixed64(w: Writer, value: u64) {
    proto_write_fixed32(w, (value & 4294967295) as u32);
    proto_write_fixed32(w, (value >> 32) as u32);
}

pub fn proto_write_double(w: Writer, value: float) {
    proto_write_fixed64(w, proto_double_bits(value));
}

pub fn proto_write_float(w: Writer, value: float) {
    proto_write_fixed32(w, proto_float_bits(value));
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

pub fn proto_int32_in_range(value: int) -> bool {
    return value >= -2147483648 && value <= 2147483647;
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
