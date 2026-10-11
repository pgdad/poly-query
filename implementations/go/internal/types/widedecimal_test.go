package types

import (
	"math/big"
	"testing"

	"polyquery/internal/errs"
)

func wide(t *testing.T, s string) Int128 {
	t.Helper()
	x, st := ParseWideRound(s, 38, 0)
	if st != TextOK {
		t.Fatalf("ParseWideRound(%q) = %v", s, st)
	}
	return x
}

func TestInt128FormatParse(t *testing.T) {
	for _, s := range []string{"0", "1", "-1", "9223372036854775807", "-9223372036854775808",
		"18446744073709551616", "-99999999999999999999999999999999999999", "10000000000000000000000000000000000000",
		"12345678901234567890123456789012345678"} {
		x := wide(t, s)
		if got := x.String(); got != s {
			t.Errorf("String(parse(%q)) = %q", s, got)
		}
		b, _ := new(big.Int).SetString(s, 10)
		if x.Big().Cmp(b) != 0 {
			t.Errorf("Big(%s) = %s", s, x.Big())
		}
		if y, ok := Int128FromBig(b); !ok || y != x {
			t.Errorf("Int128FromBig(%s) = %v", s, y)
		}
	}
	cases := map[string]string{"0.0000000001": "0.0000000001", "-0.5": "-0.5000000000", "12345678901234567890.123456789": "12345678901234567890.1234567890"}
	for in, want := range cases {
		x, st := ParseWideExact(in, 38, 10)
		if st != TextOK {
			t.Fatalf("ParseWideExact(%q) = %v", in, st)
		}
		if got := FormatWide(x, 10); got != want {
			t.Errorf("FormatWide(%q) = %q, want %q", in, got, want)
		}
	}
	if _, st := ParseWideExact("123.456", 38, 2); st != TextRange {
		t.Errorf("extra fractional digits accepted")
	}
	if _, st := ParseWideRound("999999999999999999999999999999999999999", 38, 0); st != TextRange {
		t.Errorf("39 digits accepted")
	}
	if x, st := ParseWideRound("9.995", 20, 2); st != TextOK || FormatWide(x, 2) != "10.00" {
		t.Errorf("round 9.995 = %s", FormatWide(x, 2))
	}
}

func TestWideArithmetic(t *testing.T) {
	max38 := wide(t, "99999999999999999999999999999999999998")
	if c, err := AddWide(max38, 0, Int128From(1), 0); err != nil || c.String() != "99999999999999999999999999999999999999" {
		t.Errorf("max-1 + 1 = %v, %v", c, err)
	}
	if _, err := AddWide(max38, 0, Int128From(2), 0); !errs.Is(err, errs.NumericOverflow) {
		t.Errorf("expected overflow, got %v", err)
	}
	if _, err := AddWide(max38, 0, max38, 0); !errs.Is(err, errs.NumericOverflow) {
		t.Errorf("expected overflow beyond 2^127, got %v", err)
	}
	if c, err := SubWide(Int128From(5), 1, Int128From(125), 2); err != nil || FormatWide(c, 2) != "-0.75" {
		t.Errorf("0.5-1.25 = %v, %v", FormatWide(c, 2), err)
	}
	a, b := wide(t, "12345678901234567890"), wide(t, "12345678901234567")
	if c, err := MulDecimalWide(a, b); err != nil || c.String() != "152415787532388356514250977776253630" {
		t.Errorf("product = %v, %v", c, err)
	}
	if _, err := MulDecimalWide(wide(t, "100000000000000000000"), wide(t, "10000000000000000000")); !errs.Is(err, errs.NumericOverflow) {
		t.Errorf("expected overflow, got %v", err)
	}
	if _, err := MulDecimalWide(max38, max38); !errs.Is(err, errs.NumericOverflow) {
		t.Errorf("expected overflow of a 76-digit product, got %v", err)
	}
	if c, err := MulDecimalWide(Int128From(-3), wide(t, "-4")); err != nil || c.String() != "12" {
		t.Errorf("-3*-4 = %v", c)
	}
}

func TestWideRescaleAndRounding(t *testing.T) {
	cases := []struct {
		in       string
		from, to int
		want     string
	}{
		{"125", 2, 1, "13"}, {"-125", 2, 1, "-13"}, {"-124", 2, 1, "-12"},
		{"1", 0, 37, "10000000000000000000000000000000000000"},
		{"5", 38, 0, "0"}, {"50000000000000000000000000000000000000", 38, 0, "1"},
	}
	for _, c := range cases {
		x, err := RescaleWide(wide(t, c.in), c.from, c.to, 38)
		if err != nil || x.String() != c.want {
			t.Errorf("Rescale(%s, %d→%d) = %v, %v; want %s", c.in, c.from, c.to, x, err, c.want)
		}
	}
	if _, err := RescaleWide(Int128From(10), 0, 37, 38); !errs.Is(err, errs.NumericOverflow) {
		t.Errorf("expected overflow, got %v", err)
	}
	if got := FloorWide(Int128From(-25), 1).String(); got != "-3" {
		t.Errorf("floor(-2.5) = %s", got)
	}
	if got := CeilWide(Int128From(-25), 1).String(); got != "-2" {
		t.Errorf("ceil(-2.5) = %s", got)
	}
	if got := TruncWide(wide(t, "-1234599"), 2).String(); got != "-12345" {
		t.Errorf("trunc = %s", got)
	}
}

func TestExactComparison(t *testing.T) {
	maxInt := IntValue(9223372036854775807)
	if Compare(Int64, maxInt, Decimal(2, 1), IntValue(15)) <= 0 {
		t.Errorf("9223372036854775807 > 1.5 failed")
	}
	d := Decimal(38, 37)
	tenth, _ := ParseDecimalValue("0.1", d, false)
	if Compare(d, tenth, Decimal(1, 1), IntValue(1)) != 0 {
		t.Errorf("0.1 (38,37) = 0.1 failed")
	}
	big1, _ := ParseDecimalValue("12345678901234567890.00", Decimal(22, 2), false)
	big2, _ := ParseDecimalValue("12345678901234567890.0", Decimal(21, 1), false)
	if Compare(Decimal(22, 2), big1, Decimal(21, 1), big2) != 0 {
		t.Errorf("wide equality across scales failed")
	}
	if Compare(Decimal(38, 0), WideValue(wide(t, "-99999999999999999999999999999999999999")), Decimal(38, 38), WideValue(Int128From(1))) >= 0 {
		t.Errorf("negative huge < tiny failed")
	}
}

func TestWideCasts(t *testing.T) {
	v, err := Cast(FloatValue(0.1), Float64, Decimal(38, 30))
	if err != nil || FormatValue(v, Decimal(38, 30)) != "0.100000000000000005551115123126" {
		t.Errorf("CAST(0.1e0 AS DECIMAL(38,30)) = %s, %v", FormatValue(v, Decimal(38, 30)), err)
	}
	src := Decimal(38, 0)
	x, _ := ParseDecimalValue("12345678901234567890123456789", src, false)
	if f, _ := Cast(x, src, Float64); f.F != 1.2345678901234568e28 {
		t.Errorf("to float = %v", f.F)
	}
	if _, err := Cast(WideValue(wide(t, "9223372036854775808")), Decimal(20, 0), Int64); !errs.Is(err, errs.NumericOverflow) {
		t.Errorf("expected overflow, got %v", err)
	}
	neg, _ := ParseDecimalValue("-12345.99", Decimal(30, 2), false)
	if i, err := Cast(neg, Decimal(30, 2), Int64); err != nil || i.I != -12345 {
		t.Errorf("to int = %v, %v", i.I, err)
	}
	if w, err := Cast(IntValue(-7), Int64, Decimal(25, 3)); err != nil || FormatValue(w, Decimal(25, 3)) != "-7.000" {
		t.Errorf("int to wide = %v, %v", FormatValue(w, Decimal(25, 3)), err)
	}
	if n, err := Cast(WideValue(Int128From(-125)), Decimal(30, 2), Decimal(5, 1)); err != nil || n.I != -13 {
		t.Errorf("wide to narrow = %v, %v", n.I, err)
	}
	if _, err := Resolve("DECIMAL", []int{39, 0}); !errs.Is(err, errs.SemanticError) {
		t.Errorf("DECIMAL(39,0) accepted")
	}
}

func TestWideSum(t *testing.T) {
	var s BigDecimalSum
	s.Add(9223372036854775807)
	s.Add(1)
	if v, ok := s.Wide(); !ok || v.String() != "9223372036854775808" {
		t.Errorf("sum = %v", v)
	}
	s.AddWide(wide(t, "99999999999999999999999999999999999999"))
	s.AddWide(wide(t, "99999999999999999999999999999999999999"))
	if s.Big().String() != "200000000000000000009223372036854775806" {
		t.Errorf("big sum = %s", s.Big())
	}
	var o BigDecimalSum
	o.AddWide(wide(t, "-90000000000000000000000000000000000000"))
	s.Merge(&o)
	if v, ok := s.Wide(); !ok || v.String() != "110000000000000000009223372036854775806" {
		t.Errorf("merged = %v %s", ok, s.Big())
	}
}
