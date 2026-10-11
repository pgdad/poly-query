package types

// Value is a runtime value. The interpretation of the payload depends on the
// static type of the expression or column producing it:
//
//	BOOLEAN    I (0 or 1)
//	INT64      I
//	DECIMAL    narrow (p ≤ 18): I (unscaled; value = I / 10^scale)
//	           wide (p > 18): the 128-bit unscaled value Hi·2⁶⁴ + uint64(I)
//	DATE       I (days since 1970-01-01)
//	TIMESTAMP  I (microseconds since 1970-01-01 00:00:00)
//	FLOAT64    F
//	STRING     S
//
// Null marks SQL NULL for any type.
type Value struct {
	Null bool
	I    int64
	F    float64
	S    string
	Hi   int64 // high word of a wide DECIMAL; zero for every other type
}

// NullValue is the SQL NULL.
var NullValue = Value{Null: true}

// IntValue makes an INT64 (or DECIMAL unscaled, DATE, TIMESTAMP) value.
func IntValue(i int64) Value { return Value{I: i} }

// WideValue makes a wide DECIMAL value from its unscaled value.
func WideValue(x Int128) Value { return Value{I: int64(x.Lo), Hi: x.Hi} }

// Wide returns the unscaled value of a wide DECIMAL.
func (v Value) Wide() Int128 { return Int128{Hi: v.Hi, Lo: uint64(v.I)} }

// FloatValue makes a FLOAT64 value.
func FloatValue(f float64) Value { return Value{F: f} }

// StringValue makes a STRING value.
func StringValue(s string) Value { return Value{S: s} }

// BoolValue makes a BOOLEAN value.
func BoolValue(b bool) Value {
	if b {
		return Value{I: 1}
	}
	return Value{}
}

// IsTrue reports whether a BOOLEAN value is non-NULL TRUE.
func (v Value) IsTrue() bool { return !v.Null && v.I != 0 }

// Row is a tuple of values.
type Row []Value
