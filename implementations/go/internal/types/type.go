// Package types implements the PolyQuery type system (spec/data-types/types.md):
// type descriptors, runtime values, exact decimals, dates/timestamps, text
// parsing and formatting, casts and the total ordering of values.
package types

import (
	"fmt"
	"strconv"
	"strings"

	"polyquery/internal/errs"
)

// Kind identifies a type family.
type Kind uint8

// Type kinds. KindNull is the type of the literal NULL; it is coercible to every
// other type and reported as STRING in result metadata.
const (
	KindNull Kind = iota
	KindBoolean
	KindInt64
	KindFloat64
	KindDecimal
	KindString
	KindDate
	KindTimestamp
)

// DECIMAL precision limits: decimals with precision up to
// NarrowDecimalPrecision are "narrow" (int64 unscaled values), wider ones up
// to MaxDecimalPrecision are "wide" (Int128 unscaled values).
const (
	NarrowDecimalPrecision = 18
	MaxDecimalPrecision    = 38
)

// Type is a fully parameterised SQL type.
type Type struct {
	Kind      Kind
	Precision int // DECIMAL only
	Scale     int // DECIMAL only
}

// Frequently used types.
var (
	Null      = Type{Kind: KindNull}
	Boolean   = Type{Kind: KindBoolean}
	Int64     = Type{Kind: KindInt64}
	Float64   = Type{Kind: KindFloat64}
	String    = Type{Kind: KindString}
	Date      = Type{Kind: KindDate}
	Timestamp = Type{Kind: KindTimestamp}
)

// Decimal returns DECIMAL(p,s).
func Decimal(p, s int) Type { return Type{Kind: KindDecimal, Precision: p, Scale: s} }

// IsWide reports whether t is a wide DECIMAL (precision above 18).
func (t Type) IsWide() bool { return t.Kind == KindDecimal && t.Precision > NarrowDecimalPrecision }

// IsNumeric reports whether t is INT64, DECIMAL or FLOAT64.
func (t Type) IsNumeric() bool {
	return t.Kind == KindInt64 || t.Kind == KindDecimal || t.Kind == KindFloat64
}

// IsTemporal reports whether t is DATE or TIMESTAMP.
func (t Type) IsTemporal() bool { return t.Kind == KindDate || t.Kind == KindTimestamp }

// String returns the canonical type name; the null type is "NULL".
func (t Type) String() string {
	switch t.Kind {
	case KindNull:
		return "NULL"
	case KindBoolean:
		return "BOOLEAN"
	case KindInt64:
		return "INT64"
	case KindFloat64:
		return "FLOAT64"
	case KindDecimal:
		return "DECIMAL(" + strconv.Itoa(t.Precision) + "," + strconv.Itoa(t.Scale) + ")"
	case KindString:
		return "STRING"
	case KindDate:
		return "DATE"
	case KindTimestamp:
		return "TIMESTAMP"
	}
	return fmt.Sprintf("Kind(%d)", t.Kind)
}

// ResultName is the type name used in result metadata: the null type is
// reported as STRING.
func (t Type) ResultName() string {
	if t.Kind == KindNull {
		return "STRING"
	}
	return t.String()
}

// Resolve maps a (case-insensitive) type name with optional numeric parameters
// to a Type, applying the aliases of types.md §1. Unknown names and invalid
// parameters produce SEMANTIC_ERROR.
func Resolve(name string, params []int) (Type, error) {
	upper := strings.ToUpper(name)
	simple := func(t Type) (Type, error) {
		if len(params) > 0 {
			return Type{}, errs.New(errs.SemanticError, "type %s takes no parameters", upper)
		}
		return t, nil
	}
	switch upper {
	case "BOOLEAN", "BOOL":
		return simple(Boolean)
	case "INT64", "INT", "INTEGER", "BIGINT":
		return simple(Int64)
	case "FLOAT64", "DOUBLE", "FLOAT", "REAL":
		return simple(Float64)
	case "STRING", "VARCHAR", "TEXT":
		return simple(String)
	case "DATE":
		return simple(Date)
	case "TIMESTAMP":
		return simple(Timestamp)
	case "DECIMAL", "NUMERIC":
		p, s := 18, 0
		switch len(params) {
		case 0:
		case 1:
			p = params[0]
		case 2:
			p, s = params[0], params[1]
		default:
			return Type{}, errs.New(errs.SemanticError, "DECIMAL takes at most two parameters")
		}
		if p < 1 || p > MaxDecimalPrecision || s < 0 || s > p {
			return Type{}, errs.New(errs.SemanticError, "invalid DECIMAL parameters (%d,%d)", p, s)
		}
		return Decimal(p, s), nil
	}
	return Type{}, errs.New(errs.SemanticError, "unknown type %q", name)
}

// ParseTypeName parses a textual type such as "decimal(10, 2)" or "BIGINT".
func ParseTypeName(text string) (Type, error) {
	s := strings.TrimSpace(text)
	name, rest := s, ""
	if i := strings.IndexByte(s, '('); i >= 0 {
		name, rest = strings.TrimSpace(s[:i]), strings.TrimSpace(s[i:])
	}
	if name == "" {
		return Type{}, errs.New(errs.SemanticError, "empty type name")
	}
	for _, c := range name {
		if !(c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9') {
			return Type{}, errs.New(errs.SemanticError, "invalid type name %q", text)
		}
	}
	var params []int
	if rest != "" {
		if !strings.HasSuffix(rest, ")") {
			return Type{}, errs.New(errs.SemanticError, "invalid type name %q", text)
		}
		for _, part := range strings.Split(rest[1:len(rest)-1], ",") {
			part = strings.TrimSpace(part)
			n, err := strconv.Atoi(part)
			if err != nil || part == "" || part[0] < '0' || part[0] > '9' {
				return Type{}, errs.New(errs.SemanticError, "invalid type parameter in %q", text)
			}
			params = append(params, n)
		}
	}
	return Resolve(name, params)
}
