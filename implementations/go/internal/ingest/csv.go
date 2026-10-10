package ingest

import (
	"strings"

	"polyquery/internal/errs"
	"polyquery/internal/storage"
	"polyquery/internal/types"
)

// Field flags.
const (
	fieldText        uint8 = iota // ordinary (possibly quoted, non-empty) field
	fieldNull                     // unquoted empty field
	fieldQuotedEmpty              // ""
)

// csvColumn collects the raw fields of one column.
type csvColumn struct {
	texts []string
	flags []uint8
}

type csvReader struct {
	s      string
	pos    int
	delim  byte
	record int // 1-based number of the record being read
	buf    []string
	flags  []uint8
}

// readRecord reads the next non-empty record; ok is false at end of input.
func (r *csvReader) readRecord() (fields []string, flags []uint8, ok bool, err error) {
	s := r.s
	for r.pos < len(s) {
		if s[r.pos] == '\n' {
			r.pos++
			continue
		}
		if s[r.pos] == '\r' && r.pos+1 < len(s) && s[r.pos+1] == '\n' {
			r.pos += 2
			continue
		}
		break
	}
	if r.pos >= len(s) {
		return nil, nil, false, nil
	}
	r.record++
	r.buf, r.flags = r.buf[:0], r.flags[:0]
	for {
		var text string
		var flag uint8
		if r.pos < len(s) && s[r.pos] == '"' {
			text, err = r.quotedField()
			if err != nil {
				return nil, nil, false, err
			}
			flag = fieldText
			if text == "" {
				flag = fieldQuotedEmpty
			}
		} else {
			start := r.pos
			for r.pos < len(s) {
				c := s[r.pos]
				if c == r.delim || c == '\n' || (c == '\r' && r.pos+1 < len(s) && s[r.pos+1] == '\n') {
					break
				}
				r.pos++
			}
			text = s[start:r.pos]
			flag = fieldText
			if text == "" {
				flag = fieldNull
			}
		}
		if len(text) > MaxFieldBytes {
			return nil, nil, false, errs.New(errs.IngestError, "field longer than 16 MiB in record %d", r.record).With("record", r.record)
		}
		r.buf = append(r.buf, text)
		r.flags = append(r.flags, flag)
		if r.pos >= len(s) {
			return r.buf, r.flags, true, nil
		}
		switch c := s[r.pos]; {
		case c == r.delim:
			r.pos++
		case c == '\n':
			r.pos++
			return r.buf, r.flags, true, nil
		case c == '\r' && r.pos+1 < len(s) && s[r.pos+1] == '\n':
			r.pos += 2
			return r.buf, r.flags, true, nil
		default:
			return nil, nil, false, errs.New(errs.IngestError, "unexpected character after quoted field in record %d", r.record).With("record", r.record)
		}
	}
}

func (r *csvReader) quotedField() (string, error) {
	s := r.s
	r.pos++ // opening quote
	segStart := r.pos
	var sb strings.Builder
	escaped := false
	for {
		i := strings.IndexByte(s[r.pos:], '"')
		if i < 0 {
			return "", errs.New(errs.IngestError, "unterminated quoted field in record %d", r.record).With("record", r.record)
		}
		end := r.pos + i
		if end+1 < len(s) && s[end+1] == '"' {
			sb.WriteString(s[segStart : end+1]) // keep one quote of the "" pair
			r.pos = end + 2
			segStart = r.pos
			escaped = true
			continue
		}
		r.pos = end + 1
		if !escaped {
			return s[segStart:end], nil
		}
		sb.WriteString(s[segStart:end])
		return sb.String(), nil
	}
}

func loadCSV(s string, opts Options) (*storage.Data, error) {
	r := &csvReader{s: s, delim: opts.Delimiter}
	var names []string
	var schema []storage.ColumnDef = opts.Schema
	if opts.Header {
		fields, _, ok, err := r.readRecord()
		if err != nil {
			return nil, err
		}
		if !ok {
			if schema == nil {
				return nil, errs.New(errs.IngestError, "CSV input has no header record")
			}
		} else {
			names = append(names, fields...)
			cols := make([]storage.ColumnDef, len(names))
			for i, n := range names {
				cols[i] = storage.ColumnDef{Name: n}
			}
			if err := checkColumnNames(cols); err != nil {
				return nil, err
			}
			if schema != nil {
				if len(schema) != len(names) {
					return nil, errs.New(errs.IngestError, "header has %d columns but the schema has %d", len(names), len(schema))
				}
				for i, n := range names {
					if !storage.EqualFold(n, schema[i].Name) {
						return nil, errs.New(errs.IngestError, "header column %q does not match schema column %q", n, schema[i].Name)
					}
				}
			}
		}
	}
	if schema != nil {
		names = names[:0]
		for _, c := range schema {
			names = append(names, c.Name)
		}
	}
	ncols := len(names)
	cols := make([]csvColumn, ncols)
	rows := 0
	for {
		fields, flags, ok, err := r.readRecord()
		if err != nil {
			return nil, err
		}
		if !ok {
			break
		}
		if len(fields) != ncols {
			return nil, errs.New(errs.IngestError, "record %d has %d fields, expected %d", r.record, len(fields), ncols).With("record", r.record)
		}
		for i := range fields {
			cols[i].texts = append(cols[i].texts, fields[i])
			cols[i].flags = append(cols[i].flags, flags[i])
		}
		rows++
		if err := checkRows(rows, opts); err != nil {
			return nil, err
		}
	}
	firstRecord := 1
	if opts.Header {
		firstRecord = 2
	}
	t := &storage.Data{Rows: rows}
	for i, name := range names {
		var typ types.Type
		if schema != nil {
			typ = schema[i].Type
		} else {
			typ = inferCSV(&cols[i])
		}
		vec, err := convertCSVColumn(&cols[i], typ, name, firstRecord)
		if err != nil {
			return nil, err
		}
		cols[i] = csvColumn{} // release raw texts early
		t.Columns = append(t.Columns, storage.ColumnDef{Name: name, Type: typ})
		t.Vectors = append(t.Vectors, vec)
	}
	return t, nil
}

func inferCSV(c *csvColumn) types.Type {
	in := newInference()
	for i, text := range c.texts {
		if c.flags[i] != fieldText {
			continue
		}
		t := types.TrimSpaceTab(text)
		if t == "" {
			continue
		}
		in.observe(t)
		if !in.possible() {
			return types.String
		}
	}
	return in.result()
}

func convertCSVColumn(c *csvColumn, typ types.Type, name string, firstRecord int) (*storage.Vector, error) {
	vec := storage.NewVector(typ, len(c.texts))
	for i, text := range c.texts {
		flag := c.flags[i]
		if flag == fieldNull {
			vec.Append(types.NullValue)
			continue
		}
		if typ.Kind == types.KindString {
			vec.Append(types.StringValue(text))
			continue
		}
		t := types.TrimSpaceTab(text)
		if flag == fieldQuotedEmpty || t == "" {
			vec.Append(types.NullValue)
			continue
		}
		v, ok := convertText(t, typ)
		if !ok {
			return nil, conversionError(firstRecord+i, name, "cannot convert %q to %s", text, typ)
		}
		vec.Append(v)
	}
	return vec, nil
}
