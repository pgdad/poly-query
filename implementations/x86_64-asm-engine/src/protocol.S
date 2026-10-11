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
    .asciz ",\"sql.cte\",\"sql.correlated_subquery\"]"

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
    .quad op_explain, op_unsupported, op_unsupported, op_unsupported

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

/* flush_out(): writes g_out + newline to stdout */
FUNC flush_out
    sub $8, %rsp
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
    movq $0, g_err_line(%rip)
    movq $0, g_out+BUF_LEN(%rip)
    movq $0, g_deadline_ns(%rip)
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
    mov %rbx, %rdi
    CSTR %rsi, "op"
    mov $J_STRING, %edx
    call opt_field
    test %rax, %rax
    jz hr_invalid
    mov JN_PTR(%rax), %r12          /* op name */
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
    mov g_pending_arena(%rip), %rdi
    test %rdi, %rdi
    jz 1f
    movq $0, g_pending_arena(%rip)
    call arena_destroy
1:  movq $0, g_out+BUF_LEN(%rip)
    lea g_out(%rip), %r15
    PUTS %r15, "{\"id\":"
    call put_id
    PUTS %r15, ",\"ok\":false,\"error\":{\"code\":\""
    mov g_err_code(%rip), %rax
    cmp $E_TIMEOUT, %rax
    jbe 2f
    mov $E_INTERNAL_ERROR, %eax
2:  test %rax, %rax
    jnz 3f
    mov $E_INTERNAL_ERROR, %eax
3:  lea err_names(%rip), %rcx
    mov (%rcx, %rax, 8), %rsi
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
4:  PUTS %r15, "}}"
    call flush_out
    movq $0, g_jmpbuf(%rip)
    LEAVE
ENDF handle_request_noreset

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
    PUTS %r15, ",\"indexes\":[]"
    LEAVE
ENDF op_schema

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
    xor %edx, %edx
    mov $1000, %ecx
    div %rcx
    mov %rax, 0(%rsp)
    imul $1000000, %rdx, %rdx
    mov %rdx, 8(%rsp)
    lea 0(%rsp), %rdi
    xor %esi, %esi
    call nanosleep
    LEAVE
1:  RAISE E_INVALID_REQUEST, "sleep requires --enable-test-functions and an ms field"
ENDF op_sleep

/* ================================================================ query */

FUNC op_query
    ENTER 48
    mov %rdi, %rbx
    CSTR %rsi, "sql"
    call req_str
    mov %rax, %r12                  /* sql pstr */
    movq $-1, 0(%rsp)               /* max_rows */
    movq $0, 8(%rsp)                /* count only */
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
    mov %rax, 0(%rsp)
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
    movq $1, 8(%rsp)
    jmp 3f
2:  RAISE E_UNSUPPORTED, "unsupported result mode"
3:  test %r13, %r13
    jz 4f
    mov %r13, %rdi                  /* validate the remaining known options */
    call check_exec_options
4:  /* per-query memory budget */
    mov g_arena(%rip), %rax
    mov g_max_query_mem(%rip), %rcx
    mov %rcx, AR_LIMIT(%rax)
    lea 8(%r12), %rdi
    mov (%r12), %rsi
    call sql_parse
    mov %rax, %r14                  /* statement */
    mov ST_KIND(%r14), %rax
    cmp $STMT_QUERY, %rax
    je 5f
    cmp $STMT_EXPLAIN, %rax
    je 6f
    RAISE E_UNSUPPORTED, "indexes are not supported by this engine"
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
9:  mov g_arena(%rip), %rax
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

/* op_load(node) */
#define LD_NAME    0
#define LD_FMT     8
#define LD_SCHEMA  16
#define LD_HEADER  24
#define LD_DELIM   32
#define LD_REPLACE 40
#define LD_DATA    48
#define LD_LEN     56
FUNC op_load
    ENTER 64
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
8:  /* input bytes */
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

/* opt_enum(options rdi, key rsi, NUL-separated allowed list rdx):
 * UNSUPPORTED if the option is present and not one of the allowed strings */
FUNC opt_enum
    ENTER 0
    mov %rdx, %r12
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
    jmp 1b
8:  RAISE E_UNSUPPORTED, "unsupported value for a query option"
9:  LEAVE
ENDF opt_enum

/* opt_boolean(options rdi, key rsi): UNSUPPORTED unless absent/null/boolean */
FUNC opt_boolean
    sub $8, %rsp
    call json_obj_get
    test %rax, %rax
    jz 9f
    mov JN_TYPE(%rax), %rcx
    cmp $J_TRUE, %ecx
    ja 8f
    add $8, %rsp
    ret
8:  RAISE E_UNSUPPORTED, "unsupported value for a query option"
9:  add $8, %rsp
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
    mov %rbx, %rdi
    CSTR %rsi, "join"
    lea joins_ok(%rip), %rdx
    call opt_enum
    mov %rbx, %rdi
    CSTR %rsi, "optimize"
    call opt_boolean
    mov %rbx, %rdi
    CSTR %rsi, "use_indexes"
    call opt_boolean
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
9:  LEAVE
8:  RAISE E_UNSUPPORTED, "unsupported value for threads"
ENDF check_exec_options
