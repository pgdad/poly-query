# Data Types and Value Semantics

## 1. Types

| Type name (canonical) | Domain | Physical (in PQCF) |
|---|---|---|
| `BOOLEAN` | `false`, `true` | bit |
| `INT64` | signed 64-bit two's-complement integers, −2⁶³ … 2⁶³−1 | i64 LE |
| `FLOAT64` | **finite** IEEE-754 binary64 values (no NaN, no ±Infinity). `-0.0` is normalised to `0.0` on output. | f64 LE |
| `DECIMAL(p,s)` | fixed-point decimals, `1 ≤ p ≤ 18`, `0 ≤ s ≤ p`; value = unscaled / 10ˢ where unscaled is an integer with at most `p` digits | unscaled i64 LE |
| `STRING` | sequences of Unicode scalar values, UTF-8 encoded | UTF-8 bytes |
| `DATE` | proleptic Gregorian calendar days `0001-01-01` … `9999-12-31` | i32 LE days since 1970-01-01 |
| `TIMESTAMP` | microseconds since `1970-01-01 00:00:00`, no time zone, range `0001-01-01 00:00:00` … `9999-12-31 23:59:59.999999` | i64 LE microseconds |

Every column is nullable. `NULL` is a value of every type. A literal `NULL`
has the special *null type* which is coercible to every type; an expression
whose static type remains the null type (e.g. `SELECT NULL`) is reported as
`STRING` in result metadata.

Canonical type names are uppercase, and `DECIMAL` is always written with both
parameters and no spaces: `DECIMAL(18,2)`.

Type-name aliases accepted in SQL `CAST` and in explicit schemas
(case-insensitive): `BOOL`→`BOOLEAN`; `INT`, `INTEGER`, `BIGINT`→`INT64`;
`DOUBLE`, `FLOAT`, `REAL`→`FLOAT64`; `VARCHAR`, `TEXT`→`STRING`;
`NUMERIC(p,s)`→`DECIMAL(p,s)`; `DECIMAL`/`NUMERIC` without parameters →
`DECIMAL(18,0)`; `DECIMAL(p)` → `DECIMAL(p,0)`.

## 2. Type categories and numeric promotion

Numeric types are `INT64`, `DECIMAL(p,s)`, `FLOAT64`, ordered by the promotion
lattice `INT64 < DECIMAL < FLOAT64`.

When a binary arithmetic or comparison operator combines two numeric operands of
different types, both are promoted to the *common numeric type*:

| left \ right | INT64 | DECIMAL(p2,s2) | FLOAT64 |
|---|---|---|---|
| INT64 | INT64 | DECIMAL(18,s2) | FLOAT64 |
| DECIMAL(p1,s1) | DECIMAL(18,s1) | DECIMAL(18,max(s1,s2)) | FLOAT64 |
| FLOAT64 | FLOAT64 | FLOAT64 | FLOAT64 |

Promotion of INT64 to DECIMAL(18,s) fails with `NUMERIC_OVERFLOW` at runtime if
the scaled value needs more than 18 digits.

`DATE` and `TIMESTAMP` are comparable with each other: a `DATE` is promoted to
the `TIMESTAMP` at `00:00:00` of that day.

All other combinations of distinct types are **not** comparable and raise
`TYPE_ERROR` during semantic validation (e.g. `STRING = INT64`,
`BOOLEAN < INT64`, `DATE = STRING`). There is no implicit string↔number or
string↔date conversion; use `CAST`.

## 3. Literals

| Literal | Type |
|---|---|
| `123`, `-7` (digits only) | `INT64`. A digits-only literal outside the INT64 range is a `NUMERIC_OVERFLOW` error at parse/validation time. (`-9223372036854775808` MUST be accepted: unary minus applied to the literal `9223372036854775808` is folded.) |
| `1.50`, `.5`, `3.` | `DECIMAL(p,s)` where `s` = number of digits after the point and `p = max(total significant digits incl. leading integer digits, s, 1)`; if `p > 18` the literal is `FLOAT64` instead. Example: `1.50` → `DECIMAL(3,2)`, `0.5` → `DECIMAL(1,1)`, `.5` → `DECIMAL(1,1)`. |
| `1e3`, `2.5E-4` (with exponent) | `FLOAT64` |
| `'text'` (single quotes; `''` escapes a quote) | `STRING` |
| `TRUE`, `FALSE` | `BOOLEAN` |
| `NULL` | null type |
| `DATE 'YYYY-MM-DD'` | `DATE` (invalid → `CONVERSION_ERROR`) |
| `TIMESTAMP 'YYYY-MM-DD HH:MM:SS[.f{1,6}]'` (space or `T` separator) | `TIMESTAMP` |

For `p` of a decimal literal, leading zeros of the integer part are not
significant (`0.05` → `DECIMAL(2,2)`; `00012.5` → `DECIMAL(3,1)`).

## 4. Arithmetic

Operators: unary `-`, unary `+`, binary `+ - * / %`, string concatenation `||`.

* Operands of `+ - * / %` MUST be numeric, else `TYPE_ERROR`. (Exception: date
  arithmetic is **not** supported in v1; `DATE + INT64` is a `TYPE_ERROR`.)
* Any NULL operand ⇒ result NULL (checked before division-by-zero).
* **INT64 (op) INT64**: `+ - *` produce INT64; overflow ⇒ `NUMERIC_OVERFLOW`.
  `/` is integer division truncating toward zero; `%` is the remainder with the
  sign of the dividend (`-7 % 3 = -1`). Divisor 0 ⇒ `DIVISION_BY_ZERO`.
  `INT64_MIN / -1` ⇒ `NUMERIC_OVERFLOW`; `INT64_MIN % -1 = 0`.
* **DECIMAL**: after promotion to DECIMAL(18,s1) and DECIMAL(18,s2) (scales of
  the individual operands are preserved; precision becomes 18):
  * `+`, `-`: result `DECIMAL(18, max(s1,s2))`.
  * `*`: result `DECIMAL(18, s1+s2)`; if `s1+s2 > 18` ⇒ `TYPE_ERROR` at validation.
  * `/`: result is `FLOAT64` (both operands converted to FLOAT64). Divisor 0 ⇒
    `DIVISION_BY_ZERO`.
  * `%`: `TYPE_ERROR` (only INT64 supports `%`).
  * Any result whose unscaled value needs more than 18 digits ⇒ `NUMERIC_OVERFLOW`.
    Intermediate computations MUST be exact (use 128-bit or arbitrary precision
    intermediates where needed).
* **FLOAT64**: IEEE-754 binary64 round-to-nearest-even. Division by zero
  (including `0.0/0.0`) ⇒ `DIVISION_BY_ZERO`. A non-finite result (overflow)
  ⇒ `NUMERIC_OVERFLOW`. `%` ⇒ `TYPE_ERROR`.
* Unary `-` and `+` preserve the operand's type (e.g. `-2.50` is `DECIMAL(3,2)`).
  Unary minus INT64 overflow (`-(-9223372036854775808)`) ⇒ `NUMERIC_OVERFLOW`.

Rounding, whenever a DECIMAL must be reduced in scale (CAST, ROUND, ingestion
with explicit schema is **not** a rounding context — see ingestion.md), uses
**round half away from zero**.

## 5. Comparison

Operators: `=`, `<>` (also `!=`), `<`, `<=`, `>`, `>=`.

* If either operand is NULL the result is NULL.
* Numeric values compare by mathematical value after promotion. An INT64 vs
  FLOAT64 comparison converts the INT64 to the nearest FLOAT64.
* `STRING` compares by **Unicode code point sequence**, lexicographically (this
  equals byte-wise comparison of UTF-8). No collation, case-sensitive.
* `BOOLEAN`: `false < true`.
* `DATE`/`TIMESTAMP`: chronological.

## 6. Three-valued logic

`AND`, `OR`, `NOT` take BOOLEAN (or NULL) operands, else `TYPE_ERROR`. Truth
tables follow SQL three-valued logic (`NULL AND FALSE = FALSE`,
`NULL OR TRUE = TRUE`, otherwise NULL propagates). `WHERE`, `HAVING`, `ON` and
`CASE WHEN` treat NULL as not-true. The condition of `WHERE`/`HAVING`/`ON`/`CASE WHEN` MUST
have type BOOLEAN (or null type), else `TYPE_ERROR`.

Engines MAY short-circuit evaluation, but MUST NOT let short-circuiting change
the result *value*. Whether an error in an operand that need not be evaluated is
raised is implementation-defined (conformance tests avoid that situation).

## 7. Total ordering of values (ORDER BY, MIN/MAX, DISTINCT, GROUP BY, indexes)

For sorting, within a single column type: `NULL` sorts **before** every
non-NULL value in ascending order (and therefore last in descending order),
unless `NULLS FIRST`/`NULLS LAST` is given. Non-null values use §5 ordering.
`0.0` and `-0.0` are equal.

For `DISTINCT`, `GROUP BY`, `UNION`-like deduplication and `COUNT(DISTINCT)`,
two NULLs are considered *not distinct* (they form one group). Numeric values of
the same type are distinct iff unequal. DECIMAL values compare by value
(`1.50 = 1.5`).

## 8. CAST

`CAST(x AS T)`; NULL input ⇒ NULL output. Supported conversions:

| from \ to | BOOLEAN | INT64 | DECIMAL(p,s) | FLOAT64 | STRING | DATE | TIMESTAMP |
|---|---|---|---|---|---|---|---|
| BOOLEAN | id | 0/1 | – | – | `true`/`false` | – | – |
| INT64 | ≠0 | id | exact (overflow ⇒ `NUMERIC_OVERFLOW`) | nearest | decimal digits | – | – |
| DECIMAL | – | truncate toward zero | rescale, round half away from zero; overflow ⇒ `NUMERIC_OVERFLOW` | nearest | canonical decimal text (§9) | – | – |
| FLOAT64 | – | truncate toward zero; out of range ⇒ `NUMERIC_OVERFLOW` | round half away from zero; overflow ⇒ `NUMERIC_OVERFLOW` | id | implementation-defined round-trip text | – | – |
| STRING | `true`/`false` (case-insensitive, trimmed) | trimmed decimal integer | trimmed decimal text, rounding half away if more fractional digits | any float syntax incl. exponent, trimmed | id | `YYYY-MM-DD` | timestamp syntax (§3) |
| DATE | – | – | – | – | `YYYY-MM-DD` | id | midnight |
| TIMESTAMP | – | – | – | – | §9 text | date part (truncate) | id |

`–` means `TYPE_ERROR` at validation. An unparsable string ⇒ `CONVERSION_ERROR`;
a syntactically valid numeric string whose value does not fit the target type ⇒
`NUMERIC_OVERFLOW` (note: ingestion reports such values as `CONVERSION_ERROR`).
Strings parsed as numbers accept an optional leading `+`/`-`. An unknown type
name in `CAST` ⇒ `SEMANTIC_ERROR`; invalid DECIMAL parameters (p > 18, s > p) ⇒
`SEMANTIC_ERROR`.

## 9. Canonical value serialization (results, JSON)

Results are serialized as JSON values:

| Type | JSON |
|---|---|
| NULL (any type) | `null` |
| BOOLEAN | `true` / `false` |
| INT64 | JSON integer, e.g. `-42` (full 64-bit precision; never in exponent form) |
| FLOAT64 | JSON number. Any representation that parses back to the identical binary64 value is acceptable (e.g. `0.1`, `1e-07`, `3.0`, `3`). Consumers MUST compare FLOAT64 results with tolerance (see acceptance). |
| DECIMAL(p,s) | JSON **string** with exactly `s` fractional digits, a leading `-` for negative values, no `+`, at least one integer digit, no exponent: `"-0.50"`, `"12"` (s=0), `"0.000"` |
| STRING | JSON string. Engines MUST escape `"` `\` and control characters < U+0020; non-ASCII MAY be emitted raw (UTF-8) or as `\uXXXX` escapes. |
| DATE | JSON string `"YYYY-MM-DD"` |
| TIMESTAMP | JSON string `"YYYY-MM-DD HH:MM:SS"` when the microsecond part is 0, else `"YYYY-MM-DD HH:MM:SS.ffffff"` (exactly 6 digits) |

Years are always 4 digits (zero padded: `0001-01-01`).
