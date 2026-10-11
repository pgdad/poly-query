// =============================================================================
// protocol.S — JSON request handling (protocol.md §3-§6).
//
// handle_request_line parses one JSON request, dispatches on "op" and writes
// exactly one response line to stdout. Errors raised anywhere below unwind
// (longjmp) back here and become error responses. After every request the
// request arena is released.
// =============================================================================
#include "pq.inc"

    .bss
    .p2align 3
g_cur_id:       .skip 8         // JNode* of the request "id" (or 0)
g_req_start:    .skip 8         // µs timestamp of request start

    .section .rodata
k_id:       .asciz "id"
k_op:       .asciz "op"
k_table:    .asciz "table"
k_format:   .asciz "format"
k_path:     .asciz "path"
k_data:     .asciz "data"
k_schema:   .asciz "schema"
k_options:  .asciz "options"
k_replace:  .asciz "replace"
k_header:   .asciz "header"
k_delim:    .asciz "delimiter"
k_name:     .asciz "name"
k_type:     .asciz "type"
k_sql:      .asciz "sql"
k_ms:       .asciz "ms"
k_max_rows: .asciz "max_rows"
k_timeout:  .asciz "timeout_ms"
k_result:   .asciz "result"
k_mode:     .asciz "mode"
k_threads:  .asciz "threads"
k_join:     .asciz "join"
k_optimize: .asciz "optimize"
k_use_idx:  .asciz "use_indexes"
k_native:   .asciz "native"
k_layout:   .asciz "layout"
k_dict:     .asciz "dictionary"
v_row:      .asciz "row"
v_column:   .asciz "column"
v_csv:      .asciz "csv"
v_json:     .asciz "json"
v_jsonl:    .asciz "jsonl"
v_rows:     .asciz "rows"
v_count:    .asciz "count"
v_auto:     .asciz "auto"

op_names:
    .quad o_load, op_load
    .quad o_query, op_query
    .quad o_tables, op_tables
    .quad o_schema, op_schema
    .quad o_drop, op_drop
    .quad o_reset, op_reset
    .quad o_version, op_version
    .quad o_caps, op_capabilities
    .quad o_sleep, op_sleep
    .quad o_explain, op_explain
    .quad o_save, op_unsupported
    .quad o_open, op_unsupported
    .quad o_stats, op_stats
    .quad 0, 0
o_load:     .asciz "load"
o_query:    .asciz "query"
o_tables:   .asciz "tables"
o_schema:   .asciz "schema"
o_drop:     .asciz "drop"
o_reset:    .asciz "reset"
o_version:  .asciz "version"
o_caps:     .asciz "capabilities"
o_sleep:    .asciz "sleep"
o_explain:  .asciz "explain"
o_save:     .asciz "save"
o_open:     .asciz "open"
o_stats:    .asciz "stats"

r_id:       .asciz "{\"id\":"
r_null:     .asciz "null"
r_ok:       .asciz ",\"ok\":true"
r_err:      .asciz ",\"ok\":false,\"error\":{\"code\":\""
r_msg:      .asciz "\",\"message\":"
r_details:  .asciz ",\"details\":{\"line\":"
r_column:   .asciz ",\"column\":"
r_caps:     .asciz ",\"protocol_version\":1,\"capabilities\":[\"phase1\",\"ingest.csv\",\"ingest.json\",\"ingest.jsonl\",\"sql.basic\",\"test.functions\",\"phase2\",\"sql.groupby\",\"sql.join\",\"sql.functions\",\"sql.subquery\",\"sql.cte\",\"sql.correlated_subquery\"]"
r_version:  .asciz ",\"engine\":\"polyquery-arm64-asm\",\"engine_version\":\"0.1.0\",\"language\":\"arm64-asm-engine\",\"protocol_version\":1,\"spec_version\":\"1.0.0\",\"runtime\":\"GNU as (AArch64) + glibc\",\"build\":{\"profile\":\"release\",\"flags\":\"-g\"}"
r_tables:   .asciz ",\"tables\":["
r_name:     .asciz "{\"name\":"
r_rowcount: .asciz ",\"row_count\":"
r_table:    .asciz ",\"table\":"
r_columns:  .asciz ",\"columns\":["
r_type:     .asciz ",\"type\":\""
r_indexes:  .asciz ",\"indexes\":["
r_column_k: .asciz ",\"column\":"
r_kind_h:   .asciz ",\"kind\":\"HASH\"}"
r_kind_b:   .asciz ",\"kind\":\"BTREE\"}"
r_layout_c: .asciz ",\"layout\":\"column\""
r_layout_r: .asciz ",\"layout\":\"row\""
r_nullcnt:  .asciz ",\"null_count\":"
r_distinct: .asciz ",\"distinct_count\":"
r_min:      .asciz ",\"min\":"
r_max:      .asciz ",\"max\":"
r_rows:     .asciz ",\"rows\":["
r_stats:    .asciz ",\"stats\":{\"elapsed_us\":"
r_plan:     .asciz ",\"plan\":"
s_plan:     .asciz "plan"

m_badjson:  .asciz "request is not a valid JSON object"
m_noop:     .asciz "missing or non-string 'op'"
m_unknownop: .asciz "unknown op "
m_field:    .asciz "missing or ill-typed field "
m_unsupop:  .asciz "operation not supported by this engine: "
m_notable:  .asciz "unknown table "
m_exists:   .asciz "table already exists "
m_format:   .asciz "format must be csv, json or jsonl"
m_pathdata: .asciz "exactly one of 'path' or 'data' is required"
m_denied:   .asciz "path not permitted "
m_nofile:   .asciz "file not found "
m_ioerr:    .asciz "cannot read file "
m_toobig:   .asciz "input exceeds --max-ingest-bytes"
m_schema:   .asciz "schema must be an array of {name, type} objects"
m_schtype:  .asciz "unknown or invalid type in schema "
m_schdup:   .asciz "duplicate column name in schema "
m_schempty: .asciz "empty column name in schema"
m_delim:    .asciz "delimiter must be a single ASCII character"
m_noheader: .asciz "header=false requires an explicit schema"
m_sleep:    .asciz "sleep requires --enable-test-functions"
m_maxrows:  .asciz "result exceeds max_rows"
m_optval:   .asciz "unsupported value for query option "
m_stmt:     .asciz "only SELECT queries are supported in this engine phase"
m_emptytab: .asciz "table name must not be empty"
    .text

// ------------------------------------------------------------- helpers -------

// out_puts(x0 cstr)
LFUNC out_puts
    mov  x1, x0
    ADR_L x0, g_out
    b    buf_puts
ENDF out_puts

// out_str(x0 Str*): JSON string
LFUNC out_str
    ldr  x2, [x0, #STR_LEN]
    add  x1, x0, #STR_DATA
    ADR_L x0, g_out
    b    buf_put_jstr
ENDF out_str

// out_i64(x0 value)
LFUNC out_i64
    mov  x1, x0
    ADR_L x0, g_out
    b    buf_put_i64
ENDF out_i64

// out_c(w0 char)
LFUNC out_c
    mov  w1, w0
    ADR_L x0, g_out
    b    buf_putc
ENDF out_c

// out_begin(): reset the response buffer and write {"id":<id>
LFUNC out_begin
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    ADR_L x0, g_out
    str  xzr, [x0, #BUF_LEN]
    ADR_L x0, r_id
    bl   out_puts
    LDR_G x1, g_cur_id
    cbz  x1, 1f
    ADR_L x0, g_out
    bl   json_write
    b    2f
1:  ADR_L x0, r_null
    bl   out_puts
2:  ldp  x29, x30, [sp], #16
    ret
ENDF out_begin

// out_begin_ok(): {"id":..,"ok":true
LFUNC out_begin_ok
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    bl   out_begin
    ADR_L x0, r_ok
    bl   out_puts
    ldp  x29, x30, [sp], #16
    ret
ENDF out_begin_ok

// out_flush(): append "}\n" and write the whole response to stdout.
LFUNC out_flush
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    mov  w0, #'}'
    bl   out_c
    mov  w0, #'\n'
    bl   out_c
    ADR_L x0, g_out
    ldr  x19, [x0, #BUF_PTR]
    ldr  x20, [x0, #BUF_LEN]
1:  cbz  x20, 9f
    mov  w0, #1
    mov  x1, x19
    mov  x2, x20
    bl   write
    cmp  x0, #0
    b.le 9f                         // stdout gone: give up on this response
    add  x19, x19, x0
    sub  x20, x20, x0
    b    1b
9:  ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF out_flush

// raise_field(x0 key cstr): INVALID_REQUEST "missing or ill-typed field 'key'"
LFUNC raise_field
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    str  x0, [sp, #16]
    bl   strlen
    mov  x3, x0
    ldr  x2, [sp, #16]
    ADR_L x1, m_field
    mov  w0, #ERR_INVALID_REQUEST
    bl   pq_raise_s
ENDF raise_field

// get_field(x0 obj, x1 key, w2 jtype, w3 required) -> x0 JNode* or 0
// A present field of another type (or a missing required one) is INVALID_REQUEST.
// A JSON null counts as absent.
LFUNC get_field
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    mov  x19, x1
    mov  w20, w2
    mov  w21, w3
    bl   json_get
    cbz  x0, 2f
    ldr  w1, [x0, #JN_TYPE]
    cmp  w1, #J_NULL
    b.eq 2f
    cmp  w20, #J_TRUE               // J_TRUE requested means "any boolean"
    b.ne 1f
    cmp  w1, #J_FALSE
    b.eq 3f
1:  cmp  w1, w20
    b.eq 3f
    mov  x0, x19
    bl   raise_field
2:  mov  x0, #0
    cbz  w21, 3f
    mov  x0, x19
    bl   raise_field
3:  ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
ENDF get_field

// get_str(x0 obj, x1 key, w2 required) -> x0 Str* or 0
LFUNC get_str
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    mov  w3, w2
    mov  w2, #J_STR
    bl   get_field
    cbz  x0, 1f
    ldr  x0, [x0, #JN_PTR]
1:  ldp  x29, x30, [sp], #16
    ret
ENDF get_str

// get_bool(x0 obj, x1 key, w2 default) -> w0 0/1
LFUNC get_bool
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    str  x2, [sp, #16]
    mov  w2, #J_TRUE
    mov  w3, #0
    bl   get_field
    cbz  x0, 1f
    ldr  w1, [x0, #JN_TYPE]
    cmp  w1, #J_TRUE
    cset w0, eq
    b    2f
1:  ldr  x0, [sp, #16]
2:  ldp  x29, x30, [sp], #32
    ret
ENDF get_bool

// get_int(x0 obj, x1 key, x2 default, x3 min) -> x0 value
// Must be an integer JSON number >= min, else INVALID_REQUEST.
LFUNC get_int
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    mov  x19, x1
    mov  x20, x2
    mov  x21, x3
    mov  w2, #J_NUM
    mov  w3, #0
    bl   get_field
    cbz  x0, 1f
    ldr  x1, [x0, #JN_PTR]
    ldr  x0, [x1, #STR_LEN]
    mov  x2, x0
    add  x0, x1, #STR_DATA
    mov  x1, x2
    bl   parse_int64
    cbnz w1, 2f
    cmp  x0, x21
    b.lt 2f
    b    3f
1:  mov  x0, x20
3:  ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
2:  mov  x0, x19
    bl   raise_field
ENDF get_int

// str_eq_c(x0 Str*, x1 cstr) -> w0 1/0 (exact)
LFUNC str_eq_c
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    add  x0, x0, #STR_DATA
    bl   strcmp
    cmp  w0, #0
    cset w0, eq
    ldp  x29, x30, [sp], #16
    ret
ENDF str_eq_c

// ----------------------------------------------------------- dispatcher ------

// handle_request_line(x0 ptr, x1 len): process one request, write one response.
FUNC handle_request_line
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    mov  x19, x0
    mov  x20, x1
    ADR_L x0, g_cur_id
    str  xzr, [x0]
    bl   now_us
    ADR_L x1, g_req_start
    str  x0, [x1]
    ADR_L x0, g_jmpbuf
    bl   setjmp
    cbnz w0, .Lhr_error
    mov  x0, x19
    mov  x1, x20
    bl   json_parse
    cbz  x0, .Lhr_badjson
    ldr  w1, [x0, #JN_TYPE]
    cmp  w1, #J_OBJ
    b.ne .Lhr_badjson
    mov  x21, x0
    ADR_L x1, k_id
    bl   json_get
    ADR_L x1, g_cur_id
    str  x0, [x1]
    // op
    mov  x0, x21
    ADR_L x1, k_op
    bl   json_get
    cbz  x0, .Lhr_noop
    ldr  w1, [x0, #JN_TYPE]
    cmp  w1, #J_STR
    b.ne .Lhr_noop
    ldr  x22, [x0, #JN_PTR]         // op Str*
    ADR_L x19, op_names
1:  ldr  x1, [x19]
    cbz  x1, .Lhr_unknownop
    mov  x0, x22
    bl   str_eq_c
    cbnz w0, 2f
    add  x19, x19, #16
    b    1b
2:  ldr  x2, [x19, #8]
    mov  x0, x21
    mov  x1, x22
    blr  x2                         // handler(x0 request, x1 op Str*)
    bl   out_flush
    b    .Lhr_done
.Lhr_badjson:
    RAISE ERR_INVALID_REQUEST, "request is not a valid JSON object"
.Lhr_noop:
    RAISE ERR_INVALID_REQUEST, "missing or non-string 'op'"
.Lhr_unknownop:
    mov  w0, #ERR_INVALID_REQUEST
    ADR_L x1, m_unknownop
    add  x2, x22, #STR_DATA
    ldr  x3, [x22, #STR_LEN]
    bl   pq_raise_s
.Lhr_error:
    // free a half-built table, then emit the error response
    LDR_G x19, g_pending_table
    cbz  x19, 3f
    add  x0, x19, #TBL_ARENA
    bl   arena_free
    mov  x0, x19
    bl   free
    ADR_L x0, g_pending_table
    str  xzr, [x0]
3:  bl   write_error_response
    bl   out_flush
.Lhr_done:
    ADR_L x0, g_arena
    bl   arena_free
    ADR_L x0, g_deadline
    str  xzr, [x0]
    ADR_L x0, g_arena_limit
    str  xzr, [x0]
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
ENDF handle_request_line

// write_error_response(): {"id":..,"ok":false,"error":{...}}  (without final })
LFUNC write_error_response
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    bl   out_begin
    ADR_L x0, r_err
    bl   out_puts
    ADR_L x0, g_err_code
    ldr  w0, [x0]
    bl   err_code_name
    bl   out_puts
    ADR_L x0, r_msg
    bl   out_puts
    // sanitise the message to ASCII so the response is always valid UTF-8
    ADR_L x19, g_err_msg
    mov  x20, x19
1:  ldrb w1, [x20]
    cbz  w1, 2f
    cmp  w1, #0x7f
    b.lo 11f
    mov  w1, #'?'
    strb w1, [x20]
11: add  x20, x20, #1
    b    1b
2:  ADR_L x0, g_out
    mov  x1, x19
    sub  x2, x20, x19
    bl   buf_put_jstr
    ADR_L x0, g_err_line
    ldr  w19, [x0]
    cbz  w19, 3f
    ADR_L x0, r_details
    bl   out_puts
    mov  x0, x19
    bl   out_i64
    ADR_L x0, r_column
    bl   out_puts
    ADR_L x0, g_err_col
    ldr  w0, [x0]
    bl   out_i64
    mov  w0, #'}'
    bl   out_c
3:  mov  w0, #'}'
    bl   out_c
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF write_error_response

// handle_request_batch(x0 ptr, x1 len): exec mode — one request object or an
// array of request objects. Each element is re-serialised to its own line
// (persistent buffer) because the request arena is reset per request.
FUNC handle_request_batch
    stp  x29, x30, [sp, #-80]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    stp  xzr, xzr, [sp, #64]       // (unused)
    mov  x19, x0
    mov  x20, x1
    // skip leading whitespace to see whether this is an array
    mov  x2, #0
1:  cmp  x2, x20
    b.hs 8f
    ldrb w3, [x19, x2]
    cmp  w3, #'['
    b.eq 2f
    cmp  w3, #' '
    b.eq 11f
    cmp  w3, #'\n'
    b.eq 11f
    cmp  w3, #'\r'
    b.eq 11f
    cmp  w3, #'\t'
    b.ne 8f
11: add  x2, x2, #1
    b    1b
2:  // array: parse once (request arena), serialise elements into a malloc buffer
    mov  x0, x19
    mov  x1, x20
    bl   json_parse
    cbz  x0, 8f
    mov  x21, x0
    sub  sp, sp, #32
    stp  xzr, xzr, [sp]
    stp  xzr, xzr, [sp, #16]
    ldr  w22, [x21, #JN_COUNT]
    ldr  x23, [x21, #JN_PTR]
    mov  x24, #0
3:  cmp  x24, x22
    b.hs 4f
    ldr  x1, [x23, x24, lsl #3]
    mov  x0, sp
    bl   json_write
    mov  x0, sp
    mov  w1, #'\n'
    bl   buf_putc
    add  x24, x24, #1
    b    3b
4:  ADR_L x0, g_arena
    bl   arena_free
    ldr  x21, [sp, #BUF_PTR]
    ldr  x22, [sp, #BUF_LEN]
    add  sp, sp, #32
    // process line by line
    mov  x23, #0                    // line start
5:  cmp  x23, x22
    b.hs 7f
    mov  x24, x23
6:  ldrb w3, [x21, x24]
    cmp  w3, #'\n'
    b.eq 61f
    add  x24, x24, #1
    b    6b
61: add  x0, x21, x23
    sub  x1, x24, x23
    bl   handle_request_line
    add  x23, x24, #1
    b    5b
7:  mov  x0, x21
    bl   free
    b    9f
8:  mov  x0, x19                    // single request (or invalid JSON)
    mov  x1, x20
    bl   handle_request_line
9:  ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x23, x24, [sp, #48]
    ldp  x29, x30, [sp], #80
    ret
ENDF handle_request_batch

// cli_version / cli_capabilities: print the response object for the CLI modes
FUNC cli_version
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    mov  x0, #0
    mov  x1, #0
    bl   op_version
    bl   out_flush
    ldp  x29, x30, [sp], #16
    ret
ENDF cli_version

FUNC cli_capabilities
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    mov  x0, #0
    mov  x1, #0
    bl   op_capabilities
    bl   out_flush
    ldp  x29, x30, [sp], #16
    ret
ENDF cli_capabilities

// ------------------------------------------------------------ operations -----
// Every handler: x0 = request object (JNode*), x1 = op name (Str*).
// It writes the response (without the closing brace) into g_out.

LFUNC op_capabilities
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    bl   out_begin_ok
    ADR_L x0, r_caps
    bl   out_puts
    ldp  x29, x30, [sp], #16
    ret
ENDF op_capabilities

LFUNC op_version
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    bl   out_begin_ok
    ADR_L x0, r_version
    bl   out_puts
    ldp  x29, x30, [sp], #16
    ret
ENDF op_version

LFUNC op_unsupported
    mov  x2, x1
    mov  w0, #ERR_UNSUPPORTED
    ADR_L x1, m_unsupop
    ldr  x3, [x2, #STR_LEN]
    add  x2, x2, #STR_DATA
    b    pq_raise_s
ENDF op_unsupported

LFUNC op_reset
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    bl   catalog_reset
    bl   out_begin_ok
    ldp  x29, x30, [sp], #16
    ret
ENDF op_reset

// lookup_table_field(x0 request) -> x0 Table* (NOT_FOUND if unknown)
LFUNC lookup_table_field
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    ADR_L x1, k_table
    mov  w2, #1
    bl   get_str
    mov  x19, x0
    add  x0, x19, #STR_DATA
    ldr  x1, [x19, #STR_LEN]
    bl   catalog_find
    cbnz x0, 1f
    mov  w0, #ERR_NOT_FOUND
    ADR_L x1, m_notable
    add  x2, x19, #STR_DATA
    ldr  x3, [x19, #STR_LEN]
    bl   pq_raise_s
1:  ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF lookup_table_field

LFUNC op_drop
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    bl   lookup_table_field
    bl   catalog_remove
    bl   out_begin_ok
    ldp  x29, x30, [sp], #16
    ret
ENDF op_drop

// write_table_columns(x0 Table*): ,"columns":[{"name":..,"type":..},...]
LFUNC write_table_columns
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    ldr  x19, [x0, #TBL_COLS]
    ldr  x20, [x0, #TBL_NCOLS]
    mov  x21, #0
    ADR_L x0, r_columns
    bl   out_puts
1:  cmp  x21, x20
    b.hs 2f
    cbz  x21, 11f
    mov  w0, #','
    bl   out_c
11: ldr  x0, [x19, #COL_NAME]
    ldr  w1, [x19, #COL_TYPE]
    bl   write_column_desc
    add  x19, x19, #COL_SIZE
    add  x21, x21, #1
    b    1b
2:  mov  w0, #']'
    bl   out_c
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
ENDF write_table_columns

// write_column_desc(x0 name Str*, w1 type): {"name":"..","type":".."}
LFUNC write_column_desc
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    mov  x19, x0
    mov  w20, w1
    ADR_L x0, r_name
    bl   out_puts
    mov  x0, x19
    bl   out_str
    ADR_L x0, r_type
    bl   out_puts
    ADR_L x0, g_out
    mov  w1, w20
    bl   type_write
    mov  w0, #'"'
    bl   out_c
    mov  w0, #'}'
    bl   out_c
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF write_column_desc

// write_table_header(x0 Table*): ,"table":"..","row_count":N
LFUNC write_table_header
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    str  x19, [sp, #16]
    mov  x19, x0
    ADR_L x0, r_table
    bl   out_puts
    ldr  x0, [x19, #TBL_NAME]
    bl   out_str
    ADR_L x0, r_rowcount
    bl   out_puts
    ldr  x0, [x19, #TBL_NROWS]
    bl   out_i64
    ldr  x19, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF write_table_header

LFUNC op_schema
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    bl   lookup_table_field
    mov  x19, x0
    bl   out_begin_ok
    mov  x0, x19
    bl   write_table_header
    mov  x0, x19
    bl   write_table_columns
    mov  x0, x19
    bl   write_table_indexes
    ADR_L x0, r_layout_c
    ldr  w9, [x19, #TBL_LAYOUT]
    cbz  w9, 1f
    ADR_L x0, r_layout_r
1:  bl   out_puts
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF op_schema

// write_table_indexes(x0 Table*): ,"indexes":[{"name":..,"column":..,"kind":..}]
//   x19 Index** list, x20 count, x21 index, x22 Index*, x23 table
LFUNC write_table_indexes
    stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    str  x23, [sp, #48]
    mov  x23, x0
    bl   index_list
    mov  x19, x0
    mov  x20, x1
    ADR_L x0, r_indexes
    bl   out_puts
    mov  x21, #0
1:  cmp  x21, x20
    b.hs 3f
    cbz  x21, 2f
    mov  w0, #','
    bl   out_c
2:  ldr  x22, [x19, x21, lsl #3]
    ADR_L x0, r_name
    bl   out_puts
    ldr  x0, [x22, #IX_NAME]
    bl   out_str
    ADR_L x0, r_column_k
    bl   out_puts
    ldr  x9, [x23, #TBL_COLS]
    ldr  x10, [x22, #IX_COL]
    add  x9, x9, x10, lsl #5
    ldr  x0, [x9, #COL_NAME]
    bl   out_str
    ldr  w9, [x22, #IX_KIND]
    ADR_L x0, r_kind_h
    cmp  w9, #IXK_HASH
    b.eq 21f
    ADR_L x0, r_kind_b
21: bl   out_puts
    add  x21, x21, #1
    b    1b
3:  mov  w0, #']'
    bl   out_c
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldr  x23, [sp, #48]
    ldp  x29, x30, [sp], #64
    ret
ENDF write_table_indexes

// op_stats: {"op":"stats","table":"t"} => row count and per-column
// null_count / distinct_count / min / max (protocol.md §5.8)
//   x19 table, x20 ColStats*, x21 column index, x22 Column*, x23 ColStats,
//   x24 1 if min/max are unknown
LFUNC op_stats
    stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    bl   lookup_table_field
    mov  x19, x0
    bl   table_stats
    mov  x20, x0
    bl   out_begin_ok
    mov  x0, x19
    bl   write_table_header
    ADR_L x0, r_columns
    bl   out_puts
    mov  x21, #0
1:  ldr  x9, [x19, #TBL_NCOLS]
    cmp  x21, x9
    b.hs 4f
    cbz  x21, 2f
    mov  w0, #','
    bl   out_c
2:  ldr  x22, [x19, #TBL_COLS]
    add  x22, x22, x21, lsl #5
    add  x23, x20, x21, lsl #5
    ldr  x0, [x22, #COL_NAME]
    ldr  w1, [x22, #COL_TYPE]
    bl   write_column_desc
    ADR_L x0, g_out                     // reopen the object written above
    ldr  x9, [x0, #BUF_LEN]
    sub  x9, x9, #1
    str  x9, [x0, #BUF_LEN]
    ADR_L x0, r_nullcnt
    bl   out_puts
    ldr  x0, [x23, #CST_NULLS]
    bl   out_i64
    ADR_L x0, r_distinct
    bl   out_puts
    ldr  x0, [x23, #CST_DISTINCT]
    bl   out_i64
    ldr  x9, [x23, #CST_NULLS]          // all NULL (or no rows): min/max null
    ldr  x10, [x19, #TBL_NROWS]
    cmp  x9, x10
    cset x24, hs
    ADR_L x0, r_min
    bl   out_puts
    ADR_L x0, g_out
    ldr  x1, [x23, #CST_MIN]
    mov  x2, x24
    ldr  w3, [x22, #COL_TYPE]
    bl   write_value_json
    ADR_L x0, r_max
    bl   out_puts
    ADR_L x0, g_out
    ldr  x1, [x23, #CST_MAX]
    mov  x2, x24
    ldr  w3, [x22, #COL_TYPE]
    bl   write_value_json
    mov  w0, #'}'
    bl   out_c
    add  x21, x21, #1
    b    1b
4:  mov  w0, #']'
    bl   out_c
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x23, x24, [sp, #48]
    ldp  x29, x30, [sp], #64
    ret
ENDF op_stats

// qsort comparator: two Table** by name, case-insensitive
LFUNC cmp_table_names
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    ldr  x0, [x0]
    ldr  x2, [x1]
    ldr  x0, [x0, #TBL_NAME]
    ldr  x2, [x2, #TBL_NAME]
    ldr  x1, [x0, #STR_LEN]
    ldr  x3, [x2, #STR_LEN]
    add  x0, x0, #STR_DATA
    add  x2, x2, #STR_DATA
    bl   ci_cmp
    ldp  x29, x30, [sp], #16
    ret
ENDF cmp_table_names

LFUNC op_tables
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    bl   catalog_snapshot           // x0 Table** (arena copy), x1 count
    mov  x19, x0
    mov  x20, x1
    mov  x2, #8
    ADR_L x3, cmp_table_names
    bl   qsort
    bl   out_begin_ok
    ADR_L x0, r_tables
    bl   out_puts
    mov  x21, #0
1:  cmp  x21, x20
    b.hs 2f
    cbz  x21, 11f
    mov  w0, #','
    bl   out_c
11: ldr  x22, [x19, x21, lsl #3]
    ADR_L x0, r_name
    bl   out_puts
    ldr  x0, [x22, #TBL_NAME]
    bl   out_str
    ADR_L x0, r_rowcount
    bl   out_puts
    ldr  x0, [x22, #TBL_NROWS]
    bl   out_i64
    mov  w0, #'}'
    bl   out_c
    add  x21, x21, #1
    b    1b
2:  mov  w0, #']'
    bl   out_c
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
ENDF op_tables

// op_sleep: {"op":"sleep","ms":N} (test functions only)
LFUNC op_sleep
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    str  x19, [sp, #16]
    ADR_L x2, g_test_functions
    ldr  w2, [x2]
    cbnz w2, 1f
    RAISE ERR_INVALID_REQUEST, "sleep requires --enable-test-functions"
1:  ADR_L x1, k_ms
    mov  w2, #J_NUM
    mov  w3, #1
    bl   get_field                  // required
    ldr  x1, [x0, #JN_PTR]
    add  x0, x1, #STR_DATA
    ldr  x1, [x1, #STR_LEN]
    bl   parse_int64
    cbnz w1, 3f
    tbnz x0, #63, 3f
    mov  x19, x0
    mov  x1, #1000
    mul  x0, x19, x1
    bl   usleep
    bl   out_begin_ok
    ldr  x19, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
3:  ADR_L x0, k_ms
    bl   raise_field
ENDF op_sleep

// ------------------------------------------------------------------ load -----

// layout_options(x0 options JNode* or 0) -> w0 layout (LAYOUT_*, -1 default),
// w1 dictionary mode (0 auto, 1 forced). Bad values => INVALID_REQUEST.
//   x19 options, x20 layout Str*
FUNC layout_options
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    mov  x19, x0
    mov  w0, #-1
    mov  w1, #0
    cbz  x19, 9f
    mov  x0, x19
    ADR_L x1, k_layout
    mov  w2, #0
    bl   get_str
    mov  x20, x0
    mov  w0, #-1
    cbz  x20, 3f
    mov  x0, x20
    ADR_L x1, v_row
    bl   str_eq_c
    cbz  w0, 1f
    mov  w0, #LAYOUT_ROW
    b    3f
1:  mov  x0, x20
    ADR_L x1, v_column
    bl   str_eq_c
    cbz  w0, 2f
    mov  w0, #LAYOUT_COLUMN
    b    3f
2:  RAISE ERR_INVALID_REQUEST, "layout must be \"row\" or \"column\""
3:  mov  w20, w0
    mov  x0, x19
    ADR_L x1, k_dict
    mov  w2, #0
    bl   get_bool
    mov  w1, w0
    mov  w0, w20
9:  ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF layout_options

// check_path(x0 Str*): ACCESS_DENIED for empty / absolute / NUL / '..' component
LFUNC check_path
    ldr  x1, [x0, #STR_LEN]
    add  x2, x0, #STR_DATA
    cbz  x1, 9f
    ldrb w3, [x2]
    cmp  w3, #'/'
    b.eq 9f
    mov  x4, #0                     // index
    mov  x5, #0                     // component start
1:  cmp  x4, x1
    b.hs 3f
    ldrb w3, [x2, x4]
    cbz  w3, 9f
    cmp  w3, #'/'
    b.eq 2f
    add  x4, x4, #1
    b    1b
2:  // component [x5, x4)
    sub  x6, x4, x5
    cmp  x6, #2
    b.ne 21f
    add  x7, x2, x5
    ldrb w8, [x7]
    ldrb w9, [x7, #1]
    mov  w10, #'.'
    cmp  w8, w10
    ccmp w9, w10, #0, eq
    b.eq 9f
21: add  x4, x4, #1
    mov  x5, x4
    b    1b
3:  sub  x6, x4, x5                 // last component
    cmp  x6, #2
    b.ne 4f
    add  x7, x2, x5
    ldrb w8, [x7]
    ldrb w9, [x7, #1]
    mov  w10, #'.'
    cmp  w8, w10
    ccmp w9, w10, #0, eq
    b.eq 9f
4:  ret
9:  mov  x3, x1
    mov  w0, #ERR_ACCESS_DENIED
    ADR_L x1, m_denied
    b    pq_raise_s
ENDF check_path

// read_data_file(x0 path Str*) -> x0 data ptr, x1 len  (request arena)
LFUNC read_data_file
    stp  x29, x30, [sp, #-208]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    mov  x19, x0
    // full path = data_dir + "/" + path
    LDR_G x0, g_data_dir
    bl   strlen
    mov  x20, x0
    ldr  x1, [x19, #STR_LEN]
    add  x0, x20, x1
    add  x0, x0, #2
    bl   arena_alloc
    mov  x21, x0
    LDR_G x1, g_data_dir
    mov  x2, x20
    bl   memcpy
    mov  w1, #'/'
    strb w1, [x21, x20]
    add  x0, x21, x20
    add  x0, x0, #1
    add  x1, x19, #STR_DATA
    ldr  x2, [x19, #STR_LEN]
    add  x2, x2, #1                 // include NUL
    bl   memcpy
    // open
    mov  x0, x21
    mov  w1, #0                     // O_RDONLY
    bl   open
    mov  w22, w0
    tbz  w0, #31, 2f
    bl   __errno_location
    ldr  w0, [x0]
    cmp  w0, #2                     // ENOENT
    b.eq 1f
    cmp  w0, #20                    // ENOTDIR
    b.eq 1f
    b    8f
1:  mov  w0, #ERR_NOT_FOUND
    ADR_L x1, m_nofile
    add  x2, x19, #STR_DATA
    ldr  x3, [x19, #STR_LEN]
    bl   pq_raise_s
2:  mov  w0, w22
    add  x1, sp, #64                // struct stat (128 bytes)
    bl   fstat
    cbnz w0, 7f
    ldr  w0, [sp, #64+16]           // st_mode
    and  w0, w0, #0170000
    cmp  w0, #0100000               // regular file?
    b.ne 7f
    ldr  x23, [sp, #64+48]          // st_size
    LDR_G x0, g_max_ingest_bytes
    cmp  x23, x0
    b.ls 3f
    mov  w0, w22
    bl   close
    RAISE ERR_RESOURCE_LIMIT, "input exceeds --max-ingest-bytes"
3:  add  x0, x23, #1
    bl   arena_alloc
    mov  x24, x0
    mov  x20, #0                    // bytes read
4:  cmp  x20, x23
    b.hs 5f
    mov  w0, w22
    add  x1, x24, x20
    sub  x2, x23, x20
    bl   read
    cmp  x0, #0
    b.lt 7f
    b.eq 5f
    add  x20, x20, x0
    b    4b
5:  mov  w0, w22
    bl   close
    strb wzr, [x24, x20]
    mov  x0, x24
    mov  x1, x20
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x23, x24, [sp, #48]
    ldp  x29, x30, [sp], #208
    ret
7:  mov  w0, w22
    bl   close
8:  mov  w0, #ERR_IO
    ADR_L x1, m_ioerr
    add  x2, x19, #STR_DATA
    ldr  x3, [x19, #STR_LEN]
    bl   pq_raise_s
ENDF read_data_file

// parse_schema(x0 JNode* array) -> x0 Schema*
LFUNC parse_schema
    stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    mov  x19, x0
    ldr  w20, [x19, #JN_COUNT]
    mov  x0, #SCH_SIZE
    bl   arena_zalloc
    mov  x21, x0
    str  x20, [x21, #SCH_N]
    lsl  x0, x20, #3
    add  x0, x0, #8
    bl   arena_alloc
    str  x0, [x21, #SCH_NAMES]
    lsl  x0, x20, #2
    add  x0, x0, #8
    bl   arena_alloc
    str  x0, [x21, #SCH_TYPES]
    mov  x22, #0
1:  cmp  x22, x20
    b.hs 5f
    ldr  x0, [x19, #JN_PTR]
    ldr  x23, [x0, x22, lsl #3]     // element
    ldr  w1, [x23, #JN_TYPE]
    cmp  w1, #J_OBJ
    b.ne 9f
    mov  x0, x23
    ADR_L x1, k_name
    bl   json_get
    cbz  x0, 9f
    ldr  w1, [x0, #JN_TYPE]
    cmp  w1, #J_STR
    b.ne 9f
    ldr  x24, [x0, #JN_PTR]         // name Str*
    ldr  x1, [x24, #STR_LEN]
    cbnz x1, 11f
    RAISE ERR_INGEST, "empty column name in schema"
11: ldr  x1, [x21, #SCH_NAMES]
    str  x24, [x1, x22, lsl #3]
    // duplicate check against earlier names
    mov  x2, #0
2:  cmp  x2, x22
    b.hs 3f
    ldr  x1, [x21, #SCH_NAMES]
    ldr  x1, [x1, x2, lsl #3]
    str  x2, [sp, #-16]!
    mov  x0, x24
    bl   str_ieq
    ldr  x2, [sp], #16
    cbz  w0, 21f
    mov  w0, #ERR_INGEST
    ADR_L x1, m_schdup
    add  x2, x24, #STR_DATA
    ldr  x3, [x24, #STR_LEN]
    bl   pq_raise_s
21: add  x2, x2, #1
    b    2b
3:  mov  x0, x23
    ADR_L x1, k_type
    bl   json_get
    cbz  x0, 9f
    ldr  w1, [x0, #JN_TYPE]
    cmp  w1, #J_STR
    b.ne 9f
    ldr  x24, [x0, #JN_PTR]
    add  x0, x24, #STR_DATA
    ldr  x1, [x24, #STR_LEN]
    bl   type_parse
    tbz  w0, #31, 4f
    mov  w0, #ERR_INVALID_REQUEST
    ADR_L x1, m_schtype
    add  x2, x24, #STR_DATA
    ldr  x3, [x24, #STR_LEN]
    bl   pq_raise_s
4:  ldr  x1, [x21, #SCH_TYPES]
    str  w0, [x1, x22, lsl #2]
    add  x22, x22, #1
    b    1b
5:  mov  x0, x21
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x23, x24, [sp, #48]
    ldp  x29, x30, [sp], #64
    ret
9:  RAISE ERR_INVALID_REQUEST, "schema must be an array of {name, type} objects"
ENDF parse_schema

// op_load
// Register use: x19 request, x20 table name Str*, w21 format, x22 data ptr,
// x23 data len, x24 schema, w25 header, w26 delimiter, w27 replace, x28 table
LFUNC op_load
    stp  x29, x30, [sp, #-96]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    stp  x25, x26, [sp, #64]
    stp  x27, x28, [sp, #80]
    sub  sp, sp, #16                // [sp] u32 layout, [sp+4] u32 dictionary
    mov  w9, #-1
    str  w9, [sp]
    str  wzr, [sp, #4]
    mov  x19, x0
    ADR_L x1, k_table
    mov  w2, #1
    bl   get_str
    mov  x20, x0
    ldr  x1, [x20, #STR_LEN]
    cbnz x1, 1f
    RAISE ERR_INVALID_REQUEST, "table name must not be empty"
1:  mov  x0, x19
    ADR_L x1, k_format
    mov  w2, #1
    bl   get_str
    mov  x22, x0
    mov  w21, #FMT_CSV
    ADR_L x1, v_csv
    bl   str_eq_c
    cbnz w0, 2f
    mov  w21, #FMT_JSON
    mov  x0, x22
    ADR_L x1, v_json
    bl   str_eq_c
    cbnz w0, 2f
    mov  w21, #FMT_JSONL
    mov  x0, x22
    ADR_L x1, v_jsonl
    bl   str_eq_c
    cbnz w0, 2f
    RAISE ERR_INVALID_REQUEST, "format must be csv, json or jsonl"
2:  // path / data
    mov  x0, x19
    ADR_L x1, k_path
    mov  w2, #0
    bl   get_str
    mov  x22, x0
    mov  x0, x19
    ADR_L x1, k_data
    mov  w2, #0
    bl   get_str
    mov  x23, x0
    cmp  x22, #0
    cset w1, ne
    cmp  x23, #0
    cset w2, ne
    cmp  w1, w2
    b.ne 3f
    RAISE ERR_INVALID_REQUEST, "exactly one of 'path' or 'data' is required"
3:  // schema
    mov  x0, x19
    ADR_L x1, k_schema
    mov  w2, #J_ARR
    mov  w3, #0
    bl   get_field
    mov  x24, x0
    cbz  x0, 4f
    bl   parse_schema
    mov  x24, x0
4:  // options
    mov  w25, #1
    mov  w26, #','
    mov  x0, x19
    ADR_L x1, k_options
    mov  w2, #J_OBJ
    mov  w3, #0
    bl   get_field
    cbz  x0, 6f
    mov  x28, x0
    bl   layout_options
    str  w0, [sp]
    str  w1, [sp, #4]
    mov  x0, x28
    ADR_L x1, k_header
    mov  w2, #1
    bl   get_bool
    mov  w25, w0
    mov  x0, x28
    ADR_L x1, k_delim
    mov  w2, #0
    bl   get_str
    cbz  x0, 6f
    ldr  x1, [x0, #STR_LEN]
    cmp  x1, #1
    b.ne 5f
    ldrb w26, [x0, #STR_DATA]
    cmp  w26, #0x80
    b.hs 5f
    cmp  w26, #'"'
    b.eq 5f
    cmp  w26, #'\n'
    b.eq 5f
    cmp  w26, #'\r'
    b.ne 6f
5:  RAISE ERR_INVALID_REQUEST, "delimiter must be a single ASCII character"
6:  cbnz w25, 61f
    cmp  w21, #FMT_CSV
    b.ne 61f
    cbnz x24, 61f
    RAISE ERR_INVALID_REQUEST, "header=false requires an explicit schema"
61: mov  x0, x19
    ADR_L x1, k_replace
    mov  w2, #0
    bl   get_bool
    mov  w27, w0
    // existing table?
    add  x0, x20, #STR_DATA
    ldr  x1, [x20, #STR_LEN]
    bl   catalog_find
    cbz  x0, 7f
    cbnz w27, 7f
    mov  w0, #ERR_ALREADY_EXISTS
    ADR_L x1, m_exists
    add  x2, x20, #STR_DATA
    ldr  x3, [x20, #STR_LEN]
    bl   pq_raise_s
7:  // input bytes
    cbz  x22, 71f
    mov  x0, x22
    bl   check_path
    mov  x0, x22
    bl   read_data_file
    mov  x22, x0
    mov  x23, x1
    b    72f
71: ldr  x1, [x23, #STR_LEN]
    add  x22, x23, #STR_DATA
    mov  x23, x1
    LDR_G x0, g_max_ingest_bytes
    cmp  x23, x0
    b.ls 72f
    RAISE ERR_RESOURCE_LIMIT, "input exceeds --max-ingest-bytes"
72: // build the table (registered as pending so errors free it)
    mov  x0, #1
    mov  x1, #TBL_SIZE
    bl   calloc
    cbnz x0, 73f
    RAISE ERR_RESOURCE_LIMIT, "out of memory"
73: mov  x28, x0
    ADR_L x1, g_pending_table
    str  x28, [x1]
    mov  x0, x28
    mov  x1, x22
    mov  x2, x23
    mov  w3, w21
    mov  x4, x24
    mov  w5, w25
    mov  w6, w26
    bl   ingest
    mov  x0, x28
    ldr  w1, [sp]
    ldr  w2, [sp, #4]
    bl   table_finalize
    add  x0, x28, #TBL_ARENA
    add  x1, x20, #STR_DATA
    ldr  x2, [x20, #STR_LEN]
    bl   str_new_in
    str  x0, [x28, #TBL_NAME]
    // commit: replace an existing table atomically
    add  x0, x20, #STR_DATA
    ldr  x1, [x20, #STR_LEN]
    bl   catalog_find
    cbz  x0, 8f
    bl   catalog_remove
8:  mov  x0, x28
    bl   catalog_add
    ADR_L x1, g_pending_table
    str  xzr, [x1]
    bl   out_begin_ok
    mov  x0, x28
    bl   write_table_header
    mov  x0, x28
    bl   write_table_columns
    add  sp, sp, #16
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x23, x24, [sp, #48]
    ldp  x25, x26, [sp, #64]
    ldp  x27, x28, [sp, #80]
    ldp  x29, x30, [sp], #96
    ret
ENDF op_load

// ----------------------------------------------------------------- query -----

// check_option_str(x0 options, x1 key, x2 allowed cstr): string option whose
// only supported value is `allowed`; other strings => UNSUPPORTED.
LFUNC check_option_str
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    mov  x19, x1
    mov  x20, x2
    mov  w2, #J_STR
    mov  w3, #0
    bl   get_field
    cbz  x0, 1f
    ldr  x0, [x0, #JN_PTR]
    mov  x1, x20
    bl   str_eq_c
    cbnz w0, 1f
    mov  x0, x19
    bl   strlen
    mov  x3, x0
    mov  x2, x19
    mov  w0, #ERR_UNSUPPORTED
    ADR_L x1, m_optval
    bl   pq_raise_s
1:  ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF check_option_str

// explain_query(x0 Query*) -> x0 Str* plan JSON text (binds and plans)
//   x19 root plan, sp: temporary Buf
LFUNC explain_query
    stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    bl   bind_query
    bl   plan_statement
    mov  x19, x0
    add  x0, sp, #32
    stp  xzr, xzr, [x0]
    stp  xzr, xzr, [x0, #16]
    mov  x1, x19
    bl   plan_explain
    ldr  x0, [sp, #(32 + BUF_PTR)]
    ldr  x1, [sp, #(32 + BUF_LEN)]
    bl   str_new
    mov  x19, x0
    ldr  x0, [sp, #(32 + BUF_PTR)]
    bl   free
    mov  x0, x19
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #64
    ret
ENDF explain_query

// explain_result(x0 Str* plan) -> x0 BoundQuery* (one output column "plan"
// STRING), x1 ResultSet* (one row)
//   x19 plan text, x20 bq, x21 rs
LFUNC explain_result
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    mov  x19, x0
    mov  x0, #BQ_SIZE
    bl   arena_zalloc
    mov  x20, x0
    mov  x9, #1
    str  x9, [x20, #BQ_NOUT]
    mov  x0, #OC_SIZE
    bl   arena_zalloc
    str  x0, [x20, #BQ_OUT]
    mov  w9, #T_STR
    str  w9, [x0, #OC_TYPE]
    mov  x21, x0
    ADR_L x0, s_plan
    mov  x1, #4
    bl   str_new
    str  x0, [x21, #OC_NAME]
    mov  x0, #RS_SIZE
    bl   arena_zalloc
    mov  x21, x0
    mov  x9, #1
    str  x9, [x21, #RS_WIDTH]
    str  x9, [x21, #RS_NROWS]
    mov  x0, #32
    bl   arena_zalloc
    str  x19, [x0, #16]             // cell: payload Str*, not NULL
    add  x9, x0, #16
    str  x9, [x0]                   // rows[0] -> cell
    str  x0, [x21, #RS_ROWS]
    mov  x0, x20
    mov  x1, x21
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
ENDF explain_result

// empty_result() -> x0 BoundQuery* (no columns), x1 ResultSet* (no rows)
LFUNC empty_result
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    str  x19, [sp, #16]
    mov  x0, #BQ_SIZE
    bl   arena_zalloc
    mov  x19, x0
    mov  x0, #RS_SIZE
    bl   arena_zalloc
    mov  x1, x0
    mov  x0, x19
    ldr  x19, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF empty_result

// op_explain: {"op":"explain","sql":…} => {"ok":true,"plan":{…}}
//   x19 request, x20 plan text
LFUNC op_explain
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    mov  x19, x0
    ADR_L x1, k_sql
    mov  w2, #1
    bl   get_str
    mov  x20, x0
    LDR_G x0, g_max_query_mem
    ADR_L x1, g_arena_limit
    str  x0, [x1]
    add  x0, x20, #STR_DATA
    ldr  x1, [x20, #STR_LEN]
    bl   parse_sql
    ldr  w1, [x0, #ST_KIND]
    cmp  w1, #SK_QUERY
    b.eq 1f
    cmp  w1, #SK_EXPLAIN
    b.eq 1f
    RAISE ERR_UNSUPPORTED, "only queries can be explained"
1:  ldr  x0, [x0, #ST_QUERY]
    bl   explain_query
    mov  x20, x0
    bl   out_begin_ok
    ADR_L x0, r_plan
    bl   out_puts
    ADR_L x0, g_out
    add  x1, x20, #STR_DATA
    ldr  x2, [x20, #STR_LEN]
    bl   buf_put
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF op_explain

// op_query
// x19 request, x20 options or 0, x21 max_rows (-1 none), w22 count-only,
// x23 BoundQuery*, x24 ResultSet*
LFUNC op_query
    stp  x29, x30, [sp, #-96]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    stp  x25, x26, [sp, #64]
    stp  x27, x28, [sp, #80]
    mov  x19, x0
    ADR_L x1, k_sql
    mov  w2, #1
    bl   get_str
    mov  x25, x0                    // sql Str*
    mov  x21, #-1
    mov  w22, #0
    mov  x0, x19
    ADR_L x1, k_options
    mov  w2, #J_OBJ
    mov  w3, #0
    bl   get_field
    mov  x20, x0
    cbz  x20, 3f
    // max_rows
    ADR_L x1, k_max_rows
    mov  x2, #-1
    mov  x3, #0
    bl   get_int
    mov  x21, x0
    mov  x0, x20
    ADR_L x1, k_max_rows
    bl   json_get                   // max_rows explicitly present?
    cbnz x0, 1f
    mov  x21, #-1
1:  // timeout_ms
    mov  x0, x20
    ADR_L x1, k_timeout
    mov  x2, #0
    mov  x3, #0
    bl   get_int
    cbz  x0, 2f
    mov  x26, x0
    bl   now_us
    mov  x1, #1000
    madd x0, x26, x1, x0
    ADR_L x1, g_deadline
    str  x0, [x1]
2:  // result mode
    mov  x0, x20
    ADR_L x1, k_result
    mov  w2, #J_STR
    mov  w3, #0
    bl   get_field
    cbz  x0, 21f
    ldr  x26, [x0, #JN_PTR]
    mov  x0, x26
    ADR_L x1, v_count
    bl   str_eq_c
    mov  w22, w0
    cbnz w0, 21f
    mov  x0, x26
    ADR_L x1, v_rows
    bl   str_eq_c
    cbnz w0, 21f
    mov  w0, #ERR_UNSUPPORTED
    ADR_L x1, m_optval
    ADR_L x2, k_result
    mov  x3, #6
    bl   pq_raise_s
21: mov  x0, x20
    ADR_L x1, k_mode
    ADR_L x2, v_auto
    bl   check_option_str
    mov  x0, x20
    ADR_L x1, k_join
    ADR_L x2, v_auto
    bl   check_option_str
    mov  x0, x20
    ADR_L x1, k_threads
    mov  x2, #1
    mov  x3, #1
    bl   get_int
    mov  x0, x20
    ADR_L x1, k_optimize
    mov  w2, #1
    bl   get_bool
    mov  x0, x20
    ADR_L x1, k_use_idx
    mov  w2, #1
    bl   get_bool
    mov  x0, x20
    ADR_L x1, k_native
    mov  w2, #0
    bl   get_bool
3:  // memory budget for this query
    LDR_G x0, g_max_query_mem
    ADR_L x1, g_arena_limit
    str  x0, [x1]
    // lex + parse
    add  x0, x25, #STR_DATA
    ldr  x1, [x25, #STR_LEN]
    bl   parse_sql
    ldr  w1, [x0, #ST_KIND]
    cmp  w1, #SK_QUERY
    b.eq 4f
    cmp  w1, #SK_EXPLAIN
    b.eq 41f
    bl   index_stmt                 // CREATE / DROP INDEX
    bl   empty_result
    mov  x23, x0
    mov  x24, x1
    b    42f
4:  ldr  x0, [x0, #ST_QUERY]
    bl   bind_query                 // semantic analysis
    mov  x23, x0
    bl   plan_statement             // logical + physical plan
    mov  x1, #0
    bl   exec_plan                  // execution
    mov  x24, x0
    b    42f
41: ldr  x0, [x0, #ST_QUERY]        // EXPLAIN: one STRING column "plan"
    bl   explain_query
    bl   explain_result
    mov  x23, x0
    mov  x24, x1
42:
    // max_rows
    tbnz x21, #63, 5f
    ldr  x0, [x24, #RS_NROWS]
    cmp  x0, x21
    b.ls 5f
    RAISE ERR_RESOURCE_LIMIT, "result exceeds max_rows"
5:  bl   out_begin_ok
    // columns
    ADR_L x0, r_columns
    bl   out_puts
    ldr  x25, [x23, #BQ_OUT]
    ldr  x26, [x23, #BQ_NOUT]
    mov  x27, #0
6:  cmp  x27, x26
    b.hs 7f
    cbz  x27, 61f
    mov  w0, #','
    bl   out_c
61: mov  x1, #OC_SIZE
    madd x1, x27, x1, x25
    ldr  x0, [x1, #OC_NAME]
    ldr  w1, [x1, #OC_TYPE]
    bl   write_column_desc
    add  x27, x27, #1
    b    6b
7:  mov  w0, #']'
    bl   out_c
    cbnz w22, 9f
    // rows
    ADR_L x0, r_rows
    bl   out_puts
    mov  x27, #0                    // row index
71: ldr  x0, [x24, #RS_NROWS]
    cmp  x27, x0
    b.hs 8f
    cbz  x27, 72f
    mov  w0, #','
    bl   out_c
72: mov  w0, #'['
    bl   out_c
    ldr  x0, [x24, #RS_ROWS]
    ldr  x28, [x0, x27, lsl #3]     // row cells
    mov  x20, #0                    // column index
73: cmp  x20, x26
    b.hs 75f
    cbz  x20, 74f
    mov  w0, #','
    bl   out_c
74: mov  x1, #OC_SIZE
    madd x1, x20, x1, x25
    ldr  w3, [x1, #OC_TYPE]
    add  x2, x28, x20, lsl #4
    ldr  x1, [x2]
    ldr  x2, [x2, #8]
    ADR_L x0, g_out
    bl   write_value_json
    add  x20, x20, #1
    b    73b
75: mov  w0, #']'
    bl   out_c
    add  x27, x27, #1
    b    71b
8:  mov  w0, #']'
    bl   out_c
9:  ADR_L x0, r_rowcount
    bl   out_puts
    ldr  x0, [x24, #RS_NROWS]
    bl   out_i64
    ADR_L x0, r_stats
    bl   out_puts
    bl   now_us
    LDR_G x1, g_req_start
    sub  x0, x0, x1
    bl   out_i64
    mov  w0, #'}'
    bl   out_c
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x23, x24, [sp, #48]
    ldp  x25, x26, [sp, #64]
    ldp  x27, x28, [sp, #80]
    ldp  x29, x30, [sp], #96
    ret
ENDF op_query

    NOTE_GNU_STACK
