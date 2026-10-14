package config

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// DefaultFile is the configuration file used when neither --config nor
// PQLEDGER_CONFIG is given.
const DefaultFile = "pqledger.conf"

// EnvVar names the environment variable that may point to the
// configuration file.
const EnvVar = "PQLEDGER_CONFIG"

// Config is a parsed configuration file. Paths are resolved against the
// file's directory.
type Config struct {
	File       string // the configuration file as located
	DataDir    string
	RulesFile  string // "" if not configured
	BudgetFile string // "" if not configured
	Format     string // table, csv or json
	Threads    int    // 0: engine default
	MemoryMB   int64  // 0: engine default

	imports  map[string]string            // [import] assignments
	accounts map[string]map[string]string // [account NAME] assignments
}

// Locate returns the configuration file to use: flag (--config) if
// non-empty, else $PQLEDGER_CONFIG if non-empty, else ./pqledger.conf.
func Locate(flag string) string {
	if flag != "" {
		return flag
	}
	if env := os.Getenv(EnvVar); env != "" {
		return env
	}
	return DefaultFile
}

// Load reads and validates a configuration file.
func Load(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, &Error{File: path, Msg: "cannot read configuration: " + describe(err)}
	}
	return Parse(path, data)
}

func describe(err error) string {
	if pe, ok := err.(*os.PathError); ok {
		return pe.Err.Error()
	}
	return err.Error()
}

// Parse validates configuration text; path locates the file (its
// directory is the base of relative paths).
func Parse(path string, data []byte) (*Config, error) {
	lines, err := SplitLines(path, data, true)
	if err != nil {
		return nil, err
	}
	c := &Config{File: path, Format: "table", imports: map[string]string{}, accounts: map[string]map[string]string{}}
	base := filepath.Dir(path)
	resolve := func(p string) string {
		if filepath.IsAbs(p) {
			return p
		}
		return filepath.Join(base, p)
	}
	fail := func(l Line, format string, args ...any) error {
		return &Error{File: path, Line: l.No, Msg: fmt.Sprintf(format, args...)}
	}
	seenSections := map[string]bool{}
	section, account := "", ""
	var keys map[string]bool
	for _, l := range lines {
		if l.Key == "" {
			name := l.Section
			switch {
			case name == "ledger" || name == "import" || name == "output" || name == "engine":
				section, account = name, ""
			case strings.HasPrefix(name, "account "):
				account = strings.TrimPrefix(name, "account ")
				if !ValidName(account) {
					return nil, fail(l, "invalid account name %q (expected [a-z0-9_-]{1,32})", account)
				}
				section = "account"
				c.accounts[account] = map[string]string{}
			default:
				return nil, fail(l, "unknown section [%s]", name)
			}
			if seenSections[name] {
				return nil, fail(l, "section [%s] is repeated", name)
			}
			seenSections[name] = true
			keys = map[string]bool{}
			continue
		}
		if section == "" {
			return nil, fail(l, "assignment %q before the first section header", l.Key)
		}
		if keys[l.Key] {
			return nil, fail(l, "key %q is repeated in this section", l.Key)
		}
		keys[l.Key] = true
		v := l.Value
		switch section {
		case "ledger":
			switch l.Key {
			case "data_dir", "rules_file", "budget_file":
				if v == "" {
					return nil, fail(l, "%s must not be empty", l.Key)
				}
				switch l.Key {
				case "data_dir":
					c.DataDir = resolve(v)
				case "rules_file":
					c.RulesFile = resolve(v)
				default:
					c.BudgetFile = resolve(v)
				}
			default:
				return nil, fail(l, "unknown key %q in [ledger]", l.Key)
			}
		case "output":
			if l.Key != "format" {
				return nil, fail(l, "unknown key %q in [output]", l.Key)
			}
			if !ValidFormat(v) {
				return nil, fail(l, "invalid format %q (expected table, csv or json)", v)
			}
			c.Format = v
		case "engine":
			n, ok := positive(v)
			if !ok {
				return nil, fail(l, "%s must be an integer ≥ 1, got %q", l.Key, v)
			}
			switch l.Key {
			case "threads":
				if n > 1024 {
					return nil, fail(l, "threads must be at most 1024")
				}
				c.Threads = int(n)
			case "memory_mb":
				if n > 1<<40 {
					return nil, fail(l, "memory_mb is too large")
				}
				c.MemoryMB = n
			default:
				return nil, fail(l, "unknown key %q in [engine]", l.Key)
			}
		case "import", "account":
			if err := checkImportKey(l.Key, v); err != nil {
				return nil, fail(l, "%s", err)
			}
			if section == "import" {
				c.imports[l.Key] = v
			} else {
				c.accounts[account][l.Key] = v
			}
		}
	}
	if !seenSections["ledger"] {
		return nil, &Error{File: path, Msg: "missing required section [ledger]"}
	}
	if c.DataDir == "" {
		return nil, &Error{File: path, Msg: "missing required key data_dir in [ledger]"}
	}
	// The effective settings of every configured account must be
	// consistent; accounts without a section are checked on import.
	for name := range c.accounts {
		if _, err := c.ImportFor(name); err != nil {
			return nil, err
		}
	}
	return c, nil
}

// ValidFormat reports whether f is an output format.
func ValidFormat(f string) bool { return f == "table" || f == "csv" || f == "json" }

// positive parses a decimal integer ≥ 1.
func positive(s string) (int64, bool) {
	n, ok := nonNegative(s)
	return n, ok && n >= 1
}

// nonNegative parses a decimal integer ≥ 0 (digits only).
func nonNegative(s string) (int64, bool) {
	if s == "" || strings.Trim(s, "0123456789") != "" {
		return 0, false
	}
	n, err := strconv.ParseInt(s, 10, 64)
	return n, err == nil
}
