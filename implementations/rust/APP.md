# pqledger — user guide

`pqledger` is a personal-finance ledger for the command line. It imports the
CSV statements your banks let you download, recognizes transactions it has
already seen, assigns categories with simple rules, and prints monthly,
category and merchant reports and budget checks. You can also query the ledger
with SQL.

The ledger is a directory of three PQCF files (the PolyQuery columnar format).
All queries run inside `pqledger` itself, on the PolyQuery engine embedded as a
library: no server or other process is started and no network connection is
opened.

Specification: [`spec/apps/pqledger.md`](../../spec/apps/pqledger.md).

* [Building and installing](#building-and-installing)
* [Quick start](#quick-start)
* [The configuration file](#the-configuration-file)
* [The rules file](#the-rules-file)
* [The budget file](#the-budget-file)
* [Commands](#commands)
* [Output formats](#output-formats)
* [Exit status and messages](#exit-status-and-messages)
* [The ledger files](#the-ledger-files)
* [Troubleshooting](#troubleshooting)

## Building and installing

You need Rust 1.96 or newer with Cargo. No network access is needed: the
program uses only the Rust standard library.

```bash
cd implementations/rust
make build          # builds the engine, the library, pqledger and the example
make test           # unit tests of the engine, the library and pqledger
```

The executable is `target/release/pqledger`; `bin/pqledger` is a launcher that
finds it from any working directory. To install it, either put
`implementations/rust/bin` on your `PATH`, symlink the launcher
(`ln -s "$PWD/bin/pqledger" ~/.local/bin/pqledger`), or copy the binary
(`install -m 755 target/release/pqledger ~/.local/bin/`). The binary is
self-contained.

## Quick start

```bash
mkdir ~/money && cd ~/money
cat > pqledger.conf <<'EOF'
[ledger]
data_dir = ledger
rules_file = rules.conf
budget_file = budgets.conf
EOF
cat > rules.conf <<'EOF'
groceries = WHOLE FOODS*, TRADER JOE*, SAFEWAY
coffee = STARBUCKS*, SQ *BLUE BOTTLE*
housing = RENT*
EOF
echo "groceries = 600" > budgets.conf

pqledger init
pqledger import ~/Downloads/checking-2026-01.csv --account checking
pqledger report monthly
```

Run `pqledger` from the directory that holds `pqledger.conf`, or name the file
with `--config` or the `PQLEDGER_CONFIG` environment variable.

## The configuration file

### Where it is looked for

The first that applies is used:

1. `--config PATH` (before the command: `pqledger --config ~/money/pqledger.conf accounts`);
2. the environment variable `PQLEDGER_CONFIG`, if set and not empty;
3. `pqledger.conf` in the current directory.

If that file does not exist or cannot be read, the command fails with exit
status 2. Relative paths *inside* the file (`data_dir`, `rules_file`,
`budget_file`) are relative to the directory of the configuration file;
relative paths given with `--config` or `PQLEDGER_CONFIG` are relative to the
current directory. `help` and `version` need no configuration.

### Syntax

UTF-8 text; `\n` or `\r\n` line ends; a leading byte-order mark is ignored.
Leading and trailing spaces and tabs of every line are ignored. A line is

* empty;
* a comment: it starts with `#` or `;`;
* a section header `[NAME]`: `[ledger]`, `[import]`, `[output]`, `[engine]` or
  `[account NAME]` (exactly one space before the account name);
* an assignment `KEY = VALUE`. The key is the text before the first `=`, the
  value the text after it, both trimmed. To keep leading or trailing spaces,
  or to write an empty value, put the value in double quotes; inside the
  quotes `\"` is a quote and `\\` a backslash. There are no comments at the
  end of a line: `delimiter = ; # x` sets the delimiter to `; # x`, which is
  invalid.

It is an error (exit 2, the message names the line) to have an assignment
before the first section, an unknown section or key, a key twice in one
section, a section header twice, or an invalid value.

**Names.** An account name is 1–32 characters from `a-z`, `0-9`, `_` and `-`
(lower case only). A category name follows the same rule and must not be
`uncategorized`.

### `[ledger]` — required

| key | value | default |
|---|---|---|
| `data_dir` | directory of the ledger (created by `init`) | required |
| `rules_file` | the [rules file](#the-rules-file) | no rules: everything is `uncategorized` |
| `budget_file` | the [budget file](#the-budget-file) | none: `budget` fails with exit 2 |

### `[import]` and `[account NAME]` — how bank files are read

`[import]` sets the defaults for all accounts; an `[account NAME]` section
overrides any of the keys for one account. The effective value for an account
is its `[account NAME]` value, else the `[import]` value, else the default
below. Accounts need no section of their own.

| key | value | default |
|---|---|---|
| `delimiter` | one ASCII character, or `tab` | `,` |
| `header` | `true` or `false`: the first record holds the column names | `true` |
| `skip_lines` | number of physical lines before the first record (a preamble) | `0` |
| `date_column` | column reference | `Date` |
| `date_format` | `YYYY-MM-DD`, `YYYYMMDD`, `MM/DD/YYYY`, `DD/MM/YYYY` or `DD.MM.YYYY` | `YYYY-MM-DD` |
| `description_column` | column reference | `Description` |
| `amount_mode` | `signed` (one amount column) or `debit_credit` (two columns) | `signed` |
| `amount_column` | column reference (`signed`) | `Amount` |
| `debit_column`, `credit_column` | column references (`debit_credit`) | `Debit`, `Credit` |
| `decimal_separator` | `.` or `,` | `.` |
| `thousands_separator` | `none`, `,`, `.`, `space` or `'` | `none` |
| `currency_symbol` | text removed from the start or end of amounts, e.g. `$`, `EUR` | empty |
| `invert_sign` | `true` or `false`: negate every amount | `false` |

* A **column reference** is a 1-based column number (`3`) or a header name,
  compared ignoring ASCII case and surrounding blanks. Names need `header = true`.
* In `MM/DD/YYYY`, `DD/MM/YYYY` and `DD.MM.YYYY` the month and day may have one
  or two digits; the year always has four.
* The decimal and thousands separators must differ.
* Amounts are negative for money going out. Use `invert_sign = true` for
  exports that show charges as positive numbers (typical for credit cards).
  In `debit_credit` mode the amount is credit − debit; one of the two may be
  empty.

### `[output]`

| key | value | default |
|---|---|---|
| `format` | `table`, `csv` or `json` ([output formats](#output-formats)) | `table` |

The global option `--format` overrides it.

### `[engine]`

| key | value | default |
|---|---|---|
| `threads` | worker threads per query (integer ≥ 1) | the engine's default (CPUs, at most 16) |
| `memory_mb` | memory limit per query in MiB (integer ≥ 1) | 4096 |

### Complete example

```ini
# ~/money/pqledger.conf
[ledger]
data_dir = ledger
rules_file = rules.conf
budget_file = budgets.conf

[import]
# defaults for all accounts (these are the built-in defaults anyway)
date_column = Date
description_column = Description
amount_column = Amount

[output]
format = table

[engine]
threads = 4
memory_mb = 1024

# US credit card: "Transaction Date","Description","Amount" with "$1,234.56",
# refunds in parentheses, charges positive
[account card]
date_column = Transaction Date
date_format = MM/DD/YYYY
currency_symbol = $
thousands_separator = ,
invert_sign = true

# German current account: ';' separated, two preamble lines,
# Buchungstag;Verwendungszweck;Soll;Haben with "1.120,00", CRLF lines
[account giro]
delimiter = ;
skip_lines = 2
date_column = Buchungstag
date_format = DD.MM.YYYY
description_column = Verwendungszweck
amount_mode = debit_credit
debit_column = Soll
credit_column = Haben
decimal_separator = ,
thousands_separator = .

# an export without a header line: date;text;amount
[account savings]
delimiter = ;
header = false
date_column = 1
description_column = 2
amount_column = 3
```

## The rules file

Rules assign categories by the **merchant**: the transaction's description,
normalized (ASCII letters upper-cased, runs of blanks collapsed, a trailing
store number such as `#10234` or `4421` removed; `Whole Foods Market #10234`
becomes `WHOLE FOODS MARKET`). `pqledger export` shows the merchant of every
transaction.

Same line syntax as the configuration file, without sections:

```ini
# CATEGORY = PATTERN, PATTERN, ...   (first match wins)
groceries = WHOLE FOODS*, TRADER JOE*, SAFEWAY, REWE*, LIDL*
coffee    = SQ *BLUE BOTTLE*, STARBUCKS*, CAFé*
transport = SHELL*, CHEVRON*, UBER*, LYFT*, ARAL*
housing   = RENT*, MIETE*
income    = PAYROLL*, GEHALT*
shopping  = AMAZON*, HOME DEPOT, REI
groceries = ALDI*
```

* A pattern must match the **whole** merchant. `*` matches any characters
  (also none), `?` exactly one character; everything else matches itself,
  ignoring ASCII case. Patterns must not be empty or contain `%` or `_`.
* The category of a transaction is its override (`set-category`) if it has
  one; else the category of the first matching pattern, in file order (line
  by line, left to right); else `uncategorized`.
* A category may appear on several lines.
* Rules are read by every command, so editing the file re-categorizes all
  past transactions. A missing or invalid rules file is an error (exit 2) for
  every command except `init`, `help` and `version`.

## The budget file

One monthly budget per category:

```ini
groceries = 600
coffee = 30.00
transport = 200
shopping = 150.5
```

Amounts are `digits` with optionally 1–2 decimals (at most 16 integer digits),
no sign. A category listed twice is an error. The file is read by `budget` and
`query` only.

## Commands

```
pqledger [--config PATH] [--format table|csv|json] [--help] COMMAND [ARGUMENTS]
```

Global options come before the command. Options of a command come after it,
in any order among its arguments, and always take their value as the next
argument (`--month 2026-09`; `--month=2026-09` is not supported). Repeating
an option, an unknown option or command, a missing or malformed value or an
extra argument is a usage error (exit 1).

**Filters** (where a command lists `[FILTERS]`):

| option | meaning |
|---|---|
| `--month YYYY-MM` | only that month |
| `--from YYYY-MM`, `--to YYYY-MM` | inclusive range of months; either may be given alone |
| `--account NAME` | only that account |

`--month` cannot be combined with `--from`/`--to`, and `--from` must not be
later than `--to`.

The examples below use the configuration above and three sample statements.

### `init`

Creates `data_dir` (with missing parents) and an empty ledger. Fails with
exit 6 if a ledger already exists there.

```
$ pqledger init
initialized ledger
```

### `import FILE --account NAME`

Imports a bank CSV file (path relative to the current directory) into an
account, using the account's `[import]` settings. Prints the batch number, the
number of new transactions and the number of duplicates.

```
$ pqledger import checking-2026-01.csv --account checking
batch 1: imported 24, duplicates 0
$ pqledger import card.csv --account card
batch 2: imported 17, duplicates 0
$ pqledger import giro.csv --account giro
batch 3: imported 22, duplicates 0
$ pqledger import checking-2026-01.csv --account checking
batch 4: imported 0, duplicates 24
```

**Duplicates.** Statements overlap, so importing must not count a transaction
twice. Transactions are compared by account, date, amount and merchant. If a
file contains `f` transactions with the same values and the ledger already
has `l` of them, the last `f − l` of the file are imported (none if `l ≥ f`).
So two identical coffees on one day are both kept, and re-importing the same
statement adds nothing.

If any record cannot be read (bad date, bad amount, wrong number of fields,
missing column, …), **nothing** is imported and the message names the file
and line:

```
$ pqledger import bad.csv --account checking
pqledger: error: bad.csv:3: invalid date '2026-02-30'
```

Amount fields are read like this: blanks trimmed; `(…)` or a leading `-`
means negative, a leading `+` is dropped; the `currency_symbol` is removed from
the start or end; thousands separators are removed; the decimal separator
becomes `.`; the result must be `digits[.d[d]]` with at most 16 integer digits;
finally `invert_sign` applies.

### `report monthly [FILTERS]`

Income (sum of positive amounts), expenses (spending, as a positive number),
net and number of transactions per month.

```
$ pqledger report monthly
month     income  expenses      net  transactions
-------  -------  --------  -------  ------------
2026-01  8175.76   4623.57  3552.19            32
2026-02  8120.33   4562.07  3558.26            31
(2 rows)
```

### `report categories [FILTERS]`

Spending (negative amounts only) per category, largest first, with each
category's share of the total in percent (exact, rounded half away from zero to
one decimal).

```
$ pqledger report categories --month 2026-02
category         spent  share  transactions
-------------  -------  -----  ------------
housing        2970.00   65.1             2
shopping        560.45   12.3             4
utilities       436.95    9.6             6
groceries       350.33    7.7             4
transport       167.07    3.7             5
uncategorized    39.84    0.9             4
coffee           37.43    0.8             3
(7 rows)
```

### `report merchants [FILTERS] [--top N]`

The `N` merchants (default 10) you spent most at.

```
$ pqledger report merchants --top 3
merchant                spent  transactions
--------------------  -------  ------------
RENT - OAKWOOD APTS   3700.00             2
MIETE HAUSVERWALTUNG  2240.00             2
REI                    672.01             5
(3 rows)
```

### `budget --month YYYY-MM [--account NAME]`

Compares the month's spending per category with the budget file. The exit
status is **3** if any category is over budget (the table is printed either
way), else 0. Needs `budget_file` (exit 2 without).

```
$ pqledger budget --month 2026-01
category   budget   spent  remaining  status
---------  ------  ------  ---------  ------
coffee      30.00   27.55       2.45  ok
groceries  600.00  477.52     122.48  ok
shopping   150.50  406.64    -256.14  over
transport  200.00  498.59    -298.59  over
(4 rows)
$ echo $?
3
```

### `accounts`

Number of transactions, balance (sum of amounts) and first and last date per
account.

```
$ pqledger accounts
account   transactions   balance  first       last
--------  ------------  --------  ----------  ----------
card                17  -1021.83  2026-01-03  2026-02-26
checking            24   3572.29  2026-01-01  2026-02-27
giro                22   4559.99  2026-01-01  2026-02-26
(3 rows)
```

### `list [FILTERS] [--category C | --uncategorized]`

Transactions ordered by date (then id), with their category.

```
$ pqledger list --account card --month 2026-02 --category shopping
id  date        account  description   amount  category
--  ----------  -------  -----------  -------  --------
37  2026-02-18  card     REI #540     -137.18  shopping
40  2026-02-24  card     REI #2426     -31.23  shopping
(2 rows)
```

`--uncategorized` lists the transactions no rule matches — useful when
writing rules.

### `export [FILTERS]`

All columns, ordered by id: `id`, `account`, `date`, `description`,
`merchant`, `amount`, `category`, `batch`. Combine with `--format csv` to get a
spreadsheet-friendly file.

```
$ pqledger --format csv export --to 2026-01 --account card
id,account,date,description,merchant,amount,category,batch
25,card,2026-01-03,UBER   *TRIP Q5WS6F,UBER *TRIP Q5WS6F,-31.06,transport,2
26,card,2026-01-05,UBER   *TRIP Q5WS6F,UBER *TRIP Q5WS6F,31.06,transport,2
27,card,2026-01-06,Home Depot #3203,HOME DEPOT,-248.23,shopping,2
...
```

### `set-category ID CATEGORY` and `set-category ID --clear`

Overrides the category of one transaction (the `id` shown by `list`), or
removes the override. Overrides win over rules. An unknown id is exit 6; an
invalid category name exit 1.

```
$ pqledger set-category 41 gifts
transaction 41: category gifts
$ pqledger set-category 41 --clear
transaction 41: category cleared
```

### `query SQL`

Runs one SQL statement ([PolyQuery SQL](../../spec/sql/grammar.md)) on these
tables:

| table | columns |
|---|---|
| `transactions` | `id`, `account`, `date`, `description`, `merchant`, `amount`, `batch` |
| `batches` | `batch`, `account`, `file`, `imported`, `duplicates` |
| `overrides` | `id`, `category` |
| `ledger` | the `transactions` columns, then `category` (resolved) |
| `rules` | `rule_no` (1, 2, … in file order, one per pattern), `category`, `pattern` (upper-cased) |
| `budgets` | `category`, `amount` |

Nothing the statement does is saved. Note that `date`, `first` and `last` are
SQL keywords: write `"date"`. An SQL error is exit 5 with the engine's error
code.

```
$ pqledger query "SELECT category, COUNT(*) AS n, SUM(amount) AS total FROM ledger WHERE account = 'giro' GROUP BY category ORDER BY total"
category       n     total
-------------  -  --------
housing        2  -2240.00
utilities      8   -401.60
transport      6   -261.21
groceries      3   -152.92
uncategorized  1     -5.38
income         2   7621.10
(6 rows)
$ pqledger query "SELEC 1"
pqledger: error: PARSE_ERROR: expected SELECT, found identifier 'SELEC'
```

### `help`, `--help`, `version`

`help` (or `--help`) prints a command summary; `version` prints
`pqledger 0.1.0 (polyquery-rust engine, embedded)`.

## Output formats

Choose with `--format` or `[output] format`.

**`table`** (default): a header line, a line of dashes, one line per row, and
`(N rows)` (`(1 row)`). Columns are as wide as their longest value (counted in
characters) and separated by two spaces; numbers are right-aligned.

**`csv`**: a header line and one line per row, comma-separated. Fields that
are empty strings, contain `,`, `"` or a line break, or start or end with a
space are quoted (`"` doubled inside). Missing values (NULL) are empty and
unquoted.

**`json`**: one JSON object per row and line (JSON Lines), nothing for zero
rows. Amounts and dates are strings (exact), counts are numbers:

```
$ pqledger --format json report monthly --account giro
{"month":"2026-01","income":"3894.70","expenses":"1579.48","net":"2315.22","transactions":11}
{"month":"2026-02","income":"3870.33","expenses":"1625.56","net":"2244.77","transactions":11}
```

Value text in all formats: amounts with exactly two decimals (`-12.50`), dates
`YYYY-MM-DD`, booleans `true`/`false`, floating-point results (e.g. `AVG` in a
query) with six decimals.

## Exit status and messages

| status | meaning |
|---|---|
| 0 | success |
| 1 | usage error (command line) |
| 2 | configuration error (configuration, rules or budget file) |
| 3 | `budget`: some category is over budget |
| 4 | import data error (file missing, unreadable or invalid) |
| 5 | `query`: the SQL statement failed |
| 6 | ledger state: no ledger, ledger already exists, unknown transaction id |
| 7 | any other error (I/O, unexpected engine errors) |

On an error, nothing is printed to standard output, and the message on
standard error starts with `pqledger: error: `. A failing command never
changes the ledger.

## The ledger files

`data_dir` contains `transactions.pqcf`, `batches.pqcf` and `overrides.pqcf`
(columns as in the `query` table above; amounts `DECIMAL(18,2)`, ids and batch
numbers `INT64`, dates `DATE`). They are standard PQCF files: any PolyQuery
implementation can open them, and `pqledger` reads ledgers written by other
implementations. Ids are 1, 2, 3, … in import order and never reused.
Categories are not stored (only overrides are); they are computed on every
command from the rules.

To back up the ledger, copy the directory. `import` writes the new files under
temporary names and renames them into place, so an interrupted import leaves
the old ledger intact. Do not run two commands that change the same ledger
(`import`, `set-category`) at the same time.

## Troubleshooting

| message | cause and remedy |
|---|---|
| `cannot read configuration file 'pqledger.conf'` (exit 2) | No configuration found. Run in the directory with `pqledger.conf`, or use `--config PATH` or `PQLEDGER_CONFIG`. |
| `…: line N: unknown key 'x' in [ledger]` (exit 2) | Typo in a key or section name; keys are case-sensitive and lower-case. |
| `no ledger in '…' (run 'pqledger init' first)` (exit 6) | `data_dir` has no `transactions.pqcf`. Check `data_dir` (relative to the configuration file) or run `init`. |
| `FILE:1: the header has no column 'Date'` (exit 4) | The file's column names differ from the settings. Set `date_column` etc. in an `[account NAME]` section, or use column numbers. Check `skip_lines` if the file has a preamble, and `delimiter`. |
| `FILE:N: invalid amount '1.234,56'` (exit 4) | Set `decimal_separator`, `thousands_separator` and `currency_symbol` for the account. |
| `FILE:N: invalid date '…'` (exit 4) | Set `date_format` for the account. |
| `FILE:N: 4 fields, expected 3` (exit 4) | A record has a different number of fields than the header: check `delimiter` and quoting. |
| Everything is `uncategorized` | No `rules_file`, or patterns do not match the **merchant**: patterns must match the whole merchant (add `*`). Look at the `merchant` column of `export` and at `list --uncategorized`. |
| Spending shows up as income | The bank exports charges as positive numbers: set `invert_sign = true` for the account. |
| `budget requires budget_file in [ledger]` (exit 2) | Add `budget_file` to `[ledger]`. |
| `PARSE_ERROR` in `query` near `date` | `date`, `first`, `last` are SQL keywords: write `"date"`. |
| `engine error: RESOURCE_LIMIT: …` (exit 7) | A query needed more memory than allowed: raise `[engine] memory_mb`. |
