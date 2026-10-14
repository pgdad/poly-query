package output

import (
	"strings"
	"testing"

	"polyquery"
)

func sample() *polyquery.Result {
	day, _ := polyquery.DateOf(2026, 8, 1)
	return &polyquery.Result{
		Columns: []polyquery.Column{
			{Name: "name", Type: polyquery.TypeString},
			{Name: "amount", Type: polyquery.DecimalType(18, 2)},
			{Name: "n", Type: polyquery.TypeInt64},
			{Name: "f", Type: polyquery.TypeFloat64},
			{Name: "day", Type: polyquery.TypeDate},
			{Name: "b", Type: polyquery.TypeBoolean},
		},
		Rows: [][]any{
			{"Ünï, \"q\"", polyquery.NewDecimal(-1250, 2), int64(3), 0.5, day, true},
			{"", nil, int64(-10), -0.0000001, nil, nil},
		},
	}
}

func render(t *testing.T, format string, r *polyquery.Result) string {
	t.Helper()
	var b strings.Builder
	if err := Write(&b, format, r); err != nil {
		t.Fatal(err)
	}
	return b.String()
}

func TestTable(t *testing.T) {
	want := "" +
		"name      amount    n         f  day         b\n" +
		"--------  ------  ---  --------  ----------  ----\n" +
		"Ünï, \"q\"  -12.50    3  0.500000  2026-08-01  true\n" +
		"                  -10  0.000000\n" +
		"(2 rows)\n"
	if got := render(t, "table", sample()); got != want {
		t.Errorf("got\n%s\nwant\n%s", got, want)
	}
	one := sample()
	one.Rows = one.Rows[:1]
	if got := render(t, "table", one); !strings.HasSuffix(got, "(1 row)\n") {
		t.Errorf("footer: %q", got)
	}
}

func TestCSV(t *testing.T) {
	want := "name,amount,n,f,day,b\n\"Ünï, \"\"q\"\"\",-12.50,3,0.500000,2026-08-01,true\n\"\",,-10,0.000000,,\n"
	if got := render(t, "csv", sample()); got != want {
		t.Errorf("got %q\nwant %q", got, want)
	}
}

func TestJSON(t *testing.T) {
	r := sample()
	r.Rows[1][0] = "a\\b\t\x01\n"
	want := `{"name":"Ünï, \"q\"","amount":"-12.50","n":3,"f":0.500000,"day":"2026-08-01","b":true}` + "\n" +
		`{"name":"a\\b\t\u0001\n","amount":null,"n":-10,"f":0.000000,"day":null,"b":null}` + "\n"
	if got := render(t, "json", r); got != want {
		t.Errorf("got %s\nwant %s", got, want)
	}
	r.Rows = nil
	if got := render(t, "json", r); got != "" {
		t.Errorf("zero rows: %q", got)
	}
}
