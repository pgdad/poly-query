package bank

import (
	"strings"
	"testing"

	"polyquery/app/internal/config"
)

func settings(t *testing.T, conf string) config.Import {
	t.Helper()
	c, err := config.Parse("pqledger.conf", []byte("[ledger]\ndata_dir = l\n[account a]\n"+conf))
	if err != nil {
		t.Fatal(err)
	}
	im, err := c.ImportFor("a")
	if err != nil {
		t.Fatal(err)
	}
	return im
}

func TestMerchant(t *testing.T) {
	cases := map[string]string{
		"Whole Foods Market #10234": "WHOLE FOODS MARKET",
		"SQ *Blue  Bottle 4421":     "SQ *BLUE BOTTLE",
		"Rent 2026":                 "RENT",
		"7-Eleven 12":               "7-ELEVEN 12",
		"#123":                      "#123",
		"Café\tMélange  #9":         "CAFé MéLANGE",
		"Shop 12 345":               "SHOP 12",
		"REI #":                     "REI #",
		"":                          "",
		"  a  ":                     "A",
		"Line\nbreak":               "LINE\nBREAK",
	}
	for in, want := range cases {
		if got := Merchant(in); got != want {
			t.Errorf("Merchant(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestParseAmount(t *testing.T) {
	us := settings(t, "currency_symbol = $\nthousands_separator = ,\n")
	de := settings(t, "decimal_separator = ,\nthousands_separator = .\ncurrency_symbol = EUR\n")
	cases := []struct {
		im   config.Import
		in   string
		want int64
	}{
		{us, "$1,234.56", 123456}, {us, "($31.06)", -3106}, {us, "-$5", -500}, {us, "+7.5", 750},
		{us, " 12 ", 1200}, {us, "-0.00", 0}, {us, "9999999999999999.99", 999999999999999999},
		{de, "1.120,00", 112000}, {de, "3,5 EUR", 350}, {de, "-EUR 2,00", -200},
	}
	for _, c := range cases {
		got, err := ParseAmount(c.in, c.im)
		if err != nil || got != c.want {
			t.Errorf("ParseAmount(%q) = %d, %v; want %d", c.in, got, err, c.want)
		}
	}
	for _, bad := range []string{"", "12.345", "1,000", "abc", "1.", ".5", "--1", "12345678901234567", "$-5"} {
		if _, err := ParseAmount(bad, us); err == nil && bad != "1,000" {
			t.Errorf("ParseAmount(%q) accepted", bad)
		}
	}
	if _, err := ParseAmount("1,000", settings(t, "")); err == nil {
		t.Errorf("thousands separator accepted without configuration")
	}
}

func TestParseDate(t *testing.T) {
	cases := []struct{ in, format, want string }{
		{"2026-01-05", "YYYY-MM-DD", "2026-01-05"},
		{"20260105", "YYYYMMDD", "2026-01-05"},
		{"1/5/2026", "MM/DD/YYYY", "2026-01-05"},
		{"05/01/2026", "DD/MM/YYYY", "2026-01-05"},
		{"5.1.2026", "DD.MM.YYYY", "2026-01-05"},
		{"29.02.2024", "DD.MM.YYYY", "2024-02-29"},
	}
	for _, c := range cases {
		d, ok := ParseDate(c.in, c.format)
		if !ok || d.String() != c.want {
			t.Errorf("ParseDate(%q, %s) = %v, %v", c.in, c.format, d, ok)
		}
	}
	for _, bad := range [][2]string{{"2026-1-05", "YYYY-MM-DD"}, {"2026-02-30", "YYYY-MM-DD"}, {"0000-01-01", "YYYY-MM-DD"},
		{"1/5/26", "MM/DD/YYYY"}, {"13/01/2026", "MM/DD/YYYY"}, {"001.01.2026", "DD.MM.YYYY"}, {"2026010", "YYYYMMDD"}} {
		if _, ok := ParseDate(bad[0], bad[1]); ok {
			t.Errorf("ParseDate(%q, %s) accepted", bad[0], bad[1])
		}
	}
}

func TestParseGiro(t *testing.T) {
	im := settings(t, "delimiter = ;\nskip_lines = 2\ndate_column = Buchungstag\ndate_format = DD.MM.YYYY\n"+
		"description_column = Verwendungszweck\namount_mode = debit_credit\ndebit_column = Soll\ncredit_column = Haben\n"+
		"decimal_separator = ,\nthousands_separator = .\n")
	text := "\xEF\xBB\xBFKontoumsätze;;;\r\nZeitraum;;;\r\nbuchungstag ;Verwendungszweck;Soll;Haben\r\n" +
		"01.01.2026;Miete;1.120,00;\r\n\r\n15.01.2026;\"Gehalt\r\nACME\";;3.810,55\r\n"
	txs, err := Parse("giro.csv", []byte(text), im)
	if err != nil {
		t.Fatal(err)
	}
	if len(txs) != 2 || txs[0].Amount != -112000 || txs[1].Amount != 381055 || txs[1].Line != 6 || txs[1].Description != "Gehalt\r\nACME" {
		t.Errorf("txs = %+v", txs)
	}
}

func TestErrorsNameFileAndLine(t *testing.T) {
	im := settings(t, "")
	cases := map[string]string{
		"Date,Description,Amount\n2026-01-05,Lunch,-12.00\n2026-02-30,Dinner,-30.00\n":                        "f.csv:3:",
		"Date,Description,Amount\n2026-01-05,Lunch,-12.005\n":                                                 "f.csv:2:",
		"Date,Description,Amount\n2026-01-05,Lunch,-12.00\n\n\"2026-01-06\",\"Multi\nline\",-1.00\n1,2,3,4\n": "f.csv:6:",
		"Date,Description,Amount\n2026-01-05,\"open,-1\n":                                                     "f.csv:2:",
		"Day,Description,Amount\n2026-01-05,Lunch,-12.00\n":                                                   "f.csv:1:",
		"Date,Description,Amount\n2026-01-05,\"a\"b,1\n":                                                      "f.csv:2:",
	}
	for text, want := range cases {
		_, err := Parse("f.csv", []byte(text), im)
		if err == nil || !strings.HasPrefix(err.Error(), want) {
			t.Errorf("%q: err = %v, want prefix %s", text, err, want)
		}
	}
	both := settings(t, "amount_mode = debit_credit\n")
	if _, err := Parse("f.csv", []byte("Date,Description,Debit,Credit\n2026-01-05,x,,\n"), both); err == nil {
		t.Errorf("empty debit and credit accepted")
	}
	pos := settings(t, "header = false\ndate_column = 1\ndescription_column = 2\namount_column = 4\n")
	if _, err := Parse("f.csv", []byte("2026-01-05,x,1\n"), pos); err == nil {
		t.Errorf("column beyond the record accepted")
	}
}

func TestHeaderlessAndInvert(t *testing.T) {
	im := settings(t, "header = false\ndate_column = 3\ndescription_column = 1\namount_column = 2\ninvert_sign = true\ndate_format = YYYYMMDD\n")
	txs, err := Parse("f.csv", []byte("Coffee,4.50,20260102\nRefund,-0.00,20260103\n"), im)
	if err != nil {
		t.Fatal(err)
	}
	if len(txs) != 2 || txs[0].Amount != -450 || txs[1].Amount != 0 || txs[0].Line != 1 {
		t.Errorf("txs = %+v", txs)
	}
}

func TestQuoteErrorsNameTheRecordStart(t *testing.T) {
	im := settings(t, "")
	for _, text := range []string{
		"Date,Description,Amount\n2026-01-05,\"Multi\nline\",-1.00\n2026-01-06,\"a\nb\"x,1\n",
		"Date,Description,Amount\n2026-01-05,\"Multi\nline\",-1.00\n2026-01-06,\"a\nb\",1,\"x\ny\n",
	} {
		if _, err := Parse("a.csv", []byte(text), im); err == nil || !strings.HasPrefix(err.Error(), "a.csv:4:") {
			t.Errorf("%q: err = %v, want a.csv:4:", text, err)
		}
	}
}
