import "builder";

pub let GRPC_DEFAULT_MAX_MESSAGE_BYTES = 4194304;
pub let GRPC_HARD_MAX_MESSAGE_BYTES = 67108864;
pub let GRPC_STATUS_OK = 0;
pub let GRPC_STATUS_CANCELLED = 1;
pub let GRPC_STATUS_UNKNOWN = 2;
pub let GRPC_STATUS_INVALID_ARGUMENT = 3;
pub let GRPC_STATUS_DEADLINE_EXCEEDED = 4;
pub let GRPC_STATUS_NOT_FOUND = 5;
pub let GRPC_STATUS_ALREADY_EXISTS = 6;
pub let GRPC_STATUS_PERMISSION_DENIED = 7;
pub let GRPC_STATUS_RESOURCE_EXHAUSTED = 8;
pub let GRPC_STATUS_FAILED_PRECONDITION = 9;
pub let GRPC_STATUS_ABORTED = 10;
pub let GRPC_STATUS_OUT_OF_RANGE = 11;
pub let GRPC_STATUS_UNIMPLEMENTED = 12;
pub let GRPC_STATUS_INTERNAL = 13;
pub let GRPC_STATUS_UNAVAILABLE = 14;
pub let GRPC_STATUS_DATA_LOSS = 15;
pub let GRPC_STATUS_UNAUTHENTICATED = 16;

pub gc struct GrpcMessage {
    wire: bytes,
    offset: int,
    size: int
}

pub gc struct GrpcLimits {
    max_message_bytes: int
}

pub fn grpc_default_limits() -> GrpcLimits {
    return GrpcLimits { max_message_bytes: GRPC_DEFAULT_MAX_MESSAGE_BYTES };
}

pub fn grpc_new_limits(max_message_bytes: int) -> result[GrpcLimits, str] {
    if max_message_bytes < 1 || max_message_bytes > GRPC_HARD_MAX_MESSAGE_BYTES {
        return err("grpc limits: message bytes must be 1..67108864");
    }
    return ok(GrpcLimits { max_message_bytes: max_message_bytes });
}

// gRPC's five-byte envelope: one compression flag and a big-endian length.
// V1 supports uncompressed messages only and refuses compression explicitly.
pub fn grpc_frame_message(message: bytes, limits: GrpcLimits)
                           -> result[bytes, str] {
    if limits.max_message_bytes < 1 ||
       limits.max_message_bytes > GRPC_HARD_MAX_MESSAGE_BYTES {
        return err("grpc frame: invalid message limit");
    }
    if len(message) > limits.max_message_bytes {
        return err("grpc frame: message exceeds configured byte limit");
    }
    let out = builder.new_bytes();
    out.write_byte(0);
    out.write_byte((len(message) >> 24) & 255);
    out.write_byte((len(message) >> 16) & 255);
    out.write_byte((len(message) >> 8) & 255);
    out.write_byte(len(message) & 255);
    out.write(message);
    return ok(out.finish());
}

// The returned view retains the original frame and avoids a second copy of
// the protobuf message. Use grpc_message_bytes only when an owned copy is
// actually required by the caller.
pub fn grpc_parse_message(wire: bytes, limits: GrpcLimits)
                          -> result[GrpcMessage, str] {
    if limits.max_message_bytes < 1 ||
       limits.max_message_bytes > GRPC_HARD_MAX_MESSAGE_BYTES {
        return err("grpc parse: invalid message limit");
    }
    if len(wire) < 5 {
        return err("grpc parse: message is shorter than the five-byte envelope");
    }
    if wire[0] != 0 {
        return err("grpc parse: compressed messages are not supported");
    }
    // Reject lengths above the configured 64 MiB hard cap before shifting
    // into slang's signed int representation.
    if wire[1] > 4 ||
       (wire[1] == 4 && (wire[2] != 0 || wire[3] != 0 || wire[4] != 0)) {
        return err("grpc parse: message exceeds configured byte limit");
    }
    let size = (wire[1] << 24) | (wire[2] << 16) |
               (wire[3] << 8) | wire[4];
    if size > limits.max_message_bytes {
        return err("grpc parse: message exceeds configured byte limit");
    }
    if len(wire) != 5 + size {
        return err("grpc parse: declared message length does not match frame");
    }
    return ok(GrpcMessage { wire: wire, offset: 5, size: size });
}

pub fn grpc_message_size(message: GrpcMessage) -> int {
    return message.size;
}

pub fn grpc_message_bytes(message: GrpcMessage) -> bytes {
    return message.wire[message.offset..message.offset + message.size];
}

pub fn grpc_message_reader(message: GrpcMessage, limits: Limits)
                           -> result[Reader, str] {
    if !proto_limits_valid(limits) {
        return err("grpc message reader: invalid protobuf limits");
    }
    if message.size > limits.max_message_bytes {
        return err("grpc message reader: message exceeds configured byte limit");
    }
    let budget = Budget { values: 0, max_values: limits.max_values };
    return ok(Reader {
        data: message.wire,
        pos: message.offset,
        end: message.offset + message.size,
        depth: 0,
        limits: limits,
        budget: budget
    });
}
