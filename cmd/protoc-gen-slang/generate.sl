import "builder";
import "json";
import "strings";

gc struct GeneratedFile {
    name: str,
    content: str
}

gc struct Registry {
    messages: map[str]MessageDesc,
    message_list: [MessageDesc],
    enums: map[str]EnumDesc,
    by_name: map[str]str
}

fn is_safe_relative_proto_path(name: str) -> bool {
    if len(name) == 0 { return false; }
    if !strings.has_suffix(name, ".proto") { return false; }
    if strings.has_prefix(name, "/") || strings.contains(name, "\\") || strings.contains(name, "//") {
        return false;
    }
    let b = to_bytes(name);
    for i in 0..len(b) {
        let c = b[i];
        if c < 32 || c == 127 {
            return false;
        }
    }
    let parts = strings.split(name, "/");
    for i in 0..len(parts) {
        let seg = parts[i];
        if len(seg) == 0 || seg == "." || seg == ".." {
            return false;
        }
    }
    return true;
}

fn generate(requested: [str], files: [FileDesc]) -> result[[GeneratedFile], str] {
    let file_by_name: map[str]FileDesc = {};
    let file_list: [FileDesc] = [];
    let reg = Registry { messages: {}, message_list: [], enums: {}, by_name: {} };

    for i in 0..len(files) {
        let file = files[i];
        if !is_safe_relative_proto_path(file.name) {
            return err("proto file name " + json.encode(file.name) + " is not a safe relative path");
        }
        if has(file_by_name, file.name) {
            return err("protoc supplied duplicate descriptor for " + json.encode(file.name));
        }
        file_by_name[file.name] = file;
        push(file_list, file);
        for j in 0..len(file.messages) {
            let mr = collect_message(reg, file.messages[j]);
            guard let _ok = mr else let e = err_of(mr) { return err(e); }
        }
        for j in 0..len(file.enums) {
            let er = add_enum(reg, file.enums[j]);
            guard let _ok = er else let e = err_of(er) { return err(e); }
        }
    }

    let requested_set: map[str]bool = {};
    let package_name = "";
    let has_pkg = false;
    for i in 0..len(requested) {
        let name = requested[i];
        if has(requested_set, name) {
            return err("protoc requested " + json.encode(name) + " more than once");
        }
        if !has(file_by_name, name) {
            return err("protoc requested " + json.encode(name) + " but omitted its descriptor");
        }
        let f = file_by_name[name];
        if f.syntax != "proto3" {
            return err(name + ": only proto3 syntax is supported; set `syntax = \"proto3\";`");
        }
        if !has_pkg {
            package_name = f.pkg;
            has_pkg = true;
        } else if package_name != f.pkg {
            return err("input files use different proto packages (" + json.encode(package_name) + " and " + json.encode(f.pkg) + "); generate one package per invocation");
        }
        requested_set[name] = true;
    }

    let vr = validate_registry(reg, requested_set, file_list);
    guard let _vok = vr else let e = err_of(vr) { return err(e); }

    let out: [GeneratedFile] = [];
    for i in 0..len(requested) {
        let name = requested[i];
        let cr = generate_file(file_by_name[name], reg);
        guard let content = cr else let e = err_of(cr) { return err(e); }
        push(out, GeneratedFile { name: output_name(name), content: content });
    }
    return ok(out);
}

fn collect_message(reg: Registry, m: MessageDesc) -> result[bool, str] {
    let mr = add_message(reg, m);
    guard let _mok = mr else let e = err_of(mr) { return err(e); }
    for i in 0..len(m.enums) {
        let er = add_enum(reg, m.enums[i]);
        guard let _eok = er else let e = err_of(er) { return err(e); }
    }
    for i in 0..len(m.nested) {
        let cr = collect_message(reg, m.nested[i]);
        guard let _cok = cr else let e = err_of(cr) { return err(e); }
    }
    return ok(true);
}

fn add_message(reg: Registry, m: MessageDesc) -> result[bool, str] {
    if m.map_entry {
        if !has(reg.messages, m.full_name) {
            push(reg.message_list, m);
        }
        reg.messages[m.full_name] = m;
        return ok(true);
    }
    if has(reg.by_name, m.slang_name) {
        let prev = reg.by_name[m.slang_name];
        if prev != m.full_name {
            return err("proto types " + prev + " and " + m.full_name + " both map to Slang name " + m.slang_name + "; rename one declaration");
        }
    }
    reg.by_name[m.slang_name] = m.full_name;
    if !has(reg.messages, m.full_name) {
        push(reg.message_list, m);
    }
    reg.messages[m.full_name] = m;
    return ok(true);
}

fn add_enum(reg: Registry, e: EnumDesc) -> result[bool, str] {
    if has(reg.by_name, e.slang_name) {
        let prev = reg.by_name[e.slang_name];
        if prev != e.full_name {
            return err("proto types " + prev + " and " + e.full_name + " both map to Slang name " + e.slang_name + "; rename one declaration");
        }
    }
    reg.by_name[e.slang_name] = e.full_name;
    reg.enums[e.full_name] = e;
    return ok(true);
}

fn file_for_type(full: str, files: [FileDesc]) -> str {
    for i in 0..len(files) {
        let f = files[i];
        let prefix = f.pkg;
        if len(prefix) > 0 {
            prefix = prefix + ".";
        }
        if strings.has_prefix(full, prefix) {
            return f.name;
        }
    }
    return "";
}

fn attach_map(fld: FieldDesc, entry: MessageDesc) -> result[bool, str] {
    let key: opt[FieldDesc] = none;
    let value: opt[FieldDesc] = none;
    for i in 0..len(entry.fields) {
        let f = entry.fields[i];
        if f.number == 1 { key = some(f); }
        if f.number == 2 { value = some(f); }
    }
    if len(entry.fields) != 2 {
        return err("map entry must contain exactly key field 1 and value field 2");
    }
    guard let kv = key else {
        return err("map entry must contain exactly key field 1 and value field 2");
    }
    guard let vv = value else {
        return err("map entry must contain exactly key field 1 and value field 2");
    }
    if kv.kind == type_message() || kv.kind == type_enum() || kv.kind == type_bytes() ||
       kv.kind == type_float() || kv.kind == type_double() {
        return err("unsupported protobuf map key type");
    }
    fld.map_key = some(kv);
    fld.map_value = some(vv);
    return ok(true);
}

fn validate_registry(reg: Registry, requested: map[str]bool, files: [FileDesc]) -> result[bool, str] {
    for i in 0..len(reg.message_list) {
        let m = reg.message_list[i];
        if m.map_entry { continue; }
        let seen_number: map[int]bool = {};
        let seen_name: map[str]bool = {};
        for j in 0..len(m.fields) {
            let f = m.fields[j];
            let sname = safe_identifier(f.name);
            if has(seen_number, f.number) || has(seen_name, sname) {
                return err(m.full_name + ": duplicate or colliding field " + json.encode(f.name));
            }
            seen_number[f.number] = true;
            seen_name[sname] = true;
            if f.label == label_required() {
                return err(m.full_name + "." + f.name + ": proto2 required fields are unsupported");
            }
            if f.oneof_index >= 0 && !f.proto3_optional {
                return err(m.full_name + "." + f.name + ": oneof fields are unsupported in v1; use proto3 optional or separate fields");
            }
            if let mk = f.map_key {
                let kr = slang_base_type(mk, reg);
                guard let _kt = kr else let e = err_of(kr) {
                    return err(m.full_name + "." + f.name + " map key: " + e);
                }
                if let mv = f.map_value {
                    let vr = slang_base_type(mv, reg);
                    guard let _vt = vr else let e = err_of(vr) {
                        return err(m.full_name + "." + f.name + " map value: " + e);
                    }
                }
                continue;
            }
            if f.kind == type_message() || f.kind == type_enum() {
                if len(f.type_name) == 0 {
                    return err(m.full_name + "." + f.name + ": missing message or enum type name");
                }
                if f.kind == type_message() {
                    if !has(reg.messages, f.type_name) {
                        return err(m.full_name + "." + f.name + ": message type " + f.type_name + " is not included; add its .proto file to protoc inputs");
                    }
                    let ref = reg.messages[f.type_name];
                    if !ref.map_entry {
                        let ref_file = file_for_type(ref.full_name, files);
                        if len(ref_file) > 0 && !has(requested, ref_file) {
                            let stem = strings.slice(ref_file, 0, len(ref_file) - 6);
                            return err(m.full_name + "." + f.name + ": generate the referenced " + stem + ".proto file in the same `protoc --slang_out` invocation");
                        }
                    } else {
                        if f.label != label_repeated() {
                            return err(m.full_name + "." + f.name + ": map entry field is not repeated");
                        }
                        let ar = attach_map(f, ref);
                        guard let _aok = ar else let e = err_of(ar) {
                            return err(m.full_name + "." + f.name + ": " + e);
                        }
                        continue;
                    }
                } else if !has(reg.enums, f.type_name) {
                    return err(m.full_name + "." + f.name + ": enum type " + f.type_name + " is not included; add its .proto file to protoc inputs");
                }
            }
            let bt = slang_base_type(f, reg);
            guard let _btok = bt else let e = err_of(bt) {
                return err(m.full_name + "." + f.name + ": " + e);
            }
        }
    }
    return ok(true);
}

fn generate_file(file: FileDesc, reg: Registry) -> result[str, str] {
    let b = builder.new_str();
    b.write("// Code generated by protoc-gen-slang. DO NOT EDIT.\n");
    b.write("// Source: " + json.encode(file.name) + "\n\nimport \"grpc\";\n\n");
    for i in 0..len(file.enums) {
        let er = emit_enum(b, file.enums[i]);
        guard let _eok = er else let e = err_of(er) { return err(e); }
    }
    for i in 0..len(file.messages) {
        let mr = emit_message_tree(b, file.messages[i], reg);
        guard let _mok = mr else let e = err_of(mr) { return err(e); }
    }
    for i in 0..len(file.services) {
        let sr = emit_service(b, file, file.services[i], reg);
        guard let _sok = sr else let e = err_of(sr) { return err(e); }
    }
    let out = b.finish();
    while len(out) > 0 && strings.has_suffix(out, "\n") {
        out = strings.slice(out, 0, len(out) - 1);
    }
    return ok(out + "\n");
}

fn emit_message_tree(b: builder.Str, m: MessageDesc, reg: Registry) -> result[bool, str] {
    if !m.map_entry {
        for i in 0..len(m.enums) {
            let er = emit_enum(b, m.enums[i]);
            guard let _eok = er else let e = err_of(er) { return err(e); }
        }
        let mr = emit_message(b, m, reg);
        guard let _mok = mr else let e = err_of(mr) { return err(e); }
    }
    for i in 0..len(m.nested) {
        let nr = emit_message_tree(b, m.nested[i], reg);
        guard let _nok = nr else let e = err_of(nr) { return err(e); }
    }
    return ok(true);
}

fn emit_enum(b: builder.Str, e: EnumDesc) -> result[bool, str] {
    for i in 0..len(e.values) {
        let v = e.values[i];
        if v.number < -2147483648 || v.number > 2147483647 {
            return err(e.full_name + "." + v.name + ": enum number is outside int32 range");
        }
        b.write("pub let " + e.slang_name + "_" + safe_identifier(v.name) + " = " + to_str(v.number) + ";\n");
    }
    b.write("\n");
    return ok(true);
}

fn sort_fields_by_number(src: [FieldDesc]) -> [FieldDesc] {
    let fields: [FieldDesc] = [];
    for i in 0..len(src) {
        push(fields, src[i]);
    }
    let i = 1;
    while i < len(fields) {
        let cur = fields[i];
        let j = i - 1;
        while j >= 0 && fields[j].number > cur.number {
            fields[j + 1] = fields[j];
            j = j - 1;
        }
        fields[j + 1] = cur;
        i = i + 1;
    }
    return fields;
}

fn emit_message(b: builder.Str, m: MessageDesc, reg: Registry) -> result[bool, str] {
    let fields = sort_fields_by_number(m.fields);
    b.write("pub struct " + m.slang_name + " {\n");
    if len(fields) == 0 {
        b.write("    _protobuf_empty: bool,\n");
    }
    for i in 0..len(fields) {
        let f = fields[i];
        let tr = slang_field_type(f, reg);
        guard let t = tr else let e = err_of(tr) {
            return err(m.full_name + "." + f.name + ": " + e);
        }
        b.write("    " + safe_identifier(f.name) + ": " + t + ",\n");
    }
    b.write("}\n\n");
    b.write("pub fn new_" + m.slang_name + "() -> " + m.slang_name + " {\n    return " + m.slang_name + " {\n");
    if len(fields) == 0 {
        b.write("        _protobuf_empty: false\n");
    }
    for i in 0..len(fields) {
        let f = fields[i];
        let comma = ",";
        if i == len(fields) - 1 { comma = ""; }
        b.write("        " + safe_identifier(f.name) + ": " + default_expr(f, reg) + comma + "\n");
    }
    b.write("    };\n}\n\n");
    let dr = emit_decoder(b, m, fields, reg);
    guard let _dok = dr else let e = err_of(dr) { return err(e); }
    let er = emit_encoder(b, m, fields, reg);
    guard let _eok = er else let e = err_of(er) { return err(e); }
    return ok(true);
}

fn err_text(label: str, code: str) -> str {
    return json.encode(label + ": ") + " + grpc.proto_error_text(" + code + ")";
}

fn emit_check(b: builder.Str, indent: str, id: str, call: str, target: str, label: str) {
    b.write(indent + "let " + id + " = " + call + ";\n");
    b.write(indent + "guard let " + target + " = " + id + " else let code = err_of(" + id + ") { return err(" + err_text(label, "code") + "); }\n");
}

fn emit_decoder(b: builder.Str, m: MessageDesc, fields: [FieldDesc], reg: Registry) -> result[bool, str] {
    b.write("fn decode_" + m.slang_name + "_reader(reader: grpc.Reader) -> result[" + m.slang_name + ", str] {\n");
    b.write("    let out = new_" + m.slang_name + "();\n");
    b.write("    while true {\n");
    b.write("        let key_read = grpc.proto_reader_key(reader);\n");
    b.write("        guard let key = key_read else let code = err_of(key_read) { return err(" + err_text(m.slang_name + ": protobuf key", "code") + "); }\n");
    b.write("        if key == 0 { break; }\n");
    b.write("        let wire = key & 7;\n");
    b.write("        switch key >> 3 {\n");
    for i in 0..len(fields) {
        let f = fields[i];
        b.write("          case " + to_str(f.number) + " {\n");
        let fr = emit_decode_field(b, m, f, reg, "            ");
        guard let _fok = fr else let e = err_of(fr) { return err(e); }
        b.write("          }\n");
    }
    b.write("          default {\n");
    b.write("            let skipped = grpc.proto_reader_skip(reader, wire);\n");
    b.write("            guard let _skipped = skipped else let code = err_of(skipped) { return err(" + err_text(m.slang_name + ": unknown protobuf field", "code") + "); }\n");
    b.write("          }\n        }\n    }\n");
    b.write("    return ok(out);\n}\n\npub fn decode_" + m.slang_name + "(raw: bytes, limits: grpc.Limits) -> result[" + m.slang_name + ", str] {\n");
    b.write("    let reader_result = grpc.proto_reader(raw, limits);\n    guard let reader = reader_result else let e = err_of(reader_result) { return err(e); }\n");
    b.write("    return decode_" + m.slang_name + "_reader(reader);\n}\n\n");
    return ok(true);
}

fn emit_decode_field(b: builder.Str, owner: MessageDesc, f: FieldDesc, reg: Registry, indent: str) -> result[bool, str] {
    let name = safe_identifier(f.name);
    let label = owner.slang_name + "." + name;
    if let _mk = f.map_key {
        return emit_decode_map(b, owner, f, reg, indent);
    }
    if f.label == label_repeated() && is_packable(f.kind) {
        let id = "f" + to_str(f.number) + "_packed";
        b.write(indent + "if wire == grpc.PROTO_BYTES {\n");
        let inner = indent + "    ";
        emit_check(b, inner, id + "_read", "grpc.proto_reader_enter_packed(reader)", id + "_outer", label);
        b.write(inner + "while !grpc.proto_reader_done(reader) {\n");
        emit_check(b, inner + "    ", id + "_charged", "grpc.proto_reader_charge(reader)", "_" + id + "_charged", label);
        let vr = emit_read_value(b, label, f, reg, inner + "    ", "packed_value");
        guard let _vok = vr else let e = err_of(vr) { return err(e); }
        b.write(inner + "    push(out." + name + ", packed_value);\n" + inner + "}\n");
        emit_check(b, inner, id + "_left", "grpc.proto_reader_leave_packed(reader, " + id + "_outer)", "_" + id + "_left", label);
        b.write(indent + "} else {\n");
        b.write(inner + "if wire != " + wire_constant(f.kind) + " { return err(" + json.encode(label + ": wrong protobuf wire type") + "); }\n");
        let rv = emit_read_value(b, label, f, reg, inner, "field_value");
        guard let _rvok = rv else let e = err_of(rv) { return err(e); }
        b.write(inner + "push(out." + name + ", field_value);\n" + indent + "}\n");
        return ok(true);
    }
    b.write(indent + "if wire != " + wire_constant(f.kind) + " { return err(" + json.encode(label + ": wrong protobuf wire type") + "); }\n");
    let rv = emit_read_value(b, label, f, reg, indent, "field_value");
    guard let _rvok = rv else let e = err_of(rv) { return err(e); }
    if f.label == label_repeated() {
        b.write(indent + "push(out." + name + ", field_value);\n");
    } else if is_optional(f) {
        b.write(indent + "out." + name + " = some(field_value);\n");
    } else {
        b.write(indent + "out." + name + " = field_value;\n");
    }
    return ok(true);
}

fn emit_read_value(b: builder.Str, label: str, f: FieldDesc, reg: Registry, indent: str, target: str) -> result[bool, str] {
    let id = "f" + to_str(f.number) + "_" + target;
    let kind = value_kind(f);
    if kind == type_int32() || kind == type_int64() || kind == type_uint32() || kind == type_uint64() ||
       kind == type_sint32() || kind == type_sint64() || kind == type_bool() || kind == type_enum() {
        emit_check(b, indent, id + "_read", "grpc.proto_reader_varint(reader)", id + "_raw", label);
        let expr = "";
        if kind == type_int32() || kind == type_enum() {
            b.write(indent + "if !grpc.proto_int32_wire_valid(" + id + "_raw) { return err(" + json.encode(label + ": int32 varint is outside the valid wire range") + "); }\n");
            expr = "grpc.proto_int32_from_wire(" + id + "_raw)";
        } else if kind == type_int64() {
            expr = id + "_raw as int";
        } else if kind == type_uint32() {
            b.write(indent + "if " + id + "_raw > 4294967295 { return err(" + json.encode(label + ": uint32 value exceeds 4294967295") + "); }\n");
            expr = id + "_raw as u32";
        } else if kind == type_sint32() {
            b.write(indent + "if " + id + "_raw > 4294967295 { return err(" + json.encode(label + ": sint32 value exceeds 4294967295") + "); }\n");
            expr = "grpc.proto_sint32_from_wire(" + id + "_raw)";
        } else if kind == type_uint64() {
            expr = id + "_raw";
        } else if kind == type_sint64() {
            expr = "grpc.proto_sint64_from_wire(" + id + "_raw)";
        } else {
            expr = id + "_raw != 0";
        }
        b.write(indent + "let " + target + ": " + slang_base_type_for_kind(kind, f, reg) + " = " + expr + ";\n");
        return ok(true);
    }
    if kind == type_fixed32() || kind == type_sfixed32() || kind == type_float() {
        let fn_name = "proto_reader_fixed32";
        if kind == type_float() { fn_name = "proto_reader_float"; }
        emit_check(b, indent, id + "_read", "grpc." + fn_name + "(reader)", id + "_raw", label);
        let expr = id + "_raw";
        if kind == type_sfixed32() { expr = "(" + id + "_raw as i32) as int"; }
        b.write(indent + "let " + target + ": " + slang_base_type_for_kind(kind, f, reg) + " = " + expr + ";\n");
        return ok(true);
    }
    if kind == type_fixed64() || kind == type_sfixed64() || kind == type_double() {
        let fn_name = "proto_reader_fixed64";
        if kind == type_double() { fn_name = "proto_reader_double"; }
        emit_check(b, indent, id + "_read", "grpc." + fn_name + "(reader)", id + "_raw", label);
        let expr = id + "_raw";
        if kind == type_sfixed64() { expr = id + "_raw as int"; }
        b.write(indent + "let " + target + ": " + slang_base_type_for_kind(kind, f, reg) + " = " + expr + ";\n");
        return ok(true);
    }
    if kind == type_string() {
        emit_check(b, indent, id + "_read", "grpc.proto_reader_string_end(reader)", id + "_end", label);
        b.write(indent + "let " + target + " = grpc.proto_reader_take_string(reader, " + id + "_end);\n");
        return ok(true);
    }
    if kind == type_bytes() {
        emit_check(b, indent, id + "_read", "grpc.proto_reader_open(reader)", id + "_end", label);
        b.write(indent + "let " + target + " = grpc.proto_reader_take_bytes(reader, " + id + "_end);\n");
        return ok(true);
    }
    if kind == type_message() {
        let tname = type_name(f);
        if !has(reg.messages, tname) || reg.messages[tname].map_entry {
            return err(label + ": missing generated message descriptor " + tname);
        }
        let msg = reg.messages[tname];
        emit_check(b, indent, id + "_enter", "grpc.proto_reader_enter(reader)", id + "_outer", label);
        b.write(indent + "let " + id + "_result = decode_" + msg.slang_name + "_reader(reader);\n");
        b.write(indent + "guard let " + target + " = " + id + "_result else let e = err_of(" + id + "_result) { return err(" + json.encode(label + ": ") + " + e); }\n");
        emit_check(b, indent, id + "_leave", "grpc.proto_reader_leave(reader, " + id + "_outer)", "_" + id + "_left", label);
        return ok(true);
    }
    return err(label + ": unsupported protobuf field type " + to_str(kind));
}

fn emit_decode_map(b: builder.Str, owner: MessageDesc, f: FieldDesc, reg: Registry, indent: str) -> result[bool, str] {
    guard let mk = f.map_key else { return err("missing map key"); }
    guard let mv = f.map_value else { return err("missing map value"); }
    let name = safe_identifier(f.name);
    let id = "map_" + to_str(f.number);
    let label = owner.slang_name + "." + name;
    let entry_label = label + " map entry";
    b.write(indent + "if wire != grpc.PROTO_BYTES { return err(" + json.encode(label + ": wrong protobuf wire type") + "); }\n");
    emit_check(b, indent, id + "_enter", "grpc.proto_reader_enter(reader)", id + "_outer", label);
    let kr = slang_base_type(mk, reg);
    guard let key_type = kr else let e = err_of(kr) { return err(e); }
    let vr = slang_base_type(mv, reg);
    guard let value_type = vr else let e = err_of(vr) { return err(e); }
    b.write(indent + "let " + id + "_key: " + key_type + " = " + default_base_expr(mk, reg) + ";\n");
    b.write(indent + "let " + id + "_value: " + value_type + " = " + default_base_expr(mv, reg) + ";\n");
    b.write(indent + "while true {\n");
    let inner = indent + "    ";
    emit_check(b, inner, id + "_key_read", "grpc.proto_reader_key(reader)", id + "_k", entry_label);
    b.write(inner + "if " + id + "_k == 0 { break; }\n");
    b.write(inner + "switch " + id + "_k >> 3 {\n");
    let parts = [mk, mv];
    for i in 0..len(parts) {
        let part = parts[i];
        let target = id + "_key";
        if part.number == 2 { target = id + "_value"; }
        b.write(inner + "  case " + to_str(part.number) + " {\n");
        b.write(inner + "    if (" + id + "_k & 7) != " + wire_constant(part.kind) + " { return err(" + json.encode(entry_label + ": wrong map entry wire type") + "); }\n");
        let rr = emit_read_value(b, entry_label, part, reg, inner + "    ", target + "_read");
        guard let _rok = rr else let e = err_of(rr) { return err(e); }
        b.write(inner + "    " + target + " = " + target + "_read;\n" + inner + "  }\n");
    }
    b.write(inner + "  default {\n");
    emit_check(b, inner + "    ", id + "_skip", "grpc.proto_reader_skip(reader, " + id + "_k & 7)", "_" + id + "_skipped", entry_label);
    b.write(inner + "  }\n" + inner + "}\n" + indent + "}\n");
    emit_check(b, indent, id + "_leave", "grpc.proto_reader_leave(reader, " + id + "_outer)", "_" + id + "_left", label);
    b.write(indent + "out." + name + "[" + id + "_key] = " + id + "_value;\n");
    return ok(true);
}

fn emit_encoder(b: builder.Str, m: MessageDesc, fields: [FieldDesc], reg: Registry) -> result[bool, str] {
    b.write("pub fn encode_" + m.slang_name + "(value: " + m.slang_name + ", limits: grpc.Limits) -> result[bytes, str] {\n");
    b.write("    if !grpc.proto_limits_valid(limits) { return err(\"grpc.proto writer: invalid limits\"); }\n");
    b.write("    let size = size_" + m.slang_name + "(value);\n");
    b.write("    if size < 0 { return err(check_" + m.slang_name + "(value)); }\n");
    b.write("    if size > limits.max_message_bytes { return err(\"grpc.proto writer: message exceeds configured byte limit\"); }\n");
    b.write("    let writer = grpc.proto_writer();\n");
    b.write("    write_" + m.slang_name + "(writer, value);\n");
    b.write("    return ok(grpc.proto_writer_finish(writer));\n}\n\n");

    b.write("fn size_" + m.slang_name + "(value: " + m.slang_name + ") -> int {\n    let n = 0;\n");
    for i in 0..len(fields) {
        let sr = emit_size_field(b, m, fields[i], reg);
        guard let _sok = sr else let e = err_of(sr) { return err(e); }
    }
    b.write("    return n;\n}\n\n");

    b.write("fn write_" + m.slang_name + "(w: grpc.Writer, value: " + m.slang_name + ") {\n");
    for i in 0..len(fields) {
        let wr = emit_write_field(b, m, fields[i], reg);
        guard let _wok = wr else let e = err_of(wr) { return err(e); }
    }
    b.write("}\n\n");

    b.write("fn check_" + m.slang_name + "(value: " + m.slang_name + ") -> str {\n");
    for i in 0..len(fields) {
        let cr = emit_check_field(b, m, fields[i], reg);
        guard let _cok = cr else let e = err_of(cr) { return err(e); }
    }
    b.write("    return \"\";\n}\n\n");
    return ok(true);
}

fn value_kind(f: FieldDesc) -> int {
    if let mv = f.map_value {
        return mv.kind;
    }
    return f.kind;
}

fn is_int32_kind(kind: int) -> bool {
    return kind == type_int32() || kind == type_sint32() || kind == type_sfixed32() || kind == type_enum();
}

fn key_size(field: int, wire: int) -> int {
    let v = ((field as u64) << (3 as u64)) | (wire as u64);
    let n = 1;
    while v > (127 as u64) {
        v = v >> (7 as u64);
        n = n + 1;
    }
    return n;
}

fn size_expr(kind: int, v: str) -> str {
    if kind == type_int32() || kind == type_enum() {
        return "grpc.proto_size_varint(grpc.proto_int32_to_wire(" + v + "))";
    }
    if kind == type_int64() || kind == type_uint32() {
        return "grpc.proto_size_varint(" + v + " as u64)";
    }
    if kind == type_uint64() {
        return "grpc.proto_size_varint(" + v + ")";
    }
    if kind == type_sint32() {
        return "grpc.proto_size_varint(grpc.proto_sint32_to_wire(" + v + "))";
    }
    if kind == type_sint64() {
        return "grpc.proto_size_varint(grpc.proto_sint64_to_wire(" + v + "))";
    }
    if kind == type_bool() { return "1"; }
    if kind == type_fixed32() || kind == type_sfixed32() || kind == type_float() { return "4"; }
    if kind == type_fixed64() || kind == type_sfixed64() || kind == type_double() { return "8"; }
    if kind == type_string() || kind == type_bytes() {
        return "grpc.proto_size_delimited(len(" + v + "))";
    }
    return "";
}

fn emit_size_value(b: builder.Str, f: FieldDesc, kind: int, v: str, acc: str, indent: str, checked: bool, reg: Registry) -> result[bool, str] {
    if checked && is_int32_kind(kind) {
        b.write(indent + "if !grpc.proto_int32_in_range(" + v + ") { return -1; }\n");
    }
    if kind == type_message() {
        let tname = type_name(f);
        if !has(reg.messages, tname) {
            return err(f.name + ": message descriptor missing");
        }
        let msg = reg.messages[tname];
        let id = "size_" + to_str(f.number);
        b.write(indent + "let " + id + " = size_" + msg.slang_name + "(" + v + ");\n");
        if checked {
            b.write(indent + "if " + id + " < 0 { return -1; }\n");
        }
        b.write(indent + acc + " = " + acc + " + grpc.proto_size_delimited(" + id + ");\n");
        return ok(true);
    }
    let expr = size_expr(kind, v);
    if len(expr) == 0 {
        return err(f.name + ": unsupported protobuf writer field kind " + to_str(kind));
    }
    b.write(indent + acc + " = " + acc + " + " + expr + ";\n");
    return ok(true);
}

fn emit_size_field(b: builder.Str, m: MessageDesc, f: FieldDesc, reg: Registry) -> result[bool, str] {
    let name = safe_identifier(f.name);
    if let _mk = f.map_key {
        return emit_size_map(b, f, reg);
    }
    if f.label == label_repeated() {
        if is_packable(f.kind) && packed_by_default(f) {
            b.write("    if len(value." + name + ") > 0 {\n        let packed = 0;\n        for item in value." + name + " {\n");
            let sr = emit_size_value(b, f, f.kind, "item", "packed", "            ", true, reg);
            guard let _sok = sr else let e = err_of(sr) { return err(e); }
            b.write("        }\n        n = n + " + to_str(key_size(f.number, 2)) + " + grpc.proto_size_delimited(packed);\n    }\n");
            return ok(true);
        }
        b.write("    for item in value." + name + " {\n        n = n + " + to_str(key_size(f.number, expected_wire(f.kind))) + ";\n");
        let sr = emit_size_value(b, f, f.kind, "item", "n", "        ", true, reg);
        guard let _sok = sr else let e = err_of(sr) { return err(e); }
        b.write("    }\n");
        return ok(true);
    }
    if is_optional(f) {
        b.write("    if let item = value." + name + " {\n        n = n + " + to_str(key_size(f.number, expected_wire(f.kind))) + ";\n");
        let sr = emit_size_value(b, f, f.kind, "item", "n", "        ", true, reg);
        guard let _sok = sr else let e = err_of(sr) { return err(e); }
        b.write("    }\n");
        return ok(true);
    }
    b.write("    if value." + name + " != " + zero_expr(f.kind) + " {\n        n = n + " + to_str(key_size(f.number, expected_wire(f.kind))) + ";\n");
    let sr = emit_size_value(b, f, f.kind, "value." + name, "n", "        ", true, reg);
    guard let _sok = sr else let e = err_of(sr) { return err(e); }
    b.write("    }\n");
    return ok(true);
}

fn emit_entry_size(b: builder.Str, f: FieldDesc, reg: Registry, indent: str, checked: bool) -> result[bool, str] {
    guard let key = f.map_key else { return err("missing map key"); }
    guard let value = f.map_value else { return err("missing map value"); }
    b.write(indent + "let entry = 0;\n");
    b.write(indent + "if map_key != " + zero_expr(key.kind) + " {\n" + indent + "    entry = entry + " + to_str(key_size(1, expected_wire(key.kind))) + ";\n");
    let kr = emit_size_value(b, key, key.kind, "map_key", "entry", indent + "    ", checked, reg);
    guard let _kok = kr else let e = err_of(kr) { return err(e); }
    b.write(indent + "}\n");
    if value.kind == type_message() {
        b.write(indent + "entry = entry + " + to_str(key_size(2, 2)) + ";\n");
        return emit_size_value(b, f, value.kind, "map_value", "entry", indent, checked, reg);
    }
    b.write(indent + "if map_value != " + zero_expr(value.kind) + " {\n" + indent + "    entry = entry + " + to_str(key_size(2, expected_wire(value.kind))) + ";\n");
    let vr = emit_size_value(b, value, value.kind, "map_value", "entry", indent + "    ", checked, reg);
    guard let _vok = vr else let e = err_of(vr) { return err(e); }
    b.write(indent + "}\n");
    return ok(true);
}

fn emit_size_map(b: builder.Str, f: FieldDesc, reg: Registry) -> result[bool, str] {
    b.write("    for map_key, map_value in value." + safe_identifier(f.name) + " {\n");
    let er = emit_entry_size(b, f, reg, "        ", true);
    guard let _eok = er else let e = err_of(er) { return err(e); }
    b.write("        n = n + " + to_str(key_size(f.number, 2)) + " + grpc.proto_size_delimited(entry);\n    }\n");
    return ok(true);
}

fn emit_write_value(b: builder.Str, f: FieldDesc, kind: int, v: str, indent: str, reg: Registry) -> result[bool, str] {
    let call = "";
    if kind == type_int32() || kind == type_enum() {
        call = "grpc.proto_write_varint(w, grpc.proto_int32_to_wire(" + v + "))";
    } else if kind == type_int64() || kind == type_uint32() {
        call = "grpc.proto_write_varint(w, " + v + " as u64)";
    } else if kind == type_uint64() {
        call = "grpc.proto_write_varint(w, " + v + ")";
    } else if kind == type_sint32() {
        call = "grpc.proto_write_varint(w, grpc.proto_sint32_to_wire(" + v + "))";
    } else if kind == type_sint64() {
        call = "grpc.proto_write_varint(w, grpc.proto_sint64_to_wire(" + v + "))";
    } else if kind == type_bool() {
        call = "grpc.proto_write_bool(w, " + v + ")";
    } else if kind == type_fixed32() {
        call = "grpc.proto_write_fixed32(w, " + v + ")";
    } else if kind == type_sfixed32() {
        call = "grpc.proto_write_fixed32(w, " + v + " as u32)";
    } else if kind == type_float() {
        call = "grpc.proto_write_float(w, " + v + ")";
    } else if kind == type_fixed64() {
        call = "grpc.proto_write_fixed64(w, " + v + ")";
    } else if kind == type_sfixed64() {
        call = "grpc.proto_write_fixed64(w, " + v + " as u64)";
    } else if kind == type_double() {
        call = "grpc.proto_write_double(w, " + v + ")";
    } else if kind == type_string() {
        call = "grpc.proto_write_string(w, " + v + ")";
    } else if kind == type_bytes() {
        call = "grpc.proto_write_bytes(w, " + v + ")";
    } else if kind == type_message() {
        let tname = type_name(f);
        if !has(reg.messages, tname) {
            return err(f.name + ": message descriptor missing");
        }
        let msg = reg.messages[tname];
        b.write(indent + "grpc.proto_write_varint(w, size_" + msg.slang_name + "(" + v + ") as u64);\n");
        call = "write_" + msg.slang_name + "(w, " + v + ")";
    } else {
        return err(f.name + ": unsupported protobuf writer field kind " + to_str(kind));
    }
    b.write(indent + call + ";\n");
    return ok(true);
}

fn emit_write_key(b: builder.Str, field: int, wire: int, indent: str) {
    let k = ((field as u64) << (3 as u64)) | (wire as u64);
    b.write(indent + "grpc.proto_write_varint(w, " + to_str(k) + ");\n");
}

fn emit_write_field(b: builder.Str, m: MessageDesc, f: FieldDesc, reg: Registry) -> result[bool, str] {
    let name = safe_identifier(f.name);
    if let _mk = f.map_key {
        return emit_write_map(b, f, reg);
    }
    if f.label == label_repeated() {
        if is_packable(f.kind) && packed_by_default(f) {
            b.write("    if len(value." + name + ") > 0 {\n        let packed = 0;\n        for item in value." + name + " {\n");
            let sr = emit_size_value(b, f, f.kind, "item", "packed", "            ", false, reg);
            guard let _sok = sr else let e = err_of(sr) { return err(e); }
            b.write("        }\n");
            emit_write_key(b, f.number, 2, "        ");
            b.write("        grpc.proto_write_varint(w, packed as u64);\n");
            b.write("        for item in value." + name + " {\n");
            let wr = emit_write_value(b, f, f.kind, "item", "            ", reg);
            guard let _wok = wr else let e = err_of(wr) { return err(e); }
            b.write("        }\n    }\n");
            return ok(true);
        }
        b.write("    for item in value." + name + " {\n");
        emit_write_key(b, f.number, expected_wire(f.kind), "        ");
        let wr = emit_write_value(b, f, f.kind, "item", "        ", reg);
        guard let _wok = wr else let e = err_of(wr) { return err(e); }
        b.write("    }\n");
        return ok(true);
    }
    if is_optional(f) {
        b.write("    if let item = value." + name + " {\n");
        emit_write_key(b, f.number, expected_wire(f.kind), "        ");
        let wr = emit_write_value(b, f, f.kind, "item", "        ", reg);
        guard let _wok = wr else let e = err_of(wr) { return err(e); }
        b.write("    }\n");
        return ok(true);
    }
    b.write("    if value." + name + " != " + zero_expr(f.kind) + " {\n");
    emit_write_key(b, f.number, expected_wire(f.kind), "        ");
    let wr = emit_write_value(b, f, f.kind, "value." + name, "        ", reg);
    guard let _wok = wr else let e = err_of(wr) { return err(e); }
    b.write("    }\n");
    return ok(true);
}

fn emit_write_map(b: builder.Str, f: FieldDesc, reg: Registry) -> result[bool, str] {
    guard let key = f.map_key else { return err("missing map key"); }
    guard let value = f.map_value else { return err("missing map value"); }
    b.write("    for map_key, map_value in value." + safe_identifier(f.name) + " {\n");
    let er = emit_entry_size(b, f, reg, "        ", false);
    guard let _eok = er else let e = err_of(er) { return err(e); }
    emit_write_key(b, f.number, 2, "        ");
    b.write("        grpc.proto_write_varint(w, entry as u64);\n");
    b.write("        if map_key != " + zero_expr(key.kind) + " {\n");
    emit_write_key(b, 1, expected_wire(key.kind), "            ");
    let kw = emit_write_value(b, key, key.kind, "map_key", "            ", reg);
    guard let _kok = kw else let e = err_of(kw) { return err(e); }
    b.write("        }\n");
    if value.kind == type_message() {
        emit_write_key(b, 2, 2, "        ");
        let vw = emit_write_value(b, f, value.kind, "map_value", "        ", reg);
        guard let _vok = vw else let e = err_of(vw) { return err(e); }
    } else {
        b.write("        if map_value != " + zero_expr(value.kind) + " {\n");
        emit_write_key(b, 2, expected_wire(value.kind), "            ");
        let vw = emit_write_value(b, value, value.kind, "map_value", "            ", reg);
        guard let _vok = vw else let e = err_of(vw) { return err(e); }
        b.write("        }\n");
    }
    b.write("    }\n");
    return ok(true);
}

fn emit_check_value(b: builder.Str, f: FieldDesc, kind: int, v: str, label: str, indent: str, reg: Registry) {
    if is_int32_kind(kind) {
        b.write(indent + "if !grpc.proto_int32_in_range(" + v + ") { return " + json.encode(label + ": value is outside int32 range") + "; }\n");
    }
    if kind == type_message() {
        let tname = type_name(f);
        if has(reg.messages, tname) {
            let msg = reg.messages[tname];
            let id = "check_" + to_str(f.number);
            b.write(indent + "let " + id + " = check_" + msg.slang_name + "(" + v + ");\n");
            b.write(indent + "if " + id + " != \"\" { return " + json.encode(label + ": ") + " + " + id + "; }\n");
        }
    }
}

fn emit_check_field(b: builder.Str, m: MessageDesc, f: FieldDesc, reg: Registry) -> result[bool, str] {
    let name = safe_identifier(f.name);
    let label = m.slang_name + "." + name;
    if let mk = f.map_key {
        guard let mv = f.map_value else { return ok(true); }
        if !is_int32_kind(mk.kind) && !is_int32_kind(mv.kind) && mv.kind != type_message() {
            return ok(true);
        }
        b.write("    for map_key, map_value in value." + name + " {\n");
        emit_check_value(b, mk, mk.kind, "map_key", label + " map key", "        ", reg);
        if mv.kind == type_message() {
            emit_check_value(b, f, type_message(), "map_value", label + " map value", "        ", reg);
        } else {
            emit_check_value(b, mv, mv.kind, "map_value", label + " map value", "        ", reg);
        }
        b.write("    }\n");
        return ok(true);
    }
    if !is_int32_kind(f.kind) && f.kind != type_message() {
        return ok(true);
    }
    if f.label == label_repeated() {
        b.write("    for item in value." + name + " {\n");
        emit_check_value(b, f, f.kind, "item", label, "        ", reg);
        b.write("    }\n");
        return ok(true);
    }
    if is_optional(f) {
        b.write("    if let item = value." + name + " {\n");
        emit_check_value(b, f, f.kind, "item", label, "        ", reg);
        b.write("    }\n");
        return ok(true);
    }
    emit_check_value(b, f, f.kind, "value." + name, label, "    ", reg);
    return ok(true);
}

fn emit_service(b: builder.Str, file: FileDesc, service: ServiceDesc, reg: Registry) -> result[bool, str] {
    for i in 0..len(service.methods) {
        let method = service.methods[i];
        if method.client_stream || method.server_stream {
            return err(service.name + "." + method.name + ": streaming RPCs are not supported in v1; use a unary method");
        }
        if !has(reg.messages, method.input_type) || !has(reg.messages, method.output_type) {
            return err(service.name + "." + method.name + ": request and response .proto files must be generated in the same invocation");
        }
        let prefix = "";
        if len(file.pkg) > 0 {
            prefix = strings.replace(file.pkg, ".", "_") + "_";
        }
        let name = strings.to_upper(safe_identifier(prefix + service.name + "_" + method.name));
        let full_service = service.name;
        if len(file.pkg) > 0 {
            full_service = file.pkg + "." + service.name;
        }
        b.write("pub let " + name + "_PATH = " + json.encode("/" + full_service + "/" + method.name) + ";\n");
    }
    if len(service.methods) > 0 {
        b.write("\n");
    }
    return ok(true);
}

fn slang_field_type(f: FieldDesc, reg: Registry) -> result[str, str] {
    if let mk = f.map_key {
        let kr = slang_base_type(mk, reg);
        guard let key = kr else let e = err_of(kr) { return err(e); }
        guard let mv = f.map_value else { return err("missing map value"); }
        let vr = slang_base_type(mv, reg);
        guard let value = vr else let e = err_of(vr) { return err(e); }
        return ok("map[" + key + "]" + value);
    }
    let br = slang_base_type(f, reg);
    guard let base = br else let e = err_of(br) { return err(e); }
    if f.label == label_repeated() {
        return ok("[" + base + "]");
    }
    if is_optional(f) {
        return ok("opt[" + base + "]");
    }
    return ok(base);
}

fn slang_base_type(f: FieldDesc, reg: Registry) -> result[str, str] {
    let kind = value_kind(f);
    if kind == type_double() || kind == type_float() { return ok("float"); }
    if kind == type_int64() || kind == type_int32() || kind == type_sint32() ||
       kind == type_sint64() || kind == type_sfixed32() || kind == type_sfixed64() ||
       kind == type_enum() {
        return ok("int");
    }
    if kind == type_uint32() || kind == type_fixed32() { return ok("u32"); }
    if kind == type_uint64() || kind == type_fixed64() { return ok("u64"); }
    if kind == type_bool() { return ok("bool"); }
    if kind == type_string() { return ok("str"); }
    if kind == type_bytes() { return ok("bytes"); }
    if kind == type_message() {
        let tname = type_name(f);
        if !has(reg.messages, tname) || reg.messages[tname].map_entry {
            return err("message type " + tname + " is not generated");
        }
        return ok(reg.messages[tname].slang_name);
    }
    return err("unsupported protobuf field type " + to_str(kind));
}

fn slang_base_type_for_kind(kind: int, f: FieldDesc, reg: Registry) -> str {
    let tmp = FieldDesc {
        name: f.name,
        type_name: type_name(f),
        number: f.number,
        label: f.label,
        kind: kind,
        oneof_index: f.oneof_index,
        proto3_optional: f.proto3_optional,
        has_packed: false,
        packed: false,
        map_key: none,
        map_value: none
    };
    let br = slang_base_type(tmp, reg);
    guard let s = br else { return ""; }
    return s;
}

fn type_name(f: FieldDesc) -> str {
    if let mv = f.map_value {
        return mv.type_name;
    }
    return f.type_name;
}

fn is_optional(f: FieldDesc) -> bool {
    return f.label != label_repeated() && (f.proto3_optional || f.kind == type_message());
}

fn is_packable(kind: int) -> bool {
    return kind != type_string() && kind != type_bytes() && kind != type_message() && kind != type_group();
}

fn packed_by_default(f: FieldDesc) -> bool {
    return !f.has_packed || f.packed;
}

fn expected_wire(kind: int) -> int {
    if kind == type_double() || kind == type_fixed64() || kind == type_sfixed64() { return 1; }
    if kind == type_string() || kind == type_bytes() || kind == type_message() { return 2; }
    if kind == type_float() || kind == type_fixed32() || kind == type_sfixed32() { return 5; }
    return 0;
}

fn wire_constant(kind: int) -> str {
    return wire_const_value(expected_wire(kind));
}

fn wire_const_value(wire: int) -> str {
    if wire == 0 { return "grpc.PROTO_VARINT"; }
    if wire == 1 { return "grpc.PROTO_FIXED64"; }
    if wire == 2 { return "grpc.PROTO_BYTES"; }
    if wire == 5 { return "grpc.PROTO_FIXED32"; }
    return "-1";
}

fn default_expr(f: FieldDesc, reg: Registry) -> str {
    if let _mk = f.map_key { return "{}"; }
    if f.label == label_repeated() { return "[]"; }
    if is_optional(f) { return "none"; }
    return default_base_expr(f, reg);
}

fn default_base_expr(f: FieldDesc, reg: Registry) -> str {
    let kind = value_kind(f);
    if kind == type_bool() { return "false"; }
    if kind == type_float() || kind == type_double() { return "0.0"; }
    if kind == type_string() { return "\"\""; }
    if kind == type_bytes() { return "b\"\""; }
    if kind == type_message() {
        let tname = type_name(f);
        if has(reg.messages, tname) {
            return "new_" + reg.messages[tname].slang_name + "()";
        }
    }
    return "0";
}

fn zero_expr(kind: int) -> str {
    if kind == type_bool() { return "false"; }
    if kind == type_float() || kind == type_double() { return "0.0"; }
    if kind == type_string() { return "\"\""; }
    if kind == type_bytes() { return "b\"\""; }
    return "0";
}
