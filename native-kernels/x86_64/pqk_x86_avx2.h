/*
 * pqk_x86_avx2.h — building blocks of the x86_avx2 variant that are used by
 * more than one of its kernels (included by pqk_x86_avx2.S only). Requires
 * pqk_x86_common.h and pqk_x86_simd.h. Emits nothing by itself.
 *
 *   VPRED, ROWPRED, VOP, VCNT       i64 predicate kinds / mask routines /
 *                                   direct counters
 *   EMIT_IDX_COMPRESS8              8-row pdep/pext index compress
 *   VDRIVER                         filter_i64 / _bitmap / count_i64
 *   VBOP, VBITOP                    bitmap and / or / andnot
 *   LTX, GTX, VG128, NIBFIX,        filter_i128 / count_i128
 *   VOP128, VCNT128, VDRIVER128
 *
 * AVX2 has only "==" and signed ">" for qwords, so every operator maps to
 * (kind, invert):
 *     EQ: x==a   NE: !(x==a)   LT: a>x   LE: !(x>a)   GT: x>a   GE: !(a>x)
 *     BETWEEN: !(a>x | x>b)
 * (table vop_inv in pqk_x86_consts.h holds the invert flags).
 */
#ifndef PQK_X86_AVX2_H
#define PQK_X86_AVX2_H

/* Pseudo operator for BETWEEN with a <= b (kind 4, see VPRED); index 7 of
 * vop_table / vcnt_table / vop_inv. */
#define PQK_OP_RANGE 7

/* RANGE_SETUP k: if op (ecx) is BETWEEN and a (r8) <= b (r9): ecx =
 * PQK_OP_RANGE, ymm8 = bcast(a ^ 2^63), ymm9 = bcast((b - a) ^ 2^63).
 * clobbers rax, r10. */
.macro RANGE_SETUP k
        cmp     $PQK_BETWEEN, %ecx
        jne     .L\k\()_norange
        cmp     %r9, %r8
        jg      .L\k\()_norange          /* a > b: empty, kind 3 */
        mov     $PQK_OP_RANGE, %ecx
        movabs  $C_SIGN64, %rax
        mov     %r8, %r10
        xor     %rax, %r10
        vmovq   %r10, %xmm8
        vpbroadcastq %xmm8, %ymm8
        mov     %r9, %r10
        sub     %r8, %r10
        xor     %rax, %r10
        vmovq   %r10, %xmm9
        vpbroadcastq %xmm9, %ymm9
.L\k\()_norange:
.endm

/* minmax_i64 / minmax_i128 quick reject: after a failed attempt it is not
 * tried for the next QR_BACKOFF blocks, doubling per further failure up to
 * QR_BACKOFF_MAX blocks (see MM64_GLOBAL / MM128_BLOCK). */
#define QR_BACKOFF 8
#define QR_BACKOFF_MAX 1024

/* filter: a full block with at least DENSE_MIN hits uses the compress step
 * (swept 1, 2, 3, 4, 8, 16: 1 is flattest across selectivities). */
#define DENSE_MIN 1

/* ------------------------------------------------------------------------
 * Predicate kinds: 0 EQ (x==a), 1 ALT (a>x), 2 XGT (x>a), 3 OUT (a>x | x>b),
 * 4 ROUT: OUT as one unsigned range test, valid only for a <= b:
 *     x outside [a, b]  <=>  (x - a) >u (b - a)
 *                       <=>  (x - (a ^ 2^63)) >s ((b - a) ^ 2^63)
 *     (x - a + 2^63 = x - (a ^ 2^63) mod 2^64 turns the unsigned compare
 *     into the signed vpcmpgtq): vpsubq + vpcmpgtq instead of two
 *     compares + vpor (one op instead of two on the two Zen 5 compare
 *     pipes). The driver uses it for BETWEEN when a <= b (pseudo operator
 *     PQK_OP_RANGE) and keeps kind 3 for a > b (empty range).
 * VPRED kind, src, dst, tmp: vector form, ymm8 = bcast(a), ymm9 = bcast(b)
 *     (kind 4: ymm8 = bcast(a ^ 2^63), ymm9 = bcast((b - a) ^ 2^63));
 *     src = memory or register; dst = all-ones / zero lanes.
 * ROWPRED kind: scalar form for one row, rdx = x, r8 = a, r9 = b
 *     (kind 4 = kind 3; r8/r9 keep the original a/b) -> r10 = 0/1;
 *     clobbers r11.
 * ---------------------------------------------------------------------- */
.macro VPRED kind, src, dst, tmp
.if \kind == 0
        vpcmpeqq \src, %ymm8, \dst
.elseif \kind == 1
        vpcmpgtq \src, %ymm8, \dst
.elseif \kind == 2
        vmovdqu \src, \dst
        vpcmpgtq %ymm8, \dst, \dst
.elseif \kind == 3
        vmovdqu \src, \tmp
        vpcmpgtq \tmp, %ymm8, \dst
        vpcmpgtq %ymm9, \tmp, \tmp
        vpor    \tmp, \dst, \dst
.else
        vmovdqu \src, \dst
        vpsubq  %ymm8, \dst, \dst
        vpcmpgtq %ymm9, \dst, \dst
.endif
.endm

.macro ROWPRED kind
        xor     %r10d, %r10d
.if \kind == 0
        cmp     %r8, %rdx
        sete    %r10b
.elseif \kind == 1
        cmp     %rdx, %r8
        setg    %r10b
.elseif \kind == 2
        cmp     %r8, %rdx
        setg    %r10b
.else
        cmp     %r8, %rdx
        setl    %r10b
        xor     %r11d, %r11d
        cmp     %r9, %rdx
        setg    %r11b
        or      %r11d, %r10d
.endif
.endm

/* ------------------------------------------------------------------------
 * VOP name, kind, inv: emits mask routine `name` (driver convention):
 * in rdi = block ptr, esi = len (1..64), r8/r9 = a/b, ymm8/ymm9 = bcast a/b.
 * out rax = mask with exactly len bits.
 * clobbers rcx, rdx, rdi, rsi, r10, r11, ymm0-ymm3.
 * [main] full block: 16 x (VPRED on 4 qwords + vmovmskpd); the 4-bit pieces
 * are shifted into place on two independent OR chains.
 * [tail] partial block: whole vectors while >= 4 rows remain, ROWPRED for
 * the last 1..3 rows, then bzhi to len bits; nothing beyond the last row is
 * loaded.
 * ---------------------------------------------------------------------- */
.macro VOP name, kind, inv
LFUNC \name
        cmp     $64, %esi
        jne     .L\name\()_part
        VPRED   \kind, 0(%rdi), %ymm0, %ymm1
        vmovmskpd %ymm0, %eax
        VPRED   \kind, 32(%rdi), %ymm2, %ymm3
        vmovmskpd %ymm2, %edx
        shl     $4, %edx
        .set g, 2
        .rept 14
        VPRED   \kind, g*32(%rdi), %ymm0, %ymm1
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
        xor     %ecx, %ecx              /* bit position */
        cmp     $4, %esi
        jb      .L\name\()_rows
.L\name\()_grp:
        VPRED   \kind, (%rdi), %ymm0, %ymm1
        vmovmskpd %ymm0, %edx
        shlx    %rcx, %rdx, %rdx
        or      %rdx, %rax
        add     $32, %rdi
        add     $4, %ecx
        sub     $4, %esi
        cmp     $4, %esi
        jae     .L\name\()_grp
.L\name\()_rows:
        test    %esi, %esi
        jz      .L\name\()_fin
.L\name\()_row:
        mov     (%rdi), %rdx
        ROWPRED \kind
        shlx    %rcx, %r10, %r10
        or      %r10, %rax
        add     $8, %rdi
        inc     %ecx
        dec     %esi
        jnz     .L\name\()_row
.L\name\()_fin:
.if \inv
        not     %rax
.endif
        bzhi    %rcx, %rax, %rax        /* rcx == len here */
        ret
ENDF \name
.endm

/* VCNT name, kind: direct counter for count_i64 without validity.
 * in rdi = data, rdx = rows (multiple of 16, > 0). out rax = number of rows
 * where the KIND holds (inversion applied by the caller); rcx, rdx kept.
 * 4 accumulators, vpsubq of all-ones lanes (no movmsk).
 * clobbers rdi, r10, ymm0-ymm7. */
.macro VCNT name, kind
LFUNC \name
        vpxor   %xmm4, %xmm4, %xmm4
        vpxor   %xmm5, %xmm5, %xmm5
        vpxor   %xmm6, %xmm6, %xmm6
        vpxor   %xmm7, %xmm7, %xmm7
        mov     %rdx, %r10
.L\name\()_loop:
        VPRED   \kind, 0(%rdi), %ymm0, %ymm1
        vpsubq  %ymm0, %ymm4, %ymm4
        VPRED   \kind, 32(%rdi), %ymm2, %ymm3
        vpsubq  %ymm2, %ymm5, %ymm5
        VPRED   \kind, 64(%rdi), %ymm0, %ymm1
        vpsubq  %ymm0, %ymm6, %ymm6
        VPRED   \kind, 96(%rdi), %ymm2, %ymm3
        vpsubq  %ymm2, %ymm7, %ymm7
        sub     $-128, %rdi
        sub     $16, %r10
        jnz     .L\name\()_loop
        vpaddq  %ymm5, %ymm4, %ymm4
        vpaddq  %ymm7, %ymm6, %ymm6
        vpaddq  %ymm6, %ymm4, %ymm4
        HSUMQ   %ymm4, %xmm4, %xmm0, %rax
        ret
ENDF \name
.endm

/* ------------------------------------------------------------------------
 * EMIT_IDX_COMPRESS8: emit the indices of a full 64-row block mask (rax),
 * 8 rows per step, branch-free (its cost does not depend on selectivity):
 * the table idx8 (pqk_x86_consts.h) holds, for every byte value m, the
 * positions of the set bits of m packed into 8 bytes; one vpmovzxbd load
 * widens them to 8 dwords, + row base (ymm4), stored with one 32-byte
 * store; rbp advances by popcnt. (Formerly pdep + imul + pext + vmovq +
 * vpmovzxbd per step; filter_i64 at 10% selected: 0.146 -> 0.098 ns/row in L2,
 * 0.155 -> 0.111 in L3.)
 * The store never passes out_idx + 4n: outputs so far <= rows consumed and
 * only full blocks use this path. Bytes beyond the count are scratch.
 * in: rax = mask, ebx = row base, rbp = out, ymm5 = bcast(8).
 * clobbers rax, rcx, r10, ymm0, ymm4.
 * ---------------------------------------------------------------------- */
.macro EMIT_IDX_COMPRESS8
        lea     idx8(%rip), %r10
        vmovd   %ebx, %xmm4
        vpbroadcastd %xmm4, %ymm4
        .rept 8
        movzbl  %al, %ecx
        vpmovzxbd (%r10,%rcx,8), %ymm0  /* positions of the set bits */
        vpaddd  %ymm4, %ymm0, %ymm0
        vmovdqu %ymm0, (%rbp)
        popcnt  %ecx, %ecx
        lea     (%rbp,%rcx,4), %rbp
        vpaddd  %ymm5, %ymm4, %ymm4
        shr     $8, %rax
        .endr
.endm

/* ------------------------------------------------------------------------
 * VDRIVER mode, k: body of filter_i64 (MODE_FILTER), filter_i64_bitmap
 * (MODE_BITMAP) and count_i64 (MODE_COUNT); k = kernel name (labels).
 * Args: rdi = data, rsi = validity, rdx = n, ecx = op, r8 = a, r9 = b,
 *       8(%rsp) = out (MODE_FILTER, MODE_BITMAP).
 * Driver registers: pqk_x86_common.h section 6; r15 = vop_* routine,
 * ymm8/9 = bcast a/b, ymm4 = row-base dwords and ymm5 = bcast(8) for the
 * compress step.
 * [check] OP_CHECK; n == 0 skips the block loop. count without validity
 * first runs the direct counter vcnt_<kind> over n & ~15 rows (inversion:
 * rows - count). [main] 64-row blocks: mask, & validity word, consume:
 * filter: EMIT_IDX_COMPRESS8 for full blocks with a hit, EMIT_IDX_BITS
 * (tzcnt/blsr) otherwise; bitmap: 8-byte store + popcnt; count: popcnt.
 * [tail] the last block (len < 64) runs through the same loop.
 * [result] index count / set-bit count; vzeroupper.
 * ---------------------------------------------------------------------- */
.macro VDRIVER mode, k
        DRV_ENTER PQK_OP_LAST, .L\k\()_inval            /* [check] */
        vmovq   %r8, %xmm8
        vpbroadcastq %xmm8, %ymm8
        vmovq   %r9, %xmm9
        vpbroadcastq %xmm9, %ymm9
        RANGE_SETUP \k
        JTAB_LOAD vop_table, %r15
        DRV_ARGS
.if \mode == MODE_FILTER
        vpbroadcastd c_eight_d(%rip), %ymm5
.endif
.if \mode == MODE_COUNT
        test    %r13, %r13              /* no validity: direct counter */
        jnz     .L\k\()_start
        cmp     $16, %r14
        jb      .L\k\()_start
        mov     %r14, %rdx
        and     $-16, %rdx
        JTAB_LOAD vcnt_table, %r10
        mov     %r12, %rdi
        call    *%r10                   /* rax = raw kind count; rcx, rdx kept */
        lea     vop_inv(%rip), %r10
        cmpb    $0, (%r10,%rcx)
        je      .L\k\()_noinv
        neg     %rax
        add     %rdx, %rax
.L\k\()_noinv:
        mov     %rax, %rbx
        lea     (%r12,%rdx,8), %r12
        sub     %rdx, %r14
.endif
.L\k\()_start:
        test    %r14, %r14
        jz      .L\k\()_result
.L\k\()_main:                                           /* [main] + [tail] */
        DRV_MASK
        DRV_VALIDITY
.if \mode == MODE_FILTER
        popcnt  %rax, %rcx
        cmp     $64, %r14
        jb      .L\k\()_sparse
        cmp     $DENSE_MIN, %ecx
        jb      .L\k\()_sparse
        EMIT_IDX_COMPRESS8
        jmp     .L\k\()_next
.L\k\()_sparse:
        EMIT_IDX_BITS %rax
.L\k\()_next:
        add     $64, %rbx
.elseif \mode == MODE_BITMAP
        popcnt  %rax, %rcx
        add     %rcx, %rbx
        cmp     $64, %r14
        jb      .L\k\()_tail
        STORE_BITS_FULL
        jmp     .L\k\()_adv
.L\k\()_tail:
        STORE_BITS_TAIL
.L\k\()_adv:
.else
        popcnt  %rax, %rax
        add     %rax, %rbx
.endif
        DRV_NEXT 512, .L\k\()_main
.L\k\()_result:                                         /* [result] */
        DRV_LEAVE \mode
        VRET
.L\k\()_inval:
        OP_INVALID
.endm

/* ------------------------------------------------------------------------
 * VBITOP k, vop, sop, neg: body of bitmap and/or/andnot (a = rdi, b = rsi,
 * out = rdx, nbytes = rcx); k = kernel name. [main] 128 bytes per iteration
 * (4 ymm, all loads/ops before the stores, so out may alias a or b).
 * [tail] 32-byte, 8-byte and single-byte steps (BYTE_BITOP).
 * VBOP neg, vop, off, reg: reg = a[off] vop b[off] (neg: a & ~b).
 * clobbers rax, rcx, rdx, rsi, rdi, r8, ymm0-ymm3.
 * ---------------------------------------------------------------------- */
.macro VBOP neg, vop, off, reg
.if \neg
        vmovdqu \off(%rsi), \reg
        vpandn  \off(%rdi), \reg, \reg          /* ~b & a */
.else
        vmovdqu \off(%rdi), \reg
        \vop    \off(%rsi), \reg, \reg
.endif
.endm

.macro VBITOP k, vop, sop, neg
        cmp     $128, %rcx              /* [check] none: nbytes may be 0 */
        jb      .L\k\()_tail
.L\k\()_main:                           /* [main] 128 bytes */
        VBOP    \neg, \vop, 0, %ymm0
        VBOP    \neg, \vop, 32, %ymm1
        VBOP    \neg, \vop, 64, %ymm2
        VBOP    \neg, \vop, 96, %ymm3
        vmovdqu %ymm0, (%rdx)
        vmovdqu %ymm1, 32(%rdx)
        vmovdqu %ymm2, 64(%rdx)
        vmovdqu %ymm3, 96(%rdx)
        sub     $-128, %rdi
        sub     $-128, %rsi
        sub     $-128, %rdx
        add     $-128, %rcx
        cmp     $128, %rcx
        jae     .L\k\()_main
.L\k\()_tail:                           /* [tail] 32 bytes */
        cmp     $32, %rcx
        jb      .L\k\()_qwords
        VBOP    \neg, \vop, 0, %ymm0
        vmovdqu %ymm0, (%rdx)
        add     $32, %rdi
        add     $32, %rsi
        add     $32, %rdx
        sub     $32, %rcx
        jmp     .L\k\()_tail
.L\k\()_qwords:                         /* 8 bytes */
        cmp     $8, %rcx
        jb      .L\k\()_bytes
        mov     (%rsi), %r8
.if \neg
        andn    (%rdi), %r8, %rax       /* ~b & a */
.else
        mov     (%rdi), %rax
        \sop    %r8, %rax
.endif
        mov     %rax, (%rdx)
        add     $8, %rdi
        add     $8, %rsi
        add     $8, %rdx
        sub     $8, %rcx
        jmp     .L\k\()_qwords
.L\k\()_bytes:
        BYTE_BITOP \sop, \neg
        VRET                            /* [result] */
.endm

/* ========================================================================
 * 128-bit predicates (filter_i128 / count_i128).
 * Vector layout: a "group" is 4 rows = two unaligned 32-byte loads
 *   Y0 = [lo0 hi0 lo1 hi1], Y1 = [lo2 hi2 lo3 hi3];
 * vpunpcklqdq / vpunpckhqdq de-interleave them (within 128-bit lanes) into
 *   L = [lo0 lo2 lo1 lo3], H = [hi0 hi2 hi1 hi3],
 * i.e. lane k holds row (0, 2, 1, 3)[k]. Order does not matter for counts;
 * predicate masks are fixed up with a SWAR bit swap (NIBFIX).
 * Low words are compared after biasing them with 2^63
 * (x ^ 2^63 <s y ^ 2^63 <=> x <u y). Signed 128-bit
 *   x < c  <=>  c.hi >s x.hi | (c.hi == x.hi & c.lo' >s x.lo')
 * is one vpcmpgtq + vpcmpeqq + vpcmpgtq + vblendvpd (the blend selects the
 * low-word result where the high words are equal).
 * Constant registers (set by VDRIVER128):
 *   ymm8 = bcast(a.lo ^ 2^63), ymm9 = bcast(a.hi),
 *   ymm10 = bcast(b.lo ^ 2^63), ymm11 = bcast(b.hi) (BETWEEN only),
 *   ymm12 = bcast(2^63).
 * Kinds: 0 EQ (x == a), 1 LT (x < a), 2 GT (x > a), 3 OUT (x < a | x > b);
 * operators are (kind, invert): EQ (0,0) NE (0,1) LT (1,0) LE (2,1)
 * GT (2,0) GE (1,1) BETWEEN (3,1). "a > b" needs no special case: OUT is
 * then true for every x, so BETWEEN is empty, as required.
 * Kind 4 ROUT (pseudo operator PQK_OP_RANGE = BETWEEN with a <= b): OUT as
 * one unsigned 128-bit range test, d = x - a (mod 2^128) >u w = b - a:
 *   dL' = L - (a.lo ^ 2^63)                    (= dL ^ 2^63)
 *   borrow = L <u a.lo                         (L' <s a.lo ^ 2^63)
 *   dH' = H - borrow - (a.hi ^ 2^63)           (= dH ^ 2^63)
 *   out = dH' >s wH' | (dH' == wH' & dL' >s wL')   (w' = w ^ 2^63 halves)
 * 4 compares + 1 blend per group instead of 6 + 2 (+ vpor) for kind 3;
 * constants ymm8 = bcast(a.lo ^ 2^63), ymm9 = bcast(a.hi ^ 2^63),
 * ymm10 = bcast(w.lo ^ 2^63), ymm11 = bcast(w.hi ^ 2^63) (RANGE128_SETUP).
 * ====================================================================== */

/* LTX / GTX w, cl, ch, R: lane-wise x < c / x > c with x = (L' in reg 0,
 * H in reg 2), c = (reg cl, reg ch); w = x (xmm) or y (ymm). Result in R;
 * clobbers regs 1 and 3. */
.macro LTX w, cl, ch, R
        vpcmpgtq %\w\()mm2, %\w\()mm\ch, %\w\()mm1
        vpcmpeqq %\w\()mm2, %\w\()mm\ch, %\w\()mm3
        vpcmpgtq %\w\()mm0, %\w\()mm\cl, %\w\()mm\R
        vblendvpd %\w\()mm3, %\w\()mm\R, %\w\()mm1, %\w\()mm\R
.endm
.macro GTX w, cl, ch, R
        vpcmpgtq %\w\()mm\ch, %\w\()mm2, %\w\()mm1
        vpcmpeqq %\w\()mm2, %\w\()mm\ch, %\w\()mm3
        vpcmpgtq %\w\()mm\cl, %\w\()mm0, %\w\()mm\R
        vblendvpd %\w\()mm3, %\w\()mm\R, %\w\()mm1, %\w\()mm\R
.endm
/* VG128 kind, w, off, R, T: w = y: the group of 4 rows at off(%rdi);
 * w = x: one row (both lanes = the row). Result: all-ones / zero lanes in
 * register R. clobbers registers 0-3 and T. */
.macro VG128 kind, w, off, R, T
.ifc \w, y
        vmovdqu \off(%rdi), %ymm0
        vmovdqu \off+32(%rdi), %ymm1
        vpunpckhqdq %ymm1, %ymm0, %ymm2         /* H */
        vpunpcklqdq %ymm1, %ymm0, %ymm0         /* L */
.else
        vmovdqu \off(%rdi), %xmm0
        vpunpckhqdq %xmm0, %xmm0, %xmm2
        vpunpcklqdq %xmm0, %xmm0, %xmm0
.endif
.if \kind == 4
        vpxor   %\w\()mm12, %\w\()mm0, %\w\()mm3 /* L' */
        vpsubq  %\w\()mm8, %\w\()mm0, %\w\()mm0  /* dL' = L - (a.lo ^ 2^63) */
        vpcmpgtq %\w\()mm3, %\w\()mm8, %\w\()mm3 /* borrow: L <u a.lo */
        vpaddq  %\w\()mm3, %\w\()mm2, %\w\()mm2
        vpsubq  %\w\()mm9, %\w\()mm2, %\w\()mm2  /* dH' = H - borrow - (a.hi ^ 2^63) */
        vpcmpgtq %\w\()mm11, %\w\()mm2, %\w\()mm1
        vpcmpeqq %\w\()mm11, %\w\()mm2, %\w\()mm3
        vpcmpgtq %\w\()mm10, %\w\()mm0, %\w\()mm\R
        vblendvpd %\w\()mm3, %\w\()mm\R, %\w\()mm1, %\w\()mm\R /* d >u w */
.else
        vpxor   %\w\()mm12, %\w\()mm0, %\w\()mm0 /* L' = L ^ 2^63 */
.if \kind == 0
        vpcmpeqq %\w\()mm0, %\w\()mm8, %\w\()mm1
        vpcmpeqq %\w\()mm2, %\w\()mm9, %\w\()mm\R
        vpand   %\w\()mm1, %\w\()mm\R, %\w\()mm\R
.elseif \kind == 1
        LTX     \w, 8, 9, \R
.elseif \kind == 2
        GTX     \w, 8, 9, \R
.else
        LTX     \w, 8, 9, \T
        GTX     \w, 10, 11, \R
        vpor    %\w\()mm\T, %\w\()mm\R, %\w\()mm\R
.endif
.endif
.endm

/* RANGE128_SETUP k: if op (ecx) is BETWEEN and *a (r8) <= *b (r9) (signed
 * 128-bit): ecx = PQK_OP_RANGE and ymm8-ymm11 = the kind-4 constants
 * (a.lo ^ 2^63, a.hi ^ 2^63, w.lo ^ 2^63, w.hi ^ 2^63 with w = b - a).
 * clobbers rax, r10, r11. */
.macro RANGE128_SETUP k
        cmp     $PQK_BETWEEN, %ecx
        jne     .L\k\()_norange
        mov     8(%r8), %rax            /* a.hi */
        cmp     8(%r9), %rax
        jg      .L\k\()_norange          /* a > b: empty, kind 3 */
        jl      .L\k\()_range
        mov     (%r8), %rax
        cmp     (%r9), %rax
        ja      .L\k\()_norange
.L\k\()_range:
        mov     $PQK_OP_RANGE, %ecx
        mov     (%r9), %r10             /* w = b - a */
        mov     8(%r9), %r11
        sub     (%r8), %r10
        sbb     8(%r8), %r11
        movabs  $C_SIGN64, %rax
        xor     %rax, %r10
        xor     %rax, %r11
        vmovq   %r10, %xmm10
        vpbroadcastq %xmm10, %ymm10
        vmovq   %r11, %xmm11
        vpbroadcastq %xmm11, %ymm11
        mov     8(%r8), %r10
        xor     %rax, %r10
        vmovq   %r10, %xmm9
        vpbroadcastq %xmm9, %ymm9       /* ymm8 = a.lo ^ 2^63 already */
.L\k\()_norange:
.endm

/* NIBFIX m: vmovmskpd of a group yields rows in bit order (0, 2, 1, 3); swap
 * bits 1 and 2 of every nibble of \m (delta swap). clobbers rdx, r11. */
.macro NIBFIX m
        mov     \m, %rdx
        shr     $1, %rdx
        xor     \m, %rdx
        movabs  $C_NIB_BIT1, %r11
        and     %r11, %rdx
        lea     (%rdx,%rdx,2), %rdx
        xor     %rdx, \m
.endm

/* VOP128 name, kind, inv: emits mask routine `name` (driver convention):
 * in rdi = block ptr, esi = len (1..64), constants as above.
 * out rax = mask with exactly len bits (bit j = row j).
 * clobbers rcx, rdx, rdi, rsi, r10, r11, ymm0-ymm3, ymm13, ymm14.
 * [main] full block: 16 groups on two independent OR chains, then NIBFIX.
 * [tail] partial block: whole groups while >= 4 rows remain (NIBFIX applies
 * to them only), then 1..3 single rows as 16-byte xmm loads; nothing past
 * the last row is read. */
.macro VOP128 name, kind, inv
LFUNC \name
        cmp     $64, %esi
        jne     .L\name\()_part
        VG128   \kind, y, 0, 13, 14
        vmovmskpd %ymm13, %eax
        VG128   \kind, y, 64, 13, 14
        vmovmskpd %ymm13, %r10d
        shl     $4, %r10d
        .set g, 2
        .rept 14
        VG128   \kind, y, g*64, 13, 14
        vmovmskpd %ymm13, %ecx
        shl     $(4*g), %rcx
        .if g % 2
        or      %rcx, %r10
        .else
        or      %rcx, %rax
        .endif
        .set g, g + 1
        .endr
        or      %r10, %rax
        NIBFIX  %rax
.if \inv
        not     %rax
.endif
        ret
.L\name\()_part:
        xor     %eax, %eax
        xor     %ecx, %ecx              /* bit position */
        cmp     $4, %esi
        jb      .L\name\()_rows
.L\name\()_grp:
        VG128   \kind, y, 0, 13, 14
        vmovmskpd %ymm13, %edx
        shlx    %rcx, %rdx, %rdx
        or      %rdx, %rax
        add     $64, %rdi
        add     $4, %ecx
        sub     $4, %esi
        cmp     $4, %esi
        jae     .L\name\()_grp
        NIBFIX  %rax
.L\name\()_rows:
        test    %esi, %esi
        jz      .L\name\()_fin
.L\name\()_row:
        VG128   \kind, x, 0, 13, 14
        vmovmskpd %xmm13, %edx
        and     $1, %edx
        shlx    %rcx, %rdx, %rdx
        or      %rdx, %rax
        add     $16, %rdi
        inc     %ecx
        dec     %esi
        jnz     .L\name\()_row
.L\name\()_fin:
.if \inv
        not     %rax
.endif
        bzhi    %rcx, %rax, %rax        /* rcx == len here */
        ret
ENDF \name
.endm

/* VOP128F name, kind, inv, exact: mask routine like VOP128 (same
 * convention) for kinds 1 (LT) and 2 (GT) with a high-word fast path for
 * full blocks: per row T = "kind holds whatever the low word is" and F =
 * "kind fails whatever the low word is" (see VCNT128_HI); if every row of
 * the block is decided (T | F), the mask is T: 2 compares + vmovmskpd per
 * group instead of 3 compares + blend + vmovmskpd (+ low-word
 * de-interleave and bias). Otherwise, and for partial blocks, it jumps to
 * the exact routine \exact; after a failed attempt the fast path is
 * skipped for r8d blocks (exponential back-off in r9d, QR_BACKOFF ..
 * QR_BACKOFF_MAX; set up by VDRIVER128).
 * clobbers rcx, rdx, rdi, rsi, r10, r11, ymm0-ymm3, ymm13, ymm14. */
.macro VOP128F name, kind, inv, exact
LFUNC \name
        cmp     $64, %esi
        jne     \exact
        test    %r8d, %r8d
        jnz     .L\name\()_plain
        .set g, 0
        .rept 16
        vmovdqu g*64(%rdi), %ymm0
        vpunpckhqdq g*64+32(%rdi), %ymm0, %ymm2 /* H */
.if \kind == 1
        vpcmpgtq %ymm2, %ymm9, %ymm1            /* T: a.hi > hi */
        vpcmpgtq %ymm9, %ymm2, %ymm3            /* F: hi > a.hi */
.else
        vpcmpgtq %ymm9, %ymm2, %ymm1
        vpcmpgtq %ymm2, %ymm9, %ymm3
.endif
        vpor    %ymm1, %ymm3, %ymm3             /* decided */
        .if g == 0
        vmovdqa %ymm3, %ymm13
        .elseif g == 1
        vmovdqa %ymm3, %ymm14
        .elseif g % 2
        vpand   %ymm3, %ymm14, %ymm14
        .else
        vpand   %ymm3, %ymm13, %ymm13
        .endif
        vmovmskpd %ymm1, %ecx
        .if g == 0
        mov     %ecx, %eax
        .elseif g == 1
        shl     $4, %ecx
        mov     %ecx, %r10d
        .else
        shl     $(4*g), %rcx
        .if g % 2
        or      %rcx, %r10
        .else
        or      %rcx, %rax
        .endif
        .endif
        .set g, g + 1
        .endr
        vpand   %ymm14, %ymm13, %ymm13
        vtestpd c_sign4(%rip), %ymm13           /* CF: all rows decided */
        jnc     .L\name\()_fail
        or      %r10, %rax
        NIBFIX  %rax
.if \inv
        not     %rax
.endif
        mov     $QR_BACKOFF, %r9d
        ret
.L\name\()_fail:
        mov     %r9d, %r8d
        add     %r9d, %r9d
        mov     $QR_BACKOFF_MAX, %ecx
        cmp     %ecx, %r9d
        cmova   %ecx, %r9d
        jmp     \exact
.L\name\()_plain:
        dec     %r8d
        jmp     \exact
ENDF \name
.endm

/* VCNT128 name, kind: direct counter for count_i128 without validity.
 * in rdi = data, rdx = rows (multiple of 4, > 0). out rax = number of rows
 * where the KIND holds (inversion applied by the caller); rcx, rdx kept.
 * Two groups per iteration on two accumulators (vpsubq of all-ones lanes).
 * Kinds 1, 2, 4 first run 64-row blocks through VCNT128_HI (high words
 * only); a block with an undecided row is recounted exactly (VCNT128_EXACT)
 * and the fast test is then skipped for r11d blocks (exponential back-off
 * in esi, as for minmax: QR_BACKOFF .. QR_BACKOFF_MAX).
 * clobbers rsi, rdi, r10, r11, ymm0-ymm7, ymm13-ymm15; 32 bytes of stack
 * (kind 4). */
.macro VCNT128_EXACT kind
        .set g, 0
        .rept 8
        VG128   \kind, y, g*128, 13, 14
        vpsubq  %ymm13, %ymm4, %ymm4
        VG128   \kind, y, g*128+64, 15, 14
        vpsubq  %ymm15, %ymm6, %ymm6
        .set g, g + 1
        .endr
.endm
/* VCNT128_HI kind: one 64-row block on the high words: per row T = "kind
 * holds whatever the low word is", F = "kind fails whatever the low word
 * is"; a row with neither (high word equal to a bound) is undecided.
 *   kind 1 (x < a): T = a.hi > hi, F = hi > a.hi        (ymm9 = a.hi)
 *   kind 2 (x > a): T = hi > a.hi, F = a.hi > hi
 *   kind 4 (OUT):   T = hi outside [a.hi, b.hi], F = hi inside (a.hi, b.hi),
 *                   both as unsigned range tests (cf. VPRED kind 4):
 *                   T = (hi - a.hi) >u b.hi - a.hi, F = (hi - a.hi - 1) <u
 *                   b.hi - a.hi - 1 (never if b.hi <= a.hi); ymm9 =
 *                   a.hi ^ 2^63, ymm7 = (a.hi + 1) ^ 2^63, (%rsp) =
 *                   bcast((b.hi - a.hi) ^ 2^63), ymm5 = bcast(W2 ^ 2^63).
 * 2 compares per group instead of 3 compares + blend (+ the low-word
 * de-interleave and bias). Every lane sees 16 rows; if T + F == 16 in all
 * lanes, ymm4 += T counts and CF = 1, else CF = 0 (ymm4 unchanged).
 * clobbers ymm0-ymm3, ymm13-ymm15. */
.macro VCNT128_HI kind
        vpxor   %xmm13, %xmm13, %xmm13
        vpxor   %xmm14, %xmm14, %xmm14
        .set g, 0
        .rept 16
        vmovdqu g*64(%rdi), %ymm0
        vpunpckhqdq g*64+32(%rdi), %ymm0, %ymm2 /* H */
.if \kind == 1
        vpcmpgtq %ymm2, %ymm9, %ymm1
        vpcmpgtq %ymm9, %ymm2, %ymm3
.elseif \kind == 2
        vpcmpgtq %ymm9, %ymm2, %ymm1
        vpcmpgtq %ymm2, %ymm9, %ymm3
.else
        vpsubq  %ymm9, %ymm2, %ymm1
        vpcmpgtq (%rsp), %ymm1, %ymm1           /* outside [a.hi, b.hi] */
        vpsubq  %ymm7, %ymm2, %ymm3
        vpcmpgtq %ymm3, %ymm5, %ymm3            /* inside (a.hi, b.hi) */
.endif
        vpsubq  %ymm1, %ymm13, %ymm13
        vpsubq  %ymm3, %ymm14, %ymm14
        .set g, g + 1
        .endr
        vpaddq  %ymm14, %ymm13, %ymm15
        vpcmpeqq c_sixteen_q(%rip), %ymm15, %ymm15
        vtestpd c_sign4(%rip), %ymm15           /* CF: all lanes decided */
        jnc     .Lvh_und\@
        vpaddq  %ymm13, %ymm4, %ymm4
        stc
.Lvh_und\@:
.endm
.macro VCNT128 name, kind
LFUNC \name
        vpxor   %xmm4, %xmm4, %xmm4
        vpxor   %xmm6, %xmm6, %xmm6
        mov     %rdx, %r10
.if \kind == 1 || \kind == 2 || \kind == 4
.if \kind == 4
        sub     $32, %rsp
        vmovq   %xmm9, %rax             /* a.hi ^ 2^63 */
        vmovq   %xmm8, %rsi             /* a.lo ^ 2^63 */
        vmovq   %xmm10, %r11            /* w.lo ^ 2^63 */
        btc     $63, %rsi
        btc     $63, %r11
        add     %r11, %rsi              /* CF: carry of a.lo + w.lo */
        vmovq   %xmm11, %r11            /* w.hi ^ 2^63 */
        adc     $0, %r11                /* (b.hi - a.hi) ^ 2^63 */
        vmovq   %r11, %xmm0
        vpbroadcastq %xmm0, %ymm0
        vmovdqu %ymm0, (%rsp)
        btc     $63, %r11               /* D = b.hi - a.hi (unsigned) */
        sub     $1, %r11                /* W2 = D - 1 */
        jnc     .L\name\()_w2
        xor     %r11d, %r11d            /* D == 0: no interior, W2 = 0 */
.L\name\()_w2:
        btc     $63, %r11
        vmovq   %r11, %xmm5
        vpbroadcastq %xmm5, %ymm5
        inc     %rax                    /* (a.hi + 1) ^ 2^63 */
        vmovq   %rax, %xmm7
        vpbroadcastq %xmm7, %ymm7
.endif
        xor     %r11d, %r11d            /* back-off countdown / length */
        mov     $QR_BACKOFF, %esi
.L\name\()_blk:
        cmp     $64, %r10
        jb      .L\name\()_rest
        test    %r11d, %r11d
        jnz     .L\name\()_plain
        VCNT128_HI \kind
        jnc     .L\name\()_fail
        mov     $QR_BACKOFF, %esi
        jmp     .L\name\()_next
.L\name\()_fail:
        mov     %esi, %r11d
        add     %esi, %esi
        mov     $QR_BACKOFF_MAX, %eax
        cmp     %eax, %esi
        cmova   %eax, %esi
        jmp     .L\name\()_exact
.L\name\()_plain:
        dec     %r11d
.L\name\()_exact:
        VCNT128_EXACT \kind
.L\name\()_next:
        add     $1024, %rdi
        sub     $64, %r10
        jmp     .L\name\()_blk
.L\name\()_rest:
        test    %r10, %r10
        jz      .L\name\()_sum
.endif
        test    $4, %r10d
        jz      .L\name\()_loop
        VG128   \kind, y, 0, 13, 14
        vpsubq  %ymm13, %ymm4, %ymm4
        add     $64, %rdi
        sub     $4, %r10
        jz      .L\name\()_sum
.L\name\()_loop:
        VG128   \kind, y, 0, 13, 14
        vpsubq  %ymm13, %ymm4, %ymm4
        VG128   \kind, y, 64, 15, 14
        vpsubq  %ymm15, %ymm6, %ymm6
        sub     $-128, %rdi
        sub     $8, %r10
        jnz     .L\name\()_loop
.L\name\()_sum:
        vpaddq  %ymm6, %ymm4, %ymm4
        HSUMQ   %ymm4, %xmm4, %xmm0, %rax
.if \kind == 4
        add     $32, %rsp
.endif
        ret
ENDF \name
.endm

/* ------------------------------------------------------------------------
 * VDRIVER128 mode, k: body of filter_i128 (MODE_FILTER) / count_i128
 * (MODE_COUNT); k = kernel name (labels).
 * Args: rdi = data, rsi = validity, rdx = n, ecx = op, r8 = &a, r9 = &b,
 *       8(%rsp) = out_idx (MODE_FILTER).
 * [check] The op is checked first (unsigned compare, so negative ints are
 * rejected too); an invalid op returns (size_t)-1 before a or b is touched.
 * b is read only for BETWEEN; a always (also for n == 0). count without
 * validity first runs vcnt128_<kind> over n & ~3 rows.
 * Driver registers: pqk_x86_common.h section 6; r15 = vop128_* routine,
 * ymm8-12 = constants (see above), ymm4 = row-base dwords and ymm5 =
 * bcast(8) for EMIT_IDX_COMPRESS8.
 * [main] per 64-row block: mask & validity word; filter emits like
 * filter_i64 (compress steps for full blocks with any hit, tzcnt/blsr
 * otherwise); count popcnts. [tail] the last block runs through the same
 * loop. [result] count; vzeroupper.
 * ---------------------------------------------------------------------- */
.macro VDRIVER128 mode, k
        DRV_ENTER PQK_OP_LAST, .L\k\()_inval            /* [check] */
        vpbroadcastq c_i64min(%rip), %ymm12
        cmp     $PQK_BETWEEN, %ecx
        jne     .L\k\()_a
        vpbroadcastq (%r9), %ymm10      /* b (BETWEEN only) */
        vpbroadcastq 8(%r9), %ymm11
        vpxor   %ymm12, %ymm10, %ymm10
.L\k\()_a:
        vpbroadcastq (%r8), %ymm8       /* a */
        vpbroadcastq 8(%r8), %ymm9
        vpxor   %ymm12, %ymm8, %ymm8
        RANGE128_SETUP \k
        JTAB_LOAD vop128_table, %r15
        DRV_ARGS
        xor     %r8d, %r8d              /* VOP128F back-off countdown */
        mov     $QR_BACKOFF, %r9d       /* and length (a, b no longer needed) */
.if \mode == MODE_FILTER
        vpbroadcastd c_eight_d(%rip), %ymm5
.endif
.if \mode == MODE_COUNT
        test    %r13, %r13              /* no validity: direct counter */
        jnz     .L\k\()_start
        cmp     $4, %r14
        jb      .L\k\()_start
        mov     %r14, %rdx
        and     $-4, %rdx
        JTAB_LOAD vcnt128_table, %r10
        mov     %r12, %rdi
        call    *%r10                   /* rax = raw kind count; rcx, rdx kept */
        lea     vop_inv(%rip), %r10
        cmpb    $0, (%r10,%rcx)
        je      .L\k\()_noinv
        neg     %rax
        add     %rdx, %rax
.L\k\()_noinv:
        mov     %rax, %rbx
        shl     $4, %rdx
        add     %rdx, %r12
        shr     $4, %rdx
        sub     %rdx, %r14
.endif
.L\k\()_start:
        test    %r14, %r14
        jz      .L\k\()_result
.L\k\()_main:                                           /* [main] + [tail] */
        DRV_MASK
        DRV_VALIDITY
.if \mode == MODE_FILTER
        cmp     $64, %r14
        jb      .L\k\()_sparse
        test    %rax, %rax
        jz      .L\k\()_next
        EMIT_IDX_COMPRESS8
        jmp     .L\k\()_next
.L\k\()_sparse:
        EMIT_IDX_BITS %rax
.L\k\()_next:
        add     $64, %rbx
.else
        popcnt  %rax, %rax
        add     %rax, %rbx
.endif
        DRV_NEXT 1024, .L\k\()_main
.L\k\()_result:                                         /* [result] */
        DRV_LEAVE \mode
        VRET
.L\k\()_inval:
        OP_INVALID
.endm

#endif /* PQK_X86_AVX2_H */
