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

// Decoders walk one grpc.Reader over the whole message tree: a nested
// message, packed field or map entry narrows the reader (proto_reader_enter)
// rather than allocating a reader of its own. The runtime's primitives
// report failures as integer codes; the generated code adds the field's
// name and only then builds the text, so a successful read allocates
// nothing beyond the decoded value.
func emitDecoder(b *strings.Builder, m *messageDesc, fields []*fieldDesc, reg *registry) error {
	fmt.Fprintf(b, "fn decode_%s_reader(reader: grpc.Reader) -> result[%s, str] {\n", m.slangName, m.slangName)
	fmt.Fprintf(b, "    let out = new_%s();\n", m.slangName)
	b.WriteString("    while true {\n")
	b.WriteString("        let key_read = grpc.proto_reader_key(reader);\n")
	fmt.Fprintf(b, "        guard let key = key_read else let code = err_of(key_read) { return err(%s); }\n", errText(m.slangName+": protobuf key", "code"))
	b.WriteString("        if key == 0 { break; }\n")
	b.WriteString("        let wire = key & 7;\n")
	b.WriteString("        switch key >> 3 {\n")
	for _, f := range fields {
		fmt.Fprintf(b, "          case %d {\n", f.number)
		if err := emitDecodeField(b, m, f, reg, "            "); err != nil {
			return err
		}
		b.WriteString("          }\n")
	}
	b.WriteString("          default {\n")
	b.WriteString("            let skipped = grpc.proto_reader_skip(reader, wire);\n")
	fmt.Fprintf(b, "            guard let _skipped = skipped else let code = err_of(skipped) { return err(%s); }\n", errText(m.slangName+": unknown protobuf field", "code"))
	b.WriteString("          }\n        }\n    }\n")
	fmt.Fprintf(b, "    return ok(out);\n}\n\npub fn decode_%s(raw: bytes, limits: grpc.Limits) -> result[%s, str] {\n", m.slangName, m.slangName)
	b.WriteString("    let reader_result = grpc.proto_reader(raw, limits);\n    guard let reader = reader_result else let e = err_of(reader_result) { return err(e); }\n")
	fmt.Fprintf(b, "    return decode_%s_reader(reader);\n}\n\n", m.slangName)
	return nil
}

// errText is the slang expression for a failure: the label, then the
// runtime's text for the integer code held in variable `code`.
func errText(label, code string) string {
	return fmt.Sprintf("%s + grpc.proto_error_text(%s)", strconv.Quote(label+": "), code)
}

// emitCheck reads a result[T, int] from `call` into `target`, returning the
// labelled failure.
func emitCheck(b *strings.Builder, indent, id, call, target, label string) {
	fmt.Fprintf(b, "%slet %s = %s;\n", indent, id, call)
	fmt.Fprintf(b, "%sguard let %s = %s else let code = err_of(%s) { return err(%s); }\n", indent, target, id, id, errText(label, "code"))
}

func emitDecodeField(b *strings.Builder, owner *messageDesc, f *fieldDesc, reg *registry, indent string) error {
	name := safeIdentifier(f.name)
	label := owner.slangName + "." + name
	if f.mapKey != nil {
		return emitDecodeMap(b, owner, f, reg, indent)
	}
	if f.label == labelRepeated && isPackable(f.kind) {
		id := fmt.Sprintf("f%d_packed", f.number)
		fmt.Fprintf(b, "%sif wire == grpc.PROTO_BYTES {\n", indent)
		inner := indent + "    "
		emitCheck(b, inner, id+"_read", "grpc.proto_reader_enter_packed(reader)", id+"_outer", label)
		fmt.Fprintf(b, "%swhile !grpc.proto_reader_done(reader) {\n", inner)
		emitCheck(b, inner+"    ", id+"_charged", "grpc.proto_reader_charge(reader)", "_"+id+"_charged", label)
		if err := emitReadValue(b, label, f, reg, inner+"    ", "packed_value"); err != nil {
			return err
		}
		fmt.Fprintf(b, "%s    push(out.%s, packed_value);\n%s}\n", inner, name, inner)
		emitCheck(b, inner, id+"_left", fmt.Sprintf("grpc.proto_reader_leave_packed(reader, %s_outer)", id), "_"+id+"_left", label)
		fmt.Fprintf(b, "%s} else {\n", indent)
		fmt.Fprintf(b, "%sif wire != %s { return err(%s); }\n", inner, wireConstant(f.kind), strconv.Quote(label+": wrong protobuf wire type"))
		if err := emitReadValue(b, label, f, reg, inner, "field_value"); err != nil {
			return err
		}
		fmt.Fprintf(b, "%spush(out.%s, field_value);\n%s}\n", inner, name, indent)
		return nil
	}
	fmt.Fprintf(b, "%sif wire != %s { return err(%s); }\n", indent, wireConstant(f.kind), strconv.Quote(label+": wrong protobuf wire type"))
	if err := emitReadValue(b, label, f, reg, indent, "field_value"); err != nil {
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

// emitReadValue reads one value of f's kind (its map value's kind for a map
// field) from `reader` into a new variable `target`.
func emitReadValue(b *strings.Builder, label string, f *fieldDesc, reg *registry, indent, target string) error {
	id := fmt.Sprintf("f%d_%s", f.number, target)
	kind := f.kind
	if f.mapValue != nil {
		kind = f.mapValue.kind
	}
	switch kind {
	case typeInt32, typeInt64, typeUint32, typeUint64, typeSint32, typeSint64, typeBool, typeEnum:
		emitCheck(b, indent, id+"_read", "grpc.proto_reader_varint(reader)", id+"_raw", label)
		expr := ""
		switch kind {
		case typeInt32, typeEnum:
			fmt.Fprintf(b, "%sif !grpc.proto_int32_wire_valid(%s_raw) { return err(%s); }\n", indent, id, strconv.Quote(label+": int32 varint is outside the valid wire range"))
			expr = fmt.Sprintf("grpc.proto_int32_from_wire(%s_raw)", id)
		case typeInt64:
			expr = id + "_raw as int"
		case typeUint32:
			fmt.Fprintf(b, "%sif %s_raw > 4294967295 { return err(%s); }\n", indent, id, strconv.Quote(label+": uint32 value exceeds 4294967295"))
			expr = id + "_raw as u32"
		case typeSint32:
			fmt.Fprintf(b, "%sif %s_raw > 4294967295 { return err(%s); }\n", indent, id, strconv.Quote(label+": sint32 value exceeds 4294967295"))
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
		emitCheck(b, indent, id+"_read", fmt.Sprintf("grpc.%s(reader)", fn), id+"_raw", label)
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
		emitCheck(b, indent, id+"_read", fmt.Sprintf("grpc.%s(reader)", fn), id+"_raw", label)
		expr := id + "_raw"
		if kind == typeSfixed64 {
			expr = id + "_raw as int"
		}
		fmt.Fprintf(b, "%slet %s: %s = %s;\n", indent, target, slangBaseTypeForKind(kind, f, reg), expr)
	case typeString:
		emitCheck(b, indent, id+"_read", "grpc.proto_reader_string_end(reader)", id+"_end", label)
		fmt.Fprintf(b, "%slet %s = grpc.proto_reader_take_string(reader, %s_end);\n", indent, target, id)
	case typeBytes:
		emitCheck(b, indent, id+"_read", "grpc.proto_reader_open(reader)", id+"_end", label)
		fmt.Fprintf(b, "%slet %s = grpc.proto_reader_take_bytes(reader, %s_end);\n", indent, target, id)
	case typeMessage:
		msg := reg.messages[typeName(f)]
		if msg == nil || msg.mapEntry {
			return fmt.Errorf("%s: missing generated message descriptor %s", label, typeName(f))
		}
		emitCheck(b, indent, id+"_enter", "grpc.proto_reader_enter(reader)", id+"_outer", label)
		fmt.Fprintf(b, "%slet %s_result = decode_%s_reader(reader);\n", indent, id, msg.slangName)
		fmt.Fprintf(b, "%sguard let %s = %s_result else let e = err_of(%s_result) { return err(%s + e); }\n", indent, target, id, id, strconv.Quote(label+": "))
		emitCheck(b, indent, id+"_leave", fmt.Sprintf("grpc.proto_reader_leave(reader, %s_outer)", id), "_"+id+"_left", label)
	default:
		return fmt.Errorf("%s: unsupported protobuf field type %d", label, kind)
	}
	return nil
}

func emitDecodeMap(b *strings.Builder, owner *messageDesc, f *fieldDesc, reg *registry, indent string) error {
	name := safeIdentifier(f.name)
	id := fmt.Sprintf("map_%d", f.number)
	label := owner.slangName + "." + name
	entryLabel := label + " map entry"
	fmt.Fprintf(b, "%sif wire != grpc.PROTO_BYTES { return err(%s); }\n", indent, strconv.Quote(label+": wrong protobuf wire type"))
	emitCheck(b, indent, id+"_enter", "grpc.proto_reader_enter(reader)", id+"_outer", label)
	keyType, err := slangBaseType(f.mapKey, reg)
	if err != nil {
		return err
	}
	valueType, err := slangBaseType(f.mapValue, reg)
	if err != nil {
		return err
	}
	fmt.Fprintf(b, "%slet %s_key: %s = %s;\n%slet %s_value: %s = %s;\n", indent, id, keyType, defaultBaseExpr(f.mapKey, reg), indent, id, valueType, defaultBaseExpr(f.mapValue, reg))
	fmt.Fprintf(b, "%swhile true {\n", indent)
	inner := indent + "    "
	emitCheck(b, inner, id+"_key_read", "grpc.proto_reader_key(reader)", id+"_k", entryLabel)
	fmt.Fprintf(b, "%sif %s_k == 0 { break; }\n", inner, id)
	fmt.Fprintf(b, "%sswitch %s_k >> 3 {\n", inner, id)
	for _, part := range []*fieldDesc{f.mapKey, f.mapValue} {
		target := id + "_key"
		if part.number == 2 {
			target = id + "_value"
		}
		fmt.Fprintf(b, "%s  case %d {\n", inner, part.number)
		fmt.Fprintf(b, "%s    if (%s_k & 7) != %s { return err(%s); }\n", inner, id, wireConstant(part.kind), strconv.Quote(entryLabel+": wrong map entry wire type"))
		if err := emitReadValue(b, entryLabel, part, reg, inner+"    ", target+"_read"); err != nil {
			return err
		}
		fmt.Fprintf(b, "%s    %s = %s_read;\n%s  }\n", inner, target, target, inner)
	}
	fmt.Fprintf(b, "%s  default {\n", inner)
	emitCheck(b, inner+"    ", id+"_skip", fmt.Sprintf("grpc.proto_reader_skip(reader, %s_k & 7)", id), "_"+id+"_skipped", entryLabel)
	fmt.Fprintf(b, "%s  }\n%s}\n%s}\n", inner, inner, indent)
	emitCheck(b, indent, id+"_leave", fmt.Sprintf("grpc.proto_reader_leave(reader, %s_outer)", id), "_"+id+"_left", label)
	fmt.Fprintf(b, "%sout.%s[%s_key] = %s_value;\n", indent, name, id, id)
	return nil
}

// Encoders run in two passes so the bytes are written exactly once, into
// one builder. size_<M> computes the encoded size, which every length
// prefix needs before its value, or -1 when a value cannot be encoded;
// write_<M> then writes and cannot fail. A nested message's size is
// computed again by its parent's write pass, so a tree d levels deep sizes
// its innermost fields d times: the cost of not keeping a size cache in
// every message struct. check_<M> runs only after size_<M> says -1, to
// name the field.
func emitEncoder(b *strings.Builder, m *messageDesc, fields []*fieldDesc, reg *registry) error {
	fmt.Fprintf(b, "pub fn encode_%s(value: %s, limits: grpc.Limits) -> result[bytes, str] {\n", m.slangName, m.slangName)
	b.WriteString("    if !grpc.proto_limits_valid(limits) { return err(\"grpc.proto writer: invalid limits\"); }\n")
	fmt.Fprintf(b, "    let size = size_%s(value);\n", m.slangName)
	fmt.Fprintf(b, "    if size < 0 { return err(check_%s(value)); }\n", m.slangName)
	b.WriteString("    if size > limits.max_message_bytes { return err(\"grpc.proto writer: message exceeds configured byte limit\"); }\n")
	b.WriteString("    let writer = grpc.proto_writer();\n")
	fmt.Fprintf(b, "    write_%s(writer, value);\n", m.slangName)
	b.WriteString("    return ok(grpc.proto_writer_finish(writer));\n}\n\n")

	fmt.Fprintf(b, "fn size_%s(value: %s) -> int {\n    let n = 0;\n", m.slangName, m.slangName)
	for _, f := range fields {
		if err := emitSizeField(b, m, f, reg); err != nil {
			return err
		}
	}
	b.WriteString("    return n;\n}\n\n")

	fmt.Fprintf(b, "fn write_%s(w: grpc.Writer, value: %s) {\n", m.slangName, m.slangName)
	for _, f := range fields {
		if err := emitWriteField(b, m, f, reg); err != nil {
			return err
		}
	}
	b.WriteString("}\n\n")

	fmt.Fprintf(b, "fn check_%s(value: %s) -> str {\n", m.slangName, m.slangName)
	for _, f := range fields {
		if err := emitCheckField(b, m, f, reg); err != nil {
			return err
		}
	}
	b.WriteString("    return \"\";\n}\n\n")
	return nil
}

func valueKind(f *fieldDesc) int {
	if f.mapValue != nil {
		return f.mapValue.kind
	}
	return f.kind
}

func isInt32Kind(kind int) bool {
	return kind == typeInt32 || kind == typeSint32 || kind == typeSfixed32 || kind == typeEnum
}

// keySize is the encoded size of a field's key, known when generating.
func keySize(field, wire int) int {
	v := uint64(field)<<3 | uint64(wire)
	n := 1
	for v > 127 {
		v >>= 7
		n++
	}
	return n
}

// sizeExpr is the encoded size of one scalar value v (not its key); "" for
// a message, whose size needs a statement.
func sizeExpr(kind int, v string) string {
	switch kind {
	case typeInt32, typeEnum:
		return fmt.Sprintf("grpc.proto_size_varint(grpc.proto_int32_to_wire(%s))", v)
	case typeInt64, typeUint32:
		return fmt.Sprintf("grpc.proto_size_varint(%s as u64)", v)
	case typeUint64:
		return fmt.Sprintf("grpc.proto_size_varint(%s)", v)
	case typeSint32:
		return fmt.Sprintf("grpc.proto_size_varint(grpc.proto_sint32_to_wire(%s))", v)
	case typeSint64:
		return fmt.Sprintf("grpc.proto_size_varint(grpc.proto_sint64_to_wire(%s))", v)
	case typeBool:
		return "1"
	case typeFixed32, typeSfixed32, typeFloat:
		return "4"
	case typeFixed64, typeSfixed64, typeDouble:
		return "8"
	case typeString, typeBytes:
		return fmt.Sprintf("grpc.proto_size_delimited(len(%s))", v)
	}
	return ""
}

// emitSizeValue adds one value's size (without its key) to `acc`. In the
// size pass (checked) it returns -1 from size_<M> when the value cannot be
// encoded; the write pass recomputes sizes of values already checked.
func emitSizeValue(b *strings.Builder, f *fieldDesc, kind int, v, acc, indent string, checked bool, reg *registry) error {
	if checked && isInt32Kind(kind) {
		fmt.Fprintf(b, "%sif !grpc.proto_int32_in_range(%s) { return -1; }\n", indent, v)
	}
	if kind == typeMessage {
		msg := reg.messages[typeName(f)]
		if msg == nil {
			return fmt.Errorf("%s: message descriptor missing", f.name)
		}
		id := fmt.Sprintf("size_%d", f.number)
		fmt.Fprintf(b, "%slet %s = size_%s(%s);\n", indent, id, msg.slangName, v)
		if checked {
			fmt.Fprintf(b, "%sif %s < 0 { return -1; }\n", indent, id)
		}
		fmt.Fprintf(b, "%s%s = %s + grpc.proto_size_delimited(%s);\n", indent, acc, acc, id)
		return nil
	}
	expr := sizeExpr(kind, v)
	if expr == "" {
		return fmt.Errorf("%s: unsupported protobuf writer field kind %d", f.name, kind)
	}
	fmt.Fprintf(b, "%s%s = %s + %s;\n", indent, acc, acc, expr)
	return nil
}

func emitSizeField(b *strings.Builder, m *messageDesc, f *fieldDesc, reg *registry) error {
	name := safeIdentifier(f.name)
	if f.mapKey != nil {
		return emitSizeMap(b, f, reg)
	}
	if f.label == labelRepeated {
		if isPackable(f.kind) && packedByDefault(f) {
			fmt.Fprintf(b, "    if len(value.%s) > 0 {\n        let packed = 0;\n        for item in value.%s {\n", name, name)
			if err := emitSizeValue(b, f, f.kind, "item", "packed", "            ", true, reg); err != nil {
				return err
			}
			fmt.Fprintf(b, "        }\n        n = n + %d + grpc.proto_size_delimited(packed);\n    }\n", keySize(f.number, 2))
			return nil
		}
		fmt.Fprintf(b, "    for item in value.%s {\n        n = n + %d;\n", name, keySize(f.number, expectedWire(f.kind)))
		if err := emitSizeValue(b, f, f.kind, "item", "n", "        ", true, reg); err != nil {
			return err
		}
		b.WriteString("    }\n")
		return nil
	}
	if isOptional(f) {
		fmt.Fprintf(b, "    if let item = value.%s {\n        n = n + %d;\n", name, keySize(f.number, expectedWire(f.kind)))
		if err := emitSizeValue(b, f, f.kind, "item", "n", "        ", true, reg); err != nil {
			return err
		}
		b.WriteString("    }\n")
		return nil
	}
	fmt.Fprintf(b, "    if value.%s != %s {\n        n = n + %d;\n", name, zeroExpr(f.kind), keySize(f.number, expectedWire(f.kind)))
	if err := emitSizeValue(b, f, f.kind, "value."+name, "n", "        ", true, reg); err != nil {
		return err
	}
	b.WriteString("    }\n")
	return nil
}

// emitEntrySize computes a map entry's encoded size into `entry`: the key
// and value, each omitted at its proto3 default (a message value always
// written), as the write pass does.
func emitEntrySize(b *strings.Builder, f *fieldDesc, reg *registry, indent string, checked bool) error {
	key, value := f.mapKey, f.mapValue
	fmt.Fprintf(b, "%slet entry = 0;\n", indent)
	fmt.Fprintf(b, "%sif map_key != %s {\n%s    entry = entry + %d;\n", indent, zeroExpr(key.kind), indent, keySize(1, expectedWire(key.kind)))
	if err := emitSizeValue(b, key, key.kind, "map_key", "entry", indent+"    ", checked, reg); err != nil {
		return err
	}
	fmt.Fprintf(b, "%s}\n", indent)
	if value.kind == typeMessage {
		fmt.Fprintf(b, "%sentry = entry + %d;\n", indent, keySize(2, 2))
		return emitSizeValue(b, f, value.kind, "map_value", "entry", indent, checked, reg)
	}
	fmt.Fprintf(b, "%sif map_value != %s {\n%s    entry = entry + %d;\n", indent, zeroExpr(value.kind), indent, keySize(2, expectedWire(value.kind)))
	if err := emitSizeValue(b, value, value.kind, "map_value", "entry", indent+"    ", checked, reg); err != nil {
		return err
	}
	fmt.Fprintf(b, "%s}\n", indent)
	return nil
}

func emitSizeMap(b *strings.Builder, f *fieldDesc, reg *registry) error {
	fmt.Fprintf(b, "    for map_key, map_value in value.%s {\n", safeIdentifier(f.name))
	if err := emitEntrySize(b, f, reg, "        ", true); err != nil {
		return err
	}
	fmt.Fprintf(b, "        n = n + %d + grpc.proto_size_delimited(entry);\n    }\n", keySize(f.number, 2))
	return nil
}

// emitWriteValue writes one value (not its key). Values were range-checked
// by the size pass, so nothing here can fail.
func emitWriteValue(b *strings.Builder, f *fieldDesc, kind int, v, indent string, reg *registry) error {
	call := ""
	switch kind {
	case typeInt32, typeEnum:
		call = fmt.Sprintf("grpc.proto_write_varint(w, grpc.proto_int32_to_wire(%s))", v)
	case typeInt64, typeUint32:
		call = fmt.Sprintf("grpc.proto_write_varint(w, %s as u64)", v)
	case typeUint64:
		call = fmt.Sprintf("grpc.proto_write_varint(w, %s)", v)
	case typeSint32:
		call = fmt.Sprintf("grpc.proto_write_varint(w, grpc.proto_sint32_to_wire(%s))", v)
	case typeSint64:
		call = fmt.Sprintf("grpc.proto_write_varint(w, grpc.proto_sint64_to_wire(%s))", v)
	case typeBool:
		call = fmt.Sprintf("grpc.proto_write_bool(w, %s)", v)
	case typeFixed32:
		call = fmt.Sprintf("grpc.proto_write_fixed32(w, %s)", v)
	case typeSfixed32:
		call = fmt.Sprintf("grpc.proto_write_fixed32(w, %s as u32)", v)
	case typeFloat:
		call = fmt.Sprintf("grpc.proto_write_float(w, %s)", v)
	case typeFixed64:
		call = fmt.Sprintf("grpc.proto_write_fixed64(w, %s)", v)
	case typeSfixed64:
		call = fmt.Sprintf("grpc.proto_write_fixed64(w, %s as u64)", v)
	case typeDouble:
		call = fmt.Sprintf("grpc.proto_write_double(w, %s)", v)
	case typeString:
		call = fmt.Sprintf("grpc.proto_write_string(w, %s)", v)
	case typeBytes:
		call = fmt.Sprintf("grpc.proto_write_bytes(w, %s)", v)
	case typeMessage:
		msg := reg.messages[typeName(f)]
		if msg == nil {
			return fmt.Errorf("%s: message descriptor missing", f.name)
		}
		fmt.Fprintf(b, "%sgrpc.proto_write_varint(w, size_%s(%s) as u64);\n", indent, msg.slangName, v)
		call = fmt.Sprintf("write_%s(w, %s)", msg.slangName, v)
	default:
		return fmt.Errorf("%s: unsupported protobuf writer field kind %d", f.name, kind)
	}
	fmt.Fprintf(b, "%s%s;\n", indent, call)
	return nil
}

func emitWriteKey(b *strings.Builder, field, wire int, indent string) {
	fmt.Fprintf(b, "%sgrpc.proto_write_varint(w, %d);\n", indent, uint64(field)<<3|uint64(wire))
}

func emitWriteField(b *strings.Builder, m *messageDesc, f *fieldDesc, reg *registry) error {
	name := safeIdentifier(f.name)
	if f.mapKey != nil {
		return emitWriteMap(b, f, reg)
	}
	if f.label == labelRepeated {
		if isPackable(f.kind) && packedByDefault(f) {
			fmt.Fprintf(b, "    if len(value.%s) > 0 {\n        let packed = 0;\n        for item in value.%s {\n", name, name)
			if err := emitSizeValue(b, f, f.kind, "item", "packed", "            ", false, reg); err != nil {
				return err
			}
			b.WriteString("        }\n")
			emitWriteKey(b, f.number, 2, "        ")
			b.WriteString("        grpc.proto_write_varint(w, packed as u64);\n")
			fmt.Fprintf(b, "        for item in value.%s {\n", name)
			if err := emitWriteValue(b, f, f.kind, "item", "            ", reg); err != nil {
				return err
			}
			b.WriteString("        }\n    }\n")
			return nil
		}
		fmt.Fprintf(b, "    for item in value.%s {\n", name)
		emitWriteKey(b, f.number, expectedWire(f.kind), "        ")
		if err := emitWriteValue(b, f, f.kind, "item", "        ", reg); err != nil {
			return err
		}
		b.WriteString("    }\n")
		return nil
	}
	if isOptional(f) {
		fmt.Fprintf(b, "    if let item = value.%s {\n", name)
		emitWriteKey(b, f.number, expectedWire(f.kind), "        ")
		if err := emitWriteValue(b, f, f.kind, "item", "        ", reg); err != nil {
			return err
		}
		b.WriteString("    }\n")
		return nil
	}
	fmt.Fprintf(b, "    if value.%s != %s {\n", name, zeroExpr(f.kind))
	emitWriteKey(b, f.number, expectedWire(f.kind), "        ")
	if err := emitWriteValue(b, f, f.kind, "value."+name, "        ", reg); err != nil {
		return err
	}
	b.WriteString("    }\n")
	return nil
}

func emitWriteMap(b *strings.Builder, f *fieldDesc, reg *registry) error {
	key, value := f.mapKey, f.mapValue
	fmt.Fprintf(b, "    for map_key, map_value in value.%s {\n", safeIdentifier(f.name))
	if err := emitEntrySize(b, f, reg, "        ", false); err != nil {
		return err
	}
	emitWriteKey(b, f.number, 2, "        ")
	b.WriteString("        grpc.proto_write_varint(w, entry as u64);\n")
	fmt.Fprintf(b, "        if map_key != %s {\n", zeroExpr(key.kind))
	emitWriteKey(b, 1, expectedWire(key.kind), "            ")
	if err := emitWriteValue(b, key, key.kind, "map_key", "            ", reg); err != nil {
		return err
	}
	b.WriteString("        }\n")
	if value.kind == typeMessage {
		emitWriteKey(b, 2, 2, "        ")
		if err := emitWriteValue(b, f, value.kind, "map_value", "        ", reg); err != nil {
			return err
		}
	} else {
		fmt.Fprintf(b, "        if map_value != %s {\n", zeroExpr(value.kind))
		emitWriteKey(b, 2, expectedWire(value.kind), "            ")
		if err := emitWriteValue(b, value, value.kind, "map_value", "            ", reg); err != nil {
			return err
		}
		b.WriteString("        }\n")
	}
	b.WriteString("    }\n")
	return nil
}

// emitCheckValue returns the labelled reason a value cannot be encoded:
// an int32 out of range, or a nested message's own failure.
func emitCheckValue(b *strings.Builder, f *fieldDesc, kind int, v, label, indent string, reg *registry) {
	if isInt32Kind(kind) {
		fmt.Fprintf(b, "%sif !grpc.proto_int32_in_range(%s) { return %s; }\n", indent, v, strconv.Quote(label+": value is outside int32 range"))
	}
	if kind == typeMessage {
		if msg := reg.messages[typeName(f)]; msg != nil {
			id := fmt.Sprintf("check_%d", f.number)
			fmt.Fprintf(b, "%slet %s = check_%s(%s);\n%sif %s != \"\" { return %s + %s; }\n", indent, id, msg.slangName, v, indent, id, strconv.Quote(label+": "), id)
		}
	}
}

func emitCheckField(b *strings.Builder, m *messageDesc, f *fieldDesc, reg *registry) error {
	name := safeIdentifier(f.name)
	label := m.slangName + "." + name
	if f.mapKey != nil {
		if !isInt32Kind(f.mapKey.kind) && !isInt32Kind(f.mapValue.kind) && f.mapValue.kind != typeMessage {
			return nil
		}
		fmt.Fprintf(b, "    for map_key, map_value in value.%s {\n", name)
		emitCheckValue(b, f.mapKey, f.mapKey.kind, "map_key", label+" map key", "        ", reg)
		if f.mapValue.kind == typeMessage {
			emitCheckValue(b, f, typeMessage, "map_value", label+" map value", "        ", reg)
		} else {
			emitCheckValue(b, f.mapValue, f.mapValue.kind, "map_value", label+" map value", "        ", reg)
		}
		b.WriteString("    }\n")
		return nil
	}
	if !isInt32Kind(f.kind) && f.kind != typeMessage {
		return nil
	}
	if f.label == labelRepeated {
		fmt.Fprintf(b, "    for item in value.%s {\n", name)
		emitCheckValue(b, f, f.kind, "item", label, "        ", reg)
		b.WriteString("    }\n")
		return nil
	}
	if isOptional(f) {
		fmt.Fprintf(b, "    if let item = value.%s {\n", name)
		emitCheckValue(b, f, f.kind, "item", label, "        ", reg)
		b.WriteString("    }\n")
		return nil
	}
	emitCheckValue(b, f, f.kind, "value."+name, label, "    ", reg)
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
