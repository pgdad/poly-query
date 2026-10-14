# pqledger — user guide

`pqledger` is a personal-finance command-line program. It imports the CSV
statements your banks let you download, keeps every transaction in a ledger,
assigns categories with simple wildcard rules, and prints monthly reports,
spending breakdowns and budget checks. You can also ask the ledger anything
with SQL.

It is written in x86-64 assembly and runs the PolyQuery engine of this
directory **inside its own process** through the embedding library
(`lib/libpolyquery.a`, see [EMBEDDING.md](EMBEDDING.md)): it never starts a
server or another process and never opens a network connection. The ledger
is a set of PQCF files that every PolyQuery implementation can read.

Contents: [Building and installing](#building-and-installing) ·
[Quick start](#quick-start) · [Configuration](#configuration-reference) ·
[Rules file](#the-rules-file) · [Budget file](#the-budget-file) ·
[Commands](#commands) · [Output formats](#output-formats) ·
[The ledger files](#the-ledger-files) · [Exit codes](#exit-codes) ·
[Troubleshooting](#troubleshooting)

## Building and installing

Requirements: x86-64 Linux, GNU binutils 2.42, gcc 13.3 (used only as the
assembler/linker driver), GNU make, glibc. In this directory:

```sh
make build        # engine, lib/libpolyquery.a, out/pqledger, out/pq-embed-demo
make test         # engine and application unit tests, end-to-end tests
```

`bin/pqledger` is the launcher: a small shell script that runs
`out/pqledger` (and runs `make build` first if the binary is missing). It
works from any directory, so install it by putting `bin/` on your `PATH` or
by linking it:

```sh
ln -s "$PWD/bin/pqledger" ~/.local/bin/pqledger
```

The binary `out/pqledger` itself depends only on glibc (libc, libm,
libpthread); you may copy it anywhere.

## Quick start

```sh
mkdir ~/finance && cd ~/finance
cat > pqledger.conf <<'EOF'
[ledger]
data_dir = ledger
rules_file = rules.conf
budget_file = budgets.conf

[account checking]

[account visa]
date_column = Transaction Date
date_format = MM/DD/YYYY
currency_symbol = $
thousands_separator = ,
invert_sign = true
EOF
echo 'groceries = WHOLE FOODS*, TRADER JOE*' > rules.conf
echo 'groceries = 400'                        > budgets.conf

pqledger init
pqledger import ~/Downloads/checking-2026-09.csv --account checking
pqledger import ~/Downloads/visa-2026-09.csv --account visa
pqledger report monthly
pqledger report categories --month 2026-09
pqledger budget --month 2026-09
```

## Command line

```
pqledger [GLOBAL OPTIONS] COMMAND [COMMAND ARGUMENTS AND OPTIONS]
```

Global options must come **before** the command:

| option | meaning |
|---|---|
| `--config PATH` | use this configuration file |
| `--format table\|csv\|json` | output format; overrides `[output] format` |
| `--help` | same as `pqledger help` |

Options of a command come after the command, in any order and mixed with
its positional arguments. Every option takes its value as the **next**
argument: `--month 2026-09` (not `--month=2026-09`). Giving an option twice,
an unknown command or option, a missing or malformed value, or an extra
argument is a usage error (exit 1).

**Filters** accepted by `report …`, `list` and `export`:

| option | value | meaning |
|---|---|---|
| `--month M` | `YYYY-MM` | only transactions dated in month M |
| `--from M` | `YYYY-MM` | from the first day of month M on |
| `--to M` | `YYYY-MM` | up to the last day of month M |
| `--account NAME` | account name | only that account's transactions |

`--from` and `--to` may be used alone or together (inclusive range);
`--month` cannot be combined with either. Months are `YYYY-MM` with a year
0001–9999 and month 01–12; `--from` later than `--to` is a usage error.

## Configuration reference

### Where the configuration is read from

The first that applies:

1. `--config PATH` (relative to the current directory);
2. the environment variable `PQLEDGER_CONFIG`, if set and not empty
   (relative to the current directory);
3. `pqledger.conf` in the current directory.

If that file does not exist or cannot be read, the command fails with exit
2. Relative paths **inside** the configuration (`data_dir`, `rules_file`,
`budget_file`) are relative to the directory of the configuration file, so
`pqledger --config ~/finance/pqledger.conf …` works from anywhere.

### Syntax

UTF-8 text with `\n` or `\r\n` line ends (a leading byte-order mark is
ignored). Each line, after trimming spaces and tabs, is:

* empty, or
* a comment: starts with `#` or `;` (comments must be on their own line —
  there are no comments after a value),
* a section header `[ledger]`, `[import]`, `[output]`, `[engine]` or
  `[account NAME]` (exactly one space before the account name),
* an assignment `KEY = VALUE`; key and value are trimmed. To keep leading or
  trailing spaces, or to write an empty value, put the value in double
  quotes; inside them `\"` is `"` and `\\` is `\`:

  ```ini
  currency_symbol = " EUR"
  ```

Errors — an assignment before the first section, an unknown section or
key, a key given twice in one section, a section header given twice, an
invalid value — stop every command with exit 2 and a message naming the
file and line, e.g. `pqledger: error: pqledger.conf:3: unknown key 'foo' in
this section`.

### `[ledger]` (required)

| key | value | default |
|---|---|---|
| `data_dir` | directory holding the ledger files; **required** | — |
| `rules_file` | path of the category rules file | no rules: everything `uncategorized` |
| `budget_file` | path of the budget file | none (`budget` then fails with exit 2) |

### `[import]` and `[account NAME]`

`[import]` says how bank CSV files are read. An `[account NAME]` section may
override any of these keys for one account: the effective value for an
account is its `[account NAME]` value, else the `[import]` value, else the
default. Account sections are optional — you can import into any account
name; it then uses the `[import]` settings.

| key | value | default |
|---|---|---|
| `delimiter` | one ASCII character, or `tab` | `,` |
| `header` | `true` or `false`: the first record is a header | `true` |
| `skip_lines` | integer ≥ 0: physical lines to skip before the first record (a bank's preamble) | `0` |
| `date_column` | column reference | `Date` |
| `date_format` | `YYYY-MM-DD`, `YYYYMMDD`, `MM/DD/YYYY`, `DD/MM/YYYY` or `DD.MM.YYYY` | `YYYY-MM-DD` |
| `description_column` | column reference | `Description` |
| `amount_mode` | `signed` (one amount column) or `debit_credit` (two columns) | `signed` |
| `amount_column` | column reference (mode `signed`) | `Amount` |
| `debit_column` | column reference (mode `debit_credit`) | `Debit` |
| `credit_column` | column reference (mode `debit_credit`) | `Credit` |
| `decimal_separator` | `.` or `,` | `.` |
| `thousands_separator` | `none`, `,`, `.`, `space` or `'` | `none` |
| `currency_symbol` | text removed from the start or end of amounts, e.g. `$`, `€`, `EUR` | empty |
| `invert_sign` | `true` or `false`: negate every amount (card exports that list charges as positive numbers) | `false` |

A **column reference** is either a column position (`1` is the first
column) or a header name, matched case-insensitively against the header
fields (ignoring surrounding spaces). Names need `header = true`. The
decimal and thousands separators must differ.

**Account names** and **category names** consist of 1 to 32 characters
from `a-z 0-9 _ -` (lower case); `uncategorized` is not a valid category
name.

### `[output]`

| key | value | default |
|---|---|---|
| `format` | `table`, `csv` or `json` | `table` |

### `[engine]`

| key | value | default |
|---|---|---|
| `threads` | integer ≥ 1: worker threads per query | engine default (online CPUs, at most 16) |
| `memory_mb` | integer ≥ 1: memory limit per query, MiB | engine default (4096) |

### A complete example

A checking account with the defaults, a credit card that exports charges as
positive dollar amounts, and a German giro account with a two-line
preamble, `;` separators, `1.234,56` numbers and separate debit/credit
columns:

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

[account checking]
# Date,Description,Amount / 2026-09-01,"Whole Foods Market #10234",-54.20

[account visa]
# "Transaction Date","Description","Amount" / 09/01/2026,"Starbucks","$4.50"
date_column = Transaction Date
date_format = MM/DD/YYYY
currency_symbol = $
thousands_separator = ,
invert_sign = true

[account giro]
# Kontoauszug ... (2 preamble lines)
# Buchungstag;Verwendungszweck;Soll;Haben / 01.09.2026;REWE Markt;54,20;
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
```

## The rules file

The rules file assigns categories to transactions by their **merchant**
(the normalized description, see [import](#pqledger-import-file---account-name)).
Same line syntax as the configuration, without sections:

```ini
# category = pattern, pattern, ...
groceries = WHOLE FOODS*, TRADER JOE*, SAFEWAY
dining    = SQ *, *CAFE*, CHIPOTLE, STARBUCKS*
housing   = RENT*
utilities = PACIFIC GAS*, COMCAST*
income    = PAYROLL*, ACME CORP*
dining    = UBER   *EATS*
```

* In a pattern `*` matches any run of characters (also none), `?` exactly
  one character, everything else matches itself, ignoring ASCII case.
* A pattern must match the **whole** merchant: `WHOLE FOODS` does not match
  `WHOLE FOODS MARKET`, `WHOLE FOODS*` does.
* Patterns are trimmed, must not be empty and must not contain `%` or `_`.
* A category may appear on several lines.
* **First match wins**, in file order (line by line, left to right within a
  line). A transaction no pattern matches is `uncategorized`.
* A manual override (`set-category`) beats every rule.

Rules are read on every command, so editing the file immediately
recategorizes all past transactions. Errors stop the command with exit 2
(`pqledger: error: rules.conf:4: a pattern must not contain '%' or '_'`).

## The budget file

One monthly budget per category:

```ini
# category = monthly amount
groceries = 400
dining    = 150.00
utilities = 250
```

Amounts are `[0-9]+(\.[0-9]{1,2})?` (at most 16 integer digits). A category
listed twice is an error (exit 2). The budget file is read only by `budget`
and `query`.

## Commands

The examples below use the configuration of the quick start with a few
weeks of statements. Every command except `init`, `help` and `version`
needs an existing ledger (exit 6 otherwise) and reads the rules file.

### `pqledger init`

Creates `data_dir` (and missing parent directories) and the three empty
ledger tables.

```
$ pqledger init
initialized ledger
```

If a ledger already exists there, nothing changes and the exit status is 6.

### `pqledger import FILE --account NAME`

Reads a bank CSV export with the account's effective `[import]` settings and
appends its transactions to the ledger.

```
$ pqledger import checking-2026-09.csv --account checking
batch 1: imported 30, duplicates 0
$ pqledger import visa-2026-09.csv --account visa
batch 2: imported 21, duplicates 0
$ pqledger import checking-2026-09.csv --account checking
batch 3: imported 0, duplicates 30
```

How a record is read:

* **date** — in the configured `date_format`; in the `/` and `.` formats
  day and month may have one or two digits. It must be a real calendar
  date.
* **description** — trimmed of spaces and tabs (may be empty).
* **amount** — trimmed; `(12.50)` and `-12.50` are negative, a leading `+`
  is dropped; the `currency_symbol` is removed from the start or end; the
  thousands separators are removed; the decimal separator becomes `.`. What
  remains must be digits with at most two decimals (at most 16 integer
  digits). In `debit_credit` mode the amount is credit − debit, an empty
  field counts as 0 (but not both empty). `invert_sign` negates the result.
* **merchant** — the description upper-cased (ASCII letters), runs of spaces
  and tabs collapsed, and a trailing store or reference number removed: a
  last word `#` + digits, or of 3 or more digits, when there is more than
  one word. `Whole Foods Market #10234` → `WHOLE FOODS MARKET`,
  `SQ *Blue  Bottle 4421` → `SQ *BLUE BOTTLE`, `7-Eleven 12` → `7-ELEVEN 12`.

**Duplicates.** Statements overlap, so importing the same period twice must
not count it twice. Records are compared by (account, date, amount,
merchant): if the file has `f` records with one such key and the ledger
already has `l` transactions with it, only the last `f − l` of them are
imported (none if `l ≥ f`); the rest are counted as duplicates. Genuine
repeated purchases (two identical coffees the same day) are kept, because
they appear twice in the file.

New transactions get ids continuing after the largest id, in file order;
every import gets the next batch number, even when it imports nothing.

**All or nothing.** If any record is invalid, nothing is imported, no batch
is recorded and the exit status is 4. The message names the file and the
physical line where the bad record starts:

```
$ pqledger import sept.csv --account checking
pqledger: error: sept.csv:2: invalid date '2026-09-31'
```

### `pqledger report monthly [FILTERS]`

Income (sum of positive amounts), expenses (spending, as a positive
number), net and the number of transactions per month.

```
$ pqledger report monthly
month     income  expenses      net  transactions
-------  -------  --------  -------  ------------
2026-08  4400.08   3200.85  1199.23            26
2026-09  4330.35   3628.05   702.30            25
(2 rows)
```

### `pqledger report categories [FILTERS]`

Spending (outflows only) per category, largest first, with each category's
share of the total in percent (rounded half away from zero to one decimal).

```
$ pqledger report categories
category         spent  share  transactions
-------------  -------  -----  ------------
housing        3700.00   54.2             2
uncategorized  2016.76   29.5            30
utilities       760.93   11.1             6
groceries       314.22    4.6             4
dining           36.99    0.5             4
(5 rows)
```

### `pqledger report merchants [FILTERS] [--top N]`

The `N` merchants (default 10) with the largest spending.

```
$ pqledger report merchants --top 5
merchant                           spent  transactions
-------------------------------  -------  ------------
RENT - OAKWOOD APTS              3700.00             2
PACIFIC GAS & ELECTRIC            586.78             4
HOME DEPOT                        447.28             3
REI                               426.42             2
AMAZON.COM*8RYKA6 AMZN.COM/BILL   187.47             1
(5 rows)
```

### `pqledger budget --month M [--account NAME]`

Compares one month's spending per category with the budget file. Exit
status 3 if any category is over budget (the table is printed in full
either way), so scripts can react to it.

```
$ pqledger budget --month 2026-09
category   budget   spent  remaining  status
---------  ------  ------  ---------  ------
dining     150.00    9.69     140.31  ok
groceries  400.00   98.84     301.16  ok
utilities  250.00  549.61    -299.61  over
(3 rows)
$ echo $?
3
```

Without a `budget_file` in the configuration: exit 2. Without `--month`:
exit 1.

### `pqledger accounts`

```
$ pqledger accounts
account   transactions   balance  first       last
--------  ------------  --------  ----------  ----------
checking            30   3219.52  2026-08-01  2026-09-30
visa                21  -1317.99  2026-08-02  2026-09-29
(2 rows)
```

`balance` is the sum of the imported amounts (not your bank's balance,
unless you imported the account's complete history).

### `pqledger list [FILTERS] [--category C | --uncategorized]`

Transactions ordered by date, then id, with their resolved category.

```
$ pqledger list --month 2026-09 --account visa --category dining
id  date        account  description         amount  category
--  ----------  -------  ------------------  ------  --------
51  2026-09-29  visa     Starbucks Store 7979   -9.69  dining
(1 row)
```

`--uncategorized` lists the transactions no rule matched — handy for
writing new rules.

### `pqledger export [FILTERS]`

Every column of the transactions, with the resolved category, ordered by
id. Most useful with `--format csv` or `--format json`:

```
$ pqledger --format csv export --month 2026-08 | head -3
id,account,date,description,merchant,amount,category,batch
1,checking,2026-08-01,RENT - OAKWOOD APTS,RENT - OAKWOOD APTS,-1850.00,housing,1
2,checking,2026-08-04,REI #1172,REI,-280.06,uncategorized,1
```

### `pqledger set-category ID CATEGORY` / `pqledger set-category ID --clear`

Overrides the rules for one transaction (ids are shown by `list`), or
removes the override again.

```
$ pqledger set-category 3 dining
transaction 3: category dining
$ pqledger set-category 3 --clear
transaction 3: category cleared
```

An unknown id is exit 6; an invalid category name is exit 1. Clearing a
transaction that has no override succeeds.

### `pqledger query SQL`

Runs one SQL statement (PolyQuery SQL, see `spec/sql/`) on the ledger.
Tables available:

| table | columns |
|---|---|
| `transactions` | `id`, `account`, `date`, `description`, `merchant`, `amount`, `batch` |
| `batches` | `batch`, `account`, `file`, `imported`, `duplicates` |
| `overrides` | `id`, `category` |
| `ledger` | the `transactions` columns + `category` (resolved) |
| `rules` | `rule_no` (1, 2, … in file order), `category`, `pattern` (upper-cased) |
| `budgets` | `category`, `amount` (empty if no budget file is configured) |

`date` is a reserved word in SQL: write `"date"`. Nothing a query does is
saved.

```
$ pqledger query 'SELECT category, COUNT(*) AS n FROM ledger GROUP BY category ORDER BY n DESC'
category        n
-------------  --
uncategorized  31
utilities       8
groceries       4
dining          4
housing         2
income          2
(6 rows)
$ pqledger query 'SELECT nope FROM ledger'
pqledger: error: SEMANTIC_ERROR: unknown column 'nope'
$ echo $?
5
```

### `pqledger help`, `pqledger version`

`help` (or `--help`) prints the command summary; `version` prints e.g.
`pqledger 1.0.0 (engine polyquery-x86_64-asm 0.1.0)`. Both exit 0.

## Output formats

Choose with `--format` (before the command) or `[output] format`.

**table** (default): aligned columns, numbers right-aligned, a row count
footer `(N rows)` / `(1 row)`. Widths count Unicode characters, so accented
names line up.

**csv**: a header line, then one line per row, `,`-separated. Fields are
quoted only when needed (they contain `,`, `"` or a line break, start or end
with a space, or are an empty string); NULL is an empty unquoted field.

```
$ pqledger --format csv report monthly
month,income,expenses,net,transactions
2026-08,4400.08,3200.85,1199.23,26
2026-09,4330.35,3628.05,702.30,25
```

**json**: JSON Lines — one object per row, nothing at all for zero rows.
Decimal amounts, dates and strings are JSON strings (amounts stay exact),
integers and floating-point numbers are JSON numbers, NULL is `null`.

```
$ pqledger --format json accounts
{"account":"checking","transactions":30,"balance":"3219.52","first":"2026-08-01","last":"2026-09-30"}
{"account":"visa","transactions":21,"balance":"-1317.99","first":"2026-08-02","last":"2026-09-29"}
```

Value text: decimals with their scale (`-12.50`), dates `YYYY-MM-DD`,
booleans `true`/`false`, floating-point values with 6 decimals
(`0.333333`).

## The ledger files

`data_dir` holds three PQCF tables (the PolyQuery columnar file format);
they are the whole ledger — back up the directory to back up your data:

| file | columns |
|---|---|
| `transactions.pqcf` | `id` INT64, `account` STRING, `date` DATE, `description` STRING, `merchant` STRING, `amount` DECIMAL(18,2), `batch` INT64 |
| `batches.pqcf` | `batch` INT64, `account` STRING, `file` STRING (base name), `imported` INT64, `duplicates` INT64 |
| `overrides.pqcf` | `id` INT64, `category` STRING |

Any PolyQuery implementation can read and write them, e.g. with the engine
CLI: `bin/polyquery session --data-dir ~/finance/ledger` and
`{"op":"open","table":"t","path":"transactions.pqcf"}`.

Commands that change the ledger (`import`, `set-category`) compute the
complete new table in memory and write it only after everything succeeded,
so a failing command leaves the ledger unchanged.

## Exit codes

| exit | meaning |
|---|---|
| 0 | success |
| 1 | usage error (unknown command or option, bad or missing value, extra argument) |
| 2 | configuration error (configuration, rules or budget file) |
| 3 | `budget`: some category is over budget (output printed normally) |
| 4 | import data error (bad record, missing column, unreadable file) |
| 5 | `query`: the engine rejected or failed the SQL |
| 6 | ledger state: no ledger, ledger already exists, unknown transaction id |
| 7 | any other error (I/O, unexpected engine error, out of memory) |

On every error (1, 2, 4–7) nothing is written to standard output and the
first line on standard error starts with `pqledger: error: `.

## Troubleshooting

| message / symptom | cause and fix |
|---|---|
| `cannot read configuration file pqledger.conf: No such file or directory` (exit 2) | run in the directory holding `pqledger.conf`, or pass `--config PATH` / set `PQLEDGER_CONFIG` |
| `no ledger in ./ledger (run 'pqledger init' first)` (exit 6) | `data_dir` points to a directory without `transactions.pqcf`; run `pqledger init` or fix `data_dir` (relative to the configuration file) |
| `FILE: the header has no column 'Date'` (exit 4) | the account's `date_column` / `description_column` / `amount_column` does not match the bank's header; check with `head -3 FILE`, mind a preamble (`skip_lines`) |
| `FILE:7: expected 4 fields, found 3` (exit 4) | wrong `delimiter`, or a broken record at line 7 |
| `FILE:2: invalid date '09/01/2026'` | `date_format` does not match the file |
| `FILE:2: invalid amount '1.234,56'` | set `decimal_separator = ,` and `thousands_separator = .`; amounts with a currency text need `currency_symbol` |
| everything is `uncategorized` | patterns must match the whole merchant: add `*` (`WHOLE FOODS*`); look at the `merchant` column of `pqledger export` |
| card charges show up as income | set `invert_sign = true` for that account |
| an import reports duplicates you expected to be new | identical (account, date, amount, merchant) transactions already in the ledger are matched one to one; see [Duplicates](#pqledger-import-file---account-name) |
| `SEMANTIC_ERROR` … from `query` (exit 5) | the SQL is wrong; `date` must be quoted as `"date"` |
| very large ledgers | the whole ledger is processed in memory; at 1,000,000 transactions every command runs in under a second and `list` / `export` peak at about 1.5 GB. `[engine] memory_mb` caps a single query |
