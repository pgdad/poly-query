package ingest

import (
	"testing"

	"polyquery/internal/errs"
	"polyquery/internal/storage"
	"polyquery/internal/types"
)

func load(t *testing.T, f Format, data string, schema []storage.ColumnDef) (*storage.Data, error) {
	t.Helper()
	opts := DefaultOptions(f)
	opts.Schema = schema
	return Load([]byte(data), opts)
}

func colTypes(tb *storage.Data) []string {
	var out []string
	for _, c := range tb.Columns {
		out = append(out, c.Type.String())
	}
	return out
}

func TestCSVInference(t *testing.T) {
	tb, err := load(t, CSV, "\xEF\xBB\xBFb,i,f,d,ts,s,e\r\nTRUE,1, 2.5 ,2024-01-01,2024-01-01,x,\nfalse,-3,4,2024-02-29,2024-01-01 10:00:00,\"y, z\",\n", nil)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"BOOLEAN", "INT64", "FLOAT64", "DATE", "TIMESTAMP", "STRING", "STRING"}
	for i, typ := range colTypes(tb) {
		if typ != want[i] {
			t.Errorf("column %d: %s, want %s", i, typ, want[i])
		}
	}
	if tb.Rows != 2 || tb.Vectors[5].Get(1).S != "y, z" || !tb.Vectors[6].IsNull(0) {
		t.Errorf("unexpected data")
	}
}

func TestCSVQuotingAndNulls(t *testing.T) {
	tb, err := load(t, CSV, "n,s\n\"\",\"\"\n1,\"a \"\"q\"\"\nline\"\n,\n", nil)
	if err != nil {
		t.Fatal(err)
	}
	if tb.Columns[0].Type != types.Int64 || !tb.Vectors[0].IsNull(0) {
		t.Errorf("quoted empty should be NULL for INT64")
	}
	if v := tb.Vectors[1].Get(0); v.Null || v.S != "" {
		t.Errorf("quoted empty should be '' for STRING")
	}
	if v := tb.Vectors[1].Get(1); v.S != "a \"q\"\nline" {
		t.Errorf("escaped field = %q", v.S)
	}
	if !tb.Vectors[1].IsNull(2) {
		t.Errorf("unquoted empty should be NULL")
	}
}

func TestCSVErrors(t *testing.T) {
	cases := []struct {
		data   string
		schema []storage.ColumnDef
		code   errs.Code
	}{
		{"a,b\n1\n", nil, errs.IngestError},
		{"a,a\n1,2\n", nil, errs.IngestError},
		{"a,b\n1,\"x\n", nil, errs.IngestError},
		{"a,,c\n1,2,3\n", nil, errs.IngestError},
		{"v\n10.005\n", []storage.ColumnDef{{Name: "v", Type: types.Decimal(10, 2)}}, errs.ConversionError},
		{"v\n9223372036854775808\n", []storage.ColumnDef{{Name: "v", Type: types.Int64}}, errs.ConversionError},
		{"x\n1\n", []storage.ColumnDef{{Name: "y", Type: types.Int64}}, errs.IngestError},
	}
	for _, c := range cases {
		_, err := load(t, CSV, c.data, c.schema)
		if !errs.Is(err, c.code) {
			t.Errorf("%q: got %v, want %s", c.data, err, c.code)
		}
	}
}

func TestJSON(t *testing.T) {
	tb, err := load(t, JSON, `[{"a": 1, "s": "2024-01-01"}, {"b": "xé", "a": 2.5, "s": "2024-01-01T10:00:00"}]`, nil)
	if err != nil {
		t.Fatal(err)
	}
	got := colTypes(tb)
	if len(got) != 3 || got[0] != "FLOAT64" || got[1] != "TIMESTAMP" || got[2] != "STRING" {
		t.Errorf("types = %v", got)
	}
	if tb.Vectors[2].Get(1).S != "xé" || !tb.Vectors[2].IsNull(0) {
		t.Errorf("unexpected values")
	}
	tb, err = load(t, JSONL, "{\"n\": 7}\n\n{\"n\": null}\n", []storage.ColumnDef{{Name: "N", Type: types.Decimal(5, 2)}})
	if err != nil {
		t.Fatal(err)
	}
	if v := tb.Vectors[0].Get(0); v.I != 700 {
		t.Errorf("decimal from JSON number = %d", v.I)
	}
}

func TestJSONErrors(t *testing.T) {
	cases := []struct {
		f    Format
		data string
		code errs.Code
	}{
		{JSON, `{"a": 1}`, errs.IngestError},
		{JSON, `[{"a": 1}, 2]`, errs.IngestError},
		{JSON, `[{"a": 1},]`, errs.IngestError},
		{JSONL, `{"a": 1, "a": 2}`, errs.IngestError},
		{JSONL, `{"a": NaN}`, errs.IngestError},
		{JSONL, `{"a": [1]}`, errs.IngestError},
		{JSONL, "{\"a\": 1}\n{\"a\": \"x\"}", errs.IngestError},
		{JSONL, `{"a": 1,`, errs.IngestError},
	}
	for _, c := range cases {
		if _, err := load(t, c.f, c.data, nil); !errs.Is(err, c.code) {
			t.Errorf("%q: got %v, want %s", c.data, err, c.code)
		}
	}
}
