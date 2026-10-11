# Change request CR-2: `DECIMAL` precision 38 (PQCF v2)

Status: adopted for the *architectural change* experiment family (capability
`change.decimal38`). Applies identically to every language. Spec version for
engines claiming this change: 1.2.0-cr2 (it composes with CR-1).

The change raises the maximum `DECIMAL` precision from 18 to 38 digits. It is
designed so that **every existing conformance case keeps its expected result**
(one base-suite fixture is replaced, §8):
decimals of precision ≤ 18 ("narrow") behave exactly as before, and only
expressions that involve a decimal of precision 19–38 ("wide") use the new
rules. The change reaches the type system, literals, arithmetic, aggregates,
CAST, ingestion, the result protocol and the storage format.

## 1. Type domain (replaces the `DECIMAL(p,s)` row of `types.md` §1)

`DECIMAL(p,s)` with `1 ≤ p ≤ 38`, `0 ≤ s ≤ p`; value = unscaled / 10ˢ where
unscaled is an integer with at most `p` digits (|unscaled| < 10ᵖ). A decimal
type is *narrow* if `p ≤ 18` and *wide* if `p > 18`.

Aliases are unchanged (`DECIMAL` without parameters is still `DECIMAL(18,0)`).
`p > 38`, `p < 1` or `s > p` in `CAST` or a schema ⇒ `SEMANTIC_ERROR` (CAST) /
`INVALID_REQUEST` (load schema; this CR fixes the code, which the base spec
leaves open for invalid schema types).

## 2. Result precision `W`

Every rule of the base spec that produces the precision **18** for a decimal
result now produces the precision `W`:

* `W = 18` if every DECIMAL operand involved is narrow (INT64 operands do not
  count), and
* `W = 38` if at least one DECIMAL operand is wide.

This applies to:

| base rule | where | becomes |
|---|---|---|
| INT64 ⊕ DECIMAL(p,s) common type `DECIMAL(18,s)` | types.md §2 | `DECIMAL(W,s)` |
| DECIMAL ⊕ DECIMAL common type `DECIMAL(18,max(s1,s2))` | types.md §2, semantics.md §13 (CASE, COALESCE), CR-1 `UNION ALL` | `DECIMAL(W,max(s1,s2))` |
| `+`, `-` result `DECIMAL(18,max(s1,s2))` | types.md §4 | `DECIMAL(W,max(s1,s2))` |
| `*` result `DECIMAL(18,s1+s2)`, `s1+s2 > 18` ⇒ `TYPE_ERROR` | types.md §4 | `DECIMAL(W,s1+s2)`, `s1+s2 > W` ⇒ `TYPE_ERROR` |
| result needing more than 18 digits ⇒ `NUMERIC_OVERFLOW` | types.md §4 | more than `W` digits |
| `SUM(DECIMAL(p,s))` → `DECIMAL(18,s)` | functions.md | `DECIMAL(W,s)` (W from `p`) |
| `ROUND(DECIMAL(p,s), n)` → `DECIMAL(18, max(0,min(n,s)))` | functions.md | `DECIMAL(W, …)` |
| `FLOOR`/`CEIL(DECIMAL(p,s))` → `DECIMAL(18,0)` | functions.md | `DECIMAL(W,0)` |

Consequences worth stating explicitly:

* `SUM` over a **narrow** column still overflows beyond 18 digits; to sum into
  38 digits, cast the argument: `SUM(CAST(x AS DECIMAL(38,2)))`.
* Unary `-`/`+`, `ABS`, `MIN`, `MAX`, `NULLIF` keep the operand type
  (`ABS(DECIMAL(38,0))` of `-10³⁷…` cannot overflow because |v| < 10ᵖ).
* `/` still yields `FLOAT64`; `%` on decimals is still `TYPE_ERROR`; `AVG`
  is still `FLOAT64` (the sum SHOULD be exact before the final division).
* Intermediate computations MUST be exact. A product of two wide operands needs
  up to 76 digits before the overflow check; engines may use 256-bit or
  arbitrary-precision intermediates.

## 3. Literals (replaces the decimal-literal row of `types.md` §3)

A literal with a decimal point and without exponent has type `DECIMAL(p,s)`
computed as before if `p ≤ 38`; if `p > 38` it is `FLOAT64`. (Before this
change the limit was 18: literals of 19–38 significant digits were `FLOAT64`.)
Digits-only literals are unchanged: they are `INT64`, and outside the INT64
range they are a `NUMERIC_OVERFLOW` error (write `12345678901234567890.` or
`CAST('…' AS DECIMAL(38,0))` for a wide integer value).

## 4. Comparison (resolves SPEC-Q-001)

Comparisons between INT64 and DECIMAL values, and between decimals of any
precision/scale, compare the **exact mathematical values** and never raise
`NUMERIC_OVERFLOW` (this applies to `= <> < <= > >=`, `BETWEEN`, `IN`, simple
`CASE`, `NULLIF`, join conditions, `MIN`/`MAX`, `ORDER BY`, `GROUP BY` and
`DISTINCT` keys). Example: `9223372036854775807 > 1.5` is `TRUE` (it was a
`NUMERIC_OVERFLOW` under the literal promotion rule). DECIMAL vs FLOAT64 is
unchanged (the decimal is converted to the nearest FLOAT64).

## 5. CAST (amends `types.md` §8)

* Target `DECIMAL(p,s)` accepts `1 ≤ p ≤ 38`. All conversions to DECIMAL keep
  their rules (exact for INT64, rescale with round half away from zero,
  overflow ⇒ `NUMERIC_OVERFLOW`).
* DECIMAL → INT64 truncates toward zero; a result outside the INT64 range ⇒
  `NUMERIC_OVERFLOW` (now reachable with wide decimals).
* DECIMAL → FLOAT64 yields the FLOAT64 nearest to the exact decimal value.
* FLOAT64 → DECIMAL uses the exact binary value of the double, then rounds half
  away from zero to scale `s` (e.g. `CAST(0.1e0 AS DECIMAL(38,30))` is
  `"0.100000000000000005551115123126"`).
* DECIMAL → STRING: canonical text (unchanged rule, up to 38 digits).

## 6. Ingestion and protocol

* Explicit schemas (CSV, JSON, JSONL) accept `DECIMAL(p,s)` with `p ≤ 38`; the
  ingestion rules are otherwise unchanged (exact, no rounding, value must fit
  `p`). JSON numbers converted to DECIMAL MUST use the number's literal text,
  never a binary floating-point intermediate.
* Inference still never yields DECIMAL.
* Results: wide decimals serialize exactly like narrow ones (JSON string,
  exactly `s` fractional digits, types.md §9); type names such as
  `DECIMAL(38,10)` appear in result metadata and `schema`.
* Native kernels are not extended: their ABI covers 64-bit values only. Engines
  MUST NOT pass wide decimal columns to kernels (fall back to their own code).

## 7. Storage: PQCF format version 2

PQCF v2 is PQCF v1 (`spec/storage/pqcf-v1.md`) with these differences:

1. Header `format_version` = 2 and metadata `"format_version": 2` (a header /
   metadata version mismatch ⇒ `STORAGE_CORRUPT`).
2. Columns of wide decimal type (`p > 18`) are allowed. Their values are stored
   as **128-bit two's-complement little-endian** unscaled integers:
   * `PLAIN`: n × i128 (16 bytes each);
   * `RLE`: `u32 R`, then R × `{ i128 value, u32 run_length }` (20 bytes per
     run, packed);
   * validity: |unscaled| < 10ᵖ, else `STORAGE_CORRUPT`;
   * chunk `min`/`max` statistics are canonical decimal strings, as in v1.
   Narrow decimal columns keep the v1 i64 layout inside v2 files.
3. **Writer rule:** a table that has at least one wide decimal column MUST be
   written as v2; every other table MUST be written as v1 (so files remain
   readable by v1-only engines whenever possible).
4. **Reader rule:** a v2-capable reader reads v1 and v2. A v1 file that declares
   a wide decimal column ⇒ `STORAGE_CORRUPT`. `format_version` > 2 or `flags` ≠ 0
   ⇒ `STORAGE_VERSION_UNSUPPORTED`.

Indexes (`BTREE`, `HASH`) on wide decimal columns behave as for any other
orderable type, including persistence in PQCF metadata.

## 8. Test changes

* New public cases `tests/conformance/cases/changes/decimal38.pqt` and hidden
  cases; new reference fixtures `fixtures/pqcf/wide_*.pqcf` and
  `fixtures/pqcf/corrupt/wide_*.pqcf` produced by the reference writer
  (`tools/validation/pqcf.py`, which supports v2).
* The base-suite fixture `corrupt/version2.pqcf` (a v1 body with header version
  2, expected `STORAGE_VERSION_UNSUPPORTED`) becomes ambiguous under this change
  (a v2 reader sees a header/metadata mismatch). It is replaced by
  `corrupt/version3.pqcf`, which every reader — v1-only or v2 — must reject
  with `STORAGE_VERSION_UNSUPPORTED`. No other existing case changes.
* Expected values of the new cases cannot come from the SQLite oracle (SQLite
  has no 38-digit decimals); they were computed with Python's `decimal` module
  at 100-digit precision and reviewed by hand.

## 9. Acceptance

* The engine claims `change.decimal38` (in addition to all capabilities it
  claimed before; it keeps `change.union_all`).
* `changes/decimal38` cases pass, and every case that passed before still passes
  (session, HTTP, `--modes`, native).
* `README.md` documents the decimal representation chosen for wide values and
  how narrow/wide arithmetic is dispatched.
