// Unit tests for rt.S: buffers, number/JSON formatting, string compare, arenas,
// the CR-6 stack guard and deadline ticks.
#include "pq.inc"

    .bss
    .p2align 4
tbuf:     .skip BUF_SIZE
tarena:   .skip AR_SIZE
failures: .skip 8

    .section .rodata
fmt_fail: .asciz "FAIL %s: got '%.*s' expected '%s'\n"
fmt_failn: .asciz "FAIL %s: got %ld expected %ld\n"
fmt_sum:  .asciz "test_rt: %ld failures\n"
    .text

// expect_buf(x0 name, x1 expected cstr): compare tbuf contents, then clear it
LFUNC expect_buf
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    mov  x19, x0
    mov  x20, x1
    mov  x0, x1
    bl   strlen
    ADR_L x1, tbuf
    ldr  x21, [x1, #BUF_LEN]
    ldr  x22, [x1, #BUF_PTR]
    cmp  x0, x21
    b.ne 1f
    mov  x2, x0
    mov  x0, x22
    mov  x1, x20
    bl   memcmp
    cbz  w0, 2f
1:  ADR_L x0, fmt_fail
    mov  x1, x19
    mov  w2, w21
    mov  x3, x22
    mov  x4, x20
    bl   printf
    ADR_L x0, failures
    ldr  x1, [x0]
    add  x1, x1, #1
    str  x1, [x0]
2:  ADR_L x0, tbuf
    str  xzr, [x0, #BUF_LEN]
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
ENDF expect_buf

// expect_eq(x0 name, x1 got, x2 expected)
LFUNC expect_eq
    cmp  x1, x2
    b.ne 1f
    ret
1:  stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    mov  x3, x2
    mov  x2, x1
    mov  x1, x0
    ADR_L x0, fmt_failn
    bl   printf
    ADR_L x0, failures
    ldr  x1, [x0]
    add  x1, x1, #1
    str  x1, [x0]
    ldp  x29, x30, [sp], #16
    ret
ENDF expect_eq

.macro F64_CASE bits, expected
    ADR_L x0, tbuf
    ldr  x1, =\bits
    fmov d0, x1
    bl   buf_put_f64
    adr  x0, 7771f
    adr  x1, 7772f
    bl   expect_buf
    b    7773f
7771: .asciz "f64 \expected"
7772: .asciz "\expected"
    .p2align 2
7773:
.endm

.macro I64_CASE val, expected
    ADR_L x0, tbuf
    ldr  x1, =\val
    bl   buf_put_i64
    adr  x0, 7771f
    adr  x1, 7772f
    bl   expect_buf
    b    7773f
7771: .asciz "i64 \expected"
7772: .asciz "\expected"
    .p2align 2
7773:
.endm

FUNC main
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]

    F64_CASE 0x3FB999999999999A, "0.1"
    F64_CASE 0x8000000000000000, "0"
    F64_CASE 0x4008000000000000, "3"
    F64_CASE 0x7e41eb2d66005835, "1.5e+300"
    F64_CASE 0x3FD5555555555555, "0.3333333333333333"
    I64_CASE 0, "0"
    I64_CASE -42, "-42"
    I64_CASE 0x8000000000000000, "-9223372036854775808"
    I64_CASE 0x7fffffffffffffff, "9223372036854775807"

    // JSON string escaping
    ADR_L x0, tbuf
    adr  x1, jsrc
    mov  x2, #6
    bl   buf_put_jstr
    adr  x0, jname
    adr  x1, jexp
    bl   expect_buf

    // ci_cmp / bytes_cmp / ci_eq
    adr  x0, sA
    mov  x1, #3
    adr  x2, sa
    mov  x3, #3
    bl   ci_eq
    mov  x1, x0
    adr  x0, n_cieq
    mov  x2, #1
    bl   expect_eq
    adr  x0, sA
    mov  x1, #3
    adr  x2, sa
    mov  x3, #2
    bl   ci_cmp
    cmp  w0, #0
    cset x1, gt
    adr  x0, n_cicmp
    mov  x2, #1
    bl   expect_eq
    adr  x0, sA
    mov  x1, #3
    adr  x2, sa
    mov  x3, #3
    bl   bytes_cmp
    sxtw x1, w0
    adr  x0, n_bcmp
    mov  x2, #-1
    bl   expect_eq

    // arena: many allocations, alignment, free
    mov  x19, #0
1:  ADR_L x0, tarena
    mov  x1, #1000
    bl   arena_alloc_in
    and  x1, x0, #15
    adr  x0, n_align
    mov  x2, #0
    bl   expect_eq
    add  x19, x19, #1
    cmp  x19, #2000
    b.lo 1b
    ADR_L x0, tarena
    bl   arena_free
    ADR_L x0, tarena
    ldr  x1, [x0, #AR_CHUNKS]
    adr  x0, n_free
    mov  x2, #0
    bl   expect_eq

    // arena chunks start at 32 KiB (+16 header) and grow (CR-6)
    ADR_L x0, tarena
    mov  x1, #16
    bl   arena_alloc_in
    ADR_L x0, tarena
    ldr  x1, [x0, #AR_TOTAL]
    adr  x0, n_chunk
    mov  x2, #(32 * 1024 + 16)
    bl   expect_eq
    ADR_L x0, tarena
    bl   arena_free

    bl   test_stack_guard
    bl   test_deadline_tick

    ADR_L x0, failures
    ldr  x19, [x0]
    ADR_L x0, fmt_sum
    mov  x1, x19
    bl   printf
    cmp  x19, #0
    cset w0, ne
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
    .ltorg
jsrc:   .ascii "a\"b\\\n\001"
jname:  .asciz "jstr"
jexp:   .asciz "\"a\\\"b\\\\\\n\\u0001\""
sA:     .ascii "ABC"
sa:     .ascii "abc"
n_cieq: .asciz "ci_eq"
n_cicmp: .asciz "ci_cmp longer"
n_bcmp: .asciz "bytes_cmp case"
n_align: .asciz "arena align"
n_free: .asciz "arena free"
n_chunk: .asciz "arena first chunk"
    .p2align 2
ENDF main

// test_stack_guard: stack_guard_init leaves 0 < limit < sp; with the limit
// above sp, STACK_GUARD raises RESOURCE_LIMIT through g_jmpbuf
LFUNC test_stack_guard
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    str  x19, [sp, #16]
    bl   stack_guard_init
    TLS_LDR x19, g_stack_limit
    cmp  x19, #0
    cset x1, ne
    mov  x9, sp
    cmp  x19, x9
    cset x9, lo
    and  x1, x1, x9
    adr  x0, n_glimit
    mov  x2, #1
    bl   expect_eq
    TLS_ADDR x0, g_jmpbuf
    bl   setjmp
    cbnz w0, 1f
    mov  x9, sp                         // every sp is now "too deep"
    add  x9, x9, #4096
    TLS_ADDR x10, g_stack_limit
    str  x9, [x10]
    STACK_GUARD
    mov  x1, #0                         // not raised
    b    2f
1:  TLS_ADDR x9, g_err_code
    ldr  w1, [x9]
2:  TLS_ADDR x10, g_stack_limit
    str  x19, [x10]
    adr  x0, n_guard
    mov  x2, #ERR_RESOURCE_LIMIT
    bl   expect_eq
    ldr  x19, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
n_glimit: .asciz "stack limit below sp"
n_guard:  .asciz "STACK_GUARD raises"
    .p2align 2
ENDF test_stack_guard

// test_deadline_tick: with an expired deadline, DEADLINE_TICK raises TIMEOUT
// within DEADLINE_TICKS executions and preserves the registers it does not
// document as clobbered
LFUNC test_deadline_tick
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    str  x19, [sp, #16]
    TLS_ADDR x0, g_jmpbuf
    bl   setjmp
    cbnz w0, 1f
    mov  x9, #1                         // 1 us after the epoch: expired
    TLS_ADDR x10, g_deadline
    str  x9, [x10]
    mov  x19, #0
    mov  x0, #77
    mov  x15, #99
3:  DEADLINE_TICK
    cmp  x0, #77
    b.ne 4f
    cmp  x15, #99
    b.ne 4f
    add  x19, x19, #1
    cmp  x19, #(2 * DEADLINE_TICKS)
    b.lo 3b
4:  mov  x1, #0                         // not raised (or registers lost)
    b    2f
1:  TLS_ADDR x9, g_err_code
    ldr  w1, [x9]
2:  TLS_ADDR x10, g_deadline
    str  xzr, [x10]
    adr  x0, n_tick
    mov  x2, #ERR_TIMEOUT
    bl   expect_eq
    ldr  x19, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
n_tick:   .asciz "DEADLINE_TICK raises TIMEOUT"
    .p2align 2
ENDF test_deadline_tick

    NOTE_GNU_STACK
