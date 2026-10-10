package types

import "strings"

// Compare compares two non-NULL values. Both must be of the same kind; DECIMAL
// values may differ in scale. DATE vs TIMESTAMP must be promoted by the caller.
func Compare(ta Type, a Value, tb Type, b Value) int {
	switch ta.Kind {
	case KindDecimal:
		return CompareDecimal(a.I, ta.Scale, b.I, tb.Scale)
	case KindFloat64:
		switch {
		case a.F < b.F:
			return -1
		case a.F > b.F:
			return 1
		}
		return 0
	case KindString:
		return strings.Compare(a.S, b.S)
	case KindNull:
		return 0
	}
	switch {
	case a.I < b.I:
		return -1
	case a.I > b.I:
		return 1
	}
	return 0
}

// CompareSame compares two values of the same type t with NULLs first.
func CompareSame(t Type, a, b Value) int {
	if a.Null || b.Null {
		switch {
		case a.Null && b.Null:
			return 0
		case a.Null:
			return -1
		}
		return 1
	}
	return Compare(t, a, t, b)
}

// Comparable reports whether values of types a and b may be compared
// (types.md §2): identical kinds, numeric vs numeric, DATE vs TIMESTAMP, or
// either side being the null type.
func Comparable(a, b Type) bool {
	if a.Kind == KindNull || b.Kind == KindNull || a.Kind == b.Kind {
		return true
	}
	if a.IsNumeric() && b.IsNumeric() {
		return true
	}
	return a.IsTemporal() && b.IsTemporal()
}

// CommonNumeric returns the common numeric type of two numeric types
// (types.md §2 promotion lattice).
func CommonNumeric(a, b Type) Type {
	switch {
	case a.Kind == KindFloat64 || b.Kind == KindFloat64:
		return Float64
	case a.Kind == KindDecimal && b.Kind == KindDecimal:
		return Decimal(18, max(a.Scale, b.Scale))
	case a.Kind == KindDecimal:
		return Decimal(18, a.Scale)
	case b.Kind == KindDecimal:
		return Decimal(18, b.Scale)
	}
	return Int64
}

// CommonType returns the common type of a and b for comparisons and
// CASE/COALESCE-like unification; ok is false if they have none.
func CommonType(a, b Type) (Type, bool) {
	switch {
	case a.Kind == KindNull:
		return b, true
	case b.Kind == KindNull:
		return a, true
	case a.IsNumeric() && b.IsNumeric():
		if a == b {
			return a, true
		}
		return CommonNumeric(a, b), true
	case a.IsTemporal() && b.IsTemporal():
		if a.Kind == b.Kind {
			return a, true
		}
		return Timestamp, true
	case a.Kind == b.Kind:
		return a, true
	}
	return Type{}, false
}
