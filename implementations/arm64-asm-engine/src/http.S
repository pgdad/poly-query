// =============================================================================
// http.S — the `serve` HTTP/1.1 server (protocol.md §7, concurrency.md).
//
// Threads:
//   * the main thread accepts connections (poll on the listening socket and
//     a self-pipe written by the SIGTERM/SIGINT handler) and runs the
//     graceful shutdown;
//   * one thread per connection reads requests (keep-alive, Content-Length
//     or chunked bodies, --max-request-bytes), routes them and writes the
//     responses. Queries execute on the connection thread once admitted by
//     server.S (worker limit, FIFO queue, OVERLOADED), so /health, /metrics,
//     /v1/queries and cancellations never wait for a worker;
//   * the watchdog (server.S) cancels queries of disconnected clients.
// Every endpoint maps onto a protocol request handled by handle_request
// (protocol.S); the response object in g_out becomes the HTTP body and the
// error code selects the status (§7.1).
//
// Streaming (/v1/query/stream): op_query calls http_stream_result with the
// result, which writes the header line, batches of at most STREAM_BATCH
// rows and the end line as chunks. Writes block when the client stops
// reading, which stalls the query (backpressure: at most one batch is
// buffered by the server).
//
//   serve_main() -> never returns (exit status 0 after shutdown, 1 on a
//                   fatal startup error)
//   http_stream_result(x0 BoundQuery*, x1 ResultSet*)   (op_query)
// =============================================================================
#include "pq.inc"
#include "frame.inc"

// Connection state (calloc'ed by the accept loop, owned by its thread)
#define CN_FD       0       // socket
#define CN_BUF      8       // input buffer (malloc)
#define CN_CAP      16
#define CN_LEN      24      // valid bytes in CN_BUF
#define CN_POS      32      // consumed bytes
#define CN_CLOSE    40      // 1: close the connection after this response
#define CN_METHOD   48      // M_*
#define CN_PATHLEN  56      // path bytes in CN_TARGET (NUL terminated)
#define CN_QOFF     64      // offset of the query string in CN_TARGET
#define CN_QLEN     72      // query string length (0 = none)
#define CN_CLEN     80      // Content-Length or -1
#define CN_CHUNKED  88      // u32 Transfer-Encoding: chunked
#define CN_EXPECT   92      // u32 Expect: 100-continue
#define CN_BODY     96      // body Str* (malloc: len, bytes, NUL) or 0
#define CN_STATUS   104     // status of the response being sent
#define CN_T0       112     // µs when the request head was complete
#define CN_TARGET   128     // request target copy
#define TARGET_MAX  8192
#define CN_SIZE     (CN_TARGET + TARGET_MAX + 16)

#define M_OTHER     0
#define M_GET       1
#define M_POST      2
#define M_PUT       3
#define M_DELETE    4

#define HEAD_MAX        65536       // request line + headers
#define LINE_MAX        4096        // chunk-size / trailer line
#define STREAM_BATCH    1000        // rows per streamed batch (<= 10000)
#define CHUNK_PAD       24          // room for the chunk-size line in g_out
#define DRAIN_MAX       (64*1024*1024)  // oversized bodies we read and discard

// read_body results
#define RB_OK       0
#define RB_BAD      1       // malformed framing: 400, close
#define RB_LARGE    2       // body exceeds --max-request-bytes: 413
#define RB_EOF      3       // connection closed / I/O error

// Linux constants
#define AF_INET         2
#define SOCK_STREAM     1
#define SOCK_CLOEXEC    0x80000
#define SOL_SOCKET      1
#define SO_REUSEADDR    2
#define SO_SNDTIMEO     21
#define IPPROTO_TCP     6
#define TCP_NODELAY     1
#define SHUT_WR         1
#define MSG_NOSIGNAL    0x4000
#define EINTR           4
#define EAGAIN          11
#define POLLIN          1
#define SIGINT          2
#define SIGPIPE         13
#define SIGTERM         15
#define O_NONBLOCK      0x800
#define O_CLOEXEC       0x80000

// ------------------------------------------------------------------ data -----
    .bss
    .p2align 4
g_listen_fd:    .skip 8
g_sig_pipe:     .skip 8         // int[2] self-pipe (read end, write end)
g_inflight:     .skip 8         // HTTP requests being processed (atomic)
g_thread_attr:  .skip 64        // pthread_attr_t for connection threads

    TBSS
    .p2align 3
    .global g_stream
g_stream:       .skip 8         // Conn* while serving /v1/query/stream
g_stream_state: .skip 8         // 0 nothing sent, 1 header sent, 2 complete
g_stream_bq:    .skip 8         // BoundQuery* of the streamed query
g_stream_max:   .skip 8         // its max_rows option (-1 none)
g_hdr:          .skip BUF_SIZE  // response head being built

    .section .rodata
    .p2align 3
// error code -> HTTP status (protocol.md §7.1), indexed by ERR_*
status_of_err:
    .hword 500, 400, 400, 400, 400, 400, 400, 400, 400, 400, 400, 403, 404
    .hword 409, 413, 500, 500, 504, 400, 409, 500, 500, 503, 503
    .p2align 3
// routes with a fixed path: path, method, handler
routes:
    .quad p_health,   M_GET,    h_health
    .quad p_metrics,  M_GET,    h_metrics
    .quad p_version,  M_GET,    h_version
    .quad p_caps,     M_GET,    h_capabilities
    .quad p_query,    M_POST,   h_query
    .quad p_stream,   M_POST,   h_stream
    .quad p_explain,  M_POST,   h_explain
    .quad p_tables,   M_GET,    h_tables
    .quad p_request,  M_POST,   h_request
    .quad p_queries,  M_GET,    h_queries
    .quad 0, 0, 0
p_health:   .asciz "/health"
p_metrics:  .asciz "/metrics"
p_version:  .asciz "/v1/version"
p_caps:     .asciz "/v1/capabilities"
p_query:    .asciz "/v1/query"
p_stream:   .asciz "/v1/query/stream"
p_explain:  .asciz "/v1/explain"
p_tables:   .asciz "/v1/tables"
p_request:  .asciz "/v1/request"
p_queries:  .asciz "/v1/queries"
p_tables_s: .asciz "/v1/tables/"
p_queries_s: .asciz "/v1/queries/"
p_schema:   .asciz "/schema"
p_stats:    .asciz "/stats"

s_get:      .asciz "GET"
s_post:     .asciz "POST"
s_put:      .asciz "PUT"
s_delete:   .asciz "DELETE"
h_clen:     .asciz "content-length"
h_te:       .asciz "transfer-encoding"
h_conn:     .asciz "connection"
h_expect:   .asciz "expect"
v_chunked:  .asciz "chunked"
v_close:    .asciz "close"
v_keepalive: .asciz "keep-alive"
v_continue: .asciz "100-continue"

op_query_s:   .asciz "query"
op_explain_s: .asciz "explain"
op_version_s: .asciz "version"
op_caps_s:    .asciz "capabilities"
op_tables_s:  .asciz "tables"
op_schema_s:  .asciz "schema"
op_stats_s:   .asciz "stats"
op_drop_s:    .asciz "drop"
op_load_s:    .asciz "load"
k_table:    .asciz "table"
k_format:   .asciz "format"
k_data:     .asciz "data"
k_replace:  .asciz "replace"
k_options:  .asciz "options"
k_header:   .asciz "header"
k_delim:    .asciz "delimiter"
v_true:     .asciz "true"
v_one:      .asciz "1"

ct_json:    .asciz "application/json"
ct_ndjson:  .asciz "application/x-ndjson"
ct_text:    .asciz "text/plain; version=0.0.4; charset=utf-8"
f_status:   .asciz "HTTP/1.1 %d %s\r\nContent-Type: %s\r\n"
f_clen:     .asciz "Content-Length: %lu\r\n"
s_te_chunked: .asciz "Transfer-Encoding: chunked\r\n"
s_qid_hdr:  .asciz "X-PolyQuery-Query-Id: "
s_conn_close: .asciz "Connection: close\r\n"
s_crlf:     .asciz "\r\n"
s_continue: .asciz "HTTP/1.1 100 Continue\r\n\r\n"
s_last_chunk: .asciz "0\r\n\r\n"
f_hex:      .asciz "%lx\r\n"
f_listening: .asciz "{\"event\":\"listening\",\"host\":\"%s\",\"port\":%d}\n"
s_localhost: .asciz "localhost"
s_loopback: .asciz "127.0.0.1"

b_health_ok:  .asciz "{\"status\":\"ok\"}"
b_health_down: .asciz "{\"status\":\"shutting_down\"}"
b_cancelled:  .asciz "{\"id\":null,\"ok\":true,\"cancelled\":true}"
b_queries:    .asciz "{\"id\":null,\"ok\":true,\"queries\":"
b_err_head:   .asciz "{\"id\":null,\"ok\":false,\"error\":{\"code\":\""
b_err_msg:    .asciz "\",\"message\":"
j_header:     .asciz "{\"type\":\"header\",\"query_id\":"
j_columns:    .asciz ",\"columns\":"
j_rows:       .asciz "{\"type\":\"rows\",\"rows\":["
j_rows_end:   .asciz "]}\n"
j_end:        .asciz "{\"type\":\"end\",\"row_count\":"
j_error:      .asciz "{\"type\":\"error\",\"error\":"

m_notfound:   .asciz "unknown path"
m_method:     .asciz "method not allowed for this path"
m_toolarge:   .asciz "request body exceeds --max-request-bytes"
m_badreq:     .asciz "malformed HTTP request"
m_noquery:    .asciz "unknown or finished query id"
m_disconnect: .asciz "client disconnected"
m_bind:       .asciz "polyquery: cannot listen on %s:%ld\n"
m_badhost:    .asciz "polyquery: invalid --host %s\n"
l_listening:  .asciz "server listening"
l_shutdown:   .asciz "shutdown requested"
l_stopped:    .asciz "server stopped"
k_port:       .asciz "port"
k_workers:    .asciz "workers"
k_inflight:   .asciz "in_flight"
l_request:    .asciz "request"
k_method:     .asciz "method"
k_path:       .asciz "path"
k_hstatus:    .asciz "http_status"
k_duration:   .asciz "duration_ms"
    .p2align 3
method_names:
    .quad s_other, s_get, s_post, s_put, s_delete
s_other:      .asciz "OTHER"

reasons:
    .quad 100, r_100, 200, r_200, 201, r_201, 400, r_400, 403, r_403
    .quad 404, r_404, 405, r_405, 409, r_409, 413, r_413, 500, r_500
    .quad 503, r_503, 504, r_504, 0, r_500
r_100:  .asciz "Continue"
r_200:  .asciz "OK"
r_201:  .asciz "Created"
r_400:  .asciz "Bad Request"
r_403:  .asciz "Forbidden"
r_404:  .asciz "Not Found"
r_405:  .asciz "Method Not Allowed"
r_409:  .asciz "Conflict"
r_413:  .asciz "Payload Too Large"
r_500:  .asciz "Internal Server Error"
r_503:  .asciz "Service Unavailable"
r_504:  .asciz "Gateway Timeout"
    .text

// =============================================================================
// Socket output
// =============================================================================

// write_all(w0 fd, x1 ptr, x2 len, w3 interruptible) -> w0 0 ok, -1 error
// Retries short writes, EINTR and send timeouts (SO_SNDTIMEO); with
// interruptible set (streaming inside a query) a timeout also polls the
// query's cancellation flag and deadline (check_deadline may raise).
//   w19 fd, x20 ptr, x21 len, w22 interruptible
LFUNC write_all
    ENTER 3
    mov  w19, w0
    mov  x20, x1
    mov  x21, x2
    mov  w22, w3
1:  cbz  x21, 8f
    mov  w0, w19
    mov  x1, x20
    mov  x2, x21
    mov  w3, #MSG_NOSIGNAL
    bl   send
    cmp  x0, #0
    b.le 2f
    add  x20, x20, x0
    sub  x21, x21, x0
    b    1b
2:  b.eq 9f                             // nothing written: give up
    bl   __errno_location
    ldr  w0, [x0]
    cmp  w0, #EINTR
    b.eq 1b
    cmp  w0, #EAGAIN
    b.ne 9f
    cbz  w22, 1b
    bl   check_deadline                 // cancelled / timed out: raises
    b    1b
8:  mov  w0, #0
    LEAVE 3
9:  mov  w0, #-1
    LEAVE 3
ENDF write_all

// reason_phrase(w0 status) -> x0 cstr     (leaf)
LFUNC reason_phrase
    ADR_L x9, reasons
1:  ldr  x10, [x9]
    cbz  x10, 2f
    cmp  x10, x0
    b.eq 2f
    add  x9, x9, #16
    b    1b
2:  ldr  x0, [x9, #8]
    ret
ENDF reason_phrase

// head_begin(x0 conn, w1 status, x2 content type): g_hdr = status line +
// Content-Type (+ X-PolyQuery-Query-Id when this request ran a query).
//   x19 conn, w20 status, x21 type; locals [sp] text (160 bytes)
LFUNC head_begin
    ENTER 3
    sub  sp, sp, #160
    mov  x19, x0
    mov  w20, w1
    mov  x21, x2
    str  x20, [x19, #CN_STATUS]
    mov  w0, w20
    bl   reason_phrase
    mov  x4, x0
    mov  x0, sp
    mov  x1, #160
    ADR_L x2, f_status
    mov  w3, w20
    mov  x5, x21
    bl   snprintf
    TLS_ADDR x0, g_hdr
    str  xzr, [x0, #BUF_LEN]
    mov  x1, sp
    bl   buf_puts
    TLS_LDR x20, g_qid
    cbz  x20, 3f
    TLS_ADDR x0, g_hdr
    ADR_L x1, s_qid_hdr
    bl   buf_puts
    // the id is client data: keep header-safe bytes only
    ldr  x21, [x20, #STR_LEN]
    add  x20, x20, #STR_DATA
1:  cbz  x21, 2f
    ldrb w1, [x20], #1
    sub  x21, x21, #1
    cmp  w1, #0x20
    b.lo 1b
    cmp  w1, #0x7f
    b.eq 1b
    TLS_ADDR x0, g_hdr
    bl   buf_putc
    b    1b
2:  TLS_ADDR x0, g_hdr
    ADR_L x1, s_crlf
    bl   buf_puts
3:  ldr  x9, [x19, #CN_CLOSE]
    cbz  x9, 4f
    TLS_ADDR x0, g_hdr
    ADR_L x1, s_conn_close
    bl   buf_puts
4:  add  sp, sp, #160
    LEAVE 3
ENDF head_begin

// send_response(x0 conn, w1 status, x2 content type, x3 body, x4 len)
//   x19 conn, x20 body, x21 len; locals [sp] text
LFUNC send_response
    ENTER 3
    sub  sp, sp, #48
    mov  x19, x0
    mov  x20, x3
    mov  x21, x4
    bl   head_begin
    mov  x0, sp
    mov  x1, #48
    ADR_L x2, f_clen
    mov  x3, x21
    bl   snprintf
    TLS_ADDR x0, g_hdr
    mov  x1, sp
    bl   buf_puts
    TLS_ADDR x0, g_hdr
    ADR_L x1, s_crlf
    bl   buf_puts
    mov  x9, #65536                     // small bodies: one write
    cmp  x21, x9
    b.hi 1f
    TLS_ADDR x0, g_hdr
    mov  x1, x20
    mov  x2, x21
    bl   buf_put
    mov  x21, #0
1:  TLS_ADDR x9, g_hdr
    ldr  w0, [x19, #CN_FD]
    ldr  x1, [x9, #BUF_PTR]
    ldr  x2, [x9, #BUF_LEN]
    mov  w3, #0
    bl   write_all
    cbnz w0, 8f
    cbz  x21, 9f
    ldr  w0, [x19, #CN_FD]
    mov  x1, x20
    mov  x2, x21
    mov  w3, #0
    bl   write_all
    cbz  w0, 9f
8:  mov  x9, #1                         // the client is gone
    str  x9, [x19, #CN_CLOSE]
9:  add  sp, sp, #48
    LEAVE 3
ENDF send_response

// send_out(x0 conn, w1 status, x2 content type): body = g_out
LFUNC send_out
    TLS_ADDR x9, g_out
    ldr  x3, [x9, #BUF_PTR]
    ldr  x4, [x9, #BUF_LEN]
    b    send_response
ENDF send_out

// send_cstr(x0 conn, w1 status, x2 JSON body cstr)
LFUNC send_cstr
    ENTER 2
    mov  x19, x0
    mov  w20, w1
    mov  x0, x2
    str  x2, [sp, #-16]!
    bl   strlen
    mov  x4, x0
    ldr  x3, [sp], #16
    mov  x0, x19
    mov  w1, w20
    ADR_L x2, ct_json
    bl   send_response
    LEAVE 2
ENDF send_cstr

// send_error(x0 conn, w1 ERR_* code, x2 message cstr): protocol error
// object with the status of the code (§7.1)
LFUNC send_error
    ENTER 2
    mov  x19, x0
    mov  w20, w1
    mov  x21, x2
    mov  w0, w1
    bl   http_status
    mov  w3, w0
    mov  x0, x19
    mov  w1, w20
    mov  x2, x21
    bl   send_error_st
    LEAVE 2
ENDF send_error

// send_error_st(x0 conn, w1 code, x2 message, w3 status)
//   x19 conn, w20 code, x21 message, w22 status
LFUNC send_error_st
    ENTER 3
    mov  x19, x0
    mov  w20, w1
    mov  x21, x2
    mov  w22, w3
    TLS_ADDR x0, g_out
    str  xzr, [x0, #BUF_LEN]
    ADR_L x1, b_err_head
    bl   buf_puts
    mov  w0, w20
    bl   err_code_name
    mov  x1, x0
    TLS_ADDR x0, g_out
    bl   buf_puts
    TLS_ADDR x0, g_out
    ADR_L x1, b_err_msg
    bl   buf_puts
    mov  x0, x21
    bl   strlen
    mov  x2, x0
    mov  x1, x21
    TLS_ADDR x0, g_out
    bl   buf_put_jstr
    TLS_ADDR x0, g_out
    mov  w1, #'}'
    bl   buf_putc
    TLS_ADDR x0, g_out
    mov  w1, #'}'
    bl   buf_putc
    mov  w1, w22
    mov  x0, x19
    ADR_L x2, ct_json
    bl   send_out
    LEAVE 3
ENDF send_error_st

// http_status(w0 error code) -> w0 HTTP status            (leaf)
LFUNC http_status
    cbz  w0, 1f
    cmp  w0, #ERR_LAST
    b.hi 2f
    ADR_L x9, status_of_err
    ldrh w0, [x9, w0, uxtw #1]
    ret
1:  mov  w0, #200
    ret
2:  mov  w0, #500
    ret
ENDF http_status

// send_chunk(x0 conn): g_out holds CHUNK_PAD reserved bytes followed by the
// chunk data; prefix the chunk-size line, append CRLF and write it. A
// failed write means the client went away: CANCELLED (raises).
//   x19 conn, x20 data length, x21 size-line length; locals [sp] text
LFUNC send_chunk
    ENTER 3
    sub  sp, sp, #32
    mov  x19, x0
    TLS_ADDR x9, g_out
    ldr  x20, [x9, #BUF_LEN]
    sub  x20, x20, #CHUNK_PAD
    mov  x0, sp
    mov  x1, #32
    ADR_L x2, f_hex
    mov  x3, x20
    bl   snprintf
    sxtw x21, w0
    TLS_ADDR x0, g_out
    ADR_L x1, s_crlf
    bl   buf_puts
    TLS_ADDR x9, g_out
    ldr  x0, [x9, #BUF_PTR]
    add  x0, x0, #CHUNK_PAD
    sub  x0, x0, x21
    mov  x1, sp
    mov  x2, x21
    bl   memcpy
    TLS_ADDR x9, g_out
    ldr  x1, [x9, #BUF_PTR]
    add  x1, x1, #CHUNK_PAD
    sub  x1, x1, x21
    ldr  x2, [x9, #BUF_LEN]
    sub  x2, x2, #CHUNK_PAD
    add  x2, x2, x21
    ldr  w0, [x19, #CN_FD]
    mov  w3, #1
    bl   write_all
    cbz  w0, 9f
    mov  x9, #1
    str  x9, [x19, #CN_CLOSE]
    mov  w0, #ERR_CANCELLED
    ADR_L x1, m_disconnect
    bl   pq_raise
9:  add  sp, sp, #32
    LEAVE 3
ENDF send_chunk

// chunk_begin(): g_out = CHUNK_PAD reserved bytes
LFUNC chunk_begin
    ENTER 0
    TLS_ADDR x0, g_out
    str  xzr, [x0, #BUF_LEN]
    mov  x1, #CHUNK_PAD
    bl   buf_reserve
    TLS_ADDR x0, g_out
    mov  x1, #CHUNK_PAD
    str  x1, [x0, #BUF_LEN]
    LEAVE 0
ENDF chunk_begin

// out_cstr(x0 cstr) / out_jstr(x0 Str*): append to g_out
LFUNC out_cstr
    mov  x1, x0
    TLS_ADDR x0, g_out
    b    buf_puts
ENDF out_cstr

LFUNC out_jstr
    ldr  x2, [x0, #STR_LEN]
    add  x1, x0, #STR_DATA
    TLS_ADDR x0, g_out
    b    buf_put_jstr
ENDF out_jstr

// =============================================================================
// Streaming (/v1/query/stream), called from op_query inside the request:
//   http_stream_open(x0 BoundQuery*, x1 max_rows or -1)
//   http_stream_sink(x0 0, x1 total)  -> checks max_rows, sends the HTTP
//                                        head and the header line
//   http_stream_sink(x0 ResultSet*)   -> one "rows" line for its rows
//   http_stream_end(x0 total)         -> end line and the last chunk
//   http_stream_result(x0 BoundQuery*, x1 ResultSet*): all of the above for
//                                        a materialised result
// =============================================================================
FUNC http_stream_open
    TLS_ADDR x9, g_stream_bq
    stp  x0, x1, [x9]                   // g_stream_bq, g_stream_max
    ret
ENDF http_stream_open

// http_stream_sink(x0 ResultSet* batch or 0, x1 total when x0 = 0)
//   x19 rs, x20 conn, x21 bq
FUNC http_stream_sink
    ENTER 3
    mov  x19, x0
    TLS_LDR x20, g_stream
    TLS_LDR x21, g_stream_bq
    cbnz x19, 2f
    TLS_ADDR x9, g_stream_bq            // begin: max_rows first
    ldr  x9, [x9, #8]
    tbnz x9, #63, 1f
    cmp  x1, x9
    b.ls 1f
    RAISE ERR_RESOURCE_LIMIT, "result exceeds max_rows"
1:  mov  x0, x20
    mov  x1, x21
    bl   stream_begin
    LEAVE 3
2:  bl   check_deadline                 // cancellation / timeout
    bl   chunk_begin
    ADR_L x0, j_rows
    bl   out_cstr
    mov  x0, x21
    mov  x1, x19
    mov  x2, #0
    ldr  x3, [x19, #RS_NROWS]
    bl   out_rows
    ADR_L x0, j_rows_end
    bl   out_cstr
    mov  x0, x20
    bl   send_chunk
    LEAVE 3
ENDF http_stream_sink

// stream_begin(x0 conn, x1 BoundQuery*): response head and header line
//   x19 conn, x20 bq
LFUNC stream_begin
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    mov  w1, #200
    ADR_L x2, ct_ndjson
    bl   head_begin
    TLS_ADDR x0, g_hdr
    ADR_L x1, s_te_chunked
    bl   buf_puts
    TLS_ADDR x0, g_hdr
    ADR_L x1, s_crlf
    bl   buf_puts
    TLS_ADDR x9, g_hdr
    ldr  w0, [x19, #CN_FD]
    ldr  x1, [x9, #BUF_PTR]
    ldr  x2, [x9, #BUF_LEN]
    mov  w3, #1
    bl   write_all
    cbz  w0, 1f
    mov  x9, #1
    str  x9, [x19, #CN_CLOSE]
    mov  w0, #ERR_CANCELLED
    ADR_L x1, m_disconnect
    bl   pq_raise
1:  TLS_ADDR x9, g_stream_state
    mov  x10, #1
    str  x10, [x9]
    bl   chunk_begin
    ADR_L x0, j_header
    bl   out_cstr
    TLS_LDR x0, g_qid
    bl   out_jstr
    ADR_L x0, j_columns
    bl   out_cstr
    mov  x0, x20
    bl   out_columns
    mov  w0, #'}'
    bl   out_c_nl
    mov  x0, x19
    bl   send_chunk
    LEAVE 2
ENDF stream_begin

// http_stream_end(x0 total rows)
//   x19 total, x20 conn
FUNC http_stream_end
    ENTER 2
    mov  x19, x0
    TLS_LDR x20, g_stream
    bl   chunk_begin
    ADR_L x0, j_end
    bl   out_cstr
    TLS_ADDR x0, g_out
    mov  x1, x19
    bl   buf_put_u64
    mov  w0, #'}'
    bl   out_c_nl
    mov  x0, x20
    bl   send_chunk
    ldr  w0, [x20, #CN_FD]
    ADR_L x1, s_last_chunk
    mov  x2, #5
    mov  w3, #1
    bl   write_all
    TLS_ADDR x9, g_stream_state
    mov  x10, #2
    str  x10, [x9]
    LEAVE 2
ENDF http_stream_end

// http_stream_result(x0 BoundQuery*, x1 ResultSet*): materialised result
//   x19 bq, x20 rs, x21 conn, x22 row, x23 rows, x24 batch end
FUNC http_stream_result
    ENTER 4
    mov  x19, x0
    mov  x20, x1
    TLS_LDR x21, g_stream
    mov  x0, x21
    mov  x1, x19
    bl   stream_begin
    ldr  x23, [x20, #RS_NROWS]
    mov  x22, #0
2:  cmp  x22, x23
    b.hs 3f
    bl   check_deadline                 // cancellation / timeout
    add  x24, x22, #STREAM_BATCH
    cmp  x24, x23
    csel x24, x24, x23, lo
    bl   chunk_begin
    ADR_L x0, j_rows
    bl   out_cstr
    mov  x0, x19
    mov  x1, x20
    mov  x2, x22
    mov  x3, x24
    bl   out_rows
    ADR_L x0, j_rows_end
    bl   out_cstr
    mov  x0, x21
    bl   send_chunk
    mov  x22, x24
    b    2b
3:  mov  x0, x23
    bl   http_stream_end
    LEAVE 4
ENDF http_stream_result

// out_c_nl(w0 char): append char and '\n' to g_out
LFUNC out_c_nl
    ENTER 1
    mov  w19, w0
    TLS_ADDR x0, g_out
    mov  w1, w19
    bl   buf_putc
    TLS_ADDR x0, g_out
    mov  w1, #'\n'
    bl   buf_putc
    LEAVE 1
ENDF out_c_nl

// =============================================================================
// Request bodies as protocol requests (JSON DOM built in the request arena)
// =============================================================================

// jn_new(w0 type, x1 ptr, w2 count) -> x0 JNode*
LFUNC jn_new
    ENTER 2
    mov  w19, w0
    mov  x20, x1
    stp  x2, x2, [sp, #-16]!
    mov  x0, #JN_SIZE
    bl   arena_zalloc
    ldp  x2, x3, [sp], #16
    str  w19, [x0, #JN_TYPE]
    str  w2, [x0, #JN_COUNT]
    str  x20, [x0, #JN_PTR]
    LEAVE 2
ENDF jn_new

// jn_obj(w0 capacity pairs) -> x0 empty object JNode*
LFUNC jn_obj
    ENTER 1
    lsl  x0, x0, #4
    add  x0, x0, #16
    bl   arena_zalloc
    mov  x1, x0
    mov  w0, #J_OBJ
    mov  w2, #0
    bl   jn_new
    LEAVE 1
ENDF jn_obj

// jn_put(x0 obj, x1 key cstr, x2 value JNode*)
//   x19 obj, x20 key, x21 value
LFUNC jn_put
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x0, x1
    bl   strlen
    mov  x1, x0
    mov  x0, x20
    bl   str_new
    mov  x1, x0
    mov  w0, #J_STR
    mov  w2, #0
    bl   jn_new
    ldr  w9, [x19, #JN_COUNT]
    ldr  x10, [x19, #JN_PTR]
    add  x10, x10, x9, lsl #4
    stp  x0, x21, [x10]
    add  w9, w9, #1
    str  w9, [x19, #JN_COUNT]
    LEAVE 3
ENDF jn_put

// jn_put_str(x0 obj, x1 key cstr, x2 Str*)
LFUNC jn_put_str
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    mov  x1, x2
    mov  w0, #J_STR
    mov  w2, #0
    bl   jn_new
    mov  x2, x0
    mov  x0, x19
    mov  x1, x20
    bl   jn_put
    LEAVE 2
ENDF jn_put_str

// pct_decode(x0 ptr, x1 len) -> x0 Str* (request arena): %XX decoded,
// '+' kept (paths and our query parameters never encode spaces as '+')
//   x19 src, x20 len, x21 Str*, x22 out index
LFUNC pct_decode
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    add  x0, x1, #(STR_DATA + 1)
    bl   arena_alloc
    mov  x21, x0
    mov  x22, #0
1:  cbz  x20, 9f
    ldrb w9, [x19]
    cmp  w9, #'%'
    b.ne 3f
    cmp  x20, #3
    b.lo 3f
    ldrb w0, [x19, #1]
    bl   hexval
    mov  w10, w0
    ldrb w0, [x19, #2]
    bl   hexval
    tbnz w10, #31, 2f
    tbnz w0, #31, 2f
    orr  w9, w0, w10, lsl #4
    add  x10, x21, #STR_DATA
    strb w9, [x10, x22]
    add  x22, x22, #1
    add  x19, x19, #3
    sub  x20, x20, #3
    b    1b
2:  mov  w9, #'%'
3:  add  x10, x21, #STR_DATA
    strb w9, [x10, x22]
    add  x22, x22, #1
    add  x19, x19, #1
    sub  x20, x20, #1
    b    1b
9:  str  x22, [x21, #STR_LEN]
    add  x10, x21, #STR_DATA
    strb wzr, [x10, x22]
    mov  x0, x21
    LEAVE 3
ENDF pct_decode

// hexval(w0 char) -> w0 0..15 or -1     (leaf)
LFUNC hexval
    sub  w1, w0, #'0'
    cmp  w1, #9
    b.ls 1f
    orr  w1, w0, #0x20
    sub  w1, w1, #'a'
    cmp  w1, #5
    b.hi 2f
    add  w1, w1, #10
1:  mov  w0, w1
    ret
2:  mov  w0, #-1
    ret
ENDF hexval

// query_param(x0 conn, x1 name cstr) -> x0 Str* decoded value or 0
//   x19 conn, x20 name, x21 name len, x22 cursor, x23 end, x24 pair end
LFUNC query_param
    ENTER 4
    mov  x19, x0
    mov  x20, x1
    mov  x0, x1
    bl   strlen
    mov  x21, x0
    ldr  x9, [x19, #CN_QOFF]
    add  x22, x19, #CN_TARGET
    add  x22, x22, x9
    ldr  x9, [x19, #CN_QLEN]
    add  x23, x22, x9
1:  cmp  x22, x23
    b.hs 8f
    mov  x24, x22                       // find the end of this pair
2:  cmp  x24, x23
    b.hs 3f
    ldrb w9, [x24]
    cmp  w9, #'&'
    b.eq 3f
    add  x24, x24, #1
    b    2b
3:  sub  x9, x24, x22                   // "name=" prefix?
    cmp  x9, x21
    b.ls 4f
    ldrb w9, [x22, x21]
    cmp  w9, #'='
    b.ne 4f
    mov  x0, x22
    mov  x1, x20
    mov  x2, x21
    bl   strncmp
    cbnz w0, 4f
    add  x0, x22, x21
    add  x0, x0, #1
    sub  x1, x24, x0
    bl   pct_decode
    b    9f
4:  add  x22, x24, #1
    b    1b
8:  mov  x0, #0
9:  LEAVE 4
ENDF query_param

// param_bool(x0 Str*) -> w0 1 for "true"/"1", else 0
LFUNC param_bool
    ENTER 1
    add  x19, x0, #STR_DATA
    mov  x0, x19
    ADR_L x1, v_true
    bl   strcasecmp
    cbz  w0, 1f
    mov  x0, x19
    ADR_L x1, v_one
    bl   strcmp
    cbz  w0, 1f
    mov  w0, #0
    LEAVE 1
1:  mov  w0, #1
    LEAVE 1
ENDF param_bool

// =============================================================================
// Endpoint handlers: x0 conn. Each sends exactly one response.
// =============================================================================

// run_request(x0 conn, x1 body ptr, x2 len, x3 prebuilt JNode* or 0,
//             x4 forced op cstr or 0, w5 success status)
// Runs a protocol request and sends its response (status per §7.1).
//   x19 conn, w20 success status
LFUNC run_request
    ENTER 2
    mov  x19, x0
    mov  w20, w5
    mov  x0, x1
    mov  x1, x2
    mov  x2, x3
    mov  x3, x4
    bl   handle_request
    cbz  w0, 1f
    bl   http_status
    mov  w20, w0
1:  mov  x0, x19
    mov  w1, w20
    ADR_L x2, ct_json
    bl   send_out
    LEAVE 2
ENDF run_request

// body_ptr(x0 conn) -> x0 data ptr, x1 len (empty if no body)   (leaf)
LFUNC body_ptr
    ldr  x9, [x0, #CN_BODY]
    cbz  x9, 1f
    ldr  x1, [x9, #STR_LEN]
    add  x0, x9, #STR_DATA
    ret
1:  mov  x0, x9
    mov  x1, #0
    ret
ENDF body_ptr

// run_body_op(x0 conn, x1 forced op cstr or 0): request object = body
LFUNC run_body_op
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    bl   body_ptr
    mov  x2, x1
    mov  x1, x0
    mov  x0, x19
    mov  x3, #0
    mov  x4, x20
    mov  w5, #200
    bl   run_request
    LEAVE 2
ENDF run_body_op

// run_obj_op(x0 conn, x1 op cstr, x2 request JNode*, w3 success status)
LFUNC run_obj_op
    mov  x4, x1
    mov  w5, w3
    mov  x3, x2
    mov  x1, #0
    mov  x2, #0
    b    run_request
ENDF run_obj_op

LFUNC h_health
    ENTER 1
    mov  x19, x0
    LDR_G x9, g_srv_shutdown
    mov  w1, #200
    ADR_L x2, b_health_ok
    cbz  x9, 1f
    mov  w1, #503
    ADR_L x2, b_health_down
1:  mov  x0, x19
    bl   send_cstr
    LEAVE 1
ENDF h_health

LFUNC h_metrics
    ENTER 1
    mov  x19, x0
    TLS_ADDR x0, g_out
    str  xzr, [x0, #BUF_LEN]
    bl   srv_write_metrics
    mov  x0, x19
    mov  w1, #200
    ADR_L x2, ct_text
    bl   send_out
    LEAVE 1
ENDF h_metrics

// h_simple(x0 conn, x1 op): op without arguments
LFUNC h_simple
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    mov  w0, #0
    bl   jn_obj
    mov  x2, x0
    mov  x0, x19
    mov  x1, x20
    mov  w3, #200
    bl   run_obj_op
    LEAVE 2
ENDF h_simple

LFUNC h_version
    ADR_L x1, op_version_s
    b    h_simple
ENDF h_version

LFUNC h_capabilities
    ADR_L x1, op_caps_s
    b    h_simple
ENDF h_capabilities

LFUNC h_tables
    ADR_L x1, op_tables_s
    b    h_simple
ENDF h_tables

LFUNC h_query
    ADR_L x1, op_query_s
    b    run_body_op
ENDF h_query

LFUNC h_explain
    ADR_L x1, op_explain_s
    b    run_body_op
ENDF h_explain

LFUNC h_request
    mov  x1, #0
    b    run_body_op
ENDF h_request

// h_stream: POST /v1/query/stream
//   x19 conn, w20 error code
LFUNC h_stream
    ENTER 2
    mov  x19, x0
    TLS_ADDR x9, g_stream
    str  x19, [x9]
    str  xzr, [x9, #8]                  // g_stream_state
    bl   body_ptr
    mov  x2, #0
    ADR_L x3, op_query_s
    bl   handle_request
    mov  w20, w0
    TLS_ADDR x9, g_stream
    str  xzr, [x9]
    ldr  x10, [x9, #8]
    cmp  x10, #2
    b.eq 9f                             // complete
    cmp  x10, #1
    b.eq 2f
    // nothing sent yet: a normal response (error before the header)
    mov  w0, w20
    bl   http_status
    mov  w1, w0
    mov  x0, x19
    ADR_L x2, ct_json
    bl   send_out
    b    9f
2:  // failure after the header: final error line, then end the stream
    ldr  x9, [x19, #CN_CLOSE]
    cbnz x9, 9f                         // the client is gone
    bl   chunk_begin
    ADR_L x0, j_error
    bl   out_cstr
    TLS_ADDR x0, g_out
    bl   put_error_object
    mov  w0, #'}'
    bl   out_c_nl
    TLS_ADDR x9, g_out                  // (no query context: plain writes)
    ldr  x10, [x9, #BUF_LEN]
    sub  x10, x10, #CHUNK_PAD
    mov  x0, x19
    bl   send_chunk_plain
    ldr  w0, [x19, #CN_FD]
    ADR_L x1, s_last_chunk
    mov  x2, #5
    mov  w3, #0
    bl   write_all
9:  LEAVE 2
ENDF h_stream

// send_chunk_plain(x0 conn): like send_chunk outside a query (no raising;
// a failed write just marks the connection for closing)
//   x19 conn, x20 data length, x21 size-line length; locals [sp] text
LFUNC send_chunk_plain
    ENTER 3
    sub  sp, sp, #32
    mov  x19, x0
    TLS_ADDR x9, g_out
    ldr  x20, [x9, #BUF_LEN]
    sub  x20, x20, #CHUNK_PAD
    mov  x0, sp
    mov  x1, #32
    ADR_L x2, f_hex
    mov  x3, x20
    bl   snprintf
    sxtw x21, w0
    TLS_ADDR x0, g_out
    ADR_L x1, s_crlf
    bl   buf_puts
    TLS_ADDR x9, g_out
    ldr  x0, [x9, #BUF_PTR]
    add  x0, x0, #CHUNK_PAD
    sub  x0, x0, x21
    mov  x1, sp
    mov  x2, x21
    bl   memcpy
    TLS_ADDR x9, g_out
    ldr  x1, [x9, #BUF_PTR]
    add  x1, x1, #CHUNK_PAD
    sub  x1, x1, x21
    ldr  x2, [x9, #BUF_LEN]
    sub  x2, x2, #CHUNK_PAD
    add  x2, x2, x21
    ldr  w0, [x19, #CN_FD]
    mov  w3, #0
    bl   write_all
    cbz  w0, 9f
    mov  x9, #1
    str  x9, [x19, #CN_CLOSE]
9:  add  sp, sp, #32
    LEAVE 3
ENDF send_chunk_plain

// h_queries: GET /v1/queries
LFUNC h_queries
    ENTER 1
    mov  x19, x0
    TLS_ADDR x0, g_out
    str  xzr, [x0, #BUF_LEN]
    ADR_L x1, b_queries
    bl   buf_puts
    TLS_ADDR x0, g_out
    bl   srv_write_queries
    TLS_ADDR x0, g_out
    mov  w1, #'}'
    bl   buf_putc
    mov  x0, x19
    mov  w1, #200
    ADR_L x2, ct_json
    bl   send_out
    LEAVE 1
ENDF h_queries

// h_cancel(x0 conn, x1 id ptr, x2 len): DELETE /v1/queries/{id}
//   x19 conn
LFUNC h_cancel
    ENTER 1
    mov  x19, x0
    mov  x0, x1
    mov  x1, x2
    bl   pct_decode
    add  x1, x0, #STR_DATA
    ldr  x2, [x0, #STR_LEN]
    mov  x0, x1
    mov  x1, x2
    bl   srv_cancel
    cbz  w0, 1f
    mov  x0, x19
    mov  w1, #200
    ADR_L x2, b_cancelled
    bl   send_cstr
    LEAVE 1
1:  mov  x0, x19
    mov  w1, #ERR_NOT_FOUND
    ADR_L x2, m_noquery
    bl   send_error
    LEAVE 1
ENDF h_cancel

// h_table(x0 conn, x1 name ptr, x2 name len, x3 suffix ptr, x4 suffix len)
// /v1/tables/{name}[/schema|/stats]
//   x19 conn, x20 name Str*, x21 suffix, x22 suffix len, x23 request,
//   x24 method / scratch
LFUNC h_table
    ENTER 4
    mov  x19, x0
    mov  x21, x3
    mov  x22, x4
    mov  x0, x1
    mov  x1, x2
    bl   pct_decode
    mov  x20, x0
    ldr  x24, [x19, #CN_METHOD]
    cbz  x22, .Lht_resource
    // /schema or /stats: GET only
    mov  x0, x21
    ADR_L x1, p_schema
    bl   strcmp
    ADR_L x23, op_schema_s
    cbz  w0, 1f
    mov  x0, x21
    ADR_L x1, p_stats
    bl   strcmp
    ADR_L x23, op_stats_s
    cbnz w0, .Lht_notfound
1:  cmp  x24, #M_GET
    b.ne .Lht_method
    mov  w0, #1
    bl   jn_obj
    mov  x24, x0
    ADR_L x1, k_table
    mov  x2, x20
    bl   jn_put_str
    mov  x0, x19
    mov  x1, x23
    mov  x2, x24
    mov  w3, #200
    bl   run_obj_op
    b    9f
.Lht_resource:
    cmp  x24, #M_DELETE
    b.ne 2f
    mov  w0, #1
    bl   jn_obj
    mov  x24, x0
    ADR_L x1, k_table
    mov  x2, x20
    bl   jn_put_str
    mov  x0, x19
    ADR_L x1, op_drop_s
    mov  x2, x24
    mov  w3, #200
    bl   run_obj_op
    b    9f
2:  cmp  x24, #M_PUT
    b.ne .Lht_method
    // PUT: load the raw body; ?format=…&replace=…&header=…&delimiter=…
    mov  w0, #6
    bl   jn_obj
    mov  x23, x0
    ADR_L x1, k_table
    mov  x2, x20
    bl   jn_put_str
    mov  x0, x19
    ADR_L x1, k_format
    bl   query_param
    cbz  x0, 3f
    mov  x2, x0
    mov  x0, x23
    ADR_L x1, k_format
    bl   jn_put_str
3:  ldr  x2, [x19, #CN_BODY]            // the body is already a Str
    cbnz x2, 31f
    mov  x0, #0
    mov  x1, #0
    bl   str_new
    mov  x2, x0
31: mov  x0, x23
    ADR_L x1, k_data
    bl   jn_put_str
    mov  x0, x19
    ADR_L x1, k_replace
    bl   query_param
    cbz  x0, 4f
    bl   param_bool
    mov  w9, #J_FALSE
    cmp  w0, #0
    mov  w10, #J_TRUE
    csel w0, w10, w9, ne
    mov  x1, #0
    mov  w2, #0
    bl   jn_new
    mov  x2, x0
    mov  x0, x23
    ADR_L x1, k_replace
    bl   jn_put
4:  mov  w0, #2                         // options: header, delimiter
    bl   jn_obj
    mov  x24, x0
    mov  x0, x19
    ADR_L x1, k_header
    bl   query_param
    cbz  x0, 5f
    bl   param_bool
    mov  w9, #J_FALSE
    cmp  w0, #0
    mov  w10, #J_TRUE
    csel w0, w10, w9, ne
    mov  x1, #0
    mov  w2, #0
    bl   jn_new
    mov  x2, x0
    mov  x0, x24
    ADR_L x1, k_header
    bl   jn_put
5:  mov  x0, x19
    ADR_L x1, k_delim
    bl   query_param
    cbz  x0, 6f
    mov  x2, x0
    mov  x0, x24
    ADR_L x1, k_delim
    bl   jn_put_str
6:  mov  x0, x23
    ADR_L x1, k_options
    mov  x2, x24
    bl   jn_put
    mov  x0, x19
    ADR_L x1, op_load_s
    mov  x2, x23
    mov  w3, #201
    bl   run_obj_op
    b    9f
.Lht_notfound:
    mov  x0, x19
    mov  w1, #ERR_NOT_FOUND
    ADR_L x2, m_notfound
    bl   send_error
    b    9f
.Lht_method:
    mov  x0, x19
    bl   send_405
9:  LEAVE 4
ENDF h_table

// send_405(x0 conn)
LFUNC send_405
    mov  w1, #ERR_INVALID_REQUEST       // INVALID_REQUEST with status 405
    ADR_L x2, m_method
    mov  w3, #405
    b    send_error_st
ENDF send_405

// =============================================================================
// Routing
// =============================================================================

// starts_with(x0 str, x1 prefix cstr) -> w0 1/0       (leaf)
LFUNC starts_with
1:  ldrb w9, [x1], #1
    cbz  w9, 2f
    ldrb w10, [x0], #1
    cmp  w9, w10
    b.eq 1b
    mov  w0, #0
    ret
2:  mov  w0, #1
    ret
ENDF starts_with

// route(x0 conn)
//   x19 conn, x20 path, x21 route entry, w22 path matched
LFUNC route
    ENTER 3
    mov  x19, x0
    add  x20, x19, #CN_TARGET
    ADR_L x21, routes
    mov  w22, #0
1:  ldr  x1, [x21]
    cbz  x1, 3f
    mov  x0, x20
    bl   strcmp
    cbnz w0, 2f
    mov  w22, #1
    ldr  x9, [x21, #8]
    ldr  x10, [x19, #CN_METHOD]
    cmp  x9, x10
    b.ne 2f
    ldr  x9, [x21, #16]
    mov  x0, x19
    blr  x9
    b    9f
2:  add  x21, x21, #24
    b    1b
3:  cbnz w22, .Lr_method
    // /v1/tables/{name}[/suffix]
    mov  x0, x20
    ADR_L x1, p_tables_s
    bl   starts_with
    cbz  w0, 5f
    add  x1, x20, #11                   // name start
    mov  x2, x1
4:  ldrb w9, [x2]
    cbz  w9, 41f
    cmp  w9, #'/'
    b.eq 41f
    add  x2, x2, #1
    b    4b
41: sub  x9, x2, x1                     // name length
    cbz  x9, .Lr_notfound
    mov  x3, x2                         // suffix ("" or "/schema"…)
    mov  x0, x3
    stp  x1, x9, [sp, #-16]!
    str  x3, [sp, #-16]!
    bl   strlen
    mov  x4, x0
    ldr  x3, [sp], #16
    ldp  x1, x2, [sp], #16
    mov  x0, x19
    bl   h_table
    b    9f
5:  // /v1/queries/{id}
    mov  x0, x20
    ADR_L x1, p_queries_s
    bl   starts_with
    cbz  w0, .Lr_notfound
    add  x21, x20, #12
    ldrb w9, [x21]
    cbz  w9, .Lr_notfound
    ldr  x9, [x19, #CN_METHOD]
    cmp  x9, #M_DELETE
    b.ne .Lr_method
    mov  x0, x21
    bl   strlen
    mov  x2, x0
    mov  x1, x21
    mov  x0, x19
    bl   h_cancel
    b    9f
.Lr_notfound:
    mov  x0, x19
    mov  w1, #ERR_NOT_FOUND
    ADR_L x2, m_notfound
    bl   send_error
    b    9f
.Lr_method:
    mov  x0, x19
    bl   send_405
9:  LEAVE 3
ENDF route

// =============================================================================
// Request input
// =============================================================================

// conn_fill(x0 conn) -> x0 bytes read (0 = EOF or error). Makes room first
// (compacting consumed bytes, growing the buffer).
//   x19 conn
LFUNC conn_fill
    ENTER 1
    mov  x19, x0
    ldr  x9, [x19, #CN_POS]             // compact
    cbz  x9, 1f
    ldr  x10, [x19, #CN_LEN]
    ldr  x0, [x19, #CN_BUF]
    add  x1, x0, x9
    sub  x2, x10, x9
    str  x2, [x19, #CN_LEN]
    str  xzr, [x19, #CN_POS]
    bl   memmove
1:  ldr  x9, [x19, #CN_LEN]
    ldr  x10, [x19, #CN_CAP]
    sub  x11, x10, x9
    cmp  x11, #4096
    b.hs 2f
    lsl  x10, x10, #1
    mov  x11, #65536
    cmp  x10, x11
    csel x10, x10, x11, hs
    str  x10, [x19, #CN_CAP]
    ldr  x0, [x19, #CN_BUF]
    mov  x1, x10
    bl   realloc
    cbnz x0, 11f
    bl   abort
11: str  x0, [x19, #CN_BUF]
2:  ldr  w0, [x19, #CN_FD]
    ldr  x1, [x19, #CN_BUF]
    ldr  x9, [x19, #CN_LEN]
    add  x1, x1, x9
    ldr  x2, [x19, #CN_CAP]
    sub  x2, x2, x9
    bl   read
    cmp  x0, #0
    b.gt 3f
    b.eq 9f
    bl   __errno_location
    ldr  w0, [x0]
    cmp  w0, #EINTR
    b.eq 2b
    mov  x0, #0
    b    9f
3:  ldr  x9, [x19, #CN_LEN]
    add  x9, x9, x0
    str  x9, [x19, #CN_LEN]
9:  LEAVE 1
ENDF conn_fill

// read_head(x0 conn) -> w0 1 head available (x1 offset just past the blank
// line), 0 connection closed, -1 head too large
//   x19 conn, x20 scan offset
LFUNC read_head
    ENTER 2
    mov  x19, x0
1:  // skip empty lines between requests
    ldr  x9, [x19, #CN_POS]
    ldr  x10, [x19, #CN_LEN]
    sub  x11, x10, x9
    cmp  x11, #2
    b.lo 2f
    ldr  x12, [x19, #CN_BUF]
    ldrb w13, [x12, x9]
    cmp  w13, #'\r'
    b.ne 2f
    add  x14, x9, #1
    ldrb w13, [x12, x14]
    cmp  w13, #'\n'
    b.ne 2f
    add  x9, x9, #2
    str  x9, [x19, #CN_POS]
    b    1b
2:  ldr  x20, [x19, #CN_POS]
3:  ldr  x10, [x19, #CN_LEN]
    add  x11, x20, #4
    cmp  x11, x10
    b.hi 5f
    ldr  x12, [x19, #CN_BUF]
    ldr  w13, [x12, x20]                // unaligned 4-byte load
    movz w14, #0x0a0d
    movk w14, #0x0a0d, lsl #16          // "\r\n\r\n"
    cmp  w13, w14
    b.eq 4f
    add  x20, x20, #1
    b    3b
4:  add  x1, x20, #4
    mov  w0, #1
    b    9f
5:  ldr  x9, [x19, #CN_POS]
    sub  x10, x10, x9
    mov  x11, #HEAD_MAX
    cmp  x10, x11
    b.hs 8f
    sub  x20, x20, x9                   // keep the scan position across
    mov  x0, x19                        // compaction
    bl   conn_fill
    cbz  x0, 7f
    ldr  x9, [x19, #CN_POS]
    add  x20, x20, x9
    b    1b
7:  mov  w0, #0
    b    9f
8:  mov  w0, #-1
9:  LEAVE 2
ENDF read_head

// ci_prefix(x0 ptr, x1 len, x2 lowercase cstr) -> w0 1 if the header name
// [ptr, ptr+len) equals the cstr (ASCII case-insensitive)      (leaf)
LFUNC ci_name_eq
1:  ldrb w9, [x2], #1
    cbz  w9, 3f
    cbz  x1, 2f
    ldrb w10, [x0], #1
    sub  x1, x1, #1
    orr  w10, w10, #0x20
    cmp  w9, w10
    b.eq 1b
2:  mov  w0, #0
    ret
3:  cmp  x1, #0
    cset w0, eq
    ret
ENDF ci_name_eq

// ci_contains(x0 ptr, x1 len, x2 lowercase cstr) -> w0 1/0
//   x19 ptr, x20 len, x21 needle, x22 needle len
LFUNC ci_contains
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x0, x2
    bl   strlen
    mov  x22, x0
1:  cmp  x20, x22
    b.lo 8f
    mov  x0, x19
    mov  x1, x22
    mov  x2, x21
    bl   ci_name_eq
    cbnz w0, 9f
    add  x19, x19, #1
    sub  x20, x20, #1
    b    1b
8:  mov  w0, #0
9:  LEAVE 3
ENDF ci_contains

// METHOD_TRY name, value: if the NUL-terminated method at x20 equals name,
// x23 = value (parse_head)
.macro METHOD_TRY name, val
    mov  x0, x20
    ADR_L x1, \name
    bl   strcmp
    mov  x9, #\val
    cmp  w0, #0
    csel x23, x9, x23, eq
.endm

// parse_head(x0 conn, x1 end offset) -> w0 0 ok, 1 malformed
// Request line and the headers the server uses; consumes the head.
//   x19 conn, x20 cursor, x21 end, x22 line end, x23 scratch, x24 scratch
LFUNC parse_head
    ENTER 4
    mov  x19, x0
    ldr  x9, [x19, #CN_BUF]
    ldr  x10, [x19, #CN_POS]
    add  x20, x9, x10
    add  x21, x9, x1
    str  x1, [x19, #CN_POS]
    mov  x9, #-1
    str  x9, [x19, #CN_CLEN]
    str  xzr, [x19, #CN_CHUNKED]        // also CN_EXPECT
    str  xzr, [x19, #CN_CLOSE]
    str  xzr, [x19, #CN_QLEN]
    str  xzr, [x19, #CN_QOFF]
    // method
    mov  x22, x20
1:  cmp  x22, x21
    b.hs .Lph_bad
    ldrb w9, [x22]
    cmp  w9, #' '
    b.eq 2f
    add  x22, x22, #1
    b    1b
2:  strb wzr, [x22]                     // NUL-terminate in place
    mov  x23, #M_OTHER
    METHOD_TRY s_get, M_GET
    METHOD_TRY s_post, M_POST
    METHOD_TRY s_put, M_PUT
    METHOD_TRY s_delete, M_DELETE
3:  str  x23, [x19, #CN_METHOD]
    add  x20, x22, #1
    // target
    mov  x22, x20
4:  cmp  x22, x21
    b.hs .Lph_bad
    ldrb w9, [x22]
    cmp  w9, #' '
    b.eq 5f
    cmp  w9, #'\r'
    b.eq .Lph_bad
    add  x22, x22, #1
    b    4b
5:  sub  x2, x22, x20
    mov  x9, #(TARGET_MAX - 1)
    cmp  x2, x9
    b.hs .Lph_bad
    add  x0, x19, #CN_TARGET
    mov  x1, x20
    mov  x24, x2
    bl   memcpy
    add  x9, x19, #CN_TARGET
    strb wzr, [x9, x24]
    // split off the query string
    mov  x10, #0
51: cmp  x10, x24
    b.hs 52f
    ldrb w11, [x9, x10]
    cmp  w11, #'?'
    b.eq 53f
    add  x10, x10, #1
    b    51b
53: strb wzr, [x9, x10]
    add  x11, x10, #1
    str  x11, [x19, #CN_QOFF]
    sub  x12, x24, x11
    str  x12, [x19, #CN_QLEN]
52: str  x10, [x19, #CN_PATHLEN]
    // version: HTTP/1.0 closes by default
    add  x20, x22, #1
    add  x9, x20, #8
    cmp  x9, x21
    b.hi .Lph_bad
    ldrb w9, [x20, #7]
    cmp  w9, #'0'
    b.ne 6f
    mov  x9, #1
    str  x9, [x19, #CN_CLOSE]
6:  // skip to the end of the request line
    ldrb w9, [x20]
    cmp  w9, #'\n'
    add  x20, x20, #1
    b.ne 6b
    // headers: name ':' value CRLF, up to the blank line
.Lph_hdr:
    sub  x9, x21, x20
    cmp  x9, #2
    b.ls .Lph_ok                         // only the final CRLF is left
    mov  x22, x20                       // line end
7:  ldrb w9, [x22]
    cmp  w9, #'\n'
    b.eq 8f
    add  x22, x22, #1
    b    7b
8:  mov  x23, x20                       // name end
81: cmp  x23, x22
    b.hs .Lph_next
    ldrb w9, [x23]
    cmp  w9, #':'
    b.eq 82f
    add  x23, x23, #1
    b    81b
82: add  x24, x23, #1                   // value start (trim blanks)
83: ldrb w9, [x24]
    cmp  w9, #' '
    b.eq 84f
    cmp  w9, #'\t'
    b.ne 85f
84: add  x24, x24, #1
    b    83b
85: // content-length
    mov  x0, x20
    sub  x1, x23, x20
    ADR_L x2, h_clen
    bl   ci_name_eq
    cbz  w0, 86f
    mov  x10, #0                        // digits only
    mov  x11, x24
    mov  x12, #0
851: ldrb w9, [x11]
    sub  w9, w9, #'0'
    cmp  w9, #9
    b.hi 852f
    mov  x13, #10
    madd x10, x10, x13, x9
    lsr  x13, x10, #50
    cbnz x13, .Lph_bad                  // absurdly large
    add  x11, x11, #1
    mov  x12, #1
    b    851b
852: cbz  x12, .Lph_bad
    str  x10, [x19, #CN_CLEN]
    b    .Lph_next
86: mov  x0, x20
    sub  x1, x23, x20
    ADR_L x2, h_te
    bl   ci_name_eq
    cbz  w0, 87f
    mov  x0, x24
    sub  x1, x22, x24
    ADR_L x2, v_chunked
    bl   ci_contains
    str  w0, [x19, #CN_CHUNKED]
    b    .Lph_next
87: mov  x0, x20
    sub  x1, x23, x20
    ADR_L x2, h_conn
    bl   ci_name_eq
    cbz  w0, 88f
    mov  x0, x24
    sub  x1, x22, x24
    ADR_L x2, v_close
    bl   ci_contains
    cbz  w0, 871f
    mov  x9, #1
    str  x9, [x19, #CN_CLOSE]
    b    .Lph_next
871: mov  x0, x24
    sub  x1, x22, x24
    ADR_L x2, v_keepalive
    bl   ci_contains
    cbz  w0, .Lph_next
    str  xzr, [x19, #CN_CLOSE]
    b    .Lph_next
88: mov  x0, x20
    sub  x1, x23, x20
    ADR_L x2, h_expect
    bl   ci_name_eq
    cbz  w0, .Lph_next
    mov  x0, x24
    sub  x1, x22, x24
    ADR_L x2, v_continue
    bl   ci_contains
    str  w0, [x19, #CN_EXPECT]
.Lph_next:
    add  x20, x22, #1
    b    .Lph_hdr
.Lph_ok:
    mov  w0, #0
    LEAVE 4
.Lph_bad:
    mov  w0, #1
    LEAVE 4
ENDF parse_head


// conn_take(x0 conn, x1 dst or 0, x2 n) -> w0 0 ok, -1 EOF: n body bytes
// (from the buffer, then the socket); dst 0 discards them.
//   x19 conn, x20 dst, x21 remaining
LFUNC conn_take
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
1:  cbz  x21, 8f
    ldr  x9, [x19, #CN_POS]
    ldr  x10, [x19, #CN_LEN]
    sub  x11, x10, x9
    cbnz x11, 2f
    mov  x0, x19
    bl   conn_fill
    cbz  x0, 9f
    b    1b
2:  cmp  x11, x21
    csel x11, x11, x21, lo
    add  x12, x9, x11
    str  x12, [x19, #CN_POS]
    cbz  x20, 3f
    mov  x0, x20
    ldr  x1, [x19, #CN_BUF]
    add  x1, x1, x9
    mov  x2, x11
    str  x11, [sp, #-16]!
    bl   memcpy
    ldr  x11, [sp], #16
    add  x20, x20, x11
3:  sub  x21, x21, x11
    b    1b
8:  mov  w0, #0
    LEAVE 3
9:  mov  w0, #-1
    LEAVE 3
ENDF conn_take

// conn_line(x0 conn) -> x0 line ptr (in the buffer, valid until the next
// read), x1 length without CRLF; x1 = -1 on EOF, -2 if the line is too long
// or not CRLF terminated.
//   x19 conn, x20 scan offset
LFUNC conn_line
    ENTER 2
    mov  x19, x0
    mov  x20, #0                        // relative to CN_POS
1:  ldr  x9, [x19, #CN_POS]
    ldr  x10, [x19, #CN_LEN]
    ldr  x12, [x19, #CN_BUF]
2:  add  x11, x9, x20
    cmp  x11, x10
    b.hs 4f
    ldrb w13, [x12, x11]
    cmp  w13, #'\n'
    b.eq 3f
    add  x20, x20, #1
    cmp  x20, #LINE_MAX
    b.hs 7f
    b    2b
3:  cbz  x20, 7f                        // LF alone
    sub  x14, x11, #1
    ldrb w13, [x12, x14]
    cmp  w13, #'\r'
    b.ne 7f
    add  x0, x12, x9
    sub  x1, x20, #1
    add  x11, x11, #1
    str  x11, [x19, #CN_POS]
    b    9f
4:  mov  x0, x19
    bl   conn_fill
    cbnz x0, 1b
    mov  x1, #-1
    b    9f
7:  mov  x1, #-2
9:  LEAVE 2
ENDF conn_line

// body_alloc(x0 conn, x1 capacity) — (re)allocate the body Str
//   x19 conn, x20 capacity
LFUNC body_alloc
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    ldr  x0, [x19, #CN_BODY]
    add  x1, x20, #(STR_DATA + 1)
    bl   realloc
    cbnz x0, 1f
    bl   abort
1:  ldr  x9, [x19, #CN_BODY]
    cbnz x9, 2f
    str  xzr, [x0, #STR_LEN]
2:  str  x0, [x19, #CN_BODY]
    LEAVE 2
ENDF body_alloc

// read_body(x0 conn) -> w0 RB_*
//   x19 conn, x20 max bytes, x21 total, x22 capacity, x23 chunk size,
//   x24 line ptr / scratch
LFUNC read_body
    ENTER 4
    mov  x19, x0
    LDR_G x20, g_srv_max_request
    str  xzr, [x19, #CN_BODY]
    ldr  w9, [x19, #CN_CHUNKED]
    cbnz w9, .Lrb_chunked
    ldr  x21, [x19, #CN_CLEN]
    tbnz x21, #63, .Lrb_ok              // no body
    cmp  x21, x20
    b.hi .Lrb_large_cl
    bl   send_continue
    mov  x0, x19
    mov  x1, x21
    bl   body_alloc
    ldr  x9, [x19, #CN_BODY]
    str  x21, [x9, #STR_LEN]
    add  x10, x9, #STR_DATA
    strb wzr, [x10, x21]
    mov  x0, x19
    mov  x1, x10
    mov  x2, x21
    bl   conn_take
    cbnz w0, .Lrb_eof
    b    .Lrb_ok
.Lrb_large_cl:
    // too large: read and discard the declared body (bounded) so the
    // connection stays usable; larger ones close the connection
    mov  x9, #DRAIN_MAX
    cmp  x21, x9
    b.hi 1f
    mov  x0, x19
    mov  x1, #0
    mov  x2, x21
    bl   conn_take
    cbnz w0, .Lrb_eof
    mov  w0, #RB_LARGE
    LEAVE 4
1:  mov  x9, #1
    str  x9, [x19, #CN_CLOSE]
    mov  w0, #RB_LARGE
    LEAVE 4
.Lrb_chunked:
    bl   send_continue
    mov  x21, #0
    mov  x22, #4096
    mov  x0, x19
    mov  x1, x22
    bl   body_alloc
.Lrb_chunk:
    mov  x0, x19
    bl   conn_line
    cmn  x1, #1
    b.eq .Lrb_eof
    tbnz x1, #63, .Lrb_bad
    // chunk-size = 1*HEXDIG [ BWS ; ext ]
    mov  x24, x0
    add  x9, x0, x1                     // line end
    mov  x23, #0
    mov  x10, #0                        // digits seen
2:  cmp  x24, x9
    b.hs 4f
    ldrb w0, [x24]
    stp  x9, x10, [sp, #-16]!
    bl   hexval
    ldp  x9, x10, [sp], #16
    tbnz w0, #31, 3f
    lsl  x23, x23, #4
    add  x23, x23, x0
    add  x10, x10, #1
    lsr  x11, x23, #44
    cbnz x11, .Lrb_large_close          // absurdly large
    add  x24, x24, #1
    b    2b
3:  ldrb w11, [x24]                     // after the digits: blanks, ';'
    cmp  w11, #' '
    b.eq 31f
    cmp  w11, #'\t'
    b.eq 31f
    cmp  w11, #';'
    b.eq 4f
    b    .Lrb_bad
31: add  x24, x24, #1
    cmp  x24, x9
    b.lo 3b
4:  cbz  x10, .Lrb_bad
    cbz  x23, .Lrb_trailer
    add  x9, x21, x23
    cmp  x9, x20
    b.hi .Lrb_large_close
    cmp  x9, x22                        // grow the body buffer
    b.ls 5f
    lsl  x22, x22, #1
    cmp  x22, x9
    csel x22, x22, x9, hs
    mov  x0, x19
    mov  x1, x22
    bl   body_alloc
5:  ldr  x9, [x19, #CN_BODY]
    add  x1, x9, #STR_DATA
    add  x1, x1, x21
    mov  x0, x19
    mov  x2, x23
    bl   conn_take
    cbnz w0, .Lrb_eof
    add  x21, x21, x23
    mov  x0, x19                        // CRLF after the data
    bl   conn_line
    cmn  x1, #1
    b.eq .Lrb_eof
    cbnz x1, .Lrb_bad
    b    .Lrb_chunk
.Lrb_trailer:
    mov  x0, x19
    bl   conn_line
    cmn  x1, #1
    b.eq .Lrb_eof
    tbnz x1, #63, .Lrb_bad
    cbnz x1, .Lrb_trailer
    ldr  x9, [x19, #CN_BODY]
    str  x21, [x9, #STR_LEN]
    add  x10, x9, #STR_DATA
    strb wzr, [x10, x21]
.Lrb_ok:
    mov  w0, #RB_OK
    LEAVE 4
.Lrb_bad:
    mov  x9, #1
    str  x9, [x19, #CN_CLOSE]
    mov  w0, #RB_BAD
    LEAVE 4
.Lrb_large_close:
    mov  x9, #1
    str  x9, [x19, #CN_CLOSE]
    mov  w0, #RB_LARGE
    LEAVE 4
.Lrb_eof:
    mov  w0, #RB_EOF
    LEAVE 4
ENDF read_body

// send_continue(x0 conn): answer "Expect: 100-continue"
LFUNC send_continue
    ENTER 1
    mov  x19, x0
    ldr  w9, [x19, #CN_EXPECT]
    cbz  w9, 9f
    ldr  w0, [x19, #CN_FD]
    ADR_L x1, s_continue
    mov  x2, #25
    mov  w3, #0
    bl   write_all
9:  LEAVE 1
ENDF send_continue

// =============================================================================
// Connection thread
// =============================================================================

// conn_main(x0 fd): serve requests until the client closes, an error makes
// the connection unusable, or Connection: close.
//   x19 conn, w20 status
LFUNC conn_main
    ENTER 2
    mov  x20, x0
    mov  x0, #1
    mov  x1, #CN_SIZE
    bl   calloc
    cbz  x0, .Lcm_exit_fd
    mov  x19, x0
    str  x20, [x19, #CN_FD]
    add  x9, x20, #1
    TLS_ADDR x10, g_conn_fd
    str  x9, [x10]
.Lcm_loop:
    mov  x0, x19
    bl   read_head
    cmp  w0, #0
    b.eq .Lcm_close
    b.lt .Lcm_head_large
    str  x1, [sp, #-16]!                // head end offset
    bl   now_us
    str  x0, [x19, #CN_T0]
    ldr  x1, [sp], #16
    mov  x0, x19
    bl   parse_head
    mov  x9, #1
    ADR_L x10, g_inflight
    stp  x0, x1, [sp, #-16]!
    mov  x0, x10
    mov  x1, x9
    bl   atomic_fetch_add
    ldp  x0, x1, [sp], #16
    cbnz w0, .Lcm_bad
    mov  x0, x19
    bl   read_body
    cmp  w0, #RB_EOF
    b.eq .Lcm_eof_inflight
    cmp  w0, #RB_BAD
    b.eq .Lcm_bad
    cmp  w0, #RB_LARGE
    b.eq .Lcm_large
    mov  x0, x19
    bl   route
    b    .Lcm_done
.Lcm_bad:
    mov  x9, #1
    str  x9, [x19, #CN_CLOSE]
    mov  x0, x19
    mov  w1, #ERR_INVALID_REQUEST
    ADR_L x2, m_badreq
    bl   send_error
    b    .Lcm_done
.Lcm_large:
    mov  x0, x19
    mov  w1, #ERR_RESOURCE_LIMIT
    ADR_L x2, m_toolarge
    bl   send_error
.Lcm_done:
    mov  x0, x19
    bl   log_request
    bl   request_cleanup
    ldr  x0, [x19, #CN_BODY]
    str  xzr, [x19, #CN_BODY]
    bl   free
    ADR_L x0, g_inflight
    mov  x1, #-1
    bl   atomic_fetch_add
    ldr  x9, [x19, #CN_CLOSE]
    cbz  x9, .Lcm_loop
    b    .Lcm_close_drain
.Lcm_head_large:
    mov  x9, #1
    str  x9, [x19, #CN_CLOSE]
    mov  x0, x19
    mov  w1, #ERR_INVALID_REQUEST
    ADR_L x2, m_badreq
    bl   send_error
    b    .Lcm_close_drain
.Lcm_eof_inflight:
    ldr  x0, [x19, #CN_BODY]
    str  xzr, [x19, #CN_BODY]
    bl   free
    ADR_L x0, g_inflight
    mov  x1, #-1
    bl   atomic_fetch_add
    b    .Lcm_close
.Lcm_close_drain:
    // closing with unread input would reset the connection and could
    // destroy the response in flight: half-close, then drain briefly
    ldr  w0, [x19, #CN_FD]
    mov  w1, #SHUT_WR
    bl   shutdown
    bl   drain_input
.Lcm_close:
    ldr  w0, [x19, #CN_FD]
    bl   close
    ldr  x0, [x19, #CN_BUF]
    bl   free
    mov  x0, x19
    bl   free
    bl   thread_cleanup
    mov  x0, #0
    LEAVE 2
.Lcm_exit_fd:
    mov  w0, w20
    bl   close
    mov  x0, #0
    LEAVE 2
ENDF conn_main

// drain_input(): read and discard input on this thread's connection for at
// most ~1 s (until EOF), so a half-closed client receives the response.
//   w19 fd, x20 deadline; locals [sp] pollfd, [sp+16] scratch (512)
LFUNC drain_input
    ENTER 2
    sub  sp, sp, #528
    TLS_LDR x19, g_conn_fd
    sub  x19, x19, #1
    bl   now_us
    mov  x9, #0x4240
    movk x9, #0xf, lsl #16              // 1 000 000 µs
    add  x20, x0, x9
1:  bl   now_us
    cmp  x0, x20
    b.hs 9f
    str  w19, [sp]
    mov  w9, #POLLIN
    strh w9, [sp, #4]
    strh wzr, [sp, #6]
    mov  x0, sp
    mov  x1, #1
    mov  w2, #100
    bl   poll
    cmp  w0, #0
    b.le 1b
    mov  w0, w19
    add  x1, sp, #16
    mov  x2, #512
    bl   read
    cmp  x0, #0
    b.gt 1b
9:  add  sp, sp, #528
    LEAVE 2
ENDF drain_input

// log_request(x0 conn): debug event per request (method, path, status,
// duration); never the body or query parameters
//   x19 conn
LFUNC log_request
    ENTER 1
    mov  x19, x0
    mov  w0, #LOG_DEBUG
    ADR_L x1, l_request
    bl   log_begin
    cbz  w0, 9f
    ldr  x9, [x19, #CN_METHOD]
    ADR_L x10, method_names
    ldr  x1, [x10, x9, lsl #3]
    mov  x0, x1
    str  x1, [sp, #-16]!
    bl   strlen
    mov  x2, x0
    ldr  x1, [sp], #16
    ADR_L x0, k_method
    bl   log_str
    ADR_L x0, k_path
    add  x1, x19, #CN_TARGET
    ldr  x2, [x19, #CN_PATHLEN]
    bl   log_str
    ADR_L x0, k_hstatus
    ldr  x1, [x19, #CN_STATUS]
    bl   log_int
    bl   now_us
    ldr  x9, [x19, #CN_T0]
    sub  x1, x0, x9
    mov  x9, #1000
    udiv x1, x1, x9
    ADR_L x0, k_duration
    bl   log_int
    bl   log_end
9:  LEAVE 1
ENDF log_request

// request_cleanup(): per-request state of the connection thread
LFUNC request_cleanup
    ENTER 0
    TLS_ADDR x9, g_qid
    ldr  x0, [x9]
    str  xzr, [x9]
    bl   free
    TLS_ADDR x0, g_arena
    bl   arena_free
    LEAVE 0
ENDF request_cleanup

// thread_cleanup(): free the thread's persistent buffers before it exits
LFUNC thread_cleanup
    ENTER 1
    .irp b, g_out, g_hdr, g_pq_out, g_pq_meta
    TLS_ADDR x19, \b
    ldr  x0, [x19, #BUF_PTR]
    str  xzr, [x19, #BUF_PTR]
    stp  xzr, xzr, [x19, #BUF_LEN]
    bl   free
    .endr
    bl   log_thread_cleanup
    LEAVE 1
ENDF thread_cleanup

// =============================================================================
// Listener, signals and shutdown
// =============================================================================

// on_signal(w0 signo): async-signal-safe; wakes the accept loop
LFUNC on_signal
    sub  sp, sp, #16
    stp  x29, x30, [sp]
    mov  x29, sp
    ADR_L x9, g_sig_pipe
    ldr  w0, [x9, #4]
    ADR_L x1, s_crlf
    mov  x2, #1
    bl   write
    ldp  x29, x30, [sp]
    add  sp, sp, #16
    ret
ENDF on_signal

// serve_main(): never returns.
//   x19 listen fd, x20 scratch, x21 deadline / fd; locals: [sp] sockaddr_in
//   (16), [sp+16] socklen / pollfd[2] (16), [sp+32] timespec (16), [sp+48]
//   int one, [sp+64] text (128)
FUNC serve_main
    ENTER 3
    sub  sp, sp, #192
    mov  w0, #SIGPIPE
    mov  x1, #1                         // SIG_IGN
    bl   signal
    mov  x0, sp                         // probe the CRC implementation now,
    mov  x1, #0                         // before any thread exists
    bl   crc32
    bl   cat_init
    bl   srv_init
    // address
    stp  xzr, xzr, [sp]
    mov  w9, #AF_INET
    strh w9, [sp]
    LDR_G x9, g_srv_port
    rev16 w9, w9
    strh w9, [sp, #2]
    mov  w0, #AF_INET
    LDR_G x1, g_srv_host
    add  x2, sp, #4
    bl   inet_pton
    cmp  w0, #1
    b.eq 1f
    LDR_G x0, g_srv_host
    ADR_L x1, s_localhost
    bl   strcmp
    cbnz w0, .Lsm_badhost
    mov  w0, #AF_INET
    ADR_L x1, s_loopback
    add  x2, sp, #4
    bl   inet_pton
1:  mov  w0, #AF_INET
    ldr  w1, =(SOCK_STREAM | SOCK_CLOEXEC)
    mov  w2, #0
    bl   socket
    tbnz w0, #31, .Lsm_bindfail
    mov  w19, w0
    mov  w9, #1
    str  w9, [sp, #48]
    mov  w0, w19
    mov  w1, #SOL_SOCKET
    mov  w2, #SO_REUSEADDR
    add  x3, sp, #48
    mov  w4, #4
    bl   setsockopt
    mov  w0, w19
    mov  x1, sp
    mov  w2, #16
    bl   bind
    cbnz w0, .Lsm_bindfail
    mov  w0, w19
    mov  w1, #512
    bl   listen
    cbnz w0, .Lsm_bindfail
    mov  w9, #16
    str  w9, [sp, #16]
    mov  w0, w19
    mov  x1, sp
    add  x2, sp, #16
    bl   getsockname
    ldrh w20, [sp, #2]
    rev16 w20, w20
    ADR_L x9, g_listen_fd
    str  x19, [x9]
    // connection threads: detached, 16 MiB stacks
    ADR_L x0, g_thread_attr
    bl   pthread_attr_init
    ADR_L x0, g_thread_attr
    mov  w1, #1                         // PTHREAD_CREATE_DETACHED
    bl   pthread_attr_setdetachstate
    ADR_L x0, g_thread_attr
    mov  x1, #(16*1024*1024)
    bl   pthread_attr_setstacksize
    // signals -> self-pipe
    ADR_L x0, g_sig_pipe
    ldr  w1, =(O_NONBLOCK | O_CLOEXEC)
    bl   pipe2
    mov  w0, #SIGTERM
    ADR_L x1, on_signal
    bl   signal
    mov  w0, #SIGINT
    ADR_L x1, on_signal
    bl   signal
    // the listening line (stdout, exactly one line)
    add  x0, sp, #64
    mov  x1, #128
    ADR_L x2, f_listening
    LDR_G x3, g_srv_host
    mov  w4, w20
    bl   snprintf
    add  x0, sp, #64
    bl   strlen
    mov  x2, x0
    mov  w0, #1
    add  x1, sp, #64
    bl   write
    mov  w0, #LOG_INFO
    ADR_L x1, l_listening
    bl   log_begin
    cbz  w0, .Lsm_accept
    ADR_L x0, k_port
    mov  x1, x20
    bl   log_int
    ADR_L x0, k_workers
    LDR_G x1, g_srv_workers
    bl   log_int
    bl   log_end
.Lsm_accept:
    str  w19, [sp, #16]                 // pollfd[0]: listening socket
    mov  w9, #POLLIN
    str  w9, [sp, #20]                  // events = POLLIN, revents = 0
    ADR_L x9, g_sig_pipe
    ldr  w9, [x9]
    str  w9, [sp, #24]                  // pollfd[1]: signal pipe
    mov  w9, #POLLIN
    str  w9, [sp, #28]
    add  x0, sp, #16
    mov  x1, #2
    mov  w2, #-1
    bl   poll
    cmp  w0, #0
    b.le .Lsm_accept
    ldrh w9, [sp, #30]
    cbnz w9, .Lsm_shutdown
    ldrh w9, [sp, #22]
    cbz  w9, .Lsm_accept
    mov  w0, w19
    mov  x1, #0
    mov  x2, #0
    mov  w3, #SOCK_CLOEXEC
    bl   accept4
    tbnz w0, #31, .Lsm_accept
    mov  w21, w0
    mov  w9, #1                         // TCP_NODELAY: no Nagle delays
    str  w9, [sp, #48]
    mov  w0, w21
    mov  w1, #IPPROTO_TCP
    mov  w2, #TCP_NODELAY
    add  x3, sp, #48
    mov  w4, #4
    bl   setsockopt
    mov  x9, #0                         // SO_SNDTIMEO 100 ms: blocked
    ldr  x10, =100000                   // writes re-check cancellation
    stp  x9, x10, [sp, #32]
    mov  w0, w21
    mov  w1, #SOL_SOCKET
    mov  w2, #SO_SNDTIMEO
    add  x3, sp, #32
    mov  w4, #16
    bl   setsockopt
    add  x0, sp, #56                    // pthread_t (unused)
    ADR_L x1, g_thread_attr
    ADR_L x2, conn_main
    mov  x3, x21
    bl   pthread_create
    cbz  w0, .Lsm_accept
    mov  w0, w21                        // no thread: drop the connection
    bl   close
    b    .Lsm_accept
.Lsm_shutdown:
    // 1. stop accepting; queries on open connections get SHUTTING_DOWN
    ADR_L x9, g_srv_shutdown
    mov  x10, #1
    stlr x10, [x9]
    mov  w0, w19
    bl   close
    mov  w0, #LOG_INFO
    ADR_L x1, l_shutdown
    bl   log_begin
    cbz  w0, 2f
    ADR_L x0, k_inflight
    LDR_G x1, g_inflight
    bl   log_int
    bl   log_end
2:  // 2. let running and queued requests finish within the grace period
    bl   now_us
    LDR_G x9, g_srv_grace_ms
    mov  x10, #1000
    madd x21, x9, x10, x0
    bl   wait_idle
    // 3. cancel what is still running, give it a moment to answer
    ADR_L x9, g_inflight
    ldar x9, [x9]
    cbz  x9, 3f
    bl   srv_cancel_all
    bl   now_us
    mov  x9, #0x8480
    movk x9, #0x1e, lsl #16             // 2 000 000 µs
    add  x21, x0, x9
    bl   wait_idle
3:  mov  w0, #LOG_INFO
    ADR_L x1, l_stopped
    bl   log_begin
    cbz  w0, 4f
    bl   log_end
4:  // 4. exit 0
    mov  w0, #0
    bl   exit
.Lsm_badhost:
    GOT_LOAD x0, stderr
    ADR_L x1, m_badhost
    LDR_G x2, g_srv_host
    bl   fprintf
    mov  w0, #1
    bl   exit
.Lsm_bindfail:
    GOT_LOAD x0, stderr
    ADR_L x1, m_bind
    LDR_G x2, g_srv_host
    LDR_G x3, g_srv_port
    bl   fprintf
    mov  w0, #1
    bl   exit
ENDF serve_main

// wait_idle(x21 deadline µs): sleep in 5 ms steps until no HTTP request is
// in flight or the deadline passes. (Uses the caller's x21; preserves it.)
LFUNC wait_idle
    ENTER 0
    sub  sp, sp, #16
1:  ADR_L x9, g_inflight
    ldar x9, [x9]
    cbz  x9, 9f
    bl   now_us
    cmp  x0, x21
    b.hs 9f
    mov  x9, #0
    mov  x10, #0x4b40
    movk x10, #0x4c, lsl #16            // 5 000 000 ns
    stp  x9, x10, [sp]
    mov  x0, sp
    mov  x1, #0
    bl   nanosleep
    b    1b
9:  add  sp, sp, #16
    LEAVE 0
ENDF wait_idle

    NOTE_GNU_STACK
