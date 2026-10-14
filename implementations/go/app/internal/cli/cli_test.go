package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fixture is a temporary directory with a configuration.
type fixture struct {
	t    *testing.T
	dir  string
	conf string
}

func newFixture(t *testing.T, files map[string]string) *fixture {
	t.Helper()
	f := &fixture{t: t, dir: t.TempDir()}
	f.conf = f.path("pqledger.conf")
	base := map[string]string{
		"pqledger.conf": "[ledger]\ndata_dir = books\nrules_file = rules.conf\nbudget_file = budgets.conf\n" +
			"[account card]\ndate_format = MM/DD/YYYY\ncurrency_symbol = $\ninvert_sign = true\n",
		"rules.conf":   "groceries = WHOLE FOODS*, SAFEWAY\ncoffee = STARBUCKS*\ntransport = UBER*\n",
		"budgets.conf": "groceries = 100\ncoffee = 10.00\n",
	}
	for k, v := range files {
		base[k] = v
	}
	for name, text := range base {
		if err := os.WriteFile(f.path(name), []byte(text), 0o666); err != nil {
			t.Fatal(err)
		}
	}
	return f
}

func (f *fixture) path(name string) string { return filepath.Join(f.dir, name) }

// run runs pqledger with the fixture's configuration.
func (f *fixture) run(args ...string) (status int, stdout, stderr string) {
	var out, errOut strings.Builder
	status = Main(append([]string{"--config", f.conf}, args...), &out, &errOut)
	return status, out.String(), errOut.String()
}

// expect runs a command and checks its status and (if non-empty) stdout.
func (f *fixture) expect(status int, stdout string, args ...string) string {
	f.t.Helper()
	got, out, errOut := f.run(args...)
	if got != status {
		f.t.Fatalf("%v: status %d, want %d (stderr %q)", args, got, status, errOut)
	}
	if stdout != "" && out != stdout {
		f.t.Fatalf("%v: stdout\n%s\nwant\n%s", args, out, stdout)
	}
	if status != 0 && status != 3 {
		if out != "" || !strings.HasPrefix(errOut, "pqledger: error: ") {
			f.t.Fatalf("%v: failure output: stdout %q, stderr %q", args, out, errOut)
		}
	}
	return out
}

const checking = "Date,Description,Amount\n" +
	"2026-01-02,Whole Foods Market #12,-50.00\n" +
	"2026-01-03,Starbucks 1234,-4.50\n" +
	"2026-01-03,Starbucks 1234,-4.50\n" +
	"2026-01-15,Payroll,1000.00\n" +
	"2026-02-01,Uber trip,-12.25\n"

func TestLedgerWorkflow(t *testing.T) {
	f := newFixture(t, map[string]string{
		"chk.csv":  checking,
		"chk2.csv": "Date,Description,Amount\n2026-01-03,STARBUCKS  1234,-4.50\n2026-01-03,Starbucks 1234,-4.50\n2026-01-03,Starbucks 1234,-4.50\n2026-02-02,Safeway,-30.00\n",
		"card.csv": "Date,Description,Amount\n01/05/2026,Corner Shop,$7.10\n01/06/2026,Corner Shop,($2.00)\n",
	})
	f.expect(exitState, "", "accounts")
	f.expect(exitOK, "initialized ledger\n", "init")
	f.expect(exitState, "", "init")
	f.expect(exitOK, "batch 1: imported 5, duplicates 0\n", "import", f.path("chk.csv"), "--account", "checking")
	f.expect(exitOK, "batch 2: imported 2, duplicates 2\n", "import", f.path("chk2.csv"), "--account", "checking")
	f.expect(exitOK, "batch 3: imported 2, duplicates 0\n", "--format", "csv", "import", f.path("card.csv"), "--account", "card")

	f.expect(exitOK, "account,transactions,balance,first,last\n"+
		"card,2,-5.10,2026-01-05,2026-01-06\n"+
		"checking,7,894.25,2026-01-02,2026-02-02\n", "--format", "csv", "accounts")
	f.expect(exitOK, "month,income,expenses,net,transactions\n"+
		"2026-01,1002.00,70.60,931.40,7\n"+
		"2026-02,0.00,42.25,-42.25,2\n", "--format", "csv", "report", "monthly")
	f.expect(exitOK, "category,spent,share,transactions\n"+
		"groceries,50.00,70.8,1\ncoffee,13.50,19.1,3\nuncategorized,7.10,10.1,1\n",
		"--format", "csv", "report", "categories", "--to", "2026-01")
	f.expect(exitOK, "merchant,spent,transactions\nWHOLE FOODS MARKET,50.00,1\n",
		"--format", "csv", "report", "merchants", "--top", "1")
	f.expect(exitOverBudget, "category,budget,spent,remaining,status\n"+
		"coffee,10.00,13.50,-3.50,over\ngroceries,100.00,50.00,50.00,ok\n",
		"--format", "csv", "budget", "--month", "2026-01")
	f.expect(exitOK, "", "budget", "--month", "2026-01", "--account", "card")

	f.expect(exitOK, "transaction 9: category shopping\n", "set-category", "9", "shopping")
	f.expect(exitOK, "id,date,account,description,amount,category\n"+
		"8,2026-01-05,card,Corner Shop,-7.10,uncategorized\n"+
		"4,2026-01-15,checking,Payroll,1000.00,uncategorized\n",
		"--format", "csv", "list", "--uncategorized")
	f.expect(exitOK, `{"id":9,"date":"2026-01-06","account":"card","description":"Corner Shop","amount":"2.00","category":"shopping"}`+"\n",
		"--format", "json", "list", "--category", "shopping")
	f.expect(exitOK, "transaction 9: category cleared\n", "set-category", "9", "--clear")
	f.expect(exitState, "", "set-category", "99", "gifts")

	out := f.expect(exitOK, "", "--format", "csv", "export", "--account", "checking", "--month", "2026-02")
	if out != "id,account,date,description,merchant,amount,category,batch\n"+
		"5,checking,2026-02-01,Uber trip,UBER TRIP,-12.25,transport,1\n"+
		"7,checking,2026-02-02,Safeway,SAFEWAY,-30.00,groceries,2\n" {
		t.Errorf("export:\n%s", out)
	}
	f.expect(exitOK, "n\n9\n", "--format", "csv", "query", "SELECT COUNT(*) AS n FROM ledger")
	f.expect(exitOK, "rule_no,category,pattern\n2,groceries,SAFEWAY\n",
		"--format", "csv", "query", "SELECT * FROM rules WHERE rule_no = 2")
	f.expect(exitQuery, "", "query", "SELEC 1")

	// Changing the rules recategorizes past transactions.
	if err := os.WriteFile(f.path("rules.conf"), []byte("shops = CORNER SHOP\n"), 0o666); err != nil {
		t.Fatal(err)
	}
	f.expect(exitOK, "category,n\nshops,2\nuncategorized,7\n",
		"--format", "csv", "query", "SELECT category, COUNT(*) AS n FROM ledger GROUP BY category ORDER BY category")
}

func TestImportErrorLeavesLedgerUnchanged(t *testing.T) {
	f := newFixture(t, map[string]string{
		"good.csv": "Date,Description,Amount\n2026-01-05,Lunch,-12.00\n",
		"bad.csv":  "Date,Description,Amount\n2026-01-06,Dinner,-30.00\n2026-02-30,Dinner,-30.00\n",
	})
	f.expect(exitOK, "", "init")
	f.expect(exitOK, "", "import", f.path("good.csv"), "--account", "a")
	before, err := os.ReadFile(f.path("books/transactions.pqcf"))
	if err != nil {
		t.Fatal(err)
	}
	_, _, stderr := f.run("import", f.path("bad.csv"), "--account", "a")
	if !strings.Contains(stderr, "bad.csv:3:") {
		t.Errorf("stderr = %q", stderr)
	}
	f.expect(exitImport, "", "import", f.path("bad.csv"), "--account", "a")
	f.expect(exitImport, "", "import", f.path("missing.csv"), "--account", "a")
	after, _ := os.ReadFile(f.path("books/transactions.pqcf"))
	if string(before) != string(after) {
		t.Errorf("failed import changed the ledger")
	}
	f.expect(exitOK, "batch 2: imported 0, duplicates 1\n", "import", f.path("good.csv"), "--account", "a")
}

func TestUsageAndConfigErrors(t *testing.T) {
	f := newFixture(t, map[string]string{"bad-rules.conf": "x = A_B\n"})
	f.expect(exitOK, "", "init")
	for _, args := range [][]string{
		{"frobnicate"}, {"report"}, {"report", "weekly"}, {"report", "monthly", "--month", "2026-01", "--from", "2026-01"},
		{"report", "monthly", "--month", "2026-13"}, {"report", "monthly", "--from", "2026-03", "--to", "2026-02"},
		{"report", "monthly", "--bogus"}, {"import", "x.csv"}, {"import", "x.csv", "--account", "Bad Name"},
		{"set-category", "1", "Groceries"}, {"set-category", "1", "uncategorized"}, {"set-category", "0", "x"},
		{"set-category", "1", "x", "--clear"}, {"set-category", "1"}, {"report", "merchants", "--top", "0"},
		{"--format", "xml", "accounts"}, {"accounts", "extra"}, {"budget"}, {"budget", "--month", "2026-01", "--from", "2026-01"},
		{"report", "monthly", "--month", "2026-01", "--month", "2026-02"}, {"list", "--category", "a", "--uncategorized"},
		{"report", "monthly", "--month"}, {"query"}, {"query", "a", "b"},
	} {
		f.expect(exitUsage, "", args...)
	}
	var out, errOut strings.Builder
	if status := Main([]string{"--config", f.path("nope.conf"), "init"}, &out, &errOut); status != exitConfig {
		t.Errorf("missing config: %d", status)
	}
	if err := os.WriteFile(f.conf, []byte("[ledger]\ndata_dir = books\nrules_file = bad-rules.conf\n"), 0o666); err != nil {
		t.Fatal(err)
	}
	f.expect(exitConfig, "", "accounts")
	f.expect(exitConfig, "", "budget", "--month", "2026-01")
	for _, args := range [][]string{{"help"}, {"--help"}, {"version"}} {
		var out, errOut strings.Builder
		if status := Main(args, &out, &errOut); status != exitOK || out.Len() == 0 {
			t.Errorf("%v: status %d", args, status)
		}
	}
}
