# pqledger — a personal-finance command-line application (application spec 1.0.0)

Status: adopted 2026-10-14 (ADR-0018). Applies identically to every implementation.
`pqledger` is an example application built on an implementation's PolyQuery engine,
used **in-process through the engine's embedding API** ([embedding.md](embedding.md)).
It imports bank-statement CSV exports into a ledger, assigns categories with rules,
and prints reports and budget checks.

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119. Where this
document is silent, behaviour is implementation-defined and tests do not depend on it.

## 1. Deliverables and layout

In the implementation directory (`implementations/<lang>/`):

| path | contents |
|---|---|
| `bin/pqledger` | executable launcher; works from any working directory |
| `app/` | the application's source code (separate from the engine's source) |
| `APP.md` | user guide: building, configuration reference with a complete example, the rules and budget files, every command with example output, exit codes, troubleshooting |
| `EMBEDDING.md` | developer guide to the embedding API ([embedding.md](embedding.md) §4) |
| `examples/embed-demo/` | the minimal embedding example ([embedding.md](embedding.md) §5), launcher `bin/pq-embed-demo` |

`make build` builds the engine, the library, `pqledger` and the example; `make test` also
runs the application's own unit tests. `bin/polyquery` and everything it did before keeps
working unchanged.

**In-process use (MUST).** `pqledger` performs all data access through the embedding API in
the same process. It MUST NOT start `bin/polyquery` or any other process except its own
launcher chain (e.g. a shell launcher that `exec`s a runtime), and MUST NOT open network
connections. All filtering, joining, aggregation, sorting and category resolution for
`report`, `budget`, `accounts`, `list` and `export` MUST be performed by SQL queries executed
by the embedded engine. The host program parses files and arguments, converts bank CSV
records, decides duplicates, formats output, and computes the `share` column (§9.2).

## 2. Command line

```
pqledger [GLOBAL OPTIONS] COMMAND [COMMAND ARGUMENTS AND OPTIONS]
```

Global options (only before `COMMAND`):

| option | meaning |
|---|---|
| `--config PATH` | configuration file (§3.1) |
| `--format table\|csv\|json` | output format, overrides `[output] format` |
| `--help` | same as the `help` command |

Commands: `init`, `import`, `report monthly`, `report categories`, `report merchants`, `budget`,
`accounts`, `list`, `export`, `set-category`, `query`, `help`, `version` (§6–§9).
Options of a command follow the command and may appear in any order among its positional
arguments. Every option takes its value as the next argument (`--month 2026-09`); the form
`--month=2026-09` is not required. Repeating an option, an unknown command or option, a
missing or malformed value, or a surplus argument is a usage error (exit 1).

Common filter options (where a command lists them):

| option | value | meaning |
|---|---|---|
| `--month M` | `YYYY-MM` | only transactions dated in month M |
| `--from M`, `--to M` | `YYYY-MM` | inclusive month range; either may be given alone |
| `--account NAME` | account name (§3.3) | only transactions of that account |

`--month` together with `--from` or `--to` is a usage error. A month must be a valid
`YYYY-MM` with month 01–12 and year 0001–9999; `--from` later than `--to` is a usage error.

## 3. Configuration

### 3.1 Locating the file

The first of these that applies is used: `--config PATH`; the environment variable
`PQLEDGER_CONFIG` if set and non-empty; `pqledger.conf` in the current directory. If the
chosen file does not exist or cannot be read ⇒ configuration error (exit 2). Relative paths
inside the configuration (and in `PQLEDGER_CONFIG`/`--config`) are resolved against, respectively,
the configuration file's directory and the current directory.

### 3.2 Syntax

UTF-8 text, `\n` or `\r\n` line ends, a leading BOM ignored. Each line, after removing
leading and trailing spaces and tabs, is one of:

* empty;
* a comment: first character `#` or `;`;
* a section header `[NAME]`, `NAME` being `ledger`, `import`, `output`, `engine`, or
  `account ACCOUNT` (one space, then an account name, §3.3);
* an assignment `KEY = VALUE`: `KEY` is the text before the first `=`, trimmed; `VALUE` the text
  after it, trimmed. If `VALUE` starts and ends with `"` (and is at least 2 characters long)
  the quotes are removed and inside them `\"` means `"` and `\\` means `\`; this is how a
  value keeps leading or trailing spaces or is empty. There are no inline comments.

Assignments before the first section header, unknown sections, unknown keys in a section, a
key repeated within one section, a repeated section header, and invalid values are
configuration errors (exit 2); the message SHOULD name the line number.

### 3.3 Sections and keys

`[ledger]` (required section):

| key | value | default |
|---|---|---|
| `data_dir` | directory of the ledger (§4); required | — |
| `rules_file` | category rules file (§5.1) | none: no rules |
| `budget_file` | budget file (§5.2) | none |

`[import]` — how bank CSV files are read; `[account NAME]` sections MAY override any of these
keys for one account (the effective value for an account is the `[account NAME]` value, else the
`[import]` value, else the default):

| key | value | default |
|---|---|---|
| `delimiter` | one ASCII character, or `tab` | `,` |
| `header` | `true` \| `false` | `true` |
| `skip_lines` | integer ≥ 0: physical lines skipped before the first record (a preamble) | `0` |
| `date_column` | column reference (below) | `Date` |
| `date_format` | `YYYY-MM-DD`, `YYYYMMDD`, `MM/DD/YYYY`, `DD/MM/YYYY` or `DD.MM.YYYY` | `YYYY-MM-DD` |
| `description_column` | column reference | `Description` |
| `amount_mode` | `signed` (one amount column) \| `debit_credit` (two columns) | `signed` |
| `amount_column` | column reference (`signed`) | `Amount` |
| `debit_column`, `credit_column` | column references (`debit_credit`) | `Debit`, `Credit` |
| `decimal_separator` | `.` \| `,` | `.` |
| `thousands_separator` | `none`, `,`, `.`, `space` or `'` | `none` |
| `currency_symbol` | text removed from amounts (§6.2) | empty |
| `invert_sign` | `true` \| `false`: negate every amount (e.g. card exports where charges are positive) | `false` |

A **column reference** is a positive decimal integer (1-based column position) or otherwise a
header name, matched against the header fields (after trimming spaces and tabs) with ASCII
case-insensitive comparison; a name requires `header = true`. The decimal and thousands
separators MUST differ.

`[output]`: `format` = `table` | `csv` | `json` (default `table`).

`[engine]`: `threads` (integer ≥ 1) and `memory_mb` (integer ≥ 1). When present, they SHOULD
be passed to the engine as the query `threads` option and the per-query memory limit
(`--max-query-memory-mb`). Absent: the engine's defaults.

An **account name** matches `[a-z0-9_-]{1,32}`. A **category name** matches
`[a-z0-9_-]{1,32}` and is not `uncategorized`.

Example:

```ini
[ledger]
data_dir = ledger
rules_file = rules.conf
budget_file = budgets.conf

[import]
date_column = Date
description_column = Description
amount_column = Amount

[account visa]
date_format = MM/DD/YYYY
invert_sign = true

[account sparkonto]
delimiter = ;
date_format = DD.MM.YYYY
decimal_separator = ,
thousands_separator = .
amount_mode = debit_credit
debit_column = Soll
credit_column = Haben
```

## 4. The ledger (normative storage)

The ledger is the set of these PQCF files in `data_dir`; they are the only authority for its
contents, so a ledger written by any conforming implementation is readable and writable by
every other. Each file holds one table with exactly these columns, in this order:

`transactions.pqcf`:

| column | type | meaning |
|---|---|---|
| `id` | `INT64` | 1, 2, 3, … in import order; never reused |
| `account` | `STRING` | account name |
| `date` | `DATE` | posting date |
| `description` | `STRING` | the bank's description, trimmed of leading/trailing spaces and tabs |
| `merchant` | `STRING` | normalized description (§6.3) |
| `amount` | `DECIMAL(18,2)` | negative = money out, positive = money in |
| `batch` | `INT64` | the import that added the row |

`batches.pqcf`: `batch INT64` (1, 2, 3, …), `account STRING`, `file STRING` (the imported
file's base name), `imported INT64` (rows added), `duplicates INT64` (rows skipped, §6.4).

`overrides.pqcf`: `id INT64` (a transaction id; at most one row each), `category STRING`.

No column contains NULL. Rows SHOULD be stored in key order (`id`, `batch`, `id`). The files
MAY carry indexes; other files in `data_dir` MAY exist (an implementation's own caches) but
MUST NOT be needed to read the ledger. Every command except `init`, `help` and `version`
requires an existing ledger (`transactions.pqcf` present), else ⇒ ledger state error (exit 6).

## 5. Rules and budgets

### 5.1 Rules file

Same line syntax as §3.2 without sections: blank lines, comments, and lines
`CATEGORY = PATTERN [, PATTERN …]`. Patterns are trimmed, must be non-empty and must not
contain `%` or `_`. In a pattern `*` matches any sequence of characters (also empty), `?`
exactly one character, and everything else itself, ASCII case-insensitively; a pattern must
match the **whole** merchant. A category may appear on several lines. Errors ⇒ exit 2.

The rules file is read by every command except `init`, `help` and `version`; the budget file
only by `budget` and `query`. A configured file that is missing or invalid ⇒ exit 2 from those
commands.

**Category resolution.** The category of a transaction is its override (§8.3) if one exists;
else the category of the first pattern, in file order (line order, then order within the
line), that matches its merchant; else `uncategorized`. Rules are read on every invocation;
changing the rules file recategorizes past transactions.

### 5.2 Budget file

Lines `CATEGORY = AMOUNT`: a monthly budget, `AMOUNT` matching `[0-9]+(\.[0-9]{1,2})?`, at most
16 integer digits. A category listed twice ⇒ configuration error (exit 2).

## 6. `init` and `import`

### 6.1 `pqledger init`

Creates `data_dir` (with missing parents) and the three tables with zero rows. If
`transactions.pqcf` already exists ⇒ ledger state error (exit 6), nothing changes.
Prints `initialized ledger`.

### 6.2 `pqledger import FILE --account NAME`

`FILE` is resolved against the current directory; `--account` is required. The file is read
with the account's effective `[import]` settings:

1. UTF-8; a leading BOM is ignored. The first `skip_lines` physical lines are skipped.
2. The rest is CSV as in `spec/data-types/ingestion.md` §1 (RFC 4180, the configured delimiter,
   quote `"`, `\n` or `\r\n`, empty lines ignored). With `header = true` the first record is the
   header. Every record MUST have as many fields as the header (or, without one, as the first
   record).
3. For each data record: **date** — the field, trimmed, in the configured format (`MM` and `DD`
   may have 1 or 2 digits in the `/` and `.` formats; `YYYY` is 4 digits) and a valid calendar
   date. **description** — the field trimmed of spaces and tabs (may be empty). **amount** —
   `signed`: the amount field; `debit_credit`: credit minus debit, where an empty (after
   trimming) debit or credit field counts as 0 but not both may be empty.

   An amount field is converted thus: trim spaces and tabs; if the text is `(`…`)` it is
   negative and the parentheses are removed, else a leading `-` makes it negative and a leading
   `+` is removed; then a configured `currency_symbol` is removed if the text starts or ends
   with it, and the result is trimmed again; then every configured thousands separator is
   removed (`space`: U+0020); then the configured decimal separator becomes `.`. The result
   MUST match `[0-9]+(\.[0-9]{1,2})?` with at most 16 integer digits. In `debit_credit` mode the
   debit and credit fields are each converted this way. Finally `invert_sign` negates the
   amount. `-0.00` is `0.00`.
4. Any record that fails ⇒ import data error (exit 4) with a message that names the file and
   the 1-based physical line on which the record starts (`FILE:LINE: …`); **nothing** is
   imported and no batch is recorded. A missing or unreadable file, a header without a
   referenced column, or a column position beyond the record ⇒ also exit 4.

### 6.3 Merchant normalization

From the description: ASCII letters are upper-cased; every run of spaces and tabs becomes one
space; leading and trailing spaces are removed; then, if the result contains a space and its
last space-separated token is `#` followed by one or more digits, or consists of 3 or more
digits only, that token and the space before it are removed (once). Examples:
`Whole Foods Market #10234` → `WHOLE FOODS MARKET`; `SQ *Blue  Bottle 4421` → `SQ *BLUE BOTTLE`;
`Rent 2026` → `RENT`; `7-Eleven 12` → `7-ELEVEN 12`; `#123` → `#123`.

### 6.4 Duplicates

Statements overlap, so re-importing must not double-count. Group the file's converted records
by the key (account, date, amount, merchant). For a key with `f` records in the file and `l`
transactions already in the ledger, the **last** `max(0, f − l)` of those records in file
order are imported and the others count as duplicates. Imported records get consecutive new ids
in file order, starting at the ledger's largest id + 1 (1 for an empty ledger), and the batch
number largest batch + 1 (1 for the first); the batch is recorded even if it imports nothing.
Prints one line: `batch B: imported N, duplicates D`.

## 7. Output

Every report, `list`, `export` and `query` produces a result: named columns, each with a type,
and rows. It is printed in the selected format.

**Value text** (used by `table` and `csv`): `STRING` as is; `INT64` in decimal; `DECIMAL` as in
`spec/data-types/types.md` §9 without quotes (`-12.50`, `0.0`); `DATE` `YYYY-MM-DD`;
`TIMESTAMP` as in types.md §9; `BOOLEAN` `true`/`false`; `FLOAT64` rounded to 6 fractional
digits like C `printf("%.6f")`, with `-0.000000` printed as `0.000000` (tests avoid values
whose rounding is a near tie); `NULL` empty.

**`table`**: a header line with the column names, a line of `-` runs (one per column, each as
long as the column), then one line per row, then a footer `(N rows)`, or `(1 row)` when N = 1.
The width of a column is the largest length, in Unicode code points, of its name and its value
texts. Cells are separated by two spaces; cells of `INT64`, `DECIMAL` and `FLOAT64` columns are
right-aligned (also in the header), all others left-aligned, padded with spaces to the width;
trailing spaces are removed from every line.

```
month    income  expenses       net  transactions
-------  ------  --------  --------  ------------
2026-08  100.00     45.10     54.90             3
2026-09    0.00   1200.00  -1200.00             1
(2 rows)
```

**`csv`**: a header record and one record per row, `,`-separated, `\n`-terminated. A field is
enclosed in `"` (with `"` doubled) if it is an empty non-NULL string or contains `,`, `"`, CR or
LF, or starts or ends with a space; otherwise it is written as is. NULL is an empty unquoted
field.

**`json`**: JSON Lines, one object per row (nothing for zero rows), keys = column names in
column order, no whitespace between tokens: `{"month":"2026-08","income":"100.00","transactions":3}`.
`STRING`, `DECIMAL`, `DATE`, `TIMESTAMP` are JSON strings (value text); `INT64` and `FLOAT64`
(value text) are JSON numbers; `BOOLEAN` `true`/`false`; NULL `null`. In strings `"` and `\` are
escaped as `\"` and `\\`, U+0008/0009/000A/000C/000D as `\b` `\t` `\n` `\f` `\r`, other characters
below U+0020 as `\u00xx` (lowercase hex); all other characters are written as UTF-8.

## 8. Listing and editing

### 8.1 `pqledger list [filters] [--category C | --uncategorized]`

Columns `id` INT64, `date` DATE, `account` STRING, `description` STRING, `amount`
DECIMAL(18,2), `category` STRING; one row per transaction passing the filters (and with the
given resolved category; `--uncategorized` means category `uncategorized`), ordered by `date`,
then `id`.

### 8.2 `pqledger export [filters]`

Columns `id`, `account`, `date`, `description`, `merchant`, `amount`, `category`, `batch` (types
as in §4, `category` STRING), ordered by `id`.

### 8.3 `pqledger set-category ID CATEGORY` / `pqledger set-category ID --clear`

Sets or removes the override of transaction `ID` (a positive integer). An unknown id ⇒ ledger
state error (exit 6); an invalid category name ⇒ usage error (exit 1). Prints
`transaction ID: category CATEGORY` or `transaction ID: category cleared`. Clearing a
transaction without an override succeeds.

### 8.4 `pqledger accounts`

Columns `account` STRING, `transactions` INT64, `balance` DECIMAL(18,2) (sum of amounts),
`first` DATE, `last` DATE (earliest and latest date); one row per account with transactions,
ordered by `account`.

## 9. Reports and budgets

Amounts are sums of `amount`. **Outflows** are transactions with `amount < 0`; their **spent**
value is the negated sum (≥ 0).

### 9.1 `pqledger report monthly [filters]`

Columns `month` STRING (`YYYY-MM`), `income` DECIMAL(18,2) (sum of positive amounts, `0.00` if
none), `expenses` DECIMAL(18,2) (spent of the outflows), `net` DECIMAL(18,2) (sum of all
amounts), `transactions` INT64; one row per month with at least one transaction, ordered by
`month`.

### 9.2 `pqledger report categories [filters]`

Outflows only. Columns `category` STRING, `spent` DECIMAL(18,2), `share` DECIMAL(18,1),
`transactions` INT64; one row per resolved category, ordered by `spent` descending, then
`category` ascending. `share` is `100 × spent ÷ total spent of all rows`, rounded half away from
zero to one fractional digit, computed exactly (e.g. in integer cents). No outflows ⇒ no rows.

### 9.3 `pqledger report merchants [filters] [--top N]`

Outflows only. Columns `merchant` STRING, `spent` DECIMAL(18,2), `transactions` INT64; ordered by
`spent` descending, then `merchant` ascending; the first `N` rows (`N` ≥ 1, default 10).

### 9.4 `pqledger budget --month M [--account NAME]`

Requires a `budget_file` (else configuration error, exit 2) and `--month`. Columns `category`
STRING, `budget` DECIMAL(18,2), `spent` DECIMAL(18,2) (spent of the month's outflows with that
resolved category), `remaining` DECIMAL(18,2) (`budget − spent`), `status` STRING (`ok` if
`spent ≤ budget`, else `over`); one row per budget category, ordered by `category`. The exit
status is 3 if any row is `over` (the result is printed in full either way).

### 9.5 `pqledger query SQL`

Runs one SQL statement on the embedded engine, with these tables loaded:
`transactions`, `batches`, `overrides` (§4); `ledger` — the `transactions` columns followed by
`category` STRING (resolved, §5.1); `rules` — `rule_no` INT64 (1, 2, … in file order),
`category` STRING, `pattern` STRING (as written, upper-cased); `budgets` — `category` STRING,
`amount` DECIMAL(18,2). Nothing the query does is persisted. The result is printed with the
engine's column names and types. An engine error ⇒ exit 5, first stderr line
`pqledger: error: CODE: MESSAGE` with the engine's error code.

## 10. `help`, `version`, exit status and messages

`help` (and `--help`) prints usage to stdout; `version` prints a line starting with `pqledger `.
Both exit 0; their text is implementation-defined.

| exit | meaning |
|---|---|
| 0 | success |
| 1 | usage error |
| 2 | configuration error (configuration, rules or budget file) |
| 3 | `budget`: some category is over budget |
| 4 | import data error |
| 5 | `query`: the engine reported an error |
| 6 | ledger state error: no ledger, ledger already exists, unknown transaction id |
| 7 | any other error (I/O, unexpected engine errors) |

With exit status 1, 2, 4, 5, 6 or 7, nothing is printed to stdout and the first line on stderr
starts with `pqledger: error: `. A failing command leaves the ledger unchanged. When several
errors apply to one invocation, which one is reported is implementation-defined (tests avoid
such combinations).

## 11. Scale

Every command SHOULD complete within 30 seconds on a ledger of 1,000,000 transactions, and an
import of a 100,000-record file within 30 seconds, on the reference hardware.
