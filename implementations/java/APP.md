# pqledger — user guide

`pqledger` is a personal-finance command-line application. It imports the CSV exports of
your bank statements into a ledger, assigns categories with rules, and prints reports and
budget checks. It runs the PolyQuery engine **in-process** through the embedding API
(`polyquery.api`, see [EMBEDDING.md](EMBEDDING.md)). Every report is an SQL query on the
embedded engine. pqledger never starts another process and never opens a network
connection.

Contents: [Building](#building) · [Installation](#installation) ·
[Quick start](#quick-start) · [Command line](#command-line) ·
[Configuration](#configuration) · [Rules file](#rules-file) · [Budget file](#budget-file) ·
[Commands](#commands) · [Output formats](#output-formats) ·
[How import works](#how-import-works) · [Ledger storage](#ledger-storage) ·
[Exit codes](#exit-codes) · [Troubleshooting](#troubleshooting)

## Building

Requirements: **OpenJDK 27** (`java`, `javac` and `jar` on `PATH`, or `JAVA_HOME` set) and
`make`. There are no third-party libraries and the build needs no network access.

```sh
cd implementations/java
make build      # engine + library build/polyquery.jar, build/pqledger.jar,
                # build/pq-embed-demo.jar and the engine's AOT cache (~10 s)
make test       # also runs the engine's and pqledger's unit tests
```

| file | contents |
|---|---|
| `build/polyquery.jar` | the engine and the embedding API (module `polyquery`) |
| `build/pqledger.jar` | the application (module `pqledger`, which `requires polyquery`) |
| `bin/pqledger` | the launcher |

The application's source code is in `app/src/main/java/pqledger/`. Its unit tests are in
`app/src/test/java/`.

## Installation

`bin/pqledger` is a POSIX shell script. It works from any working directory. It finds its
own location (following symbolic links with `readlink -f`) and runs

```
java <JVM options> --module-path build/polyquery.jar:build/pqledger.jar -m pqledger/pqledger.Main ARGS…
```

Pick one of these ways to put it on your `PATH`:

```sh
# a symbolic link (the launcher follows it back to the build directory)
ln -s "$PWD/bin/pqledger" ~/.local/bin/pqledger

# or the whole bin directory (this also exposes bin/polyquery and bin/pq-embed-demo)
export PATH="$PWD/bin:$PATH"
```

Do not **copy** the script somewhere else. It looks for `../build/*.jar` relative to its
own real location. The build directory must stay in place, and after `make clean` you have
to rebuild.

The launcher's environment:

| variable | effect |
|---|---|
| `JAVA_HOME` | if `$JAVA_HOME/bin/java` is executable, it is used; otherwise `java` from `PATH` |
| `PQLEDGER_JAVA_OPTS` | extra JVM options, e.g. `-Xmx8g` |
| `PQLEDGER_CONFIG` | the configuration file (see [Locating the file](#locating-the-file)) |

The JVM options come from `bin/jvm-options`, which `bin/polyquery` also uses:
`-XX:+UseParallelGC -XX:-UsePerfData -Xlog:disable`. On machines with at least 16 GiB of
memory they also include `-Xms4g -Xmn2g`. The launcher also adds `-Xshare:auto`. The program
parses and runs its SQL on a thread with a 512 MiB stack, so no `-Xss` is needed.

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

The examples in this guide were produced by running pqledger in a directory with the
[example configuration](#example-configuration), [rules file](#rules-file) and
[budget file](#budget-file) shown below. The statements came from
`datasets/generators/bankgen.py` (styles `us-checking`, `us-card` and `de-giro`, months
2026-08 to 2026-09, `--per-month 8`).

## Command line

```
pqledger [GLOBAL OPTIONS] COMMAND [COMMAND ARGUMENTS AND OPTIONS]
```

Global options must come **before** the command:

| option | meaning |
|---|---|
| `--config PATH` | the configuration file (overrides `PQLEDGER_CONFIG` and `./pqledger.conf`) |
| `--format table\|csv\|json` | the output format; overrides `[output] format` |
| `--help` | same as `pqledger help` |

Rules for arguments:

* An option is an argument of the form `--name`. Every option except the flags
  `--uncategorized` and `--clear` takes its value from the **next** argument
  (`--month 2026-09`). The form `--month=2026-09` is not supported. It is treated as a
  surplus positional argument, which is a usage error.
* A command's options may appear in any order before, between or after its positional
  arguments.
* Each of these is a usage error (exit 1): an unknown command or option, a repeated option, a
  missing or malformed value, or a surplus argument.

**Filter options.** These are accepted by `report monthly`, `report categories`,
`report merchants`, `list` and `export`:

| option | value | meaning |
|---|---|---|
| `--month M` | `YYYY-MM` | only transactions dated in month M |
| `--from M` | `YYYY-MM` | only transactions from month M on (inclusive) |
| `--to M` | `YYYY-MM` | only transactions up to the end of month M (inclusive) |
| `--account NAME` | account name | only transactions of that account |

`--from` and `--to` may each be given alone. You cannot combine `--month` with `--from` or
`--to`. A month must have month 01–12 and year 0001–9999. A `--from` later than `--to` is
a usage error.

## Configuration

### Locating the file

pqledger uses the first of these that applies:

1. `--config PATH`;
2. the environment variable `PQLEDGER_CONFIG`, if it is set and not empty;
3. `pqledger.conf` in the current directory.

If the chosen file does not exist or cannot be read, that is a configuration error
(exit 2). The configuration file is not needed by `help` and `version`.

Relative paths are resolved as follows:

* `--config` and `PQLEDGER_CONFIG` are resolved against the **current directory**.
* `data_dir`, `rules_file` and `budget_file` are resolved against the **directory of the
  configuration file**. So `pqledger --config ~/finance/pqledger.conf …` works from
  anywhere.
* The `FILE` of `import` is resolved against the current directory.

### Syntax

The file is UTF-8 text. Lines may end with `\n` or `\r\n`, and a leading byte-order mark is
ignored. Leading and trailing spaces and tabs are removed from each line, which is then one
of:

* empty;
* a comment, starting with `#` or `;`;
* a section header: `[ledger]`, `[import]`, `[output]`, `[engine]` or `[account NAME]`
  (exactly one space before the account name);
* an assignment `KEY = VALUE`. The key is the text before the first `=` and the value the
  text after it, both trimmed. If the value starts and ends with `"`, the quotes are removed,
  and inside them `\"` stands for `"` and `\\` for `\`. Use quotes for an empty value or for
  one with leading or trailing spaces, e.g. `currency_symbol = " EUR"`.

There are **no inline comments**. In `currency_symbol = $  # dollars`, the value is
`$  # dollars`.

Each of these is a configuration error (exit 2), and the message names the file and line:
an assignment before the first section header, an unknown section, an unknown key, a key
repeated in one section, a repeated section header, an invalid account name or an invalid
value.

**Names.** An account name matches `[a-z0-9_-]{1,32}`. A category name matches
`[a-z0-9_-]{1,32}` and is not `uncategorized`.

### `[ledger]` (required)

| key | value | default |
|---|---|---|
| `data_dir` | directory of the ledger; **required** | — |
| `rules_file` | the [rules file](#rules-file) | none: every transaction is `uncategorized` unless overridden |
| `budget_file` | the [budget file](#budget-file) | none (`budget` then fails with exit 2) |

### `[import]` and `[account NAME]`

`[import]` describes how bank CSV files are read. An `[account NAME]` section may override
any of these keys for one account. For each key, the value used for an account is the
`[account NAME]` value, else the `[import]` value, else the default. You can import into an
account that has no `[account]` section; it uses the `[import]` settings.

| key | value | default |
|---|---|---|
| `delimiter` | one ASCII character other than `"`, or `tab` | `,` |
| `header` | `true` \| `false`: the first record is a header | `true` |
| `skip_lines` | integer ≥ 0: physical lines skipped before the first record (a preamble) | `0` |
| `date_column` | column reference | `Date` |
| `date_format` | `YYYY-MM-DD`, `YYYYMMDD`, `MM/DD/YYYY`, `DD/MM/YYYY` or `DD.MM.YYYY` | `YYYY-MM-DD` |
| `description_column` | column reference | `Description` |
| `amount_mode` | `signed` (one amount column) \| `debit_credit` (two columns) | `signed` |
| `amount_column` | column reference (used by `signed`) | `Amount` |
| `debit_column` | column reference (used by `debit_credit`) | `Debit` |
| `credit_column` | column reference (used by `debit_credit`) | `Credit` |
| `decimal_separator` | `.` \| `,` | `.` |
| `thousands_separator` | `none`, `,`, `.`, `space` or `'` | `none` |
| `currency_symbol` | text removed from the start or end of amounts | empty |
| `invert_sign` | `true` \| `false`: negate every amount (card exports where charges are positive) | `false` |

A **column reference** is either:

* a positive integer: the 1-based column position; or
* a header name. It is compared with the header fields after trimming, ASCII
  case-insensitively. A name needs `header = true`; otherwise `import` reports a
  configuration error (exit 2).

`decimal_separator` and `thousands_separator` must differ.

In `MM/DD/YYYY`, `DD/MM/YYYY` and `DD.MM.YYYY`, the month and day may have one or two digits.

### `[output]`

| key | value | default |
|---|---|---|
| `format` | `table`, `csv` or `json` | `table` |

The global option `--format` overrides it.

### `[engine]`

| key | value | default |
|---|---|---|
| `threads` | integer ≥ 1: worker threads per query (values above 1024 are treated as 1024) | the number of processors |
| `memory_mb` | integer ≥ 1: per-query memory limit in MiB | 4096 |

The engine caps the effective memory limit at 70 % of the JVM's maximum heap. The JVM's
default heap is ¼ of physical memory; raise it with `PQLEDGER_JAVA_OPTS=-Xmx…`.

### Example configuration

This example sets every section and key. It is the configuration used for all the examples
in this guide. Comments must be on their own lines, because pqledger has no inline
comments.

```ini
# pqledger.conf
[ledger]
# relative paths are relative to this file's directory
data_dir = ledger
rules_file = rules.conf
budget_file = budgets.conf

# Defaults for every account. All values below are the built-in defaults,
# written out; account "checking" has no section of its own and uses these.
[import]
delimiter = ,
header = true
skip_lines = 0
date_column = Date
date_format = YYYY-MM-DD
description_column = Description
amount_mode = signed
amount_column = Amount
debit_column = Debit
credit_column = Credit
decimal_separator = .
thousands_separator = none
currency_symbol = ""
invert_sign = false

[output]
# the default
format = table

[engine]
threads = 4
memory_mb = 2048

# US credit card: "Transaction Date","Description","Amount" with "$1,234.56",
# charges positive, refunds as ($360.66)
[account visa]
date_column = Transaction Date
date_format = MM/DD/YYYY
currency_symbol = $
thousands_separator = ,
invert_sign = true

# German current account: 2 preamble lines, ';', Soll/Haben, 1.120,00
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

# tab-separated export without a header: date, amount, description
[account savings]
delimiter = tab
header = false
date_column = 1
date_format = YYYYMMDD
description_column = 3
amount_column = 2
```

`datasets/generators/bankgen.py --style STYLE --from M --to M --print-config` prints the
`[account]` keys that match each generated statement style.

## Rules file

The rules file assigns categories to transactions by their **merchant** (the normalized
description, see [Merchant normalization](#merchant-normalization)). It uses the same line
syntax as the configuration, without sections: blank lines, comments, and lines

```
CATEGORY = PATTERN [, PATTERN …]
```

* Patterns are separated by `,` and trimmed. A pattern must not be empty and must not
  contain `%` or `_`.
* `*` matches any sequence of characters (including none), `?` matches exactly one
  character, and every other character matches itself, ASCII case-insensitively.
* A pattern must match the **whole** merchant. Use `WHOLE FOODS*`, not `WHOLE FOODS`, to
  match `WHOLE FOODS MARKET`.
* A category may appear on several lines.

**Category resolution.** A transaction's category is chosen in this order:

1. its override, if one was set with [`set-category`](#set-category);
2. the category of the **first** pattern that matches its merchant, in file order (line
   order, then order within the line);
3. `uncategorized`.

The rules file is read on every invocation, by every command except `init`, `help` and
`version`. Editing it recategorizes all past transactions. A configured rules file that is
missing or invalid causes exit 2.

**Non-ASCII letters.** Only ASCII letters are case-folded. In merchants, `Café` becomes
`CAFé`. Write non-ASCII letters in the same case the bank uses (`café *`), or replace them
with `?` (`B?CKEREI*`). The pattern `CAFÉ*` does **not** match `CAFé MéLANGE`.

The rules file used for the examples:

```ini
# CATEGORY = PATTERN, PATTERN, ...
housing   = RENT - *, MIETE *
groceries = WHOLE FOODS*, REWE *, LIDL *
transport = UBER *TRIP*, LYFT RIDE*, ARAL *, DB VERTRIEB*
dining    = SQ *BLUE BOTTLE*, STARBUCKS*, CHIPOTLE*, café *, B?CKEREI*
utilities = PACIFIC GAS*, COMCAST*, TELEKOM*
subscriptions = NETFLIX.COM, SPOTIFY*
income    = PAYROLL *, GEHALT *
```

Error examples (exit 2):

```
pqledger: error: /tmp/appdoc/bad/r1.conf:1: pattern 'Coffee_Shop' contains '%' or '_'
pqledger: error: cannot read rules file /tmp/appdoc/bad/rules.conf: no such file
```

## Budget file

The budget file sets a monthly budget per category. It uses the same line syntax, with
lines `CATEGORY = AMOUNT`:

* `AMOUNT` matches `[0-9]+(\.[0-9]{1,2})?` and has at most 16 integer digits (no sign, no
  thousands separator).
* Listing a category twice is a configuration error (exit 2).

The budget file is read only by `budget` and `query`.

```ini
# CATEGORY = monthly budget
groceries = 300
dining = 50.00
transport = 120
housing = 3000
```

```
pqledger: error: /tmp/appdoc/bad/b.conf:2: category 'dining' already has a budget (line 1)
```

## Commands

Every command except `init`, `help` and `version` needs an existing ledger (exit 6
otherwise). Each section below shows the command's options and real output.

### `init`

```
pqledger init
```

Creates `data_dir` (with any missing parents) and the three ledger tables, with no rows.
Fails with exit 6 if `transactions.pqcf` already exists; in that case nothing changes.

```
$ pqledger init
initialized ledger
$ pqledger init
pqledger: error: a ledger already exists in /tmp/appdoc/ledger
```

### `import`

```
pqledger import FILE --account NAME
```

Imports a bank CSV export into account `NAME` (`--account` is required) using the
account's import settings. Duplicates are skipped, see
[Duplicate detection](#duplicate-detection). Each import is recorded as a batch, even if it
adds nothing. If any record is invalid, nothing is imported and no batch is recorded
(exit 4).

```
$ pqledger import statements/us-checking.csv --account checking
batch 1: imported 21, duplicates 0
$ pqledger import statements/us-card.csv --account visa
batch 2: imported 17, duplicates 0
$ pqledger import statements/de-giro.csv --account giro
batch 3: imported 22, duplicates 0
$ pqledger import statements/us-checking.csv --account checking
batch 4: imported 0, duplicates 21
$ pqledger import statements/checking-overlap.csv --account checking
batch 5: imported 1, duplicates 2
```

### `accounts`

```
pqledger accounts
```

Columns: `account` STRING, `transactions` INT64, `balance` DECIMAL(18,2) (the sum of the
amounts), and `first` and `last` DATE. There is one row per account that has transactions,
ordered by account. This command takes no options.

```
$ pqledger accounts
account   transactions  balance  first       last
--------  ------------  -------  ----------  ----------
checking            22  4083.04  2026-08-01  2026-09-30
giro                22  4641.01  2026-08-01  2026-09-26
visa                17  -685.67  2026-08-02  2026-09-19
(3 rows)
```

### `report monthly`

```
pqledger report monthly [--month M | --from M --to M] [--account NAME]
```

Columns:

* `month` (`YYYY-MM`);
* `income`: the sum of positive amounts;
* `expenses`: money out, as a positive number;
* `net`: the sum of all amounts;
* `transactions`.

There is one row per month that has transactions, ordered by month.

```
$ pqledger report monthly
month     income  expenses      net  transactions
-------  -------  --------  -------  ------------
2026-08  8172.23   4161.33  4010.90            30
2026-09  8475.86   4448.38  4027.48            31
(2 rows)
$ pqledger report monthly --account giro
month     income  expenses      net  transactions
-------  -------  --------  -------  ------------
2026-08  3828.13   1491.50  2336.63            11
2026-09  3865.20   1560.82  2304.38            11
(2 rows)
```

### `report categories`

```
pqledger report categories [FILTERS]
```

Counts outflows only (`amount < 0`). Columns:

* `category`;
* `spent`: the negated sum, ≥ 0;
* `share`: `100 × spent ÷ total spent`, exact, rounded half away from zero to one decimal;
* `transactions`.

Rows are ordered by `spent` descending, then by category.

```
$ pqledger report categories
category         spent  share  transactions
-------------  -------  -----  ------------
housing        5940.00   69.0             4
uncategorized  1240.75   14.4            12
groceries       450.93    5.2             8
transport       423.22    4.9            13
utilities       400.80    4.7             4
dining          100.66    1.2             8
subscriptions    53.35    0.6             4
(7 rows)
$ pqledger report categories --month 2026-09 --account checking
category         spent  share  transactions
-------------  -------  -----  ------------
housing        1850.00   76.1             1
uncategorized   341.53   14.0             3
groceries       168.67    6.9             2
transport        59.48    2.4             3
dining           11.48    0.5             1
(5 rows)
```

### `report merchants`

```
pqledger report merchants [FILTERS] [--top N]
```

Counts outflows only. Columns: `merchant`, `spent`, `transactions`. Rows are ordered by
`spent` descending, then by merchant, and limited to the first `N` (N ≥ 1, default 10).

```
$ pqledger report merchants --top 5
merchant                           spent  transactions
-------------------------------  -------  ------------
RENT - OAKWOOD APTS              3700.00             2
MIETE HAUSVERWALTUNG             2240.00             2
HOME DEPOT                        469.89             2
AMAZON.COM*MFUHA4 AMZN.COM/BILL   236.12             1
PACIFIC GAS & ELECTRIC            215.06             1
(5 rows)
```

### `budget`

```
pqledger budget --month M [--account NAME]
```

Needs a `budget_file` (exit 2 otherwise) and `--month`. Columns:

* `category`;
* `budget`;
* `spent`: the outflows of the month with that category;
* `remaining`: `budget − spent`;
* `status`: `ok` if `spent ≤ budget`, else `over`.

There is one row per category in the budget file, ordered by category. The table is always
printed in full. The exit status is **3** if any category is `over`, which makes the
command easy to use in scripts.

```
$ pqledger budget --month 2026-09
category    budget    spent  remaining  status
---------  -------  -------  ---------  ------
dining       50.00    70.29     -20.29  over
groceries   300.00   382.87     -82.87  over
housing    3000.00  2970.00      30.00  ok
transport   120.00   102.32      17.68  ok
(4 rows)
$ echo $?
3
```

### `list`

```
pqledger list [FILTERS] [--category C | --uncategorized]
```

Columns: `id`, `date`, `account`, `description`, `amount`, `category`. There is one row per
transaction, ordered by date, then id.

* `--category C` keeps only transactions whose resolved category is `C`.
* `--uncategorized` keeps only transactions with category `uncategorized`.
* The two options cannot be combined.

```
$ pqledger list --month 2026-09 --account visa
id  date        account  description            amount  category
--  ----------  -------  --------------------  -------  -------------
30  2026-09-01  visa     Lyft Ride 918          -10.11  transport
31  2026-09-01  visa     Lyft Ride 8105         -17.50  transport
32  2026-09-08  visa     Home Depot #1361      -360.66  uncategorized
33  2026-09-10  visa     Starbucks Store 5674    -5.91  dining
34  2026-09-10  visa     Home Depot #1361       360.66  uncategorized
35  2026-09-15  visa     Chipotle 1923          -11.97  dining
36  2026-09-16  visa     Café Mélange           -22.08  dining
37  2026-09-17  visa     7-Eleven 12            -12.94  uncategorized
38  2026-09-19  visa     UBER   *TRIP SMME6Z    -15.23  transport
(9 rows)
$ pqledger list --uncategorized --from 2026-09
id  date        account   description                       amount  category
--  ----------  --------  -------------------------------  -------  -------------
32  2026-09-08  visa      Home Depot #1361                 -360.66  uncategorized
34  2026-09-10  visa      Home Depot #1361                  360.66  uncategorized
18  2026-09-15  checking  CVS/PHARMACY #6852                -41.23  uncategorized
37  2026-09-17  visa      7-Eleven 12                       -12.94  uncategorized
59  2026-09-25  giro      Stadtwerke München               -152.43  uncategorized
21  2026-09-26  checking  AMAZON.COM*MFUHA4 AMZN.COM/BILL  -236.12  uncategorized
61  2026-09-30  checking  Trader Joe's #552                 -64.18  uncategorized
(7 rows)
```

`list --uncategorized` is the fastest way to find what your rules still miss.

### `export`

```
pqledger export [FILTERS]
```

Every column of the matching transactions, ordered by id: `id`, `account`, `date`,
`description`, `merchant`, `amount`, `category` (resolved), `batch`. It is most useful with
`--format csv`.

```
$ pqledger export --from 2026-09 --account giro
id  account  date        description               merchant                amount  category       batch
--  -------  ----------  ------------------------  --------------------  --------  -------------  -----
50  giro     2026-09-01  Miete Hausverwaltung      MIETE HAUSVERWALTUNG  -1120.00  housing            3
51  giro     2026-09-08  REWE Markt GmbH 4364      REWE MARKT GMBH         -40.45  groceries          3
52  giro     2026-09-11  Telekom Deutschland       TELEKOM DEUTSCHLAND     -55.34  utilities          3
53  giro     2026-09-15  Gehalt ACME GmbH          GEHALT ACME GMBH       3810.55  income             3
54  giro     2026-09-18  Bäckerei Schäfer          BäCKEREI SCHäFER         -8.44  dining             3
55  giro     2026-09-19  REWE Markt GmbH 1255      REWE MARKT GMBH         -52.30  groceries          3
56  giro     2026-09-19  Lidl Dienstleistung 2791  LIDL DIENSTLEISTUNG     -66.80  groceries          3
57  giro     2026-09-23  Bäckerei Schäfer          BäCKEREI SCHäFER        -10.41  dining             3
58  giro     2026-09-24  Lidl Dienstleistung 6571  LIDL DIENSTLEISTUNG     -54.65  groceries          3
59  giro     2026-09-25  Stadtwerke München        STADTWERKE MüNCHEN     -152.43  uncategorized      3
60  giro     2026-09-26  Lidl Dienstleistung 6571  LIDL DIENSTLEISTUNG      54.65  groceries          3
(11 rows)
```

### `set-category`

```
pqledger set-category ID CATEGORY
pqledger set-category ID --clear
```

Sets or removes the category override of transaction `ID`, a positive integer as shown by
`list`. An override takes precedence over all rules.

* An unknown id is exit 6.
* An invalid category name (including `uncategorized`) is exit 1.
* Clearing a transaction that has no override succeeds.

```
$ pqledger set-category 21 shopping
transaction 21: category shopping
$ pqledger list --category shopping
id  date        account   description                       amount  category
--  ----------  --------  -------------------------------  -------  --------
21  2026-09-26  checking  AMAZON.COM*MFUHA4 AMZN.COM/BILL  -236.12  shopping
(1 row)
$ pqledger set-category 21 --clear
transaction 21: category cleared
$ pqledger set-category 999 shopping
pqledger: error: no transaction with id 999
$ pqledger set-category 21 Shopping
pqledger: error: invalid category name 'Shopping' (expected [a-z0-9_-]{1,32}, not 'uncategorized')
```

### `query`

```
pqledger query SQL
```

Runs one SQL statement on the embedded engine and prints the result with the engine's
column names and types. These tables are loaded:

| table | columns |
|---|---|
| `transactions` | `id`, `account`, `date`, `description`, `merchant`, `amount`, `batch` |
| `batches` | `batch`, `account`, `file`, `imported`, `duplicates` |
| `overrides` | `id`, `category` |
| `ledger` | the `transactions` columns followed by the resolved `category` |
| `rules` | `rule_no` (1, 2, … in file order), `category`, `pattern` (as written, upper-cased) |
| `budgets` | `category`, `amount` (empty without a `budget_file`) |

Nothing the query does is saved. `CREATE INDEX` only lasts for the one invocation. Quote
the SQL for your shell. An engine error is exit 5, with the engine's error code on stderr.

```
$ pqledger query "SELECT category, COUNT(*) AS n, SUM(amount) AS total FROM ledger GROUP BY category ORDER BY category"
category        n     total
-------------  --  --------
dining          8   -100.66
groceries      10   -378.70
housing         4  -5940.00
income          4  16121.10
subscriptions   4    -53.35
transport      13   -423.22
uncategorized  14   -785.99
utilities       4   -400.80
(8 rows)
$ pqledger query "SELECT * FROM batches"
batch  account   file                  imported  duplicates
-----  --------  --------------------  --------  ----------
    1  checking  us-checking.csv             21           0
    2  visa      us-card.csv                 17           0
    3  giro      de-giro.csv                 22           0
    4  checking  us-checking.csv              0          21
    5  checking  checking-overlap.csv         1           2
(5 rows)
$ pqledger query "SELECT * FROM rules WHERE category = 'dining'"
rule_no  category  pattern
-------  --------  ----------------
     10  dining    SQ *BLUE BOTTLE*
     11  dining    STARBUCKS*
     12  dining    CHIPOTLE*
     13  dining    CAFé *
     14  dining    B?CKEREI*
(5 rows)
$ pqledger query "SELECT nope FROM ledger"
pqledger: error: SEMANTIC_ERROR: unknown column 'nope'
$ echo $?
5
```

Column names such as `date`, `first` and `last` are SQL keywords. Write them in double
quotes when you need to (`SELECT "date" FROM transactions`).

### `help` and `version`

`pqledger help` and `pqledger --help` print the usage summary. `pqledger version` prints the
version. Both exit 0 and need no configuration file.

```
$ pqledger version
pqledger 1.0.0 (application spec 1.0.0, PolyQuery Java engine)
$ pqledger help
usage: pqledger [--config PATH] [--format table|csv|json] COMMAND [ARGUMENTS]

Personal-finance ledger: imports bank-statement CSV exports, assigns categories with
rules and prints reports and budget checks. See APP.md for the full guide.

commands:
  init                                  create an empty ledger in data_dir
  import FILE --account NAME            import a bank CSV export (duplicates are skipped)
  report monthly [FILTERS]              income, expenses and net per month
  …
```

## Output formats

Reports, `accounts`, `list`, `export` and `query` produce a result: named, typed columns and
rows. The format is chosen with `--format`, else `[output] format`, else `table`.

**Value text** (used by `table` and `csv`):

| type | text |
|---|---|
| STRING | as is |
| INT64 | decimal |
| DECIMAL | with its scale: `-12.50` |
| DATE | `YYYY-MM-DD` |
| TIMESTAMP | `YYYY-MM-DD HH:MM:SS[.ffffff]` |
| BOOLEAN | `true` / `false` |
| FLOAT64 | 6 decimals, like `printf("%.6f")` |
| NULL | empty |

**`table`** (the default) is meant for reading:

* a header line, a line of `-` runs, one line per row, then `(N rows)` or `(1 row)`;
* columns are as wide as their longest value, in Unicode code points, and are separated by
  two spaces;
* numeric columns are right-aligned, others left-aligned;
* trailing spaces are removed.

**`csv`**:

* a header record and one record per row, separated by `,` and ended by `\n`;
* a field is quoted (with `"` doubled) if it is an empty string, contains `,`, `"`, CR or
  LF, or starts or ends with a space;
* NULL is an empty unquoted field.

```
$ pqledger --format csv report monthly
month,income,expenses,net,transactions
2026-08,8172.23,4161.33,4010.90,30
2026-09,8475.86,4448.38,4027.48,31
$ pqledger --format csv list --month 2026-08 --account checking
id,date,account,description,amount,category
1,2026-08-01,checking,RENT - OAKWOOD APTS,-1850.00,housing
2,2026-08-05,checking,Spotify USA,-11.41,subscriptions
3,2026-08-06,checking,CVS/PHARMACY #7500,-16.46,uncategorized
4,2026-08-08,checking,Café Mélange,-25.32,dining
…
```

**`json`** is JSON Lines:

* one object per row, with keys in column order and no whitespace; zero rows print
  nothing;
* STRING, DECIMAL, DATE and TIMESTAMP values are JSON strings, so amounts stay exact;
* INT64 and FLOAT64 are numbers, BOOLEAN is `true`/`false` and NULL is `null`.

```
$ pqledger --format json report monthly
{"month":"2026-08","income":"8172.23","expenses":"4161.33","net":"4010.90","transactions":30}
{"month":"2026-09","income":"8475.86","expenses":"4448.38","net":"4027.48","transactions":31}
$ pqledger --format json list --to 2026-08 --account visa
{"id":22,"date":"2026-08-02","account":"visa","description":"Netflix.com","amount":"-15.77","category":"subscriptions"}
{"id":23,"date":"2026-08-02","account":"visa","description":"Pacific Gas & Electric","amount":"-215.06","category":"utilities"}
…
```

Messages of `init`, `import` and `set-category` are plain text in every format.

## How import works

### Reading the file

1. The file is read as UTF-8, and a leading BOM is ignored. The first `skip_lines` physical
   lines are skipped.
2. The rest is parsed as RFC 4180 CSV:
   * the configured delimiter and quote `"`;
   * `\n` or `\r\n` line ends;
   * fields may be quoted and may contain line breaks;
   * empty lines are ignored.

   With `header = true`, the first record is the header. Every record must have as many
   fields as the header (or, without a header, as the first record).
3. For each record:
   * **date**: the field, trimmed, must be a valid calendar date in `date_format`;
   * **description**: the field, trimmed of spaces and tabs (it may be empty);
   * **amount**: `signed` mode uses the amount field. `debit_credit` mode uses credit minus
     debit; an empty debit or credit counts as 0, but not both may be empty.

**Amount conversion.** Each amount field is converted in these steps:

1. Trim spaces and tabs.
2. Handle the sign: `(…)` means negative (the parentheses are removed). Otherwise a leading
   `-` means negative, and a leading `+` is dropped.
3. Remove `currency_symbol` if the text starts or ends with it, then trim again.
4. Remove every thousands separator.
5. Turn the decimal separator into `.`.
6. The result must match `[0-9]+(\.[0-9]{1,2})?`, with at most 16 integer digits.
7. Finally, `invert_sign` negates the amount.

For example, with the `visa` settings, `"$1,234.50"` becomes −1234.50 and `"($360.66)"`
becomes +360.66. With the `giro` settings, Soll `1.120,00` becomes −1120.00.

**Errors.** Any invalid record makes the whole import fail with exit 4. The message names
the file and the 1-based physical line on which the record starts. Nothing is imported.

```
pqledger: error: statements/bad-date.csv:3: invalid date '2026-09-31' (expected YYYY-MM-DD)
pqledger: error: statements/bad-amount.csv:2: invalid amount '-3.5O'
pqledger: error: statements/bad-fields.csv:2: record has 2 fields, expected 3
pqledger: error: statements/bad-header.csv: the header has no column 'Amount' (amount_column)
pqledger: error: statements/missing.csv: no such file
```

### Merchant normalization

The merchant is derived from the description and is what rules and `report merchants` use:

1. ASCII letters are upper-cased. Other letters are kept unchanged.
2. Every run of spaces and tabs becomes one space, and leading and trailing spaces are
   removed.
3. If the result contains a space and its last word is `#` followed by digits, or is 3 or
   more digits, that word is removed (once). This strips store and terminal numbers.

| description | merchant |
|---|---|
| `Whole Foods Market #5293` | `WHOLE FOODS MARKET` |
| `SQ *Blue Bottle Coffee 3887` | `SQ *BLUE BOTTLE COFFEE` |
| `UBER   *TRIP SMME6Z` | `UBER *TRIP SMME6Z` |
| `Rent 2026` | `RENT` |
| `7-Eleven 12` | `7-ELEVEN 12` (only 2 digits) |
| `#123` | `#123` (no space) |
| `Bäckerei Schäfer` | `BäCKEREI SCHäFER` |

### Duplicate detection

Statements overlap, so re-importing must not double-count. Records are compared by the key
**(account, date, amount, merchant)**. Suppose a key appears `f` times in the file and `l`
times in the ledger. Then the **last** `max(0, f − l)` of those records, in file order, are
imported, and the others count as duplicates.

* Re-importing the same file imports nothing (batch 4 above: `imported 0, duplicates 21`).
* An overlapping statement imports only the new rows. In batch 5 above, two rows already
  existed and one was new.
* Two genuinely identical purchases on one day (same merchant and amount) are both kept the
  first time. Later they only count as duplicates against rows that already exist.

Imported rows get consecutive ids in file order, starting at the largest id + 1. Each
import gets the next batch number.

## Ledger storage

The ledger is the set of three **PQCF** files (PolyQuery's columnar file format) in
`data_dir`:

| file | columns |
|---|---|
| `transactions.pqcf` | `id` INT64, `account` STRING, `date` DATE, `description` STRING, `merchant` STRING, `amount` DECIMAL(18,2), `batch` INT64 |
| `batches.pqcf` | `batch` INT64, `account` STRING, `file` STRING (base name), `imported` INT64, `duplicates` INT64 |
| `overrides.pqcf` | `id` INT64, `category` STRING |

* No column contains NULL, and rows are kept in key order.
* Categories are **not** stored, except overrides. They are computed from the rules on
  every invocation.
* The files are the only state, and their layout is fixed by the application spec. A
  ledger written by this implementation can be read and written by every other conforming
  pqledger, and vice versa.
* Every file is replaced atomically when written. A failing command does not change the
  ledger.
* Back up a ledger by copying `data_dir`. The files can also be opened directly with
  `bin/polyquery` (`open` operation) or through the embedding API.
* There is no locking. Do not run two commands that modify the same ledger (`import`,
  `set-category`) at the same time.

## Exit codes

| exit | meaning |
|---|---|
| 0 | success |
| 1 | usage error (command line) |
| 2 | configuration error (configuration, rules or budget file) |
| 3 | `budget`: some category is over budget (the table is still printed) |
| 4 | import data error (`FILE:LINE: …`) |
| 5 | `query`: the engine reported an error (`CODE: message`) |
| 6 | ledger state error: no ledger, ledger already exists, unknown transaction id |
| 7 | any other error (I/O, unexpected engine errors, damaged ledger files) |

With exit status 1, 2, 4, 5, 6 or 7, nothing is printed to stdout. The first line on stderr
starts with `pqledger: error: `.

## Troubleshooting

| message (stderr) | exit | cause and fix |
|---|---|---|
| `cannot read configuration file /path/pqledger.conf: no such file` | 2 | No configuration found. Run from the directory containing `pqledger.conf`, pass `--config PATH`, or set `PQLEDGER_CONFIG`. |
| `FILE:LINE: unknown key 'colour' in section [ledger]` | 2 | Typo in a key, or a key in the wrong section. The line number points at it. |
| `FILE:LINE: assignment before the first section header` | 2 | Add `[ledger]` (or the right section) above the line. |
| `FILE:LINE: section [ledger] repeated (first on line 1)` | 2 | Merge the two sections. |
| `FILE:LINE: invalid account name 'Visa' (expected [a-z0-9_-]{1,32})` | 2 | Account names are lower case. |
| `FILE:LINE: delimiter must be one ASCII character (not '"') or 'tab', got ';;'` | 2 | Invalid value; also check for an accidental inline comment. |
| `FILE:LINE: date_format must be YYYY-MM-DD, …, got 'YYYY/MM/DD'` | 2 | Only the five listed formats exist. |
| `FILE:LINE: [import]: decimal_separator and thousands_separator must differ (both ',')` | 2 | Set both explicitly, e.g. `,` and `.`. |
| `FILE:LINE: pattern 'Coffee_Shop' contains '%' or '_'` (rules file) | 2 | Use `?` for a single character. |
| `no budget_file configured in [ledger] of …` | 2 | `budget` needs `budget_file`. |
| `column reference 'Date' is a header name but header = false` | 2 | Without a header, use column positions (`date_column = 1`). |
| `no ledger in /path/ledger (run 'pqledger init')` | 6 | `data_dir` has no `transactions.pqcf`. Run `pqledger init`, or check that `data_dir` (relative to the configuration file) points where you think. |
| `a ledger already exists in …` | 6 | `init` refuses to overwrite. Remove the directory if you really want to start over. |
| `FILE:LINE: invalid date '…' (expected …)` | 4 | Wrong `date_format` for this account, or an invalid date in the file. Check `[account NAME]`. |
| `FILE:LINE: invalid amount '…'` | 4 | Check `decimal_separator`, `thousands_separator` and `currency_symbol` for this account. |
| `FILE:LINE: record has N fields, expected M` | 4 | Wrong `delimiter`, or a preamble that needs `skip_lines`. |
| `FILE: the header has no column 'Amount' (amount_column)` | 4 | Set the account's `*_column` keys to the header names the bank uses (matched case-insensitively), or to positions. |
| `unknown option '--top' for list`, `option --month given twice`, `unexpected argument '--month=2026-09'` | 1 | See [Command line](#command-line). Values follow options as separate arguments. |
| `SEMANTIC_ERROR: unknown column 'nope'` | 5 | Error in your `query` SQL. The engine's error code comes first. |
| `batches.pqcf does not have the columns of the ledger's batches table: …` or `cannot open …/batches.pqcf: NOT_FOUND: file not found` | 7 | A ledger file (`batches.pqcf` or `overrides.pqcf`) is missing or is not a pqledger file. Restore `data_dir` from a backup. |
| `exec: java: not found` | 127 | No Java. Install OpenJDK 27, or set `JAVA_HOME` to it. |
| `java.lang.module.FindException: … Unsupported major.minor version 71.0` | 1 | The `java` found is older than 27 (e.g. `/usr/bin/java` is Java 25). Set `JAVA_HOME` to a JDK 27, or put it first on `PATH`. |
| `build/pqledger.jar not found; run 'make -C … build' first` | 7 | Build first. The launcher must stay in (or be symlinked from) `implementations/java/bin`. |

The last three rows come from the launcher or the JVM, not from pqledger itself, so they do
not follow the `pqledger: error:` convention. An outdated Java exits with status 1, the same
as a usage error.

**Rules do not match?** Look at the normalized merchants with
`pqledger export --format csv` or
`pqledger query "SELECT DISTINCT merchant FROM transactions ORDER BY merchant"`. Remember
that patterns must match the whole merchant (add `*`), and that non-ASCII letters are not
case-folded.

**Performance.** Each invocation starts a JVM, which costs about 0.1–0.3 s. All filtering
and aggregation runs inside the embedded engine. Measured on a 32-core machine:

| operation | time |
|---|---|
| importing a 100,830-record statement into an empty ledger | 0.6 s |
| re-importing the same file (all duplicates) | 0.5 s |
| `report categories` on 100,830 transactions | 0.25 s |
| `export --format csv` on 100,830 transactions | 0.3 s |

A very large ledger needs heap: by default the JVM uses ¼ of physical memory. Set
`PQLEDGER_JAVA_OPTS=-Xmx8g` if a command fails with `RESOURCE_LIMIT: out of memory`
(exit 7, or 5 for `query`). `[engine] threads` and `memory_mb` limit the engine per query.
