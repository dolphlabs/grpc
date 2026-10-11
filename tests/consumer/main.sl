import "grpc";

fn require(ok: bool, what: str) {
    if !ok { panic("gRPC consumer failed: " + what); }
}

fn is_err[T](value: result[T, str]) -> bool {
    if let _ok = value { return false; }
    return true;
}

let user = new_User();
user.id = 17;
user.score = -23;
user.name = "Ada";
user.avatar = b"\x00\xff";
user.active = true;
user.ratio = 1.5;
user.balance = -42.25;
user.color = Color_RED;
push(user.nums, 1 as u32);
push(user.nums, 300 as u32);
push(user.old_nums, -1);
user.address = some(Address { city: "Lagos" });
user.nickname = some("A");
user.labels["role"] = 3;
user.offices[7] = Address { city: "Abuja" };
user.unsigned_count = 4294967295 as u32;
user.unsigned_total = 18446744073709551615 as u64;
user.signed_delta = -2147483648;
user.fixed_count = 4294967295 as u32;
user.fixed_total = 18446744073709551615 as u64;
user.signed_fixed = -2147483648;
user.signed_fixed_total = -9223372036854775807;

let limits = grpc.proto_default_limits();
let encoded_result = encode_User(user, limits);
guard let encoded = encoded_result else let e = err_of(encoded_result) { panic(e); }
require(encoded_size_User(user, limits) == len(encoded), "generated message size matches output");
let decoded_result = decode_User(encoded, limits);
guard let decoded = decoded_result else let e = err_of(decoded_result) { panic(e); }
require(decoded.id == 17 && decoded.score == -23, "signed scalar round trip");
require(decoded.name == "Ada" && decoded.avatar == b"\x00\xff", "bytes and string round trip");
require(decoded.active && decoded.ratio == 1.5 && decoded.balance == -42.25, "bool and float round trip");
require(decoded.color == Color_RED, "enum constant round trip");
require(len(decoded.nums) == 2 && decoded.nums[1] == (300 as u32), "packed repeated round trip");
require(len(decoded.old_nums) == 1 && decoded.old_nums[0] == -1, "unpacked repeated round trip");
guard let address = decoded.address else { panic("nested message missing"); }
require(address.city == "Lagos", "nested message round trip");
guard let nickname = decoded.nickname else { panic("optional string missing"); }
require(nickname == "A", "optional scalar round trip");
require(decoded.labels["role"] == 3, "map scalar round trip");
require(decoded.offices[7].city == "Abuja", "map message round trip");

let default_maps = new_User();
default_maps.labels[""] = 0;
default_maps.offices[0] = new_Address();
let default_maps_result = encode_User(default_maps, limits);
guard let default_maps_raw = default_maps_result else let e = err_of(default_maps_result) { panic(e); }
require(encoded_size_User(default_maps, limits) == len(default_maps_raw),
        "generated map sizes match default-valued entries");
let default_maps_decoded_result = decode_User(default_maps_raw, limits);
guard let default_maps_decoded = default_maps_decoded_result else let e = err_of(default_maps_decoded_result) { panic(e); }
require(default_maps_decoded.labels[""] == 0 && default_maps_decoded.offices[0].city == "",
        "default-valued map entries round trip");

let short_nested_limits_result = grpc.proto_new_limits(6, 4, 100);
guard let short_nested_limits = short_nested_limits_result else let e = err_of(short_nested_limits_result) { panic(e); }
let nested_only = new_User();
nested_only.address = some(Address { city: "Lagos" });
require(is_err(encode_User(nested_only, short_nested_limits)),
        "nested message size respects configured byte limit");

let short_map_limits_result = grpc.proto_new_limits(8, 4, 100);
guard let short_map_limits = short_map_limits_result else let e = err_of(short_map_limits_result) { panic(e); }
let map_only = new_User();
map_only.offices[0] = Address { city: "Lagos" };
require(is_err(encode_User(map_only, short_map_limits)),
        "map entry size respects configured byte limit");
require(decoded.unsigned_count == (4294967295 as u32) &&
        decoded.unsigned_total == (18446744073709551615 as u64),
        "unsigned integer round trip");
require(decoded.signed_delta == -2147483648 &&
        decoded.fixed_count == (4294967295 as u32) &&
        decoded.fixed_total == (18446744073709551615 as u64),
        "zigzag and fixed unsigned round trip");
require(decoded.signed_fixed == -2147483648 &&
        decoded.signed_fixed_total == -9223372036854775807,
        "signed fixed integer round trip");
let malformed_uint32 = decode_User(b"\x78\x80\x80\x80\x80\x10", limits);
require(is_err(malformed_uint32), "uint32 overflow rejected");
let malformed_sint32 = decode_User(b"\x88\x01\x80\x80\x80\x80\x10", limits);
require(is_err(malformed_sint32), "sint32 overflow rejected");
let malformed_int32 = decode_User(b"\x08\x80\x80\x80\x80\x10", limits);
require(is_err(malformed_int32), "int32 overflow rejected");
let future = new_User();
future.color = 99;
let future_raw_result = encode_User(future, limits);
guard let future_raw = future_raw_result else let e = err_of(future_raw_result) { panic(e); }
let future_decoded_result = decode_User(future_raw, limits);
guard let future_decoded = future_decoded_result else let e = err_of(future_decoded_result) { panic(e); }
require(future_decoded.color == 99, "unknown enum value round trip");
println("generated codecs ok");
