// Package native binds the PolyQuery native kernel library libpqkernels
// (native-kernels/include/pq_kernels.h, ABI version 1) through cgo.
//
// The library is not linked at build time: Load opens it at run time with
// dlopen and resolves every kernel with dlsym, so the engine builds and runs
// without it, and a missing or incompatible library only disables native
// execution. The Go wrappers take slices, check their lengths (a short
// buffer panics instead of corrupting memory) and translate the C status
// conventions into Go results.
//
// Validity and result bitmaps are LSB-first byte arrays (row i is bit i%8 of
// byte i/8; 1 = valid/selected), the layout of the kernels. A nil validity
// slice means "all rows valid".
package native

import (
	"fmt"
	"unsafe"
)

// ABIVersion is the kernel ABI version this binding implements.
const ABIVersion = 1

// Op is a kernel comparison operator (PQK_EQ … PQK_BETWEEN).
type Op int32

// Comparison operators: the predicate holds for x with constants a, b.
const (
	EQ      Op = iota // x == a
	NE                // x != a
	LT                // x <  a
	LE                // x <= a
	GT                // x >  a
	GE                // x >= a
	Between           // a <= x <= b
)

// Negate returns the operator testing the complement on non-NULL values
// (Between has none).
func (op Op) Negate() (Op, bool) {
	switch op {
	case EQ:
		return NE, true
	case NE:
		return EQ, true
	case LT:
		return GE, true
	case LE:
		return GT, true
	case GT:
		return LE, true
	case GE:
		return LT, true
	}
	return op, false
}

// Flip returns the operator with swapped operands (a op x ⇔ x Flip(op) a).
func (op Op) Flip() Op {
	switch op {
	case LT:
		return GT
	case LE:
		return GE
	case GT:
		return LT
	case GE:
		return LE
	}
	return op
}

// Holds evaluates the predicate in Go (reference semantics, used by tests).
func (op Op) Holds(x, a, b int64) bool {
	switch op {
	case EQ:
		return x == a
	case NE:
		return x != a
	case LT:
		return x < a
	case LE:
		return x <= a
	case GT:
		return x > a
	case GE:
		return x >= a
	case Between:
		return a <= x && x <= b
	}
	return false
}

// Status is a kernel status code.
type Status int

// Kernel status codes.
const (
	OK       Status = 0 // PQK_OK
	Overflow Status = 1 // PQK_OVERFLOW
	Invalid  Status = 2 // PQK_EINVAL
)

// BitmapBytes returns the number of bytes of a bitmap of n bits.
func BitmapBytes(n int) int { return (n + 7) >> 3 }

// WordsAsBytes views a little-endian []uint64 bitmap (bit i of word i/64)
// as the equivalent LSB-first byte bitmap without copying.
func WordsAsBytes(words []uint64) []byte {
	if len(words) == 0 {
		return nil
	}
	return unsafe.Slice((*byte)(unsafe.Pointer(&words[0])), len(words)*8)
}

// littleEndian reports whether the host stores integers little-endian
// (the []uint64 bitmaps of the engine are byte-compatible with the kernel
// bitmaps only then).
func littleEndian() bool {
	x := uint16(1)
	return *(*byte)(unsafe.Pointer(&x)) == 1
}

func checkLen(what string, have, need int) {
	if have < need {
		panic(fmt.Sprintf("native: %s buffer too short (%d < %d)", what, have, need))
	}
}

func checkValidity(valid []byte, n int) {
	if valid != nil {
		checkLen("validity", len(valid), BitmapBytes(n))
	}
}
