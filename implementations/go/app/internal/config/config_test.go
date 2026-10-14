package config

import (
	"path/filepath"
	"strings"
	"testing"
)

func parse(t *testing.T, text string) (*Config, error) {
	t.Helper()
	return Parse(filepath.Join("conf", "pqledger.conf"), []byte(text))
}

func TestParseExample(t *testing.T) {
	c, err := parse(t, "\xEF\xBB\xBF; comment\r\n[ledger]\r\ndata_dir = ledger\nrules_file = \"r s.conf\"\n"+
		"[import]\ndate_column = 2\n[account visa]\ndate_format = MM/DD/YYYY\ninvert_sign = true\n"+
		"[account giro]\ndelimiter = tab\ndecimal_separator = ,\nthousands_separator = space\namount_mode = debit_credit\n"+
		"[output]\nformat = json\n[engine]\nthreads = 4\nmemory_mb = 512\n")
	if err != nil {
		t.Fatal(err)
	}
	if c.DataDir != filepath.Join("conf", "ledger") || c.RulesFile != filepath.Join("conf", "r s.conf") || c.BudgetFile != "" {
		t.Errorf("paths: %q %q %q", c.DataDir, c.RulesFile, c.BudgetFile)
	}
	if c.Format != "json" || c.Threads != 4 || c.MemoryMB != 512 {
		t.Errorf("output/engine: %+v", c)
	}
	visa, err := c.ImportFor("visa")
	if err != nil || !visa.InvertSign || visa.DateFormat != "MM/DD/YYYY" || visa.DateColumn.Pos != 2 || visa.Delimiter != ',' {
		t.Errorf("visa = %+v, %v", visa, err)
	}
	giro, err := c.ImportFor("giro")
	if err != nil || giro.Delimiter != '\t' || giro.DecimalSeparator != ',' || giro.ThousandsSeparator != " " || giro.AmountMode != DebitCredit {
		t.Errorf("giro = %+v, %v", giro, err)
	}
	other, err := c.ImportFor("other")
	if err != nil || other.DateColumn.Pos != 2 || other.DescriptionColumn.Name != "Description" || !other.Header {
		t.Errorf("other = %+v, %v", other, err)
	}
}

func TestQuotedValues(t *testing.T) {
	c, err := parse(t, "[ledger]\ndata_dir = l\n[import]\ncurrency_symbol = \" \\\"EUR\\\\ \"\n")
	if err != nil {
		t.Fatal(err)
	}
	im, _ := c.ImportFor("x")
	if im.CurrencySymbol != ` "EUR\ ` {
		t.Errorf("currency = %q", im.CurrencySymbol)
	}
}

func TestErrors(t *testing.T) {
	cases := map[string]string{
		"unknown key":      "[ledger]\ndata_dir = l\ncolour = blue\n",
		"repeated key":     "[ledger]\ndata_dir = l\ndata_dir = m\n",
		"before section":   "data_dir = l\n[ledger]\ndata_dir = l\n",
		"no data_dir":      "[ledger]\nrules_file = r\n",
		"no ledger":        "[output]\nformat = csv\n",
		"bad format":       "[ledger]\ndata_dir = l\n[output]\nformat = xml\n",
		"bad header":       "[ledger]\ndata_dir = l\n[import]\nheader = yes\n",
		"unknown section":  "[ledger]\ndata_dir = l\n[accounts]\n",
		"same separators":  "[ledger]\ndata_dir = l\n[account eu]\ndecimal_separator = ,\nthousands_separator = ,\n",
		"repeated section": "[ledger]\ndata_dir = l\n[ledger]\n",
		"bad account":      "[ledger]\ndata_dir = l\n[account Visa]\n",
		"two spaces":       "[ledger]\ndata_dir = l\n[account  visa]\n",
		"no equals":        "[ledger]\ndata_dir\n",
		"bad threads":      "[ledger]\ndata_dir = l\n[engine]\nthreads = 0\n",
		"bad delimiter":    "[ledger]\ndata_dir = l\n[import]\ndelimiter = ;;\n",
		"name sans header": "[ledger]\ndata_dir = l\n[account a]\nheader = false\ndate_column = 1\n",
		"bad date format":  "[ledger]\ndata_dir = l\n[import]\ndate_format = YY-MM-DD\n",
		"bad utf8":         "[ledger]\ndata_dir = \xff\n",
	}
	for name, text := range cases {
		_, err := parse(t, text)
		if err == nil || !IsConfigError(err) {
			t.Errorf("%s: err = %v", name, err)
		}
	}
	_, err := parse(t, "[ledger]\ndata_dir = l\nbogus = 1\n")
	if err == nil || !strings.Contains(err.Error(), ":3:") {
		t.Errorf("error does not name the line: %v", err)
	}
}

func TestSeparatorCheckedForAccountsWithoutSection(t *testing.T) {
	c, err := parse(t, "[ledger]\ndata_dir = l\n[import]\ndecimal_separator = ,\nthousands_separator = ,\n[account a]\nthousands_separator = .\n")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.ImportFor("a"); err != nil {
		t.Errorf("a: %v", err)
	}
	if _, err := c.ImportFor("b"); err == nil {
		t.Errorf("b: same separators accepted")
	}
}

func TestValidNames(t *testing.T) {
	for _, ok := range []string{"a", "visa-2", "my_acct", strings.Repeat("x", 32)} {
		if !ValidName(ok) {
			t.Errorf("%q rejected", ok)
		}
	}
	for _, bad := range []string{"", "Visa", "a b", strings.Repeat("x", 33), "é"} {
		if ValidName(bad) {
			t.Errorf("%q accepted", bad)
		}
	}
	if ValidCategory("uncategorized") || !ValidCategory("gifts") {
		t.Errorf("ValidCategory")
	}
}
