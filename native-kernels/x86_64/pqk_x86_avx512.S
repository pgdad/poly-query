/*
 * pqk_x86_avx512.S — PolyQuery native kernels, variant "x86_avx512".
 *
 * Requires AVX-512 F/BW/VL/DQ (+ BMI1/BMI2/POPCNT, implied on every CPU with
 * those). Only F/BW/VL/DQ instructions are used (no VPOPCNTDQ/CD/VBMI2,
 * which the dispatcher does not check). All 20 kernels of pq_kernels.h
 * (ABI revision 1) as global symbols pqk_x86_avx512_<kernel>, System V
 * AMD64 ABI; every public function that touches vector registers returns
 * through vzeroupper (VRET). Only zmm0-zmm15 are used, so vzeroupper leaves
 * no dirty upper or Hi16 state.
 *
 * Design overview (details at each kernel):
 *  - Predicates: vpcmpq writes k-masks directly (KPRED); a 64-row block is
 *    8 compares merged with kunpckbw/wd/dq. filter_i64 emits indices with
 *    vpcompressd (16 rows per step). count_i64 without validity uses a
 *    direct loop (vpcmpq -> k, merge-masked "acc -= -1").
 *  - Validity: kmovb/kmovw load validity bytes straight into k registers,
 *    used as merge write masks on arithmetic. Hot loops use plain loads;
 *    masked loads appear only in tails (see pqk_x86_avx512.h).
 *  - No-validity streaming loops (count, sum_i64, sum_f64, minmax) peel up
 *    to 7 leading rows so the main loop's 64-byte loads are cache-line
 *    aligned (PEELMASK).
 *  - sum_i64 exact: vpsraq exists, so per lane S = sum(x) mod 2^64 and
 *    H = sum(x >> 32) (arithmetic); sum_i128 uses the 192-bit scheme of the
 *    AVX2 variant (FOLD_LANES128). hash_i64 uses vpmullq (DQ).
 *
 * Layout of this file:
 *   1. constant tables and file-local helpers used by several kernels
 *   2. the kernels, in pq_kernels.h order; each starts with a header comment
 *      (arguments, result, clobbered registers, algorithm, tail strategy)
 *      and follows the [check] / [main] / [tail] / [result] skeleton
 *      described in pqk_x86_common.h.
 * Building blocks shared with other variants or kernels live in
 * pqk_x86_common.h (+ pqk_x86_consts.h), pqk_x86_simd.h and
 * pqk_x86_avx512.h (see README, "Shared building blocks").
 *
 * ABI notes: internal helpers have documented private register conventions
 * and use the stack only for call/ret; no red zone is used; kernels save and
 * restore every callee-saved register they use (PROLOGUE / EPILOGUE).
 */
#include "pqk_x86_common.h"             /* includes pqk_x86_consts.h */
#include "pqk_x86_simd.h"
#include "pqk_x86_avx512.h"

        .set PQK_BMI, 1                 /* tzcnt / blsr / bzhi available */
        .text

/* ========================================================================
 * 1. Constant tables (pqk_x86_consts.h) and file-local helpers
 *   lvp                    partial validity word (kernels with validity)
 *   kop_*, kop_table       i64 mask routines (filter/bitmap/count_i64)
 *   kcnt_*, kcnt_table     i64 direct counters (count_i64)
 *   kop128_*, kcnt128_*    the same for filter_i128 / count_i128
 * ====================================================================== */
        TAB_IOTA16
        TAB_SIXTEEN_D
        TAB_FMIX
        TAB_PINF_NINF
        TAB_I64MAX
        TAB_I64MIN
        TAB_NIB_LUT
        TAB_0F
        TAB_IDX_EVEN_ODD
        TAB_HIBIAS
        TAB_KINV128

        DEFINE_LVP

        KOP kop_eq, 0
        KOP kop_ne, 4
        KOP kop_lt, 6
        KOP kop_le, 5
        KOP kop_gt, 1
        KOP kop_ge, 2
        KOP kop_bt, 99
        OPTABLE kop_table, kop

        KCNT kcnt_eq, 0
        KCNT kcnt_ne, 4
        KCNT kcnt_lt, 6
        KCNT kcnt_le, 5
        KCNT kcnt_gt, 1
        KCNT kcnt_ge, 2
        KCNT kcnt_bt, 99
        OPTABLE kcnt_table, kcnt

        KOP128 kop128_eq, 0, 0
        KOP128 kop128_ne, 0, 1
        KOP128 kop128_lt, 1, 0
        KOP128 kop128_le, 2, 1
        KOP128 kop128_gt, 2, 0
        KOP128 kop128_ge, 1, 1
        KOP128 kop128_bt, 3, 0
        OPTABLE kop128_table, kop128

        KCNT128 kcnt128_k0, 0
        KCNT128 kcnt128_k1, 1
        KCNT128 kcnt128_k2, 2
        KCNT128 kcnt128_k3, 3
        /* operator -> kind (EQ NE LT LE GT GE BETWEEN), inversion: kinv128 */
        JUMPTABLE kcnt128_table, kcnt128_k0, kcnt128_k0, kcnt128_k1, kcnt128_k2, kcnt128_k2, kcnt128_k1, kcnt128_k3

/* ========================================================================
 * size_t pqk_x86_avx512_filter_i64(data, validity, n, op, a, b, out_idx)
 * Args:     rdi = data, rsi = validity, rdx = n, ecx = op, r8 = a, r9 = b,
 *           8(%rsp) = out_idx
 * Returns:  rax = number of indices written; (size_t)-1 for an invalid op
 * Clobbers: rax, rcx, rdx, rsi, rdi, r10, zmm0, zmm4-zmm6, zmm8, zmm9,
 *           k1-k4, flags (rbx, rbp, r12-r15 saved and restored)
 * Algorithm: KDRIVER: 64-row blocks; kop_<op> builds the block mask
 *           (8 vpcmpq -> k, kunpck), & validity word; full blocks emit
 *           indices with vpcompressd (EMIT_IDX_COMPRESS16), the last one
 *           with tzcnt/blsr.
 * Tail:     last block (len < 64): kop_* uses zero-masked 8-row groups
 *           (fault suppression); lvp loads exactly ceil(len/8) bytes.
 * ====================================================================== */
FUNC pqk_x86_avx512_filter_i64
        KDRIVER MODE_FILTER, filter_i64
ENDF pqk_x86_avx512_filter_i64

/* ========================================================================
 * size_t pqk_x86_avx512_filter_i64_bitmap(data, validity, n, op, a, b,
 *                                         out_bits)
 * Args:     rdi = data, rsi = validity, rdx = n, ecx = op, r8 = a, r9 = b,
 *           8(%rsp) = out_bits
 * Returns:  rax = number of set bits; (size_t)-1 for an invalid op
 * Clobbers: rax, rcx, rdx, rsi, rdi, r10, zmm0, zmm8, zmm9, k1-k4, flags
 *           (rbx, rbp, r12-r15 saved and restored)
 * Algorithm: KDRIVER: as filter_i64; each block mask is popcnt-ed and
 *           stored with one 8-byte store.
 * Tail:     last block: ceil(len/8) single-byte stores (trailing bits are
 *           already 0, nothing past ceil(n/8) is written).
 * ====================================================================== */
FUNC pqk_x86_avx512_filter_i64_bitmap
        KDRIVER MODE_BITMAP, filter_i64_bitmap
ENDF pqk_x86_avx512_filter_i64_bitmap

/* ========================================================================
 * size_t pqk_x86_avx512_count_i64(data, validity, n, op, a, b)
 * Args:     rdi = data, rsi = validity, rdx = n, ecx = op, r8 = a, r9 = b
 * Returns:  rax = number of valid rows satisfying op; (size_t)-1 if invalid
 * Clobbers: rax, rcx, rdx, rsi, rdi, r10, r11, zmm0, zmm3-zmm9, k1-k4,
 *           flags (rbx, rbp, r12-r15 saved and restored)
 * Algorithm: KDRIVER: without validity the direct counter kcnt_<op>
 *           (alignment peel, 32 rows per step: vpcmpq -> k, merge-masked
 *           acc -= -1 on 4 accumulators) counts all rows; with validity the
 *           block masks of filter_i64 are popcnt-ed.
 * Tail:     direct counter: masked 8-row groups; block path: the last block
 *           through the mask routine.
 * ====================================================================== */
FUNC pqk_x86_avx512_count_i64
        KDRIVER MODE_COUNT, count_i64
ENDF pqk_x86_avx512_count_i64

/* ========================================================================
 * size_t pqk_x86_avx512_compare_i64(a, b, n, op, out_bits)
 * Args:     rdi = a, rsi = b, rdx = n, ecx = op, r8 = out_bits
 * Returns:  rax = number of set bits; (size_t)-1 for an invalid op
 *           (BETWEEN is invalid here)
 * Clobbers: rax, rcx, rdx, rsi, rdi, r10, zmm0, zmm1, k1-k4, flags
 *           (rbx, rbp, r12-r15 saved and restored)
 * Algorithm: 64-row blocks: kcmp_<op> computes a OP b directly with vpcmpq
 *           (a in a register, b from memory), 8 k-masks merged with kunpck;
 *           the block mask is popcnt-ed and stored (8 bytes).
 *           r12 = a block, r13 = b block, r14 = remaining, r15 = routine,
 *           rbx = popcount total, rbp = out ptr.
 * Tail:     last block: zero-masked 8-row groups; ceil(len/8) single-byte
 *           stores.
 * ====================================================================== */

/* Element-wise compare routines kcmp_* (compare_i64 only):
 * in rdi = &a[block], rsi = &b[block], edx = len (1..64).
 * out rax = mask with exactly len bits. vpcmpq imm computes a OP b directly.
 * clobbers rcx, rdx, rdi, rsi, r10, k1-k4, zmm0, zmm1. */
.macro KCMP1 imm, off, k
        vmovdqu64 \off(%rdi), %zmm0
        vpcmpq  $\imm, \off(%rsi), %zmm0, \k
.endm

.macro KCMP name, imm
LFUNC \name
        cmp     $64, %edx
        jne     .L\name\()_part
        KCMP1   \imm, 0, %k1
        KCMP1   \imm, 64, %k2
        kunpckbw %k1, %k2, %k1
        KCMP1   \imm, 128, %k2
        KCMP1   \imm, 192, %k3
        kunpckbw %k2, %k3, %k2
        kunpckwd %k1, %k2, %k1
        KCMP1   \imm, 256, %k2
        KCMP1   \imm, 320, %k3
        kunpckbw %k2, %k3, %k2
        KCMP1   \imm, 384, %k3
        KCMP1   \imm, 448, %k4
        kunpckbw %k3, %k4, %k3
        kunpckwd %k2, %k3, %k2
        kunpckdq %k1, %k2, %k1
        kmovq   %k1, %rax
        ret
.L\name\()_part:
        xor     %eax, %eax
        xor     %ecx, %ecx
.L\name\()_grp:
        LANES8  %edx, %r10d
        kmovb   %r10d, %k4
        vmovdqu64 (%rdi), %zmm0{%k4}{z}
        vmovdqu64 (%rsi), %zmm1{%k4}{z}
        vpcmpq  $\imm, %zmm1, %zmm0, %k1{%k4}
        kmovb   %k1, %r10d
        shlx    %rcx, %r10, %r10
        or      %r10, %rax
        add     $64, %rdi
        add     $64, %rsi
        add     $8, %ecx
        sub     $8, %edx
        jg      .L\name\()_grp
        ret
ENDF \name
.endm

        KCMP kcmp_eq, 0
        KCMP kcmp_ne, 4
        KCMP kcmp_lt, 1
        KCMP kcmp_le, 2
        KCMP kcmp_gt, 6
        KCMP kcmp_ge, 5
        CMPTABLE kcmp_table, kcmp

#define SAVED %rbx, %rbp, %r12, %r13, %r14, %r15
FUNC pqk_x86_avx512_compare_i64
        OP_CHECK PQK_CMP_OP_LAST, .Lcompare_i64_inval   /* [check] */
        PROLOGUE SAVED
        mov     %ecx, %ecx
        JTAB_LOAD kcmp_table, %r15
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
ENDF pqk_x86_avx512_compare_i64
#undef SAVED

/* ========================================================================
 * int pqk_x86_avx512_sum_i64(data, validity, n, out_sum)
 * Args:     rdi = data, rsi = validity, rdx = n, rcx = out_sum
 * Returns:  eax = PQK_OK (sum stored) or PQK_OVERFLOW (*out_sum untouched)
 * Clobbers: rax, rcx, rdx, rsi, rdi, r8, r9, r10, r11, zmm0-zmm3, zmm6,
 *           zmm7, zmm10, k1, k2, flags (rbx, r12 saved and restored)
 * Algorithm: exact: per lane S = sum(x) mod 2^64 and H = sum(x >> 32)
 *           (arithmetic, vpsraq). sum(x) = H*2^32 + L with L = sum of the low
 *           halves = (S - H*2^32) mod 2^64 (exact while < 2^64); chunks of
 *           <= SUM_CHUNK_ROWS (2^28) rows are folded into the 128-bit scalar
 *           total r9:r8. Validity: kmovb of the row group's byte as merge
 *           mask on the adds (plain loads). Overflow iff hi is not the sign
 *           extension of lo (JNE_SEXT).
 *           Accumulators S zmm0/zmm1, H zmm2/zmm3 (two sets, 16 rows per
 *           step); zmm6/zmm7 data, zmm10 temp; r10 = rows remaining in the
 *           call, r12 = rows left in the chunk, r11 = out_sum.
 * Tail:     no validity: an alignment peel (0..7 scalar rows, PEELMASK)
 *           first. Each chunk's last 0..15 rows: up to 2 zero-masked 8-row
 *           groups (GROUPMASK: row limit & validity byte).
 * ====================================================================== */
#define SAVED %rbx, %r12
FUNC pqk_x86_avx512_sum_i64
        PROLOGUE SAVED
        xor     %r8d, %r8d                              /* [check] */
        xor     %r9d, %r9d
        mov     %rcx, %r11
        mov     %rdx, %r10
        test    %rsi, %rsi
        jnz     .Lsum_i64_chunk
        xor     %edx, %edx
        PEELMASK %r10, %rcx, %ecx, %edx /* scalar head to 64B alignment */
        jz      .Lsum_i64_chunk
        sub     %rcx, %r10
.Lsum_i64_peel:                         /* [main] alignment peel */
        mov     (%rdi), %rax
        cqo
        add     %rax, %r8
        adc     %rdx, %r9
        add     $8, %rdi
        dec     %ecx
        jnz     .Lsum_i64_peel
.Lsum_i64_chunk:                        /* [main] per chunk */
        test    %r10, %r10
        jz      .Lsum_i64_result
        mov     %r10, %r12
        mov     $SUM_CHUNK_ROWS, %eax
        cmp     %rax, %r12
        cmova   %rax, %r12
        sub     %r12, %r10
        vpxorq  %zmm0, %zmm0, %zmm0
        vpxorq  %zmm1, %zmm1, %zmm1
        vpxorq  %zmm2, %zmm2, %zmm2
        vpxorq  %zmm3, %zmm3, %zmm3
        test    %rsi, %rsi
        jnz     .Lsum_i64_vmain
.Lsum_i64_main:                         /* 16 rows, no validity */
        cmp     $16, %r12
        jb      .Lsum_i64_tail
        vmovdqu64 (%rdi), %zmm6
        vmovdqu64 64(%rdi), %zmm7
        vpaddq  %zmm6, %zmm0, %zmm0
        vpaddq  %zmm7, %zmm1, %zmm1
        vpsraq  $32, %zmm6, %zmm6
        vpsraq  $32, %zmm7, %zmm7
        vpaddq  %zmm6, %zmm2, %zmm2
        vpaddq  %zmm7, %zmm3, %zmm3
        sub     $-128, %rdi
        sub     $16, %r12
        jmp     .Lsum_i64_main
.Lsum_i64_vmain:                        /* 16 rows, validity bytes -> k */
        cmp     $16, %r12
        jb      .Lsum_i64_tail
        kmovb   (%rsi), %k1
        kmovb   1(%rsi), %k2
        vmovdqu64 (%rdi), %zmm6
        vmovdqu64 64(%rdi), %zmm7
        vpaddq  %zmm6, %zmm0, %zmm0{%k1}
        vpaddq  %zmm7, %zmm1, %zmm1{%k2}
        vpsraq  $32, %zmm6, %zmm6
        vpsraq  $32, %zmm7, %zmm7
        vpaddq  %zmm6, %zmm2, %zmm2{%k1}
        vpaddq  %zmm7, %zmm3, %zmm3{%k2}
        sub     $-128, %rdi
        add     $2, %rsi
        sub     $16, %r12
        jmp     .Lsum_i64_vmain
.Lsum_i64_tail:                         /* [tail] 0..15 rows: <= 2 groups */
        test    %r12, %r12
        jz      .Lsum_i64_fold
        xchg    %r10, %r12              /* GROUPMASK uses r10 as row count */
        GROUPMASK
        xchg    %r10, %r12
        vmovdqu64 (%rdi), %zmm6{%k1}{z}
        vpaddq  %zmm6, %zmm0, %zmm0
        vpsraq  $32, %zmm6, %zmm6
        vpaddq  %zmm6, %zmm2, %zmm2
        add     $64, %rdi
        test    %rsi, %rsi
        jz      .Lsum_i64_tnext
        inc     %rsi
.Lsum_i64_tnext:
        sub     $8, %r12
        jg      .Lsum_i64_tail
        xor     %r12d, %r12d
.Lsum_i64_fold:                         /* chunk -> 128-bit total */
        vpaddq  %zmm1, %zmm0, %zmm0
        vpaddq  %zmm3, %zmm2, %zmm2
        HSUMZ   %zmm0, %ymm0, %xmm0, %ymm10, %xmm10, %rax      /* S */
        HSUMZ   %zmm2, %ymm2, %xmm2, %ymm10, %xmm10, %rcx      /* H */
        mov     %rcx, %rbx
        shl     $32, %rbx                       /* H << 32 */
        sar     $32, %rcx                       /* H >> 32 (arith) */
        sub     %rbx, %rax                      /* L = S - H*2^32 */
        add     %rax, %r8
        adc     $0, %r9
        add     %rbx, %r8
        adc     %rcx, %r9
        jmp     .Lsum_i64_chunk
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
ENDF pqk_x86_avx512_sum_i64
#undef SAVED

/* ========================================================================
 * double pqk_x86_avx512_sum_f64(data, validity, n)
 * Args:     rdi = data, rsi = validity, rdx = n
 * Returns:  xmm0 = sum of the valid rows (lane-wise partial sums; allowed
 *           reassociation, see pq_kernels.h)
 * Clobbers: rax, rcx, rdx, rsi, rdi, r10, zmm0-zmm7, k1-k4, flags
 * Algorithm: 32 lane partial sums in zmm0-zmm3 (+0.0 init, so a lane is
 *           never -0.0 and zero-masked +0.0 lanes are exact no-ops); 32 rows
 *           per step with the validity bytes as merge masks on the adds
 *           (plain loads: a masked memory operand behaves like a slow masked
 *           load). r10 = rows remaining.
 * Tail:     no validity: alignment peel (masked group) first. The last
 *           0..31 rows: zero-masked 8-row groups (GROUPMASK).
 * ====================================================================== */
FUNC pqk_x86_avx512_sum_f64
        vpxorq  %zmm0, %zmm0, %zmm0                     /* [check] */
        vpxorq  %zmm1, %zmm1, %zmm1
        vpxorq  %zmm2, %zmm2, %zmm2
        vpxorq  %zmm3, %zmm3, %zmm3
        mov     %rdx, %r10
        test    %rsi, %rsi
        jnz     .Lsum_f64_vmain
        xor     %edx, %edx
        PEELMASK %r10, %rcx, %ecx, %edx
        jz      .Lsum_f64_main
        vmovupd (%rdi), %zmm4{%k1}{z}   /* alignment peel */
        vaddpd  %zmm4, %zmm0, %zmm0
        lea     (%rdi,%rcx,8), %rdi
        sub     %rcx, %r10
.Lsum_f64_main:                                         /* [main] 32 rows */
        cmp     $32, %r10
        jb      .Lsum_f64_tail
        vaddpd  (%rdi), %zmm0, %zmm0
        vaddpd  64(%rdi), %zmm1, %zmm1
        vaddpd  128(%rdi), %zmm2, %zmm2
        vaddpd  192(%rdi), %zmm3, %zmm3
        add     $256, %rdi
        sub     $32, %r10
        jmp     .Lsum_f64_main
.Lsum_f64_vmain:                        /* [main] 32 rows with validity */
        cmp     $32, %r10
        jb      .Lsum_f64_tail
        kmovb   (%rsi), %k1
        kmovb   1(%rsi), %k2
        kmovb   2(%rsi), %k3
        kmovb   3(%rsi), %k4
        vmovupd (%rdi), %zmm4                   /* plain loads: a masked */
        vmovupd 64(%rdi), %zmm5                 /* memory operand behaves */
        vmovupd 128(%rdi), %zmm6                /* like a slow masked load */
        vmovupd 192(%rdi), %zmm7
        vaddpd  %zmm4, %zmm0, %zmm0{%k1}
        vaddpd  %zmm5, %zmm1, %zmm1{%k2}
        vaddpd  %zmm6, %zmm2, %zmm2{%k3}
        vaddpd  %zmm7, %zmm3, %zmm3{%k4}
        add     $256, %rdi
        add     $4, %rsi
        sub     $32, %r10
        jmp     .Lsum_f64_vmain
.Lsum_f64_tail:                                         /* [tail] groups */
        test    %r10, %r10
        jz      .Lsum_f64_result
        GROUPMASK
        vmovupd (%rdi), %zmm4{%k1}{z}
        vaddpd  %zmm4, %zmm0, %zmm0
        add     $64, %rdi
        test    %rsi, %rsi
        jz      .Lsum_f64_tnext
        inc     %rsi
.Lsum_f64_tnext:
        sub     $8, %r10
        jg      .Lsum_f64_tail
.Lsum_f64_result:                                       /* [result] */
        vaddpd  %zmm1, %zmm0, %zmm0
        vaddpd  %zmm3, %zmm2, %zmm2
        vaddpd  %zmm2, %zmm0, %zmm0
        vextractf64x4 $1, %zmm0, %ymm1
        vaddpd  %ymm1, %ymm0, %ymm0
        vextractf128 $1, %ymm0, %xmm1
        vaddpd  %xmm1, %xmm0, %xmm0
        vunpckhpd %xmm0, %xmm0, %xmm1
        vaddsd  %xmm1, %xmm0, %xmm0
        VRET
ENDF pqk_x86_avx512_sum_f64

/* ========================================================================
 * size_t pqk_x86_avx512_minmax_i64(data, validity, n, out_min, out_max)
 * Args:     rdi = data, rsi = validity, rdx = n, rcx = out_min, r8 = out_max
 * Returns:  rax = number of valid rows; *out_min / *out_max written if > 0
 * Clobbers: rax, rdx, rsi, rdi, r9, r10, zmm0-zmm5, k1, k2, flags
 * Algorithm: vpminsq/vpmaxsq with merge masking (invalid / out-of-range
 *           lanes keep the accumulator). zmm0/zmm2 min accs (INT64_MAX),
 *           zmm1/zmm3 max accs (INT64_MIN), 16 rows per step; the count is
 *           popcnt of the validity bytes (or n).
 *           r10 = rows remaining, r9 = count of valid rows.
 * Tail:     no validity: alignment peel (masked group) first. The last
 *           0..15 rows: zero-masked 8-row groups (GROUPMASK).
 * ====================================================================== */
FUNC pqk_x86_avx512_minmax_i64
        vpbroadcastq c_i64max(%rip), %zmm0              /* [check] */
        vpbroadcastq c_i64min(%rip), %zmm1
        vmovdqa64 %zmm0, %zmm2
        vmovdqa64 %zmm1, %zmm3
        mov     %rdx, %r10
        xor     %r9d, %r9d
        test    %rsi, %rsi
        jnz     .Lminmax_i64_vmain
        mov     %rdx, %r9
        xor     %edx, %edx
        PEELMASK %r10, %rax, %eax, %edx
        jz      .Lminmax_i64_main
        vmovdqu64 (%rdi), %zmm4{%k1}{z} /* alignment peel */
        vpminsq %zmm4, %zmm0, %zmm0{%k1}
        vpmaxsq %zmm4, %zmm1, %zmm1{%k1}
        lea     (%rdi,%rax,8), %rdi
        sub     %rax, %r10
.Lminmax_i64_main:                                      /* [main] 16 rows */
        cmp     $16, %r10
        jb      .Lminmax_i64_tail
        vmovdqu64 (%rdi), %zmm4
        vmovdqu64 64(%rdi), %zmm5
        vpminsq %zmm4, %zmm0, %zmm0
        vpmaxsq %zmm4, %zmm1, %zmm1
        vpminsq %zmm5, %zmm2, %zmm2
        vpmaxsq %zmm5, %zmm3, %zmm3
        sub     $-128, %rdi
        sub     $16, %r10
        jmp     .Lminmax_i64_main
.Lminmax_i64_vmain:                     /* [main] 16 rows with validity */
        cmp     $16, %r10
        jb      .Lminmax_i64_tail
        movzwl  (%rsi), %eax
        popcnt  %eax, %edx
        add     %rdx, %r9
        kmovw   %eax, %k1
        kshiftrw $8, %k1, %k2
        vmovdqu64 (%rdi), %zmm4
        vmovdqu64 64(%rdi), %zmm5
        vpminsq %zmm4, %zmm0, %zmm0{%k1}
        vpmaxsq %zmm4, %zmm1, %zmm1{%k1}
        vpminsq %zmm5, %zmm2, %zmm2{%k2}
        vpmaxsq %zmm5, %zmm3, %zmm3{%k2}
        sub     $-128, %rdi
        add     $2, %rsi
        sub     $16, %r10
        jmp     .Lminmax_i64_vmain
.Lminmax_i64_tail:                                      /* [tail] groups */
        test    %r10, %r10
        jz      .Lminmax_i64_result
        GROUPMASK
        test    %rsi, %rsi
        jz      .Lminmax_i64_tload
        popcnt  %eax, %eax
        add     %rax, %r9
        inc     %rsi
.Lminmax_i64_tload:
        vmovdqu64 (%rdi), %zmm4{%k1}{z}
        vpminsq %zmm4, %zmm0, %zmm0{%k1}
        vpmaxsq %zmm4, %zmm1, %zmm1{%k1}
        add     $64, %rdi
        sub     $8, %r10
        jg      .Lminmax_i64_tail
.Lminmax_i64_result:                                    /* [result] */
        vpminsq %zmm2, %zmm0, %zmm0
        vpmaxsq %zmm3, %zmm1, %zmm1
        vextracti64x4 $1, %zmm0, %ymm2
        vextracti64x4 $1, %zmm1, %ymm3
        vpminsq %ymm2, %ymm0, %ymm0
        vpmaxsq %ymm3, %ymm1, %ymm1
        vextracti128 $1, %ymm0, %xmm2
        vextracti128 $1, %ymm1, %xmm3
        vpminsq %xmm2, %xmm0, %xmm0
        vpmaxsq %xmm3, %xmm1, %xmm1
        vpshufd $0x4e, %xmm0, %xmm2
        vpshufd $0x4e, %xmm1, %xmm3
        vpminsq %xmm2, %xmm0, %xmm0
        vpmaxsq %xmm3, %xmm1, %xmm1
        mov     %r9, %rax
        test    %rax, %rax
        jz      .Lminmax_i64_ret
        vmovq   %xmm0, (%rcx)
        vmovq   %xmm1, (%r8)
.Lminmax_i64_ret:
        VRET
ENDF pqk_x86_avx512_minmax_i64

/* ========================================================================
 * size_t pqk_x86_avx512_minmax_f64(data, validity, n, out_min, out_max)
 * Args:     rdi = data, rsi = validity, rdx = n, rcx = out_min, r8 = out_max
 * Returns:  rax = number of valid rows; *out_min / *out_max written if > 0
 * Clobbers: rax, rdx, rsi, rdi, r9, r10, r11, zmm0-zmm5, k1, k2, flags
 *           (rbx, r12, r13 saved and restored)
 * Algorithm: like minmax_i64 with vminpd/vmaxpd ("x < acc ? x : acc" per
 *           lane, merge masked); accumulators start at +inf / -inf. Signed
 *           zero: F64_ZERO_FIXUP (first valid zero of the column if the
 *           result compares equal to 0.0).
 *           r9 = count, r10 = remaining, r11 = saved data, r12 = saved
 *           validity, r13 = saved n, ebx = fix-up flags.
 * Tail:     no validity: alignment peel (masked group) first. The last
 *           0..15 rows: zero-masked 8-row groups (GROUPMASK).
 * ====================================================================== */
#define SAVED %rbx, %r12, %r13
FUNC pqk_x86_avx512_minmax_f64
        PROLOGUE SAVED
        mov     %rdi, %r11                              /* [check] */
        mov     %rsi, %r12
        mov     %rdx, %r13
        vbroadcastsd c_pinf(%rip), %zmm0
        vbroadcastsd c_ninf(%rip), %zmm1
        vmovapd %zmm0, %zmm2
        vmovapd %zmm1, %zmm3
        mov     %rdx, %r10
        xor     %r9d, %r9d
        test    %rsi, %rsi
        jnz     .Lminmax_f64_vmain
        mov     %rdx, %r9
        xor     %edx, %edx
        PEELMASK %r10, %rax, %eax, %edx
        jz      .Lminmax_f64_main
        vmovupd (%rdi), %zmm4{%k1}{z}   /* alignment peel */
        vminpd  %zmm0, %zmm4, %zmm0{%k1}
        vmaxpd  %zmm1, %zmm4, %zmm1{%k1}
        lea     (%rdi,%rax,8), %rdi
        sub     %rax, %r10
.Lminmax_f64_main:                                      /* [main] 16 rows */
        cmp     $16, %r10
        jb      .Lminmax_f64_tail
        vmovupd (%rdi), %zmm4
        vmovupd 64(%rdi), %zmm5
        vminpd  %zmm0, %zmm4, %zmm0
        vmaxpd  %zmm1, %zmm4, %zmm1
        vminpd  %zmm2, %zmm5, %zmm2
        vmaxpd  %zmm3, %zmm5, %zmm3
        sub     $-128, %rdi
        sub     $16, %r10
        jmp     .Lminmax_f64_main
.Lminmax_f64_vmain:                     /* [main] 16 rows with validity */
        cmp     $16, %r10
        jb      .Lminmax_f64_tail
        movzwl  (%rsi), %eax
        popcnt  %eax, %edx
        add     %rdx, %r9
        kmovw   %eax, %k1
        kshiftrw $8, %k1, %k2
        vmovupd (%rdi), %zmm4
        vmovupd 64(%rdi), %zmm5
        vminpd  %zmm0, %zmm4, %zmm0{%k1}
        vmaxpd  %zmm1, %zmm4, %zmm1{%k1}
        vminpd  %zmm2, %zmm5, %zmm2{%k2}
        vmaxpd  %zmm3, %zmm5, %zmm3{%k2}
        sub     $-128, %rdi
        add     $2, %rsi
        sub     $16, %r10
        jmp     .Lminmax_f64_vmain
.Lminmax_f64_tail:                                      /* [tail] groups */
        test    %r10, %r10
        jz      .Lminmax_f64_reduce
        GROUPMASK
        test    %rsi, %rsi
        jz      .Lminmax_f64_tload
        popcnt  %eax, %eax
        add     %rax, %r9
        inc     %rsi
.Lminmax_f64_tload:
        vmovupd (%rdi), %zmm4{%k1}{z}
        vminpd  %zmm0, %zmm4, %zmm0{%k1}
        vmaxpd  %zmm1, %zmm4, %zmm1{%k1}
        add     $64, %rdi
        sub     $8, %r10
        jg      .Lminmax_f64_tail
.Lminmax_f64_reduce:                    /* [result] lanes, zero fix-up */
        vminpd  %zmm2, %zmm0, %zmm0
        vmaxpd  %zmm3, %zmm1, %zmm1
        vextractf64x4 $1, %zmm0, %ymm2
        vextractf64x4 $1, %zmm1, %ymm3
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
        test    %r9, %r9
        jz      .Lminmax_f64_ret
        F64_ZERO_FIXUP %ebx, %r11, %r12, %r13
        vmovsd  %xmm0, (%rcx)
        vmovsd  %xmm1, (%r8)
.Lminmax_f64_ret:
        mov     %r9, %rax
        EPILOGUE SAVED
        VRET
ENDF pqk_x86_avx512_minmax_f64
#undef SAVED

/* ========================================================================
 * void pqk_x86_avx512_bitmap_and(a, b, out, nbytes)
 * void pqk_x86_avx512_bitmap_or(a, b, out, nbytes)
 * void pqk_x86_avx512_bitmap_andnot(a, b, out, nbytes)
 * Args:     rdi = a, rsi = b, rdx = out, rcx = nbytes
 * Returns:  -
 * Clobbers: rax, rcx, rdx, rsi, rdi, zmm0-zmm3, zmm7, k1, flags
 * Algorithm: ZBITOP: 256 bytes per iteration (4 zmm; loads before stores at
 *           identical offsets, so out may alias a or b).
 * Tail:     64-byte steps, then one byte-masked step (vmovdqu8 {k1}).
 * ====================================================================== */
FUNC pqk_x86_avx512_bitmap_and
        ZBITOP  bitmap_and, vpandq, 0
ENDF pqk_x86_avx512_bitmap_and

FUNC pqk_x86_avx512_bitmap_or
        ZBITOP  bitmap_or, vporq, 0
ENDF pqk_x86_avx512_bitmap_or

FUNC pqk_x86_avx512_bitmap_andnot
        ZBITOP  bitmap_andnot, vpandnq, 1
ENDF pqk_x86_avx512_bitmap_andnot

/* ========================================================================
 * size_t pqk_x86_avx512_bitmap_popcount(bits, nbits)
 * Args:     rdi = bits, rsi = nbits
 * Returns:  rax = number of set bits among the first nbits bits
 * Clobbers: rax, rcx, rdx, rsi, rdi, r8, r9, zmm0-zmm5, zmm10-zmm14, flags
 * Algorithm: VPOPCNTQ is not part of F/BW/VL/DQ, so: Mula nibble lookup
 *           with vpshufb on zmm (BW), byte counts summed per qword with
 *           vpsadbw, 256 bytes per iteration into 2 zmm accumulators (MULA).
 *           zmm10 = nibble LUT, zmm11 = 0x0f, zmm12 = zero, rcx = blocks /
 *           words.
 * Tail:     the remaining whole qwords with POPCNT, the last 0..63 bits via
 *           lvp (exactly ceil(rem/8) bytes) + bzhi.
 * ====================================================================== */
/* MULA src, acc: acc += per-qword popcount of zmm src. clobbers zmm13,
 * zmm14. */
.macro MULA src, acc
        vpandq  \src, %zmm11, %zmm13
        vpsrlw  $4, \src, %zmm14
        vpandq  %zmm14, %zmm11, %zmm14
        vpshufb %zmm13, %zmm10, %zmm13
        vpshufb %zmm14, %zmm10, %zmm14
        vpaddb  %zmm14, %zmm13, %zmm13
        vpsadbw %zmm12, %zmm13, %zmm13
        vpaddq  %zmm13, \acc, \acc
.endm

FUNC pqk_x86_avx512_bitmap_popcount
        vbroadcasti32x4 nib_lut(%rip), %zmm10           /* [check] */
        vpbroadcastb c_0f(%rip), %zmm11
        vpxorq  %zmm12, %zmm12, %zmm12
        vpxorq  %zmm0, %zmm0, %zmm0
        vpxorq  %zmm1, %zmm1, %zmm1
        mov     %rsi, %rcx
        shr     $11, %rcx                       /* 256-byte blocks */
        jz      .Lbitmap_popcount_sum
.Lbitmap_popcount_main:                                 /* [main] 256 B */
        vmovdqu64 (%rdi), %zmm2
        vmovdqu64 64(%rdi), %zmm3
        vmovdqu64 128(%rdi), %zmm4
        vmovdqu64 192(%rdi), %zmm5
        MULA    %zmm2, %zmm0
        MULA    %zmm3, %zmm1
        MULA    %zmm4, %zmm0
        MULA    %zmm5, %zmm1
        add     $256, %rdi
        dec     %rcx
        jnz     .Lbitmap_popcount_main
.Lbitmap_popcount_sum:
        vpaddq  %zmm1, %zmm0, %zmm0
        HSUMZ   %zmm0, %ymm0, %xmm0, %ymm1, %xmm1, %r8
        mov     %rsi, %rcx
        shr     $6, %rcx
        and     $31, %ecx                       /* remaining whole qwords */
        jz      .Lbitmap_popcount_bits
.Lbitmap_popcount_tail:                                 /* [tail] words */
        popcnt  (%rdi), %rax
        add     %rax, %r8
        add     $8, %rdi
        dec     %ecx
        jnz     .Lbitmap_popcount_tail
.Lbitmap_popcount_bits:                                 /* then bits */
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
ENDF pqk_x86_avx512_bitmap_popcount

/* ========================================================================
 * void pqk_x86_avx512_hash_i64(data, n, seed, out)
 * Args:     rdi = data, rsi = n, rdx = seed, rcx = out
 * Returns:  -
 * Clobbers: rax, rcx, rsi, rdi, zmm0-zmm7, zmm10-zmm12, k1, flags
 * Algorithm: out[i] = fmix64(data[i] ^ seed) with vpmullq (DQ), 32 rows per
 *           iteration (4 independent zmm chains). zmm10/zmm11 = C1/C2,
 *           zmm12 = seed, zmm0-zmm3 = k, zmm4-zmm7 temps.
 * Tail:     masked 8-row groups (zero-masked load, masked store).
 * ====================================================================== */
.macro ZXSH k, t
        vpsrlq  $33, \k, \t
        vpxorq  \t, \k, \k
.endm
.macro ZFMIX k, t
        ZXSH    \k, \t
        vpmullq %zmm10, \k, \k
        ZXSH    \k, \t
        vpmullq %zmm11, \k, \k
        ZXSH    \k, \t
.endm

FUNC pqk_x86_avx512_hash_i64
        vpbroadcastq c_fmix1(%rip), %zmm10              /* [check] */
        vpbroadcastq c_fmix2(%rip), %zmm11
        vpbroadcastq %rdx, %zmm12
        cmp     $32, %rsi
        jb      .Lhash_i64_tail
.Lhash_i64_main:                                        /* [main] 32 rows */
        vpxorq  (%rdi), %zmm12, %zmm0
        vpxorq  64(%rdi), %zmm12, %zmm1
        vpxorq  128(%rdi), %zmm12, %zmm2
        vpxorq  192(%rdi), %zmm12, %zmm3
        ZFMIX   %zmm0, %zmm4
        ZFMIX   %zmm1, %zmm5
        ZFMIX   %zmm2, %zmm6
        ZFMIX   %zmm3, %zmm7
        vmovdqu64 %zmm0, (%rcx)
        vmovdqu64 %zmm1, 64(%rcx)
        vmovdqu64 %zmm2, 128(%rcx)
        vmovdqu64 %zmm3, 192(%rcx)
        add     $256, %rdi
        add     $256, %rcx
        sub     $32, %rsi
        cmp     $32, %rsi
        jae     .Lhash_i64_main
.Lhash_i64_tail:                                        /* [tail] groups */
        test    %rsi, %rsi
        jz      .Lhash_i64_result
        LANES8  %esi, %eax
        kmovb   %eax, %k1
        vmovdqu64 (%rdi), %zmm0{%k1}{z}
        vpxorq  %zmm12, %zmm0, %zmm0
        ZFMIX   %zmm0, %zmm4
        vmovdqu64 %zmm0, (%rcx){%k1}
        add     $64, %rdi
        add     $64, %rcx
        sub     $8, %rsi
        jg      .Lhash_i64_tail
.Lhash_i64_result:                                      /* [result] */
        VRET
ENDF pqk_x86_avx512_hash_i64

/* ========================================================================
 * void pqk_x86_avx512_compare_fixed(a, b, width, n, out)
 * Args:     rdi = a, rsi = b, rdx = width, rcx = n, r8 = out
 * Returns:  -
 * Clobbers: rax, rcx, rsi, rdi, r8, r9, r10, r11, zmm0, zmm1, k1, k2, flags
 *           (rbx, r12-r14 saved and restored)
 * Algorithm: records of width <= 64 (common case) use a dedicated one-chunk
 *           loop with the record byte mask precomputed. Otherwise, per
 *           record, 64-byte chunks: vpcmpb NEQ -> k2 -> "differs" mask (the
 *           record's last chunk limited to the record with bzhi).
 *           Branch-free per record: every chunk is scanned (fixed trip count
 *           per width) and pos = min(offset + tzcnt(mask)) is tracked with
 *           cmovc (tzcnt sets CF for an empty mask) / cmova. If nothing
 *           differs pos becomes 0, whose bytes are equal, so the same byte
 *           compare (seta/sbb -> -1/0/1) yields 0.
 *           r9 = bytes from the current record start to the buffer end,
 *           r10 = offset in record, r11 = bytes left in record, r13 = first
 *           differing offset (-1 = none yet), r14 = -1, rbx/r12 = differing
 *           bytes.
 * Tail:     plain loads (which may run into the next record) are used
 *           while >= 64 bytes remain before the end of the whole buffer;
 *           within the last 64 bytes the loads are byte-masked to the
 *           record (vmovdqu8 {z}, fault suppressing). width 0: all equal.
 * ====================================================================== */
#define SAVED %rbx, %r12, %r13, %r14
FUNC pqk_x86_avx512_compare_fixed
        test    %rcx, %rcx                              /* [check] */
        jz      .Lcompare_fixed_ret
        test    %rdx, %rdx
        jz      .Lcompare_fixed_zero
        PROLOGUE SAVED
        mov     $-1, %r14
        mov     %rdx, %r9
        imul    %rcx, %r9
        cmp     $64, %rdx
        ja      .Lcompare_fixed_rec
        /* width <= 64: one chunk per record, r13 = record byte mask */
        mov     $-1, %r13
        bzhi    %rdx, %r13, %r13
.Lcompare_fixed_fast:                   /* [main] one chunk per record */
        cmp     $64, %r9
        jb      .Lcompare_fixed_rec             /* last records: general path */
        vmovdqu64 (%rdi), %zmm0
        vpcmpb  $4, (%rsi), %zmm0, %k2
        kmovq   %k2, %rax
        and     %r13, %rax                      /* differs & in record */
        tzcnt   %rax, %rax
        and     $63, %eax                       /* none -> byte 0 (equal) */
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
.Lcompare_fixed_rec:                    /* [main] general: 64-byte chunks */
        xor     %r10d, %r10d
        mov     %r14, %r13
.Lcompare_fixed_chunk:
        mov     %rdx, %r11
        sub     %r10, %r11                      /* > 0 */
        mov     %r9, %rax
        sub     %r10, %rax
        cmp     $64, %rax
        jb      .Lcompare_fixed_tail
        vmovdqu64 (%rdi,%r10), %zmm0
        vpcmpb  $4, (%rsi,%r10), %zmm0, %k2
        kmovq   %k2, %rax                       /* differs mask */
.Lcompare_fixed_got:
        cmp     $64, %r11
        ja      .Lcompare_fixed_pos
        bzhi    %r11, %rax, %rax
.Lcompare_fixed_pos:
        tzcnt   %rax, %rax                      /* CF = (mask == 0) */
        lea     (%rax,%r10), %rax
        cmovc   %r14, %rax
        cmp     %rax, %r13
        cmova   %rax, %r13
        add     $64, %r10
        cmp     $64, %r11
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
.Lcompare_fixed_tail:                   /* [tail] within 64 B of the end: r11 < 64 */
        mov     $-1, %rax
        bzhi    %r11, %rax, %rax
        kmovq   %rax, %k1
        vmovdqu8 (%rdi,%r10), %zmm0{%k1}{z}
        vmovdqu8 (%rsi,%r10), %zmm1{%k1}{z}
        vpcmpb  $4, %zmm1, %zmm0, %k2
        kmovq   %k2, %rax
        jmp     .Lcompare_fixed_got
.Lcompare_fixed_zero:                   /* width 0: all equal */
        movb    $0, (%r8)
        inc     %r8
        dec     %rcx
        jnz     .Lcompare_fixed_zero
        ret
ENDF pqk_x86_avx512_compare_fixed
#undef SAVED

/* ========================================================================
 * int pqk_x86_avx512_group_sum_i64(gid, values, validity, n, sums, counts,
 *                                  ngroups)
 * Args:     rdi = gid, rsi = values, rdx = validity, rcx = n, r8 = sums,
 *           r9 = counts (may be NULL), 8(%rsp) = ngroups
 * Returns:  eax = PQK_OK, PQK_OVERFLOW (some addition wrapped) or
 *           PQK_EINVAL (a valid row's group id >= ngroups; outputs
 *           untouched)
 * Clobbers: rax, rcx, rdx, r10, r11, zmm0, zmm1, k1-k4, flags
 *           (rbx, rbp, r12-r15 saved and restored)
 * Algorithm: pass 1: vpcmpud "ngroups <= id" on 16 ids per zmm (unsigned
 *           compare is native; ngroups == 0 flags every valid row, as
 *           required). Validity bytes (kmovw) or a lane mask (tail) serve as
 *           write masks; 64 rows per step are combined with korw/kortestw.
 *           ngroups > UINT32_MAX skips the check. Pass 2 (GSUM_PASS2):
 *           scalar scatter-add in row order (overflow flag exactly the
 *           reference's).
 *           r10 = row, r11 = ngroups, r12b = overflow flag.
 * Tail:     pass 1: the last < 16 rows as one zero-masked group (lane mask
 *           & validity bytes); pass 2: the last partial validity block with
 *           lvp + bzhi.
 * ====================================================================== */
#define SAVED %rbx, %rbp, %r12, %r13, %r14, %r15
FUNC pqk_x86_avx512_group_sum_i64
        PROLOGUE SAVED
        mov     ARG7(6)(%rsp), %r11     /* ngroups */      /* [check] */
        xor     %r12d, %r12d
        xor     %r10d, %r10d
        mov     $0xffffffff, %eax
        cmp     %rax, %r11
        ja      .Lgroup_sum_i64_pass2
        vpbroadcastd %r11d, %zmm1
        test    %rdx, %rdx
        jnz     .Lgroup_sum_i64_check_v
.Lgroup_sum_i64_check64:                /* [main] pass 1: 64 ids */
        mov     %rcx, %rax
        sub     %r10, %rax
        cmp     $64, %rax
        jb      .Lgroup_sum_i64_check16
        vpcmpud $2, (%rdi,%r10,4), %zmm1, %k1
        vpcmpud $2, 64(%rdi,%r10,4), %zmm1, %k2
        vpcmpud $2, 128(%rdi,%r10,4), %zmm1, %k3
        vpcmpud $2, 192(%rdi,%r10,4), %zmm1, %k4
        korw    %k2, %k1, %k1
        korw    %k4, %k3, %k3
        kortestw %k3, %k1
        jnz     .Lgroup_sum_i64_einval
        add     $64, %r10
        jmp     .Lgroup_sum_i64_check64
.Lgroup_sum_i64_check16:                /* 16 ids */
        mov     %rcx, %rax
        sub     %r10, %rax
        cmp     $16, %rax
        jb      .Lgroup_sum_i64_check_t
        vpcmpud $2, (%rdi,%r10,4), %zmm1, %k1
        kortestw %k1, %k1
        jnz     .Lgroup_sum_i64_einval
        add     $16, %r10
        jmp     .Lgroup_sum_i64_check16
.Lgroup_sum_i64_check_v:                /* 16 ids, validity bytes -> k4 */
        mov     %rcx, %rax
        sub     %r10, %rax
        cmp     $16, %rax
        jb      .Lgroup_sum_i64_check_t
        mov     %r10, %rax
        shr     $3, %rax
        kmovw   (%rdx,%rax), %k4
        vmovdqu32 (%rdi,%r10,4), %zmm0
        vpcmpud $2, %zmm0, %zmm1, %k1{%k4}
        kortestw %k1, %k1
        jnz     .Lgroup_sum_i64_einval
        add     $16, %r10
        jmp     .Lgroup_sum_i64_check_v
.Lgroup_sum_i64_check_t:                /* [tail] < 16 rows left */
        mov     %rcx, %rax
        sub     %r10, %rax
        jz      .Lgroup_sum_i64_pass2
        mov     $0xffff, %ebx
        bzhi    %eax, %ebx, %ebx                /* lane mask */
        test    %rdx, %rdx
        jz      .Lgroup_sum_i64_check_tk
        mov     %r10, %r13
        shr     $3, %r13
        movzbl  (%rdx,%r13), %r14d
        cmp     $8, %eax
        jbe     .Lgroup_sum_i64_check_tv
        movzbl  1(%rdx,%r13), %r15d
        shl     $8, %r15d
        or      %r15d, %r14d
.Lgroup_sum_i64_check_tv:
        and     %r14d, %ebx
.Lgroup_sum_i64_check_tk:
        kmovw   %ebx, %k4
        vmovdqu32 (%rdi,%r10,4), %zmm0{%k4}{z}
        vpcmpud $2, %zmm0, %zmm1, %k1{%k4}
        kortestw %k1, %k1
        jnz     .Lgroup_sum_i64_einval

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
ENDF pqk_x86_avx512_group_sum_i64
#undef SAVED

/* ========================================================================
 * void pqk_x86_avx512_gather_i64(data, idx, m, out)
 * Args:     rdi = data, rsi = idx, rdx = m, rcx = out
 * Returns:  -
 * Clobbers: rax, rcx, rdx, rsi, r8, r9, r10, flags
 * Algorithm: GATHER_I64 8, as the AVX2 variant: 8 independent scalar loads
 *           per iteration (the gather instruction measured slower for
 *           DRAM-resident columns). No vector registers.
 * Tail:     0..7 single rows.
 * ====================================================================== */
FUNC pqk_x86_avx512_gather_i64
        GATHER_I64 8                    /* [check] m < 8 -> [tail] */
        ret                             /* [result] */
ENDF pqk_x86_avx512_gather_i64

/* ========================================================================
 * 128-bit kernels (CR-4, ABI revision 1). A pqk_i128 row is 16 bytes
 * {lo, hi}; row i is at data + 16*i (any alignment). Groups, de-interleave
 * (LG128 natural order / LGU128 in-lane order + KFIX) and the signed
 * 128-bit compare: see pqk_x86_avx512.h. Tails use zero-masked loads
 * (architectural fault suppression); the hot loops use plain loads.
 * ====================================================================== */

/* ========================================================================
 * size_t pqk_x86_avx512_filter_i128(data, validity, n, op, a, b, out_idx)
 * Args:     rdi = data, rsi = validity, rdx = n, ecx = op, r8 = &a, r9 = &b,
 *           8(%rsp) = out_idx
 * Returns:  rax = number of indices written; (size_t)-1 for an invalid op
 *           (then a and b are not dereferenced)
 * Clobbers: rax, rcx, rdx, rsi, rdi, r10, r11, zmm0-zmm2, zmm4-zmm6,
 *           zmm8-zmm11, k1-k7, flags (rbx, rbp, r12-r15 saved and restored)
 * Algorithm: KDRIVER128: 64-row blocks; kop128_<op> evaluates 8 groups of 8
 *           rows (LGU128 + KP128: vpcmpq/vpcmpuq/korb), merges the k-masks
 *           and restores row order (KFIX); mask & validity word; full blocks
 *           with a hit emit with vpcompressd (EMIT_IDX_COMPRESS16).
 * Tail:     last block: zero-masked groups (GLANES), bzhi to len; tzcnt /
 *           blsr emission; lvp for the validity bytes.
 * ====================================================================== */
FUNC pqk_x86_avx512_filter_i128
        KDRIVER128 MODE_FILTER, filter_i128
ENDF pqk_x86_avx512_filter_i128

/* ========================================================================
 * size_t pqk_x86_avx512_count_i128(data, validity, n, op, a, b)
 * Args:     rdi = data, rsi = validity, rdx = n, ecx = op, r8 = &a, r9 = &b
 * Returns:  rax = number of valid rows satisfying op; (size_t)-1 if invalid
 * Clobbers: rax, rcx, rdx, rsi, rdi, r10, r11, zmm0-zmm5, zmm8-zmm11,
 *           k1-k7, flags (rbx, rbp, r12-r15 saved and restored)
 * Algorithm: KDRIVER128: without validity the direct counter
 *           kcnt128_<kind> (merge-masked acc -= -1 per group, two
 *           accumulators) counts all rows, inversion applied once (rows -
 *           count, table kinv128); otherwise the block masks of filter_i128
 *           are popcnt-ed.
 * Tail:     direct counter: zero-masked groups ANDed with a row mask in
 *           permuted lane order (pdep 0x55 / 0xaa); block path: the last
 *           block through the mask routine.
 * ====================================================================== */
FUNC pqk_x86_avx512_count_i128
        KDRIVER128 MODE_COUNT, count_i128
ENDF pqk_x86_avx512_count_i128

/* ========================================================================
 * int pqk_x86_avx512_sum_i128(data, validity, n, out_sum)
 * Args:     rdi = data, rsi = validity, rdx = n, rcx = out_sum
 * Returns:  eax = PQK_OK (sum stored) or PQK_OVERFLOW (*out_sum untouched)
 * Clobbers: rax, rcx, rdx, rsi, rdi, r8, r9, r10, r11, zmm0, zmm1,
 *           zmm4-zmm8, k1, flags (rbx, r12 saved and restored; 8 bytes of
 *           stack hold out_sum)
 * Algorithm: same exact algorithm as pqk_x86_avx2_sum_i128, on 4 rows per
 *           zmm: each 64-bit word is accumulated unsigned (high words
 *           biased by 2^63) as S = sum mod 2^64 and H = sum(v >>> 32)
 *           (ZS128); chunks <= SUM128_CHUNK_ROWS (2^28) rows keep H, L <
 *           2^60. fold512 (FOLD_LANES128) adds the lanes into the 192-bit
 *           total r10:r9:r8, and at the end UNBIAS192 subtracts cnt * 2^127
 *           (cnt = number of rows that were biased). Overflow iff T's top
 *           word is not the sign extension of its middle word (JNE_SEXT).
 *           Rows that must not count (invalid, or beyond n in a tail) are
 *           removed by a zero-masking vpxorq: their lanes become 0 (not
 *           biased, not counted). Validity: a 64-row word is expanded to a
 *           128-bit lane mask (DOUBLE2: each bit doubled with pdep 0x5555..
 *           then *3); one byte per 4-row load goes to k1.
 *           r11 = rows remaining, r12 = chunk counter, rbx = cnt, (%rsp) =
 *           out_sum, rax/rcx/rdx = lane masks; zmm4/zmm5 = S0/S1, zmm6/zmm7
 *           = H0/H1, zmm8 = [0, 2^63] x 4, zmm0 scratch.
 * Tail:     < 16 rows without validity, or the final partial block with
 *           validity: zero-masked loads with the same lane mask (no scalar
 *           tail).
 * ====================================================================== */

/* fold512 (sum_i128 only): T += exact value of (S0+S1, H0+H1); zeroes
 * zmm4-zmm7. clobbers rax, rcx, rdx, zmm0, zmm1. */
LFUNC fold512
        vpaddq  %zmm5, %zmm4, %zmm4
        vpaddq  %zmm7, %zmm6, %zmm6
        vextracti64x4 $1, %zmm4, %ymm0
        vextracti64x4 $1, %zmm6, %ymm1
        vpaddq  %ymm0, %ymm4, %ymm4
        vpaddq  %ymm1, %ymm6, %ymm6
        vextracti128 $1, %ymm4, %xmm0
        vextracti128 $1, %ymm6, %xmm1
        vpaddq  %xmm0, %xmm4, %xmm4     /* [S_lo, S_hi] */
        vpaddq  %xmm1, %xmm6, %xmm6     /* [H_lo, H_hi] */
        FOLD_LANES128
        ret
ENDF fold512

/* ZS128 s, h: accumulate zmm0 into S\s / H\h (clobbers zmm0). */
.macro ZS128 s, h
        vpaddq  %zmm0, %zmm\s, %zmm\s
        vpsrlq  $32, %zmm0, %zmm0
        vpaddq  %zmm0, %zmm\h, %zmm\h
.endm

/* DOUBLE2 w(gpr64, clobbered), lo, hi: 128-bit lane mask hi:lo from the
 * 64-row validity word: bit j -> bits 2j, 2j+1. clobbers rcx. */
.macro DOUBLE2 w, lo, hi
        movabs  $C_BITS_EVEN, %rcx
        pdep    %rcx, \w, \lo
        shr     $32, \w
        pdep    %rcx, \w, \hi
        lea     (\lo,\lo,2), \lo
        lea     (\hi,\hi,2), \hi
.endm

#define SAVED %rbx, %r12
FUNC pqk_x86_avx512_sum_i128
        PROLOGUE SAVED
        push    %rcx                    /* (%rsp) = out_sum */
        xor     %r8d, %r8d                              /* [check] */
        xor     %r9d, %r9d
        xor     %r10d, %r10d
        xor     %ebx, %ebx
        mov     %rdx, %r11
        vbroadcasti32x4 c_hibias(%rip), %zmm8
        vpxor   %xmm4, %xmm4, %xmm4
        vpxor   %xmm5, %xmm5, %xmm5
        vpxor   %xmm6, %xmm6, %xmm6
        vpxor   %xmm7, %xmm7, %xmm7
        test    %rsi, %rsi
        jnz     .Lsum_i128_vmain
        cmp     $16, %r11
        jb      .Lsum_i128_tail
        mov     $(SUM128_CHUNK_ROWS / 16), %r12d
.Lsum_i128_main:                                        /* [main] 16 rows */
        vpxorq  0(%rdi), %zmm8, %zmm0
        ZS128   4, 6
        vpxorq  64(%rdi), %zmm8, %zmm0
        ZS128   5, 7
        vpxorq  128(%rdi), %zmm8, %zmm0
        ZS128   4, 6
        vpxorq  192(%rdi), %zmm8, %zmm0
        ZS128   5, 7
        add     $256, %rdi
        add     $16, %rbx
        sub     $16, %r11
        dec     %r12d
        jnz     .Lsum_i128_more
        call    fold512
        mov     $(SUM128_CHUNK_ROWS / 16), %r12d
.Lsum_i128_more:
        cmp     $16, %r11
        jae     .Lsum_i128_main
.Lsum_i128_tail:                        /* [tail] 0..15 rows, all valid */
        test    %r11, %r11
        jz      .Lsum_i128_result
        mov     $4, %ecx
        cmp     %rcx, %r11
        cmovb   %r11, %rcx
        add     %rcx, %rbx
        sub     %rcx, %r11
        add     %ecx, %ecx
        mov     $0xff, %edx
        bzhi    %ecx, %edx, %edx
        kmovb   %edx, %k1
        vmovdqu64 (%rdi), %zmm0{%k1}{z}
        vpxorq  %zmm8, %zmm0, %zmm0{%k1}{z}
        ZS128   4, 6
        add     $64, %rdi
        jmp     .Lsum_i128_tail
.Lsum_i128_vmain:                       /* [main] validity, 64-row blocks */
        mov     $(SUM128_CHUNK_ROWS / 64), %r12d
.Lsum_i128_vblk:
        cmp     $64, %r11
        jb      .Lsum_i128_vtail
        mov     (%rsi), %rax
        popcnt  %rax, %rdx
        add     %rdx, %rbx
        DOUBLE2 %rax, %rdx, %rax        /* rdx = rows 0-31, rax = rows 32-63 */
        .set j, 0
        .rept 16
        .if j == 8
        mov     %rax, %rdx
        .endif
        kmovb   %edx, %k1
        .if j % 8 != 7
        shr     $8, %rdx
        .endif
        vmovdqu64 j*64(%rdi), %zmm0
        vpxorq  %zmm8, %zmm0, %zmm0{%k1}{z}
        .if j % 2
        ZS128   5, 7
        .else
        ZS128   4, 6
        .endif
        .set j, j + 1
        .endr
        add     $1024, %rdi
        add     $8, %rsi
        sub     $64, %r11
        dec     %r12d
        jnz     .Lsum_i128_vblk
        call    fold512
        mov     $(SUM128_CHUNK_ROWS / 64), %r12d
        jmp     .Lsum_i128_vblk
.Lsum_i128_vtail:                       /* [tail] 0..63 rows */
        test    %r11, %r11
        jz      .Lsum_i128_result
        mov     %r11d, %ecx
        call    lvp                     /* exactly ceil(rows/8) bytes */
        bzhi    %r11, %rax, %rax        /* only rows < len */
        popcnt  %rax, %rdx
        add     %rdx, %rbx
        DOUBLE2 %rax, %rdx, %rax
        lea     3(%r11), %r11
        shr     $2, %r11                /* loads of 4 rows */
.Lsum_i128_vrow:
        kmovb   %edx, %k1
        shrd    $8, %rax, %rdx
        shr     $8, %rax
        vmovdqu64 (%rdi), %zmm0{%k1}{z}
        vpxorq  %zmm8, %zmm0, %zmm0{%k1}{z}
        ZS128   4, 6
        add     $64, %rdi
        dec     %r11
        jnz     .Lsum_i128_vrow
.Lsum_i128_result:                                      /* [result] */
        call    fold512
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
ENDF pqk_x86_avx512_sum_i128
#undef SAVED

/* ========================================================================
 * size_t pqk_x86_avx512_minmax_i128(data, validity, n, out_min, out_max)
 * Args:     rdi = data, rsi = validity, rdx = n, rcx = out_min, r8 = out_max
 * Returns:  rax = number of valid rows; *out_min / *out_max written if > 0
 * Clobbers: rax, rcx, rdx, rsi, rdi, r11, zmm0-zmm2, zmm4-zmm11, zmm14,
 *           zmm15, k1-k5, flags (rbx, rbp, r12-r15 saved and restored; 272
 *           bytes of stack: 0..255 spill, 256 = out_max, 264 = out_min)
 * Algorithm: lane-wise 128-bit min/max over de-interleaved 8-row groups in
 *           natural order (LG128):
 *             lt = (x.hi <s min.hi) | (x.hi == min.hi & x.lo <u min.lo)
 *             min.{lo,hi} = lt ? x : min (merge-masked vmovdqa64), same for
 *           max (ZMM128). The compares are write-masked with the group's
 *           validity byte (k3), so invalid rows never update anything;
 *           branch-free. Two accumulator sets (A: zmm4-7, B: zmm8-11 =
 *           minL, minH, maxL, maxH) alternate between groups; they start at
 *           INT128_MAX / INT128_MIN (neutral). The count is popcnt of the
 *           validity words (bzhi'd to n in the last block) or n. At the end
 *           B is merged into A, A is spilled and its 8 lanes are folded into
 *           r13:r12 (min) / r15:r14 (max) with SMIN128 / SMAX128.
 *           rbx = count, rbp = validity word, zmm14/zmm15 = indices, k3 =
 *           row mask, k4/k5 = load lane masks.
 * Tail:     groups of < 8 rows (or the final partial block) use zero-masked
 *           loads and a row mask (ZTAIL); no scalar tail.
 * ====================================================================== */

/* ZMM128 mnl, mnh, mxl, mxh[, vk]: update one accumulator set with the group
 * in zmm0/zmm1 (rows selected by \vk, or all rows if blank). clobbers k1,
 * k2. */
.macro ZMM128 mnl, mnh, mxl, mxh, vk=
.ifb \vk
        vpcmpq  $0, %zmm\mnh, %zmm1, %k1
        vpcmpq  $1, %zmm\mnh, %zmm1, %k2
.else
        vpcmpq  $0, %zmm\mnh, %zmm1, %k1{\vk}
        vpcmpq  $1, %zmm\mnh, %zmm1, %k2{\vk}
.endif
        vpcmpuq $1, %zmm\mnl, %zmm0, %k1{%k1}
        korb    %k1, %k2, %k1                   /* x < min */
        vmovdqa64 %zmm0, %zmm\mnl{%k1}
        vmovdqa64 %zmm1, %zmm\mnh{%k1}
.ifb \vk
        vpcmpq  $0, %zmm\mxh, %zmm1, %k1
        vpcmpq  $6, %zmm\mxh, %zmm1, %k2
.else
        vpcmpq  $0, %zmm\mxh, %zmm1, %k1{\vk}
        vpcmpq  $6, %zmm\mxh, %zmm1, %k2{\vk}
.endif
        vpcmpuq $6, %zmm\mxl, %zmm0, %k1{%k1}
        korb    %k1, %k2, %k1                   /* x > max */
        vmovdqa64 %zmm0, %zmm\mxl{%k1}
        vmovdqa64 %zmm1, %zmm\mxh{%k1}
.endm

/* ZTAIL: masked group of r11 rows (1..8 used) selected by k3 = row limit &
 * validity in ebp's low byte (or all rows: ebp = -1); advances rdi and rbp
 * (the caller advances r11). clobbers ecx, edx, k1-k5, zmm0-zmm2. */
.macro ZTAIL
        mov     $8, %ecx
        cmp     %rcx, %r11
        cmovb   %r11, %rcx
        mov     $0xff, %edx
        bzhi    %ecx, %edx, %edx
        and     %ebp, %edx
        kmovb   %edx, %k3
        GLANES  %ecx
        LG128   0, %k4, %k5
        ZMM128  4, 5, 6, 7, %k3
        sub     $-128, %rdi
        shr     $8, %rbp
.endm

#define SAVED %rbx, %rbp, %r12, %r13, %r14, %r15
FUNC pqk_x86_avx512_minmax_i128
        PROLOGUE SAVED
        push    %rcx                    /* out_min */
        push    %r8                     /* out_max */
        sub     $256, %rsp
        vmovdqu64 c_idx_even(%rip), %zmm14              /* [check] */
        vmovdqu64 c_idx_odd(%rip), %zmm15
        vpternlogd $0xff, %zmm4, %zmm4, %zmm4   /* minL = 2^64-1 */
        vpbroadcastq c_i64max(%rip), %zmm5      /* minH */
        vpxor   %xmm6, %xmm6, %xmm6             /* maxL = 0 */
        vpbroadcastq c_i64min(%rip), %zmm7      /* maxH */
        vmovdqa64 %zmm4, %zmm8
        vmovdqa64 %zmm5, %zmm9
        vmovdqa64 %zmm6, %zmm10
        vmovdqa64 %zmm7, %zmm11
        xor     %ebx, %ebx
        mov     %rdx, %r11
        test    %rsi, %rsi
        jnz     .Lminmax_i128_vmain
        mov     %r11, %rbx              /* count = n */
        cmp     $16, %r11
        jb      .Lminmax_i128_tail
.Lminmax_i128_main:                                     /* [main] 16 rows */
        LG128   0
        ZMM128  4, 5, 6, 7
        LG128   128
        ZMM128  8, 9, 10, 11
        add     $256, %rdi
        sub     $16, %r11
        cmp     $16, %r11
        jae     .Lminmax_i128_main
.Lminmax_i128_tail:                                     /* [tail] groups */
        mov     $-1, %rbp
.Lminmax_i128_tgroup:
        test    %r11, %r11
        jz      .Lminmax_i128_reduce
        ZTAIL
        sub     $8, %r11
        ja      .Lminmax_i128_tgroup
        jmp     .Lminmax_i128_reduce
.Lminmax_i128_vmain:                    /* [main] validity, 64-row blocks */
        test    %r11, %r11
        jz      .Lminmax_i128_reduce
        cmp     $64, %r11
        jb      .Lminmax_i128_vtail
        mov     (%rsi), %rbp
        popcnt  %rbp, %rax
        add     %rax, %rbx
        .set g, 0
        .rept 8
        kmovb   %ebp, %k3
        shr     $8, %rbp
        LG128   g*128
        .if g % 2
        ZMM128  8, 9, 10, 11, %k3
        .else
        ZMM128  4, 5, 6, 7, %k3
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
.Lminmax_i128_vgroup:
        ZTAIL
        sub     $8, %r11
        ja      .Lminmax_i128_vgroup
.Lminmax_i128_reduce:                   /* [result] merge B into A */
        vmovdqa64 %zmm8, %zmm0
        vmovdqa64 %zmm9, %zmm1
        vpcmpq  $0, %zmm5, %zmm1, %k1
        vpcmpq  $1, %zmm5, %zmm1, %k2
        vpcmpuq $1, %zmm4, %zmm0, %k1{%k1}
        korb    %k1, %k2, %k1
        vmovdqa64 %zmm0, %zmm4{%k1}
        vmovdqa64 %zmm1, %zmm5{%k1}
        vmovdqa64 %zmm10, %zmm0
        vmovdqa64 %zmm11, %zmm1
        vpcmpq  $0, %zmm7, %zmm1, %k1
        vpcmpq  $6, %zmm7, %zmm1, %k2
        vpcmpuq $6, %zmm6, %zmm0, %k1{%k1}
        korb    %k1, %k2, %k1
        vmovdqa64 %zmm0, %zmm6{%k1}
        vmovdqa64 %zmm1, %zmm7{%k1}
        vmovdqu64 %zmm4, 0(%rsp)        /* spill A, fold its lanes */
        vmovdqu64 %zmm5, 64(%rsp)
        vmovdqu64 %zmm6, 128(%rsp)
        vmovdqu64 %zmm7, 192(%rsp)
        mov     $-1, %r12               /* min = INT128_MAX */
        mov     c_i64max(%rip), %r13
        xor     %r14d, %r14d            /* max = INT128_MIN */
        mov     c_i64min(%rip), %r15
        .set j, 0
        .rept 8
        mov     j*8(%rsp), %rax
        mov     64+j*8(%rsp), %rdx
        SMIN128
        mov     128+j*8(%rsp), %rax
        mov     192+j*8(%rsp), %rdx
        SMAX128
        .set j, j + 1
        .endr
        mov     %rbx, %rax
        test    %rax, %rax
        jz      .Lminmax_i128_ret
        mov     264(%rsp), %rcx
        mov     256(%rsp), %rdx
        mov     %r12, (%rcx)
        mov     %r13, 8(%rcx)
        mov     %r14, (%rdx)
        mov     %r15, 8(%rdx)
.Lminmax_i128_ret:
        add     $272, %rsp
        EPILOGUE SAVED
        VRET
ENDF pqk_x86_avx512_minmax_i128
#undef SAVED

        .section .note.GNU-stack, "", @progbits
