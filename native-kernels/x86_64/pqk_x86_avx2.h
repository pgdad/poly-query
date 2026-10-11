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

/* filter: a full block with at least DENSE_MIN hits uses the compress step
 * (swept 1, 2, 3, 4, 8, 16: 1 is flattest across selectivities). */
#define DENSE_MIN 1

/* ------------------------------------------------------------------------
 * Predicate kinds: 0 EQ (x==a), 1 ALT (a>x), 2 XGT (x>a), 3 OUT (a>x | x>b).
 * VPRED kind, src, dst, tmp: vector form, ymm8 = bcast(a), ymm9 = bcast(b);
 *     src = memory or register; dst = all-ones / zero lanes.
 * ROWPRED kind: scalar form for one row, rdx = x, r8 = a, r9 = b
 *     -> r10 = 0/1; clobbers r11.
 * ---------------------------------------------------------------------- */
.macro VPRED kind, src, dst, tmp
.if \kind == 0
        vpcmpeqq \src, %ymm8, \dst
.elseif \kind == 1
        vpcmpgtq \src, %ymm8, \dst
.elseif \kind == 2
        vmovdqu \src, \dst
        vpcmpgtq %ymm8, \dst, \dst
.else
        vmovdqu \src, \tmp
        vpcmpgtq \tmp, %ymm8, \dst
        vpcmpgtq %ymm9, \tmp, \tmp
        vpor    \tmp, \dst, \dst
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
 * pdep spreads the 8 mask bits to bytes, imul 0xff turns them into byte
 * masks, pext packs the row positions 0..7; vpmovzxbd + row base (ymm4)
 * give 8 dwords, stored with one 32-byte store; rbp advances by popcnt.
 * The store never passes out_idx + 4n: outputs so far <= rows consumed and
 * only full blocks use this path. Bytes beyond the count are scratch.
 * in: rax = mask, ebx = row base, rbp = out, ymm5 = bcast(8).
 * clobbers rax, rcx, rdx, r10, r11, ymm0, ymm4.
 * ---------------------------------------------------------------------- */
.macro EMIT_IDX_COMPRESS8
        movabs  $C_BYTE_ONES, %r10
        movabs  $C_BYTE_IOTA, %r11
        vmovd   %ebx, %xmm4
        vpbroadcastd %xmm4, %ymm4
        .rept 8
        movzbl  %al, %ecx
        pdep    %r10, %rcx, %rdx        /* bit j -> byte j bit 0 */
        imul    $0xff, %rdx, %rdx       /* -> 0x00 / 0xff bytes */
        pext    %rdx, %r11, %rdx        /* packed positions of set bits */
        vmovq   %rdx, %xmm0
        vpmovzxbd %xmm0, %ymm0
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
        JTAB_LOAD vop_table, %r15
        vmovq   %r8, %xmm8
        vpbroadcastq %xmm8, %ymm8
        vmovq   %r9, %xmm9
        vpbroadcastq %xmm9, %ymm9
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

/* VCNT128 name, kind: direct counter for count_i128 without validity.
 * in rdi = data, rdx = rows (multiple of 4, > 0). out rax = number of rows
 * where the KIND holds (inversion applied by the caller); rcx, rdx kept.
 * Two groups per iteration on two accumulators (vpsubq of all-ones lanes).
 * clobbers rdi, r10, ymm0-ymm4, ymm6, ymm13-ymm15. */
.macro VCNT128 name, kind
LFUNC \name
        vpxor   %xmm4, %xmm4, %xmm4
        vpxor   %xmm6, %xmm6, %xmm6
        mov     %rdx, %r10
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
        JTAB_LOAD vop128_table, %r15
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
        DRV_ARGS
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
