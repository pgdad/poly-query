/*
 * api.S - the embedding API (include/polyquery.h, spec/apps/embedding.md):
 * the engine as an in-process C-ABI library (lib/libpolyquery.a).
 *
 * Design
 *   - The engine core keeps its state in process globals (catalog, limits,
 *     request arena, error slot).  An instance (pq_db) owns a catalog and a
 *     configuration; every API call takes the process-wide lock api_lock,
 *     makes its instance the active one (api_activate swaps the catalog in
 *     and sets the limit globals) and runs the operation.  Several
 *     instances can exist; calls are serialized.
 *   - Operations run through the same request handlers as the CLI and the
 *     HTTP server (protocol.S): the API builds the JSON request, runs it with
 *     proto_handle_line in capture mode (g_http_capture: the response stays
 *     in g_out) and reads the outcome (g_req_status, g_err_msg).  So load,
 *     save, open and drop behave exactly as the protocol operations,
 *     including path safety and every error code.
 *   - Queries: with g_api_capture set, op_query hands the executed result
 *     to api_capture_result (typed pq_result in one malloc'd block, no JSON)
 *     or to api_capture_table (pq_create_table: a new catalog table whose
 *     strings and wide decimals are copied into the table's own arena).
 *   - The engine runs on a dedicated 1 GiB lazily committed stack (like the
 *     CLI) with the CR-6 STACK_CHECK limit set, so very deep statements end
 *     in RESOURCE_LIMIT instead of overflowing the caller's stack.
 */
#include "pq.inc"
#include "sql.inc"
#include "polyquery.inc"

    .section .note.GNU-stack, "", @progbits

/* pq_db: an engine instance */
#define DB_DATA_DIR  0      /* malloc'd C string */
#define DB_MAXMEM    8      /* bytes */
#define DB_THREADS   16     /* default threads per query */
#define DB_AUTO      24     /* 1 = threads chosen automatically */
#define DB_MAXINGEST 32
#define DB_MAXROWS   40
#define DB_MAXJOIN   48
#define DB_TIMEOUT   56     /* default query timeout (ms), 0 = none */
#define DB_TESTFN    64
#define DB_CAT       72     /* saved catalog state while inactive (3 words) */
#define DB_ERRCODE   96
#define DB_ERRMSG    104    /* malloc'd C string or 0 */
#define DB_SIZE      112

#define API_STACK     (1024*1024*1024)
#define API_GUARD     (64*1024)
#define DEFAULT_THREADS_MAX 16
#define SC_NPROCESSORS_ONLN 84

/* capture modes (g_api_capture) */
#define CAP_NONE   0
#define CAP_RESULT 1
#define CAP_TABLE  2

    .data
    .p2align 3
api_lock:       .zero 64        /* pthread_mutex_t (zero = default mutex) */
api_active:     .quad 0         /* pq_db* whose catalog is in the globals */
api_inited:     .quad 0
api_stack_lo:   .quad 0         /* lowest usable address of the engine stack */
api_stack_top:  .quad 0
api_def_mem:    .quad 0         /* engine defaults captured at first use */
api_def_ingest: .quad 0
api_def_rows:   .quad 0
api_def_join:   .quad 0
api_req:        .zero BUF_SIZE  /* JSON request being built */
api_create_code: .quad 0        /* error of the last failed pq_create */
api_create_msg: .zero 256

    .globl g_api_capture, g_api_result, g_api_ct_name, g_api_ct_replace
g_api_capture:  .quad 0         /* CAP_*: what op_query does with a result */
g_api_result:   .quad 0         /* pq_result* built by api_capture_result */
g_api_ct_name:  .quad 0         /* pq_create_table: table name (C string) */
g_api_ct_replace: .quad 0
g_api_ct_rows:  .quad 0

    .section .rodata
version_text:   .asciz "polyquery-x86_64-asm 0.1.0"
ok_name:        .asciz "OK"
empty_str:      .asciz ""
    .text

/* ================================================================ lock / activation */

/* api_init(): one-time process set-up (lock held): request arena, the
 * engine's default limits, the engine stack */
FUNC api_init
    ENTER 0
    cmpq $0, api_inited(%rip)
    jne 9f
    cmpq $0, g_arena(%rip)
    jne 1f
    call arena_new
    mov %rax, g_arena(%rip)
1:  call par_no_pin                 /* leave the host's CPU affinity alone */
    mov g_max_query_mem(%rip), %rax
    mov %rax, api_def_mem(%rip)
    mov g_max_ingest_bytes(%rip), %rax
    mov %rax, api_def_ingest(%rip)
    mov g_max_table_rows(%rip), %rax
    mov %rax, api_def_rows(%rip)
    mov g_max_join_rows(%rip), %rax
    mov %rax, api_def_join(%rip)
    xor %edi, %edi
    mov $API_STACK, %rsi
    mov $3, %edx                    /* PROT_READ | PROT_WRITE */
    mov $0x4022, %ecx               /* MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE */
    mov $-1, %r8d
    xor %r9d, %r9d
    call mmap
    cmp $-1, %rax
    je 2f                           /* no big stack: run on the caller's */
    mov %rax, %rbx
    mov %rax, %rdi
    mov $API_GUARD, %esi
    xor %edx, %edx                  /* guard pages: PROT_NONE */
    call mprotect
    lea API_GUARD(%rbx), %rax
    mov %rax, api_stack_lo(%rip)
    lea API_STACK(%rbx), %rax
    mov %rax, api_stack_top(%rip)
2:  movq $1, api_inited(%rip)
9:  LEAVE
ENDF api_init

/* api_activate(db rdi): makes db the active instance (lock held) */
FUNC api_activate
    ENTER 0
    mov %rdi, %rbx
    mov api_active(%rip), %rax
    cmp %rax, %rbx
    je 2f
    test %rax, %rax
    jz 1f
    lea DB_CAT(%rax), %rdi          /* park the active instance's catalog */
    call cat_swap
1:  lea DB_CAT(%rbx), %rdi
    call cat_swap
    mov %rbx, api_active(%rip)
2:  mov DB_DATA_DIR(%rbx), %rax
    mov %rax, g_data_dir(%rip)
    mov DB_MAXMEM(%rbx), %rax
    mov %rax, g_max_query_mem(%rip)
    mov DB_THREADS(%rbx), %rax
    mov %rax, g_default_threads(%rip)
    mov DB_AUTO(%rbx), %rax
    mov %rax, g_threads_auto(%rip)
    mov DB_MAXINGEST(%rbx), %rax
    mov %rax, g_max_ingest_bytes(%rip)
    mov DB_MAXROWS(%rbx), %rax
    mov %rax, g_max_table_rows(%rip)
    mov DB_MAXJOIN(%rbx), %rax
    mov %rax, g_max_join_rows(%rip)
    mov DB_TIMEOUT(%rbx), %rax
    mov %rax, g_srv_timeout_ms(%rip)
    mov DB_TESTFN(%rbx), %rax
    mov %rax, g_test_functions(%rip)
    movq $0, DB_ERRCODE(%rbx)
    LEAVE
ENDF api_activate

/* api_begin(db rdi): takes the lock and activates db */
FUNC api_begin
    push %rbx
    mov %rdi, %rbx
    lea api_lock(%rip), %rdi
    call pthread_mutex_lock
    mov %rbx, %rdi
    call api_activate
    pop %rbx
    ret
ENDF api_begin

/* api_end(status edi) -> eax status: releases the lock */
FUNC api_end
    push %rbx
    mov %edi, %ebx
    lea api_lock(%rip), %rdi
    call pthread_mutex_unlock
    mov %ebx, %eax
    pop %rbx
    ret
ENDF api_end

/* api_set_error(db rdi, code esi, msg rdx) -> eax code: records an error */
FUNC api_set_error
    ENTER 0
    mov %rdi, %rbx
    mov %esi, %r12d
    mov %rdx, %r13
    mov %r12, DB_ERRCODE(%rbx)
    mov DB_ERRMSG(%rbx), %rdi
    call free
    mov %r13, %rdi
    call strdup
    mov %rax, DB_ERRMSG(%rbx)
    mov %r12d, %eax
    LEAVE
ENDF api_set_error

/* api_bad_arg(db rdi) -> eax PQ_E_INVALID_ARGUMENT (missing argument) */
FUNC api_bad_arg
    sub $8, %rsp
    mov $PQ_E_INVALID_ARGUMENT, %esi
    CSTR %rdx, "missing or invalid argument"
    call api_set_error
    add $8, %rsp
    ret
ENDF api_bad_arg

/* ================================================================ requests */

/* areq_begin(op rdi): starts the request {"op":"<op>" */
FUNC areq_begin
    push %rbx
    mov %rdi, %rbx
    movq $0, api_req+BUF_LEN(%rip)
    lea api_req(%rip), %rdi
    CSTR %rsi, "{\"op\":\""
    call buf_puts
    lea api_req(%rip), %rdi
    mov %rbx, %rsi
    call buf_puts
    lea api_req(%rip), %rdi
    mov $'"', %esi
    call buf_putc
    pop %rbx
    ret
ENDF areq_begin

/* areq_key(key rdi): ,"key": */
FUNC areq_key
    push %rbx
    mov %rdi, %rbx
    lea api_req(%rip), %rdi
    CSTR %rsi, ",\""
    call buf_puts
    lea api_req(%rip), %rdi
    mov %rbx, %rsi
    call buf_puts
    lea api_req(%rip), %rdi
    CSTR %rsi, "\":"
    call buf_puts
    pop %rbx
    ret
ENDF areq_key

/* areq_strn(key rdi, ptr rsi, len rdx): ,"key":"escaped" */
FUNC areq_strn
    push %rbx
    push %r12
    push %r13
    mov %rsi, %r12
    mov %rdx, %r13
    call areq_key
    lea api_req(%rip), %rdi
    mov %r12, %rsi
    mov %r13, %rdx
    call buf_put_json_str
    pop %r13
    pop %r12
    pop %rbx
    ret
ENDF areq_strn

/* areq_str(key rdi, cstr rsi) */
FUNC areq_str
    push %rbx
    push %r12
    sub $8, %rsp
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rsi, %rdi
    call strlen
    mov %rbx, %rdi
    mov %r12, %rsi
    mov %rax, %rdx
    call areq_strn
    add $8, %rsp
    pop %r12
    pop %rbx
    ret
ENDF areq_str

/* areq_int(key rdi, value rsi) */
FUNC areq_int
    push %rbx
    mov %rsi, %rbx
    call areq_key
    lea api_req(%rip), %rdi
    mov %rbx, %rsi
    call buf_put_i64
    pop %rbx
    ret
ENDF areq_int

/* areq_bool(key rdi, value rsi: 0 false, else true) */
FUNC areq_bool
    push %rbx
    mov %rsi, %rbx
    call areq_key
    lea api_req(%rip), %rdi
    CSTR %rsi, "true"
    test %rbx, %rbx
    jnz 1f
    CSTR %rsi, "false"
1:  call buf_puts
    pop %rbx
    ret
ENDF areq_bool

/* areq_json_str(cstr rdi): a quoted, escaped JSON string */
FUNC areq_json_str
    push %rbx
    mov %rdi, %rbx
    call strlen
    lea api_req(%rip), %rdi
    mov %rbx, %rsi
    mov %rax, %rdx
    call buf_put_json_str
    pop %rbx
    ret
ENDF areq_json_str

/* areq_raw(cstr rdi) */
FUNC areq_raw
    sub $8, %rsp
    mov %rdi, %rsi
    lea api_req(%rip), %rdi
    call buf_puts
    add $8, %rsp
    ret
ENDF areq_raw

/* areq_run(db rdi) -> eax status: completes the request and runs it on the
 * engine stack through the protocol dispatcher; records the error */
FUNC areq_run
    ENTER 16
    mov %rdi, %rbx
    lea api_req(%rip), %rdi
    mov $'}', %esi
    call buf_putc
    mov g_http_capture(%rip), %rax
    mov %rax, 0(%rsp)
    movq $1, g_http_capture(%rip)   /* keep the response in g_out */
    mov api_stack_top(%rip), %rax
    test %rax, %rax
    jz 1f
    mov %rax, %rsp                  /* engine stack (LEAVE restores via rbp) */
    mov api_stack_lo(%rip), %rdi
    call stack_set_bottom
1:  mov api_req+BUF_DATA(%rip), %rdi
    mov api_req+BUF_LEN(%rip), %rsi
    call proto_handle_line
    movq $0, %fs:t_stack_lo@tpoff
    lea -64(%rbp), %rsp             /* back on the caller's stack (0(%rsp) kept) */
    mov 0(%rsp), %rax
    mov %rax, g_http_capture(%rip)
    movq $CAP_NONE, g_api_capture(%rip)
    mov g_req_status(%rip), %rax
    test %rax, %rax
    jz 9f
    mov %rbx, %rdi
    mov %eax, %esi
    lea g_err_msg(%rip), %rdx
    call api_set_error
9:  LEAVE
ENDF areq_run

/* areq_query_options(opts rdi or 0): ,"options":{...} of a query */
FUNC areq_query_options
    ENTER 0
    mov %rdi, %rbx
    CSTR %rdi, ",\"options\":{\"result\":\"rows\""
    call areq_raw
    test %rbx, %rbx
    jz 9f
    mov PQ_QOPT_THREADS(%rbx), %rsi
    test %rsi, %rsi
    jz 1f
    CSTR %rdi, "threads"
    call areq_int
1:  mov PQ_QOPT_TIMEOUT_MS(%rbx), %rsi
    test %rsi, %rsi
    jz 2f
    CSTR %rdi, "timeout_ms"
    call areq_int
2:  mov PQ_QOPT_MAX_ROWS(%rbx), %rsi
    test %rsi, %rsi
    js 3f
    CSTR %rdi, "max_rows"
    call areq_int
3:  mov PQ_QOPT_MODE(%rbx), %rsi
    test %rsi, %rsi
    jz 4f
    CSTR %rdi, "mode"
    call areq_str
4:  mov PQ_QOPT_JOIN(%rbx), %rsi
    test %rsi, %rsi
    jz 5f
    CSTR %rdi, "join"
    call areq_str
5:  mov PQ_QOPT_OPTIMIZE(%rbx), %rsi
    test %rsi, %rsi
    jz 6f
    xor %eax, %eax
    cmp $1, %rsi
    sete %al
    mov %rax, %rsi
    CSTR %rdi, "optimize"
    call areq_bool
6:  mov PQ_QOPT_USE_INDEXES(%rbx), %rsi
    test %rsi, %rsi
    jz 9f
    xor %eax, %eax
    cmp $1, %rsi
    sete %al
    mov %rax, %rsi
    CSTR %rdi, "use_indexes"
    call areq_bool
9:  CSTR %rdi, "}"
    call areq_raw
    LEAVE
ENDF areq_query_options

/* ================================================================ create / close */

/* create_fail(msg rdi) -> eax PQ_E_INVALID_ARGUMENT: error of pq_create */
FUNC create_fail
    sub $8, %rsp
    mov %rdi, %rsi
    lea api_create_msg(%rip), %rdi
    mov $255, %edx
    call strncpy
    movq $PQ_E_INVALID_ARGUMENT, api_create_code(%rip)
    mov $PQ_E_INVALID_ARGUMENT, %eax
    add $8, %rsp
    ret
ENDF create_fail

/* pq_create(config rdi or 0, out rsi) -> eax status */
FUNC pq_create
    ENTER 16
    mov %rdi, %r12                  /* config */
    mov %rsi, %r13                  /* out */
    test %r13, %r13
    jz 90f
    movq $0, (%r13)
    lea api_lock(%rip), %rdi
    call pthread_mutex_lock
    call api_init
    movq $0, api_create_code(%rip)
    movb $0, api_create_msg(%rip)
    /* validate: every numeric field >= 0 */
    test %r12, %r12
    jz 2f
    mov $1, %ecx
1:  cmp $8, %ecx
    jae 2f
    cmpq $0, (%r12, %rcx, 8)
    jl 91f
    inc %ecx
    jmp 1b
2:  mov $1, %edi
    mov $DB_SIZE, %esi
    call calloc
    test %rax, %rax
    jz 92f
    mov %rax, %rbx
    /* data directory */
    CSTR %rdi, "."
    test %r12, %r12
    jz 3f
    mov PQ_CONFIG_DATA_DIR(%r12), %rax
    test %rax, %rax
    jz 3f
    mov %rax, %rdi
3:  call strdup
    mov %rax, DB_DATA_DIR(%rbx)
    /* limits: given value or the engine default */
    mov api_def_mem(%rip), %rax
    test %r12, %r12
    jz 4f
    mov PQ_CONFIG_MAX_QUERY_MEM(%r12), %rcx
    test %rcx, %rcx
    jz 4f
    mov %rcx, %rax
    shl $20, %rax
4:  mov %rax, DB_MAXMEM(%rbx)
    mov api_def_ingest(%rip), %rax
    test %r12, %r12
    jz 5f
    mov PQ_CONFIG_MAX_INGEST(%r12), %rcx
    test %rcx, %rcx
    cmovnz %rcx, %rax
5:  mov %rax, DB_MAXINGEST(%rbx)
    mov api_def_rows(%rip), %rax
    test %r12, %r12
    jz 6f
    mov PQ_CONFIG_MAX_TABLE_ROWS(%r12), %rcx
    test %rcx, %rcx
    cmovnz %rcx, %rax
6:  mov %rax, DB_MAXROWS(%rbx)
    mov api_def_join(%rip), %rax
    test %r12, %r12
    jz 7f
    mov PQ_CONFIG_MAX_JOIN_ROWS(%r12), %rcx
    test %rcx, %rcx
    cmovnz %rcx, %rax
7:  mov %rax, DB_MAXJOIN(%rbx)
    test %r12, %r12
    jz 8f
    mov PQ_CONFIG_TIMEOUT_MS(%r12), %rax
    mov %rax, DB_TIMEOUT(%rbx)
    mov PQ_CONFIG_TEST_FUNCTIONS(%r12), %rax
    test %rax, %rax
    setnz %al
    movzbl %al, %eax
    mov %rax, DB_TESTFN(%rbx)
8:  /* default threads: given, else the online CPUs capped at 16 */
    xor %eax, %eax
    test %r12, %r12
    jz 81f
    mov PQ_CONFIG_THREADS(%r12), %rax
81: test %rax, %rax
    jnz 82f
    movq $1, DB_AUTO(%rbx)
    mov $SC_NPROCESSORS_ONLN, %edi
    call sysconf
    mov $DEFAULT_THREADS_MAX, %ecx
    cmp %rcx, %rax
    cmovg %rcx, %rax
82: mov $1, %ecx
    cmp %rcx, %rax
    cmovl %rcx, %rax
    mov $MAX_THREADS, %ecx
    cmp %rcx, %rax
    cmova %rcx, %rax
    mov %rax, DB_THREADS(%rbx)
    mov %rbx, (%r13)
    xor %edi, %edi
    call api_end
    LEAVE
90: CSTR %rdi, "pq_create: out must not be NULL"
    call create_fail
    LEAVE
91: CSTR %rdi, "pq_create: configuration values must not be negative"
    call create_fail
    mov %eax, %edi
    call api_end
    LEAVE
92: CSTR %rdi, "pq_create: out of memory"
    call create_fail
    movq $PQ_E_RESOURCE_LIMIT, api_create_code(%rip)
    mov $PQ_E_RESOURCE_LIMIT, %edi
    call api_end
    LEAVE
ENDF pq_create

/* pq_close(db rdi): drops the instance's tables and frees it */
FUNC pq_close
    ENTER 0
    mov %rdi, %rbx
    test %rbx, %rbx
    jz 9f
    mov %rbx, %rdi
    call api_begin
    call cat_reset
    lea DB_CAT(%rbx), %rdi          /* deactivate: the globals become empty */
    call cat_swap
    movq $0, api_active(%rip)
    mov DB_CAT(%rbx), %rdi          /* the catalog's (now empty) array */
    call free
    mov DB_ERRMSG(%rbx), %rdi
    call free
    mov DB_DATA_DIR(%rbx), %rdi
    call free
    mov %rbx, %rdi
    call free
    xor %edi, %edi
    call api_end
9:  LEAVE
ENDF pq_close

/* ================================================================ errors, version */

/* pq_errcode(db rdi or 0) -> eax */
FUNC pq_errcode
    test %rdi, %rdi
    jz 1f
    mov DB_ERRCODE(%rdi), %rax
    ret
1:  mov api_create_code(%rip), %rax
    ret
ENDF pq_errcode

/* pq_errmsg(db rdi or 0) -> rax C string */
FUNC pq_errmsg
    test %rdi, %rdi
    jz 1f
    cmpq $0, DB_ERRCODE(%rdi)
    je 2f
    mov DB_ERRMSG(%rdi), %rax
    test %rax, %rax
    jz 2f
    ret
1:  lea api_create_msg(%rip), %rax
    ret
2:  lea empty_str(%rip), %rax
    ret
ENDF pq_errmsg

/* pq_error_name(code edi) -> rax C string */
FUNC pq_error_name
    test %edi, %edi
    jnz 1f
    lea ok_name(%rip), %rax
    ret
1:  movslq %edi, %rdi
    cmp $0, %rdi
    jg 2f
    mov $PQ_E_INTERNAL_ERROR, %edi
2:  jmp proto_err_name
ENDF pq_error_name

/* pq_version() -> rax C string */
FUNC pq_version
    lea version_text(%rip), %rax
    ret
ENDF pq_version

/* ================================================================ load */

/* load_common(db, table, path, data, len, opts) [rows_out at 16(%rbp)]:
 * pq_load_file (data = 0) and pq_load_text (path = 0) */
FUNC load_common
    ENTER 16
    mov %rdi, %rbx                  /* db */
    mov %rsi, %r12                  /* table */
    mov %rdx, %r13                  /* path */
    mov %rcx, %r14                  /* data */
    mov %r8, 0(%rsp)                /* len */
    mov %r9, %r15                   /* opts */
    mov %rbx, %rdi
    call api_begin
    test %r12, %r12
    jz 80f
    test %r13, %r13
    jnz 1f
    test %r14, %r14
    jnz 1f
    cmpq $0, 0(%rsp)                /* NULL data of length 0: empty text */
    jne 80f
    CSTR %r14, ""
1:  CSTR %rdi, "load"
    call areq_begin
    CSTR %rdi, "table"
    mov %r12, %rsi
    call areq_str
    CSTR %rdi, "format"
    CSTR %rsi, "csv"
    test %r15, %r15
    jz 2f
    mov PQ_LOAD_FORMAT(%r15), %rax
    test %rax, %rax
    cmovnz %rax, %rsi
2:  call areq_str
    test %r13, %r13
    jz 3f
    CSTR %rdi, "path"
    mov %r13, %rsi
    call areq_str
    jmp 4f
3:  CSTR %rdi, "data"
    mov %r14, %rsi
    mov 0(%rsp), %rdx
    call areq_strn
4:  test %r15, %r15
    jz 20f
    /* explicit schema */
    mov PQ_LOAD_SCHEMA(%r15), %r13
    test %r13, %r13
    jz 10f
    cmpq $0, PQ_LOAD_SCHEMA_LEN(%r15)
    jle 10f
    CSTR %rdi, ",\"schema\":["
    call areq_raw
    xor %r14d, %r14d
5:  cmp PQ_LOAD_SCHEMA_LEN(%r15), %r14
    jge 7f
    test %r14, %r14
    jz 6f
    CSTR %rdi, ","
    call areq_raw
6:  mov %r14, %rax
    shl $4, %rax
    cmpq $0, PQ_COLDEF_NAME(%r13, %rax)
    je 81f
    cmpq $0, PQ_COLDEF_TYPE(%r13, %rax)
    je 81f
    CSTR %rdi, "{\"name\":"
    call areq_raw
    mov %r14, %rax
    shl $4, %rax
    mov PQ_COLDEF_NAME(%r13, %rax), %rdi
    call areq_json_str
    mov %r14, %rax
    shl $4, %rax
    mov PQ_COLDEF_TYPE(%r13, %rax), %rsi
    CSTR %rdi, "type"
    call areq_str
    CSTR %rdi, "}"
    call areq_raw
    inc %r14
    jmp 5b
7:  CSTR %rdi, "]"
    call areq_raw
10: /* CSV options */
    CSTR %rdi, ",\"options\":{\"header\":"
    call areq_raw
    CSTR %rdi, "true"
    cmpq $PQ_HEADER_NO, PQ_LOAD_HEADER(%r15)
    jne 11f
    CSTR %rdi, "false"
11: call areq_raw
    mov PQ_LOAD_DELIMITER(%r15), %rax
    test %rax, %rax
    jz 12f
    mov %al, 8(%rsp)
    CSTR %rdi, "delimiter"
    lea 8(%rsp), %rsi
    mov $1, %edx
    call areq_strn
12: CSTR %rdi, "}"
    call areq_raw
    CSTR %rdi, "replace"
    mov PQ_LOAD_REPLACE(%r15), %rsi
    call areq_bool
20: mov %rbx, %rdi
    call areq_run
    test %eax, %eax
    jnz 90f
    mov 16(%rbp), %r13              /* rows_out */
    test %r13, %r13
    jz 90f
    mov %r12, %rdi
    call strlen
    mov %r12, %rdi
    mov %rax, %rsi
    call cat_find
    test %rax, %rax
    jz 21f
    mov TB_NROWS(%rax), %rax
21: mov %rax, (%r13)
    xor %eax, %eax
    jmp 90f
80: mov %rbx, %rdi
    call api_bad_arg
    jmp 90f
81: mov %rbx, %rdi
    call api_bad_arg
90: mov %eax, %edi
    call api_end
    LEAVE
ENDF load_common

/* pq_load_file(db, table, path, opts, rows_out) -> eax */
FUNC pq_load_file
    test %rdx, %rdx
    jz api_bad_arg_locked
    push %r8                        /* rows_out: the 7th argument */
    mov %rcx, %r9                   /* opts */
    xor %ecx, %ecx                  /* data */
    xor %r8d, %r8d                  /* len */
    call load_common
    add $8, %rsp
    ret
ENDF pq_load_file

/* pq_load_text(db, table, data, len, opts, rows_out) -> eax */
FUNC pq_load_text
    push %r9                        /* rows_out: the 7th argument */
    mov %r8, %r9                    /* opts */
    mov %rcx, %r8                   /* len */
    mov %rdx, %rcx                  /* data */
    xor %edx, %edx                  /* path */
    call load_common
    add $8, %rsp
    ret
ENDF pq_load_text

/* api_bad_arg_locked(db rdi) -> eax: argument error outside the lock */
FUNC api_bad_arg_locked
    push %rbx
    mov %rdi, %rbx
    test %rbx, %rbx
    jz 1f
    call api_begin
    mov %rbx, %rdi
    call api_bad_arg
    mov %eax, %edi
    call api_end
    pop %rbx
    ret
1:  mov $PQ_E_INVALID_ARGUMENT, %eax
    pop %rbx
    ret
ENDF api_bad_arg_locked

/* ================================================================ query */

/* pq_query(db, sql, opts, out) -> eax */
FUNC pq_query
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rcx, %r14
    test %rbx, %rbx
    jz 81f
    mov %rbx, %rdi
    call api_begin
    test %r14, %r14
    jz 80f
    movq $0, (%r14)
    test %r12, %r12
    jz 80f
    CSTR %rdi, "query"
    call areq_begin
    CSTR %rdi, "sql"
    mov %r12, %rsi
    call areq_str
    mov %r13, %rdi
    call areq_query_options
    movq $0, g_api_result(%rip)
    movq $CAP_RESULT, g_api_capture(%rip)
    mov %rbx, %rdi
    call areq_run
    test %eax, %eax
    jnz 2f
    mov g_api_result(%rip), %rax
    test %rax, %rax
    jnz 1f
    xor %edi, %edi                  /* a statement (CREATE INDEX ...): no columns */
    xor %esi, %esi
    xor %edx, %edx
    call api_result_alloc
1:  mov %rax, (%r14)
    xor %eax, %eax
    jmp 90f
2:  mov %eax, %r15d                 /* failed: drop a partial result */
    mov g_api_result(%rip), %rdi
    call free
    mov %r15d, %eax
    jmp 90f
80: mov %rbx, %rdi
    call api_bad_arg
90: movq $0, g_api_result(%rip)
    mov %eax, %edi
    call api_end
    LEAVE
81: mov $PQ_E_INVALID_ARGUMENT, %eax
    LEAVE
ENDF pq_query

/* pq_create_table(db, table, sql, opts, replace, rows_out) -> eax */
FUNC pq_create_table
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rcx, %r14
    mov %r8, %r15
    mov %r9, 0(%rsp)
    test %rbx, %rbx
    jz 81f
    mov %rbx, %rdi
    call api_begin
    test %r12, %r12
    jz 80f
    test %r13, %r13
    jz 80f
    cmpb $0, (%r12)
    je 80f
    CSTR %rdi, "query"
    call areq_begin
    CSTR %rdi, "sql"
    mov %r13, %rsi
    call areq_str
    mov %r14, %rdi
    call areq_query_options
    mov %r12, g_api_ct_name(%rip)
    xor %eax, %eax
    test %r15, %r15
    setnz %al
    mov %rax, g_api_ct_replace(%rip)
    movq $0, g_api_ct_rows(%rip)
    movq $CAP_TABLE, g_api_capture(%rip)
    mov %rbx, %rdi
    call areq_run
    test %eax, %eax
    jnz 90f
    mov 0(%rsp), %rcx
    test %rcx, %rcx
    jz 90f
    mov g_api_ct_rows(%rip), %rdx
    mov %rdx, (%rcx)
    jmp 90f
80: mov %rbx, %rdi
    call api_bad_arg
90: mov %eax, %edi
    call api_end
    LEAVE
81: mov $PQ_E_INVALID_ARGUMENT, %eax
    LEAVE
ENDF pq_create_table

/* ================================================================ results */

/* api_result_alloc(ncols rdi, nrows rsi, string bytes rdx) -> rax pq_result*:
 * one zeroed block: header, columns, values, then rdx bytes of text;
 * the text area pointer is returned in rdx */
FUNC api_result_alloc
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rbx, %r13                  /* values: ncols * nrows * 24 */
    imul %r12, %r13
    imul $PQ_VAL_SIZE, %r13, %r13
    mov %rbx, %r14
    shl $PQ_COL_SHIFT, %r14         /* columns */
    lea PQ_RES_SIZE(%r14, %r13), %rsi
    add %rdx, %rsi
    add $8, %rsi
    mov $1, %edi
    call calloc
    test %rax, %rax
    jz 9f
    mov %rax, %r15
    mov %rbx, PQ_RES_NCOLS(%r15)
    mov %r12, PQ_RES_NROWS(%r15)
    lea PQ_RES_SIZE(%r15), %rcx
    mov %rcx, PQ_RES_COLUMNS(%r15)
    add %r14, %rcx
    mov %rcx, PQ_RES_VALUES(%r15)
    lea (%rcx, %r13), %rdx          /* text area */
    mov %r15, %rax
    LEAVE
9:  RAISE E_RESOURCE_LIMIT, "out of memory for the result"
ENDF api_result_alloc

/* api_put_column(col rdi, name pstr rsi, type rdx, text area rcx) -> rax new
 * text position: fills a pq_column, copying name and type name */
FUNC api_put_column
    ENTER 48
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rcx, %r14
    movzbl %r13b, %eax
    cmp $T_NULL, %eax
    jne 1f
    mov $T_STR, %eax                /* an untyped NULL column is STRING */
1:  mov %eax, PQ_COL_TYPE(%rbx)
    cmp $T_DEC, %eax
    jne 2f
    mov %r13, %rax
    shr $8, %rax
    movzbl %al, %eax
    mov %eax, PQ_COL_PRECISION(%rbx)
    mov %r13, %rax
    shr $16, %rax
    movzbl %al, %eax
    mov %eax, PQ_COL_SCALE(%rbx)
2:  mov %r14, PQ_COL_NAME(%rbx)     /* name */
    mov %r14, %rdi
    lea 8(%r12), %rsi
    mov (%r12), %rdx
    call memcpy
    add (%r12), %r14
    movb $0, (%r14)
    inc %r14
    lea 0(%rsp), %rdi               /* type name via a Buf */
    call buf_init
    lea 0(%rsp), %rdi
    mov %r13, %rsi
    call fmt_type
    mov %r14, PQ_COL_TYPE_NAME(%rbx)
    mov %r14, %rdi
    mov 0+BUF_DATA(%rsp), %rsi
    mov 0+BUF_LEN(%rsp), %rdx
    call memcpy
    add 0+BUF_LEN(%rsp), %r14
    movb $0, (%r14)
    inc %r14
    lea 0(%rsp), %rdi
    call buf_free
    mov %r14, %rax
    LEAVE
ENDF api_put_column

#define TYPE_NAME_MAX 24            /* "DECIMAL(38,38)" fits */

/* api_capture_result(plan rdi, result rsi): op_query in CAP_RESULT mode:
 * converts the executed result into a pq_result (g_api_result) */
FUNC api_capture_result
    ENTER 32
    mov %rdi, %rbx                  /* plan */
    mov %rsi, %r12                  /* result set */
    /* text bytes: column names + type names + string values */
    xor %r13d, %r13d
    xor %ecx, %ecx
1:  cmp QP_NOUT(%rbx), %rcx
    jae 2f
    imul $OC_SIZE, %rcx, %rax
    add QP_OUT(%rbx), %rax
    mov OC_NAME(%rax), %rdx
    mov (%rdx), %rdx
    lea TYPE_NAME_MAX+2(%r13, %rdx), %r13
    inc %rcx
    jmp 1b
2:  xor %r14d, %r14d                /* column */
3:  cmp QP_NOUT(%rbx), %r14
    jae 6f
    imul $OC_SIZE, %r14, %rax
    add QP_OUT(%rbx), %rax
    movzbl OC_TYPE(%rax), %eax
    cmp $T_STR, %eax
    jne 5f
    mov %r14, %r8
    shl $4, %r8                     /* cell offset in a row */
    mov RS_ROWS(%r12), %r9
    xor %ecx, %ecx
4:  cmp RS_NROWS(%r12), %rcx
    jae 5f
    mov (%r9, %rcx, 8), %rax
    inc %rcx
    cmpq $0, VAL_NULL(%rax, %r8)
    jne 4b
    inc %r13                        /* the NUL */
    mov VAL_P(%rax, %r8), %rax
    test %rax, %rax
    jz 4b
    add (%rax), %r13
    jmp 4b
5:  inc %r14
    jmp 3b
6:  mov QP_NOUT(%rbx), %rdi
    mov RS_NROWS(%r12), %rsi
    mov %r13, %rdx
    call api_result_alloc
    mov %rax, %r15
    mov %rax, g_api_result(%rip)
    mov %rdx, %r13                  /* text position */
    /* columns */
    xor %r14d, %r14d
7:  cmp QP_NOUT(%rbx), %r14
    jae 8f
    imul $OC_SIZE, %r14, %rax
    add QP_OUT(%rbx), %rax
    mov %r14, %rdi
    shl $PQ_COL_SHIFT, %rdi
    add PQ_RES_COLUMNS(%r15), %rdi
    mov OC_NAME(%rax), %rsi
    mov OC_TYPE(%rax), %rdx
    mov %r13, %rcx
    call api_put_column
    mov %rax, %r13
    inc %r14
    jmp 7b
8:  /* values, row-major */
    mov PQ_RES_VALUES(%r15), %rdi   /* output cursor */
    xor %ecx, %ecx                  /* row */
10: cmp RS_NROWS(%r12), %rcx
    jae 30f
    mov RS_ROWS(%r12), %rax
    mov (%rax, %rcx, 8), %r8        /* row cells */
    xor %r14d, %r14d
11: cmp QP_NOUT(%rbx), %r14
    jae 20f
    mov %r14, %rax
    shl $4, %rax
    cmpq $0, VAL_NULL(%r8, %rax)
    je 12f
    movq $1, PQ_VAL_IS_NULL(%rdi)
    jmp 19f
12: mov VAL_P(%r8, %rax), %rdx      /* payload */
    imul $OC_SIZE, %r14, %rax
    add QP_OUT(%rbx), %rax
    mov OC_TYPE(%rax), %rsi
    movzbl %sil, %eax
    cmp $T_STR, %eax
    je 15f
    cmp $T_DEC, %eax
    jne 14f
    shr $8, %rsi
    cmp $18, %sil
    ja 13f
    mov %rdx, PQ_VAL_DEC_LO(%rdi)   /* narrow: sign-extend to 128 bits */
    sar $63, %rdx
    mov %rdx, PQ_VAL_DEC_HI(%rdi)
    jmp 19f
13: mov (%rdx), %rax                /* wide: boxed i128 */
    mov %rax, PQ_VAL_DEC_LO(%rdi)
    mov 8(%rdx), %rax
    mov %rax, PQ_VAL_DEC_HI(%rdi)
    jmp 19f
14: mov %rdx, PQ_VAL_I64(%rdi)      /* BOOL, INT, FLOAT bits, DATE, TS */
    jmp 19f
15: mov %r13, PQ_VAL_STR_PTR(%rdi)
    test %rdx, %rdx
    jz 16f
    mov (%rdx), %rax
    mov %rax, PQ_VAL_STR_LEN(%rdi)
    push %rcx
    push %rdi
    push %r8
    push %rax
    mov %r13, %rdi
    lea 8(%rdx), %rsi
    mov %rax, %rdx
    call memcpy
    pop %rax
    pop %r8
    pop %rdi
    pop %rcx
    add %rax, %r13
16: movb $0, (%r13)
    inc %r13
19: add $PQ_VAL_SIZE, %rdi
    inc %r14
    jmp 11b
20: inc %rcx
    test $1023, %rcx
    jnz 10b
    push %rcx
    push %rdi
    push %r8
    sub $8, %rsp
    call check_deadline
    add $8, %rsp
    pop %r8
    pop %rdi
    pop %rcx
    jmp 10b
30: LEAVE
ENDF api_capture_result

/* api_capture_text(ptr rdi, len rsi): EXPLAIN in CAP_RESULT mode: one
 * STRING column "plan" with one row */
FUNC api_capture_text
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov $1, %edi
    mov $1, %esi
    lea 64(%r12), %rdx
    call api_result_alloc
    mov %rax, %r15
    mov %rax, g_api_result(%rip)
    mov %rdx, %r13
    lea 0(%rsp), %rsi               /* pstr "plan" on the stack */
    movq $4, 0(%rsp)
    movl $0x6e616c70, 8(%rsp)       /* "plan" */
    movb $0, 12(%rsp)
    mov PQ_RES_COLUMNS(%r15), %rdi
    mov $T_STR, %edx
    mov %r13, %rcx
    call api_put_column
    mov %rax, %r13
    mov PQ_RES_VALUES(%r15), %r14
    mov %r13, PQ_VAL_STR_PTR(%r14)
    mov %r12, PQ_VAL_STR_LEN(%r14)
    mov %r13, %rdi
    mov %rbx, %rsi
    mov %r12, %rdx
    call memcpy
    movb $0, (%r13, %r12)
    LEAVE
ENDF api_capture_text

/* api_capture_table(plan rdi, result rsi): op_query in CAP_TABLE mode
 * (pq_create_table): publishes the result as table g_api_ct_name, its
 * strings and wide decimals copied into the new table's arena */
FUNC api_capture_table
    ENTER 32
    mov %rdi, %rbx
    mov %rsi, %r12
    mov g_api_ct_name(%rip), %rdi
    call strlen
    mov %rax, 0(%rsp)               /* name length */
    cmpq $0, g_api_ct_replace(%rip)
    jne 1f
    mov g_api_ct_name(%rip), %rdi
    mov 0(%rsp), %rsi
    call cat_find
    test %rax, %rax
    jz 1f
    RAISE E_ALREADY_EXISTS, "table already exists"
1:  mov RS_NROWS(%r12), %rax
    cmp g_max_table_rows(%rip), %rax
    jbe 2f
    RAISE E_RESOURCE_LIMIT, "table exceeds --max-table-rows"
2:  call arena_new
    mov %rax, %r13                  /* the table's arena */
    mov %rax, g_pending_arena(%rip) /* destroyed if anything fails */
    mov %r13, %rdi
    mov g_api_ct_name(%rip), %rsi
    mov 0(%rsp), %rdx
    call pstr_new
    mov %r13, %rdi
    mov %rax, %rsi
    mov QP_NOUT(%rbx), %rdx
    mov RS_NROWS(%r12), %rcx
    call table_new
    mov %rax, 8(%rsp)               /* Table* */
    xor %r14d, %r14d                /* column */
3:  cmp QP_NOUT(%rbx), %r14
    jae 9f
    mov %r14, %r15
    shl $COL_SHIFT, %r15
    mov 8(%rsp), %rax
    add TB_COLS(%rax), %r15         /* Column* */
    imul $OC_SIZE, %r14, %rax
    add QP_OUT(%rbx), %rax
    mov OC_TYPE(%rax), %rcx
    movzbl %cl, %edx
    cmp $T_NULL, %edx
    jne 4f
    mov $T_STR, %ecx                /* untyped NULL column: STRING */
4:  mov %rcx, 16(%rsp)              /* column type */
    mov %r13, %rdi
    mov %r15, %rsi
    mov OC_NAME(%rax), %rdx
    mov RS_NROWS(%r12), %r8
    call col_stage
    xor %ecx, %ecx                  /* row */
5:  cmp RS_NROWS(%r12), %rcx
    jae 8f
    mov %rcx, 24(%rsp)
    mov RS_ROWS(%r12), %rax
    mov (%rax, %rcx, 8), %rax
    mov %r14, %rdx
    shl $4, %rdx
    add %rdx, %rax                  /* cell */
    cmpq $0, VAL_NULL(%rax)
    je 6f
    mov COL_NULLS(%r15), %rdx
    movb $1, (%rdx, %rcx)
    xor %eax, %eax
    jmp 7f
6:  mov VAL_P(%rax), %rax
    mov 16(%rsp), %rdx
    movzbl %dl, %esi
    cmp $T_STR, %esi
    jne 61f
    test %rax, %rax
    jz 7f
    mov %r13, %rdi                  /* copy the string */
    lea 8(%rax), %rsi
    mov (%rax), %rdx
    call pstr_new
    jmp 7f
61: cmp $T_DEC, %esi
    jne 7f
    shr $8, %rdx
    cmp $18, %dl
    jbe 7f
    mov %r13, %rdi                  /* copy the wide decimal box */
    mov 8(%rax), %rdx
    mov (%rax), %rsi
    call dec_box_in
7:  mov 24(%rsp), %rcx
    mov COL_DATA(%r15), %rdx
    mov %rax, (%rdx, %rcx, 8)
    inc %rcx
    jmp 5b
8:  inc %r14
    jmp 3b
9:  mov 8(%rsp), %rdi
    mov $LAYOUT_COLUMN, %esi
    mov $DICT_AUTO, %edx
    call table_finalize
    mov 8(%rsp), %rax
    mov TB_NROWS(%rax), %rax
    mov %rax, g_api_ct_rows(%rip)
    movq $0, g_pending_arena(%rip)
    mov 8(%rsp), %rdi
    call cat_put                    /* replaces (and frees) an old table */
    LEAVE
ENDF api_capture_table

/* pq_result_free(result rdi) */
FUNC pq_result_free
    jmp free
ENDF pq_result_free

/* pq_value_text(result rdi, row rsi, col rdx, buf rcx, cap r8) -> rax length:
 * canonical text of a value (reads only the pq_result structure) */
FUNC pq_value_text
    ENTER 48
    mov %rcx, %r14                  /* buf */
    mov %r8, %r15                   /* cap */
    mov %rdx, %rax                  /* value = values + (row * ncols + col) * 24 */
    mov PQ_RES_NCOLS(%rdi), %r9
    imul %rsi, %r9
    add %rdx, %r9
    imul $PQ_VAL_SIZE, %r9, %r9
    add PQ_RES_VALUES(%rdi), %r9
    mov %r9, %r12                   /* pq_value* */
    shl $PQ_COL_SHIFT, %rax
    add PQ_RES_COLUMNS(%rdi), %rax
    mov %rax, %r13                  /* pq_column* */
    lea 0(%rsp), %rdi
    call buf_init
    cmpq $0, PQ_VAL_IS_NULL(%r12)
    jne 8f
    movslq PQ_COL_TYPE(%r13), %rsi
    cmp $PQ_TYPE_STRING, %esi
    jne 1f
    lea 0(%rsp), %rdi
    mov PQ_VAL_STR_PTR(%r12), %rsi
    mov PQ_VAL_STR_LEN(%r12), %rdx
    test %rsi, %rsi
    jz 8f
    call buf_put
    jmp 8f
1:  mov PQ_VAL_I64(%r12), %rdx      /* payload */
    cmp $PQ_TYPE_DECIMAL, %esi
    jne 2f
    movslq PQ_COL_PRECISION(%r13), %rax
    movslq PQ_COL_SCALE(%r13), %rcx
    shl $16, %rcx
    or %rcx, %rsi
    cmp $18, %eax
    jbe 11f
    lea PQ_VAL_DEC_LO(%r12), %rdx   /* wide: same i128 layout as a box */
11: shl $8, %rax
    or %rax, %rsi
2:  lea 0(%rsp), %rdi
    call fmt_value_text
8:  mov 0+BUF_LEN(%rsp), %rbx       /* length */
    test %r15, %r15
    jz 9f
    lea -1(%r15), %rdx              /* copy at most cap - 1 bytes */
    cmp %rbx, %rdx
    cmova %rbx, %rdx
    mov %rdx, 24(%rsp)
    test %rdx, %rdx
    jz 81f
    mov %r14, %rdi
    mov 0+BUF_DATA(%rsp), %rsi
    call memcpy
81: mov 24(%rsp), %rdx
    movb $0, (%r14, %rdx)
9:  lea 0(%rsp), %rdi
    call buf_free
    mov %rbx, %rax
    LEAVE
ENDF pq_value_text

/* ================================================================ save, open, drop */

/* pq_save(db, table, path, encoding) -> eax */
FUNC pq_save
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rcx, %r14
    test %rbx, %rbx
    jz 81f
    mov %rbx, %rdi
    call api_begin
    test %r12, %r12
    jz 80f
    test %r13, %r13
    jz 80f
    CSTR %rdi, "save"
    call areq_begin
    CSTR %rdi, "table"
    mov %r12, %rsi
    call areq_str
    CSTR %rdi, "path"
    mov %r13, %rsi
    call areq_str
    test %r14, %r14
    jz 1f
    CSTR %rdi, ",\"options\":{\"encoding\":"
    call areq_raw
    mov %r14, %rdi
    call areq_json_str
    CSTR %rdi, "}"
    call areq_raw
1:  mov %rbx, %rdi
    call areq_run
    jmp 90f
80: mov %rbx, %rdi
    call api_bad_arg
90: mov %eax, %edi
    call api_end
    LEAVE
81: mov $PQ_E_INVALID_ARGUMENT, %eax
    LEAVE
ENDF pq_save

/* pq_open(db, table, path, flags) -> eax */
FUNC pq_open
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rcx, %r14
    test %rbx, %rbx
    jz 81f
    mov %rbx, %rdi
    call api_begin
    test %r12, %r12
    jz 80f
    test %r13, %r13
    jz 80f
    CSTR %rdi, "open"
    call areq_begin
    CSTR %rdi, "table"
    mov %r12, %rsi
    call areq_str
    CSTR %rdi, "path"
    mov %r13, %rsi
    call areq_str
    mov %r14, %rsi
    and $PQ_OPEN_REPLACE, %esi
    CSTR %rdi, "replace"
    call areq_bool
    test $PQ_OPEN_MMAP, %r14
    jz 1f
    CSTR %rdi, ",\"options\":{\"mmap\":true}"
    call areq_raw
1:  mov %rbx, %rdi
    call areq_run
    jmp 90f
80: mov %rbx, %rdi
    call api_bad_arg
90: mov %eax, %edi
    call api_end
    LEAVE
81: mov $PQ_E_INVALID_ARGUMENT, %eax
    LEAVE
ENDF pq_open

/* pq_drop(db, table) -> eax */
FUNC pq_drop
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    test %rbx, %rbx
    jz 81f
    mov %rbx, %rdi
    call api_begin
    test %r12, %r12
    jz 80f
    CSTR %rdi, "drop"
    call areq_begin
    CSTR %rdi, "table"
    mov %r12, %rsi
    call areq_str
    mov %rbx, %rdi
    call areq_run
    jmp 90f
80: mov %rbx, %rdi
    call api_bad_arg
90: mov %eax, %edi
    call api_end
    LEAVE
81: mov $PQ_E_INVALID_ARGUMENT, %eax
    LEAVE
ENDF pq_drop

/* ================================================================ tables, schema */

/* pq_tables(db, out) -> eax: the catalog sorted by name */
FUNC pq_tables
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    test %rbx, %rbx
    jz 81f
    mov %rbx, %rdi
    call api_begin
    test %r12, %r12
    jz 80f
    movq $0, (%r12)
    mov g_arena(%rip), %rdi
    call arena_reset
    call cat_sorted
    mov %rax, %r13                  /* Table*[] (request arena) */
    call cat_count
    mov %rax, %r14
    /* size: header + entries + names */
    mov %r14, %r15
    shl $4, %r15
    add $PQ_TL_SIZE, %r15
    xor %ecx, %ecx
1:  cmp %r14, %rcx
    jae 2f
    mov (%r13, %rcx, 8), %rax
    mov TB_NAME(%rax), %rax
    mov (%rax), %rax
    lea 1(%r15, %rax), %r15
    inc %rcx
    jmp 1b
2:  mov $1, %edi
    mov %r15, %rsi
    call calloc
    test %rax, %rax
    jz 82f
    mov %rax, %r15
    mov %r14, PQ_TL_COUNT(%r15)
    lea PQ_TL_SIZE(%r15), %rax
    mov %rax, PQ_TL_TABLES(%r15)
    mov %r14, %rcx
    shl $4, %rcx
    add %rcx, %rax
    mov %rax, 0(%rsp)               /* name area */
    xor %ecx, %ecx
3:  cmp %r14, %rcx
    jae 4f
    mov %rcx, 8(%rsp)
    mov (%r13, %rcx, 8), %rax       /* Table* */
    shl $4, %rcx
    add PQ_TL_TABLES(%r15), %rcx    /* entry */
    mov TB_NROWS(%rax), %rdx
    mov %rdx, PQ_TI_ROW_COUNT(%rcx)
    mov 0(%rsp), %rdi
    mov %rdi, PQ_TI_NAME(%rcx)
    mov TB_NAME(%rax), %rax
    lea 8(%rax), %rsi
    mov (%rax), %rdx
    inc %rdx                        /* with the NUL */
    add %rdx, 0(%rsp)
    call memcpy
    mov 8(%rsp), %rcx
    inc %rcx
    jmp 3b
4:  mov %r15, (%r12)
    xor %eax, %eax
    jmp 90f
82: mov %rbx, %rdi
    mov $PQ_E_RESOURCE_LIMIT, %esi
    CSTR %rdx, "out of memory"
    call api_set_error
    jmp 90f
80: mov %rbx, %rdi
    call api_bad_arg
90: mov %eax, %edi
    call api_end
    LEAVE
81: mov $PQ_E_INVALID_ARGUMENT, %eax
    LEAVE
ENDF pq_tables

/* pq_table_list_free(list rdi) */
FUNC pq_table_list_free
    jmp free
ENDF pq_table_list_free

/* pq_schema(db, table, out) -> eax */
FUNC pq_schema
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    test %rbx, %rbx
    jz 81f
    mov %rbx, %rdi
    call api_begin
    test %r13, %r13
    jz 80f
    movq $0, (%r13)
    test %r12, %r12
    jz 80f
    mov %r12, %rdi
    call strlen
    mov %r12, %rdi
    mov %rax, %rsi
    call cat_find
    test %rax, %rax
    jz 83f
    mov %rax, %r14                  /* Table* */
    /* size: header + columns + names (+ type names) + table name */
    mov TB_NCOLS(%r14), %r15
    shl $PQ_COL_SHIFT, %r15
    add $PQ_SCH_SIZE, %r15
    mov TB_NAME(%r14), %rax
    mov (%rax), %rax
    lea 1(%r15, %rax), %r15
    xor %ecx, %ecx
1:  cmp TB_NCOLS(%r14), %rcx
    jae 2f
    mov %rcx, %rax
    shl $COL_SHIFT, %rax
    add TB_COLS(%r14), %rax
    mov COL_NAME(%rax), %rax
    mov (%rax), %rax
    lea TYPE_NAME_MAX+2(%r15, %rax), %r15
    inc %rcx
    jmp 1b
2:  mov $1, %edi
    mov %r15, %rsi
    call calloc
    test %rax, %rax
    jz 82f
    mov %rax, %r15
    mov TB_NROWS(%r14), %rax
    mov %rax, PQ_SCH_ROW_COUNT(%r15)
    mov TB_NCOLS(%r14), %rax
    mov %rax, PQ_SCH_NCOLS(%r15)
    lea PQ_SCH_SIZE(%r15), %rcx
    mov %rcx, PQ_SCH_COLUMNS(%r15)
    shl $PQ_COL_SHIFT, %rax
    add %rax, %rcx                  /* text area */
    mov %rcx, PQ_SCH_NAME(%r15)
    mov TB_NAME(%r14), %rax
    mov %rcx, %rdi
    lea 8(%rax), %rsi
    mov (%rax), %rdx
    inc %rdx
    mov %rdx, 0(%rsp)
    call memcpy
    mov PQ_SCH_NAME(%r15), %rax
    add 0(%rsp), %rax
    mov %rax, 0(%rsp)               /* text position */
    xor %ecx, %ecx
3:  cmp TB_NCOLS(%r14), %rcx
    jae 4f
    mov %rcx, 8(%rsp)
    mov %rcx, %rax
    shl $COL_SHIFT, %rax
    add TB_COLS(%r14), %rax
    mov %rcx, %rdi
    shl $PQ_COL_SHIFT, %rdi
    add PQ_SCH_COLUMNS(%r15), %rdi
    mov COL_NAME(%rax), %rsi
    mov COL_TYPE(%rax), %rdx
    mov 0(%rsp), %rcx
    call api_put_column
    mov %rax, 0(%rsp)
    mov 8(%rsp), %rcx
    inc %rcx
    jmp 3b
4:  mov %r15, (%r13)
    xor %eax, %eax
    jmp 90f
83: mov %rbx, %rdi
    mov $PQ_E_NOT_FOUND, %esi
    CSTR %rdx, "unknown table"
    call api_set_error
    jmp 90f
82: mov %rbx, %rdi
    mov $PQ_E_RESOURCE_LIMIT, %esi
    CSTR %rdx, "out of memory"
    call api_set_error
    jmp 90f
80: mov %rbx, %rdi
    call api_bad_arg
90: mov %eax, %edi
    call api_end
    LEAVE
81: mov $PQ_E_INVALID_ARGUMENT, %eax
    LEAVE
ENDF pq_schema

/* pq_schema_free(schema rdi) */
FUNC pq_schema_free
    jmp free
ENDF pq_schema_free
