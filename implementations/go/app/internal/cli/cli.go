// Package cli implements pqledger's command line (spec/apps/pqledger.md
// §2, §6–§10).
package cli

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"math"
	"path/filepath"
	"strconv"
	"strings"

	"polyquery"
	"polyquery/app/internal/bank"
	"polyquery/app/internal/config"
	"polyquery/app/internal/ledger"
	"polyquery/app/internal/output"
	"polyquery/app/internal/rules"
)

// Version is the application version.
const Version = "1.0.0"

// Exit statuses (§10).
const (
	exitOK         = 0
	exitUsage      = 1
	exitConfig     = 2
	exitOverBudget = 3
	exitImport     = 4
	exitQuery      = 5
	exitState      = 6
	exitOther      = 7
)

// queryError is an engine error reported by the query command (exit 5).
type queryError struct{ err error }

func (e *queryError) Error() string { return e.err.Error() }
func (e *queryError) Unwrap() error { return e.err }

// Main runs pqledger with the given arguments (without the program name)
// and returns the exit status. Results go to stdout only if the command
// succeeds (or finds a category over budget).
func Main(args []string, stdout, stderr io.Writer) int {
	var out bytes.Buffer
	status, err := run(context.Background(), args, &out)
	if err != nil {
		fmt.Fprintf(stderr, "pqledger: error: %v\n", err)
		return exitStatus(err)
	}
	if _, err := stdout.Write(out.Bytes()); err != nil {
		fmt.Fprintf(stderr, "pqledger: error: cannot write output: %v\n", err)
		return exitOther
	}
	return status
}

func exitStatus(err error) int {
	var (
		ue *usageError
		ce *config.Error
		be *bank.Error
		qe *queryError
		se *ledger.StateError
	)
	switch {
	case errors.As(err, &ue):
		return exitUsage
	case errors.As(err, &ce):
		return exitConfig
	case errors.As(err, &be):
		return exitImport
	case errors.As(err, &qe):
		return exitQuery
	case errors.As(err, &se):
		return exitState
	}
	return exitOther
}

// app holds what a command needs.
type app struct {
	cfg    *config.Config
	format string
	out    io.Writer
}

func run(ctx context.Context, args []string, out io.Writer) (int, error) {
	inv, err := parseArgs(args)
	if err != nil {
		return 0, err
	}
	switch inv.command {
	case "help":
		_, err := io.WriteString(out, usage)
		return exitOK, err
	case "version":
		_, err := fmt.Fprintf(out, "pqledger %s (PolyQuery engine %s, embedded)\n", Version, polyquery.Version)
		return exitOK, err
	}
	// Validate the command's arguments before touching any file.
	exec, err := prepare(inv)
	if err != nil {
		return 0, err
	}
	cfg, err := config.Load(config.Locate(inv.config))
	if err != nil {
		return 0, err
	}
	a := &app{cfg: cfg, format: cfg.Format, out: out}
	if inv.format != "" {
		a.format = inv.format
	}
	return exec(ctx, a)
}

func (a *app) settings() ledger.Settings {
	return ledger.Settings{Threads: a.cfg.Threads, MemoryMB: a.cfg.MemoryMB}
}

func (a *app) print(res *polyquery.Result) error { return output.Write(a.out, a.format, res) }

// open opens the ledger with the rules table loaded, and the budgets
// table if withBudgets is set (requireBudgets: a budget file must be
// configured).
func (a *app) open(ctx context.Context, withBudgets, requireBudgets bool) (*ledger.Ledger, error) {
	var rs []rules.Rule
	var bs []rules.Budget
	var err error
	if a.cfg.RulesFile != "" {
		if rs, err = rules.LoadRules(a.cfg.RulesFile); err != nil {
			return nil, err
		}
	}
	if requireBudgets && a.cfg.BudgetFile == "" {
		return nil, &config.Error{File: a.cfg.File, Msg: "budget needs budget_file in [ledger]"}
	}
	if withBudgets && a.cfg.BudgetFile != "" {
		if bs, err = rules.LoadBudgets(a.cfg.BudgetFile); err != nil {
			return nil, err
		}
	}
	l, err := ledger.Open(a.cfg.DataDir, a.settings())
	if err != nil {
		return nil, err
	}
	if err := l.LoadRules(rs); err != nil {
		l.Close()
		return nil, err
	}
	if withBudgets {
		if err := l.LoadBudgets(bs); err != nil {
			l.Close()
			return nil, err
		}
	}
	return l, nil
}

// commandFunc executes a validated command.
type commandFunc func(ctx context.Context, a *app) (int, error)

// prepare validates the command-specific arguments and returns the
// function that executes the command.
func prepare(inv *invocation) (commandFunc, error) {
	switch inv.command {
	case "init":
		return runInit, nil
	case "import":
		return prepareImport(inv)
	case "report monthly":
		return filtered(inv, false, (*ledger.Ledger).Monthly)
	case "report categories":
		return filtered(inv, true, (*ledger.Ledger).Categories)
	case "export":
		return filtered(inv, true, (*ledger.Ledger).Export)
	case "report merchants":
		return prepareMerchants(inv)
	case "budget":
		return prepareBudget(inv)
	case "accounts":
		return withLedger(false, (*ledger.Ledger).Accounts), nil
	case "list":
		return prepareList(inv)
	case "set-category":
		return prepareSetCategory(inv)
	case "query":
		return prepareQuery(inv), nil
	}
	return nil, usagef("unknown command %q", inv.command)
}

// withLedger runs a query on the opened ledger and prints its result.
func withLedger(categories bool, q func(*ledger.Ledger, context.Context) (*polyquery.Result, error)) commandFunc {
	return func(ctx context.Context, a *app) (int, error) {
		l, err := a.open(ctx, false, false)
		if err != nil {
			return 0, err
		}
		defer l.Close()
		if categories {
			if err := l.ResolveCategories(ctx); err != nil {
				return 0, err
			}
		}
		res, err := q(l, ctx)
		if err != nil {
			return 0, err
		}
		return exitOK, a.print(res)
	}
}

// filtered is withLedger for a query taking the common filter options.
func filtered(inv *invocation, categories bool, q func(*ledger.Ledger, context.Context, ledger.Filter) (*polyquery.Result, error)) (commandFunc, error) {
	f, err := inv.filter()
	if err != nil {
		return nil, err
	}
	return withLedger(categories, func(l *ledger.Ledger, ctx context.Context) (*polyquery.Result, error) {
		return q(l, ctx, f)
	}), nil
}

func runInit(ctx context.Context, a *app) (int, error) {
	if err := ledger.Init(a.cfg.DataDir, a.settings()); err != nil {
		return 0, err
	}
	_, err := io.WriteString(a.out, "initialized ledger\n")
	return exitOK, err
}

func prepareMerchants(inv *invocation) (commandFunc, error) {
	f, err := inv.filter()
	if err != nil {
		return nil, err
	}
	top := int64(10)
	if v, ok := inv.opts["--top"]; ok {
		if v == "" || strings.Trim(v, "0123456789") != "" {
			return nil, usagef("--top needs an integer ≥ 1, got %q", v)
		}
		if top, err = strconv.ParseInt(v, 10, 64); err != nil {
			top = math.MaxInt64 // more rows than any ledger has
		}
		if top < 1 {
			return nil, usagef("--top needs an integer ≥ 1, got %q", v)
		}
	}
	return withLedger(false, func(l *ledger.Ledger, ctx context.Context) (*polyquery.Result, error) {
		return l.Merchants(ctx, f, top)
	}), nil
}

func prepareList(inv *invocation) (commandFunc, error) {
	f, err := inv.filter()
	if err != nil {
		return nil, err
	}
	c, hasCategory := inv.opts["--category"]
	_, uncategorized := inv.opts["--uncategorized"]
	switch {
	case hasCategory && uncategorized:
		return nil, usagef("--category and --uncategorized exclude each other")
	case uncategorized:
		f.Category = config.Uncategorized
	case hasCategory:
		if !config.ValidCategory(c) {
			return nil, usagef("invalid category name %q (expected [a-z0-9_-]{1,32})", c)
		}
		f.Category = c
	}
	return withLedger(true, func(l *ledger.Ledger, ctx context.Context) (*polyquery.Result, error) { return l.List(ctx, f) }), nil
}

func prepareBudget(inv *invocation) (commandFunc, error) {
	if _, ok := inv.opts["--month"]; !ok {
		return nil, usagef("budget needs --month YYYY-MM")
	}
	f, err := inv.filter()
	if err != nil {
		return nil, err
	}
	return func(ctx context.Context, a *app) (int, error) {
		l, err := a.open(ctx, true, true)
		if err != nil {
			return 0, err
		}
		defer l.Close()
		if err := l.ResolveCategories(ctx); err != nil {
			return 0, err
		}
		res, err := l.Budget(ctx, f)
		if err != nil {
			return 0, err
		}
		status := exitOK
		for _, row := range res.Rows {
			if row[len(row)-1] == "over" {
				status = exitOverBudget
			}
		}
		return status, a.print(res)
	}, nil
}

func prepareImport(inv *invocation) (commandFunc, error) {
	account, ok := inv.opts["--account"]
	if !ok {
		return nil, usagef("import needs --account NAME")
	}
	if !config.ValidName(account) {
		return nil, usagef("invalid account name %q (expected [a-z0-9_-]{1,32})", account)
	}
	file := inv.args[0]
	return func(ctx context.Context, a *app) (int, error) {
		im, err := a.cfg.ImportFor(account)
		if err != nil {
			return 0, err
		}
		l, err := a.open(ctx, false, false)
		if err != nil {
			return 0, err
		}
		defer l.Close()
		txs, err := bank.ReadFile(file, file, im)
		if err != nil {
			return 0, err
		}
		res, err := l.Import(ctx, account, filepath.Base(file), txs)
		if err != nil {
			return 0, err
		}
		_, err = fmt.Fprintf(a.out, "batch %d: imported %d, duplicates %d\n", res.Batch, res.Imported, res.Duplicates)
		return exitOK, err
	}, nil
}

func prepareSetCategory(inv *invocation) (commandFunc, error) {
	idText := inv.args[0]
	id, err := strconv.ParseInt(idText, 10, 64)
	if err != nil {
		// A positive integer too large for INT64 cannot be a known id.
		if ne, ok := err.(*strconv.NumError); !ok || ne.Err != strconv.ErrRange || idText[0] == '-' || idText[0] == '+' {
			return nil, usagef("invalid transaction id %q", idText)
		}
		id = -1
	} else if id < 1 || idText[0] == '+' {
		return nil, usagef("invalid transaction id %q", idText)
	}
	_, clear := inv.opts["--clear"]
	category := ""
	switch {
	case clear && len(inv.args) == 2:
		return nil, usagef("set-category takes a CATEGORY or --clear, not both")
	case !clear && len(inv.args) == 1:
		return nil, usagef("set-category needs a CATEGORY or --clear")
	case !clear:
		category = inv.args[1]
		if !config.ValidCategory(category) {
			return nil, usagef("invalid category name %q (expected [a-z0-9_-]{1,32}, not uncategorized)", category)
		}
	}
	return func(ctx context.Context, a *app) (int, error) {
		l, err := a.open(ctx, false, false)
		if err != nil {
			return 0, err
		}
		defer l.Close()
		if id < 0 {
			return 0, &ledger.StateError{Msg: fmt.Sprintf("unknown transaction id %s", idText)}
		}
		if err := l.SetCategory(ctx, id, category); err != nil {
			return 0, err
		}
		if clear {
			_, err = fmt.Fprintf(a.out, "transaction %d: category cleared\n", id)
		} else {
			_, err = fmt.Fprintf(a.out, "transaction %d: category %s\n", id, category)
		}
		return exitOK, err
	}, nil
}

func prepareQuery(inv *invocation) commandFunc {
	sql := inv.args[0]
	return func(ctx context.Context, a *app) (int, error) {
		l, err := a.open(ctx, true, false)
		if err != nil {
			return 0, err
		}
		defer l.Close()
		if err := l.ResolveCategories(ctx); err != nil {
			return 0, err
		}
		res, err := l.Query(ctx, sql)
		if err != nil {
			if polyquery.ErrorCode(err) != "" {
				return 0, &queryError{err}
			}
			return 0, err
		}
		return exitOK, a.print(res)
	}
}
