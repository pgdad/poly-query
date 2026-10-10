# Data Ingestion

Tables are created by the protocol `load` operation (see protocol.md) from CSV,
JSON (array of objects) or JSON Lines input, either from a file (resolved inside
the engine's data directory) or from inline text.

Loaded tables are **immutable**. Re-loading a table with `"replace": true`
atomically replaces it; without `replace`, loading an existing table name fails
with `ALREADY_EXISTS`.

Table and column names are matched case-insensitively (ASCII case folding) but
reported with their original spelling. Duplicate column names (case-insensitive)
in one table ⇒ `INGEST_ERROR`. Empty column names ⇒ `INGEST_ERROR`.

## 1. CSV

* RFC 4180 with these specifics:
  * Encoding UTF-8. A leading UTF-8 BOM is ignored.
  * Field delimiter `,` (configurable via `options.delimiter`, a single ASCII character).
  * Quote character `"`; inside a quoted field `""` is a literal quote. Quoted
    fields may contain delimiters and newlines.
  * Record terminator `\n` or `\r\n`. A final terminator is optional. Completely
    empty lines (zero characters) are ignored.
  * The first record is the header (`options.header`, default `true`). If
    `header` is `false`, an explicit schema is required and supplies names.
  * Every record MUST have exactly as many fields as the header, else
    `INGEST_ERROR` (message SHOULD include the 1-based record number).
* **NULL**: an *unquoted empty* field is NULL. A *quoted empty* field (`""`) is
  the empty string for STRING columns and NULL for all other column types.
* Surrounding whitespace is significant for STRING columns; for all other types
  the field text is trimmed of ASCII spaces/tabs before conversion.

### 1.1 Schema inference (no explicit schema)

For each column, consider all field texts that are neither unquoted-empty nor
quoted-empty (after trimming for the non-string candidates) and choose the first type in this list for which **every**
value matches:

1. `BOOLEAN`  — `true` or `false`, case-insensitive.
2. `INT64`    — `^[+-]?[0-9]+$` and within INT64 range.
3. `FLOAT64`  — `^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$` and finite.
   (So a column mixing integers and decimals is FLOAT64.)
4. `DATE`     — `^[0-9]{4}-[0-9]{2}-[0-9]{2}$` and a valid calendar date.
5. `TIMESTAMP` — `^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?$`
   and valid. A column mixing DATE and TIMESTAMP texts is TIMESTAMP (dates mean midnight).
6. `STRING`   — otherwise.

A column with no considered values is `STRING` (its quoted-empty fields are
then empty strings). Inference NEVER yields DECIMAL;
DECIMAL columns require an explicit schema.

### 1.2 Explicit schema

`schema` is an array `[{"name": "...", "type": "..."}]` (type syntax per
types.md, aliases allowed). With `header: true`, the header names MUST match
the schema names in count and order (case-insensitive), else `INGEST_ERROR`.
Each field is converted to the declared type; failure ⇒ `CONVERSION_ERROR`
(message SHOULD include record number and column name). Accepted texts:

* BOOLEAN: `true`/`false` (case-insensitive).
* INT64: as in 1.1.
* FLOAT64: as in 1.1 (finite).
* DECIMAL(p,s): `^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)$`; the number of fractional
  digits MUST be ≤ s (trailing zeros beyond s are **not** permitted either —
  ingestion is exact, never rounds), and the value MUST fit precision p.
  Violations ⇒ `CONVERSION_ERROR`.
* DATE / TIMESTAMP: as in 1.1 (a DATE text is accepted for a TIMESTAMP column).
* STRING: raw field text (not trimmed).

## 2. JSON and JSON Lines

* `json`: the document MUST be a JSON array whose elements are objects.
* `jsonl`: each non-blank line (after trimming whitespace) MUST be a JSON object.
* Strict RFC 8259 JSON (no comments, no trailing commas, no NaN). Malformed
  input ⇒ `INGEST_ERROR`.
* Columns are the union of object keys in **order of first appearance**. A key
  missing in an object ⇒ NULL. Duplicate keys within one object ⇒ `INGEST_ERROR`.
* Nested objects or arrays as values ⇒ `INGEST_ERROR`.

### 2.1 Inference

Per column, over non-null values:

* all JSON booleans ⇒ `BOOLEAN`
* all JSON numbers, all written without `.`/`e`/`E` and within INT64 range ⇒ `INT64`
* all JSON numbers otherwise ⇒ `FLOAT64`
* all JSON strings: if all match the DATE syntax ⇒ `DATE`; else if all match
  DATE or TIMESTAMP syntax ⇒ `TIMESTAMP`; else `STRING`
* no non-null values ⇒ `STRING`
* any other mixture (e.g. numbers and strings) ⇒ `INGEST_ERROR`

### 2.2 Explicit schema

Schema names define columns (keys not in the schema ⇒ `INGEST_ERROR`). Value
conversion: JSON numbers → INT64/FLOAT64/DECIMAL using the number's literal
text and the CSV rules; JSON strings → DATE/TIMESTAMP/STRING, or
DECIMAL/INT64/FLOAT64 by parsing the text with the CSV rules; JSON booleans →
BOOLEAN. Any other combination ⇒ `CONVERSION_ERROR`.

## 3. Limits

* Engines MUST enforce a configurable maximum input size and row count
  (`--max-ingest-bytes`, `--max-table-rows`; defaults implementation-defined
  but ≥ 2 GiB and ≥ 200,000,000). Exceeding them ⇒ `RESOURCE_LIMIT`.
* A single field longer than 16 MiB ⇒ `INGEST_ERROR`.
