/*
 * server.S - `serve` mode (protocol.md §7, concurrency.md): the HTTP/1.1
 * server.
 *
 * Process model
 *   One single-threaded parent process owns the catalog and all sockets and
 *   runs a poll() event loop.  Catalog operations (load, drop, open, save,
 *   stats, schema, CREATE/DROP INDEX, ...) execute inline in the parent, so
 *   mutations are serialized and atomic.  Every query is admitted (worker
 *   limit, FIFO queue, OVERLOADED) and then executed in a fork()ed child:
 *   the child's copy-on-write address space is the query's snapshot of the
 *   catalog, so concurrent replace/drop never affects running queries, and
 *   readers never block each other.  The child writes the HTTP response
 *   directly to the client socket (blocking writes = streaming
 *   backpressure) and reports status / row count through a small shared
 *   memory record; the parent reaps it (SIGCHLD via signalfd) and resumes
 *   reading the keep-alive connection.
 *
 *   Timeouts: the absolute deadline (arrival + timeout) is enforced by the
 *   parent while queued and by the child's operators (check_deadline) while
 *   running.  Cancellation: SIGUSR1 -> g_cancel_flag -> CANCELLED at the
 *   next check; a client disconnect kills the child.  SIGTERM/SIGINT: stop
 *   accepting, drain within --shutdown-grace-ms, cancel the rest, exit 0.
 */
#include "pq.inc"
#include "http.inc"
#include "sql.inc"

    .section .note.GNU-stack, "", @progbits

#define MAX_CONN    1000
#define JOBQ_SIZE   1024            /* power of two > MAX_CONN */
#define WORKER_STACK (1024*1024*1024)
#define READ_CHUNK  262144
#define NS_PER_MS   1000000
#define KILL_AFTER  300000000       /* ns after a deadline / cancel before SIGKILL */
#define DRAIN_NS    2000000000      /* lingering close */

#define SIGINT_  2
#define SIGKILL_ 9
#define SIGUSR1_ 10
#define SIGTERM_ 15
#define SIGCHLD_ 17

#define LV_DEBUG 0
#define LV_INFO  1
#define LV_WARN  2
#define LV_ERROR 3
#define LV_OFF   4

    .data
    .p2align 3
    .globl g_srv_host, g_srv_port, g_srv_workers, g_srv_queue, g_srv_timeout_ms
    .globl g_srv_grace_ms, g_srv_max_req, g_log_level
g_srv_host:       .quad 0           /* C string; 0 = 127.0.0.1 */
g_srv_port:       .quad -1          /* -1 = not given */
g_srv_workers:    .quad 0           /* 0 = CPU count */
g_srv_queue:      .quad 64
g_srv_timeout_ms: .quad 0
g_srv_grace_ms:   .quad 10000
g_srv_max_req:    .quad 1073741824
g_log_level:      .quad LV_INFO

listen_fd:   .quad -1
sig_fd:      .quad -1
conns:       .quad 0                /* Conn[MAX_CONN] */
shm:         .quad 0                /* shared records, SH_SIZE per connection */
conn_hi:     .quad 0                /* slots in use are below this index */
pfds:        .quad 0                /* struct pollfd[MAX_CONN + 2] */
pmap:        .quad 0                /* Conn* per pollfd (0 = special) */
n_running:   .quad 0
n_queued:    .quad 0
q_seq:       .quad 0
id_seq:      .quad 0
shutting:    .quad 0
grace_dl:    .quad 0
grace_fired: .quad 0
start_ns:    .quad 0
child_conn:  .quad 0                /* child: its Conn* */
net_arena:   .quad 0                /* request arena of the network thread */
jobq:        .quad 0                /* ring of Conn* waiting for the catalog worker */
q_head:      .quad 0                /* (q_mutex) */
q_tail:      .quad 0
done_r:      .quad -1               /* pipe: Conn* of finished catalog jobs */
done_w:      .quad -1
n_inline:    .quad 0                /* catalog jobs queued or running */
n_starting:  .quad 0                /* admitted queries waiting to fork */
g_cat_threaded: .quad 0             /* catalog worker thread in use */
g_cat_locked:   .quad 0             /* worker: holds cat_lock */
stream_hdr:  .quad 0                /* child: stream header already sent */
ss_plan:     .quad 0                /* child: streamed plan and sink state */
ss_seen:     .quad 0
ss_emitted:  .quad 0
ss_batch:    .quad 0                /* rows in the batch being built in g_out */
ss_offset:   .quad 0
ss_limit:    .quad -1

/* metrics */
m_ok:        .quad 0
m_err:       .quad 0
m_rejected:  .quad 0
m_cancelled: .quad 0
m_timeout:   .quad 0
m_dur_ns:    .quad 0
m_dur_cnt:   .quad 0

    .bss
    .p2align 4
g_req:      .zero RQ_SIZE           /* request being routed */
srv_buf:    .zero BUF_SIZE          /* parent-built response bodies */
log_buf:    .zero BUF_SIZE
jb_stream:  .zero 512
ss_head:    .zero BUF_SIZE          /* child: the stream's header line */
    .p2align 6
cat_lock:   .zero 64                /* pthread_mutex_t: catalog consistency for fork() */
q_mutex:    .zero 64
q_cond:     .zero 64

    .section .rodata
ctype_json:   .asciz "application/json"
ctype_ndjson: .asciz "application/x-ndjson"
ctype_text:   .asciz "text/plain; version=0.0.4; charset=utf-8"
op_query_s:   .asciz "query"
lv_names:     .quad lv0, lv1, lv2, lv3
lv0: .asciz "debug"
lv1: .asciz "info"
lv2: .asciz "warn"
lv3: .asciz "error"

    .text

/* ================================================================ logging */

/* log_begin(level edi, msg rsi) -> eax 1 if the event is to be logged:
 * starts {"ts":..,"level":..,"msg":.. in log_buf */
FUNC log_begin
    ENTER 96
    mov %edi, %ebx
    mov %rsi, %r12
    xor %eax, %eax
    cmp g_log_level(%rip), %rbx
    jb 9f
    lea log_buf(%rip), %r15
    movq $0, BUF_LEN(%r15)
    PUTS %r15, "{\"ts\":\""
    xor %edi, %edi                  /* CLOCK_REALTIME */
    lea 0(%rsp), %rsi
    call clock_gettime
    lea 0(%rsp), %rdi
    lea 16(%rsp), %rsi              /* struct tm */
    call gmtime_r
    lea 72(%rsp), %rdi
    mov $24, %esi
    CSTR %rdx, "%Y-%m-%dT%H:%M:%S"
    lea 16(%rsp), %rcx
    call strftime
    mov %r15, %rdi
    lea 72(%rsp), %rsi
    call buf_puts
    mov 8(%rsp), %rax               /* milliseconds */
    xor %edx, %edx
    mov $NS_PER_MS, %ecx
    div %rcx
    lea 72(%rsp), %rdi
    mov $16, %esi
    CSTR %rdx, ".%03ldZ"
    mov %rax, %rcx
    xor %eax, %eax
    call snprintf
    mov %r15, %rdi
    lea 72(%rsp), %rsi
    call buf_puts
    PUTS %r15, "\",\"level\":\""
    lea lv_names(%rip), %rax
    mov (%rax, %rbx, 8), %rsi
    mov %r15, %rdi
    call buf_puts
    PUTS %r15, "\",\"msg\":"
    mov %r12, %rdi
    call strlen
    mov %r15, %rdi
    mov %r12, %rsi
    mov %rax, %rdx
    call buf_put_json_str
    mov $1, %eax
9:  LEAVE
ENDF log_begin

/* log_end(): closes the object and writes it to stderr as one line */
FUNC log_end
    push %rbx
    lea log_buf(%rip), %rbx
    mov %rbx, %rdi
    CSTR %rsi, "}\n"
    call buf_puts
    mov $2, %edi
    mov BUF_DATA(%rbx), %rsi
    mov BUF_LEN(%rbx), %rdx
    call write
    pop %rbx
    ret
ENDF log_end

/* log_simple(level edi, msg rsi) */
FUNC log_simple
    sub $8, %rsp
    call log_begin
    test %eax, %eax
    jz 1f
    call log_end
1:  add $8, %rsp
    ret
ENDF log_simple

/* ================================================================ helpers */

/* conn_sh(c rdi) -> rax shared record of the connection */
FUNC conn_sh
    mov %rdi, %rax
    sub conns(%rip), %rax
    xor %edx, %edx
    mov $CN_SIZE, %ecx
    div %rcx
    shl $5, %rax                    /* SH_SIZE = 32 */
    add shm(%rip), %rax
    ret
ENDF conn_sh

/* xstrdup_mem(ptr rdi, len rsi) -> rax malloc'd NUL-terminated copy */
FUNC xstrdup_mem
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    lea 1(%rsi), %rdi
    call xmalloc
    mov %rax, %r13
    mov %rax, %rdi
    mov %rbx, %rsi
    mov %r12, %rdx
    call memcpy
    movb $0, (%r13, %r12)
    mov %r13, %rax
    LEAVE
ENDF xstrdup_mem

/* respond(c rdi, status esi, ctype rdx, body rcx, len r8) */
FUNC respond
    ENTER 0
    mov %rdi, %rbx
    xor %r9d, %r9d
    cmpq $0, CN_CLOSE(%rbx)
    je 1f
    mov $HS_CLOSE, %r9d
1:  mov CN_FD(%rbx), %edi
    call http_send
    test %eax, %eax
    jz 2f
    movq $1, CN_CLOSE(%rbx)         /* peer gone: close after this request */
2:  LEAVE
ENDF respond

/* respond_buf(c rdi, status esi, Buf* rdx) - JSON body */
FUNC respond_buf
    sub $8, %rsp
    mov BUF_DATA(%rdx), %rcx
    mov BUF_LEN(%rdx), %r8
    lea ctype_json(%rip), %rdx
    call respond
    add $8, %rsp
    ret
ENDF respond_buf

/* respond_error(c rdi, code esi, msg rdx): {"id":..,"ok":false,"error":{..}}
 * with the query id header of the connection's pending query */
FUNC respond_error
    xor %ecx, %ecx
    jmp respond_error_st
ENDF respond_error

/* respond_error_st(c rdi, code esi, msg rdx, status ecx (0 = by code)) */
FUNC respond_error_st
    ENTER 0
    mov %rdi, %rbx
    mov %esi, %r12d
    mov %rdx, %r13
    mov %ecx, %r14d
    lea srv_buf(%rip), %r15
    movq $0, BUF_LEN(%r15)
    PUTS %r15, "{\"id\":"
    mov CN_QREQID(%rbx), %rsi
    test %rsi, %rsi
    jnz 1f
    CSTR %rsi, "null"
1:  mov %r15, %rdi
    call buf_puts
    PUTS %r15, ",\"ok\":false,\"error\":{\"code\":\""
    mov %r12d, %edi
    call proto_err_name
    mov %r15, %rdi
    mov %rax, %rsi
    call buf_puts
    PUTS %r15, "\",\"message\":"
    mov %r13, %rdi
    call strlen
    mov %r15, %rdi
    mov %r13, %rsi
    mov %rax, %rdx
    call buf_put_json_str
    PUTS %r15, "}}"
    mov CN_QID(%rbx), %rax
    mov %rax, g_resp_qid(%rip)
    mov %r14d, %eax
    test %eax, %eax
    jnz 2f
    mov %r12d, %edi
    call http_status_for
2:  mov %rbx, %rdi
    mov %eax, %esi
    mov %r15, %rdx
    call respond_buf
    movq $0, g_resp_qid(%rip)
    LEAVE
ENDF respond_error_st

/* respond_cstr(c rdi, status esi, json C string rdx) */
FUNC respond_cstr
    ENTER 0
    mov %rdi, %rbx
    mov %esi, %r12d
    mov %rdx, %r13
    mov %rdx, %rdi
    call strlen
    mov %rax, %r8
    mov %rbx, %rdi
    mov %r12d, %esi
    lea ctype_json(%rip), %rdx
    mov %r13, %rcx
    call respond
    LEAVE
ENDF respond_cstr

/* clear_query(c rdi): frees the pending query's / job's fields */
FUNC clear_query
    push %rbx
    mov %rdi, %rbx
    mov CN_QID(%rbx), %rdi
    call free
    mov CN_QBODY(%rbx), %rdi
    call free
    mov CN_QREQID(%rbx), %rdi
    call free
    mov CN_RESP(%rbx), %rdi
    call free
    mov CN_JREQ(%rbx), %rdi
    call free
    lea CN_QSTATE(%rbx), %rdi
    xor %esi, %esi
    mov $(CN_SIZE - CN_QSTATE), %edx
    call memset
    pop %rbx
    ret
ENDF clear_query

/* ================================================================ accounting */

/* account_code(qid rdi, start rsi, code rdx, rows rcx): metrics and the
 * query completion log event */
FUNC account_code
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rcx, %r14
    call now_ns
    sub %r12, %rax
    mov %rax, %r12                  /* duration ns */
    add %rax, m_dur_ns(%rip)
    incq m_dur_cnt(%rip)
    test %r13, %r13
    jnz 1f
    incq m_ok(%rip)
    jmp 3f
1:  incq m_err(%rip)
    cmp $E_TIMEOUT, %r13
    jne 2f
    incq m_timeout(%rip)
2:  cmp $E_CANCELLED, %r13
    jne 3f
    incq m_cancelled(%rip)
3:  mov $LV_INFO, %edi
    CSTR %rsi, "query finished"
    call log_begin
    test %eax, %eax
    jz 9f
    lea log_buf(%rip), %r15
    PUTS %r15, ",\"query_id\":"
    mov %rbx, %rdi
    call strlen
    mov %r15, %rdi
    mov %rbx, %rsi
    mov %rax, %rdx
    call buf_put_json_str
    PUTS %r15, ",\"status\":\""
    CSTR %rsi, "ok"
    test %r13, %r13
    jz 5f
    CSTR %rsi, "timeout"
    cmp $E_TIMEOUT, %r13
    je 5f
    CSTR %rsi, "cancelled"
    cmp $E_CANCELLED, %r13
    je 5f
    CSTR %rsi, "error"
5:  mov %r15, %rdi
    call buf_puts
    PUTS %r15, "\""
    test %r13, %r13
    jz 6f
    PUTS %r15, ",\"error_code\":\""
    mov %r13, %rdi
    call proto_err_name
    mov %r15, %rdi
    mov %rax, %rsi
    call buf_puts
    PUTS %r15, "\""
6:  PUTS %r15, ",\"duration_ms\":"
    cvtsi2sd %r12, %xmm0
    mov $1000000, %eax
    cvtsi2sd %rax, %xmm1
    divsd %xmm1, %xmm0
    mov %r15, %rdi
    CSTR %rsi, "%.3f"
    call buf_put_double
    PUTS %r15, ",\"rows\":"
    mov %r15, %rdi
    mov %r14, %rsi
    call buf_put_u64
    call log_end
9:  LEAVE
ENDF account_code

/* buf_put_double(buf rdi, fmt rsi, value xmm0) */
FUNC buf_put_double
    ENTER 64
    mov %rdi, %rbx
    mov %rsi, %rdx
    lea 0(%rsp), %rdi
    mov $64, %esi
    mov $1, %eax
    call snprintf
    mov %rbx, %rdi
    lea 0(%rsp), %rsi
    call buf_puts
    LEAVE
ENDF buf_put_double

/* account(c rdi): accounts the connection's running query once */
FUNC account
    ENTER 0
    mov %rdi, %rbx
    cmpq $0, CN_QACCT(%rbx)
    jne 9f
    movq $1, CN_QACCT(%rbx)
    call conn_sh
    mov %rax, %r12
    cmpq $0, SH_DONE(%r12)
    je 1f
    mov SH_STATUS(%r12), %rdx
    mov SH_ROWS(%r12), %rcx
    jmp 2f
1:  mov CN_QKILL(%rbx), %rdx        /* killed before finishing */
    test %rdx, %rdx
    jnz 11f
    mov $E_CANCELLED, %edx
11: xor %ecx, %ecx
2:  mov CN_QID(%rbx), %rdi
    mov CN_QSTART(%rbx), %rsi
    call account_code
9:  LEAVE
ENDF account

/* harvest(): accounts queries whose children finished their response but
 * are not reaped yet (so metrics are exact as soon as clients see results) */
FUNC harvest
    ENTER 0
    mov conns(%rip), %rbx
    xor %r12d, %r12d
1:  cmp conn_hi(%rip), %r12
    jae 9f
    cmpq $QS_RUNNING, CN_QSTATE(%rbx)
    jne 2f
    cmpq $0, CN_QACCT(%rbx)
    jne 2f
    mov %rbx, %rdi
    call conn_sh
    cmpq $0, SH_DONE(%rax)
    je 2f
    mov %rbx, %rdi
    call account
2:  add $CN_SIZE, %rbx
    inc %r12
    jmp 1b
9:  LEAVE
ENDF harvest

/* ================================================================ connections */

/* conn_close(c rdi) */
FUNC conn_close
    push %rbx
    mov %rdi, %rbx
    mov CN_FD(%rbx), %edi
    call close
    mov CN_BUF+BUF_DATA(%rbx), %rdi
    call free
    mov %rbx, %rdi
    call clear_query
    mov %rbx, %rdi
    xor %esi, %esi
    mov $CN_SIZE, %edx
    call memset
    pop %rbx
    ret
ENDF conn_close

/* conn_linger(c rdi): half-close, then discard input until EOF / deadline */
FUNC conn_linger
    push %rbx
    mov %rdi, %rbx
    mov CN_FD(%rbx), %edi
    mov $1, %esi                    /* SHUT_WR */
    call shutdown
    movq $CS_DRAIN, CN_STATE(%rbx)
    movq $0, CN_BUF+BUF_LEN(%rbx)
    call now_ns
    add $DRAIN_NS, %rax
    mov %rax, CN_DRAINDL(%rbx)
    pop %rbx
    ret
ENDF conn_linger

/* conn_consume(c rdi, n rsi): drops n bytes from the front of the buffer */
FUNC conn_consume
    push %rbx
    mov %rdi, %rbx
    mov CN_BUF+BUF_LEN(%rbx), %rdx
    sub %rsi, %rdx
    mov %rdx, CN_BUF+BUF_LEN(%rbx)
    jz 1f
    mov CN_BUF+BUF_DATA(%rbx), %rdi
    add %rdi, %rsi
    call memmove
1:  pop %rbx
    ret
ENDF conn_consume

/* conn_accept() */
FUNC conn_accept
    ENTER 16
    mov listen_fd(%rip), %edi
    xor %esi, %esi
    xor %edx, %edx
    call accept
    test %eax, %eax
    js 9f
    mov %eax, %r12d
    /* free slot */
    mov conns(%rip), %rbx
    xor %r13d, %r13d
1:  cmp $MAX_CONN, %r13
    jae 8f
    cmpq $CS_FREE, CN_STATE(%rbx)
    je 2f
    add $CN_SIZE, %rbx
    inc %r13
    jmp 1b
2:  movq $CS_READ, CN_STATE(%rbx)
    mov %r12, CN_FD(%rbx)
    lea 1(%r13), %rax
    cmp conn_hi(%rip), %rax
    jbe 3f
    mov %rax, conn_hi(%rip)
3:  movl $1, 0(%rsp)                /* TCP_NODELAY */
    mov %r12d, %edi
    mov $6, %esi                    /* IPPROTO_TCP */
    mov $1, %edx
    lea 0(%rsp), %rcx
    mov $4, %r8d
    call setsockopt
    LEAVE
8:  mov %r12d, %edi                 /* no slot left */
    call close
9:  LEAVE
ENDF conn_accept

/* conn_read(c rdi): reads available input and processes complete requests */
FUNC conn_read
    ENTER 0
    mov %rdi, %rbx
    lea CN_BUF(%rbx), %rdi
    mov $READ_CHUNK, %esi
    call buf_reserve
1:  mov CN_FD(%rbx), %edi
    mov CN_BUF+BUF_DATA(%rbx), %rsi
    add CN_BUF+BUF_LEN(%rbx), %rsi
    mov CN_BUF+BUF_CAP(%rbx), %rdx
    sub CN_BUF+BUF_LEN(%rbx), %rdx
    dec %rdx                        /* keep room for a NUL */
    call read
    test %rax, %rax
    jg 2f
    jz 8f
    call __errno_location
    cmpl $4, (%rax)
    je 1b
8:  mov %rbx, %rdi                  /* EOF / error */
    call conn_close
    LEAVE
2:  add %rax, CN_BUF+BUF_LEN(%rbx)
    mov %rbx, %rdi
    call conn_process
    LEAVE
ENDF conn_read

/* conn_drain(c rdi): lingering close input */
FUNC conn_drain
    ENTER 4096
    mov %rdi, %rbx
    mov CN_FD(%rbx), %edi
    lea 0(%rsp), %rsi
    mov $4096, %edx
    call read
    test %rax, %rax
    jg 9f
    mov %rbx, %rdi
    call conn_close
9:  LEAVE
ENDF conn_drain

/* conn_process(c rdi): parses and routes buffered requests while the
 * connection is in the reading state */
FUNC conn_process
    ENTER 16
    mov %rdi, %rbx
    lea g_req(%rip), %r13
1:  cmpq $CS_READ, CN_STATE(%rbx)
    jne 9f
    mov CN_BUF+BUF_LEN(%rbx), %r12
    mov CN_DISCARD(%rbx), %rax
    test %rax, %rax
    jz 2f
    cmp %r12, %rax                  /* skipping the body of a rejected request */
    cmova %r12, %rax
    sub %rax, CN_DISCARD(%rbx)
    mov %rbx, %rdi
    mov %rax, %rsi
    call conn_consume
    cmpq $0, CN_DISCARD(%rbx)
    jne 9f
    jmp 1b
2:  test %r12, %r12
    jz 9f
    mov CN_BUF+BUF_DATA(%rbx), %rdi
    mov %r12, %rsi
    mov g_srv_max_req(%rip), %rdx
    mov %r13, %rcx
    lea CN_CRES(%rbx), %r8
    call http_parse
    cmp $HP_NEED, %eax
    je 21f
    movq $0, CN_CRES(%rbx)          /* the next request starts afresh */
    movq $0, CN_CRES+8(%rbx)
21:
    cmp $HP_OK, %eax
    je 5f
    cmp $HP_BAD, %eax
    je 3f
    cmp $HP_TOOBIG, %eax
    je 4f
    /* incomplete: answer Expect: 100-continue once the header is in */
    cmpq $0, RQ_EXPECT(%r13)
    je 9f
    cmpq $0, RQ_HDRLEN(%r13)
    je 9f
    cmpq $0, CN_CONT(%rbx)
    jne 9f
    movq $1, CN_CONT(%rbx)
    mov CN_FD(%rbx), %edi
    CSTR %rsi, "HTTP/1.1 100 Continue\r\n\r\n"
    mov $25, %edx
    mov $0x4000, %ecx               /* MSG_NOSIGNAL */
    call send
    jmp 9f
3:  movq $1, CN_CLOSE(%rbx)         /* malformed framing */
    mov %rbx, %rdi
    mov $E_INVALID_REQUEST, %esi
    CSTR %rdx, "malformed HTTP request"
    call respond_error
    mov %rbx, %rdi
    call conn_linger
    jmp 9f
4:  movq $0, CN_CONT(%rbx)          /* body over --max-request-bytes */
    mov RQ_CHUNKED(%r13), %rax
    or RQ_CLOSE(%r13), %rax
    mov %rax, CN_CLOSE(%rbx)
    mov %rbx, %rdi
    mov $E_RESOURCE_LIMIT, %esi
    CSTR %rdx, "request body exceeds --max-request-bytes"
    call respond_error
    cmpq $0, CN_CLOSE(%rbx)
    je 41f
    mov %rbx, %rdi
    call conn_linger
    jmp 9f
41: mov RQ_CLEN(%r13), %rax
    mov %rax, CN_DISCARD(%rbx)
    mov %rbx, %rdi
    mov RQ_HDRLEN(%r13), %rsi
    call conn_consume
    jmp 1b
5:  movq $0, CN_CONT(%rbx)
    mov RQ_CLOSE(%r13), %rax
    mov %rax, CN_CLOSE(%rbx)
    mov RQ_BODY(%r13), %rax         /* NUL-terminate the body in place */
    add RQ_BODYLEN(%r13), %rax
    mov %rax, 0(%rsp)
    movzbl (%rax), %ecx
    mov %rcx, 8(%rsp)
    movb $0, (%rax)
    mov %rbx, %rdi
    mov %r13, %rsi
    call route
    cmpq $QS_INLINE, CN_QSTATE(%rbx)
    jne 51f
    mov 0(%rsp), %rax               /* catalog job reads the buffer: the */
    mov %rax, CN_JNULPOS(%rbx)      /* request is consumed when it is done */
    mov 8(%rsp), %rax
    mov %rax, CN_JNULVAL(%rbx)
    jmp 9f
51: mov 0(%rsp), %rax
    mov 8(%rsp), %rcx
    mov %cl, (%rax)
    mov %rbx, %rdi
    mov RQ_TOTAL(%r13), %rsi
    call conn_consume
    cmpq $CS_READ, CN_STATE(%rbx)
    jne 9f
    cmpq $0, CN_CLOSE(%rbx)
    je 1b
    mov %rbx, %rdi
    call conn_linger
9:  LEAVE
ENDF conn_process

/* ================================================================ routing */

/* path_eq(req rdi, cstr rsi) -> eax */
FUNC path_eq
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rsi, %rdi
    call strlen
    cmp RQ_PATHLEN(%rbx), %rax
    jne 8f
    mov RQ_PATH(%rbx), %rdi
    mov %r12, %rsi
    mov %rax, %rdx
    call memcmp
    test %eax, %eax
    jnz 8f
    mov $1, %eax
    LEAVE
8:  xor %eax, %eax
    LEAVE
ENDF path_eq

/* path_prefix(req rdi, cstr rsi) -> rax rest ptr (0 if no match), rdx rest len */
FUNC path_prefix
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rsi, %rdi
    call strlen
    mov %rax, %r13
    cmp RQ_PATHLEN(%rbx), %rax
    jae 8f
    mov RQ_PATH(%rbx), %rdi
    mov %r12, %rsi
    mov %r13, %rdx
    call memcmp
    test %eax, %eax
    jnz 8f
    mov RQ_PATH(%rbx), %rax
    add %r13, %rax
    mov RQ_PATHLEN(%rbx), %rdx
    sub %r13, %rdx
    LEAVE
8:  xor %eax, %eax
    xor %edx, %edx
    LEAVE
ENDF path_prefix

/* meth_eq(req rdi, cstr rsi) -> eax */
FUNC meth_eq
    push %rbx
    push %r12
    sub $8, %rsp
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rsi, %rdi
    call strlen
    cmp RQ_METHLEN(%rbx), %rax
    jne 8f
    mov RQ_METH(%rbx), %rdi
    mov %r12, %rsi
    mov %rax, %rdx
    call memcmp
    test %eax, %eax
    jnz 8f
    mov $1, %eax
    jmp 9f
8:  xor %eax, %eax
9:  add $8, %rsp
    pop %r12
    pop %rbx
    ret
ENDF meth_eq

/* parse_body(req rdi, arena rsi) -> rax JSON node or 0 */
FUNC parse_body
    mov %rsi, %rdx
    mov RQ_BODYLEN(%rdi), %rsi
    mov RQ_BODY(%rdi), %rdi
    jmp json_parse
ENDF parse_body




/* sql_mutates(node rdi) -> eax 1 if the request's "sql" is a CREATE/DROP
 * statement (first keyword after blanks and comments) */
FUNC sql_mutates
    ENTER 0
    CSTR %rsi, "sql"
    call json_obj_get
    test %rax, %rax
    jz 8f
    cmpq $J_STRING, JN_TYPE(%rax)
    jne 8f
    mov JN_PTR(%rax), %rbx
    mov JN_LEN(%rax), %r12
    add %rbx, %r12                  /* end */
1:  cmp %r12, %rbx
    jae 8f
    movzbl (%rbx), %eax
    cmp $' ', %eax
    je 2f
    cmp $'\t', %eax
    je 2f
    cmp $'\n', %eax
    je 2f
    cmp $'\r', %eax
    je 2f
    cmp $'(', %eax
    je 8f
    cmp $'-', %eax                  /* -- comment */
    jne 3f
    lea 1(%rbx), %rcx
    cmp %r12, %rcx
    jae 8f
    cmpb $'-', (%rcx)
    jne 8f
21: inc %rbx
    cmp %r12, %rbx
    jae 8f
    cmpb $'\n', (%rbx)
    jne 21b
    jmp 2f
3:  cmp $'/', %eax                  /* block comment */
    jne 4f
    lea 1(%rbx), %rcx
    cmp %r12, %rcx
    jae 8f
    cmpb $'*', (%rcx)
    jne 8f
    add $2, %rbx
31: lea 1(%rbx), %rcx
    cmp %r12, %rcx
    jae 8f
    cmpb $'*', (%rbx)
    jne 32f
    cmpb $'/', (%rcx)
    jne 32f
    add $2, %rbx
    jmp 1b
32: inc %rbx
    jmp 31b
2:  inc %rbx
    jmp 1b
4:  mov %r12, %r13                  /* keyword */
    sub %rbx, %r13
    cmp $4, %r13
    jb 8f
    mov %rbx, %rdi
    mov $4, %esi
    CSTR %rdx, "drop"
    call cstr_ieq
    test %eax, %eax
    jnz 5f
    cmp $6, %r13
    jb 8f
    mov %rbx, %rdi
    mov $6, %esi
    CSTR %rdx, "create"
    call cstr_ieq
    test %eax, %eax
    jz 8f
5:  mov $1, %eax
    LEAVE
8:  xor %eax, %eax
    LEAVE
ENDF sql_mutates

/* route(c rdi, req rsi): dispatches one complete request.  Health,
 * metrics, version, capabilities and the query registry are answered here;
 * queries go through admission control; catalog operations are handed to
 * the catalog worker thread (job_submit). */
FUNC route
    ENTER 32
    mov %rdi, %rbx
    mov %rsi, %r13
    mov net_arena(%rip), %rdi
    call arena_reset
    mov $LV_DEBUG, %edi
    CSTR %rsi, "http request"
    call log_begin
    test %eax, %eax
    jz 0f
    lea log_buf(%rip), %r15
    PUTS %r15, ",\"method\":"
    mov %r15, %rdi
    mov RQ_METH(%r13), %rsi
    mov RQ_METHLEN(%r13), %rdx
    call buf_put_json_str
    PUTS %r15, ",\"path\":"
    mov %r15, %rdi
    mov RQ_PATH(%r13), %rsi
    mov RQ_PATHLEN(%r13), %rdx
    call buf_put_json_str
    call log_end
0:  /* ---- fixed paths */
    mov %r13, %rdi
    CSTR %rsi, "/health"
    call path_eq
    test %eax, %eax
    jz 1f
    mov %r13, %rdi
    CSTR %rsi, "GET"
    call meth_eq
    test %eax, %eax
    jz r_405
    mov %rbx, %rdi
    cmpq $0, shutting(%rip)
    jne 97f
    mov $200, %esi
    CSTR %rdx, "{\"status\":\"ok\"}"
    call respond_cstr
    LEAVE
97: mov $503, %esi
    CSTR %rdx, "{\"status\":\"shutting_down\"}"
    call respond_cstr
    LEAVE
1:  mov %r13, %rdi
    CSTR %rsi, "/metrics"
    call path_eq
    test %eax, %eax
    jz 2f
    mov %r13, %rdi
    CSTR %rsi, "GET"
    call meth_eq
    test %eax, %eax
    jz r_405
    mov %rbx, %rdi
    call handle_metrics
    LEAVE
2:  mov %r13, %rdi
    CSTR %rsi, "/v1/version"
    call path_eq
    test %eax, %eax
    jz 3f
    xor %r14d, %r14d
    jmp r_static
3:  mov %r13, %rdi
    CSTR %rsi, "/v1/capabilities"
    call path_eq
    test %eax, %eax
    jz 4f
    mov $1, %r14d
    jmp r_static
4:  mov %r13, %rdi
    CSTR %rsi, "/v1/tables"
    call path_eq
    test %eax, %eax
    jz 5f
    mov %r13, %rdi
    CSTR %rsi, "GET"
    call meth_eq
    test %eax, %eax
    jz r_405
    mov %rbx, %rdi
    mov $JK_EMPTY, %esi
    CSTR %rdx, "tables"
    mov $200, %ecx
    xor %r8d, %r8d
    call job_submit
    LEAVE
5:  mov %r13, %rdi
    CSTR %rsi, "/v1/query"
    call path_eq
    test %eax, %eax
    jz 6f
    mov $QK_QUERY, %r14d
    jmp r_post_query
6:  mov %r13, %rdi
    CSTR %rsi, "/v1/query/stream"
    call path_eq
    test %eax, %eax
    jz 7f
    mov $QK_STREAM, %r14d
    jmp r_post_query
7:  mov %r13, %rdi
    CSTR %rsi, "/v1/request"
    call path_eq
    test %eax, %eax
    jz 8f
    mov $QK_REQUEST, %r14d
    jmp r_post_query
8:  mov %r13, %rdi
    CSTR %rsi, "/v1/explain"
    call path_eq
    test %eax, %eax
    jz 9f
    mov %r13, %rdi
    CSTR %rsi, "POST"
    call meth_eq
    test %eax, %eax
    jz r_405
    mov %rbx, %rdi
    mov $JK_BODY, %esi
    CSTR %rdx, "explain"
    mov $200, %ecx
    xor %r8d, %r8d
    call job_submit
    LEAVE
9:  mov %r13, %rdi
    CSTR %rsi, "/v1/queries"
    call path_eq
    test %eax, %eax
    jz 10f
    mov %r13, %rdi
    CSTR %rsi, "GET"
    call meth_eq
    test %eax, %eax
    jz r_405
    mov %rbx, %rdi
    call handle_queries
    LEAVE
10: /* ---- /v1/queries/{id} */
    mov %r13, %rdi
    CSTR %rsi, "/v1/queries/"
    call path_prefix
    test %rax, %rax
    jz 11f
    mov %rax, %r14
    mov %rdx, %r15
    mov %r13, %rdi
    CSTR %rsi, "DELETE"
    call meth_eq
    test %eax, %eax
    jz r_405
    mov net_arena(%rip), %rdi
    lea 1(%r15), %rsi
    call arena_alloc
    mov %rax, %r12
    mov %r14, %rdi
    mov %r15, %rsi
    mov %r12, %rdx
    call url_decode
    mov %rbx, %rdi
    mov %r12, %rsi
    call handle_cancel
    LEAVE
11: /* ---- /v1/tables/{name}[/schema|/stats] */
    mov %r13, %rdi
    CSTR %rsi, "/v1/tables/"
    call path_prefix
    test %rax, %rax
    jz r_404
    mov %rax, %r14
    mov %rdx, %r15
    mov %r14, CN_JNAME(%rbx)
    mov %r15, CN_JNLEN(%rbx)
    mov %r14, %rdi
    mov $'/', %esi
    mov %r15, %rdx
    call memchr
    test %rax, %rax
    jz r_table
    mov %rax, %r12                  /* "/schema" or "/stats" */
    mov %r15, %rcx
    add %r14, %rcx
    sub %rax, %rcx
    mov %rcx, 0(%rsp)
    sub %r14, %rax
    mov %rax, CN_JNLEN(%rbx)        /* name length */
    mov %r12, %rdi
    mov 0(%rsp), %rsi
    CSTR %rdx, "/schema"
    call cstr_ieq
    test %eax, %eax
    jz 12f
    CSTR %rax, "schema"
    jmp 13f
12: mov %r12, %rdi
    mov 0(%rsp), %rsi
    CSTR %rdx, "/stats"
    call cstr_ieq
    test %eax, %eax
    jz r_404
    CSTR %rax, "stats"
13: mov %rax, 8(%rsp)
    mov %r13, %rdi
    CSTR %rsi, "GET"
    call meth_eq
    test %eax, %eax
    jz r_405
    mov %rbx, %rdi
    mov $JK_TABLE, %esi
    mov 8(%rsp), %rdx
    mov $200, %ecx
    xor %r8d, %r8d
    call job_submit
    LEAVE
r_table:
    mov %r13, %rdi
    CSTR %rsi, "PUT"
    call meth_eq
    test %eax, %eax
    jnz r_put
    mov %r13, %rdi
    CSTR %rsi, "DELETE"
    call meth_eq
    test %eax, %eax
    jz r_405
    cmpq $0, shutting(%rip)
    jne r_shutting
    mov %rbx, %rdi
    mov $JK_TABLE, %esi
    CSTR %rdx, "drop"
    mov $200, %ecx
    xor %r8d, %r8d
    call job_submit
    LEAVE
r_put:
    cmpq $0, shutting(%rip)
    jne r_shutting
    mov %rbx, %rdi
    mov $JK_PUT, %esi
    CSTR %rdx, "load"
    mov $201, %ecx
    xor %r8d, %r8d
    call job_submit
    LEAVE
r_static:                           /* r14d: 0 version, 1 capabilities */
    mov %r13, %rdi
    CSTR %rsi, "GET"
    call meth_eq
    test %eax, %eax
    jz r_405
    lea srv_buf(%rip), %r15
    movq $0, BUF_LEN(%r15)
    mov %r14d, %edi
    mov %r15, %rsi
    call proto_static_buf
    mov %rbx, %rdi
    mov $200, %esi
    mov %r15, %rdx
    call respond_buf
    LEAVE
r_post_query:
    mov %r13, %rdi
    CSTR %rsi, "POST"
    call meth_eq
    test %eax, %eax
    jz r_405
    cmpq $0, shutting(%rip)
    jne r_shutting
    mov %r13, %rdi
    mov net_arena(%rip), %rsi
    call parse_body
    mov %rax, %r12                  /* node */
    test %r12, %r12
    jz r_post_inline
    cmpq $J_OBJECT, JN_TYPE(%r12)
    jne r_post_inline
    cmp $QK_REQUEST, %r14d
    jne 20f
    /* /v1/request: only "query" and "sleep" go through admission */
    mov %r12, %rdi
    CSTR %rsi, "op"
    call json_obj_get
    test %rax, %rax
    jz r_post_inline
    cmpq $J_STRING, JN_TYPE(%rax)
    jne r_post_inline
    mov JN_PTR(%rax), %r15
    mov %r15, %rdi
    CSTR %rsi, "sleep"
    call strcmp
    test %eax, %eax
    jz 21f
    mov %r15, %rdi
    CSTR %rsi, "query"
    call strcmp
    test %eax, %eax
    jnz r_post_inline
20: mov %r12, %rdi
    call sql_mutates
    test %eax, %eax
    jz 21f
    mov %r12, %rdi                  /* CREATE / DROP INDEX: catalog job */
    call query_id_of
    mov %rax, CN_QID(%rbx)
    mov $1, %r8d
    jmp r_post_job
21: mov %rbx, %rdi
    mov %r13, %rsi
    mov %r12, %rdx
    mov %r14d, %ecx
    call query_admit
    LEAVE
r_post_inline:                      /* invalid bodies and catalog operations */
    xor %r8d, %r8d
r_post_job:
    lea op_query_s(%rip), %rdx
    cmp $QK_REQUEST, %r14d
    jne 22f
    xor %edx, %edx
22: mov %rbx, %rdi
    mov $JK_BODY, %esi
    mov $200, %ecx
    call job_submit
    LEAVE
r_shutting:
    mov %rbx, %rdi
    mov $E_SHUTTING_DOWN, %esi
    CSTR %rdx, "server is shutting down"
    call respond_error
    LEAVE
r_404:
    mov %rbx, %rdi
    mov $E_NOT_FOUND, %esi
    CSTR %rdx, "unknown path"
    call respond_error
    LEAVE
r_405:
    mov %rbx, %rdi
    mov $E_INVALID_REQUEST, %esi
    CSTR %rdx, "method not allowed"
    mov $405, %ecx
    call respond_error_st
    LEAVE
ENDF route

/* table_node(name rdi, len rsi) -> rax {"table":"<decoded name>"} */
FUNC table_node
    ENTER 32
    mov %rdi, %rbx
    mov %rsi, %r12
    lea 1(%rsi), %rdi
    call tmp_alloc
    mov %rax, %r13
    mov %rbx, %rdi
    mov %r12, %rsi
    mov %r13, %rdx
    call url_decode
    mov %rax, %r12
    lea 0(%rsp), %rdi
    call buf_init
    lea 0(%rsp), %r15
    PUTS %r15, "{\"table\":"
    mov %r15, %rdi
    mov %r13, %rsi
    mov %r12, %rdx
    call buf_put_json_str
    PUTS %r15, "}"
    mov 0(%rsp), %rdi
    mov 8(%rsp), %rsi
    mov g_arena(%rip), %rdx
    call json_parse
    mov %rax, %rbx
    lea 0(%rsp), %rdi
    call buf_free
    mov %rbx, %rax
    LEAVE
ENDF table_node

/* qp_true(qs, qslen, name) -> eax 1 if the parameter is "true"/"1" */
FUNC qp_true
    push %rbx
    call query_param
    test %rax, %rax
    jz 8f
    mov %rax, %rbx
    mov %rbx, %rdi
    mov %rdx, %rsi
    push %rdx
    push %rdx
    CSTR %rdx, "true"
    call cstr_ieq
    pop %rdx
    pop %rdx
    test %eax, %eax
    jnz 9f
    cmp $1, %rdx
    jne 8f
    cmpb $'1', (%rbx)
    jne 8f
    mov $1, %eax
    jmp 9f
8:  xor %eax, %eax
9:  pop %rbx
    ret
ENDF qp_true

/* qp_false(qs, qslen, name) -> eax 1 if the parameter is "false"/"0" */
FUNC qp_false
    push %rbx
    call query_param
    test %rax, %rax
    jz 8f
    mov %rax, %rbx
    mov %rbx, %rdi
    mov %rdx, %rsi
    push %rdx
    push %rdx
    CSTR %rdx, "false"
    call cstr_ieq
    pop %rdx
    pop %rdx
    test %eax, %eax
    jnz 9f
    cmp $1, %rdx
    jne 8f
    cmpb $'0', (%rbx)
    jne 8f
    mov $1, %eax
    jmp 9f
8:  xor %eax, %eax
9:  pop %rbx
    ret
ENDF qp_false

/* put_node(req rdi, name rsi, len rdx) -> rax load request for PUT
 * /v1/tables/{name}?format=..&replace=..&header=.. (raw data as body) */
FUNC put_node
    ENTER 32
    mov %rdi, %r13
    mov %rsi, %r14
    mov %rdx, %r15
    lea 0(%rsp), %rdi
    call buf_init
    lea 0(%rsp), %r12
    PUTS %r12, "{\"table\":"
    lea 1(%r15), %rdi
    call tmp_alloc
    mov %rax, 24(%rsp)
    mov %r14, %rdi
    mov %r15, %rsi
    mov %rax, %rdx
    call url_decode
    mov %r12, %rdi
    mov 24(%rsp), %rsi
    mov %rax, %rdx
    call buf_put_json_str
    /* format */
    mov RQ_QS(%r13), %rdi
    mov RQ_QSLEN(%r13), %rsi
    CSTR %rdx, "format"
    call query_param
    test %rax, %rax
    jz 1f
    mov %rax, %r14
    mov %rdx, %r15
    lea 1(%r15), %rdi
    call tmp_alloc
    mov %rax, 24(%rsp)
    mov %r14, %rdi
    mov %r15, %rsi
    mov %rax, %rdx
    call url_decode
    mov %rax, %r15
    PUTS %r12, ",\"format\":"
    mov %r12, %rdi
    mov 24(%rsp), %rsi
    mov %r15, %rdx
    call buf_put_json_str
1:  mov RQ_QS(%r13), %rdi
    mov RQ_QSLEN(%r13), %rsi
    CSTR %rdx, "replace"
    call qp_true
    test %eax, %eax
    jz 2f
    PUTS %r12, ",\"replace\":true"
2:  mov RQ_QS(%r13), %rdi
    mov RQ_QSLEN(%r13), %rsi
    CSTR %rdx, "header"
    call qp_false
    test %eax, %eax
    jz 3f
    PUTS %r12, ",\"options\":{\"header\":false}"
3:  PUTS %r12, ",\"data\":\"\"}"
    mov 0(%rsp), %rdi
    mov 8(%rsp), %rsi
    mov g_arena(%rip), %rdx
    call json_parse
    mov %rax, %r14
    lea 0(%rsp), %rdi
    call buf_free
    mov %r14, %rdi                  /* the data member: the body itself */
    CSTR %rsi, "data"
    call json_obj_get
    mov RQ_BODY(%r13), %rcx
    test %rcx, %rcx
    jnz 4f
    CSTR %rcx, ""
4:  mov %rcx, JN_PTR(%rax)
    mov RQ_BODYLEN(%r13), %rcx
    mov %rcx, JN_LEN(%rax)
    mov %r14, %rax
    LEAVE
ENDF put_node

/* ================================================================ catalog worker */

/* job_submit(c rdi, kind esi, op rdx, ok status ecx, is_query r8d): hands
 * the request in g_req to the catalog worker thread */
FUNC job_submit
    ENTER 0
    mov %rdi, %rbx
    mov %esi, %eax
    mov %rax, CN_JKIND(%rbx)
    mov %rdx, CN_JOP(%rbx)
    mov %ecx, %eax
    mov %rax, CN_JOK(%rbx)
    mov %r8d, %eax
    mov %rax, CN_JQUERY(%rbx)
    mov $RQ_SIZE, %edi
    call xmalloc
    mov %rax, CN_JREQ(%rbx)
    mov %rax, %rdi
    lea g_req(%rip), %rsi
    mov $RQ_SIZE, %edx
    call memcpy
    call now_ns
    mov %rax, CN_QSTART(%rbx)
    movq $CS_BUSY, CN_STATE(%rbx)
    movq $QS_INLINE, CN_QSTATE(%rbx)
    incq n_inline(%rip)
    lea q_mutex(%rip), %rdi
    call pthread_mutex_lock
    mov q_tail(%rip), %rax
    and $(JOBQ_SIZE - 1), %eax
    mov jobq(%rip), %rcx
    mov %rbx, (%rcx, %rax, 8)
    incq q_tail(%rip)
    lea q_cond(%rip), %rdi
    call pthread_cond_signal
    lea q_mutex(%rip), %rdi
    call pthread_mutex_unlock
    LEAVE
ENDF job_submit

/* finish_inline(c rdi): (network thread) a catalog job is done: respond,
 * consume the request and continue with the connection */
FUNC finish_inline
    ENTER 0
    mov %rdi, %rbx
    decq n_inline(%rip)
    mov CN_QID(%rbx), %rax
    mov %rax, g_resp_qid(%rip)
    mov %rbx, %rdi
    mov CN_RSTATUS(%rbx), %esi
    lea ctype_json(%rip), %rdx
    mov CN_RESP(%rbx), %rcx
    mov CN_RESPLEN(%rbx), %r8
    call respond
    movq $0, g_resp_qid(%rip)
    cmpq $0, CN_JQUERY(%rbx)
    je 1f
    mov CN_QID(%rbx), %rdi
    mov CN_QSTART(%rbx), %rsi
    mov CN_ISTATUS(%rbx), %rdx
    xor %ecx, %ecx
    call account_code
1:  mov CN_JNULPOS(%rbx), %rax
    mov CN_JNULVAL(%rbx), %rcx
    mov %cl, (%rax)
    mov CN_JREQ(%rbx), %rax
    mov RQ_TOTAL(%rax), %rsi
    mov %rbx, %rdi
    call conn_consume
    mov %rbx, %rdi
    call clear_query
    mov %rbx, %rdi
    call after_response
    LEAVE
ENDF finish_inline

/* handle_done(): (network thread) reads finished jobs from the pipe */
FUNC handle_done
    ENTER 512
    mov done_r(%rip), %edi
    lea 0(%rsp), %rsi
    mov $512, %edx
    call read
    test %rax, %rax
    jle 9f
    shr $3, %rax
    mov %rax, %r12
    xor %r13d, %r13d
1:  cmp %r12, %r13
    jae 9f
    mov (%rsp, %r13, 8), %rdi
    call finish_inline
    inc %r13
    jmp 1b
9:  LEAVE
ENDF handle_done

/* cw_exec(c rdi): (worker thread) runs a catalog job; the response is left
 * in CN_RESP / CN_RSTATUS */
FUNC cw_exec
    ENTER 16
    mov %rdi, %rbx
    mov CN_JREQ(%rbx), %r13
    mov g_arena(%rip), %rdi
    call arena_reset
    mov CN_JKIND(%rbx), %rax
    cmp $JK_BODY, %rax
    jne 1f
    mov %r13, %rdi
    mov g_arena(%rip), %rsi
    call parse_body
    jmp 5f
1:  cmp $JK_TABLE, %rax
    jne 2f
    mov CN_JNAME(%rbx), %rdi
    mov CN_JNLEN(%rbx), %rsi
    call table_node
    jmp 5f
2:  cmp $JK_PUT, %rax
    jne 3f
    mov %r13, %rdi
    mov CN_JNAME(%rbx), %rsi
    mov CN_JNLEN(%rbx), %rdx
    call put_node
    jmp 5f
3:  CSTR %rdi, "{}"
    mov $2, %esi
    mov g_arena(%rip), %rdx
    call json_parse
5:  mov %rax, %r12                  /* request node */
    mov CN_JOP(%rbx), %rax
    mov %rax, g_force_op(%rip)
    movq $0, g_forced_deadline(%rip)
    mov %r12, %rdi
    call handle_request_noreset
    movq $0, g_force_op(%rip)
    mov CN_JOK(%rbx), %rax
    mov g_req_status(%rip), %rdi
    mov %rdi, CN_ISTATUS(%rbx)
    test %rdi, %rdi
    jz 6f
    call http_status_for
6:  mov %rax, CN_RSTATUS(%rbx)
    mov g_out+BUF_DATA(%rip), %rdi
    mov g_out+BUF_LEN(%rip), %rsi
    mov %rsi, CN_RESPLEN(%rbx)
    test %rdi, %rdi
    jnz 7f
    CSTR %rdi, ""
7:  call xstrdup_mem
    mov %rax, CN_RESP(%rbx)
    LEAVE
ENDF cw_exec

/* cw_main(arg): the catalog worker thread: executes catalog jobs one at a
 * time holding cat_lock (released while a load parses its input) */
FUNC cw_main
    ENTER 48
    /* STACK_CHECK limit and alternate signal stack: stack overflows are
     * reported as RESOURCE_LIMIT */
    call thread_stack_init
1:  lea q_mutex(%rip), %rdi
    call pthread_mutex_lock
2:  mov q_head(%rip), %rax
    cmp q_tail(%rip), %rax
    jne 3f
    lea q_cond(%rip), %rdi
    lea q_mutex(%rip), %rsi
    call pthread_cond_wait
    jmp 2b
3:  and $(JOBQ_SIZE - 1), %eax
    mov jobq(%rip), %rcx
    mov (%rcx, %rax, 8), %rbx
    incq q_head(%rip)
    lea q_mutex(%rip), %rdi
    call pthread_mutex_unlock
    lea cat_lock(%rip), %rdi
    call pthread_mutex_lock
    movq $1, g_cat_locked(%rip)
    mov %rbx, %rdi
    call cw_exec
    cmpq $0, g_cat_locked(%rip)
    je 4f
    movq $0, g_cat_locked(%rip)
    lea cat_lock(%rip), %rdi
    call pthread_mutex_unlock
4:  mov %rbx, 0(%rsp)
5:  mov done_w(%rip), %edi
    lea 0(%rsp), %rsi
    mov $8, %edx
    call write
    cmp $8, %rax
    je 1b
    call __errno_location
    cmpl $4, (%rax)
    je 5b
    jmp 1b
ENDF cw_main

/* cat_parse_begin(): op_load is about to parse its input: let queries fork
 * meanwhile (the catalog is not touched until cat_parse_end) */
FUNC cat_parse_begin
    cmpq $0, g_cat_threaded(%rip)
    jne 1f
    ret
1:  sub $8, %rsp
    cmpq $0, g_cat_locked(%rip)
    je 2f
    movq $0, g_cat_locked(%rip)
    lea cat_lock(%rip), %rdi
    call pthread_mutex_unlock
2:  add $8, %rsp
    ret
ENDF cat_parse_begin

/* cat_parse_end(): reacquires the catalog lock before publishing */
FUNC cat_parse_end
    cmpq $0, g_cat_threaded(%rip)
    jne 1f
    ret
1:  sub $8, %rsp
    cmpq $0, g_cat_locked(%rip)
    jne 2f
    lea cat_lock(%rip), %rdi
    call pthread_mutex_lock
    movq $1, g_cat_locked(%rip)
2:  add $8, %rsp
    ret
ENDF cat_parse_end

/* ================================================================ queries */

/* query_id_of(request node rdi) -> rax malloc'd query id: options.query_id
 * or a server-assigned "q-<n>" */
FUNC query_id_of
    ENTER 32
    CSTR %rsi, "options"
    call json_obj_get
    mov %rax, %rdi
    CSTR %rsi, "query_id"
    call json_obj_get               /* (0 / non-objects give 0) */
    test %rax, %rax
    jz 2f
    cmpq $J_STRING, JN_TYPE(%rax)
    jne 2f
    mov JN_PTR(%rax), %rdi
    mov JN_LEN(%rax), %rsi
    call xstrdup_mem
    LEAVE
2:  incq id_seq(%rip)
    lea 0(%rsp), %rdi
    mov $24, %esi
    CSTR %rdx, "q-%lu"
    mov id_seq(%rip), %rcx
    xor %eax, %eax
    call snprintf
    lea 0(%rsp), %rdi
    mov %rax, %rsi
    call xstrdup_mem
    LEAVE
ENDF query_id_of

/* query_admit(c rdi, req rsi, node rdx, kind ecx): admission control for a
 * query (QK_*); the request is an object */
FUNC query_admit
    ENTER 32
    mov %rdi, %rbx
    mov %rsi, %r13
    mov %rdx, %r12
    mov %ecx, %r14d
    movq $0, 0(%rsp)                /* options */
    mov %r12, %rdi
    CSTR %rsi, "options"
    call json_obj_get
    test %rax, %rax
    jz 1f
    cmpq $J_OBJECT, JN_TYPE(%rax)
    jne 1f
    mov %rax, 0(%rsp)
1:  mov %r12, %rdi
    call query_id_of
    mov %rax, CN_QID(%rbx)
    mov %r14, CN_QKIND(%rbx)
    /* request id (/v1/request) for parent-generated errors */
    cmp $QK_REQUEST, %r14d
    jne 4f
    mov %r12, %rdi
    CSTR %rsi, "id"
    call json_obj_get
    test %rax, %rax
    jz 4f
    mov %rax, %r15
    lea srv_buf(%rip), %rdi
    movq $0, BUF_LEN(%rdi)
    mov %r15, %rsi
    call json_write
    mov srv_buf+BUF_DATA(%rip), %rdi
    mov srv_buf+BUF_LEN(%rip), %rsi
    call xstrdup_mem
    mov %rax, CN_QREQID(%rbx)
4:  /* a query id must not be in use */
    mov CN_QID(%rbx), %rdi
    call find_query
    test %rax, %rax
    jz 5f
    mov %rbx, %rdi
    mov $E_ALREADY_EXISTS, %esi
    CSTR %rdx, "query_id is already in use"
    call respond_error
    mov %rbx, %rdi
    call clear_query
    LEAVE
5:  /* deadline: options.timeout_ms, else --query-timeout-ms; queue time counts */
    call now_ns
    mov %rax, CN_QSTART(%rbx)
    mov g_srv_timeout_ms(%rip), %r15
    mov 0(%rsp), %rdi
    test %rdi, %rdi
    jz 6f
    CSTR %rsi, "timeout_ms"
    call json_obj_get
    test %rax, %rax
    jz 6f
    cmpq $J_NUMBER, JN_TYPE(%rax)
    jne 6f
    mov %rax, %rdi
    call json_is_int
    test %eax, %eax
    jz 6f
    test %rdx, %rdx
    jle 6f
    mov %rdx, %r15
6:  test %r15, %r15
    jz 7f
    mov $1000000000000, %rax        /* beyond ~31 years: none */
    cmp %rax, %r15
    ja 7f
    imul $NS_PER_MS, %r15, %rax
    add CN_QSTART(%rbx), %rax
    mov %rax, CN_QDL(%rbx)
7:  /* body copy for the child */
    mov RQ_BODY(%r13), %rdi
    mov RQ_BODYLEN(%r13), %rsi
    call xstrdup_mem
    mov %rax, CN_QBODY(%rbx)
    mov RQ_BODYLEN(%r13), %rax
    mov %rax, CN_QBLEN(%rbx)
    movq $CS_BUSY, CN_STATE(%rbx)
    /* admission */
    mov n_running(%rip), %rax
    cmp g_srv_workers(%rip), %rax
    jae 8f
    cmpq $0, n_queued(%rip)
    jne 8f
    movq $QS_STARTING, CN_QSTATE(%rbx)
    incq n_running(%rip)
    incq n_starting(%rip)
    mov %rbx, %rdi
    call start_child
    LEAVE
8:  mov n_queued(%rip), %rax
    cmp g_srv_queue(%rip), %rax
    jae 9f
    movq $QS_QUEUED, CN_QSTATE(%rbx)
    incq q_seq(%rip)
    mov q_seq(%rip), %rax
    mov %rax, CN_QSEQ(%rbx)
    incq n_queued(%rip)
    LEAVE
9:  incq m_rejected(%rip)
    movq $CS_READ, CN_STATE(%rbx)
    mov $LV_WARN, %edi
    CSTR %rsi, "query rejected: overloaded"
    call log_simple
    mov %rbx, %rdi
    mov $E_OVERLOADED, %esi
    CSTR %rdx, "all workers are busy and the queue is full"
    call respond_error
    mov %rbx, %rdi
    call clear_query
    LEAVE
ENDF query_admit

/* find_query(id rdi) -> rax Conn* with a queued / running (unfinished)
 * query of that id, or 0 */
FUNC find_query
    ENTER 0
    mov %rdi, %r13
    mov conns(%rip), %rbx
    xor %r12d, %r12d
1:  cmp conn_hi(%rip), %r12
    jae 8f
    cmpq $QS_NONE, CN_QSTATE(%rbx)
    je 3f
    cmpq $QS_RUNNING, CN_QSTATE(%rbx)
    jne 2f
    mov %rbx, %rdi
    call conn_sh
    cmpq $0, SH_DONE(%rax)
    jne 3f
2:  mov CN_QID(%rbx), %rdi
    test %rdi, %rdi
    jz 3f
    mov %r13, %rsi
    call strcmp
    test %eax, %eax
    jz 9f
3:  add $CN_SIZE, %rbx
    inc %r12
    jmp 1b
8:  xor %ebx, %ebx
9:  mov %rbx, %rax
    LEAVE
ENDF find_query

/* start_child(c rdi) -> eax 0 if the catalog is busy (the query stays
 * QS_STARTING and is retried by dispatch), else 1: forks the query's process
 * (the catalog lock guarantees a consistent snapshot) */
FUNC start_child
    ENTER 0
    mov %rdi, %rbx
    lea cat_lock(%rip), %rdi
    call pthread_mutex_trylock
    test %eax, %eax
    jnz 7f
    decq n_starting(%rip)
    mov %rbx, %rdi
    call conn_sh
    movq $0, SH_DONE(%rax)
    movq $0, SH_STATUS(%rax)
    movq $0, SH_ROWS(%rax)
    movq $0, SH_WRITING(%rax)
    movq $QS_RUNNING, CN_QSTATE(%rbx)
    call fork
    test %eax, %eax
    jz 1f
    js 8f
    cltq
    mov %rax, CN_QPID(%rbx)
    lea cat_lock(%rip), %rdi
    call pthread_mutex_unlock
    mov $1, %eax
    LEAVE
1:  call chunk_pool_forget
    call par_after_fork
    mov %rbx, %rdi
    call child_main                 /* does not return */
7:  xor %eax, %eax
    LEAVE
8:  lea cat_lock(%rip), %rdi
    call pthread_mutex_unlock
    decq n_running(%rip)
    movq $QS_NONE, CN_QSTATE(%rbx)
    mov %rbx, %rdi
    mov $E_INTERNAL_ERROR, %esi
    CSTR %rdx, "cannot start the query process"
    call respond_error
    mov %rbx, %rdi
    call clear_query
    mov %rbx, %rdi
    call after_response
    mov $1, %eax
    LEAVE
ENDF start_child

/* pending_remove(c rdi): takes a queued / starting query out of admission */
FUNC pending_remove
    mov CN_QSTATE(%rdi), %rax
    cmp $QS_QUEUED, %rax
    jne 1f
    decq n_queued(%rip)
    jmp 9f
1:  cmp $QS_STARTING, %rax
    jne 9f
    decq n_running(%rip)
    decq n_starting(%rip)
9:  movq $QS_NONE, CN_QSTATE(%rdi)
    ret
ENDF pending_remove

/* queued_fail(c rdi, code esi, msg rdx): ends a not yet started query with
 * an error */
FUNC queued_fail
    ENTER 0
    mov %rdi, %rbx
    mov %esi, %r12d
    mov %rdx, %r13
    call pending_remove
    mov CN_QID(%rbx), %rdi
    mov CN_QSTART(%rbx), %rsi
    mov %r12, %rdx
    xor %ecx, %ecx
    call account_code
    mov %rbx, %rdi
    mov %r12d, %esi
    mov %r13, %rdx
    call respond_error
    mov %rbx, %rdi
    call clear_query
    movq $CS_READ, CN_STATE(%rbx)
    mov %rbx, %rdi
    call after_response
    LEAVE
ENDF queued_fail

/* after_response(c rdi): continue with the connection once its query ended */
FUNC after_response
    push %rbx
    mov %rdi, %rbx
    cmpq $0, CN_HUP(%rbx)
    jne 1f
    cmpq $0, CN_CLOSE(%rbx)
    jne 2f
    movq $CS_READ, CN_STATE(%rbx)
    call conn_process
    pop %rbx
    ret
1:  call conn_close
    pop %rbx
    ret
2:  call conn_linger
    pop %rbx
    ret
ENDF after_response

/* finish_query(c rdi): the query's child has exited */
FUNC finish_query
    ENTER 0
    mov %rdi, %rbx
    decq n_running(%rip)
    call account
    mov %rbx, %rdi
    call conn_sh
    mov %rax, %r12
    cmpq $0, SH_DONE(%r12)
    jne 5f
    /* killed: no (complete) response was written */
    cmpq $0, CN_HUP(%rbx)
    jne 4f
    cmpq $0, SH_WRITING(%r12)
    jne 4f
    mov CN_QKILL(%rbx), %rsi
    test %rsi, %rsi
    jnz 1f
    mov $E_CANCELLED, %esi
1:  CSTR %rdx, "query cancelled"
    cmp $E_TIMEOUT, %esi
    jne 2f
    CSTR %rdx, "query timeout exceeded"
2:  mov %rbx, %rdi
    call respond_error
    jmp 5f
4:  movq $1, CN_HUP(%rbx)           /* partial response: close */
5:  mov %rbx, %rdi
    call clear_query
    mov %rbx, %rdi
    call after_response
    LEAVE
ENDF finish_query

/* reap(): collects exited children */
FUNC reap
    ENTER 16
1:  mov $-1, %edi
    lea 0(%rsp), %rsi
    mov $1, %edx                    /* WNOHANG */
    call waitpid
    test %eax, %eax
    jle 9f
    cltq
    mov %rax, %r13
    mov conns(%rip), %rbx
    xor %r12d, %r12d
2:  cmp conn_hi(%rip), %r12
    jae 1b
    cmpq $QS_RUNNING, CN_QSTATE(%rbx)
    jne 3f
    cmp CN_QPID(%rbx), %r13
    jne 3f
    mov %rbx, %rdi
    call finish_query
    jmp 1b
3:  add $CN_SIZE, %rbx
    inc %r12
    jmp 2b
9:  LEAVE
ENDF reap

/* dispatch(): forks admitted queries waiting for the catalog lock, then
 * starts queued queries (FIFO) while workers are free */
FUNC dispatch
    ENTER 0
    cmpq $0, n_starting(%rip)
    je 1f
    mov conns(%rip), %rbx
    xor %r12d, %r12d
81: cmp conn_hi(%rip), %r12
    jae 1f
    cmpq $QS_STARTING, CN_QSTATE(%rbx)
    jne 82f
    mov %rbx, %rdi
    call start_child
    test %eax, %eax
    jz 9f                           /* catalog busy: retry later */
82: add $CN_SIZE, %rbx
    inc %r12
    jmp 81b
1:  cmpq $0, n_queued(%rip)
    je 9f
    mov n_running(%rip), %rax
    cmp g_srv_workers(%rip), %rax
    jae 9f
    mov conns(%rip), %rbx
    xor %r12d, %r12d
    xor %r13d, %r13d                /* best */
2:  cmp conn_hi(%rip), %r12
    jae 4f
    cmpq $QS_QUEUED, CN_QSTATE(%rbx)
    jne 3f
    test %r13, %r13
    jz 21f
    mov CN_QSEQ(%rbx), %rax
    cmp CN_QSEQ(%r13), %rax
    jae 3f
21: mov %rbx, %r13
3:  add $CN_SIZE, %rbx
    inc %r12
    jmp 2b
4:  test %r13, %r13
    jz 9f
    decq n_queued(%rip)
    incq n_running(%rip)
    incq n_starting(%rip)
    movq $QS_STARTING, CN_QSTATE(%r13)
    mov %r13, %rdi
    call start_child
    test %eax, %eax
    jnz 1b
9:  LEAVE
ENDF dispatch

/* check_timers(): queued deadlines, kill escalation, lingering closes and
 * the shutdown grace period */
FUNC check_timers
    ENTER 16
    call now_ns
    mov %rax, %r14
    /* grace period over: cancel everything still running */
    cmpq $0, shutting(%rip)
    je 1f
    cmpq $0, grace_fired(%rip)
    jne 1f
    cmp grace_dl(%rip), %r14
    jb 1f
    movq $1, grace_fired(%rip)
    mov $LV_WARN, %edi
    CSTR %rsi, "shutdown grace period expired: cancelling queries"
    call log_simple
1:  mov conns(%rip), %rbx
    xor %r12d, %r12d
2:  cmp conn_hi(%rip), %r12
    jae 9f
    mov CN_STATE(%rbx), %rax
    cmp $CS_DRAIN, %rax
    jne 3f
    cmp CN_DRAINDL(%rbx), %r14
    jb 8f
    mov %rbx, %rdi
    call conn_close
    jmp 8f
3:  cmp $CS_BUSY, %rax
    jne 8f
    mov CN_QSTATE(%rbx), %rax
    cmp $QS_STARTING, %rax
    je 31f
    cmp $QS_QUEUED, %rax
    jne 5f
31: cmpq $0, grace_fired(%rip)
    je 4f
    mov %rbx, %rdi
    mov $E_CANCELLED, %esi
    CSTR %rdx, "query cancelled: server shutting down"
    call queued_fail
    jmp 8f
4:  mov CN_QDL(%rbx), %rax
    test %rax, %rax
    jz 8f
    cmp %rax, %r14
    jb 8f
    mov %rbx, %rdi
    mov $E_TIMEOUT, %esi
    CSTR %rdx, "query timeout exceeded while queued"
    call queued_fail
    jmp 8f
5:  cmp $QS_RUNNING, %rax
    jne 8f
    cmpq $0, CN_QKILL(%rbx)
    jne 8f
    mov %rbx, %rdi
    call conn_sh
    cmpq $0, SH_DONE(%rax)
    jne 8f
    cmpq $0, grace_fired(%rip)      /* shutdown: cancel cooperatively first */
    je 51f
    cmpq $0, CN_QCANCEL(%rbx)
    jne 51f
    mov %r14, CN_QCANCEL(%rbx)
    mov CN_QPID(%rbx), %rdi
    mov $SIGUSR1_, %esi
    call kill
51: mov CN_QDL(%rbx), %rax          /* child ignores its deadline: kill */
    test %rax, %rax
    jz 6f
    add $KILL_AFTER, %rax
    cmp %rax, %r14
    jb 6f
    movq $E_TIMEOUT, CN_QKILL(%rbx)
    jmp 7f
6:  mov CN_QCANCEL(%rbx), %rax
    test %rax, %rax
    jz 8f
    add $KILL_AFTER, %rax
    cmp %rax, %r14
    jb 8f
    movq $E_CANCELLED, CN_QKILL(%rbx)
7:  mov CN_QPID(%rbx), %rdi
    mov $SIGKILL_, %esi
    call kill
8:  add $CN_SIZE, %rbx
    inc %r12
    jmp 2b
9:  LEAVE
ENDF check_timers

/* ================================================================ endpoints */

/* handle_cancel(c rdi, id rsi): DELETE /v1/queries/{id} */
FUNC handle_cancel
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    call harvest
    mov %r12, %rdi
    call find_query
    test %rax, %rax
    jz 8f
    mov %rax, %r13
    cmpq $QS_STARTING, CN_QSTATE(%r13)
    je 83f
    cmpq $QS_QUEUED, CN_QSTATE(%r13)
    jne 1f
83:
    mov %r13, %rdi
    mov $E_CANCELLED, %esi
    CSTR %rdx, "query cancelled"
    call queued_fail
    jmp 2f
1:  cmpq $0, CN_QCANCEL(%r13)
    jne 2f
    call now_ns
    mov %rax, CN_QCANCEL(%r13)
    mov CN_QPID(%r13), %rdi
    mov $SIGUSR1_, %esi
    call kill
2:  mov $LV_INFO, %edi
    CSTR %rsi, "query cancellation requested"
    call log_begin
    test %eax, %eax
    jz 3f
    lea log_buf(%rip), %r15
    PUTS %r15, ",\"query_id\":"
    mov %r12, %rdi
    call strlen
    mov %r15, %rdi
    mov %r12, %rsi
    mov %rax, %rdx
    call buf_put_json_str
    call log_end
3:  mov %rbx, %rdi
    mov $200, %esi
    CSTR %rdx, "{\"ok\":true,\"cancelled\":true}"
    call respond_cstr
    LEAVE
8:  mov %rbx, %rdi
    mov $E_NOT_FOUND, %esi
    CSTR %rdx, "no queued or running query with this id"
    call respond_error
    LEAVE
ENDF handle_cancel

/* handle_queries(c rdi): GET /v1/queries */
FUNC handle_queries
    ENTER 16
    mov %rdi, 0(%rsp)
    call harvest
    call now_ns
    mov %rax, %r14
    lea srv_buf(%rip), %r15
    movq $0, BUF_LEN(%r15)
    PUTS %r15, "{\"ok\":true,\"queries\":["
    mov conns(%rip), %rbx
    xor %r12d, %r12d
    xor %r13d, %r13d                /* listed */
1:  cmp conn_hi(%rip), %r12
    jae 9f
    mov CN_QSTATE(%rbx), %rax
    cmp $QS_QUEUED, %rax
    je 2f
    cmp $QS_STARTING, %rax
    je 2f
    cmp $QS_RUNNING, %rax
    jne 8f
    mov %rbx, %rdi
    call conn_sh
    cmpq $0, SH_DONE(%rax)
    jne 8f
2:  test %r13, %r13
    jz 3f
    PUTS %r15, ","
3:  inc %r13
    PUTS %r15, "{\"query_id\":"
    mov CN_QID(%rbx), %rdi
    call strlen
    mov %r15, %rdi
    mov CN_QID(%rbx), %rsi
    mov %rax, %rdx
    call buf_put_json_str
    PUTS %r15, ",\"state\":\""
    CSTR %rsi, "running"
    cmpq $QS_QUEUED, CN_QSTATE(%rbx)
    jne 4f
    CSTR %rsi, "queued"
4:  mov %r15, %rdi
    call buf_puts
    PUTS %r15, "\",\"elapsed_ms\":"
    mov %r14, %rax
    sub CN_QSTART(%rbx), %rax
    xor %edx, %edx
    mov $NS_PER_MS, %ecx
    div %rcx
    mov %r15, %rdi
    mov %rax, %rsi
    call buf_put_u64
    PUTS %r15, "}"
8:  add $CN_SIZE, %rbx
    inc %r12
    jmp 1b
9:  PUTS %r15, "]}"
    mov 0(%rsp), %rdi
    mov $200, %esi
    mov %r15, %rdx
    call respond_buf
    LEAVE
ENDF handle_queries

/* metric_u64(buf rdi, type rsi, name rdx, value rcx): "# TYPE" + sample */
FUNC metric_u64
    ENTER 0
    mov %rdi, %r15
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rcx, %r14
    PUTS %r15, "# TYPE "
    mov %r15, %rdi
    mov %r13, %rsi
    call buf_puts
    mov %r15, %rdi
    mov $' ', %esi
    call buf_putc
    mov %r15, %rdi
    mov %r12, %rsi
    call buf_puts
    mov %r15, %rdi
    mov $'\n', %esi
    call buf_putc
    mov %r15, %rdi
    mov %r13, %rsi
    call buf_puts
    mov %r15, %rdi
    mov $' ', %esi
    call buf_putc
    mov %r15, %rdi
    mov %r14, %rsi
    call buf_put_u64
    mov %r15, %rdi
    mov $'\n', %esi
    call buf_putc
    LEAVE
ENDF metric_u64

/* handle_metrics(c rdi): GET /metrics (Prometheus text format 0.0.4) */
FUNC handle_metrics
    ENTER 16
    mov %rdi, 0(%rsp)
    call harvest
    /* running (unfinished) queries */
    xor %r13d, %r13d
    mov conns(%rip), %rbx
    xor %r12d, %r12d
1:  cmp conn_hi(%rip), %r12
    jae 2f
    cmpq $QS_STARTING, CN_QSTATE(%rbx)
    je 12f
    cmpq $QS_RUNNING, CN_QSTATE(%rbx)
    jne 11f
    mov %rbx, %rdi
    call conn_sh
    cmpq $0, SH_DONE(%rax)
    jne 11f
12: inc %r13
11: add $CN_SIZE, %rbx
    inc %r12
    jmp 1b
2:  lea srv_buf(%rip), %r15
    movq $0, BUF_LEN(%r15)
    PUTS %r15, "# HELP polyquery_queries_total Finished queries by status.\n"
    PUTS %r15, "# TYPE polyquery_queries_total counter\n"
    PUTS %r15, "polyquery_queries_total{status=\"ok\"} "
    mov %r15, %rdi
    mov m_ok(%rip), %rsi
    call buf_put_u64
    PUTS %r15, "\npolyquery_queries_total{status=\"error\"} "
    mov %r15, %rdi
    mov m_err(%rip), %rsi
    call buf_put_u64
    PUTS %r15, "\n"
    mov %r15, %rdi
    CSTR %rsi, "gauge"
    CSTR %rdx, "polyquery_queries_in_flight"
    mov %r13, %rcx
    call metric_u64
    mov %r15, %rdi
    CSTR %rsi, "gauge"
    CSTR %rdx, "polyquery_queries_queued"
    mov n_queued(%rip), %rcx
    call metric_u64
    mov %r15, %rdi
    CSTR %rsi, "counter"
    CSTR %rdx, "polyquery_queries_rejected_total"
    mov m_rejected(%rip), %rcx
    call metric_u64
    mov %r15, %rdi
    CSTR %rsi, "counter"
    CSTR %rdx, "polyquery_queries_cancelled_total"
    mov m_cancelled(%rip), %rcx
    call metric_u64
    mov %r15, %rdi
    CSTR %rsi, "counter"
    CSTR %rdx, "polyquery_queries_timeout_total"
    mov m_timeout(%rip), %rcx
    call metric_u64
    PUTS %r15, "# TYPE polyquery_query_duration_seconds summary\n"
    PUTS %r15, "polyquery_query_duration_seconds_sum "
    cvtsi2sdq m_dur_ns(%rip), %xmm0
    mov $1000000000, %eax
    cvtsi2sd %rax, %xmm1
    divsd %xmm1, %xmm0
    mov %r15, %rdi
    CSTR %rsi, "%.6f"
    call buf_put_double
    PUTS %r15, "\npolyquery_query_duration_seconds_count "
    mov %r15, %rdi
    mov m_dur_cnt(%rip), %rsi
    call buf_put_u64
    PUTS %r15, "\n"
    call cat_count
    mov %r15, %rdi
    CSTR %rsi, "gauge"
    CSTR %rdx, "polyquery_tables"
    mov %rax, %rcx
    call metric_u64
    PUTS %r15, "# TYPE polyquery_uptime_seconds gauge\npolyquery_uptime_seconds "
    call now_ns
    sub start_ns(%rip), %rax
    cvtsi2sd %rax, %xmm0
    mov $1000000000, %eax
    cvtsi2sd %rax, %xmm1
    divsd %xmm1, %xmm0
    mov %r15, %rdi
    CSTR %rsi, "%.3f"
    call buf_put_double
    PUTS %r15, "\n"
    mov %r15, %rdi
    CSTR %rsi, "gauge"
    CSTR %rdx, "polyquery_workers"
    mov g_srv_workers(%rip), %rcx
    call metric_u64
    mov 0(%rsp), %rdi
    mov $200, %esi
    lea ctype_text(%rip), %rdx
    mov BUF_DATA(%r15), %rcx
    mov BUF_LEN(%r15), %r8
    call respond
    LEAVE
ENDF handle_metrics

/* ================================================================ child */

/* child_sigusr1(sig): cancellation request */
FUNC child_sigusr1
    movq $1, g_cancel_flag(%rip)
    ret
ENDF child_sigusr1

/* child_finish(status rdi, rows rsi): publishes the final result in the
 * shared record (before the response is written) */
FUNC child_finish
    sub $8, %rsp
    push %rdi
    push %rsi
    mov child_conn(%rip), %rdi
    call conn_sh
    pop %rsi
    pop %rdi
    mov %rdi, SH_STATUS(%rax)
    mov %rsi, SH_ROWS(%rax)
    movq $1, SH_WRITING(%rax)
    movq $1, SH_DONE(%rax)
    add $8, %rsp
    ret
ENDF child_finish

/* child_main(c rdi): runs the connection's query in the forked process,
 * writes the response to the socket and exits */
FUNC child_main
    ENTER 160
    mov %rdi, %rbx
    mov %rdi, child_conn(%rip)
    /* keep only stdio and the client socket */
    mov CN_FD(%rbx), %r12
    cmp $3, %r12d
    jbe 1f
    mov $3, %edi
    lea -1(%r12), %esi
    xor %edx, %edx
    call close_range
1:  lea 1(%r12), %edi
    mov $-1, %esi
    xor %edx, %edx
    call close_range
    /* SIGUSR1 = cancel */
    lea 0(%rsp), %rdi
    xor %esi, %esi
    mov $152, %edx
    call memset
    lea child_sigusr1(%rip), %rax
    mov %rax, 0(%rsp)
    movl $0x10000000, 136(%rsp)     /* SA_RESTART */
    mov $SIGUSR1_, %edi
    lea 0(%rsp), %rsi
    xor %edx, %edx
    call sigaction
    /* fresh request state: the catalog worker may have been using the
     * shared globals when this process was forked */
    movq $0, g_cat_threaded(%rip)
    movq $0, g_pending_arena(%rip)
    movq $0, g_pending_map(%rip)
    lea g_out(%rip), %rdi
    call buf_init
    call arena_new
    mov %rax, g_arena(%rip)
    mov CN_QBODY(%rbx), %rdi
    mov CN_QBLEN(%rbx), %rsi
    mov g_arena(%rip), %rdx
    call json_parse
    mov %rax, %r13
    mov CN_QDL(%rbx), %rax
    mov %rax, g_forced_deadline(%rip)
    mov CN_QID(%rbx), %rax
    mov %rax, g_resp_qid(%rip)
    cmpq $QK_STREAM, CN_QKIND(%rbx)
    jne 2f
    mov %rbx, %rdi
    mov %r13, %rsi
    call child_stream               /* does not return */
2:  movq $1, g_http_capture(%rip)
    movq $0, g_force_op(%rip)
    cmpq $QK_QUERY, CN_QKIND(%rbx)
    jne 3f
    lea op_query_s(%rip), %rax
    mov %rax, g_force_op(%rip)
3:  mov %r13, %rdi
    call handle_request_noreset
    mov g_req_status(%rip), %rdi
    mov g_result_rows(%rip), %rsi
    call child_finish
    mov $200, %r14d
    mov g_req_status(%rip), %rdi
    test %rdi, %rdi
    jz 4f
    call http_status_for
    mov %eax, %r14d
4:  xor %r9d, %r9d
    cmpq $0, CN_CLOSE(%rbx)
    je 5f
    mov $HS_CLOSE, %r9d
5:  mov CN_FD(%rbx), %edi
    mov %r14d, %esi
    lea ctype_json(%rip), %rdx
    mov g_out+BUF_DATA(%rip), %rcx
    mov g_out+BUF_LEN(%rip), %r8
    call http_send
    xor %edi, %edi
    call _exit
ENDF child_main

/* stream_chunk(fd edi): sends g_out as one chunk; exits if the client is gone */
FUNC stream_chunk
    sub $8, %rsp
    mov g_out+BUF_DATA(%rip), %rsi
    mov g_out+BUF_LEN(%rip), %rdx
    call http_send_chunk
    test %eax, %eax
    jnz 1f
    movq $0, g_out+BUF_LEN(%rip)
    add $8, %rsp
    ret
1:  mov $1, %edi
    call _exit
ENDF stream_chunk

#define STREAM_BATCH 1000
/* child_stream(c rdi, node rsi): POST /v1/query/stream - NDJSON header,
 * row batches (<= STREAM_BATCH rows) and end line, chunked.  Queries
 * without ORDER BY / aggregation / DISTINCT are streamed while they execute
 * (stream_sink); others are materialized first.  The header is sent with
 * the first batch, so errors before that get an ordinary error response. */
FUNC child_stream
    ENTER 48
    mov %rdi, %rbx
    mov %rsi, %r13
    mov CN_FD(%rbx), %r12
    movq $0, stream_hdr(%rip)
    lea jb_stream(%rip), %rdi
    mov %rdi, g_jmpbuf(%rip)
    call _setjmp
    test %eax, %eax
    jnz cs_error
    test %r13, %r13
    jz cs_invalid
    cmpq $J_OBJECT, JN_TYPE(%r13)
    jne cs_invalid
    mov %r13, %rdi
    call query_setup
    mov %rax, %r14                  /* statement */
    mov ST_KIND(%r14), %rax
    cmp $STMT_QUERY, %rax
    je 1f
    cmp $STMT_EXPLAIN, %rax
    je 10f
    RAISE E_UNSUPPORTED, "statement not supported on the streaming endpoint"
1:  mov ST_QUERY(%r14), %rdi
    call bind_statement
    mov %rax, %r15                  /* plan */
    mov %r15, ss_plan(%rip)
    mov %r15, %rdi
    call cs_head
    lea g_out(%rip), %r13
    movq $0, BUF_LEN(%r13)
    cmpq $0, QP_AGG(%r15)
    jne 20f
    cmpq $0, QP_NUNION(%r15)        /* UNION ALL: materialized */
    jne 20f
    cmpq $0, QP_NKEYS(%r15)
    jne 20f
    cmpq $0, QP_DISTINCT(%r15)
    jne 20f
    /* ---- pipelined: rows go to stream_sink as they are projected */
    mov QP_OFFSET(%r15), %rax
    mov %rax, ss_offset(%rip)
    mov QP_LIMIT(%r15), %rax
    mov %rax, ss_limit(%rip)
    lea stream_sink(%rip), %rax
    mov %rax, g_row_sink(%rip)
    mov %r15, g_sink_plan(%rip)
    mov %r15, %rdi
    xor %esi, %esi
    call exec_plan
    movq $0, g_sink_plan(%rip)
    call stream_flush
    mov ss_emitted(%rip), %rax
    mov %rax, 16(%rsp)
    jmp 5f
20: /* ---- materialized */
    mov %r15, %rdi
    mov g_q_max_rows(%rip), %rsi
    call exec_query_result
    mov %rax, 0(%rsp)               /* result */
    movq $0, 8(%rsp)                /* next row */
2:  mov 0(%rsp), %rax
    mov 8(%rsp), %rcx
    cmp RS_NROWS(%rax), %rcx
    jae 4f
    call check_deadline
    mov 0(%rsp), %rax
    mov RS_ROWS(%rax), %rax
    mov 8(%rsp), %rcx
    mov (%rax, %rcx, 8), %rsi
    call stream_add_row
    incq 8(%rsp)
    cmpq $STREAM_BATCH, ss_batch(%rip)
    jb 2b
    call stream_flush
    jmp 2b
4:  call stream_flush
    mov 0(%rsp), %rax
    mov RS_NROWS(%rax), %rax
    mov %rax, 16(%rsp)
5:  cmpq $0, stream_hdr(%rip)       /* no rows: the header still goes first */
    jne 51f
    call cs_begin
51: PUTS %r13, "{\"type\":\"end\",\"row_count\":"
    mov %r13, %rdi
    mov 16(%rsp), %rsi
    call buf_put_u64
    PUTS %r13, "}\n"
    xor %edi, %edi
    mov 16(%rsp), %rsi
    call child_finish
    jmp cs_end
10: /* EXPLAIN: one STRING column "plan" */
    mov ST_QUERY(%r14), %rdi
    call bind_statement
    mov %rax, %r15
    lea 24(%rsp), %rdi
    call buf_init
    mov %r15, %rdi
    lea 24(%rsp), %rsi
    call explain_plan
    lea ss_head(%rip), %r13
    movq $0, BUF_LEN(%r13)
    PUTS %r13, "{\"type\":\"header\",\"query_id\":"
    mov CN_QID(%rbx), %rdi
    call strlen
    mov %r13, %rdi
    mov CN_QID(%rbx), %rsi
    mov %rax, %rdx
    call buf_put_json_str
    PUTS %r13, ",\"columns\":[{\"name\":\"plan\",\"type\":\"STRING\"}]}\n"
    call cs_begin
    lea g_out(%rip), %r13
    movq $0, BUF_LEN(%r13)
    PUTS %r13, "{\"type\":\"rows\",\"rows\":[["
    mov %r13, %rdi
    mov 24+BUF_DATA(%rsp), %rsi
    mov 24+BUF_LEN(%rsp), %rdx
    call buf_put_json_str
    PUTS %r13, "]]}\n"
    mov %r12d, %edi
    call stream_chunk
    PUTS %r13, "{\"type\":\"end\",\"row_count\":1}\n"
    xor %edi, %edi
    mov $1, %esi
    call child_finish
cs_end:
    mov %r12d, %edi
    call stream_chunk
    mov %r12d, %edi
    xor %esi, %esi
    xor %edx, %edx
    call http_send_chunk            /* last chunk */
    xor %edi, %edi
    call _exit
cs_invalid:
    RAISE E_INVALID_REQUEST, "request body must be a JSON object"
cs_error:
    movq $0, g_sink_plan(%rip)
    mov child_conn(%rip), %rbx
    mov CN_FD(%rbx), %r12
    lea g_out(%rip), %r13
    movq $0, BUF_LEN(%r13)
    cmpq $0, stream_hdr(%rip)
    jne 30f
    /* nothing sent yet: an ordinary error response */
    PUTS %r13, "{\"id\":null,\"ok\":false,\"error\":"
    mov %r13, %rdi
    call proto_put_error
    mov %rax, %r14
    PUTS %r13, "}"
    mov %r14, %rdi
    xor %esi, %esi
    call child_finish
    mov %r14d, %edi
    call http_status_for
    xor %r9d, %r9d
    cmpq $0, CN_CLOSE(%rbx)
    je 11f
    mov $HS_CLOSE, %r9d
11: mov %r12d, %edi
    mov %eax, %esi
    lea ctype_json(%rip), %rdx
    mov g_out+BUF_DATA(%rip), %rcx
    mov g_out+BUF_LEN(%rip), %r8
    call http_send
    xor %edi, %edi
    call _exit
30: /* after the header: a final error line, no end line */
    PUTS %r13, "{\"type\":\"error\",\"error\":"
    mov %r13, %rdi
    call proto_put_error
    mov %rax, %r14
    PUTS %r13, "}\n"
    mov %r14, %rdi
    xor %esi, %esi
    call child_finish
    jmp cs_end
ENDF child_stream

/* cs_head(plan rdi): builds the header line in ss_head */
FUNC cs_head
    ENTER 0
    mov %rdi, %r12
    mov child_conn(%rip), %rbx
    lea ss_head(%rip), %r13
    movq $0, BUF_LEN(%r13)
    PUTS %r13, "{\"type\":\"header\",\"query_id\":"
    mov CN_QID(%rbx), %rdi
    call strlen
    mov %r13, %rdi
    mov CN_QID(%rbx), %rsi
    mov %rax, %rdx
    call buf_put_json_str
    mov %r13, %rdi
    mov $',', %esi
    call buf_putc
    mov %r12, %rdi
    mov %r13, %rsi
    call exec_put_columns
    PUTS %r13, "}\n"
    LEAVE
ENDF cs_head

/* stream_add_row(row rsi): appends a row to the batch in g_out */
FUNC stream_add_row
    ENTER 0
    mov %rsi, %rbx
    lea g_out(%rip), %r15
    cmpq $0, ss_batch(%rip)
    jne 1f
    PUTS %r15, "{\"type\":\"rows\",\"rows\":["
    jmp 2f
1:  mov %r15, %rdi
    mov $',', %esi
    call buf_putc
2:  mov ss_plan(%rip), %rdi
    mov %rbx, %rsi
    mov %r15, %rdx
    call exec_put_row
    incq ss_batch(%rip)
    LEAVE
ENDF stream_add_row

/* stream_flush(): sends the batch in g_out (and before it the header) */
FUNC stream_flush
    sub $8, %rsp
    cmpq $0, ss_batch(%rip)
    je 9f
    cmpq $0, stream_hdr(%rip)
    jne 1f
    call cs_begin
1:  lea g_out(%rip), %rdi
    CSTR %rsi, "]}\n"
    call buf_puts
    movq $0, ss_batch(%rip)
    mov child_conn(%rip), %rax
    mov CN_FD(%rax), %edi
    call stream_chunk
9:  add $8, %rsp
    ret
ENDF stream_flush

/* stream_sink(row rdi) -> eax 1 when LIMIT is reached: row sink of a
 * pipelined streamed query (applies OFFSET / LIMIT and max_rows) */
FUNC stream_sink
    ENTER 0
    mov %rdi, %rbx
    incq ss_seen(%rip)
    mov ss_seen(%rip), %rax
    cmp ss_offset(%rip), %rax
    jbe 8f
    incq ss_emitted(%rip)
    mov g_q_max_rows(%rip), %rcx
    test %rcx, %rcx
    js 1f
    cmp %rcx, ss_emitted(%rip)
    jbe 1f
    RAISE E_RESOURCE_LIMIT, "result exceeds max_rows"
1:  mov %rbx, %rsi
    call stream_add_row
    cmpq $STREAM_BATCH, ss_batch(%rip)
    jb 2f
    call stream_flush
2:  mov ss_limit(%rip), %rax
    test %rax, %rax
    js 8f
    cmp %rax, ss_emitted(%rip)
    jb 8f
    mov $1, %eax
    LEAVE
8:  xor %eax, %eax
    LEAVE
ENDF stream_sink

/* cs_begin(): sends the response head and the header line (ss_head) */
FUNC cs_begin
    push %rbx
    mov child_conn(%rip), %rdi
    call conn_sh
    movq $1, SH_WRITING(%rax)
    mov child_conn(%rip), %rbx
    mov CN_FD(%rbx), %edi
    lea ctype_ndjson(%rip), %rsi
    call http_send_head_chunked
    test %eax, %eax
    jnz 1f
    movq $1, stream_hdr(%rip)
    mov CN_FD(%rbx), %edi
    mov ss_head+BUF_DATA(%rip), %rsi
    mov ss_head+BUF_LEN(%rip), %rdx
    call http_send_chunk
    test %eax, %eax
    jnz 1f
    pop %rbx
    ret
1:  mov $1, %edi
    call _exit
ENDF cs_begin

/* ================================================================ main loop */

/* begin_shutdown() */
FUNC begin_shutdown
    sub $8, %rsp
    cmpq $0, shutting(%rip)
    jne 9f
    movq $1, shutting(%rip)
    call now_ns
    mov g_srv_grace_ms(%rip), %rcx
    imul $NS_PER_MS, %rcx, %rcx
    add %rcx, %rax
    mov %rax, grace_dl(%rip)
    mov listen_fd(%rip), %edi
    call close
    movq $-1, listen_fd(%rip)
    mov $LV_INFO, %edi
    CSTR %rsi, "shutdown requested: draining queries"
    call log_simple
9:  add $8, %rsp
    ret
ENDF begin_shutdown

/* handle_signals(): reads the signalfd */
FUNC handle_signals
    ENTER 128
1:  mov sig_fd(%rip), %edi
    lea 0(%rsp), %rsi
    mov $128, %edx
    call read
    cmp $128, %rax
    jne 9f
    mov 0(%rsp), %eax               /* ssi_signo */
    cmp $SIGCHLD_, %eax
    je 2f
    call begin_shutdown
    jmp 9f
2:  call reap
9:  call reap                       /* SIGCHLD may coalesce */
    LEAVE
ENDF handle_signals

/* serve_exit(): final cleanup, exit 0 */
FUNC serve_exit
    sub $8, %rsp
    /* kill whatever is left (grace expired) */
    mov conns(%rip), %rbx
    xor %r12d, %r12d
1:  cmp conn_hi(%rip), %r12
    jae 2f
    cmpq $QS_RUNNING, CN_QSTATE(%rbx)
    jne 11f
    mov CN_QPID(%rbx), %rdi
    mov $SIGKILL_, %esi
    call kill
11: add $CN_SIZE, %rbx
    inc %r12
    jmp 1b
2:  mov $LV_INFO, %edi
    CSTR %rsi, "server stopped"
    call log_simple
    xor %edi, %edi
    call exit
ENDF serve_exit

/* serve_main(): binds, prints the listening event and runs the loop */
FUNC serve_main
    ENTER 256
    call now_ns
    mov %rax, start_ns(%rip)
    movq $1, g_http_capture(%rip)
    cmpq $0, g_srv_workers(%rip)
    jne 1f
    mov $84, %edi                   /* _SC_NPROCESSORS_ONLN */
    call sysconf
    cmp $1, %rax
    jge 97f
    mov $1, %eax
97: mov %rax, g_srv_workers(%rip)
1:  cmpq $0, g_srv_host(%rip)
    jne 2f
    CSTR %rax, "127.0.0.1"
    mov %rax, g_srv_host(%rip)
2:  /* sockaddr_in at 0(%rsp) */
    lea 0(%rsp), %rdi
    xor %esi, %esi
    mov $16, %edx
    call memset
    movw $2, 0(%rsp)                /* AF_INET */
    mov g_srv_port(%rip), %rax
    xchg %al, %ah                   /* htons */
    mov %ax, 2(%rsp)
    mov $2, %edi
    mov g_srv_host(%rip), %rsi
    lea 4(%rsp), %rdx
    call inet_pton
    cmp $1, %eax
    je 3f
    mov g_srv_host(%rip), %rdi
    CSTR %rsi, "localhost"
    call strcmp
    test %eax, %eax
    jnz s_badhost
    movl $0x0100007f, 4(%rsp)
3:  mov $2, %edi                    /* AF_INET */
    mov $1, %esi                    /* SOCK_STREAM */
    xor %edx, %edx
    call socket
    test %eax, %eax
    js s_fatal
    mov %rax, listen_fd(%rip)
    movl $1, 32(%rsp)
    mov listen_fd(%rip), %edi
    mov $1, %esi                    /* SOL_SOCKET */
    mov $2, %edx                    /* SO_REUSEADDR */
    lea 32(%rsp), %rcx
    mov $4, %r8d
    call setsockopt
    mov listen_fd(%rip), %edi
    lea 0(%rsp), %rsi
    mov $16, %edx
    call bind
    test %eax, %eax
    jnz s_fatal
    mov listen_fd(%rip), %edi
    mov $1024, %esi
    call listen
    test %eax, %eax
    jnz s_fatal
    movl $16, 32(%rsp)
    mov listen_fd(%rip), %edi
    lea 0(%rsp), %rsi
    lea 32(%rsp), %rdx
    call getsockname
    movzwl 2(%rsp), %eax
    xchg %al, %ah
    mov %rax, g_srv_port(%rip)
    /* state */
    mov $MAX_CONN, %edi
    mov $CN_SIZE, %esi
    call calloc
    mov %rax, conns(%rip)
    mov $(MAX_CONN + 2), %edi
    mov $8, %esi
    call calloc
    mov %rax, pfds(%rip)
    mov $(MAX_CONN + 2), %edi
    mov $8, %esi
    call calloc
    mov %rax, pmap(%rip)
    xor %edi, %edi
    mov $(MAX_CONN * SH_SIZE), %esi
    mov $3, %edx                    /* PROT_READ | PROT_WRITE */
    mov $0x21, %ecx                 /* MAP_SHARED | MAP_ANONYMOUS */
    mov $-1, %r8d
    xor %r9d, %r9d
    call mmap
    cmp $-1, %rax
    je s_fatal
    mov %rax, shm(%rip)
    /* signals: SIGCHLD, SIGTERM, SIGINT through a signalfd */
    lea 64(%rsp), %rdi
    call sigemptyset
    lea 64(%rsp), %rdi
    mov $SIGCHLD_, %esi
    call sigaddset
    lea 64(%rsp), %rdi
    mov $SIGTERM_, %esi
    call sigaddset
    lea 64(%rsp), %rdi
    mov $SIGINT_, %esi
    call sigaddset
    xor %edi, %edi                  /* SIG_BLOCK */
    lea 64(%rsp), %rsi
    xor %edx, %edx
    call sigprocmask
    mov $-1, %edi
    lea 64(%rsp), %rsi
    xor %edx, %edx
    call signalfd
    test %eax, %eax
    js s_fatal
    mov %rax, sig_fd(%rip)
    /* catalog worker thread */
    call arena_new
    mov %rax, net_arena(%rip)
    mov $JOBQ_SIZE, %edi
    mov $8, %esi
    call calloc
    mov %rax, jobq(%rip)
    lea 32(%rsp), %rdi
    call pipe
    test %eax, %eax
    jnz s_fatal
    movslq 32(%rsp), %rax
    mov %rax, done_r(%rip)
    movslq 36(%rsp), %rax
    mov %rax, done_w(%rip)
    movq $1, g_cat_threaded(%rip)
    lea 192(%rsp), %rdi             /* pthread_attr_t (56 bytes) */
    call pthread_attr_init
    lea 192(%rsp), %rdi
    mov $WORKER_STACK, %esi
    call pthread_attr_setstacksize
    lea 40(%rsp), %rdi              /* pthread_t */
    lea 192(%rsp), %rsi
    lea cw_main(%rip), %rdx
    xor %ecx, %ecx
    call pthread_create
    test %eax, %eax
    jnz s_fatal
    /* {"event":"listening",...} on stdout */
    lea srv_buf(%rip), %r15
    movq $0, BUF_LEN(%r15)
    PUTS %r15, "{\"event\":\"listening\",\"host\":"
    mov g_srv_host(%rip), %rdi
    call strlen
    mov %r15, %rdi
    mov g_srv_host(%rip), %rsi
    mov %rax, %rdx
    call buf_put_json_str
    PUTS %r15, ",\"port\":"
    mov %r15, %rdi
    mov g_srv_port(%rip), %rsi
    call buf_put_u64
    PUTS %r15, "}\n"
    mov $1, %edi
    mov BUF_DATA(%r15), %rsi
    mov BUF_LEN(%r15), %rdx
    call write
    mov $LV_INFO, %edi
    CSTR %rsi, "listening"
    call log_begin
    test %eax, %eax
    jz 4f
    lea log_buf(%rip), %r15
    PUTS %r15, ",\"port\":"
    mov %r15, %rdi
    mov g_srv_port(%rip), %rsi
    call buf_put_u64
    PUTS %r15, ",\"workers\":"
    mov %r15, %rdi
    mov g_srv_workers(%rip), %rsi
    call buf_put_u64
    PUTS %r15, ",\"queue_depth\":"
    mov %r15, %rdi
    mov g_srv_queue(%rip), %rsi
    call buf_put_u64
    call log_end
4:  call serve_loop
    LEAVE
s_badhost:
    mov $LV_ERROR, %edi
    CSTR %rsi, "invalid --host (IPv4 address expected)"
    call log_simple
    mov $2, %edi
    call exit
s_fatal:
    mov $LV_ERROR, %edi
    CSTR %rsi, "cannot start the server (socket / bind / listen failed)"
    call log_simple
    mov $1, %edi
    call exit
ENDF serve_main

/* serve_loop(): the poll() event loop; returns only through serve_exit */
FUNC serve_loop
    ENTER 16
s_top:
    call harvest
    call dispatch
    cmpq $0, shutting(%rip)
    je 1f
    cmpq $0, n_running(%rip)
    jne 97f
    cmpq $0, n_queued(%rip)
    jne 97f
    cmpq $0, n_inline(%rip)
    jne 97f
    call serve_exit
97: cmpq $0, grace_fired(%rip)      /* grace expired and cancels ignored */
    je 1f
    call now_ns
    mov grace_dl(%rip), %rcx
    add $(2 * KILL_AFTER), %rcx
    cmp %rcx, %rax
    jb 1f
    call serve_exit
1:  /* poll set */
    mov pfds(%rip), %r12
    mov pmap(%rip), %r13
    xor %r14d, %r14d                /* entries */
    mov sig_fd(%rip), %eax
    mov %eax, (%r12)
    movl $1, 4(%r12)                /* POLLIN, revents 0 */
    movq $0, (%r13)
    inc %r14
    mov done_r(%rip), %eax
    mov %eax, (%r12, %r14, 8)
    movl $1, 4(%r12, %r14, 8)
    movq $0, (%r13, %r14, 8)
    inc %r14
    mov listen_fd(%rip), %rax
    test %rax, %rax
    js 2f
    mov %eax, (%r12, %r14, 8)
    movl $1, 4(%r12, %r14, 8)
    movq $0, (%r13, %r14, 8)
    inc %r14
2:  mov conns(%rip), %rbx
    xor %r15d, %r15d
3:  cmp conn_hi(%rip), %r15
    jae 6f
    mov CN_STATE(%rbx), %rax
    cmp $CS_FREE, %rax
    je 5f
    mov $1, %ecx                    /* POLLIN */
    cmp $CS_BUSY, %rax
    jne 4f
    cmpq $0, CN_HUP(%rbx)
    jne 5f
    cmpq $QS_INLINE, CN_QSTATE(%rbx)
    je 5f                           /* the worker owns it */
    mov $0x2000, %ecx               /* POLLRDHUP: disconnect while busy */
4:  mov CN_FD(%rbx), %eax
    mov %eax, (%r12, %r14, 8)
    mov %ecx, 4(%r12, %r14, 8)      /* events; revents = 0 */
    mov %rbx, (%r13, %r14, 8)
    inc %r14
5:  add $CN_SIZE, %rbx
    inc %r15
    jmp 3b
6:  /* timeout */
    mov $1000, %edx
    cmpq $0, n_running(%rip)
    jne 61f
    cmpq $0, shutting(%rip)
    je 62f
61: mov $50, %edx
62: cmpq $0, n_queued(%rip)
    je 63f
    mov $10, %edx
63: cmpq $0, n_starting(%rip)
    je 64f
    mov $2, %edx
64: mov %r12, %rdi
    mov %r14, %rsi
    call poll
    test %eax, %eax
    jle s_timers
    /* events */
    xor %r15d, %r15d
7:  cmp %r14, %r15
    jae s_timers
    movzwl 6(%r12, %r15, 8), %ecx   /* revents */
    test %ecx, %ecx
    jz 9f
    mov (%r13, %r15, 8), %rbx
    test %rbx, %rbx
    jnz 8f
    mov (%r12, %r15, 8), %eax       /* special fds */
    cmp sig_fd(%rip), %eax
    jne 71f
    call handle_signals
    jmp 9f
71: cmp done_r(%rip), %eax
    jne 72f
    call handle_done
    jmp 9f
72: cmpq $0, shutting(%rip)
    jne 9f
    call conn_accept
    jmp 9f
8:  /* the connection may have changed state since the poll set was built */
    mov (%r12, %r15, 8), %eax
    cmp CN_FD(%rbx), %eax
    jne 9f
    mov CN_STATE(%rbx), %rax
    cmp $CS_READ, %rax
    jne 81f
    mov %rbx, %rdi
    call conn_read
    jmp 9f
81: cmp $CS_DRAIN, %rax
    jne 82f
    mov %rbx, %rdi
    call conn_drain
    jmp 9f
82: cmp $CS_BUSY, %rax
    jne 9f
    mov %rbx, %rdi
    call conn_hangup
9:  inc %r15
    jmp 7b
s_timers:
    call check_timers
    jmp s_top
ENDF serve_loop

/* conn_hangup(c rdi): the client disconnected while its query was pending:
 * cancel it */
FUNC conn_hangup
    ENTER 0
    mov %rdi, %rbx
    cmpq $0, CN_HUP(%rbx)
    jne 9f
    movq $1, CN_HUP(%rbx)
    mov CN_QSTATE(%rbx), %rax
    cmp $QS_STARTING, %rax
    je 83f
    cmp $QS_QUEUED, %rax
    jne 1f
83: mov %rbx, %rdi
    call pending_remove
    mov CN_QID(%rbx), %rdi
    mov CN_QSTART(%rbx), %rsi
    mov $E_CANCELLED, %edx
    xor %ecx, %ecx
    call account_code
    mov %rbx, %rdi
    call conn_close
    LEAVE
1:  cmp $QS_RUNNING, %rax
    jne 9f
    mov %rbx, %rdi
    call conn_sh
    cmpq $0, SH_DONE(%rax)
    jne 9f                          /* finished: just close when reaped */
    movq $E_CANCELLED, CN_QKILL(%rbx)
    mov CN_QPID(%rbx), %rdi
    mov $SIGKILL_, %esi
    call kill
9:  LEAVE
ENDF conn_hangup
