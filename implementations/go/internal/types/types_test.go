package types

import (
	"testing"

	"polyquery/internal/errs"
)

func TestDateRoundTrip(t *testing.T) {
	for _, s := range []string{"0001-01-01", "1969-12-31", "1970-01-01", "2000-02-29", "2024-02-29", "9999-12-31"} {
		d, ok := ParseDate(s)
		if !ok {
			t.Fatalf("ParseDate(%q) failed", s)
		}
		if got := FormatDate(d); got != s {
			t.Errorf("FormatDate(ParseDate(%q)) = %q", s, got)
		}
	}
	if d, _ := ParseDate("0001-01-01"); d != MinDate {
		t.Errorf("min date = %d", d)
	}
	for _, s := range []string{"2023-02-29", "1900-02-29", "0000-01-01", "2024-13-01", "2024-1-01", "2024-01-32"} {
		if _, ok := ParseDate(s); ok {
			t.Errorf("ParseDate(%q) unexpectedly succeeded", s)
		}
	}
}

func TestTimestamp(t *testing.T) {
	cases := map[string]string{
		"2024-02-29 13:14:15.5":      "2024-02-29 13:14:15.500000",
		"2024-01-01T00:00:00":        "2024-01-01 00:00:00",
		"1969-12-31 23:59:59.999999": "1969-12-31 23:59:59.999999",
		"0001-01-01 00:00:00":        "0001-01-01 00:00:00",
	}
	for in, want := range cases {
		ts, ok := ParseTimestamp(in)
		if !ok {
			t.Fatalf("ParseTimestamp(%q) failed", in)
		}
		if got := FormatTimestamp(ts); got != want {
			t.Errorf("FormatTimestamp(%q) = %q, want %q", in, got, want)
		}
	}
	for _, s := range []string{"2024-01-01 24:00:00", "2024-01-01 10:00", "2024-01-01 10:00:00.1234567", "2024-01-01"} {
		if _, ok := ParseTimestamp(s); ok {
			t.Errorf("ParseTimestamp(%q) unexpectedly succeeded", s)
		}
	}
	if d := TimestampToDate(-1); FormatDate(d) != "1969-12-31" {
		t.Errorf("TimestampToDate(-1) = %s", FormatDate(d))
	}
}

func TestDecimalArithmetic(t *testing.T) {
	if v, err := DecimalAdd(125, 2, 25, 1); err != nil || v != 375 {
		t.Errorf("1.25+2.5 = %d, %v", v, err)
	}
	if _, err := DecimalAdd(999999999999999999, 1, 1, 1); !errs.Is(err, errs.NumericOverflow) {
		t.Errorf("expected overflow, got %v", err)
	}
	if _, err := DecimalMul(999999999999999999, 100); !errs.Is(err, errs.NumericOverflow) {
		t.Errorf("expected overflow, got %v", err)
	}
	if c := CompareDecimal(150, 2, 15, 1); c != 0 {
		t.Errorf("1.50 vs 1.5 = %d", c)
	}
	if c := CompareDecimal(100000000000000000, 0, 999, 2); c != 1 {
		t.Errorf("large vs small = %d", c)
	}
	if got := FormatDecimal(-5, 2); got != "-0.05" {
		t.Errorf("FormatDecimal = %q", got)
	}
	if got := FormatDecimal(12, 0); got != "12" {
		t.Errorf("FormatDecimal = %q", got)
	}
	if got := RoundDiv(-2345, 1); got != -235 {
		t.Errorf("RoundDiv(-2345,1) = %d", got)
	}
}

func TestDecimalText(t *testing.T) {
	if v, st := ParseDecimalExact("+7", 4, 1); st != TextOK || v != 70 {
		t.Errorf("+7 -> %d %v", v, st)
	}
	if _, st := ParseDecimalExact("10.005", 10, 2); st != TextRange {
		t.Errorf("10.005 should not fit scale 2")
	}
	if _, st := ParseDecimalExact("123.4", 3, 1); st != TextRange {
		t.Errorf("123.4 should not fit DECIMAL(3,1)")
	}
	if v, st := ParseDecimalRound("1.005", 4, 2); st != TextOK || v != 101 {
		t.Errorf("round 1.005 -> %d %v", v, st)
	}
	if _, st := ParseDecimalRound("99.995", 4, 2); st != TextRange {
		t.Errorf("99.995 should overflow DECIMAL(4,2)")
	}
	if _, st := ParseDecimalRound("1e2", 5, 0); st != TextSyntax {
		t.Errorf("1e2 is not decimal text")
	}
}

func TestCast(t *testing.T) {
	check := func(v Value, from, to Type, want string) {
		t.Helper()
		got, err := Cast(v, from, to)
		if err != nil {
			t.Fatalf("Cast(%v %s -> %s): %v", v, from, to, err)
		}
		if s := FormatValue(got, to); s != want {
			t.Errorf("Cast(%v %s -> %s) = %s, want %s", v, from, to, s, want)
		}
	}
	check(IntValue(-375), Decimal(3, 2), Int64, "-3")
	check(IntValue(2345), Decimal(4, 3), Decimal(5, 2), "2.35")
	check(FloatValue(2.5), Float64, Decimal(3, 0), "3")
	check(StringValue(" 12 "), String, Int64, "12")
	check(StringValue("  TRUE "), String, Boolean, "true")
	check(IntValue(0), Int64, Boolean, "false")
	check(FloatValue(7.9), Float64, Int64, "7")
	if _, err := Cast(FloatValue(1e19), Float64, Int64); !errs.Is(err, errs.NumericOverflow) {
		t.Errorf("expected overflow, got %v", err)
	}
	if _, err := Cast(StringValue("abc"), String, Int64); !errs.Is(err, errs.ConversionError) {
		t.Errorf("expected conversion error, got %v", err)
	}
	if _, err := Cast(StringValue("9223372036854775808"), String, Int64); !errs.Is(err, errs.NumericOverflow) {
		t.Errorf("expected overflow, got %v", err)
	}
	if CastAllowed(Date, Int64) || CastAllowed(Int64, Date) || !CastAllowed(Timestamp, Date) {
		t.Errorf("CastAllowed table mismatch")
	}
}

func TestTypeNames(t *testing.T) {
	cases := map[string]string{
		"bigint": "INT64", "Decimal": "DECIMAL(18,0)", "numeric(4, 1)": "DECIMAL(4,1)",
		"DECIMAL(7)": "DECIMAL(7,0)", "text": "STRING", "real": "FLOAT64", "bool": "BOOLEAN",
	}
	for in, want := range cases {
		typ, err := ParseTypeName(in)
		if err != nil || typ.String() != want {
			t.Errorf("ParseTypeName(%q) = %v, %v; want %s", in, typ, err, want)
		}
	}
	for _, bad := range []string{"WIDGET", "DECIMAL(19,0)", "DECIMAL(5,6)", "INT(3)"} {
		if _, err := ParseTypeName(bad); err == nil {
			t.Errorf("ParseTypeName(%q) should fail", bad)
		}
	}
}

func TestFloatFormatting(t *testing.T) {
	cases := map[float64]string{0: "0.0", 3: "3.0", 0.1: "0.1", 1.5e300: "1.5e+300", -2.5: "-2.5"}
	for f, want := range cases {
		if got := FormatFloat(f); got != want {
			t.Errorf("FormatFloat(%v) = %q, want %q", f, got, want)
		}
	}
	negZero := FloatValue(0)
	negZero.F = -negZero.F
	if got := FormatFloat(negZero.F); got != "0.0" {
		t.Errorf("-0 formatted as %q", got)
	}
}

func TestTextParsing(t *testing.T) {
	for _, s := range []string{"1", "-1.5", ".5", "3.", "1e10", "+2.5E-3"} {
		if _, st := ParseFloatText(s); st != TextOK {
			t.Errorf("ParseFloatText(%q) failed", s)
		}
	}
	for _, s := range []string{"NaN", "inf", "0x10", "1e", ".", ""} {
		if _, st := ParseFloatText(s); st == TextOK {
			t.Errorf("ParseFloatText(%q) unexpectedly succeeded", s)
		}
	}
	if _, st := ParseIntText("9223372036854775808"); st != TextRange {
		t.Errorf("int overflow not detected")
	}
}
