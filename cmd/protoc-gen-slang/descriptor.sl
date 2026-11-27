import "builder";
import "json";
import "strings";
import "unicode";

fn label_optional() -> int { return 1; }
fn label_required() -> int { return 2; }
fn label_repeated() -> int { return 3; }

fn type_double() -> int { return 1; }
fn type_float() -> int { return 2; }
fn type_int64() -> int { return 3; }
fn type_uint64() -> int { return 4; }
fn type_int32() -> int { return 5; }
fn type_fixed64() -> int { return 6; }
fn type_fixed32() -> int { return 7; }
fn type_bool() -> int { return 8; }
fn type_string() -> int { return 9; }
fn type_group() -> int { return 10; }
fn type_message() -> int { return 11; }
fn type_bytes() -> int { return 12; }
fn type_uint32() -> int { return 13; }
fn type_enum() -> int { return 14; }
fn type_sfixed32() -> int { return 15; }
fn type_sfixed64() -> int { return 16; }
fn type_sint32() -> int { return 17; }
fn type_sint64() -> int { return 18; }

gc struct EnumValue {
    name: str,
    number: int
}

gc struct EnumDesc {
    name: str,
    full_name: str,
    slang_name: str,
    allow_alias: bool,
    values: [EnumValue]
}

gc struct FieldDesc {
    name: str,
    type_name: str,
    number: int,
    label: int,
    kind: int,
    oneof_index: int,
    proto3_optional: bool,
    has_packed: bool,
    packed: bool,
    map_key: opt[FieldDesc],
    map_value: opt[FieldDesc]
}

gc struct MessageDesc {
    name: str,
    full_name: str,
    slang_name: str,
    map_entry: bool,
    fields: [FieldDesc],
    nested: [MessageDesc],
    enums: [EnumDesc]
}

gc struct MethodDesc {
    name: str,
    input_type: str,
    output_type: str,
    client_stream: bool,
    server_stream: bool
}

gc struct ServiceDesc {
    name: str,
    methods: [MethodDesc]
}

gc struct FileDesc {
    name: str,
    pkg: str,
    syntax: str,
    messages: [MessageDesc],
    enums: [EnumDesc],
    services: [ServiceDesc]
}

gc struct ParsedRequest {
    files_to_generate: [str],
    files: [FileDesc]
}

fn bytes_to_str(b: bytes) -> str {
    return strings.from_bytes(b, 0, len(b));
}

fn trim_leading_dot(s: str) -> str {
    if strings.has_prefix(s, ".") {
        return strings.slice(s, 1, len(s));
    }
    return s;
}

fn copy_and_append_str(xs: [str], item: str) -> [str] {
    let out: [str] = [];
    for i in 0..len(xs) {
        push(out, xs[i]);
    }
    push(out, item);
    return out;
}

fn valid_proto_identifier(name: str) -> bool {
    let b = to_bytes(name);
    if len(b) == 0 { return false; }
    let c0 = b[0];
    if !((c0 >= 65 && c0 <= 90) || (c0 >= 97 && c0 <= 122) || c0 == 95) {
        return false;
    }
    for i in 1..len(b) {
        let c = b[i];
        if !((c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95) {
            return false;
        }
    }
    return true;
}

fn valid_qualified_identifier(name: str) -> bool {
    if len(name) == 0 { return false; }
    let parts = strings.split(name, ".");
    for i in 0..len(parts) {
        if !valid_proto_identifier(parts[i]) {
            return false;
        }
    }
    return true;
}

fn is_reserved(name: str) -> bool {
    if name == "as" || name == "break" || name == "case" || name == "chan" ||
       name == "continue" || name == "default" || name == "else" || name == "enum" ||
       name == "false" || name == "fn" || name == "for" || name == "gc" ||
       name == "guard" || name == "if" || name == "impl" || name == "in" ||
       name == "let" || name == "match" || name == "mut" || name == "none" ||
       name == "opt" || name == "own" || name == "pub" || name == "result" ||
       name == "return" || name == "self" || name == "spawn" || name == "struct" ||
       name == "switch" || name == "true" || name == "while" ||
       name == "bool" || name == "bytes" || name == "float" || name == "int" ||
       name == "str" || name == "u8" || name == "u16" || name == "u32" ||
       name == "u64" || name == "i8" || name == "i16" || name == "i32" ||
       name == "i64" || name == "f32" || name == "f64" {
        return true;
    }
    return false;
}

fn safe_identifier(name: str) -> str {
    let b = to_bytes(name);
    let out = builder.new_bytes();
    for i in 0..len(b) {
        let c = b[i];
        let valid = c == 95 || (c >= 97 && c <= 122) || (c >= 65 && c <= 90) ||
                    (i > 0 && c >= 48 && c <= 57);
        if valid {
            out.write_byte(c);
        } else {
            out.write_byte(95);
        }
    }
    let res = bytes_to_str(out.finish());
    let rb = to_bytes(res);
    if len(rb) == 0 || (rb[0] >= 48 && rb[0] <= 57) {
        res = "_" + res;
    }
    if is_reserved(res) {
        res = res + "_";
    }
    return res;
}

fn qualified(pkg: str, path: [str]) -> str {
    let name = strings.join(path, ".");
    if len(pkg) == 0 { return name; }
    return pkg + "." + name;
}

fn flatten_name(path: [str]) -> str {
    let parts: [str] = [];
    for i in 0..len(path) {
        push(parts, safe_identifier(path[i]));
    }
    return strings.join(parts, "_");
}

fn output_name(proto_name: str) -> str {
    let slash = strings.rfind(proto_name, "/");
    let dot = strings.rfind(proto_name, ".");
    let base = proto_name;
    if dot > slash {
        base = strings.slice(proto_name, 0, dot);
    }
    return base + ".pb.sl";
}

fn parse_request(raw: bytes) -> result[ParsedRequest, str] {
    let fr = parse_wire(raw);
    guard let fields = fr else let e = err_of(fr) {
        return err("CodeGeneratorRequest: " + e);
    }
    let files_to_generate: [str] = [];
    let files: [FileDesc] = [];
    for i in 0..len(fields) {
        let f = fields[i];
        if f.number == 1 {
            if f.wire != 2 || !unicode.valid_bytes(f.raw) {
                return err("CodeGeneratorRequest.file_to_generate is not UTF-8");
            }
            push(files_to_generate, bytes_to_str(f.raw));
        } else if f.number == 15 {
            if f.wire != 2 {
                return err("CodeGeneratorRequest.proto_file has the wrong wire type");
            }
            let dr = parse_file(f.raw);
            guard let d = dr else let e = err_of(dr) { return err(e); }
            push(files, d);
        }
    }
    if len(files_to_generate) == 0 {
        return err("protoc supplied no input files");
    }
    return ok(ParsedRequest { files_to_generate: files_to_generate, files: files });
}

fn parse_file(raw: bytes) -> result[FileDesc, str] {
    let fr = parse_wire(raw);
    guard let fields = fr else let e = err_of(fr) {
        return err("FileDescriptorProto: " + e);
    }
    let d = FileDesc { name: "", pkg: "", syntax: "", messages: [], enums: [], services: [] };
    let raw_messages: [bytes] = [];
    let raw_enums: [bytes] = [];
    let raw_services: [bytes] = [];
    for i in 0..len(fields) {
        let f = fields[i];
        if f.number == 1 { d.name = bytes_to_str(f.raw); }
        else if f.number == 2 { d.pkg = bytes_to_str(f.raw); }
        else if f.number == 4 { push(raw_messages, f.raw); }
        else if f.number == 5 { push(raw_enums, f.raw); }
        else if f.number == 6 { push(raw_services, f.raw); }
        else if f.number == 12 { d.syntax = bytes_to_str(f.raw); }
    }
    if len(d.name) == 0 {
        return err("FileDescriptorProto has no name");
    }
    if !strings.has_suffix(d.name, ".proto") || !unicode.valid(d.name) {
        return err("FileDescriptorProto name " + json.encode(d.name) + " must be a UTF-8 .proto path");
    }
    if len(d.pkg) > 0 && !valid_qualified_identifier(d.pkg) {
        return err(d.name + ": invalid proto package name " + json.encode(d.pkg));
    }
    let empty_parents: [str] = [];
    for i in 0..len(raw_messages) {
        let mr = parse_message(raw_messages[i], d.pkg, empty_parents);
        guard let m = mr else let e = err_of(mr) { return err(e); }
        push(d.messages, m);
    }
    for i in 0..len(raw_enums) {
        let er = parse_enum(raw_enums[i], d.pkg, empty_parents);
        guard let ev = er else let e = err_of(er) { return err(e); }
        push(d.enums, ev);
    }
    for i in 0..len(raw_services) {
        let sr = parse_service(raw_services[i]);
        guard let s = sr else let e = err_of(sr) { return err(e); }
        push(d.services, s);
    }
    return ok(d);
}

fn parse_message(raw: bytes, pkg: str, parents: [str]) -> result[MessageDesc, str] {
    return parse_message_depth(raw, pkg, parents, 0);
}

fn parse_message_depth(raw: bytes, pkg: str, parents: [str], depth: int) -> result[MessageDesc, str] {
    if depth > 64 {
        return err("nested message depth exceeds 64");
    }
    let fr = parse_wire(raw);
    guard let fields = fr else let e = err_of(fr) {
        return err("DescriptorProto: " + e);
    }
    let d = MessageDesc {
        name: "",
        full_name: "",
        slang_name: "",
        map_entry: false,
        fields: [],
        nested: [],
        enums: []
    };
    let raw_fields: [bytes] = [];
    let raw_nested: [bytes] = [];
    let raw_enums: [bytes] = [];
    let raw_oneofs: [bytes] = [];
    for i in 0..len(fields) {
        let f = fields[i];
        if f.number == 1 { d.name = bytes_to_str(f.raw); }
        else if f.number == 2 { push(raw_fields, f.raw); }
        else if f.number == 3 { push(raw_nested, f.raw); }
        else if f.number == 4 { push(raw_enums, f.raw); }
        else if f.number == 7 {
            let opt_res = parse_wire(f.raw);
            guard let opts = opt_res else let e = err_of(opt_res) {
                return err(d.name + " options: " + e);
            }
            for j in 0..len(opts) {
                let optv = opts[j];
                if optv.number == 7 && optv.value == (1 as u64) {
                    d.map_entry = true;
                }
            }
        } else if f.number == 8 {
            push(raw_oneofs, f.raw);
        }
    }
    if !valid_proto_identifier(d.name) {
        return err("DescriptorProto has invalid name " + json.encode(d.name));
    }
    let path = copy_and_append_str(parents, d.name);
    d.full_name = qualified(pkg, path);
    d.slang_name = flatten_name(path);

    for i in 0..len(raw_oneofs) {
        let of_res = parse_wire(raw_oneofs[i]);
        guard let of_parts = of_res else let e = err_of(of_res) {
            return err(d.full_name + " oneof: " + e);
        }
        let oname = "";
        for j in 0..len(of_parts) {
            if of_parts[j].number == 1 {
                oname = bytes_to_str(of_parts[j].raw);
            }
        }
        if len(oname) == 0 {
            return err(d.full_name + " has an unnamed oneof at index " + to_str(i));
        }
    }
    for i in 0..len(raw_fields) {
        let fld_res = parse_field(raw_fields[i]);
        guard let fld = fld_res else let e = err_of(fld_res) {
            return err(d.full_name + " field: " + e);
        }
        push(d.fields, fld);
    }
    for i in 0..len(raw_nested) {
        let mr = parse_message_depth(raw_nested[i], pkg, path, depth + 1);
        guard let child = mr else let e = err_of(mr) { return err(e); }
        push(d.nested, child);
    }
    for i in 0..len(raw_enums) {
        let er = parse_enum(raw_enums[i], pkg, path);
        guard let ev = er else let e = err_of(er) { return err(e); }
        push(d.enums, ev);
    }
    return ok(d);
}

fn parse_field(raw: bytes) -> result[FieldDesc, str] {
    let pr = parse_wire(raw);
    guard let parts = pr else let e = err_of(pr) { return err(e); }
    let f = FieldDesc {
        name: "",
        type_name: "",
        number: 0,
        label: 0,
        kind: 0,
        oneof_index: -1,
        proto3_optional: false,
        has_packed: false,
        packed: false,
        map_key: none,
        map_value: none
    };
    for i in 0..len(parts) {
        let p = parts[i];
        if p.number == 1 { f.name = bytes_to_str(p.raw); }
        else if p.number == 3 { f.number = p.value as int; }
        else if p.number == 4 { f.label = p.value as int; }
        else if p.number == 5 { f.kind = p.value as int; }
        else if p.number == 6 { f.type_name = trim_leading_dot(bytes_to_str(p.raw)); }
        else if p.number == 8 {
            let opt_res = parse_wire(p.raw);
            guard let opts = opt_res else let e = err_of(opt_res) { return err(e); }
            for j in 0..len(opts) {
                let optv = opts[j];
                if optv.number == 2 {
                    f.has_packed = true;
                    f.packed = optv.value != (0 as u64);
                }
            }
        }
        else if p.number == 9 { f.oneof_index = p.value as int; }
        else if p.number == 17 { f.proto3_optional = p.value != (0 as u64); }
    }
    if !valid_proto_identifier(f.name) || f.number < 1 || f.number > 536870911 ||
       f.label < 1 || f.label > 3 || f.kind < 1 || f.kind > 18 {
        return err("incomplete or invalid field descriptor");
    }
    if f.kind == type_group() {
        return err("field " + f.name + " uses unsupported GROUP");
    }
    return ok(f);
}

fn parse_enum(raw: bytes, pkg: str, parents: [str]) -> result[EnumDesc, str] {
    let fr = parse_wire(raw);
    guard let fields = fr else let e = err_of(fr) {
        return err("EnumDescriptorProto: " + e);
    }
    let e = EnumDesc { name: "", full_name: "", slang_name: "", allow_alias: false, values: [] };
    let raw_values: [bytes] = [];
    for i in 0..len(fields) {
        let f = fields[i];
        if f.number == 1 { e.name = bytes_to_str(f.raw); }
        else if f.number == 2 { push(raw_values, f.raw); }
        else if f.number == 3 {
            let opt_res = parse_wire(f.raw);
            guard let opts = opt_res else let err_msg = err_of(opt_res) {
                return err("enum options: " + err_msg);
            }
            for j in 0..len(opts) {
                if opts[j].number == 2 {
                    e.allow_alias = opts[j].value != (0 as u64);
                }
            }
        }
    }
    if !valid_proto_identifier(e.name) {
        return err("EnumDescriptorProto has invalid name " + json.encode(e.name));
    }
    let path = copy_and_append_str(parents, e.name);
    e.full_name = qualified(pkg, path);
    e.slang_name = flatten_name(path);

    let seen_names: map[str]bool = {};
    let seen_identifiers: map[str]bool = {};
    let seen_numbers: map[int]bool = {};
    for i in 0..len(raw_values) {
        let pr = parse_wire(raw_values[i]);
        guard let parts = pr else let err_msg = err_of(pr) {
            return err(e.full_name + " value: " + err_msg);
        }
        let v = EnumValue { name: "", number: 0 };
        for j in 0..len(parts) {
            let part = parts[j];
            if part.number == 1 { v.name = bytes_to_str(part.raw); }
            if part.number == 2 { v.number = part.value as int; }
        }
        if !valid_proto_identifier(v.name) {
            return err(e.full_name + " has invalid enum value name " + json.encode(v.name));
        }
        if has(seen_names, v.name) {
            return err(e.full_name + " has duplicate enum value name " + json.encode(v.name));
        }
        let ident = safe_identifier(v.name);
        if has(seen_identifiers, ident) {
            return err(e.full_name + " enum values collide after Slang name conversion at " + json.encode(v.name));
        }
        if has(seen_numbers, v.number) && !e.allow_alias {
            return err(e.full_name + " has duplicate numeric values; set option allow_alias = true");
        }
        seen_names[v.name] = true;
        seen_identifiers[ident] = true;
        seen_numbers[v.number] = true;
        push(e.values, v);
    }
    if len(e.values) == 0 || e.values[0].number != 0 {
        return err(e.full_name + " must declare its zero value first");
    }
    return ok(e);
}

fn parse_service(raw: bytes) -> result[ServiceDesc, str] {
    let fr = parse_wire(raw);
    guard let fields = fr else let e = err_of(fr) {
        return err("ServiceDescriptorProto: " + e);
    }
    let d = ServiceDesc { name: "", methods: [] };
    let raw_methods: [bytes] = [];
    for i in 0..len(fields) {
        let f = fields[i];
        if f.number == 1 { d.name = bytes_to_str(f.raw); }
        if f.number == 2 { push(raw_methods, f.raw); }
    }
    if !valid_proto_identifier(d.name) {
        return err("service descriptor has invalid name " + json.encode(d.name));
    }
    for i in 0..len(raw_methods) {
        let mr = parse_method(raw_methods[i]);
        guard let m = mr else let e = err_of(mr) { return err(e); }
        push(d.methods, m);
    }
    return ok(d);
}

fn parse_method(raw: bytes) -> result[MethodDesc, str] {
    let fr = parse_wire(raw);
    guard let fields = fr else let e = err_of(fr) {
        return err("MethodDescriptorProto: " + e);
    }
    let m = MethodDesc { name: "", input_type: "", output_type: "", client_stream: false, server_stream: false };
    for i in 0..len(fields) {
        let f = fields[i];
        if f.number == 1 { m.name = bytes_to_str(f.raw); }
        else if f.number == 2 { m.input_type = trim_leading_dot(bytes_to_str(f.raw)); }
        else if f.number == 3 { m.output_type = trim_leading_dot(bytes_to_str(f.raw)); }
        else if f.number == 5 { m.client_stream = f.value != (0 as u64); }
        else if f.number == 6 { m.server_stream = f.value != (0 as u64); }
    }
    if !valid_proto_identifier(m.name) || !valid_qualified_identifier(m.input_type) || !valid_qualified_identifier(m.output_type) {
        return err("service method descriptor is incomplete");
    }
    return ok(m);
}
