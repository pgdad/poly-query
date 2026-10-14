# pqledger — user guide

`pqledger` is a personal-finance command-line tool. It imports the CSV
statements your banks let you download, keeps them in a ledger without double
counting overlapping statements, assigns categories with simple rules, and
prints monthly reports, spending breakdowns and budget checks. You can also
query the ledger with SQL.

It is written in AArch64 assembly and runs the PolyQuery engine **inside its
own process** (through the library described in [EMBEDDING.md](EMBEDDING.md)):
no server, no network, no other processes. The ledger is stored as PQCF files
that every PolyQuery implementation can read.

Contents: [1 Build and install](#1-build-and-install) ·
[2 Quick start](#2-quick-start) · [3 Configuration](#3-configuration-reference) ·
[4 Rules file](#4-rules-file) · [5 Budget file](#5-budget-file) ·
[6 Commands](#6-commands) · [7 Output formats](#7-output-formats) ·
[8 Exit codes](#8-exit-codes) · [9 Troubleshooting](#9-troubleshooting)

---

## 1. Build and install

Requirements: an AArch64 (arm64) Linux machine with `make`, `gcc` and binutils.

```sh
cd implementations/arm64-asm-engine
make build        # engine, lib/libpolyquery.a, build/pqledger, the embed demo
make test         # optional: engine and application unit tests
```

Run it through the launcher, which works from any directory:

```sh
/path/to/arm64-asm-engine/bin/pqledger version
```

To install, either put `bin/` on your `PATH`, or copy the binary — it is
self-contained (the engine is linked in; it needs only glibc):

```sh
install -m 755 build/pqledger ~/.local/bin/pqledger
```

## 2. Quick start

```sh
mkdir ~/finance && cd ~/finance
cat > pqledger.conf <<'EOF'
[ledger]
data_dir = ledger
rules_file = rules.conf
budget_file = budgets.conf
EOF
echo 'groceries = WHOLE FOODS*, TRADER JOE*' > rules.conf
echo 'groceries = 400'                    > budgets.conf

pqledger init
pqledger import ~/Downloads/checking-2026-09.csv --account checking
pqledger report monthly
pqledger budget --month 2026-09
```

## 3. Configuration reference

### 3.1 Where the configuration comes from

The first of these that applies is used:

1. `--config PATH` (before the command: `pqledger --config ~/finance/pqledger.conf accounts`);
2. the environment variable `PQLEDGER_CONFIG`, if set and non-empty;
3. `pqledger.conf` in the current directory.

If that file does not exist or cannot be read, pqledger stops with exit code 2.
Relative paths given with `--config`/`PQLEDGER_CONFIG` are relative to the
current directory; relative paths **inside** the file (`data_dir`,
`rules_file`, `budget_file`) are relative to the directory containing the
configuration file — so `pqledger --config ~/finance/pqledger.conf …` works
from anywhere.

### 3.2 Syntax

* UTF-8 text; `\n` or `\r\n` line ends; a leading byte-order mark is ignored.
* Leading and trailing spaces/tabs of every line are ignored.
* Empty lines and comment lines (first character `#` or `;`) are ignored.
  There are no comments at the end of a line: `format = csv # x` sets the
  value `csv # x` (which is invalid).
* `[section]` starts a section: `[ledger]`, `[import]`, `[output]`,
  `[engine]` or `[account NAME]` (exactly one space before the account name).
* `KEY = VALUE`: the key is the text before the first `=`, the value the text
  after it, both trimmed. To keep leading/trailing spaces, or to give an
  empty value, put the value in double quotes; inside quotes `\"` is a quote
  and `\\` a backslash: `currency_symbol = " EUR"`.

It is an error (exit 2, the message names the line) to have an assignment
before the first section, an unknown section or key, a key twice in one
section, the same section header twice, or an invalid value.

### 3.3 `[ledger]` (required)

| key | value | default |
|---|---|---|
| `data_dir` | directory holding the ledger files (created by `init`) | required |
| `rules_file` | category rules file ([§4](#4-rules-file)) | no rules: everything is `uncategorized` |
| `budget_file` | budget file ([§5](#5-budget-file)) | none (`budget` then fails with exit 2) |

### 3.4 `[import]` and `[account NAME]`

`[import]` sets how bank CSV files are read. An `[account NAME]` section may
override any of these keys for one account; the effective value is the
account's, else `[import]`'s, else the default. Accounts do not need a section
unless their format differs.

| key | value | default |
|---|---|---|
| `delimiter` | one ASCII character, or `tab` | `,` |
| `header` | `true` / `false` — does the file have a header row? | `true` |
| `skip_lines` | number of physical lines to skip first (a preamble) | `0` |
| `date_column` | column reference (below) | `Date` |
| `date_format` | `YYYY-MM-DD`, `YYYYMMDD`, `MM/DD/YYYY`, `DD/MM/YYYY`, `DD.MM.YYYY` | `YYYY-MM-DD` |
| `description_column` | column reference | `Description` |
| `amount_mode` | `signed` (one amount column, negative = money out) or `debit_credit` (two columns) | `signed` |
| `amount_column` | column reference (`signed`) | `Amount` |
| `debit_column`, `credit_column` | column references (`debit_credit`) | `Debit`, `Credit` |
| `decimal_separator` | `.` or `,` | `.` |
| `thousands_separator` | `none`, `,`, `.`, `space` or `'` | `none` |
| `currency_symbol` | text removed from the start or end of amounts, e.g. `$`, `€`, `" EUR"` | empty |
| `invert_sign` | `true` / `false` — negate every amount (card exports that list charges as positive) | `false` |

A **column reference** is either a 1-based column number (`3`) or a header
name, compared case-insensitively after trimming (`transaction date` matches
`Transaction Date`). Names need `header = true`. The decimal and thousands
separators must differ.

In `/` and `.` date formats the day and month may have one or two digits
(`9/1/2026`); the year always has four.

**Account names** and **category names** use lowercase letters, digits, `_`
and `-`, 1–32 characters (`checking`, `visa-gold`, `eating_out`); the
category name `uncategorized` is reserved.

### 3.5 `[output]`

| key | value | default |
|---|---|---|
| `format` | `table`, `csv` or `json` ([§7](#7-output-formats)); `--format` overrides it | `table` |

### 3.6 `[engine]`

| key | value | default |
|---|---|---|
| `threads` | integer ≥ 1: worker threads per query | engine default (min(CPUs, 8)) |
| `memory_mb` | integer ≥ 1: memory limit per query in MiB | engine default (4096) |

### 3.7 Complete example

Three accounts: a US checking account (the defaults fit), a credit card whose
export lists charges as positive dollar amounts, and a German giro account
with a two-line preamble, `;` separators and separate debit/credit columns.

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

[account visa]
date_column = Transaction Date
date_format = MM/DD/YYYY
currency_symbol = $
thousands_separator = ,
invert_sign = true

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
```

The files these settings read look like:

```
==> checking-2026-09.csv <==
Date,Description,Amount
2026-08-01,"RENT - OAKWOOD APTS",-1850.00
2026-08-05,"Spotify USA",-11.41

==> visa-2026-09.csv <==
"Transaction Date","Description","Amount"
08/09/2026,"SAFEWAY 781","$134.26"
08/14/2026,"Shell Oil 8945","$55.27"

==> giro-2026-09.csv <==
Kontoumsätze Girokonto;;;
Zeitraum;;;
Buchungstag;Verwendungszweck;Soll;Haben
01.09.2026;Miete Hausverwaltung;1.120,00;
```

### 3.8 How bank records are converted

* **CSV**: RFC 4180 with the configured delimiter and `"` quotes; empty lines
  are ignored; every record must have as many fields as the header (or the
  first record without a header).
* **Description**: trimmed of spaces and tabs.
* **Amount**: trimmed; `(12.50)` or `-12.50` is negative, a leading `+` is
  dropped; the currency symbol is removed from the start or end; thousands
  separators are removed; the decimal separator becomes `.`. The result must
  be digits with at most 2 decimals (at most 16 integer digits). In
  `debit_credit` mode the amount is credit − debit, an empty side counting as
  0 (but not both empty). `invert_sign` is applied last.
* **Merchant**: a normalized description used for rules, duplicates and the
  merchants report: ASCII letters upper-cased, runs of spaces/tabs collapsed,
  and a trailing store number removed — a last word `#` + digits, or of 3+
  digits: `Whole Foods Market #10234` → `WHOLE FOODS MARKET`,
  `SQ *Blue  Bottle 4421` → `SQ *BLUE BOTTLE`, `7-Eleven 12` stays
  `7-ELEVEN 12`.

## 4. Rules file

Each line assigns merchant patterns to a category:

```ini
# rules.conf — CATEGORY = PATTERN, PATTERN, ...
groceries = WHOLE FOODS MARKET, TRADER JOE*, REWE*, EDEKA*
dining    = SQ *BLUE BOTTLE*, *STARBUCKS*, CHIPOTLE*
housing   = RENT*, MIETE*
utilities = PACIFIC GAS*, COMCAST*, STADTWERKE*
income    = PAYROLL*, GEHALT*
shopping  = AMAZON*, HOME DEPOT, REI
```

* Same comment/blank-line syntax as the configuration, no sections.
* A pattern must match the **whole merchant** (the normalized description,
  see `pqledger export` or the `merchant` column), ignoring ASCII case.
  `*` matches any text (also none), `?` exactly one character, everything else
  itself. `%` and `_` are not allowed in patterns.
* A category may appear on several lines.
* The **first** matching pattern wins, in file order (line by line, then left
  to right). A manual override (`set-category`) beats every rule; with no
  match the category is `uncategorized`.
* Rules are applied each time you run a command, never stored: edit the file
  and every report reflects the change, including past transactions.

Tip: `pqledger list --uncategorized` shows what still needs a rule, and
`pqledger query "SELECT * FROM rules"` shows how the rules were read.

## 5. Budget file

One monthly budget per category:

```ini
# budgets.conf — CATEGORY = monthly amount
groceries = 400
dining    = 60
utilities = 250.00
shopping  = 150
```

Amounts are non-negative with up to two decimals (`[0-9]+(.[0-9]{1,2})?`, at
most 16 integer digits). Listing a category twice is an error.

## 6. Commands

```
pqledger [--config PATH] [--format table|csv|json] [--help] COMMAND [ARGS]
```

Global options go **before** the command. A command's options follow it, in
any order among its arguments; each option takes its value as the next
argument (`--month 2026-09`). Repeating an option, unknown commands or
options, missing or malformed values and extra arguments are usage errors
(exit 1).

**Filters** (for `report …`, `list`, `export`):

| option | meaning |
|---|---|
| `--month YYYY-MM` | only that month |
| `--from YYYY-MM`, `--to YYYY-MM` | inclusive month range; either alone is fine; not with `--month` |
| `--account NAME` | only that account |

The examples below use the configuration of §3.7 and three small statements.

### `init`

Creates `data_dir` (and missing parents) and an empty ledger. Fails with exit
6 if a ledger already exists there.

```console
$ pqledger init
initialized ledger
```

### `import FILE --account NAME`

Imports a bank statement using the account's settings. Re-importing the same
or an overlapping statement does not create duplicates: for each
(account, date, amount, merchant) combination, only as many records are added
as the file has beyond what the ledger already holds (the last ones in the
file). Each import is recorded as a batch, even when it adds nothing.

```console
$ pqledger import checking-2026-09.csv --account checking
batch 1: imported 17, duplicates 0
$ pqledger import visa-2026-09.csv --account visa
batch 2: imported 11, duplicates 0
$ pqledger import giro-2026-09.csv --account giro
batch 3: imported 7, duplicates 0
$ pqledger import checking-2026-09.csv --account checking
batch 4: imported 0, duplicates 17
```

If any record is invalid nothing is imported, and the error names the file
and line (exit 4):

```console
$ pqledger import bad.csv --account checking
pqledger: error: bad.csv:3: invalid date '2026-13-01'
```

### `accounts`

Transactions, balance (sum of amounts) and first/last date per account.

```console
$ pqledger accounts
account   transactions  balance  first       last
--------  ------------  -------  ----------  ----------
checking            17  4440.52  2026-08-01  2026-09-28
giro                 7  2425.34  2026-09-01  2026-09-24
visa                11  -592.42  2026-08-09  2026-09-30
(3 rows)
```

### `report monthly [filters]`

Income (positive amounts), expenses (money out, as a positive number), net
and the number of transactions per month.

```console
$ pqledger report monthly
month     income  expenses      net  transactions
-------  -------  --------  -------  ------------
2026-08  4250.00   2375.52  1874.48            13
2026-09  8334.27   3935.31  4398.96            22
(2 rows)
```

### `report categories [filters]`

Spending (outflows only) per category, largest first, with each category's
share of the total in percent (rounded half away from zero to one decimal).

```console
$ pqledger report categories --month 2026-09
category         spent  share  transactions
-------------  -------  -----  ------------
housing        2970.00   75.5             2
uncategorized   315.05    8.0             7
shopping        236.12    6.0             1
groceries       209.09    5.3             3
utilities       187.27    4.8             2
dining           17.78    0.5             2
(6 rows)
```

### `report merchants [filters] [--top N]`

The merchants you spend most with (outflows only); the top 10 unless `--top N`.

```console
$ pqledger report merchants --top 5
merchant                           spent  transactions
-------------------------------  -------  ------------
RENT - OAKWOOD APTS              3700.00             2
MIETE HAUSVERWALTUNG             1120.00             1
WHOLE FOODS MARKET                271.69             3
AMAZON.COM*MFUHA4 AMZN.COM/BILL   236.12             1
COMCAST CABLE                     196.17             2
(5 rows)
```

### `budget --month YYYY-MM [--account NAME]`

Compares each budget category's spending in the month with its budget.
Requires `budget_file`. The exit code is **3** when any category is over
budget (handy in scripts); the table is printed either way.

```console
$ pqledger budget --month 2026-09
category   budget   spent  remaining  status
---------  ------  ------  ---------  ------
dining      60.00   17.78      42.22  ok
groceries  400.00  209.09     190.91  ok
shopping   150.00  236.12     -86.12  over
utilities  250.00  187.27      62.73  ok
(4 rows)
$ echo $?
3
```

### `list [filters] [--category C | --uncategorized]`

Transactions with their resolved category, by date then id.

```console
$ pqledger list --account visa --month 2026-09
id  date        account  description            amount  category
--  ----------  -------  --------------------  -------  -------------
23  2026-09-10  visa     Trader Joe's #5396     -40.42  groceries
24  2026-09-20  visa     Lyft Ride 7887         -20.13  uncategorized
25  2026-09-24  visa     Comcast Cable         -105.12  utilities
26  2026-09-27  visa     Spotify USA            -11.71  uncategorized
27  2026-09-30  visa     Starbucks Store 6283    -6.30  dining
28  2026-09-30  visa     Starbucks Store 6283     6.30  dining
(6 rows)
```

### `export [filters]`

Every column, by id — use `--format csv` to feed a spreadsheet.

```console
$ pqledger export --month 2026-09 --account giro
id  account  date        description           merchant                amount  category       batch
--  -------  ----------  --------------------  --------------------  --------  -------------  -----
29  giro     2026-09-01  Miete Hausverwaltung  MIETE HAUSVERWALTUNG  -1120.00  housing            3
30  giro     2026-09-12  Aral Tankstelle 5314  ARAL TANKSTELLE         -31.30  uncategorized      3
31  giro     2026-09-14  Aral Tankstelle 5314  ARAL TANKSTELLE          31.30  uncategorized      3
32  giro     2026-09-15  Gehalt ACME GmbH      GEHALT ACME GMBH       3810.55  income             3
33  giro     2026-09-16  Aral Tankstelle 6948  ARAL TANKSTELLE         -45.68  uncategorized      3
34  giro     2026-09-24  Stadtwerke München    STADTWERKE MüNCHEN      -82.15  utilities          3
35  giro     2026-09-24  DB Vertrieb GmbH      DB VERTRIEB GMBH       -137.38  uncategorized      3
(7 rows)
```

### `set-category ID CATEGORY` / `set-category ID --clear`

Overrides the category of one transaction (ids are shown by `list` and
`export`), or removes the override so the rules apply again.

```console
$ pqledger set-category 3 shopping
transaction 3: category shopping
$ pqledger set-category 3 --clear
transaction 3: category cleared
```

An unknown id is exit 6; an invalid category name exit 1.

### `query SQL`

Runs one SQL statement (PolyQuery SQL) on these tables; nothing is saved.

| table | columns |
|---|---|
| `transactions` | `id`, `account`, `date`, `description`, `merchant`, `amount` DECIMAL(18,2), `batch` |
| `batches` | `batch`, `account`, `file`, `imported`, `duplicates` |
| `overrides` | `id`, `category` |
| `ledger` | the `transactions` columns plus the resolved `category` |
| `rules` | `rule_no` (1, 2, … in file order), `category`, `pattern` (upper-cased) |
| `budgets` | `category`, `amount` DECIMAL(18,2) (empty without a budget file) |

```console
$ pqledger query "SELECT category, SUM(amount) AS total FROM ledger WHERE amount < 0 GROUP BY category ORDER BY total LIMIT 3"
category          total
-------------  --------
housing        -4820.00
uncategorized   -646.50
groceries       -312.11
(3 rows)
$ pqledger query "SELECT * FROM batches"
batch  account   file                  imported  duplicates
-----  --------  --------------------  --------  ----------
    1  checking  checking-2026-09.csv        17           0
    2  visa      visa-2026-09.csv            11           0
    3  giro      giro-2026-09.csv             7           0
    4  checking  checking-2026-09.csv         0          17
(4 rows)
$ pqledger query "SELECT nope FROM ledger"
pqledger: error: SEMANTIC_ERROR: unknown column 'nope'
```

SQL errors exit with 5 and show the engine's error code.

### `help`, `version`

`pqledger help` (or `--help`) prints a command summary; `pqledger version`
prints `pqledger 1.0.0 (PolyQuery AArch64 assembly engine, embedded)`.

## 7. Output formats

Choose with `--format` (before the command) or `[output] format`.

**table** (default) — aligned columns, numbers right-aligned, a `(N rows)`
footer; widths count Unicode characters.

**csv** — a header line and one line per row, comma-separated; fields with a
comma, quote, line break, or leading/trailing space (and empty strings) are
quoted with `"`, quotes doubled. NULL is an empty field.

```console
$ pqledger --format csv report monthly
month,income,expenses,net,transactions
2026-08,4250.00,2375.52,1874.48,13
2026-09,8334.27,3935.31,4398.96,22
```

**json** — JSON Lines, one object per row (no output for zero rows). Amounts,
dates and text are JSON strings (exact decimals); integers are numbers.

```console
$ pqledger --format json accounts
{"account":"checking","transactions":17,"balance":"4440.52","first":"2026-08-01","last":"2026-09-28"}
{"account":"giro","transactions":7,"balance":"2425.34","first":"2026-09-01","last":"2026-09-24"}
{"account":"visa","transactions":11,"balance":"-592.42","first":"2026-08-09","last":"2026-09-30"}
```

Value text: amounts with their decimals (`-12.50`), dates `YYYY-MM-DD`,
floating-point numbers (only from `query`) with 6 decimals, booleans
`true`/`false`, NULL empty (csv/table) or `null` (json).

## 8. Exit codes

| code | meaning |
|---|---|
| 0 | success |
| 1 | usage error (unknown command/option, bad value, missing argument) |
| 2 | configuration error (configuration, rules or budget file missing or invalid) |
| 3 | `budget`: at least one category is over budget (output printed normally) |
| 4 | import data error (bad record, missing column, unreadable file) — nothing imported |
| 5 | `query`: the engine reported an SQL error |
| 6 | ledger state error: no ledger yet, ledger already exists, unknown transaction id |
| 7 | any other error (I/O failure, unexpected engine error) |

On every error (all codes except 0 and 3) nothing is written to standard
output, the first line on standard error starts with `pqledger: error: `, and
the ledger is left unchanged.

## 9. Troubleshooting

| message | cause and fix |
|---|---|
| `cannot read configuration file pqledger.conf` (exit 2) | No configuration found: run in the directory holding `pqledger.conf`, or use `--config PATH` / `PQLEDGER_CONFIG` |
| `pqledger.conf:3: unknown key 'colour'` (exit 2) | Typo or key in the wrong section; the number is the line |
| `no ledger in /…/ledger (run 'pqledger init' first)` (exit 6) | `data_dir` has no `transactions.pqcf`: run `pqledger init`, or check `data_dir` (relative to the configuration file's directory) |
| `a ledger already exists in ledger` (exit 6) | `init` refuses to overwrite; nothing changed |
| `bad.csv:3: invalid date '2026-13-01'` (exit 4) | Wrong `date_format` for this account, or a broken record. Lines count physical lines including preamble and header |
| `bad.csv:2: expected 3 fields, found 4` (exit 4) | Unquoted decimal comma with a `,` delimiter, or the wrong `delimiter` |
| `invalid amount …` (exit 4) | Check `decimal_separator`, `thousands_separator` and `currency_symbol` for the account |
| `… column … not found` (exit 4) | A `*_column` name does not match the header (case is ignored, spaces trimmed); use a 1-based number if the header is unusual |
| `import requires --account NAME` (exit 1) | Every import names its account |
| `rules.conf:1: pattern '5%' contains '%' or '_'` (exit 2) | Use `*` and `?` as wildcards |
| `no budget_file configured` (exit 2) | `budget` needs `budget_file` in `[ledger]` |
| `SEMANTIC_ERROR: unknown column 'nope'` (exit 5) | An SQL error from `query`; see the table list above |
| Amounts of a card are all inverted | Set `invert_sign = true` for that account |
| A transaction landed in the wrong category | The first matching pattern wins — move the more specific rule up, or `set-category` it |
| A re-import added rows | The rows differ in date, amount or merchant (normalized description) from those already imported — compare with `pqledger export --format csv` |

Files in `data_dir`: `transactions.pqcf`, `batches.pqcf`, `overrides.pqcf`.
They are standard PQCF tables: back them up by copying the directory, and you
can inspect them with any PolyQuery engine, e.g.
`bin/polyquery` → `{"op":"open","table":"t","path":"transactions.pqcf"}`.
