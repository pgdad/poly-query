// Package rules reads the category rules file and the budget file
// (spec/apps/pqledger.md §5).
package rules

import (
	"fmt"
	"os"
	"strings"

	"polyquery/app/internal/config"
)

// Rule maps a merchant pattern to a category. Rules are numbered 1, 2, …
// in file order (line order, then order within the line).
type Rule struct {
	No       int64
	Category string
	// Pattern is the pattern as written, ASCII upper-cased: "*" matches
	// any sequence of characters, "?" exactly one character.
	Pattern string
}

// Budget is a monthly budget of a category.
type Budget struct {
	Category string
	Amount   string // [0-9]+(\.[0-9]{1,2})?
}

func read(path string) ([]byte, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		msg := err.Error()
		if pe, ok := err.(*os.PathError); ok {
			msg = pe.Err.Error()
		}
		return nil, &config.Error{File: path, Msg: "cannot read file: " + msg}
	}
	return data, nil
}

// LoadRules reads a rules file.
func LoadRules(path string) ([]Rule, error) {
	data, err := read(path)
	if err != nil {
		return nil, err
	}
	return ParseRules(path, data)
}

// ParseRules parses rules file text.
func ParseRules(file string, data []byte) ([]Rule, error) {
	lines, err := config.SplitLines(file, data, false)
	if err != nil {
		return nil, err
	}
	var out []Rule
	for _, l := range lines {
		fail := func(format string, args ...any) error {
			return &config.Error{File: file, Line: l.No, Msg: fmt.Sprintf(format, args...)}
		}
		if !config.ValidCategory(l.Key) {
			return nil, fail("invalid category name %q", l.Key)
		}
		for _, p := range strings.Split(l.Value, ",") {
			p = config.TrimSpaceTab(p)
			switch {
			case p == "":
				return nil, fail("empty pattern")
			case strings.ContainsAny(p, "%_"):
				return nil, fail("pattern %q must not contain %% or _", p)
			}
			out = append(out, Rule{No: int64(len(out) + 1), Category: l.Key, Pattern: upperASCII(p)})
		}
	}
	return out, nil
}

// LoadBudgets reads a budget file.
func LoadBudgets(path string) ([]Budget, error) {
	data, err := read(path)
	if err != nil {
		return nil, err
	}
	return ParseBudgets(path, data)
}

// ParseBudgets parses budget file text.
func ParseBudgets(file string, data []byte) ([]Budget, error) {
	lines, err := config.SplitLines(file, data, false)
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	var out []Budget
	for _, l := range lines {
		fail := func(format string, args ...any) error {
			return &config.Error{File: file, Line: l.No, Msg: fmt.Sprintf(format, args...)}
		}
		if !config.ValidCategory(l.Key) {
			return nil, fail("invalid category name %q", l.Key)
		}
		if seen[l.Key] {
			return nil, fail("category %q is listed twice", l.Key)
		}
		seen[l.Key] = true
		if !validAmount(l.Value) {
			return nil, fail("invalid amount %q (expected e.g. 250 or 99.50)", l.Value)
		}
		out = append(out, Budget{Category: l.Key, Amount: l.Value})
	}
	return out, nil
}

// validAmount reports whether s matches [0-9]+(\.[0-9]{1,2})? with at most
// 16 integer digits.
func validAmount(s string) bool {
	whole, frac, hasDot := strings.Cut(s, ".")
	if whole == "" || len(whole) > 16 || !digits(whole) {
		return false
	}
	return !hasDot || len(frac) >= 1 && len(frac) <= 2 && digits(frac)
}

func digits(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// upperASCII upper-cases ASCII letters only.
func upperASCII(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'a' && c <= 'z' {
			b[i] = c - 'a' + 'A'
		}
	}
	return string(b)
}
