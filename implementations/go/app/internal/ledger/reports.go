package ledger

import (
	"context"
	"fmt"
	"math/big"
	"strings"

	"polyquery"
)

// Filter restricts the transactions a report, list or export covers.
type Filter struct {
	From, To polyquery.Date // inclusive date range, if HasFrom / HasTo
	HasFrom  bool
	HasTo    bool
	Account  string // "" = all accounts
	Category string // "" = all categories (list only)
}

// where returns the SQL conditions of f, joined by AND (a leading "AND"
// is included, so the result can follow any WHERE clause).
func (f Filter) where() string {
	var b strings.Builder
	if f.HasFrom {
		fmt.Fprintf(&b, ` AND "date" >= DATE '%s'`, f.From)
	}
	if f.HasTo {
		fmt.Fprintf(&b, ` AND "date" <= DATE '%s'`, f.To)
	}
	if f.Account != "" {
		fmt.Fprintf(&b, " AND account = %s", sqlString(f.Account))
	}
	if f.Category != "" {
		fmt.Fprintf(&b, " AND category = %s", sqlString(f.Category))
	}
	return b.String()
}

// Monthly is `report monthly` (§9.1).
func (l *Ledger) Monthly(ctx context.Context, f Filter) (*polyquery.Result, error) {
	return l.Query(ctx, `SELECT month,
		SUM(CASE WHEN amount > 0 THEN amount ELSE 0.00 END) AS income,
		-SUM(CASE WHEN amount < 0 THEN amount ELSE 0.00 END) AS expenses,
		SUM(amount) AS net,
		COUNT(*) AS transactions
	FROM (SELECT SUBSTR(CAST("date" AS STRING), 1, 7) AS month, amount
	      FROM transactions WHERE TRUE`+f.where()+`) t
	GROUP BY month ORDER BY month`)
}

// Categories is `report categories` (§9.2). The share column is computed
// here, exactly, from the spent amounts in cents.
func (l *Ledger) Categories(ctx context.Context, f Filter) (*polyquery.Result, error) {
	res, err := l.Query(ctx, `SELECT category, -SUM(amount) AS spent, COUNT(*) AS transactions
	FROM ledger WHERE amount < 0`+f.where()+`
	GROUP BY category ORDER BY spent DESC, category`)
	if err != nil {
		return nil, err
	}
	total := new(big.Int)
	for _, row := range res.Rows {
		total.Add(total, row[1].(polyquery.Decimal).Unscaled())
	}
	out := &polyquery.Result{
		Columns: []polyquery.Column{res.Columns[0], res.Columns[1],
			{Name: "share", Type: polyquery.DecimalType(18, 1)}, res.Columns[2]},
		Rows: make([][]any, len(res.Rows)),
	}
	for i, row := range res.Rows {
		share, err := polyquery.DecimalFromBig(Share(row[1].(polyquery.Decimal).Unscaled(), total), 1)
		if err != nil {
			return nil, err
		}
		out.Rows[i] = []any{row[0], row[1], share, row[2]}
	}
	return out, nil
}

// Share returns 100 × part ÷ total in tenths, rounded half away from zero
// (part, total ≥ 0; total > 0).
func Share(part, total *big.Int) *big.Int {
	// round(1000·part / total) = floor((2000·part + total) / (2·total))
	num := new(big.Int).Mul(part, big.NewInt(2000))
	num.Add(num, total)
	den := new(big.Int).Mul(total, big.NewInt(2))
	return num.Quo(num, den)
}

// Merchants is `report merchants` (§9.3).
func (l *Ledger) Merchants(ctx context.Context, f Filter, top int64) (*polyquery.Result, error) {
	return l.Query(ctx, fmt.Sprintf(`SELECT merchant, -SUM(amount) AS spent, COUNT(*) AS transactions
	FROM transactions WHERE amount < 0%s
	GROUP BY merchant ORDER BY spent DESC, merchant LIMIT %d`, f.where(), top))
}

// Budget is `budget` (§9.4); f covers one month. It needs the budgets
// table (LoadBudgets).
func (l *Ledger) Budget(ctx context.Context, f Filter) (*polyquery.Result, error) {
	return l.Query(ctx, `SELECT b.category AS category, b.amount AS budget,
		COALESCE(s.spent, 0.00) AS spent,
		b.amount - COALESCE(s.spent, 0.00) AS remaining,
		CASE WHEN COALESCE(s.spent, 0.00) <= b.amount THEN 'ok' ELSE 'over' END AS status
	FROM budgets b LEFT JOIN (
		SELECT category, -SUM(amount) AS spent FROM ledger WHERE amount < 0`+f.where()+`
		GROUP BY category) s ON s.category = b.category
	ORDER BY category`)
}

// Accounts is `accounts` (§8.4).
func (l *Ledger) Accounts(ctx context.Context) (*polyquery.Result, error) {
	return l.Query(ctx, `SELECT account, COUNT(*) AS transactions, SUM(amount) AS balance,
		MIN("date") AS "first", MAX("date") AS "last"
	FROM transactions GROUP BY account ORDER BY account`)
}

// List is `list` (§8.1).
func (l *Ledger) List(ctx context.Context, f Filter) (*polyquery.Result, error) {
	return l.Query(ctx, `SELECT id, "date", account, description, amount, category
	FROM ledger WHERE TRUE`+f.where()+` ORDER BY "date", id`)
}

// Export is `export` (§8.2).
func (l *Ledger) Export(ctx context.Context, f Filter) (*polyquery.Result, error) {
	return l.Query(ctx, `SELECT id, account, "date", description, merchant, amount, category, batch
	FROM ledger WHERE TRUE`+f.where()+` ORDER BY id`)
}
