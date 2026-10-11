package main

import (
	"fmt"
	"path"
	"sort"
	"strconv"
	"strings"
	"unicode"
)

type registry struct {
	messages map[string]*messageDesc
	enums    map[string]*enumDesc
	byName   map[string]string
}

func generate(requested []string, files []*fileDesc) ([]generatedFile, error) {
	fileByName := make(map[string]*fileDesc, len(files))
	reg := registry{messages: map[string]*messageDesc{}, enums: map[string]*enumDesc{}, byName: map[string]string{}}
	for _, file := range files {
		clean := path.Clean(file.name)
		control := strings.IndexFunc(file.name, unicode.IsControl) >= 0
		if file.name == "" || path.IsAbs(file.name) || clean == ".." ||
			strings.HasPrefix(clean, "../") || clean != file.name ||
			!strings.HasSuffix(file.name, ".proto") || strings.Contains(file.name, "\\") || control {
			return nil, fmt.Errorf("proto file name %q is not a safe relative path", file.name)
		}
		if fileByName[file.name] != nil {
			return nil, fmt.Errorf("protoc supplied duplicate descriptor for %q", file.name)
		}
		fileByName[file.name] = file
		for _, m := range file.messages {
			if err := collectMessage(&reg, m); err != nil {
				return nil, err
			}
		}
		for _, e := range file.enums {
			if err := addEnum(&reg, e); err != nil {
				return nil, err
			}
		}
	}
	requestedSet := make(map[string]bool, len(requested))
	var packageName string
	for _, name := range requested {
		if requestedSet[name] {
			return nil, fmt.Errorf("protoc requested %q more than once", name)
		}
		f := fileByName[name]
		if f == nil {
			return nil, fmt.Errorf("protoc requested %q but omitted its descriptor", name)
		}
		if f.syntax != "proto3" {
			return nil, fmt.Errorf("%s: only proto3 syntax is supported; set `syntax = \"proto3\";`", name)
		}
		if packageName == "" {
			packageName = f.pkg
		} else if packageName != f.pkg {
			return nil, fmt.Errorf("input files use different proto packages (%q and %q); generate one package per invocation", packageName, f.pkg)
		}
		requestedSet[name] = true
	}
	if err := validateRegistry(&reg, requestedSet, fileByName); err != nil {
		return nil, err
	}
	out := make([]generatedFile, 0, len(requested))
	for _, name := range requested {
		content, err := generateFile(fileByName[name], &reg)
		if err != nil {
			return nil, err
		}
		out = append(out, generatedFile{name: outputName(name), content: content})
	}
	return out, nil
}

func collectMessage(reg *registry, m *messageDesc) error {
	if err := addMessage(reg, m); err != nil {
		return err
	}
	for _, e := range m.enums {
		if err := addEnum(reg, e); err != nil {
			return err
		}
	}
	for _, child := range m.nested {
		if err := collectMessage(reg, child); err != nil {
			return err
		}
	}
	return nil
}

func addMessage(reg *registry, m *messageDesc) error {
	if m.mapEntry {
		reg.messages[m.fullName] = m
		return nil
	}
	if prev, ok := reg.byName[m.slangName]; ok && prev != m.fullName {
		return fmt.Errorf("proto types %s and %s both map to Slang name %s; rename one declaration", prev, m.fullName, m.slangName)
	}
	reg.byName[m.slangName] = m.fullName
	reg.messages[m.fullName] = m
	return nil
}

func addEnum(reg *registry, e *enumDesc) error {
	if prev, ok := reg.byName[e.slangName]; ok && prev != e.fullName {
		return fmt.Errorf("proto types %s and %s both map to Slang name %s; rename one declaration", prev, e.fullName, e.slangName)
	}
	reg.byName[e.slangName] = e.fullName
	reg.enums[e.fullName] = e
	return nil
}

func validateRegistry(reg *registry, requested map[string]bool, files map[string]*fileDesc) error {
	for _, m := range reg.messages {
		if m.mapEntry {
			continue
		}
		seenNumber, seenName := map[int]bool{}, map[string]bool{}
		for _, f := range m.fields {
			if seenNumber[f.number] || seenName[safeIdentifier(f.name)] {
				return fmt.Errorf("%s: duplicate or colliding field %q", m.fullName, f.name)
			}
			seenNumber[f.number], seenName[safeIdentifier(f.name)] = true, true
			if f.label == labelRequired {
				return fmt.Errorf("%s.%s: proto2 required fields are unsupported", m.fullName, f.name)
			}
			if f.oneofIndex >= 0 && !f.proto3Optional {
				return fmt.Errorf("%s.%s: oneof fields are unsupported in v1; use proto3 optional or separate fields", m.fullName, f.name)
			}
			if f.mapKey != nil {
				if _, err := slangBaseType(f.mapKey, reg); err != nil {
					return fmt.Errorf("%s.%s map key: %w", m.fullName, f.name, err)
				}
				if _, err := slangBaseType(f.mapValue, reg); err != nil {
					return fmt.Errorf("%s.%s map value: %w", m.fullName, f.name, err)
				}
				continue
			}
			if f.kind == typeMessage || f.kind == typeEnum {
				if f.typeName == "" {
					return fmt.Errorf("%s.%s: missing message or enum type name", m.fullName, f.name)
				}
				if f.kind == typeMessage {
					ref := reg.messages[f.typeName]
					if ref == nil {
						return fmt.Errorf("%s.%s: message type %s is not included; add its .proto file to protoc inputs", m.fullName, f.name, f.typeName)
					}
					if !ref.mapEntry {
						if fileForType(ref.fullName, files) != "" && !requested[fileForType(ref.fullName, files)] {
							return fmt.Errorf("%s.%s: generate the referenced %s.proto file in the same `protoc --slang_out` invocation", m.fullName, f.name, strings.TrimSuffix(fileForType(ref.fullName, files), ".proto"))
						}
					}
					if ref.mapEntry {
						if f.label != labelRepeated {
							return fmt.Errorf("%s.%s: map entry field is not repeated", m.fullName, f.name)
						}
						if err := attachMap(f, ref); err != nil {
							return fmt.Errorf("%s.%s: %w", m.fullName, f.name, err)
						}
						continue
					}
				} else if reg.enums[f.typeName] == nil {
					return fmt.Errorf("%s.%s: enum type %s is not included; add its .proto file to protoc inputs", m.fullName, f.name, f.typeName)
				}
			}
			if _, err := slangBaseType(f, reg); err != nil {
				return fmt.Errorf("%s.%s: %w", m.fullName, f.name, err)
			}
		}
	}
	return nil
}

func fileForType(full string, files map[string]*fileDesc) string {
	for name, f := range files {
		prefix := f.pkg
		if prefix != "" {
			prefix += "."
		}
		if strings.HasPrefix(full, prefix) {
			return name
		}
	}
	return ""
}

func attachMap(field *fieldDesc, entry *messageDesc) error {
	var key, value *fieldDesc
	for _, f := range entry.fields {
		if f.number == 1 {
			key = f
		}
		if f.number == 2 {
			value = f
		}
	}
	if key == nil || value == nil || len(entry.fields) != 2 {
		return fmt.Errorf("map entry must contain exactly key field 1 and value field 2")
	}
	if key.kind == typeMessage || key.kind == typeEnum || key.kind == typeBytes || key.kind == typeFloat || key.kind == typeDouble {
		return fmt.Errorf("unsupported protobuf map key type")
	}
	field.mapKey, field.mapValue = key, value
	return nil
}

func generateFile(file *fileDesc, reg *registry) (string, error) {
	var b strings.Builder
	fmt.Fprintf(&b, "// Code generated by protoc-gen-slang. DO NOT EDIT.\n")
	fmt.Fprintf(&b, "// Source: %s\n\nimport \"grpc\";\n\n", strconv.Quote(file.name))
	for _, e := range file.enums {
		if err := emitEnum(&b, e); err != nil {
			return "", err
		}
	}
	for _, m := range file.messages {
		if err := emitMessageTree(&b, m, reg); err != nil {
			return "", err
		}
	}
	for _, service := range file.services {
		if err := emitService(&b, file, service, reg); err != nil {
			return "", err
		}
	}
	return strings.TrimRight(b.String(), "\n") + "\n", nil
}

func emitMessageTree(b *strings.Builder, m *messageDesc, reg *registry) error {
	if !m.mapEntry {
		for _, e := range m.enums {
			if err := emitEnum(b, e); err != nil {
				return err
			}
		}
		if err := emitMessage(b, m, reg); err != nil {
			return err
		}
	}
	for _, child := range m.nested {
		if err := emitMessageTree(b, child, reg); err != nil {
			return err
		}
	}
	return nil
}

func emitEnum(b *strings.Builder, e *enumDesc) error {
	for _, v := range e.values {
		if v.number < -2147483648 || v.number > 2147483647 {
			return fmt.Errorf("%s.%s: enum number is outside int32 range", e.fullName, v.name)
		}
		fmt.Fprintf(b, "pub let %s_%s = %d;\n", e.slangName, safeIdentifier(v.name), v.number)
	}
	b.WriteByte('\n')
	return nil
}

func emitMessage(b *strings.Builder, m *messageDesc, reg *registry) error {
	fields := append([]*fieldDesc(nil), m.fields...)
	sort.Slice(fields, func(i, j int) bool { return fields[i].number < fields[j].number })
	fmt.Fprintf(b, "pub struct %s {\n", m.slangName)
	if len(fields) == 0 {
		// slang does not support constructing an empty struct value. The marker
		// is never encoded and keeps an empty protobuf message an ordinary type.
		b.WriteString("    _protobuf_empty: bool,\n")
	}
	for _, f := range fields {
		t, err := slangFieldType(f, reg)
		if err != nil {
			return fmt.Errorf("%s.%s: %w", m.fullName, f.name, err)
		}
		fmt.Fprintf(b, "    %s: %s,\n", safeIdentifier(f.name), t)
	}
	b.WriteString("}\n\n")
	fmt.Fprintf(b, "pub fn new_%s() -> %s {\n    return %s {\n", m.slangName, m.slangName, m.slangName)
	if len(fields) == 0 {
		b.WriteString("        _protobuf_empty: false\n")
	}
	for i, f := range fields {
		comma := ","
		if i == len(fields)-1 {
			comma = ""
		}
		fmt.Fprintf(b, "        %s: %s%s\n", safeIdentifier(f.name), defaultExpr(f, reg), comma)
	}
	b.WriteString("    };\n}\n\n")
	if err := emitDecoder(b, m, fields, reg); err != nil {
		return err
	}
	if err := emitEncoder(b, m, fields, reg); err != nil {
		return err
	}
	return nil
}

func emitDecoder(b *strings.Builder, m *messageDesc, fields []*fieldDesc, reg *registry) error {
	fmt.Fprintf(b, "fn decode_%s_reader(reader: grpc.Reader) -> result[%s, str] {\n", m.slangName, m.slangName)
	fmt.Fprintf(b, "    let out = new_%s();\n", m.slangName)
	b.WriteString("    while true {\n        let tag_result = grpc.proto_reader_tag(reader);\n        guard let tag_opt = tag_result else let e = err_of(tag_result) { return err(\"protobuf tag: \" + e); }\n        guard let tag = tag_opt else { break; }\n        switch tag.field_number {\n")
	for _, f := range fields {
		fmt.Fprintf(b, "          case %d {\n", f.number)
		if err := emitDecodeField(b, m, f, reg, "            "); err != nil {
			return err
		}
		b.WriteString("          }\n")
	}
	b.WriteString("          default {\n            let skipped = grpc.proto_reader_skip(reader, tag.wire_type);\n            guard let _skip = skipped else let e = err_of(skipped) { return err(\"unknown protobuf field: \" + e); }\n          }\n        }\n    }\n")
	b.WriteString("    if !grpc.proto_reader_done(reader) { return err(\"protobuf submessage was not fully consumed\"); }\n")
	fmt.Fprintf(b, "    return ok(out);\n}\n\npub fn decode_%s(raw: bytes, limits: grpc.Limits) -> result[%s, str] {\n", m.slangName, m.slangName)
	b.WriteString("    let reader_result = grpc.proto_reader(raw, limits);\n    guard let reader = reader_result else let e = err_of(reader_result) { return err(e); }\n")
	fmt.Fprintf(b, "    return decode_%s_reader(reader);\n}\n\n", m.slangName)
	return nil
}

func emitDecodeField(b *strings.Builder, owner *messageDesc, f *fieldDesc, reg *registry, indent string) error {
	name := safeIdentifier(f.name)
	if f.mapKey != nil {
		return emitDecodeMap(b, owner, f, reg, indent)
	}
	if f.label == labelRepeated && isPackable(f.kind) {
		fmt.Fprintf(b, "%sif tag.wire_type == grpc.PROTO_BYTES {\n", indent)
		fmt.Fprintf(b, "%s    let packed_result = grpc.proto_reader_packed(reader);\n%s    guard let packed = packed_result else let e = err_of(packed_result) { return err(\"%s.%s: \" + e); }\n", indent, indent, owner.slangName, name)
		fmt.Fprintf(b, "%s    while !grpc.proto_reader_done(packed) {\n", indent)
		fmt.Fprintf(b, "%s        let charged = grpc.proto_reader_charge(packed);\n%s        guard let _charged = charged else let e = err_of(charged) { return err(\"%s.%s: \" + e); }\n", indent, indent, owner.slangName, name)
		if err := emitReadValue(b, owner.slangName+"."+name, f, reg, "packed", indent+"        ", "packed_value"); err != nil {
			return err
		}
		fmt.Fprintf(b, "%s        push(out.%s, packed_value);\n%s    }\n%s} else {\n", indent, name, indent, indent)
		fmt.Fprintf(b, "%s    if tag.wire_type != %s { return err(\"%s.%s: wrong protobuf wire type\"); }\n", indent, wireConstant(f.kind), owner.slangName, name)
		if err := emitReadValue(b, owner.slangName+"."+name, f, reg, "reader", indent+"    ", "field_value"); err != nil {
			return err
		}
		fmt.Fprintf(b, "%s    push(out.%s, field_value);\n%s}\n", indent, name, indent)
		return nil
	}
	fmt.Fprintf(b, "%sif tag.wire_type != %s { return err(\"%s.%s: wrong protobuf wire type\"); }\n", indent, wireConstant(f.kind), owner.slangName, name)
	if err := emitReadValue(b, owner.slangName+"."+name, f, reg, "reader", indent, "field_value"); err != nil {
		return err
	}
	if f.label == labelRepeated {
		fmt.Fprintf(b, "%spush(out.%s, field_value);\n", indent, name)
	} else if isOptional(f) {
		fmt.Fprintf(b, "%sout.%s = some(field_value);\n", indent, name)
	} else {
		fmt.Fprintf(b, "%sout.%s = field_value;\n", indent, name)
	}
	return nil
}

func emitReadValue(b *strings.Builder, label string, f *fieldDesc, reg *registry, reader, indent, target string) error {
	id := fmt.Sprintf("f%d_%s", f.number, target)
	kind := f.kind
	if f.mapValue != nil {
		kind = f.mapValue.kind
	}
	switch kind {
	case typeInt32, typeInt64, typeUint32, typeUint64, typeSint32, typeSint64, typeBool, typeEnum:
		fmt.Fprintf(b, "%slet %s_result = grpc.proto_reader_varint(%s);\n%sguard let %s_raw = %s_result else let e = err_of(%s_result) { return err(\"%s: \" + e); }\n", indent, id, reader, indent, id, id, id, label)
		expr := ""
		switch kind {
		case typeInt32, typeEnum:
			fmt.Fprintf(b, "%sif !grpc.proto_int32_wire_valid(%s_raw) { return err(\"%s: int32 varint is outside the valid wire range\"); }\n", indent, id, label)
			expr = fmt.Sprintf("grpc.proto_int32_from_wire(%s_raw)", id)
		case typeInt64:
			expr = id + "_raw as int"
		case typeUint32:
			fmt.Fprintf(b, "%sif %s_raw > 4294967295 { return err(\"%s: uint32 value exceeds 4294967295\"); }\n", indent, id, label)
			expr = id + "_raw as u32"
		case typeSint32:
			fmt.Fprintf(b, "%sif %s_raw > 4294967295 { return err(\"%s: sint32 value exceeds 4294967295\"); }\n", indent, id, label)
			expr = fmt.Sprintf("grpc.proto_sint32_from_wire(%s_raw)", id)
		case typeUint64:
			expr = id + "_raw"
		case typeSint64:
			expr = fmt.Sprintf("grpc.proto_sint64_from_wire(%s_raw)", id)
		case typeBool:
			expr = id + "_raw != 0"
		}
		fmt.Fprintf(b, "%slet %s: %s = %s;\n", indent, target, slangBaseTypeForKind(kind, f, reg), expr)
	case typeFixed32, typeSfixed32, typeFloat:
		fn := "proto_reader_fixed32"
		if kind == typeFloat {
			fn = "proto_reader_float"
		}
		fmt.Fprintf(b, "%slet %s_result = grpc.%s(%s);\n%sguard let %s_raw = %s_result else let e = err_of(%s_result) { return err(\"%s: \" + e); }\n", indent, id, fn, reader, indent, id, id, id, label)
		expr := id + "_raw"
		if kind == typeSfixed32 {
			expr = "(" + id + "_raw as i32) as int"
		}
		fmt.Fprintf(b, "%slet %s: %s = %s;\n", indent, target, slangBaseTypeForKind(kind, f, reg), expr)
	case typeFixed64, typeSfixed64, typeDouble:
		fn := "proto_reader_fixed64"
		if kind == typeDouble {
			fn = "proto_reader_double"
		}
		fmt.Fprintf(b, "%slet %s_result = grpc.%s(%s);\n%sguard let %s_raw = %s_result else let e = err_of(%s_result) { return err(\"%s: \" + e); }\n", indent, id, fn, reader, indent, id, id, id, label)
		expr := id + "_raw"
		if kind == typeSfixed64 {
			expr = id + "_raw as int"
		}
		fmt.Fprintf(b, "%slet %s: %s = %s;\n", indent, target, slangBaseTypeForKind(kind, f, reg), expr)
	case typeString:
		fmt.Fprintf(b, "%slet %s_result = grpc.proto_reader_string(%s);\n%sguard let %s = %s_result else let e = err_of(%s_result) { return err(\"%s: \" + e); }\n", indent, id, reader, indent, target, id, id, label)
	case typeBytes:
		fmt.Fprintf(b, "%slet %s_result = grpc.proto_reader_bytes(%s);\n%sguard let %s = %s_result else let e = err_of(%s_result) { return err(\"%s: \" + e); }\n", indent, id, reader, indent, target, id, id, label)
	case typeMessage:
		msg := reg.messages[typeName(f)]
		if msg == nil || msg.mapEntry {
			return fmt.Errorf("%s: missing generated message descriptor %s", label, typeName(f))
		}
		fmt.Fprintf(b, "%slet %s_sub_result = grpc.proto_reader_submessage(%s);\n%sguard let %s_sub = %s_sub_result else let e = err_of(%s_sub_result) { return err(\"%s: \" + e); }\n", indent, id, reader, indent, id, id, id, label)
		fmt.Fprintf(b, "%slet %s_result = decode_%s_reader(%s_sub);\n%sguard let %s = %s_result else let e = err_of(%s_result) { return err(\"%s: \" + e); }\n", indent, id, msg.slangName, id, indent, target, id, id, label)
	default:
		return fmt.Errorf("%s: unsupported protobuf field type %d", label, kind)
	}
	return nil
}

func emitDecodeMap(b *strings.Builder, owner *messageDesc, f *fieldDesc, reg *registry, indent string) error {
	name := safeIdentifier(f.name)
	id := fmt.Sprintf("map_%d", f.number)
	fmt.Fprintf(b, "%sif tag.wire_type != grpc.PROTO_BYTES { return err(\"%s.%s: wrong protobuf wire type\"); }\n", indent, owner.slangName, name)
	fmt.Fprintf(b, "%slet %s_result = grpc.proto_reader_submessage(reader);\n%sguard let %s_reader = %s_result else let e = err_of(%s_result) { return err(\"%s.%s: \" + e); }\n", indent, id, indent, id, id, id, owner.slangName, name)
	keyType, err := slangBaseType(f.mapKey, reg)
	if err != nil {
		return err
	}
	valueType, err := slangBaseType(f.mapValue, reg)
	if err != nil {
		return err
	}
	fmt.Fprintf(b, "%slet %s_key: %s = %s;\n%slet %s_value: %s = %s;\n", indent, id, keyType, defaultBaseExpr(f.mapKey, reg), indent, id, valueType, defaultBaseExpr(f.mapValue, reg))
	fmt.Fprintf(b, "%swhile true {\n%s    let %s_tag_result = grpc.proto_reader_tag(%s_reader);\n%s    guard let %s_tag_opt = %s_tag_result else let e = err_of(%s_tag_result) { return err(\"%s.%s map entry: \" + e); }\n%s    guard let %s_tag = %s_tag_opt else { break; }\n%s    switch %s_tag.field_number {\n", indent, indent, id, id, indent, id, id, id, owner.slangName, name, indent, id, id, indent, id)
	for _, part := range []*fieldDesc{f.mapKey, f.mapValue} {
		n := part.number
		target := id + "_key"
		if n == 2 {
			target = id + "_value"
		}
		label := owner.slangName + "." + name + " map entry"
		fmt.Fprintf(b, "%s      case %d {\n", indent, n)
		fmt.Fprintf(b, "%s        if %s_tag.wire_type != %s { return err(\"%s: wrong map entry wire type\"); }\n", indent, id, wireConstant(part.kind), label)
		if err := emitReadValue(b, label, part, reg, id+"_reader", indent+"        ", target+"_read"); err != nil {
			return err
		}
		fmt.Fprintf(b, "%s        %s = %s;\n%s      }\n", indent, target, target+"_read", indent)
	}
	fmt.Fprintf(b, "%s      default {\n%s        let %s_skip = grpc.proto_reader_skip(%s_reader, %s_tag.wire_type);\n%s        guard let _%s_skip = %s_skip else let e = err_of(%s_skip) { return err(\"%s.%s map entry: \" + e); }\n%s      }\n%s    }\n%s}\n%sout.%s[%s_key] = %s_value;\n", indent, indent, id, id, id, indent, id, id, id, owner.slangName, name, indent, indent, indent, indent, name, id, id)
	return nil
}

func emitEncoder(b *strings.Builder, m *messageDesc, fields []*fieldDesc, reg *registry) error {
	fmt.Fprintf(b, "pub fn encode_%s(value: %s, limits: grpc.Limits) -> result[bytes, str] {\n", m.slangName, m.slangName)
	b.WriteString("    let writer_result = grpc.proto_writer(limits);\n    guard let writer = writer_result else let e = err_of(writer_result) { return err(e); }\n")
	for _, f := range fields {
		if err := emitEncodeField(b, m, f, reg); err != nil {
			return err
		}
	}
	b.WriteString("    return ok(grpc.proto_writer_finish(writer));\n}\n\n")
	return nil
}

func emitEncodeField(b *strings.Builder, m *messageDesc, f *fieldDesc, reg *registry) error {
	name := safeIdentifier(f.name)
	if f.mapKey != nil {
		return emitEncodeMap(b, m, f, reg)
	}
	if f.label == labelRepeated {
		if isPackable(f.kind) && packedByDefault(f) {
			fmt.Fprintf(b, "    if len(value.%s) > 0 {\n        let packed_result = grpc.proto_writer(limits);\n        guard let packed = packed_result else let e = err_of(packed_result) { return err(e); }\n        for item in value.%s {\n", name, name)
			if err := emitWriteValue(b, m.slangName+"."+name, f, "packed", "item", 12, reg); err != nil {
				return err
			}
			fmt.Fprintf(b, "        }\n        let packed_bytes = grpc.proto_writer_finish(packed);\n")
			if err := emitWriteTag(b, m.slangName+"."+name, f.number, 2, 8); err != nil {
				return err
			}
			if err := emitWriteBytesTo(b, m.slangName+"."+name, "writer", "packed_bytes", fmt.Sprintf("write_packed_%d", f.number), 8); err != nil {
				return err
			}
			b.WriteString("    }\n")
			return nil
		}
		fmt.Fprintf(b, "    for item in value.%s {\n", name)
		if err := emitWriteTag(b, m.slangName+"."+name, f.number, expectedWire(f.kind), 8); err != nil {
			return err
		}
		if err := emitWriteValue(b, m.slangName+"."+name, f, "writer", "item", 8, reg); err != nil {
			return err
		}
		b.WriteString("    }\n")
		return nil
	}
	if isOptional(f) {
		fmt.Fprintf(b, "    if let item = value.%s {\n", name)
		if err := emitWriteTag(b, m.slangName+"."+name, f.number, expectedWire(f.kind), 8); err != nil {
			return err
		}
		if err := emitWriteValue(b, m.slangName+"."+name, f, "writer", "item", 8, reg); err != nil {
			return err
		}
		b.WriteString("    }\n")
		return nil
	}
	fmt.Fprintf(b, "    if value.%s != %s {\n", name, zeroExpr(f.kind))
	if err := emitWriteTag(b, m.slangName+"."+name, f.number, expectedWire(f.kind), 8); err != nil {
		return err
	}
	if err := emitWriteValue(b, m.slangName+"."+name, f, "writer", "value."+name, 8, reg); err != nil {
		return err
	}
	b.WriteString("    }\n")
	return nil
}

func emitWriteTag(b *strings.Builder, label string, field, wire, spaces int) error {
	return emitWriteTagTo(b, label, "writer", fmt.Sprintf("tag_%d", field), field, wire, spaces)
}

func emitWriteTagTo(b *strings.Builder, label, writer, id string, field, wire, spaces int) error {
	indent := strings.Repeat(" ", spaces)
	fmt.Fprintf(b, "%slet %s_result = grpc.proto_writer_tag(%s, %d, %s);\n%sguard let _%s = %s_result else let e = err_of(%s_result) { return err(\"%s: \" + e); }\n", indent, id, writer, field, wireConstValue(wire), indent, id, id, id, label)
	return nil
}

func emitWriteBytes(b *strings.Builder, label, writer, value string, spaces int) error {
	return emitWriteBytesTo(b, label, writer, value, fmt.Sprintf("write_bytes_%d", len(label)+spaces), spaces)
}

func emitWriteBytesTo(b *strings.Builder, label, writer, value, id string, spaces int) error {
	indent := strings.Repeat(" ", spaces)
	fmt.Fprintf(b, "%slet %s_result = grpc.proto_writer_bytes(%s, %s);\n%sguard let _%s = %s_result else let e = err_of(%s_result) { return err(\"%s: \" + e); }\n", indent, id, writer, value, indent, id, id, id, label)
	return nil
}

func emitWriteValue(b *strings.Builder, label string, f *fieldDesc, writer, value string, spaces int, reg *registry) error {
	indent := strings.Repeat(" ", spaces)
	id := fmt.Sprintf("write_%d_%s", f.number, safeIdentifier(f.name))
	kind := f.kind
	if f.mapValue != nil {
		kind = f.mapValue.kind
	}
	if kind == typeInt32 || kind == typeSint32 || kind == typeSfixed32 || kind == typeEnum {
		fmt.Fprintf(b, "%sif %s < -2147483648 || %s > 2147483647 { return err(\"%s: value is outside int32 range\"); }\n", indent, value, value, label)
	}
	fn := ""
	arg := value
	switch kind {
	case typeInt32, typeEnum:
		fn, arg = "proto_writer_varint", fmt.Sprintf("grpc.proto_int32_to_wire(%s)", value)
	case typeInt64:
		fn, arg = "proto_writer_varint", value+" as u64"
	case typeUint32:
		fn, arg = "proto_writer_varint", value+" as u64"
	case typeUint64:
		fn = "proto_writer_varint"
	case typeSint32:
		fn, arg = "proto_writer_varint", fmt.Sprintf("grpc.proto_sint32_to_wire(%s)", value)
	case typeSint64:
		fn, arg = "proto_writer_varint", fmt.Sprintf("grpc.proto_sint64_to_wire(%s)", value)
	case typeBool:
		raw := id + "_raw"
		fmt.Fprintf(b, "%slet %s: u64 = 0;\n%sif %s { %s = 1; }\n", indent, raw, indent, value, raw)
		fn, arg = "proto_writer_varint", raw
	case typeFixed32:
		fn, arg = "proto_writer_fixed32", value
	case typeSfixed32:
		fn, arg = "proto_writer_fixed32", value+" as u32"
	case typeFloat:
		fn = "proto_writer_float"
	case typeFixed64:
		fn, arg = "proto_writer_fixed64", value
	case typeSfixed64:
		fn, arg = "proto_writer_fixed64", value+" as u64"
	case typeDouble:
		fn = "proto_writer_double"
	case typeString:
		fn = "proto_writer_string"
	case typeBytes:
		fn = "proto_writer_bytes"
	case typeMessage:
		msg := reg.messages[typeName(f)]
		if msg == nil {
			return fmt.Errorf("%s: message descriptor missing", label)
		}
		encode := id + "_message"
		fmt.Fprintf(b, "%slet %s_result = encode_%s(%s, limits);\n%sguard let %s = %s_result else let e = err_of(%s_result) { return err(\"%s: \" + e); }\n", indent, encode, msg.slangName, value, indent, encode, encode, encode, label)
		fn, arg = "proto_writer_bytes", encode
	default:
		return fmt.Errorf("%s: unsupported protobuf writer field kind %d", label, kind)
	}
	fmt.Fprintf(b, "%slet %s_result = grpc.%s(%s, %s);\n%sguard let _%s = %s_result else let e = err_of(%s_result) { return err(\"%s: \" + e); }\n", indent, id, fn, writer, arg, indent, id, id, id, label)
	return nil
}

func emitEncodeMap(b *strings.Builder, owner *messageDesc, f *fieldDesc, reg *registry) error {
	name := safeIdentifier(f.name)
	key := f.mapKey
	value := f.mapValue
	keyName, valueName := "map_key", "map_value"
	entryID := fmt.Sprintf("map_entry_%d", f.number)
	fmt.Fprintf(b, "    for %s, %s in value.%s {\n", keyName, valueName, name)
	fmt.Fprintf(b, "        let %s_result = grpc.proto_writer(limits);\n        guard let %s = %s_result else let e = err_of(%s_result) { return err(e); }\n", entryID, entryID, entryID, entryID)
	zero := zeroExpr(key.kind)
	if key.kind == typeString || key.kind == typeBytes || key.kind == typeBool || key.kind == typeFloat || key.kind == typeDouble || key.kind == typeInt32 || key.kind == typeInt64 || key.kind == typeUint32 || key.kind == typeUint64 || key.kind == typeSint32 || key.kind == typeSint64 || key.kind == typeSfixed32 || key.kind == typeSfixed64 || key.kind == typeFixed32 || key.kind == typeFixed64 || key.kind == typeEnum {
		fmt.Fprintf(b, "        if %s != %s {\n", keyName, zero)
		if err := emitWriteTagTo(b, owner.slangName+"."+name+" map key", entryID, entryID+"_key_tag", 1, expectedWire(key.kind), 12); err != nil {
			return err
		}
		if err := emitWriteValue(b, owner.slangName+"."+name+" map key", key, entryID, keyName, 12, reg); err != nil {
			return err
		}
		b.WriteString("        }\n")
	}
	if value.kind == typeMessage {
		if err := emitWriteTagTo(b, owner.slangName+"."+name+" map value", entryID, entryID+"_value_tag", 2, expectedWire(value.kind), 8); err != nil {
			return err
		}
		if err := emitWriteValue(b, owner.slangName+"."+name+" map value", value, entryID, valueName, 8, reg); err != nil {
			return err
		}
	} else {
		fmt.Fprintf(b, "        if %s != %s {\n", valueName, zeroExpr(value.kind))
		if err := emitWriteTagTo(b, owner.slangName+"."+name+" map value", entryID, entryID+"_value_tag", 2, expectedWire(value.kind), 12); err != nil {
			return err
		}
		if err := emitWriteValue(b, owner.slangName+"."+name+" map value", value, entryID, valueName, 12, reg); err != nil {
			return err
		}
		b.WriteString("        }\n")
	}
	fmt.Fprintf(b, "        let %s_bytes = grpc.proto_writer_finish(%s);\n", entryID, entryID)
	if err := emitWriteTag(b, owner.slangName+"."+name, f.number, 2, 8); err != nil {
		return err
	}
	if err := emitWriteBytesTo(b, owner.slangName+"."+name, "writer", entryID+"_bytes", entryID+"_outer", 8); err != nil {
		return err
	}
	b.WriteString("    }\n")
	return nil
}

func emitService(b *strings.Builder, file *fileDesc, service *serviceDesc, reg *registry) error {
	for _, method := range service.methods {
		if method.clientStream || method.serverStream {
			return fmt.Errorf("%s.%s: streaming RPCs are not supported in v1; use a unary method", service.name, method.name)
		}
		if reg.messages[method.inputType] == nil || reg.messages[method.outputType] == nil {
			return fmt.Errorf("%s.%s: request and response .proto files must be generated in the same invocation", service.name, method.name)
		}
		prefix := ""
		if file.pkg != "" {
			prefix = strings.ReplaceAll(file.pkg, ".", "_") + "_"
		}
		name := strings.ToUpper(safeIdentifier(prefix + service.name + "_" + method.name))
		fullService := service.name
		if file.pkg != "" {
			fullService = file.pkg + "." + service.name
		}
		fmt.Fprintf(b, "pub let %s_PATH = %s;\n", name, strconv.Quote("/"+fullService+"/"+method.name))
	}
	if len(service.methods) > 0 {
		b.WriteByte('\n')
	}
	return nil
}

func slangFieldType(f *fieldDesc, reg *registry) (string, error) {
	if f.mapKey != nil {
		key, err := slangBaseType(f.mapKey, reg)
		if err != nil {
			return "", err
		}
		value, err := slangBaseType(f.mapValue, reg)
		if err != nil {
			return "", err
		}
		return "map[" + key + "]" + value, nil
	}
	base, err := slangBaseType(f, reg)
	if err != nil {
		return "", err
	}
	if f.label == labelRepeated {
		return "[" + base + "]", nil
	}
	if isOptional(f) {
		return "opt[" + base + "]", nil
	}
	return base, nil
}

func slangBaseType(f *fieldDesc, reg *registry) (string, error) {
	kind := f.kind
	if f.mapValue != nil {
		kind = f.mapValue.kind
	}
	switch kind {
	case typeDouble, typeFloat:
		return "float", nil
	case typeInt64, typeInt32, typeSint32, typeSint64, typeSfixed32, typeSfixed64, typeEnum:
		return "int", nil
	case typeUint32, typeFixed32:
		return "u32", nil
	case typeUint64, typeFixed64:
		return "u64", nil
	case typeBool:
		return "bool", nil
	case typeString:
		return "str", nil
	case typeBytes:
		return "bytes", nil
	case typeMessage:
		m := reg.messages[typeName(f)]
		if m == nil || m.mapEntry {
			return "", fmt.Errorf("message type %s is not generated", typeName(f))
		}
		return m.slangName, nil
	default:
		return "", fmt.Errorf("unsupported protobuf field type %d", kind)
	}
}

func slangBaseTypeForKind(kind int, f *fieldDesc, reg *registry) string {
	base, _ := slangBaseType(&fieldDesc{kind: kind, typeName: f.typeName, mapValue: f.mapValue}, reg)
	return base
}
func typeName(f *fieldDesc) string {
	if f.mapValue != nil {
		return f.mapValue.typeName
	}
	return f.typeName
}

func isOptional(f *fieldDesc) bool {
	return f.label != labelRepeated && (f.proto3Optional || f.kind == typeMessage)
}
func isPackable(kind int) bool {
	return kind != typeString && kind != typeBytes && kind != typeMessage && kind != typeGroup
}
func packedByDefault(f *fieldDesc) bool { return f.packed == nil || *f.packed }

func expectedWire(kind int) int {
	switch kind {
	case typeDouble, typeFixed64, typeSfixed64:
		return 1
	case typeString, typeBytes, typeMessage:
		return 2
	case typeFloat, typeFixed32, typeSfixed32:
		return 5
	default:
		return 0
	}
}
func wireConstant(kind int) string { return wireConstValue(expectedWire(kind)) }
func wireConstValue(wire int) string {
	switch wire {
	case 0:
		return "grpc.PROTO_VARINT"
	case 1:
		return "grpc.PROTO_FIXED64"
	case 2:
		return "grpc.PROTO_BYTES"
	case 5:
		return "grpc.PROTO_FIXED32"
	}
	return "-1"
}

func defaultExpr(f *fieldDesc, reg *registry) string {
	if f.mapKey != nil {
		return "{}"
	}
	if f.label == labelRepeated {
		return "[]"
	}
	if isOptional(f) {
		return "none"
	}
	return defaultBaseExpr(f, reg)
}
func defaultBaseExpr(f *fieldDesc, reg *registry) string {
	if f == nil {
		return "0"
	}
	kind := f.kind
	if f.mapValue != nil {
		kind = f.mapValue.kind
	}
	switch kind {
	case typeBool:
		return "false"
	case typeFloat, typeDouble:
		return "0.0"
	case typeString:
		return "\"\""
	case typeBytes:
		return "b\"\""
	case typeMessage:
		m := reg.messages[typeName(f)]
		if m != nil {
			return "new_" + m.slangName + "()"
		}
	}
	return "0"
}
func zeroExpr(kind int) string {
	switch kind {
	case typeBool:
		return "false"
	case typeFloat, typeDouble:
		return "0.0"
	case typeString:
		return "\"\""
	case typeBytes:
		return "b\"\""
	}
	return "0"
}
