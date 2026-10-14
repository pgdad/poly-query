package polyquery_test

import (
	"context"
	"errors"
	"math/big"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"polyquery"
)

func newDB(t *testing.T) (*polyquery.DB, string) {
	t.Helper()
	dir := t.TempDir()
	db, err := polyquery.New(polyquery.Config{DataDir: dir, Threads: 2})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	return db, dir
}

func query(t *testing.T, db *polyquery.DB, sql string) *polyquery.Result {
	t.Helper()
	res, err := db.Query(context.Background(), sql, nil)
	if err != nil {
		t.Fatalf("%s: %v", sql, err)
	}
	return res
}

func TestLoadAndQueryTypedValues(t *testing.T) {
	db, _ := newDB(t)
	schema := []polyquery.Column{
		{Name: "id", Type: polyquery.TypeInt64},
		{Name: "amount", Type: polyquery.DecimalType(18, 2)},
		{Name: "day", Type: polyquery.TypeDate},
		{Name: "ok", Type: polyquery.TypeBoolean},
		{Name: "name", Type: polyquery.TypeString},
	}
	info, err := db.LoadText("t", "id,amount,day,ok,name\n1,10.50,2026-01-02,true,ann\n2,,2026-01-03,false,\"\"\n", &polyquery.LoadOptions{Schema: schema})
	if err != nil {
		t.Fatal(err)
	}
	if info.RowCount != 2 || len(info.Columns) != 5 {
		t.Fatalf("info = %+v", info)
	}
	res := query(t, db, "SELECT id, amount, day, ok, name, amount * 2 AS d, CAST(id AS DOUBLE) / 4 AS f, TIMESTAMP '2026-01-02 03:04:05.5' AS ts FROM t ORDER BY id")
	wantTypes := []string{"INT64", "DECIMAL(18,2)", "DATE", "BOOLEAN", "STRING", "DECIMAL(18,2)", "FLOAT64", "TIMESTAMP"}
	for i, c := range res.Columns {
		if c.Type.String() != wantTypes[i] {
			t.Errorf("column %s type %s, want %s", c.Name, c.Type, wantTypes[i])
		}
	}
	if res.RowCount() != 2 {
		t.Fatalf("rows = %d", res.RowCount())
	}
	r := res.Rows[0]
	if r[0] != int64(1) || r[3] != true || r[4] != "ann" || r[6] != 0.25 {
		t.Errorf("row 0 = %v", r)
	}
	if d := r[1].(polyquery.Decimal); d.String() != "10.50" || d.Scale() != 2 {
		t.Errorf("amount = %v", d)
	}
	if u, ok := r[1].(polyquery.Decimal).UnscaledInt64(); !ok || u != 1050 {
		t.Errorf("unscaled = %d %v", u, ok)
	}
	if day := r[2].(polyquery.Date); day.String() != "2026-01-02" {
		t.Errorf("day = %v", day)
	} else if y, m, d := day.YMD(); y != 2026 || m != 1 || d != 2 {
		t.Errorf("YMD = %d-%d-%d", y, m, d)
	}
	if ts := r[7].(polyquery.Timestamp); ts.String() != "2026-01-02 03:04:05.500000" || ts.Time().Nanosecond() != 500000000 {
		t.Errorf("ts = %v", ts)
	}
	if res.Rows[1][1] != nil || res.Rows[1][4] != "" {
		t.Errorf("row 1 = %v (want NULL amount, empty name)", res.Rows[1])
	}
}

func TestErrorsCarryCodesAndLeaveInstanceUsable(t *testing.T) {
	db, _ := newDB(t)
	ctx := context.Background()
	cases := []struct {
		sql  string
		code polyquery.Code
	}{
		{"SELEC 1", polyquery.CodeParseError},
		{"SELECT * FROM nowhere", polyquery.CodeSemanticError},
		{"SELECT 1 / 0", polyquery.CodeDivisionByZero},
	}
	for _, c := range cases {
		_, err := db.Query(ctx, c.sql, nil)
		var pe *polyquery.Error
		if !errors.As(err, &pe) || pe.Code != c.code || pe.Message == "" {
			t.Errorf("%s: err = %v, want %s", c.sql, err, c.code)
		}
		if polyquery.ErrorCode(err) != c.code {
			t.Errorf("ErrorCode = %q", polyquery.ErrorCode(err))
		}
	}
	if _, err := db.LoadFile("x", "../escape.csv", nil); polyquery.ErrorCode(err) != polyquery.CodeAccessDenied {
		t.Errorf("path escape: %v", err)
	}
	if _, err := db.LoadFile("x", "missing.csv", nil); polyquery.ErrorCode(err) != polyquery.CodeNotFound {
		t.Errorf("missing file: %v", err)
	}
	if res := query(t, db, "SELECT 1 + 1 AS two"); res.Rows[0][0] != int64(2) {
		t.Errorf("instance unusable after errors: %v", res.Rows)
	}
}

func TestQueryOptions(t *testing.T) {
	db, _ := newDB(t)
	if _, err := db.LoadText("t", "n\n1\n2\n3\n", nil); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	if _, err := db.Query(ctx, "SELECT n FROM t", &polyquery.QueryOptions{MaxRows: 2}); polyquery.ErrorCode(err) != polyquery.CodeResourceLimit {
		t.Errorf("max rows: %v", err)
	}
	res, err := db.Query(ctx, "SELECT SUM(n) FROM t", &polyquery.QueryOptions{Threads: 1, Mode: "row"})
	if err != nil || res.Rows[0][0] != int64(6) {
		t.Errorf("row mode: %v %v", res, err)
	}
	if _, err := db.Query(ctx, "SELECT 1", &polyquery.QueryOptions{Mode: "quantum"}); polyquery.ErrorCode(err) != polyquery.CodeUnsupported {
		t.Errorf("bad mode: %v", err)
	}
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := db.Query(cancelled, "SELECT n FROM t", nil); polyquery.ErrorCode(err) != polyquery.CodeCancelled {
		t.Errorf("cancelled: %v", err)
	}
}

func TestCreateSaveOpenDropListSchema(t *testing.T) {
	db, dir := newDB(t)
	cols := []polyquery.Column{
		{Name: "id", Type: polyquery.TypeInt64},
		{Name: "amount", Type: polyquery.DecimalType(18, 2)},
		{Name: "day", Type: polyquery.TypeDate},
		{Name: "big", Type: polyquery.DecimalType(38, 0)},
	}
	day, _ := polyquery.DateOf(2026, 2, 28)
	huge, _ := new(big.Int).SetString("12345678901234567890123456789", 10)
	bigDec, err := polyquery.DecimalFromBig(huge, 0)
	if err != nil {
		t.Fatal(err)
	}
	rows := [][]any{
		{int64(1), polyquery.NewDecimal(-1250, 2), day, bigDec},
		{2, polyquery.NewDecimal(3, 0), nil, nil}, // int and an exactly rescaled Decimal
	}
	if _, err := db.CreateTable("t", cols, rows, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := db.CreateTable("t", cols, nil, nil); polyquery.ErrorCode(err) != polyquery.CodeAlreadyExists {
		t.Errorf("duplicate create: %v", err)
	}
	if _, err := db.CreateTable("u", cols, [][]any{{"x", nil, nil, nil}}, nil); polyquery.ErrorCode(err) != polyquery.CodeTypeError {
		t.Errorf("type mismatch: %v", err)
	}
	if _, err := db.CreateTable("u", cols[1:2], [][]any{{polyquery.NewDecimal(1, 3)}}, nil); err == nil {
		t.Errorf("inexact rescale accepted")
	}
	if _, err := db.SaveTable("t", "t.pqcf", nil); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "t.pqcf")); err != nil {
		t.Fatal(err)
	}
	if _, err := db.OpenTable("t", "t.pqcf", nil); polyquery.ErrorCode(err) != polyquery.CodeAlreadyExists {
		t.Errorf("open without replace: %v", err)
	}
	if _, err := db.OpenTable("t2", "t.pqcf", &polyquery.OpenOptions{Mmap: true}); err != nil {
		t.Fatal(err)
	}
	res := query(t, db, "SELECT id, amount, day, big FROM t2 ORDER BY id")
	if got := res.Rows[0][1].(polyquery.Decimal).String(); got != "-12.50" {
		t.Errorf("amount = %s", got)
	}
	if got := res.Rows[1][1].(polyquery.Decimal).String(); got != "3.00" {
		t.Errorf("rescaled amount = %s", got)
	}
	if got := res.Rows[0][3].(polyquery.Decimal).Unscaled(); got.Cmp(huge) != 0 {
		t.Errorf("wide decimal = %s", got)
	}
	if _, err := db.CreateTableAs(context.Background(), "neg", "SELECT id, -amount AS amount, NULL AS nothing FROM t2", nil); err != nil {
		t.Fatal(err)
	}
	info, err := db.Schema("neg")
	if err != nil || info.RowCount != 2 || info.Columns[2].Type != polyquery.TypeString {
		t.Errorf("schema = %+v, %v", info, err)
	}
	list, err := db.Tables()
	if err != nil || len(list) != 3 || list[0].Name != "neg" {
		t.Errorf("tables = %+v, %v", list, err)
	}
	if err := db.DropTable("neg"); err != nil {
		t.Fatal(err)
	}
	if err := db.DropTable("neg"); polyquery.ErrorCode(err) != polyquery.CodeNotFound {
		t.Errorf("second drop: %v", err)
	}
	if _, err := db.Schema("neg"); polyquery.ErrorCode(err) != polyquery.CodeNotFound {
		t.Errorf("schema of dropped table: %v", err)
	}
}

func TestQueryRowsStreams(t *testing.T) {
	db, _ := newDB(t)
	if _, err := db.LoadText("t", "n\n1\n2\n3\n", nil); err != nil {
		t.Fatal(err)
	}
	rows, err := db.QueryRows(context.Background(), "SELECT n FROM t ORDER BY n DESC", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var got []int64
	for rows.Next() {
		got = append(got, rows.Values()[0].(int64))
	}
	if rows.Err() != nil || len(got) != 3 || got[0] != 3 || rows.Columns()[0].Name != "n" {
		t.Errorf("got %v, %v", got, rows.Err())
	}
}

func TestConcurrentQueries(t *testing.T) {
	db, _ := newDB(t)
	if _, err := db.LoadText("t", "n\n1\n2\n3\n", nil); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			res, err := db.Query(context.Background(), "SELECT SUM(n) FROM t", nil)
			if err != nil || res.Rows[0][0] != int64(6) {
				t.Errorf("concurrent query: %v %v", res, err)
			}
		}()
	}
	wg.Wait()
}

func TestCloseAndConfig(t *testing.T) {
	db, _ := newDB(t)
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Query(context.Background(), "SELECT 1", nil); polyquery.ErrorCode(err) != polyquery.CodeInvalidRequest {
		t.Errorf("query after close: %v", err)
	}
	if _, err := polyquery.New(polyquery.Config{DataDir: filepath.Join(t.TempDir(), "nope")}); polyquery.ErrorCode(err) != polyquery.CodeNotFound {
		t.Errorf("missing data dir: %v", err)
	}
	if _, err := polyquery.New(polyquery.Config{Threads: -1}); polyquery.ErrorCode(err) != polyquery.CodeInvalidArgument {
		t.Errorf("negative threads: %v", err)
	}
}

func TestDecimalAndDateHelpers(t *testing.T) {
	d, err := polyquery.ParseDecimal("-0.50")
	if err != nil || d.String() != "-0.50" || d.Sign() != -1 || d.Float64() != -0.5 {
		t.Errorf("ParseDecimal = %v, %v", d, err)
	}
	if d.Cmp(polyquery.NewDecimal(-5, 1)) != 0 || d.Rat().String() != "-1/2" {
		t.Errorf("Cmp/Rat")
	}
	for _, bad := range []string{"", "-", "1e5", "1.2.3", "12345678901234567890123456789012345678901"} {
		if _, err := polyquery.ParseDecimal(bad); err == nil {
			t.Errorf("ParseDecimal(%q) accepted", bad)
		}
	}
	if _, ok := polyquery.DateOf(2026, 2, 29); ok {
		t.Errorf("2026-02-29 accepted")
	}
	if day, err := polyquery.ParseDate("1969-12-31"); err != nil || day != -1 {
		t.Errorf("ParseDate = %d %v", day, err)
	}
	if typ, err := polyquery.ParseType("numeric(10, 3)"); err != nil || typ.String() != "DECIMAL(10,3)" {
		t.Errorf("ParseType = %v %v", typ, err)
	}
}
