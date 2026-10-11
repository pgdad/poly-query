/*
 * pqk_x86_avx512.h — building blocks of the x86_avx512 variant that are
 * used by more than one of its kernels (included by pqk_x86_avx512.S only).
 * Requires pqk_x86_common.h and pqk_x86_simd.h. Emits nothing by itself.
 * Only AVX-512 F/BW/VL/DQ (+ BMI1/BMI2/POPCNT) instructions are used.
 *
 *   LANES8, PEELMASK, GROUPMASK     lane masks for 8-row groups / peel
 *   KPRED, KOP, KCNT                i64 predicates / mask routines /
 *                                   direct counters
 *   EMIT_IDX_COMPRESS16             vpcompressd index emission
 *   KDRIVER                         filter_i64 / _bitmap / count_i64
 *   ZBOP, ZBITOP                    bitmap and / or / andnot
 *   LG128, LGU128, KFIX, GLANES,    128-bit groups and predicates
 *   KP128, KOP128, KCNT128,         (filter_i128 / count_i128; LG128 and
 *   KDRIVER128                       GLANES also minmax_i128)
 *
 * Hot loops use plain loads; masked loads appear only in tails: zero-masked
 * loads (and merge-masked ops with a memory operand) measured up to 2.5x
 * slower when streaming from DRAM on Zen 5. AVX-512 masked loads suppress
 * faults on masked-off elements architecturally, so tails are vector code
 * that never touches memory past a buffer.
 */
#ifndef PQK_X86_AVX512_H
#define PQK_X86_AVX512_H

/* ------------------------------------------------------------------------
 * LANES8 cnt, dst      dst (32-bit gpr) = (1 << min(cnt, 8)) - 1.
 * PEELMASK rem, h, h32, t
 *     alignment peel of the no-validity streaming loops: h = number of
 *     leading rows (0..7) until rdi is 64-byte aligned, capped at rem; 0 if
 *     rdi is not 8-byte aligned (then no row boundary is 64-byte aligned).
 *     k1 = lanes < h. \t must hold 0 on entry. clobbers h, t, flags;
 *     ZF set iff h == 0. Aligned 64-byte loads measured up to 25% faster
 *     when streaming from DRAM (malloc returns 16 mod 64).
 * GROUPMASK
 *     k1 = lane mask of the next 8-row group = (8 lanes, limited to the
 *     remaining rows r10) & validity byte (rsi) if rsi != 0; eax = the
 *     same mask. clobbers eax, edx.
 * ---------------------------------------------------------------------- */
.macro LANES8 cnt, dst
        mov     $0xff, \dst
        bzhi    \cnt, \dst, \dst
.endm

.macro PEELMASK rem, h, h32, t
        mov     %edi, \h32
        neg     \h32
        and     $63, \h32
        shr     $3, \h32
        test    $7, %dil
        cmovnz  \t, \h32               /* \t must hold 0 */
        cmp     \rem, \h
        cmova   \rem, \h
        mov     $0xff, \t
        bzhi    \h32, \t, \t
        kmovb   \t, %k1
        test    \h32, \h32
.endm

.macro GROUPMASK
        LANES8  %r10d, %eax
        test    %rsi, %rsi
        jz      .Lgm_set\@
        movzbl  (%rsi), %edx
        and     %edx, %eax
.Lgm_set\@:
        kmovb   %eax, %k1
.endm

/* ------------------------------------------------------------------------
 * i64 predicates. vpcmpq writes k-masks directly; with x in memory as the
 * second operand the predicate is written as "a OP' x" (imm):
 *     EQ: a==x(0)  NE: a!=x(4)  LT: a>x(6)  LE: a>=x(5)  GT: a<x(1)
 *     GE: a<=x(2)  BETWEEN (imm 99): a<=x (2), then masked b>=x (5).
 * KPRED imm, src, k[, wm]: \k = predicate of the 8 qwords at src
 *     (memory or zmm0), zmm8/zmm9 = bcast a/b; wm = optional write mask
 *     ({%kN}). BETWEEN loads src into zmm0 once (a k-masked compare with a
 *     memory operand is slow). clobbers zmm0 (BETWEEN).
 * ---------------------------------------------------------------------- */
.macro KPRED imm, src, k, wm=none
.if \imm == 99
  .ifnc \src, %zmm0
        vmovdqu64 \src, %zmm0                  /* load once: a k-masked compare */
  .endif                                        /* with a memory operand is slow */
  .ifc \wm, none
        vpcmpq  $2, %zmm0, %zmm8, \k
  .else
        vpcmpq  $2, %zmm0, %zmm8, \k\wm
  .endif
        vpcmpq  $5, %zmm0, %zmm9, \k{\k}
.else
  .ifc \wm, none
        vpcmpq  $\imm, \src, %zmm8, \k
  .else
        vpcmpq  $\imm, \src, %zmm8, \k\wm
  .endif
.endif
.endm

/* KOP name, imm: emits mask routine `name` (driver convention):
 * in rdi = block ptr, esi = len (1..64), zmm8/zmm9 = bcast a/b.
 * out rax = mask with exactly len bits. clobbers rcx, rdx, rdi, rsi,
 * k1-k4, zmm0.
 * [main] full block: 8 compares whose 8-bit masks are merged with
 * kunpckbw/wd/dq into one 64-bit mask (kmovq).
 * [tail] partial block: 8-row groups with zero-masked loads (vmovdqu64
 * {z}), kmovb + shlx; nothing past the buffer is touched. */
.macro KOP name, imm
LFUNC \name
        cmp     $64, %esi
        jne     .L\name\()_part
        KPRED   \imm, 0(%rdi), %k1
        KPRED   \imm, 64(%rdi), %k2
        kunpckbw %k1, %k2, %k1
        KPRED   \imm, 128(%rdi), %k2
        KPRED   \imm, 192(%rdi), %k3
        kunpckbw %k2, %k3, %k2
        kunpckwd %k1, %k2, %k1
        KPRED   \imm, 256(%rdi), %k2
        KPRED   \imm, 320(%rdi), %k3
        kunpckbw %k2, %k3, %k2
        KPRED   \imm, 384(%rdi), %k3
        KPRED   \imm, 448(%rdi), %k4
        kunpckbw %k3, %k4, %k3
        kunpckwd %k2, %k3, %k2
        kunpckdq %k1, %k2, %k1
        kmovq   %k1, %rax
        ret
.L\name\()_part:
        xor     %eax, %eax
        xor     %ecx, %ecx
.L\name\()_grp:
        LANES8  %esi, %edx
        kmovb   %edx, %k4
        vmovdqu64 (%rdi), %zmm0{%k4}{z}
        KPRED   \imm, %zmm0, %k1, {%k4}
        kmovb   %k1, %edx
        shlx    %rcx, %rdx, %rdx
        or      %rdx, %rax
        add     $64, %rdi
        add     $8, %ecx
        sub     $8, %esi
        jg      .L\name\()_grp
        ret
ENDF \name
.endm

/* KCNT name, imm: direct counter for count_i64 without validity.
 * in rdi = data, rdx = rows (>= 1), zmm8/zmm9 = bcast a/b. out rax = count.
 * Alignment peel (masked, PEELMASK), 32 rows per step: vpcmpq -> k,
 * merge-masked "acc -= -1" (no kmov/popcnt), then masked 8-row tail
 * groups. clobbers rcx, rdx, rdi, r10, r11, zmm0, zmm3-zmm7, k1-k4. */
.macro KCNT name, imm
LFUNC \name
        vpxorq  %zmm4, %zmm4, %zmm4
        vpxorq  %zmm5, %zmm5, %zmm5
        vpxorq  %zmm6, %zmm6, %zmm6
        vpxorq  %zmm7, %zmm7, %zmm7
        vpternlogd $0xff, %zmm3, %zmm3, %zmm3   /* all ones = -1 */
        xor     %r11d, %r11d
        PEELMASK %rdx, %rcx, %ecx, %r11d
        jz      .L\name\()_main
        vmovdqu64 (%rdi), %zmm0{%k1}{z}
        kmovb   %k1, %k4
        KPRED   \imm, %zmm0, %k1, {%k4}
        vpsubq  %zmm3, %zmm4, %zmm4{%k1}
        lea     (%rdi,%rcx,8), %rdi
        sub     %rcx, %rdx
.L\name\()_main:
        cmp     $32, %rdx
        jb      .L\name\()_tail
        KPRED   \imm, 0(%rdi), %k1
        KPRED   \imm, 64(%rdi), %k2
        KPRED   \imm, 128(%rdi), %k3
        KPRED   \imm, 192(%rdi), %k4
        vpsubq  %zmm3, %zmm4, %zmm4{%k1}
        vpsubq  %zmm3, %zmm5, %zmm5{%k2}
        vpsubq  %zmm3, %zmm6, %zmm6{%k3}
        vpsubq  %zmm3, %zmm7, %zmm7{%k4}
        add     $256, %rdi
        sub     $32, %rdx
        jmp     .L\name\()_main
.L\name\()_tail:
        test    %rdx, %rdx
        jz      .L\name\()_sum
        LANES8  %edx, %r10d
        kmovb   %r10d, %k4
        vmovdqu64 (%rdi), %zmm0{%k4}{z}
        KPRED   \imm, %zmm0, %k1, {%k4}
        vpsubq  %zmm3, %zmm5, %zmm5{%k1}
        add     $64, %rdi
        sub     $8, %rdx
        jg      .L\name\()_tail
.L\name\()_sum:
        vpaddq  %zmm5, %zmm4, %zmm4
        vpaddq  %zmm7, %zmm6, %zmm6
        vpaddq  %zmm6, %zmm4, %zmm4
        HSUMZ   %zmm4, %ymm4, %xmm4, %ymm0, %xmm0, %rax
        ret
ENDF \name
.endm

/* ------------------------------------------------------------------------
 * EMIT_IDX_COMPRESS16: emit the indices of a full 64-row block mask (rax)
 * with vpcompressd, 16 rows per step (zmm of row indices, store 64 bytes,
 * advance by popcnt): branch-free, so no mispredicts on varying
 * selectivity. The 64-byte store stays inside out_idx[0..n) because
 * outputs so far <= rows consumed (full blocks only).
 * in: rax = mask, ebx = row base, rbp = out, zmm5 = iota16, zmm6 =
 * bcast(16). clobbers rax, rcx, zmm0, zmm4, k1.
 * ---------------------------------------------------------------------- */
.macro EMIT_IDX_COMPRESS16
        vpbroadcastd %ebx, %zmm4
        vpaddd  %zmm5, %zmm4, %zmm4
        .rept 4
        kmovw   %eax, %k1
        vpcompressd %zmm4, %zmm0{%k1}{z}
        vmovdqu32 %zmm0, (%rbp)
        movzwl  %ax, %ecx
        popcnt  %ecx, %ecx
        lea     (%rbp,%rcx,4), %rbp
        vpaddd  %zmm6, %zmm4, %zmm4
        shr     $16, %rax
        .endr
.endm

/* ------------------------------------------------------------------------
 * KDRIVER mode, k: body of filter_i64 (MODE_FILTER), filter_i64_bitmap
 * (MODE_BITMAP) and count_i64 (MODE_COUNT); k = kernel name (labels).
 * Args: rdi = data, rsi = validity, rdx = n, ecx = op, r8 = a, r9 = b,
 *       8(%rsp) = out (MODE_FILTER, MODE_BITMAP).
 * Driver registers: pqk_x86_common.h section 6; r15 = kop_* routine,
 * zmm8/9 = bcast a/b, zmm4 = row indices, zmm5 = iota, zmm6 = bcast(16).
 * [check] OP_CHECK; n == 0 skips the block loop. count without validity
 * runs only the direct counter kcnt_<op> (all rows, masked tail groups).
 * [main] 64-row blocks: mask, & validity word, consume: filter:
 * EMIT_IDX_COMPRESS16 for full blocks, tzcnt/blsr (EMIT_IDX_BITS) for the
 * last; bitmap: popcnt + 8-byte store; count: popcnt.
 * [tail] the last block (len < 64) runs through the same loop.
 * [result] index count / set-bit count; vzeroupper.
 * ---------------------------------------------------------------------- */
.macro KDRIVER mode, k
        DRV_ENTER PQK_OP_LAST, .L\k\()_inval            /* [check] */
        JTAB_LOAD kop_table, %r15
        vpbroadcastq %r8, %zmm8
        vpbroadcastq %r9, %zmm9
        DRV_ARGS
.if \mode == MODE_FILTER
        vmovdqu32 iota16(%rip), %zmm5
        vpbroadcastd c_sixteen_d(%rip), %zmm6
.endif
.if \mode == MODE_COUNT
        test    %r13, %r13              /* no validity: direct counter */
        jnz     .L\k\()_start
        test    %r14, %r14
        jz      .L\k\()_start
        JTAB_LOAD kcnt_table, %r10
        mov     %r12, %rdi
        mov     %r14, %rdx
        call    *%r10
        mov     %rax, %rbx
        jmp     .L\k\()_result
.L\k\()_start:
.endif
        test    %r14, %r14
        jz      .L\k\()_result
.L\k\()_main:                                           /* [main] + [tail] */
        DRV_MASK
        DRV_VALIDITY
.if \mode == MODE_FILTER
        cmp     $64, %r14
        jb      .L\k\()_sparse
        EMIT_IDX_COMPRESS16
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
 * ZBITOP k, vop, neg: body of bitmap and/or/andnot (a = rdi, b = rsi,
 * out = rdx, nbytes = rcx); k = kernel name. [main] 256 bytes per
 * iteration (4 zmm; loads before stores, so out may alias a or b).
 * [tail] 64-byte steps, then one byte-masked step (vmovdqu8 with k1 = low
 * rem bits; fault suppressing).
 * ZBOP neg, vop, off, reg[, km]: reg = a[off] vop b[off] (neg: a & ~b),
 * km = optional {%k1}{z} load mask. clobbers zmm7.
 * clobbers rax, rcx, rdx, rsi, rdi, zmm0-zmm3, zmm7, k1.
 * ---------------------------------------------------------------------- */
.macro ZBOP neg, vop, off, reg, km=
.if \neg
        vmovdqu8 \off(%rsi), \reg\km
        vmovdqu8 \off(%rdi), %zmm7\km
        vpandnq %zmm7, \reg, \reg               /* ~b & a */
.else
        vmovdqu8 \off(%rdi), \reg\km
        vmovdqu8 \off(%rsi), %zmm7\km
        \vop    %zmm7, \reg, \reg
.endif
.endm

.macro ZBITOP k, vop, neg
        cmp     $256, %rcx              /* [check] none: nbytes may be 0 */
        jb      .L\k\()_tail
.L\k\()_main:                           /* [main] 256 bytes */
        ZBOP    \neg, \vop, 0, %zmm0
        ZBOP    \neg, \vop, 64, %zmm1
        ZBOP    \neg, \vop, 128, %zmm2
        ZBOP    \neg, \vop, 192, %zmm3
        vmovdqu8 %zmm0, (%rdx)
        vmovdqu8 %zmm1, 64(%rdx)
        vmovdqu8 %zmm2, 128(%rdx)
        vmovdqu8 %zmm3, 192(%rdx)
        add     $256, %rdi
        add     $256, %rsi
        add     $256, %rdx
        sub     $256, %rcx
        cmp     $256, %rcx
        jae     .L\k\()_main
.L\k\()_tail:                           /* [tail] 64 bytes */
        cmp     $64, %rcx
        jb      .L\k\()_bytes
        ZBOP    \neg, \vop, 0, %zmm0
        vmovdqu8 %zmm0, (%rdx)
        add     $64, %rdi
        add     $64, %rsi
        add     $64, %rdx
        sub     $64, %rcx
        jmp     .L\k\()_tail
.L\k\()_bytes:                          /* < 64 bytes, byte-masked */
        test    %rcx, %rcx
        jz      .L\k\()_result
        mov     $-1, %rax
        bzhi    %rcx, %rax, %rax
        kmovq   %rax, %k1
        ZBOP    \neg, \vop, 0, %zmm0, {%k1}{z}
        vmovdqu8 %zmm0, (%rdx){%k1}
.L\k\()_result:                         /* [result] */
        VRET
.endm

/* ========================================================================
 * 128-bit groups. A "group" is 8 rows = two 64-byte loads
 * Z0 = [lo0 hi0 .. lo3 hi3], Z1 = [lo4 hi4 .. lo7 hi7].
 * AVX-512 has unsigned compares, so signed 128-bit
 *   x < c  <=>  (x.hi <s c.hi) | (x.hi == c.hi & x.lo <u c.lo)
 * is vpcmpq + vpcmpq + vpcmpuq{masked} + korb.
 * ====================================================================== */

/* LG128 off[, k0, k1]: load the group at off(%rdi) into zmm0 = L, zmm1 = H
 * in natural row order (vpermt2q with zmm14 = c_idx_even, zmm15 =
 * c_idx_odd); zmm2 scratch. With k0/k1: zero-masked loads of the halves. */
.macro LG128 off, k0=, k1=
.ifb \k0
        vmovdqu64 \off(%rdi), %zmm0
        vmovdqu64 \off+64(%rdi), %zmm2
.else
        vmovdqu64 \off(%rdi), %zmm0{\k0}{z}
        vmovdqu64 \off+64(%rdi), %zmm2{\k1}{z}
.endif
        vmovdqa64 %zmm0, %zmm1
        vpermt2q %zmm2, %zmm14, %zmm0           /* L */
        vpermt2q %zmm2, %zmm15, %zmm1           /* H */
.endm

/* LGU128 off[, k0, k1]: like LG128 but with in-lane vpunpck{l,h}qdq, which
 * is cheaper than vpermt2q (count -12%, filter -5% measured) and leaves the
 * rows in lane order (0, 4, 1, 5, 2, 6, 3, 7): row j < 4 in lane 2j, row
 * j + 4 in lane 2j + 1. Used by filter/count, whose masks are reordered with
 * KFIX (counts need no fix). */
.macro LGU128 off, k0=, k1=
.ifb \k0
        vmovdqu64 \off(%rdi), %zmm2
        vmovdqu64 \off+64(%rdi), %zmm1
.else
        vmovdqu64 \off(%rdi), %zmm2{\k0}{z}
        vmovdqu64 \off+64(%rdi), %zmm1{\k1}{z}
.endif
        vpunpcklqdq %zmm1, %zmm2, %zmm0         /* L */
        vpunpckhqdq %zmm1, %zmm2, %zmm1         /* H */
.endm

/* KFIX m: reorder every byte of a 64-bit mask built from LGU128 groups from
 * lane order (0,4,1,5,2,6,3,7) to row order: the even bits (rows 0-3 of each
 * group) and odd bits (rows 4-7) are extracted with pext and deposited into
 * the low / high nibbles with pdep. clobbers rcx, rdx. */
.macro KFIX m
        movabs  $C_BITS_EVEN, %rcx
        pext    %rcx, \m, %rdx          /* rows 0-3 of each group */
        add     %rcx, %rcx              /* 0xaaaa... */
        pext    %rcx, \m, \m            /* rows 4-7 */
        movabs  $C_NIBBLE_LO, %rcx
        pdep    %rcx, %rdx, %rdx
        not     %rcx
        pdep    %rcx, \m, \m
        or      %rdx, \m
.endm

/* GLANES r: k4/k5 = lane masks for the first r (1..8) rows of a group
 * (2r qwords). in: \r (32-bit gpr, doubled on exit), clobbers edx. */
.macro GLANES r
        mov     $0xffff, %edx
        add     \r, \r                  /* clobbered: callers pass a copy */
        bzhi    \r, %edx, %edx
        kmovw   %edx, %k4
        kshiftrw $8, %k4, %k5
.endm

/* KP128 kind, k: predicate on L (zmm0) / H (zmm1) into \k (not k6/k7).
 * Constants: zmm8 = bcast a.lo, zmm9 = bcast a.hi, zmm10/zmm11 = b
 * (BETWEEN). Lane order is irrelevant here (lane-wise).
 * Kinds: 0 EQ, 1 LT (x < a), 2 GT (x > a), 3 IN (a <= x <= b); operators are
 * (kind, invert) = EQ (0,0) NE (0,1) LT (1,0) LE (2,1) GT (2,0) GE (1,1)
 * BETWEEN (3,0) (inversions: table kinv128). IN with a > b is empty
 * automatically. clobbers k6, k7. */
.macro KP128 kind, k
.if \kind == 0
        vpcmpq  $0, %zmm8, %zmm0, \k
        vpcmpq  $0, %zmm9, %zmm1, \k{\k}
.elseif \kind == 1
        vpcmpq  $0, %zmm9, %zmm1, %k7
        vpcmpuq $1, %zmm8, %zmm0, %k7{%k7}
        vpcmpq  $1, %zmm9, %zmm1, \k
        korb    %k7, \k, \k
.elseif \kind == 2
        vpcmpq  $0, %zmm9, %zmm1, %k7
        vpcmpuq $6, %zmm8, %zmm0, %k7{%k7}
        vpcmpq  $6, %zmm9, %zmm1, \k
        korb    %k7, \k, \k
.else
        vpcmpq  $0, %zmm9, %zmm1, %k7           /* x >= a */
        vpcmpuq $5, %zmm8, %zmm0, %k7{%k7}
        vpcmpq  $6, %zmm9, %zmm1, %k6
        korb    %k7, %k6, %k6
        vpcmpq  $0, %zmm11, %zmm1, %k7{%k6}     /* and x <= b */
        vpcmpuq $2, %zmm10, %zmm0, %k7{%k7}
        vpcmpq  $1, %zmm11, %zmm1, \k{%k6}
        korb    %k7, \k, \k
.endif
.endm

/* KOP128 name, kind, inv: emits mask routine `name` (driver convention):
 * in rdi = block ptr, esi = len (1..64), constants as above.
 * out rax = mask with exactly len bits.
 * clobbers rcx, rdx, rdi, rsi, r10, r11, k1-k7, zmm0-zmm2.
 * [main] full block: 8 groups (LGU128), k-masks merged with kunpckbw/wd/dq,
 * then KFIX. [tail] partial block: groups with zero-masked loads, kmovb +
 * shlx, KFIX, then bzhi to len. */
.macro KOP128 name, kind, inv
LFUNC \name
        cmp     $64, %esi
        jne     .L\name\()_part
        LGU128   0
        KP128   \kind, %k1
        LGU128   128
        KP128   \kind, %k2
        kunpckbw %k1, %k2, %k1
        LGU128   256
        KP128   \kind, %k2
        LGU128   384
        KP128   \kind, %k3
        kunpckbw %k2, %k3, %k2
        kunpckwd %k1, %k2, %k1
        LGU128   512
        KP128   \kind, %k2
        LGU128   640
        KP128   \kind, %k3
        kunpckbw %k2, %k3, %k2
        LGU128   768
        KP128   \kind, %k3
        LGU128   896
        KP128   \kind, %k4
        kunpckbw %k3, %k4, %k3
        kunpckwd %k2, %k3, %k2
        kunpckdq %k1, %k2, %k1
        kmovq   %k1, %rax
        KFIX    %rax
.if \inv
        not     %rax
.endif
        ret
.L\name\()_part:
        mov     %esi, %r10d
        xor     %eax, %eax
        xor     %ecx, %ecx
.L\name\()_grp:
        mov     $8, %edx
        cmp     %edx, %esi
        cmovb   %esi, %edx
        mov     %edx, %r11d
        GLANES  %r11d
        LGU128   0, %k4, %k5
        KP128   \kind, %k1
        kmovb   %k1, %edx
        shlx    %rcx, %rdx, %rdx
        or      %rdx, %rax
        sub     $-128, %rdi
        add     $8, %ecx
        sub     $8, %esi
        jg      .L\name\()_grp
        KFIX    %rax
.if \inv
        not     %rax
.endif
        bzhi    %r10, %rax, %rax
        ret
ENDF \name
.endm

/* KCNT128 name, kind: direct counter for count_i128 without validity.
 * in rdi = data, rdx = rows (>= 1). out rax = number of rows where the KIND
 * holds (inversion applied by the caller). Two groups per step: predicate
 * -> k, merge-masked "acc -= -1"; the last 1..15 rows use zero-masked
 * groups whose k is ANDed with the row mask (in LGU128 lane order).
 * clobbers rcx, rdx, rdi, r10, r11, zmm0-zmm5, k1-k7. */
.macro KCNT128 name, kind
LFUNC \name
        vpxorq  %zmm4, %zmm4, %zmm4
        vpxorq  %zmm5, %zmm5, %zmm5
        vpternlogd $0xff, %zmm3, %zmm3, %zmm3   /* all ones = -1 */
        mov     %rdx, %r10
.L\name\()_main:
        cmp     $16, %r10
        jb      .L\name\()_tail
        LGU128   0
        KP128   \kind, %k1
        vpsubq  %zmm3, %zmm4, %zmm4{%k1}
        LGU128   128
        KP128   \kind, %k2
        vpsubq  %zmm3, %zmm5, %zmm5{%k2}
        add     $256, %rdi
        sub     $16, %r10
        jmp     .L\name\()_main
.L\name\()_tail:
        test    %r10, %r10
        jz      .L\name\()_sum
        mov     $8, %ecx
        cmp     %rcx, %r10
        cmovb   %r10, %rcx
        mov     $0xff, %edx
        bzhi    %ecx, %edx, %edx        /* rows < r, in LGU128 lane order: */
        mov     $0x55, %eax
        pdep    %eax, %edx, %r11d       /* rows 0-3 -> lanes 0, 2, 4, 6 */
        shr     $4, %edx
        mov     $0xaa, %eax
        pdep    %eax, %edx, %edx        /* rows 4-7 -> lanes 1, 3, 5, 7 */
        or      %r11d, %edx
        kmovb   %edx, %k3
        GLANES  %ecx
        LGU128   0, %k4, %k5
        KP128   \kind, %k1
        kandb   %k3, %k1, %k1
        vpsubq  %zmm3, %zmm4, %zmm4{%k1}
        sub     $-128, %rdi
        sub     $8, %r10
        jg      .L\name\()_tail
.L\name\()_sum:
        vpaddq  %zmm5, %zmm4, %zmm4
        HSUMZ   %zmm4, %ymm4, %xmm4, %ymm0, %xmm0, %rax
        ret
ENDF \name
.endm

/* ------------------------------------------------------------------------
 * KDRIVER128 mode, k: body of filter_i128 (MODE_FILTER) / count_i128
 * (MODE_COUNT); k = kernel name (labels).
 * Args: rdi = data, rsi = validity, rdx = n, ecx = op, r8 = &a, r9 = &b,
 *       8(%rsp) = out_idx (MODE_FILTER).
 * [check] The op is checked first (unsigned compare, so negative ints are
 * rejected too); an invalid op returns (size_t)-1 before a or b is touched.
 * b is read only for BETWEEN; a always (also for n == 0). count without
 * validity runs only KCNT128 (inversion: rows - count, table kinv128).
 * Driver registers: pqk_x86_common.h section 6; r15 = kop128_* routine,
 * zmm8-11 = a/b constants, zmm4 = row indices, zmm5 = iota, zmm6 =
 * bcast(16).
 * [main] per 64-row block: mask & validity word; filter emits with
 * EMIT_IDX_COMPRESS16 for full blocks with a hit, tzcnt/blsr for the last
 * one; count popcnts. [tail] the last block runs through the same loop.
 * [result] count; vzeroupper.
 * ---------------------------------------------------------------------- */
.macro KDRIVER128 mode, k
        DRV_ENTER PQK_OP_LAST, .L\k\()_inval            /* [check] */
        JTAB_LOAD kop128_table, %r15
        cmp     $PQK_BETWEEN, %ecx
        jne     .L\k\()_a
        vpbroadcastq (%r9), %zmm10      /* b (BETWEEN only) */
        vpbroadcastq 8(%r9), %zmm11
.L\k\()_a:
        vpbroadcastq (%r8), %zmm8       /* a */
        vpbroadcastq 8(%r8), %zmm9
        DRV_ARGS
.if \mode == MODE_FILTER
        vmovdqu32 iota16(%rip), %zmm5
        vpbroadcastd c_sixteen_d(%rip), %zmm6
.endif
.if \mode == MODE_COUNT
        test    %r13, %r13              /* no validity: direct counter */
        jnz     .L\k\()_start
        test    %r14, %r14
        jz      .L\k\()_start
        JTAB_LOAD kcnt128_table, %r10
        mov     %r12, %rdi
        mov     %r14, %rdx
        push    %rcx
        call    *%r10
        pop     %rcx
        lea     kinv128(%rip), %r10
        cmpb    $0, (%r10,%rcx)
        je      .L\k\()_noinv
        neg     %rax
        add     %r14, %rax
.L\k\()_noinv:
        mov     %rax, %rbx
        jmp     .L\k\()_result
.L\k\()_start:
.endif
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
        EMIT_IDX_COMPRESS16
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

#endif /* PQK_X86_AVX512_H */
