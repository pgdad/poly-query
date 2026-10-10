package types

// Value is a runtime value. The interpretation of the payload depends on the
// static type of the expression or column producing it:
//
//	BOOLEAN    I (0 or 1)
//	INT64      I
//	DECIMAL    I (unscaled; value = I / 10^scale)
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
}

// NullValue is the SQL NULL.
var NullValue = Value{Null: true}

// IntValue makes an INT64 (or DECIMAL unscaled, DATE, TIMESTAMP) value.
func IntValue(i int64) Value { return Value{I: i} }

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
