package main

import (
	"errors"
	"fmt"
)

type wireField struct {
	number int
	wire   int
	value  uint64
	bytes  []byte
}

const maxDescriptorFields = 100000

func readVarint(raw []byte, at *int) (uint64, error) {
	var value uint64
	for shift := uint(0); shift <= 63; shift += 7 {
		if *at >= len(raw) {
			return 0, errors.New("truncated varint")
		}
		b := raw[*at]
		*at++
		if shift == 63 && b > 1 {
			return 0, errors.New("varint overflows uint64")
		}
		value |= uint64(b&0x7f) << shift
		if b < 0x80 {
			if shift > 0 && b == 0 {
				return 0, errors.New("non-canonical varint")
			}
			return value, nil
		}
	}
	return 0, errors.New("varint exceeds ten bytes")
}

func parseWire(raw []byte) ([]wireField, error) {
	out := make([]wireField, 0, 16)
	for at := 0; at < len(raw); {
		tag, err := readVarint(raw, &at)
		if err != nil {
			return nil, err
		}
		number := int(tag >> 3)
		wire := int(tag & 7)
		if number < 1 || number > (1<<29)-1 {
			return nil, fmt.Errorf("invalid field number %d", number)
		}
		f := wireField{number: number, wire: wire}
		switch wire {
		case 0:
			f.value, err = readVarint(raw, &at)
		case 1:
			if len(raw)-at < 8 {
				err = errors.New("truncated fixed64")
			} else {
				f.bytes = raw[at : at+8]
				at += 8
			}
		case 2:
			var n uint64
			n, err = readVarint(raw, &at)
			if err == nil {
				if n > uint64(len(raw)-at) {
					err = errors.New("length exceeds remaining bytes")
				} else {
					f.bytes = raw[at : at+int(n)]
					at += int(n)
				}
			}
		case 5:
			if len(raw)-at < 4 {
				err = errors.New("truncated fixed32")
			} else {
				f.bytes = raw[at : at+4]
				at += 4
			}
		default:
			err = fmt.Errorf("unsupported protobuf wire type %d", wire)
		}
		if err != nil {
			return nil, fmt.Errorf("field %d: %w", number, err)
		}
		if len(out) >= maxDescriptorFields {
			return nil, fmt.Errorf("descriptor exceeds %d fields", maxDescriptorFields)
		}
		out = append(out, f)
	}
	return out, nil
}

func appendVarint(out []byte, value uint64) []byte {
	for value > 0x7f {
		out = append(out, byte(value)|0x80)
		value >>= 7
	}
	return append(out, byte(value))
}

func appendBytesField(out []byte, number int, value []byte) []byte {
	out = appendVarint(out, uint64(number<<3|2))
	out = appendVarint(out, uint64(len(value)))
	return append(out, value...)
}

func appendStringField(out []byte, number int, value string) []byte {
	return appendBytesField(out, number, []byte(value))
}
