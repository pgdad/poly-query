# pqledger — user guide

`pqledger` keeps a personal-finance ledger: it imports the CSV statement
exports of your bank accounts and cards, skips transactions it already has,
assigns categories with simple rules, and prints monthly reports, spending
by category and merchant, and budget checks. You can also query the ledger
with SQL.

The ledger is stored as PQCF files (the PolyQuery columnar format), so any
PolyQuery implementation can read and write it. pqledger runs the PolyQuery
engine **inside its own process** (through the embedding API, see
[EMBEDDING.md](EMBEDDING.md)): no server, no network connection.

Contents: [Installation](#1-installation) · [Quick start](#2-quick-start) ·
[Configuration](#3-configuration-reference) · [Rules](#4-the-rules-file) ·
[Budgets](#5-the-budget-file) · [Commands](#6-commands) ·
[Output formats](#7-output-formats) · [The ledger files](#8-the-ledger-files) ·
[Exit statuses](#9-exit-statuses) · [Troubleshooting](#10-troubleshooting)

## 1. Installation

Requirements: Linux (or another POSIX system) with CPython 3.14 as `python3`
on the `PATH`. Nothing else: pqledger uses only Python's standard library.

```sh
cd implementations/python
make build          # byte-compiles engine and application, checks the launchers
make test           # optional: unit tests of the engine, the library and pqledger
bin/pqledger version
```

`bin/pqledger` works from any directory and through symbolic links, so you
can put it on your `PATH`:

```sh
ln -s "$PWD/bin/pqledger" ~/.local/bin/pqledger
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
echo 'groceries = WHOLE FOODS*, SAFEWAY' > rules.conf
echo 'groceries = 600' > budgets.conf

pqledger init
pqledger import ~/Downloads/checking-2026-01.csv --account checking
pqledger report monthly
pqledger budget --month 2026-01
```

pqledger finds `pqledger.conf` in the current directory; see §3.1 for other
locations.

## 3. Configuration reference

### 3.1 Where the configuration file is

The first of these is used:

1. `--config PATH` (a global option, before the command);
2. the environment variable `PQLEDGER_CONFIG`, if it is set and not empty;
3. `pqledger.conf` in the current directory.

`PATH` and `PQLEDGER_CONFIG` may be relative to the current directory.
Relative paths **inside** the file (`data_dir`, `rules_file`, `budget_file`)
are relative to the directory of the configuration file, so a ledger can be
used from any working directory. A missing or unreadable file is a
configuration error (exit status 2). `help` and `version` need no
configuration.

### 3.2 Syntax

UTF-8 text (a leading byte-order mark is ignored), `\n` or `\r\n` line ends.
Leading and trailing spaces and tabs of a line are ignored. A line is

* empty, or a **comment** starting with `#` or `;`;
* a **section header** `[ledger]`, `[import]`, `[output]`, `[engine]` or
  `[account NAME]` (exactly one space before the account name);
* an **assignment** `KEY = VALUE`. Spaces around key and value are removed.
  To keep leading/trailing spaces or write an empty value, put the value in
  double quotes: `currency_symbol = " EUR"`; inside quotes `\"` is a quote
  and `\\` a backslash. There are no comments at the end of a line
  (`format = csv # x` sets the format to `csv # x`, which is invalid).

These are errors (exit status 2, the message names the line): an assignment
before the first section header, an unknown section or key, a key given
twice in one section, a section given twice, an invalid value.

### 3.3 `[ledger]` (required)

| key | value | default |
|---|---|---|
| `data_dir` | directory of the ledger files (created by `init`) | required |
| `rules_file` | the category rules file (§4) | none: everything is `uncategorized` unless overridden |
| `budget_file` | the budget file (§5); needed by `budget` | none |

### 3.4 `[import]` and `[account NAME]` — reading bank files

`[import]` sets how bank CSV files are read for all accounts; an
`[account NAME]` section overrides any of these keys for one account (an
account without a section uses `[import]`). Each value is taken from
`[account NAME]`, else from `[import]`, else the default.

| key | value | default |
|---|---|---|
| `delimiter` | one ASCII character, or `tab` | `,` |
| `header` | `true` or `false`: the first record is a header | `true` |
| `skip_lines` | number of lines to skip before the first record (a preamble) | `0` |
| `date_column` | column (see below) of the posting date | `Date` |
| `date_format` | `YYYY-MM-DD`, `YYYYMMDD`, `MM/DD/YYYY`, `DD/MM/YYYY` or `DD.MM.YYYY` | `YYYY-MM-DD` |
| `description_column` | column of the description | `Description` |
| `amount_mode` | `signed` (one amount column, negative = money out) or `debit_credit` (two columns) | `signed` |
| `amount_column` | column of the amount (`signed`) | `Amount` |
| `debit_column`, `credit_column` | columns of money out / money in (`debit_credit`) | `Debit`, `Credit` |
| `decimal_separator` | `.` or `,` | `.` |
| `thousands_separator` | `none`, `,`, `.`, `space` or `'` | `none` |
| `currency_symbol` | text removed from the start or end of amounts, e.g. `$` or `EUR` | empty |
| `invert_sign` | `true`: negate every amount (card exports that show charges as positive numbers) | `false` |

A **column** is either a 1-based position (`3`) or a header name
(`Transaction Date`), compared case-insensitively and ignoring spaces around
the header fields. Names need `header = true`. The decimal and thousands
separators must differ.

Account names consist of 1–32 characters `a-z`, `0-9`, `_`, `-`.

In `MM/DD/YYYY`, `DD/MM/YYYY` and `DD.MM.YYYY` the day and month may have one
or two digits (`3/7/2026`). Amounts may be written `-12.50`, `+12.50`,
`(12.50)` (negative), with the currency symbol before or after the number
(`$1,234.50`, `1.234,50 EUR`); after removing the symbol and the thousands
separators at most 16 integer digits and two decimals remain. In
`debit_credit` mode the amount is credit minus debit; one of the two may be
empty.

### 3.5 `[output]`

| key | value | default |
|---|---|---|
| `format` | `table`, `csv` or `json` (§7); `--format` overrides it | `table` |

### 3.6 `[engine]`

| key | value | default |
|---|---|---|
| `threads` | integer ≥ 1: parallelism of the engine's queries | engine default (automatic) |
| `memory_mb` | integer ≥ 1: memory limit of one query in MiB | engine default (4096) |

The engine always runs inside the pqledger process; parallel parts of a query
run one after the other in that process (no worker processes).

### 3.7 Complete example

```ini
# ~/finance/pqledger.conf
[ledger]
data_dir = ledger
rules_file = rules.conf
budget_file = budgets.conf

[import]
# defaults for all accounts (these are the built-in defaults anyway)
date_column = Date
description_column = Description
amount_column = Amount

[account card]
# "Transaction Date","Description","Amount" / 01/03/2026,"UBER *TRIP","$31.06"
date_column = Transaction Date
date_format = MM/DD/YYYY
currency_symbol = $
thousands_separator = ,
invert_sign = true

[account giro]
# Kontoumsätze Girokonto;;;        <- 2 preamble lines
# Zeitraum;;;
# Buchungstag;Verwendungszweck;Soll;Haben
# 01.01.2026;Miete Hausverwaltung;1.120,00;
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

[account savings]
# no header: date, text, amount by position
header = false
date_column = 1
description_column = 2
amount_column = 3
date_format = YYYYMMDD

[output]
format = table

[engine]
threads = 2
memory_mb = 1024
```

The `checking` account of the examples below has no section: it uses
`[import]` (`Date,Description,Amount`, ISO dates, signed amounts).

## 4. The rules file

Categories are assigned by patterns on the transaction's **merchant**, a
normalized form of the description: ASCII letters upper-cased, runs of spaces
and tabs collapsed to one space, and a trailing store number removed — a last
word that is `#` plus digits or at least three digits
(`Whole Foods Market #10234` → `WHOLE FOODS MARKET`, `Shell Oil 8395` →
`SHELL OIL`, but `7-Eleven 12` stays `7-ELEVEN 12`). `pqledger export` shows
the merchant of every transaction.

The rules file has the line syntax of §3.2 without sections; each rule line is

```
CATEGORY = PATTERN [, PATTERN ...]
```

```ini
# rules.conf — the first matching pattern wins (top to bottom, left to right)
groceries = WHOLE FOODS*, TRADER JOE*, SAFEWAY, REWE*, EDEKA*, LIDL*
coffee = SQ *BLUE BOTTLE*, STARBUCKS*, CAFé*
transport = SHELL*, CHEVRON*, UBER*, LYFT*, ARAL*, DB VERTRIEB*
housing = RENT*, MIETE*
income = PAYROLL*, GEHALT*
shopping = AMAZON*, HOME DEPOT, REI
utilities = PACIFIC GAS*, COMCAST*, STADTWERKE*, TELEKOM*
```

* A pattern must match the **whole** merchant: `*` matches any text (also
  none), `?` exactly one character, everything else itself, ignoring the case
  of ASCII letters (`é` and `É` differ). `SAFEWAY` matches only `SAFEWAY`;
  `SAFEWAY*` also `SAFEWAY STORE`.
* Patterns cannot contain `%` or `_` and cannot be empty; spaces around
  patterns are removed.
* Category names: 1–32 characters `a-z`, `0-9`, `_`, `-`; `uncategorized` is
  reserved. A category may appear on several lines.
* The category of a transaction is its manual override (`set-category`), else
  the category of the first matching pattern, else `uncategorized`.
* Rules are applied whenever a command runs, so editing the file
  re-categorizes all past transactions.

The file is read by every command except `init`, `help` and `version`; a
missing or invalid configured file is an error (exit status 2).

## 5. The budget file

Monthly budgets, one category per line:

```ini
# budgets.conf
groceries = 600
coffee = 30.00
transport = 200
shopping = 150.5
```

Amounts are non-negative numbers with up to 16 integer digits and up to two
decimals (`.` as decimal point, no thousands separators). A category may be
listed only once. The file is read by `budget` (which requires it) and
`query`.

## 6. Commands

```
pqledger [--config PATH] [--format table|csv|json] [--help] COMMAND [ARGUMENTS]
```

Global options come **before** the command. Options of a command come after
it, in any order, each followed by its value as a separate argument
(`--month 2026-01`). Repeating an option, an unknown command or option, a
missing or malformed value, or a surplus argument is a usage error (exit
status 1).

Filters accepted by `report …`, `list` and `export`:

| option | meaning |
|---|---|
| `--month YYYY-MM` | only transactions of that month |
| `--from YYYY-MM`, `--to YYYY-MM` | an inclusive range of months; either may be given alone |
| `--account NAME` | only transactions of that account |

`--month` cannot be combined with `--from`/`--to`, and `--from` must not be
later than `--to`.

The examples below use the configuration of §3.7, the rules of §4 and the
budgets of §5, with January/February 2026 statements of a checking account
(`chk.csv`), a credit card (`card.csv`) and a German giro account
(`giro.csv`).

### `init`

Creates `data_dir` (and missing parent directories) with an empty ledger.
Fails with exit status 6 if a ledger exists there already.

```
$ pqledger init
initialized ledger
```

### `import FILE --account NAME`

Imports a statement export (`FILE` relative to the current directory) into
account `NAME`, read with that account's settings (§3.4).

```
$ pqledger import chk.csv --account checking
batch 1: imported 24, duplicates 0
$ pqledger import card.csv --account card
batch 2: imported 17, duplicates 0
$ pqledger import giro.csv --account giro
batch 3: imported 22, duplicates 0
$ pqledger import chk.csv --account checking
batch 4: imported 0, duplicates 24
```

**Duplicates.** Statements overlap, so importing the same transaction twice
must not count it twice. Records are compared by account, date, amount and
merchant. If the file contains *f* records with the same values and the
ledger already has *l* such transactions, the last *f − l* of them (if any)
are imported and the others are counted as duplicates. So re-importing a file
adds nothing, an overlapping statement adds only the new days, and two
identical coffees on one day in one file are both kept.

Every import is recorded as a numbered **batch** (also when it adds nothing);
new transactions get the next ids. If any record of the file is invalid,
nothing is imported and the error names the file and line:

```
$ pqledger import bad.csv --account checking
pqledger: error: bad.csv:3: '2026-02-30' is not a valid date
```

### `accounts`

```
$ pqledger accounts
account   transactions   balance  first       last
--------  ------------  --------  ----------  ----------
card                17  -1021.83  2026-01-03  2026-02-26
checking            24   3572.29  2026-01-01  2026-02-27
giro                22   4559.99  2026-01-01  2026-02-26
(3 rows)
```

`balance` is the sum of the account's amounts, `first`/`last` its earliest
and latest date.

### `report monthly [FILTERS]`

Income (sum of positive amounts), expenses (money out, as a positive number),
net (sum of all amounts) and the number of transactions per month:

```
$ pqledger report monthly
month     income  expenses      net  transactions
-------  -------  --------  -------  ------------
2026-01  8175.76   4623.57  3552.19            32
2026-02  8120.33   4562.07  3558.26            31
(2 rows)
```

### `report categories [FILTERS]`

Money out per category, with its share of the total (in percent, rounded
half away from zero to one decimal), largest first:

```
$ pqledger report categories --month 2026-01
category         spent  share  transactions
-------------  -------  -----  ------------
housing        2970.00   64.2             2
transport       498.59   10.8            10
groceries       477.52   10.3             4
shopping        406.64    8.8             3
utilities       206.79    4.5             3
uncategorized    36.48    0.8             3
coffee           27.55    0.6             3
(7 rows)
```

### `report merchants [FILTERS] [--top N]`

The `N` merchants (default 10) with the most money out:

```
$ pqledger report merchants --top 5 --account card
merchant             spent  transactions
------------------  ------  ------------
HOME DEPOT          295.08             2
REI                 279.97             3
COMCAST CABLE       182.36             2
WHOLE FOODS MARKET  126.23             1
LYFT RIDE            39.49             2
(5 rows)
```

### `budget --month M [--account NAME]`

Compares each budget category's money out in month `M` with its budget. The
exit status is **3** if any category is over budget (the table is printed
either way), so scripts can react to it:

```
$ pqledger budget --month 2026-02
category   budget   spent  remaining  status
---------  ------  ------  ---------  ------
coffee      30.00   37.43      -7.43  over
groceries  600.00  350.33     249.67  ok
shopping   150.50  560.45    -409.95  over
transport  200.00  167.07      32.93  ok
(4 rows)
$ echo $?
3
```

### `list [FILTERS] [--category C | --uncategorized]`

Transactions ordered by date (then id), optionally only those of one
category:

```
$ pqledger list --account card --month 2026-01
id  date        account  description           amount  category
--  ----------  -------  -------------------  -------  ---------
25  2026-01-03  card     UBER   *TRIP Q5WS6F   -31.06  transport
26  2026-01-05  card     UBER   *TRIP Q5WS6F    31.06  transport
27  2026-01-06  card     Home Depot #3203     -248.23  shopping
28  2026-01-10  card     UBER   *TRIP UUX37L   -24.74  transport
29  2026-01-11  card     Café Mélange           -6.95  coffee
30  2026-01-16  card     Home Depot #4509      -46.85  shopping
31  2026-01-17  card     Lyft Ride 6767        -30.74  transport
32  2026-01-23  card     Comcast Cable         -97.62  utilities
33  2026-01-31  card     REI #8127            -111.56  shopping
(9 rows)
$ pqledger list --uncategorized --from 2026-02
id  date        account   description    amount  category
--  ----------  --------  -------------  ------  -------------
14  2026-02-03  checking  7-Eleven 12     -4.15  uncategorized
17  2026-02-11  checking  Chipotle 1517  -13.25  uncategorized
19  2026-02-17  checking  Chipotle 1131  -11.00  uncategorized
24  2026-02-27  checking  7-Eleven 12    -11.44  uncategorized
(4 rows)
```

### `export [FILTERS]`

All columns, ordered by id — best combined with `--format csv` for a
spreadsheet:

```
$ pqledger --format csv export --account giro --month 2026-02
id,account,date,description,merchant,amount,category,batch
53,giro,2026-02-01,Miete Hausverwaltung,MIETE HAUSVERWALTUNG,-1120.00,housing,3
54,giro,2026-02-03,Stadtwerke München,STADTWERKE MüNCHEN,-132.40,utilities,3
55,giro,2026-02-06,EDEKA Center 894,EDEKA CENTER,-48.38,groceries,3
56,giro,2026-02-06,EDEKA Center 7206,EDEKA CENTER,-61.26,groceries,3
57,giro,2026-02-12,Telekom Deutschland,TELEKOM DEUTSCHLAND,-46.50,utilities,3
58,giro,2026-02-13,Aral Tankstelle 8733,ARAL TANKSTELLE,-43.71,transport,3
59,giro,2026-02-15,Gehalt ACME GmbH,GEHALT ACME GMBH,3810.55,income,3
60,giro,2026-02-21,Telekom Deutschland,TELEKOM DEUTSCHLAND,-59.78,utilities,3
61,giro,2026-02-23,Telekom Deutschland,TELEKOM DEUTSCHLAND,59.78,utilities,3
62,giro,2026-02-24,Stadtwerke München,STADTWERKE MüNCHEN,-70.32,utilities,3
63,giro,2026-02-26,Telekom Deutschland,TELEKOM DEUTSCHLAND,-43.21,utilities,3
```

### `set-category ID CATEGORY` and `set-category ID --clear`

Overrides the category of one transaction (the `id` shown by `list`), or
removes the override so the rules apply again. Clearing a transaction without
an override is fine; an unknown id is an error (exit status 6).

```
$ pqledger set-category 3 gifts
transaction 3: category gifts
$ pqledger --format json list --category gifts
{"id":3,"date":"2026-01-02","account":"checking","description":"Trader Joe's #3614","amount":"-119.75","category":"gifts"}
$ pqledger set-category 3 --clear
transaction 3: category cleared
```

### `query SQL`

Runs one SQL statement (PolyQuery SQL, `spec/sql/`) on these tables; nothing
it does is saved:

| table | columns |
|---|---|
| `transactions` | `id`, `account`, `date`, `description`, `merchant`, `amount`, `batch` (§8) |
| `batches` | `batch`, `account`, `file`, `imported`, `duplicates` |
| `overrides` | `id`, `category` |
| `ledger` | the columns of `transactions` plus `category` (the resolved category) |
| `rules` | `rule_no` (1, 2, … in file order), `category`, `pattern` (upper-cased) |
| `budgets` | `category`, `amount` |

`date` is an SQL keyword: quote the column as `"date"` (`SELECT "date" FROM
ledger`). Remember to quote the statement for the shell.

```
$ pqledger query "SELECT category, COUNT(*) AS n, SUM(amount) AS total FROM ledger WHERE amount < 0 GROUP BY category ORDER BY total"
category        n     total
-------------  --  --------
housing         4  -5940.00
shopping        7   -967.09
groceries       8   -827.85
transport      15   -665.66
utilities       9   -643.74
uncategorized   7    -76.32
coffee          6    -64.98
(7 rows)
$ pqledger --format csv query "SELECT batch, account, file, imported, duplicates FROM batches ORDER BY batch"
batch,account,file,imported,duplicates
1,checking,chk.csv,24,0
2,card,card.csv,17,0
3,giro,giro.csv,22,0
4,checking,chk.csv,0,24
$ pqledger query "SELECT * FROM nowhere"
pqledger: error: SEMANTIC_ERROR: unknown table 'nowhere'
```

An SQL error exits with status 5; the message starts with the engine's error
code (`PARSE_ERROR`, `SEMANTIC_ERROR`, `TYPE_ERROR`, …).

### `help`, `version`

`pqledger help` (or `pqledger --help`) prints the command summary;
`pqledger version` prints `pqledger 1.0.0 (engine polyquery-python 0.4.0)`.

## 7. Output formats

Select with `--format` or `[output] format`.

* **`table`** (default): aligned columns, numbers right-aligned, a row count
  footer `(N rows)`. Meant for reading.
* **`csv`**: a header line and one line per row, comma-separated. Fields that
  are empty strings, contain a comma, a quote or a line break, or start or end
  with a space are quoted (`"Comma, Inc"`, quotes doubled). Empty unquoted
  fields are SQL NULLs (only possible in `query` results).
* **`json`**: JSON Lines, one object per row (`{"id":3,"amount":"-119.75",…}`),
  no output for zero rows. Amounts, dates and texts are JSON strings, so
  amounts keep their exact decimals; integer columns are JSON numbers.

Amounts always have two decimals (`-12.50`), dates are `YYYY-MM-DD`.

## 8. The ledger files

`data_dir` holds three PQCF files, the complete ledger:

| file | columns |
|---|---|
| `transactions.pqcf` | `id` INT64 (1, 2, … in import order), `account` STRING, `date` DATE, `description` STRING (as in the bank file, without surrounding spaces), `merchant` STRING (§4), `amount` DECIMAL(18,2) (negative = money out), `batch` INT64 |
| `batches.pqcf` | `batch` INT64, `account` STRING, `file` STRING (base name of the imported file), `imported` INT64, `duplicates` INT64 |
| `overrides.pqcf` | `id` INT64, `category` STRING (manual categories) |

Categories from rules are not stored; they are computed on every run. Every
change replaces a file atomically (write to a temporary file, then rename), and
a failing command changes nothing. Back up the ledger by copying `data_dir`.
The files can be opened by any PolyQuery engine (e.g. `bin/polyquery` with
the `open` operation) and by any other conforming pqledger implementation.

## 9. Exit statuses

| status | meaning |
|---|---|
| 0 | success |
| 1 | usage error (unknown command or option, missing or malformed argument) |
| 2 | configuration error: configuration, rules or budget file missing or invalid |
| 3 | `budget`: at least one category is over budget (the result is printed) |
| 4 | import data error: missing/unreadable file, invalid record, missing column |
| 5 | `query`: the engine rejected the SQL statement |
| 6 | ledger state: no ledger (run `init`), ledger already exists, unknown transaction id |
| 7 | any other error (I/O errors, unreadable ledger files, unexpected engine errors) |

On every error (statuses 1, 2, 4–7) nothing is written to standard output and
the first line on standard error starts with `pqledger: error: `.

## 10. Troubleshooting

| message / symptom | cause and remedy |
|---|---|
| `pqledger: error: configuration file /…/pqledger.conf does not exist` | run in the directory with `pqledger.conf`, or use `--config PATH` / `PQLEDGER_CONFIG` |
| `pqledger.conf:7: unknown key 'colour'` | a typo in a key, or a key in the wrong section (`[import]` keys are not valid in `[ledger]`) |
| `pqledger.conf:3: key 'data_dir' is repeated` / `section [account x] is repeated` | merge the duplicate lines or sections |
| `… names a header column but header = false` | with `header = false`, give columns by position (`date_column = 1`) |
| `no ledger in … (run 'pqledger init')` (status 6) | `data_dir` points to the wrong place, or `init` was not run |
| `chk.csv: the header has no column 'Date' (date_column)` | the export's header differs; set `date_column` (etc.) for the account, or use positions |
| `card.csv:5: invalid amount '$1.234,50'` | adjust `currency_symbol`, `decimal_separator`, `thousands_separator` of the account |
| `giro.csv:3: date '2026-01-04' does not match DD.MM.YYYY` | set the account's `date_format` |
| `giro.csv: the header has no column 'Buchungstag'` although the file has it | a preamble before the header (set `skip_lines`) or a wrong `delimiter` |
| `giro.csv:9: the record has 5 fields, expected 4` | a malformed record (often an unquoted delimiter inside a description); fix the line or the `delimiter` |
| an import says `imported 0, duplicates N` | the transactions are already in the ledger (same account, date, amount, merchant); nothing to do |
| a transaction has the wrong category | check its merchant with `export`; the first matching pattern wins, so put specific patterns first, or use `set-category` |
| `rules.conf:2: patterns must not contain '%' or '_'` | use `*` and `?` as wildcards |
| `query` fails with `PARSE_ERROR` near `date` | write the column as `"date"` |
| a `table` output looks garbled | descriptions may contain tabs or line breaks; use `--format csv` or `json` |
