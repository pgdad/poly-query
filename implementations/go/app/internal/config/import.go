package config

import (
	"errors"
	"fmt"
)

// Date formats of the date_format key.
var dateFormats = map[string]bool{
	"YYYY-MM-DD": true, "YYYYMMDD": true, "MM/DD/YYYY": true, "DD/MM/YYYY": true, "DD.MM.YYYY": true,
}

// Amount modes.
const (
	Signed      = "signed"
	DebitCredit = "debit_credit"
)

// ColumnRef refers to a column of a bank CSV file: a 1-based position, or
// otherwise a header name.
type ColumnRef struct {
	Pos  int    // > 0: 1-based column position
	Name string // header name (Pos == 0)
}

func (r ColumnRef) String() string {
	if r.Pos > 0 {
		return fmt.Sprintf("column %d", r.Pos)
	}
	return fmt.Sprintf("column %q", r.Name)
}

func parseColumnRef(v string) ColumnRef {
	if n, ok := positive(v); ok && n <= 1<<20 {
		return ColumnRef{Pos: int(n)}
	}
	return ColumnRef{Name: v}
}

// Import holds the effective [import] settings of one account.
type Import struct {
	Delimiter          byte
	Header             bool
	SkipLines          int
	DateColumn         ColumnRef
	DateFormat         string
	DescriptionColumn  ColumnRef
	AmountMode         string // Signed or DebitCredit
	AmountColumn       ColumnRef
	DebitColumn        ColumnRef
	CreditColumn       ColumnRef
	DecimalSeparator   byte
	ThousandsSeparator string // "" for none, else one character
	CurrencySymbol     string
	InvertSign         bool
}

// importDefaults are the documented defaults of the [import] keys.
var importDefaults = map[string]string{
	"delimiter":           ",",
	"header":              "true",
	"skip_lines":          "0",
	"date_column":         "Date",
	"date_format":         "YYYY-MM-DD",
	"description_column":  "Description",
	"amount_mode":         Signed,
	"amount_column":       "Amount",
	"debit_column":        "Debit",
	"credit_column":       "Credit",
	"decimal_separator":   ".",
	"thousands_separator": "none",
	"currency_symbol":     "",
	"invert_sign":         "false",
}

// checkImportKey validates one [import] / [account NAME] assignment.
func checkImportKey(key, v string) error {
	if _, ok := importDefaults[key]; !ok {
		return fmt.Errorf("unknown key %q", key)
	}
	switch key {
	case "delimiter":
		if v != "tab" && (len(v) != 1 || v[0] >= 0x80 || v[0] == '"' || v[0] == '\r' || v[0] == '\n') {
			return fmt.Errorf("delimiter must be one ASCII character or tab, got %q", v)
		}
	case "header", "invert_sign":
		if v != "true" && v != "false" {
			return fmt.Errorf("%s must be true or false, got %q", key, v)
		}
	case "skip_lines":
		if _, ok := nonNegative(v); !ok {
			return fmt.Errorf("skip_lines must be an integer ≥ 0, got %q", v)
		}
	case "date_format":
		if !dateFormats[v] {
			return fmt.Errorf("unknown date_format %q", v)
		}
	case "amount_mode":
		if v != Signed && v != DebitCredit {
			return fmt.Errorf("amount_mode must be signed or debit_credit, got %q", v)
		}
	case "decimal_separator":
		if v != "." && v != "," {
			return fmt.Errorf("decimal_separator must be . or ,, got %q", v)
		}
	case "thousands_separator":
		switch v {
		case "none", ",", ".", "space", "'":
		default:
			return fmt.Errorf("thousands_separator must be none, ',', '.', space or ', got %q", v)
		}
	case "date_column", "description_column", "amount_column", "debit_column", "credit_column":
		if v == "" {
			return fmt.Errorf("%s must not be empty", key)
		}
	}
	return nil
}

// ImportFor returns the effective import settings of an account: its
// [account NAME] value, else the [import] value, else the default.
func (c *Config) ImportFor(account string) (Import, error) {
	get := func(key string) string {
		if v, ok := c.accounts[account][key]; ok {
			return v
		}
		if v, ok := c.imports[key]; ok {
			return v
		}
		return importDefaults[key]
	}
	im := Import{
		Header:            get("header") == "true",
		DateColumn:        parseColumnRef(get("date_column")),
		DateFormat:        get("date_format"),
		DescriptionColumn: parseColumnRef(get("description_column")),
		AmountMode:        get("amount_mode"),
		AmountColumn:      parseColumnRef(get("amount_column")),
		DebitColumn:       parseColumnRef(get("debit_column")),
		CreditColumn:      parseColumnRef(get("credit_column")),
		DecimalSeparator:  get("decimal_separator")[0],
		CurrencySymbol:    get("currency_symbol"),
		InvertSign:        get("invert_sign") == "true",
	}
	if d := get("delimiter"); d == "tab" {
		im.Delimiter = '\t'
	} else {
		im.Delimiter = d[0]
	}
	n, _ := nonNegative(get("skip_lines"))
	im.SkipLines = int(min(n, 1<<31))
	switch t := get("thousands_separator"); t {
	case "none":
	case "space":
		im.ThousandsSeparator = " "
	default:
		im.ThousandsSeparator = t
	}
	section := "[import]"
	if _, ok := c.accounts[account]; ok {
		section = "[account " + account + "]"
	}
	fail := func(msg string) error {
		return &Error{File: c.File, Msg: section + ": " + msg}
	}
	if im.ThousandsSeparator == string(im.DecimalSeparator) {
		return im, fail("decimal_separator and thousands_separator must differ")
	}
	if !im.Header {
		for _, r := range im.Columns() {
			if r.Pos == 0 {
				return im, fail(fmt.Sprintf("%s is a header name but header = false", r))
			}
		}
	}
	return im, nil
}

// Columns returns the column references the settings use.
func (im Import) Columns() []ColumnRef {
	refs := []ColumnRef{im.DateColumn, im.DescriptionColumn}
	if im.AmountMode == DebitCredit {
		return append(refs, im.DebitColumn, im.CreditColumn)
	}
	return append(refs, im.AmountColumn)
}

// IsConfigError reports whether err is a configuration error.
func IsConfigError(err error) bool {
	var ce *Error
	return errors.As(err, &ce)
}
