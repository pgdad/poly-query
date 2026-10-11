/*
 * pqk_x86_avx2.S — PolyQuery native kernels, variant "x86_avx2".
 *
 * Requires AVX2 + BMI1 + BMI2 + POPCNT (checked by the dispatcher). All 20
 * kernels of pq_kernels.h (ABI revision 1) as global symbols
 * pqk_x86_avx2_<kernel>, System V AMD64 ABI; every public function that
 * touches ymm registers returns through vzeroupper (VRET).
 *
 * Design overview (details at each kernel):
 *  - Predicates (filter/bitmap/count/compare): blocks of 64 rows; a
 *    per-operator mask routine (vop_* / vcmp_*) turns one block into a
 *    64-bit mask (16 x vpcmpeqq/vpcmpgtq on 4 qwords + vmovmskpd); operators
 *    map to (kind, invert), see pqk_x86_avx2.h.
 *  - filter emits indices with an 8-row pdep/pext compress step for full
 *    blocks with a hit, tzcnt/blsr otherwise.
 *  - Validity in vector loops: the 64-bit validity word of a full block is
 *    broadcast and shifted per lane with vpsllvq (tables shc*) so that the
 *    row's bit lands in the lane's sign bit; vblendvpd consumes it directly,
 *    sums widen it to a lane mask (vpcmpgtq against zero) and AND it with a
 *    plain load. vpmaskmovq/vmaskmovpd are deliberately NOT used (up to 4x
 *    slower from DRAM on Zen 5; fault behaviour of masked-off elements is
 *    implementation dependent on AMD). Final partial blocks run scalar code.
 *  - sum_i64 / sum_i128 are exact (lane sums folded into a 128-/192-bit
 *    scalar total per chunk); hash_i64 emulates the 64x64 multiply with
 *    three vpmuludq.
 *
 * Layout of this file:
 *   1. constant tables and file-local helpers used by several kernels
 *   2. the kernels, in pq_kernels.h order; each starts with a header comment
 *      (arguments, result, clobbered registers, algorithm, tail strategy)
 *      and follows the [check] / [main] / [tail] / [result] skeleton
 *      described in pqk_x86_common.h.
 * Building blocks shared with other variants or kernels live in
 * pqk_x86_common.h (+ pqk_x86_consts.h), pqk_x86_simd.h and
 * pqk_x86_avx2.h (see README, "Shared building blocks").
 *
 * ABI notes: internal helpers have documented private register conventions
 * and use the stack only for call/ret; no red zone is used; kernels save and
 * restore every callee-saved register they use (PROLOGUE / EPILOGUE).
 */
#include "pqk_x86_common.h"             /* includes pqk_x86_consts.h */
#include "pqk_x86_simd.h"
#include "pqk_x86_avx2.h"

        .set PQK_BMI, 1                 /* tzcnt / blsr / bzhi available */
        .text

/* ========================================================================
 * 1. Constant tables (pqk_x86_consts.h) and file-local helpers
 *   lvp                    partial validity word (kernels with validity)
 *   vop_*, vop_table       i64 mask routines (filter/bitmap/count_i64)
 *   vcnt_*, vcnt_table     i64 direct counters (count_i64), vop_inv
 *   vop128_*, vcnt128_*    the same for filter_i128 / count_i128
 * ====================================================================== */
        TAB_SHC
        TAB_EIGHT_D
        TAB_SIGN_D
        TAB_FMIX_HALVES
        TAB_FMIX_SWAP
        TAB_PINF_NINF
        TAB_SHC128S
        TAB_SHC128M
        TAB_HIBIAS
        TAB_I64MIN
        TAB_VOP_INV
        TAB_NIB_LUT
        TAB_0F
        TAB_NIBMASK

        DEFINE_LVP

        VOP vop_eq, 0, 0
        VOP vop_ne, 0, 1
        VOP vop_lt, 1, 0
        VOP vop_le, 2, 1
        VOP vop_gt, 2, 0
        VOP vop_ge, 1, 1
        VOP vop_bt, 3, 1
        OPTABLE vop_table, vop

        VCNT vcnt_k0, 0
        VCNT vcnt_k1, 1
        VCNT vcnt_k2, 2
        VCNT vcnt_k3, 3
        /* operator -> kind (EQ NE LT LE GT GE BETWEEN), inversion: vop_inv */
        JUMPTABLE vcnt_table, vcnt_k0, vcnt_k0, vcnt_k1, vcnt_k2, vcnt_k2, vcnt_k1, vcnt_k3

        VOP128 vop128_eq, 0, 0
        VOP128 vop128_ne, 0, 1
        VOP128 vop128_lt, 1, 0
        VOP128 vop128_le, 2, 1
        VOP128 vop128_gt, 2, 0
        VOP128 vop128_ge, 1, 1
        VOP128 vop128_bt, 3, 1
        OPTABLE vop128_table, vop128

        VCNT128 vcnt128_k0, 0
        VCNT128 vcnt128_k1, 1
        VCNT128 vcnt128_k2, 2
        VCNT128 vcnt128_k3, 3
        JUMPTABLE vcnt128_table, vcnt128_k0, vcnt128_k0, vcnt128_k1, vcnt128_k2, vcnt128_k2, vcnt128_k1, vcnt128_k3

/* ========================================================================
 * size_t pqk_x86_avx2_filter_i64(data, validity, n, op, a, b, out_idx)
 * Args:     rdi = data, rsi = validity, rdx = n, ecx = op, r8 = a, r9 = b,
 *           8(%rsp) = out_idx
 * Returns:  rax = number of indices written; (size_t)-1 for an invalid op
 * Clobbers: rax, rcx, rdx, rsi, rdi, r10, r11, ymm0-ymm5, ymm8, ymm9, flags
 *           (rbx, rbp, r12-r15 saved and restored)
 * Algorithm: VDRIVER: 64-row blocks; vop_<op> builds the block mask, &
 *           validity word; full blocks with a hit emit indices with
 *           EMIT_IDX_COMPRESS8 (pdep/pext, 8 rows per 32-byte store), other
 *           blocks with tzcnt/blsr (EMIT_IDX_BITS).
 * Tail:     the last block (len < 64) runs through the same loop: vop_*
 *           compares whole vectors while >= 4 rows remain and the last 1..3
 *           rows in scalar code; lvp loads exactly ceil(len/8) bytes.
 * ====================================================================== */
FUNC pqk_x86_avx2_filter_i64
        VDRIVER MODE_FILTER, filter_i64
ENDF pqk_x86_avx2_filter_i64

/* ========================================================================
 * size_t pqk_x86_avx2_filter_i64_bitmap(data, validity, n, op, a, b,
 *                                       out_bits)
 * Args:     rdi = data, rsi = validity, rdx = n, ecx = op, r8 = a, r9 = b,
 *           8(%rsp) = out_bits
 * Returns:  rax = number of set bits; (size_t)-1 for an invalid op
 * Clobbers: rax, rcx, rdx, rsi, rdi, r10, r11, ymm0-ymm3, ymm8, ymm9, flags
 *           (rbx, rbp, r12-r15 saved and restored)
 * Algorithm: VDRIVER: as filter_i64; each block mask is popcnt-ed and
 *           stored with one 8-byte store.
 * Tail:     last block: ceil(len/8) single-byte stores (trailing bits are
 *           already 0, nothing past ceil(n/8) is written).
 * ====================================================================== */
FUNC pqk_x86_avx2_filter_i64_bitmap
        VDRIVER MODE_BITMAP, filter_i64_bitmap
ENDF pqk_x86_avx2_filter_i64_bitmap

/* ========================================================================
 * size_t pqk_x86_avx2_count_i64(data, validity, n, op, a, b)
 * Args:     rdi = data, rsi = validity, rdx = n, ecx = op, r8 = a, r9 = b
 * Returns:  rax = number of valid rows satisfying op; (size_t)-1 if invalid
 * Clobbers: rax, rcx, rdx, rsi, rdi, r10, r11, ymm0-ymm9, flags
 *           (rbx, rbp, r12-r15 saved and restored)
 * Algorithm: VDRIVER: without validity the direct counter vcnt_<kind>
 *           accumulates the compare results (vpsubq of all-ones lanes,
 *           4 accumulators) over n & ~15 rows; the operator's inversion is
 *           applied once (rows - count). Otherwise (and for the rest) the
 *           block masks of filter_i64 are popcnt-ed.
 * Tail:     the 0..15 rows after the direct counter, or the last block,
 *           through the mask routine (len < 64).
 * ====================================================================== */
FUNC pqk_x86_avx2_count_i64
        VDRIVER MODE_COUNT, count_i64
ENDF pqk_x86_avx2_count_i64

/* ========================================================================
 * size_t pqk_x86_avx2_compare_i64(a, b, n, op, out_bits)
 * Args:     rdi = a, rsi = b, rdx = n, ecx = op, r8 = out_bits
 * Returns:  rax = number of set bits; (size_t)-1 for an invalid op
 *           (BETWEEN is invalid here)
 * Clobbers: rax, rcx, rdx, rsi, rdi, r10, r11, ymm0, flags
 *           (rbx, rbp, r12-r15 saved and restored)
 * Algorithm: 64-row blocks: the element-wise routine vcmp_<op> builds the
 *           block mask (16 x vpcmpeqq/vpcmpgtq + vmovmskpd), which is
 *           popcnt-ed and stored (8 bytes).
 *           r12 = a block, r13 = b block, r14 = remaining, r15 = routine,
 *           rbx = popcount total, rbp = out ptr.
 * Tail:     last block: whole vectors while >= 4 rows remain, then scalar
 *           rows, bzhi to len; ceil(len/8) single-byte stores.
 * ====================================================================== */

/* Element-wise compare routines vcmp_* (compare_i64 only):
 * in rdi = &a[block], rsi = &b[block], edx = len (1..64).
 * out rax = mask with exactly len bits.
 * kind 0: P == Q, kind 1: P > Q; (P, Q) = (a, b) or swapped; inv negates.
 * clobbers rcx, rdx, rdi, rsi, r10, r11, ymm0. */
.macro VCMPQ kind, off, P, Q
        vmovdqu \off(\P), %ymm0
.if \kind == 0
        vpcmpeqq \off(\Q), %ymm0, %ymm0
.else
        vpcmpgtq \off(\Q), %ymm0, %ymm0
.endif
.endm

.macro VCMP name, kind, P, Q, inv
LFUNC \name
        cmp     $64, %edx
        jne     .L\name\()_part
        VCMPQ   \kind, 0, \P, \Q
        vmovmskpd %ymm0, %eax
        VCMPQ   \kind, 32, \P, \Q
        vmovmskpd %ymm0, %edx
        shl     $4, %edx
        .set g, 2
        .rept 14
        VCMPQ   \kind, g*32, \P, \Q
        vmovmskpd %ymm0, %ecx
        shl     $(4*g), %rcx
        .if g % 2
        or      %rcx, %rdx
        .else
        or      %rcx, %rax
        .endif
        .set g, g + 1
        .endr
        or      %rdx, %rax
.if \inv
        not     %rax
.endif
        ret
.L\name\()_part:
        xor     %eax, %eax
        xor     %ecx, %ecx
        cmp     $4, %edx
        jb      .L\name\()_rows
.L\name\()_grp:
        VCMPQ   \kind, 0, \P, \Q
        vmovmskpd %ymm0, %r10d
        shlx    %rcx, %r10, %r10
        or      %r10, %rax
        add     $32, %rdi
        add     $32, %rsi
        add     $4, %ecx
        sub     $4, %edx
        cmp     $4, %edx
        jae     .L\name\()_grp
.L\name\()_rows:
        test    %edx, %edx
        jz      .L\name\()_fin
.L\name\()_row:
        mov     (\P), %r10
        xor     %r11d, %r11d
        cmp     (\Q), %r10
.if \kind == 0
        sete    %r11b
.else
        setg    %r11b
.endif
        shlx    %rcx, %r11, %r11
        or      %r11, %rax
        add     $8, %rdi
        add     $8, %rsi
        inc     %ecx
        dec     %edx
        jnz     .L\name\()_row
.L\name\()_fin:
.if \inv
        not     %rax
.endif
        bzhi    %rcx, %rax, %rax
        ret
ENDF \name
.endm

        VCMP vcmp_eq, 0, %rdi, %rsi, 0
        VCMP vcmp_ne, 0, %rdi, %rsi, 1
        VCMP vcmp_lt, 1, %rsi, %rdi, 0  /* a < b  <=>  b > a     */
        VCMP vcmp_le, 1, %rdi, %rsi, 1  /* a <= b <=> !(a > b)   */
        VCMP vcmp_gt, 1, %rdi, %rsi, 0
        VCMP vcmp_ge, 1, %rsi, %rdi, 1  /* a >= b <=> !(b > a)   */
        CMPTABLE vcmp_table, vcmp

#define SAVED %rbx, %rbp, %r12, %r13, %r14, %r15
FUNC pqk_x86_avx2_compare_i64
        OP_CHECK PQK_CMP_OP_LAST, .Lcompare_i64_inval   /* [check] */
        PROLOGUE SAVED
        mov     %ecx, %ecx
        JTAB_LOAD vcmp_table, %r15
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
        popcnt  %rax, %rcx
        add     %rcx, %rbx
        cmp     $64, %r14
        jb      .Lcompare_i64_tail
        STORE_BITS_FULL
        add     $512, %r12
        add     $512, %r13
        sub     $64, %r14
        jnz     .Lcompare_i64_main
        jmp     .Lcompare_i64_result
.Lcompare_i64_tail:                                     /* [tail] */
        STORE_BITS_TAIL
.Lcompare_i64_result:                                   /* [result] */
        mov     %rbx, %rax
        EPILOGUE SAVED
        VRET
.Lcompare_i64_inval:
        OP_INVALID
ENDF pqk_x86_avx2_compare_i64
#undef SAVED

/* ========================================================================
 * int pqk_x86_avx2_sum_i64(data, validity, n, out_sum)
 * Args:     rdi = data, rsi = validity, rdx = n, rcx = out_sum
 * Returns:  eax = PQK_OK (sum stored) or PQK_OVERFLOW (*out_sum untouched)
 * Clobbers: rax, rcx, rdx, rsi, rdi, r8, r9, r10, r11, ymm0-ymm13, flags
 *           (rbx, rbp, r12, r13 saved and restored)
 * Algorithm: exact, with biased values: x' = x ^ 2^63 = x + 2^63 is an
 *           UNSIGNED 64-bit number, and per lane S = sum(x') mod 2^64 and
 *           U = sum(x' >>> 32) give the exact unsigned lane sum
 *           U*2^32 + LU with LU = S - U*2^32 (mod 2^64, exact while
 *           < 2^64). Chunks of at most SUM_CHUNK_ROWS (2^28) rows keep U
 *           and LU below 2^60; each chunk is folded (SFOLD) into the
 *           128-bit scalar total r9:r8, and the bias c * 2^63 (c = rows of
 *           the chunk that went through the vector path, rbp) is
 *           subtracted. 4 vector ops per 4 rows (xor, add, shift, add)
 *           instead of 5 with the former "count the negatives" form, and
 *           only one of them (the shift) on the two Zen 5 shift pipes.
 *           Four accumulator sets (S ymm0-ymm3, U ymm4-ymm7; vpaddq has
 *           2-cycle latency on Zen 5), ymm8 = bcast(2^63).
 *           Validity: invalid rows must contribute exactly 0, so
 *           x'' = (x ^ 2^63) & lane mask and c counts the valid rows
 *           (popcnt of the validity words). The lane mask of 4 rows comes
 *           from the 512-byte table nibmask (16 x 4 qwords), indexed by the
 *           row nibble of the validity word with rorx + and on the integer
 *           side (r13 = table base); this replaces vpsllvq + vpcmpgtq
 *           (two ops on the busy vector pipes) per 4 rows.
 *           Overflow iff hi is not the sign extension of lo (JNE_SEXT).
 *           r10 = rows remaining, r11 = out_sum, r12 = rows / blocks left
 *           in the chunk, rcx = validity word, temps ymm9-ymm13.
 * Tail:     no validity: 16-row iterations, then 4-row steps (set A),
 *           then the last 0..3 rows in scalar code (cqo/adc).
 *           Validity: the final partial block (lvp) row by row, scalar.
 * ====================================================================== */
#ifndef SUM_CHUNK_BLOCKS                /* = SUM_CHUNK_ROWS / 64 */
#define SUM_CHUNK_BLOCKS (1 << 22)
#endif

/* SACC x, set: accumulate the biased vector x into set 0..3 (S ymm<set>,
 * U ymm<set+4>); clobbers x. */
.macro SACC2 x, s, u
        vpaddq  \x, \s, \s
        vpsrlq  $32, \x, \x
        vpaddq  \x, \u, \u
.endm
.macro SACC x, set
.if (\set) == 0
        SACC2   \x, %ymm0, %ymm4
.elseif (\set) == 1
        SACC2   \x, %ymm1, %ymm5
.elseif (\set) == 2
        SACC2   \x, %ymm2, %ymm6
.else
        SACC2   \x, %ymm3, %ymm7
.endif
.endm

.macro SZERO
        vpxor   %xmm0, %xmm0, %xmm0
        vpxor   %xmm1, %xmm1, %xmm1
        vpxor   %xmm2, %xmm2, %xmm2
        vpxor   %xmm3, %xmm3, %xmm3
        vpxor   %xmm4, %xmm4, %xmm4
        vpxor   %xmm5, %xmm5, %xmm5
        vpxor   %xmm6, %xmm6, %xmm6
        vpxor   %xmm7, %xmm7, %xmm7
.endm

/* SFOLD: total(r9:r8) += U*2^32 + (S - U*2^32 mod 2^64) - c*2^63 with
 * c = rbp; rbp = 0. clobbers rax, rcx, rbx, ymm0-ymm7 (zeroed by the
 * caller's SZERO before reuse), xmm9. */
.macro SFOLD
        vpaddq  %ymm1, %ymm0, %ymm0
        vpaddq  %ymm3, %ymm2, %ymm2
        vpaddq  %ymm5, %ymm4, %ymm4
        vpaddq  %ymm7, %ymm6, %ymm6
        vpaddq  %ymm2, %ymm0, %ymm0
        vpaddq  %ymm6, %ymm4, %ymm4
        HSUMQ   %ymm0, %xmm0, %xmm9, %rax       /* S  */
        HSUMQ   %ymm4, %xmm4, %xmm9, %rcx       /* U  */
        mov     %rcx, %rbx
        shl     $32, %rbx
        sub     %rbx, %rax                      /* LU */
        shr     $32, %rcx                       /* U >> 32 (before the adds: shr clobbers CF) */
        add     %rax, %r8
        adc     $0, %r9
        add     %rbx, %r8
        adc     %rcx, %r9
        mov     %rbp, %rax                      /* - c * 2^63 */
        shl     $63, %rax
        shr     $1, %rbp
        sub     %rax, %r8
        sbb     %rbp, %r9
        xor     %ebp, %ebp
.endm

#define SAVED %rbx, %rbp, %r12, %r13
FUNC pqk_x86_avx2_sum_i64
        PROLOGUE SAVED
        xor     %r8d, %r8d                              /* [check] */
        xor     %r9d, %r9d
        xor     %ebp, %ebp
        mov     %rcx, %r11
        mov     %rdx, %r10
        vpbroadcastq c_i64min(%rip), %ymm8
        test    %rsi, %rsi
        jnz     .Lsum_i64_vmain
.Lsum_i64_chunk:                        /* [main] no validity, per chunk */
        cmp     $4, %r10
        jb      .Lsum_i64_tail
        mov     %r10, %r12
        mov     $SUM_CHUNK_ROWS, %eax
        cmp     %rax, %r12
        cmova   %rax, %r12
        and     $-4, %r12
        sub     %r12, %r10
        mov     %r12, %rbp                      /* c = rows of the chunk */
        SZERO
        cmp     $16, %r12
        jb      .Lsum_i64_quad
.Lsum_i64_main:                                         /* 16 rows */
        vpxor   (%rdi), %ymm8, %ymm9
        vpxor   32(%rdi), %ymm8, %ymm10
        vpxor   64(%rdi), %ymm8, %ymm11
        vpxor   96(%rdi), %ymm8, %ymm12
        SACC    %ymm9, 0
        SACC    %ymm10, 1
        SACC    %ymm11, 2
        SACC    %ymm12, 3
        sub     $-128, %rdi
        sub     $16, %r12
        cmp     $16, %r12
        jae     .Lsum_i64_main
.Lsum_i64_quad:                                         /* 4 rows */
        test    %r12, %r12
        jz      .Lsum_i64_fold
        vpxor   (%rdi), %ymm8, %ymm9
        SACC    %ymm9, 0
        add     $32, %rdi
        sub     $4, %r12
        jmp     .Lsum_i64_quad
.Lsum_i64_fold:
        SFOLD
        jmp     .Lsum_i64_chunk
.Lsum_i64_tail:                                         /* [tail] 0..3 */
        test    %r10, %r10
        jz      .Lsum_i64_result
.Lsum_i64_row:
        mov     (%rdi), %rax
        cqo
        add     %rax, %r8
        adc     %rdx, %r9
        add     $8, %rdi
        dec     %r10
        jnz     .Lsum_i64_row
        jmp     .Lsum_i64_result

.Lsum_i64_vmain:                        /* [main] validity, 64-row blocks */
        SZERO
        lea     nibmask(%rip), %r13
        xor     %r12d, %r12d
.Lsum_i64_vblk:
        cmp     $64, %r10
        jb      .Lsum_i64_vtail
        mov     (%rsi), %rcx
        popcnt  %rcx, %rax
        add     %rax, %rbp                      /* c += valid rows */
        .set g, 0
        .rept 16
        rorx    $((4*g - 5) & 63), %rcx, %rax   /* nibble g -> bits 5..8 */
        and     $0x1e0, %eax                    /* * 32: table entry */
        vpxor   g*32(%rdi), %ymm8, %ymm9
        vpand   (%r13,%rax), %ymm9, %ymm9       /* invalid rows -> 0 */
        SACC    %ymm9, (g % 4)
        .set g, g + 1
        .endr
        add     $512, %rdi
        add     $8, %rsi
        sub     $64, %r10
        inc     %r12
        cmp     $SUM_CHUNK_BLOCKS, %r12
        jb      .Lsum_i64_vblk
        SFOLD
        SZERO
        xor     %r12d, %r12d
        jmp     .Lsum_i64_vblk
.Lsum_i64_vtail:                        /* [tail] last partial block */
        SFOLD
        test    %r10, %r10
        jz      .Lsum_i64_result
        mov     %r10d, %ecx
        call    lvp
        mov     %rax, %rbx
.Lsum_i64_vrow:
        mov     (%rdi), %rax
        VBIT_MASK %rbx, %rdx
        and     %rdx, %rax
        cqo
        add     %rax, %r8
        adc     %rdx, %r9
        add     $8, %rdi
        dec     %r10
        jnz     .Lsum_i64_vrow
.Lsum_i64_result:                                       /* [result] */
        JNE_SEXT %r8, %r9, .Lsum_i64_ovf
        mov     %r8, (%r11)
        xor     %eax, %eax                              /* PQK_OK */
        jmp     .Lsum_i64_ret
.Lsum_i64_ovf:
        mov     $PQK_OVERFLOW, %eax
.Lsum_i64_ret:
        EPILOGUE SAVED
        VRET
ENDF pqk_x86_avx2_sum_i64
#undef SAVED

/* ========================================================================
 * double pqk_x86_avx2_sum_f64(data, validity, n)
 * Args:     rdi = data, rsi = validity, rdx = n
 * Returns:  xmm0 = sum of the valid rows (lane-wise partial sums; allowed
 *           reassociation, see pq_kernels.h)
 * Clobbers: rax, rcx, rdx, rsi, rdi, r10, r11, ymm0-ymm6, ymm12, ymm13,
 *           ymm15, flags
 * Algorithm: 16 lane-wise partial sums in ymm0-ymm3 (+0.0 init), scalar
 *           tail sum in xmm4. Invalid rows are ANDed to +0.0 bits (full
 *           vpcmpgtq lane mask from the vpsllvq sign mask in full blocks).
 *           Final: ((ymm0+ymm1)+(ymm2+ymm3)) lanes, then + xmm4.
 *           r10 = rows remaining, ymm12/13 validity, ymm15 zero, ymm6 temp.
 * Tail:     no validity: 4-row vectors, then 0..3 scalar rows. Validity:
 *           the final partial block (lvp) in scalar code (VBIT_MASK).
 * ====================================================================== */
FUNC pqk_x86_avx2_sum_f64
        vxorpd  %xmm0, %xmm0, %xmm0                     /* [check] */
        vxorpd  %xmm1, %xmm1, %xmm1
        vxorpd  %xmm2, %xmm2, %xmm2
        vxorpd  %xmm3, %xmm3, %xmm3
        vxorpd  %xmm4, %xmm4, %xmm4
        mov     %rdx, %r10
        test    %rsi, %rsi
        jnz     .Lsum_f64_vmain
        cmp     $16, %r10
        jb      .Lsum_f64_tail
.Lsum_f64_main:                                         /* [main] 16 rows */
        vaddpd  (%rdi), %ymm0, %ymm0
        vaddpd  32(%rdi), %ymm1, %ymm1
        vaddpd  64(%rdi), %ymm2, %ymm2
        vaddpd  96(%rdi), %ymm3, %ymm3
        sub     $-128, %rdi
        sub     $16, %r10
        cmp     $16, %r10
        jae     .Lsum_f64_main
.Lsum_f64_tail:                                         /* [tail] 4 rows */
        cmp     $4, %r10
        jb      .Lsum_f64_rows
        vaddpd  (%rdi), %ymm0, %ymm0
        add     $32, %rdi
        sub     $4, %r10
        jmp     .Lsum_f64_tail
.Lsum_f64_rows:                                         /* 0..3 rows */
        test    %r10, %r10
        jz      .Lsum_f64_result
        vaddsd  (%rdi), %xmm4, %xmm4
        add     $8, %rdi
        dec     %r10
        jmp     .Lsum_f64_rows
.Lsum_f64_vmain:                        /* [main] validity, 64-row blocks */
        vpxor   %xmm15, %xmm15, %xmm15
.Lsum_f64_vblk:
        cmp     $64, %r10
        jb      .Lsum_f64_vtail
        vpbroadcastq (%rsi), %ymm12
        .set g, 0
        .rept 16
        vpsllvq shc+g*32(%rip), %ymm12, %ymm13
        vpcmpgtq %ymm13, %ymm15, %ymm13         /* 0 > m: full lane mask */
        vandpd  g*32(%rdi), %ymm13, %ymm6       /* invalid -> +0.0 */
        .if g % 4 == 0
        vaddpd  %ymm6, %ymm0, %ymm0
        .elseif g % 4 == 1
        vaddpd  %ymm6, %ymm1, %ymm1
        .elseif g % 4 == 2
        vaddpd  %ymm6, %ymm2, %ymm2
        .else
        vaddpd  %ymm6, %ymm3, %ymm3
        .endif
        .set g, g + 1
        .endr
        add     $512, %rdi
        add     $8, %rsi
        sub     $64, %r10
        jmp     .Lsum_f64_vblk
.Lsum_f64_vtail:                        /* [tail] last partial block */
        test    %r10, %r10
        jz      .Lsum_f64_result
        mov     %r10d, %ecx
        call    lvp
.Lsum_f64_vrow:
        mov     (%rdi), %rdx
        VBIT_MASK %rax, %r11
        and     %r11, %rdx
        vmovq   %rdx, %xmm5
        vaddsd  %xmm5, %xmm4, %xmm4
        add     $8, %rdi
        dec     %r10
        jnz     .Lsum_f64_vrow
.Lsum_f64_result:                                       /* [result] */
        vaddpd  %ymm1, %ymm0, %ymm0
        vaddpd  %ymm3, %ymm2, %ymm2
        vaddpd  %ymm2, %ymm0, %ymm0
        vextractf128 $1, %ymm0, %xmm1
        vaddpd  %xmm1, %xmm0, %xmm0
        vunpckhpd %xmm0, %xmm0, %xmm1
        vaddsd  %xmm1, %xmm0, %xmm0
        vaddsd  %xmm4, %xmm0, %xmm0
        VRET
ENDF pqk_x86_avx2_sum_f64

/* ========================================================================
 * size_t pqk_x86_avx2_minmax_i64(data, validity, n, out_min, out_max)
 * Args:     rdi = data, rsi = validity, rdx = n, rcx = out_min, r8 = out_max
 * Returns:  rax = number of valid rows; *out_min / *out_max written if > 0
 * Clobbers: rax, rdx, rsi, rdi, r9, r10, r11, ymm0-ymm13,
 *           flags (rbx, r12-r14 saved and restored; rcx is preserved)
 * Algorithm: four accumulator sets, min ymm0/ymm2/ymm8/ymm10, max
 *           ymm1/ymm3/ymm9/ymm11 (no 64-bit min/max in AVX2: vpcmpgtq +
 *           vblendvpd, MMI_STEP). Four sets because one set's
 *           compare -> blend chain is 4 cycles on Zen 5 (2-cycle latency
 *           each); with the former two sets the loop was latency-bound
 *           (0.10 -> 0.075 ns/row, L2 and L3). No validity: 32 rows per
 *           iteration, then groups of 4 rows (set A). A tournament tree
 *           (3.5 instead of 4 compare/blend ops per 4 rows) and a lazy
 *           "any lane outside [min, max]?" test were measured: no faster
 *           in L3, so the data-independent form was kept.
 *           With validity the compare result is ANDed with the vpsllvq
 *           sign mask (blendv only looks
 *           at sign bits); the count is popcnt of the validity words.
 *           Scalar parts: r12 = lo, r13 = hi; r14 = count;
 *           r9/r11 = INT64_MAX/MIN; r10 = remaining; rbx = validity bits.
 * Tail:     no validity: 0..3 rows in scalar code. Validity: the final
 *           partial block (lvp) in scalar code (cmovnc on VBIT_CF).
 * ====================================================================== */

/* MMI_STEP x, mn, mx, mask: lane-wise min/max update with ymm x (mask =
 * sign mask of valid lanes, or none). clobbers ymm6, ymm7. */
.macro MMI_STEP x, mn, mx, mask
        vpcmpgtq \x, \mn, %ymm6                 /* min > x */
.ifnc \mask, none
        vpand   \mask, %ymm6, %ymm6
.endif
        vblendvpd %ymm6, \x, \mn, \mn
        vpcmpgtq \mx, \x, %ymm7                 /* x > max */
.ifnc \mask, none
        vpand   \mask, %ymm7, %ymm7
.endif
        vblendvpd %ymm7, \x, \mx, \mx
.endm

#define SAVED %rbx, %r12, %r13, %r14
FUNC pqk_x86_avx2_minmax_i64
        PROLOGUE SAVED
        movabs  $C_I64MAX, %r9                          /* [check] */
        movabs  $C_SIGN64, %r11
        mov     %r9, %r12
        mov     %r11, %r13
        vmovq   %r9, %xmm0
        vpbroadcastq %xmm0, %ymm0
        vmovdqa %ymm0, %ymm2
        vmovq   %r11, %xmm1
        vpbroadcastq %xmm1, %ymm1
        vmovdqa %ymm1, %ymm3
        vmovdqa %ymm0, %ymm8
        vmovdqa %ymm0, %ymm10
        vmovdqa %ymm1, %ymm9
        vmovdqa %ymm1, %ymm11
        xor     %r14d, %r14d
        mov     %rdx, %r10
        test    %rsi, %rsi
        jnz     .Lminmax_i64_vmain
        mov     %r10, %r14
        cmp     $32, %r10
        jb      .Lminmax_i64_quad
.Lminmax_i64_main:                                      /* [main] 32 rows */
        vmovdqu (%rdi), %ymm4
        vmovdqu 32(%rdi), %ymm5
        vmovdqu 64(%rdi), %ymm12
        vmovdqu 96(%rdi), %ymm13
        MMI_STEP %ymm4, %ymm0, %ymm1, none
        MMI_STEP %ymm5, %ymm2, %ymm3, none
        MMI_STEP %ymm12, %ymm8, %ymm9, none
        MMI_STEP %ymm13, %ymm10, %ymm11, none
        vmovdqu 128(%rdi), %ymm4
        vmovdqu 160(%rdi), %ymm5
        vmovdqu 192(%rdi), %ymm12
        vmovdqu 224(%rdi), %ymm13
        MMI_STEP %ymm4, %ymm0, %ymm1, none
        MMI_STEP %ymm5, %ymm2, %ymm3, none
        MMI_STEP %ymm12, %ymm8, %ymm9, none
        MMI_STEP %ymm13, %ymm10, %ymm11, none
        add     $256, %rdi
        sub     $32, %r10
        cmp     $32, %r10
        jae     .Lminmax_i64_main
.Lminmax_i64_quad:                                      /* 4 rows */
        cmp     $4, %r10
        jb      .Lminmax_i64_tail
        vmovdqu (%rdi), %ymm4
        MMI_STEP %ymm4, %ymm0, %ymm1, none
        add     $32, %rdi
        sub     $4, %r10
        jmp     .Lminmax_i64_quad
.Lminmax_i64_tail:                                      /* [tail] 0..3 */
        test    %r10, %r10
        jz      .Lminmax_i64_result
.Lminmax_i64_row:
        mov     (%rdi), %rax
        cmp     %rax, %r12
        cmovg   %rax, %r12
        cmp     %rax, %r13
        cmovl   %rax, %r13
        add     $8, %rdi
        dec     %r10
        jnz     .Lminmax_i64_row
        jmp     .Lminmax_i64_result
.Lminmax_i64_vmain:                     /* [main] validity, 64-row blocks */
        cmp     $64, %r10
        jb      .Lminmax_i64_vtail
        popcnt  (%rsi), %rax
        add     %rax, %r14
        vpbroadcastq (%rsi), %ymm12
        .set g, 0
        .rept 16
        vpsllvq shc+g*32(%rip), %ymm12, %ymm13
        vmovdqu g*32(%rdi), %ymm4
        .if g % 4 == 0
        MMI_STEP %ymm4, %ymm0, %ymm1, %ymm13
        .elseif g % 4 == 1
        MMI_STEP %ymm4, %ymm2, %ymm3, %ymm13
        .elseif g % 4 == 2
        MMI_STEP %ymm4, %ymm8, %ymm9, %ymm13
        .else
        MMI_STEP %ymm4, %ymm10, %ymm11, %ymm13
        .endif
        .set g, g + 1
        .endr
        add     $512, %rdi
        add     $8, %rsi
        sub     $64, %r10
        jmp     .Lminmax_i64_vmain
.Lminmax_i64_vtail:                     /* [tail] last partial block */
        test    %r10, %r10
        jz      .Lminmax_i64_result
        push    %rcx                    /* lvp clobbers rcx (out_min) */
        mov     %r10d, %ecx
        call    lvp
        pop     %rcx
        mov     %rax, %rbx
.Lminmax_i64_vrow:
        mov     (%rdi), %rax
        mov     %rax, %rdx
        VBIT_CF %rbx
        cmovnc  %r9, %rax
        cmovnc  %r11, %rdx
        adc     $0, %r14
        cmp     %rax, %r12
        cmovg   %rax, %r12
        cmp     %rdx, %r13
        cmovl   %rdx, %r13
        add     $8, %rdi
        dec     %r10
        jnz     .Lminmax_i64_vrow
.Lminmax_i64_result:                    /* [result] lanes -> r12 / r13 */
        vpcmpgtq %ymm10, %ymm8, %ymm6           /* sets C, D -> A, B */
        vblendvpd %ymm6, %ymm10, %ymm8, %ymm8
        vpcmpgtq %ymm9, %ymm11, %ymm7
        vblendvpd %ymm7, %ymm11, %ymm9, %ymm9
        vpcmpgtq %ymm8, %ymm0, %ymm6
        vblendvpd %ymm6, %ymm8, %ymm0, %ymm0
        vpcmpgtq %ymm1, %ymm9, %ymm7
        vblendvpd %ymm7, %ymm9, %ymm1, %ymm1
        vpcmpgtq %ymm2, %ymm0, %ymm6
        vblendvpd %ymm6, %ymm2, %ymm0, %ymm0
        vpcmpgtq %ymm1, %ymm3, %ymm7
        vblendvpd %ymm7, %ymm3, %ymm1, %ymm1
        vextracti128 $1, %ymm0, %xmm2
        vextracti128 $1, %ymm1, %xmm3
        .irp lane, %xmm0, %xmm2
        vmovq   \lane, %rax
        cmp     %rax, %r12
        cmovg   %rax, %r12
        vpextrq $1, \lane, %rax
        cmp     %rax, %r12
        cmovg   %rax, %r12
        .endr
        .irp lane, %xmm1, %xmm3
        vmovq   \lane, %rax
        cmp     %rax, %r13
        cmovl   %rax, %r13
        vpextrq $1, \lane, %rax
        cmp     %rax, %r13
        cmovl   %rax, %r13
        .endr
        mov     %r14, %rax
        test    %rax, %rax
        jz      .Lminmax_i64_ret
        mov     %r12, (%rcx)
        mov     %r13, (%r8)
.Lminmax_i64_ret:
        EPILOGUE SAVED
        VRET
ENDF pqk_x86_avx2_minmax_i64
#undef SAVED

/* ========================================================================
 * size_t pqk_x86_avx2_minmax_f64(data, validity, n, out_min, out_max)
 * Args:     rdi = data, rsi = validity, rdx = n, rcx = out_min, r8 = out_max
 * Returns:  rax = number of valid rows; *out_min / *out_max written if > 0
 * Clobbers: rax, rdx, rsi, rdi, r9, r10, ymm0-ymm7, ymm10-ymm15, flags
 *           (rbx, r12-r15 saved and restored; rcx is preserved)
 * Algorithm: min accs ymm0/ymm2 (+inf), max accs ymm1/ymm3 (-inf); per lane
 *           vminpd(acc, x) keeps "x < acc ? x : acc" like the reference.
 *           Invalid lanes are replaced by +inf / -inf via vblendvpd on the
 *           vpsllvq sign mask. Scalar accumulators xmm10 (lo) / xmm11 (hi).
 *           Signed zero: F64_ZERO_FIXUP (first valid zero of the column if
 *           the result compares equal to 0.0).
 *           r14 = count, r10 = remaining, rbx = validity bits, r12 = saved
 *           data, r13 = saved validity, r15 = saved n, ymm14/15 = +inf/-inf.
 * Tail:     no validity: 0..7 rows in scalar code. Validity: the final
 *           partial block (lvp) in scalar code, skipping invalid rows.
 * ====================================================================== */
#define SAVED %rbx, %r12, %r13, %r14, %r15
FUNC pqk_x86_avx2_minmax_f64
        PROLOGUE SAVED
        mov     %rdi, %r12                              /* [check] */
        mov     %rsi, %r13
        mov     %rdx, %r15
        vbroadcastsd c_pinf(%rip), %ymm14
        vbroadcastsd c_ninf(%rip), %ymm15
        vmovapd %ymm14, %ymm0
        vmovapd %ymm14, %ymm2
        vmovapd %ymm15, %ymm1
        vmovapd %ymm15, %ymm3
        vmovapd %xmm14, %xmm10
        vmovapd %xmm15, %xmm11
        xor     %r14d, %r14d
        mov     %rdx, %r10
        test    %rsi, %rsi
        jnz     .Lminmax_f64_vmain
        mov     %r10, %r14
        cmp     $8, %r10
        jb      .Lminmax_f64_tail
.Lminmax_f64_main:                                      /* [main] 8 rows */
        vmovupd (%rdi), %ymm4
        vmovupd 32(%rdi), %ymm5
        vminpd  %ymm0, %ymm4, %ymm0
        vmaxpd  %ymm1, %ymm4, %ymm1
        vminpd  %ymm2, %ymm5, %ymm2
        vmaxpd  %ymm3, %ymm5, %ymm3
        add     $64, %rdi
        sub     $8, %r10
        cmp     $8, %r10
        jae     .Lminmax_f64_main
.Lminmax_f64_tail:                                      /* [tail] 0..7 */
        test    %r10, %r10
        jz      .Lminmax_f64_reduce
.Lminmax_f64_row:
        vmovsd  (%rdi), %xmm4
        vminsd  %xmm10, %xmm4, %xmm10
        vmaxsd  %xmm11, %xmm4, %xmm11
        add     $8, %rdi
        dec     %r10
        jnz     .Lminmax_f64_row
        jmp     .Lminmax_f64_reduce
.Lminmax_f64_vmain:                     /* [main] validity, 64-row blocks */
        cmp     $64, %r10
        jb      .Lminmax_f64_vtail
        popcnt  (%rsi), %rax
        add     %rax, %r14
        vpbroadcastq (%rsi), %ymm12
        .set g, 0
        .rept 16
        vpsllvq shc+g*32(%rip), %ymm12, %ymm13
        vmovupd g*32(%rdi), %ymm4
        vblendvpd %ymm13, %ymm4, %ymm14, %ymm6
        vblendvpd %ymm13, %ymm4, %ymm15, %ymm7
        .if g % 2
        vminpd  %ymm2, %ymm6, %ymm2
        vmaxpd  %ymm3, %ymm7, %ymm3
        .else
        vminpd  %ymm0, %ymm6, %ymm0
        vmaxpd  %ymm1, %ymm7, %ymm1
        .endif
        .set g, g + 1
        .endr
        add     $512, %rdi
        add     $8, %rsi
        sub     $64, %r10
        jmp     .Lminmax_f64_vmain
.Lminmax_f64_vtail:                     /* [tail] last partial block */
        test    %r10, %r10
        jz      .Lminmax_f64_reduce
        push    %rcx
        mov     %r10d, %ecx
        call    lvp
        pop     %rcx
        mov     %rax, %rbx
.Lminmax_f64_vrow:
        VBIT_CF %rbx
        jnc     .Lminmax_f64_vnext
        inc     %r14
        vmovsd  (%rdi), %xmm4
        vminsd  %xmm10, %xmm4, %xmm10
        vmaxsd  %xmm11, %xmm4, %xmm11
.Lminmax_f64_vnext:
        add     $8, %rdi
        dec     %r10
        jnz     .Lminmax_f64_vrow
.Lminmax_f64_reduce:                    /* [result] lanes, zero fix-up */
        vminpd  %ymm2, %ymm0, %ymm0
        vmaxpd  %ymm3, %ymm1, %ymm1
        vextractf128 $1, %ymm0, %xmm2
        vextractf128 $1, %ymm1, %xmm3
        vminpd  %xmm2, %xmm0, %xmm0
        vmaxpd  %xmm3, %xmm1, %xmm1
        vunpckhpd %xmm0, %xmm0, %xmm2
        vunpckhpd %xmm1, %xmm1, %xmm3
        vminsd  %xmm2, %xmm0, %xmm0
        vmaxsd  %xmm3, %xmm1, %xmm1
        vminsd  %xmm10, %xmm0, %xmm0
        vmaxsd  %xmm11, %xmm1, %xmm1
        test    %r14, %r14
        jz      .Lminmax_f64_ret
        F64_ZERO_FIXUP %r9d, %r12, %r13, %r15
        vmovsd  %xmm0, (%rcx)
        vmovsd  %xmm1, (%r8)
.Lminmax_f64_ret:
        mov     %r14, %rax
        EPILOGUE SAVED
        VRET
ENDF pqk_x86_avx2_minmax_f64
#undef SAVED

/* ========================================================================
 * void pqk_x86_avx2_bitmap_and(a, b, out, nbytes)
 * void pqk_x86_avx2_bitmap_or(a, b, out, nbytes)
 * void pqk_x86_avx2_bitmap_andnot(a, b, out, nbytes)
 * Args:     rdi = a, rsi = b, rdx = out, rcx = nbytes
 * Returns:  -
 * Clobbers: rax, rcx, rdx, rsi, rdi, r8, ymm0-ymm3, flags
 * Algorithm: VBITOP: 128 bytes per iteration (4 ymm; all loads before the
 *           stores, at identical offsets, so out may alias a or b).
 * Tail:     32-byte, 8-byte (andn for andnot) and single-byte steps.
 * ====================================================================== */
FUNC pqk_x86_avx2_bitmap_and
        VBITOP  bitmap_and, vpand, and, 0
ENDF pqk_x86_avx2_bitmap_and

FUNC pqk_x86_avx2_bitmap_or
        VBITOP  bitmap_or, vpor, or, 0
ENDF pqk_x86_avx2_bitmap_or

FUNC pqk_x86_avx2_bitmap_andnot
        VBITOP  bitmap_andnot, vpandn, and, 1
ENDF pqk_x86_avx2_bitmap_andnot

/* ========================================================================
 * size_t pqk_x86_avx2_bitmap_popcount(bits, nbits)
 * Args:     rdi = bits, rsi = nbits
 * Returns:  rax = number of set bits among the first nbits bits
 * Clobbers: rax, rcx, rdx, rsi, rdi, r8, r9, r10, r11, ymm0-ymm15, flags
 * Algorithm: 640 bytes per iteration, split between the vector and the
 *           integer units, which run in parallel:
 *           - 512 bytes (16 ymm) through a Harley-Seal carry-save adder
 *             tree (CSA): the running "ones/twos/fours/eights" vectors
 *             (ymm4-ymm7) absorb 16 inputs, and only the resulting
 *             "sixteens" vector is popcounted (nibble LUT: vpshufb +
 *             vpsadbw, PCNTV) into ymm0. The CSA is ordered so that each
 *             running vector sees only one dependent op per step (Zen 5
 *             vector integer ops have 2-cycle latency).
 *           - 128 bytes with scalar POPCNT into r8-r11.
 *           After the loop: total = 16*ymm0 + 8*pc(eights) + 4*pc(fours)
 *           + 2*pc(twos) + pc(ones). (POPCNT on words alone: 0.0018 ns/bit
 *           in L2; vpshufb alone 0.0014; this hybrid 0.0010.)
 *           ymm15 = nibble LUT, ymm14 = bcast(0x0f), ymm13 = 0, temps
 *           ymm1-ymm3, ymm8-ymm12. rcx = word counter.
 * Tail:     the last < 80 words with POPCNT one at a time; the last 0..63
 *           bits via lvp (exactly ceil(rem/8) bytes) + bzhi.
 * ====================================================================== */

/* CSA h, l, b, c: carry-save add of b and c into the running vector l:
 * l = l ^ b ^ c, h = majority(l, b, c); b ^ c first, so l is on a chain of
 * one op. clobbers ymm11, ymm12. */
.macro CSA h, l, b, c
        vpxor   \b, \c, %ymm12
        vpand   \b, \c, \h
        vpand   \l, %ymm12, %ymm11
        vpxor   \l, %ymm12, \l
        vpor    %ymm11, \h, \h
.endm
/* PCNTV v, acc: acc (4 qwords) += popcount of the bytes of v.
 * clobbers ymm11, ymm12. */
.macro PCNTV v, acc
        vpsrlw  $4, \v, %ymm11
        vpand   %ymm14, \v, %ymm12
        vpand   %ymm14, %ymm11, %ymm11
        vpshufb %ymm12, %ymm15, %ymm12
        vpshufb %ymm11, %ymm15, %ymm11
        vpaddb  %ymm11, %ymm12, %ymm12
        vpsadbw %ymm13, %ymm12, %ymm12
        vpaddq  %ymm12, \acc, \acc
.endm
/* HS8 base, eights: 8 inputs (base..base+7, in ymm) -> ones (ymm4), twos
 * (ymm5) updated, fours (ymm6) updated, carry into \eights. Each input
 * load is paired with one scalar POPCNT of the integer part
 * (POPQ k: word k of the 128 scalar bytes at 512(%rdi)).
 * clobbers ymm1, ymm2, ymm8-ymm12, rax. */
.macro POPQ k
        popcnt  512+8*(\k)(%rdi), %rax
        .if (\k) % 4 == 0
        add     %rax, %r8
        .elseif (\k) % 4 == 1
        add     %rax, %r9
        .elseif (\k) % 4 == 2
        add     %rax, %r10
        .else
        add     %rax, %r11
        .endif
.endm
.macro HS8 base, eights
        vmovdqu 32*(\base)(%rdi), %ymm1
        POPQ    \base
        vmovdqu 32*(\base)+32(%rdi), %ymm2
        POPQ    \base+1
        CSA     %ymm8, %ymm4, %ymm1, %ymm2      /* twos A */
        vmovdqu 32*(\base)+64(%rdi), %ymm1
        POPQ    \base+2
        vmovdqu 32*(\base)+96(%rdi), %ymm2
        POPQ    \base+3
        CSA     %ymm9, %ymm4, %ymm1, %ymm2      /* twos B */
        CSA     %ymm10, %ymm5, %ymm8, %ymm9     /* fours A */
        vmovdqu 32*(\base)+128(%rdi), %ymm1
        POPQ    \base+4
        vmovdqu 32*(\base)+160(%rdi), %ymm2
        POPQ    \base+5
        CSA     %ymm8, %ymm4, %ymm1, %ymm2
        vmovdqu 32*(\base)+192(%rdi), %ymm1
        POPQ    \base+6
        vmovdqu 32*(\base)+224(%rdi), %ymm2
        POPQ    \base+7
        CSA     %ymm9, %ymm4, %ymm1, %ymm2
        CSA     %ymm1, %ymm5, %ymm8, %ymm9      /* fours B */
        CSA     \eights, %ymm6, %ymm10, %ymm1
.endm

FUNC pqk_x86_avx2_bitmap_popcount
        xor     %r8d, %r8d                              /* [check] */
        xor     %r9d, %r9d
        xor     %r10d, %r10d
        xor     %r11d, %r11d
        mov     %rsi, %rcx
        shr     $6, %rcx
        cmp     $80, %rcx
        jb      .Lbitmap_popcount_tail
        vbroadcasti128 nib_lut(%rip), %ymm15
        vpbroadcastb c_0f(%rip), %ymm14
        vpxor   %xmm13, %xmm13, %xmm13
        vpxor   %xmm0, %xmm0, %xmm0
        vpxor   %xmm4, %xmm4, %xmm4
        vpxor   %xmm5, %xmm5, %xmm5
        vpxor   %xmm6, %xmm6, %xmm6
        vpxor   %xmm7, %xmm7, %xmm7
.Lbitmap_popcount_main:                                 /* [main] 640 bytes */
        HS8     0, %ymm3                        /* eights A */
        HS8     8, %ymm2                        /* eights B */
        CSA     %ymm1, %ymm7, %ymm3, %ymm2      /* sixteens */
        PCNTV   %ymm1, %ymm0
        add     $640, %rdi
        sub     $80, %rcx
        cmp     $80, %rcx
        jae     .Lbitmap_popcount_main
        vpsllq  $4, %ymm0, %ymm0                /* 16 * pc(sixteens) */
        vpxor   %xmm3, %xmm3, %xmm3
        PCNTV   %ymm7, %ymm3
        vpsllq  $3, %ymm3, %ymm3
        vpaddq  %ymm3, %ymm0, %ymm0             /* + 8 * pc(eights) */
        vpxor   %xmm3, %xmm3, %xmm3
        PCNTV   %ymm6, %ymm3
        vpsllq  $2, %ymm3, %ymm3
        vpaddq  %ymm3, %ymm0, %ymm0             /* + 4 * pc(fours) */
        vpxor   %xmm3, %xmm3, %xmm3
        PCNTV   %ymm5, %ymm3
        vpaddq  %ymm3, %ymm3, %ymm3
        vpaddq  %ymm3, %ymm0, %ymm0             /* + 2 * pc(twos) */
        PCNTV   %ymm4, %ymm0                    /* + pc(ones) */
        HSUMQ   %ymm0, %xmm0, %xmm1, %rax
        add     %rax, %r8
.Lbitmap_popcount_tail:                                 /* [tail] words */
        test    %rcx, %rcx
        jz      .Lbitmap_popcount_bits
        popcnt  (%rdi), %rax
        add     %rax, %r8
        add     $8, %rdi
        dec     %rcx
        jmp     .Lbitmap_popcount_tail
.Lbitmap_popcount_bits:                                 /* then bits */
        add     %r9, %r8
        add     %r11, %r10
        add     %r10, %r8
        and     $63, %esi
        jz      .Lbitmap_popcount_result
        mov     %esi, %r9d
        mov     %rdi, %rsi
        mov     %r9d, %ecx
        call    lvp
        bzhi    %r9, %rax, %rax
        popcnt  %rax, %rax
        add     %rax, %r8
.Lbitmap_popcount_result:                               /* [result] */
        mov     %r8, %rax
        VRET
ENDF pqk_x86_avx2_bitmap_popcount

/* ========================================================================
 * void pqk_x86_avx2_hash_i64(data, n, seed, out)
 * Args:     rdi = data, rsi = n, rdx = seed, rcx = out
 * Returns:  -
 * Clobbers: rax, rcx, rsi, rdi, r8, r9, r10, r11, ymm0-ymm15, flags
 *           (rbx, rbp saved and restored)
 * Algorithm: out[i] = fmix64(data[i] ^ seed), 24 rows per iteration split
 *           between the vector unit (16 rows: 4 ymm, ymm0-ymm3) and the
 *           integer unit (8 rows, scalar imul), which run in parallel.
 *           AVX2 has no 64-bit multiply; k * C (mod 2^64) is
 *           lo*clo + ((lo*chi + hi*clo) mod 2^32) << 32 (HMUL): one
 *           vpmulld against the dword-swapped constant (chi, clo) yields
 *           both cross products, vpsllq / vpand place them in the high
 *           dword, vpmuludq gives lo*clo (2 multiplies instead of 3, one
 *           shift instead of two). The four vectors are interleaved step
 *           by step (each fmix64 is a ~30-cycle dependency chain on Zen 5)
 *           and the scalar rows are spread between the steps.
 *           Measured (L1/L2, ns/row): former 3-vpmuludq form 0.34, vpmulld
 *           form 0.30, hybrid 0.21.
 *           ymm4-ymm11 temps, ymm12/13 = bcast(clo) of C1/C2, ymm14 =
 *           bcast(0xffffffff00000000), ymm15 = bcast(seed);
 *           r8/r9 = C1/C2, rbx = 33 (shrx count), rax/r10 and r11/rbp
 *           scalar row registers.
 * Tail:     4-row vector steps, then the last 0..3 rows in scalar code.
 * ====================================================================== */
/* HXSH k, t: k ^= k >> 33 (lanes). HMUL k, clo, csw, t1, t2: k *= C
 * (lanes, mod 2^64), clo = bcast(lo32(C)), csw = (hi32(C), lo32(C)) dword
 * pairs (memory), ymm14 = high-dword mask. */
.macro HXSH k, t
        vpsrlq  $33, \k, \t
        vpxor   \t, \k, \k
.endm
.macro HMUL k, clo, csw, t1, t2
        vpmulld \csw, \k, \t1                   /* (lo*chi, hi*clo) */
        vpsllq  $32, \t1, \t2                   /* lo*chi << 32 */
        vpmuludq \clo, \k, \k                   /* lo*clo */
        vpand   %ymm14, \t1, \t1                /* hi*clo << 32 */
        vpaddq  \t2, \k, \k
        vpaddq  \t1, \k, \k
.endm
/* The same step on the four vectors ymm0-ymm3 (temps ymm4-ymm11). */
.macro HXSH4
        HXSH    %ymm0, %ymm4
        HXSH    %ymm1, %ymm6
        HXSH    %ymm2, %ymm8
        HXSH    %ymm3, %ymm10
.endm
.macro HMUL4 clo, csw
        HMUL    %ymm0, \clo, \csw, %ymm4, %ymm5
        HMUL    %ymm1, \clo, \csw, %ymm6, %ymm7
        HMUL    %ymm2, \clo, \csw, %ymm8, %ymm9
        HMUL    %ymm3, \clo, \csw, %ymm10, %ymm11
.endm
/* HROW off, r, t: one scalar row, out[off] = fmix64(data[off] ^ seed). */
.macro HROW off, r, t
        mov     \off(%rdi), \r
        xor     %rdx, \r
        shrx    %rbx, \r, \t
        xor     \t, \r
        imul    %r8, \r
        shrx    %rbx, \r, \t
        xor     \t, \r
        imul    %r9, \r
        shrx    %rbx, \r, \t
        xor     \t, \r
        mov     \r, \off(%rcx)
.endm

#define SAVED %rbx, %rbp
FUNC pqk_x86_avx2_hash_i64
        PROLOGUE SAVED
        vpbroadcastq c_fmix1_lo(%rip), %ymm12           /* [check] */
        vpbroadcastq c_fmix2_lo(%rip), %ymm13
        vpbroadcastq c_hi32(%rip), %ymm14
        vmovq   %rdx, %xmm15
        vpbroadcastq %xmm15, %ymm15
        FMIX_CONSTS %r8, %r9
        mov     $33, %ebx
        cmp     $24, %rsi
        jb      .Lhash_i64_quad
.Lhash_i64_main:                                        /* [main] 24 rows */
        vpxor   (%rdi), %ymm15, %ymm0
        vpxor   32(%rdi), %ymm15, %ymm1
        vpxor   64(%rdi), %ymm15, %ymm2
        vpxor   96(%rdi), %ymm15, %ymm3
        HXSH4
        HROW    128, %rax, %r10
        HMUL4   %ymm12, c_fmix1_sw(%rip)
        HROW    136, %r11, %rbp
        HROW    144, %rax, %r10
        HXSH4
        HROW    152, %r11, %rbp
        HMUL4   %ymm13, c_fmix2_sw(%rip)
        HROW    160, %rax, %r10
        HROW    168, %r11, %rbp
        HXSH4
        HROW    176, %rax, %r10
        HROW    184, %r11, %rbp
        vmovdqu %ymm0, (%rcx)
        vmovdqu %ymm1, 32(%rcx)
        vmovdqu %ymm2, 64(%rcx)
        vmovdqu %ymm3, 96(%rcx)
        add     $192, %rdi
        add     $192, %rcx
        sub     $24, %rsi
        cmp     $24, %rsi
        jae     .Lhash_i64_main
.Lhash_i64_quad:                                        /* [tail] 4 rows */
        cmp     $4, %rsi
        jb      .Lhash_i64_rows
        vpxor   (%rdi), %ymm15, %ymm0
        HXSH    %ymm0, %ymm4
        HMUL    %ymm0, %ymm12, c_fmix1_sw(%rip), %ymm4, %ymm5
        HXSH    %ymm0, %ymm4
        HMUL    %ymm0, %ymm13, c_fmix2_sw(%rip), %ymm4, %ymm5
        HXSH    %ymm0, %ymm4
        vmovdqu %ymm0, (%rcx)
        add     $32, %rdi
        add     $32, %rcx
        sub     $4, %rsi
        jmp     .Lhash_i64_quad
.Lhash_i64_rows:                                        /* 0..3 rows */
        test    %rsi, %rsi
        jz      .Lhash_i64_result
.Lhash_i64_row:
        HROW    0, %rax, %r10
        add     $8, %rdi
        add     $8, %rcx
        dec     %rsi
        jnz     .Lhash_i64_row
.Lhash_i64_result:                                      /* [result] */
        EPILOGUE SAVED
        VRET
ENDF pqk_x86_avx2_hash_i64
#undef SAVED

/* ========================================================================
 * void pqk_x86_avx2_compare_fixed(a, b, width, n, out)
 * Args:     rdi = a, rsi = b, rdx = width, rcx = n, r8 = out
 * Returns:  -
 * Clobbers: rax, rcx, rsi, rdi, r8, r9, r10, r11, ymm0, flags
 *           (rbx, r12-r14 saved and restored)
 * Algorithm: records of width <= 32 (common case) use a dedicated one-chunk
 *           loop with the record byte mask precomputed. Otherwise, per
 *           record, 32-byte chunks: vpcmpeqb + vpmovmskb -> "differs" mask
 *           (the record's last chunk limited to the record with bzhi).
 *           Branch-free per record: every chunk is scanned (fixed trip count
 *           per width, so the loop is predictable) and
 *           pos = min(offset + tzcnt(mask)) is tracked with cmovc (tzcnt
 *           sets CF for an empty mask) / cmova. If nothing differs pos
 *           becomes 0, whose bytes are equal, so the same byte compare
 *           (seta/sbb -> -1/0/1) yields 0.
 *           r9 = bytes from the current record start to the buffer end,
 *           r10 = offset in record, r11 = bytes left in record, r13 = first
 *           differing offset (-1 = none yet), r14 = -1, rbx/r12 = byte or
 *           qword operands.
 * Tail:     a 32-byte load is issued only if >= 32 bytes remain before the
 *           END OF THE WHOLE BUFFER (r9 - offset): loads may run into the
 *           next record but never past a + width*n. Otherwise (last few
 *           records) the rest of the record is compared with 8-byte bswap
 *           compares and single bytes. width 0: all records equal.
 * ====================================================================== */
#define SAVED %rbx, %r12, %r13, %r14
FUNC pqk_x86_avx2_compare_fixed
        test    %rcx, %rcx                              /* [check] */
        jz      .Lcompare_fixed_ret
        test    %rdx, %rdx
        jz      .Lcompare_fixed_zero
        PROLOGUE SAVED
        mov     $-1, %r14
        mov     %rdx, %r9
        imul    %rcx, %r9
        cmp     $32, %rdx
        ja      .Lcompare_fixed_rec
        /* width <= 32: one chunk per record, r13d = record byte mask */
        mov     $-1, %r13d
        bzhi    %edx, %r13d, %r13d
.Lcompare_fixed_fast:                   /* [main] one chunk per record */
        cmp     $32, %r9
        jb      .Lcompare_fixed_rec             /* last records: general path */
        vmovdqu (%rdi), %ymm0
        vpcmpeqb (%rsi), %ymm0, %ymm0
        vpmovmskb %ymm0, %eax
        andn    %r13d, %eax, %eax               /* differs & in record */
        tzcnt   %eax, %eax
        and     $31, %eax                       /* none -> byte 0 (equal) */
        movzbl  (%rdi,%rax), %ebx
        movzbl  (%rsi,%rax), %r12d
        cmp     %r12d, %ebx
        seta    %al
        sbb     $0, %al
        mov     %al, (%r8)
        inc     %r8
        add     %rdx, %rdi
        add     %rdx, %rsi
        sub     %rdx, %r9
        dec     %rcx
        jnz     .Lcompare_fixed_fast
        jmp     .Lcompare_fixed_done
.Lcompare_fixed_rec:                    /* [main] general: 32-byte chunks */
        xor     %r10d, %r10d
        mov     %r14, %r13
.Lcompare_fixed_chunk:
        mov     %rdx, %r11
        sub     %r10, %r11                      /* > 0 */
        mov     %r9, %rax
        sub     %r10, %rax
        cmp     $32, %rax
        jb      .Lcompare_fixed_tail
        vmovdqu (%rdi,%r10), %ymm0
        vpcmpeqb (%rsi,%r10), %ymm0, %ymm0
        vpmovmskb %ymm0, %eax
        not     %eax                            /* differs mask */
        cmp     $32, %r11
        ja      .Lcompare_fixed_pos
        bzhi    %r11d, %eax, %eax
.Lcompare_fixed_pos:
        tzcnt   %eax, %eax                      /* CF = (mask == 0) */
        lea     (%rax,%r10), %rax
        cmovc   %r14, %rax
        cmp     %rax, %r13
        cmova   %rax, %r13
        add     $32, %r10
        cmp     $32, %r11
        ja      .Lcompare_fixed_chunk
.Lcompare_fixed_res:                    /* [result] per record */
        xor     %eax, %eax
        cmp     %r14, %r13
        cmove   %rax, %r13                      /* none: byte 0 (equal) */
        movzbl  (%rdi,%r13), %ebx
        movzbl  (%rsi,%r13), %r12d
        cmp     %r12d, %ebx
.Lcompare_fixed_sign:
        seta    %al
        sbb     $0, %al                         /* (a > b) - (a < b) */
.Lcompare_fixed_store:
        mov     %al, (%r8)
        inc     %r8
        add     %rdx, %rdi
        add     %rdx, %rsi
        sub     %rdx, %r9
        dec     %rcx
        jnz     .Lcompare_fixed_rec
.Lcompare_fixed_done:                   /* [result] */
        EPILOGUE SAVED
        vzeroupper
.Lcompare_fixed_ret:
        ret
.Lcompare_fixed_tail:                   /* [tail] near the buffer end */
        cmp     %r14, %r13
        jne     .Lcompare_fixed_res             /* already found earlier */
.Lcompare_fixed_q:
        lea     8(%r10), %rax
        cmp     %rdx, %rax
        ja      .Lcompare_fixed_b
        mov     (%rdi,%r10), %rbx
        mov     (%rsi,%r10), %r12
        cmp     %r12, %rbx
        jne     .Lcompare_fixed_qdiff
        add     $8, %r10
        jmp     .Lcompare_fixed_q
.Lcompare_fixed_b:
        cmp     %rdx, %r10
        jae     .Lcompare_fixed_eq
        movzbl  (%rdi,%r10), %ebx
        movzbl  (%rsi,%r10), %r12d
        cmp     %r12d, %ebx
        jne     .Lcompare_fixed_sign
        inc     %r10
        jmp     .Lcompare_fixed_b
.Lcompare_fixed_qdiff:
        bswap   %rbx
        bswap   %r12
        cmp     %r12, %rbx
        jmp     .Lcompare_fixed_sign
.Lcompare_fixed_eq:
        xor     %eax, %eax
        jmp     .Lcompare_fixed_store
.Lcompare_fixed_zero:                   /* width 0: all equal */
        movb    $0, (%r8)
        inc     %r8
        dec     %rcx
        jnz     .Lcompare_fixed_zero
        ret
ENDF pqk_x86_avx2_compare_fixed
#undef SAVED

/* ========================================================================
 * int pqk_x86_avx2_group_sum_i64(gid, values, validity, n, sums, counts,
 *                                ngroups)
 * Args:     rdi = gid, rsi = values, rdx = validity, rcx = n, r8 = sums,
 *           r9 = counts (may be NULL), 8(%rsp) = ngroups
 * Returns:  eax = PQK_OK, PQK_OVERFLOW (some addition wrapped) or
 *           PQK_EINVAL (a valid row's group id >= ngroups; outputs
 *           untouched)
 * Clobbers: rax, rcx, rdx, r10, r11, ymm1-ymm6, flags
 *           (rbx, rbp, r12-r15 saved and restored)
 * Algorithm: pass 1 (vectorized range check, 8 ids per ymm): unsigned
 *           id >= ngroups <=> (id ^ 2^31) >s ((ngroups-1) ^ 2^31). Without
 *           validity 32 ids are OR-ed and tested with one vptest; with
 *           validity the 8-bit vmovmskps result is ANDed with the row's
 *           validity byte. ngroups > UINT32_MAX skips the check; ngroups ==
 *           0 and the < 8 row tail use the scalar check. Pass 2
 *           (GSUM_PASS2): scalar scatter-add in row order, so the overflow
 *           flag is exactly the reference's.
 *           r10 = row, r11 = ngroups, r12b = overflow flag.
 * Tail:     pass 1: the last < 8 rows in scalar code (VBIT_TEST); pass 2
 *           handles the last partial validity block with lvp + bzhi.
 * ====================================================================== */
#define SAVED %rbx, %rbp, %r12, %r13, %r14, %r15
FUNC pqk_x86_avx2_group_sum_i64
        PROLOGUE SAVED
        mov     ARG7(6)(%rsp), %r11     /* ngroups */      /* [check] */
        xor     %r12d, %r12d
        xor     %r10d, %r10d
        mov     $0xffffffff, %eax
        cmp     %rax, %r11
        ja      .Lgroup_sum_i64_pass2
        test    %r11, %r11
        jz      .Lgroup_sum_i64_check_s
        lea     -1(%r11), %eax
        xor     $C_SIGN32, %eax
        vmovd   %eax, %xmm1
        vpbroadcastd %xmm1, %ymm1
        vpbroadcastd c_sign_d(%rip), %ymm2
        test    %rdx, %rdx
        jnz     .Lgroup_sum_i64_check8
.Lgroup_sum_i64_check32:                /* [main] pass 1: 32 ids */
        mov     %rcx, %rax
        sub     %r10, %rax
        cmp     $32, %rax
        jb      .Lgroup_sum_i64_check8
        vpxor   (%rdi,%r10,4), %ymm2, %ymm3
        vpxor   32(%rdi,%r10,4), %ymm2, %ymm4
        vpxor   64(%rdi,%r10,4), %ymm2, %ymm5
        vpxor   96(%rdi,%r10,4), %ymm2, %ymm6
        vpcmpgtd %ymm1, %ymm3, %ymm3
        vpcmpgtd %ymm1, %ymm4, %ymm4
        vpcmpgtd %ymm1, %ymm5, %ymm5
        vpcmpgtd %ymm1, %ymm6, %ymm6
        vpor    %ymm4, %ymm3, %ymm3
        vpor    %ymm6, %ymm5, %ymm5
        vpor    %ymm5, %ymm3, %ymm3
        vptest  %ymm3, %ymm3
        jnz     .Lgroup_sum_i64_einval
        add     $32, %r10
        jmp     .Lgroup_sum_i64_check32
.Lgroup_sum_i64_check8:                 /* 8 ids (validity: & byte) */
        mov     %rcx, %rax
        sub     %r10, %rax
        cmp     $8, %rax
        jb      .Lgroup_sum_i64_check_s
        vpxor   (%rdi,%r10,4), %ymm2, %ymm3
        vpcmpgtd %ymm1, %ymm3, %ymm3
        vmovmskps %ymm3, %eax
        test    %rdx, %rdx
        jz      .Lgroup_sum_i64_check8_any
        mov     %r10, %rbx
        shr     $3, %rbx
        movzbl  (%rdx,%rbx), %ebx
        and     %ebx, %eax
.Lgroup_sum_i64_check8_any:
        test    %eax, %eax
        jnz     .Lgroup_sum_i64_einval
        add     $8, %r10
        jmp     .Lgroup_sum_i64_check8
.Lgroup_sum_i64_check_s:                /* [tail] scalar check, rows r10.. */
        cmp     %rcx, %r10
        jae     .Lgroup_sum_i64_pass2
        test    %rdx, %rdx
        jz      .Lgroup_sum_i64_check_id
        VBIT_TEST %rdx, %r10, %r10d, %ebx
        jnc     .Lgroup_sum_i64_check_next
.Lgroup_sum_i64_check_id:
        mov     (%rdi,%r10,4), %eax
        cmp     %r11, %rax
        jae     .Lgroup_sum_i64_einval
.Lgroup_sum_i64_check_next:
        inc     %r10
        jmp     .Lgroup_sum_i64_check_s

.Lgroup_sum_i64_pass2:                  /* [main] pass 2 + [tail] */
        test    %rcx, %rcx
        jz      .Lgroup_sum_i64_ok
        GSUM_PASS2
.Lgroup_sum_i64_ok:                                     /* [result] */
        movzbl  %r12b, %eax
        jmp     .Lgroup_sum_i64_ret
.Lgroup_sum_i64_einval:
        mov     $PQK_EINVAL, %eax
.Lgroup_sum_i64_ret:
        EPILOGUE SAVED
        VRET
ENDF pqk_x86_avx2_group_sum_i64
#undef SAVED

/* ========================================================================
 * void pqk_x86_avx2_gather_i64(data, idx, m, out)
 * Args:     rdi = data, rsi = idx, rdx = m, rcx = out
 * Returns:  -
 * Clobbers: rax, rcx, rdx, rsi, r8, r9, r10, flags
 * Algorithm: GATHER_I64 8: 8 independent scalar load pairs per iteration
 *           (idx zero-extended by the 32-bit mov, so indices >= 2^31 are
 *           fine). vpgatherqq was measured: ~5% faster when data is cache
 *           resident, but 15-20% slower from DRAM (random access is latency
 *           bound; the gather exposes less memory-level parallelism on
 *           Zen 5), so plain loads are used. No vector registers.
 * Tail:     0..7 single rows.
 * ====================================================================== */
FUNC pqk_x86_avx2_gather_i64
        GATHER_I64 8                    /* [check] m < 8 -> [tail] */
        ret                             /* [result] */
ENDF pqk_x86_avx2_gather_i64

/* ========================================================================
 * 128-bit kernels (CR-4, ABI revision 1). A pqk_i128 row is 16 bytes
 * {lo, hi}; row i is at data + 16*i (any alignment). Vector layout and the
 * signed 128-bit compare: see pqk_x86_avx2.h.
 * ====================================================================== */

/* ========================================================================
 * size_t pqk_x86_avx2_filter_i128(data, validity, n, op, a, b, out_idx)
 * Args:     rdi = data, rsi = validity, rdx = n, ecx = op, r8 = &a, r9 = &b,
 *           8(%rsp) = out_idx
 * Returns:  rax = number of indices written; (size_t)-1 for an invalid op
 *           (then a and b are not dereferenced)
 * Clobbers: rax, rcx, rdx, rsi, rdi, r10, r11, ymm0-ymm5, ymm8-ymm14, flags
 *           (rbx, rbp, r12-r15 saved and restored)
 * Algorithm: VDRIVER128: 64-row blocks; vop128_<op> evaluates groups of 4
 *           de-interleaved rows (VG128: 3 compares + blend per 128-bit
 *           predicate), NIBFIX restores row order; mask & validity word;
 *           emission as filter_i64 (EMIT_IDX_COMPRESS8 / tzcnt-blsr; the
 *           32-byte stores stay inside out_idx since outputs <= rows).
 * Tail:     last block: whole groups while >= 4 rows remain, then 1..3
 *           single rows as 16-byte xmm loads; lvp for the validity bytes.
 * ====================================================================== */
FUNC pqk_x86_avx2_filter_i128
        VDRIVER128 MODE_FILTER, filter_i128
ENDF pqk_x86_avx2_filter_i128

/* ========================================================================
 * size_t pqk_x86_avx2_count_i128(data, validity, n, op, a, b)
 * Args:     rdi = data, rsi = validity, rdx = n, ecx = op, r8 = &a, r9 = &b
 * Returns:  rax = number of valid rows satisfying op; (size_t)-1 if invalid
 * Clobbers: rax, rcx, rdx, rsi, rdi, r10, r11, ymm0-ymm4, ymm6, ymm8-ymm15,
 *           flags (rbx, rbp, r12-r15 saved and restored)
 * Algorithm: VDRIVER128: without validity the direct counter
 *           vcnt128_<kind> (vpsubq of all-ones lanes, two accumulators) over
 *           n & ~3 rows, inversion applied once (rows - count); otherwise
 *           the block masks of filter_i128 are popcnt-ed.
 * Tail:     the 1..3 rows after the direct counter, or the last block,
 *           through the mask routine.
 * ====================================================================== */
FUNC pqk_x86_avx2_count_i128
        VDRIVER128 MODE_COUNT, count_i128
ENDF pqk_x86_avx2_count_i128

/* ========================================================================
 * int pqk_x86_avx2_sum_i128(data, validity, n, out_sum)
 * Args:     rdi = data, rsi = validity, rdx = n, rcx = out_sum
 * Returns:  eax = PQK_OK (sum stored) or PQK_OVERFLOW (*out_sum untouched)
 * Clobbers: rax, rcx, rdx, rsi, rdi, r8, r9, r10, r11, ymm0, ymm1,
 *           ymm4-ymm10, flags (rbx, rbp, r12 saved and restored; 8 bytes of
 *           stack hold out_sum)
 * Algorithm: exact sum with overflow detection beyond 128 bits. Each 32-byte
 *           load v = [lo_r, hi_r, lo_r+1, hi_r+1] is treated as four
 *           UNSIGNED 64-bit words after biasing the high words:
 *           hi ^ 2^63 = hi + 2^63, so x = lo + 2^64 * (hi ^ 2^63) - 2^127.
 *           Per lane S = sum(v) mod 2^64 and H = sum(v >>> 32) (SV128);
 *           chunks of at most SUM128_CHUNK_ROWS (2^28) rows keep H and
 *           L < 2^60. fold128 (FOLD_LANES128) adds even lanes at weight 1
 *           and odd lanes at weight 2^64 into the 192-bit total r10:r9:r8,
 *           which cannot wrap (|exact sum| < 2^159). After all rows
 *           UNBIAS192 removes cnt * 2^127 (cnt = rows run through the
 *           vector path; invalid ones are zeroed BEFORE the bias, so they
 *           contribute exactly 2^127 each). Overflow iff T's top word is not
 *           the sign extension of its middle word (JNE_SEXT).
 *           Validity: per full block the word is broadcast (ymm9), vpsllvq
 *           (table shc128s) moves each row's bit into the sign bits of its
 *           two lanes, vpcmpgtq against zero (ymm10) widens it to a lane
 *           mask, which is ANDed with the load.
 *           rdi = row ptr, rsi = validity ptr, r11 = rows remaining, r12 =
 *           chunk counter, rbx = cnt, rbp = tail validity word, (%rsp) =
 *           out_sum; ymm4/ymm5 = S0/S1, ymm6/ymm7 = H0/H1, ymm8 = c_hibias.
 * Tail:     < 8 rows without validity, or the final partial 64-row block
 *           with validity (lvp): added in scalar code, sign-extended to
 *           192 bits (add/adc/adc; invalid rows masked by VBIT_MASK).
 * ====================================================================== */

/* fold128 (sum_i128 only): T += exact value of (S0+S1, H0+H1); zeroes
 * ymm4-ymm7. clobbers rax, rcx, rdx, xmm0, xmm1. */
LFUNC fold128
        vpaddq  %ymm5, %ymm4, %ymm4
        vpaddq  %ymm7, %ymm6, %ymm6
        vextracti128 $1, %ymm4, %xmm0
        vextracti128 $1, %ymm6, %xmm1
        vpaddq  %xmm0, %xmm4, %xmm4     /* [S_lo, S_hi] */
        vpaddq  %xmm1, %xmm6, %xmm6     /* [H_lo, H_hi] */
        FOLD_LANES128
        ret
ENDF fold128

/* SV128 off, s, h, valid, k: one 32-byte load (2 rows) into S\s / H\h;
 * valid = 1: masked with validity pair k (shc128s). clobbers ymm0. */
.macro SV128 off, s, h, valid, k
.if \valid
        vpsllvq shc128s+32*\k(%rip), %ymm9, %ymm0
        vpcmpgtq %ymm0, %ymm10, %ymm0   /* sign -> lane mask */
        vpand   \off(%rdi), %ymm0, %ymm0
        vpxor   %ymm8, %ymm0, %ymm0
.else
        vpxor   \off(%rdi), %ymm8, %ymm0
.endif
        vpaddq  %ymm0, %ymm\s, %ymm\s
        vpsrlq  $32, %ymm0, %ymm0
        vpaddq  %ymm0, %ymm\h, %ymm\h
.endm

#define SAVED %rbx, %rbp, %r12
FUNC pqk_x86_avx2_sum_i128
        PROLOGUE SAVED
        push    %rcx                    /* (%rsp) = out_sum */
        xor     %r8d, %r8d                              /* [check] */
        xor     %r9d, %r9d
        xor     %r10d, %r10d
        xor     %ebx, %ebx
        mov     %rdx, %r11
        vmovdqu c_hibias(%rip), %ymm8
        vpxor   %xmm4, %xmm4, %xmm4
        vpxor   %xmm5, %xmm5, %xmm5
        vpxor   %xmm6, %xmm6, %xmm6
        vpxor   %xmm7, %xmm7, %xmm7
        vpxor   %xmm10, %xmm10, %xmm10
        test    %rsi, %rsi
        jnz     .Lsum_i128_vmain
        cmp     $8, %r11
        jb      .Lsum_i128_tail
        mov     $(SUM128_CHUNK_ROWS / 8), %r12d
.Lsum_i128_main:                                        /* [main] 8 rows */
        SV128   0, 4, 6, 0, 0
        SV128   32, 5, 7, 0, 0
        SV128   64, 4, 6, 0, 0
        SV128   96, 5, 7, 0, 0
        sub     $-128, %rdi
        add     $8, %rbx
        sub     $8, %r11
        dec     %r12d
        jnz     .Lsum_i128_more
        call    fold128
        mov     $(SUM128_CHUNK_ROWS / 8), %r12d
.Lsum_i128_more:
        cmp     $8, %r11
        jae     .Lsum_i128_main
        call    fold128
        jmp     .Lsum_i128_tail
.Lsum_i128_vmain:                       /* [main] validity, 64-row blocks */
        mov     $(SUM128_CHUNK_ROWS / 64), %r12d
.Lsum_i128_vblk:
        cmp     $64, %r11
        jb      .Lsum_i128_vend
        vpbroadcastq (%rsi), %ymm9
        .set k, 0
        .rept 32
        .if k % 2
        SV128   k*32, 5, 7, 1, k
        .else
        SV128   k*32, 4, 6, 1, k
        .endif
        .set k, k + 1
        .endr
        add     $1024, %rdi
        add     $8, %rsi
        add     $64, %rbx
        sub     $64, %r11
        dec     %r12d
        jnz     .Lsum_i128_vblk
        call    fold128
        mov     $(SUM128_CHUNK_ROWS / 64), %r12d
        jmp     .Lsum_i128_vblk
.Lsum_i128_vend:
        call    fold128
.Lsum_i128_tail:                        /* [tail] scalar rows */
        test    %r11, %r11
        jz      .Lsum_i128_result
        mov     $-1, %rbp
        test    %rsi, %rsi
        jz      .Lsum_i128_row
        mov     %r11d, %ecx
        call    lvp                     /* exactly ceil(rows/8) bytes */
        mov     %rax, %rbp
.Lsum_i128_row:
        VBIT_MASK %rbp, %rcx            /* CF = validity bit */
        mov     (%rdi), %rax
        and     %rcx, %rax
        and     8(%rdi), %rcx
        mov     %rcx, %rdx
        sar     $63, %rdx
        add     %rax, %r8
        adc     %rcx, %r9
        adc     %rdx, %r10
        add     $16, %rdi
        dec     %r11
        jnz     .Lsum_i128_row
.Lsum_i128_result:                                      /* [result] */
        UNBIAS192
        JNE_SEXT %r9, %r10, .Lsum_i128_ovf
        pop     %rcx
        mov     %r8, (%rcx)
        mov     %r9, 8(%rcx)
        xor     %eax, %eax                              /* PQK_OK */
        jmp     .Lsum_i128_ret
.Lsum_i128_ovf:
        pop     %rcx
        mov     $PQK_OVERFLOW, %eax
.Lsum_i128_ret:
        EPILOGUE SAVED
        VRET
ENDF pqk_x86_avx2_sum_i128
#undef SAVED

/* ========================================================================
 * size_t pqk_x86_avx2_minmax_i128(data, validity, n, out_min, out_max)
 * Args:     rdi = data, rsi = validity, rdx = n, rcx = out_min, r8 = out_max
 * Returns:  rax = number of valid rows; *out_min / *out_max written if > 0
 * Clobbers: rax, rcx, rdx, rsi, rdi, r8, r10, r11, ymm0-ymm15, flags
 *           (rbx, rbp, r12-r15 saved and restored; 144 bytes of stack:
 *           0..127 spill area, 128 = out_max, 136 = out_min)
 * Algorithm: lane-wise 128-bit min/max over de-interleaved groups (lane
 *           order 0,2,1,3), low words kept sign-biased (lo ^ 2^63) in the
 *           accumulators so every compare is a signed vpcmpgtq:
 *           lt = (x < min) [3 compares + blend], min = lt ? x : min
 *           (2 blends), gt likewise; the update blends are skipped when no
 *           valid lane of the group needs them (vtestpd, MMG128). Two
 *           accumulator sets (A: ymm4-7, B: ymm8-11 = minL', minH, maxL',
 *           maxH) alternate between groups; they start at INT128_MAX /
 *           INT128_MIN, so no first-element case is needed.
 *           Validity: per block the word is broadcast (ymm13); vpsllvq
 *           (table shc128m) moves each row's bit into its lane's sign bit;
 *           lt/gt are ANDed with it. The count is popcnt of the validity
 *           words (bzhi'd to the rows of the final block), or n.
 *           rbx = count, rbp = validity word (tail: bits of the remaining
 *           rows), r10 = shift-table pointer (partial block), ymm12 =
 *           bcast(2^63).
 * Tail:     groups of 4 while >= 4 rows remain (also inside the final
 *           partial block); the last 0..3 rows in scalar code after the
 *           reduction: B is merged into A, A is spilled to the stack and its
 *           4 lanes are folded into r13:r12 (min) / r15:r14 (max) with
 *           SMIN128 / SMAX128.
 * ====================================================================== */

/* MMG128 off, mnl, mnh, mxl, mxh, valid, sh: one group of 4 rows.
 * Lazy update: lt and gt are computed for all lanes; one vtestpd checks
 * whether any (valid) lane needs an update, and only then are the four
 * blends executed. With random data updates become rare after a few
 * thousand rows (measured -15% in L2/L3); ascending data takes the update
 * path every time (+5%, always predicted); 50% unpredictable updates per
 * group were still 10% faster than the branch-free form.
 * clobbers ymm0-ymm3, ymm14, ymm15. */
.macro MMG128 off, mnl, mnh, mxl, mxh, valid, sh
        vmovdqu \off(%rdi), %ymm0
        vmovdqu \off+32(%rdi), %ymm1
        vpunpckhqdq %ymm1, %ymm0, %ymm2         /* H */
        vpunpcklqdq %ymm1, %ymm0, %ymm0
        vpxor   %ymm12, %ymm0, %ymm0            /* L' */
        vpcmpgtq %ymm2, %ymm\mnh, %ymm1
        vpcmpeqq %ymm2, %ymm\mnh, %ymm3
        vpcmpgtq %ymm0, %ymm\mnl, %ymm15
        vblendvpd %ymm3, %ymm15, %ymm1, %ymm1   /* x < min */
        vpcmpgtq %ymm\mxh, %ymm2, %ymm3
        vpcmpeqq %ymm2, %ymm\mxh, %ymm15
        vpcmpgtq %ymm\mxl, %ymm0, %ymm14
        vblendvpd %ymm15, %ymm14, %ymm3, %ymm3  /* x > max */
        vpor    %ymm1, %ymm3, %ymm15
.if \valid
        vpsllvq \sh, %ymm13, %ymm14             /* sign = row valid */
        vtestpd %ymm14, %ymm15                  /* ZF: no valid lane to update */
.else
        vtestpd %ymm15, %ymm15
.endif
        jz      .Lmmg_skip\@
.if \valid
        vpand   %ymm14, %ymm1, %ymm1
        vpand   %ymm14, %ymm3, %ymm3
.endif
        vblendvpd %ymm1, %ymm0, %ymm\mnl, %ymm\mnl
        vblendvpd %ymm1, %ymm2, %ymm\mnh, %ymm\mnh
        vblendvpd %ymm3, %ymm0, %ymm\mxl, %ymm\mxl
        vblendvpd %ymm3, %ymm2, %ymm\mxh, %ymm\mxh
.Lmmg_skip\@:
.endm

#define SAVED %rbx, %rbp, %r12, %r13, %r14, %r15
FUNC pqk_x86_avx2_minmax_i128
        PROLOGUE SAVED
        push    %rcx                    /* out_min */
        push    %r8                     /* out_max */
        sub     $128, %rsp
        vpbroadcastq c_i64min(%rip), %ymm12             /* [check] */
        vpcmpeqd %ymm4, %ymm4, %ymm4
        vpsrlq  $1, %ymm4, %ymm4        /* 2^63-1: minL' (= ~0 ^ 2^63), minH */
        vmovdqa %ymm4, %ymm5
        vmovdqa %ymm12, %ymm6           /* 2^63: maxL' (= 0 ^ 2^63), maxH */
        vmovdqa %ymm12, %ymm7
        vmovdqa %ymm4, %ymm8
        vmovdqa %ymm4, %ymm9
        vmovdqa %ymm12, %ymm10
        vmovdqa %ymm12, %ymm11
        xor     %ebx, %ebx
        mov     %rdx, %r11
        test    %rsi, %rsi
        jnz     .Lminmax_i128_vmain
        mov     %r11, %rbx              /* count = n */
        mov     $-1, %rbp               /* tail rows all valid */
        cmp     $8, %r11
        jb      .Lminmax_i128_tail
.Lminmax_i128_main:                                     /* [main] 8 rows */
        MMG128  0, 4, 5, 6, 7, 0
        MMG128  64, 8, 9, 10, 11, 0
        sub     $-128, %rdi
        sub     $8, %r11
        cmp     $8, %r11
        jae     .Lminmax_i128_main
.Lminmax_i128_tail:                                     /* [tail] 4 rows */
        cmp     $4, %r11
        jb      .Lminmax_i128_reduce
        MMG128  0, 4, 5, 6, 7, 0
        add     $64, %rdi
        sub     $4, %r11
        jmp     .Lminmax_i128_reduce
.Lminmax_i128_vmain:                    /* [main] validity, 64-row blocks */
        test    %r11, %r11
        jz      .Lminmax_i128_reduce
        cmp     $64, %r11
        jb      .Lminmax_i128_vtail
        mov     (%rsi), %rbp
        popcnt  %rbp, %rax
        add     %rax, %rbx
        vpbroadcastq (%rsi), %ymm13
        .set g, 0
        .rept 16
        .if g % 2
        MMG128  g*64, 8, 9, 10, 11, 1, shc128m+32*g(%rip)
        .else
        MMG128  g*64, 4, 5, 6, 7, 1, shc128m+32*g(%rip)
        .endif
        .set g, g + 1
        .endr
        add     $1024, %rdi
        add     $8, %rsi
        sub     $64, %r11
        jmp     .Lminmax_i128_vmain
.Lminmax_i128_vtail:                    /* [tail] last partial block */
        mov     %r11d, %ecx
        call    lvp                     /* exactly ceil(rows/8) bytes */
        bzhi    %r11, %rax, %rbp
        popcnt  %rbp, %rax
        add     %rax, %rbx
        vmovq   %rbp, %xmm13
        vpbroadcastq %xmm13, %ymm13
        lea     shc128m(%rip), %r10
        cmp     $4, %r11
        jb      .Lminmax_i128_reduce
.Lminmax_i128_vgroup:
        MMG128  0, 4, 5, 6, 7, 1, (%r10)
        add     $32, %r10
        add     $64, %rdi
        shr     $4, %rbp
        sub     $4, %r11
        cmp     $4, %r11
        jae     .Lminmax_i128_vgroup
.Lminmax_i128_reduce:                   /* [result] merge B into A */
        vmovdqa %ymm8, %ymm0
        vmovdqa %ymm9, %ymm2
        vpcmpgtq %ymm2, %ymm5, %ymm1
        vpcmpeqq %ymm2, %ymm5, %ymm3
        vpcmpgtq %ymm0, %ymm4, %ymm15
        vblendvpd %ymm3, %ymm15, %ymm1, %ymm1
        vblendvpd %ymm1, %ymm0, %ymm4, %ymm4
        vblendvpd %ymm1, %ymm2, %ymm5, %ymm5
        vmovdqa %ymm10, %ymm0
        vmovdqa %ymm11, %ymm2
        vpcmpgtq %ymm7, %ymm2, %ymm1
        vpcmpeqq %ymm2, %ymm7, %ymm3
        vpcmpgtq %ymm6, %ymm0, %ymm15
        vblendvpd %ymm3, %ymm15, %ymm1, %ymm1
        vblendvpd %ymm1, %ymm0, %ymm6, %ymm6
        vblendvpd %ymm1, %ymm2, %ymm7, %ymm7
        vmovdqu %ymm4, 0(%rsp)          /* spill A, fold its lanes */
        vmovdqu %ymm5, 32(%rsp)
        vmovdqu %ymm6, 64(%rsp)
        vmovdqu %ymm7, 96(%rsp)
        movabs  $C_SIGN64, %r8
        lea     -1(%r8), %r13           /* min = INT128_MAX */
        mov     $-1, %r12
        mov     %r8, %r15               /* max = INT128_MIN */
        xor     %r14d, %r14d
        .set j, 0
        .rept 4
        mov     j*8(%rsp), %rax
        xor     %r8, %rax
        mov     32+j*8(%rsp), %rdx
        SMIN128
        mov     64+j*8(%rsp), %rax
        xor     %r8, %rax
        mov     96+j*8(%rsp), %rdx
        SMAX128
        .set j, j + 1
        .endr
        test    %r11, %r11              /* [tail] 0..3 rows, scalar */
        jz      .Lminmax_i128_store
.Lminmax_i128_row:
        VBIT_CF %rbp                    /* CF = validity bit */
        jnc     .Lminmax_i128_next
        mov     (%rdi), %rax
        mov     8(%rdi), %rdx
        SMIN128
        SMAX128
.Lminmax_i128_next:
        add     $16, %rdi
        dec     %r11
        jnz     .Lminmax_i128_row
.Lminmax_i128_store:
        mov     %rbx, %rax
        test    %rax, %rax
        jz      .Lminmax_i128_ret
        mov     136(%rsp), %rcx
        mov     128(%rsp), %rdx
        mov     %r12, (%rcx)
        mov     %r13, 8(%rcx)
        mov     %r14, (%rdx)
        mov     %r15, 8(%rdx)
.Lminmax_i128_ret:
        add     $144, %rsp
        EPILOGUE SAVED
        VRET
ENDF pqk_x86_avx2_minmax_i128
#undef SAVED

        .section .note.GNU-stack, "", @progbits
