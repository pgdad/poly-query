# pqledger — user guide

`pqledger` is a personal-finance ledger for the command line. It imports
the CSV statement exports of your bank accounts and credit cards, skips
the transactions it has already seen, assigns categories with simple
pattern rules, and prints monthly reports, spending by category or
merchant, and budget checks — as aligned tables, CSV or JSON Lines. You can
also query the ledger with SQL.

All data processing runs on the PolyQuery engine embedded in the program
(no server, no network). The ledger is a directory of three PQCF files
that every PolyQuery implementation can read.

Contents: [Building](#1-building-and-installing) ·
[Quick start](#2-quick-start) · [Configuration](#3-configuration-reference) ·
[Rules](#4-the-rules-file) · [Budgets](#5-the-budget-file) ·
[Commands](#6-commands) · [Output formats](#7-output-formats) ·
[The ledger files](#8-the-ledger-files) · [Exit status](#9-exit-status) ·
[Troubleshooting](#10-troubleshooting)

## 1. Building and installing

Requirements: Go 1.27 and `make` (a C compiler is optional). Nothing is
downloaded.

```bash
cd implementations/go
make build          # builds build/pqledger (and the engine, library and example)
make test           # runs all unit tests, including pqledger's
bin/pqledger help   # the launcher works from any directory
```

`bin/pqledger` is a small shell launcher that runs `build/pqledger`
(building it first if it is missing). To install, either put
`implementations/go/bin` on your `PATH`, or copy the self-contained
binary:

```bash
install -m 755 implementations/go/build/pqledger ~/.local/bin/pqledger
```

The source is in `app/` (`app/cmd/pqledger` is the entry point;
`app/internal/{cli,config,rules,bank,ledger,output}` are the parts).

## 2. Quick start

```bash
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
pqledger import ~/Downloads/checking.csv --account checking
pqledger report monthly
pqledger report categories --month 2026-10
pqledger budget --month 2026-10
```

Re-importing an overlapping statement is safe: transactions already in
the ledger are counted as duplicates and skipped.

## 3. Configuration reference

### 3.1 Where the configuration is read from

The first of these is used:

1. `--config PATH` (before the command: `pqledger --config ~/finance/pqledger.conf report monthly`);
2. the environment variable `PQLEDGER_CONFIG`, if set and not empty;
3. `pqledger.conf` in the current directory.

If that file does not exist or cannot be read, the command fails with exit
status 2. Relative paths given with `--config` or `PQLEDGER_CONFIG` are
relative to the current directory; relative paths **inside** the file
(`data_dir`, `rules_file`, `budget_file`) are relative to the directory
of the configuration file — so a configuration works from any directory.

`help` and `version` need no configuration.

### 3.2 Syntax

UTF-8 text, LF or CRLF line ends (a leading byte-order mark is ignored).
Leading and trailing spaces and tabs of each line are ignored. A line is:

* empty;
* a comment — first character `#` or `;` (comments must be on their own
  line; there are no end-of-line comments);
* a section header `[NAME]`;
* an assignment `KEY = VALUE` — key and value are trimmed. To keep
  leading/trailing spaces or to write an empty value, quote it:
  `currency_symbol = " EUR"`. Inside quotes, `\"` is `"` and `\\` is `\`.

Errors (exit status 2, the message names the file and line): an
assignment before the first section, an unknown section or key, a key
repeated in a section, a repeated section header, an invalid value.

### 3.3 Sections and keys

**`[ledger]`** (required)

| key | value | default |
|---|---|---|
| `data_dir` | the ledger directory (required) | — |
| `rules_file` | the category rules file (§4) | no rules: everything is `uncategorized` |
| `budget_file` | the budget file (§5) | none (`budget` then fails) |

**`[import]`** — how bank CSV files are read, for all accounts.
**`[account NAME]`** sections may set any of the same keys for one
account; the effective value is the `[account NAME]` value, else the
`[import]` value, else the default. An account needs no section if the
defaults (or `[import]`) fit its export.

| key | value | default |
|---|---|---|
| `delimiter` | one ASCII character, or `tab` | `,` |
| `header` | `true` \| `false` — the first record is a header | `true` |
| `skip_lines` | number of physical lines to skip before the first record (a preamble) | `0` |
| `date_column` | column reference (below) | `Date` |
| `date_format` | `YYYY-MM-DD`, `YYYYMMDD`, `MM/DD/YYYY`, `DD/MM/YYYY` or `DD.MM.YYYY` | `YYYY-MM-DD` |
| `description_column` | column reference | `Description` |
| `amount_mode` | `signed` (one amount column) or `debit_credit` (two columns) | `signed` |
| `amount_column` | column reference (`signed`) | `Amount` |
| `debit_column` | column reference (`debit_credit`): money out | `Debit` |
| `credit_column` | column reference (`debit_credit`): money in | `Credit` |
| `decimal_separator` | `.` or `,` | `.` |
| `thousands_separator` | `none`, `,`, `.`, `space` or `'` | `none` |
| `currency_symbol` | text removed from the start or end of amounts, e.g. `$`, `€`, `EUR` | empty |
| `invert_sign` | `true` \| `false` — negate every amount (card exports that list charges as positive) | `false` |

A **column reference** is either a 1-based column number (`3`) or a
header name, compared case-insensitively (ASCII) with the header fields
after trimming spaces and tabs. Names need `header = true`. The decimal
and thousands separators must differ.

In `MM/DD/YYYY`, `DD/MM/YYYY` and `DD.MM.YYYY` the day and month may have
one or two digits (`3/7/2026`); the year always has four.

**`[output]`**

| key | value | default |
|---|---|---|
| `format` | `table`, `csv` or `json` (overridden by `--format`) | `table` |

**`[engine]`**

| key | value | default |
|---|---|---|
| `threads` | worker threads per query (integer ≥ 1) | min(16, CPUs) |
| `memory_mb` | memory limit per query in MB (integer ≥ 1) | 4096 |

**Names.** Account and category names consist of 1–32 characters from
`a`–`z`, `0`–`9`, `_` and `-`. `uncategorized` is reserved.

### 3.4 Complete example

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

# US credit card: "Transaction Date","Description","Amount" with "$1,248.23",
# charges positive, refunds in parentheses.
[account visa]
date_column = Transaction Date
date_format = MM/DD/YYYY
currency_symbol = $
thousands_separator = ,
invert_sign = true

# German current account: 2-line preamble, ';', Soll/Haben columns, 1.120,00
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

[output]
format = table

[engine]
threads = 4
memory_mb = 1024
```

The examples in this guide use this configuration with these statements:

```
statements/checking-2026-09.csv    Date,Description,Amount
                                   2026-09-01,"RENT - OAKWOOD APTS",-1850.00 …
statements/visa-2026-10.csv        "Transaction Date","Description","Amount"
                                   10/02/2026,"Home Depot #3203","$1,248.23" …
statements/giro-2026-10.csv        Kontoumsätze Girokonto;;;
                                   Zeitraum: 01.10.2026 - 31.10.2026;;;
                                   Buchungstag;Verwendungszweck;Soll;Haben
                                   01.10.2026;Miete Hausverwaltung;1.120,00; …
```

The bank-statement generator `datasets/generators/bankgen.py` produces
realistic exports in these three styles; `--print-config` prints the
matching `[account]` keys.

### 3.5 How a statement is read

1. A leading byte-order mark is ignored; the first `skip_lines` lines are
   skipped.
2. The rest is CSV (RFC 4180): fields may be quoted with `"` (and then
   contain the delimiter, `""` for a quote, and line breaks); empty lines
   are ignored; every record must have as many fields as the header.
3. For each record: the **date** must be valid in `date_format`; the
   **description** is trimmed; the **amount** is converted like this:
   trim; `(12.50)` means −12.50, a leading `-` means negative, a leading
   `+` is dropped; the `currency_symbol` is removed from the start or end;
   thousands separators are removed; the decimal separator becomes `.`.
   The result must be digits with at most 2 decimals and at most 16
   integer digits. With `debit_credit` the amount is credit − debit (an
   empty field counts as 0, but not both). Then `invert_sign` applies.
4. Any bad record rejects the **whole file**: nothing is imported and the
   error names the file and line (`statements/bad.csv:2: invalid amount
   "-12.005"`).

**Merchant.** Each transaction also gets a normalized *merchant*, used by
rules, duplicate detection and `report merchants`: letters A–Z
upper-cased, runs of spaces/tabs collapsed, and a trailing store number
removed — a last word `#` + digits or of 3+ digits:
`Whole Foods Market #10234` → `WHOLE FOODS MARKET`,
`SQ *Blue  Bottle 4421` → `SQ *BLUE BOTTLE`, `7-Eleven 12` → `7-ELEVEN 12`.

**Duplicates.** Statements overlap. Transactions with the same account,
date, amount and merchant are "the same kind". If a file has *f* records
of a kind and the ledger already has *n*, the last max(0, *f* − *n*) of
them are imported and the others count as duplicates. Two genuinely
identical purchases on one day in one file are therefore both kept, and
importing the same file twice adds nothing.

## 4. The rules file

```ini
# CATEGORY = PATTERN, PATTERN, ...   (first match wins, in file order)
groceries = WHOLE FOODS*, TRADER JOE*, SAFEWAY, REWE*
coffee    = STARBUCKS*, SQ *BLUE BOTTLE*
transport = SHELL*, UBER*, DB VERTRIEB*
housing   = RENT*, MIETE*
income    = PAYROLL*, GEHALT*
```

* Same line syntax as the configuration, without sections.
* A pattern must match the **whole merchant**, ignoring ASCII case.
  `*` matches any characters (also none), `?` exactly one character;
  everything else matches itself. Patterns are trimmed, must not be
  empty and must not contain `%` or `_`.
* A transaction's category is: its **override** (`set-category`), else
  the category of the **first** pattern that matches (line order, then
  left to right), else `uncategorized`.
* A category may appear on several lines.
* Rules are applied at every command, so editing the file recategorizes
  past transactions too.

Patterns match the merchant, not the raw description: write `REWE*`, not
`REWE Markt 4412`. Use `pqledger list --uncategorized` to find what still
needs a rule, and `pqledger query "SELECT DISTINCT merchant FROM ledger
WHERE category = 'uncategorized'"` for the merchant texts.

## 5. The budget file

```ini
# CATEGORY = monthly budget
groceries = 400
coffee    = 25.00
transport = 150
```

One line per category: a non-negative amount with at most 2 decimals and
16 integer digits. A category listed twice is an error. The file is read
by `budget` and `query` only.

## 6. Commands

```
pqledger [--config PATH] [--format table|csv|json] COMMAND [ARGUMENTS] [OPTIONS]
```

Global options go before the command. Command options can be placed
anywhere after the command; each takes its value as the next argument
(`--month 2026-10`, not `--month=2026-10`). Repeating an option, an
unknown option or command, a missing or malformed value, or an extra
argument is a usage error (exit 1).

**Filters** accepted by `report …`, `list` and `export`:

| option | meaning |
|---|---|
| `--month YYYY-MM` | only that month |
| `--from YYYY-MM`, `--to YYYY-MM` | inclusive month range; either may be given alone |
| `--account NAME` | only that account |

`--month` cannot be combined with `--from`/`--to`, and `--from` must not
be later than `--to`.

All amounts are sums of `amount`; negative amounts are money out
(**outflows**), whose **spent** value is the positive total.

### `init`

Creates `data_dir` (and missing parent directories) with an empty ledger.

```
$ pqledger init
initialized ledger
```

Fails with exit 6 if a ledger exists there already (nothing is changed).

### `import FILE --account NAME`

Imports a statement (`FILE` relative to the current directory) for an
account, using the account's `[import]` settings, as one new **batch**.

```
$ pqledger import statements/checking-2026-09.csv --account checking
batch 1: imported 9, duplicates 0
$ pqledger import statements/checking-2026-10.csv --account checking
batch 2: imported 5, duplicates 1
$ pqledger import statements/visa-2026-10.csv --account visa
batch 3: imported 4, duplicates 0
$ pqledger import statements/giro-2026-10.csv --account giro
batch 4: imported 4, duplicates 0
$ pqledger import statements/giro-2026-10.csv --account giro
batch 5: imported 0, duplicates 4
```

New transactions get the ids following the largest id in the ledger, in
file order. A batch is recorded even if it imports nothing. A bad record
rejects the file (exit 4):

```
$ pqledger import statements/bad.csv --account checking
pqledger: error: statements/bad.csv:2: invalid amount "-12.005"
```

### `accounts`

Transactions, balance (sum of amounts) and first/last date per account.

```
$ pqledger accounts
account   transactions   balance  first       last
--------  ------------  --------  ----------  ----------
checking            14     66.99  2026-09-01  2026-10-12
giro                 4   2575.44  2026-10-01  2026-10-17
visa                 4  -1236.86  2026-10-02  2026-10-10
(3 rows)
```

### `report monthly [FILTERS]`

Per month: income (sum of positive amounts), expenses (spent of the
outflows), net (sum of all amounts) and the number of transactions.

```
$ pqledger report monthly
month     income  expenses      net  transactions
-------  -------  --------  -------  ------------
2026-09  4250.00   2227.34  2022.66             9
2026-10  3858.78   4475.87  -617.09            13
(2 rows)

$ pqledger report monthly --from 2026-10 --account checking
month    income  expenses       net  transactions
-------  ------  --------  --------  ------------
2026-10    0.00   1955.67  -1955.67             5
(1 row)
```

### `report categories [FILTERS]`

Outflows per category, largest first, with each category's share of the
total in percent (exact, rounded half away from zero to one decimal).

```
$ pqledger report categories --month 2026-10
category         spent  share  transactions
-------------  -------  -----  ------------
housing        2970.00   66.4             2
uncategorized  1248.23   27.9             1
transport       126.69    2.8             3
groceries       107.40    2.4             2
coffee           23.55    0.5             3
(5 rows)
```

### `report merchants [FILTERS] [--top N]`

The `N` merchants (default 10) with the largest outflows.

```
$ pqledger report merchants --top 5
merchant                spent  transactions
--------------------  -------  ------------
RENT - OAKWOOD APTS   3700.00             2
HOME DEPOT            1248.23             1
MIETE HAUSVERWALTUNG  1120.00             1
WHOLE FOODS MARKET     217.20             2
TRADER JOE'S            82.40             1
(5 rows)
```

### `budget --month YYYY-MM [--account NAME]`

Compares the month's outflows per category with the budget file: one row
per budgeted category, `remaining` = budget − spent, `status` `ok` or
`over`. Needs `budget_file` (else exit 2). **Exit status 3** if any
category is over budget (the table is printed either way), so scripts can
react:

```
$ pqledger budget --month 2026-10
category   budget   spent  remaining  status
---------  ------  ------  ---------  ------
coffee      20.00   23.55      -3.55  over
groceries  400.00  107.40     292.60  ok
transport  150.00  126.69      23.31  ok
(3 rows)
$ echo $?
3
$ pqledger --format json budget --month 2026-10 --account visa
{"category":"coffee","budget":"20.00","spent":"5.80","remaining":"14.20","status":"ok"}
{"category":"groceries","budget":"400.00","spent":"0.00","remaining":"400.00","status":"ok"}
{"category":"transport","budget":"150.00","spent":"31.06","remaining":"118.94","status":"ok"}
```

(This example used `coffee = 20.00` in the budget file.)

### `list [FILTERS] [--category C | --uncategorized]`

Transactions with their resolved category, ordered by date, then id.
`--category C` keeps one category, `--uncategorized` the transactions
without one.

```
$ pqledger list --category coffee
id  date        account   description                  amount  category
--  ----------  --------  ---------------------------  ------  --------
 3  2026-09-04  checking  Starbucks Store 4606          -6.25  coffee
 7  2026-09-19  checking  Starbucks Store 4606          -7.10  coffee
11  2026-10-03  checking  SQ *Blue Bottle Coffee 1750  -11.50  coffee
17  2026-10-07  visa      Starbucks Store 1201          -5.80  coffee
14  2026-10-12  checking  Starbucks Store 4606          -6.25  coffee
(5 rows)

$ pqledger list --month 2026-10 --uncategorized
id  date        account  description         amount  category
--  ----------  -------  ----------------  --------  -------------
15  2026-10-02  visa     Home Depot #3203  -1248.23  uncategorized
16  2026-10-05  visa     Home Depot #3203     48.23  uncategorized
(2 rows)
```

### `export [FILTERS]`

Every column of the transactions plus the category, ordered by id —
handy with `--format csv` for spreadsheets.

```
$ pqledger --format csv export --account giro
id,account,date,description,merchant,amount,category,batch
19,giro,2026-10-01,Miete Hausverwaltung,MIETE HAUSVERWALTUNG,-1120.00,housing,4
20,giro,2026-10-04,DB Vertrieb GmbH,DB VERTRIEB GMBH,-71.83,transport,4
21,giro,2026-10-15,Gehalt ACME GmbH,GEHALT ACME GMBH,3810.55,income,4
22,giro,2026-10-17,REWE Markt 4412,REWE MARKT,-43.28,groceries,4
```

### `set-category ID CATEGORY` / `set-category ID --clear`

Overrides the category of one transaction (the id from `list`), or
removes the override. Overrides win over rules.

```
$ pqledger set-category 15 shopping
transaction 15: category shopping
$ pqledger set-category 15 --clear
transaction 15: category cleared
```

An unknown id is exit 6; an invalid category name is exit 1. Clearing a
transaction that has no override succeeds.

### `query SQL`

Runs one SQL statement (PolyQuery SQL: `SELECT`, `WITH`, joins, `GROUP BY`,
`UNION ALL`, subqueries, …) on these tables:

| table | columns |
|---|---|
| `transactions` | `id`, `account`, `date`, `description`, `merchant`, `amount`, `batch` |
| `batches` | `batch`, `account`, `file`, `imported`, `duplicates` |
| `overrides` | `id`, `category` |
| `ledger` | the `transactions` columns plus the resolved `category` |
| `rules` | `rule_no`, `category`, `pattern` (upper-cased) |
| `budgets` | `category`, `amount` |

Nothing a query does is saved. The result keeps the engine's column names
and types.

```
$ pqledger query "SELECT category, COUNT(*) AS n, SUM(amount) AS total FROM ledger GROUP BY category ORDER BY total"
category       n     total
-------------  -  --------
housing        3  -4820.00
uncategorized  3  -1215.49
groceries      5   -407.00
transport      4   -175.59
coffee         5    -36.90
income         2   8060.55
(6 rows)

$ pqledger query "SELECT batch, file, imported, duplicates FROM batches ORDER BY batch"
batch  file                  imported  duplicates
-----  --------------------  --------  ----------
    1  checking-2026-09.csv         9           0
    2  checking-2026-10.csv         5           1
    3  visa-2026-10.csv             4           0
    4  giro-2026-10.csv             4           0
    5  giro-2026-10.csv             0           4
(5 rows)
```

`date`, `first` and `last` are SQL keywords: write them in double quotes,
`SELECT "date", amount FROM ledger WHERE "date" >= DATE '2026-10-01'`.
SQL errors are exit 5 with the engine's error code:

```
$ pqledger query "SELECT nope FROM ledger"
pqledger: error: SEMANTIC_ERROR: unknown column "nope"
```

### `help`, `version`

`pqledger help` (or `pqledger --help`) prints a usage summary;
`pqledger version` prints e.g. `pqledger 1.0.0 (PolyQuery engine 0.3.0, embedded)`.

## 7. Output formats

Choose with `--format` or `[output] format`.

* **`table`** (default): a header, a line of dashes, the rows and a
  `(N rows)` footer. Columns are as wide as their longest value (counted
  in characters); numbers are right-aligned, everything else left-aligned.
* **`csv`**: a header and one line per row, `,`-separated. A field is
  quoted (`"` doubled inside) when it is an empty string or contains `,`,
  `"` or a line break, or starts or ends with a space. NULL is an empty
  unquoted field.
* **`json`**: JSON Lines, one object per row (no output for zero rows):
  `{"id":17,"date":"2026-10-07","amount":"-5.80","category":"coffee"}`.
  Amounts and dates are strings (exact), counts and ids numbers.

Amounts always have two decimals (`-12.50`, `0.00`), dates are
`YYYY-MM-DD`.

## 8. The ledger files

`data_dir` holds three PQCF files — the only place the ledger lives:

| file | columns |
|---|---|
| `transactions.pqcf` | `id` INT64, `account` STRING, `date` DATE, `description` STRING, `merchant` STRING, `amount` DECIMAL(18,2), `batch` INT64 |
| `batches.pqcf` | `batch` INT64, `account` STRING, `file` STRING (base name), `imported` INT64, `duplicates` INT64 |
| `overrides.pqcf` | `id` INT64, `category` STRING |

They are written atomically (a new file is written and renamed over the
old one), so a failing command leaves the ledger unchanged. Any PolyQuery
engine can open them (`polyquery session` → `{"op":"open",…}`), and a
ledger written by another implementation's pqledger works here. Back up
the ledger by copying the directory.

## 9. Exit status

| status | meaning |
|---|---|
| 0 | success |
| 1 | usage error (unknown command or option, bad value, wrong arguments) |
| 2 | configuration error (configuration, rules or budget file missing or invalid) |
| 3 | `budget`: some category is over budget |
| 4 | import data error (unreadable file, missing column, bad record) |
| 5 | `query`: the SQL failed (the engine's error code is printed) |
| 6 | ledger state: no ledger yet, ledger already exists, unknown transaction id |
| 7 | other error (I/O, unexpected engine error) |

On failure (every status except 0 and 3) nothing is written to standard
output, and standard error starts with `pqledger: error: `.

## 10. Troubleshooting

| message / symptom | cause and fix |
|---|---|
| `pqledger.conf: cannot read configuration: no such file or directory` (exit 2) | No configuration found: run in the directory with `pqledger.conf`, pass `--config PATH`, or set `PQLEDGER_CONFIG`. |
| `pqledger.conf:7: unknown key "colour" in [ledger]` (exit 2) | Typo in a key or section name; the line number points to it. Keys of `[import]` are also the only keys allowed in `[account NAME]`. |
| `no ledger in … (run pqledger init)` (exit 6) | `data_dir` has no `transactions.pqcf`. Check `data_dir` (relative to the configuration file's directory) or run `pqledger init`. |
| `FILE:1: the header has no column "Date"` (exit 4) | The account's column settings do not match the export. Check `date_column`, `description_column`, `amount_column` (names are case-insensitive), `delimiter` and `skip_lines` (a preamble shifts the header). |
| `FILE:N: record has 5 fields, expected 4` | Wrong `delimiter`, or an unquoted delimiter inside a field. Note the line is the one the record **starts** on. |
| `FILE:N: invalid date "13/01/2026" (expected MM/DD/YYYY)` | Use the right `date_format` (`DD/MM/YYYY` here). |
| `FILE:N: invalid amount "1.234,56"` | Set `decimal_separator = ,` and `thousands_separator = .`; for `$` or `EUR` set `currency_symbol`. |
| Card charges appear as income | Set `invert_sign = true` for that account. |
| Everything is `uncategorized` | Patterns must match the **whole merchant** (normalized, upper-case, store number removed): use `STARBUCKS*`, not `Starbucks`. Check `pqledger query "SELECT DISTINCT merchant FROM ledger"`. |
| `PARSE_ERROR: expected string literal after DATE` (exit 5) | `date` is an SQL keyword: write `"date"`. |
| An import says `duplicates N` although the rows are new | They match existing transactions in account, date, amount and merchant. If they really are new, they can only be added by a statement that contains more of them than the ledger. |
| `budget needs budget_file in [ledger]` (exit 2) | Add `budget_file = budgets.conf` to `[ledger]`. |
| A query fails with `RESOURCE_LIMIT` | Raise `[engine] memory_mb`. |
