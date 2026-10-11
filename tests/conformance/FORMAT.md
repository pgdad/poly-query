# `.pqt` Conformance Test Format

A `.pqt` file is a sequence of **directives** and **blocks**, executed in order
against one fresh engine process (`bin/polyquery session`). Lines starting with
`#` are comments. Blank lines separate blocks.

## Header directives (top of file)

```
@phase 1                         # phase the file belongs to (1..5)
@requires sql.basic ingest.csv   # capabilities required (space separated)
@engine-args --enable-test-functions   # extra CLI args for this file (optional)
```

## Setup directives (single line)

```
load <table> <path> [format=csv|json|jsonl] [schema=<col>:<TYPE>;<col>:<TYPE>…]
     [schemafile=<path to JSON schema array, relative to tests/conformance>]
     [header=false] [delimiter=<c>] [replace=true] [layout=row|column] [expect=<ERROR_CODE>]
```
`path` is relative to the data directory, which contains `fixtures/` (the
public fixtures, read-only) and is otherwise writable. Default format is taken
from the file extension. `expect=CODE` asserts the load fails with that code.

```
data <table> <format> [same options as load]
<inline content lines>
.
```
Loads inline content (`"data"` field) terminated by a line consisting of a single `.`.

```
open <table> <path> [mmap=true] [replace=true] [layout=row|column] [expect=<CODE>]
save <table> <path> [encoding=plain|dict|rle|auto] [row_group_size=N] [expect=<CODE>]
corrupt <table> <path> <CODE>
```
`open`/`save` are test cases (protocol ops of the same name). `corrupt` asserts
that opening a damaged PQCF file fails with CODE — either at `open`, or (for
engines that verify chunk checksums lazily) at a subsequent full scan
`SELECT * FROM <table>`, which the runner issues automatically when `open` succeeds.

```
pqcf <path> <format_version>
```
A test case evaluated by the runner itself (no protocol request): the file the
engine saved at `<path>` must carry `<format_version>` in both its header and its
footer metadata (used by CR-2, which selects PQCF v1 or v2 by column types).

## Query blocks

```
query [ordered|unordered] [oracle] [options=<json object>]
SELECT …               (one or more SQL lines)
----
<col> <TYPE> | <col> <TYPE> | …        (column header; names may be JSON-quoted: "a \"b\"")
[json values of row 1]
[json values of row 2]
```
* An empty result has the header line and no rows. A result with zero columns
  (statements) uses the header line `-` .
* Values are written exactly as the protocol serializes them (types.md §9):
  `["1.50", null, true, "2024-01-01", 3.5]`.
* `ordered` compares row order; `unordered` (default) compares multisets.
* `oracle` marks the test as eligible for the SQLite oracle cross-check.
* `rowcount N` instead of rows asserts only the count (`----` then `rowcount 5`).

## Error blocks

```
error <CODE> [options=<json>]
SELECT …
```

## Statement blocks

```
statement ok
CREATE INDEX i ON t (c)
```
`statement error <CODE>` asserts failure.

## Raw protocol requests

```
request
{"op":"schema","table":"people"}
----
match {"ok":true,"columns":[{"name":"id","type":"INT64"}]}
```
Expectation lines (any number, all must hold):
* `ok` — response `ok` is true;
* `error <CODE>`;
* `match <json>` — *subset match*: every key of an expected object must be present
  with a matching value; arrays must have equal length and match element-wise;
  scalars must be equal (FLOAT64 tolerance applies to numbers with a fraction).

## EXPLAIN assertions

```
explain [options=<json>]
SELECT …
----
index-scan <index_name>          # some IndexScan node uses this index
no-index-scan                    # no IndexScan node anywhere
scan-columns <table> <c1,c2,…>   # the TableScan(s) of <table> read exactly these columns (set)
node <OpName>                    # some node has op == OpName
no-node <OpName>
```

## Comparison rules

As in spec/acceptance/README.md §1.
