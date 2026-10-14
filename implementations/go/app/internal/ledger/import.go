package ledger

import (
	"context"
	"fmt"

	"polyquery"
	"polyquery/app/internal/bank"
)

// ImportResult summarizes an import.
type ImportResult struct {
	Batch      int64
	Imported   int
	Duplicates int
}

// key identifies possibly duplicate transactions (§6.4).
type key struct {
	date     polyquery.Date
	amount   int64
	merchant string
}

// Import adds the converted records of one statement file as a new batch.
// For each key (account, date, amount, merchant) with f records in the
// file and n transactions in the ledger, the last max(0, f−n) records are
// imported and the others are duplicates.
func (l *Ledger) Import(ctx context.Context, account, file string, txs []bank.Transaction) (ImportResult, error) {
	var res ImportResult
	existing, err := l.existingKeys(ctx, account, txs)
	if err != nil {
		return res, err
	}
	inFile := map[key]int{}
	for _, t := range txs {
		inFile[key{t.Date, t.Amount, t.Merchant}]++
	}
	maxID, err := l.scalarInt(ctx, "SELECT COALESCE(MAX(id), 0) FROM transactions")
	if err != nil {
		return res, err
	}
	// The next batch number also accounts for transactions whose batch
	// record might be missing.
	maxBatch, err := l.scalarInt(ctx, `SELECT MAX(b) FROM (
		SELECT COALESCE(MAX(batch), 0) AS b FROM batches UNION ALL SELECT COALESCE(MAX(batch), 0) FROM transactions) x`)
	if err != nil {
		return res, err
	}
	res.Batch = maxBatch + 1
	var rows [][]any
	seen := map[key]int{}
	for _, t := range txs {
		k := key{t.Date, t.Amount, t.Merchant}
		seen[k]++
		// Skip the first min(f, n) records of the key: the last
		// max(0, f−n) are new.
		if seen[k] <= min(inFile[k], existing[k]) {
			res.Duplicates++
			continue
		}
		maxID++
		rows = append(rows, []any{maxID, account, t.Date, t.Description, t.Merchant, polyquery.NewDecimal(t.Amount, 2), res.Batch})
	}
	res.Imported = len(rows)
	changed := []string{"batches"}
	if len(rows) > 0 {
		if _, err := l.db.CreateTable("incoming", TransactionColumns, rows, nil); err != nil {
			return res, err
		}
		if _, err := l.db.CreateTableAs(ctx, "transactions",
			"SELECT * FROM transactions UNION ALL SELECT * FROM incoming ORDER BY id",
			&polyquery.CreateOptions{Replace: true, Query: *l.opts}); err != nil {
			return res, err
		}
		changed = append(changed, "transactions")
	}
	batch := [][]any{{res.Batch, account, file, int64(res.Imported), int64(res.Duplicates)}}
	if _, err := l.db.CreateTable("new_batch", BatchColumns, batch, nil); err != nil {
		return res, err
	}
	if _, err := l.db.CreateTableAs(ctx, "batches",
		"SELECT * FROM batches UNION ALL SELECT * FROM new_batch ORDER BY batch",
		&polyquery.CreateOptions{Replace: true, Query: *l.opts}); err != nil {
		return res, err
	}
	return res, l.commit(changed...)
}

// existingKeys counts the account's ledger transactions per key, for the
// dates of the file's records.
func (l *Ledger) existingKeys(ctx context.Context, account string, txs []bank.Transaction) (map[key]int, error) {
	counts := map[key]int{}
	if len(txs) == 0 {
		return counts, nil
	}
	lo, hi := txs[0].Date, txs[0].Date
	for _, t := range txs {
		lo, hi = min(lo, t.Date), max(hi, t.Date)
	}
	res, err := l.Query(ctx, fmt.Sprintf(`SELECT "date", amount, merchant, COUNT(*) AS n FROM transactions
		WHERE account = %s AND "date" BETWEEN DATE '%s' AND DATE '%s'
		GROUP BY "date", amount, merchant`, sqlString(account), lo, hi))
	if err != nil {
		return nil, err
	}
	for _, row := range res.Rows {
		cents, ok := row[1].(polyquery.Decimal).UnscaledInt64()
		if !ok {
			return nil, fmt.Errorf("amount %v out of range", row[1])
		}
		counts[key{row[0].(polyquery.Date), cents, row[2].(string)}] = int(row[3].(int64))
	}
	return counts, nil
}

// SetCategory sets (category != "") or clears the override of a
// transaction.
func (l *Ledger) SetCategory(ctx context.Context, id int64, category string) error {
	n, err := l.scalarInt(ctx, fmt.Sprintf("SELECT COUNT(*) FROM transactions WHERE id = %d", id))
	if err != nil {
		return err
	}
	if n == 0 {
		return &StateError{Msg: fmt.Sprintf("unknown transaction id %d", id)}
	}
	sql := fmt.Sprintf("SELECT id, category FROM overrides WHERE id <> %d", id)
	if category != "" {
		if _, err := l.db.CreateTable("new_override", OverrideColumns, [][]any{{id, category}}, nil); err != nil {
			return err
		}
		sql += " UNION ALL SELECT id, category FROM new_override"
	}
	if _, err := l.db.CreateTableAs(ctx, "overrides", sql+" ORDER BY id",
		&polyquery.CreateOptions{Replace: true, Query: *l.opts}); err != nil {
		return err
	}
	return l.commit("overrides")
}
