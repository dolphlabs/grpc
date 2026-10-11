package main

import (
	"strings"
	"testing"
)

func TestParseWireRejectsMalformedFields(t *testing.T) {
	tests := []struct {
		name string
		wire []byte
		want string
	}{
		{name: "field zero", wire: []byte{0}, want: "invalid field number"},
		{name: "noncanonical tag", wire: []byte{0x88, 0x00, 0}, want: "non-canonical varint"},
		{name: "group", wire: []byte{0x0b}, want: "unsupported protobuf wire type"},
		{name: "truncated length", wire: []byte{0x0a, 0x02, 0x01}, want: "length exceeds remaining bytes"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := parseWire(tt.wire)
			if err == nil || !strings.Contains(err.Error(), tt.want) {
				t.Fatalf("parseWire error = %v, want substring %q", err, tt.want)
			}
		})
	}
}

func TestParseWireCapsDescriptorFieldCount(t *testing.T) {
	raw := make([]byte, 0, (maxDescriptorFields+1)*2)
	for i := 0; i <= maxDescriptorFields; i++ {
		raw = append(raw, 0x08, 0x00) // field 1, varint 0
	}
	_, err := parseWire(raw)
	if err == nil || !strings.Contains(err.Error(), "descriptor exceeds") {
		t.Fatalf("parseWire error = %v, want descriptor field cap", err)
	}
}

func TestParseFileUsesPackageIndependentOfWireOrder(t *testing.T) {
	message := appendStringField(nil, 1, "User")
	var raw []byte
	raw = appendBytesField(raw, 4, message) // message appears before package
	raw = appendStringField(raw, 2, "example.v1")
	raw = appendStringField(raw, 1, "user.proto")
	raw = appendStringField(raw, 12, "proto3")
	file, err := parseFile(raw)
	if err != nil {
		t.Fatal(err)
	}
	if got := file.messages[0].fullName; got != "example.v1.User" {
		t.Fatalf("message full name = %q", got)
	}
}

func TestGenerateRejectsUnsafeAndDuplicateInputs(t *testing.T) {
	for _, name := range []string{"../escape.proto", "dir/../escape.proto", "/absolute.proto", "bad\\path.proto", "bad\nname.proto"} {
		_, err := generate([]string{name}, []*fileDesc{{name: name, syntax: "proto3"}})
		if err == nil || !strings.Contains(err.Error(), "safe relative path") {
			t.Errorf("generate(%q) error = %v, want unsafe path error", name, err)
		}
	}
	file := &fileDesc{name: "user.proto", syntax: "proto3"}
	if _, err := generate([]string{"user.proto", "user.proto"}, []*fileDesc{file}); err == nil || !strings.Contains(err.Error(), "more than once") {
		t.Fatalf("duplicate requested input error = %v", err)
	}
	if _, err := generate([]string{"user.proto"}, []*fileDesc{file, file}); err == nil || !strings.Contains(err.Error(), "duplicate descriptor") {
		t.Fatalf("duplicate descriptor error = %v", err)
	}
}

func TestParseEnumAllowsDeclaredAliases(t *testing.T) {
	zero := appendStringField(nil, 1, "COLOR_UNSPECIFIED")
	zero = appendVarintField(zero, 2, 0)
	one := appendStringField(nil, 1, "COLOR_RED")
	one = appendVarintField(one, 2, 1)
	alias := appendStringField(nil, 1, "COLOR_CRIMSON")
	alias = appendVarintField(alias, 2, 1)
	options := appendVarintField(nil, 2, 1) // EnumOptions.allow_alias
	var raw []byte
	raw = appendStringField(raw, 1, "Color")
	raw = appendBytesField(raw, 2, zero)
	raw = appendBytesField(raw, 2, one)
	raw = appendBytesField(raw, 2, alias)
	raw = appendBytesField(raw, 3, options)
	e, err := parseEnum(raw, "example", nil)
	if err != nil {
		t.Fatal(err)
	}
	if !e.allowAlias || len(e.values) != 3 || e.values[1].number != e.values[2].number {
		t.Fatalf("alias descriptor not preserved: %#v", e)
	}
}

func appendVarintField(raw []byte, number int, value uint64) []byte {
	raw = appendVarint(raw, uint64(number<<3))
	return appendVarint(raw, value)
}
