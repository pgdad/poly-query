/*
 * dec128.S - wide DECIMAL support (change request CR-2, DECIMAL(p,s) with
 * 19 <= p <= 38).
 *
 * Representation.  A narrow decimal (p <= 18) keeps its unscaled value as
 * an inline i64 in the 64-bit value slot.  A wide decimal (p > 18) stores a
 * pointer to an immutable 16-byte little-endian two's-complement i128 (the
 * unscaled value) in the slot - the same boxing strings use (pstr*).  Boxes
 * live in the arena of their owner (request / worker arena for computed
 * values, the table arena for stored ones) and are never modified, so value
 * slots can be copied freely.
 *
 * Arithmetic on wide values is exact: operands are widened to 256-bit
 * intermediates (|v| < 10^38 < 2^127, so v * 10^38 and products of two
 * operands fit), and only the final result is checked against 10^p.
 *
 *   dec_is_wide(type edi) -> eax 1 if the packed type is DECIMAL with p > 18
 *   num_load(type edi, payload rsi) -> rax lo, rdx hi, ecx scale
 *       INT64 / narrow / wide DECIMAL value as i128 (INT64: scale 0)
 *   dec_put(lo rdi, hi rsi, type edx) -> rax payload; NUMERIC_OVERFLOW
 *       unless |v| < 10^p; narrow: the i64, wide: a new box
 *   dec_box(lo rdi, hi rsi) -> rax box in the current request arena
 *   dec_box_in(arena rdi, lo rsi, hi rdx) -> rax box in the given arena
 *   i128_fits(lo rdi, hi rsi, p edx) -> eax 1 if |v| < 10^p
 *   num_cmp(ta edi, a rsi, tb edx, b rcx) -> eax -1/0/1: exact comparison of
 *       two INT64 / DECIMAL values of any precision and scale
 *   dec_arith(op edi, ta esi, a rdx, tb ecx, b r8, tr r9d) -> rax payload:
 *       B_ADD / B_SUB / B_MUL of INT64 / DECIMAL operands into type tr
 *   dec_rescale128(lo rdi, hi rsi, from edx, to ecx, p r8d)
 *       -> rax lo, rdx hi, ecx status (0 ok, 2 overflow): rescale (round half
 *       away from zero when the scale decreases) and check |v| < 10^p
 *   i128_round_pow10(lo rdi, hi rsi, k edx) -> rax lo, rdx hi:
 *       v / 10^k rounded half away from zero
 *   i128_div_pow10(lo rdi, hi rsi, k edx) -> rax lo, rdx hi, rcx 1 if the
 *       division was inexact: v / 10^k truncated toward zero
 *   dec_parse(ptr rdi, len rsi, prec edx, scale ecx, mode r8d, out r9)
 *       -> eax status: text_parse_decimal for up to 38 digits, the i128
 *       stored at out (status 0 ok, 1 syntax, 2 overflow, 3 too many
 *       fraction digits in exact mode 0; mode 1 rounds half away from zero)
 *   fmt_dec128(buf rdi, lo rsi, hi rdx, scale ecx): canonical text
 *   dec128_to_double(lo rdi, hi rsi, scale edx) -> xmm0 nearest FLOAT64
 *   double_to_dec128(x xmm0, prec edi, scale esi, out rdx) -> eax status:
 *       exact binary value of x rounded half away from zero to the scale
 *   dec128_to_int(lo rdi, hi rsi, scale edx) -> rax, edx status:
 *       truncation toward zero, status 2 outside the INT64 range
 *   sum192_add(acc rdi, lo rsi, hi rdx): acc (3 qwords, i192) += v
 *   sum192_to_i128(acc rdi) -> rax lo, rdx hi, ecx 1 if it fits i128
 *   avg192_to_double(acc rdi, count rsi, scale edx) -> xmm0
 *       (sum / 10^scale) / count, from the exact quotient's digits
 */
#include "pq.inc"
#include "sql.inc"

    .section .note.GNU-stack, "", @progbits

    .section .rodata
    .p2align 4
    .globl p10_128
/* 10^k as u128 (lo, hi), k = 0..38 */
p10_128:
    .quad 0x0000000000000001, 0x0000000000000000    /* 10^0 */
    .quad 0x000000000000000a, 0x0000000000000000    /* 10^1 */
    .quad 0x0000000000000064, 0x0000000000000000    /* 10^2 */
    .quad 0x00000000000003e8, 0x0000000000000000    /* 10^3 */
    .quad 0x0000000000002710, 0x0000000000000000    /* 10^4 */
    .quad 0x00000000000186a0, 0x0000000000000000    /* 10^5 */
    .quad 0x00000000000f4240, 0x0000000000000000    /* 10^6 */
    .quad 0x0000000000989680, 0x0000000000000000    /* 10^7 */
    .quad 0x0000000005f5e100, 0x0000000000000000    /* 10^8 */
    .quad 0x000000003b9aca00, 0x0000000000000000    /* 10^9 */
    .quad 0x00000002540be400, 0x0000000000000000    /* 10^10 */
    .quad 0x000000174876e800, 0x0000000000000000    /* 10^11 */
    .quad 0x000000e8d4a51000, 0x0000000000000000    /* 10^12 */
    .quad 0x000009184e72a000, 0x0000000000000000    /* 10^13 */
    .quad 0x00005af3107a4000, 0x0000000000000000    /* 10^14 */
    .quad 0x00038d7ea4c68000, 0x0000000000000000    /* 10^15 */
    .quad 0x002386f26fc10000, 0x0000000000000000    /* 10^16 */
    .quad 0x016345785d8a0000, 0x0000000000000000    /* 10^17 */
    .quad 0x0de0b6b3a7640000, 0x0000000000000000    /* 10^18 */
    .quad 0x8ac7230489e80000, 0x0000000000000000    /* 10^19 */
    .quad 0x6bc75e2d63100000, 0x0000000000000005    /* 10^20 */
    .quad 0x35c9adc5dea00000, 0x0000000000000036    /* 10^21 */
    .quad 0x19e0c9bab2400000, 0x000000000000021e    /* 10^22 */
    .quad 0x02c7e14af6800000, 0x000000000000152d    /* 10^23 */
    .quad 0x1bcecceda1000000, 0x000000000000d3c2    /* 10^24 */
    .quad 0x161401484a000000, 0x0000000000084595    /* 10^25 */
    .quad 0xdcc80cd2e4000000, 0x000000000052b7d2    /* 10^26 */
    .quad 0x9fd0803ce8000000, 0x00000000033b2e3c    /* 10^27 */
    .quad 0x3e25026110000000, 0x00000000204fce5e    /* 10^28 */
    .quad 0x6d7217caa0000000, 0x00000001431e0fae    /* 10^29 */
    .quad 0x4674edea40000000, 0x0000000c9f2c9cd0    /* 10^30 */
    .quad 0xc0914b2680000000, 0x0000007e37be2022    /* 10^31 */
    .quad 0x85acef8100000000, 0x000004ee2d6d415b    /* 10^32 */
    .quad 0x38c15b0a00000000, 0x0000314dc6448d93    /* 10^33 */
    .quad 0x378d8e6400000000, 0x0001ed09bead87c0    /* 10^34 */
    .quad 0x2b878fe800000000, 0x0013426172c74d82    /* 10^35 */
    .quad 0xb34b9f1000000000, 0x00c097ce7bc90715    /* 10^36 */
    .quad 0x00f436a000000000, 0x0785ee10d5da46d9    /* 10^37 */
    .quad 0x098a224000000000, 0x4b3b4ca85a86c47a    /* 10^38 */
    .size p10_128, .-p10_128

    .text

/* ================================================================ basics */

/* dec_is_wide(type edi) -> eax */
FUNC dec_is_wide
    xor %eax, %eax
    cmp $T_DEC, %dil
    jne 1f
    mov %edi, %ecx
    shr $8, %ecx
    cmp $18, %cl
    seta %al
1:  ret
ENDF dec_is_wide

/* num_load(type edi, payload rsi) -> rax lo, rdx hi, ecx scale */
FUNC num_load
    movzbl %dil, %eax
    cmp $T_DEC, %eax
    je 1f
    mov %rsi, %rax                  /* INT64: scale 0 */
    cqo
    xor %ecx, %ecx
    ret
1:  mov %edi, %ecx
    shr $16, %ecx
    movzbl %cl, %ecx                /* scale */
    mov %edi, %edx
    shr $8, %edx
    cmp $18, %dl
    ja 2f
    mov %rsi, %rax                  /* narrow: inline i64 */
    cqo
    ret
2:  mov (%rsi), %rax                /* wide: boxed i128 */
    mov 8(%rsi), %rdx
    ret
ENDF num_load

/* dec_box(lo rdi, hi rsi) -> rax box in the current request arena */
FUNC dec_box
    push %rbx
    push %r12
    sub $8, %rsp
    mov %rdi, %rbx
    mov %rsi, %r12
    mov $16, %edi
    call tmp_alloc
    mov %rbx, (%rax)
    mov %r12, 8(%rax)
    add $8, %rsp
    pop %r12
    pop %rbx
    ret
ENDF dec_box

/* dec_box_in(arena rdi, lo rsi, hi rdx) -> rax box in the given arena */
FUNC dec_box_in
    push %rbx
    push %r12
    sub $8, %rsp
    mov %rsi, %rbx
    mov %rdx, %r12
    mov $16, %esi
    call arena_alloc
    mov %rbx, (%rax)
    mov %r12, 8(%rax)
    add $8, %rsp
    pop %r12
    pop %rbx
    ret
ENDF dec_box_in

/* i128_fits(lo rdi, hi rsi, p edx) -> eax 1 if |v| < 10^p (p = 0..38) */
FUNC i128_fits
    test %rsi, %rsi
    jns 1f
    neg %rdi                        /* magnitude */
    adc $0, %rsi
    neg %rsi
1:  movslq %edx, %rdx
    shl $4, %rdx
    lea p10_128(%rip), %rcx
    xor %eax, %eax
    cmp 8(%rcx, %rdx), %rsi
    jb 2f
    ja 3f
    cmp (%rcx, %rdx), %rdi
    jae 3f
2:  mov $1, %eax
3:  ret
ENDF i128_fits

/* dec_put(lo rdi, hi rsi, type edx) -> rax payload of type (overflow raised) */
FUNC dec_put
    push %rbx
    push %r12
    push %r13
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %edx, %r13d
    shr $8, %edx
    movzbl %dl, %edx
    call i128_fits
    test %eax, %eax
    jnz 1f
    call raise_overflow
1:  mov %r13d, %eax
    shr $8, %eax
    cmp $18, %al
    ja 2f
    mov %rbx, %rax                  /* narrow */
    jmp 9f
2:  mov %rbx, %rdi
    mov %r12, %rsi
    call dec_box
9:  pop %r13
    pop %r12
    pop %rbx
    ret
ENDF dec_put

/* ================================================================ 256-bit helpers */

/* u256_mul128(a_lo rdi, a_hi rsi, b_lo rdx, b_hi rcx, out r8): out = a * b
 * (unsigned 128 x 128 -> 256) */
FUNC u256_mul128
    push %rbx
    mov %rdx, %r9                   /* b0 */
    mov %rcx, %r10                  /* b1 */
    mov %rdi, %rax
    mul %r9                         /* a0 b0 */
    mov %rax, 0(%r8)
    mov %rdx, %r11                  /* word 1 */
    xor %ebx, %ebx                  /* word 2 */
    mov %rdi, %rax
    mul %r10                        /* a0 b1 */
    add %rax, %r11
    adc %rdx, %rbx
    xor %ecx, %ecx                  /* word 3 */
    mov %rsi, %rax
    mul %r9                         /* a1 b0 */
    add %rax, %r11
    adc %rdx, %rbx
    adc $0, %rcx
    mov %r11, 8(%r8)
    mov %rsi, %rax
    mul %r10                        /* a1 b1 */
    add %rax, %rbx
    adc %rdx, %rcx
    mov %rbx, 16(%r8)
    mov %rcx, 24(%r8)
    pop %rbx
    ret
ENDF u256_mul128

/* neg256(p rdi): two's complement negation in place */
FUNC neg256
    notq 0(%rdi)
    notq 8(%rdi)
    notq 16(%rdi)
    notq 24(%rdi)
    addq $1, 0(%rdi)
    adcq $0, 8(%rdi)
    adcq $0, 16(%rdi)
    adcq $0, 24(%rdi)
    ret
ENDF neg256

/* i256_scale(out rdi, lo rsi, hi rdx, k ecx): out = v * 10^k (k = 0..38) */
FUNC i256_scale
    push %rbx
    push %r12
    sub $8, %rsp
    mov %rdi, %r12                  /* out */
    mov %rdx, %rbx                  /* sign */
    mov %rsi, %rdi
    mov %rdx, %rsi
    test %rsi, %rsi
    jns 1f
    neg %rdi
    adc $0, %rsi
    neg %rsi
1:  mov %ecx, %ecx
    shl $4, %rcx
    lea p10_128(%rip), %r8
    mov (%r8, %rcx), %rdx
    mov 8(%r8, %rcx), %rcx
    mov %r12, %r8
    call u256_mul128
    test %rbx, %rbx
    jns 2f
    mov %r12, %rdi
    call neg256
2:  add $8, %rsp
    pop %r12
    pop %rbx
    ret
ENDF i256_scale

/* i256_add(out rdi, a rsi, b rdx) / i256_sub(out rdi, a rsi, b rdx) */
FUNC i256_add
    mov 0(%rsi), %rax
    add 0(%rdx), %rax
    mov %rax, 0(%rdi)
    mov 8(%rsi), %rax
    adc 8(%rdx), %rax
    mov %rax, 8(%rdi)
    mov 16(%rsi), %rax
    adc 16(%rdx), %rax
    mov %rax, 16(%rdi)
    mov 24(%rsi), %rax
    adc 24(%rdx), %rax
    mov %rax, 24(%rdi)
    ret
ENDF i256_add

FUNC i256_sub
    mov 0(%rsi), %rax
    sub 0(%rdx), %rax
    mov %rax, 0(%rdi)
    mov 8(%rsi), %rax
    sbb 8(%rdx), %rax
    mov %rax, 8(%rdi)
    mov 16(%rsi), %rax
    sbb 16(%rdx), %rax
    mov %rax, 16(%rdi)
    mov 24(%rsi), %rax
    sbb 24(%rdx), %rax
    mov %rax, 24(%rdi)
    ret
ENDF i256_sub

/* i256_cmp(a rdi, b rsi) -> eax -1/0/1 (signed) */
FUNC i256_cmp
    mov 24(%rdi), %rax
    cmp 24(%rsi), %rax
    jl 8f
    jg 9f
    mov 16(%rdi), %rax
    cmp 16(%rsi), %rax
    jb 8f
    ja 9f
    mov 8(%rdi), %rax
    cmp 8(%rsi), %rax
    jb 8f
    ja 9f
    mov 0(%rdi), %rax
    cmp 0(%rsi), %rax
    jb 8f
    ja 9f
    xor %eax, %eax
    ret
8:  mov $-1, %eax
    ret
9:  mov $1, %eax
    ret
ENDF i256_cmp

/* i256_narrow(src rdi, p esi) -> rax lo, rdx hi, ecx 1 if |v| < 10^p */
FUNC i256_narrow
    mov 0(%rdi), %r8
    mov 8(%rdi), %r9
    mov 16(%rdi), %r10
    mov 24(%rdi), %r11
    mov %r11, %rax                  /* sign mask */
    sar $63, %rax
    xor %rax, %r8                   /* magnitude = (v ^ m) - m */
    xor %rax, %r9
    xor %rax, %r10
    xor %rax, %r11
    sub %rax, %r8
    sbb %rax, %r9
    sbb %rax, %r10
    sbb %rax, %r11
    xor %ecx, %ecx
    or %r10, %r11
    jnz 9f
    movslq %esi, %rsi
    shl $4, %rsi
    lea p10_128(%rip), %rdx
    cmp 8(%rdx, %rsi), %r9
    jb 1f
    ja 9f
    cmp (%rdx, %rsi), %r8
    jae 9f
1:  mov $1, %ecx
    mov %rax, %rdx                  /* back to two's complement */
    mov %r8, %rax
    xor %rdx, %rax
    xor %rdx, %r9
    sub %rdx, %rax
    sbb %rdx, %r9
    mov %r9, %rdx
    ret
9:  xor %eax, %eax
    xor %edx, %edx
    ret
ENDF i256_narrow

/* u256_shr(p rdi, n esi): logical shift right in place, 0 <= n < 256 */
FUNC u256_shr
    mov %esi, %ecx
    and $63, %ecx                   /* bit shift */
    shr $6, %esi                    /* word shift */
    xor %r8d, %r8d                  /* i */
1:  cmp $4, %r8d
    jae 9f
    lea (%r8, %rsi), %r9            /* source word */
    xor %eax, %eax
    xor %edx, %edx
    cmp $4, %r9d
    jae 2f
    mov (%rdi, %r9, 8), %rax
    cmp $3, %r9d
    jae 2f
    mov 8(%rdi, %r9, 8), %rdx
2:  shrd %cl, %rdx, %rax
    mov %rax, (%rdi, %r8, 8)
    inc %r8d
    jmp 1b
9:  ret
ENDF u256_shr

/* ================================================================ division by powers of ten */

/* u128_div_pow10(lo rdi, hi rsi, k edx) -> rax lo, rdx hi, rcx 1 if inexact
 * (unsigned, truncating) */
FUNC u128_div_pow10
    push %rbx
    push %r12
    xor %r12d, %r12d                /* remainders seen */
    mov %edx, %ebx                  /* digits left */
    mov %rdi, %rax
    mov %rsi, %rdx
1:  test %ebx, %ebx
    jz 9f
    mov %ebx, %ecx
    cmp $19, %ecx
    jbe 2f
    mov $19, %ecx
2:  sub %ecx, %ebx
    shl $4, %ecx
    lea p10_128(%rip), %r8
    mov (%r8, %rcx), %r8            /* 10^c, c <= 19 fits 64 bits */
    mov %rax, %r9
    mov %rdx, %rax
    xor %edx, %edx
    div %r8
    mov %rax, %r10                  /* quotient high */
    mov %r9, %rax
    div %r8
    or %rdx, %r12
    mov %r10, %rdx
    jmp 1b
9:  xor %ecx, %ecx
    test %r12, %r12
    setnz %cl
    pop %r12
    pop %rbx
    ret
ENDF u128_div_pow10

/* i128_div_pow10(lo rdi, hi rsi, k edx) -> rax lo, rdx hi, rcx inexact
 * (truncation toward zero) */
FUNC i128_div_pow10
    push %rbx
    mov %rsi, %rbx                  /* sign */
    test %rsi, %rsi
    jns 1f
    neg %rdi
    adc $0, %rsi
    neg %rsi
1:  call u128_div_pow10
    test %rbx, %rbx
    jns 2f
    neg %rax
    adc $0, %rdx
    neg %rdx
2:  pop %rbx
    ret
ENDF i128_div_pow10

/* i128_round_pow10(lo rdi, hi rsi, k edx) -> rax lo, rdx hi:
 * v / 10^k rounded half away from zero */
FUNC i128_round_pow10
    test %edx, %edx
    jnz 1f
    mov %rdi, %rax
    mov %rsi, %rdx
    ret
1:  push %rbx
    mov %rsi, %rbx                  /* sign */
    test %rsi, %rsi
    jns 2f
    neg %rdi
    adc $0, %rsi
    neg %rsi
2:  dec %edx
    call u128_div_pow10             /* |v| / 10^(k-1) */
    mov $10, %r8d                   /* last digit decides */
    mov %rax, %r9
    mov %rdx, %rax
    xor %edx, %edx
    div %r8
    mov %rax, %r10
    mov %r9, %rax
    div %r8
    cmp $5, %rdx
    mov %r10, %rdx
    jb 3f
    add $1, %rax
    adc $0, %rdx
3:  test %rbx, %rbx
    jns 4f
    neg %rax
    adc $0, %rdx
    neg %rdx
4:  pop %rbx
    ret
ENDF i128_round_pow10

/* dec_rescale128(lo rdi, hi rsi, from edx, to ecx, p r8d)
 *   -> rax lo, rdx hi, ecx status (0 ok, 2 overflow) */
FUNC dec_rescale128
    ENTER 48
    mov %r8d, %ebx                  /* p */
    cmp %edx, %ecx
    jb 5f
    sub %edx, %ecx                  /* scale up by k = to - from: exact */
    cmp $38, %ecx
    jbe 1f
    mov %rdi, %rax                  /* only 0 survives a factor > 10^38 */
    or %rsi, %rax
    jnz 8f
    xor %edx, %edx
    xor %ecx, %ecx
    LEAVE
1:  mov %rsi, %rdx
    mov %rdi, %rsi
    mov %rsp, %rdi
    call i256_scale
    mov %rsp, %rdi
    mov %ebx, %esi
    call i256_narrow
    test %ecx, %ecx
    jz 8f
    xor %ecx, %ecx
    LEAVE
5:  sub %ecx, %edx                  /* scale down: round half away */
    call i128_round_pow10
    mov %rax, %r12
    mov %rdx, %r13
    mov %rax, %rdi
    mov %rdx, %rsi
    mov %ebx, %edx
    call i128_fits
    test %eax, %eax
    jz 8f
    mov %r12, %rax
    mov %r13, %rdx
    xor %ecx, %ecx
    LEAVE
8:  xor %eax, %eax
    xor %edx, %edx
    mov $2, %ecx
    LEAVE
ENDF dec_rescale128

/* ================================================================ comparison / arithmetic */

/* num_cmp(ta edi, a rsi, tb edx, b rcx) -> eax -1/0/1 (exact) */
FUNC num_cmp
    ENTER 112
    mov %edx, %r12d
    mov %rcx, %r13
    call num_load
    mov %rax, %r14
    mov %rdx, %r15
    mov %ecx, %ebx                  /* sa */
    mov %r12d, %edi
    mov %r13, %rsi
    call num_load                   /* b: rdx:rax, sb ecx */
    cmp %ecx, %ebx
    jne 5f
    cmp %rdx, %r15
    jl 7f
    jg 8f
    cmp %rax, %r14
    jb 7f
    ja 8f
    xor %eax, %eax
    LEAVE
5:  mov %rax, 64(%rsp)
    mov %rdx, 72(%rsp)
    mov %ecx, %r12d                 /* sb */
    mov %ebx, %r13d
    cmp %r12d, %r13d
    cmovb %r12d, %r13d              /* s = max(sa, sb) */
    mov %rsp, %rdi
    mov %r14, %rsi
    mov %r15, %rdx
    mov %r13d, %ecx
    sub %ebx, %ecx
    call i256_scale
    lea 32(%rsp), %rdi
    mov 64(%rsp), %rsi
    mov 72(%rsp), %rdx
    mov %r13d, %ecx
    sub %r12d, %ecx
    call i256_scale
    mov %rsp, %rdi
    lea 32(%rsp), %rsi
    call i256_cmp
    LEAVE
7:  mov $-1, %eax
    LEAVE
8:  mov $1, %eax
    LEAVE
ENDF num_cmp

/* dec_arith(op edi, ta esi, a rdx, tb ecx, b r8, tr r9d) -> rax payload */
#define DA_ALO 64
#define DA_AHI 72
#define DA_BLO 80
#define DA_BHI 88
#define DA_SA  96
#define DA_SB  100
FUNC dec_arith
    ENTER 112
    mov %edi, %ebx                  /* op */
    mov %ecx, %r12d                 /* tb */
    mov %r8, %r13                   /* b */
    mov %r9d, %r14d                 /* result type */
    mov %esi, %edi
    mov %rdx, %rsi
    call num_load
    mov %rax, DA_ALO(%rsp)
    mov %rdx, DA_AHI(%rsp)
    mov %ecx, DA_SA(%rsp)
    mov %r12d, %edi
    mov %r13, %rsi
    call num_load
    mov %rax, DA_BLO(%rsp)
    mov %rdx, DA_BHI(%rsp)
    mov %ecx, DA_SB(%rsp)
    cmp $B_MUL, %ebx
    je 5f
    mov %r14d, %r15d                /* + / -: both at the result scale */
    shr $16, %r15d
    movzbl %r15b, %r15d
    mov %rsp, %rdi
    mov DA_ALO(%rsp), %rsi
    mov DA_AHI(%rsp), %rdx
    mov %r15d, %ecx
    sub DA_SA(%rsp), %ecx
    call i256_scale
    lea 32(%rsp), %rdi
    mov DA_BLO(%rsp), %rsi
    mov DA_BHI(%rsp), %rdx
    mov %r15d, %ecx
    sub DA_SB(%rsp), %ecx
    call i256_scale
    mov %rsp, %rdi
    mov %rsp, %rsi
    lea 32(%rsp), %rdx
    cmp $B_ADD, %ebx
    jne 1f
    call i256_add
    jmp 7f
1:  call i256_sub
    jmp 7f
5:  /* *: |a| * |b| exactly, then the sign */
    mov DA_AHI(%rsp), %r15
    xor DA_BHI(%rsp), %r15          /* sign of the product */
    mov DA_ALO(%rsp), %rdi
    mov DA_AHI(%rsp), %rsi
    test %rsi, %rsi
    jns 51f
    neg %rdi
    adc $0, %rsi
    neg %rsi
51: mov DA_BLO(%rsp), %rdx
    mov DA_BHI(%rsp), %rcx
    test %rcx, %rcx
    jns 52f
    neg %rdx
    adc $0, %rcx
    neg %rcx
52: mov %rsp, %r8
    call u256_mul128
    test %r15, %r15
    jns 7f
    mov %rsp, %rdi
    call neg256
7:  mov %rsp, %rdi
    mov %r14d, %esi
    shr $8, %esi
    movzbl %sil, %esi
    call i256_narrow
    test %ecx, %ecx
    jnz 8f
    call raise_overflow
8:  mov %rax, %rdi
    mov %rdx, %rsi
    mov %r14d, %edx
    call dec_put
    LEAVE
ENDF dec_arith

/* ================================================================ text */

/* MUL10ADD lo, hi, digit: (hi:lo) = (hi:lo) * 10 + digit (no overflow;
 * clobbers rax, rdx, r10) */
.macro MUL10ADD lo, hi, dig
    mov \lo, %rax
    mov $10, %r10d
    mul %r10
    imul $10, \hi, \hi
    add %rdx, \hi
    add \dig, %rax
    adc $0, \hi
    mov %rax, \lo
.endm

/* dec_parse(ptr rdi, len rsi, prec edx, scale ecx, mode r8d, out r9) -> eax */
#define DP_OUT   0
#define DP_NEG   8
#define DP_IS    16      /* integer digits [IS, IE) */
#define DP_IE    24
#define DP_FS    32      /* fraction digits [FS, FE) */
#define DP_FE    40
FUNC dec_parse
    ENTER 48
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %edx, %r13d
    mov %ecx, %r14d
    mov %r8d, %r15d
    mov %r9, DP_OUT(%rsp)
    cmp $38, %r13d
    jbe 1f
    mov $38, %r13d
1:  cmp $38, %r14d
    jbe 2f
    mov $38, %r14d
2:  movq $0, DP_NEG(%rsp)
    xor %ecx, %ecx
    test %r12, %r12
    jz 90f
    movzbl (%rbx), %eax
    cmp $'+', %eax
    je 3f
    cmp $'-', %eax
    jne 4f
    movq $1, DP_NEG(%rsp)
3:  inc %rcx
4:  mov %rcx, DP_IS(%rsp)
5:  cmp %r12, %rcx
    jae 6f
    movzbl (%rbx, %rcx), %eax
    sub $'0', %eax
    cmp $9, %eax
    ja 6f
    inc %rcx
    jmp 5b
6:  mov %rcx, DP_IE(%rsp)
    mov %rcx, DP_FS(%rsp)
    mov %rcx, DP_FE(%rsp)
    cmp %r12, %rcx
    jae 8f
    cmpb $'.', (%rbx, %rcx)
    jne 90f
    inc %rcx
    mov %rcx, DP_FS(%rsp)
7:  cmp %r12, %rcx
    jae 71f
    movzbl (%rbx, %rcx), %eax
    sub $'0', %eax
    cmp $9, %eax
    ja 90f
    inc %rcx
    jmp 7b
71: mov %rcx, DP_FE(%rsp)
8:  /* at least one digit */
    mov DP_IE(%rsp), %rax
    sub DP_IS(%rsp), %rax
    mov DP_FE(%rsp), %rdx
    sub DP_FS(%rsp), %rdx
    add %rdx, %rax
    jz 90f
    /* fraction digits beyond the scale */
    xor %r11d, %r11d                /* round-up digit flag */
    cmp %r14, %rdx
    jbe 9f
    test %r15d, %r15d
    jz 93f
    mov DP_FS(%rsp), %rax
    add %r14, %rax
    cmpb $'5', (%rbx, %rax)
    setae %r11b
9:  /* skip leading zeros of the integer part */
    mov DP_IS(%rsp), %rcx
10: cmp DP_IE(%rsp), %rcx
    jae 11f
    cmpb $'0', (%rbx, %rcx)
    jne 11f
    inc %rcx
    jmp 10b
11: mov DP_IE(%rsp), %rax
    sub %rcx, %rax
    add %r14, %rax                  /* significant digits incl. the scale */
    cmp $38, %rax
    ja 92f
    xor %r8d, %r8d                  /* value lo */
    xor %r9d, %r9d                  /* value hi */
12: cmp DP_IE(%rsp), %rcx
    jae 13f
    movzbl (%rbx, %rcx), %esi
    sub $'0', %esi
    MUL10ADD %r8, %r9, %rsi
    inc %rcx
    jmp 12b
13: mov DP_FS(%rsp), %rcx           /* exactly `scale` fraction digits */
    xor %edi, %edi                  /* digits taken */
14: cmp %r14d, %edi
    jae 16f
    xor %esi, %esi
    cmp DP_FE(%rsp), %rcx
    jae 15f
    movzbl (%rbx, %rcx), %esi
    sub $'0', %esi
    inc %rcx
15: MUL10ADD %r8, %r9, %rsi
    inc %edi
    jmp 14b
16: add %r11, %r8
    adc $0, %r9
    mov %r13d, %eax                 /* < 10^prec */
    shl $4, %rax
    lea p10_128(%rip), %rdx
    cmp 8(%rdx, %rax), %r9
    jb 17f
    ja 92f
    cmp (%rdx, %rax), %r8
    jae 92f
17: cmpq $0, DP_NEG(%rsp)
    je 18f
    neg %r8
    adc $0, %r9
    neg %r9
18: mov DP_OUT(%rsp), %rax
    mov %r8, (%rax)
    mov %r9, 8(%rax)
    xor %eax, %eax
    LEAVE
90: mov $1, %eax
    jmp 99f
92: mov $2, %eax
    jmp 99f
93: mov $3, %eax
99: mov DP_OUT(%rsp), %rcx
    movq $0, (%rcx)
    movq $0, 8(%rcx)
    LEAVE
ENDF dec_parse

/* u128_digits(end rdi, lo rsi, hi rdx, min ecx) -> rax first digit: writes
 * the decimal digits of the unsigned value backwards ending before `end`,
 * at least `min` digits (zero padded) and at least one (leaf) */
FUNC u128_digits
    mov %rdx, %r9
    mov %ecx, %r11d
    mov $10, %r8d
1:  mov %r9, %rax
    xor %edx, %edx
    div %r8
    mov %rax, %r9
    mov %rsi, %rax
    div %r8
    mov %rax, %rsi
    add $'0', %edx
    dec %rdi
    mov %dl, (%rdi)
    dec %r11d
    mov %rsi, %rax
    or %r9, %rax
    jnz 1b
    test %r11d, %r11d
    jg 1b
    mov %rdi, %rax
    ret
ENDF u128_digits

/* fmt_dec128(buf rdi, lo rsi, hi rdx, scale ecx) */
FUNC fmt_dec128
    ENTER 80
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %ecx, %r14d
    test %r13, %r13
    jns 1f
    neg %r12
    adc $0, %r13
    neg %r13
    mov $'-', %esi
    call buf_putc
1:  lea 64(%rsp), %rdi
    mov %r12, %rsi
    mov %r13, %rdx
    lea 1(%r14), %ecx               /* at least one integer digit */
    call u128_digits
    mov %rax, %r15
    lea 64(%rsp), %r12
    sub %rax, %r12                  /* digit count */
    sub %r14, %r12                  /* integer digits */
    mov %rbx, %rdi
    mov %r15, %rsi
    mov %r12, %rdx
    call buf_put
    test %r14d, %r14d
    jz 9f
    mov %rbx, %rdi
    mov $'.', %esi
    call buf_putc
    mov %rbx, %rdi
    lea (%r15, %r12), %rsi
    mov %r14, %rdx
    call buf_put
9:  LEAVE
ENDF fmt_dec128

/* dec128_to_double(lo rdi, hi rsi, scale edx) -> xmm0 (correctly rounded:
 * the exact digits go through strtod) */
FUNC dec128_to_double
    ENTER 80
    mov %edx, %ebx
    mov %rsi, %r12                  /* sign */
    mov %rsi, %rdx
    test %rdx, %rdx
    jns 1f
    neg %rdi
    adc $0, %rdx
    neg %rdx
1:  mov %rdi, %rsi
    lea 48(%rsp), %rdi
    mov $1, %ecx
    call u128_digits
    mov %rax, %r13                  /* text start */
    test %r12, %r12
    jns 2f
    dec %r13
    movb $'-', (%r13)
2:  movb $'e', 48(%rsp)             /* exponent -scale (scale <= 38) */
    movb $'-', 49(%rsp)
    mov %ebx, %eax
    xor %edx, %edx
    mov $10, %ecx
    div %ecx
    add $'0', %eax
    add $'0', %edx
    mov %al, 50(%rsp)
    mov %dl, 51(%rsp)
    movb $0, 52(%rsp)
    mov %r13, %rdi
    xor %esi, %esi
    call strtod
    LEAVE
ENDF dec128_to_double

/* ================================================================ conversions */

/* double_to_dec128(x xmm0, prec edi, scale esi, out rdx) -> eax status */
FUNC double_to_dec128
    ENTER 48
    mov %edi, %r12d                 /* prec */
    mov %esi, %r13d                 /* scale */
    mov %rdx, %r14                  /* out */
    movq %xmm0, %rbx
    mov %rbx, %r15
    shr $63, %r15                   /* sign */
    mov %rbx, %rcx
    shr $52, %rcx
    and $0x7ff, %ecx                /* biased exponent */
    movabs $0xfffffffffffff, %rax
    and %rax, %rbx                  /* mantissa */
    cmp $0x7ff, %ecx
    je 92f                          /* inf / nan */
    test %ecx, %ecx
    jnz 1f
    test %rbx, %rbx
    jz 80f                          /* +-0 */
    mov $-1074, %ecx                /* subnormal */
    jmp 2f
1:  bts $52, %rbx
    sub $1075, %ecx                 /* x = m * 2^E */
2:  test %ecx, %ecx
    js 5f
    /* E >= 0: integer m << E (< 2^128 when E <= 74), times 10^scale */
    cmp $74, %ecx
    jg 92f
    xor %esi, %esi
    mov %rbx, %rdi
    shld %cl, %rdi, %rsi
    shl %cl, %rdi
    cmp $64, %ecx
    jb 3f
    mov %rdi, %rsi                  /* shifts of 64..74 bits */
    xor %edi, %edi
3:  mov %r13d, %eax
    shl $4, %rax
    lea p10_128(%rip), %r8
    mov (%r8, %rax), %rdx
    mov 8(%r8, %rax), %rcx
    mov %rsp, %r8
    call u256_mul128
    jmp 7f
5:  /* E < 0: round(m * 10^scale / 2^-E) */
    neg %ecx
    mov %ecx, 32(%rsp)              /* n */
    mov %r13d, %eax
    shl $4, %rax
    lea p10_128(%rip), %r8
    mov (%r8, %rax), %rdx
    mov 8(%r8, %rax), %rcx
    mov %rbx, %rdi
    xor %esi, %esi
    mov %rsp, %r8
    call u256_mul128                /* < 2^180 */
    mov 32(%rsp), %ecx
    cmp $256, %ecx
    jae 80f
    lea -1(%rcx), %rax              /* half bit = bit n-1 */
    xor %edx, %edx
    bt %rax, (%rsp)
    setc %dl
    mov %rdx, 40(%rsp)
    mov %rsp, %rdi
    mov %ecx, %esi
    call u256_shr
    mov 40(%rsp), %rax
    add %rax, 0(%rsp)
    adcq $0, 8(%rsp)
    adcq $0, 16(%rsp)
    adcq $0, 24(%rsp)
7:  /* magnitude in 0(%rsp): must be < 10^prec */
    mov %rsp, %rdi
    mov %r12d, %esi
    call i256_narrow
    test %ecx, %ecx
    jz 92f
    test %r15, %r15
    jz 8f
    neg %rax
    adc $0, %rdx
    neg %rdx
8:  mov %rax, (%r14)
    mov %rdx, 8(%r14)
    xor %eax, %eax
    LEAVE
80: movq $0, (%r14)
    movq $0, 8(%r14)
    xor %eax, %eax
    LEAVE
92: movq $0, (%r14)
    movq $0, 8(%r14)
    mov $2, %eax
    LEAVE
ENDF double_to_dec128

/* dec128_to_int(lo rdi, hi rsi, scale edx) -> rax, edx status */
FUNC dec128_to_int
    sub $8, %rsp
    call i128_div_pow10
    mov %rax, %rcx
    sar $63, %rcx
    cmp %rcx, %rdx
    jne 1f
    xor %edx, %edx
    add $8, %rsp
    ret
1:  xor %eax, %eax
    mov $2, %edx
    add $8, %rsp
    ret
ENDF dec128_to_int

/* ================================================================ SUM / AVG accumulators */

/* sum192_add(acc rdi, lo rsi, hi rdx) */
FUNC sum192_add
    mov %rdx, %rax
    sar $63, %rax
    add %rsi, 0(%rdi)
    adc %rdx, 8(%rdi)
    adc %rax, 16(%rdi)
    ret
ENDF sum192_add

/* sum192_merge(acc rdi, other rsi): acc += other */
FUNC sum192_merge
    mov 0(%rsi), %rax
    add %rax, 0(%rdi)
    mov 8(%rsi), %rax
    adc %rax, 8(%rdi)
    mov 16(%rsi), %rax
    adc %rax, 16(%rdi)
    ret
ENDF sum192_merge

/* sum192_to_i128(acc rdi) -> rax lo, rdx hi, ecx 1 if it fits i128 */
FUNC sum192_to_i128
    mov 0(%rdi), %rax
    mov 8(%rdi), %rdx
    mov %rdx, %rcx
    sar $63, %rcx
    cmp 16(%rdi), %rcx
    sete %cl
    movzbl %cl, %ecx
    ret
ENDF sum192_to_i128

/* avg192_to_double(acc rdi, count rsi, scale edx) -> xmm0: the quotient
 * sum / count is written out exactly (integer digits, then fraction digits
 * by long division up to 40 significant ones) and converted by strtod */
#define AV_W    0        /* |sum| as 3 words */
#define AV_TXT  32       /* text, 256 bytes */
#define AV_DEND 160      /* integer digits are produced backwards before this */
FUNC avg192_to_double
    ENTER 320
    mov %rsi, %rbx                  /* count */
    mov %edx, %r12d                 /* scale */
    mov 0(%rdi), %r8
    mov 8(%rdi), %r9
    mov 16(%rdi), %r10
    mov %r10, %r13
    sar $63, %r13                   /* sign mask */
    xor %r13, %r8
    xor %r13, %r9
    xor %r13, %r10
    sub %r13, %r8
    sbb %r13, %r9
    sbb %r13, %r10
    mov %r8, AV_W(%rsp)
    mov %r9, AV_W+8(%rsp)
    mov %r10, AV_W+16(%rsp)
    /* integer quotient in place, remainder in r14 */
    xor %edx, %edx
    mov AV_W+16(%rsp), %rax
    div %rbx
    mov %rax, AV_W+16(%rsp)
    mov AV_W+8(%rsp), %rax
    div %rbx
    mov %rax, AV_W+8(%rsp)
    mov AV_W(%rsp), %rax
    div %rbx
    mov %rax, AV_W(%rsp)
    mov %rdx, %r14
    /* integer digits backwards before AV_DEND */
    lea AV_DEND(%rsp), %r15
    mov $10, %ecx
1:  xor %edx, %edx
    mov AV_W+16(%rsp), %rax
    div %rcx
    mov %rax, AV_W+16(%rsp)
    mov AV_W+8(%rsp), %rax
    div %rcx
    mov %rax, AV_W+8(%rsp)
    mov AV_W(%rsp), %rax
    div %rcx
    mov %rax, AV_W(%rsp)
    add $'0', %edx
    dec %r15
    mov %dl, (%r15)
    mov AV_W(%rsp), %rax
    or AV_W+8(%rsp), %rax
    or AV_W+16(%rsp), %rax
    jnz 1b
    lea AV_DEND(%rsp), %r9
    sub %r15, %r9                   /* significant integer digits */
    cmp $1, %r9
    jne 2f
    cmpb $'0', (%r15)
    jne 2f
    xor %r9d, %r9d                  /* the integer part is 0 */
2:  test %r13, %r13
    jz 22f
    dec %r15
    movb $'-', (%r15)
22: lea AV_DEND(%rsp), %rdi
    movb $'.', (%rdi)
    inc %rdi
    xor %r10d, %r10d                /* fraction digits */
3:  test %r14, %r14
    jz 5f
    cmp $40, %r9
    jae 5f
    cmp $80, %r10
    jae 5f
    mov %r14, %rax
    mov $10, %ecx
    mul %rcx
    div %rbx
    mov %rdx, %r14
    test %rax, %rax
    jnz 4f
    test %r9, %r9
    jz 41f
4:  inc %r9
41: add $'0', %eax
    mov %al, (%rdi)
    inc %rdi
    inc %r10
    jmp 3b
5:  movb $'e', (%rdi)
    movb $'-', 1(%rdi)
    mov %r12d, %eax
    xor %edx, %edx
    mov $10, %ecx
    div %ecx
    add $'0', %eax
    add $'0', %edx
    mov %al, 2(%rdi)
    mov %dl, 3(%rdi)
    movb $0, 4(%rdi)
    mov %r15, %rdi
    xor %esi, %esi
    call strtod
    LEAVE
ENDF avg192_to_double

/* dec_cmp_any(ta edi, a rsi, tb edx, b rcx) -> eax -1/0/1: exact comparison
 * of INT64 / DECIMAL values; INT64 and narrow operands use eval.S dec_cmp */
FUNC dec_cmp_any
    mov %edi, %eax
    shr $8, %eax
    cmp $T_DEC, %dil
    jne 1f
    cmp $18, %al
    ja num_cmp
1:  mov %edx, %eax
    shr $8, %eax
    cmp $T_DEC, %dl
    jne 2f
    cmp $18, %al
    ja num_cmp
2:  mov %edi, %r8d
    shr $16, %r8d
    movzbl %r8b, %r8d               /* sa (INT64: 0) */
    mov %edx, %r9d
    shr $16, %r9d
    movzbl %r9b, %r9d               /* sb */
    mov %rsi, %rdi
    mov %r8d, %esi
    mov %rcx, %rdx
    mov %r9d, %ecx
    jmp dec_cmp
ENDF dec_cmp_any

/* ================================================================ functions */

/* round_dec128(box rdi, s esi, n rdx) -> rax box: ROUND of a wide decimal to
 * n digits (result scale max(0, min(n, s))) */
FUNC round_dec128
    push %rbx
    push %r12
    sub $8, %rsp
    mov %rdx, %rbx                  /* n */
    movslq %esi, %rax
    mov %rdi, %rcx
    cmp %rax, %rbx
    jge 9f                          /* n >= s: unchanged */
    sub %rbx, %rax                  /* k = s - n digits dropped */
    xor %ecx, %ecx
    xor %edx, %edx
    cmp $40, %rax
    jae 5f                          /* |v| < 10^38 rounds to 0 */
    mov (%rdi), %rcx
    mov 8(%rdi), %rsi
    mov %rcx, %rdi
    mov %eax, %edx
    call i128_round_pow10
    test %rbx, %rbx
    jns 4f
    mov %rax, %rdi                  /* n < 0: back to scale 0 */
    mov %rdx, %rsi
    xor %edx, %edx
    mov %rbx, %rcx
    neg %rcx
    cmp $64, %rcx
    jb 1f
    mov $64, %ecx
1:  mov $38, %r8d
    call dec_rescale128
    test %ecx, %ecx
    jz 4f
    call raise_overflow
4:  mov %rax, %rcx
5:  mov %rcx, %rdi
    mov %rdx, %rsi
    call dec_box
    mov %rax, %rcx
9:  mov %rcx, %rax
    add $8, %rsp
    pop %r12
    pop %rbx
    ret
ENDF round_dec128

/* floor_dec128(box rdi, s esi, ceil edx) -> rax box: FLOOR / CEIL of a wide
 * decimal to scale 0 */
FUNC floor_dec128
    push %rbx
    push %r12
    sub $8, %rsp
    mov %edx, %r12d
    mov 8(%rdi), %rbx               /* sign */
    mov %esi, %edx
    mov 8(%rdi), %rsi
    mov (%rdi), %rdi
    call i128_div_pow10             /* truncated, rcx = inexact */
    test %ecx, %ecx
    jz 9f
    test %r12d, %r12d
    jnz 2f
    test %rbx, %rbx                 /* FLOOR: negative inexact values - 1 */
    jns 9f
    sub $1, %rax
    sbb $0, %rdx
    jmp 9f
2:  test %rbx, %rbx                 /* CEIL: positive inexact values + 1 */
    js 9f
    add $1, %rax
    adc $0, %rdx
9:  mov %rax, %rdi
    mov %rdx, %rsi
    call dec_box
    add $8, %rsp
    pop %r12
    pop %rbx
    ret
ENDF floor_dec128
