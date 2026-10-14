// =============================================================================
// util.S — pqledger runtime helpers: errors, memory, byte buffers, files,
// strings.
//
//   fail(w0 exit code, x1 printf format, x2..x7 args)   never returns
//   xmalloc(x0 n) -> x0 / xrealloc(x0 p, x1 n) -> x0     exit 7 when exhausted
//   xstrndup(x0 ptr, x1 len) -> x0 cstr / xstrdup(x0 cstr) -> x0 cstr
//   buf_reserve(x0 Buf*, x1 extra) -> x0 write pointer (len unchanged)
//   buf_put(x0 Buf*, x1 ptr, x2 len) / buf_putc(x0 Buf*, w1 byte)
//   buf_puts(x0 Buf*, x1 cstr) / buf_put_i64(x0 Buf*, x1 value)
//   buf_put_cents(x0 Buf*, x1 cents)        "-12.50" (two decimals)
//   buf_put_sqlstr(x0 Buf*, x1 ptr, x2 len) SQL literal '...' ('' doubled)
//   buf_cstr(x0 Buf*) -> x0 NUL-terminated bytes (length unchanged)
//   buf_free(x0 Buf*)
//   read_file(x0 path) -> x0 malloc'ed bytes (NUL-terminated) or 0, x1 len
//   write_all(w0 fd, x1 ptr, x2 len) -> w0 0 / -1
//   trim_ws(x0 ptr, x1 len) -> x0 ptr, x1 len    (spaces and tabs)
//   ascii_ieq(x0 p1, x1 l1, x2 p2, x3 l2) -> w0 1 if equal ignoring ASCII case
//   valid_name(x0 cstr) -> w0 1 if it matches [a-z0-9_-]{1,32}
//   parse_u64(x0 ptr, x1 len) -> x0 value, w1 0 ok / 1 invalid (digits only,
//       non-empty, no overflow)
// =============================================================================
#include "ledger.inc"

    .section .rodata
s_prefix:   .asciz "pqledger: error: "
s_oom:      .asciz "out of memory"
s_rb:       .asciz "rb"
    .text

// fail(w0 code, x1 fmt, x2..x7 args): print the error and exit(code)
//   x19 code; args saved at [sp+16..]
FUNC fail
    stp  x29, x30, [sp, #-96]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x1, x2, [sp, #32]
    stp  x3, x4, [sp, #48]
    stp  x5, x6, [sp, #64]
    str  x7, [sp, #80]
    mov  w19, w0
    GOT_LOAD x0, stdout             // nothing reaches stdout on failure
    bl   fflush
    ADR_L x0, s_prefix
    GOT_LOAD x1, stderr
    bl   fputs
    GOT_LOAD x0, stderr
    ldp  x1, x2, [sp, #32]
    ldp  x3, x4, [sp, #48]
    ldp  x5, x6, [sp, #64]
    ldr  x7, [sp, #80]
    bl   fprintf
    GOT_LOAD x1, stderr
    mov  w0, #'\n'
    bl   fputc
    mov  w0, w19
    bl   exit
ENDF fail

// xmalloc(x0 n) -> x0 (never 0)
FUNC xmalloc
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    cmp  x0, #0
    csinc x0, x0, xzr, ne
    bl   malloc
    cbz  x0, 1f
    ldp  x29, x30, [sp], #16
    ret
1:  mov  w0, #EX_OTHER
    ADR_L x1, s_oom
    bl   fail
ENDF xmalloc

// xrealloc(x0 p, x1 n) -> x0
FUNC xrealloc
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    cmp  x1, #0
    csinc x1, x1, xzr, ne
    bl   realloc
    cbz  x0, 1f
    ldp  x29, x30, [sp], #16
    ret
1:  mov  w0, #EX_OTHER
    ADR_L x1, s_oom
    bl   fail
ENDF xrealloc

// xstrndup(x0 ptr, x1 len) -> x0 NUL-terminated copy
FUNC xstrndup
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    add  x0, x1, #1
    bl   xmalloc
    strb wzr, [x0, x20]
    mov  x1, x19
    mov  x2, x20
    bl   memcpy
    LEAVE 2
ENDF xstrndup

// xstrdup(x0 cstr) -> x0 copy
FUNC xstrdup
    ENTER 1
    mov  x19, x0
    bl   strlen
    mov  x1, x0
    mov  x0, x19
    bl   xstrndup
    LEAVE 1
ENDF xstrdup

// ---------------------------------------------------------------- Buf --------

// buf_reserve(x0 Buf*, x1 extra) -> x0 pointer to the first free byte
FUNC buf_reserve
    ldr  x2, [x0, #BUF_LEN]
    ldr  x3, [x0, #BUF_CAP]
    add  x4, x2, x1
    add  x4, x4, #1                 // room for buf_cstr's NUL
    cmp  x4, x3
    b.hi 1f
    ldr  x0, [x0, #BUF_PTR]
    add  x0, x0, x2
    ret
1:  ENTER 1
    mov  x19, x0
    lsl  x3, x3, #1                 // new cap = max(2*cap, needed, 256)
    cmp  x3, x4
    csel x3, x3, x4, hs
    mov  x5, #256
    cmp  x3, x5
    csel x1, x3, x5, hs
    str  x1, [x19, #BUF_CAP]
    ldr  x0, [x19, #BUF_PTR]
    bl   xrealloc
    str  x0, [x19, #BUF_PTR]
    ldr  x2, [x19, #BUF_LEN]
    add  x0, x0, x2
    LEAVE 1
ENDF buf_reserve

// buf_put(x0 Buf*, x1 ptr, x2 len)
FUNC buf_put
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x1, x2
    bl   buf_reserve
    mov  x1, x20
    mov  x2, x21
    bl   memcpy
    ldr  x9, [x19, #BUF_LEN]
    add  x9, x9, x21
    str  x9, [x19, #BUF_LEN]
    LEAVE 3
ENDF buf_put

// buf_putc(x0 Buf*, w1 byte)
FUNC buf_putc
    ldr  x2, [x0, #BUF_LEN]
    ldr  x3, [x0, #BUF_CAP]
    add  x4, x2, #2
    cmp  x4, x3
    b.hi 1f
    ldr  x3, [x0, #BUF_PTR]
    strb w1, [x3, x2]
    add  x2, x2, #1
    str  x2, [x0, #BUF_LEN]
    ret
1:  ENTER 2
    mov  x19, x0
    mov  w20, w1
    mov  x1, #1
    bl   buf_reserve
    strb w20, [x0]
    ldr  x2, [x19, #BUF_LEN]
    add  x2, x2, #1
    str  x2, [x19, #BUF_LEN]
    LEAVE 2
ENDF buf_putc

// buf_puts(x0 Buf*, x1 cstr)
FUNC buf_puts
    ENTER 1
    stp  x0, x1, [sp, #-16]!
    mov  x0, x1
    bl   strlen
    mov  x2, x0
    ldp  x0, x1, [sp], #16
    bl   buf_put
    LEAVE 1
ENDF buf_puts

// buf_put_u64(x0 Buf*, x1 value): unsigned decimal
FUNC buf_put_u64
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    add  x3, sp, #48                // digits written backwards into [sp+16, sp+48)
    mov  x4, #10
1:  udiv x5, x1, x4
    msub x6, x5, x4, x1
    add  w6, w6, #'0'
    strb w6, [x3, #-1]!
    mov  x1, x5
    cbnz x1, 1b
    add  x2, sp, #48
    sub  x2, x2, x3
    mov  x1, x3
    bl   buf_put
    ldp  x29, x30, [sp], #48
    ret
ENDF buf_put_u64

// buf_put_i64(x0 Buf*, x1 value): signed decimal
FUNC buf_put_i64
    tbz  x1, #63, buf_put_u64
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    mov  w1, #'-'
    bl   buf_putc
    neg  x1, x20
    mov  x0, x19
    bl   buf_put_u64
    LEAVE 2
ENDF buf_put_i64

// buf_put_cents(x0 Buf*, x1 cents): decimal text with two fractional digits
FUNC buf_put_cents
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    tbz  x20, #63, 1f
    mov  w1, #'-'
    bl   buf_putc
    neg  x20, x20
1:  mov  x9, #100
    udiv x1, x20, x9
    msub x20, x1, x9, x20           // x20 = fractional cents
    mov  x0, x19
    bl   buf_put_u64
    mov  x0, x19
    mov  w1, #'.'
    bl   buf_putc
    mov  x9, #10
    udiv x1, x20, x9
    msub x20, x1, x9, x20
    add  w1, w1, #'0'
    mov  x0, x19
    bl   buf_putc
    add  w1, w20, #'0'
    mov  x0, x19
    bl   buf_putc
    LEAVE 2
ENDF buf_put_cents

// buf_put_sqlstr(x0 Buf*, x1 ptr, x2 len): '...' with ' doubled
FUNC buf_put_sqlstr
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    add  x21, x1, x2                // end
    mov  w1, #'\''
    bl   buf_putc
1:  cmp  x20, x21
    b.hs 3f
    ldrb w1, [x20], #1
    cmp  w1, #'\''
    b.ne 2f
    mov  x0, x19
    bl   buf_putc
    mov  w1, #'\''
2:  mov  x0, x19
    bl   buf_putc
    b    1b
3:  mov  x0, x19
    mov  w1, #'\''
    bl   buf_putc
    LEAVE 3
ENDF buf_put_sqlstr

// buf_cstr(x0 Buf*) -> x0 NUL-terminated data
FUNC buf_cstr
    ENTER 1
    mov  x19, x0
    mov  x1, #0
    bl   buf_reserve
    strb wzr, [x0]
    ldr  x0, [x19, #BUF_PTR]
    LEAVE 1
ENDF buf_cstr

// buf_free(x0 Buf*): release the bytes; the buffer becomes empty
FUNC buf_free
    ENTER 1
    mov  x19, x0
    ldr  x0, [x0, #BUF_PTR]
    bl   free
    stp  xzr, xzr, [x19]
    stp  xzr, xzr, [x19, #16]
    LEAVE 1
ENDF buf_free

// ---------------------------------------------------------------- files ------

// read_file(x0 path) -> x0 bytes (malloc, NUL-terminated) or 0, x1 length
//   x19 FILE*, sp: Buf
FUNC read_file
    ENTER 2
    sub  sp, sp, #BUF_SIZE
    stp  xzr, xzr, [sp]
    stp  xzr, xzr, [sp, #16]
    ADR_L x1, s_rb
    bl   fopen
    cbz  x0, 8f
    mov  x19, x0
1:  mov  x0, sp
    mov  x1, #65536
    bl   buf_reserve
    mov  x1, #1
    mov  x2, #65536
    mov  x3, x19
    bl   fread
    cbz  x0, 2f
    ldr  x1, [sp, #BUF_LEN]
    add  x1, x1, x0
    str  x1, [sp, #BUF_LEN]
    b    1b
2:  mov  x0, x19
    bl   ferror
    mov  w20, w0
    mov  x0, x19
    bl   fclose
    cbnz w20, 7f
    mov  x0, sp
    bl   buf_cstr
    ldr  x1, [sp, #BUF_LEN]
    b    9f
7:  mov  x0, sp
    bl   buf_free
8:  mov  x0, #0
    mov  x1, #0
9:  add  sp, sp, #BUF_SIZE
    LEAVE 2
ENDF read_file

// write_all(w0 fd, x1 ptr, x2 len) -> w0 0 / -1
FUNC write_all
    ENTER 2
    mov  w19, w0
1:  cbz  x2, 8f
    stp  x1, x2, [sp, #-16]!
    mov  w0, w19
    bl   write
    ldp  x1, x2, [sp], #16
    cmp  x0, #0
    b.le 9f
    add  x1, x1, x0
    sub  x2, x2, x0
    b    1b
8:  mov  w0, #0
    LEAVE 2
9:  mov  w0, #-1
    LEAVE 2
ENDF write_all

// ------------------------------------------------------------- strings -------

// trim_ws(x0 ptr, x1 len) -> x0 ptr, x1 len: strip spaces and tabs   (leaf)
FUNC trim_ws
1:  cbz  x1, 3f
    ldrb w2, [x0]
    cmp  w2, #' '
    ccmp w2, #'\t', #4, ne
    b.ne 2f
    add  x0, x0, #1
    sub  x1, x1, #1
    b    1b
2:  sub  x3, x1, #1
    ldrb w2, [x0, x3]
    cmp  w2, #' '
    ccmp w2, #'\t', #4, ne
    b.ne 3f
    mov  x1, x3
    cbnz x1, 2b
3:  ret
ENDF trim_ws

// ascii_ieq(x0 p1, x1 l1, x2 p2, x3 l2) -> w0 1/0   (leaf)
FUNC ascii_ieq
    cmp  x1, x3
    b.ne 8f
1:  cbz  x1, 9f
    ldrb w4, [x0], #1
    ldrb w5, [x2], #1
    sub  w6, w4, #'A'
    cmp  w6, #25
    b.hi 2f
    add  w4, w4, #32
2:  sub  w6, w5, #'A'
    cmp  w6, #25
    b.hi 3f
    add  w5, w5, #32
3:  cmp  w4, w5
    b.ne 8f
    sub  x1, x1, #1
    b    1b
8:  mov  w0, #0
    ret
9:  mov  w0, #1
    ret
ENDF ascii_ieq

// valid_name(x0 cstr) -> w0 1 if [a-z0-9_-]{1,32}   (leaf)
FUNC valid_name
    mov  x1, #0
1:  ldrb w2, [x0, x1]
    cbz  w2, 3f
    sub  w3, w2, #'a'
    cmp  w3, #25
    b.ls 2f
    sub  w3, w2, #'0'
    cmp  w3, #9
    b.ls 2f
    cmp  w2, #'_'
    b.eq 2f
    cmp  w2, #'-'
    b.ne 8f
2:  add  x1, x1, #1
    cmp  x1, #32
    b.hi 8f
    b    1b
3:  cbz  x1, 8f
    mov  w0, #1
    ret
8:  mov  w0, #0
    ret
ENDF valid_name

// parse_u64(x0 ptr, x1 len) -> x0 value, w1 status (0 ok, 1 invalid)   (leaf)
FUNC parse_u64
    cbz  x1, 8f
    mov  x2, x0
    mov  x0, #0
    mov  x5, #10
1:  ldrb w3, [x2], #1
    sub  w3, w3, #'0'
    cmp  w3, #9
    b.hi 8f
    umulh x4, x0, x5
    cbnz x4, 8f
    mul  x0, x0, x5
    adds x0, x0, x3
    b.cs 8f
    subs x1, x1, #1
    b.ne 1b
    mov  w1, #0
    ret
8:  mov  x0, #0
    mov  w1, #1
    ret
ENDF parse_u64

    NOTE_GNU_STACK
