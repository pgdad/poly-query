# Internal module API (AArch64, AAPCS64)

All structures/constants are in `include/pq.inc`. Registers: arguments in
x0..x7 / d0..d7, results in x0 (x1 second result) / d0. Every function keeps
a frame record and preserves x19-x28, d8-d15. Errors: functions documented
as "raises" call `pq_raise*` (longjmp to the request dispatcher, never return).
"status" results: 0 = ok, other values documented per function.

Per-request memory: `arena_alloc` (request arena `g_arena`, reset after every
request). Persistent memory: table arenas (`arena_alloc_in(tbl+TBL_ARENA, n)`).

## rt.S — runtime (errors, memory, buffers, strings, misc)

| function | in | out | notes |
|---|---|---|---|
| `pq_raise` | w0 code, x1 msg cstr | noreturn | |
| `pq_raise_s` | w0 code, x1 prefix cstr, x2 ptr, x3 len | noreturn | message = prefix + `'` + bytes + `'` |
| `pq_raise_pos` | w0 code, x1 msg cstr, w2 line, w3 col | noreturn | adds details {line,column} |
| `arena_alloc` | x0 size | x0 ptr | request arena, 16-byte aligned, not zeroed; budget ⇒ RESOURCE_LIMIT |
| `arena_zalloc` | x0 size | x0 ptr | zeroed |
| `arena_alloc_in` | x0 Arena*, x1 size | x0 ptr | any arena, 16-aligned, not zeroed |
| `arena_free` | x0 Arena* | – | frees all chunks, arena becomes empty (reusable) |
| `str_new` | x0 ptr, x1 len | x0 Str* | copy into request arena |
| `str_new_in` | x0 Arena*, x1 ptr, x2 len | x0 Str* | copy into given arena |
| `ci_eq` | x0 p1, x1 l1, x2 p2, x3 l2 | w0 1/0 | ASCII case-insensitive equality |
| `str_ieq` | x0 Str*, x1 Str* | w0 1/0 | ASCII case-insensitive equality |
| `str_ieq_c` | x0 Str*, x1 cstr | w0 1/0 | vs. C string |
| `ci_cmp` | x0 p1, x1 l1, x2 p2, x3 l2 | w0 <0/0/>0 | ASCII case-insensitive ordering |
| `bytes_cmp` | x0 p1, x1 l1, x2 p2, x3 l2 | w0 -1/0/1 | bytewise (memcmp then length) |
| `buf_reserve` | x0 Buf*, x1 extra | x0 write ptr | ensures cap ≥ len+extra |
| `buf_putc` | x0 Buf*, w1 byte | – | |
| `buf_put` | x0 Buf*, x1 ptr, x2 len | – | |
| `buf_puts` | x0 Buf*, x1 cstr | – | |
| `buf_put_i64` | x0 Buf*, x1 value | – | signed decimal |
| `buf_put_u64` | x0 Buf*, x1 value | – | unsigned decimal |
| `buf_put_jstr` | x0 Buf*, x1 ptr, x2 len | – | JSON string literal incl. quotes, escapes `"` `\` and < 0x20 |
| `buf_put_f64` | x0 Buf*, d0 value | – | shortest round-trip JSON number (-0 ⇒ 0) |
| `now_us` | – | x0 µs | CLOCK_MONOTONIC |
| `check_deadline` | – | – | raises TIMEOUT if `g_deadline` (µs, 0 = none) passed |

Globals (rt.S): `g_arena` (Arena), `g_out` (Buf, response line), `g_deadline`,
`g_test_functions` (u32), `g_max_query_mem` (bytes), `g_max_ingest_bytes`,
`g_max_table_rows`, `g_pending_table` (Table* freed if an error occurs).

## values.S / datetime.S / decimal.S / types.S — value library

| function | in | out |
|---|---|---|
| `trim_ws` | x0 ptr, x1 len | x0 ptr, x1 len (ASCII space/tab trimmed both ends) |
| `trim_all_ws` | x0 ptr, x1 len | x0 ptr, x1 len (space, tab, CR, LF) |
| `parse_bool` | x0 ptr, x1 len | x0 0/1, w1 status (1 = invalid); `true`/`false` case-insensitive, no trimming |
| `parse_int64` | x0 ptr, x1 len | x0 value, w1 status (1 syntax, 2 overflow); `^[+-]?[0-9]+$` |
| `parse_float` | x0 ptr, x1 len | d0 value, w1 status (1 syntax, 2 not finite); `^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$` |
| `parse_decimal` | x0 ptr, x1 len, w2 prec, w3 scale, w4 mode | x0 unscaled, w1 status (1 syntax, 2 does not fit precision, 3 too many fractional digits (mode 0 only)); syntax `^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)$`; mode 0 exact (ingestion), mode 1 round half away from zero (CAST) |
| `parse_date` | x0 ptr, x1 len | x0 days, w1 status (1 invalid); strict `YYYY-MM-DD`, valid calendar date 0001..9999 |
| `parse_timestamp` | x0 ptr, x1 len, w2 allow_date | x0 micros, w1 status; `YYYY-MM-DD[ T]HH:MM:SS(.f{1,6})?`; if allow_date≠0 a bare date is accepted (midnight) |
| `days_from_civil` | x0 y, x1 m, x2 d | x0 days |
| `civil_from_days` | x0 days | x0 y, x1 m, x2 d |
| `fmt_date` | x0 Buf*, x1 days | – (no quotes) |
| `fmt_timestamp` | x0 Buf*, x1 micros | – (no quotes; `.ffffff` only if µs ≠ 0) |
| `fmt_decimal` | x0 Buf*, x1 unscaled, w2 scale | – (no quotes) |
| `write_value_json` | x0 Buf*, x1 payload, x2 isnull, w3 type | – JSON per types.md §9 |
| `value_to_str` | x0 payload, w1 type | x0 Str* (request arena) text per CAST-to-STRING rules |
| `value_cmp` | x0 a, x1 b, w2 type | w0 -1/0/1 (same type, non-null) |
| `pow10_i64` | w0 n (0..18) | x0 10^n |
| `dec_fits` | x0 unscaled, w1 prec | w0 1/0 |
| `dec_rescale` | x0 unscaled, w1 from_scale, w2 to_scale | x0, w1 status (2 overflow > 18 digits); rounds half away when reducing |
| `dec_to_f64` | x0 unscaled, w1 scale | d0 (correctly rounded) |
| `f64_to_dec` | d0 value, w1 prec, w2 scale | x0 unscaled, w1 status (2 overflow); round half away |
| `cast_value` | x0 payload, w1 from_type, w2 to_type | x0 payload; raises CONVERSION_ERROR / NUMERIC_OVERFLOW; caller handles NULL; from==T_NULL never passed |
| `cast_allowed` | w0 from_type, w1 to_type | w0 1/0 (types.md §8 matrix; T_NULL ⇒ 1) |
| `type_from_name` | x0 ptr, x1 len, w2 nparams (0..2), x3 p, x4 s | w0 type, or -1 unknown name, -2 invalid parameters |
| `type_parse` | x0 ptr, x1 len | w0 type / -1 / -2 — parses text like `decimal(10, 2)`, `INT` |
| `type_write` | x0 Buf*, w1 type | – canonical name (`DECIMAL(18,2)`; T_NULL ⇒ `STRING`) |

## json.S — JSON

| function | in | out |
|---|---|---|
| `json_parse` | x0 ptr, x1 len | x0 JNode* or 0 if invalid (strict RFC 8259, whole input = one value, surrounding whitespace allowed) |
| `json_parse_prefix` | x0 ptr, x1 len | x0 JNode* or 0, x1 bytes consumed (leading/trailing whitespace consumed) |
| `json_get` | x0 JNode* (object), x1 key cstr | x0 value JNode* or 0 (exact key match) |
| `json_write` | x0 Buf*, x1 JNode* | – compact serialization |

## lexer.S / parser.S

| function | in | out |
|---|---|---|
| `parse_sql` | x0 ptr, x1 len | x0 Statement*; raises PARSE_ERROR (with position), UNSUPPORTED (FULL/RIGHT/UNION), NUMERIC_OVERFLOW (int literal), CONVERSION_ERROR (bad DATE/TIMESTAMP literal), SEMANTIC_ERROR (unknown CAST type) |

## ingest.S

| function | in | out |
|---|---|---|
| `ingest` | x0 Table* (zeroed, arena empty), x1 data ptr, x2 len, w3 format FMT_*, x4 Schema* or 0, w5 header (CSV), w6 delimiter byte (CSV) | fills TBL_NCOLS/NROWS/COLS (all in the table arena); raises INGEST_ERROR / CONVERSION_ERROR / RESOURCE_LIMIT |

## binder.S / eval.S

| function | in | out |
|---|---|---|
| `bind_query` | x0 Query* | x0 BoundQuery*; raises SEMANTIC/TYPE/UNSUPPORTED/INVALID_ARGUMENT |
| `eval` | x0 Node*, x1 EvalCtx* | x0 payload, x1 isnull; raises runtime errors |
| `agg_init` | x0 BoundQuery* | x0 state* |
| `agg_step` | x0 BoundQuery*, x1 state*, x2 EvalCtx* | – |
| `agg_finish` | x0 BoundQuery*, x1 state* | x0 cell array (16 bytes/slot) |

## catalog.S / exec.S / protocol.S / main.S

| function | in | out |
|---|---|---|
| `catalog_find` | x0 ptr, x1 len | x0 Table* or 0 (case-insensitive) |
| `exec_query` | x0 BoundQuery* | x0 ResultSet* |
