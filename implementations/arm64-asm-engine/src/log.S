// =============================================================================
// log.S — structured logs (protocol.md §7.4): one JSON object per line on
// stderr with "ts" (RFC 3339 UTC, milliseconds), "level" and "msg", plus
// event fields. Each line is assembled in a thread-local buffer and written
// with a single write(2), so lines of concurrent threads never interleave.
//
//   log_begin(w0 LOG_*, x1 msg cstr) -> w0 1 if the level is enabled
//       (only then may log_str / log_int / log_end be called)
//   log_str(x0 key cstr, x1 ptr, x2 len)    ,"key":"…"
//   log_int(x0 key cstr, x1 value)          ,"key":123
//   log_end()                               finishes and writes the line
//   log_level_parse(x0 cstr) -> w0 LOG_* or -1
//
// g_log_level: lowest level written (LOG_OFF = nothing). Logs must never
// contain table data or request bodies at info level: callers only pass
// identifiers, codes, counts and durations.
// =============================================================================
#include "pq.inc"
#include "frame.inc"

    .data
    .p2align 2
    .global g_log_level
g_log_level:    .word LOG_INFO

    TBSS
    .p2align 3
g_log:          .skip BUF_SIZE          // line being built (this thread)

    .section .rodata
    .p2align 3
level_names:
    .quad s_debug, s_info, s_warn, s_error, s_off
s_debug:    .asciz "debug"
s_info:     .asciz "info"
s_warn:     .asciz "warn"
s_error:    .asciz "error"
s_off:      .asciz "off"
f_ts:       .asciz "{\"ts\":\"%04d-%02d-%02dT%02d:%02d:%02d.%03dZ\",\"level\":\""
s_msg:      .asciz "\",\"msg\":"
    .text

// log_begin(w0 level, x1 msg) -> w0 1 if enabled
//   w19 level, x20 msg; locals: [sp] timespec, [sp+16] struct tm (56 bytes),
//   [sp+80] text (64 bytes)
FUNC log_begin
    ENTER 2
    sub  sp, sp, #160
    mov  w19, w0
    mov  x20, x1
    ADR_L x9, g_log_level
    ldr  w9, [x9]
    cmp  w19, w9
    b.lo 8f
    cmp  w19, #LOG_OFF
    b.hs 8f
    mov  w0, #0                         // CLOCK_REALTIME
    mov  x1, sp
    bl   clock_gettime
    mov  x0, sp
    add  x1, sp, #16
    bl   gmtime_r
    ldr  x9, [sp, #8]                   // milliseconds
    mov  x10, #16960
    movk x10, #0xf, lsl #16             // 1 000 000
    udiv x9, x9, x10
    sub  sp, sp, #16                    // variadic arguments 8 and 9
    ldr  w10, [sp, #(16 + 16)]          // tm_sec
    stp  x10, x9, [sp]
    add  x0, sp, #(16 + 80)
    mov  x1, #64
    ADR_L x2, f_ts
    ldr  w3, [sp, #(16 + 16 + 20)]      // tm_year
    add  w3, w3, #1900
    ldr  w4, [sp, #(16 + 16 + 16)]      // tm_mon
    add  w4, w4, #1
    ldr  w5, [sp, #(16 + 16 + 12)]      // tm_mday
    ldr  w6, [sp, #(16 + 16 + 8)]       // tm_hour
    ldr  w7, [sp, #(16 + 16 + 4)]       // tm_min
    bl   snprintf
    add  sp, sp, #16
    TLS_ADDR x0, g_log
    str  xzr, [x0, #BUF_LEN]
    add  x1, sp, #80
    bl   buf_puts
    TLS_ADDR x0, g_log
    ADR_L x1, level_names
    ldr  x1, [x1, w19, uxtw #3]
    bl   buf_puts
    TLS_ADDR x0, g_log
    ADR_L x1, s_msg
    bl   buf_puts
    mov  x0, x20
    bl   strlen
    mov  x2, x0
    mov  x1, x20
    TLS_ADDR x0, g_log
    bl   buf_put_jstr
    mov  w0, #1
    b    9f
8:  mov  w0, #0
9:  add  sp, sp, #160
    LEAVE 2
ENDF log_begin

// log_key(x0 key cstr): ,"key":
LFUNC log_key
    ENTER 1
    mov  x19, x0
    TLS_ADDR x0, g_log
    mov  w1, #','
    bl   buf_putc
    mov  x0, x19
    bl   strlen
    mov  x2, x0
    mov  x1, x19
    TLS_ADDR x0, g_log
    bl   buf_put_jstr
    TLS_ADDR x0, g_log
    mov  w1, #':'
    bl   buf_putc
    LEAVE 1
ENDF log_key

// log_str(x0 key, x1 ptr, x2 len)
FUNC log_str
    ENTER 2
    mov  x19, x1
    mov  x20, x2
    bl   log_key
    TLS_ADDR x0, g_log
    mov  x1, x19
    mov  x2, x20
    bl   buf_put_jstr
    LEAVE 2
ENDF log_str

// log_int(x0 key, x1 value)
FUNC log_int
    ENTER 1
    mov  x19, x1
    bl   log_key
    TLS_ADDR x0, g_log
    mov  x1, x19
    bl   buf_put_i64
    LEAVE 1
ENDF log_int

// log_end(): close the object and write the line to stderr
//   x19 ptr, x20 remaining
FUNC log_end
    ENTER 2
    TLS_ADDR x0, g_log
    mov  w1, #'}'
    bl   buf_putc
    TLS_ADDR x0, g_log
    mov  w1, #'\n'
    bl   buf_putc
    TLS_ADDR x0, g_log
    ldr  x19, [x0, #BUF_PTR]
    ldr  x20, [x0, #BUF_LEN]
1:  cbz  x20, 9f
    mov  w0, #2
    mov  x1, x19
    mov  x2, x20
    bl   write
    cmp  x0, #0
    b.le 9f
    add  x19, x19, x0
    sub  x20, x20, x0
    b    1b
9:  LEAVE 2
ENDF log_end

// log_level_parse(x0 cstr) -> w0 LOG_* or -1
//   x19 text, x20 level
FUNC log_level_parse
    ENTER 2
    mov  x19, x0
    mov  x20, #0
1:  cmp  x20, #LOG_OFF
    b.hi 8f
    ADR_L x9, level_names
    ldr  x1, [x9, x20, lsl #3]
    mov  x0, x19
    bl   strcmp
    cbz  w0, 9f
    add  x20, x20, #1
    b    1b
8:  mov  x20, #-1
9:  mov  w0, w20
    LEAVE 2
ENDF log_level_parse

// log_thread_cleanup(): free this thread's line buffer (thread exit)
FUNC log_thread_cleanup
    ENTER 0
    TLS_ADDR x9, g_log
    ldr  x0, [x9, #BUF_PTR]
    stp  xzr, xzr, [x9]
    str  xzr, [x9, #BUF_CAP]
    bl   free
    LEAVE 0
ENDF log_thread_cleanup

    NOTE_GNU_STACK
