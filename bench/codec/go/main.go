package main

import (
	"bytes"
	"fmt"
	"os"
	"testing"

	"github.com/dolphlabs/grpc/bench/codec/go/codecpb"
	"google.golang.org/protobuf/proto"
)

func fixture() *codecpb.User {
	nick := "A"
	return &codecpb.User{
		Id: 17, Score: -23, Name: "Ada", Avatar: []byte{0x00, 0xff}, Active: true,
		Ratio: 1.5, Balance: -42.25, Color: codecpb.Color_RED,
		Nums: []uint32{1, 300}, OldNums: []int32{-1},
		Address: &codecpb.Address{City: "Lagos"}, Nickname: &nick,
		Labels:  map[string]int32{"role": 3},
		Offices: map[int64]*codecpb.Address{7: {City: "Abuja"}},
		UnsignedCount: 4294967295, UnsignedTotal: 18446744073709551615,
		SignedDelta: -2147483648, FixedCount: 4294967295,
		FixedTotal: 18446744073709551615, SignedFixed: -2147483648,
		SignedFixedTotal: -9223372036854775807,
	}
}

func main() {
	user := fixture()
	wire, err := proto.Marshal(user)
	if err != nil {
		panic(err)
	}
	slangWire, err := os.ReadFile(os.Args[1])
	if err != nil {
		panic(err)
	}
	fmt.Printf("go %d bytes, slang %d bytes, identical: %v\n", len(wire), len(slangWire), bytes.Equal(wire, slangWire))
	var back codecpb.User
	if err := proto.Unmarshal(slangWire, &back); err != nil || !proto.Equal(&back, user) {
		panic(fmt.Sprintf("Go could not decode slang's bytes: %v", err))
	}
	enc := testing.Benchmark(func(b *testing.B) {
		b.ReportAllocs()
		for i := 0; i < b.N; i++ {
			if _, err := proto.Marshal(user); err != nil {
				b.Fatal(err)
			}
		}
	})
	dec := testing.Benchmark(func(b *testing.B) {
		b.ReportAllocs()
		for i := 0; i < b.N; i++ {
			var u codecpb.User
			if err := proto.Unmarshal(wire, &u); err != nil {
				b.Fatal(err)
			}
		}
	})
	fmt.Printf("go encode %d ns/op %d allocs/op %d B/op\n", enc.NsPerOp(), enc.AllocsPerOp(), enc.AllocedBytesPerOp())
	fmt.Printf("go decode %d ns/op %d allocs/op %d B/op\n", dec.NsPerOp(), dec.AllocsPerOp(), dec.AllocedBytesPerOp())
}
