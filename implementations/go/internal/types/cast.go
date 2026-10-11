package types

import (
	"math"
	"strconv"

	"polyquery/internal/errs"
)

// CastAllowed reports whether CAST(from AS to) is supported (types.md §8).
func CastAllowed(from, to Type) bool {
	if from.Kind == KindNull || from.Kind == to.Kind || to.Kind == KindString || from.Kind == KindString {
		return true
	}
	switch from.Kind {
	case KindBoolean:
		return to.Kind == KindInt64
	case KindInt64:
		return to.Kind == KindBoolean || to.Kind == KindDecimal || to.Kind == KindFloat64
	case KindDecimal, KindFloat64:
		return to.Kind == KindInt64 || to.Kind == KindDecimal || to.Kind == KindFloat64
	case KindDate:
		return to.Kind == KindTimestamp
	case KindTimestamp:
		return to.Kind == KindDate
	}
	return false
}

func convErr(format string, args ...any) error {
	return errs.New(errs.ConversionError, format, args...)
}

// Cast converts v from type `from` to type `to`. The conversion must be
// allowed by CastAllowed.
func Cast(v Value, from, to Type) (Value, error) {
	if v.Null || from.Kind == KindNull {
		return NullValue, nil
	}
	switch to.Kind {
	case KindBoolean:
		switch from.Kind {
		case KindBoolean:
			return v, nil
		case KindInt64:
			return BoolValue(v.I != 0), nil
		case KindString:
			b, ok := ParseBoolText(TrimASCIISpace(v.S))
			if !ok {
				return Value{}, convErr("cannot convert %q to BOOLEAN", v.S)
			}
			return BoolValue(b), nil
		}
	case KindInt64:
		switch from.Kind {
		case KindInt64, KindBoolean:
			return IntValue(v.I), nil
		case KindDecimal:
			if !from.IsWide() {
				return IntValue(v.I / Pow10[from.Scale]), nil
			}
			q := TruncWide(v.Wide(), from.Scale)
			if !q.IsInt64() {
				return Value{}, overflow("DECIMAL value out of INT64 range")
			}
			return IntValue(q.Int64()), nil
		case KindFloat64:
			t := math.Trunc(v.F)
			if t < -9223372036854775808.0 || t >= 9223372036854775808.0 {
				return Value{}, overflow("FLOAT64 value out of INT64 range")
			}
			return IntValue(int64(t)), nil
		case KindString:
			i, st := ParseIntText(TrimASCIISpace(v.S))
			switch st {
			case TextSyntax:
				return Value{}, convErr("cannot convert %q to INT64", v.S)
			case TextRange:
				return Value{}, overflow("value %q out of INT64 range", v.S)
			}
			return IntValue(i), nil
		}
	case KindFloat64:
		switch from.Kind {
		case KindFloat64:
			return v, nil
		case KindInt64:
			return FloatValue(float64(v.I)), nil
		case KindDecimal:
			return FloatValue(DecimalValueToFloat(v, from)), nil
		case KindString:
			f, st := ParseFloatText(TrimASCIISpace(v.S))
			switch st {
			case TextSyntax:
				return Value{}, convErr("cannot convert %q to FLOAT64", v.S)
			case TextRange:
				return Value{}, overflow("value %q out of FLOAT64 range", v.S)
			}
			return FloatValue(f), nil
		}
	case KindDecimal:
		return castToDecimal(v, from, to)
	case KindString:
		return StringValue(FormatValue(v, from)), nil
	case KindDate:
		switch from.Kind {
		case KindDate:
			return v, nil
		case KindTimestamp:
			return IntValue(TimestampToDate(v.I)), nil
		case KindString:
			d, ok := ParseDate(TrimASCIISpace(v.S))
			if !ok {
				return Value{}, convErr("cannot convert %q to DATE", v.S)
			}
			return IntValue(d), nil
		}
	case KindTimestamp:
		switch from.Kind {
		case KindTimestamp:
			return v, nil
		case KindDate:
			return IntValue(v.I * MicrosPerDay), nil
		case KindString:
			t, ok := ParseTimestamp(TrimASCIISpace(v.S))
			if !ok {
				return Value{}, convErr("cannot convert %q to TIMESTAMP", v.S)
			}
			return IntValue(t), nil
		}
	}
	return Value{}, errs.New(errs.TypeError, "cannot cast %s to %s", from, to)
}

// castToDecimal converts INT64, DECIMAL, FLOAT64 and STRING values to
// DECIMAL type to.
func castToDecimal(v Value, from, to Type) (Value, error) {
	p, s := to.Precision, to.Scale
	switch from.Kind {
	case KindInt64:
		if !to.IsWide() {
			if s > NarrowDecimalPrecision {
				return Value{}, overflow("value does not fit %s", to)
			}
			u, ok := mulCheck(v.I, Pow10[s])
			if !ok || !FitsPrecision(u, p) {
				return Value{}, overflow("value does not fit %s", to)
			}
			return IntValue(u), nil
		}
		x, err := RescaleWide(Int128From(v.I), 0, s, p)
		if err != nil {
			return Value{}, overflow("value does not fit %s", to)
		}
		return WideValue(x), nil
	case KindDecimal:
		if !from.IsWide() && !to.IsWide() {
			u, err := Rescale(v.I, from.Scale, s, p)
			if err != nil {
				return Value{}, err
			}
			return IntValue(u), nil
		}
		x, err := RescaleWide(DecimalOf(from, v), from.Scale, s, p)
		if err != nil {
			return Value{}, err
		}
		return MakeDecimal(to, x), nil
	case KindFloat64:
		x, ok := FloatToDecimal(v.F, p, s)
		if !ok {
			return Value{}, overflow("value does not fit %s", to)
		}
		return MakeDecimal(to, x), nil
	case KindString:
		r, st := ParseDecimalValue(TrimASCIISpace(v.S), to, true)
		switch st {
		case TextSyntax:
			return Value{}, convErr("cannot convert %q to %s", v.S, to)
		case TextRange:
			return Value{}, overflow("value %q does not fit %s", v.S, to)
		}
		return r, nil
	}
	return Value{}, errs.New(errs.TypeError, "cannot cast %s to %s", from, to)
}

// FormatValue renders a non-NULL value as text (used for CAST to STRING):
// DECIMAL canonical form, DATE/TIMESTAMP per §9, booleans as true/false.
func FormatValue(v Value, t Type) string {
	switch t.Kind {
	case KindBoolean:
		if v.I != 0 {
			return "true"
		}
		return "false"
	case KindInt64:
		return strconv.FormatInt(v.I, 10)
	case KindFloat64:
		return FormatFloat(v.F)
	case KindDecimal:
		return FormatDecimalValue(v, t)
	case KindDate:
		return FormatDate(v.I)
	case KindTimestamp:
		return FormatTimestamp(v.I)
	}
	return v.S
}
