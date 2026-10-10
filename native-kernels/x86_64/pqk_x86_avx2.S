/*
 * pqk_x86_avx2.S — PolyQuery native kernels, variant "x86_avx2".
 *
 * Requires AVX2 + BMI1 + BMI2 + POPCNT (checked by the dispatcher). All 16
 * kernels of pq_kernels.h as global symbols pqk_x86_avx2_<kernel>, System V
 * AMD64 ABI; every public function ends with vzeroupper.
 *
 * Design overview (details at each function):
 *  - Predicates (filter/bitmap/count/compare): blocks of 64 rows. A
 *    per-operator mask routine (vop_* / vcmp_*) turns one block into a 64-bit
 *    mask: 16 x (vpcmpeqq/vpcmpgtq on 4 qwords + vmovmskpd), the 4-bit pieces
 *    are shifted into place on two independent OR chains. Only "==" and ">"
 *    exist in AVX2, so every operator is mapped to (kind, invert):
 *        EQ:x==a  NE:!(x==a)  LT:a>x  LE:!(x>a)  GT:x>a  GE:!(a>x)
 *        BETWEEN: !(a>x | x>b)
 *    The final partial block uses whole vectors while >= 4 rows remain and
 *    scalar compares for the last 1..3 rows, then bzhi to len bits; nothing
 *    beyond the last element is ever loaded.
 *  - filter_i64 emits indices adaptively per 64-row block: sparse masks via
 *    tzcnt/blsr; dense masks (>= 16 hits) via an 8-row "compress" step:
 *    pdep/imul/pext turn the 8-bit mask into packed byte positions, which are
 *    widened (vpmovzxbd), offset by the row base and stored as 8 dwords; the
 *    output pointer then advances by popcnt. The 32-byte store never passes
 *    out_idx + 4*n because k (outputs so far) <= rows consumed.
 *  - count_i64 without validity accumulates the comparison masks directly
 *    (vpsubq of all-ones lanes) — no movmsk needed.
 *  - Validity in vector loops: the 64-bit validity word of a full block is
 *    broadcast and shifted per lane with vpsllvq so that the row's bit lands in
 *    the lane's sign bit. vblendvpd consumes that sign mask directly; for
 *    sums it is widened to a full lane mask (vpcmpgtq against zero) and ANDed
 *    with a plain load. vpmaskmovq/vmaskmovpd are deliberately NOT used: on
 *    Zen 5 they were up to 4x slower when streaming from DRAM, and AMD
 *    documents fault behaviour of masked-off elements as implementation
 *    dependent. Final partial blocks (< 64 rows) run scalar code.
 *  - sum_i64 is exact: per lane we accumulate S = sum(x) mod 2^64,
 *    HU = sum(x >>> 32) and N = number of negative x. With LU = sum of the low
 *    32-bit halves, sum(x) = HU*2^32 + LU - N*2^64 and LU = S - HU*2^32
 *    (mod 2^64, exact while < 2^64). Chunks of at most 2^28 rows keep HU and
 *    LU below 2^60; each chunk is folded into a 128-bit scalar total.
 *  - hash_i64: 64x64->64 multiply emulated with three vpmuludq.
 *
 * Internal helpers use custom conventions (documented at each helper); they
 * do not touch the stack apart from call/ret. No red zone is used.
 */

        .text

.macro FUNC name
        .globl \name
        .type \name, @function
        .p2align 5
\name:
.endm
.macro LFUNC name
        .type \name, @function
        .p2align 4
\name:
.endm
.macro ENDF name
        .size \name, . - \name
.endm

/* horizontal sum of 4 qwords: ymm \y (aliased xmm \x), temp xmm \t -> \r */
.macro HSUMQ y, x, t, r
        vextracti128 $1, \y, \t
        vpaddq  \t, \x, \x
        vpshufd $0x4e, \x, \t
        vpaddq  \t, \x, \x
        vmovq   \x, \r
.endm

        .section .rodata
        .p2align 5
/* vpsllvq counts: group g (rows 4g..4g+3) lane j -> 63-(4g+j), moving
 * validity bit 4g+j into the sign bit of lane j. */
shc:
        .set r, 0
        .rept 64
        .quad 63 - r
        .set r, r + 1
        .endr
c_eight_d:      .long 8
c_sign_d:       .long 0x80000000
c_fmix1_lo:     .quad 0xed558ccd
c_fmix1_hi:     .quad 0xff51afd7
c_fmix2_lo:     .quad 0x1a85ec53
c_fmix2_hi:     .quad 0xc4ceb9fe
c_pinf:         .quad 0x7ff0000000000000
c_ninf:         .quad 0xfff0000000000000
        .text

/* ------------------------------------------------------------------------
 * lvp: partial validity word. in: rsi = ptr, ecx = len (1..64); loads
 * exactly ceil(len/8) bytes. out: rax (bits >= len inside the last byte are
 * not cleared). clobbers rcx, rdx.
 * ---------------------------------------------------------------------- */
LFUNC lvp
        add     $7, %ecx
        shr     $3, %ecx
        xor     %eax, %eax
1:      shl     $8, %rax
        movzbl  -1(%rsi,%rcx), %edx
        or      %rdx, %rax
        dec     %ecx
        jnz     1b
        ret
ENDF lvp

/* ------------------------------------------------------------------------
 * Predicate kinds: 0 EQ (x==a), 1 ALT (a>x), 2 XGT (x>a), 3 OUT (a>x | x>b)
 * VPRED: vector form, ymm8 = bcast(a), ymm9 = bcast(b); src = mem or reg.
 * SPRED: scalar form, rdx = x, r8 = a, r9 = b -> r10 = 0/1, clobbers r11.
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

.macro SPRED kind
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
 * Mask routines vop_*: in rdi = block ptr, esi = len (1..64), r8/r9 = a/b,
 * ymm8/ymm9 = bcast a/b. out rax = mask with exactly len bits.
 * clobbers rcx, rdx, rdi, rsi, r10, r11, ymm0-ymm3.
 * ---------------------------------------------------------------------- */
.macro VOP name, kind, inv
LFUNC \name
        cmp     $64, %esi
        jne     .Lpart\@
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
.Lpart\@:
        xor     %eax, %eax
        xor     %ecx, %ecx              /* bit position */
        cmp     $4, %esi
        jb      .Lrows\@
.Lgrp\@:
        VPRED   \kind, (%rdi), %ymm0, %ymm1
        vmovmskpd %ymm0, %edx
        shlx    %rcx, %rdx, %rdx
        or      %rdx, %rax
        add     $32, %rdi
        add     $4, %ecx
        sub     $4, %esi
        cmp     $4, %esi
        jae     .Lgrp\@
.Lrows\@:
        test    %esi, %esi
        jz      .Lfin\@
.Lrow\@:
        mov     (%rdi), %rdx
        SPRED   \kind
        shlx    %rcx, %r10, %r10
        or      %r10, %rax
        add     $8, %rdi
        inc     %ecx
        dec     %esi
        jnz     .Lrow\@
.Lfin\@:
.if \inv
        not     %rax
.endif
        bzhi    %rcx, %rax, %rax        /* rcx == len here */
        ret
ENDF \name
.endm

        VOP vop_eq, 0, 0
        VOP vop_ne, 0, 1
        VOP vop_lt, 1, 0
        VOP vop_le, 2, 1
        VOP vop_gt, 2, 0
        VOP vop_ge, 1, 1
        VOP vop_bt, 3, 1

/* Direct counters for count_i64 without validity: in rdi = data,
 * rdx = rows (multiple of 16, > 0). out rax = number of rows where the KIND
 * holds (inversion applied by the caller). clobbers rdi, r10, ymm0-ymm7. */
.macro VCNT name, kind
LFUNC \name
        vpxor   %xmm4, %xmm4, %xmm4
        vpxor   %xmm5, %xmm5, %xmm5
        vpxor   %xmm6, %xmm6, %xmm6
        vpxor   %xmm7, %xmm7, %xmm7
        mov     %rdx, %r10
1:      VPRED   \kind, 0(%rdi), %ymm0, %ymm1
        vpsubq  %ymm0, %ymm4, %ymm4
        VPRED   \kind, 32(%rdi), %ymm2, %ymm3
        vpsubq  %ymm2, %ymm5, %ymm5
        VPRED   \kind, 64(%rdi), %ymm0, %ymm1
        vpsubq  %ymm0, %ymm6, %ymm6
        VPRED   \kind, 96(%rdi), %ymm2, %ymm3
        vpsubq  %ymm2, %ymm7, %ymm7
        sub     $-128, %rdi
        sub     $16, %r10
        jnz     1b
        vpaddq  %ymm5, %ymm4, %ymm4
        vpaddq  %ymm7, %ymm6, %ymm6
        vpaddq  %ymm6, %ymm4, %ymm4
        HSUMQ   %ymm4, %xmm4, %xmm0, %rax
        ret
ENDF \name
.endm

        VCNT vcnt_k0, 0
        VCNT vcnt_k1, 1
        VCNT vcnt_k2, 2
        VCNT vcnt_k3, 3

        .section .rodata
        .p2align 2
vop_table:
        .long   vop_eq - vop_table, vop_ne - vop_table, vop_lt - vop_table
        .long   vop_le - vop_table, vop_gt - vop_table, vop_ge - vop_table
        .long   vop_bt - vop_table
vcnt_table:
        .long   vcnt_k0 - vcnt_table, vcnt_k0 - vcnt_table, vcnt_k1 - vcnt_table
        .long   vcnt_k2 - vcnt_table, vcnt_k2 - vcnt_table, vcnt_k1 - vcnt_table
        .long   vcnt_k3 - vcnt_table
vop_inv:
        .byte   0, 1, 0, 1, 0, 1, 1
        .text

/* ------------------------------------------------------------------------
 * Predicate driver: mode 0 filter_i64, 1 filter_i64_bitmap, 2 count_i64.
 * Args: rdi=data rsi=validity rdx=n ecx=op r8=a r9=b [rsp+8]=out.
 * r12 = block data ptr, r13 = validity ptr (0 = all valid), r14 = rows
 * remaining, r15 = mask routine, rbx = row base (mode 0) / count (1, 2),
 * rbp = output ptr; (%rsp) = output start. ymm8/9 = bcast a/b,
 * ymm4 = row-base dwords and ymm5 = bcast(8) for the compress step.
 * ---------------------------------------------------------------------- */
#define DENSE_MIN 16

.macro PRED_DRIVER mode
        cmp     $6, %ecx
        ja      .Linval\@
        push    %rbx
        push    %rbp
        push    %r12
        push    %r13
        push    %r14
        push    %r15
        mov     56(%rsp), %rbp
        push    %rbp
        mov     %ecx, %ecx
        lea     vop_table(%rip), %rax
        movslq  (%rax,%rcx,4), %r15
        add     %rax, %r15
        vmovq   %r8, %xmm8
        vpbroadcastq %xmm8, %ymm8
        vmovq   %r9, %xmm9
        vpbroadcastq %xmm9, %ymm9
        mov     %rdi, %r12
        mov     %rsi, %r13
        mov     %rdx, %r14
        xor     %ebx, %ebx
.if \mode == 0
        vpbroadcastd c_eight_d(%rip), %ymm5
.endif
.if \mode == 2
        test    %r13, %r13
        jnz     .Lstart\@
        cmp     $16, %r14
        jb      .Lstart\@
        mov     %r14, %rdx
        and     $-16, %rdx
        lea     vcnt_table(%rip), %rax
        movslq  (%rax,%rcx,4), %r10
        add     %rax, %r10
        mov     %r12, %rdi
        call    *%r10                   /* rax = raw kind count; rcx, rdx kept */
        lea     vop_inv(%rip), %r10
        cmpb    $0, (%r10,%rcx)
        je      1f
        neg     %rax
        add     %rdx, %rax
1:      mov     %rax, %rbx
        lea     (%r12,%rdx,8), %r12
        sub     %rdx, %r14
.endif
.Lstart\@:
        test    %r14, %r14
        jz      .Ldone\@
.Lloop\@:
        mov     $64, %esi
        cmp     %rsi, %r14
        cmovb   %r14, %rsi
        mov     %r12, %rdi
        call    *%r15
        test    %r13, %r13
        jz      .Lvok\@
        cmp     $64, %r14
        jb      .Lvpart\@
        and     (%r13), %rax
        add     $8, %r13
        jmp     .Lvok\@
.Lvpart\@:
        mov     %rax, %r10
        mov     %r13, %rsi
        mov     %r14d, %ecx
        call    lvp
        and     %r10, %rax
.Lvok\@:
.if \mode == 0
        popcnt  %rax, %rcx
        cmp     $64, %r14
        jb      .Lsparse\@
        cmp     $DENSE_MIN, %ecx
        jb      .Lsparse\@
        /* dense: 8 x compress 8 rows */
        movabs  $0x0101010101010101, %r10
        movabs  $0x0706050403020100, %r11
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
        jmp     .Lnext\@
.Lsparse\@:
        test    %rax, %rax
        jz      .Lnext\@
.Lbits\@:
        tzcnt   %rax, %rcx
        add     %ebx, %ecx
        mov     %ecx, (%rbp)
        add     $4, %rbp
        blsr    %rax, %rax
        jnz     .Lbits\@
.Lnext\@:
        add     $64, %rbx
.elseif \mode == 1
        popcnt  %rax, %rcx
        add     %rcx, %rbx
        cmp     $64, %r14
        jb      .Lspart\@
        mov     %rax, (%rbp)
        add     $8, %rbp
        jmp     .Ladv\@
.Lspart\@:
        lea     7(%r14), %ecx
        shr     $3, %ecx
.Lsb\@: mov     %al, (%rbp)
        inc     %rbp
        shr     $8, %rax
        dec     %ecx
        jnz     .Lsb\@
.Ladv\@:
.else
        popcnt  %rax, %rax
        add     %rax, %rbx
.endif
        add     $512, %r12
        sub     $64, %r14
        ja      .Lloop\@
.Ldone\@:
.if \mode == 0
        mov     %rbp, %rax
        sub     (%rsp), %rax
        shr     $2, %rax
.else
        mov     %rbx, %rax
.endif
        pop     %rdx
        pop     %r15
        pop     %r14
        pop     %r13
        pop     %r12
        pop     %rbp
        pop     %rbx
        vzeroupper
        ret
.Linval\@:
        mov     $-1, %rax
        ret
.endm

/* size_t pqk_x86_avx2_filter_i64(data, validity, n, op, a, b, out_idx) */
FUNC pqk_x86_avx2_filter_i64
        PRED_DRIVER 0
ENDF pqk_x86_avx2_filter_i64

/* size_t pqk_x86_avx2_filter_i64_bitmap(data, validity, n, op, a, b, out_bits) */
FUNC pqk_x86_avx2_filter_i64_bitmap
        PRED_DRIVER 1
ENDF pqk_x86_avx2_filter_i64_bitmap

/* size_t pqk_x86_avx2_count_i64(data, validity, n, op, a, b) */
FUNC pqk_x86_avx2_count_i64
        PRED_DRIVER 2
ENDF pqk_x86_avx2_count_i64

/* ------------------------------------------------------------------------
 * Element-wise compare routines vcmp_*: in rdi = &a[block], rsi = &b[block],
 * edx = len (1..64). out rax = mask with exactly len bits.
 * kind 0: P == Q, kind 1: P > Q; (P, Q) = (a, b) or swapped; inv negates.
 * clobbers rcx, rdx, rdi, rsi, r10, r11, ymm0.
 * ---------------------------------------------------------------------- */
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
        jne     .Lpart\@
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
.Lpart\@:
        xor     %eax, %eax
        xor     %ecx, %ecx
        cmp     $4, %edx
        jb      .Lrows\@
.Lgrp\@:
        VCMPQ   \kind, 0, \P, \Q
        vmovmskpd %ymm0, %r10d
        shlx    %rcx, %r10, %r10
        or      %r10, %rax
        add     $32, %rdi
        add     $32, %rsi
        add     $4, %ecx
        sub     $4, %edx
        cmp     $4, %edx
        jae     .Lgrp\@
.Lrows\@:
        test    %edx, %edx
        jz      .Lfin\@
.Lrow\@:
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
        jnz     .Lrow\@
.Lfin\@:
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

        .section .rodata
        .p2align 2
vcmp_table:
        .long   vcmp_eq - vcmp_table, vcmp_ne - vcmp_table, vcmp_lt - vcmp_table
        .long   vcmp_le - vcmp_table, vcmp_gt - vcmp_table, vcmp_ge - vcmp_table
        .text

/* ------------------------------------------------------------------------
 * size_t pqk_x86_avx2_compare_i64(a=rdi, b=rsi, n=rdx, op=ecx, out=r8)
 * r12 = a block, r13 = b block, r14 = remaining, r15 = routine,
 * rbx = popcount total, rbp = out ptr.
 * ---------------------------------------------------------------------- */
FUNC pqk_x86_avx2_compare_i64
        cmp     $5, %ecx
        ja      .Lci_inval
        push    %rbx
        push    %rbp
        push    %r12
        push    %r13
        push    %r14
        push    %r15
        mov     %ecx, %ecx
        lea     vcmp_table(%rip), %rax
        movslq  (%rax,%rcx,4), %r15
        add     %rax, %r15
        mov     %rdi, %r12
        mov     %rsi, %r13
        mov     %rdx, %r14
        mov     %r8, %rbp
        xor     %ebx, %ebx
        test    %r14, %r14
        jz      .Lci_done
.Lci_loop:
        mov     $64, %edx
        cmp     %rdx, %r14
        cmovb   %r14, %rdx
        mov     %r12, %rdi
        mov     %r13, %rsi
        call    *%r15
        popcnt  %rax, %rcx
        add     %rcx, %rbx
        cmp     $64, %r14
        jb      .Lci_part
        mov     %rax, (%rbp)
        add     $8, %rbp
        add     $512, %r12
        add     $512, %r13
        sub     $64, %r14
        jnz     .Lci_loop
        jmp     .Lci_done
.Lci_part:
        lea     7(%r14), %ecx
        shr     $3, %ecx
1:      mov     %al, (%rbp)
        inc     %rbp
        shr     $8, %rax
        dec     %ecx
        jnz     1b
.Lci_done:
        mov     %rbx, %rax
        pop     %r15
        pop     %r14
        pop     %r13
        pop     %r12
        pop     %rbp
        pop     %rbx
        vzeroupper
        ret
.Lci_inval:
        mov     $-1, %rax
        ret
ENDF pqk_x86_avx2_compare_i64

/* ------------------------------------------------------------------------
 * int pqk_x86_avx2_sum_i64(data=rdi, validity=rsi, n=rdx, out_sum=rcx)
 * Lane accumulators (two sets for ILP): S ymm0/ymm1, HU ymm2/ymm3,
 * N ymm4/ymm5; temps ymm6/ymm7/ymm10/ymm11; ymm12 = bcast validity word,
 * ymm13 = per-group lane mask, ymm15 = zero. Scalar 128-bit total r9:r8 (hi:lo).
 * r10 = rows remaining, r11 = out_sum, r12 = rows/blocks left in chunk.
 * ---------------------------------------------------------------------- */
#ifndef SUM_CHUNK_ROWS                  /* overridable to test the fold path */
#define SUM_CHUNK_ROWS   (1 << 28)
#endif
#ifndef SUM_CHUNK_BLOCKS
#define SUM_CHUNK_BLOCKS (1 << 22)
#endif

.macro SACC x, set, t
.if \set == 0
        vpaddq  \x, %ymm0, %ymm0
        vpsrlq  $32, \x, \t
        vpaddq  \t, %ymm2, %ymm2
        vpsrlq  $63, \x, \x
        vpaddq  \x, %ymm4, %ymm4
.else
        vpaddq  \x, %ymm1, %ymm1
        vpsrlq  $32, \x, \t
        vpaddq  \t, %ymm3, %ymm3
        vpsrlq  $63, \x, \x
        vpaddq  \x, %ymm5, %ymm5
.endif
.endm

.macro SZERO
        vpxor   %xmm0, %xmm0, %xmm0
        vpxor   %xmm1, %xmm1, %xmm1
        vpxor   %xmm2, %xmm2, %xmm2
        vpxor   %xmm3, %xmm3, %xmm3
        vpxor   %xmm4, %xmm4, %xmm4
        vpxor   %xmm5, %xmm5, %xmm5
.endm

/* total(r9:r8) += HU*2^32 + (S - HU*2^32 mod 2^64) - N*2^64.
 * clobbers rax, rcx, rdx, rbx and the accumulators. */
.macro SFOLD
        vpaddq  %ymm1, %ymm0, %ymm0
        vpaddq  %ymm3, %ymm2, %ymm2
        vpaddq  %ymm5, %ymm4, %ymm4
        HSUMQ   %ymm0, %xmm0, %xmm6, %rax       /* S  */
        HSUMQ   %ymm2, %xmm2, %xmm6, %rcx       /* HU */
        HSUMQ   %ymm4, %xmm4, %xmm6, %rdx       /* N  */
        mov     %rcx, %rbx
        shl     $32, %rbx
        sub     %rbx, %rax                      /* LU */
        shr     $32, %rcx                       /* HU >> 32 (before the adds: shr clobbers CF) */
        add     %rax, %r8
        adc     $0, %r9
        add     %rbx, %r8
        adc     %rcx, %r9
        sub     %rdx, %r9
.endm

FUNC pqk_x86_avx2_sum_i64
        push    %rbx
        push    %r12
        xor     %r8d, %r8d
        xor     %r9d, %r9d
        mov     %rcx, %r11
        mov     %rdx, %r10
        test    %rsi, %rsi
        jnz     .Lsv
.Lsn_chunk:
        cmp     $8, %r10
        jb      .Lsn_tail
        mov     %r10, %r12
        and     $-8, %r12
        mov     $SUM_CHUNK_ROWS, %eax
        cmp     %rax, %r12
        cmova   %rax, %r12
        sub     %r12, %r10
        SZERO
1:      vmovdqu (%rdi), %ymm6
        vmovdqu 32(%rdi), %ymm7
        SACC    %ymm6, 0, %ymm10
        SACC    %ymm7, 1, %ymm11
        add     $64, %rdi
        sub     $8, %r12
        jnz     1b
        SFOLD
        jmp     .Lsn_chunk
.Lsn_tail:
        test    %r10, %r10
        jz      .Ls_fin
2:      mov     (%rdi), %rax
        cqo
        add     %rax, %r8
        adc     %rdx, %r9
        add     $8, %rdi
        dec     %r10
        jnz     2b
        jmp     .Ls_fin

.Lsv:
        SZERO
        vpxor   %xmm15, %xmm15, %xmm15
        xor     %r12d, %r12d
.Lsv_blk:
        cmp     $64, %r10
        jb      .Lsv_part
        vpbroadcastq (%rsi), %ymm12
        .set g, 0
        .rept 16
        vpsllvq shc+g*32(%rip), %ymm12, %ymm13
        vpcmpgtq %ymm13, %ymm15, %ymm13         /* 0 > m: full lane mask */
        vpand   g*32(%rdi), %ymm13, %ymm6
        SACC    %ymm6, (g % 2), %ymm10
        .set g, g + 1
        .endr
        add     $512, %rdi
        add     $8, %rsi
        sub     $64, %r10
        inc     %r12
        cmp     $SUM_CHUNK_BLOCKS, %r12
        jb      .Lsv_blk
        SFOLD
        SZERO
        xor     %r12d, %r12d
        jmp     .Lsv_blk
.Lsv_part:
        SFOLD
        test    %r10, %r10
        jz      .Ls_fin
        mov     %r10d, %ecx
        call    lvp
        mov     %rax, %rbx
3:      mov     (%rdi), %rax
        shr     $1, %rbx
        sbb     %rdx, %rdx
        and     %rdx, %rax
        cqo
        add     %rax, %r8
        adc     %rdx, %r9
        add     $8, %rdi
        dec     %r10
        jnz     3b
.Ls_fin:
        mov     %r8, %rax
        sar     $63, %rax
        cmp     %rax, %r9
        jne     .Ls_ovf
        mov     %r8, (%r11)
        xor     %eax, %eax
        jmp     .Ls_ret
.Ls_ovf:
        mov     $1, %eax
.Ls_ret:
        pop     %r12
        pop     %rbx
        vzeroupper
        ret
ENDF pqk_x86_avx2_sum_i64

/* ------------------------------------------------------------------------
 * double pqk_x86_avx2_sum_f64(data=rdi, validity=rsi, n=rdx)
 * 16 lane-wise partial sums in ymm0-ymm3 (+0.0 init), scalar tail sum in
 * xmm4. Invalid rows are ANDed to +0.0 bits (full vpcmpgtq lane mask from
 * the vpsllvq sign mask in full blocks, sbb mask in the partial block).
 * Final: ((ymm0+ymm1)+(ymm2+ymm3)) lanes, then + xmm4.
 * r10 = rows remaining, ymm12/13 validity, ymm15 zero, ymm6 temp.
 * ---------------------------------------------------------------------- */
FUNC pqk_x86_avx2_sum_f64
        vxorpd  %xmm0, %xmm0, %xmm0
        vxorpd  %xmm1, %xmm1, %xmm1
        vxorpd  %xmm2, %xmm2, %xmm2
        vxorpd  %xmm3, %xmm3, %xmm3
        vxorpd  %xmm4, %xmm4, %xmm4
        mov     %rdx, %r10
        test    %rsi, %rsi
        jnz     .Lfv
        cmp     $16, %r10
        jb      2f
1:      vaddpd  (%rdi), %ymm0, %ymm0
        vaddpd  32(%rdi), %ymm1, %ymm1
        vaddpd  64(%rdi), %ymm2, %ymm2
        vaddpd  96(%rdi), %ymm3, %ymm3
        sub     $-128, %rdi
        sub     $16, %r10
        cmp     $16, %r10
        jae     1b
2:      cmp     $4, %r10
        jb      3f
        vaddpd  (%rdi), %ymm0, %ymm0
        add     $32, %rdi
        sub     $4, %r10
        jmp     2b
3:      test    %r10, %r10
        jz      .Lf_red
        vaddsd  (%rdi), %xmm4, %xmm4
        add     $8, %rdi
        dec     %r10
        jmp     3b
.Lfv:
        vpxor   %xmm15, %xmm15, %xmm15
.Lfv_blk:
        cmp     $64, %r10
        jb      .Lfv_part
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
        jmp     .Lfv_blk
.Lfv_part:
        test    %r10, %r10
        jz      .Lf_red
        mov     %r10d, %ecx
        call    lvp
4:      mov     (%rdi), %rdx
        shr     $1, %rax
        sbb     %r11, %r11
        and     %r11, %rdx
        vmovq   %rdx, %xmm5
        vaddsd  %xmm5, %xmm4, %xmm4
        add     $8, %rdi
        dec     %r10
        jnz     4b
.Lf_red:
        vaddpd  %ymm1, %ymm0, %ymm0
        vaddpd  %ymm3, %ymm2, %ymm2
        vaddpd  %ymm2, %ymm0, %ymm0
        vextractf128 $1, %ymm0, %xmm1
        vaddpd  %xmm1, %xmm0, %xmm0
        vunpckhpd %xmm0, %xmm0, %xmm1
        vaddsd  %xmm1, %xmm0, %xmm0
        vaddsd  %xmm4, %xmm0, %xmm0
        vzeroupper
        ret
ENDF pqk_x86_avx2_sum_f64

/* ------------------------------------------------------------------------
 * size_t pqk_x86_avx2_minmax_i64(data=rdi, validity=rsi, n=rdx,
 *                                out_min=rcx, out_max=r8)
 * min accs ymm0/ymm2, max accs ymm1/ymm3 (no 64-bit min/max in AVX2:
 * vpcmpgtq + vblendvpd). With validity the compare result is ANDed with the
 * vpsllvq sign mask (blendv only looks at sign bits).
 * Scalar tail: r12 = lo, r13 = hi; r14 = count; r9/r11 = INT64_MAX/MIN;
 * r10 = remaining; rbx = validity bits.
 * ---------------------------------------------------------------------- */
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

FUNC pqk_x86_avx2_minmax_i64
        push    %rbx
        push    %r12
        push    %r13
        push    %r14
        movabs  $0x7fffffffffffffff, %r9
        movabs  $0x8000000000000000, %r11
        mov     %r9, %r12
        mov     %r11, %r13
        vmovq   %r9, %xmm0
        vpbroadcastq %xmm0, %ymm0
        vmovdqa %ymm0, %ymm2
        vmovq   %r11, %xmm1
        vpbroadcastq %xmm1, %ymm1
        vmovdqa %ymm1, %ymm3
        xor     %r14d, %r14d
        mov     %rdx, %r10
        test    %rsi, %rsi
        jnz     .Lmv
        mov     %r10, %r14
        cmp     $8, %r10
        jb      2f
1:      vmovdqu (%rdi), %ymm4
        vmovdqu 32(%rdi), %ymm5
        MMI_STEP %ymm4, %ymm0, %ymm1, none
        MMI_STEP %ymm5, %ymm2, %ymm3, none
        add     $64, %rdi
        sub     $8, %r10
        cmp     $8, %r10
        jae     1b
2:      test    %r10, %r10
        jz      .Lm_red
3:      mov     (%rdi), %rax
        cmp     %rax, %r12
        cmovg   %rax, %r12
        cmp     %rax, %r13
        cmovl   %rax, %r13
        add     $8, %rdi
        dec     %r10
        jnz     3b
        jmp     .Lm_red
.Lmv:
        cmp     $64, %r10
        jb      .Lmv_part
        popcnt  (%rsi), %rax
        add     %rax, %r14
        vpbroadcastq (%rsi), %ymm12
        .set g, 0
        .rept 16
        vpsllvq shc+g*32(%rip), %ymm12, %ymm13
        vmovdqu g*32(%rdi), %ymm4
        .if g % 2
        MMI_STEP %ymm4, %ymm2, %ymm3, %ymm13
        .else
        MMI_STEP %ymm4, %ymm0, %ymm1, %ymm13
        .endif
        .set g, g + 1
        .endr
        add     $512, %rdi
        add     $8, %rsi
        sub     $64, %r10
        jmp     .Lmv
.Lmv_part:
        test    %r10, %r10
        jz      .Lm_red
        push    %rcx                    /* lvp clobbers rcx (out_min) */
        mov     %r10d, %ecx
        call    lvp
        pop     %rcx
        mov     %rax, %rbx
4:      mov     (%rdi), %rax
        mov     %rax, %rdx
        shr     $1, %rbx
        cmovnc  %r9, %rax
        cmovnc  %r11, %rdx
        adc     $0, %r14
        cmp     %rax, %r12
        cmovg   %rax, %r12
        cmp     %rdx, %r13
        cmovl   %rdx, %r13
        add     $8, %rdi
        dec     %r10
        jnz     4b
.Lm_red:
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
        jz      5f
        mov     %r12, (%rcx)
        mov     %r13, (%r8)
5:      pop     %r14
        pop     %r13
        pop     %r12
        pop     %rbx
        vzeroupper
        ret
ENDF pqk_x86_avx2_minmax_i64

/* ------------------------------------------------------------------------
 * size_t pqk_x86_avx2_minmax_f64(data=rdi, validity=rsi, n=rdx,
 *                                out_min=rcx, out_max=r8)
 * min accs ymm0/ymm2 (+inf), max accs ymm1/ymm3 (-inf); per lane
 * vminpd(acc, x) keeps "x < acc ? x : acc" like the reference. Invalid lanes
 * are replaced by +inf / -inf via vblendvpd on the vpsllvq sign mask.
 * Scalar tail accumulators xmm10 (lo) / xmm11 (hi).
 * Signed zero: lanes merge in a different order than the sequential scan, so
 * if the final min (max) compares equal to 0.0 it is replaced by the first
 * valid zero of the column (exactly what the reference returns in that case).
 * r14 = count, r10 = remaining, rbx = validity bits, r12 = saved data,
 * r13 = saved validity, r15 = saved n, ymm14/15 = +inf/-inf.
 * ---------------------------------------------------------------------- */
FUNC pqk_x86_avx2_minmax_f64
        push    %rbx
        push    %r12
        push    %r13
        push    %r14
        push    %r15
        mov     %rdi, %r12
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
        jnz     .Lfm_v
        mov     %r10, %r14
        cmp     $8, %r10
        jb      2f
1:      vmovupd (%rdi), %ymm4
        vmovupd 32(%rdi), %ymm5
        vminpd  %ymm0, %ymm4, %ymm0
        vmaxpd  %ymm1, %ymm4, %ymm1
        vminpd  %ymm2, %ymm5, %ymm2
        vmaxpd  %ymm3, %ymm5, %ymm3
        add     $64, %rdi
        sub     $8, %r10
        cmp     $8, %r10
        jae     1b
2:      test    %r10, %r10
        jz      .Lfm_red
3:      vmovsd  (%rdi), %xmm4
        vminsd  %xmm10, %xmm4, %xmm10
        vmaxsd  %xmm11, %xmm4, %xmm11
        add     $8, %rdi
        dec     %r10
        jnz     3b
        jmp     .Lfm_red
.Lfm_v:
        cmp     $64, %r10
        jb      .Lfm_vpart
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
        jmp     .Lfm_v
.Lfm_vpart:
        test    %r10, %r10
        jz      .Lfm_red
        push    %rcx
        mov     %r10d, %ecx
        call    lvp
        pop     %rcx
        mov     %rax, %rbx
4:      shr     $1, %rbx
        jnc     5f
        inc     %r14
        vmovsd  (%rdi), %xmm4
        vminsd  %xmm10, %xmm4, %xmm10
        vmaxsd  %xmm11, %xmm4, %xmm11
5:      add     $8, %rdi
        dec     %r10
        jnz     4b
.Lfm_red:
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
        jz      .Lfm_ret
        /* signed-zero fix-up */
        vxorpd  %xmm5, %xmm5, %xmm5
        xor     %r9d, %r9d              /* bit0: min==0, bit1: max==0 */
        vucomisd %xmm5, %xmm0
        jne     6f
        or      $1, %r9d
6:      vucomisd %xmm5, %xmm1
        jne     7f
        or      $2, %r9d
7:      test    %r9d, %r9d
        jz      .Lfm_store
        xor     %r10d, %r10d            /* row index */
8:      test    %r13, %r13
        jz      9f
        mov     %r10, %rax
        shr     $3, %rax
        movzbl  (%r13,%rax), %eax
        mov     %r10d, %edx
        and     $7, %edx
        bt      %edx, %eax
        jnc     10f
9:      mov     (%r12,%r10,8), %rax
        mov     %rax, %rdx
        add     %rdx, %rdx              /* drop the sign bit */
        jz      11f
10:     inc     %r10
        cmp     %r15, %r10
        jb      8b
        jmp     .Lfm_store              /* unreachable: a zero exists */
11:     test    $1, %r9d
        jz      12f
        vmovq   %rax, %xmm0
12:     test    $2, %r9d
        jz      .Lfm_store
        vmovq   %rax, %xmm1
.Lfm_store:
        vmovsd  %xmm0, (%rcx)
        vmovsd  %xmm1, (%r8)
.Lfm_ret:
        mov     %r14, %rax
        pop     %r15
        pop     %r14
        pop     %r13
        pop     %r12
        pop     %rbx
        vzeroupper
        ret
ENDF pqk_x86_avx2_minmax_f64

/* ------------------------------------------------------------------------
 * Bitmap and/or/andnot(a=rdi, b=rsi, out=rdx, nbytes=rcx)
 * 128 bytes per iteration (4 ymm, all loads/ops before the stores), then
 * 32-byte, 8-byte and single-byte steps. out may alias a or b.
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

.macro VBITOP name, vop, sop, neg
FUNC \name
        cmp     $128, %rcx
        jb      2f
1:      VBOP    \neg, \vop, 0, %ymm0
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
        jae     1b
2:      cmp     $32, %rcx
        jb      3f
        VBOP    \neg, \vop, 0, %ymm0
        vmovdqu %ymm0, (%rdx)
        add     $32, %rdi
        add     $32, %rsi
        add     $32, %rdx
        sub     $32, %rcx
        jmp     2b
3:      cmp     $8, %rcx
        jb      4f
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
        jmp     3b
4:      test    %rcx, %rcx
        jz      6f
5:      movzbl  (%rsi), %r8d
.if \neg
        not     %r8d
.endif
        movzbl  (%rdi), %eax
        \sop    %r8d, %eax
        mov     %al, (%rdx)
        inc     %rdi
        inc     %rsi
        inc     %rdx
        dec     %rcx
        jnz     5b
6:      vzeroupper
        ret
ENDF \name
.endm

        VBITOP pqk_x86_avx2_bitmap_and, vpand, and, 0
        VBITOP pqk_x86_avx2_bitmap_or, vpor, or, 0
        VBITOP pqk_x86_avx2_bitmap_andnot, vpandn, and, 1

/* ------------------------------------------------------------------------
 * size_t pqk_x86_avx2_bitmap_popcount(bits=rdi, nbits=rsi)
 * POPCNT on 64-bit words, 4 independent accumulators (r8-r11) over 32 bytes
 * per iteration; remaining 0..63 bits via lvp + bzhi. rcx = word counter.
 * ---------------------------------------------------------------------- */
FUNC pqk_x86_avx2_bitmap_popcount
        xor     %r8d, %r8d
        xor     %r9d, %r9d
        xor     %r10d, %r10d
        xor     %r11d, %r11d
        mov     %rsi, %rcx
        shr     $6, %rcx
        cmp     $4, %rcx
        jb      2f
1:      popcnt  (%rdi), %rax
        popcnt  8(%rdi), %rdx
        add     %rax, %r8
        add     %rdx, %r9
        popcnt  16(%rdi), %rax
        popcnt  24(%rdi), %rdx
        add     %rax, %r10
        add     %rdx, %r11
        add     $32, %rdi
        sub     $4, %rcx
        cmp     $4, %rcx
        jae     1b
2:      test    %rcx, %rcx
        jz      3f
        popcnt  (%rdi), %rax
        add     %rax, %r8
        add     $8, %rdi
        dec     %rcx
        jmp     2b
3:      add     %r9, %r8
        add     %r11, %r10
        add     %r10, %r8
        and     $63, %esi
        jz      4f
        mov     %esi, %r9d
        mov     %rdi, %rsi
        mov     %r9d, %ecx
        call    lvp
        bzhi    %r9, %rax, %rax
        popcnt  %rax, %rax
        add     %rax, %r8
4:      mov     %r8, %rax
        ret
ENDF pqk_x86_avx2_bitmap_popcount

/* ------------------------------------------------------------------------
 * void pqk_x86_avx2_hash_i64(data=rdi, n=rsi, seed=rdx, out=rcx)
 * 8 rows per iteration in ymm0/ymm1 (k), temps ymm2-ymm5.
 * ymm10/11 = C1 low/high dwords, ymm12/13 = C2 low/high dwords,
 * ymm14 = bcast(seed). MUL64: k*c = lo*clo + ((hi*clo + lo*chi) << 32).
 * Last 1..3 rows: scalar (r8/r9 = C1/C2, rax/r10 scratch).
 * ---------------------------------------------------------------------- */
.macro XSH33 k, t
        vpsrlq  $33, \k, \t
        vpxor   \t, \k, \k
.endm
.macro MUL64 k, clo, chi, t1, t2
        vpsrlq  $32, \k, \t1
        vpmuludq \clo, \t1, \t1
        vpmuludq \chi, \k, \t2
        vpaddq  \t2, \t1, \t1
        vpsllq  $32, \t1, \t1
        vpmuludq \clo, \k, \k
        vpaddq  \t1, \k, \k
.endm
.macro VFMIX k, t1, t2
        XSH33   \k, \t1
        MUL64   \k, %ymm10, %ymm11, \t1, \t2
        XSH33   \k, \t1
        MUL64   \k, %ymm12, %ymm13, \t1, \t2
        XSH33   \k, \t1
.endm

FUNC pqk_x86_avx2_hash_i64
        vpbroadcastq c_fmix1_lo(%rip), %ymm10
        vpbroadcastq c_fmix1_hi(%rip), %ymm11
        vpbroadcastq c_fmix2_lo(%rip), %ymm12
        vpbroadcastq c_fmix2_hi(%rip), %ymm13
        vmovq   %rdx, %xmm14
        vpbroadcastq %xmm14, %ymm14
        cmp     $8, %rsi
        jb      2f
1:      vpxor   (%rdi), %ymm14, %ymm0
        vpxor   32(%rdi), %ymm14, %ymm1
        VFMIX   %ymm0, %ymm2, %ymm3
        VFMIX   %ymm1, %ymm4, %ymm5
        vmovdqu %ymm0, (%rcx)
        vmovdqu %ymm1, 32(%rcx)
        add     $64, %rdi
        add     $64, %rcx
        sub     $8, %rsi
        cmp     $8, %rsi
        jae     1b
2:      cmp     $4, %rsi
        jb      3f
        vpxor   (%rdi), %ymm14, %ymm0
        VFMIX   %ymm0, %ymm2, %ymm3
        vmovdqu %ymm0, (%rcx)
        add     $32, %rdi
        add     $32, %rcx
        sub     $4, %rsi
3:      test    %rsi, %rsi
        jz      5f
        movabs  $0xff51afd7ed558ccd, %r8
        movabs  $0xc4ceb9fe1a85ec53, %r9
4:      mov     (%rdi), %rax
        xor     %rdx, %rax
        mov     %rax, %r10
        shr     $33, %r10
        xor     %r10, %rax
        imul    %r8, %rax
        mov     %rax, %r10
        shr     $33, %r10
        xor     %r10, %rax
        imul    %r9, %rax
        mov     %rax, %r10
        shr     $33, %r10
        xor     %r10, %rax
        mov     %rax, (%rcx)
        add     $8, %rdi
        add     $8, %rcx
        dec     %rsi
        jnz     4b
5:      vzeroupper
        ret
ENDF pqk_x86_avx2_hash_i64

/* ------------------------------------------------------------------------
 * void pqk_x86_avx2_compare_fixed(a=rdi, b=rsi, width=rdx, n=rcx, out=r8)
 * Per record, 32-byte chunks: vpcmpeqb + vpmovmskb, mask limited to the
 * record (bzhi), tzcnt finds the first differing byte. A 32-byte load is
 * only issued when at least 32 bytes remain before the END OF THE WHOLE
 * buffer (r9 - offset), so loads may run into the next record but never past
 * a + width*n. Otherwise: 8-byte bswap compares, then bytes.
 * r9 = bytes from current record start to buffer end, r10 = offset in
 * record, r11 = bytes left in record, rbx/r12 = byte or qword operands.
 * ---------------------------------------------------------------------- */
FUNC pqk_x86_avx2_compare_fixed
        test    %rcx, %rcx
        jz      .Lcf_ret0
        push    %rbx
        push    %r12
        mov     %rdx, %r9
        imul    %rcx, %r9
.Lcf_rec:
        xor     %r10d, %r10d
.Lcf_vec:
        mov     %rdx, %r11
        sub     %r10, %r11
        jz      .Lcf_eq
        mov     %r9, %rax
        sub     %r10, %rax
        cmp     $32, %rax
        jb      .Lcf_q
        vmovdqu (%rdi,%r10), %ymm0
        vpcmpeqb (%rsi,%r10), %ymm0, %ymm0
        vpmovmskb %ymm0, %eax
        not     %eax
        cmp     $32, %r11
        jae     1f
        bzhi    %r11d, %eax, %eax
1:      test    %eax, %eax
        jnz     .Lcf_vdiff
        add     $32, %r10
        cmp     $32, %r11
        ja      .Lcf_vec
        jmp     .Lcf_eq
.Lcf_vdiff:
        tzcnt   %eax, %eax
        add     %r10, %rax
        movzbl  (%rdi,%rax), %ebx
        movzbl  (%rsi,%rax), %r12d
        cmp     %r12d, %ebx
        jmp     .Lcf_diff
.Lcf_q:
        lea     8(%r10), %rax
        cmp     %rdx, %rax
        ja      .Lcf_b
        mov     (%rdi,%r10), %rbx
        mov     (%rsi,%r10), %r12
        cmp     %r12, %rbx
        jne     .Lcf_qdiff
        add     $8, %r10
        jmp     .Lcf_q
.Lcf_b:
        cmp     %rdx, %r10
        jae     .Lcf_eq
        movzbl  (%rdi,%r10), %ebx
        movzbl  (%rsi,%r10), %r12d
        cmp     %r12d, %ebx
        jne     .Lcf_diff
        inc     %r10
        jmp     .Lcf_b
.Lcf_qdiff:
        bswap   %rbx
        bswap   %r12
        cmp     %r12, %rbx
.Lcf_diff:
        sbb     %eax, %eax
        or      $1, %eax
        jmp     .Lcf_store
.Lcf_eq:
        xor     %eax, %eax
.Lcf_store:
        mov     %al, (%r8)
        inc     %r8
        add     %rdx, %rdi
        add     %rdx, %rsi
        sub     %rdx, %r9
        dec     %rcx
        jnz     .Lcf_rec
        pop     %r12
        pop     %rbx
        vzeroupper
.Lcf_ret0:
        ret
ENDF pqk_x86_avx2_compare_fixed

/* ------------------------------------------------------------------------
 * int pqk_x86_avx2_group_sum_i64(gid=rdi, values=rsi, validity=rdx, n=rcx,
 *                                sums=r8, counts=r9, ngroups=[rsp+8])
 * Pass 1 (vectorized range check, 8 ids per ymm): unsigned id >= ngroups
 * <=> (id ^ 2^31) >s ((ngroups-1) ^ 2^31). Without validity 32 ids are OR-ed
 * and tested with one vptest; with validity the 8-bit vmovmskps result is
 * ANDed with the row's validity byte. ngroups > UINT32_MAX skips the check;
 * ngroups == 0 and the < 8 row tail use the scalar check.
 * Pass 2 (scalar scatter-add in row order, so the overflow flag is exactly
 * the reference's): no validity -> straight loop that, after the first jo,
 * continues in a copy without overflow checks; with validity -> per 64 rows
 * iterate the set validity bits with tzcnt/blsr, seto/or into r12b. r10 = row, r11 = ngroups / group id,
 * r13 = rows left, r14 = row base, r15 = validity bits, rbp = validity ptr.
 * ---------------------------------------------------------------------- */
FUNC pqk_x86_avx2_group_sum_i64
        push    %rbx
        push    %rbp
        push    %r12
        push    %r13
        push    %r14
        push    %r15
        mov     56(%rsp), %r11
        xor     %r12d, %r12d
        xor     %r10d, %r10d
        mov     $0xffffffff, %eax
        cmp     %rax, %r11
        ja      .Lg_p2
        test    %r11, %r11
        jz      .Lg_p1s
        lea     -1(%r11), %eax
        xor     $0x80000000, %eax
        vmovd   %eax, %xmm1
        vpbroadcastd %xmm1, %ymm1
        vpbroadcastd c_sign_d(%rip), %ymm2
        test    %rdx, %rdx
        jnz     .Lg_p1v
.Lg_p1n32:
        mov     %rcx, %rax
        sub     %r10, %rax
        cmp     $32, %rax
        jb      .Lg_p1v
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
        jnz     .Lg_einval
        add     $32, %r10
        jmp     .Lg_p1n32
.Lg_p1v:                                /* 8 rows at a time */
        mov     %rcx, %rax
        sub     %r10, %rax
        cmp     $8, %rax
        jb      .Lg_p1s
        vpxor   (%rdi,%r10,4), %ymm2, %ymm3
        vpcmpgtd %ymm1, %ymm3, %ymm3
        vmovmskps %ymm3, %eax
        test    %rdx, %rdx
        jz      1f
        mov     %r10, %rbx
        shr     $3, %rbx
        movzbl  (%rdx,%rbx), %ebx
        and     %ebx, %eax
1:      test    %eax, %eax
        jnz     .Lg_einval
        add     $8, %r10
        jmp     .Lg_p1v
.Lg_p1s:                                /* scalar check of rows r10..n-1 */
        cmp     %rcx, %r10
        jae     .Lg_p2
        test    %rdx, %rdx
        jz      1f
        mov     %r10, %rax
        shr     $3, %rax
        movzbl  (%rdx,%rax), %eax
        mov     %r10d, %ebx
        and     $7, %ebx
        bt      %ebx, %eax
        jnc     2f
1:      mov     (%rdi,%r10,4), %eax
        cmp     %r11, %rax
        jae     .Lg_einval
2:      inc     %r10
        jmp     .Lg_p1s

.Lg_p2:
        test    %rcx, %rcx
        jz      .Lg_ok
        test    %rdx, %rdx
        jnz     .Lg_p2v
        xor     %r10d, %r10d
        test    %r9, %r9
        jz      .Lg_p2n
        /* With counts. After the first wrap the flag is final, so the loop
         * continues in a variant without the jo check (no mispredicts on
         * overflow-heavy data). */
.Lg_p2c:
        mov     (%rdi,%r10,4), %eax
        mov     (%rsi,%r10,8), %rbx
        add     %rbx, (%r8,%rax,8)
        jo      .Lg_p2c_of
        incq    (%r9,%rax,8)
        inc     %r10
        cmp     %rcx, %r10
        jb      .Lg_p2c
        jmp     .Lg_ok
.Lg_p2c_of:
        mov     $1, %r12d
        incq    (%r9,%rax,8)
        inc     %r10
        cmp     %rcx, %r10
        jae     .Lg_ok
.Lg_p2c_nc:
        mov     (%rdi,%r10,4), %eax
        mov     (%rsi,%r10,8), %rbx
        add     %rbx, (%r8,%rax,8)
        incq    (%r9,%rax,8)
        inc     %r10
        cmp     %rcx, %r10
        jb      .Lg_p2c_nc
        jmp     .Lg_ok
        /* Without counts, same scheme. */
.Lg_p2n:
        mov     (%rdi,%r10,4), %eax
        mov     (%rsi,%r10,8), %rbx
        add     %rbx, (%r8,%rax,8)
        jo      .Lg_p2n_of
        inc     %r10
        cmp     %rcx, %r10
        jb      .Lg_p2n
        jmp     .Lg_ok
.Lg_p2n_of:
        mov     $1, %r12d
        inc     %r10
        cmp     %rcx, %r10
        jae     .Lg_ok
.Lg_p2n_nc:
        mov     (%rdi,%r10,4), %eax
        mov     (%rsi,%r10,8), %rbx
        add     %rbx, (%r8,%rax,8)
        inc     %r10
        cmp     %rcx, %r10
        jb      .Lg_p2n_nc
        jmp     .Lg_ok

.Lg_p2v:
        mov     %rcx, %r13
        xor     %r14d, %r14d
        mov     %rdx, %rbp
.Lg_vblk:
        cmp     $64, %r13
        jb      .Lg_vpart
        mov     (%rbp), %r15
        jmp     .Lg_vbits
.Lg_vpart:
        push    %rsi
        mov     %rbp, %rsi
        mov     %r13d, %ecx
        call    lvp
        pop     %rsi
        bzhi    %r13, %rax, %r15
.Lg_vbits:
        test    %r15, %r15
        jz      .Lg_vnext
.Lg_vrow:
        tzcnt   %r15, %r10
        add     %r14, %r10
        mov     (%rdi,%r10,4), %r11d
        mov     (%rsi,%r10,8), %rbx
        add     %rbx, (%r8,%r11,8)
        seto    %al
        or      %al, %r12b
        test    %r9, %r9
        jz      1f
        incq    (%r9,%r11,8)
1:      blsr    %r15, %r15
        jnz     .Lg_vrow
.Lg_vnext:
        add     $64, %r14
        add     $8, %rbp
        sub     $64, %r13
        ja      .Lg_vblk

.Lg_ok:
        movzbl  %r12b, %eax
        jmp     .Lg_ret
.Lg_einval:
        mov     $2, %eax
.Lg_ret:
        pop     %r15
        pop     %r14
        pop     %r13
        pop     %r12
        pop     %rbp
        pop     %rbx
        vzeroupper
        ret
ENDF pqk_x86_avx2_group_sum_i64

/* ------------------------------------------------------------------------
 * void pqk_x86_avx2_gather_i64(data=rdi, idx=rsi, m=rdx, out=rcx)
 * 8 independent scalar load pairs per iteration (idx zero-extended by the
 * 32-bit mov, so indices >= 2^31 are fine). vpgatherqq was measured: ~5%
 * faster when data is cache resident, but 15-20% slower when the gathered
 * column comes from DRAM (random access is latency bound; the gather
 * instruction exposes less memory-level parallelism on Zen 5), so plain
 * loads are used. rax/r8-r11 scratch.
 * ---------------------------------------------------------------------- */
FUNC pqk_x86_avx2_gather_i64
        cmp     $8, %rdx
        jb      2f
1:      mov     (%rsi), %eax
        mov     4(%rsi), %r8d
        mov     8(%rsi), %r9d
        mov     12(%rsi), %r10d
        mov     (%rdi,%rax,8), %rax
        mov     (%rdi,%r8,8), %r8
        mov     (%rdi,%r9,8), %r9
        mov     (%rdi,%r10,8), %r10
        mov     %rax, (%rcx)
        mov     %r8, 8(%rcx)
        mov     %r9, 16(%rcx)
        mov     %r10, 24(%rcx)
        mov     16(%rsi), %eax
        mov     20(%rsi), %r8d
        mov     24(%rsi), %r9d
        mov     28(%rsi), %r10d
        mov     (%rdi,%rax,8), %rax
        mov     (%rdi,%r8,8), %r8
        mov     (%rdi,%r9,8), %r9
        mov     (%rdi,%r10,8), %r10
        mov     %rax, 32(%rcx)
        mov     %r8, 40(%rcx)
        mov     %r9, 48(%rcx)
        mov     %r10, 56(%rcx)
        add     $32, %rsi
        add     $64, %rcx
        sub     $8, %rdx
        cmp     $8, %rdx
        jae     1b
2:      test    %rdx, %rdx
        jz      4f
3:      mov     (%rsi), %eax
        mov     (%rdi,%rax,8), %rax
        mov     %rax, (%rcx)
        add     $4, %rsi
        add     $8, %rcx
        dec     %rdx
        jnz     3b
4:      ret
ENDF pqk_x86_avx2_gather_i64

        .section .note.GNU-stack, "", @progbits
