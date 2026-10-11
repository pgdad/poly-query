// =============================================================================
// rt.S — runtime support: error raising, arenas, strings, byte buffers, time.
//
// Error model: a request handler calls setjmp(g_jmpbuf); pq_raise* records the
// error (code, message, optional position) and longjmp()s back. All memory a
// request allocates comes from g_arena, which the dispatcher frees after each
// request, so unwinding never leaks.
// =============================================================================
#include "pq.inc"

#define ARENA_CHUNK   (256*1024)       // default chunk payload size
#define ERRMSG_MAX    1024

// ------------------------------------------------------------------ data -----
    // per-thread request state (thread-local)
    TBSS
    .p2align 4
    .global g_arena, g_out, g_jmpbuf, g_err_msg
g_arena:        .skip AR_SIZE
g_out:          .skip BUF_SIZE
g_jmpbuf:       .skip 512
g_err_msg:      .skip ERRMSG_MAX

    .p2align 3
    .global g_deadline, g_pending_table, g_err_code
    .global g_err_line, g_err_col, g_arena_limit, g_cancel_flag
g_cancel_flag:   .skip 8       // u32* cancellation flag of the running query, or 0
g_deadline:      .skip 8       // µs (CLOCK_MONOTONIC); 0 = no deadline
g_pending_table: .skip 8       // Table* under construction (freed on error)
g_arena_limit:   .skip 8       // max bytes in g_arena chunks; 0 = unlimited
g_err_code:      .skip 4
g_err_line:      .skip 4
g_err_col:       .skip 4

    // process-wide settings (written once by main before any thread starts)
    .bss
    .p2align 3
    .global g_data_dir, g_test_functions
g_data_dir:      .skip 8       // cstr data directory (set by main)
g_test_functions: .skip 4

    .data
    .p2align 3
    .global g_max_query_mem, g_max_ingest_bytes, g_max_table_rows, g_max_join_rows
g_max_query_mem:    .quad 4096*1024*1024
g_max_ingest_bytes: .quad 4*1024*1024*1024
g_max_table_rows:   .quad 200000000
g_max_join_rows:    .quad 100000000

    .section .rodata
    .p2align 3
err_names:
    .quad s_none, s_parse, s_semantic, s_type, s_overflow, s_div0, s_conv
    .quad s_invarg, s_invreq, s_ingest, s_unsup, s_access, s_notfound
    .quad s_exists, s_reslimit, s_io, s_internal, s_timeout, s_subq, s_cancel
    .quad s_corrupt, s_version, s_overload, s_shutdown
s_none:     .asciz "INTERNAL_ERROR"
s_parse:    .asciz "PARSE_ERROR"
s_semantic: .asciz "SEMANTIC_ERROR"
s_type:     .asciz "TYPE_ERROR"
s_overflow: .asciz "NUMERIC_OVERFLOW"
s_div0:     .asciz "DIVISION_BY_ZERO"
s_conv:     .asciz "CONVERSION_ERROR"
s_invarg:   .asciz "INVALID_ARGUMENT"
s_invreq:   .asciz "INVALID_REQUEST"
s_ingest:   .asciz "INGEST_ERROR"
s_unsup:    .asciz "UNSUPPORTED"
s_access:   .asciz "ACCESS_DENIED"
s_notfound: .asciz "NOT_FOUND"
s_exists:   .asciz "ALREADY_EXISTS"
s_reslimit: .asciz "RESOURCE_LIMIT"
s_io:       .asciz "IO_ERROR"
s_internal: .asciz "INTERNAL_ERROR"
s_timeout:  .asciz "TIMEOUT"
s_subq:     .asciz "SUBQUERY_CARDINALITY"
s_cancel:   .asciz "CANCELLED"
s_corrupt:  .asciz "STORAGE_CORRUPT"
s_version:  .asciz "STORAGE_VERSION_UNSUPPORTED"
s_overload: .asciz "OVERLOADED"
s_shutdown: .asciz "SHUTTING_DOWN"
s_oom:      .asciz "out of memory"
s_qmem:     .asciz "query memory budget exceeded"
s_timeoutm: .asciz "query timeout exceeded"
s_cancelm:  .asciz "query cancelled"
fmt_g:      .asciz "%.*g"
    .text

// ---------------------------------------------------------------- errors -----

// err_code_name(w0 code) -> x0 cstr
FUNC err_code_name
    cmp  w0, #ERR_LAST
    b.ls 1f
    mov  w0, #ERR_INTERNAL
1:  ADR_L x1, err_names
    ldr  x0, [x1, w0, uxtw #3]
    ret
ENDF err_code_name

// copy_errmsg(x0 dst offset, x1 src, x2 len) -> x0 new offset   (leaf)
// Appends bytes to g_err_msg, truncating at ERRMSG_MAX-1, keeps NUL terminated.
LFUNC copy_errmsg
    TLS_ADDR x3, g_err_msg
1:  cbz  x2, 2f
    cmp  x0, #ERRMSG_MAX-1
    b.hs 2f
    ldrb w4, [x1], #1
    strb w4, [x3, x0]
    add  x0, x0, #1
    sub  x2, x2, #1
    b    1b
2:  strb wzr, [x3, x0]
    ret
ENDF copy_errmsg

// data_path(x0 Str* relative path) -> x0 cstr "<data_dir>/<path>" (request
// arena). The caller has validated the path (protocol.md §6).
//   x19 path, x20 dir length, x21 result
FUNC data_path
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    str  x21, [sp, #32]
    mov  x19, x0
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
    add  x2, x2, #1                 // include the NUL
    bl   memcpy
    mov  x0, x21
    ldp  x19, x20, [sp, #16]
    ldr  x21, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
ENDF data_path

// pq_raise(w0 code, x1 msg cstr) — noreturn
FUNC pq_raise
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    mov  w19, w0
    mov  x20, x1
    mov  x0, x1
    bl   strlen
    mov  x2, x0
    mov  x1, x20
    mov  x0, #0
    bl   copy_errmsg
    mov  w0, w19
    mov  w2, #0
    mov  w3, #0
    b    raise_common
ENDF pq_raise

// pq_raise_n(w0 code, x1 msg ptr, x2 msg len) — noreturn (re-raises an
// error recorded elsewhere, e.g. by a worker thread)
FUNC pq_raise_n
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    str  x19, [sp, #16]
    mov  w19, w0
    mov  x0, #0
    bl   copy_errmsg
    mov  w0, w19
    mov  w2, #0
    mov  w3, #0
    b    raise_common
ENDF pq_raise_n

// arena_adopt(x0 dst Arena*, x1 src Arena*): moves every chunk of src into
// dst (freed with dst); src becomes empty.
FUNC arena_adopt
    ldr  x2, [x1, #AR_CHUNKS]
    cbz  x2, 3f
1:  ldr  x3, [x2]                       // find the tail of src's list
    cbz  x3, 2f
    mov  x2, x3
    b    1b
2:  ldr  x3, [x0, #AR_CHUNKS]
    str  x3, [x2]
    ldr  x3, [x1, #AR_CHUNKS]
    str  x3, [x0, #AR_CHUNKS]
    ldr  x3, [x0, #AR_TOTAL]
    ldr  x4, [x1, #AR_TOTAL]
    add  x3, x3, x4
    str  x3, [x0, #AR_TOTAL]
3:  stp  xzr, xzr, [x1, #AR_CUR]
    stp  xzr, xzr, [x1, #AR_CHUNKS]
    ret
ENDF arena_adopt

// pq_raise_pos(w0 code, x1 msg, w2 line, w3 col) — noreturn
FUNC pq_raise_pos
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    mov  w19, w0
    mov  x20, x1
    mov  w21, w2
    mov  w22, w3
    mov  x0, x1
    bl   strlen
    mov  x2, x0
    mov  x1, x20
    mov  x0, #0
    bl   copy_errmsg
    mov  w0, w19
    mov  w2, w21
    mov  w3, w22
    b    raise_common
ENDF pq_raise_pos

// pq_raise_s(w0 code, x1 prefix cstr, x2 ptr, x3 len) — noreturn
FUNC pq_raise_s
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    mov  w19, w0
    mov  x20, x1
    mov  x21, x2
    mov  x22, x3
    mov  x0, x1
    bl   strlen
    mov  x2, x0
    mov  x1, x20
    mov  x0, #0
    bl   copy_errmsg
    sub  sp, sp, #16
    mov  w1, #'\''
    strb w1, [sp]
    mov  x20, x0
    mov  x1, sp
    mov  x2, #1
    bl   copy_errmsg
    cmp  x22, #200
    mov  x2, #200
    csel x2, x2, x22, hi
    mov  x1, x21
    bl   copy_errmsg
    mov  x1, sp
    mov  x2, #1
    bl   copy_errmsg
    add  sp, sp, #16
    mov  w0, w19
    mov  w2, #0
    mov  w3, #0
    b    raise_common
ENDF pq_raise_s

// raise_common(w0 code, w2 line, w3 col): record and longjmp (never returns)
LFUNC raise_common
    TLS_ADDR x4, g_err_code
    str  w0, [x4]
    TLS_ADDR x4, g_err_line
    str  w2, [x4]
    TLS_ADDR x4, g_err_col
    str  w3, [x4]
    TLS_ADDR x0, g_jmpbuf
    mov  w1, #1
    bl   longjmp
    brk  #0
ENDF raise_common

// ---------------------------------------------------------------- arenas -----

// arena_alloc_in(x0 Arena*, x1 size) -> x0 ptr (16-byte aligned)
FUNC arena_alloc_in
    add  x1, x1, #15
    and  x1, x1, #~15
    ldr  x2, [x0, #AR_CUR]
    ldr  x3, [x0, #AR_END]
    add  x4, x2, x1
    cmp  x4, x3
    b.hi 1f
    cbz  x2, 1f
    str  x4, [x0, #AR_CUR]
    mov  x0, x2
    ret
1:  // slow path: new chunk of max(size, ARENA_CHUNK) + 16 header bytes
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    mov  x19, x0
    mov  x20, x1
    mov  x21, #ARENA_CHUNK
    cmp  x1, x21
    csel x21, x1, x21, hi
    add  x21, x21, #16                  // chunk bytes incl. header
    // memory budget for the request arena
    TLS_ADDR x2, g_arena
    cmp  x0, x2
    b.ne 2f
    TLS_LDR x3, g_arena_limit
    cbz  x3, 2f
    ldr  x4, [x0, #AR_TOTAL]
    add  x4, x4, x21
    cmp  x4, x3
    b.ls 2f
    mov  w0, #ERR_RESOURCE_LIMIT
    ADR_L x1, s_qmem
    bl   pq_raise
2:  mov  x0, x21
    bl   malloc
    cbnz x0, 3f
    mov  w0, #ERR_RESOURCE_LIMIT
    ADR_L x1, s_oom
    bl   pq_raise
3:  ldr  x2, [x19, #AR_CHUNKS]
    str  x2, [x0]                       // chunk->next
    str  x21, [x0, #8]                  // chunk->size
    str  x0, [x19, #AR_CHUNKS]
    ldr  x2, [x19, #AR_TOTAL]
    add  x2, x2, x21
    str  x2, [x19, #AR_TOTAL]
    add  x3, x0, #16                    // payload start
    add  x4, x0, x21                    // chunk end
    add  x5, x3, x20                    // after this allocation
    str  x5, [x19, #AR_CUR]
    str  x4, [x19, #AR_END]
    mov  x0, x3
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
ENDF arena_alloc_in

// arena_alloc(x0 size) -> x0 ptr  (request arena)
FUNC arena_alloc
    mov  x1, x0
    TLS_ADDR x0, g_arena
    b    arena_alloc_in
ENDF arena_alloc

// arena_zalloc(x0 size) -> x0 zeroed ptr (request arena)
FUNC arena_zalloc
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    str  x19, [sp, #16]
    mov  x19, x0
    bl   arena_alloc
    mov  x2, x19
    mov  w1, #0
    bl   memset
    ldr  x19, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF arena_zalloc

// arena_free(x0 Arena*): release every chunk; the arena is empty afterwards.
FUNC arena_free
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    mov  x19, x0
    ldr  x20, [x0, #AR_CHUNKS]
1:  cbz  x20, 2f
    mov  x0, x20
    ldr  x20, [x20]
    bl   free
    b    1b
2:  stp  xzr, xzr, [x19, #AR_CUR]
    stp  xzr, xzr, [x19, #AR_CHUNKS]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF arena_free

// --------------------------------------------------------------- strings -----

// str_new_in(x0 Arena*, x1 ptr, x2 len) -> x0 Str*
FUNC str_new_in
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    str  x21, [sp, #32]
    mov  x19, x1
    mov  x20, x2
    add  x1, x2, #STR_DATA+1
    bl   arena_alloc_in
    mov  x21, x0
    str  x20, [x0, #STR_LEN]
    add  x0, x0, #STR_DATA
    mov  x1, x19
    mov  x2, x20
    bl   memcpy
    add  x0, x21, #STR_DATA
    strb wzr, [x0, x20]
    mov  x0, x21
    ldp  x19, x20, [sp, #16]
    ldr  x21, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
ENDF str_new_in

// str_new(x0 ptr, x1 len) -> x0 Str* (request arena)
FUNC str_new
    mov  x2, x1
    mov  x1, x0
    TLS_ADDR x0, g_arena
    b    str_new_in
ENDF str_new

// lower(w) helper inline: if 'A'<=w<='Z' then w+=32
.macro TOLOWER w, tmp
    sub  \tmp, \w, #'A'
    cmp  \tmp, #25
    b.hi 8888f
    add  \w, \w, #32
8888:
.endm

// ci_eq(x0 p1, x1 l1, x2 p2, x3 l2) -> w0 1/0   (leaf)
FUNC ci_eq
    cmp  x1, x3
    b.ne 9f
1:  cbz  x1, 8f
    ldrb w4, [x0], #1
    ldrb w5, [x2], #1
    TOLOWER w4, w6
    TOLOWER w5, w6
    cmp  w4, w5
    b.ne 9f
    sub  x1, x1, #1
    b    1b
8:  mov  w0, #1
    ret
9:  mov  w0, #0
    ret
ENDF ci_eq

// ci_cmp(x0 p1, x1 l1, x2 p2, x3 l2) -> w0 <0/0/>0   (leaf)
FUNC ci_cmp
    mov  x7, #0
1:  cmp  x7, x1
    b.hs 7f
    cmp  x7, x3
    b.hs 6f                     // p2 exhausted: p1 longer => >0
    ldrb w4, [x0, x7]
    ldrb w5, [x2, x7]
    TOLOWER w4, w6
    TOLOWER w5, w6
    subs w8, w4, w5
    b.ne 8f
    add  x7, x7, #1
    b    1b
6:  mov  w0, #1
    ret
7:  cmp  x7, x3
    cset w0, lo
    neg  w0, w0                 // p1 exhausted: shorter => -1, equal => 0
    ret
8:  mov  w0, w8
    ret
ENDF ci_cmp

// str_ieq(x0 Str*, x1 Str*) -> w0
FUNC str_ieq
    ldr  x3, [x1, #STR_LEN]
    add  x2, x1, #STR_DATA
    ldr  x1, [x0, #STR_LEN]
    add  x0, x0, #STR_DATA
    b    ci_eq
ENDF str_ieq

// str_ieq_c(x0 Str*, x1 cstr) -> w0
FUNC str_ieq_c
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    mov  x19, x0
    mov  x20, x1
    mov  x0, x1
    bl   strlen
    mov  x3, x0
    mov  x2, x20
    ldr  x1, [x19, #STR_LEN]
    add  x0, x19, #STR_DATA
    bl   ci_eq
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF str_ieq_c

// bytes_cmp(x0 p1, x1 l1, x2 p2, x3 l2) -> w0 -1/0/1 (memcmp, then length)
FUNC bytes_cmp
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    mov  x19, x1
    mov  x20, x3
    mov  x1, x2                 // memcmp(p1, p2, min(l1, l2))
    cmp  x19, x20
    csel x2, x19, x20, lo
    bl   memcmp
    cmp  w0, #0
    b.ne 1f
    cmp  x19, x20               // common prefix equal: shorter sorts first
    cset w0, hi
    csinv w0, w0, wzr, hs       // lo => -1
    b    2f
1:  cset w0, gt
    csinv w0, w0, wzr, ge
2:  ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF bytes_cmp

// ----------------------------------------------------------------- buffers ---
// buf_reserve(x0 Buf*, x1 extra) -> x0 pointer to write position
FUNC buf_reserve
    ldr  x2, [x0, #BUF_LEN]
    ldr  x3, [x0, #BUF_CAP]
    add  x4, x2, x1
    cmp  x4, x3
    b.hi 1f
    ldr  x0, [x0, #BUF_PTR]
    add  x0, x0, x2
    ret
1:  stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    mov  x19, x0
    lsl  x3, x3, #1             // new cap = max(2*cap, needed, 4096)
    cmp  x3, x4
    csel x3, x3, x4, hs
    mov  x5, #4096
    cmp  x3, x5
    csel x20, x3, x5, hs
    ldr  x0, [x19, #BUF_PTR]
    mov  x1, x20
    bl   realloc
    cbnz x0, 2f
    mov  w0, #ERR_RESOURCE_LIMIT
    ADR_L x1, s_oom
    bl   pq_raise
2:  str  x0, [x19, #BUF_PTR]
    str  x20, [x19, #BUF_CAP]
    ldr  x2, [x19, #BUF_LEN]
    add  x0, x0, x2
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF buf_reserve

// buf_putc(x0 Buf*, w1 byte)
FUNC buf_putc
    ldr  x2, [x0, #BUF_LEN]
    ldr  x3, [x0, #BUF_CAP]
    cmp  x2, x3
    b.hs 1f
    ldr  x4, [x0, #BUF_PTR]
    strb w1, [x4, x2]
    add  x2, x2, #1
    str  x2, [x0, #BUF_LEN]
    ret
1:  stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    mov  x19, x0
    mov  w20, w1
    mov  x1, #1
    bl   buf_reserve
    strb w20, [x0]
    ldr  x2, [x19, #BUF_LEN]
    add  x2, x2, #1
    str  x2, [x19, #BUF_LEN]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF buf_putc

// buf_put(x0 Buf*, x1 ptr, x2 len)
FUNC buf_put
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    str  x21, [sp, #32]
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x1, x2
    bl   buf_reserve
    mov  x1, x20
    mov  x2, x21
    bl   memcpy
    ldr  x2, [x19, #BUF_LEN]
    add  x2, x2, x21
    str  x2, [x19, #BUF_LEN]
    ldp  x19, x20, [sp, #16]
    ldr  x21, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
ENDF buf_put

// buf_puts(x0 Buf*, x1 cstr)
FUNC buf_puts
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    mov  x19, x0
    mov  x20, x1
    mov  x0, x1
    bl   strlen
    mov  x2, x0
    mov  x1, x20
    mov  x0, x19
    bl   buf_put
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF buf_puts

// buf_put_u64(x0 Buf*, x1 value)
FUNC buf_put_u64
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    add  x3, sp, #48            // digits written backwards into [sp+16, sp+48)
    mov  x4, #10
1:  udiv x5, x1, x4
    msub x6, x5, x4, x1
    add  w6, w6, #'0'
    strb w6, [x3, #-1]!
    mov  x1, x5
    cbnz x1, 1b
    mov  x1, x3
    add  x2, sp, #48
    sub  x2, x2, x3
    bl   buf_put
    ldp  x29, x30, [sp], #48
    ret
ENDF buf_put_u64

// buf_put_i64(x0 Buf*, x1 value)
FUNC buf_put_i64
    tbz  x1, #63, buf_put_u64
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    mov  x19, x0
    neg  x20, x1                // INT64_MIN negates to itself = 2^63 unsigned
    mov  w1, #'-'
    bl   buf_putc
    mov  x0, x19
    mov  x1, x20
    bl   buf_put_u64
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF buf_put_i64

    .section .rodata
hexdigits: .ascii "0123456789abcdef"
    .text

// buf_put_jstr(x0 Buf*, x1 ptr, x2 len): JSON string literal with quotes.
FUNC buf_put_jstr
    stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    mov  x19, x0
    mov  x20, x1                // cursor
    add  x21, x1, x2            // end
    // worst case 6 bytes per input byte + 2 quotes
    mov  x1, #6
    mul  x1, x2, x1
    add  x1, x1, #2
    bl   buf_reserve
    mov  x22, x0                // write pointer
    mov  x23, x0                // start
    mov  w4, #'"'
    strb w4, [x22], #1
    ADR_L x24, hexdigits
1:  cmp  x20, x21
    b.hs 8f
    ldrb w4, [x20], #1
    cmp  w4, #'"'
    b.eq 3f
    cmp  w4, #'\\'
    b.eq 3f
    cmp  w4, #0x20
    b.lo 4f
    strb w4, [x22], #1
    b    1b
3:  mov  w5, #'\\'
    strb w5, [x22], #1
    strb w4, [x22], #1
    b    1b
4:  // control character
    mov  w5, #'\\'
    strb w5, [x22], #1
    cmp  w4, #'\n'
    b.ne 5f
    mov  w5, #'n'
    strb w5, [x22], #1
    b    1b
5:  cmp  w4, #'\t'
    b.ne 6f
    mov  w5, #'t'
    strb w5, [x22], #1
    b    1b
6:  cmp  w4, #'\r'
    b.ne 7f
    mov  w5, #'r'
    strb w5, [x22], #1
    b    1b
7:  mov  w5, #'u'
    strb w5, [x22], #1
    mov  w5, #'0'
    strb w5, [x22], #1
    strb w5, [x22], #1
    lsr  w5, w4, #4
    ldrb w5, [x24, x5]
    strb w5, [x22], #1
    and  w5, w4, #15
    ldrb w5, [x24, x5]
    strb w5, [x22], #1
    b    1b
8:  mov  w4, #'"'
    strb w4, [x22], #1
    sub  x0, x22, x23
    ldr  x1, [x19, #BUF_LEN]
    add  x1, x1, x0
    str  x1, [x19, #BUF_LEN]
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x23, x24, [sp, #48]
    ldp  x29, x30, [sp], #64
    ret
ENDF buf_put_jstr

// buf_put_f64(x0 Buf*, d0 value): shortest "%.*g" (15..17 digits) that
// round-trips; -0.0 is written as 0.0. Output is always a valid JSON number.
FUNC buf_put_f64
    stp  x29, x30, [sp, #-112]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    str  d8, [sp, #32]
    mov  x19, x0
    fmov d8, d0
    fcmp d0, #0.0
    b.ne 1f
    fmov d8, xzr                // normalise -0.0
1:  mov  w20, #15
2:  add  x0, sp, #48            // char buf[64] at sp+48
    mov  x1, #64
    ADR_L x2, fmt_g
    mov  w3, w20
    fmov d0, d8
    bl   snprintf
    cmp  w20, #17
    b.hs 3f
    add  x0, sp, #48
    mov  x1, #0
    bl   strtod
    fcmp d0, d8
    b.eq 3f
    add  w20, w20, #1
    b    2b
3:  mov  x0, x19
    add  x1, sp, #48
    bl   buf_puts
    ldp  x19, x20, [sp, #16]
    ldr  d8, [sp, #32]
    ldp  x29, x30, [sp], #112
    ret
ENDF buf_put_f64

// ------------------------------------------------------------------- time ----

// now_us() -> x0 microseconds (CLOCK_MONOTONIC)
FUNC now_us
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    mov  w0, #1                 // CLOCK_MONOTONIC
    add  x1, sp, #16
    bl   clock_gettime
    ldp  x0, x1, [sp, #16]      // tv_sec, tv_nsec
    mov  x2, #1000
    udiv x1, x1, x2
    mov  x3, #16960
    movk x3, #0xf, lsl #16      // 1000000
    madd x0, x0, x3, x1
    ldp  x29, x30, [sp], #32
    ret
ENDF now_us

// check_deadline(): interruption point of long-running operators.
// Raises CANCELLED if the running query's cancellation flag (g_cancel_flag,
// set by DELETE /v1/queries, a client disconnect or shutdown) is set, and
// TIMEOUT if g_deadline has passed.
FUNC check_deadline
    TLS_LDR x0, g_cancel_flag
    cbz  x0, 1f
    ldar w0, [x0]
    cbz  w0, 1f
    mov  w0, #ERR_CANCELLED
    ADR_L x1, s_cancelm
    b    pq_raise
1:  TLS_LDR x0, g_deadline
    cbnz x0, 2f
    ret
2:  stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    bl   now_us
    TLS_LDR x1, g_deadline
    cmp  x0, x1
    b.lo 3f
    mov  w0, #ERR_TIMEOUT
    ADR_L x1, s_timeoutm
    bl   pq_raise
3:  ldp  x29, x30, [sp], #16
    ret
ENDF check_deadline

// atomic_fetch_add(x0 u64*, x1 delta) -> x0 previous value        (leaf)
FUNC atomic_fetch_add
1:  ldaxr x2, [x0]
    add  x3, x2, x1
    stlxr w4, x3, [x0]
    cbnz w4, 1b
    mov  x0, x2
    ret
ENDF atomic_fetch_add

    NOTE_GNU_STACK
