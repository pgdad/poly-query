# pqledger — user guide

`pqledger` is a personal-finance ledger for the command line. It imports the
CSV statement exports of your bank accounts and credit cards, skips the rows
it has already seen, assigns categories with simple rules, and prints monthly
reports, spending by category and merchant, and budget checks. Everything is
stored in a small directory of PQCF files (the PolyQuery columnar format), so
any PolyQuery implementation can read and extend the same ledger.

`pqledger` embeds the PolyQuery engine of this directory as a library: it runs
in a single process, never starts a server and never opens a network
connection. Reports are SQL queries executed by the embedded engine, and you
can run your own SQL on the ledger with `pqledger query`.

Contents: [Building and installing](#building-and-installing) ·
[Quick start](#quick-start) · [Configuration](#configuration) ·
[The rules file](#the-rules-file) · [The budget file](#the-budget-file) ·
[Commands](#commands) · [Output formats](#output-formats) ·
[The ledger directory](#the-ledger-directory) · [Exit status](#exit-status) ·
[Troubleshooting](#troubleshooting)

## Building and installing

Requirements: SBCL 2.6.9 (`sbcl` on `PATH`, with its bundled ASDF) and GNU
make. Nothing is downloaded.

```sh
make -C implementations/common-lisp build   # builds build/polyquery, build/pqledger, build/pq-embed-demo
make -C implementations/common-lisp test    # unit tests of the engine and of pqledger
implementations/common-lisp/bin/pqledger version
```

`bin/pqledger` is a small shell launcher that runs the standalone executable
`build/pqledger`; it works from any working directory and through symbolic
links, so the usual way to install it is a link in a directory on your `PATH`:

```sh
ln -s "$PWD/implementations/common-lisp/bin/pqledger" ~/.local/bin/pqledger
```

The executable is self-contained (the engine is compiled into it); moving it
requires moving `build/pqledger` together with `bin/pqledger`, or calling
`build/pqledger` directly.

## Quick start

```sh
mkdir ~/finance && cd ~/finance
cat > pqledger.conf <<'EOF'
[ledger]
data_dir = ledger
rules_file = rules.conf
budget_file = budgets.conf
EOF
echo 'groceries = WHOLE FOODS*, TRADER JOE*' > rules.conf
echo 'groceries = 400' > budgets.conf

pqledger init
pqledger import ~/Downloads/checking-2026-09.csv --account checking
pqledger report monthly
pqledger budget --month 2026-09
```

The examples in this guide use the configuration, rules and budget files of
the next sections and three statements: a checking account (`Date`,
`Description`, signed `Amount`), a Visa card export (US dates, `$` amounts,
charges positive) and a German giro account (`;`-separated, a two-line
preamble, separate debit and credit columns, `1.234,56` amounts).

## Configuration

### Where pqledger looks for it

The first of these that applies is used:

1. `--config PATH` (a global option, before the command);
2. the environment variable `PQLEDGER_CONFIG`, if it is set and not empty;
3. `pqledger.conf` in the current directory.

If the chosen file does not exist or cannot be read, pqledger stops with exit
status 2. A relative `--config` or `PQLEDGER_CONFIG` path is relative to the
current directory; relative paths *inside* the file (`data_dir`,
`rules_file`, `budget_file`) are relative to the directory containing the
configuration file, so a configuration works the same from any directory.

`help` and `version` do not read the configuration.

### Syntax

The file is UTF-8 text with `\n` or `\r\n` line ends (a leading byte order
mark is ignored). Leading and trailing spaces and tabs of every line are
ignored. A line is

* empty, or a comment starting with `#` or `;` (comments must be on their
  own line — there are no comments after a value);
* a section header: `[ledger]`, `[import]`, `[output]`, `[engine]` or
  `[account NAME]` (exactly one space before the account name);
* an assignment `KEY = VALUE`. The key is the text before the first `=`, the
  value the text after it, both trimmed. To keep leading or trailing spaces,
  or to write an empty value, enclose the value in double quotes; inside the
  quotes `\"` stands for `"` and `\\` for `\`.

Each section and each key within a section may appear only once. An
assignment before the first section header, an unknown section or key, and an
invalid value are configuration errors (exit status 2); the message names
the file and the line.

**Names.** An account name and a category name consist of 1 to 32 of the
characters `a`–`z`, `0`–`9`, `_` and `-`. The category name `uncategorized`
is reserved for transactions without a category.

### `[ledger]` (required)

| key | value | default |
|---|---|---|
| `data_dir` | the directory holding the ledger files; **required** | — |
| `rules_file` | the category rules file ([below](#the-rules-file)) | no rules: everything is `uncategorized` |
| `budget_file` | the budget file ([below](#the-budget-file)) | none (`budget` then fails) |

### `[import]` and `[account NAME]`

`[import]` describes how statement CSV files are read. An `[account NAME]`
section may override any of these keys for the account `NAME`; for each key
the account's value is used if present, else the `[import]` value, else the
default. Accounts do not need a section: an account without one uses
`[import]` and the defaults.

| key | value | default |
|---|---|---|
| `delimiter` | the field separator: one ASCII character, or `tab` | `,` |
| `header` | `true` if the first record holds the column names, else `false` | `true` |
| `skip_lines` | number of physical lines before the CSV starts (a preamble), ≥ 0 | `0` |
| `date_column` | column of the posting date (see *column references*) | `Date` |
| `date_format` | `YYYY-MM-DD`, `YYYYMMDD`, `MM/DD/YYYY`, `DD/MM/YYYY` or `DD.MM.YYYY` | `YYYY-MM-DD` |
| `description_column` | column of the description | `Description` |
| `amount_mode` | `signed`: one amount column; `debit_credit`: separate debit and credit columns | `signed` |
| `amount_column` | the amount column (`signed`) | `Amount` |
| `debit_column`, `credit_column` | the debit and credit columns (`debit_credit`) | `Debit`, `Credit` |
| `decimal_separator` | `.` or `,` | `.` |
| `thousands_separator` | `none`, `,`, `.`, `space` or `'` | `none` |
| `currency_symbol` | text removed at the start or end of amounts, e.g. `$` or `" EUR"` | empty |
| `invert_sign` | `true` to negate every amount (card exports where charges are positive) | `false` |

**Column references.** A positive number is a 1-based column position
(`date_column = 1`); anything else is a header name, compared with the
header fields after trimming spaces and tabs, ignoring ASCII case. Names
require `header = true`; with `header = false` use positions.

**Dates.** In the `/` and `.` formats the month and day may have one or two
digits (`9/3/2026`); the year always has four. `YYYY-MM-DD` and `YYYYMMDD`
need two-digit months and days. The date must exist (`2026-02-30` is
rejected).

**Amounts.** An amount field is read like this: spaces and tabs around it are
removed; `(12.50)` is negative 12.50, a leading `-` makes it negative and a
leading `+` is dropped; the `currency_symbol` is removed from the start or
the end; the thousands separators are removed and the decimal separator
becomes a point. What remains must be digits with at most two decimals and
at most 16 digits before the point. In `debit_credit` mode the amount is
credit minus debit; one of the two may be empty (it counts as 0), but not
both. Finally `invert_sign` negates the amount. Negative amounts are money
going out, positive amounts money coming in. The decimal and thousands
separators must differ.

### `[output]`

| key | value | default |
|---|---|---|
| `format` | `table`, `csv` or `json` (see [Output formats](#output-formats)) | `table` |

The global option `--format` overrides it for one command.

### `[engine]`

| key | value | default |
|---|---|---|
| `threads` | worker threads per query (≥ 1) | one per CPU, at most 16 |
| `memory_mb` | memory limit per query in MB (≥ 1) | 2048 |

These are passed to the embedded engine (the query `threads` option and the
per-query memory limit `--max-query-memory-mb`). The defaults are fine for
ledgers of millions of transactions.

### A complete example

```ini
# ~/finance/pqledger.conf
[ledger]
data_dir = ledger
rules_file = rules.conf
budget_file = budgets.conf

[import]
date_column = Date
description_column = Description
amount_column = Amount

[output]
format = table

[engine]
threads = 4
memory_mb = 1024

# Credit card export: "Transaction Date","Description","Amount" with
# 09/05/2026 dates, "$1,248.23" amounts, charges positive, refunds "($31.06)".
[account visa]
date_column = Transaction Date
date_format = MM/DD/YYYY
currency_symbol = $
thousands_separator = ,
invert_sign = true

# German giro account: two preamble lines, then
# Buchungstag;Verwendungszweck;Soll;Haben with 04.09.2026 and 1.120,00.
[account sparkonto]
delimiter = ;
skip_lines = 2
date_column = Buchungstag
date_format = DD.MM.YYYY
description_column = Verwendungszweck
decimal_separator = ,
thousands_separator = .
amount_mode = debit_credit
debit_column = Soll
credit_column = Haben
```

The matching statement files look like this (`checking-2026-09.csv`,
`visa-2026-09.csv`, `spark-2026-09.csv`):

```
Date,Description,Amount
2026-09-01,"RENT - OAKWOOD APTS",-1850.00
2026-09-02,"Whole Foods Market #10234",-84.12
```

```
"Transaction Date","Description","Amount"
09/05/2026,"UBER   *TRIP Q5WS6F","$31.06"
09/07/2026,"Home Depot #3203","$1,248.23"
09/09/2026,"UBER   *TRIP Q5WS6F","($31.06)"
```

```
Kontoumsätze Girokonto;;;
Zeitraum: 01.09.2026 - 30.09.2026;;;
Buchungstag;Verwendungszweck;Soll;Haben
04.09.2026;DB Vertrieb GmbH;71,83;
30.09.2026;Zinsen;;0,42
```

`datasets/generators/bankgen.py --style us-checking|us-card|de-giro
--print-config` prints the account settings for its three generated
statement styles.

## The rules file

The rules file assigns categories to transactions by their **merchant**, a
normalized form of the description: ASCII letters are upper-cased, runs of
spaces and tabs become one space, and a trailing store number — a last word
`#` followed by digits, or a last word of three or more digits — is removed.
`Whole Foods Market #10234` becomes `WHOLE FOODS MARKET`,
`SQ *Blue  Bottle 4421` becomes `SQ *BLUE BOTTLE`, `Rent 2026` becomes
`RENT`, while `7-Eleven 12` stays `7-ELEVEN 12`. (`pqledger export` shows
each transaction's merchant.)

The file uses the line syntax of the configuration file without sections:
blank lines, comments, and lines

```
CATEGORY = PATTERN [, PATTERN ...]
```

A pattern must match the **whole** merchant, ignoring ASCII case: `*` matches
any text (also none), `?` exactly one character, every other character
itself. Patterns may not be empty and may not contain `%` or `_`. A category
may appear on several lines.

```ini
# rules.conf — the first matching pattern wins (line order, then left to right)
groceries = WHOLE FOODS*, TRADER JOE*, REWE*
coffee    = SQ *BLUE BOTTLE*, STARBUCKS*
transport = UBER*, SHELL*, DB VERTRIEB*
housing   = RENT*, MIETE*
income    = PAYROLL*, GEHALT*
```

The category of a transaction is

1. its override, if you set one with `pqledger set-category`;
2. else the category of the first pattern that matches its merchant, in file
   order;
3. else `uncategorized`.

Rules are applied every time pqledger runs, so editing the rules file
recategorizes all past transactions — no re-import is needed. Every command
except `init`, `help` and `version` reads the rules file; if it is configured
but missing or invalid, the command fails with exit status 2.

## The budget file

One monthly budget per category:

```ini
# budgets.conf
groceries = 400
coffee    = 25.00
transport = 150
```

An amount is digits with at most two decimals (`150`, `25.5`, `25.00`), at
most 16 digits before the point. Listing a category twice is an error. Only
`budget` and `query` read the budget file.

## Commands

```
pqledger [--config PATH] [--format table|csv|json] COMMAND [ARGUMENTS AND OPTIONS]
```

Global options go before the command; `--help` is the same as `help`.
Command options follow the command, in any order among its arguments, and
take their value as the next argument (`--month 2026-09`; the form
`--month=2026-09` is not accepted). An unknown command or option, a missing
or malformed value, a repeated option or a surplus argument is a usage error
(exit status 1).

**Filters.** `report`, `list` and `export` accept

| option | meaning |
|---|---|
| `--month YYYY-MM` | only transactions dated in that month |
| `--from YYYY-MM`, `--to YYYY-MM` | an inclusive range of months; either may be given alone |
| `--account NAME` | only transactions of that account |

`--month` cannot be combined with `--from`/`--to`, and `--from` may not be
later than `--to`. Months run from `0001-01` to `9999-12`.

The examples below show the output of the sample ledger built from the three
statements above.

### `init`

Creates `data_dir` (and missing parent directories) with an empty ledger.
Fails with exit status 6 if a ledger already exists there.

```
$ pqledger init
initialized ledger
```

### `import FILE --account NAME`

Reads the statement `FILE` (relative to the current directory) with the
settings of account `NAME` and adds its new transactions as a new *batch*.

```
$ pqledger import statements/checking-2026-09.csv --account checking
batch 1: imported 8, duplicates 0
$ pqledger import statements/visa-2026-09.csv --account visa
batch 2: imported 4, duplicates 0
$ pqledger import statements/spark-2026-09.csv --account sparkonto
batch 3: imported 3, duplicates 0
$ pqledger import statements/checking-2026-09.csv --account checking
batch 4: imported 0, duplicates 8
```

**Duplicates.** Statements overlap, so importing the same rows twice must not
count them twice. Transactions are compared by account, date, amount and
merchant. If a file has *f* rows with one such key and the ledger already
has *l* transactions with it, the last *f − l* of those rows are imported
(none if *l ≥ f*) and the others are counted as duplicates. Identical rows
within one file are therefore kept (two coffees of the same price on the same
day are two transactions), and re-importing an overlapping statement adds
only what is new.

**Errors.** If any row cannot be read — a bad date, a malformed amount, a
wrong number of fields — nothing is imported and pqledger reports the file
and the line where the row starts (exit status 4):

```
$ pqledger import bad.csv --account checking
pqledger: error: bad.csv:3: invalid date "2026-09-31"
```

A missing file, a header without a configured column, or a column position
beyond the record are import errors too. A batch is recorded even when every
row was a duplicate.

### `report monthly [FILTERS]`

Income (sum of positive amounts), expenses (money out, as a positive
number), net (sum of all amounts) and the number of transactions per month.

```
$ pqledger report monthly
month     income  expenses       net  transactions
-------  -------  --------  --------  ------------
2026-09  4281.48   3461.77    819.71            14
2026-10     0.00   1850.00  -1850.00             1
(2 rows)
```

### `report categories [FILTERS]`

Money out per category, largest first, with each category's share of the
total in percent (rounded half away from zero to one decimal, computed
exactly).

```
$ pqledger report categories --month 2026-09
category         spent  share  transactions
-------------  -------  -----  ------------
housing        1850.00   53.4             1
uncategorized  1263.72   36.5             2
groceries       169.11    4.9             3
transport       151.09    4.4             3
coffee           27.85    0.8             2
(5 rows)
```

### `report merchants [FILTERS] [--top N]`

Money out per merchant, largest first; the first `N` rows (default 10).

```
$ pqledger report merchants --top 3
merchant               spent  transactions
-------------------  -------  ------------
RENT - OAKWOOD APTS  3700.00             2
HOME DEPOT           1248.23             1
WHOLE FOODS MARKET     84.12             1
(3 rows)
```

### `budget --month M [--account NAME]`

Compares the month's spending per category with the budget file. Every
budget category is listed; `status` is `ok` when spent ≤ budget, else
`over`. The exit status is **3** if any category is over budget (the report
is printed either way), which makes `budget` usable in scripts.

```
$ pqledger budget --month 2026-09
category   budget   spent  remaining  status
---------  ------  ------  ---------  ------
coffee      25.00   27.85      -2.85  over
groceries  400.00  169.11     230.89  ok
transport  150.00  151.09      -1.09  over
(3 rows)
$ echo $?
3
```

### `accounts`

Number of transactions, balance (sum of amounts) and the first and last date
per account.

```
$ pqledger accounts
account    transactions   balance  first       last
---------  ------------  --------  ----------  ----------
checking              8    327.94  2026-09-01  2026-10-01
sparkonto             3    -94.51  2026-09-04  2026-09-30
visa                  4  -1263.72  2026-09-05  2026-09-21
(3 rows)
```

### `list [FILTERS] [--category C | --uncategorized]`

The transactions passing the filters, by date, with their category;
`--category C` keeps those whose category is `C`, `--uncategorized` those
without one. The `id` column is what `set-category` takes.

```
$ pqledger list --month 2026-09 --account visa
id  date        account  description            amount  category
--  ----------  -------  -------------------  --------  -------------
 9  2026-09-05  visa     UBER   *TRIP Q5WS6F    -31.06  transport
10  2026-09-07  visa     Home Depot #3203     -1248.23  uncategorized
11  2026-09-09  visa     UBER   *TRIP Q5WS6F     31.06  transport
12  2026-09-21  visa     Netflix.com            -15.49  uncategorized
(4 rows)
$ pqledger list --uncategorized
id  date        account    description         amount  category
--  ----------  ---------  ----------------  --------  -------------
10  2026-09-07  visa       Home Depot #3203  -1248.23  uncategorized
12  2026-09-21  visa       Netflix.com         -15.49  uncategorized
15  2026-09-30  sparkonto  Zinsen                0.42  uncategorized
(3 rows)
```

### `export [FILTERS]`

Every column of the transactions passing the filters — including the
merchant and the import batch — ordered by id. Use `--format csv` to feed a
spreadsheet.

```
$ pqledger export --account sparkonto
id  account    date        description       merchant          amount  category       batch
--  ---------  ----------  ----------------  ----------------  ------  -------------  -----
13  sparkonto  2026-09-04  DB Vertrieb GmbH  DB VERTRIEB GMBH  -71.83  transport          3
14  sparkonto  2026-09-12  REWE Markt 4411   REWE MARKT        -23.10  groceries          3
15  sparkonto  2026-09-30  Zinsen            ZINSEN              0.42  uncategorized      3
(3 rows)
```

### `set-category ID CATEGORY` and `set-category ID --clear`

Overrides the category of one transaction (rules no longer apply to it), or
removes the override again. Clearing a transaction without an override is
fine. An unknown id is a ledger error (exit status 6), an invalid category
name a usage error (exit status 1).

```
$ pqledger set-category 12 subscriptions
transaction 12: category subscriptions
$ pqledger set-category 12 --clear
transaction 12: category cleared
```

### `query SQL`

Runs one SQL statement (PolyQuery SQL, see `spec/sql/`) on the embedded
engine and prints its result. These tables are available:

| table | columns |
|---|---|
| `transactions` | `id`, `account`, `date`, `description`, `merchant`, `amount`, `batch` |
| `batches` | `batch`, `account`, `file`, `imported`, `duplicates` |
| `overrides` | `id`, `category` |
| `ledger` | the `transactions` columns and `category` (the resolved category) |
| `rules` | `rule_no` (1, 2, … in file order), `category`, `pattern` (upper-cased) |
| `budgets` | `category`, `amount` |

`date` is a reserved word in SQL: write it as `"date"`. Nothing a query does
is saved. If the engine reports an error, pqledger prints its error code and
message and exits with status 5.

```
$ pqledger query "SELECT category, COUNT(*) AS n, SUM(amount) AS total FROM ledger GROUP BY category ORDER BY total"
category       n     total
-------------  -  --------
housing        2  -3700.00
uncategorized  3  -1263.30
groceries      3   -169.11
transport      4   -120.03
coffee         2    -27.85
income         1   4250.00
(6 rows)
$ pqledger --format csv query "SELECT rule_no, category, pattern FROM rules WHERE category = 'coffee'"
rule_no,category,pattern
4,coffee,SQ *BLUE BOTTLE*
5,coffee,STARBUCKS*
$ pqledger query "SELEC 1"
pqledger: error: PARSE_ERROR: unexpected "SELEC", expected SELECT, WITH, EXPLAIN, CREATE or DROP, at line 1 column 1
```

### `help`, `version`

`help` (or `--help`) prints a usage summary, `version` the version of
pqledger and of the engine. Neither needs a configuration.

```
$ pqledger version
pqledger 1.0.0 (PolyQuery engine 0.4.0, SBCL 2.6.9)
```

## Output formats

Choose with `[output] format` or `--format` (which wins).

**`table`** (default): aligned columns separated by two spaces, numbers
right-aligned, a line of dashes under the header and a row count; widths
count Unicode characters; NULL is shown as an empty cell.

**`csv`**: a header record and one record per row, comma-separated, each
ending in `\n`. A field is quoted (with `"` doubled) if it is an empty
string, contains a comma, quote, CR or LF, or starts or ends with a space;
NULL is an empty unquoted field.

```
$ pqledger --format csv report categories
category,spent,share,transactions
housing,3700.00,69.7,2
uncategorized,1263.72,23.8,2
groceries,169.11,3.2,3
transport,151.09,2.8,3
coffee,27.85,0.5,2
```

**`json`**: JSON Lines — one object per row, keys in column order, nothing at
all for zero rows. Text, amounts and dates are JSON strings (amounts keep
their exact decimals), counts and floating-point numbers are JSON numbers,
NULL is `null`.

```
$ pqledger --format json accounts
{"account":"checking","transactions":8,"balance":"327.94","first":"2026-09-01","last":"2026-10-01"}
{"account":"sparkonto","transactions":3,"balance":"-94.51","first":"2026-09-04","last":"2026-09-30"}
{"account":"visa","transactions":4,"balance":"-1263.72","first":"2026-09-05","last":"2026-09-21"}
```

Values are written as: amounts with exactly two decimals (`-12.50`), shares
with one; dates `YYYY-MM-DD`; floating-point results of `query` with six
decimals (`0.333333`); booleans `true`/`false`.

## The ledger directory

`data_dir` holds three PQCF files, which are the whole ledger:

| file | contents |
|---|---|
| `transactions.pqcf` | `id`, `account`, `date`, `description` (trimmed), `merchant`, `amount` (DECIMAL(18,2)), `batch` |
| `batches.pqcf` | one row per import: `batch`, `account`, `file` (base name), `imported`, `duplicates` |
| `overrides.pqcf` | `id`, `category` — the categories set with `set-category` |

Ids and batch numbers count up from 1 and are never reused. Categories are
not stored (except overrides): they are computed from the rules on every
run. Back the directory up by copying it; any PolyQuery implementation's
pqledger can use it. While pqledger writes, it first saves complete new
files under temporary names (`.pqledger-*.tmp`) and then renames them into
place, so a failed command leaves the ledger as it was. Do not run two
importing commands on the same ledger at the same time.

## Exit status

| status | meaning |
|---|---|
| 0 | success |
| 1 | usage error (unknown command or option, malformed value, missing or surplus argument) |
| 2 | configuration error: the configuration, rules or budget file is missing or invalid |
| 3 | `budget`: at least one category is over budget (the report is printed) |
| 4 | import error: unreadable statement file or a row that cannot be read |
| 5 | `query`: the engine reported an error (`pqledger: error: CODE: MESSAGE`) |
| 6 | ledger state: no ledger yet, a ledger already exists (`init`), unknown transaction id |
| 7 | any other error (I/O errors, unexpected engine errors) |

On every failure (all statuses except 0 and 3) nothing is printed on
standard output, the first line on standard error starts with
`pqledger: error: `, and the ledger is unchanged.

## Troubleshooting

**`pqledger: error: cannot read configuration file …/pqledger.conf`** —
pqledger did not find a configuration. Run it in the directory with
`pqledger.conf`, pass `--config PATH`, or set `PQLEDGER_CONFIG`.

**`…: unknown key …`, `… repeated in its section`, `invalid value …`** — the
message names the file and line. Remember that comments must be on their own
line (`format = csv # comment` is an invalid value) and that values with
leading or trailing spaces need quotes (`currency_symbol = " EUR"`).

**`no ledger in … (run pqledger init first)`** (exit 6) — `data_dir` has no
`transactions.pqcf`. Check that `data_dir` points where you expect: it is
relative to the configuration file's directory, not the current directory.

**`FILE: the header has no column "Date"`** (exit 4) — the statement's
header names differ from the configured column names. Set `date_column`,
`description_column`, `amount_column` (or `debit_column`/`credit_column`)
in the account's section, or use column positions (`date_column = 1`).
If the bank puts a title above the header, set `skip_lines`.

**`FILE:LINE: invalid date …` / `invalid amount …`** (exit 4) — check
`date_format`, `decimal_separator`, `thousands_separator` and
`currency_symbol` for that account against the line shown. Nothing was
imported; fix the settings (or the file) and import again.

**`FILE:LINE: the record has N fields, expected M`** (exit 4) — the wrong
`delimiter` (`;` or `tab`), or a row with an unbalanced quote: the line is
where the broken record starts.

**Everything is `uncategorized`** — rules match the *merchant* (see
`pqledger export`), the whole of it: use `*` for the rest, e.g.
`STARBUCKS*` rather than `STARBUCKS`. Check the configured `rules_file`.

**Charges show up as income** — card exports often list charges as positive
numbers; set `invert_sign = true` for that account.

**Re-import reported duplicates you expected to be new** — rows are equal when
account, date, amount and merchant are equal; merchants ignore store numbers
(`#1234`), so two purchases of the same amount on the same day at two branches
of a chain look alike. If a statement lists such a pair twice, both are kept;
only rows already in the ledger are skipped.

**`budget` exits with 3** — that is the "over budget" signal, not an error.

**`query` says `PARSE_ERROR: unexpected …, expected string literal`** — `date`
is an SQL keyword (it starts a `DATE '2026-09-01'` literal); quote the
column: `SELECT "date", amount FROM ledger`.
