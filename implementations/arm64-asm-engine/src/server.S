// =============================================================================
// server.S — query admission, registry, cancellation and metrics for `serve`
// (concurrency.md §2-§5, protocol.md §7.3).
//
// Every query of the server (POST /v1/query, /v1/query/stream, or op
// "query" through /v1/request) is registered in a list of QRec records in
// arrival order, with its query id, state (queued / running), arrival time
// and a cancellation flag:
//   * admission (srv_query_begin, called by op_query): at most
//     g_srv_workers queries run; up to g_srv_queue_depth more wait FIFO on a
//     condition variable; any further query fails with OVERLOADED at once.
//     A waiting query gives up with TIMEOUT when its deadline (counted from
//     its arrival) passes, or CANCELLED when cancelled.
//   * running queries poll their flag through check_deadline (rt.S):
//     g_cancel_flag points to QR_CANCEL of the thread's record.
//   * srv_query_end (called by handle_request for every request) releases
//     the slot, updates the metrics and logs the completion event.
//   * a watchdog thread cancels queries whose client disconnected (poll
//     POLLRDHUP on the connection socket).
// All shared state is guarded by g_srv_lock. Outside server mode
// (g_srv_mode = 0) srv_query_begin / srv_query_end do nothing.
//
//   srv_init()                              (serve_main) start time, watchdog
//   srv_query_begin(x0 query_id Str* or 0)  raises SHUTTING_DOWN /
//                                           ALREADY_EXISTS / OVERLOADED /
//                                           TIMEOUT / CANCELLED
//   srv_query_end(w0 error code)
//   srv_cancel(x0 ptr, x1 len) -> w0 1 if a query was found and flagged
//   srv_cancel_all()
//   srv_write_queries(x0 Buf*)              [{"query_id":…,"state":…,…},…]
//   srv_write_metrics(x0 Buf*)              Prometheus text format 0.0.4
// =============================================================================
#include "pq.inc"
#include "frame.inc"

// Query record (malloc)
#define QR_NEXT     0       // QRec* (arrival order)
#define QR_PREV     8
#define QR_ID       16      // Str* (malloc'ed, owned by the request: g_qid)
#define QR_STATE    24      // u32 QS_*
#define QR_CANCEL   28      // u32 1 = cancellation requested
#define QR_START    32      // µs (CLOCK_MONOTONIC) arrival
#define QR_FD       40      // s64 connection socket or -1
#define QR_SIZE     48
#define QS_QUEUED   0
#define QS_RUNNING  1

#define POLLRDHUP   0x2000
#define POLLERR     0x8
#define POLLHUP     0x10

// ------------------------------------------------------------------ data -----
    .data
    .p2align 3
    .global g_srv_workers, g_srv_queue_depth, g_srv_timeout_ms
    .global g_srv_grace_ms, g_srv_max_request, g_srv_port, g_srv_host
g_srv_workers:      .quad 0             // 0 = CPU count (srv_init)
g_srv_queue_depth:  .quad 64
g_srv_timeout_ms:   .quad 0
g_srv_grace_ms:     .quad 10000
g_srv_max_request:  .quad 1024*1024*1024
g_srv_port:         .quad -1            // required for serve
g_srv_host:         .quad s_localhost

    .bss
    .p2align 4
    .global g_srv_mode, g_srv_shutdown
g_srv_lock:     .skip 64        // pthread_mutex_t
g_srv_cond:     .skip 64        // pthread_cond_t: slot freed / query cancelled
g_srv_mode:     .skip 8         // 1 while serving
g_srv_shutdown: .skip 8         // 1 once SIGTERM/SIGINT arrived
g_q_head:       .skip 8         // QRec list (arrival order)
g_q_tail:       .skip 8
g_n_running:    .skip 8
g_n_queued:     .skip 8
g_q_seq:        .skip 8         // server-assigned id counter
g_m_ok:         .skip 8         // metrics
g_m_err:        .skip 8
g_m_rejected:   .skip 8
g_m_cancelled:  .skip 8
g_m_timeout:    .skip 8
g_m_dur_us:     .skip 8
g_m_dur_n:      .skip 8
g_start_us:     .skip 8
g_watchdog:     .skip 8         // pthread_t

    TBSS
    .p2align 3
    .global g_qid, g_result_rows, g_conn_fd
g_qrec:         .skip 8         // QRec* of this thread's admitted query
g_qid:          .skip 8         // Str* (malloc) id of the last query of this
                                // thread's request (freed by the transport)
g_result_rows:  .skip 8         // rows of the last query result (logs)
g_conn_fd:      .skip 8         // connection socket + 1 (0 = none)

    .section .rodata
s_localhost:    .asciz "127.0.0.1"
f_qid:          .asciz "q-%lu"
m_shutdown:     .asciz "server is shutting down"
m_dupid:        .asciz "query id already in use "
m_overloaded:   .asciz "all workers busy and the queue is full"
m_qtimeout:     .asciz "query timeout exceeded while queued"
m_qcancel:      .asciz "query cancelled"
l_done:         .asciz "query finished"
k_query_id:     .asciz "query_id"
k_status:       .asciz "status"
k_code:         .asciz "code"
k_duration:     .asciz "duration_ms"
k_rows:         .asciz "rows"
v_ok:           .asciz "ok"
v_error:        .asciz "error"
j_qid:          .asciz "{\"query_id\":"
j_state_q:      .asciz ",\"state\":\"queued\",\"elapsed_ms\":"
j_state_r:      .asciz ",\"state\":\"running\",\"elapsed_ms\":"
// metrics text
mt_total:       .asciz "# HELP polyquery_queries_total Finished queries by status.\n# TYPE polyquery_queries_total counter\npolyquery_queries_total{status=\"ok\"} "
mt_total_err:   .asciz "\npolyquery_queries_total{status=\"error\"} "
mt_inflight:    .asciz "\n# HELP polyquery_queries_in_flight Queries executing now.\n# TYPE polyquery_queries_in_flight gauge\npolyquery_queries_in_flight "
mt_queued:      .asciz "\n# HELP polyquery_queries_queued Queries waiting for a worker.\n# TYPE polyquery_queries_queued gauge\npolyquery_queries_queued "
mt_rejected:    .asciz "\n# HELP polyquery_queries_rejected_total Queries rejected with OVERLOADED.\n# TYPE polyquery_queries_rejected_total counter\npolyquery_queries_rejected_total "
mt_cancelled:   .asciz "\n# HELP polyquery_queries_cancelled_total Cancelled queries.\n# TYPE polyquery_queries_cancelled_total counter\npolyquery_queries_cancelled_total "
mt_timeout:     .asciz "\n# HELP polyquery_queries_timeout_total Queries that timed out.\n# TYPE polyquery_queries_timeout_total counter\npolyquery_queries_timeout_total "
mt_dur_sum:     .asciz "\n# HELP polyquery_query_duration_seconds Query duration.\n# TYPE polyquery_query_duration_seconds summary\npolyquery_query_duration_seconds_sum "
mt_dur_count:   .asciz "\npolyquery_query_duration_seconds_count "
mt_tables:      .asciz "\n# HELP polyquery_tables Tables in the catalog.\n# TYPE polyquery_tables gauge\npolyquery_tables "
mt_uptime:      .asciz "\n# HELP polyquery_uptime_seconds Seconds since the server started.\n# TYPE polyquery_uptime_seconds gauge\npolyquery_uptime_seconds "
f_secs:         .asciz "%lu.%06lu"
    .text

// srv_lock() / srv_unlock()
LFUNC srv_lock
    ADR_L x0, g_srv_lock
    b    pthread_mutex_lock
ENDF srv_lock

LFUNC srv_unlock
    ADR_L x0, g_srv_lock
    b    pthread_mutex_unlock
ENDF srv_unlock

// srv_init(): record the start time, resolve the default worker count and
// start the disconnect watchdog. Called once before serving.
FUNC srv_init
    ENTER 0
    bl   now_us
    ADR_L x1, g_start_us
    str  x0, [x1]
    LDR_G x0, g_srv_workers
    cbnz x0, 1f
    bl   get_nprocs
    sxtw x0, w0
    cmp  x0, #1
    mov  x1, #1
    csel x0, x0, x1, ge
    ADR_L x1, g_srv_workers
    str  x0, [x1]
1:  mov  x9, #1
    ADR_L x10, g_srv_mode
    str  x9, [x10]
    ADR_L x0, g_watchdog
    mov  x1, #0
    ADR_L x2, watchdog_main
    mov  x3, #0
    bl   pthread_create
    LEAVE 0
ENDF srv_init

// str_dup_malloc(x0 ptr, x1 len) -> x0 Str* (malloc)
//   x19 ptr, x20 len
LFUNC str_dup_malloc
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    add  x0, x1, #(STR_DATA + 1)
    bl   malloc
    cbnz x0, 1f
    bl   abort
1:  str  x20, [x0, #STR_LEN]
    add  x9, x0, #STR_DATA              // NUL terminator
    strb wzr, [x9, x20]
    mov  x20, x0
    mov  x1, x19
    ldr  x2, [x20, #STR_LEN]
    add  x0, x20, #STR_DATA
    bl   memcpy
    mov  x0, x20
    LEAVE 2
ENDF str_dup_malloc

// find_query(x0 ptr, x1 len) -> x0 QRec* or 0 (lock held)
//   x19 ptr, x20 len, x21 rec
LFUNC find_query
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    LDR_G x21, g_q_head
1:  cbz  x21, 9f
    ldr  x9, [x21, #QR_ID]
    ldr  x10, [x9, #STR_LEN]
    cmp  x10, x20
    b.ne 2f
    add  x0, x9, #STR_DATA
    mov  x1, x19
    mov  x2, x20
    bl   memcmp
    cbz  w0, 9f
2:  ldr  x21, [x21, #QR_NEXT]
    b    1b
9:  mov  x0, x21
    LEAVE 3
ENDF find_query

// first_queued() -> x0 the oldest queued QRec or 0 (lock held)   (leaf)
LFUNC first_queued
    LDR_G x0, g_q_head
1:  cbz  x0, 9f
    ldr  w9, [x0, #QR_STATE]
    cmp  w9, #QS_QUEUED
    b.eq 9f
    ldr  x0, [x0, #QR_NEXT]
    b    1b
9:  ret
ENDF first_queued

// srv_query_begin(x0 query_id Str* or 0): admission control (see header).
//   x19 id Str* (malloc copy), x20 rec, x21 scratch; locals [sp] timespec,
//   [sp+16] id text
FUNC srv_query_begin
    ENTER 3
    sub  sp, sp, #48
    LDR_G x9, g_srv_mode
    cbz  x9, .Lqb_ret
    TLS_ADDR x9, g_result_rows
    str  xzr, [x9]
    mov  x19, x0
    bl   srv_lock
    // the id: client supplied, or "q-<n>"
    cbz  x19, 1f
    add  x0, x19, #STR_DATA
    ldr  x1, [x19, #STR_LEN]
    bl   str_dup_malloc
    mov  x19, x0
    b    2f
1:  ADR_L x9, g_q_seq
    ldr  x3, [x9]
    add  x3, x3, #1
    str  x3, [x9]
    add  x0, sp, #16
    mov  x1, #32
    ADR_L x2, f_qid
    bl   snprintf
    add  x0, sp, #16
    bl   strlen
    mov  x1, x0
    add  x0, sp, #16
    bl   str_dup_malloc
    mov  x19, x0
2:  TLS_ADDR x9, g_qid                  // the transport reports and frees it
    ldr  x0, [x9]
    str  x19, [x9]
    bl   free
    LDR_G x9, g_srv_shutdown
    cbz  x9, 3f
    bl   srv_unlock
    mov  w0, #ERR_SHUTTING_DOWN
    ADR_L x1, m_shutdown
    bl   pq_raise
3:  add  x0, x19, #STR_DATA
    ldr  x1, [x19, #STR_LEN]
    bl   find_query
    cbz  x0, 4f
    bl   srv_unlock
    mov  w0, #ERR_ALREADY_EXISTS
    ADR_L x1, m_dupid
    add  x2, x19, #STR_DATA
    ldr  x3, [x19, #STR_LEN]
    bl   pq_raise_s
4:  // slot: run now, queue, or reject
    mov  w21, #QS_RUNNING
    LDR_G x9, g_n_running
    LDR_G x10, g_srv_workers
    LDR_G x11, g_n_queued
    cmp  x9, x10
    b.hs 5f
    cbz  x11, 6f
5:  mov  w21, #QS_QUEUED
    LDR_G x10, g_srv_queue_depth
    cmp  x11, x10
    b.lo 6f
    ADR_L x9, g_m_rejected
    ldr  x10, [x9]
    add  x10, x10, #1
    str  x10, [x9]
    bl   srv_unlock
    mov  w0, #ERR_OVERLOADED
    ADR_L x1, m_overloaded
    bl   pq_raise
6:  ADR_L x9, g_n_running
    cmp  w21, #QS_RUNNING
    b.eq 61f
    ADR_L x9, g_n_queued
61: ldr  x10, [x9]
    add  x10, x10, #1
    str  x10, [x9]
    mov  x0, #1
    mov  x1, #QR_SIZE
    bl   calloc
    cbnz x0, 62f
    bl   abort
62: mov  x20, x0
    str  x19, [x20, #QR_ID]
    str  w21, [x20, #QR_STATE]
    TLS_LDR x9, g_req_start
    str  x9, [x20, #QR_START]
    TLS_LDR x9, g_conn_fd
    sub  x9, x9, #1
    str  x9, [x20, #QR_FD]
    LDR_G x9, g_q_tail                  // append (arrival order)
    str  x9, [x20, #QR_PREV]
    ADR_L x10, g_q_tail
    str  x20, [x10]
    ADR_L x10, g_q_head
    cbz  x9, 63f
    add  x10, x9, #QR_NEXT
63: str  x20, [x10]
    TLS_ADDR x9, g_qrec
    str  x20, [x9]
    TLS_ADDR x9, g_cancel_flag
    add  x10, x20, #QR_CANCEL
    str  x10, [x9]
    cmp  w21, #QS_RUNNING
    b.eq .Lqb_unlock
    // queued: wait (FIFO) for a free worker
.Lqb_wait:
    ldr  w9, [x20, #QR_CANCEL]
    cbz  w9, 7f
    bl   srv_unlock
    mov  w0, #ERR_CANCELLED
    ADR_L x1, m_qcancel
    bl   pq_raise
7:  TLS_LDR x21, g_deadline
    cbz  x21, 71f
    bl   now_us
    cmp  x0, x21
    b.lo 71f
    bl   srv_unlock
    mov  w0, #ERR_TIMEOUT
    ADR_L x1, m_qtimeout
    bl   pq_raise
71: LDR_G x9, g_n_running
    LDR_G x10, g_srv_workers
    cmp  x9, x10
    b.hs 72f
    bl   first_queued
    cmp  x0, x20
    b.ne 72f
    mov  w9, #QS_RUNNING                // our turn
    str  w9, [x20, #QR_STATE]
    ADR_L x9, g_n_queued
    ldr  x10, [x9]
    sub  x10, x10, #1
    str  x10, [x9]
    ADR_L x9, g_n_running
    ldr  x10, [x9]
    add  x10, x10, #1
    str  x10, [x9]
    b    .Lqb_unlock
72: mov  w0, #0                         // wait at most 10 ms, then re-check
    mov  x1, sp
    bl   clock_gettime
    ldp  x9, x10, [sp]
    mov  x11, #0x9680
    movk x11, #0x98, lsl #16            // 10 000 000 ns
    add  x10, x10, x11
    mov  x11, #0xca00
    movk x11, #0x3b9a, lsl #16          // 1 000 000 000
    cmp  x10, x11
    b.lo 73f
    sub  x10, x10, x11
    add  x9, x9, #1
73: stp  x9, x10, [sp]
    ADR_L x0, g_srv_cond
    ADR_L x1, g_srv_lock
    mov  x2, sp
    bl   pthread_cond_timedwait
    b    .Lqb_wait
.Lqb_unlock:
    bl   srv_unlock
.Lqb_ret:
    add  sp, sp, #48
    LEAVE 3
ENDF srv_query_begin

// srv_query_end(w0 error code): end of a request; for an admitted query
// release its slot, count it and log the completion.
//   x19 rec, w20 code, x21 duration µs
FUNC srv_query_end
    ENTER 3
    mov  w20, w0
    TLS_LDR x19, g_qrec
    cbz  x19, 9f
    TLS_ADDR x9, g_qrec
    str  xzr, [x9]
    bl   now_us
    TLS_LDR x9, g_req_start
    sub  x21, x0, x9
    bl   srv_lock
    // unlink
    ldr  x9, [x19, #QR_PREV]
    ldr  x10, [x19, #QR_NEXT]
    ADR_L x11, g_q_head
    cbz  x9, 1f
    add  x11, x9, #QR_NEXT
1:  str  x10, [x11]
    ADR_L x11, g_q_tail
    cbz  x10, 2f
    add  x11, x10, #QR_PREV
2:  str  x9, [x11]
    ADR_L x9, g_n_queued
    ldr  w10, [x19, #QR_STATE]
    cmp  w10, #QS_RUNNING
    b.ne 3f
    ADR_L x9, g_n_running
3:  ldr  x10, [x9]
    sub  x10, x10, #1
    str  x10, [x9]
    // metrics
    ADR_L x9, g_m_ok
    cbz  w20, 4f
    ADR_L x9, g_m_err
4:  ldr  x10, [x9]
    add  x10, x10, #1
    str  x10, [x9]
    cmp  w20, #ERR_CANCELLED
    b.ne 5f
    ADR_L x9, g_m_cancelled
    ldr  x10, [x9]
    add  x10, x10, #1
    str  x10, [x9]
5:  cmp  w20, #ERR_TIMEOUT
    b.ne 6f
    ADR_L x9, g_m_timeout
    ldr  x10, [x9]
    add  x10, x10, #1
    str  x10, [x9]
6:  ADR_L x9, g_m_dur_us
    ldr  x10, [x9]
    add  x10, x10, x21
    str  x10, [x9]
    ADR_L x9, g_m_dur_n
    ldr  x10, [x9]
    add  x10, x10, #1
    str  x10, [x9]
    ADR_L x0, g_srv_cond                // a slot is free
    bl   pthread_cond_broadcast
    bl   srv_unlock
    // completion event
    mov  w0, #LOG_INFO
    ADR_L x1, l_done
    bl   log_begin
    cbz  w0, 8f
    ldr  x9, [x19, #QR_ID]
    ADR_L x0, k_query_id
    add  x1, x9, #STR_DATA
    ldr  x2, [x9, #STR_LEN]
    bl   log_str
    ADR_L x1, v_ok
    mov  x2, #2
    cbz  w20, 7f
    ADR_L x1, v_error
    mov  x2, #5
7:  ADR_L x0, k_status
    bl   log_str
    cbz  w20, 71f
    mov  w0, w20
    bl   err_code_name
    mov  x22, x0
    bl   strlen
    mov  x2, x0
    mov  x1, x22
    ADR_L x0, k_code
    bl   log_str
71: ADR_L x0, k_duration
    mov  x1, #1000
    udiv x1, x21, x1
    bl   log_int
    ADR_L x0, k_rows
    TLS_LDR x1, g_result_rows
    cbz  w20, 72f
    mov  x1, #0
72: bl   log_int
    bl   log_end
8:  mov  x0, x19
    bl   free
9:  LEAVE 3
ENDF srv_query_end

// srv_cancel(x0 ptr, x1 len) -> w0 1 if found (and flagged), else 0
FUNC srv_cancel
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    bl   srv_lock
    mov  x0, x19
    mov  x1, x20
    bl   find_query
    mov  x19, x0
    cbz  x0, 1f
    add  x9, x0, #QR_CANCEL
    mov  w10, #1
    stlr w10, [x9]
    ADR_L x0, g_srv_cond
    bl   pthread_cond_broadcast
1:  bl   srv_unlock
    cmp  x19, #0
    cset w0, ne
    LEAVE 2
ENDF srv_cancel

// srv_cancel_all(): flag every registered query (end of the shutdown grace)
FUNC srv_cancel_all
    ENTER 1
    bl   srv_lock
    LDR_G x19, g_q_head
1:  cbz  x19, 2f
    add  x9, x19, #QR_CANCEL
    mov  w10, #1
    stlr w10, [x9]
    ldr  x19, [x19, #QR_NEXT]
    b    1b
2:  ADR_L x0, g_srv_cond
    bl   pthread_cond_broadcast
    bl   srv_unlock
    LEAVE 1
ENDF srv_cancel_all

// srv_write_queries(x0 Buf*): JSON array of the registered queries
//   x19 buf, x20 rec, x21 now, x22 first
FUNC srv_write_queries
    ENTER 3
    mov  x19, x0
    bl   now_us
    mov  x21, x0
    bl   srv_lock
    mov  x0, x19
    mov  w1, #'['
    bl   buf_putc
    LDR_G x20, g_q_head
    mov  x22, #1
1:  cbz  x20, 3f
    cbnz x22, 2f
    mov  x0, x19
    mov  w1, #','
    bl   buf_putc
2:  mov  x22, #0
    mov  x0, x19
    ADR_L x1, j_qid
    bl   buf_puts
    ldr  x9, [x20, #QR_ID]
    mov  x0, x19
    add  x1, x9, #STR_DATA
    ldr  x2, [x9, #STR_LEN]
    bl   buf_put_jstr
    ldr  w9, [x20, #QR_STATE]
    ADR_L x1, j_state_q
    cmp  w9, #QS_RUNNING
    b.ne 21f
    ADR_L x1, j_state_r
21: mov  x0, x19
    bl   buf_puts
    ldr  x9, [x20, #QR_START]
    sub  x1, x21, x9
    mov  x9, #1000
    sdiv x1, x1, x9
    cmp  x1, #0
    csel x1, x1, xzr, ge
    mov  x0, x19
    bl   buf_put_i64
    mov  x0, x19
    mov  w1, #'}'
    bl   buf_putc
    ldr  x20, [x20, #QR_NEXT]
    b    1b
3:  bl   srv_unlock
    mov  x0, x19
    mov  w1, #']'
    bl   buf_putc
    LEAVE 3
ENDF srv_write_queries

// put_seconds(x0 Buf*, x1 µs): decimal seconds with 6 fractional digits
//   x19 buf; locals: [sp] text
LFUNC put_seconds
    ENTER 1
    sub  sp, sp, #48
    mov  x19, x0
    mov  x9, #16960
    movk x9, #0xf, lsl #16              // 1 000 000
    udiv x3, x1, x9
    msub x4, x3, x9, x1
    mov  x0, sp
    mov  x1, #48
    ADR_L x2, f_secs
    bl   snprintf
    mov  x0, x19
    mov  x1, sp
    bl   buf_puts
    add  sp, sp, #48
    LEAVE 1
ENDF put_seconds

// METRIC_LINE text, offset: text, then the u64 counter at [sp+offset]
.macro METRIC_LINE text, off
    mov  x0, x19
    ADR_L x1, \text
    bl   buf_puts
    mov  x0, x19
    ldr  x1, [sp, #\off]
    bl   buf_put_u64
.endm

// srv_write_metrics(x0 Buf*): the Prometheus exposition
//   x19 buf; locals: [sp] snapshot of the counters (10 x u64)
FUNC srv_write_metrics
    ENTER 1
    sub  sp, sp, #96
    mov  x19, x0
    bl   srv_lock
    LDR_G x9, g_m_ok
    LDR_G x10, g_m_err
    stp  x9, x10, [sp]
    LDR_G x9, g_n_running
    LDR_G x10, g_n_queued
    stp  x9, x10, [sp, #16]
    LDR_G x9, g_m_rejected
    LDR_G x10, g_m_cancelled
    stp  x9, x10, [sp, #32]
    LDR_G x9, g_m_timeout
    LDR_G x10, g_m_dur_us
    stp  x9, x10, [sp, #48]
    LDR_G x9, g_m_dur_n
    str  x9, [sp, #64]
    bl   srv_unlock
    bl   catalog_count
    str  x0, [sp, #72]
    bl   now_us
    LDR_G x9, g_start_us
    sub  x0, x0, x9
    str  x0, [sp, #80]
    .irp pair, "mt_total,0", "mt_total_err,8", "mt_inflight,16", "mt_queued,24", "mt_rejected,32", "mt_cancelled,40", "mt_timeout,48"
    METRIC_LINE \pair
    .endr
    mov  x0, x19
    ADR_L x1, mt_dur_sum
    bl   buf_puts
    mov  x0, x19
    ldr  x1, [sp, #56]
    bl   put_seconds
    METRIC_LINE mt_dur_count, 64
    METRIC_LINE mt_tables, 72
    mov  x0, x19
    ADR_L x1, mt_uptime
    bl   buf_puts
    mov  x0, x19
    ldr  x1, [sp, #80]
    bl   put_seconds
    mov  x0, x19
    mov  w1, #'\n'
    bl   buf_putc
    add  sp, sp, #96
    LEAVE 1
ENDF srv_write_metrics


// watchdog_main(): every 20 ms, cancel queries whose client went away
// (the peer closed its end of the connection: POLLRDHUP / HUP / ERR).
//   x19 rec; locals: [sp] struct pollfd, [sp+16] timespec
LFUNC watchdog_main
    ENTER 1
    sub  sp, sp, #32
1:  str  xzr, [sp, #16]
    mov  x9, #0x2d00
    movk x9, #0x131, lsl #16            // 20 000 000 ns
    str  x9, [sp, #24]
    add  x0, sp, #16
    mov  x1, #0
    bl   nanosleep
    bl   srv_lock
    LDR_G x19, g_q_head
2:  cbz  x19, 4f
    ldr  x9, [x19, #QR_FD]
    tbnz x9, #63, 3f
    str  w9, [sp]                       // fd
    mov  w10, #POLLRDHUP
    strh w10, [sp, #4]                  // events
    strh wzr, [sp, #6]
    mov  x0, sp
    mov  x1, #1
    mov  w2, #0
    bl   poll
    cmp  w0, #1
    b.ne 3f
    ldrh w9, [sp, #6]
    mov  w10, #(POLLRDHUP | POLLHUP | POLLERR)
    tst  w9, w10
    b.eq 3f
    add  x9, x19, #QR_CANCEL
    mov  w10, #1
    stlr w10, [x9]
    ADR_L x0, g_srv_cond
    bl   pthread_cond_broadcast
3:  ldr  x19, [x19, #QR_NEXT]
    b    2b
4:  bl   srv_unlock
    b    1b
ENDF watchdog_main

    NOTE_GNU_STACK
