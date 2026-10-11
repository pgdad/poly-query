/*
 * pqk_x86_simd.h — building blocks shared by the two SIMD variants
 * (included by pqk_x86_avx2.S and pqk_x86_avx512.S). Requires
 * pqk_x86_common.h. Emits nothing by itself.
 *
 *   HSUMQ, HSUMZ        horizontal qword sums (ymm / zmm)
 *   F64_ZERO_FIXUP      signed-zero fix-up of SIMD minmax_f64
 *   SMIN128, SMAX128    scalar signed 128-bit min/max update (minmax_i128)
 *   FOLD_LANES128       exact fold of (S, H) lane sums into a 192-bit total
 *   UNBIAS192           remove the 2^127 row bias from the 192-bit total
 *   SUM_CHUNK_ROWS, SUM128_CHUNK_ROWS   chunk sizes of the exact sums
 */
#ifndef PQK_X86_SIMD_H
#define PQK_X86_SIMD_H

/* Exact vector sums keep per-lane partial sums that are exact only for a
 * bounded number of rows; chunks of at most these many rows keep them
 * below 2^60. Overridable with -D to exercise the fold paths in tests
 * (verify/run.sh). SUM128_CHUNK_ROWS must be a multiple of 64. */
#ifndef SUM_CHUNK_ROWS
#define SUM_CHUNK_ROWS    (1 << 28)
#endif
#ifndef SUM128_CHUNK_ROWS
#define SUM128_CHUNK_ROWS (1 << 28)     /* multiple of 64 */
#endif

/* ------------------------------------------------------------------------
 * HSUMQ y, x, t, r      r = sum of the 4 qwords of ymm \y (xmm alias \x);
 *                       clobbers \y (low lanes), xmm \t.
 * HSUMZ z, y, x, ty, tx, r   r = sum of the 8 qwords of zmm \z (aliases
 *                       \y, \x); clobbers \z (low lanes), \ty, \tx.
 * ---------------------------------------------------------------------- */
.macro HSUMQ y, x, t, r
        vextracti128 $1, \y, \t
        vpaddq  \t, \x, \x
        vpshufd $0x4e, \x, \t
        vpaddq  \t, \x, \x
        vmovq   \x, \r
.endm
.macro HSUMZ z, y, x, ty, tx, r
        vextracti64x4 $1, \z, \ty
        vpaddq  \ty, \y, \y
        HSUMQ   \y, \x, \tx, \r
.endm

/* ------------------------------------------------------------------------
 * F64_ZERO_FIXUP flags, data, vptr, n
 * SIMD lanes merge in a different order than the sequential scan, so only
 * the sign of a zero result can differ from the reference (-0.0 == +0.0).
 * If the final min (xmm0) / max (xmm1) compares equal to 0.0 it is replaced
 * by the first valid zero of the column in row order, which is exactly what
 * the reference returns in that case. Falls through when done.
 * in: xmm0/xmm1 = min/max (count > 0), data, vptr (0 = all valid), n.
 * clobbers \flags (32-bit gpr: bit 0 min == 0, bit 1 max == 0), rax, rdx,
 * r10, xmm5.
 * ---------------------------------------------------------------------- */
.macro F64_ZERO_FIXUP flags, data, vptr, n
        vxorpd  %xmm5, %xmm5, %xmm5
        xor     \flags, \flags
        vucomisd %xmm5, %xmm0
        jne     .Lfz_max\@
        or      $1, \flags
.Lfz_max\@:
        vucomisd %xmm5, %xmm1
        jne     .Lfz_test\@
        or      $2, \flags
.Lfz_test\@:
        test    \flags, \flags
        jz      .Lfz_done\@
        xor     %r10d, %r10d            /* row index */
.Lfz_row\@:
        test    \vptr, \vptr
        jz      .Lfz_value\@
        VBIT_TEST \vptr, %r10, %r10d, %edx
        jnc     .Lfz_next\@
.Lfz_value\@:
        mov     (\data,%r10,8), %rax
        mov     %rax, %rdx
        add     %rdx, %rdx              /* drop the sign bit */
        jz      .Lfz_zero\@
.Lfz_next\@:
        inc     %r10
        cmp     \n, %r10
        jb      .Lfz_row\@
        jmp     .Lfz_done\@             /* unreachable: a zero exists */
.Lfz_zero\@:
        test    $1, \flags
        jz      .Lfz_nomin\@
        vmovq   %rax, %xmm0
.Lfz_nomin\@:
        test    $2, \flags
        jz      .Lfz_done\@
        vmovq   %rax, %xmm1
.Lfz_done\@:
.endm

/* ------------------------------------------------------------------------
 * Scalar signed 128-bit updates (minmax_i128 lane reduction and tail rows).
 * SMIN128   candidate rdx:rax; r13:r12 = min(r13:r12, candidate)
 * SMAX128   candidate rdx:rax; r15:r14 = max(r15:r14, candidate)
 * cmp/sbb computes the signed 128-bit compare into SF/OF; clobber rcx.
 * ---------------------------------------------------------------------- */
.macro SMIN128
        cmp     %r12, %rax
        mov     %rdx, %rcx
        sbb     %r13, %rcx              /* x <s min */
        cmovl   %rax, %r12
        cmovl   %rdx, %r13
.endm
.macro SMAX128
        cmp     %rax, %r14
        mov     %r15, %rcx
        sbb     %rdx, %rcx              /* max <s x */
        cmovl   %rax, %r14
        cmovl   %rdx, %r15
.endm

/* ------------------------------------------------------------------------
 * Exact 128-bit sums (sum_i128). Each 64-bit lane accumulates
 * S = sum(v) mod 2^64 and H = sum(v >>> 32) (exact); the exact lane sum is
 * E = H*2^32 + L with L = (S - H*2^32) mod 2^64, so E mod 2^64 = S and
 * E div 2^64 = (H >> 32) + carry(H<<32 + L).
 * FOLD_LANES128   xmm4 = [S_even, S_odd], xmm6 = [H_even, H_odd] (lanes
 *                 already reduced to one even and one odd lane): adds the
 *                 even lane at weight 1 and the odd lane at weight 2^64 to
 *                 the 192-bit total r10:r9:r8; zeroes xmm4-xmm7 (the
 *                 accumulators, VEX-encoded: whole ymm/zmm registers).
 *                 clobbers rax, rcx, rdx.
 * UNBIAS192       r10:r9:r8 -= rbx * 2^127 (rbx = number of rows whose
 *                 high word was biased by 2^63). clobbers rax.
 * ---------------------------------------------------------------------- */
.macro FOLD_LANES128
        vmovq   %xmm6, %rax
        vmovq   %xmm4, %rdx
        mov     %rax, %rcx
        shr     $32, %rcx
        shl     $32, %rax
        sub     %rax, %rdx              /* L */
        add     %rax, %rdx              /* = S, CF = carry of H<<32 + L */
        adc     $0, %rcx                /* E = rcx:rdx */
        add     %rdx, %r8
        adc     %rcx, %r9
        adc     $0, %r10
        vpextrq $1, %xmm6, %rax
        vpextrq $1, %xmm4, %rdx
        mov     %rax, %rcx
        shr     $32, %rcx
        shl     $32, %rax
        sub     %rax, %rdx
        add     %rax, %rdx
        adc     $0, %rcx
        add     %rdx, %r9               /* weight 2^64 */
        adc     %rcx, %r10
        vpxor   %xmm4, %xmm4, %xmm4
        vpxor   %xmm5, %xmm5, %xmm5
        vpxor   %xmm6, %xmm6, %xmm6
        vpxor   %xmm7, %xmm7, %xmm7
.endm
.macro UNBIAS192
        mov     %rbx, %rax              /* T -= cnt * 2^127 */
        shr     $1, %rax
        sub     %rax, %r10
        test    $1, %bl
        jz      .Lub_done\@
        movabs  $C_SIGN64, %rax
        sub     %rax, %r9
        sbb     $0, %r10
.Lub_done\@:
.endm

#endif /* PQK_X86_SIMD_H */
