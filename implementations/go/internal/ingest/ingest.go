// Package ingest builds tables from CSV, JSON and JSON Lines input with schema
// inference or an explicit schema (spec/data-types/ingestion.md).
package ingest

import (
	"bytes"
	"unicode/utf8"

	"polyquery/internal/errs"
	"polyquery/internal/storage"
	"polyquery/internal/types"
)

// Format is an input format.
type Format string

// Supported formats.
const (
	CSV   Format = "csv"
	JSON  Format = "json"
	JSONL Format = "jsonl"
)

// MaxFieldBytes is the largest permitted single field.
const MaxFieldBytes = 16 << 20

// Options control ingestion.
type Options struct {
	Format    Format
	Schema    []storage.ColumnDef // nil = infer
	Header    bool                // CSV: first record is the header
	Delimiter byte                // CSV field delimiter
	MaxRows   int64               // 0 = unlimited
}

// DefaultOptions returns options with the documented defaults for a format.
func DefaultOptions(f Format) Options {
	return Options{Format: f, Header: true, Delimiter: ','}
}

// Load parses data into a new table called name.
func Load(name string, data []byte, opts Options) (*storage.Table, error) {
	data = bytes.TrimPrefix(data, []byte("\xEF\xBB\xBF"))
	if !utf8.Valid(data) {
		return nil, errs.New(errs.IngestError, "input is not valid UTF-8")
	}
	if opts.Schema != nil {
		if err := checkColumnNames(opts.Schema); err != nil {
			return nil, err
		}
	}
	var (
		t   *storage.Table
		err error
	)
	switch opts.Format {
	case CSV:
		t, err = loadCSV(string(data), opts)
	case JSON, JSONL:
		t, err = loadJSON(string(data), opts)
	default:
		return nil, errs.New(errs.InvalidRequest, "unknown format %q", opts.Format)
	}
	if err != nil {
		return nil, err
	}
	t.Name = name
	return t, nil
}

func checkColumnNames(cols []storage.ColumnDef) error {
	seen := make(map[string]bool, len(cols))
	for _, c := range cols {
		if c.Name == "" {
			return errs.New(errs.IngestError, "empty column name")
		}
		key := storage.FoldKey(c.Name)
		if seen[key] {
			return errs.New(errs.IngestError, "duplicate column name %q", c.Name)
		}
		seen[key] = true
	}
	return nil
}

func checkRows(n int, opts Options) error {
	if opts.MaxRows > 0 && int64(n) > opts.MaxRows {
		return errs.New(errs.ResourceLimit, "table exceeds the maximum of %d rows", opts.MaxRows)
	}
	return nil
}

func conversionError(record int, column string, format string, args ...any) error {
	e := errs.New(errs.ConversionError, format, args...)
	e.Message += " (record " + itoa(record) + ", column " + column + ")"
	return e.With("record", record).With("column_name", column)
}

func itoa(i int) string {
	var b [20]byte
	n := len(b)
	neg := i < 0
	if neg {
		i = -i
	}
	for {
		n--
		b[n] = byte('0' + i%10)
		i /= 10
		if i == 0 {
			break
		}
	}
	if neg {
		n--
		b[n] = '-'
	}
	return string(b[n:])
}

// convertText converts trimmed, non-empty field text to a value of type t
// following the explicit-schema rules (exact, no rounding).
func convertText(text string, t types.Type) (types.Value, bool) {
	switch t.Kind {
	case types.KindBoolean:
		b, ok := types.ParseBoolText(text)
		return types.BoolValue(b), ok
	case types.KindInt64:
		i, st := types.ParseIntText(text)
		return types.IntValue(i), st == types.TextOK
	case types.KindFloat64:
		f, st := types.ParseFloatText(text)
		return types.FloatValue(f), st == types.TextOK
	case types.KindDecimal:
		u, st := types.ParseDecimalExact(text, t.Precision, t.Scale)
		return types.IntValue(u), st == types.TextOK
	case types.KindDate:
		d, ok := types.ParseDate(text)
		return types.IntValue(d), ok
	case types.KindTimestamp:
		ts, ok := types.ParseDateOrTimestamp(text)
		return types.IntValue(ts), ok
	case types.KindString:
		return types.StringValue(text), true
	}
	return types.Value{}, false
}

// inference tracks which candidate types are still possible for a column of
// text values (ingestion.md §1.1).
type inference struct {
	boolean, int64, float64, date, timestamp bool
	seen                                     bool
}

func newInference() inference {
	return inference{boolean: true, int64: true, float64: true, date: true, timestamp: true}
}

func (in *inference) observe(t string) {
	in.seen = true
	if in.boolean {
		_, in.boolean = types.ParseBoolText(t)
	}
	if in.int64 {
		_, st := types.ParseIntText(t)
		in.int64 = st == types.TextOK
	}
	if in.float64 {
		_, st := types.ParseFloatText(t)
		in.float64 = st == types.TextOK
	}
	if in.date {
		_, in.date = types.ParseDate(t)
	}
	if in.timestamp {
		_, in.timestamp = types.ParseDateOrTimestamp(t)
	}
}

func (in *inference) possible() bool {
	return in.boolean || in.int64 || in.float64 || in.date || in.timestamp
}

func (in *inference) result() types.Type {
	switch {
	case !in.seen:
		return types.String
	case in.boolean:
		return types.Boolean
	case in.int64:
		return types.Int64
	case in.float64:
		return types.Float64
	case in.date:
		return types.Date
	case in.timestamp:
		return types.Timestamp
	}
	return types.String
}
