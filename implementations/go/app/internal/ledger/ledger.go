// Package ledger stores pqledger's ledger as PQCF files
// (spec/apps/pqledger.md §4) and answers every question about it with SQL
// run by an embedded PolyQuery instance.
package ledger

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"polyquery"
	"polyquery/app/internal/config"
	"polyquery/app/internal/rules"
)

// The ledger tables (§4). Each is stored as NAME.pqcf in the data
// directory.
var (
	TransactionColumns = []polyquery.Column{
		{Name: "id", Type: polyquery.TypeInt64},
		{Name: "account", Type: polyquery.TypeString},
		{Name: "date", Type: polyquery.TypeDate},
		{Name: "description", Type: polyquery.TypeString},
		{Name: "merchant", Type: polyquery.TypeString},
		{Name: "amount", Type: Money},
		{Name: "batch", Type: polyquery.TypeInt64},
	}
	BatchColumns = []polyquery.Column{
		{Name: "batch", Type: polyquery.TypeInt64},
		{Name: "account", Type: polyquery.TypeString},
		{Name: "file", Type: polyquery.TypeString},
		{Name: "imported", Type: polyquery.TypeInt64},
		{Name: "duplicates", Type: polyquery.TypeInt64},
	}
	OverrideColumns = []polyquery.Column{
		{Name: "id", Type: polyquery.TypeInt64},
		{Name: "category", Type: polyquery.TypeString},
	}
)

// Money is the type of amounts.
var Money = polyquery.DecimalType(18, 2)

// tables lists the stored tables in the order init writes them (the
// transactions file, whose presence marks a ledger, last).
var tables = []struct {
	name    string
	columns []polyquery.Column
}{
	{"batches", BatchColumns},
	{"overrides", OverrideColumns},
	{"transactions", TransactionColumns},
}

func fileOf(table string) string { return table + ".pqcf" }

// StateError is a ledger state error: no ledger, a ledger that already
// exists, or an unknown transaction id.
type StateError struct{ Msg string }

func (e *StateError) Error() string { return e.Msg }

// Settings are the [engine] settings.
type Settings struct {
	Threads  int   // 0: engine default
	MemoryMB int64 // 0: engine default
}

// Ledger is an open ledger: its tables loaded into an embedded engine.
type Ledger struct {
	dir  string
	db   *polyquery.DB
	opts *polyquery.QueryOptions
}

func newDB(dir string, s Settings) (*polyquery.DB, error) {
	return polyquery.New(polyquery.Config{DataDir: dir, Threads: s.Threads, MaxQueryMemoryMB: s.MemoryMB})
}

// Init creates the data directory (with missing parents) and an empty
// ledger in it.
func Init(dir string, s Settings) error {
	if exists(filepath.Join(dir, fileOf("transactions"))) {
		return &StateError{Msg: fmt.Sprintf("a ledger already exists in %s", dir)}
	}
	if err := os.MkdirAll(dir, 0o777); err != nil {
		return fmt.Errorf("cannot create %s: %w", dir, err)
	}
	db, err := newDB(dir, s)
	if err != nil {
		return err
	}
	defer db.Close()
	for _, t := range tables {
		if _, err := db.CreateTable(t.name, t.columns, nil, nil); err != nil {
			return err
		}
		if _, err := db.SaveTable(t.name, fileOf(t.name), nil); err != nil {
			return err
		}
	}
	return nil
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// Open loads an existing ledger.
func Open(dir string, s Settings) (*Ledger, error) {
	if !exists(filepath.Join(dir, fileOf("transactions"))) {
		return nil, &StateError{Msg: fmt.Sprintf("no ledger in %s (run pqledger init)", dir)}
	}
	for _, t := range tables {
		if !exists(filepath.Join(dir, fileOf(t.name))) {
			return nil, &StateError{Msg: fmt.Sprintf("incomplete ledger in %s: %s is missing", dir, fileOf(t.name))}
		}
	}
	db, err := newDB(dir, s)
	if err != nil {
		return nil, err
	}
	l := &Ledger{dir: dir, db: db, opts: &polyquery.QueryOptions{Threads: s.Threads}}
	for _, t := range tables {
		info, err := db.OpenTable(t.name, fileOf(t.name), &polyquery.OpenOptions{Mmap: true})
		if err != nil {
			db.Close()
			return nil, fmt.Errorf("%s: %w", fileOf(t.name), err)
		}
		if !sameColumns(info.Columns, t.columns) {
			db.Close()
			return nil, fmt.Errorf("%s: unexpected columns %s (expected %s)", fileOf(t.name), describe(info.Columns), describe(t.columns))
		}
	}
	return l, nil
}

func sameColumns(a, b []polyquery.Column) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func describe(cols []polyquery.Column) string {
	parts := make([]string, len(cols))
	for i, c := range cols {
		parts[i] = c.Name + " " + c.Type.String()
	}
	return "(" + strings.Join(parts, ", ") + ")"
}

// Close releases the engine.
func (l *Ledger) Close() { l.db.Close() }

// Query runs one SQL statement on the loaded tables.
func (l *Ledger) Query(ctx context.Context, sql string) (*polyquery.Result, error) {
	return l.db.Query(ctx, sql, l.opts)
}

// LoadRules makes the rules table: rule_no, category, pattern.
func (l *Ledger) LoadRules(rs []rules.Rule) error {
	rows := make([][]any, len(rs))
	for i, r := range rs {
		rows[i] = []any{r.No, r.Category, r.Pattern}
	}
	_, err := l.db.CreateTable("rules", []polyquery.Column{
		{Name: "rule_no", Type: polyquery.TypeInt64},
		{Name: "category", Type: polyquery.TypeString},
		{Name: "pattern", Type: polyquery.TypeString},
	}, rows, nil)
	return err
}

// LoadBudgets makes the budgets table: category, amount.
func (l *Ledger) LoadBudgets(bs []rules.Budget) error {
	rows := make([][]any, len(bs))
	for i, b := range bs {
		amount, err := polyquery.ParseDecimal(b.Amount)
		if err != nil {
			return err
		}
		rows[i] = []any{b.Category, amount}
	}
	_, err := l.db.CreateTable("budgets", []polyquery.Column{
		{Name: "category", Type: polyquery.TypeString},
		{Name: "amount", Type: Money},
	}, rows, nil)
	return err
}

// resolveSQL computes the ledger view: the transactions with their
// resolved category (§5.1): the override, else the category of the first
// matching rule, else uncategorized. Rule patterns become LIKE patterns
// ("*" → "%", "?" → "_"; patterns contain neither "%" nor "_"); each
// distinct merchant is matched once.
const resolveSQL = `
WITH merchants AS (SELECT DISTINCT merchant FROM transactions),
first_match AS (
  SELECT m.merchant AS merchant, MIN(r.rule_no) AS rule_no
  FROM merchants m JOIN rules r ON m.merchant LIKE REPLACE(REPLACE(r.pattern, '*', '%'), '?', '_')
  GROUP BY m.merchant),
merchant_category AS (
  SELECT f.merchant AS merchant, r.category AS category
  FROM first_match f JOIN rules r ON r.rule_no = f.rule_no)
SELECT t.id AS id, t.account AS account, t."date" AS "date", t.description AS description,
       t.merchant AS merchant, t.amount AS amount, t.batch AS batch,
       COALESCE(o.category, mc.category, '` + config.Uncategorized + `') AS category
FROM transactions t
LEFT JOIN overrides o ON o.id = t.id
LEFT JOIN merchant_category mc ON mc.merchant = t.merchant
ORDER BY id`

// ResolveCategories makes the ledger table (the transactions columns plus
// the resolved category). It needs the rules table (LoadRules).
func (l *Ledger) ResolveCategories(ctx context.Context) error {
	_, err := l.db.CreateTableAs(ctx, "ledger", resolveSQL, &polyquery.CreateOptions{Query: *l.opts})
	return err
}

// commit saves tables to their files, first to temporary files that are
// then renamed over the ledger files, so that a failure while writing
// leaves the ledger unchanged.
func (l *Ledger) commit(names ...string) error {
	for _, n := range names {
		if _, err := l.db.SaveTable(n, fileOf(n)+".new", nil); err != nil {
			return err
		}
	}
	for _, n := range names {
		if err := os.Rename(filepath.Join(l.dir, fileOf(n)+".new"), filepath.Join(l.dir, fileOf(n))); err != nil {
			return err
		}
	}
	return nil
}

// sqlString quotes a string literal.
func sqlString(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }

// scalarInt runs a query returning one INT64 value (nil → 0).
func (l *Ledger) scalarInt(ctx context.Context, sql string) (int64, error) {
	res, err := l.Query(ctx, sql)
	if err != nil {
		return 0, err
	}
	if len(res.Rows) != 1 || len(res.Rows[0]) != 1 {
		return 0, fmt.Errorf("unexpected result of %q", sql)
	}
	n, _ := res.Rows[0][0].(int64)
	return n, nil
}
