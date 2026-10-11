/*
 * pqk_x86_scalar.S — PolyQuery native kernels, variant "x86_scalar".
 *
 * Baseline x86-64 only (no POPCNT/BMI/AVX; SSE2 scalar double ops only), so
 * this variant runs on every x86-64 CPU. All 20 kernels of pq_kernels.h
 * (ABI revision 1) as global symbols pqk_x86_scalar_<kernel>, System V
 * AMD64 ABI. Every kernel is bit-identical to the reference, including
 * sum_f64 (same sequential addition order) and the sign of zero in
 * minmax_f64.
 *
 * Layout of this file:
 *   1. file-local helpers and tables used by several kernels
 *   2. the kernels, in pq_kernels.h order; each starts with a header comment
 *      (arguments, result, clobbered registers, algorithm, tail strategy)
 *      and follows the [check] / [main] / [tail] / [result] skeleton
 *      described in pqk_x86_common.h.
 * Building blocks shared with other variants or kernels live in
 * pqk_x86_common.h (+ pqk_x86_consts.h) and pqk_x86_scalar.h (see README,
 * "Shared building blocks"). Kernel-private macros/helpers stay next to
 * their kernel.
 *
 * ABI notes: internal helpers have documented private register conventions
 * and use the stack only for call/ret; no red zone is used; kernels save and
 * restore every callee-saved register they use (PROLOGUE / EPILOGUE).
 */
#include "pqk_x86_common.h"              /* includes pqk_x86_consts.h */
#include "pqk_x86_scalar.h"

        .set PQK_BMI, 0                 /* baseline: bsf / shifts, no BMI */
        .text

/* ========================================================================
 * 1. File-local helpers used by several kernels
 *   popcnt64        SWAR popcount (PRED_DRIVER, compare_i64, bitmap_popcount)
 *   lvp             partial validity word (all kernels with validity)
 *   sop_*, sop_table   i64 predicate mask routines (filter/bitmap/count_i64)
 * ====================================================================== */
        DEFINE_POPCNT64
        DEFINE_LVP

        SOP sop_eq, e
        SOP sop_ne, ne
        SOP sop_lt, l
        SOP sop_le, le
        SOP sop_gt, g
        SOP sop_ge, ge
        SOP sop_bt, bt

/* sop_false: BETWEEN with a > b, the empty predicate (rax = 0). */
LFUNC sop_false
        xor     %eax, %eax
        ret
ENDF sop_false

        OPTABLE sop_table, sop

/* ========================================================================
 * size_t pqk_x86_scalar_filter_i64(data, validity, n, op, a, b, out_idx)
 * Args:     rdi = data, rsi = validity, rdx = n, ecx = op, r8 = a, r9 = b,
 *           8(%rsp) = out_idx
 * Returns:  rax = number of indices written; (size_t)-1 for an invalid op
 * Clobbers: rax, rcx, rdx, rsi, rdi, r9, r10, r11, flags
 *           (rbx, rbp, r12-r15 saved and restored)
 * Algorithm: PRED_DRIVER: 64-row blocks; sop_<op> builds the block mask
 *           (8 rows per step, independent setcc chains), & validity word,
 *           indices emitted with bsf / x &= x-1 (EMIT_IDX_BITS).
 * Tail:     the last block (len < 64) runs through the same loop; sop_*
 *           does 1..7 single rows, lvp loads exactly ceil(len/8) bytes.
 * ====================================================================== */
FUNC pqk_x86_scalar_filter_i64
        PRED_DRIVER MODE_FILTER, filter_i64
ENDF pqk_x86_scalar_filter_i64

/* ========================================================================
 * size_t pqk_x86_scalar_filter_i64_bitmap(data, validity, n, op, a, b,
 *                                         out_bits)
 * Args:     rdi = data, rsi = validity, rdx = n, ecx = op, r8 = a, r9 = b,
 *           8(%rsp) = out_bits
 * Returns:  rax = number of set bits; (size_t)-1 for an invalid op
 * Clobbers: rax, rcx, rdx, rsi, rdi, r9, r10, r11, flags
 *           (rbx, rbp, r12-r15 saved and restored)
 * Algorithm: PRED_DRIVER: as filter_i64; each full block mask is stored
 *           with one 8-byte store and counted with popcnt64 (SWAR).
 * Tail:     last block: ceil(len/8) single-byte stores (trailing bits are
 *           already 0, nothing past ceil(n/8) is written).
 * ====================================================================== */
FUNC pqk_x86_scalar_filter_i64_bitmap
        PRED_DRIVER MODE_BITMAP, filter_i64_bitmap
ENDF pqk_x86_scalar_filter_i64_bitmap

/* ========================================================================
 * size_t pqk_x86_scalar_count_i64(data, validity, n, op, a, b)
 * Args:     rdi = data, rsi = validity, rdx = n, ecx = op, r8 = a, r9 = b
 * Returns:  rax = number of valid rows satisfying op; (size_t)-1 if invalid
 * Clobbers: rax, rcx, rdx, rsi, rdi, r9, r10, r11, flags
 *           (rbx, rbp, r12-r15 saved and restored)
 * Algorithm: PRED_DRIVER: as filter_i64; masks are counted with popcnt64.
 * Tail:     as filter_i64 (same block loop, len < 64).
 * ====================================================================== */
FUNC pqk_x86_scalar_count_i64
        PRED_DRIVER MODE_COUNT, count_i64
ENDF pqk_x86_scalar_count_i64

/* ========================================================================
 * size_t pqk_x86_scalar_compare_i64(a, b, n, op, out_bits)
 * Args:     rdi = a, rsi = b, rdx = n, ecx = op, r8 = out_bits
 * Returns:  rax = number of set bits; (size_t)-1 for an invalid op
 *           (BETWEEN is invalid here)
 * Clobbers: rax, rcx, rdx, rsi, rdi, r9, r10, r11, flags
 *           (rbx, rbp, r12-r15 saved and restored)
 * Algorithm: 64-row blocks like PRED_DRIVER: the element-wise routine
 *           scmp_<op> builds the block mask (8 rows per step), which is
 *           stored (8 bytes) and counted with popcnt64.
 *           r12 = a block, r13 = b block, r14 = remaining, r15 = routine,
 *           rbx = set-bit count, rbp = out ptr.
 * Tail:     last block: scmp_* does 1..7 single rows; ceil(len/8) single
 *           byte stores (STORE_BITS_TAIL).
 * ====================================================================== */

/* Element-wise compare routines scmp_* (compare_i64 only): a[i] op b[i].
 * in:  rdi = &a[block], rsi = &b[block], edx = len (1..64).
 * out: rax = mask (bits >= len 0).
 * clobbers rcx, rdx, rdi, rsi, r9, r10, r11. Same forward 8-row scheme as
 * SOP. */
.macro SCMP name, cc
LFUNC \name
        xor     %eax, %eax
        xor     %ecx, %ecx
        mov     %edx, %r9d
        cmp     $8, %r9d
        jb      .L\name\()_tail
.L\name\()_step:                        /* [main] 8 rows */
        xor     %r11d, %r11d
        .set j, 0
        .rept 8
        mov     j*8(%rdi), %rdx
        xor     %r10d, %r10d
        cmp     j*8(%rsi), %rdx         /* flags of a[i] - b[i] */
        set\cc  %r10b
        .if j
        shl     $j, %r10d
        .endif
        or      %r10d, %r11d
        .set j, j + 1
        .endr
        shl     %cl, %r11
        or      %r11, %rax
        add     $64, %rdi
        add     $64, %rsi
        add     $8, %ecx
        sub     $8, %r9d
        cmp     $8, %r9d
        jae     .L\name\()_step
.L\name\()_tail:                        /* [tail] 0..7 rows */
        test    %r9d, %r9d
        jz      .L\name\()_done
.L\name\()_row:
        mov     (%rdi), %rdx
        xor     %r10d, %r10d
        cmp     (%rsi), %rdx
        set\cc  %r10b
        shl     %cl, %r10
        or      %r10, %rax
        add     $8, %rdi
        add     $8, %rsi
        inc     %ecx
        dec     %r9d
        jnz     .L\name\()_row
.L\name\()_done:
        ret
ENDF \name
.endm

        SCMP scmp_eq, e
        SCMP scmp_ne, ne
        SCMP scmp_lt, l
        SCMP scmp_le, le
        SCMP scmp_gt, g
        SCMP scmp_ge, ge
        CMPTABLE scmp_table, scmp

#define SAVED %rbx, %rbp, %r12, %r13, %r14, %r15
FUNC pqk_x86_scalar_compare_i64
        OP_CHECK PQK_CMP_OP_LAST, .Lcompare_i64_inval   /* [check] */
        PROLOGUE SAVED
        mov     %ecx, %ecx
        JTAB_LOAD scmp_table, %r15
        mov     %rdi, %r12
        mov     %rsi, %r13
        mov     %rdx, %r14
        mov     %r8, %rbp
        xor     %ebx, %ebx
        test    %r14, %r14
        jz      .Lcompare_i64_result
.Lcompare_i64_main:                                     /* [main] 64 rows */
        mov     $64, %edx
        cmp     %rdx, %r14
        cmovb   %r14, %rdx
        mov     %r12, %rdi
        mov     %r13, %rsi
        call    *%r15
        cmp     $64, %r14
        jb      .Lcompare_i64_tail
        STORE_BITS_FULL
        jmp     .Lcompare_i64_count
.Lcompare_i64_tail:                                     /* [tail] */
        mov     %rax, %r10
        STORE_BITS_TAIL
        mov     %r10, %rax
.Lcompare_i64_count:
        call    popcnt64
        add     %rax, %rbx
        add     $512, %r12
        add     $512, %r13
        sub     $64, %r14
        ja      .Lcompare_i64_main
.Lcompare_i64_result:                                   /* [result] */
        mov     %rbx, %rax
        EPILOGUE SAVED
        ret
.Lcompare_i64_inval:
        OP_INVALID
ENDF pqk_x86_scalar_compare_i64
#undef SAVED

/* ========================================================================
 * int pqk_x86_scalar_sum_i64(data, validity, n, out_sum)
 * Args:     rdi = data, rsi = validity, rdx = n, rcx = out_sum
 * Returns:  eax = PQK_OK (sum stored) or PQK_OVERFLOW (*out_sum untouched)
 * Clobbers: rax, rcx, rdx, rsi, rdi, r8, r9, r10, r11, flags
 *           (rbx saved and restored)
 * Algorithm: exact 128-bit accumulation in r9:r8 (hi:lo): add x; adc
 *           sign(x) (cqo). Invalid rows are zeroed branch-free (VBIT_MASK:
 *           shr validity word -> CF, sbb -> 0/-1 mask). Overflow iff hi is
 *           not the sign extension of lo (JNE_SEXT).
 *           r10 = remaining rows, r11 = out_sum, rbx = validity word.
 * Tail:     no validity: 4 rows per step, then single rows. Validity:
 *           64-row blocks; the last one is loaded with lvp (VWORD_BLOCK).
 * ====================================================================== */
#define SAVED %rbx
FUNC pqk_x86_scalar_sum_i64
        PROLOGUE SAVED
        xor     %r8d, %r8d                              /* [check] */
        xor     %r9d, %r9d
        mov     %rcx, %r11
        mov     %rdx, %r10
        test    %r10, %r10
        jz      .Lsum_i64_result
        test    %rsi, %rsi
        jnz     .Lsum_i64_vmain
        cmp     $4, %r10
        jb      .Lsum_i64_tail
.Lsum_i64_main:                                         /* [main] 4 rows */
        mov     (%rdi), %rax
        cqo
        add     %rax, %r8
        adc     %rdx, %r9
        mov     8(%rdi), %rax
        cqo
        add     %rax, %r8
        adc     %rdx, %r9
        mov     16(%rdi), %rax
        cqo
        add     %rax, %r8
        adc     %rdx, %r9
        mov     24(%rdi), %rax
        cqo
        add     %rax, %r8
        adc     %rdx, %r9
        add     $32, %rdi
        sub     $4, %r10
        cmp     $4, %r10
        jae     .Lsum_i64_main
        test    %r10, %r10
        jz      .Lsum_i64_result
.Lsum_i64_tail:                                         /* [tail] 1 row */
        mov     (%rdi), %rax
        cqo
        add     %rax, %r8
        adc     %rdx, %r9
        add     $8, %rdi
        dec     %r10
        jnz     .Lsum_i64_tail
        jmp     .Lsum_i64_result
.Lsum_i64_vmain:                /* [main] validity blocks; [tail] last block */
        VWORD_BLOCK %r10, %r10d, %rbx
.Lsum_i64_vrow:
        mov     (%rdi), %rax
        VBIT_MASK %rbx, %rdx
        and     %rdx, %rax
        cqo
        add     %rax, %r8
        adc     %rdx, %r9
        add     $8, %rdi
        dec     %ecx
        jnz     .Lsum_i64_vrow
        add     $8, %rsi
        sub     $64, %r10
        ja      .Lsum_i64_vmain
.Lsum_i64_result:                                       /* [result] */
        JNE_SEXT %r8, %r9, .Lsum_i64_ovf
        mov     %r8, (%r11)
        xor     %eax, %eax                              /* PQK_OK */
        EPILOGUE SAVED
        ret
.Lsum_i64_ovf:
        mov     $PQK_OVERFLOW, %eax
        EPILOGUE SAVED
        ret
ENDF pqk_x86_scalar_sum_i64
#undef SAVED

/* ========================================================================
 * double pqk_x86_scalar_sum_f64(data, validity, n)
 * Args:     rdi = data, rsi = validity, rdx = n
 * Returns:  xmm0 = sum of the valid rows
 * Clobbers: rax, rcx, rdx, rsi, rdi, r10, xmm0, xmm1, flags
 *           (rbx saved and restored)
 * Algorithm: sequential addsd in row order into xmm0 (bit-identical to the
 *           reference). Invalid rows are replaced by +0.0 (bit pattern 0)
 *           branch-free; since the running sum starts at +0.0 it can never
 *           be -0.0, so s + 0.0 == s exactly.
 *           r10 = remaining rows, rbx = validity word.
 * Tail:     no validity: one loop over all rows. Validity: 64-row blocks,
 *           the last one loaded with lvp (VWORD_BLOCK).
 * ====================================================================== */
#define SAVED %rbx
FUNC pqk_x86_scalar_sum_f64
        PROLOGUE SAVED
        xorpd   %xmm0, %xmm0                            /* [check] */
        mov     %rdx, %r10
        test    %r10, %r10
        jz      .Lsum_f64_result
        test    %rsi, %rsi
        jnz     .Lsum_f64_vmain
.Lsum_f64_main:                         /* [main] + [tail]: all rows */
        addsd   (%rdi), %xmm0
        add     $8, %rdi
        dec     %r10
        jnz     .Lsum_f64_main
        jmp     .Lsum_f64_result
.Lsum_f64_vmain:                /* [main] validity blocks; [tail] last block */
        VWORD_BLOCK %r10, %r10d, %rbx
.Lsum_f64_vrow:
        mov     (%rdi), %rax
        VBIT_MASK %rbx, %rdx
        and     %rdx, %rax
        movq    %rax, %xmm1
        addsd   %xmm1, %xmm0
        add     $8, %rdi
        dec     %ecx
        jnz     .Lsum_f64_vrow
        add     $8, %rsi
        sub     $64, %r10
        ja      .Lsum_f64_vmain
.Lsum_f64_result:                                       /* [result] */
        EPILOGUE SAVED
        ret
ENDF pqk_x86_scalar_sum_f64
#undef SAVED

/* ========================================================================
 * size_t pqk_x86_scalar_minmax_i64(data, validity, n, out_min, out_max)
 * Args:     rdi = data, rsi = validity, rdx = n, rcx = out_min, r8 = out_max
 * Returns:  rax = number of valid rows; *out_min / *out_max written if > 0
 * Clobbers: rax, rcx, rdx, rsi, rdi, r9, r10, r11, flags
 *           (rbx, rbp, r12-r15 saved and restored)
 * Algorithm: cmov min/max in r12 (lo) / r13 (hi). Invalid rows: x is
 *           replaced by the neutral element (cmovnc on the CF of VBIT_CF)
 *           and the count is incremented with adc.
 *           r14 = count, r15 = out_min, rbp = out_max, r10 = remaining,
 *           rbx = validity word, r9 = INT64_MAX, r11 = INT64_MIN.
 * Tail:     no validity: one loop over all rows. Validity: 64-row blocks,
 *           the last one loaded with lvp (VWORD_BLOCK).
 * ====================================================================== */
#define SAVED %rbx, %rbp, %r12, %r13, %r14, %r15
FUNC pqk_x86_scalar_minmax_i64
        PROLOGUE SAVED
        mov     %rcx, %r15                              /* [check] */
        mov     %r8, %rbp
        movabs  $C_I64MAX, %r9
        movabs  $C_SIGN64, %r11
        mov     %r9, %r12
        mov     %r11, %r13
        xor     %r14d, %r14d
        mov     %rdx, %r10
        test    %r10, %r10
        jz      .Lminmax_i64_result
        test    %rsi, %rsi
        jnz     .Lminmax_i64_vmain
        mov     %r10, %r14
.Lminmax_i64_main:                      /* [main] + [tail]: all rows */
        mov     (%rdi), %rax
        cmp     %rax, %r12
        cmovg   %rax, %r12
        cmp     %rax, %r13
        cmovl   %rax, %r13
        add     $8, %rdi
        dec     %r10
        jnz     .Lminmax_i64_main
        jmp     .Lminmax_i64_result
.Lminmax_i64_vmain:             /* [main] validity blocks; [tail] last block */
        VWORD_BLOCK %r10, %r10d, %rbx
.Lminmax_i64_vrow:
        mov     (%rdi), %rax
        mov     %rax, %rdx
        VBIT_CF %rbx                    /* CF = valid */
        cmovnc  %r9, %rax               /* invalid -> INT64_MAX for min */
        cmovnc  %r11, %rdx              /* invalid -> INT64_MIN for max */
        adc     $0, %r14
        cmp     %rax, %r12
        cmovg   %rax, %r12
        cmp     %rdx, %r13
        cmovl   %rdx, %r13
        add     $8, %rdi
        dec     %ecx
        jnz     .Lminmax_i64_vrow
        add     $8, %rsi
        sub     $64, %r10
        ja      .Lminmax_i64_vmain
.Lminmax_i64_result:                                    /* [result] */
        mov     %r14, %rax
        test    %rax, %rax
        jz      .Lminmax_i64_ret
        mov     %r12, (%r15)
        mov     %r13, (%rbp)
.Lminmax_i64_ret:
        EPILOGUE SAVED
        ret
ENDF pqk_x86_scalar_minmax_i64
#undef SAVED

/* ========================================================================
 * size_t pqk_x86_scalar_minmax_f64(data, validity, n, out_min, out_max)
 * Args:     rdi = data, rsi = validity, rdx = n, rcx = out_min, r8 = out_max
 * Returns:  rax = number of valid rows; *out_min / *out_max written if > 0
 * Clobbers: rax, rdx, rsi, rdi, r9, r10, r11, xmm0-xmm3, flags
 *           (rbx, r14 saved and restored; rcx is preserved)
 * Algorithm: xmm0 = lo (init +inf), xmm1 = hi (init -inf). The update rule
 *           matches the reference exactly: lo = (x < lo) ? x : lo via
 *           "minsd lo, x" (MINSD returns the second operand when not
 *           strictly less), likewise for max. Invalid rows are replaced by
 *           +inf / -inf, which never replace anything (inputs are finite).
 *           r9 = +inf bits, r11 = -inf bits, r14 = count, r10 = remaining,
 *           rbx = validity word; rcx (out_min) is pushed around each block.
 * Tail:     no validity: one loop over all rows. Validity: 64-row blocks,
 *           the last one loaded with lvp (VWORD_BLOCK).
 * ====================================================================== */
#define SAVED %rbx, %r14
FUNC pqk_x86_scalar_minmax_f64
        PROLOGUE SAVED
        movabs  $C_F64_PINF, %r9                        /* [check] */
        movabs  $C_F64_NINF, %r11
        movq    %r9, %xmm0
        movq    %r11, %xmm1
        xor     %r14d, %r14d
        mov     %rdx, %r10
        test    %r10, %r10
        jz      .Lminmax_f64_result
        test    %rsi, %rsi
        jnz     .Lminmax_f64_vmain
        mov     %r10, %r14
.Lminmax_f64_main:                      /* [main] + [tail]: all rows */
        movsd   (%rdi), %xmm2
        movapd  %xmm2, %xmm3
        minsd   %xmm0, %xmm2            /* x < lo ? x : lo */
        maxsd   %xmm1, %xmm3            /* x > hi ? x : hi */
        movapd  %xmm2, %xmm0
        movapd  %xmm3, %xmm1
        add     $8, %rdi
        dec     %r10
        jnz     .Lminmax_f64_main
        jmp     .Lminmax_f64_result
.Lminmax_f64_vmain:             /* [main] validity blocks; [tail] last block */
        push    %rcx
        VWORD_BLOCK %r10, %r10d, %rbx
.Lminmax_f64_vrow:
        mov     (%rdi), %rax
        mov     %rax, %rdx
        VBIT_CF %rbx
        cmovnc  %r9, %rax
        cmovnc  %r11, %rdx
        adc     $0, %r14
        movq    %rax, %xmm2
        movq    %rdx, %xmm3
        minsd   %xmm0, %xmm2
        maxsd   %xmm1, %xmm3
        movapd  %xmm2, %xmm0
        movapd  %xmm3, %xmm1
        add     $8, %rdi
        dec     %ecx
        jnz     .Lminmax_f64_vrow
        pop     %rcx
        add     $8, %rsi
        sub     $64, %r10
        ja      .Lminmax_f64_vmain
.Lminmax_f64_result:                                    /* [result] */
        mov     %r14, %rax
        test    %rax, %rax
        jz      .Lminmax_f64_ret
        movsd   %xmm0, (%rcx)
        movsd   %xmm1, (%r8)
.Lminmax_f64_ret:
        EPILOGUE SAVED
        ret
ENDF pqk_x86_scalar_minmax_f64
#undef SAVED

/* ========================================================================
 * void pqk_x86_scalar_bitmap_and(a, b, out, nbytes)
 * void pqk_x86_scalar_bitmap_or(a, b, out, nbytes)
 * void pqk_x86_scalar_bitmap_andnot(a, b, out, nbytes)
 * Args:     rdi = a, rsi = b, rdx = out, rcx = nbytes
 * Returns:  -
 * Clobbers: rax, rcx, rdx, rsi, rdi, r8, r9, r10, r11, flags
 *           (rbx, rbp saved and restored)
 * Algorithm: BITOP: 32 bytes per iteration as 4 qwords; all loads of a step
 *           precede its stores at identical offsets, so out may alias a or b.
 * Tail:     8-byte steps, then single bytes (BYTE_BITOP).
 * ====================================================================== */
FUNC pqk_x86_scalar_bitmap_and
        BITOP   bitmap_and, and, 0
ENDF pqk_x86_scalar_bitmap_and

FUNC pqk_x86_scalar_bitmap_or
        BITOP   bitmap_or, or, 0
ENDF pqk_x86_scalar_bitmap_or

FUNC pqk_x86_scalar_bitmap_andnot
        BITOP   bitmap_andnot, and, 1
ENDF pqk_x86_scalar_bitmap_andnot

/* ========================================================================
 * size_t pqk_x86_scalar_bitmap_popcount(bits, nbits)
 * Args:     rdi = bits, rsi = nbits
 * Returns:  rax = number of set bits among the first nbits bits
 * Clobbers: rax, rcx, rdx, rsi, rdi, r8, r9, r10, r11, flags
 * Algorithm: whole 64-bit words with the SWAR popcnt64 helper.
 *           r8 = total, r9 = words left, r10 = remaining bits.
 * Tail:     the remaining 0..63 bits: lvp loads exactly ceil(rem/8) bytes,
 *           masked to rem bits (LOWMASK), one more popcnt64.
 * ====================================================================== */
FUNC pqk_x86_scalar_bitmap_popcount
        xor     %r8d, %r8d                              /* [check] */
        mov     %rsi, %r9
        shr     $6, %r9
        mov     %rsi, %r10
        and     $63, %r10
        test    %r9, %r9
        jz      .Lbitmap_popcount_tail
.Lbitmap_popcount_main:                                 /* [main] words */
        mov     (%rdi), %rax
        call    popcnt64
        add     %rax, %r8
        add     $8, %rdi
        dec     %r9
        jnz     .Lbitmap_popcount_main
.Lbitmap_popcount_tail:                                 /* [tail] bits */
        test    %r10, %r10
        jz      .Lbitmap_popcount_result
        mov     %rdi, %rsi
        mov     %r10d, %ecx
        call    lvp
        LOWMASK %r10d
        and     %rdx, %rax
        call    popcnt64
        add     %rax, %r8
.Lbitmap_popcount_result:                               /* [result] */
        mov     %r8, %rax
        ret
ENDF pqk_x86_scalar_bitmap_popcount

/* ========================================================================
 * void pqk_x86_scalar_hash_i64(data, n, seed, out)
 * Args:     rdi = data, rsi = n, rdx = seed, rcx = out
 * Returns:  -
 * Clobbers: rax, rcx, rdx, rsi, rdi, r8, r9, r10, r11, flags
 *           (rbx saved and restored)
 * Algorithm: out[i] = fmix64(data[i] ^ seed) (FMIX64), 2 rows interleaved
 *           for ILP. r8 = C1, r9 = C2, r11 = seed, rax/r10 = k of row 0/1,
 *           rdx/rbx = temps.
 * Tail:     one single row if n is odd.
 * ====================================================================== */
#define SAVED %rbx
FUNC pqk_x86_scalar_hash_i64
        PROLOGUE SAVED
        FMIX_CONSTS %r8, %r9                            /* [check] */
        mov     %rdx, %r11              /* seed */
        cmp     $2, %rsi
        jb      .Lhash_i64_tail
.Lhash_i64_main:                                        /* [main] 2 rows */
        mov     (%rdi), %rax
        mov     8(%rdi), %r10
        xor     %r11, %rax
        xor     %r11, %r10
        FMIX64  %rax, %rdx, %r8, %r9
        FMIX64  %r10, %rbx, %r8, %r9
        mov     %rax, (%rcx)
        mov     %r10, 8(%rcx)
        add     $16, %rdi
        add     $16, %rcx
        sub     $2, %rsi
        cmp     $2, %rsi
        jae     .Lhash_i64_main
.Lhash_i64_tail:                                        /* [tail] 0..1 */
        test    %rsi, %rsi
        jz      .Lhash_i64_result
        mov     (%rdi), %rax
        xor     %r11, %rax
        FMIX64  %rax, %rdx, %r8, %r9
        mov     %rax, (%rcx)
.Lhash_i64_result:                                      /* [result] */
        EPILOGUE SAVED
        ret
ENDF pqk_x86_scalar_hash_i64
#undef SAVED

/* ========================================================================
 * void pqk_x86_scalar_compare_fixed(a, b, width, n, out)
 * Args:     rdi = a, rsi = b, rdx = width, rcx = n, r8 = out
 * Returns:  -
 * Clobbers: rax, rcx, rsi, rdi, r8, r9, r10, r11, flags
 * Algorithm: per record: 8-byte chunks; bswap turns the first differing
 *           byte into the most significant one, so an unsigned compare
 *           gives memcmp order; sbb/or turns CF into -1 / 1.
 *           r9 = offset inside the record, r10/r11 = loaded chunks.
 * Tail:     the record's last 0..7 bytes one at a time; never reads beyond
 *           the record.
 * ====================================================================== */
FUNC pqk_x86_scalar_compare_fixed
        test    %rcx, %rcx                              /* [check] */
        jz      .Lcompare_fixed_ret
.Lcompare_fixed_rec:                    /* [main] per record: qwords */
        xor     %r9d, %r9d
        lea     8(%r9), %rax
        cmp     %rdx, %rax
        ja      .Lcompare_fixed_tail
.Lcompare_fixed_q:
        mov     (%rdi,%r9), %r10
        mov     (%rsi,%r9), %r11
        cmp     %r11, %r10
        jne     .Lcompare_fixed_qdiff
        add     $8, %r9
        lea     8(%r9), %rax
        cmp     %rdx, %rax
        jbe     .Lcompare_fixed_q
.Lcompare_fixed_tail:                   /* [tail] the record's last bytes */
        cmp     %rdx, %r9
        jae     .Lcompare_fixed_eq
        movzbl  (%rdi,%r9), %r10d
        movzbl  (%rsi,%r9), %r11d
        cmp     %r11d, %r10d
        jne     .Lcompare_fixed_diff
        inc     %r9
        jmp     .Lcompare_fixed_tail
.Lcompare_fixed_qdiff:                  /* [result] per record */
        bswap   %r10
        bswap   %r11
        cmp     %r11, %r10
.Lcompare_fixed_diff:
        sbb     %eax, %eax              /* -1 if a < b (unsigned) else 0 */
        or      $1, %eax                /* -1 or 1 */
        jmp     .Lcompare_fixed_store
.Lcompare_fixed_eq:
        xor     %eax, %eax
.Lcompare_fixed_store:
        mov     %al, (%r8)
        inc     %r8
        add     %rdx, %rdi
        add     %rdx, %rsi
        dec     %rcx
        jnz     .Lcompare_fixed_rec
.Lcompare_fixed_ret:
        ret
ENDF pqk_x86_scalar_compare_fixed

/* ========================================================================
 * int pqk_x86_scalar_group_sum_i64(gid, values, validity, n, sums, counts,
 *                                  ngroups)
 * Args:     rdi = gid, rsi = values, rdx = validity, rcx = n, r8 = sums,
 *           r9 = counts (may be NULL), 8(%rsp) = ngroups
 * Returns:  eax = PQK_OK, PQK_OVERFLOW (some addition wrapped) or
 *           PQK_EINVAL (a valid row's group id >= ngroups; outputs
 *           untouched)
 * Clobbers: rax, rcx, rdx, r10, r11, flags
 *           (rbx, rbp, r12-r15 saved and restored)
 * Algorithm: pass 1 validates every valid row's group id: a straight loop
 *           without validity, else per row with the validity byte (reloaded
 *           every 8 rows). Pass 2 (GSUM_PASS2) adds in row order, so the
 *           overflow flag equals the reference's.
 *           r10 = row, r11 = ngroups, r12b = overflow flag, rbx = validity
 *           byte (pass 1); pass 2 registers: see GSUM_PASS2.
 * Tail:     no separate tail: pass 1 goes row by row; pass 2 handles the
 *           last partial 64-row validity block with lvp + LOWMASK.
 * ====================================================================== */
#define SAVED %rbx, %rbp, %r12, %r13, %r14, %r15
FUNC pqk_x86_scalar_group_sum_i64
        PROLOGUE SAVED
        mov     ARG7(6)(%rsp), %r11     /* ngroups */      /* [check] */
        xor     %r12d, %r12d
        xor     %r10d, %r10d
        test    %rcx, %rcx
        jz      .Lgroup_sum_i64_ok
        test    %rdx, %rdx
        jnz     .Lgroup_sum_i64_check_v
.Lgroup_sum_i64_check:                  /* [main] pass 1, no validity */
        mov     (%rdi,%r10,4), %eax
        cmp     %r11, %rax
        jae     .Lgroup_sum_i64_einval
        inc     %r10
        cmp     %rcx, %r10
        jb      .Lgroup_sum_i64_check
        jmp     .Lgroup_sum_i64_pass2
.Lgroup_sum_i64_check_v:                /* [main] pass 1 with validity */
        test    $7, %r10b
        jnz     .Lgroup_sum_i64_check_bit
        mov     %r10, %rax
        shr     $3, %rax
        movzbl  (%rdx,%rax), %ebx
.Lgroup_sum_i64_check_bit:
        VBIT_CF %ebx                    /* CF = valid */
        jnc     .Lgroup_sum_i64_check_next
        mov     (%rdi,%r10,4), %eax
        cmp     %r11, %rax
        jae     .Lgroup_sum_i64_einval
.Lgroup_sum_i64_check_next:
        inc     %r10
        cmp     %rcx, %r10
        jb      .Lgroup_sum_i64_check_v
.Lgroup_sum_i64_pass2:                  /* [main] pass 2 + [tail] */
        GSUM_PASS2
.Lgroup_sum_i64_ok:                                     /* [result] */
        movzbl  %r12b, %eax
        jmp     .Lgroup_sum_i64_ret
.Lgroup_sum_i64_einval:
        mov     $PQK_EINVAL, %eax
.Lgroup_sum_i64_ret:
        EPILOGUE SAVED
        ret
ENDF pqk_x86_scalar_group_sum_i64
#undef SAVED

/* ========================================================================
 * void pqk_x86_scalar_gather_i64(data, idx, m, out)
 * Args:     rdi = data, rsi = idx, rdx = m, rcx = out
 * Returns:  -
 * Clobbers: rax, rcx, rdx, rsi, r8, r9, r10, flags
 * Algorithm: GATHER_I64 4: out[j] = data[idx[j]] (idx zero-extended),
 *           4 independent loads per iteration.
 * Tail:     0..3 single rows.
 * ====================================================================== */
FUNC pqk_x86_scalar_gather_i64
        GATHER_I64 4                    /* [check] m < 4 -> [tail] */
        ret                             /* [result] */
ENDF pqk_x86_scalar_gather_i64

/* ========================================================================
 * 128-bit kernels (CR-4, ABI revision 1).
 * A pqk_i128 is 16 bytes {lo, hi} (little-endian int128); rows are 16 bytes
 * apart, so row i is at data + 16*i. All loads are plain unaligned GPR
 * loads.
 * ====================================================================== */

/* ========================================================================
 * size_t pqk_x86_scalar_filter_i128(data, validity, n, op, a, b, out_idx)
 * Args:     rdi = data, rsi = validity, rdx = n, ecx = op, r8 = &a, r9 = &b,
 *           8(%rsp) = out_idx
 * Returns:  rax = number of indices written; (size_t)-1 for an invalid op
 *           (then a and b are not dereferenced)
 * Clobbers: rax, rcx, rdx, rsi, rdi, r8, r9, r10, r11, flags
 *           (rbx, rbp, r12-r15 saved and restored)
 * Algorithm: P128_KERNEL: 64-row blocks; per row one 128-bit compare
 *           (cmp/sbb on sign-biased high words, xor/or/neg for (in)equality,
 *           the unsigned range trick for BETWEEN) whose CF is rotated into a
 *           64-bit block mask (rcr); mask &= validity word; indices emitted
 *           with bsf / x &= x-1 (EMIT_IDX_BITS).
 * Tail:     the last block (len < 64) row by row, then one shift aligns the
 *           mask; lvp loads exactly ceil(len/8) validity bytes.
 * ====================================================================== */
FUNC pqk_x86_scalar_filter_i128
        P128_KERNEL MODE_FILTER, filter_i128
ENDF pqk_x86_scalar_filter_i128

/* ========================================================================
 * size_t pqk_x86_scalar_count_i128(data, validity, n, op, a, b)
 * Args:     rdi = data, rsi = validity, rdx = n, ecx = op, r8 = &a, r9 = &b
 * Returns:  rax = number of valid rows satisfying op; (size_t)-1 if invalid
 * Clobbers: rax, rcx, rdx, rsi, rdi, r8, r9, r10, r11, flags
 *           (rbx, rbp, r12-r15 saved and restored)
 * Algorithm: P128_KERNEL: the block masks of filter_i128, each counted with
 *           an inline SWAR popcount (POPC).
 * Tail:     as filter_i128.
 * ====================================================================== */
FUNC pqk_x86_scalar_count_i128
        P128_KERNEL MODE_COUNT, count_i128
ENDF pqk_x86_scalar_count_i128

/* ========================================================================
 * int pqk_x86_scalar_sum_i128(data, validity, n, out_sum)
 * Args:     rdi = data, rsi = validity, rdx = n, rcx = out_sum
 * Returns:  eax = PQK_OK (sum stored) or PQK_OVERFLOW (*out_sum untouched)
 * Clobbers: rax, rcx, rdx, rsi, rdi, r8, r9, r10, r11, flags
 *           (rbx, r12, r13 saved and restored)
 * Algorithm: r10:r9:r8 = 192-bit two's-complement accumulator (top:hi:lo).
 *           Every row is sign-extended to 192 bits (hi, sar 63 of hi) and
 *           added with add/adc/adc, so the accumulator holds the exact sum
 *           (|sum| < 2^32 * 2^127 = 2^159 cannot wrap 192 bits); wrap-
 *           arounds of the low 128 bits that cancel out are invisible, as
 *           required. The sum fits int128 iff the top word is the sign
 *           extension of hi (JNE_SEXT). Invalid rows are zeroed branch-free
 *           (VBIT_MASK, and). n == 0 stores 0 and returns PQK_OK.
 *           r11 = out_sum, r12 = rows remaining, r13 = 4-row steps left in
 *           a full validity block, rbx = validity word.
 * Tail:     no validity: 4 rows per step, then single rows. Validity: full
 *           64-row blocks 4 rows per step; the final partial block
 *           (lvp: exactly ceil(len/8) bytes) row by row.
 * ====================================================================== */

/* SVADD128 off: add the row at off(%rdi) if its validity bit (next bit of
 * rbx) is set (VBIT_MASK; invalid rows add 0). clobbers rax, rcx, rdx. */
.macro SVADD128 off
        VBIT_MASK %rbx, %rdx            /* CF = validity bit */
        mov     \off(%rdi), %rax
        and     %rdx, %rax
        and     \off+8(%rdi), %rdx
        mov     %rdx, %rcx
        sar     $63, %rcx
        add     %rax, %r8
        adc     %rdx, %r9
        adc     %rcx, %r10
.endm
/* SADD128 off: add the row at off(%rdi). clobbers rax, rdx. */
.macro SADD128 off
        mov     \off+8(%rdi), %rax
        mov     %rax, %rdx
        sar     $63, %rdx
        add     \off(%rdi), %r8
        adc     %rax, %r9
        adc     %rdx, %r10
.endm

#define SAVED %rbx, %r12, %r13
FUNC pqk_x86_scalar_sum_i128
        PROLOGUE SAVED
        xor     %r8d, %r8d                              /* [check] */
        xor     %r9d, %r9d
        xor     %r10d, %r10d
        mov     %rcx, %r11
        mov     %rdx, %r12
        test    %r12, %r12
        jz      .Lsum_i128_result
        test    %rsi, %rsi
        jnz     .Lsum_i128_vmain
        cmp     $4, %r12
        jb      .Lsum_i128_tail
.Lsum_i128_main:                                        /* [main] 4 rows */
        SADD128 0
        SADD128 16
        SADD128 32
        SADD128 48
        add     $64, %rdi
        sub     $4, %r12
        cmp     $4, %r12
        jae     .Lsum_i128_main
        test    %r12, %r12
        jz      .Lsum_i128_result
.Lsum_i128_tail:                                        /* [tail] 1 row */
        SADD128 0
        add     $16, %rdi
        dec     %r12
        jnz     .Lsum_i128_tail
        jmp     .Lsum_i128_result
.Lsum_i128_vmain:                       /* [main] full validity blocks */
        cmp     $64, %r12
        jb      .Lsum_i128_vtail
        mov     (%rsi), %rbx
        mov     $16, %r13d
.Lsum_i128_vstep:
        SVADD128 0
        SVADD128 16
        SVADD128 32
        SVADD128 48
        add     $64, %rdi
        dec     %r13d
        jnz     .Lsum_i128_vstep
        add     $8, %rsi
        sub     $64, %r12
        jnz     .Lsum_i128_vmain
        jmp     .Lsum_i128_result
.Lsum_i128_vtail:                       /* [tail] last partial block */
        mov     %r12d, %ecx
        call    lvp                     /* exactly ceil(len/8) bytes */
        mov     %rax, %rbx
.Lsum_i128_vrow:
        SVADD128 0
        add     $16, %rdi
        dec     %r12d
        jnz     .Lsum_i128_vrow
.Lsum_i128_result:                                      /* [result] */
        JNE_SEXT %r9, %r10, .Lsum_i128_ovf
        mov     %r8, (%r11)
        mov     %r9, 8(%r11)
        xor     %eax, %eax                              /* PQK_OK */
        EPILOGUE SAVED
        ret
.Lsum_i128_ovf:
        mov     $PQK_OVERFLOW, %eax
        EPILOGUE SAVED
        ret
ENDF pqk_x86_scalar_sum_i128
#undef SAVED

/* ========================================================================
 * size_t pqk_x86_scalar_minmax_i128(data, validity, n, out_min, out_max)
 * Args:     rdi = data, rsi = validity, rdx = n, rcx = out_min, r8 = out_max
 * Returns:  rax = number of valid rows; *out_min / *out_max written if > 0
 * Clobbers: rax, rcx, rdx, rsi, rdi, r8, r9, r10, r11, flags
 *           (rbx, rbp, r12-r15 saved and restored; 16 bytes of stack hold
 *           out_min / out_max)
 * Algorithm: range test. min and max start at the first valid row f (found
 *           by a byte scan of the validity bitmap; f = 0 without validity).
 *           Then every row from the 64-row block containing f on is tested
 *           with ONE 128-bit compare: x is inside [min, max] iff
 *           (x - min) mod 2^128 <=u w = max - min. Inside (the common case
 *           once a few rows were seen) needs no update; outside, the
 *           out-of-line mm128_upd decides x < min or x > max (exactly one
 *           holds), updates it and recomputes w. Invalid rows get d = 0
 *           (and-masked), i.e. they are always "inside". Rows of f's block
 *           before f are invalid, so the count (sbb masks subtracted per
 *           row) is exact.
 *           r13:r12 = min (hi:lo), r15:r14 = max, r10:r9 = w, rbx = count,
 *           rbp = validity word, r11 = rows remaining, r8d = 4-row steps /
 *           rows left in the block (validity path).
 * Tail:     no validity: 4 rows per step, then single rows. Validity: full
 *           blocks 4 rows per step; the final partial block (lvp) row by
 *           row.
 * ====================================================================== */

/* mm128_upd (minmax_i128 only): rax = pointer to a row outside [min, max];
 * updates min or max and w (registers as above). clobbers rax, rcx, rdx. */
LFUNC mm128_upd
        mov     8(%rax), %rdx
        mov     (%rax), %rax
        cmp     %r12, %rax
        mov     %rdx, %rcx
        sbb     %r13, %rcx
        jl      .Lmm128_upd_min         /* x <s min */
        mov     %rax, %r14
        mov     %rdx, %r15
        jmp     .Lmm128_upd_w
.Lmm128_upd_min:
        mov     %rax, %r12
        mov     %rdx, %r13
.Lmm128_upd_w:
        mov     %r14, %r9
        mov     %r15, %r10
        sub     %r12, %r9
        sbb     %r13, %r10
        ret
ENDF mm128_upd

/* MM128_ROW off, valid: range-test the row at off(%rdi); valid = 1 consumes
 * one validity bit from rbp (count in rbx, invalid rows forced inside).
 * clobbers rax, rcx, rdx. */
.macro MM128_ROW off, valid
        mov     \off(%rdi), %rax
        mov     \off+8(%rdi), %rdx
        sub     %r12, %rax
        sbb     %r13, %rdx              /* d = x - min */
.if \valid
        VBIT_MASK %rbp, %rcx            /* CF = validity bit */
        sub     %rcx, %rbx
        and     %rcx, %rax
        and     %rcx, %rdx
.endif
        cmp     %rax, %r9
        mov     %r10, %rcx
        sbb     %rdx, %rcx              /* CF = w <u d: outside */
        jae     .Lmm_inside\@
        lea     \off(%rdi), %rax
        call    mm128_upd
.Lmm_inside\@:
.endm

#define SAVED %rbx, %rbp, %r12, %r13, %r14, %r15
FUNC pqk_x86_scalar_minmax_i128
        PROLOGUE SAVED
        push    %rcx                    /* 8(%rsp) = out_min */
        push    %r8                     /* (%rsp) = out_max */
        xor     %ebx, %ebx                              /* [check] */
        mov     %rdx, %r11
        test    %r11, %r11
        jz      .Lminmax_i128_result
        test    %rsi, %rsi
        jnz     .Lminmax_i128_scan
        mov     %r11, %rbx              /* no validity: f = 0, count = n */
        mov     (%rdi), %r12
        mov     8(%rdi), %r13
        mov     %r12, %r14
        mov     %r13, %r15
        xor     %r9d, %r9d
        xor     %r10d, %r10d
        cmp     $4, %r11
        jb      .Lminmax_i128_tail
.Lminmax_i128_main:                                     /* [main] 4 rows */
        MM128_ROW 0, 0
        MM128_ROW 16, 0
        MM128_ROW 32, 0
        MM128_ROW 48, 0
        add     $64, %rdi
        sub     $4, %r11
        cmp     $4, %r11
        jae     .Lminmax_i128_main
        test    %r11, %r11
        jz      .Lminmax_i128_result
.Lminmax_i128_tail:                                     /* [tail] 1 row */
        MM128_ROW 0, 0
        add     $16, %rdi
        dec     %r11
        jnz     .Lminmax_i128_tail
        jmp     .Lminmax_i128_result
.Lminmax_i128_scan:             /* first valid row f: first non-zero byte */
        lea     7(%r11), %rcx
        shr     $3, %rcx                /* ceil(n/8) bytes */
        xor     %edx, %edx
.Lminmax_i128_scan_byte:
        movzbl  (%rsi,%rdx), %eax
        test    %eax, %eax
        jnz     .Lminmax_i128_found
        inc     %rdx
        cmp     %rcx, %rdx
        jb      .Lminmax_i128_scan_byte
        jmp     .Lminmax_i128_result    /* no valid row */
.Lminmax_i128_found:
        bsf     %eax, %eax
        lea     (%rax,%rdx,8), %rax     /* f */
        cmp     %r11, %rax
        jae     .Lminmax_i128_result    /* set bit beyond n only */
        mov     %rax, %rcx
        shl     $4, %rcx
        mov     (%rdi,%rcx), %r12
        mov     8(%rdi,%rcx), %r13
        mov     %r12, %r14
        mov     %r13, %r15
        xor     %r9d, %r9d
        xor     %r10d, %r10d
        and     $-64, %rax              /* start of f's block */
        sub     %rax, %r11
        mov     %rax, %rcx
        shr     $3, %rcx
        add     %rcx, %rsi
        shl     $4, %rax
        add     %rax, %rdi
.Lminmax_i128_vmain:                    /* [main] full validity blocks */
        cmp     $64, %r11
        jb      .Lminmax_i128_vtail
        mov     (%rsi), %rbp
        mov     $16, %r8d
.Lminmax_i128_vstep:
        MM128_ROW 0, 1
        MM128_ROW 16, 1
        MM128_ROW 32, 1
        MM128_ROW 48, 1
        add     $64, %rdi
        dec     %r8d
        jnz     .Lminmax_i128_vstep
        add     $8, %rsi
        sub     $64, %r11
        jnz     .Lminmax_i128_vmain
        jmp     .Lminmax_i128_result
.Lminmax_i128_vtail:                    /* [tail] last partial block */
        mov     %r11d, %ecx
        call    lvp
        mov     %rax, %rbp
        mov     %r11d, %r8d
.Lminmax_i128_vrow:
        MM128_ROW 0, 1
        add     $16, %rdi
        dec     %r8d
        jnz     .Lminmax_i128_vrow
.Lminmax_i128_result:                                   /* [result] */
        mov     %rbx, %rax
        test    %rax, %rax
        jz      .Lminmax_i128_ret
        mov     8(%rsp), %rcx
        mov     (%rsp), %rdx
        mov     %r12, (%rcx)
        mov     %r13, 8(%rcx)
        mov     %r14, (%rdx)
        mov     %r15, 8(%rdx)
.Lminmax_i128_ret:
        add     $16, %rsp
        EPILOGUE SAVED
        ret
ENDF pqk_x86_scalar_minmax_i128
#undef SAVED

        .section .note.GNU-stack, "", @progbits
