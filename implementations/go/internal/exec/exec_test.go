package exec

import (
	"testing"

	"polyquery/internal/types"
)

func TestLike(t *testing.T) {
	cases := []struct {
		s, p string
		want bool
	}{
		{"abc", "abc", true}, {"abc", "ABC", false}, {"abc", "a%", true}, {"abc", "%c", true},
		{"abc", "a_c", true}, {"ac", "a_c", false}, {"", "%", true}, {"", "_", false},
		{"éa", "_a", true}, {"aXbXc", "a%b%c", true}, {"abcbc", "a%bc", true}, {"ab", "a%%b%", true},
		{"abc", "b", false}, {"a.c", "a.c", true}, {"mississippi", "%iss%pi", true}, {"x", "", false},
	}
	for _, c := range cases {
		if got := newLikePattern(c.p).match(c.s); got != c.want {
			t.Errorf("%q LIKE %q = %v, want %v", c.s, c.p, got, c.want)
		}
	}
}

func TestSubstr(t *testing.T) {
	cases := []struct {
		s          string
		start, len int64
		want       string
	}{
		{"hello", 2, 3, "ell"}, {"hello", 3, -1, "llo"}, {"hello", 0, 2, "h"}, {"hello", 10, -1, ""},
		{"héllo", 2, 2, "él"}, {"hello", -1, 3, "h"}, {"hello", 2, 0, ""}, {"abc", 1 << 62, 1 << 62, ""},
	}
	for _, c := range cases {
		if got := substr(c.s, c.start, c.len); got != c.want {
			t.Errorf("substr(%q,%d,%d) = %q, want %q", c.s, c.start, c.len, got, c.want)
		}
	}
}

func TestCaseMapping(t *testing.T) {
	if got := asciiMap("abc Ünï xy", 'a', 'z', -32); got != "ABC Ünï XY" {
		t.Errorf("UPPER: %q", got)
	}
	if got := asciiMap("ABC ÜNÏ", 'A', 'Z', 32); got != "abc ÜNÏ" {
		t.Errorf("LOWER: %q", got)
	}
}

func TestRound(t *testing.T) {
	dec := func(s int) types.Type { return types.Decimal(10, s) }
	cases := []struct {
		t    types.Type
		v    int64
		n    int64
		want int64
	}{
		{dec(1), 25, 0, 3}, {dec(1), -25, 0, -3}, {dec(3), 2345, 2, 235}, {dec(4), 12345678, -2, 1200},
		{types.Int64, 15, -1, 20}, {types.Int64, -15, -1, -20}, {types.Int64, 7, 0, 7}, {dec(1), 25, 5, 25},
	}
	for _, c := range cases {
		got, err := roundFn(c.t, c.n)(types.IntValue(c.v))
		if err != nil || got.I != c.want {
			t.Errorf("ROUND(%d@%s, %d) = %v, %v; want %d", c.v, c.t, c.n, got.I, err, c.want)
		}
	}
	if _, err := roundFn(types.Int64, -1)(types.IntValue(9223372036854775807)); err == nil {
		t.Error("expected overflow")
	}
	if f, _ := roundFloat(1.26, 1); f != 1.3 {
		t.Errorf("ROUND(1.26e0, 1) = %v", f)
	}
}

func TestKeyCanonicalization(t *testing.T) {
	a := appendKey(nil, types.IntValue(150), types.Decimal(5, 2))
	b := appendKey(nil, types.IntValue(15), types.Decimal(3, 1))
	if string(a) != string(b) {
		t.Error("1.50 and 1.5 must hash equally")
	}
	z := appendKey(nil, types.FloatValue(0), types.Float64)
	nz := appendKey(nil, types.FloatValue(-1*0.0), types.Float64)
	if string(z) != string(nz) {
		t.Error("0.0 and -0.0 must hash equally")
	}
	if string(appendKey(nil, types.NullValue, types.Int64)) == string(appendKey(nil, types.IntValue(0), types.Int64)) {
		t.Error("NULL must differ from 0")
	}
}
