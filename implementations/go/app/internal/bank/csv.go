// Package bank reads bank-statement CSV exports and converts their records
// into transactions (spec/apps/pqledger.md §6.2, §6.3).
package bank

import "fmt"

// record is one CSV record and the 1-based physical line it starts on.
type record struct {
	line   int
	fields []string
}

// csvReader splits CSV text (RFC 4180, quote ", the given delimiter,
// "\n" or "\r\n" record terminators, completely empty lines ignored) into
// records, tracking physical line numbers.
type csvReader struct {
	s     string
	pos   int
	line  int // physical line of s[pos]
	delim byte
}

// lineError is a problem with the input at a physical line.
type lineError struct {
	line int
	msg  string
}

func (e *lineError) Error() string { return fmt.Sprintf("line %d: %s", e.line, e.msg) }

// next returns the next record, or nil at the end of the input.
func (r *csvReader) next() (*record, error) {
	s := r.s
	for r.pos < len(s) {
		if s[r.pos] == '\n' {
			r.pos++
			r.line++
		} else if s[r.pos] == '\r' && r.pos+1 < len(s) && s[r.pos+1] == '\n' {
			r.pos += 2
			r.line++
		} else {
			break
		}
	}
	if r.pos >= len(s) {
		return nil, nil
	}
	rec := &record{line: r.line}
	for {
		field, err := r.field()
		if err != nil {
			return nil, err
		}
		rec.fields = append(rec.fields, field)
		if r.pos >= len(s) {
			return rec, nil
		}
		switch c := s[r.pos]; {
		case c == r.delim:
			r.pos++
		case c == '\n':
			r.pos++
			r.line++
			return rec, nil
		default: // "\r\n"
			r.pos += 2
			r.line++
			return rec, nil
		}
	}
}

// field reads one field and stops before the delimiter or terminator
// that ends it.
func (r *csvReader) field() (string, error) {
	s := r.s
	if r.pos < len(s) && s[r.pos] == '"' {
		start := r.line
		r.pos++
		var b []byte
		for {
			if r.pos >= len(s) {
				return "", &lineError{start, "unterminated quoted field"}
			}
			c := s[r.pos]
			if c == '"' {
				if r.pos+1 < len(s) && s[r.pos+1] == '"' {
					b = append(b, '"')
					r.pos += 2
					continue
				}
				r.pos++
				break
			}
			if c == '\n' {
				r.line++
			}
			b = append(b, c)
			r.pos++
		}
		if r.pos < len(s) && !r.atEnd() {
			return "", &lineError{r.line, "unexpected character after a closing quote"}
		}
		return string(b), nil
	}
	start := r.pos
	for r.pos < len(s) && !r.atEnd() { // a quote inside is literal
		r.pos++
	}
	return s[start:r.pos], nil
}

// atEnd reports whether s[pos] ends a field (delimiter or terminator).
func (r *csvReader) atEnd() bool {
	c := r.s[r.pos]
	return c == r.delim || c == '\n' || c == '\r' && r.pos+1 < len(r.s) && r.s[r.pos+1] == '\n'
}
