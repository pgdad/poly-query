package cli

import (
	"fmt"
	"strconv"
	"strings"

	"polyquery"
	"polyquery/app/internal/config"
	"polyquery/app/internal/ledger"
)

// usageError is a command-line error (exit 1).
type usageError struct{ msg string }

func (e *usageError) Error() string { return e.msg + " (see pqledger help)" }

func usagef(format string, args ...any) error {
	return &usageError{msg: fmt.Sprintf(format, args...)}
}

// invocation is a parsed command line.
type invocation struct {
	config  string // --config ("" if absent)
	format  string // --format ("" if absent)
	command string // e.g. "import", "report monthly"
	args    []string
	opts    map[string]string // options given; flags map to ""
}

// option kinds of a command.
const (
	value = iota // the option takes the next argument as its value
	flag         // the option takes no value
)

// command describes a command's arguments.
type command struct {
	minArgs, maxArgs int
	options          map[string]int
}

var filterOptions = map[string]int{"--month": value, "--from": value, "--to": value, "--account": value}

func withFilters(extra map[string]int) map[string]int {
	m := map[string]int{}
	for k, v := range filterOptions {
		m[k] = v
	}
	for k, v := range extra {
		m[k] = v
	}
	return m
}

var commands = map[string]command{
	"init":              {},
	"import":            {minArgs: 1, maxArgs: 1, options: map[string]int{"--account": value}},
	"report monthly":    {options: filterOptions},
	"report categories": {options: filterOptions},
	"report merchants":  {options: withFilters(map[string]int{"--top": value})},
	"budget":            {options: map[string]int{"--month": value, "--account": value}},
	"accounts":          {},
	"list":              {options: withFilters(map[string]int{"--category": value, "--uncategorized": flag})},
	"export":            {options: filterOptions},
	"set-category":      {minArgs: 1, maxArgs: 2, options: map[string]int{"--clear": flag}},
	"query":             {minArgs: 1, maxArgs: 1},
	"help":              {},
	"version":           {},
}

// parseArgs parses the command line (without the program name).
func parseArgs(args []string) (*invocation, error) {
	inv := &invocation{opts: map[string]string{}}
	i := 0
	// Global options, only before the command.
	for ; i < len(args) && strings.HasPrefix(args[i], "-"); i++ {
		switch a := args[i]; a {
		case "--help":
			if inv.command != "" {
				return nil, usagef("option --help is repeated")
			}
			inv.command = "help"
		case "--config", "--format":
			if (a == "--config" && inv.config != "") || (a == "--format" && inv.format != "") {
				return nil, usagef("option %s is repeated", a)
			}
			if i+1 >= len(args) {
				return nil, usagef("option %s requires a value", a)
			}
			i++
			v := args[i]
			if a == "--config" {
				if v == "" {
					return nil, usagef("option --config requires a non-empty path")
				}
				inv.config = v
			} else {
				if !config.ValidFormat(v) {
					return nil, usagef("invalid --format %q (expected table, csv or json)", v)
				}
				inv.format = v
			}
		default:
			return nil, usagef("unknown option %q", a)
		}
	}
	if inv.command == "help" {
		if i < len(args) {
			return nil, usagef("unexpected argument %q after --help", args[i])
		}
		return inv, nil
	}
	if i >= len(args) {
		return nil, usagef("missing command")
	}
	inv.command = args[i]
	i++
	if inv.command == "report" {
		if i >= len(args) || strings.HasPrefix(args[i], "--") {
			return nil, usagef("report needs a kind: monthly, categories or merchants")
		}
		inv.command += " " + args[i]
		i++
	}
	spec, ok := commands[inv.command]
	if !ok {
		return nil, usagef("unknown command %q", inv.command)
	}
	for ; i < len(args); i++ {
		a := args[i]
		if !strings.HasPrefix(a, "--") {
			inv.args = append(inv.args, a)
			continue
		}
		kind, ok := spec.options[a]
		if !ok {
			return nil, usagef("unknown option %q for %s", a, inv.command)
		}
		if _, dup := inv.opts[a]; dup {
			return nil, usagef("option %s is repeated", a)
		}
		if kind == flag {
			inv.opts[a] = ""
			continue
		}
		if i+1 >= len(args) {
			return nil, usagef("option %s requires a value", a)
		}
		i++
		inv.opts[a] = args[i]
	}
	switch n := len(inv.args); {
	case n < spec.minArgs:
		return nil, usagef("%s: missing argument", inv.command)
	case n > spec.maxArgs:
		return nil, usagef("%s: unexpected argument %q", inv.command, inv.args[spec.maxArgs])
	}
	return inv, nil
}

// filter builds the common filter options (--month, --from, --to,
// --account).
func (inv *invocation) filter() (ledger.Filter, error) {
	var f ledger.Filter
	month, hasMonth := inv.opts["--month"]
	from, hasFrom := inv.opts["--from"]
	to, hasTo := inv.opts["--to"]
	if hasMonth && (hasFrom || hasTo) {
		return f, usagef("--month cannot be combined with --from or --to")
	}
	if hasMonth {
		from, to, hasFrom, hasTo = month, month, true, true
	}
	if hasFrom {
		y, m, err := parseMonth(from)
		if err != nil {
			return f, err
		}
		f.From, _ = polyquery.DateOf(y, m, 1)
		f.HasFrom = true
	}
	if hasTo {
		y, m, err := parseMonth(to)
		if err != nil {
			return f, err
		}
		f.To = lastDay(y, m)
		f.HasTo = true
	}
	if f.HasFrom && f.HasTo && f.From > f.To {
		return f, usagef("--from %s is later than --to %s", from, to)
	}
	if acc, ok := inv.opts["--account"]; ok {
		if !config.ValidName(acc) {
			return f, usagef("invalid account name %q (expected [a-z0-9_-]{1,32})", acc)
		}
		f.Account = acc
	}
	return f, nil
}

// parseMonth parses YYYY-MM (year 0001–9999, month 01–12).
func parseMonth(s string) (year, month int, err error) {
	bad := usagef("invalid month %q (expected YYYY-MM)", s)
	if len(s) != 7 || s[4] != '-' {
		return 0, 0, bad
	}
	for i, c := range []byte(s) {
		if i != 4 && (c < '0' || c > '9') {
			return 0, 0, bad
		}
	}
	year, _ = strconv.Atoi(s[:4])
	month, _ = strconv.Atoi(s[5:])
	if year < 1 || month < 1 || month > 12 {
		return 0, 0, bad
	}
	return year, month, nil
}

// lastDay returns the last day of a month.
func lastDay(year, month int) polyquery.Date {
	for day := 31; ; day-- {
		if d, ok := polyquery.DateOf(year, month, day); ok {
			return d
		}
	}
}
