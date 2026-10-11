/*
 * protocol.S - JSON-lines protocol (protocol.md §3-§6): request parsing,
 * dispatch of operations, error responses, path safety and file loading.
 *
 *   proto_handle_line(ptr, len)   parse one request line, respond on stdout
 *   proto_handle_request(node)    handle a parsed request (exec mode)
 *   proto_write_static(op)        CLI `version` / `capabilities` output
 */
#include "pq.inc"
#include "sql.inc"

    .section .note.GNU-stack, "", @progbits

    .bss
    .p2align 4
    .globl g_out
g_out:      .zero BUF_SIZE      /* response being built */
req_id:     .quad 0             /* JSON node of the request id (or 0) */
jb_main:    .zero 512           /* jmp_buf of the request handler */

    .data
    .p2align 3
    .globl g_http_capture, g_req_status, g_force_op, g_forced_deadline
    .globl g_q_max_rows, g_q_count
g_http_capture:    .quad 0     /* 1: leave the response in g_out (HTTP server) */
g_req_status:      .quad 0     /* error code of the last request, 0 = ok */
g_force_op:        .quad 0     /* C string: op to run instead of the "op" field */
g_forced_deadline: .quad 0     /* absolute query deadline set by the server */
g_q_max_rows:      .quad -1    /* options of the query being prepared */
g_q_count:         .quad 0

    .section .rodata
err_names:
    .quad 0
    .quad en1, en2, en3, en4, en5, en6, en7, en8, en9, en10, en11, en12
    .quad en13, en14, en15, en16, en17, en18, en19, en20, en21, en22, en23
en1:  .asciz "PARSE_ERROR"
en2:  .asciz "SEMANTIC_ERROR"
en3:  .asciz "TYPE_ERROR"
en4:  .asciz "NUMERIC_OVERFLOW"
en5:  .asciz "DIVISION_BY_ZERO"
en6:  .asciz "CONVERSION_ERROR"
en7:  .asciz "INVALID_ARGUMENT"
en8:  .asciz "SUBQUERY_CARDINALITY"
en9:  .asciz "INVALID_REQUEST"
en10: .asciz "INGEST_ERROR"
en11: .asciz "UNSUPPORTED"
en12: .asciz "ACCESS_DENIED"
en13: .asciz "NOT_FOUND"
en14: .asciz "ALREADY_EXISTS"
en15: .asciz "CANCELLED"
en16: .asciz "RESOURCE_LIMIT"
en17: .asciz "IO_ERROR"
en18: .asciz "STORAGE_CORRUPT"
en19: .asciz "STORAGE_VERSION_UNSUPPORTED"
en20: .asciz "INTERNAL_ERROR"
en21: .asciz "OVERLOADED"
en22: .asciz "SHUTTING_DOWN"
en23: .asciz "TIMEOUT"

version_fields:
    .ascii ",\"engine\":\"polyquery-x86_64-asm\",\"engine_version\":\"0.1.0\""
    .ascii ",\"language\":\"x86_64-asm\",\"protocol_version\":1,\"spec_version\":\"1.0.0\""
    .ascii ",\"runtime\":\"GNU as 2.42 + glibc\""
    .asciz ",\"build\":{\"profile\":\"release\",\"flags\":\"gcc -no-pie (assembler/linker driver only)\"}"
caps_fields:
    .ascii ",\"protocol_version\":1,\"capabilities\":[\"phase1\",\"ingest.csv\",\"ingest.json\""
    .ascii ",\"ingest.jsonl\",\"sql.basic\",\"test.functions\""
    .ascii ",\"phase2\",\"sql.groupby\",\"sql.join\",\"sql.functions\",\"sql.subquery\""
    .ascii ",\"sql.cte\",\"sql.correlated_subquery\""
    .ascii ",\"phase3\",\"storage.pqcf\",\"storage.mmap\",\"index.hash\",\"index.btree\""
    .ascii ",\"phase4\",\"http.streaming\""
    .ascii ",\"phase5\",\"exec.row\",\"exec.vectorized\",\"exec.parallel\""
    .asciz ",\"join.hash\",\"join.merge\",\"join.nested_loop\"]"

/* operation table: name, handler */
op_names:
    .asciz "query"
    .asciz "load"
    .asciz "tables"
    .asciz "schema"
    .asciz "drop"
    .asciz "reset"
    .asciz "version"
    .asciz "capabilities"
    .asciz "sleep"
    .asciz "explain"
    .asciz "save"
    .asciz "open"
    .asciz "stats"
    .byte 0
    .p2align 3
op_handlers:
    .quad op_query, op_load, op_tables, op_schema, op_drop, op_reset
    .quad op_version, op_capabilities, op_sleep
    .quad op_explain, op_save, op_open, op_stats

    .text

/* ================================================================ output */

/* write_all(fd edi, ptr rsi, len rdx) */
FUNC write_all
    ENTER 0
    mov %edi, %ebx
    mov %rsi, %r12
    mov %rdx, %r13
1:  test %r13, %r13
    jz 9f
    mov %ebx, %edi
    mov %r12, %rsi
    mov %r13, %rdx
    call write
    test %rax, %rax
    jg 2f
    call __errno_location
    cmpl $4, (%rax)                 /* EINTR */
    je 1b
    mov $1, %edi                    /* stdout gone: nothing sensible left to do */
    call _exit
2:  add %rax, %r12
    sub %rax, %r13
    jmp 1b
9:  LEAVE
ENDF write_all

/* flush_out(): writes g_out + newline to stdout (HTTP capture mode: keeps
 * the response in g_out for the server) */
FUNC flush_out
    cmpq $0, g_http_capture(%rip)
    je 1f
    ret
1:  sub $8, %rsp
    lea g_out(%rip), %rdi
    mov $'\n', %esi
    call buf_putc
    mov $1, %edi
    mov g_out+BUF_DATA(%rip), %rsi
    mov g_out+BUF_LEN(%rip), %rdx
    call write_all
    movq $0, g_out+BUF_LEN(%rip)
    add $8, %rsp
    ret
ENDF flush_out

/* put_id(): writes the request id (or null) */
FUNC put_id
    sub $8, %rsp
    mov req_id(%rip), %rsi
    lea g_out(%rip), %rdi
    test %rsi, %rsi
    jz 1f
    call json_write
    add $8, %rsp
    ret
1:  CSTR %rsi, "null"
    call buf_puts
    add $8, %rsp
    ret
ENDF put_id

/* put_columns(table rdi): "columns":[...] */
FUNC put_columns
    ENTER 0
    mov %rdi, %rbx
    lea g_out(%rip), %r15
    PUTS %r15, "\"columns\":["
    xor %r12d, %r12d
    mov TB_COLS(%rbx), %r13
1:  cmp TB_NCOLS(%rbx), %r12
    jae 3f
    test %r12, %r12
    jz 2f
    mov %r15, %rdi
    mov $',', %esi
    call buf_putc
2:  PUTS %r15, "{\"name\":"
    mov %r15, %rdi
    mov COL_NAME(%r13), %rsi
    call buf_put_json_pstr
    PUTS %r15, ",\"type\":\""
    mov %r15, %rdi
    mov COL_TYPE(%r13), %rsi
    call fmt_type
    PUTS %r15, "\"}"
    inc %r12
    add $COL_SIZE, %r13
    jmp 1b
3:  PUTS %r15, "]"
    LEAVE
ENDF put_columns

/* ================================================================ request fields */

bad_request:
    RAISE E_INVALID_REQUEST, "missing or ill-typed request field"

/* opt_field(node rdi, key rsi, jtype edx) -> rax value node or 0 if absent;
 * INVALID_REQUEST if present with another JSON type (J_TRUE accepts booleans) */
FUNC opt_field
    push %rbx
    mov %edx, %ebx
    call json_obj_get
    test %rax, %rax
    jz 9f
    mov JN_TYPE(%rax), %rcx
    cmp $J_NULL, %ecx               /* null = absent */
    jne 1f
    xor %eax, %eax
    jmp 9f
1:
    cmp $J_TRUE, %ebx
    jne 2f
    cmp $J_FALSE, %ecx
    je 9f
2:  cmp %rbx, %rcx
    jne bad_request
9:  pop %rbx
    ret
ENDF opt_field

/* req_str(node, key) -> rax pstr* (required string field) */
FUNC req_str
    sub $8, %rsp
    mov $J_STRING, %edx
    call opt_field
    test %rax, %rax
    jz bad_request
    mov JN_PTR(%rax), %rax
    sub $8, %rax
    add $8, %rsp
    ret
ENDF req_str

/* opt_bool(node, key, default edx) -> eax */
FUNC opt_bool
    push %rbx
    mov %edx, %ebx
    mov $J_TRUE, %edx
    call opt_field
    test %rax, %rax
    jz 1f
    xor %ebx, %ebx
    cmpq $J_TRUE, JN_TYPE(%rax)
    sete %bl
1:  mov %ebx, %eax
    pop %rbx
    ret
ENDF opt_bool

/* opt_uint(node, key, default rdx) -> rax (non-negative integer field) */
FUNC opt_uint
    push %rbx
    mov %rdx, %rbx
    mov $J_NUMBER, %edx
    call opt_field
    test %rax, %rax
    jz 1f
    mov %rax, %rdi
    call json_is_int
    test %eax, %eax
    jz bad_request
    test %rdx, %rdx
    js bad_request
    mov %rdx, %rbx
1:  mov %rbx, %rax
    pop %rbx
    ret
ENDF opt_uint

/* ================================================================ dispatch */

/* proto_handle_line(ptr, len) */
FUNC proto_handle_line
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    call par_reset
    mov g_arena(%rip), %rdi
    call arena_reset
    mov %rbx, %rdi
    mov %r12, %rsi
    mov g_arena(%rip), %rdx
    call json_parse
    mov %rax, %rdi
    call handle_request_noreset
    LEAVE
ENDF proto_handle_line

/* proto_handle_request(node): exec mode (node lives outside the request arena) */
FUNC proto_handle_request
    push %rbx
    mov %rdi, %rbx
    call par_reset
    mov g_arena(%rip), %rdi
    call arena_reset
    mov %rbx, %rdi
    call handle_request_noreset
    pop %rbx
    ret
ENDF proto_handle_request

FUNC handle_request_noreset
    ENTER 16
    mov %rdi, 0(%rsp)
    movq $0, req_id(%rip)
    movq $0, g_req_status(%rip)
    movq $0, g_err_line(%rip)
    movq $0, g_out+BUF_LEN(%rip)
    movq $0, g_deadline_ns(%rip)
    movq $1, g_opt_optimize(%rip)
    movq $1, g_opt_indexes(%rip)
    movq $MODE_AUTO, g_opt_mode(%rip)
    movq $JOIN_AUTO, g_opt_join(%rip)
    movq $1, g_opt_threads(%rip)
    lea jb_main(%rip), %rdi
    mov %rdi, g_jmpbuf(%rip)
    call _setjmp
    test %eax, %eax
    jnz hr_error
    mov 0(%rsp), %rbx
    test %rbx, %rbx
    jz hr_invalid
    cmpq $J_OBJECT, JN_TYPE(%rbx)
    jne hr_invalid
    mov %rbx, %rdi
    CSTR %rsi, "id"
    call json_obj_get
    mov %rax, req_id(%rip)
    mov g_force_op(%rip), %r12      /* endpoint-implied op (HTTP) */
    test %r12, %r12
    jnz 0f
    mov %rbx, %rdi
    CSTR %rsi, "op"
    mov $J_STRING, %edx
    call opt_field
    test %rax, %rax
    jz hr_invalid
    mov JN_PTR(%rax), %r12          /* op name */
0:
    lea g_out(%rip), %r15
    PUTS %r15, "{\"id\":"
    call put_id
    PUTS %r15, ",\"ok\":true"
    /* lookup the op */
    lea op_names(%rip), %r13
    xor %r14d, %r14d
1:  cmpb $0, (%r13)
    je hr_unknown_op
    mov %r12, %rdi
    mov %r13, %rsi
    call strcmp
    test %eax, %eax
    jz 2f
    mov %r13, %rdi
    call strlen
    lea 1(%r13, %rax), %r13
    inc %r14
    jmp 1b
2:  lea op_handlers(%rip), %rax
    mov (%rax, %r14, 8), %rax
    mov %rbx, %rdi
    call *%rax
    lea g_out(%rip), %rdi
    mov $'}', %esi
    call buf_putc
    call flush_out
    movq $0, g_jmpbuf(%rip)
    movq $0, g_deadline_ns(%rip)
    LEAVE
hr_invalid:
    RAISE E_INVALID_REQUEST, "request is not a JSON object with a string op"
hr_unknown_op:
    RAISE E_INVALID_REQUEST, "unknown op"
hr_error:
    movq $0, g_deadline_ns(%rip)
    mov g_pending_map(%rip), %rdi   /* PQCF file mapped by a failed open */
    test %rdi, %rdi
    jz 0f
    mov g_pending_map_len(%rip), %rsi
    call munmap
    movq $0, g_pending_map(%rip)
0:  mov g_pending_arena(%rip), %rdi
    test %rdi, %rdi
    jz 1f
    movq $0, g_pending_arena(%rip)
    call arena_destroy
1:  movq $0, g_out+BUF_LEN(%rip)
    lea g_out(%rip), %r15
    PUTS %r15, "{\"id\":"
    call put_id
    PUTS %r15, ",\"ok\":false,\"error\":"
    mov %r15, %rdi
    call proto_put_error
    mov %rax, g_req_status(%rip)
    PUTS %r15, "}"
    call flush_out
    movq $0, g_jmpbuf(%rip)
    LEAVE
ENDF handle_request_noreset

/* proto_put_error(buf rdi) -> rax error code: appends the error object
 * {"code":..,"message":..,"details":..} of the last raised error */
FUNC proto_put_error
    ENTER 0
    mov %rdi, %r15
    PUTS %r15, "{\"code\":\""
    mov g_err_code(%rip), %rbx
    cmp $E_TIMEOUT, %rbx
    jbe 2f
    mov $E_INTERNAL_ERROR, %ebx
2:  test %rbx, %rbx
    jnz 3f
    mov $E_INTERNAL_ERROR, %ebx
3:  lea err_names(%rip), %rcx
    mov (%rcx, %rbx, 8), %rsi
    mov %r15, %rdi
    call buf_puts
    PUTS %r15, "\",\"message\":"
    lea g_err_msg(%rip), %rdi
    call strlen
    mov %r15, %rdi
    lea g_err_msg(%rip), %rsi
    mov %rax, %rdx
    call buf_put_json_str
    cmpq $0, g_err_line(%rip)       /* SQL position of a syntax error */
    je 4f
    PUTS %r15, ",\"details\":{\"line\":"
    mov %r15, %rdi
    mov g_err_line(%rip), %rsi
    call buf_put_u64
    PUTS %r15, ",\"column\":"
    mov %r15, %rdi
    mov g_err_col(%rip), %rsi
    call buf_put_u64
    PUTS %r15, "}"
4:  PUTS %r15, "}"
    mov %rbx, %rax
    LEAVE
ENDF proto_put_error

/* proto_err_name(code rdi) -> rax C string name of an error code */
FUNC proto_err_name
    cmp $E_TIMEOUT, %rdi
    jbe 1f
    mov $E_INTERNAL_ERROR, %edi
1:  lea err_names(%rip), %rax
    mov (%rax, %rdi, 8), %rax
    ret
ENDF proto_err_name

/* proto_static_buf(which edi: 0 version, 1 capabilities, buf rsi):
 * {"ok":true,...} without an id (HTTP GET endpoints) */
FUNC proto_static_buf
    push %rbx
    push %r12
    sub $8, %rsp
    mov %edi, %ebx
    mov %rsi, %r12
    mov %r12, %rdi
    CSTR %rsi, "{\"ok\":true"
    call buf_puts
    mov %r12, %rdi
    lea version_fields(%rip), %rsi
    test %ebx, %ebx
    jz 1f
    lea caps_fields(%rip), %rsi
1:  call buf_puts
    mov %r12, %rdi
    mov $'}', %esi
    call buf_putc
    add $8, %rsp
    pop %r12
    pop %rbx
    ret
ENDF proto_static_buf

/* proto_write_static(which edi: 0 version, 1 capabilities) */
FUNC proto_write_static
    push %rbx
    mov %edi, %ebx
    lea g_out(%rip), %rdi
    CSTR %rsi, "{\"ok\":true"
    call buf_puts
    lea g_out(%rip), %rdi
    lea version_fields(%rip), %rsi
    test %ebx, %ebx
    jz 1f
    lea caps_fields(%rip), %rsi
1:  call buf_puts
    lea g_out(%rip), %rdi
    mov $'}', %esi
    call buf_putc
    call flush_out
    pop %rbx
    ret
ENDF proto_write_static

/* ================================================================ simple ops */

FUNC op_version
    sub $8, %rsp
    lea g_out(%rip), %rdi
    lea version_fields(%rip), %rsi
    call buf_puts
    add $8, %rsp
    ret
ENDF op_version

FUNC op_capabilities
    sub $8, %rsp
    lea g_out(%rip), %rdi
    lea caps_fields(%rip), %rsi
    call buf_puts
    add $8, %rsp
    ret
ENDF op_capabilities

FUNC op_unsupported
    sub $8, %rsp
    RAISE E_UNSUPPORTED, "operation not supported by this engine"
ENDF op_unsupported

FUNC op_reset
    sub $8, %rsp
    call cat_reset
    add $8, %rsp
    ret
ENDF op_reset

FUNC op_tables
    ENTER 0
    lea g_out(%rip), %r15
    PUTS %r15, ",\"tables\":["
    call cat_sorted
    mov %rax, %rbx
    call cat_count
    mov %rax, %r12
    xor %r13d, %r13d
1:  cmp %r12, %r13
    jae 3f
    test %r13, %r13
    jz 2f
    mov %r15, %rdi
    mov $',', %esi
    call buf_putc
2:  mov (%rbx, %r13, 8), %r14
    PUTS %r15, "{\"name\":"
    mov %r15, %rdi
    mov TB_NAME(%r14), %rsi
    call buf_put_json_pstr
    PUTS %r15, ",\"row_count\":"
    mov %r15, %rdi
    mov TB_NROWS(%r14), %rsi
    call buf_put_u64
    mov %r15, %rdi
    mov $'}', %esi
    call buf_putc
    inc %r13
    jmp 1b
3:  PUTS %r15, "]"
    LEAVE
ENDF op_tables

/* find_table_field(node) -> rax Table* (NOT_FOUND if unknown) */
FUNC find_table_field
    sub $8, %rsp
    CSTR %rsi, "table"
    call req_str
    lea 8(%rax), %rdi
    mov (%rax), %rsi
    call cat_find
    test %rax, %rax
    jz 1f
    add $8, %rsp
    ret
1:  RAISE E_NOT_FOUND, "unknown table"
ENDF find_table_field

FUNC op_schema
    ENTER 0
    call find_table_field
    mov %rax, %rbx
    lea g_out(%rip), %r15
    PUTS %r15, ",\"table\":"
    mov %r15, %rdi
    mov TB_NAME(%rbx), %rsi
    call buf_put_json_pstr
    PUTS %r15, ",\"row_count\":"
    mov %r15, %rdi
    mov TB_NROWS(%rbx), %rsi
    call buf_put_u64
    mov %r15, %rdi
    mov $',', %esi
    call buf_putc
    mov %rbx, %rdi
    call put_columns
    PUTS %r15, ",\"indexes\":"
    mov %r15, %rdi
    mov %rbx, %rsi
    call idx_put_list
    cmpq $LAYOUT_ROW, TB_LAYOUT(%rbx)
    je 1f
    PUTS %r15, ",\"layout\":\"column\""
    LEAVE
1:  PUTS %r15, ",\"layout\":\"row\""
    LEAVE
ENDF op_schema

/* op_stats: {"op":"stats","table":t} */
FUNC op_stats
    ENTER 16
    call find_table_field
    mov %rax, %rbx
    mov %rbx, %rdi
    call table_stats
    mov %rax, %r12
    lea g_out(%rip), %r15
    PUTS %r15, ",\"table\":"
    mov %r15, %rdi
    mov TB_NAME(%rbx), %rsi
    call buf_put_json_pstr
    PUTS %r15, ",\"row_count\":"
    mov %r15, %rdi
    mov TB_NROWS(%rbx), %rsi
    call buf_put_u64
    PUTS %r15, ",\"columns\":["
    xor %r13d, %r13d
1:  cmp TB_NCOLS(%rbx), %r13
    jae 9f
    test %r13, %r13
    jz 2f
    mov %r15, %rdi
    mov $',', %esi
    call buf_putc
2:  mov %r13, %r14
    shl $COL_SHIFT, %r14
    add TB_COLS(%rbx), %r14         /* Column* */
    PUTS %r15, "{\"name\":"
    mov %r15, %rdi
    mov COL_NAME(%r14), %rsi
    call buf_put_json_pstr
    PUTS %r15, ",\"type\":\""
    mov %r15, %rdi
    mov COL_TYPE(%r14), %rsi
    call fmt_type
    PUTS %r15, "\",\"null_count\":"
    imul $CST_SIZE, %r13, %rax
    lea (%r12, %rax), %rax
    mov %rax, 0(%rsp)               /* ColStats* */
    mov %r15, %rdi
    mov CST_NULLS(%rax), %rsi
    call buf_put_u64
    PUTS %r15, ",\"distinct_count\":"
    mov 0(%rsp), %rax
    mov %r15, %rdi
    mov CST_DISTINCT(%rax), %rsi
    call buf_put_u64
    PUTS %r15, ",\"min\":"
    mov 0(%rsp), %rax
    cmpq $0, CST_HAS(%rax)
    je 3f
    mov %r15, %rdi
    mov COL_TYPE(%r14), %rsi
    mov CST_MIN(%rax), %rdx
    call fmt_value_json
    PUTS %r15, ",\"max\":"
    mov 0(%rsp), %rax
    mov %r15, %rdi
    mov COL_TYPE(%r14), %rsi
    mov CST_MAX(%rax), %rdx
    call fmt_value_json
    jmp 4f
3:  PUTS %r15, "null,\"max\":null"
4:  PUTS %r15, "}"
    inc %r13
    jmp 1b
9:  PUTS %r15, "]"
    LEAVE
ENDF op_stats

FUNC op_drop
    sub $8, %rsp
    CSTR %rsi, "table"
    call req_str
    lea 8(%rax), %rdi
    mov (%rax), %rsi
    call cat_drop
    test %eax, %eax
    jz 1f
    add $8, %rsp
    ret
1:  RAISE E_NOT_FOUND, "unknown table"
ENDF op_drop

FUNC op_sleep
    ENTER 16
    mov %rdi, %rbx
    cmpq $0, g_test_functions(%rip)
    je 1f
    mov %rbx, %rdi
    CSTR %rsi, "ms"
    mov $-1, %rdx
    call opt_uint
    cmp $-1, %rax
    je 1f
    mov %rax, %r12                  /* remaining ms */
    mov g_forced_deadline(%rip), %rax
    mov %rax, g_deadline_ns(%rip)
2:  call check_deadline             /* 10 ms slices: deadline / cancellation */
    test %r12, %r12
    jz 3f
    mov $10, %eax
    cmp %rax, %r12
    cmovb %r12, %rax
    sub %rax, %r12
    imul $1000000, %rax, %rax
    movq $0, 0(%rsp)
    mov %rax, 8(%rsp)
    lea 0(%rsp), %rdi
    xor %esi, %esi
    call nanosleep
    jmp 2b
3:  LEAVE
1:  RAISE E_INVALID_REQUEST, "sleep requires --enable-test-functions and an ms field"
ENDF op_sleep

/* ================================================================ query */

/* query_setup(request node rdi) -> rax Statement*: reads "sql" and the
 * options (max_rows / result into g_q_max_rows / g_q_count, timeout_ms or the
 * server-imposed deadline), sets the memory budget and parses the SQL */
FUNC query_setup
    ENTER 16
    mov %rdi, %rbx
    CSTR %rsi, "sql"
    call req_str
    mov %rax, %r12                  /* sql pstr */
    movq $-1, g_q_max_rows(%rip)
    movq $0, g_q_count(%rip)
    movq $0, g_result_rows(%rip)
    xor %r13d, %r13d
    mov %rbx, %rdi
    CSTR %rsi, "options"
    mov $J_OBJECT, %edx
    call opt_field
    test %rax, %rax
    jz 3f
    mov %rax, %r13
    mov %r13, %rdi
    CSTR %rsi, "max_rows"
    mov $-1, %rdx
    call opt_uint
    mov %rax, g_q_max_rows(%rip)
    mov %r13, %rdi
    CSTR %rsi, "timeout_ms"
    xor %edx, %edx
    call opt_uint
    test %rax, %rax
    jz 1f
    mov $1000000000000, %rcx        /* > ~31 years: effectively no timeout */
    cmp %rcx, %rax
    ja 1f
    imul $1000000, %rax, %r14
    call now_ns
    add %r14, %rax
    mov %rax, g_deadline_ns(%rip)
1:  mov %r13, %rdi
    CSTR %rsi, "result"
    mov $J_STRING, %edx
    call opt_field
    test %rax, %rax
    jz 3f
    mov JN_PTR(%rax), %r14
    mov %r14, %rdi
    CSTR %rsi, "rows"
    call strcmp
    test %eax, %eax
    jz 3f
    mov %r14, %rdi
    CSTR %rsi, "count"
    call strcmp
    test %eax, %eax
    jnz 2f
    movq $1, g_q_count(%rip)
    jmp 3f
2:  RAISE E_UNSUPPORTED, "unsupported result mode"
3:  test %r13, %r13
    jz 4f
    mov %r13, %rdi                  /* validate the remaining known options */
    call check_exec_options
4:  mov g_forced_deadline(%rip), %rax   /* server: queue time counts */
    test %rax, %rax
    jz 41f
    mov %rax, g_deadline_ns(%rip)
    jmp 5f
41: cmpq $0, g_deadline_ns(%rip)        /* no timeout_ms: --query-timeout-ms */
    jne 5f
    mov g_srv_timeout_ms(%rip), %r14
    test %r14, %r14
    jz 5f
    imul $1000000, %r14, %r14
    call now_ns
    add %r14, %rax
    mov %rax, g_deadline_ns(%rip)
5:  call check_deadline
    /* per-query memory budget */
    mov g_arena(%rip), %rax
    mov g_max_query_mem(%rip), %rcx
    mov %rcx, AR_LIMIT(%rax)
    lea 8(%r12), %rdi
    mov (%r12), %rsi
    call sql_parse
    LEAVE
ENDF query_setup

FUNC op_query
    ENTER 48
    mov %rdi, %rbx
    call now_ns
    mov %rax, 40(%rsp)              /* start (stats.elapsed_us) */
    mov %rbx, %rdi
    call query_setup
    mov g_q_max_rows(%rip), %rcx
    mov %rcx, 0(%rsp)
    mov g_q_count(%rip), %rcx
    mov %rcx, 8(%rsp)
    mov %rax, %r14                  /* statement */
    mov ST_KIND(%r14), %rax
    cmp $STMT_QUERY, %rax
    je 5f
    cmp $STMT_EXPLAIN, %rax
    je 6f
    mov %r14, %rdi
    cmp $STMT_CREATE_INDEX, %rax
    jne 51f
    call idx_create_stmt
    jmp 52f
51: call idx_drop_stmt
52: lea g_out(%rip), %r15
    PUTS %r15, ",\"columns\":[],\"rows\":[],\"row_count\":0"
    jmp 9f
5:  mov ST_QUERY(%r14), %rdi
    call bind_statement
    mov %rax, %r13
    lea g_out(%rip), %rdi
    mov $',', %esi
    call buf_putc
    mov %r13, %rdi
    mov 0(%rsp), %rsi
    mov 8(%rsp), %rdx
    lea g_out(%rip), %rcx
    call exec_query
    jmp 9f
6:  /* EXPLAIN statement: one STRING column "plan", one row with the plan JSON */
    mov ST_QUERY(%r14), %rdi
    call bind_statement
    mov %rax, %r13
    lea 16(%rsp), %rdi              /* Buf at 16..39 */
    call buf_init
    mov %r13, %rdi
    lea 16(%rsp), %rsi
    call explain_plan
    lea g_out(%rip), %r15
    PUTS %r15, ",\"columns\":[{\"name\":\"plan\",\"type\":\"STRING\"}]"
    cmpq $0, 8(%rsp)
    jne 7f
    PUTS %r15, ",\"rows\":[["
    mov %r15, %rdi
    mov 16+BUF_DATA(%rsp), %rsi
    mov 16+BUF_LEN(%rsp), %rdx
    call buf_put_json_str
    PUTS %r15, "]]"
7:  PUTS %r15, ",\"row_count\":1"
    lea 16(%rsp), %rdi
    call buf_free
9:  lea g_out(%rip), %r15
    PUTS %r15, ",\"stats\":{\"elapsed_us\":"
    call now_ns
    sub 40(%rsp), %rax
    xor %edx, %edx
    mov $1000, %ecx
    div %rcx
    mov %r15, %rdi
    mov %rax, %rsi
    call buf_put_u64
    PUTS %r15, "}"
    mov g_arena(%rip), %rax
    movq $0, AR_LIMIT(%rax)
    LEAVE
ENDF op_query

/* op_explain: {"op":"explain","sql":...} => "plan":{...} */
FUNC op_explain
    ENTER 16
    mov %rdi, %rbx
    CSTR %rsi, "sql"
    call req_str
    mov %rax, %r12
    mov %rbx, %rdi
    CSTR %rsi, "options"
    mov $J_OBJECT, %edx
    call opt_field
    test %rax, %rax
    jz 2f
    mov %rax, %rdi
    call check_exec_options
2:
    mov g_arena(%rip), %rax
    mov g_max_query_mem(%rip), %rcx
    mov %rcx, AR_LIMIT(%rax)
    lea 8(%r12), %rdi
    mov (%r12), %rsi
    call sql_parse
    mov ST_KIND(%rax), %rcx
    cmp $STMT_QUERY, %rcx
    je 1f
    cmp $STMT_EXPLAIN, %rcx
    je 1f
    RAISE E_UNSUPPORTED, "indexes are not supported by this engine"
1:  mov ST_QUERY(%rax), %rdi
    call bind_statement
    mov %rax, %r13
    lea g_out(%rip), %r15
    PUTS %r15, ",\"plan\":"
    mov %r13, %rdi
    mov %r15, %rsi
    call explain_plan
    mov g_arena(%rip), %rax
    movq $0, AR_LIMIT(%rax)
    LEAVE
ENDF op_explain

/* ================================================================ load */

/* check_path(pstr rdi): ACCESS_DENIED for absolute, empty, NUL or '..' paths */
FUNC check_path
    ENTER 0
    mov (%rdi), %r12                /* len */
    lea 8(%rdi), %rbx               /* bytes */
    test %r12, %r12
    jz 9f
    cmpb $'/', (%rbx)
    je 9f
    mov %rbx, %rdi
    call strlen
    cmp %r12, %rax
    jne 9f
    /* scan components */
    xor %r13d, %r13d                /* component start */
    xor %r14d, %r14d                /* index */
1:  cmp %r12, %r14
    je 2f
    cmpb $'/', (%rbx, %r14)
    jne 3f
2:  mov %r14, %rax
    sub %r13, %rax
    cmp $2, %rax
    jne 4f
    cmpb $'.', (%rbx, %r13)
    jne 4f
    cmpb $'.', 1(%rbx, %r13)
    je 9f
4:  lea 1(%r14), %r13
    cmp %r12, %r14
    je 8f
3:  inc %r14
    jmp 1b
8:  LEAVE
9:  RAISE E_ACCESS_DENIED, "path is outside the data directory"
ENDF check_path

/* read_data_file(pstr path) -> rax ptr, rdx len (contents in the request arena) */
FUNC read_data_file
    ENTER 160
    mov %rdi, %rbx
    call check_path
    /* full path = data_dir + "/" + path */
    mov g_data_dir(%rip), %rdi
    call strlen
    lea 16(%rax), %rdi
    add (%rbx), %rdi
    mov %rdi, %r13
    call tmp_alloc
    mov %rax, %r12
    mov %r12, %rdi
    mov %r13, %rsi
    CSTR %rdx, "%s/%s"
    mov g_data_dir(%rip), %rcx
    lea 8(%rbx), %r8
    xor %eax, %eax
    call snprintf
    mov %r12, %rdi
    xor %esi, %esi                  /* O_RDONLY */
    xor %eax, %eax
    call open
    test %eax, %eax
    js 7f
    mov %eax, %r14d                 /* fd */
    mov %r14d, %edi
    lea 0(%rsp), %rsi
    call fstat
    test %eax, %eax
    jnz 6f
    mov 24(%rsp), %eax              /* st_mode */
    and $0170000, %eax
    cmp $0040000, %eax
    je 6f
    mov 48(%rsp), %r15              /* st_size */
    cmp g_max_ingest_bytes(%rip), %r15
    ja 5f
    lea 1(%r15), %rdi
    call tmp_alloc
    mov %rax, %r12
    xor %r13d, %r13d                /* bytes read */
1:  cmp %r15, %r13
    jae 3f
    mov %r14d, %edi
    lea (%r12, %r13), %rsi
    mov %r15, %rdx
    sub %r13, %rdx
    call read
    test %rax, %rax
    jg 2f
    jz 3f                           /* file shrank */
    call __errno_location
    cmpl $4, (%rax)
    je 1b
    jmp 6f
2:  add %rax, %r13
    jmp 1b
3:  mov %r14d, %edi
    call close
    movb $0, (%r12, %r13)
    mov %r12, %rax
    mov %r13, %rdx
    LEAVE
5:  mov %r14d, %edi
    call close
    RAISE E_RESOURCE_LIMIT, "input exceeds --max-ingest-bytes"
6:  mov %r14d, %edi
    call close
    RAISE E_IO_ERROR, "cannot read input file"
7:  call __errno_location
    mov (%rax), %eax
    cmp $2, %eax                    /* ENOENT */
    je 8f
    cmp $20, %eax                   /* ENOTDIR */
    je 8f
    cmp $13, %eax                   /* EACCES */
    je 9f
    RAISE E_IO_ERROR, "cannot open input file"
8:  RAISE E_NOT_FOUND, "input file not found"
9:  RAISE E_ACCESS_DENIED, "permission denied"
ENDF read_data_file

/* build_schema(array node rdi) -> rax Schema* */
FUNC build_schema
    ENTER 16
    mov %rdi, %rbx
    mov JN_LEN(%rbx), %r12          /* count */
    mov %r12, %rdi
    shl $4, %rdi
    add $16, %rdi
    call tmp_alloc
    mov %rax, %r13
    mov %r12, SC_NCOLS(%r13)
    lea 16(%r13), %rax              /* entries follow the header */
    mov %rax, SC_COLS(%r13)
    xor %r14d, %r14d
1:  cmp %r12, %r14
    jae 9f
    mov JN_PTR(%rbx), %rax
    mov (%rax, %r14, 8), %r15       /* element */
    cmpq $J_OBJECT, JN_TYPE(%r15)
    jne bad_request
    mov %r15, %rdi
    CSTR %rsi, "name"
    call req_str
    mov %r14, %rcx
    shl $4, %rcx
    mov %rax, 16+SCE_NAME(%r13, %rcx)
    mov %r15, %rdi
    CSTR %rsi, "type"
    call req_str
    lea 8(%rax), %rdi
    mov (%rax), %rsi
    call type_parse
    test %edx, %edx
    jnz 2f
    mov %r14, %rcx
    shl $4, %rcx
    mov %rax, 16+SCE_TYPE(%r13, %rcx)
    inc %r14
    jmp 1b
2:  RAISE E_INVALID_REQUEST, "invalid type in schema"
9:  mov %r13, %rax
    LEAVE
ENDF build_schema

/* layout_options(options rdi) -> rax LAYOUT_*, rdx DICT_*:
 * {"layout":"row"|"column","dictionary":bool}; other values => INVALID_REQUEST */
FUNC layout_options
    ENTER 0
    mov %rdi, %rbx
    mov $LAYOUT_COLUMN, %r12d
    mov $DICT_AUTO, %r13d
    CSTR %rsi, "layout"
    mov $J_STRING, %edx
    call opt_field
    test %rax, %rax
    jz 2f
    mov JN_PTR(%rax), %r14
    mov %r14, %rdi
    CSTR %rsi, "column"
    call strcmp
    test %eax, %eax
    jz 2f
    mov %r14, %rdi
    CSTR %rsi, "row"
    call strcmp
    test %eax, %eax
    jnz 8f
    mov $LAYOUT_ROW, %r12d
2:  mov %rbx, %rdi
    CSTR %rsi, "dictionary"
    mov $J_TRUE, %edx
    call opt_field
    test %rax, %rax
    jz 9f
    mov $DICT_ON, %r13d
    cmpq $J_TRUE, JN_TYPE(%rax)
    je 9f
    mov $DICT_OFF, %r13d
9:  mov %r12, %rax
    mov %r13, %rdx
    LEAVE
8:  RAISE E_INVALID_REQUEST, "layout must be \"row\" or \"column\""
ENDF layout_options

/* op_load(node) */
#define LD_NAME    0
#define LD_FMT     8
#define LD_SCHEMA  16
#define LD_HEADER  24
#define LD_DELIM   32
#define LD_REPLACE 40
#define LD_DATA    48
#define LD_LEN     56
#define LD_LAYOUT  64
#define LD_DICT    72
FUNC op_load
    ENTER 80
    mov %rdi, %rbx
    CSTR %rsi, "table"
    call req_str
    cmpq $0, (%rax)
    je bad_request
    mov %rax, LD_NAME(%rsp)
    mov %rbx, %rdi
    CSTR %rsi, "format"
    call req_str
    lea 8(%rax), %r12
    mov %r12, %rdi
    CSTR %rsi, "csv"
    call strcmp
    xor %r13d, %r13d
    test %eax, %eax
    jz 1f
    mov %r12, %rdi
    CSTR %rsi, "json"
    call strcmp
    mov $1, %r13d
    test %eax, %eax
    jz 1f
    mov %r12, %rdi
    CSTR %rsi, "jsonl"
    call strcmp
    mov $2, %r13d
    test %eax, %eax
    jnz bad_request
1:  mov %r13, LD_FMT(%rsp)
    /* path xor data */
    mov %rbx, %rdi
    CSTR %rsi, "path"
    mov $J_STRING, %edx
    call opt_field
    mov %rax, %r14
    mov %rbx, %rdi
    CSTR %rsi, "data"
    mov $J_STRING, %edx
    call opt_field
    mov %rax, %r15
    test %r14, %r14
    jz 2f
    test %r15, %r15
    jnz bad_request
    jmp 3f
2:  test %r15, %r15
    jz bad_request
3:  mov %rbx, %rdi
    CSTR %rsi, "replace"
    xor %edx, %edx
    call opt_bool
    mov %rax, LD_REPLACE(%rsp)
    /* options */
    movq $1, LD_HEADER(%rsp)
    movq $',', LD_DELIM(%rsp)
    movq $LAYOUT_COLUMN, LD_LAYOUT(%rsp)
    movq $DICT_AUTO, LD_DICT(%rsp)
    mov %rbx, %rdi
    CSTR %rsi, "options"
    mov $J_OBJECT, %edx
    call opt_field
    test %rax, %rax
    jz 5f
    mov %rax, %r12
    mov %r12, %rdi
    CSTR %rsi, "header"
    mov $1, %edx
    call opt_bool
    mov %rax, LD_HEADER(%rsp)
    mov %r12, %rdi
    call layout_options
    mov %rax, LD_LAYOUT(%rsp)
    mov %rdx, LD_DICT(%rsp)
    mov %r12, %rdi
    CSTR %rsi, "delimiter"
    mov $J_STRING, %edx
    call opt_field
    test %rax, %rax
    jz 5f
    cmpq $1, JN_LEN(%rax)
    jne bad_request
    mov JN_PTR(%rax), %rax
    movzbl (%rax), %eax
    cmp $0x7f, %eax
    ja bad_request
    cmp $'"', %eax
    je bad_request
    cmp $'\n', %eax
    je bad_request
    cmp $'\r', %eax
    je bad_request
    mov %rax, LD_DELIM(%rsp)
5:  /* schema */
    movq $0, LD_SCHEMA(%rsp)
    mov %rbx, %rdi
    CSTR %rsi, "schema"
    mov $J_ARRAY, %edx
    call opt_field
    test %rax, %rax
    jz 6f
    mov %rax, %rdi
    call build_schema
    mov %rax, LD_SCHEMA(%rsp)
6:  cmpq $0, LD_HEADER(%rsp)
    jne 7f
    cmpq $0, LD_SCHEMA(%rsp)
    jne 7f
    cmpq $0, LD_FMT(%rsp)
    jne 7f
    RAISE E_INVALID_REQUEST, "header=false requires an explicit schema"
7:  /* existing table? */
    cmpq $0, LD_REPLACE(%rsp)
    jne 8f
    mov LD_NAME(%rsp), %rax
    lea 8(%rax), %rdi
    mov (%rax), %rsi
    call cat_find
    test %rax, %rax
    jz 8f
    RAISE E_ALREADY_EXISTS, "table already exists"
8:  /* input bytes; parsing runs without the catalog lock (server) */
    call cat_parse_begin
    test %r14, %r14
    jz 9f
    mov JN_PTR(%r14), %rdi
    sub $8, %rdi
    call read_data_file
    mov %rax, LD_DATA(%rsp)
    mov %rdx, LD_LEN(%rsp)
    jmp 10f
9:  mov JN_PTR(%r15), %rax
    mov %rax, LD_DATA(%rsp)
    mov JN_LEN(%r15), %rax
    mov %rax, LD_LEN(%rsp)
    cmp g_max_ingest_bytes(%rip), %rax
    jbe 10f
    RAISE E_RESOURCE_LIMIT, "input exceeds --max-ingest-bytes"
10: mov LD_NAME(%rsp), %rdi
    mov LD_DATA(%rsp), %rsi
    mov LD_LEN(%rsp), %rdx
    mov LD_SCHEMA(%rsp), %rcx
    cmpq $0, LD_FMT(%rsp)
    jne 11f
    mov LD_HEADER(%rsp), %r8
    mov LD_DELIM(%rsp), %r9
    call ingest_csv
    jmp 12f
11: xor %r8d, %r8d
    cmpq $2, LD_FMT(%rsp)
    sete %r8b
    call ingest_json
12: mov %rax, %r12
    mov %r12, %rdi
    mov LD_LAYOUT(%rsp), %rsi
    mov LD_DICT(%rsp), %rdx
    call table_finalize
    call cat_parse_end
    movq $0, g_pending_arena(%rip)
    mov %r12, %rdi
    call cat_put
    lea g_out(%rip), %r15
    PUTS %r15, ",\"table\":"
    mov %r15, %rdi
    mov TB_NAME(%r12), %rsi
    call buf_put_json_pstr
    PUTS %r15, ",\"row_count\":"
    mov %r15, %rdi
    mov TB_NROWS(%r12), %rsi
    call buf_put_u64
    mov %r15, %rdi
    mov $',', %esi
    call buf_putc
    mov %r12, %rdi
    call put_columns
    LEAVE
ENDF op_load

/* ================================================================ save / open */

    .section .rodata
encodings_ok:
    .asciz "auto"
    .asciz "plain"
    .asciz "dict"
    .asciz "rle"
    .byte 0
    .text

/* op_save: {"op":"save","table":t,"path":p,"options":{"encoding":..,"row_group_size":N}} */
FUNC op_save
    ENTER 32
    mov %rdi, %rbx
    call find_table_field
    mov %rax, %r12                  /* table */
    mov %rbx, %rdi
    CSTR %rsi, "path"
    call req_str
    mov %rax, %r13                  /* path */
    movq $ENC_AUTO, 0(%rsp)
    movq $0, 8(%rsp)                /* row group size (0 = default) */
    mov %rbx, %rdi
    CSTR %rsi, "options"
    mov $J_OBJECT, %edx
    call opt_field
    test %rax, %rax
    jz 5f
    mov %rax, %r14
    mov %r14, %rdi
    CSTR %rsi, "row_group_size"
    xor %edx, %edx
    call opt_uint
    mov %rax, 8(%rsp)
    mov %r14, %rdi
    CSTR %rsi, "encoding"
    mov $J_STRING, %edx
    call opt_field
    test %rax, %rax
    jz 5f
    mov JN_PTR(%rax), %rdi
    lea encodings_ok(%rip), %rsi
    xor %r15d, %r15d                /* ENC_AUTO, PLAIN, DICT, RLE in list order */
1:  cmpb $0, (%rsi)
    je 4f
    mov %rdi, 16(%rsp)
    mov %rsi, 24(%rsp)
    call strcmp
    test %eax, %eax
    jz 3f
    mov 24(%rsp), %rdi
    call strlen
    mov 24(%rsp), %rsi
    lea 1(%rsi, %rax), %rsi
    mov 16(%rsp), %rdi
    inc %r15
    jmp 1b
3:  mov %r15, 0(%rsp)
    jmp 5f
4:  RAISE E_INVALID_REQUEST, "encoding must be auto, plain, dict or rle"
5:  mov %r12, %rdi
    mov %r13, %rsi
    mov 0(%rsp), %rdx
    mov 8(%rsp), %rcx
    call pqcf_save
    mov %rax, %r14
    lea g_out(%rip), %r15
    PUTS %r15, ",\"path\":"
    mov %r15, %rdi
    mov %r13, %rsi
    call buf_put_json_pstr
    PUTS %r15, ",\"bytes\":"
    mov %r15, %rdi
    mov %r14, %rsi
    call buf_put_u64
    LEAVE
ENDF op_save

/* op_open: {"op":"open","table":t,"path":p,"replace":b,"options":{"mmap":b,
 * "layout":..,"dictionary":b}} - loads a PQCF file and recreates its indexes */
#define OP_NAME    0
#define OP_REPLACE 8
#define OP_MMAP    16
#define OP_LAYOUT  24
#define OP_DICT    32
#define OP_IX      40
#define OP_OLD     48
#define OP_TABLE   56
FUNC op_open
    ENTER 64
    mov %rdi, %rbx
    CSTR %rsi, "table"
    call req_str
    cmpq $0, (%rax)
    je bad_request
    mov %rax, OP_NAME(%rsp)
    mov %rbx, %rdi
    CSTR %rsi, "path"
    call req_str
    mov %rax, %r13                  /* path */
    mov %rbx, %rdi
    CSTR %rsi, "replace"
    xor %edx, %edx
    call opt_bool
    mov %rax, OP_REPLACE(%rsp)
    movq $0, OP_MMAP(%rsp)
    movq $LAYOUT_COLUMN, OP_LAYOUT(%rsp)
    movq $DICT_AUTO, OP_DICT(%rsp)
    mov %rbx, %rdi
    CSTR %rsi, "options"
    mov $J_OBJECT, %edx
    call opt_field
    test %rax, %rax
    jz 1f
    mov %rax, %r14
    mov %r14, %rdi
    CSTR %rsi, "mmap"
    xor %edx, %edx
    call opt_bool
    mov %rax, OP_MMAP(%rsp)
    mov %r14, %rdi
    call layout_options
    mov %rax, OP_LAYOUT(%rsp)
    mov %rdx, OP_DICT(%rsp)
1:  /* existing table */
    mov OP_NAME(%rsp), %rax
    lea 8(%rax), %rdi
    mov (%rax), %rsi
    call cat_find
    mov %rax, OP_OLD(%rsp)
    test %rax, %rax
    jz 2f
    cmpq $0, OP_REPLACE(%rsp)
    jne 2f
    RAISE E_ALREADY_EXISTS, "table already exists"
2:  mov g_arena(%rip), %rdi
    call vec_new
    mov %rax, OP_IX(%rsp)
    call arena_new
    mov %rax, g_pending_arena(%rip)
    mov $PQ_READ, %edx              /* mmap: lazy decoding (column layout) */
    cmpq $0, OP_MMAP(%rsp)
    je 21f
    mov $PQ_MMAP_EAGER, %edx
    cmpq $LAYOUT_COLUMN, OP_LAYOUT(%rsp)
    jne 21f
    mov $PQ_MMAP_LAZY, %edx
21: mov %edx, %r14d
    call cat_parse_begin            /* reading needs no catalog lock */
    mov %r14d, %edx
    mov %r13, %rdi
    mov OP_NAME(%rsp), %rsi
    mov OP_IX(%rsp), %rcx
    call pqcf_read
    mov %rax, OP_TABLE(%rsp)
    mov %rax, %rdi
    mov OP_LAYOUT(%rsp), %rsi
    mov OP_DICT(%rsp), %rdx
    call table_finalize
    call cat_parse_end
    /* index names: unique in the file, and free in the catalog (the replaced
     * table's own indexes are dropped with it) */
    mov OP_IX(%rsp), %r14
    xor %r15d, %r15d
3:  cmp VEC_LEN(%r14), %r15
    jae 6f
    mov VEC_DATA(%r14), %rax
    mov (%rax, %r15, 8), %r12       /* name */
    xor %ecx, %ecx
4:  cmp %r15, %rcx
    jae 5f
    mov VEC_DATA(%r14), %rax
    mov (%rax, %rcx, 8), %rdi
    mov %rcx, 0(%rsp)
    mov %r12, %rsi
    call pstr_ieq
    mov 0(%rsp), %rcx
    test %eax, %eax
    jnz 8f
    add $3, %rcx
    jmp 4b
5:  lea 8(%r12), %rdi
    mov (%r12), %rsi
    call idx_find
    test %rax, %rax
    jz 51f
    mov IX_TABLE(%rax), %rax
    cmp OP_OLD(%rsp), %rax
    jne 9f
51: add $3, %r15
    jmp 3b
6:  /* build the indexes, publish the table */
    xor %r15d, %r15d
7:  cmp VEC_LEN(%r14), %r15
    jae 71f
    mov VEC_DATA(%r14), %rax
    mov OP_TABLE(%rsp), %rdi
    mov 8(%rax, %r15, 8), %rsi
    mov 16(%rax, %r15, 8), %rdx
    mov (%rax, %r15, 8), %rcx
    call idx_build
    mov OP_TABLE(%rsp), %rdi
    mov %rax, %rsi
    call idx_attach
    add $3, %r15
    jmp 7b
71: movq $0, g_pending_arena(%rip)
    movq $0, g_pending_map(%rip)    /* a lazy table now owns its mapping */
    mov OP_TABLE(%rsp), %r12
    mov %r12, %rdi
    call cat_put
    lea g_out(%rip), %r15
    PUTS %r15, ",\"table\":"
    mov %r15, %rdi
    mov TB_NAME(%r12), %rsi
    call buf_put_json_pstr
    PUTS %r15, ",\"row_count\":"
    mov %r15, %rdi
    mov TB_NROWS(%r12), %rsi
    call buf_put_u64
    mov %r15, %rdi
    mov $',', %esi
    call buf_putc
    mov %r12, %rdi
    call put_columns
    LEAVE
8:  RAISE E_STORAGE_CORRUPT, "PQCF: duplicate index name"
9:  RAISE E_ALREADY_EXISTS, "an index of the file already exists"
ENDF op_open

/* opt_enum(options rdi, key rsi, NUL-separated allowed list rdx) -> rax
 * index of the value in the list (0 when absent or null);
 * UNSUPPORTED if the option is present and not one of the allowed strings */
FUNC opt_enum
    ENTER 0
    mov %rdx, %r12
    xor %r13d, %r13d                /* index */
    call json_obj_get
    test %rax, %rax
    jz 9f
    cmpq $J_NULL, JN_TYPE(%rax)
    je 9f
    cmpq $J_STRING, JN_TYPE(%rax)
    jne 8f
    mov JN_PTR(%rax), %rbx
1:  cmpb $0, (%r12)
    je 8f
    mov %rbx, %rdi
    mov %r12, %rsi
    call strcmp
    test %eax, %eax
    jz 9f
    mov %r12, %rdi
    call strlen
    lea 1(%r12, %rax), %r12
    inc %r13
    jmp 1b
8:  RAISE E_UNSUPPORTED, "unsupported value for a query option"
9:  mov %r13, %rax
    LEAVE
ENDF opt_enum

/* opt_boolean(options rdi, key rsi) -> eax 0 if false, else 1 (absent / null
 * count as the default true); UNSUPPORTED unless absent/null/boolean */
FUNC opt_boolean
    sub $8, %rsp
    call json_obj_get
    test %rax, %rax
    jz 9f
    mov JN_TYPE(%rax), %rcx
    cmp $J_TRUE, %ecx
    ja 8f
    xor %eax, %eax
    cmp $J_FALSE, %ecx
    setne %al
    add $8, %rsp
    ret
8:  RAISE E_UNSUPPORTED, "unsupported value for a query option"
9:  mov $1, %eax
    add $8, %rsp
    ret
ENDF opt_boolean

    .section .rodata
modes_ok: .asciz "auto"
          .asciz "row"
          .asciz "vectorized"
          .byte 0
joins_ok: .asciz "auto"
          .asciz "hash"
          .asciz "merge"
          .asciz "nested_loop"
          .byte 0
    .text

/* check_exec_options(options rdi) */
FUNC check_exec_options
    ENTER 0
    mov %rdi, %rbx
    CSTR %rsi, "mode"
    lea modes_ok(%rip), %rdx
    call opt_enum
    mov %rax, g_opt_mode(%rip)
    mov %rbx, %rdi
    CSTR %rsi, "join"
    lea joins_ok(%rip), %rdx
    call opt_enum
    mov %rax, g_opt_join(%rip)
    mov %rbx, %rdi
    CSTR %rsi, "optimize"
    call opt_boolean
    mov %rax, g_opt_optimize(%rip)
    mov %rbx, %rdi
    CSTR %rsi, "use_indexes"
    call opt_boolean
    mov %rax, g_opt_indexes(%rip)
    mov %rbx, %rdi
    CSTR %rsi, "native"
    call opt_boolean
    mov %rbx, %rdi
    CSTR %rsi, "threads"
    call json_obj_get
    test %rax, %rax
    jz 9f
    cmpq $J_NULL, JN_TYPE(%rax)
    je 9f
    mov %rax, %rdi
    call json_is_int
    test %eax, %eax
    jz 8f
    cmp $1, %rdx
    jl 8f
    mov $MAX_THREADS, %eax          /* more workers than that never help */
    cmp %rax, %rdx
    cmova %rax, %rdx
    mov %rdx, g_opt_threads(%rip)
9:  LEAVE
8:  RAISE E_UNSUPPORTED, "unsupported value for threads"
ENDF check_exec_options
