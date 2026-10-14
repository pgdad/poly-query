// =============================================================================
// api.S — the embedding API (spec/apps/embedding.md; public declarations in
// include/polyquery.h / include/polyquery.inc, guide in EMBEDDING.md).
//
// An instance (pq_db, IN_* below) owns
//   * its configuration (data directory, limits, default threads),
//   * its catalog version (catalog.S CatVer: tables + indexes),
//   * a worker thread with a QUERY_STACK_SIZE stack (the engine's stack
//     guard, CR-6, needs it) that runs every call made on the instance.
// A call posts a job to the worker and waits for it (api_call). The worker
// takes the process-wide API lock, installs the instance's configuration
// into the engine globals (g_data_dir, limits, g_cat_cur via cat_exchange),
// runs the job and saves the catalog back. So several instances may exist,
// calls from any thread are safe, and they run one at a time.
//
// Jobs reuse the protocol layer: load / save / open / drop / query build a
// protocol request (JSON text) and run it through handle_request exactly as
// the CLI does. For queries the TLS hook g_api_sink (protocol.S op_query)
// hands the BoundQuery + ResultSet to api_sink_result, which converts them
// into a pq_result (one malloc'ed block) instead of JSON. pq_query_into
// converts the rows into a new Table (api_sink_table) that a second guarded
// step (api_guard, write access) publishes in the catalog. tables / schema
// are built directly from the catalog inside api_guard.
//
// Errors: the engine's pq_raise records code and message (TLS g_err_code /
// g_err_msg); the worker copies them into the instance (IN_ERR, IN_ERRMSG).
// =============================================================================
#include "pq.inc"
#include "frame.inc"

// ------------------------------------------------------------ instance -------
#define IN_DATA_DIR   0         // cstr (malloc, absolute path)
#define IN_QMEM       8         // bytes per query (--max-query-memory-mb)
#define IN_THREADS    16        // default query threads (--threads)
#define IN_INGEST     24        // --max-ingest-bytes
#define IN_TROWS      32        // --max-table-rows
#define IN_JROWS      40        // --max-join-rows
#define IN_TESTFN     48        // u32 --enable-test-functions
#define IN_STATE      52        // u32 JS_* (guarded by IN_MUTEX)
#define IN_CAT        56        // CatVer* (the instance's catalog)
#define IN_THREAD     64        // pthread_t worker
#define IN_JOB_FN     72        // job: fn(x0 arg) -> w0 error code
#define IN_JOB_ARG    80
#define IN_JOB_RC     88        // u32 result of the job
#define IN_ERR        92        // u32 code of the most recent call
#define IN_MUTEX      96        // pthread_mutex_t (job hand-over)
#define IN_COND       160       // pthread_cond_t
#define IN_CALL       224       // pthread_mutex_t (serialises callers)
#define IN_ERRMSG     288       // char[ERRMSG_LEN] message of IN_ERR
#define ERRMSG_LEN    1024
#define IN_SIZE       (IN_ERRMSG + ERRMSG_LEN)

#define JS_IDLE   0
#define JS_POSTED 1
#define JS_DONE   2
#define JS_QUIT   3

#define GA_NONE   0             // api_guard catalog access
#define GA_READ   1
#define GA_WRITE  2

// request job argument (job_request / job_query_into)
#define RJ_PTR     0            // request JSON text
#define RJ_LEN     8
#define RJ_SINK    16           // g_api_sink value
#define RJ_OUT     24           // pq_result* produced by the sink
#define RJ_NAME    32           // pq_query_into: table name cstr
#define RJ_REPLACE 40           // pq_query_into: replace flag
#define RJ_TABLE   48           // pq_query_into: built Table*
#define RJ_SIZE    64

// pq_result block layout (polyquery.h)
#define R_NCOLS   0
#define R_NROWS   8
#define R_COLUMNS 16
#define R_VALUES  24
#define R_SIZE    32
#define C_NAME    0
#define C_TNAME   8
#define C_TYPE    16
#define C_PREC    20
#define C_SCALE   24
#define C_SIZE    32
#define V_V       0
#define V_AUX     8
#define V_NULL    16
#define V_TYPE    20
#define V_SIZE    24

    .bss
    .p2align 4
g_api_lock:     .skip 64        // pthread_mutex_t: one call at a time
g_api_inited:   .skip 8         // engine defaults captured
g_api_dqmem:    .skip 8         // engine defaults (before any instance)
g_api_dingest:  .skip 8
g_api_dtrows:   .skip 8
g_api_djrows:   .skip 8

    TBSS
    .p2align 3
g_api_out:      .skip 8         // pq_result* built by api_sink_result
g_api_table:    .skip 8         // Table* built by api_sink_table
g_api_cerr:     .skip 8         // pq_create failure of this thread (code)
g_api_cmsg:     .skip 256       // ... and its message

    .section .rodata
s_version:  .asciz "polyquery-arm64-asm 0.1.0"
s_ok:       .asciz "OK"
s_empty:    .asciz ""
s_dot:      .asciz "."
s_nodir:    .asciz "data directory not found: %s"
s_nothread: .asciz "cannot create the engine thread"
s_nomem:    .asciz "out of memory"
s_nullarg:  .asciz "a required argument is NULL"
s_badopt:   .asciz "unsupported option value"
s_f6:       .asciz "%.6f"
s_mzero:    .asciz "-0.000000"
s_true:     .asciz "true"
s_false:    .asciz "false"
s_name:     .asciz "name"
s_rowcount: .asciz "row_count"
s_type:     .asciz "type"
m_notable:  .asciz "unknown table "
m_exists:   .asciz "table already exists "
m_dupcol:   .asciz "duplicate column name "
// request fragments
j_load:     .asciz "{\"op\":\"load\",\"table\":"
j_path:     .asciz ",\"path\":"
j_data:     .asciz ",\"data\":"
j_format:   .asciz ",\"format\":\""
j_replace:  .asciz ",\"replace\":true"
j_schema:   .asciz ",\"schema\":["
j_sname:    .asciz "{\"name\":"
j_stype:    .asciz ",\"type\":"
j_lopts:    .asciz ",\"options\":{\"header\":"
j_delim:    .asciz ",\"delimiter\":"
j_save:     .asciz "{\"op\":\"save\",\"table\":"
j_open:     .asciz "{\"op\":\"open\",\"table\":"
j_drop:     .asciz "{\"op\":\"drop\",\"table\":"
j_query:    .asciz "{\"op\":\"query\",\"sql\":"
j_qopts:    .asciz ",\"options\":{\"result\":\"rows\""
j_threads:  .asciz ",\"threads\":"
j_timeout:  .asciz ",\"timeout_ms\":"
j_maxrows:  .asciz ",\"max_rows\":"
j_mode:     .asciz ",\"mode\":"
f_csv:      .asciz "csv"
f_json:     .asciz "json"
f_jsonl:    .asciz "jsonl"
m_row:      .asciz "\"row\""
m_vec:      .asciz "\"vectorized\""
m_bad:      .asciz "\"invalid\""
    .p2align 3
fmt_names:  .quad f_csv, f_json, f_jsonl
    .text

// =============================================================================
// Instances
// =============================================================================

// api_defaults_once(): remember the engine's compiled-in limits (called with
// g_api_lock held, before the first instance changes them)
LFUNC api_defaults_once
    LDR_G x9, g_api_inited
    cbnz x9, 1f
    LDR_G x9, g_max_query_mem
    ADR_L x10, g_api_dqmem
    str  x9, [x10]
    LDR_G x9, g_max_ingest_bytes
    ADR_L x10, g_api_dingest
    str  x9, [x10]
    LDR_G x9, g_max_table_rows
    ADR_L x10, g_api_dtrows
    str  x9, [x10]
    LDR_G x9, g_max_join_rows
    ADR_L x10, g_api_djrows
    str  x9, [x10]
    mov  x9, #1
    ADR_L x10, g_api_inited
    str  x9, [x10]
1:  ret
ENDF api_defaults_once

// create_fail(w0 code, x1 printf format, x2 arg) -> w0 code: records a
// pq_create failure for pq_errcode / pq_errmsg(NULL) on this thread
LFUNC create_fail
    ENTER 1
    mov  w19, w0
    TLS_ADDR x9, g_api_cerr
    str  x0, [x9]
    mov  x3, x2
    mov  x2, x1
    mov  x1, #256
    TLS_ADDR x0, g_api_cmsg
    bl   snprintf
    mov  w0, w19
    LEAVE 1
ENDF create_fail

// pq_create(x0 const pq_config* or 0, x1 pq_db** out) -> w0 status
//   x19 cfg, x20 out, x21 instance, x22 data dir (realpath), x23 scratch
FUNC pq_create
    ENTER 4
    sub  sp, sp, #80                // pthread_attr_t (64 bytes)
    mov  x19, x0
    mov  x20, x1
    TLS_ADDR x9, g_api_cerr
    str  xzr, [x9]
    TLS_ADDR x9, g_api_cmsg
    strb wzr, [x9]
    cbnz x20, 1f
    mov  w0, #ERR_INVALID_REQUEST
    ADR_L x1, s_nullarg
    bl   create_fail
    b    .Lcr_ret
1:  str  xzr, [x20]
    ADR_L x0, s_dot                 // data directory: absolute and existing
    cbz  x19, 2f
    ldr  x9, [x19, #0]
    cbz  x9, 2f
    mov  x0, x9
2:  mov  x23, x0
    mov  x1, #0
    bl   realpath
    mov  x22, x0
    cbz  x0, 3f
    bl   opendir
    cbz  x0, 3f
    bl   closedir
    b    4f
3:  mov  x0, x22
    bl   free
    mov  w0, #ERR_NOT_FOUND
    ADR_L x1, s_nodir
    mov  x2, x23
    bl   create_fail
    b    .Lcr_ret
4:  mov  x0, #1
    mov  x1, #IN_SIZE
    bl   calloc
    mov  x21, x0
    cbnz x0, 5f
    mov  x0, x22
    bl   free
    mov  w0, #ERR_RESOURCE_LIMIT
    ADR_L x1, s_nomem
    bl   create_fail
    b    .Lcr_ret
5:  str  x22, [x21, #IN_DATA_DIR]
    ADR_L x0, g_api_lock
    bl   pthread_mutex_lock
    bl   api_defaults_once
    // limits: configured value, else the engine default
    LDR_G x9, g_api_dqmem
    cbz  x19, 6f
    ldr  x10, [x19, #8]             // max_query_memory_mb
    lsl  x10, x10, #20
    cmp  x10, #0
    csel x9, x9, x10, eq
6:  str  x9, [x21, #IN_QMEM]
    LDR_G x9, g_api_dingest
    cbz  x19, 7f
    ldr  x10, [x19, #24]
    cmp  x10, #0
    csel x9, x9, x10, eq
7:  str  x9, [x21, #IN_INGEST]
    LDR_G x9, g_api_dtrows
    cbz  x19, 8f
    ldr  x10, [x19, #32]
    cmp  x10, #0
    csel x9, x9, x10, eq
8:  str  x9, [x21, #IN_TROWS]
    LDR_G x9, g_api_djrows
    cbz  x19, 9f
    ldr  x10, [x19, #40]
    cmp  x10, #0
    csel x9, x9, x10, eq
9:  str  x9, [x21, #IN_JROWS]
    mov  x9, #0
    cbz  x19, 10f
    ldr  w9, [x19, #48]
    and  w9, w9, #1
10: str  w9, [x21, #IN_TESTFN]
    mov  x9, #0                     // threads: configured, else min(CPUs, 8)
    cbz  x19, 11f
    ldr  x9, [x19, #16]
11: cbnz x9, 12f
    bl   get_nprocs
    sxtw x9, w0
    cmp  x9, #8
    mov  x10, #8
    csel x9, x9, x10, ls
    cmp  x9, #1
    csinc x9, x9, xzr, hs
12: str  x9, [x21, #IN_THREADS]
    // the instance's (empty) catalog version
    mov  x0, #0
    bl   cat_exchange
    mov  x23, x0
    bl   cat_init
    mov  x0, x23
    bl   cat_exchange
    str  x0, [x21, #IN_CAT]
    ADR_L x0, g_api_lock
    bl   pthread_mutex_unlock
    add  x0, x21, #IN_MUTEX
    mov  x1, #0
    bl   pthread_mutex_init
    add  x0, x21, #IN_CALL
    mov  x1, #0
    bl   pthread_mutex_init
    add  x0, x21, #IN_COND
    mov  x1, #0
    bl   pthread_cond_init
    // the worker thread
    mov  x0, sp
    bl   big_stack_attr
    add  x0, x21, #IN_THREAD
    mov  x1, sp
    ADR_L x2, api_worker_main
    mov  x3, x21
    bl   pthread_create
    mov  w23, w0
    mov  x0, sp
    bl   pthread_attr_destroy
    cbz  w23, 13f
    mov  x0, x21
    bl   api_free_instance
    mov  w0, #ERR_INTERNAL
    ADR_L x1, s_nothread
    bl   create_fail
    b    .Lcr_ret
13: str  x21, [x20]
    mov  w0, #0
.Lcr_ret:
    add  sp, sp, #80
    LEAVE 4
ENDF pq_create

// api_free_instance(x0 instance): release the catalog and the memory (the
// worker has ended)
LFUNC api_free_instance
    ENTER 1
    mov  x19, x0
    ADR_L x0, g_api_lock
    bl   pthread_mutex_lock
    ldr  x0, [x19, #IN_CAT]
    bl   cat_release
    ADR_L x0, g_api_lock
    bl   pthread_mutex_unlock
    add  x0, x19, #IN_MUTEX
    bl   pthread_mutex_destroy
    add  x0, x19, #IN_CALL
    bl   pthread_mutex_destroy
    add  x0, x19, #IN_COND
    bl   pthread_cond_destroy
    ldr  x0, [x19, #IN_DATA_DIR]
    bl   free
    mov  x0, x19
    bl   free
    LEAVE 1
ENDF api_free_instance

// pq_close(x0 pq_db* or 0): stop the worker, free everything
FUNC pq_close
    cbz  x0, 9f
    ENTER 1
    mov  x19, x0
    add  x0, x19, #IN_CALL
    bl   pthread_mutex_lock
    add  x0, x19, #IN_MUTEX
    bl   pthread_mutex_lock
    mov  w9, #JS_QUIT
    str  w9, [x19, #IN_STATE]
    add  x0, x19, #IN_COND
    bl   pthread_cond_broadcast
    add  x0, x19, #IN_MUTEX
    bl   pthread_mutex_unlock
    ldr  x0, [x19, #IN_THREAD]
    mov  x1, #0
    bl   pthread_join
    add  x0, x19, #IN_CALL
    bl   pthread_mutex_unlock
    mov  x0, x19
    bl   api_free_instance
    LEAVE 1
9:  ret
ENDF pq_close

// api_worker_main(x0 instance) -> x0 0: runs the instance's jobs until
// pq_close. Thread-local buffers of the engine are released at the end.
LFUNC api_worker_main
    ENTER 1
    mov  x19, x0
    bl   stack_guard_init
    add  x0, x19, #IN_MUTEX
    bl   pthread_mutex_lock
1:  ldr  w9, [x19, #IN_STATE]
    cmp  w9, #JS_POSTED
    b.eq 2f
    cmp  w9, #JS_QUIT
    b.eq 3f
    add  x0, x19, #IN_COND
    add  x1, x19, #IN_MUTEX
    bl   pthread_cond_wait
    b    1b
2:  add  x0, x19, #IN_MUTEX
    bl   pthread_mutex_unlock
    mov  x0, x19
    bl   api_exec_job
    add  x0, x19, #IN_MUTEX
    bl   pthread_mutex_lock
    mov  w9, #JS_DONE
    str  w9, [x19, #IN_STATE]
    add  x0, x19, #IN_COND
    bl   pthread_cond_broadcast
    b    1b
3:  add  x0, x19, #IN_MUTEX
    bl   pthread_mutex_unlock
    TLS_LDR x0, g_out               // engine thread-local buffers
    bl   free
    TLS_LDR x0, g_pq_out
    bl   free
    TLS_LDR x0, g_pq_meta
    bl   free
    TLS_ADDR x0, g_arena
    bl   arena_free
    mov  x0, #0
    LEAVE 1
ENDF api_worker_main

// api_exec_job(x0 instance): run the posted job with the instance installed
// in the engine globals (worker thread)
//   x19 instance, x20 previous catalog version, w21 result
LFUNC api_exec_job
    ENTER 3
    mov  x19, x0
    ADR_L x0, g_api_lock
    bl   pthread_mutex_lock
    ldr  x9, [x19, #IN_DATA_DIR]
    ADR_L x10, g_data_dir
    str  x9, [x10]
    ldr  x9, [x19, #IN_QMEM]
    ADR_L x10, g_max_query_mem
    str  x9, [x10]
    ldr  x9, [x19, #IN_INGEST]
    ADR_L x10, g_max_ingest_bytes
    str  x9, [x10]
    ldr  x9, [x19, #IN_TROWS]
    ADR_L x10, g_max_table_rows
    str  x9, [x10]
    ldr  x9, [x19, #IN_JROWS]
    ADR_L x10, g_max_join_rows
    str  x9, [x10]
    ldr  x9, [x19, #IN_THREADS]
    ADR_L x10, g_def_threads
    str  x9, [x10]
    ldr  w9, [x19, #IN_TESTFN]
    ADR_L x10, g_test_functions
    str  w9, [x10]
    ldr  x0, [x19, #IN_CAT]
    bl   cat_exchange
    mov  x20, x0
    ldr  x0, [x19, #IN_JOB_ARG]
    ldr  x9, [x19, #IN_JOB_FN]
    blr  x9
    mov  w21, w0
    str  w21, [x19, #IN_JOB_RC]
    str  w21, [x19, #IN_ERR]
    strb wzr, [x19, #IN_ERRMSG]
    cbz  w21, 1f
    add  x0, x19, #IN_ERRMSG
    TLS_ADDR x1, g_err_msg
    mov  x2, #ERRMSG_LEN - 1
    bl   strncpy
    strb wzr, [x19, #IN_ERRMSG + ERRMSG_LEN - 1]
1:  mov  x0, x20
    bl   cat_exchange
    str  x0, [x19, #IN_CAT]
    ADR_L x0, g_api_lock
    bl   pthread_mutex_unlock
    LEAVE 3
ENDF api_exec_job

// api_call(x0 instance, x1 job fn, x2 job arg) -> w0 status: run a job on
// the instance's worker and wait for it
//   x19 instance
LFUNC api_call
    ENTER 2
    mov  x19, x0
    stp  x1, x2, [sp, #-16]!
    add  x0, x19, #IN_CALL
    bl   pthread_mutex_lock
    add  x0, x19, #IN_MUTEX
    bl   pthread_mutex_lock
    ldp  x1, x2, [sp], #16
    str  x1, [x19, #IN_JOB_FN]
    str  x2, [x19, #IN_JOB_ARG]
    mov  w9, #JS_POSTED
    str  w9, [x19, #IN_STATE]
    add  x0, x19, #IN_COND
    bl   pthread_cond_broadcast
1:  ldr  w9, [x19, #IN_STATE]
    cmp  w9, #JS_DONE
    b.eq 2f
    add  x0, x19, #IN_COND
    add  x1, x19, #IN_MUTEX
    bl   pthread_cond_wait
    b    1b
2:  mov  w9, #JS_IDLE
    str  w9, [x19, #IN_STATE]
    ldr  w20, [x19, #IN_JOB_RC]
    add  x0, x19, #IN_MUTEX
    bl   pthread_mutex_unlock
    add  x0, x19, #IN_CALL
    bl   pthread_mutex_unlock
    mov  w0, w20
    LEAVE 2
ENDF api_call

// api_arg_error(x0 instance or 0, w1 code, x2 message) -> w0 code: a
// failure detected before the engine runs (bad arguments)
LFUNC api_arg_error
    ENTER 1
    mov  w19, w1
    cbz  x0, 1f
    str  w1, [x0, #IN_ERR]
    add  x0, x0, #IN_ERRMSG
    mov  x1, x2
    mov  x2, #ERRMSG_LEN - 1
    bl   strncpy
1:  mov  w0, w19
    LEAVE 1
ENDF api_arg_error

// =============================================================================
// Errors
// =============================================================================

FUNC pq_errcode
    cbz  x0, 1f
    ldr  w0, [x0, #IN_ERR]
    ret
1:  TLS_LDR x0, g_api_cerr
    ret
ENDF pq_errcode

FUNC pq_code_name
    cbnz w0, 1f
    ADR_L x0, s_ok
    ret
1:  b    err_code_name
ENDF pq_code_name

FUNC pq_errname
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    bl   pq_errcode
    bl   pq_code_name
    ldp  x29, x30, [sp], #16
    ret
ENDF pq_errname

FUNC pq_errmsg
    cbz  x0, 1f
    ldr  w9, [x0, #IN_ERR]
    add  x0, x0, #IN_ERRMSG
    cbnz w9, 2f
    ADR_L x0, s_empty
2:  ret
1:  TLS_ADDR x0, g_api_cmsg
    ret
ENDF pq_errmsg

FUNC pq_version
    ADR_L x0, s_version
    ret
ENDF pq_version

// =============================================================================
// Request jobs (worker thread)
// =============================================================================

// job_request(x0 RJ*) -> w0 status: handle_request on the request text with
// the result sink installed
//   x19 RJ
LFUNC job_request
    ENTER 1
    mov  x19, x0
    TLS_ADDR x9, g_api_out
    str  xzr, [x9]
    ldr  x10, [x19, #RJ_SINK]
    TLS_ADDR x9, g_api_sink
    str  x10, [x9]
    ldr  x0, [x19, #RJ_PTR]
    ldr  x1, [x19, #RJ_LEN]
    mov  x2, #0
    mov  x3, #0
    bl   handle_request
    TLS_ADDR x9, g_api_sink
    str  xzr, [x9]
    TLS_LDR x9, g_api_out
    str  x9, [x19, #RJ_OUT]
    cbz  w0, 1f
    str  xzr, [x19, #RJ_OUT]        // failed after the sink: drop the result
    stp  x0, xzr, [sp, #-16]!
    mov  x0, x9
    bl   free
    ldp  x0, xzr, [sp], #16
1:  LEAVE 1
ENDF job_request

// job_query_into(x0 RJ*) -> w0 status: query into a Table, then publish it
//   x19 RJ
LFUNC job_query_into
    ENTER 1
    mov  x19, x0
    TLS_ADDR x9, g_api_table
    str  xzr, [x9]
    ADR_L x9, api_sink_table
    str  x9, [x19, #RJ_SINK]
    bl   job_request
    cbnz w0, 9f
    TLS_LDR x9, g_api_table
    str  x9, [x19, #RJ_TABLE]
    TLS_ADDR x9, g_pending_table    // not freed by later requests
    str  xzr, [x9]
    ADR_L x0, api_adopt
    mov  x1, x19
    mov  w2, #GA_WRITE
    bl   api_guard
9:  LEAVE 1
ENDF job_query_into

// api_guard(x0 fn(x0 arg), x1 arg, w2 GA_*) -> w0 status: runs fn like a
// request: errors raised inside unwind here, catalog changes are published
// only on success, the request arena is released.
//   x19 fn, x20 arg, w21 access, w22 status
LFUNC api_guard
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    mov  w21, w2
    TLS_ADDR x0, g_jmpbuf
    bl   setjmp
    cbnz w0, .Lg_error
    cmp  w21, #GA_READ
    b.ne 1f
    bl   cat_read_begin
    b    2f
1:  cmp  w21, #GA_WRITE
    b.ne 2f
    bl   cat_write_begin
2:  mov  x0, x20
    blr  x19
    mov  w0, #1
    bl   cat_end
    mov  w22, #ERR_NONE
    b    .Lg_done
.Lg_error:
    TLS_LDR x19, g_pending_table
    cbz  x19, 3f
    add  x0, x19, #TBL_ARENA
    bl   arena_free
    mov  x0, x19
    bl   free
    TLS_ADDR x0, g_pending_table
    str  xzr, [x0]
3:  mov  w0, #0
    bl   cat_end
    TLS_ADDR x0, g_err_code
    ldr  w22, [x0]
.Lg_done:
    TLS_ADDR x0, g_arena
    bl   arena_free
    TLS_ADDR x0, g_deadline
    str  xzr, [x0]
    TLS_ADDR x0, g_arena_limit
    str  xzr, [x0]
    mov  w0, w22
    LEAVE 3
ENDF api_guard

// api_adopt(x0 RJ*): publish the table built by api_sink_table under its name
// (guarded, write access)
//   x19 RJ, x20 Table*, x21 name, x22 name length
LFUNC api_adopt
    ENTER 3
    mov  x19, x0
    ldr  x20, [x19, #RJ_TABLE]
    TLS_ADDR x9, g_pending_table    // freed if anything below fails
    str  x20, [x9]
    ldr  x21, [x19, #RJ_NAME]
    mov  x0, x21
    bl   strlen
    mov  x22, x0
    cbnz x22, 1f
    RAISE ERR_INVALID_REQUEST, "table name must not be empty"
1:  mov  x0, x21
    mov  x1, x22
    bl   catalog_find
    mov  x23, x0
    cbz  x0, 2f
    ldr  x9, [x19, #RJ_REPLACE]
    cbnz x9, 2f
    mov  w0, #ERR_ALREADY_EXISTS
    ADR_L x1, m_exists
    mov  x2, x21
    mov  x3, x22
    bl   pq_raise_s
2:  add  x0, x20, #TBL_ARENA
    mov  x1, x21
    mov  x2, x22
    bl   str_new_in
    str  x0, [x20, #TBL_NAME]
    cbz  x23, 3f
    mov  x0, x23
    bl   catalog_remove
3:  mov  x0, x20
    bl   catalog_add
    TLS_ADDR x9, g_pending_table
    str  xzr, [x9]
    LEAVE 3
ENDF api_adopt

// =============================================================================
// Result conversion
// =============================================================================

// norm_kind(w0 engine type) -> w0 PQ_T_* (T_NULL and unknown => STRING)  (leaf)
LFUNC norm_kind
    and  w0, w0, #T_KIND_MASK
    sub  w9, w0, #1
    cmp  w9, #T_TS - 1
    b.ls 1f
    mov  w0, #T_STR
1:  ret
ENDF norm_kind

// api_sink_result(x0 BoundQuery*, x1 ResultSet*): g_api_sink for pq_query
LFUNC api_sink_result
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    mov  x2, x1
    ldr  x1, [x0, #BQ_NOUT]
    ldr  x0, [x0, #BQ_OUT]
    bl   api_build_result
    TLS_ADDR x9, g_api_out
    str  x0, [x9]
    ldp  x29, x30, [sp], #16
    ret
ENDF api_sink_result

// api_build_result(x0 OutCol*, x1 ncols, x2 ResultSet*) -> x0 pq_result*
// One malloc'ed block: header, columns, values, then the string bytes.
//   x19 OutCol*, x20 ncols, x21 rs, x22 nrows, x23 block, x24 type names
//   (Str* [ncols], request arena), x25 string cursor / size, x26 value
//   cursor, x27 row, x28 column
LFUNC api_build_result
    ENTER 5
    sub  sp, sp, #BUF_SIZE
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    ldr  x22, [x21, #RS_NROWS]
    // canonical type names
    lsl  x0, x20, #3
    add  x0, x0, #8
    bl   arena_alloc
    mov  x24, x0
    mov  x28, #0
1:  cmp  x28, x20
    b.hs 2f
    stp  xzr, xzr, [sp]
    stp  xzr, xzr, [sp, #16]
    mov  x9, #OC_SIZE
    madd x9, x28, x9, x19
    ldr  w1, [x9, #OC_TYPE]
    mov  x0, sp
    bl   type_write
    ldr  x0, [sp, #BUF_PTR]
    ldr  x1, [sp, #BUF_LEN]
    bl   str_new
    str  x0, [x24, x28, lsl #3]
    ldr  x0, [sp, #BUF_PTR]
    bl   free
    add  x28, x28, #1
    b    1b
2:  // size: fixed part + names + string cells
    mul  x9, x22, x20
    mov  x10, #V_SIZE
    mul  x25, x9, x10
    add  x25, x25, #R_SIZE
    add  x25, x25, x20, lsl #5
    mov  x28, #0
3:  cmp  x28, x20
    b.hs 6f
    mov  x9, #OC_SIZE
    madd x26, x28, x9, x19
    ldr  x9, [x26, #OC_NAME]
    ldr  x9, [x9, #STR_LEN]
    add  x25, x25, x9
    ldr  x9, [x24, x28, lsl #3]
    ldr  x9, [x9, #STR_LEN]
    add  x25, x25, x9
    add  x25, x25, #2
    ldr  w0, [x26, #OC_TYPE]
    bl   norm_kind
    cmp  w0, #T_STR
    b.ne 5f
    ldr  x9, [x21, #RS_ROWS]
    mov  x27, #0
4:  cmp  x27, x22
    b.hs 5f
    ldr  x10, [x9, x27, lsl #3]
    add  x10, x10, x28, lsl #4
    ldp  x11, x12, [x10]
    add  x27, x27, #1
    cbnz x12, 4b
    cbz  x11, 4b                    // T_NULL-typed columns: no Str
    ldr  x11, [x11, #STR_LEN]
    add  x25, x25, x11
    add  x25, x25, #1
    b    4b
5:  add  x28, x28, #1
    b    3b
6:  mov  x0, x25
    bl   malloc
    cbnz x0, 7f
    RAISE ERR_RESOURCE_LIMIT, "out of memory"
7:  mov  x23, x0
    stp  x20, x22, [x23, #R_NCOLS]
    add  x9, x23, #R_SIZE
    str  x9, [x23, #R_COLUMNS]
    add  x26, x9, x20, lsl #5
    str  x26, [x23, #R_VALUES]
    mul  x9, x22, x20
    mov  x10, #V_SIZE
    madd x25, x9, x10, x26          // string bytes follow the values
    // columns
    mov  x28, #0
8:  cmp  x28, x20
    b.hs 10f
    ldr  x9, [x23, #R_COLUMNS]
    add  x27, x9, x28, lsl #5       // pq_column*
    mov  x9, #OC_SIZE
    madd x9, x28, x9, x19
    ldr  x0, [x9, #OC_NAME]
    bl   copy_str
    str  x0, [x27, #C_NAME]
    ldr  x0, [x24, x28, lsl #3]
    bl   copy_str
    str  x0, [x27, #C_TNAME]
    mov  x9, #OC_SIZE
    madd x9, x28, x9, x19
    ldr  w10, [x9, #OC_TYPE]
    mov  w0, w10
    bl   norm_kind
    str  w0, [x27, #C_TYPE]
    str  xzr, [x27, #C_PREC]        // precision and scale
    str  wzr, [x27, #C_SIZE - 4]
    cmp  w0, #T_DEC
    b.ne 9f
    mov  x9, #OC_SIZE
    madd x9, x28, x9, x19
    ldr  w10, [x9, #OC_TYPE]
    ubfx w11, w10, #T_PREC_SHIFT, #8
    ubfx w12, w10, #T_SCALE_SHIFT, #8
    stp  w11, w12, [x27, #C_PREC]
9:  add  x28, x28, #1
    b    8b
10: // values, row-major
    mov  x27, #0
11: cmp  x27, x22
    b.hs 20f
    mov  x28, #0
12: cmp  x28, x20
    b.hs 19f
    ldr  x9, [x21, #RS_ROWS]
    ldr  x9, [x9, x27, lsl #3]
    add  x9, x9, x28, lsl #4
    ldp  x0, x1, [x9]               // payload, isnull
    ldr  x9, [x23, #R_COLUMNS]
    add  x9, x9, x28, lsl #5
    ldr  w2, [x9, #C_TYPE]
    str  w2, [x26, #V_TYPE]
    cbz  x1, 13f
    stp  xzr, xzr, [x26]
    mov  w9, #1
    str  w9, [x26, #V_NULL]
    b    18f
13: str  wzr, [x26, #V_NULL]
    cmp  w2, #T_STR
    b.ne 14f
    cbz  x0, 131f
    ldr  x9, [x0, #STR_LEN]
    str  x9, [x26, #V_AUX]
    bl   copy_str
    str  x0, [x26, #V_V]
    b    18f
131: mov  w9, #1                    // T_NULL column: NULL
    str  w9, [x26, #V_NULL]
    stp  xzr, xzr, [x26]
    b    18f
14: cmp  w2, #T_DEC
    b.ne 15f
    mov  x9, #OC_SIZE
    madd x9, x28, x9, x19
    ldr  w1, [x9, #OC_TYPE]
    bl   dec_get128
    stp  x0, x1, [x26]
    b    18f
15: stp  x0, xzr, [x26]
18: add  x26, x26, #V_SIZE
    add  x28, x28, #1
    b    12b
19: add  x27, x27, #1
    b    11b
20: mov  x0, x23
    add  sp, sp, #BUF_SIZE
    LEAVE 5

// copy_str(x0 Str*) -> x0 NUL-terminated copy at the string cursor x25
// (advanced); nested helper of api_build_result (uses its x25)
copy_str:
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    str  x19, [sp, #16]
    ldr  x2, [x0, #STR_LEN]
    add  x1, x0, #STR_DATA
    mov  x19, x25
    add  x25, x25, x2
    strb wzr, [x25], #1
    mov  x0, x19
    bl   memcpy
    mov  x0, x19
    ldr  x19, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF api_build_result

// api_sink_table(x0 BoundQuery*, x1 ResultSet*): g_api_sink for
// pq_query_into — converts the rows into a new (unnamed) Table in its own
// arena (registered as g_pending_table, left in g_api_table)
//   x19 OutCol*, x20 ncols, x21 rs, x22 nrows, x23 Table*, x24 arena,
//   x25 Column*, x26 column, x27 row, x28 type
LFUNC api_sink_table
    ENTER 5
    ldr  x19, [x0, #BQ_OUT]
    ldr  x20, [x0, #BQ_NOUT]
    mov  x21, x1
    ldr  x22, [x21, #RS_NROWS]
    mov  x0, #1
    mov  x1, #TBL_SIZE
    bl   calloc
    cbnz x0, 1f
    RAISE ERR_RESOURCE_LIMIT, "out of memory"
1:  mov  x23, x0
    TLS_ADDR x9, g_pending_table
    str  x23, [x9]
    add  x24, x23, #TBL_ARENA
    str  x20, [x23, #TBL_NCOLS]
    str  x22, [x23, #TBL_NROWS]
    mov  x0, x24
    lsl  x1, x20, #5
    add  x1, x1, #COL_SIZE
    bl   arena_alloc_in
    str  x0, [x23, #TBL_COLS]
    mov  x1, #0
    lsl  x2, x20, #5
    add  x2, x2, #COL_SIZE
    bl   memset
    mov  x26, #0
2:  cmp  x26, x20
    b.hs 9f
    ldr  x25, [x23, #TBL_COLS]
    add  x25, x25, x26, lsl #5
    mov  x9, #OC_SIZE
    madd x9, x26, x9, x19
    ldr  x10, [x9, #OC_NAME]
    ldr  w28, [x9, #OC_TYPE]
    bic  w28, w28, #T_SATF
    and  w9, w28, #T_KIND_MASK
    cbnz w9, 3f
    mov  w28, #T_STR                // untyped NULL column => STRING
3:  str  w28, [x25, #COL_TYPE]
    str  wzr, [x25, #COL_ENC]
    mov  x0, x24
    add  x1, x10, #STR_DATA
    ldr  x2, [x10, #STR_LEN]
    bl   str_new_in
    str  x0, [x25, #COL_NAME]
    // duplicate column names are not allowed in a table
    mov  x27, #0
4:  cmp  x27, x26
    b.hs 5f
    ldr  x9, [x23, #TBL_COLS]
    add  x9, x9, x27, lsl #5
    ldr  x0, [x9, #COL_NAME]
    ldr  x1, [x25, #COL_NAME]
    bl   str_ieq
    add  x27, x27, #1
    cbz  w0, 4b
    mov  w0, #ERR_INVALID_REQUEST
    ADR_L x1, m_dupcol
    ldr  x9, [x25, #COL_NAME]
    add  x2, x9, #STR_DATA
    ldr  x3, [x9, #STR_LEN]
    bl   pq_raise_s
5:  mov  x0, x24                    // payload vector
    lsl  x1, x22, #3
    add  x1, x1, #8
    bl   arena_alloc_in
    str  x0, [x25, #COL_DATA]
    mov  x0, x24                    // null bitmap (zeroed)
    add  x1, x22, #7
    lsr  x1, x1, #3
    add  x1, x1, #8
    str  x1, [sp, #-16]!
    bl   arena_alloc_in
    str  x0, [x25, #COL_NULLS]
    ldr  x2, [sp], #16
    mov  x1, #0
    bl   memset
    mov  x27, #0
6:  cmp  x27, x22
    b.hs 8f
    ldr  x9, [x21, #RS_ROWS]
    ldr  x9, [x9, x27, lsl #3]
    add  x9, x9, x26, lsl #4
    ldp  x1, x10, [x9]
    cbnz x10, 7f
    mov  x0, x24
    mov  w2, w28
    bl   val_copy_in
    ldr  x9, [x25, #COL_DATA]
    str  x0, [x9, x27, lsl #3]
    add  x27, x27, #1
    b    6b
7:  ldr  x9, [x25, #COL_DATA]       // NULL: payload 0, bit set
    str  xzr, [x9, x27, lsl #3]
    ldr  x9, [x25, #COL_NULLS]
    lsr  x10, x27, #3
    ldrb w11, [x9, x10]
    and  w12, w27, #7
    mov  w13, #1
    lsl  w13, w13, w12
    orr  w11, w11, w13
    strb w11, [x9, x10]
    add  x27, x27, #1
    b    6b
8:  add  x26, x26, #1
    b    2b
9:  mov  x0, x23
    mov  w1, #-1
    mov  w2, #0
    bl   table_finalize
    TLS_ADDR x9, g_api_table
    str  x23, [x9]
    LEAVE 5
ENDF api_sink_table

// =============================================================================
// Public operations
// =============================================================================

// jput(x0 Buf*, x1 cstr): JSON string literal of a C string
LFUNC jput
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x0, x1, [sp, #16]
    mov  x0, x1
    bl   strlen
    mov  x2, x0
    ldp  x0, x1, [sp, #16]
    ldp  x29, x30, [sp], #32
    b    buf_put_jstr
ENDF jput

// run_request(x0 db, x1 Buf* (request text, freed here), x2 sink,
//             x3 RJ* or 0 (filled)) -> w0 status
//   x19 Buf*, x20 RJ*
LFUNC run_request
    ENTER 2
    sub  sp, sp, #RJ_SIZE
    mov  x19, x1
    mov  x20, x3
    cbnz x20, 1f
    mov  x20, sp
    stp  xzr, xzr, [x20, #RJ_OUT]
    stp  xzr, xzr, [x20, #RJ_REPLACE]
1:  ldr  x9, [x19, #BUF_PTR]
    ldr  x10, [x19, #BUF_LEN]
    stp  x9, x10, [x20, #RJ_PTR]
    str  x2, [x20, #RJ_SINK]
    ADR_L x1, job_request
    ldr  x9, [x20, #RJ_NAME]
    cbz  x9, 2f
    ADR_L x1, job_query_into
2:  mov  x2, x20
    bl   api_call
    mov  w20, w0
    ldr  x0, [x19, #BUF_PTR]
    bl   free
    mov  w0, w20
    add  sp, sp, #RJ_SIZE
    LEAVE 2
ENDF run_request

// put_load(x0 Buf*, x1 table, x2 const pq_load_opts* or 0): the common part
// of a load request after the source: format, replace, schema, options
//   x19 Buf*, x20 opts, x21 i
LFUNC put_load
    ENTER 3
    mov  x19, x0
    mov  x20, x2
    ADR_L x1, j_format
    bl   buf_puts
    mov  w9, #0
    cbz  x20, 1f
    ldr  w9, [x20, #16]             // format
1:  cmp  w9, #2
    b.ls 2f
    mov  w9, #3                     // unknown => rejected below
2:  cmp  w9, #3
    b.ne 3f
    mov  x0, x19
    ADR_L x1, m_bad
    add  x1, x1, #1                 // "invalid" without the leading quote
    bl   buf_puts
    b    4f
3:  ADR_L x10, fmt_names
    ldr  x1, [x10, w9, uxtw #3]
    mov  x0, x19
    bl   buf_puts
4:  mov  x0, x19
    mov  w1, #'"'
    bl   buf_putc
    cbz  x20, 9f
    ldr  w9, [x20, #24]             // flags
    tbz  w9, #1, 5f
    mov  x0, x19
    ADR_L x1, j_replace
    bl   buf_puts
5:  ldr  x9, [x20, #0]              // schema
    cbz  x9, 7f
    mov  x0, x19
    ADR_L x1, j_schema
    bl   buf_puts
    mov  x21, #0
6:  ldr  x9, [x20, #8]
    cmp  x21, x9
    b.hs 61f
    cbz  x21, 62f
    mov  x0, x19
    mov  w1, #','
    bl   buf_putc
62: mov  x0, x19
    ADR_L x1, j_sname
    bl   buf_puts
    ldr  x9, [x20, #0]
    add  x9, x9, x21, lsl #4
    ldr  x1, [x9, #0]
    cbz  x1, .Lpl_null
    mov  x0, x19
    bl   jput
    mov  x0, x19
    ADR_L x1, j_stype
    bl   buf_puts
    ldr  x9, [x20, #0]
    add  x9, x9, x21, lsl #4
    ldr  x1, [x9, #8]
    cbz  x1, .Lpl_null
    mov  x0, x19
    bl   jput
    mov  x0, x19
    mov  w1, #'}'
    bl   buf_putc
    add  x21, x21, #1
    b    6b
61: mov  x0, x19
    mov  w1, #']'
    bl   buf_putc
7:  mov  x0, x19                    // options: header, delimiter
    ADR_L x1, j_lopts
    bl   buf_puts
    ldr  w9, [x20, #24]
    ADR_L x1, s_true
    tbz  w9, #0, 71f
    ADR_L x1, s_false
71: mov  x0, x19
    bl   buf_puts
    ldr  w9, [x20, #20]
    cbz  w9, 8f
    mov  x0, x19
    ADR_L x1, j_delim
    bl   buf_puts
    sub  sp, sp, #16
    strb w9, [sp]
    mov  x0, x19
    mov  x1, sp
    mov  x2, #1
    bl   buf_put_jstr
    add  sp, sp, #16
8:  mov  x0, x19
    mov  w1, #'}'
    bl   buf_putc
9:  mov  x0, x19
    mov  w1, #'}'
    bl   buf_putc
    mov  w0, #0
    LEAVE 3
.Lpl_null:
    mov  w0, #1                     // NULL name or type in the schema
    LEAVE 3
ENDF put_load

// load_common(x0 db, x1 table, x2 key fragment (path / data), x3 ptr,
//             x4 len, x5 opts) -> w0 status
//   x19 db, x20 table, x21 fragment, x22 ptr, x23 len, x24 opts; sp: Buf
LFUNC load_common
    ENTER 4
    sub  sp, sp, #BUF_SIZE
    stp  xzr, xzr, [sp]
    stp  xzr, xzr, [sp, #16]
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x22, x3
    mov  x23, x4
    mov  x24, x5
    cbz  x19, .Llc_null
    cbz  x20, .Llc_null
    cbz  x22, .Llc_null
    mov  x0, sp
    ADR_L x1, j_load
    bl   buf_puts
    mov  x0, sp
    mov  x1, x20
    bl   jput
    mov  x0, sp
    mov  x1, x21
    bl   buf_puts
    mov  x0, sp
    mov  x1, x22
    mov  x2, x23
    bl   buf_put_jstr
    mov  x0, sp
    mov  x1, x20
    mov  x2, x24
    bl   put_load
    cbnz w0, .Llc_null
    mov  x0, x19
    mov  x1, sp
    mov  x2, #0
    mov  x3, #0
    bl   run_request
    b    9f
.Llc_null:
    ldr  x0, [sp, #BUF_PTR]
    bl   free
    mov  x0, x19
    mov  w1, #ERR_INVALID_REQUEST
    ADR_L x2, s_nullarg
    bl   api_arg_error
9:  add  sp, sp, #BUF_SIZE
    LEAVE 4
ENDF load_common

// pq_load_file(x0 db, x1 table, x2 path, x3 opts) -> w0 status
FUNC pq_load_file
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x0, x1, [sp, #16]
    stp  x2, x3, [sp, #32]
    mov  x0, x2
    cbz  x0, 1f
    bl   strlen
1:  mov  x4, x0
    ldp  x0, x1, [sp, #16]
    ldp  x3, x5, [sp, #32]
    ldp  x29, x30, [sp], #48
    ADR_L x2, j_path
    b    load_common
ENDF pq_load_file

// pq_load_text(x0 db, x1 table, x2 text, x3 len, x4 opts) -> w0 status
FUNC pq_load_text
    mov  x5, x4
    mov  x4, x3
    mov  x3, x2
    ADR_L x2, j_data
    b    load_common
ENDF pq_load_text

// table_request(x0 db, x1 op fragment, x2 table, x3 path or 0, w4 replace)
// -> w0 status: save / open / drop
//   x19 db, x20 table, x21 path, w22 replace; sp: Buf
LFUNC table_request
    ENTER 3
    sub  sp, sp, #BUF_SIZE
    stp  xzr, xzr, [sp]
    stp  xzr, xzr, [sp, #16]
    mov  x19, x0
    mov  x20, x2
    mov  x21, x3
    mov  w22, w4
    cbz  x19, .Ltr_null
    cbz  x20, .Ltr_null
    mov  x0, sp
    bl   buf_puts
    mov  x0, sp
    mov  x1, x20
    bl   jput
    cbz  x21, 1f
    mov  x0, sp
    ADR_L x1, j_path
    bl   buf_puts
    mov  x0, sp
    mov  x1, x21
    bl   jput
1:  cbz  w22, 2f
    mov  x0, sp
    ADR_L x1, j_replace
    bl   buf_puts
2:  mov  x0, sp
    mov  w1, #'}'
    bl   buf_putc
    mov  x0, x19
    mov  x1, sp
    mov  x2, #0
    mov  x3, #0
    bl   run_request
    b    9f
.Ltr_null:
    mov  x0, x19
    mov  w1, #ERR_INVALID_REQUEST
    ADR_L x2, s_nullarg
    bl   api_arg_error
9:  add  sp, sp, #BUF_SIZE
    LEAVE 3
ENDF table_request

// pq_save(x0 db, x1 table, x2 path) -> w0
FUNC pq_save
    cbz  x2, 1f
    mov  x3, x2
    mov  x2, x1
    ADR_L x1, j_save
    mov  w4, #0
    b    table_request
1:  mov  x1, #0
    b    table_request
ENDF pq_save

// pq_open(x0 db, x1 table, x2 path, w3 replace) -> w0
FUNC pq_open
    cmp  w3, #0
    cset w4, ne
    cbz  x2, 1f
    mov  x3, x2
    mov  x2, x1
    ADR_L x1, j_open
    b    table_request
1:  mov  x1, #0
    b    table_request
ENDF pq_open

// pq_drop(x0 db, x1 table) -> w0
FUNC pq_drop
    mov  x2, x1
    ADR_L x1, j_drop
    mov  x3, #0
    mov  w4, #0
    b    table_request
ENDF pq_drop

// query_request(x0 Buf*, x1 sql, x2 opts or 0): the query request text
//   x19 Buf*, x20 opts
LFUNC query_request
    ENTER 2
    mov  x19, x0
    mov  x20, x2
    stp  x1, xzr, [sp, #-16]!
    ADR_L x1, j_query
    bl   buf_puts
    ldp  x1, xzr, [sp], #16
    mov  x0, x19
    bl   jput
    mov  x0, x19
    ADR_L x1, j_qopts
    bl   buf_puts
    cbz  x20, 9f
    ldr  x9, [x20, #0]
    cbz  x9, 1f
    mov  x0, x19
    ADR_L x1, j_threads
    bl   buf_puts
    mov  x0, x19
    ldr  x1, [x20, #0]
    bl   buf_put_u64
1:  ldr  x9, [x20, #8]
    cbz  x9, 2f
    mov  x0, x19
    ADR_L x1, j_timeout
    bl   buf_puts
    mov  x0, x19
    ldr  x1, [x20, #8]
    bl   buf_put_u64
2:  ldr  x9, [x20, #16]
    cbz  x9, 3f
    mov  x0, x19
    ADR_L x1, j_maxrows
    bl   buf_puts
    mov  x0, x19
    ldr  x1, [x20, #16]
    bl   buf_put_u64
3:  ldr  w9, [x20, #24]
    cbz  w9, 9f
    mov  x0, x19
    ADR_L x1, j_mode
    bl   buf_puts
    ldr  w9, [x20, #24]
    ADR_L x1, m_row
    cmp  w9, #1
    b.eq 4f
    ADR_L x1, m_vec
    cmp  w9, #2
    b.eq 4f
    ADR_L x1, m_bad
4:  mov  x0, x19
    bl   buf_puts
9:  mov  x0, x19
    ADR_L x1, s_close2
    bl   buf_puts
    LEAVE 2
ENDF query_request

    .section .rodata
s_close2:   .asciz "}}"
    .text

// pq_query(x0 db, x1 sql, x2 opts, x3 pq_result** out) -> w0 status
//   x19 db, x20 out; sp: Buf, RJ
FUNC pq_query
    ENTER 2
    sub  sp, sp, #BUF_SIZE + RJ_SIZE
    mov  x19, x0
    mov  x20, x3
    cbz  x19, 8f
    cbz  x1, 8f
    cbz  x20, 8f
    str  xzr, [x20]
    stp  xzr, xzr, [sp]
    stp  xzr, xzr, [sp, #16]
    mov  x0, sp
    bl   query_request
    add  x3, sp, #BUF_SIZE
    stp  xzr, xzr, [x3, #RJ_OUT]
    stp  xzr, xzr, [x3, #RJ_REPLACE]
    mov  x0, x19
    mov  x1, sp
    ADR_L x2, api_sink_result
    bl   run_request
    add  x3, sp, #BUF_SIZE
    ldr  x9, [x3, #RJ_OUT]
    str  x9, [x20]
    b    9f
8:  mov  x0, x19
    mov  w1, #ERR_INVALID_REQUEST
    ADR_L x2, s_nullarg
    bl   api_arg_error
9:  add  sp, sp, #BUF_SIZE + RJ_SIZE
    LEAVE 2
ENDF pq_query

// pq_query_into(x0 db, x1 table, x2 sql, x3 opts, w4 replace) -> w0 status
//   x19 db, x20 table, w21 replace; sp: Buf, RJ
FUNC pq_query_into
    ENTER 3
    sub  sp, sp, #BUF_SIZE + RJ_SIZE
    mov  x19, x0
    mov  x20, x1
    mov  w21, w4
    cbz  x19, 8f
    cbz  x20, 8f
    cbz  x2, 8f
    stp  xzr, xzr, [sp]
    stp  xzr, xzr, [sp, #16]
    mov  x1, x2
    mov  x2, x3
    mov  x0, sp
    bl   query_request
    add  x3, sp, #BUF_SIZE
    stp  xzr, x20, [x3, #RJ_OUT]    // RJ_OUT = 0, RJ_NAME = table
    cmp  w21, #0
    cset x9, ne
    stp  x9, xzr, [x3, #RJ_REPLACE]
    mov  x0, x19
    mov  x1, sp
    mov  x2, #0                     // job_query_into installs its sink
    bl   run_request
    b    9f
8:  mov  x0, x19
    mov  w1, #ERR_INVALID_REQUEST
    ADR_L x2, s_nullarg
    bl   api_arg_error
9:  add  sp, sp, #BUF_SIZE + RJ_SIZE
    LEAVE 3
ENDF pq_query_into

// ---------------------------------------------------------- tables / schema --

// cmp_names(x0 Table**, x1 Table**) -> w0: qsort comparator (names, ASCII
// case-insensitive)
LFUNC cmp_names
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
ENDF cmp_names

// two_col_result(x0 name0 cstr, w1 type0, x2 name1 cstr, w3 type1, x4 rows)
// -> x0 OutCol* [2], x1 ResultSet* with rows x 2 cells (cells zeroed;
// RS_ROWS[i] points to row i's 32 bytes). Request arena.
//   x19..x23 arguments, x24 OutCol*
LFUNC two_col_result
    ENTER 4
    mov  x19, x0
    mov  w20, w1
    mov  x21, x2
    mov  w22, w3
    mov  x23, x4
    mov  x0, #2 * OC_SIZE
    bl   arena_zalloc
    mov  x24, x0
    str  w20, [x24, #OC_TYPE]
    str  w22, [x24, #OC_SIZE + OC_TYPE]
    mov  x0, x19
    bl   strlen
    mov  x1, x0
    mov  x0, x19
    bl   str_new
    str  x0, [x24, #OC_NAME]
    mov  x0, x21
    bl   strlen
    mov  x1, x0
    mov  x0, x21
    bl   str_new
    str  x0, [x24, #OC_SIZE + OC_NAME]
    mov  x0, #RS_SIZE
    bl   arena_zalloc
    mov  x19, x0
    mov  x9, #2
    str  x9, [x19, #RS_WIDTH]
    str  x23, [x19, #RS_NROWS]
    lsl  x0, x23, #5
    add  x0, x0, #8
    bl   arena_zalloc
    mov  x20, x0
    lsl  x0, x23, #3
    add  x0, x0, #8
    bl   arena_alloc
    str  x0, [x19, #RS_ROWS]
    mov  x9, #0
1:  cmp  x9, x23
    b.hs 2f
    add  x10, x20, x9, lsl #5
    str  x10, [x0, x9, lsl #3]
    add  x9, x9, #1
    b    1b
2:  mov  x0, x24
    mov  x1, x19
    LEAVE 4
ENDF two_col_result

// tables_build(x0 pq_result** out): name, row_count of every table (guarded)
//   x19 out, x20 Table**, x21 count, x22 RS, x23 i
LFUNC tables_build
    ENTER 4
    mov  x19, x0
    bl   catalog_snapshot
    mov  x20, x0
    mov  x21, x1
    mov  x2, #8
    ADR_L x3, cmp_names
    bl   qsort
    ADR_L x0, s_name
    mov  w1, #T_STR
    ADR_L x2, s_rowcount
    mov  w3, #T_INT
    mov  x4, x21
    bl   two_col_result
    mov  x24, x0
    mov  x22, x1
    mov  x23, #0
1:  cmp  x23, x21
    b.hs 2f
    ldr  x9, [x22, #RS_ROWS]
    ldr  x9, [x9, x23, lsl #3]
    ldr  x10, [x20, x23, lsl #3]
    ldr  x11, [x10, #TBL_NAME]
    str  x11, [x9]
    ldr  x11, [x10, #TBL_NROWS]
    str  x11, [x9, #16]
    add  x23, x23, #1
    b    1b
2:  mov  x0, x24
    mov  x1, #2
    mov  x2, x22
    bl   api_build_result
    str  x0, [x19]
    LEAVE 4
ENDF tables_build

// schema_build(x0 [name cstr, pq_result** out]): name, type of every column
//   x19 arg, x20 Table*, x21 RS, x22 i, x23 OutCol*; sp: Buf
LFUNC schema_build
    ENTER 4
    sub  sp, sp, #BUF_SIZE
    mov  x19, x0
    ldr  x21, [x19]
    mov  x0, x21
    bl   strlen
    mov  x22, x0
    mov  x1, x0
    mov  x0, x21
    bl   catalog_find
    mov  x20, x0
    cbnz x0, 1f
    mov  w0, #ERR_NOT_FOUND
    ADR_L x1, m_notable
    mov  x2, x21
    mov  x3, x22
    bl   pq_raise_s
1:  ADR_L x0, s_name
    mov  w1, #T_STR
    ADR_L x2, s_type
    mov  w3, #T_STR
    ldr  x4, [x20, #TBL_NCOLS]
    bl   two_col_result
    mov  x23, x0
    mov  x21, x1
    mov  x22, #0
2:  ldr  x9, [x20, #TBL_NCOLS]
    cmp  x22, x9
    b.hs 3f
    ldr  x9, [x20, #TBL_COLS]
    add  x9, x9, x22, lsl #5
    ldr  x10, [x21, #RS_ROWS]
    ldr  x10, [x10, x22, lsl #3]
    ldr  x11, [x9, #COL_NAME]
    str  x11, [x10]
    stp  xzr, xzr, [sp]
    stp  xzr, xzr, [sp, #16]
    mov  x0, sp
    ldr  w1, [x9, #COL_TYPE]
    bl   type_write
    ldr  x0, [sp, #BUF_PTR]
    ldr  x1, [sp, #BUF_LEN]
    bl   str_new
    ldr  x10, [x21, #RS_ROWS]
    ldr  x10, [x10, x22, lsl #3]
    str  x0, [x10, #16]
    ldr  x0, [sp, #BUF_PTR]
    bl   free
    add  x22, x22, #1
    b    2b
3:  mov  x0, x23
    mov  x1, #2
    mov  x2, x21
    bl   api_build_result
    ldr  x9, [x19, #8]
    str  x0, [x9]
    add  sp, sp, #BUF_SIZE
    LEAVE 4
ENDF schema_build

// job_guarded(x0 [fn, access, arg...]) -> w0: api_guard(fn, arg + 16, access)
LFUNC job_guarded
    ldr  x9, [x0]
    ldr  w2, [x0, #8]
    add  x1, x0, #16
    mov  x0, x9
    b    api_guard
ENDF job_guarded

// pq_tables(x0 db, x1 pq_result** out) -> w0 status
FUNC pq_tables
    ENTER 1
    sub  sp, sp, #32
    mov  x19, x1
    cbz  x0, 8f
    cbz  x19, 8f
    str  xzr, [x19]
    ADR_L x9, tables_build
    mov  x10, #GA_READ
    stp  x9, x10, [sp]
    str  x19, [sp, #16]             // arg = the out pointer itself
    ADR_L x1, job_tables
    mov  x2, sp
    bl   api_call
    b    9f
8:  mov  w1, #ERR_INVALID_REQUEST
    ADR_L x2, s_nullarg
    bl   api_arg_error
9:  add  sp, sp, #32
    LEAVE 1
ENDF pq_tables

// job_tables(x0 [fn, access, out]) -> w0
LFUNC job_tables
    ldr  x9, [x0]
    ldr  w2, [x0, #8]
    ldr  x1, [x0, #16]
    mov  x0, x9
    b    api_guard
ENDF job_tables

// pq_schema(x0 db, x1 table, x2 pq_result** out) -> w0 status
FUNC pq_schema
    ENTER 1
    sub  sp, sp, #32
    cbz  x0, 8f
    cbz  x1, 8f
    cbz  x2, 8f
    str  xzr, [x2]
    ADR_L x9, schema_build
    mov  x10, #GA_READ
    stp  x9, x10, [sp]
    stp  x1, x2, [sp, #16]          // arg: name, out
    ADR_L x1, job_guarded
    mov  x2, sp
    bl   api_call
    b    9f
8:  mov  w1, #ERR_INVALID_REQUEST
    ADR_L x2, s_nullarg
    bl   api_arg_error
9:  add  sp, sp, #32
    LEAVE 1
ENDF pq_schema

// =============================================================================
// Results
// =============================================================================

// pq_result_free(x0 pq_result* or 0)
FUNC pq_result_free
    b    free
ENDF pq_result_free

// pq_value_at(x0 res, x1 row, x2 col) -> x0 pq_value* or 0 (out of range)
FUNC pq_value_at
    cbz  x0, 9f
    ldp  x9, x10, [x0, #R_NCOLS]
    cmp  x2, x9
    b.hs 8f
    cmp  x1, x10
    b.hs 8f
    madd x1, x1, x9, x2
    mov  x11, #V_SIZE
    ldr  x0, [x0, #R_VALUES]
    madd x0, x1, x11, x0
    ret
8:  mov  x0, #0
9:  ret
ENDF pq_value_at

// pq_format_value(x0 const pq_column*, x1 const pq_value*, w2 flags,
//                 x3 buf, x4 cap) -> x0 text length (like snprintf: at most
//                 cap-1 bytes and a NUL are written)
// Text: types.md §9 without quotes; FLOAT64 shortest round-trip, or with
// PQ_FMT_FLOAT_FIXED6 printf("%.6f") with -0.000000 printed as 0.000000;
// NULL => "".
//   x19 dst, x20 cap, x21 value, x22 column, w23 flags, x24 length;
//   [sp] Buf, [sp+32] 512-byte scratch
FUNC pq_format_value
    ENTER 4
    sub  sp, sp, #544
    mov  x19, x3
    mov  x20, x4
    mov  x21, x1
    mov  x22, x0
    mov  w23, w2
    stp  xzr, xzr, [sp]
    stp  xzr, xzr, [sp, #16]
    mov  x2, #0
    mov  x3, #0
    ldr  w9, [x21, #V_NULL]
    cbnz w9, .Lfv_copy
    ldr  w9, [x21, #V_TYPE]
    cmp  w9, #T_STR
    b.ne 1f
    ldp  x2, x3, [x21]
    b    .Lfv_copy
1:  cmp  w9, #T_BOOL
    b.ne 2f
    ldr  x9, [x21]
    ADR_L x2, s_false
    mov  x3, #5
    cbz  x9, .Lfv_copy
    ADR_L x2, s_true
    mov  x3, #4
    b    .Lfv_copy
2:  cmp  w9, #T_INT
    b.ne 3f
    mov  x0, sp
    ldr  x1, [x21]
    bl   buf_put_i64
    b    .Lfv_buf
3:  cmp  w9, #T_DEC
    b.ne 4f
    mov  x0, sp
    ldp  x1, x2, [x21]
    ldr  w3, [x22, #C_SCALE]
    bl   fmt_dec128
    b    .Lfv_buf
4:  cmp  w9, #T_FLOAT
    b.ne 6f
    ldr  d0, [x21]
    tbnz w23, #0, 5f
    mov  x0, sp
    bl   buf_put_f64
    b    .Lfv_buf
5:  add  x0, sp, #32
    mov  x1, #512
    ADR_L x2, s_f6
    bl   snprintf
    sxtw x24, w0
    cmp  x24, #511
    mov  x9, #511
    csel x24, x24, x9, lo
    add  x0, sp, #32
    ADR_L x1, s_mzero
    bl   strcmp
    add  x2, sp, #32
    mov  x3, x24
    cbnz w0, .Lfv_copy
    add  x2, x2, #1                 // -0.000000 => 0.000000
    sub  x3, x3, #1
    b    .Lfv_copy
6:  cmp  w9, #T_DATE
    b.ne 7f
    mov  x0, sp
    ldr  x1, [x21]
    bl   fmt_date
    b    .Lfv_buf
7:  cmp  w9, #T_TS
    b.ne .Lfv_copy
    mov  x0, sp
    ldr  x1, [x21]
    bl   fmt_timestamp
.Lfv_buf:
    ldr  x2, [sp, #BUF_PTR]
    ldr  x3, [sp, #BUF_LEN]
.Lfv_copy:                          // x2 text, x3 length
    mov  x24, x3
    cbz  x20, 8f
    sub  x9, x20, #1
    cmp  x3, x9
    csel x9, x3, x9, lo
    strb wzr, [x19, x9]
    mov  x0, x19
    mov  x1, x2
    mov  x2, x9
    bl   memcpy
8:  ldr  x0, [sp, #BUF_PTR]
    bl   free
    mov  x0, x24
    add  sp, sp, #544
    LEAVE 4
ENDF pq_format_value

    NOTE_GNU_STACK
