package main

import (
	"fmt"
	"path/filepath"
	"regexp"
	"strings"
	"unicode/utf8"
)

const (
	labelOptional = 1
	labelRequired = 2
	labelRepeated = 3

	typeDouble   = 1
	typeFloat    = 2
	typeInt64    = 3
	typeUint64   = 4
	typeInt32    = 5
	typeFixed64  = 6
	typeFixed32  = 7
	typeBool     = 8
	typeString   = 9
	typeGroup    = 10
	typeMessage  = 11
	typeBytes    = 12
	typeUint32   = 13
	typeEnum     = 14
	typeSfixed32 = 15
	typeSfixed64 = 16
	typeSint32   = 17
	typeSint64   = 18
)

type fileDesc struct {
	name, pkg, syntax string
	messages          []*messageDesc
	enums             []*enumDesc
	services          []*serviceDesc
}

type messageDesc struct {
	name, fullName, slangName string
	mapEntry                  bool
	fields                    []*fieldDesc
	nested                    []*messageDesc
	enums                     []*enumDesc
}

type fieldDesc struct {
	name, typeName string
	number         int
	label, kind    int
	oneofIndex     int
	proto3Optional bool
	packed         *bool
	mapKey         *fieldDesc
	mapValue       *fieldDesc
}

type enumDesc struct {
	name, fullName, slangName string
	allowAlias                bool
	values                    []enumValue
}

type enumValue struct {
	name   string
	number int64
}

type serviceDesc struct {
	name    string
	methods []methodDesc
}

type methodDesc struct {
	name, inputType, outputType string
	clientStream, serverStream  bool
}

func parseRequest(raw []byte) ([]string, []*fileDesc, error) {
	fields, err := parseWire(raw)
	if err != nil {
		return nil, nil, fmt.Errorf("CodeGeneratorRequest: %w", err)
	}
	var filesToGenerate []string
	var files []*fileDesc
	for _, f := range fields {
		switch f.number {
		case 1:
			if f.wire != 2 || !utf8.Valid(f.bytes) {
				return nil, nil, fmt.Errorf("CodeGeneratorRequest.file_to_generate is not UTF-8")
			}
			filesToGenerate = append(filesToGenerate, string(f.bytes))
		case 15:
			if f.wire != 2 {
				return nil, nil, fmt.Errorf("CodeGeneratorRequest.proto_file has the wrong wire type")
			}
			d, err := parseFile(f.bytes)
			if err != nil {
				return nil, nil, err
			}
			files = append(files, d)
		}
	}
	if len(filesToGenerate) == 0 {
		return nil, nil, fmt.Errorf("protoc supplied no input files")
	}
	return filesToGenerate, files, nil
}

func parseFile(raw []byte) (*fileDesc, error) {
	fields, err := parseWire(raw)
	if err != nil {
		return nil, fmt.Errorf("FileDescriptorProto: %w", err)
	}
	d := &fileDesc{}
	var rawMessages [][]byte
	var rawEnums [][]byte
	var rawServices [][]byte
	for _, f := range fields {
		switch f.number {
		case 1:
			d.name = string(f.bytes)
		case 2:
			d.pkg = string(f.bytes)
		case 4:
			rawMessages = append(rawMessages, f.bytes)
		case 5:
			rawEnums = append(rawEnums, f.bytes)
		case 6:
			rawServices = append(rawServices, f.bytes)
		case 12:
			d.syntax = string(f.bytes)
		}
	}
	if d.name == "" {
		return nil, fmt.Errorf("FileDescriptorProto has no name")
	}
	if !strings.HasSuffix(d.name, ".proto") || !utf8.ValidString(d.name) {
		return nil, fmt.Errorf("FileDescriptorProto name %q must be a UTF-8 .proto path", d.name)
	}
	if d.pkg != "" && !validQualifiedIdentifier(d.pkg) {
		return nil, fmt.Errorf("%s: invalid proto package name %q", d.name, d.pkg)
	}
	for _, child := range rawMessages {
		m, err := parseMessage(child, d.pkg, nil)
		if err != nil {
			return nil, err
		}
		d.messages = append(d.messages, m)
	}
	for _, child := range rawEnums {
		e, err := parseEnum(child, d.pkg, nil)
		if err != nil {
			return nil, err
		}
		d.enums = append(d.enums, e)
	}
	for _, child := range rawServices {
		s, err := parseService(child)
		if err != nil {
			return nil, err
		}
		d.services = append(d.services, s)
	}
	return d, nil
}

func parseMessage(raw []byte, pkg string, parents []string) (*messageDesc, error) {
	return parseMessageDepth(raw, pkg, parents, 0)
}

func parseMessageDepth(raw []byte, pkg string, parents []string, depth int) (*messageDesc, error) {
	if depth > 64 {
		return nil, fmt.Errorf("nested message depth exceeds 64")
	}
	fields, err := parseWire(raw)
	if err != nil {
		return nil, fmt.Errorf("DescriptorProto: %w", err)
	}
	d := &messageDesc{}
	var rawFields [][]byte
	var rawNested [][]byte
	var rawEnums [][]byte
	var rawOneofs [][]byte
	for _, f := range fields {
		switch f.number {
		case 1:
			d.name = string(f.bytes)
		case 2:
			rawFields = append(rawFields, f.bytes)
		case 3:
			rawNested = append(rawNested, f.bytes)
		case 4:
			rawEnums = append(rawEnums, f.bytes)
		case 7:
			opts, err := parseWire(f.bytes)
			if err != nil {
				return nil, fmt.Errorf("%s options: %w", d.name, err)
			}
			for _, opt := range opts {
				if opt.number == 7 && opt.value == 1 {
					d.mapEntry = true
				}
			}
		case 8:
			rawOneofs = append(rawOneofs, f.bytes)
		}
	}
	if !validProtoIdentifier(d.name) {
		return nil, fmt.Errorf("DescriptorProto has invalid name %q", d.name)
	}
	path := append(append([]string(nil), parents...), d.name)
	d.fullName = qualified(pkg, path)
	d.slangName = flattenName(path)
	for i, rawOneof := range rawOneofs {
		of, err := parseWire(rawOneof)
		if err != nil {
			return nil, fmt.Errorf("%s oneof: %w", d.fullName, err)
		}
		name := ""
		for _, part := range of {
			if part.number == 1 {
				name = string(part.bytes)
			}
		}
		if name == "" {
			return nil, fmt.Errorf("%s has an unnamed oneof at index %d", d.fullName, i)
		}
	}
	for _, rawField := range rawFields {
		f, err := parseField(rawField)
		if err != nil {
			return nil, fmt.Errorf("%s field: %w", d.fullName, err)
		}
		d.fields = append(d.fields, f)
	}
	for _, rawChild := range rawNested {
		m, err := parseMessageDepth(rawChild, pkg, path, depth+1)
		if err != nil {
			return nil, err
		}
		d.nested = append(d.nested, m)
	}
	for _, rawEnum := range rawEnums {
		e, err := parseEnum(rawEnum, pkg, path)
		if err != nil {
			return nil, err
		}
		d.enums = append(d.enums, e)
	}
	return d, nil
}

func parseField(raw []byte) (*fieldDesc, error) {
	parts, err := parseWire(raw)
	if err != nil {
		return nil, err
	}
	f := &fieldDesc{oneofIndex: -1}
	for _, p := range parts {
		switch p.number {
		case 1:
			f.name = string(p.bytes)
		case 3:
			f.number = int(p.value)
		case 4:
			f.label = int(p.value)
		case 5:
			f.kind = int(p.value)
		case 6:
			f.typeName = strings.TrimPrefix(string(p.bytes), ".")
		case 8:
			opts, err := parseWire(p.bytes)
			if err != nil {
				return nil, err
			}
			for _, opt := range opts {
				if opt.number == 2 {
					value := opt.value != 0
					f.packed = &value
				}
			}
		case 9:
			f.oneofIndex = int(p.value)
		case 17:
			f.proto3Optional = p.value != 0
		}
	}
	if !validProtoIdentifier(f.name) || f.number < 1 || f.number > (1<<29)-1 || f.label < 1 || f.label > 3 || f.kind < 1 || f.kind > 18 {
		return nil, fmt.Errorf("incomplete or invalid field descriptor")
	}
	if f.kind == typeGroup {
		return nil, fmt.Errorf("field %s uses unsupported GROUP", f.name)
	}
	return f, nil
}

func parseEnum(raw []byte, pkg string, parents []string) (*enumDesc, error) {
	fields, err := parseWire(raw)
	if err != nil {
		return nil, fmt.Errorf("EnumDescriptorProto: %w", err)
	}
	e := &enumDesc{}
	var rawValues [][]byte
	for _, f := range fields {
		switch f.number {
		case 1:
			e.name = string(f.bytes)
		case 2:
			rawValues = append(rawValues, f.bytes)
		case 3:
			options, err := parseWire(f.bytes)
			if err != nil {
				return nil, fmt.Errorf("enum options: %w", err)
			}
			for _, option := range options {
				if option.number == 2 {
					e.allowAlias = option.value != 0
				}
			}
		}
	}
	if !validProtoIdentifier(e.name) {
		return nil, fmt.Errorf("EnumDescriptorProto has invalid name %q", e.name)
	}
	path := append(append([]string(nil), parents...), e.name)
	e.fullName, e.slangName = qualified(pkg, path), flattenName(path)
	seenNames, seenIdentifiers, seenNumbers := map[string]bool{}, map[string]bool{}, map[int64]bool{}
	for _, rv := range rawValues {
		parts, err := parseWire(rv)
		if err != nil {
			return nil, fmt.Errorf("%s value: %w", e.fullName, err)
		}
		v := enumValue{}
		for _, part := range parts {
			if part.number == 1 {
				v.name = string(part.bytes)
			}
			if part.number == 2 {
				v.number = int64(part.value)
			}
		}
		if !validProtoIdentifier(v.name) {
			return nil, fmt.Errorf("%s has invalid enum value name %q", e.fullName, v.name)
		}
		if seenNames[v.name] {
			return nil, fmt.Errorf("%s has duplicate enum value name %q", e.fullName, v.name)
		}
		ident := safeIdentifier(v.name)
		if seenIdentifiers[ident] {
			return nil, fmt.Errorf("%s enum values collide after Slang name conversion at %q", e.fullName, v.name)
		}
		if seenNumbers[v.number] && !e.allowAlias {
			return nil, fmt.Errorf("%s has duplicate numeric values; set option allow_alias = true", e.fullName)
		}
		seenNames[v.name], seenIdentifiers[ident], seenNumbers[v.number] = true, true, true
		e.values = append(e.values, v)
	}
	if len(e.values) == 0 || e.values[0].number != 0 {
		return nil, fmt.Errorf("%s must declare its zero value first", e.fullName)
	}
	return e, nil
}

func parseService(raw []byte) (*serviceDesc, error) {
	fields, err := parseWire(raw)
	if err != nil {
		return nil, fmt.Errorf("ServiceDescriptorProto: %w", err)
	}
	d := &serviceDesc{}
	var rawMethods [][]byte
	for _, f := range fields {
		if f.number == 1 {
			d.name = string(f.bytes)
		}
		if f.number == 2 {
			rawMethods = append(rawMethods, f.bytes)
		}
	}
	if !validProtoIdentifier(d.name) {
		return nil, fmt.Errorf("service descriptor has invalid name %q", d.name)
	}
	for _, rawMethod := range rawMethods {
		m, err := parseMethod(rawMethod)
		if err != nil {
			return nil, err
		}
		d.methods = append(d.methods, m)
	}
	return d, nil
}

func parseMethod(raw []byte) (methodDesc, error) {
	fields, err := parseWire(raw)
	if err != nil {
		return methodDesc{}, fmt.Errorf("MethodDescriptorProto: %w", err)
	}
	var m methodDesc
	for _, f := range fields {
		switch f.number {
		case 1:
			m.name = string(f.bytes)
		case 2:
			m.inputType = strings.TrimPrefix(string(f.bytes), ".")
		case 3:
			m.outputType = strings.TrimPrefix(string(f.bytes), ".")
		case 5:
			m.clientStream = f.value != 0
		case 6:
			m.serverStream = f.value != 0
		}
	}
	if !validProtoIdentifier(m.name) || !validQualifiedIdentifier(m.inputType) || !validQualifiedIdentifier(m.outputType) {
		return m, fmt.Errorf("service method descriptor is incomplete")
	}
	return m, nil
}

func qualified(pkg string, path []string) string {
	name := strings.Join(path, ".")
	if pkg == "" {
		return name
	}
	return pkg + "." + name
}

func flattenName(path []string) string {
	parts := make([]string, len(path))
	for i, p := range path {
		parts[i] = safeIdentifier(p)
	}
	return strings.Join(parts, "_")
}

func outputName(protoName string) string {
	ext := filepath.Ext(protoName)
	base := strings.TrimSuffix(protoName, ext)
	return base + ".pb.sl"
}

var protoIdentifier = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

func validProtoIdentifier(name string) bool {
	return protoIdentifier.MatchString(name)
}

func validQualifiedIdentifier(name string) bool {
	if name == "" {
		return false
	}
	for _, part := range strings.Split(name, ".") {
		if !validProtoIdentifier(part) {
			return false
		}
	}
	return true
}

func safeIdentifier(name string) string {
	var b strings.Builder
	for i, r := range name {
		valid := r == '_' || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || i > 0 && r >= '0' && r <= '9'
		if valid {
			b.WriteRune(r)
		} else {
			b.WriteByte('_')
		}
	}
	out := b.String()
	if out == "" || out[0] >= '0' && out[0] <= '9' {
		out = "_" + out
	}
	if isReserved(out) {
		out += "_"
	}
	return out
}

func isReserved(name string) bool {
	_, ok := reservedNames[name]
	return ok
}

var reservedNames = map[string]struct{}{
	"as": {}, "break": {}, "case": {}, "chan": {}, "continue": {}, "default": {}, "else": {}, "enum": {}, "false": {}, "fn": {}, "for": {}, "gc": {}, "guard": {}, "if": {}, "impl": {}, "in": {}, "let": {}, "match": {}, "mut": {}, "none": {}, "opt": {}, "own": {}, "pub": {}, "result": {}, "return": {}, "self": {}, "spawn": {}, "struct": {}, "switch": {}, "true": {}, "while": {},
	"bool": {}, "bytes": {}, "float": {}, "int": {}, "str": {}, "u8": {}, "u16": {}, "u32": {}, "u64": {}, "i8": {}, "i16": {}, "i32": {}, "i64": {}, "f32": {}, "f64": {},
}
