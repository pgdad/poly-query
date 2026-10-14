# pqledger — user guide

`pqledger` is a personal-finance command-line application. It imports the CSV
statement exports of your bank accounts and cards into a **ledger**, detects
transactions that were already imported, assigns categories with simple
pattern rules, and prints monthly reports, category and merchant breakdowns
and budget checks. You can also run your own SQL on the ledger.

It is built on the PolyQuery engine of this directory, which it uses
**in-process as a library** ([EMBEDDING.md](EMBEDDING.md)). It never starts
another process and never opens a network connection. The ledger is stored as
PQCF files, so any other PolyQuery implementation can read it.

The behaviour is specified in `spec/apps/pqledger.md` (application spec 1.0.0).

Contents: [Build and install](#build-and-install) ·
[Quick start](#quick-start) · [Configuration](#configuration) ·
[Rules file](#rules-file) · [Budget file](#budget-file) ·
[Commands](#commands) · [Output formats](#output-formats) ·
[The ledger files](#the-ledger-files) · [Exit codes](#exit-codes) ·
[Troubleshooting](#troubleshooting)

## Build and install

You need a JDK (tested with OpenJDK 27; `JAVA_HOME` set, or `java` on
`PATH`), the Clojure CLI (`clojure`, tools.deps) with Clojure 1.12.3 in the
local Maven cache, and GNU make. No other libraries are needed.

```sh
cd implementations/clojure
make build        # engine, library jar, pqledger, pq-embed-demo (~20 s)
make test         # unit tests of the engine, the API and pqledger
bin/pqledger version
```

`make build` produces:

| file | contents |
|---|---|
| `target/polyquery.jar` | the engine and its embedding API (AOT-compiled) |
| `target/pqledger.jar` | pqledger's own classes (`app/`) |
| `target/pqledger.aot` | an optional JVM ahead-of-time cache that makes start-up fast |
| `target/classpath` | the Clojure jar(s) the launchers add to the class path |

**Installing.** `bin/pqledger` is a small shell script that finds the jars
relative to its own location, so it works from any working directory. Put it
on your `PATH` with a symbolic link, e.g.

```sh
ln -s "$PWD/bin/pqledger" ~/.local/bin/pqledger
```

Keep the `implementations/clojure` directory in place (the launcher runs the
jars in its `target/`). Rebuild with `make build` after updating the source.

Environment variables of the launcher:

| variable | meaning |
|---|---|
| `JAVA_HOME` | JDK to use (default: `java` on `PATH`) |
| `PQLEDGER_JAVA_OPTS` | extra JVM options, e.g. `-Xmx8g` for a very large ledger |
| `PQLEDGER_CONFIG` | configuration file (see [Locating the file](#locating-the-file)) |

## Quick start

```sh
mkdir ~/finance && cd ~/finance
cat > pqledger.conf <<'EOF'
[ledger]
data_dir = ledger
rules_file = rules.conf
budget_file = budgets.conf

[account checking]
EOF
echo 'groceries = WHOLE FOODS*, TRADER JOE*' > rules.conf
echo 'groceries = 400'                        > budgets.conf

pqledger init
pqledger import ~/Downloads/checking-2026-09.csv --account checking
pqledger report monthly
pqledger budget --month 2026-09
```

## Configuration

### Locating the file

The first of these that applies is used:

1. the global option `--config PATH`;
2. the environment variable `PQLEDGER_CONFIG`, if set and non-empty;
3. `pqledger.conf` in the current directory.

If the chosen file does not exist or cannot be read, pqledger stops with a
configuration error (exit 2). A relative `--config`/`PQLEDGER_CONFIG` path is
resolved against the current directory; relative paths **inside** the file
(`data_dir`, `rules_file`, `budget_file`) against the directory of the
configuration file. So a configuration file can sit next to its ledger and
be used from anywhere.

### Syntax

UTF-8 text with `\n` or `\r\n` line ends; a leading byte-order mark is
ignored. Each line, after removing leading and trailing spaces and tabs, is:

* empty;
* a comment: the first character is `#` or `;` (there are **no** inline
  comments — `format = csv # x` sets the value `csv # x`, which is invalid);
* a section header `[ledger]`, `[import]`, `[output]`, `[engine]` or
  `[account NAME]` (exactly one space before the account name);
* an assignment `KEY = VALUE`. The key is the text before the first `=`, the
  value the text after it, both trimmed. A value enclosed in double quotes
  (`"…"`) has the quotes removed, and inside them `\"` stands for `"` and
  `\\` for `\`. Quote a value to keep leading/trailing spaces or to make it
  empty: `currency_symbol = " EUR"`.

These are configuration errors (exit 2), reported with the file name and line
number: an assignment before the first section, an unknown section or key, a
key repeated within a section, a repeated section header, an invalid value, a
missing `[ledger]` section or `data_dir`.

### `[ledger]` (required)

| key | value | default |
|---|---|---|
| `data_dir` | directory of the ledger files; **required** | — |
| `rules_file` | the [rules file](#rules-file) | none: every transaction is `uncategorized` |
| `budget_file` | the [budget file](#budget-file) | none (`budget` then fails with exit 2) |

### `[import]` and `[account NAME]`

`[import]` says how bank CSV files are read. Each `[account NAME]` section
may override any of these keys for one account: the effective value for an
account is its `[account NAME]` value, else the `[import]` value, else the
default. An account needs no section if the `[import]` settings fit its
export. Account names match `[a-z0-9_-]{1,32}`.

| key | value | default |
|---|---|---|
| `delimiter` | one ASCII character, or `tab` | `,` |
| `header` | `true` \| `false` — is the first record a header? | `true` |
| `skip_lines` | integer ≥ 0: physical lines skipped before the first record (a preamble) | `0` |
| `date_column` | column reference | `Date` |
| `date_format` | `YYYY-MM-DD`, `YYYYMMDD`, `MM/DD/YYYY`, `DD/MM/YYYY` or `DD.MM.YYYY` | `YYYY-MM-DD` |
| `description_column` | column reference | `Description` |
| `amount_mode` | `signed` (one amount column) \| `debit_credit` (two columns) | `signed` |
| `amount_column` | column reference (`signed`) | `Amount` |
| `debit_column`, `credit_column` | column references (`debit_credit`) | `Debit`, `Credit` |
| `decimal_separator` | `.` \| `,` | `.` |
| `thousands_separator` | `none`, `,`, `.`, `space` or `'` | `none` |
| `currency_symbol` | text removed from the start or end of amounts | empty |
| `invert_sign` | `true` \| `false`: negate every amount (card exports listing charges as positive) | `false` |

A **column reference** is a 1-based column position (`3`) or a header name,
compared with the trimmed header fields ASCII case-insensitively (`amount`
matches `Amount`). Names require `header = true`. The decimal and thousands
separators must differ.

In the `MM/DD/YYYY`, `DD/MM/YYYY` and `DD.MM.YYYY` formats the month and day
may have one or two digits (`9/1/2026`). Dates must be valid calendar dates.

**How an amount is read.** Spaces and tabs around it are removed; `(12.50)`
is negative (accounting style), a leading `-` makes it negative and a leading
`+` is dropped; the `currency_symbol` is removed if the text starts or ends
with it; every thousands separator is removed; the decimal separator becomes
`.`. What is left must be digits with at most two decimals and at most 16
integer digits (`1234`, `1234.5`, `1234.56`). With `debit_credit` the amount
is credit − debit; one of the two fields may be empty (counts as 0), not
both. Finally `invert_sign` negates it. Negative amounts are money going
out, positive amounts money coming in.

### `[output]`

| key | value | default |
|---|---|---|
| `format` | `table` \| `csv` \| `json` ([Output formats](#output-formats)); the global option `--format` overrides it | `table` |

### `[engine]`

| key | value | default |
|---|---|---|
| `threads` | integer ≥ 1: worker threads of each query | the engine's default (min(8, processors)) |
| `memory_mb` | integer ≥ 1: per-query memory limit in MiB | the engine's default (4096) |

### Complete example

The bank formats below are those of `datasets/generators/bankgen.py`
(`--print-config` prints the account keys of each style).

```ini
# ~/finance/pqledger.conf
[ledger]
data_dir = ledger
rules_file = rules.conf
budget_file = budgets.conf

[import]
# the defaults, written out
date_column = Date
description_column = Description
amount_column = Amount

[output]
format = table

[engine]
threads = 4
memory_mb = 1024

# Date,Description,Amount  /  2026-08-02,"Comcast Cable",-78.72
[account checking]

# "Transaction Date","Description","Amount"  /  08/02/2026,"Café Mélange","$21.48"
# charges are positive, refunds in parentheses: ($12.00)
[account visa]
date_column = Transaction Date
date_format = MM/DD/YYYY
currency_symbol = $
thousands_separator = ,
invert_sign = true

# two preamble lines, then
# Buchungstag;Verwendungszweck;Soll;Haben  /  01.09.2026;Miete Hausverwaltung;1.120,00;
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

# an export without a header: date, text, amount in columns 1, 3 and 4
[account savings]
header = false
date_column = 1
date_format = YYYYMMDD
description_column = 3
amount_column = 4
```

## Rules file

Assigns categories to transactions by their **merchant** (the normalized
description, see [import](#pqledger-import-file---account-name)). Same line
syntax as the configuration, without sections:

```ini
# CATEGORY = PATTERN [, PATTERN ...]
groceries = WHOLE FOODS*, TRADER JOE*, EDEKA*, LIDL*, REWE*
rent      = RENT *, MIETE*
dining    = SQ *, *COFFEE*, *PIZZA*
utilities = PACIFIC GAS*, *ELECTRIC*, COMCAST*
income    = PAYROLL*, *GEHALT*
# a category may appear on several lines
groceries = SAFEWAY
```

* A category name matches `[a-z0-9_-]{1,32}` and is not `uncategorized`.
* In a pattern `*` matches any sequence of characters (also none), `?`
  exactly one character, and every other character itself, ASCII
  case-insensitively. A pattern must match the **whole** merchant:
  `WHOLE FOODS` does not match `WHOLE FOODS MARKET`, `WHOLE FOODS*` does.
* Patterns are trimmed, must not be empty and must not contain `%` or `_`.
* **Resolution:** a transaction's category is its override
  ([set-category](#pqledger-set-category-id-category--set-category-id---clear))
  if there is one; else the category of the first matching pattern in file
  order (line by line, left to right); else `uncategorized`.
* Rules are read on every command (except `init`, `help`, `version`) and are
  not stored in the ledger: editing the file recategorizes all past
  transactions.

A missing or invalid rules file is a configuration error (exit 2).

## Budget file

Monthly budgets per category, used by `budget` (and available to `query` as
table `budgets`):

```ini
# CATEGORY = monthly amount
groceries = 400
dining = 150.00
utilities = 200
```

Amounts match `[0-9]+(\.[0-9]{1,2})?` with at most 16 integer digits. A
category listed twice, an invalid line or a missing file is a configuration
error (exit 2).

## Commands

```
pqledger [--config PATH] [--format table|csv|json] [--help] COMMAND [ARGS]
```

Global options come before the command. A command's options follow it, in
any order among its arguments; every option takes its value as the next
argument (`--month 2026-09`; `--month=2026-09` is not accepted). Repeating
an option, an unknown command or option, a missing or malformed value or a
surplus argument is a usage error (exit 1).

**Filters** accepted by `report …`, `list` and `export`:

| option | meaning |
|---|---|
| `--month YYYY-MM` | only transactions of that month |
| `--from YYYY-MM`, `--to YYYY-MM` | inclusive month range; either may be given alone |
| `--account NAME` | only that account |

`--month` cannot be combined with `--from`/`--to`, and `--from` must not be
later than `--to`. Months are `0001-01` … `9999-12`.

The examples below use the [complete example configuration](#complete-example)
and the rules and budgets above with two months of generated statements.

### `pqledger init`

Creates `data_dir` (and missing parents) with an empty ledger.

```
$ pqledger init
initialized ledger
```

If the ledger already exists: exit 6, nothing is changed.

### `pqledger import FILE --account NAME`

Reads a statement export (path relative to the current directory) with the
account's settings and appends the new transactions.

```
$ pqledger import checking-2026-09.csv --account checking
batch 1: imported 21, duplicates 0
$ pqledger import visa-2026-09.csv --account visa
batch 2: imported 13, duplicates 0
$ pqledger import giro-2026-09.csv --account giro
batch 3: imported 8, duplicates 0
$ pqledger import checking-2026-09.csv --account checking
batch 4: imported 0, duplicates 21
```

* **Descriptions** are stored trimmed. Each also gets a **merchant**:
  ASCII letters upper-cased, runs of spaces/tabs collapsed to one space,
  and a trailing store number removed — a last word that is `#` plus digits
  or 3+ digits (`Whole Foods Market #10234` → `WHOLE FOODS MARKET`,
  `SQ *Blue  Bottle 4421` → `SQ *BLUE BOTTLE`; `7-Eleven 12` stays
  `7-ELEVEN 12`).
* **Duplicates.** Statements overlap, so you can import every export you
  download. Records are compared by (account, date, amount, merchant): if a
  key occurs `f` times in the file and `l` times in the ledger, the last
  `max(0, f − l)` of those records are imported and the rest are counted as
  duplicates. Two genuinely identical purchases on one day are therefore
  kept, and importing the same file twice adds nothing.
* New transactions get the ids following the largest id; every import gets
  a new batch number, even if it imports nothing.
* **All or nothing:** if any record is invalid (bad date or amount, wrong
  number of fields, …) nothing is imported and pqledger exits with 4,
  naming the file and the line:

  ```
  $ pqledger import bad.csv --account checking
  pqledger: error: bad.csv:2: invalid amount 'abc'
  ```

  A missing or unreadable file, a file that is not UTF-8, a header without a
  configured column or a column position beyond the record is also exit 4.

### `pqledger accounts`

One row per account with transactions: count, balance (sum of amounts),
first and last date.

```
$ pqledger accounts
account   transactions  balance  first       last
--------  ------------  -------  ----------  ----------
checking            21  3771.38  2026-08-01  2026-09-30
giro                 8  2440.42  2026-09-01  2026-09-30
visa                13  -598.14  2026-08-02  2026-09-28
(3 rows)
```

### `pqledger report monthly [filters]`

Income (sum of positive amounts), expenses (money out, as a positive
number), net and transaction count per month.

```
$ pqledger report monthly
month     income  expenses      net  transactions
-------  -------  --------  -------  ------------
2026-08  4381.48   2951.71  1429.77            17
2026-09  8208.51   4024.62  4183.89            25
(2 rows)
```

### `pqledger report categories [filters]`

Spending (outflows only) per resolved category, largest first, with its
share of the total in percent (rounded half away from zero, computed
exactly).

```
$ pqledger report categories --month 2026-09
category         spent  share  transactions
-------------  -------  -----  ------------
rent           2970.00   73.8             2
uncategorized   669.72   16.6            14
utilities       332.03    8.2             3
groceries        42.39    1.1             1
dining           10.48    0.3             1
(5 rows)
```

### `pqledger report merchants [filters] [--top N]`

Spending per merchant, largest first; the first `N` rows (default 10).

```
$ pqledger report merchants --top 5
merchant                  spent  transactions
----------------------  -------  ------------
RENT - OAKWOOD APTS     3700.00             2
MIETE HAUSVERWALTUNG    1120.00             1
PACIFIC GAS & ELECTRIC   373.62             3
HOME DEPOT               363.56             1
COMCAST CABLE            242.44             3
(5 rows)
```

### `pqledger budget --month M [--account NAME]`

Compares each budget category's spending in month `M` with its budget.
Requires `budget_file`. The exit status is **3** when any category is over
budget (the table is printed in full either way), so scripts can react.

```
$ pqledger budget --month 2026-09
category   budget   spent  remaining  status
---------  ------  ------  ---------  ------
dining     150.00   10.48     139.52  ok
groceries  400.00   42.39     357.61  ok
utilities  200.00  332.03    -132.03  over
(3 rows)
$ echo $?
3
```

### `pqledger list [filters] [--category C | --uncategorized]`

Transactions ordered by date, then id, with their resolved category.
`--uncategorized` is the same as `--category uncategorized` — useful to find
transactions that still need a rule.

```
$ pqledger list --month 2026-09 --account giro
id  date        account  description                 amount  category
--  ----------  -------  ------------------------  --------  -------------
35  2026-09-01  giro     Miete Hausverwaltung      -1120.00  rent
36  2026-09-04  giro     DB Vertrieb GmbH            -58.07  uncategorized
37  2026-09-05  giro     Stadtwerke München         -118.51  uncategorized
38  2026-09-06  giro     DB Vertrieb GmbH             58.07  uncategorized
39  2026-09-14  giro     Lidl Dienstleistung 6803    -42.39  groceries
40  2026-09-15  giro     Gehalt ACME GmbH           3810.55  income
41  2026-09-23  giro     Telekom Deutschland         -34.89  uncategorized
42  2026-09-30  giro     DB Vertrieb GmbH            -54.34  uncategorized
(8 rows)
```

### `pqledger export [filters]`

All columns (including merchant, category and batch), ordered by id — for
spreadsheets (`--format csv`) or other programs (`--format json`).

```
$ pqledger export --month 2026-08 --account visa
id  account  date        description                      merchant                          amount  category       batch
--  -------  ----------  -------------------------------  -------------------------------  -------  -------------  -----
22  visa     2026-08-02  Café Mélange                     CAFé MéLANGE                      -21.48  uncategorized      2
23  visa     2026-08-07  AMAZON.COM*7F8BJ9 AMZN.COM/BILL  AMAZON.COM*7F8BJ9 AMZN.COM/BILL   -85.54  uncategorized      2
24  visa     2026-08-18  Comcast Cable                    COMCAST CABLE                     -73.83  utilities          2
25  visa     2026-08-20  Spotify USA                      SPOTIFY USA                       -11.94  uncategorized      2
26  visa     2026-08-20  UBER   *TRIP 7UF73V              UBER *TRIP 7UF73V                 -37.70  uncategorized      2
27  visa     2026-08-24  Pacific Gas & Electric           PACIFIC GAS & ELECTRIC           -131.48  utilities          2
28  visa     2026-08-26  Pacific Gas & Electric           PACIFIC GAS & ELECTRIC            131.48  utilities          2
(7 rows)
```

(Only ASCII letters are upper-cased in merchants, hence `CAFé MéLANGE`.)

### `pqledger set-category ID CATEGORY` / `set-category ID --clear`

Sets a manual category (an override) for one transaction, which wins over
the rules; `--clear` removes it again (also fine if there is none).

```
$ pqledger set-category 3 utilities
transaction 3: category utilities
$ pqledger set-category 3 --clear
transaction 3: category cleared
```

An unknown id is exit 6; an invalid category name exit 1.

### `pqledger query SQL`

Runs one SQL statement (PolyQuery SQL, `spec/sql/`) on the embedded engine
and prints the result with the engine's column names and types. Nothing the
query does is saved. Available tables:

| table | columns |
|---|---|
| `transactions` | `id, account, date, description, merchant, amount, batch` |
| `batches` | `batch, account, file, imported, duplicates` |
| `overrides` | `id, category` |
| `ledger` | the `transactions` columns followed by `category` (resolved) |
| `rules` | `rule_no` (1, 2, … in file order), `category`, `pattern` (upper-cased) |
| `budgets` | `category, amount` (empty without a budget file) |

```
$ pqledger query "SELECT category, COUNT(*) AS n, SUM(amount) AS total FROM ledger GROUP BY category ORDER BY category"
category        n     total
-------------  --  --------
dining          1    -10.48
groceries       2   -184.35
income          3  12310.55
rent            3  -4820.00
uncategorized  25  -1287.37
utilities       8   -394.69
(6 rows)
$ pqledger query "SELEC 1"
pqledger: error: PARSE_ERROR: expected SELECT, found 'SELEC' at line 1, column 1
```

Quote the statement for the shell. `DATE` is an SQL keyword (`DATE
'2026-09-01'`), so the column must be written as a quoted identifier:
`SELECT "date", amount FROM ledger WHERE "date" >= DATE '2026-09-01'`
(`SELECT date …` is a `PARSE_ERROR`). An error reported by the engine exits
with 5 and its error code.

### `pqledger help`, `pqledger version`

`help` (or `--help`) prints the usage summary; `version` prints e.g.
`pqledger 1.0.0 (polyquery-clojure 0.1.0)`. Both exit 0.

## Output formats

Select with `--format` or `[output] format`.

* **`table`** (default): aligned columns, numbers right-aligned, a `(N rows)`
  footer (`(1 row)` for one).
* **`csv`**: a header line and one line per row; fields containing `,`,
  `"`, CR or LF, starting or ending with a space, or empty strings are
  quoted with `"` (and `"` doubled).

  ```
  $ pqledger --format csv report monthly
  month,income,expenses,net,transactions
  2026-08,4381.48,2951.71,1429.77,17
  2026-09,8208.51,4024.62,4183.89,25
  ```

* **`json`**: JSON Lines, one object per row (nothing for zero rows).
  Integers and floats are JSON numbers; decimals, dates and strings are
  JSON strings (so amounts stay exact); NULL is `null`.

  ```
  $ pqledger --format json accounts
  {"account":"checking","transactions":21,"balance":"3771.38","first":"2026-08-01","last":"2026-09-30"}
  {"account":"giro","transactions":8,"balance":"2440.42","first":"2026-09-01","last":"2026-09-30"}
  {"account":"visa","transactions":13,"balance":"-598.14","first":"2026-08-02","last":"2026-09-28"}
  ```

Amounts are printed with exactly two decimals (`-12.50`), dates as
`YYYY-MM-DD`, floats (only possible in `query`) with six decimals.

## The ledger files

The ledger is `data_dir` with three PQCF files — the only authority for its
contents; back up the directory to back up your finances:

| file | columns |
|---|---|
| `transactions.pqcf` | `id INT64, account STRING, date DATE, description STRING, merchant STRING, amount DECIMAL(18,2), batch INT64` |
| `batches.pqcf` | `batch INT64, account STRING, file STRING, imported INT64, duplicates INT64` |
| `overrides.pqcf` | `id INT64, category STRING` |

Every PolyQuery engine can open them (e.g. `bin/polyquery` with the `open`
operation), and a ledger written by another implementation's pqledger works
here. Files are replaced atomically (written to a temporary file and
renamed), so an interrupted command leaves the previous state intact; a
failing command changes nothing.

## Exit codes

| exit | meaning |
|---|---|
| 0 | success |
| 1 | usage error (unknown command or option, bad value, …) |
| 2 | configuration error (configuration, rules or budget file) |
| 3 | `budget`: some category is over budget |
| 4 | import data error |
| 5 | `query`: the engine reported an error |
| 6 | ledger state error: no ledger, ledger already exists, unknown transaction id |
| 7 | any other error (I/O, damaged ledger files, unexpected engine errors) |

With exit 1, 2, 4, 5, 6 and 7 nothing is printed to standard output and the
first line on standard error starts with `pqledger: error: `.

## Troubleshooting

| message / symptom | cause and remedy |
|---|---|
| `pqledger: error: pqledger is not built; run 'make -C … build'` (exit 7) | build first: `make build` in `implementations/clojure` |
| `cannot read configuration file …/pqledger.conf` (exit 2) | no `pqledger.conf` in the current directory: `cd` to it, pass `--config`, or set `PQLEDGER_CONFIG` |
| `pqledger.conf:7: unknown key 'date_colum'` (exit 2) | typo in a key; the line number points at it |
| `…: invalid value for 'format': expected table, csv or json` | there are no inline comments; remove `# …` after values |
| `no ledger in … (run 'pqledger init' first)` (exit 6) | `data_dir` points elsewhere than you think (it is relative to the configuration file), or run `init` |
| `FILE:LINE: invalid date '…' (expected MM/DD/YYYY)` (exit 4) | the account's `date_format` does not fit; check `--account` and the `[account NAME]` section |
| `FILE:LINE: invalid amount '1.234,56'` | set `decimal_separator = ,` and `thousands_separator = .`; for `$` amounts set `currency_symbol` |
| `FILE: the header has no column 'Date'` | set `date_column` etc. to the export's header names (case does not matter) or to positions; check `skip_lines` for preambles and `delimiter` |
| `FILE:LINE: record has 3 fields, expected 4` | a malformed line or a wrong `delimiter`; preamble lines need `skip_lines` |
| card charges show as income | set `invert_sign = true` for that account |
| everything is `uncategorized` | patterns must match the whole merchant — add `*` (`WHOLE FOODS*`); check with `pqledger query "SELECT DISTINCT merchant FROM transactions"` |
| re-imported a file, nothing added | expected: duplicates are skipped (`duplicates N` in the summary) |
| a JVM warning about the AOT cache on stderr | the cache does not match the JVM (e.g. after a JDK update); harmless, `make build` re-creates it |
| out of memory on a huge ledger | `PQLEDGER_JAVA_OPTS=-Xmx8g pqledger …`, or raise `[engine] memory_mb` for `memory limit` engine errors |
