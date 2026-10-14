package bank

import (
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"strings"
	"unicode/utf8"

	"polyquery"
	"polyquery/app/internal/config"
)

// Transaction is a converted statement record.
type Transaction struct {
	Line        int // physical line the record starts on
	Date        polyquery.Date
	Description string
	Merchant    string
	Amount      int64 // in cents; negative = money out
}

// Error is an import data error. Line is 0 for errors that concern the
// whole file.
type Error struct {
	File string
	Line int
	Msg  string
}

func (e *Error) Error() string {
	if e.Line > 0 {
		return fmt.Sprintf("%s:%d: %s", e.File, e.Line, e.Msg)
	}
	return e.File + ": " + e.Msg
}

// ReadFile reads and converts a statement file. name is the file as the
// user gave it (used in messages).
func ReadFile(path, name string, im config.Import) ([]Transaction, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		msg := err.Error()
		switch {
		case errors.Is(err, fs.ErrNotExist):
			msg = "file not found"
		case errors.Is(err, fs.ErrPermission):
			msg = "permission denied"
		}
		return nil, &Error{File: name, Msg: "cannot read file: " + msg}
	}
	return Parse(name, data, im)
}

// Parse converts statement text; name is used in messages.
func Parse(name string, data []byte, im config.Import) ([]Transaction, error) {
	data = bytes.TrimPrefix(data, []byte("\xEF\xBB\xBF"))
	if !utf8.Valid(data) {
		return nil, &Error{File: name, Line: invalidUTF8Line(data), Msg: "invalid UTF-8"}
	}
	text := string(data)
	r := &csvReader{s: text, line: 1, delim: im.Delimiter}
	for i := 0; i < im.SkipLines && r.pos < len(text); i++ {
		nl := strings.IndexByte(text[r.pos:], '\n')
		if nl < 0 {
			r.pos = len(text)
			break
		}
		r.pos += nl + 1
		r.line++
	}
	fail := func(line int, format string, args ...any) error {
		return &Error{File: name, Line: line, Msg: fmt.Sprintf(format, args...)}
	}
	next := func() (*record, error) {
		rec, err := r.next()
		var le *lineError
		if errors.As(err, &le) {
			return nil, fail(le.line, "%s", le.msg)
		}
		return rec, err
	}
	first, err := next()
	if err != nil {
		return nil, err
	}
	if first == nil {
		if im.Header {
			return nil, fail(0, "missing header record")
		}
		return nil, nil
	}
	width := len(first.fields)
	cols, err := resolveColumns(im, first, func(msg string) error { return fail(first.line, "%s", msg) })
	if err != nil {
		return nil, err
	}
	var out []Transaction
	rec := first
	if im.Header {
		rec = nil
	}
	for {
		if rec == nil {
			if rec, err = next(); err != nil {
				return nil, err
			}
			if rec == nil {
				return out, nil
			}
		}
		if len(rec.fields) != width {
			return nil, fail(rec.line, "record has %d fields, expected %d", len(rec.fields), width)
		}
		t, err := convert(im, cols, rec.fields)
		if err != nil {
			return nil, fail(rec.line, "%s", err)
		}
		t.Line = rec.line
		out = append(out, t)
		rec = nil
	}
}

// invalidUTF8Line returns the line of the first invalid UTF-8 sequence.
func invalidUTF8Line(data []byte) int {
	line := 1
	for len(data) > 0 {
		r, size := utf8.DecodeRune(data)
		if r == utf8.RuneError && size <= 1 {
			return line
		}
		if r == '\n' {
			line++
		}
		data = data[size:]
	}
	return line
}

// columns holds the 0-based positions of the referenced columns.
type columns struct {
	date, description, amount, debit, credit int
}

func resolveColumns(im config.Import, first *record, fail func(string) error) (columns, error) {
	find := func(ref config.ColumnRef) (int, error) {
		if ref.Pos > 0 {
			if ref.Pos > len(first.fields) {
				return 0, fail(fmt.Sprintf("%s is beyond the %d columns of the file", ref, len(first.fields)))
			}
			return ref.Pos - 1, nil
		}
		for i, f := range first.fields {
			if equalFoldASCII(config.TrimSpaceTab(f), ref.Name) {
				return i, nil
			}
		}
		return 0, fail(fmt.Sprintf("the header has no %s", ref))
	}
	var c columns
	var err error
	if c.date, err = find(im.DateColumn); err != nil {
		return c, err
	}
	if c.description, err = find(im.DescriptionColumn); err != nil {
		return c, err
	}
	if im.AmountMode == config.DebitCredit {
		if c.debit, err = find(im.DebitColumn); err != nil {
			return c, err
		}
		c.credit, err = find(im.CreditColumn)
		return c, err
	}
	c.amount, err = find(im.AmountColumn)
	return c, err
}

func convert(im config.Import, c columns, fields []string) (Transaction, error) {
	var t Transaction
	dateText := config.TrimSpaceTab(fields[c.date])
	d, ok := ParseDate(dateText, im.DateFormat)
	if !ok {
		return t, fmt.Errorf("invalid date %q (expected %s)", dateText, im.DateFormat)
	}
	t.Date = d
	t.Description = config.TrimSpaceTab(fields[c.description])
	t.Merchant = Merchant(t.Description)
	if im.AmountMode == config.DebitCredit {
		debitText, creditText := config.TrimSpaceTab(fields[c.debit]), config.TrimSpaceTab(fields[c.credit])
		if debitText == "" && creditText == "" {
			return t, errors.New("both debit and credit are empty")
		}
		var debit, credit int64
		var err error
		if debitText != "" {
			if debit, err = ParseAmount(debitText, im); err != nil {
				return t, fmt.Errorf("debit: %w", err)
			}
		}
		if creditText != "" {
			if credit, err = ParseAmount(creditText, im); err != nil {
				return t, fmt.Errorf("credit: %w", err)
			}
		}
		t.Amount = credit - debit
	} else {
		var err error
		if t.Amount, err = ParseAmount(fields[c.amount], im); err != nil {
			return t, err
		}
	}
	if im.InvertSign {
		t.Amount = -t.Amount
	}
	if t.Amount >= maxCents || t.Amount <= -maxCents {
		return t, errors.New("amount has more than 16 integer digits")
	}
	return t, nil
}

// maxCents bounds amounts to 16 integer digits (DECIMAL(18,2)).
const maxCents = 1e18

// ParseAmount converts an amount field to cents (§6.2), without applying
// invert_sign.
func ParseAmount(field string, im config.Import) (int64, error) {
	s := config.TrimSpaceTab(field)
	neg := false
	switch {
	case len(s) >= 2 && s[0] == '(' && s[len(s)-1] == ')':
		neg, s = true, s[1:len(s)-1]
	case strings.HasPrefix(s, "-"):
		neg, s = true, s[1:]
	case strings.HasPrefix(s, "+"):
		s = s[1:]
	}
	if sym := im.CurrencySymbol; sym != "" {
		if strings.HasPrefix(s, sym) {
			s = s[len(sym):]
		} else if strings.HasSuffix(s, sym) {
			s = s[:len(s)-len(sym)]
		}
	}
	s = config.TrimSpaceTab(s)
	if im.ThousandsSeparator != "" {
		s = strings.ReplaceAll(s, im.ThousandsSeparator, "")
	}
	if im.DecimalSeparator != '.' {
		s = strings.ReplaceAll(s, string(im.DecimalSeparator), ".")
	}
	whole, frac, hasDot := strings.Cut(s, ".")
	if whole == "" || len(whole) > 16 || !allDigits(whole) || hasDot && (len(frac) < 1 || len(frac) > 2 || !allDigits(frac)) {
		return 0, fmt.Errorf("invalid amount %q", field)
	}
	var cents int64
	for i := 0; i < len(whole); i++ {
		cents = cents*10 + int64(whole[i]-'0')
	}
	frac += "00"[len(frac):]
	cents = cents*100 + int64(frac[0]-'0')*10 + int64(frac[1]-'0')
	if neg {
		cents = -cents
	}
	return cents, nil
}

func allDigits(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// ParseDate parses a date in one of the date_format layouts. In the "/"
// and "." layouts MM and DD may have 1 or 2 digits; YYYY has 4.
func ParseDate(s, format string) (polyquery.Date, bool) {
	var y, m, d int
	var ok bool
	switch format {
	case "YYYY-MM-DD":
		if len(s) != 10 || s[4] != '-' || s[7] != '-' {
			return 0, false
		}
		y, ok = number(s[0:4], 4, 4)
		m, ok = and(ok, s[5:7], 2, 2)
		d, ok = and(ok, s[8:10], 2, 2)
	case "YYYYMMDD":
		if len(s) != 8 {
			return 0, false
		}
		y, ok = number(s[0:4], 4, 4)
		m, ok = and(ok, s[4:6], 2, 2)
		d, ok = and(ok, s[6:8], 2, 2)
	case "MM/DD/YYYY", "DD/MM/YYYY", "DD.MM.YYYY":
		sep := format[2:3]
		parts := strings.Split(s, sep)
		if len(parts) != 3 {
			return 0, false
		}
		a, okA := number(parts[0], 1, 2)
		b, okB := number(parts[1], 1, 2)
		y, ok = number(parts[2], 4, 4)
		ok = ok && okA && okB
		if format == "MM/DD/YYYY" {
			m, d = a, b
		} else {
			d, m = a, b
		}
	}
	if !ok {
		return 0, false
	}
	return polyquery.DateOf(y, m, d)
}

// number parses an ASCII digit string of minLen to maxLen digits.
func number(s string, minLen, maxLen int) (int, bool) {
	if len(s) < minLen || len(s) > maxLen || !allDigits(s) {
		return 0, false
	}
	n := 0
	for i := 0; i < len(s); i++ {
		n = n*10 + int(s[i]-'0')
	}
	return n, true
}

func and(ok bool, s string, minLen, maxLen int) (int, bool) {
	n, ok2 := number(s, minLen, maxLen)
	return n, ok && ok2
}

func equalFoldASCII(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := 0; i < len(a); i++ {
		if lowerASCII(a[i]) != lowerASCII(b[i]) {
			return false
		}
	}
	return true
}

func lowerASCII(c byte) byte {
	if c >= 'A' && c <= 'Z' {
		return c + 'a' - 'A'
	}
	return c
}

// Merchant normalizes a description (§6.3): ASCII letters upper-cased,
// runs of spaces and tabs collapsed to one space, trimmed, and a trailing
// store-number token ("#123" or three or more digits) removed once.
func Merchant(description string) string {
	b := make([]byte, 0, len(description))
	space := false
	for i := 0; i < len(description); i++ {
		c := description[i]
		if c == ' ' || c == '\t' {
			space = true
			continue
		}
		if space && len(b) > 0 {
			b = append(b, ' ')
		}
		space = false
		if c >= 'a' && c <= 'z' {
			c -= 'a' - 'A'
		}
		b = append(b, c)
	}
	s := string(b)
	if i := strings.LastIndexByte(s, ' '); i >= 0 {
		if last := s[i+1:]; isStoreNumber(last) {
			s = s[:i]
		}
	}
	return s
}

func isStoreNumber(tok string) bool {
	if strings.HasPrefix(tok, "#") {
		return len(tok) > 1 && allDigits(tok[1:])
	}
	return len(tok) >= 3 && allDigits(tok)
}
