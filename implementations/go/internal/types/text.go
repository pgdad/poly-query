package types

import (
	"math"
	"strconv"
	"strings"
)

// TextStatus classifies the outcome of parsing text into a typed value.
type TextStatus uint8

// Parse outcomes: valid, syntactically invalid, or valid syntax but out of range.
const (
	TextOK TextStatus = iota
	TextSyntax
	TextRange
)

// TrimSpaceTab trims ASCII spaces and tabs (ingestion trimming rule).
func TrimSpaceTab(s string) string {
	i, j := 0, len(s)
	for i < j && (s[i] == ' ' || s[i] == '\t') {
		i++
	}
	for j > i && (s[j-1] == ' ' || s[j-1] == '\t') {
		j--
	}
	return s[i:j]
}

// TrimASCIISpace trims ASCII whitespace (CAST trimming rule).
func TrimASCIISpace(s string) string {
	return strings.Trim(s, " \t\n\r\f\v")
}

// ParseBoolText accepts "true"/"false" case-insensitively.
func ParseBoolText(s string) (bool, bool) {
	switch {
	case strings.EqualFold(s, "true"):
		return true, true
	case strings.EqualFold(s, "false"):
		return false, true
	}
	return false, false
}

// ParseIntText parses ^[+-]?[0-9]+$ into an int64.
func ParseIntText(s string) (int64, TextStatus) {
	i := 0
	if i < len(s) && (s[i] == '+' || s[i] == '-') {
		i++
	}
	if i == len(s) {
		return 0, TextSyntax
	}
	for k := i; k < len(s); k++ {
		if s[k] < '0' || s[k] > '9' {
			return 0, TextSyntax
		}
	}
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return 0, TextRange
	}
	return v, TextOK
}

// IsFloatSyntax matches ^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$.
func IsFloatSyntax(s string) bool {
	i, n := 0, len(s)
	if i < n && (s[i] == '+' || s[i] == '-') {
		i++
	}
	intDigits := 0
	for i < n && s[i] >= '0' && s[i] <= '9' {
		i++
		intDigits++
	}
	fracDigits := 0
	if i < n && s[i] == '.' {
		i++
		for i < n && s[i] >= '0' && s[i] <= '9' {
			i++
			fracDigits++
		}
	}
	if intDigits == 0 && fracDigits == 0 {
		return false
	}
	if i < n && (s[i] == 'e' || s[i] == 'E') {
		i++
		if i < n && (s[i] == '+' || s[i] == '-') {
			i++
		}
		expDigits := 0
		for i < n && s[i] >= '0' && s[i] <= '9' {
			i++
			expDigits++
		}
		if expDigits == 0 {
			return false
		}
	}
	return i == n
}

// ParseFloatText parses float syntax into a finite FLOAT64.
func ParseFloatText(s string) (float64, TextStatus) {
	if !IsFloatSyntax(s) {
		return 0, TextSyntax
	}
	f, err := strconv.ParseFloat(s, 64)
	if err != nil {
		if ne, ok := err.(*strconv.NumError); ok && ne.Err == strconv.ErrRange && !math.IsInf(f, 0) {
			return f, TextOK // underflow to (sub)normal/zero
		}
		return 0, TextRange
	}
	if math.IsInf(f, 0) || math.IsNaN(f) {
		return 0, TextRange
	}
	return f, TextOK
}

// decimalParts splits ^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)$ into sign, integer
// digits without leading zeros, and fractional digits.
func decimalParts(s string) (neg bool, intPart, frac string, ok bool) {
	i := 0
	if i < len(s) && (s[i] == '+' || s[i] == '-') {
		neg = s[i] == '-'
		i++
	}
	start := i
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		i++
	}
	intPart = s[start:i]
	if i < len(s) && s[i] == '.' {
		i++
		fs := i
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			i++
		}
		frac = s[fs:i]
	}
	if i != len(s) || (intPart == "" && frac == "") {
		return false, "", "", false
	}
	intPart = strings.TrimLeft(intPart, "0")
	return neg, intPart, frac, true
}

func digitsValue(d string) int64 {
	var v int64
	for i := 0; i < len(d); i++ {
		v = v*10 + int64(d[i]-'0')
	}
	return v
}

// ParseDecimalExact parses decimal text for DECIMAL(p,s) without rounding
// (ingestion rule): at most s fractional digits and at most p-s integer digits.
func ParseDecimalExact(text string, p, s int) (int64, TextStatus) {
	neg, ip, frac, ok := decimalParts(text)
	if !ok {
		return 0, TextSyntax
	}
	if len(frac) > s || len(ip) > p-s {
		return 0, TextRange
	}
	v := digitsValue(ip)*Pow10[s] + digitsValue(frac)*Pow10[s-len(frac)]
	if neg {
		v = -v
	}
	return v, TextOK
}

// ParseDecimalRound parses decimal text for DECIMAL(p,s), rounding extra
// fractional digits half away from zero (CAST rule).
func ParseDecimalRound(text string, p, s int) (int64, TextStatus) {
	neg, ip, frac, ok := decimalParts(text)
	if !ok {
		return 0, TextSyntax
	}
	if len(ip) > p-s {
		return 0, TextRange
	}
	roundUp := false
	if len(frac) > s {
		roundUp = frac[s] >= '5'
		frac = frac[:s]
	}
	v := digitsValue(ip)*Pow10[s] + digitsValue(frac)*Pow10[s-len(frac)]
	if roundUp {
		v++
	}
	if !FitsPrecision(v, p) {
		return 0, TextRange
	}
	if neg {
		v = -v
	}
	return v, TextOK
}

// AppendFloat appends a FLOAT64 as a JSON number that round-trips exactly;
// -0 is normalised to 0 and integral values keep a ".0" suffix.
func AppendFloat(b []byte, f float64) []byte {
	if f == 0 {
		return append(b, "0.0"...)
	}
	start := len(b)
	b = strconv.AppendFloat(b, f, 'g', -1, 64)
	for _, c := range b[start:] {
		if c == '.' || c == 'e' || c == 'n' || c == 'N' {
			return b
		}
	}
	return append(b, ".0"...)
}

// FormatFloat renders a FLOAT64 via AppendFloat.
func FormatFloat(f float64) string { return string(AppendFloat(nil, f)) }
