# Functions

Function names are case-insensitive. Wrong number of arguments or an unknown
function ⇒ `SEMANTIC_ERROR`. An argument documented as *constant* that is not a
constant expression ⇒ `SEMANTIC_ERROR`. Argument of an unsupported type ⇒ `TYPE_ERROR`.
Unless stated otherwise, a NULL argument yields NULL. "numeric" means INT64,
DECIMAL or FLOAT64.

## 1. Scalar functions

| Function | Argument types | Result | Semantics |
|---|---|---|---|
| `ABS(x)` | numeric | same type | absolute value; `ABS(INT64_MIN)` ⇒ `NUMERIC_OVERFLOW` |
| `ROUND(x)` / `ROUND(x, n)` | numeric, n: INT64 **constant** | see right | round half away from zero to `n` (default 0) fractional digits; n may be negative (round to tens etc.). INT64 → INT64 (n ≥ 0 is identity). DECIMAL(p,s) → DECIMAL(18, max(0, min(n, s))). FLOAT64 → FLOAT64 (implementation of ties may be affected by binary representation; tests avoid exact ties). |
| `FLOOR(x)`, `CEIL(x)` (alias `CEILING`) | numeric | INT64→INT64; DECIMAL(p,s)→DECIMAL(18,0); FLOAT64→FLOAT64 | |
| `SQRT(x)` | numeric | FLOAT64 | x < 0 ⇒ `INVALID_ARGUMENT` |
| `POWER(x, y)` | numeric, numeric | FLOAT64 | non-finite result ⇒ `NUMERIC_OVERFLOW`; `0^negative` ⇒ `DIVISION_BY_ZERO`; negative base with non-integral exponent ⇒ `INVALID_ARGUMENT` |
| `MOD(a, b)` | INT64, INT64 | INT64 | same as `a % b` |
| `LENGTH(s)` | STRING | INT64 | number of code points |
| `UPPER(s)`, `LOWER(s)` | STRING | STRING | ASCII letters only are case-mapped; other characters unchanged |
| `SUBSTR(s, start [, len])` (alias `SUBSTRING`) | STRING, INT64, INT64 | STRING | 1-based code point positions. Returns code points at positions `i` with `max(start,1) ≤ i` and (if len given) `i < start + len`. `len < 0` ⇒ `INVALID_ARGUMENT`. |
| `TRIM(s)`, `LTRIM(s)`, `RTRIM(s)` | STRING | STRING | remove leading/trailing U+0020 spaces only |
| `REPLACE(s, from, to)` | STRING×3 | STRING | replace all non-overlapping occurrences left to right; `from = ''` ⇒ s unchanged |
| `CONCAT(a, b, …)` | ≥1 args, any types | STRING | concatenation of the STRING casts of non-NULL args; NULL args are **skipped** (result never NULL). FLOAT64 args ⇒ `TYPE_ERROR` (text form is implementation-defined). |
| `a \|\| b` | STRING, STRING | STRING | NULL if either is NULL; non-STRING operand ⇒ `TYPE_ERROR` |
| `COALESCE(a, b, …)` | ≥1 args, common type (as for CASE, semantics.md §13) | common | first non-NULL |
| `NULLIF(a, b)` | comparable | type of a | NULL if `a = b` is TRUE else a |
| `YEAR(d)`, `MONTH(d)`, `DAY(d)` | DATE or TIMESTAMP | INT64 | calendar fields |
| `HOUR(t)`, `MINUTE(t)`, `SECOND(t)` | TIMESTAMP | INT64 | clock fields (SECOND is the integer second) |
| `DATE_TRUNC(unit, t)` | unit: STRING constant `'year'`,`'month'`,`'day'`,`'hour'`,`'minute'`; t: DATE or TIMESTAMP | TIMESTAMP | truncate; unknown unit ⇒ `INVALID_ARGUMENT` |
| `DATE_DIFF(unit, a, b)` | `'day'`; DATE/TIMESTAMP | INT64 | `day`: number of day boundaries from a to b (b − a in whole days of the date parts) |
| `PQ_SLEEP(ms)` | INT64 | INT64 | **test-only**; enabled only with `--enable-test-functions`, else `SEMANTIC_ERROR` (unknown function). Sleeps `ms` milliseconds (per evaluation) and returns `ms`. MUST observe cancellation/timeout within 20 ms. |

`CAST` is described in types.md §8. `CASE`, `LIKE`, `BETWEEN`, `IN`, `EXISTS`,
`IS NULL` in semantics.md.

## 2. Aggregate functions

| Function | Input | Result type | Semantics |
|---|---|---|---|
| `COUNT(*)` | – | INT64 | number of rows in the group |
| `COUNT(x)` | any | INT64 | number of non-NULL x |
| `COUNT(DISTINCT x)` | any | INT64 | number of distinct non-NULL x |
| `SUM(x)` | INT64 | INT64 | overflow ⇒ `NUMERIC_OVERFLOW` (exact: an intermediate overflow that is undone later still counts as overflow only if the **final** sum is out of range; engines MAY use wider accumulators) |
| `SUM(x)` | DECIMAL(p,s) | DECIMAL(18,s) | exact; final result beyond 18 digits ⇒ `NUMERIC_OVERFLOW` |
| `SUM(x)` | FLOAT64 | FLOAT64 | summation order is implementation-defined |
| `AVG(x)` | numeric | FLOAT64 | `SUM/COUNT` computed in FLOAT64 (DECIMAL/INT64 sums SHOULD be computed exactly before the final division) |
| `MIN(x)`, `MAX(x)` | any orderable type | same as x | per types.md §7; NULLs ignored |
| `SUM(DISTINCT x)`, `AVG(DISTINCT x)` | numeric | as above | over distinct non-NULL values |
| `MIN/MAX(DISTINCT x)` | – | – | allowed, same as without DISTINCT |

All aggregates except `COUNT` return NULL when there are no non-NULL inputs.
`DISTINCT` is only allowed with a single argument. `*` only with COUNT.
Using an aggregate outside `SELECT`, `HAVING`, `ORDER BY` ⇒ `SEMANTIC_ERROR`.
