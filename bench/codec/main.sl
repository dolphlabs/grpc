// Encode or decode the consumer fixture's User (21 fields: a nested
// message, two maps, packed and unpacked repeats) N times and print the
// time per operation. Run through run.sh, which also reports allocations.
// `wire <path>` writes the encoded bytes instead, for compare-go.sh.
import "fs";
import "grpc";
import "proc";
import "time";

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

let args = proc.args();
if len(args) != 3 || (args[1] != "encode" && args[1] != "decode" && args[1] != "wire") {
    println("usage: codec encode|decode <iterations> | codec wire <path>");
    exit(2);
}
let mode = args[1];
if mode == "wire" {
    let encoded = encode_User(user, grpc.proto_default_limits());
    guard let raw = encoded else let e = err_of(encoded) { println("encode: " + e); exit(1); }
    let opened = fs.create(args[2]);
    guard let fd = opened else let e = err_of(opened) { println("create: " + e); exit(1); }
    let written = fs.write(fd as int, raw);
    guard let _n = written else let e = err_of(written) { println("write: " + e); exit(1); }
    let closed = fs.close(fd as int);
    guard let _c = closed else let e = err_of(closed) { println("close: " + e); exit(1); }
    exit(0);
}
let n = to_int(args[2]) ?? 0;
if n < 1 {
    println("iterations must be a positive integer");
    exit(2);
}
let limits = grpc.proto_default_limits();
let wire_result = encode_User(user, limits);
guard let wire = wire_result else let e = err_of(wire_result) {
    println("encode: " + e);
    exit(1);
}
let checksum = 0;
let started = time.mono() as int;
for i in 0..n {
    if mode == "encode" {
        let r = encode_User(user, limits);
        guard let out = r else { panic("encode failed"); }
        checksum += len(out);
    } else {
        let r = decode_User(wire, limits);
        guard let back = r else let e = err_of(r) { panic("decode: " + e); }
        checksum += back.id;
    }
}
let elapsed = (time.mono() as int) - started;
println(mode + " " + to_str(len(wire)) + "B ns/op " + to_str(elapsed / n) + " checksum " + to_str(checksum));
