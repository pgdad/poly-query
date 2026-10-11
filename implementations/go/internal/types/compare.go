package types

import "strings"

// Compare compares two non-NULL values. Both must be of the same kind, except
// that INT64 and DECIMAL values (of any precision and scale) may be mixed:
// they compare by exact mathematical value. DATE vs TIMESTAMP and FLOAT64 vs
// other numerics must be promoted by the caller.
func Compare(ta Type, a Value, tb Type, b Value) int {
	if ta.Kind == KindDecimal || tb.Kind == KindDecimal {
		return compareExact(ta, a, tb, b)
	}
	switch ta.Kind {
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

// compareExact compares INT64/DECIMAL values exactly (types.md §5 as
// amended by CR-2 §4).
func compareExact(ta Type, a Value, tb Type, b Value) int {
	if !ta.IsWide() && !tb.IsWide() {
		return CompareDecimal(a.I, ta.Scale, b.I, tb.Scale)
	}
	return CompareWide(DecimalOf(ta, a), ta.Scale, DecimalOf(tb, b), tb.Scale)
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

// ResultPrecision is the precision W of a decimal result computed from
// operands of types ts (CR-2 §2): 38 if some operand is a wide DECIMAL,
// else 18 (INT64 operands do not count).
func ResultPrecision(ts ...Type) int {
	for _, t := range ts {
		if t.IsWide() {
			return MaxDecimalPrecision
		}
	}
	return NarrowDecimalPrecision
}

// CommonNumeric returns the common numeric type of two numeric types
// (types.md §2 promotion lattice, with result precision W of CR-2).
func CommonNumeric(a, b Type) Type {
	switch {
	case a.Kind == KindFloat64 || b.Kind == KindFloat64:
		return Float64
	case a.Kind == KindDecimal || b.Kind == KindDecimal:
		return Decimal(ResultPrecision(a, b), max(a.Scale, b.Scale))
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
