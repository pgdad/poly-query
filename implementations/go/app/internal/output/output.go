// Package output prints results in pqledger's three output formats
// (spec/apps/pqledger.md §7).
package output

import (
	"bufio"
	"fmt"
	"io"
	"strconv"
	"strings"
	"unicode/utf8"

	"polyquery"
)

// Write prints a result in format ("table", "csv" or "json"). Values are
// nil (NULL) or of the polyquery Go type of their column.
func Write(w io.Writer, format string, r *polyquery.Result) error {
	bw := bufio.NewWriterSize(w, 64<<10)
	switch format {
	case "csv":
		writeCSV(bw, r)
	case "json":
		writeJSON(bw, r)
	default:
		writeTable(bw, r)
	}
	return bw.Flush()
}

// Text returns the value text of a non-NULL value (§7); NULL is "".
func Text(v any) string {
	switch x := v.(type) {
	case nil:
		return ""
	case string:
		return x
	case int64:
		return strconv.FormatInt(x, 10)
	case bool:
		return strconv.FormatBool(x)
	case float64:
		s := strconv.FormatFloat(x, 'f', 6, 64)
		if s == "-0.000000" {
			s = "0.000000"
		}
		return s
	case polyquery.Decimal:
		return x.String()
	case polyquery.Date:
		return x.String()
	case polyquery.Timestamp:
		return x.String()
	}
	return fmt.Sprint(v)
}

func numeric(t polyquery.Type) bool {
	return t.Kind == polyquery.KindInt64 || t.Kind == polyquery.KindDecimal || t.Kind == polyquery.KindFloat64
}

func writeTable(w *bufio.Writer, r *polyquery.Result) {
	n := len(r.Columns)
	cells := make([][]string, len(r.Rows))
	widths := make([]int, n)
	for j, c := range r.Columns {
		widths[j] = utf8.RuneCountInString(c.Name)
	}
	for i, row := range r.Rows {
		cells[i] = make([]string, n)
		for j, v := range row {
			s := Text(v)
			cells[i][j] = s
			widths[j] = max(widths[j], utf8.RuneCountInString(s))
		}
	}
	right := make([]bool, n)
	for j, c := range r.Columns {
		right[j] = numeric(c.Type)
	}
	var line []byte
	emit := func(texts []string) {
		line = line[:0]
		for j, s := range texts {
			if j > 0 {
				line = append(line, "  "...)
			}
			pad := widths[j] - utf8.RuneCountInString(s)
			if right[j] {
				line = appendSpaces(line, pad)
				line = append(line, s...)
			} else {
				line = append(line, s...)
				line = appendSpaces(line, pad)
			}
		}
		w.Write(trimRightSpaces(line))
		w.WriteByte('\n')
	}
	names := make([]string, n)
	dashes := make([]string, n)
	for j, c := range r.Columns {
		names[j] = c.Name
		dashes[j] = strings.Repeat("-", widths[j])
	}
	emit(names)
	emit(dashes)
	for _, row := range cells {
		emit(row)
	}
	if len(r.Rows) == 1 {
		w.WriteString("(1 row)\n")
	} else {
		fmt.Fprintf(w, "(%d rows)\n", len(r.Rows))
	}
}

func appendSpaces(b []byte, n int) []byte {
	for ; n > 0; n-- {
		b = append(b, ' ')
	}
	return b
}

func trimRightSpaces(b []byte) []byte {
	for len(b) > 0 && b[len(b)-1] == ' ' {
		b = b[:len(b)-1]
	}
	return b
}

func writeCSV(w *bufio.Writer, r *polyquery.Result) {
	for j, c := range r.Columns {
		if j > 0 {
			w.WriteByte(',')
		}
		writeCSVField(w, c.Name)
	}
	w.WriteByte('\n')
	for _, row := range r.Rows {
		for j, v := range row {
			if j > 0 {
				w.WriteByte(',')
			}
			if v != nil {
				writeCSVField(w, Text(v))
			}
		}
		w.WriteByte('\n')
	}
}

// writeCSVField writes a non-NULL field, quoted if it is empty, contains
// a comma, quote, CR or LF, or starts or ends with a space.
func writeCSVField(w *bufio.Writer, s string) {
	if s == "" || strings.ContainsAny(s, ",\"\r\n") || s[0] == ' ' || s[len(s)-1] == ' ' {
		w.WriteByte('"')
		w.WriteString(strings.ReplaceAll(s, `"`, `""`))
		w.WriteByte('"')
		return
	}
	w.WriteString(s)
}

func writeJSON(w *bufio.Writer, r *polyquery.Result) {
	for _, row := range r.Rows {
		w.WriteByte('{')
		for j, v := range row {
			if j > 0 {
				w.WriteByte(',')
			}
			writeJSONString(w, r.Columns[j].Name)
			w.WriteByte(':')
			switch x := v.(type) {
			case nil:
				w.WriteString("null")
			case bool, int64, float64:
				w.WriteString(Text(x))
			default:
				writeJSONString(w, Text(x))
			}
		}
		w.WriteString("}\n")
	}
}

func writeJSONString(w *bufio.Writer, s string) {
	const hex = "0123456789abcdef"
	w.WriteByte('"')
	start := 0
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= 0x20 && c != '"' && c != '\\' {
			continue
		}
		w.WriteString(s[start:i])
		start = i + 1
		switch c {
		case '"':
			w.WriteString(`\"`)
		case '\\':
			w.WriteString(`\\`)
		case '\b':
			w.WriteString(`\b`)
		case '\t':
			w.WriteString(`\t`)
		case '\n':
			w.WriteString(`\n`)
		case '\f':
			w.WriteString(`\f`)
		case '\r':
			w.WriteString(`\r`)
		default:
			w.WriteString(`\u00`)
			w.WriteByte(hex[c>>4])
			w.WriteByte(hex[c&15])
		}
	}
	w.WriteString(s[start:])
	w.WriteByte('"')
}
