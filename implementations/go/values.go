package polyquery

import (
	"math/big"
	"time"

	"polyquery/internal/storage"
	"polyquery/internal/types"
)

// Kind identifies a type family.
type Kind uint8

// The type kinds. The zero Kind is invalid.
const (
	KindBoolean Kind = iota + 1
	KindInt64
	KindFloat64
	KindDecimal
	KindString
	KindDate
	KindTimestamp
)

// Type is a column type. Precision and Scale are only meaningful for
// KindDecimal.
type Type struct {
	Kind      Kind
	Precision int
	Scale     int
}

// The parameterless types.
var (
	TypeBoolean   = Type{Kind: KindBoolean}
	TypeInt64     = Type{Kind: KindInt64}
	TypeFloat64   = Type{Kind: KindFloat64}
	TypeString    = Type{Kind: KindString}
	TypeDate      = Type{Kind: KindDate}
	TypeTimestamp = Type{Kind: KindTimestamp}
)

// DecimalType returns DECIMAL(precision, scale); 1 ≤ precision ≤ 38 and
// 0 ≤ scale ≤ precision.
func DecimalType(precision, scale int) Type {
	return Type{Kind: KindDecimal, Precision: precision, Scale: scale}
}

// ParseType parses a type name such as "INT64", "BIGINT", "DECIMAL(18,2)"
// or "VARCHAR" (the names and aliases of spec/data-types/types.md §1).
func ParseType(name string) (Type, error) {
	t, err := types.ParseTypeName(name)
	if err != nil {
		return Type{}, wrapError(err)
	}
	return fromInternalType(t), nil
}

// String returns the canonical type name, e.g. "DECIMAL(18,2)".
func (t Type) String() string {
	it, err := t.internal()
	if err != nil {
		return "INVALID"
	}
	return it.String()
}

func (t Type) internal() (types.Type, error) {
	switch t.Kind {
	case KindBoolean:
		return types.Boolean, nil
	case KindInt64:
		return types.Int64, nil
	case KindFloat64:
		return types.Float64, nil
	case KindString:
		return types.String, nil
	case KindDate:
		return types.Date, nil
	case KindTimestamp:
		return types.Timestamp, nil
	case KindDecimal:
		if t.Precision < 1 || t.Precision > types.MaxDecimalPrecision || t.Scale < 0 || t.Scale > t.Precision {
			return types.Type{}, newError(CodeInvalidArgument, "invalid DECIMAL(%d,%d)", t.Precision, t.Scale)
		}
		return types.Decimal(t.Precision, t.Scale), nil
	}
	return types.Type{}, newError(CodeInvalidArgument, "invalid type kind %d", t.Kind)
}

// fromInternalType maps an engine type; the untyped NULL type is reported
// as STRING (as in query results of the protocol).
func fromInternalType(t types.Type) Type {
	switch t.Kind {
	case types.KindBoolean:
		return TypeBoolean
	case types.KindInt64:
		return TypeInt64
	case types.KindFloat64:
		return TypeFloat64
	case types.KindDecimal:
		return DecimalType(t.Precision, t.Scale)
	case types.KindDate:
		return TypeDate
	case types.KindTimestamp:
		return TypeTimestamp
	}
	return TypeString
}

// Column is a named, typed column of a table or result.
type Column struct {
	Name string
	Type Type
}

func fromColumnDefs(defs []storage.ColumnDef) []Column {
	cols := make([]Column, len(defs))
	for i, d := range defs {
		cols[i] = Column{Name: d.Name, Type: fromInternalType(d.Type)}
	}
	return cols
}

func toColumnDefs(cols []Column) ([]storage.ColumnDef, error) {
	defs := make([]storage.ColumnDef, len(cols))
	for i, c := range cols {
		t, err := c.Type.internal()
		if err != nil {
			return nil, newError(CodeInvalidArgument, "column %q: %s", c.Name, err.(*Error).Message)
		}
		defs[i] = storage.ColumnDef{Name: c.Name, Type: t}
	}
	return defs, nil
}

// ---------------------------------------------------------------- Decimal

// Decimal is an exact decimal number: an unscaled integer of up to 38
// digits times 10^-Scale. The zero value is 0 with scale 0.
type Decimal struct {
	unscaled types.Int128
	scale    int
}

// NewDecimal returns unscaled × 10^-scale (0 ≤ scale ≤ 38).
func NewDecimal(unscaled int64, scale int) Decimal {
	return Decimal{unscaled: types.Int128From(unscaled), scale: min(max(scale, 0), types.MaxDecimalPrecision)}
}

// DecimalFromBig returns unscaled × 10^-scale; the unscaled value must
// have at most 38 digits.
func DecimalFromBig(unscaled *big.Int, scale int) (Decimal, error) {
	x, ok := types.Int128FromBig(unscaled)
	if !ok || !types.FitsWide(x, types.MaxDecimalPrecision) {
		return Decimal{}, newError(CodeNumericOverflow, "decimal has more than 38 digits")
	}
	if scale < 0 || scale > types.MaxDecimalPrecision {
		return Decimal{}, newError(CodeInvalidArgument, "invalid decimal scale %d", scale)
	}
	return Decimal{unscaled: x, scale: scale}, nil
}

// ParseDecimal parses decimal text such as "-12.50" (optional sign,
// digits, optional fraction; no exponent). The scale is the number of
// fractional digits.
func ParseDecimal(s string) (Decimal, error) {
	text := s
	neg := false
	if text != "" && (text[0] == '-' || text[0] == '+') {
		neg = text[0] == '-'
		text = text[1:]
	}
	digits := make([]byte, 0, len(text))
	scale, seenDot := 0, false
	for i := 0; i < len(text); i++ {
		c := text[i]
		switch {
		case c >= '0' && c <= '9':
			digits = append(digits, c)
			if seenDot {
				scale++
			}
		case c == '.' && !seenDot:
			seenDot = true
		default:
			return Decimal{}, newError(CodeConversionError, "invalid decimal %q", s)
		}
	}
	if len(digits) == 0 {
		return Decimal{}, newError(CodeConversionError, "invalid decimal %q", s)
	}
	u, ok := new(big.Int).SetString(string(digits), 10)
	if !ok {
		return Decimal{}, newError(CodeConversionError, "invalid decimal %q", s)
	}
	if neg {
		u.Neg(u)
	}
	d, err := DecimalFromBig(u, scale)
	if err != nil {
		return Decimal{}, newError(CodeNumericOverflow, "decimal %q has more than 38 digits", s)
	}
	return d, nil
}

// Scale returns the number of fractional digits.
func (d Decimal) Scale() int { return d.scale }

// Unscaled returns the unscaled integer value.
func (d Decimal) Unscaled() *big.Int { return d.unscaled.Big() }

// UnscaledInt64 returns the unscaled value if it fits an int64.
func (d Decimal) UnscaledInt64() (int64, bool) {
	return d.unscaled.Int64(), d.unscaled.IsInt64()
}

// Sign returns -1, 0 or +1.
func (d Decimal) Sign() int { return d.unscaled.Sign() }

// Cmp compares d and e numerically (scales may differ): -1, 0 or +1.
func (d Decimal) Cmp(e Decimal) int {
	return types.CompareWide(d.unscaled, d.scale, e.unscaled, e.scale)
}

// Rat returns the exact value as a rational number.
func (d Decimal) Rat() *big.Rat {
	den := new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(d.scale)), nil)
	return new(big.Rat).SetFrac(d.Unscaled(), den)
}

// Float64 returns the nearest binary64 value.
func (d Decimal) Float64() float64 { return types.WideToFloat(d.unscaled, d.scale) }

// String returns the canonical text with exactly Scale fractional digits,
// e.g. "-0.50" (spec/data-types/types.md §9).
func (d Decimal) String() string { return types.FormatWide(d.unscaled, d.scale) }

// rescale converts d exactly to scale s with at most p digits.
func (d Decimal) rescale(p, s int) (types.Int128, error) {
	x := d.unscaled
	if d.scale != s {
		u := d.Unscaled()
		if s > d.scale {
			u.Mul(u, new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(s-d.scale)), nil))
		} else {
			q, r := new(big.Int).QuoRem(u, new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(d.scale-s)), nil), new(big.Int))
			if r.Sign() != 0 {
				return x, newError(CodeInvalidArgument, "decimal %s does not fit scale %d exactly", d, s)
			}
			u = q
		}
		var ok bool
		if x, ok = types.Int128FromBig(u); !ok {
			return x, newError(CodeNumericOverflow, "decimal %s does not fit DECIMAL(%d,%d)", d, p, s)
		}
	}
	if !types.FitsWide(x, p) {
		return x, newError(CodeNumericOverflow, "decimal %s does not fit DECIMAL(%d,%d)", d, p, s)
	}
	return x, nil
}

// ---------------------------------------------------------------- dates

// Date is a calendar date (proleptic Gregorian) as the number of days
// since 1970-01-01.
type Date int64

// DateOf returns the date year-month-day; ok is false for an invalid
// calendar date or a year outside 1–9999.
func DateOf(year, month, day int) (d Date, ok bool) {
	if year < 1 || year > 9999 || !types.ValidDate(int64(year), int64(month), int64(day)) {
		return 0, false
	}
	return Date(types.DaysFromCivil(int64(year), int64(month), int64(day))), true
}

// ParseDate parses "YYYY-MM-DD".
func ParseDate(s string) (Date, error) {
	days, ok := types.ParseDate(s)
	if !ok {
		return 0, newError(CodeConversionError, "invalid date %q", s)
	}
	return Date(days), nil
}

// YMD returns the calendar fields.
func (d Date) YMD() (year, month, day int) {
	y, m, dd := types.CivilFromDays(int64(d))
	return int(y), int(m), int(dd)
}

// Time returns midnight UTC of the date.
func (d Date) Time() time.Time { return time.Unix(int64(d)*86400, 0).UTC() }

// String returns "YYYY-MM-DD".
func (d Date) String() string { return types.FormatDate(int64(d)) }

// Timestamp is a date and time without time zone as the number of
// microseconds since 1970-01-01 00:00:00.
type Timestamp int64

// TimestampOf converts a time.Time (its wall clock in UTC) to a Timestamp,
// truncating to microseconds.
func TimestampOf(t time.Time) Timestamp { return Timestamp(t.UnixMicro()) }

// ParseTimestamp parses timestamp text ("YYYY-MM-DD HH:MM:SS[.ffffff]",
// spec/data-types/types.md §3).
func ParseTimestamp(s string) (Timestamp, error) {
	us, ok := types.ParseTimestamp(s)
	if !ok {
		return 0, newError(CodeConversionError, "invalid timestamp %q", s)
	}
	return Timestamp(us), nil
}

// Time returns the timestamp as a UTC time.Time.
func (t Timestamp) Time() time.Time { return time.UnixMicro(int64(t)).UTC() }

// String returns "YYYY-MM-DD HH:MM:SS" or, with a microsecond part,
// "YYYY-MM-DD HH:MM:SS.ffffff".
func (t Timestamp) String() string { return types.FormatTimestamp(int64(t)) }

// ---------------------------------------------------------------- values

// toNative converts an engine value of type t to its Go representation
// (see the package documentation).
func toNative(v types.Value, t types.Type) any {
	if v.Null {
		return nil
	}
	switch t.Kind {
	case types.KindBoolean:
		return v.I != 0
	case types.KindInt64:
		return v.I
	case types.KindFloat64:
		return v.F
	case types.KindDecimal:
		return Decimal{unscaled: types.DecimalOf(t, v), scale: t.Scale}
	case types.KindString:
		return v.S
	case types.KindDate:
		return Date(v.I)
	case types.KindTimestamp:
		return Timestamp(v.I)
	}
	return nil // the untyped NULL type only has NULL values
}

// fromNative converts a Go value to an engine value of type t.
func fromNative(x any, t types.Type) (types.Value, error) {
	if x == nil {
		return types.NullValue, nil
	}
	mismatch := func() (types.Value, error) {
		return types.Value{}, newError(CodeTypeError, "a %T value cannot be stored in a %s column", x, t)
	}
	switch t.Kind {
	case types.KindBoolean:
		if b, ok := x.(bool); ok {
			return types.BoolValue(b), nil
		}
	case types.KindInt64:
		switch n := x.(type) {
		case int64:
			return types.IntValue(n), nil
		case int:
			return types.IntValue(int64(n)), nil
		case int32:
			return types.IntValue(int64(n)), nil
		}
	case types.KindFloat64:
		if f, ok := x.(float64); ok {
			return types.FloatValue(f), nil
		}
	case types.KindDecimal:
		var d Decimal
		switch n := x.(type) {
		case Decimal:
			d = n
		case int64:
			d = NewDecimal(n, 0)
		case int:
			d = NewDecimal(int64(n), 0)
		default:
			return mismatch()
		}
		u, err := d.rescale(t.Precision, t.Scale)
		if err != nil {
			return types.Value{}, err
		}
		return types.MakeDecimal(t, u), nil
	case types.KindString:
		if s, ok := x.(string); ok {
			return types.StringValue(s), nil
		}
	case types.KindDate:
		switch d := x.(type) {
		case Date:
			return types.IntValue(int64(d)), nil
		case time.Time:
			y, m, dd := d.Date()
			return types.IntValue(types.DaysFromCivil(int64(y), int64(m), int64(dd))), nil
		}
	case types.KindTimestamp:
		switch ts := x.(type) {
		case Timestamp:
			return types.IntValue(int64(ts)), nil
		case time.Time:
			return types.IntValue(ts.UnixMicro()), nil
		}
	}
	return mismatch()
}
