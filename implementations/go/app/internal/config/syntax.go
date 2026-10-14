// Package config reads pqledger's configuration file
// (spec/apps/pqledger.md §3) and the shared line syntax of the rules and
// budget files.
package config

import (
	"bytes"
	"fmt"
	"strings"
	"unicode/utf8"
)

// Line is one meaningful line of a file in the INI-like syntax of §3.2.
type Line struct {
	No int // 1-based line number
	// Section is the NAME of a section header "[NAME]" ("" for an
	// assignment).
	Section string
	// Key and Value of an assignment KEY = VALUE (quotes removed).
	Key, Value string
}

// Error is a configuration error: a problem with the configuration, rules
// or budget file.
type Error struct {
	File string
	Line int // 0 if not specific to a line
	Msg  string
}

func (e *Error) Error() string {
	if e.Line > 0 {
		return fmt.Sprintf("%s:%d: %s", e.File, e.Line, e.Msg)
	}
	return e.File + ": " + e.Msg
}

// SplitLines parses text in the syntax of §3.2: UTF-8, "\n" or "\r\n"
// line ends, a leading BOM ignored; blank lines and comments ("#" or ";")
// are skipped. If sections is false, section headers are errors.
func SplitLines(file string, data []byte, sections bool) ([]Line, error) {
	data = bytes.TrimPrefix(data, []byte("\xEF\xBB\xBF"))
	if !utf8.Valid(data) {
		return nil, &Error{File: file, Msg: "file is not valid UTF-8"}
	}
	var out []Line
	for i, raw := range strings.Split(string(data), "\n") {
		no := i + 1
		line := TrimSpaceTab(strings.TrimSuffix(raw, "\r"))
		switch {
		case line == "" || line[0] == '#' || line[0] == ';':
			continue
		case line[0] == '[':
			if !sections {
				return nil, &Error{File: file, Line: no, Msg: "section headers are not allowed here"}
			}
			if len(line) < 2 || line[len(line)-1] != ']' {
				return nil, &Error{File: file, Line: no, Msg: fmt.Sprintf("malformed section header %q", line)}
			}
			out = append(out, Line{No: no, Section: line[1 : len(line)-1]})
		default:
			key, value, ok := strings.Cut(line, "=")
			if !ok {
				return nil, &Error{File: file, Line: no, Msg: fmt.Sprintf("expected KEY = VALUE, got %q", line)}
			}
			key = TrimSpaceTab(key)
			if key == "" {
				return nil, &Error{File: file, Line: no, Msg: "missing key before '='"}
			}
			out = append(out, Line{No: no, Key: key, Value: unquote(TrimSpaceTab(value))})
		}
	}
	return out, nil
}

// unquote removes the quotes of a value written as "…"; inside them \"
// means " and \\ means \.
func unquote(v string) string {
	if len(v) < 2 || v[0] != '"' || v[len(v)-1] != '"' {
		return v
	}
	inner := v[1 : len(v)-1]
	var b strings.Builder
	for i := 0; i < len(inner); i++ {
		if inner[i] == '\\' && i+1 < len(inner) && (inner[i+1] == '"' || inner[i+1] == '\\') {
			i++
		}
		b.WriteByte(inner[i])
	}
	return b.String()
}

// TrimSpaceTab removes leading and trailing spaces and tabs.
func TrimSpaceTab(s string) string { return strings.Trim(s, " \t") }

// ValidName reports whether s matches [a-z0-9_-]{1,32} (account and
// category names).
func ValidName(s string) bool {
	if len(s) < 1 || len(s) > 32 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}

// Uncategorized is the category of transactions without override or
// matching rule.
const Uncategorized = "uncategorized"

// ValidCategory reports whether s is a valid category name (a name that
// is not "uncategorized").
func ValidCategory(s string) bool { return ValidName(s) && s != Uncategorized }
