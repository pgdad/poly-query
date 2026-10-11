package engine

import (
	"context"
	"fmt"
	"math/rand/v2"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"

	"polyquery/internal/errs"
	"polyquery/internal/ingest"
	"polyquery/internal/native"
	"polyquery/internal/storage"
	"polyquery/internal/types"
)

// testNativeLib loads libpqkernels from $PQ_NATIVE_KERNELS or the workspace
// build directory (the test is skipped when it is unavailable).
func testNativeLib(t *testing.T) *native.Lib {
	t.Helper()
	path := os.Getenv("PQ_NATIVE_KERNELS")
	if path == "" {
		arch := map[string]string{"amd64": "x86_64", "arm64": "aarch64"}[runtime.GOARCH]
		path = filepath.Join("..", "..", "..", "..", "native-kernels", "build", arch, "libpqkernels.so")
	}
	if _, err := os.Stat(path); err != nil || !native.Supported() {
		t.Skipf("native kernel library not available (%s)", path)
	}
	lib, err := native.Load(path)
	if err != nil {
		t.Fatalf("load %s: %v", path, err)
	}
	return lib
}

// newNativeEngine loads the same random data (NULLs, values near the int64
// limits, several DECIMAL scales) into tables with different storage:
// column layout (large groups), column layout with odd group sizes, and
// row layout.
func newNativeEngine(t *testing.T, lib *native.Lib) *Engine {
	t.Helper()
	cfg := DefaultConfig()
	cfg.DataDir = t.TempDir()
	cfg.MorselRows = 1000 + 3 // morsels start at bit offsets that are not byte-aligned
	cfg.Native = lib
	e := New(cfg)
	r := rand.New(rand.NewPCG(7, 11))
	var sb strings.Builder
	sb.WriteString("id,a,b,big,d,d3,f,day,ts,flag,s\n")
	opt := func(p int, s string) string {
		if r.IntN(100) < p {
			return ""
		}
		return s
	}
	for i := 0; i < 9000; i++ {
		big := int64(4e18) + r.Int64N(1000)
		if i%2 == 1 {
			big = -big + r.Int64N(10)
		}
		fmt.Fprintf(&sb, "%d,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n", i,
			opt(10, fmt.Sprint(r.IntN(201)-100)),
			opt(30, fmt.Sprint(r.IntN(201)-100)),
			opt(5, fmt.Sprint(big)),
			opt(15, fmt.Sprintf("%d.%02d", r.IntN(2000)-1000, r.IntN(100))),
			opt(15, fmt.Sprintf("%d.%03d", r.IntN(20)-10, r.IntN(1000))),
			opt(15, strconv.FormatFloat(float64(r.IntN(4001)-2000)/8, 'g', -1, 64)),
			opt(10, fmt.Sprintf("2024-%02d-%02d", 1+r.IntN(12), 1+r.IntN(28))),
			opt(10, fmt.Sprintf("2024-01-01 %02d:%02d:00", r.IntN(24), r.IntN(60))),
			opt(20, fmt.Sprint(r.IntN(2) == 0)),
			opt(20, []string{"x", "y", "zz", "w"}[r.IntN(4)]),
		)
	}
	data := sb.String()
	opts := ingest.DefaultOptions(ingest.CSV)
	opts.Schema = []storage.ColumnDef{
		{Name: "id", Type: types.Int64}, {Name: "a", Type: types.Int64}, {Name: "b", Type: types.Int64},
		{Name: "big", Type: types.Int64}, {Name: "d", Type: types.Decimal(12, 2)}, {Name: "d3", Type: types.Decimal(18, 3)},
		{Name: "f", Type: types.Float64}, {Name: "day", Type: types.Date}, {Name: "ts", Type: types.Timestamp},
		{Name: "flag", Type: types.Boolean}, {Name: "s", Type: types.String},
	}
	for name, build := range map[string]storage.BuildOptions{
		"t":  {},
		"tg": {GroupSize: 1001},
		"tr": {Layout: storage.RowLayout, GroupSize: 2500},
	} {
		if _, err := e.Load(LoadRequest{Table: name, Data: &data, Options: opts, Build: build}); err != nil {
			t.Fatal(err)
		}
	}
	return e
}

// exact renders a result exactly, in result order (or the error code).
func exact(e *Engine, sql string, c modeConfig, nat bool) string {
	res, err := e.Query(context.Background(), sql, QueryOptions{
		MaxRows: -1, Mode: c.mode, Join: c.join, Threads: c.threads, NoOptimize: !c.optimize, Native: nat,
	})
	if err != nil {
		return "error " + string(errs.From(err).Code)
	}
	var sb strings.Builder
	for _, row := range res.Rows {
		for i, v := range row {
			if i > 0 {
				sb.WriteByte(',')
			}
			if res.Columns[i].Type.Kind == types.KindFloat64 && !v.Null {
				sb.WriteString(strconv.FormatFloat(v.F, 'g', -1, 64))
			} else {
				sb.WriteString(types.FormatValue(v, res.Columns[i].Type))
			}
		}
		sb.WriteByte('|')
	}
	return sb.String()
}

var nativeQueries = []string{
	// Filters: comparisons, BETWEEN, IN, IS NULL, NOT, OR, column pairs.
	"SELECT id FROM %s WHERE a > 10",
	"SELECT id, a FROM %s WHERE a = 5 OR b = -5",
	"SELECT id FROM %s WHERE NOT (a < 0 AND b >= 3)",
	"SELECT id FROM %s WHERE a BETWEEN -3 AND 4 AND b NOT BETWEEN 0 AND 50",
	"SELECT id FROM %s WHERE a IN (1, 2, 3, NULL) OR b NOT IN (4, 5)",
	"SELECT id FROM %s WHERE b NOT IN (4, NULL)",
	"SELECT id FROM %s WHERE a IS NULL AND b IS NOT NULL",
	"SELECT id FROM %s WHERE NOT (s IS NULL) AND f IS NULL",
	"SELECT id FROM %s WHERE a < b",
	"SELECT id FROM %s WHERE NOT (a <> b)",
	"SELECT id FROM %s WHERE flag",
	"SELECT id FROM %s WHERE NOT flag",
	"SELECT id FROM %s WHERE flag = FALSE OR flag IS NULL",
	"SELECT id FROM %s WHERE d > 12.5 AND d <= 400",
	"SELECT id FROM %s WHERE d = 12.505",
	"SELECT id FROM %s WHERE d <> 3 AND d3 < -2.5",
	"SELECT id FROM %s WHERE d3 BETWEEN -1 AND 1.25",
	"SELECT id FROM %s WHERE day >= DATE '2024-06-01' AND day < DATE '2024-07-01'",
	"SELECT id FROM %s WHERE ts > TIMESTAMP '2024-01-01 12:00:00'",
	"SELECT id FROM %s WHERE a > NULL OR id = 7",
	"SELECT id FROM %s WHERE a = 1 AND s = 'x'",
	"SELECT id FROM %s WHERE a > 0 AND f > 10.5",
	"SELECT id FROM %s WHERE TRUE AND NOT FALSE AND a = 3",
	"SELECT id FROM %s WHERE id > 8990 OR a + 1 = 2",
	"SELECT id FROM %s WHERE big > 0 AND a = 1",
	"SELECT id FROM %s WHERE 5 < a",
	"SELECT id, s FROM %s WHERE a > 50 ORDER BY s, id LIMIT 20",
	// Global aggregates (native scan aggregation).
	"SELECT COUNT(*), COUNT(a), SUM(a), AVG(a), MIN(a), MAX(a) FROM %s",
	"SELECT COUNT(*), SUM(b), MIN(d), MAX(d), SUM(d), AVG(d3) FROM %s WHERE a > 0",
	"SELECT MIN(f), MAX(f), MIN(day), MAX(ts), MIN(flag), MAX(flag), COUNT(s) FROM %s WHERE b < 0",
	"SELECT SUM(big) FROM %s",
	"SELECT SUM(big) FROM %s WHERE id < 2000",
	"SELECT SUM(big) FROM %s WHERE id < 2001",
	"SELECT AVG(big), COUNT(big) FROM %s",
	"SELECT SUM(big) FROM %s WHERE big > 0",
	"SELECT COUNT(*) FROM %s WHERE a IS NULL",
	"SELECT COUNT(*), SUM(a) FROM %s WHERE a > 1000",
	"SELECT MAX(DISTINCT a), MIN(DISTINCT d) FROM %s",
	"SELECT COUNT(DISTINCT a), SUM(a) FROM %s",
	"SELECT SUM(f), SUM(a) FROM %s WHERE a > 0",
	"SELECT SUM(a) + 1 AS s, COUNT(*) FROM %s WHERE b = 3 HAVING COUNT(*) > 0",
	"SELECT x FROM (SELECT SUM(a) AS x FROM (SELECT a AS a2, a FROM %s) q WHERE a2 > 5) z",
	"SELECT COUNT(*) FROM %s WHERE a > 0 AND s LIKE 'z%%'",
	// Grouped aggregates, joins, DISTINCT.
	"SELECT a, COUNT(*), SUM(b), SUM(d), AVG(b), MIN(f) FROM %s GROUP BY a ORDER BY a",
	"SELECT s, SUM(big) FROM %s GROUP BY s ORDER BY s",
	"SELECT flag, SUM(big) FROM %s WHERE id %% 2 = 0 GROUP BY flag",
	"SELECT b, SUM(a), COUNT(a) FROM %s WHERE a > -50 GROUP BY b",
	"SELECT x.id, y.id FROM %[1]s x JOIN %[1]s y ON x.a = y.id WHERE x.b = 7 ORDER BY x.id, y.id",
	"SELECT COUNT(*), SUM(y.b) FROM %[1]s x JOIN %[1]s y ON x.a = y.b WHERE x.id < 500",
	"SELECT x.id, y.b FROM %[1]s x LEFT JOIN %[1]s y ON x.id = y.a AND y.b > 90 WHERE x.id < 300",
	"SELECT DISTINCT a FROM %s WHERE b > 95",
	"SELECT id FROM %s WHERE a = (SELECT MAX(a) FROM %[1]s WHERE b = 1)",
	"SELECT id FROM %[1]s o WHERE b = (SELECT MIN(i.b) FROM %[1]s i WHERE i.a = o.a AND i.b > 90) ORDER BY id",
}

var nativeModes = []modeConfig{
	{"row", "hash", 1, true},
	{"row", "merge", 4, false},
	{"vectorized", "hash", 1, true},
	{"vectorized", "hash", 4, true},
	{"vectorized", "merge", 3, false},
}

// TestNativeResultsIdentical checks that native: true gives exactly the
// results (and errors) of the engine's own code paths.
func TestNativeResultsIdentical(t *testing.T) {
	e := newNativeEngine(t, testNativeLib(t))
	for _, table := range []string{"t", "tg", "tr"} {
		for _, q := range nativeQueries {
			sql := fmt.Sprintf(q, table)
			for _, c := range nativeModes {
				want := exact(e, sql, c, false)
				if got := exact(e, sql, c, true); got != want {
					t.Errorf("%s %+v:\n  native %.300s\n  plain  %.300s", sql, c, got, want)
				}
			}
		}
	}
}

// TestNativeOverflowSemantics pins the exact SUM overflow behaviour:
// overflow is decided on the exact final sum.
func TestNativeOverflowSemantics(t *testing.T) {
	e := newNativeEngine(t, testNativeLib(t))
	data := "g,v\n1,9000000000000000000\n1,9000000000000000000\n2,5\n1,-9000000000000000000\n1,-9000000000000000000\n2,9223372036854775807\n"
	if _, err := e.Load(LoadRequest{Table: "ov", Data: &data, Options: ingest.DefaultOptions(ingest.CSV)}); err != nil {
		t.Fatal(err)
	}
	cases := map[string]string{
		"SELECT SUM(big) FROM t WHERE big > 0":            "error NUMERIC_OVERFLOW",
		"SELECT SUM(v) FROM ov WHERE g = 1":               "0|",
		"SELECT SUM(v), COUNT(*) FROM ov WHERE g = 2":     "error NUMERIC_OVERFLOW",
		"SELECT SUM(v) FROM ov WHERE g = 2 AND v < 10":    "5|",
		"SELECT g, SUM(v) FROM ov WHERE g = 1 GROUP BY g": "1,0|",
		"SELECT g, SUM(v) FROM ov GROUP BY g":             "error NUMERIC_OVERFLOW",
		"SELECT AVG(v) FROM ov":                           "1.5372286728091292e+18|",
	}
	for sql, want := range cases {
		for _, c := range nativeModes {
			if got := exact(e, sql, c, true); got != want {
				t.Errorf("%s %+v: %s, want %s", sql, c, got, want)
			}
		}
	}
}
