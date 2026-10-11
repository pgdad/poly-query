/*
 * pqk_x86_avx512.S — PolyQuery native kernels, variant "x86_avx512".
 *
 * Requires AVX-512 F/BW/VL/DQ (+ BMI1/BMI2/POPCNT, implied on every CPU with
 * those). Only F/BW/VL/DQ instructions are used (no VPOPCNTDQ/CD/VBMI2,
 * which the dispatcher does not check). All 16 kernels as global symbols
 * pqk_x86_avx512_<kernel>, System V AMD64 ABI; every public function that
 * touches vector registers ends with vzeroupper.
 *
 * Design overview (details at each function):
 *  - Predicates: vpcmpq writes k-masks directly. With x in memory as the
 *    second operand the predicate is written as "a OP' x":
 *        EQ: a==x(0)  NE: a!=x(4)  LT: a>x(6)  LE: a>=x(5)  GT: a<x(1)
 *        GE: a<=x(2)  BETWEEN: a<=x (2), then masked b>=x (5)
 *    A 64-row block is 8 compares whose 8-bit masks are merged with
 *    kunpckbw/wd/dq into one 64-bit mask (kmovq). The partial last block uses
 *    zero-masked loads (vmovdqu64 {z}); AVX-512 masked loads architecturally
 *    suppress faults on masked-off elements, so tails are vector code that
 *    never touches memory past the buffer.
 *  - filter_i64: full blocks emit indices with vpcompressd (16 rows per step,
 *    zmm of row indices, store 64 bytes, advance by popcnt): branch-free, so
 *    no mispredict on varying selectivity. The 64-byte store stays inside
 *    out_idx[0..n) because outputs-so-far <= rows consumed.
 *  - Validity: kmovb/kmovw load validity bytes straight into k registers and
 *    are used as merge write masks on arithmetic. Hot loops use plain loads:
 *    zero-masked loads measured up to 2.5x slower when streaming from DRAM
 *    on Zen 5, so masked loads appear only in tails (once per call/record).
 *  - sum_i64 exact: vpsraq exists, so per lane S = sum(x) mod 2^64 and
 *    H = sum(x >> 32) (arithmetic). sum(x) = H*2^32 + L, L = sum of low
 *    halves = (S - H*2^32) mod 2^64 (exact while < 2^64); chunks of <= 2^28
 *    rows are folded into a 128-bit scalar total.
 *  - count_i64 without validity: direct loop, vpcmpq -> k and merge-masked
 *    "acc -= -1" per 8 rows (no kmov/popcnt), see KCNT.
 *  - No-validity streaming loops (count, sum_i64, sum_f64, minmax) peel up to
 *    7 leading rows so the main loop's 64-byte loads are cache-line aligned
 *    (malloc returns 16 mod 64; split loads cost up to 25% from DRAM).
 *  - hash_i64 uses vpmullq (DQ) directly.
 *
 * Internal helpers use custom conventions (documented at each helper) and do
 * not touch the stack except call/ret. No red zone is used.
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

/* zmm \z (ymm alias \y, xmm alias \x), temps ymm/xmm \ty/\tx -> \r */
.macro HSUMZ z, y, x, ty, tx, r
        vextracti64x4 $1, \z, \ty
        vpaddq  \ty, \y, \y
        vextracti128 $1, \y, \tx
        vpaddq  \tx, \x, \x
        vpshufd $0x4e, \x, \tx
        vpaddq  \tx, \x, \x
        vmovq   \x, \r
.endm

        .section .rodata
        .p2align 6
        .type   iota16, @object
iota16:
        .set r, 0
        .rept 16
        .long r
        .set r, r + 1
        .endr
        .size   iota16, . - iota16
        .type   c_sixteen_d, @object
c_sixteen_d:    .long 16
        .size   c_sixteen_d, . - c_sixteen_d
        .type   c_fmix1, @object
c_fmix1:        .quad 0xff51afd7ed558ccd
        .size   c_fmix1, . - c_fmix1
        .type   c_fmix2, @object
c_fmix2:        .quad 0xc4ceb9fe1a85ec53
        .size   c_fmix2, . - c_fmix2
        .type   c_pinf, @object
c_pinf:         .quad 0x7ff0000000000000
        .size   c_pinf, . - c_pinf
        .type   c_ninf, @object
c_ninf:         .quad 0xfff0000000000000
        .size   c_ninf, . - c_ninf
        .type   c_i64max, @object
c_i64max:       .quad 0x7fffffffffffffff
        .size   c_i64max, . - c_i64max
        .type   c_i64min, @object
c_i64min:       .quad 0x8000000000000000
        .size   c_i64min, . - c_i64min
        .text

/* ------------------------------------------------------------------------
 * lvp: partial validity word. in: rsi = ptr, ecx = len (1..64); loads
 * exactly ceil(len/8) bytes. out: rax (bits >= len in the last byte not
 * cleared). clobbers rcx, rdx.
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

/* lane mask helper: \dst(32-bit gpr) = (1 << min(\cnt, 8)) - 1 (8 lanes) */
.macro LANES8 cnt, dst
        mov     $0xff, \dst
        bzhi    \cnt, \dst, \dst
.endm

/* Alignment peel (no-validity streaming loops): \h = number of leading rows
 * (0..7) until rdi is 64-byte aligned, capped at \rem; 0 if rdi is not
 * 8-byte aligned (then no row boundary is 64-byte aligned). k1 = lanes < h.
 * Aligned 64-byte loads measured up to 25% faster when streaming from DRAM.
 * clobbers \h, \t (32-bit regs) and flags; ZF set iff h == 0. */
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

/* ------------------------------------------------------------------------
 * Predicate mask routines kop_*: in rdi = block ptr, esi = len (1..64),
 * zmm8/zmm9 = bcast a/b. out rax = mask with exactly len bits.
 * clobbers rcx, rdx, rdi, rsi, k1-k4, zmm0.
 * imm = vpcmpq predicate for "a OP' x"; imm 99 = BETWEEN.
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

.macro KOP name, imm
LFUNC \name
        cmp     $64, %esi
        jne     .Lpart\@
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
.Lpart\@:
        xor     %eax, %eax
        xor     %ecx, %ecx
1:      LANES8  %esi, %edx
        kmovb   %edx, %k4
        vmovdqu64 (%rdi), %zmm0{%k4}{z}
        KPRED   \imm, %zmm0, %k1, {%k4}
        kmovb   %k1, %edx
        shlx    %rcx, %rdx, %rdx
        or      %rdx, %rax
        add     $64, %rdi
        add     $8, %ecx
        sub     $8, %esi
        jg      1b
        ret
ENDF \name
.endm

        KOP kop_eq, 0
        KOP kop_ne, 4
        KOP kop_lt, 6
        KOP kop_le, 5
        KOP kop_gt, 1
        KOP kop_ge, 2
        KOP kop_bt, 99

        .section .rodata
        .p2align 2
        .type   kop_table, @object
kop_table:
        .long   kop_eq - kop_table, kop_ne - kop_table, kop_lt - kop_table
        .long   kop_le - kop_table, kop_gt - kop_table, kop_ge - kop_table
        .long   kop_bt - kop_table
        .size   kop_table, . - kop_table
        .text

/* Direct counters for count_i64 without validity: in rdi = data,
 * rdx = rows (>= 1), zmm8/zmm9 = bcast a/b. out rax = count.
 * Alignment peel (masked), 32 rows per step: vpcmpq -> k, merge-masked
 * "acc -= -1" (no kmov/popcnt), then masked 8-row tail groups.
 * clobbers rcx, rdx, rdi, r10, r11, zmm0, zmm3-zmm7, k1-k4. */
.macro KCNT name, imm
LFUNC \name
        vpxorq  %zmm4, %zmm4, %zmm4
        vpxorq  %zmm5, %zmm5, %zmm5
        vpxorq  %zmm6, %zmm6, %zmm6
        vpxorq  %zmm7, %zmm7, %zmm7
        vpternlogd $0xff, %zmm3, %zmm3, %zmm3   /* all ones = -1 */
        xor     %r11d, %r11d
        PEELMASK %rdx, %rcx, %ecx, %r11d
        jz      1f
        vmovdqu64 (%rdi), %zmm0{%k1}{z}
        kmovb   %k1, %k4
        KPRED   \imm, %zmm0, %k1, {%k4}
        vpsubq  %zmm3, %zmm4, %zmm4{%k1}
        lea     (%rdi,%rcx,8), %rdi
        sub     %rcx, %rdx
1:      cmp     $32, %rdx
        jb      2f
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
        jmp     1b
2:      test    %rdx, %rdx
        jz      3f
        LANES8  %edx, %r10d
        kmovb   %r10d, %k4
        vmovdqu64 (%rdi), %zmm0{%k4}{z}
        KPRED   \imm, %zmm0, %k1, {%k4}
        vpsubq  %zmm3, %zmm5, %zmm5{%k1}
        add     $64, %rdi
        sub     $8, %rdx
        jg      2b
3:      vpaddq  %zmm5, %zmm4, %zmm4
        vpaddq  %zmm7, %zmm6, %zmm6
        vpaddq  %zmm6, %zmm4, %zmm4
        HSUMZ   %zmm4, %ymm4, %xmm4, %ymm0, %xmm0, %rax
        ret
ENDF \name
.endm

        KCNT kcnt_eq, 0
        KCNT kcnt_ne, 4
        KCNT kcnt_lt, 6
        KCNT kcnt_le, 5
        KCNT kcnt_gt, 1
        KCNT kcnt_ge, 2
        KCNT kcnt_bt, 99

        .section .rodata
        .p2align 2
        .type   kcnt_table, @object
kcnt_table:
        .long   kcnt_eq - kcnt_table, kcnt_ne - kcnt_table, kcnt_lt - kcnt_table
        .long   kcnt_le - kcnt_table, kcnt_gt - kcnt_table, kcnt_ge - kcnt_table
        .long   kcnt_bt - kcnt_table
        .size   kcnt_table, . - kcnt_table
        .text

/* ------------------------------------------------------------------------
 * Predicate driver: mode 0 filter_i64, 1 filter_i64_bitmap, 2 count_i64.
 * Args: rdi=data rsi=validity rdx=n ecx=op r8=a r9=b [rsp+8]=out.
 * r12 = block data ptr, r13 = validity ptr (0 = all valid), r14 = rows
 * remaining, r15 = mask routine, rbx = row base (mode 0) / count (1, 2),
 * rbp = output ptr; (%rsp) = output start. zmm8/9 = bcast a/b,
 * zmm4 = row indices for vpcompressd, zmm5 = iota, zmm6 = bcast(16).
 * ---------------------------------------------------------------------- */
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
        lea     kop_table(%rip), %rax
        movslq  (%rax,%rcx,4), %r15
        add     %rax, %r15
        vpbroadcastq %r8, %zmm8
        vpbroadcastq %r9, %zmm9
        mov     %rdi, %r12
        mov     %rsi, %r13
        mov     %rdx, %r14
        xor     %ebx, %ebx
.if \mode == 0
        vmovdqu32 iota16(%rip), %zmm5
        vpbroadcastd c_sixteen_d(%rip), %zmm6
.endif
.if \mode == 2
        test    %r13, %r13
        jnz     .Lstart\@
        test    %r14, %r14
        jz      .Lstart\@
        lea     kcnt_table(%rip), %rax
        movslq  (%rax,%rcx,4), %r10
        add     %rax, %r10
        mov     %r12, %rdi
        mov     %r14, %rdx
        call    *%r10
        mov     %rax, %rbx
        jmp     .Ldone\@
.Lstart\@:
.endif
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
        cmp     $64, %r14
        jb      .Lsparse\@
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

/* size_t pqk_x86_avx512_filter_i64(data, validity, n, op, a, b, out_idx) */
FUNC pqk_x86_avx512_filter_i64
        PRED_DRIVER 0
ENDF pqk_x86_avx512_filter_i64

/* size_t pqk_x86_avx512_filter_i64_bitmap(data, validity, n, op, a, b, out_bits) */
FUNC pqk_x86_avx512_filter_i64_bitmap
        PRED_DRIVER 1
ENDF pqk_x86_avx512_filter_i64_bitmap

/* size_t pqk_x86_avx512_count_i64(data, validity, n, op, a, b) */
FUNC pqk_x86_avx512_count_i64
        PRED_DRIVER 2
ENDF pqk_x86_avx512_count_i64

/* ------------------------------------------------------------------------
 * Element-wise compare routines kcmp_*: in rdi = &a[block],
 * rsi = &b[block], edx = len (1..64). out rax = mask with exactly len bits.
 * vpcmpq imm computes a OP b directly (a in register, b from memory).
 * clobbers rcx, rdx, rdi, rsi, r10, k1-k4, zmm0, zmm1.
 * ---------------------------------------------------------------------- */
.macro KCMP1 imm, off, k
        vmovdqu64 \off(%rdi), %zmm0
        vpcmpq  $\imm, \off(%rsi), %zmm0, \k
.endm

.macro KCMP name, imm
LFUNC \name
        cmp     $64, %edx
        jne     .Lpart\@
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
.Lpart\@:
        xor     %eax, %eax
        xor     %ecx, %ecx
1:      LANES8  %edx, %r10d
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
        jg      1b
        ret
ENDF \name
.endm

        KCMP kcmp_eq, 0
        KCMP kcmp_ne, 4
        KCMP kcmp_lt, 1
        KCMP kcmp_le, 2
        KCMP kcmp_gt, 6
        KCMP kcmp_ge, 5

        .section .rodata
        .p2align 2
        .type   kcmp_table, @object
kcmp_table:
        .long   kcmp_eq - kcmp_table, kcmp_ne - kcmp_table, kcmp_lt - kcmp_table
        .long   kcmp_le - kcmp_table, kcmp_gt - kcmp_table, kcmp_ge - kcmp_table
        .size   kcmp_table, . - kcmp_table
        .text

/* ------------------------------------------------------------------------
 * size_t pqk_x86_avx512_compare_i64(a=rdi, b=rsi, n=rdx, op=ecx, out=r8)
 * r12 = a block, r13 = b block, r14 = remaining, r15 = routine,
 * rbx = popcount total, rbp = out ptr.
 * ---------------------------------------------------------------------- */
FUNC pqk_x86_avx512_compare_i64
        cmp     $5, %ecx
        ja      .Lci_inval
        push    %rbx
        push    %rbp
        push    %r12
        push    %r13
        push    %r14
        push    %r15
        mov     %ecx, %ecx
        lea     kcmp_table(%rip), %rax
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
ENDF pqk_x86_avx512_compare_i64

/* ------------------------------------------------------------------------
 * Row-group iteration used by sum/minmax kernels: groups of 8 rows.
 * VLOAD8: k1 <- lane mask for the group = (8 lanes, limited to remaining
 * rows r10) & validity byte (if r13 != 0); clobbers eax, edx.
 * ---------------------------------------------------------------------- */
.macro GROUPMASK
        LANES8  %r10d, %eax
        test    %rsi, %rsi
        jz      1f
        movzbl  (%rsi), %edx
        and     %edx, %eax
1:      kmovb   %eax, %k1
.endm

/* ------------------------------------------------------------------------
 * int pqk_x86_avx512_sum_i64(data=rdi, validity=rsi, n=rdx, out_sum=rcx)
 * Accumulators: S zmm0/zmm1, H zmm2/zmm3 (two sets, 16 rows per step);
 * zmm6/zmm7 data, zmm10/zmm11 temps. Validity: kmovb of the row group's
 * byte as merge mask on the adds (plain loads: zero-masked loads were ~2.5x
 * slower when streaming from DRAM on Zen 5; masked loads are only used for
 * the final < 16 rows). r8/r9 = 128-bit total (lo/hi),
 * r10 = rows remaining in the call, r12 = rows left in chunk, r11 = out.
 * ---------------------------------------------------------------------- */
#ifndef SUM_CHUNK_ROWS
#define SUM_CHUNK_ROWS (1 << 28)
#endif

FUNC pqk_x86_avx512_sum_i64
        push    %rbx
        push    %r12
        xor     %r8d, %r8d
        xor     %r9d, %r9d
        mov     %rcx, %r11
        mov     %rdx, %r10
        test    %rsi, %rsi
        jnz     .Ls_chunk
        xor     %edx, %edx
        PEELMASK %r10, %rcx, %ecx, %edx         /* scalar head to 64B alignment */
        jz      .Ls_chunk
        sub     %rcx, %r10
1:      mov     (%rdi), %rax
        cqo
        add     %rax, %r8
        adc     %rdx, %r9
        add     $8, %rdi
        dec     %ecx
        jnz     1b
.Ls_chunk:
        test    %r10, %r10
        jz      .Ls_fin
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
        jnz     .Ls_v16
.Ls_n16:
        cmp     $16, %r12
        jb      .Ls_tail
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
        jmp     .Ls_n16
.Ls_v16:
        cmp     $16, %r12
        jb      .Ls_tail
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
        jmp     .Ls_v16
.Ls_tail:                               /* 0..15 rows: up to 2 masked groups */
        test    %r12, %r12
        jz      .Ls_fold
        xchg    %r10, %r12              /* GROUPMASK uses r10 as row count */
        GROUPMASK
        xchg    %r10, %r12
        vmovdqu64 (%rdi), %zmm6{%k1}{z}
        vpaddq  %zmm6, %zmm0, %zmm0
        vpsraq  $32, %zmm6, %zmm6
        vpaddq  %zmm6, %zmm2, %zmm2
        add     $64, %rdi
        test    %rsi, %rsi
        jz      2f
        inc     %rsi
2:      sub     $8, %r12
        jg      .Ls_tail
        xor     %r12d, %r12d
.Ls_fold:
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
        jmp     .Ls_chunk
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
ENDF pqk_x86_avx512_sum_i64

/* ------------------------------------------------------------------------
 * double pqk_x86_avx512_sum_f64(data=rdi, validity=rsi, n=rdx)
 * 32 lane partial sums in zmm0-zmm3 (+0.0 init, so a lane is never -0.0
 * and zero-masked +0.0 lanes are exact no-ops); 32 rows per step with the
 * validity bytes as merge masks on the adds, then masked 8-row groups.
 * r10 = rows remaining.
 * ---------------------------------------------------------------------- */
FUNC pqk_x86_avx512_sum_f64
        vpxorq  %zmm0, %zmm0, %zmm0
        vpxorq  %zmm1, %zmm1, %zmm1
        vpxorq  %zmm2, %zmm2, %zmm2
        vpxorq  %zmm3, %zmm3, %zmm3
        mov     %rdx, %r10
        test    %rsi, %rsi
        jnz     .Lf_v32
        xor     %edx, %edx
        PEELMASK %r10, %rcx, %ecx, %edx
        jz      .Lf_n32
        vmovupd (%rdi), %zmm4{%k1}{z}
        vaddpd  %zmm4, %zmm0, %zmm0
        lea     (%rdi,%rcx,8), %rdi
        sub     %rcx, %r10
.Lf_n32:
        cmp     $32, %r10
        jb      .Lf_tail
        vaddpd  (%rdi), %zmm0, %zmm0
        vaddpd  64(%rdi), %zmm1, %zmm1
        vaddpd  128(%rdi), %zmm2, %zmm2
        vaddpd  192(%rdi), %zmm3, %zmm3
        add     $256, %rdi
        sub     $32, %r10
        jmp     .Lf_n32
.Lf_v32:
        cmp     $32, %r10
        jb      .Lf_tail
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
        jmp     .Lf_v32
.Lf_tail:
        test    %r10, %r10
        jz      .Lf_red
        GROUPMASK
        vmovupd (%rdi), %zmm4{%k1}{z}
        vaddpd  %zmm4, %zmm0, %zmm0
        add     $64, %rdi
        test    %rsi, %rsi
        jz      1f
        inc     %rsi
1:      sub     $8, %r10
        jg      .Lf_tail
.Lf_red:
        vaddpd  %zmm1, %zmm0, %zmm0
        vaddpd  %zmm3, %zmm2, %zmm2
        vaddpd  %zmm2, %zmm0, %zmm0
        vextractf64x4 $1, %zmm0, %ymm1
        vaddpd  %ymm1, %ymm0, %ymm0
        vextractf128 $1, %ymm0, %xmm1
        vaddpd  %xmm1, %xmm0, %xmm0
        vunpckhpd %xmm0, %xmm0, %xmm1
        vaddsd  %xmm1, %xmm0, %xmm0
        vzeroupper
        ret
ENDF pqk_x86_avx512_sum_f64

/* ------------------------------------------------------------------------
 * size_t pqk_x86_avx512_minmax_i64(data=rdi, validity=rsi, n=rdx,
 *                                  out_min=rcx, out_max=r8)
 * vpminsq/vpmaxsq with merge masking (invalid / out-of-range lanes keep the
 * accumulator). zmm0/zmm2 min accs (INT64_MAX), zmm1/zmm3 max accs
 * (INT64_MIN). r10 = rows remaining, r9 = count of valid rows.
 * ---------------------------------------------------------------------- */
FUNC pqk_x86_avx512_minmax_i64
        vpbroadcastq c_i64max(%rip), %zmm0
        vpbroadcastq c_i64min(%rip), %zmm1
        vmovdqa64 %zmm0, %zmm2
        vmovdqa64 %zmm1, %zmm3
        mov     %rdx, %r10
        xor     %r9d, %r9d
        test    %rsi, %rsi
        jnz     .Lm_v16
        mov     %rdx, %r9
        xor     %edx, %edx
        PEELMASK %r10, %rax, %eax, %edx
        jz      .Lm_n16
        vmovdqu64 (%rdi), %zmm4{%k1}{z}
        vpminsq %zmm4, %zmm0, %zmm0{%k1}
        vpmaxsq %zmm4, %zmm1, %zmm1{%k1}
        lea     (%rdi,%rax,8), %rdi
        sub     %rax, %r10
.Lm_n16:
        cmp     $16, %r10
        jb      .Lm_tail
        vmovdqu64 (%rdi), %zmm4
        vmovdqu64 64(%rdi), %zmm5
        vpminsq %zmm4, %zmm0, %zmm0
        vpmaxsq %zmm4, %zmm1, %zmm1
        vpminsq %zmm5, %zmm2, %zmm2
        vpmaxsq %zmm5, %zmm3, %zmm3
        sub     $-128, %rdi
        sub     $16, %r10
        jmp     .Lm_n16
.Lm_v16:
        cmp     $16, %r10
        jb      .Lm_tail
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
        jmp     .Lm_v16
.Lm_tail:
        test    %r10, %r10
        jz      .Lm_red
        GROUPMASK
        test    %rsi, %rsi
        jz      1f
        popcnt  %eax, %eax
        add     %rax, %r9
        inc     %rsi
1:      vmovdqu64 (%rdi), %zmm4{%k1}{z}
        vpminsq %zmm4, %zmm0, %zmm0{%k1}
        vpmaxsq %zmm4, %zmm1, %zmm1{%k1}
        add     $64, %rdi
        sub     $8, %r10
        jg      .Lm_tail
.Lm_red:
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
        jz      2f
        vmovq   %xmm0, (%rcx)
        vmovq   %xmm1, (%r8)
2:      vzeroupper
        ret
ENDF pqk_x86_avx512_minmax_i64

/* ------------------------------------------------------------------------
 * size_t pqk_x86_avx512_minmax_f64(data=rdi, validity=rsi, n=rdx,
 *                                  out_min=rcx, out_max=r8)
 * Like minmax_i64 with vminpd/vmaxpd ("x < acc ? x : acc" per lane, merge
 * masked), accumulators start at +inf / -inf. Signed-zero fix-up as in the
 * AVX2 variant: if the min (max) equals 0.0 it is replaced by the first
 * valid zero of the column, which is what the sequential reference returns.
 * r9 = count, r10 = remaining, r11 = saved data, stack slot = saved
 * validity/n (pushed).
 * ---------------------------------------------------------------------- */
FUNC pqk_x86_avx512_minmax_f64
        push    %rbx
        push    %r12
        push    %r13
        mov     %rdi, %r11
        mov     %rsi, %r12
        mov     %rdx, %r13
        vbroadcastsd c_pinf(%rip), %zmm0
        vbroadcastsd c_ninf(%rip), %zmm1
        vmovapd %zmm0, %zmm2
        vmovapd %zmm1, %zmm3
        mov     %rdx, %r10
        xor     %r9d, %r9d
        test    %rsi, %rsi
        jnz     .Lfm_v16
        mov     %rdx, %r9
        xor     %edx, %edx
        PEELMASK %r10, %rax, %eax, %edx
        jz      .Lfm_n16
        vmovupd (%rdi), %zmm4{%k1}{z}
        vminpd  %zmm0, %zmm4, %zmm0{%k1}
        vmaxpd  %zmm1, %zmm4, %zmm1{%k1}
        lea     (%rdi,%rax,8), %rdi
        sub     %rax, %r10
.Lfm_n16:
        cmp     $16, %r10
        jb      .Lfm_tail
        vmovupd (%rdi), %zmm4
        vmovupd 64(%rdi), %zmm5
        vminpd  %zmm0, %zmm4, %zmm0
        vmaxpd  %zmm1, %zmm4, %zmm1
        vminpd  %zmm2, %zmm5, %zmm2
        vmaxpd  %zmm3, %zmm5, %zmm3
        sub     $-128, %rdi
        sub     $16, %r10
        jmp     .Lfm_n16
.Lfm_v16:
        cmp     $16, %r10
        jb      .Lfm_tail
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
        jmp     .Lfm_v16
.Lfm_tail:
        test    %r10, %r10
        jz      .Lfm_red
        GROUPMASK
        test    %rsi, %rsi
        jz      1f
        popcnt  %eax, %eax
        add     %rax, %r9
        inc     %rsi
1:      vmovupd (%rdi), %zmm4{%k1}{z}
        vminpd  %zmm0, %zmm4, %zmm0{%k1}
        vmaxpd  %zmm1, %zmm4, %zmm1{%k1}
        add     $64, %rdi
        sub     $8, %r10
        jg      .Lfm_tail
.Lfm_red:
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
        jz      .Lfm_ret
        /* signed-zero fix-up; ebx bit0: min==0, bit1: max==0 */
        vxorpd  %xmm5, %xmm5, %xmm5
        xor     %ebx, %ebx
        vucomisd %xmm5, %xmm0
        jne     2f
        or      $1, %ebx
2:      vucomisd %xmm5, %xmm1
        jne     3f
        or      $2, %ebx
3:      test    %ebx, %ebx
        jz      .Lfm_store
        xor     %r10d, %r10d
4:      test    %r12, %r12
        jz      5f
        mov     %r10, %rax
        shr     $3, %rax
        movzbl  (%r12,%rax), %eax
        mov     %r10d, %edx
        and     $7, %edx
        bt      %edx, %eax
        jnc     6f
5:      mov     (%r11,%r10,8), %rax
        mov     %rax, %rdx
        add     %rdx, %rdx
        jz      7f
6:      inc     %r10
        cmp     %r13, %r10
        jb      4b
        jmp     .Lfm_store
7:      test    $1, %ebx
        jz      8f
        vmovq   %rax, %xmm0
8:      test    $2, %ebx
        jz      .Lfm_store
        vmovq   %rax, %xmm1
.Lfm_store:
        vmovsd  %xmm0, (%rcx)
        vmovsd  %xmm1, (%r8)
.Lfm_ret:
        mov     %r9, %rax
        pop     %r13
        pop     %r12
        pop     %rbx
        vzeroupper
        ret
ENDF pqk_x86_avx512_minmax_f64

/* ------------------------------------------------------------------------
 * Bitmap and/or/andnot(a=rdi, b=rsi, out=rdx, nbytes=rcx)
 * 256 bytes per iteration (4 zmm; loads before stores), 64-byte steps, then
 * one byte-masked step (vmovdqu8 with k1 = low rem bits) for the tail.
 * out may alias a or b.
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

.macro ZBITOP name, vop, neg
FUNC \name
        cmp     $256, %rcx
        jb      2f
1:      ZBOP    \neg, \vop, 0, %zmm0
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
        jae     1b
2:      cmp     $64, %rcx
        jb      3f
        ZBOP    \neg, \vop, 0, %zmm0
        vmovdqu8 %zmm0, (%rdx)
        add     $64, %rdi
        add     $64, %rsi
        add     $64, %rdx
        sub     $64, %rcx
        jmp     2b
3:      test    %rcx, %rcx
        jz      4f
        mov     $-1, %rax
        bzhi    %rcx, %rax, %rax
        kmovq   %rax, %k1
        ZBOP    \neg, \vop, 0, %zmm0, {%k1}{z}
        vmovdqu8 %zmm0, (%rdx){%k1}
4:      vzeroupper
        ret
ENDF \name
.endm

        ZBITOP pqk_x86_avx512_bitmap_and, vpandq, 0
        ZBITOP pqk_x86_avx512_bitmap_or, vporq, 0
        ZBITOP pqk_x86_avx512_bitmap_andnot, vpandnq, 1

/* ------------------------------------------------------------------------
 * size_t pqk_x86_avx512_bitmap_popcount(bits=rdi, nbits=rsi)
 * VPOPCNTQ is not part of F/BW/VL/DQ, so: Mula nibble lookup with vpshufb
 * on zmm (BW), byte counts summed per qword with vpsadbw, 256 bytes per
 * iteration into zmm accumulators; remaining whole qwords with POPCNT and
 * the last 0..63 bits via lvp + bzhi. zmm10 = nibble LUT, zmm11 = 0x0f,
 * zmm12 = zero, zmm0/zmm1 = accumulators, rcx = 256-byte blocks / words.
 * ---------------------------------------------------------------------- */
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

        .section .rodata
        .p2align 4
        .type   nib_lut, @object
nib_lut:
        .byte 0,1,1,2,1,2,2,3,1,2,2,3,2,3,3,4
        .size   nib_lut, . - nib_lut
        .type   c_0f, @object
c_0f:   .byte 0x0f
        .size   c_0f, . - c_0f
        .text

FUNC pqk_x86_avx512_bitmap_popcount
        vbroadcasti32x4 nib_lut(%rip), %zmm10
        vpbroadcastb c_0f(%rip), %zmm11
        vpxorq  %zmm12, %zmm12, %zmm12
        vpxorq  %zmm0, %zmm0, %zmm0
        vpxorq  %zmm1, %zmm1, %zmm1
        mov     %rsi, %rcx
        shr     $11, %rcx                       /* 256-byte blocks */
        jz      2f
1:      vmovdqu64 (%rdi), %zmm2
        vmovdqu64 64(%rdi), %zmm3
        vmovdqu64 128(%rdi), %zmm4
        vmovdqu64 192(%rdi), %zmm5
        MULA    %zmm2, %zmm0
        MULA    %zmm3, %zmm1
        MULA    %zmm4, %zmm0
        MULA    %zmm5, %zmm1
        add     $256, %rdi
        dec     %rcx
        jnz     1b
2:      vpaddq  %zmm1, %zmm0, %zmm0
        HSUMZ   %zmm0, %ymm0, %xmm0, %ymm1, %xmm1, %r8
        mov     %rsi, %rcx
        shr     $6, %rcx
        and     $31, %ecx                       /* remaining whole qwords */
        jz      4f
3:      popcnt  (%rdi), %rax
        add     %rax, %r8
        add     $8, %rdi
        dec     %ecx
        jnz     3b
4:      and     $63, %esi
        jz      5f
        mov     %esi, %r9d
        mov     %rdi, %rsi
        mov     %r9d, %ecx
        call    lvp
        bzhi    %r9, %rax, %rax
        popcnt  %rax, %rax
        add     %rax, %r8
5:      mov     %r8, %rax
        vzeroupper
        ret
ENDF pqk_x86_avx512_bitmap_popcount

/* ------------------------------------------------------------------------
 * void pqk_x86_avx512_hash_i64(data=rdi, n=rsi, seed=rdx, out=rcx)
 * 32 rows per iteration (4 independent zmm chains), then masked 8-row
 * groups (zero-masked load, masked store). zmm10/zmm11 = C1/C2,
 * zmm12 = seed, zmm0-zmm3 = k, zmm4-zmm7 temps.
 * ---------------------------------------------------------------------- */
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
        vpbroadcastq c_fmix1(%rip), %zmm10
        vpbroadcastq c_fmix2(%rip), %zmm11
        vpbroadcastq %rdx, %zmm12
        cmp     $32, %rsi
        jb      2f
1:      vpxorq  (%rdi), %zmm12, %zmm0
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
        jae     1b
2:      test    %rsi, %rsi
        jz      3f
        LANES8  %esi, %eax
        kmovb   %eax, %k1
        vmovdqu64 (%rdi), %zmm0{%k1}{z}
        vpxorq  %zmm12, %zmm0, %zmm0
        ZFMIX   %zmm0, %zmm4
        vmovdqu64 %zmm0, (%rcx){%k1}
        add     $64, %rdi
        add     $64, %rcx
        sub     $8, %rsi
        jg      2b
3:      vzeroupper
        ret
ENDF pqk_x86_avx512_hash_i64

/* ------------------------------------------------------------------------
 * void pqk_x86_avx512_compare_fixed(a=rdi, b=rsi, width=rdx, n=rcx, out=r8)
 * Records of width <= 64 (common case) use a dedicated one-chunk loop with
 * the record byte mask precomputed. Otherwise, per record, 64-byte chunks: vpcmpb NEQ -> k2 -> "differs" mask (the
 * record's last chunk limited to the record with bzhi). Branch-free per
 * record: every chunk is scanned (fixed trip count per width) and
 * pos = min(offset + tzcnt(mask)) is tracked with cmovc (tzcnt sets CF for
 * an empty mask) / cmova. If nothing differs pos becomes 0, whose bytes are
 * equal, so the same byte compare (seta/sbb -> -1/0/1) yields 0. Plain loads
 * (which may run into the next record) are used while >= 64 bytes remain
 * before the end of the whole buffer; within the last 64 bytes the loads are
 * byte-masked to the record (vmovdqu8 {z}, fault suppressing).
 * r9 = bytes from current record start to buffer end, r10 = offset in
 * record, r11 = bytes left in record, r13 = first differing offset (-1 =
 * none yet), r14 = -1, rbx/r12 = differing bytes.
 * ---------------------------------------------------------------------- */
FUNC pqk_x86_avx512_compare_fixed
        test    %rcx, %rcx
        jz      .Lcf_ret0
        test    %rdx, %rdx
        jz      .Lcf_zero
        push    %rbx
        push    %r12
        push    %r13
        push    %r14
        mov     $-1, %r14
        mov     %rdx, %r9
        imul    %rcx, %r9
        cmp     $64, %rdx
        ja      .Lcf_rec
        /* width <= 64: one chunk per record, r13 = record byte mask */
        mov     $-1, %r13
        bzhi    %rdx, %r13, %r13
.Lcf_fast:
        cmp     $64, %r9
        jb      .Lcf_rec                        /* last records: general path */
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
        jnz     .Lcf_fast
        jmp     .Lcf_done
.Lcf_rec:
        xor     %r10d, %r10d
        mov     %r14, %r13
.Lcf_chunk:
        mov     %rdx, %r11
        sub     %r10, %r11                      /* > 0 */
        mov     %r9, %rax
        sub     %r10, %rax
        cmp     $64, %rax
        jb      .Lcf_tail
        vmovdqu64 (%rdi,%r10), %zmm0
        vpcmpb  $4, (%rsi,%r10), %zmm0, %k2
        kmovq   %k2, %rax                       /* differs mask */
.Lcf_got:
        cmp     $64, %r11
        ja      1f
        bzhi    %r11, %rax, %rax
1:
        tzcnt   %rax, %rax                      /* CF = (mask == 0) */
        lea     (%rax,%r10), %rax
        cmovc   %r14, %rax
        cmp     %rax, %r13
        cmova   %rax, %r13
        add     $64, %r10
        cmp     $64, %r11
        ja      .Lcf_chunk
.Lcf_res:
        xor     %eax, %eax
        cmp     %r14, %r13
        cmove   %rax, %r13                      /* none: byte 0 (equal) */
        movzbl  (%rdi,%r13), %ebx
        movzbl  (%rsi,%r13), %r12d
        cmp     %r12d, %ebx
.Lcf_sign:
        seta    %al
        sbb     $0, %al                         /* (a > b) - (a < b) */
.Lcf_store:
        mov     %al, (%r8)
        inc     %r8
        add     %rdx, %rdi
        add     %rdx, %rsi
        sub     %rdx, %r9
        dec     %rcx
        jnz     .Lcf_rec
.Lcf_done:
        pop     %r14
        pop     %r13
        pop     %r12
        pop     %rbx
        vzeroupper
.Lcf_ret0:
        ret
.Lcf_tail:                                      /* within 64 B of the end: r11 < 64 */
        mov     $-1, %rax
        bzhi    %r11, %rax, %rax
        kmovq   %rax, %k1
        vmovdqu8 (%rdi,%r10), %zmm0{%k1}{z}
        vmovdqu8 (%rsi,%r10), %zmm1{%k1}{z}
        vpcmpb  $4, %zmm1, %zmm0, %k2
        kmovq   %k2, %rax
        jmp     .Lcf_got
.Lcf_zero:                                      /* width 0: all equal */
        movb    $0, (%r8)
        inc     %r8
        dec     %rcx
        jnz     .Lcf_zero
        ret
ENDF pqk_x86_avx512_compare_fixed

/* ------------------------------------------------------------------------
 * int pqk_x86_avx512_group_sum_i64(gid=rdi, values=rsi, validity=rdx, n=rcx,
 *                                  sums=r8, counts=r9, ngroups=[rsp+8])
 * Pass 1: vpcmpud "ngroups <= id" on 16 ids per zmm (unsigned compare is
 * native; ngroups == 0 flags every valid row, as required). Validity bytes
 * (kmovw) or a lane mask (tail) serve as write masks; 64 rows per step are
 * combined with korw/kortestw. ngroups > UINT32_MAX skips the check.
 * Pass 2: scalar scatter-add in row order (identical to the AVX2 variant:
 * no-check loop after the first overflow; set-bit iteration with validity).
 * r10 = row, r11 = ngroups / group id, r12b = overflow flag, r13 = rows
 * left, r14 = row base, r15 = validity bits, rbp = validity ptr.
 * ---------------------------------------------------------------------- */
FUNC pqk_x86_avx512_group_sum_i64
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
        vpbroadcastd %r11d, %zmm1
        test    %rdx, %rdx
        jnz     .Lg_p1v
.Lg_p1n64:
        mov     %rcx, %rax
        sub     %r10, %rax
        cmp     $64, %rax
        jb      .Lg_p1n16
        vpcmpud $2, (%rdi,%r10,4), %zmm1, %k1
        vpcmpud $2, 64(%rdi,%r10,4), %zmm1, %k2
        vpcmpud $2, 128(%rdi,%r10,4), %zmm1, %k3
        vpcmpud $2, 192(%rdi,%r10,4), %zmm1, %k4
        korw    %k2, %k1, %k1
        korw    %k4, %k3, %k3
        kortestw %k3, %k1
        jnz     .Lg_einval
        add     $64, %r10
        jmp     .Lg_p1n64
.Lg_p1n16:
        mov     %rcx, %rax
        sub     %r10, %rax
        cmp     $16, %rax
        jb      .Lg_p1t
        vpcmpud $2, (%rdi,%r10,4), %zmm1, %k1
        kortestw %k1, %k1
        jnz     .Lg_einval
        add     $16, %r10
        jmp     .Lg_p1n16
.Lg_p1v:
        mov     %rcx, %rax
        sub     %r10, %rax
        cmp     $16, %rax
        jb      .Lg_p1t
        mov     %r10, %rax
        shr     $3, %rax
        kmovw   (%rdx,%rax), %k4
        vmovdqu32 (%rdi,%r10,4), %zmm0
        vpcmpud $2, %zmm0, %zmm1, %k1{%k4}
        kortestw %k1, %k1
        jnz     .Lg_einval
        add     $16, %r10
        jmp     .Lg_p1v
.Lg_p1t:                                        /* < 16 rows left */
        mov     %rcx, %rax
        sub     %r10, %rax
        jz      .Lg_p2
        mov     $0xffff, %ebx
        bzhi    %eax, %ebx, %ebx                /* lane mask */
        test    %rdx, %rdx
        jz      1f
        mov     %r10, %r13
        shr     $3, %r13
        movzbl  (%rdx,%r13), %r14d
        cmp     $8, %eax
        jbe     2f
        movzbl  1(%rdx,%r13), %r15d
        shl     $8, %r15d
        or      %r15d, %r14d
2:      and     %r14d, %ebx
1:      kmovw   %ebx, %k4
        vmovdqu32 (%rdi,%r10,4), %zmm0{%k4}{z}
        vpcmpud $2, %zmm0, %zmm1, %k1{%k4}
        kortestw %k1, %k1
        jnz     .Lg_einval

.Lg_p2:
        test    %rcx, %rcx
        jz      .Lg_ok
        test    %rdx, %rdx
        jnz     .Lg_p2v
        xor     %r10d, %r10d
        test    %r9, %r9
        jz      .Lg_p2n
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
ENDF pqk_x86_avx512_group_sum_i64

/* ------------------------------------------------------------------------
 * void pqk_x86_avx512_gather_i64(data=rdi, idx=rsi, m=rdx, out=rcx)
 * Same as the AVX2 variant: 8 independent scalar loads per iteration (the
 * gather instruction measured slower for DRAM-resident columns).
 * ---------------------------------------------------------------------- */
FUNC pqk_x86_avx512_gather_i64
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
ENDF pqk_x86_avx512_gather_i64


/* ========================================================================
 * 128-bit kernels (CR-4, ABI revision 1). A pqk_i128 row is 16 bytes
 * {lo, hi}; row i is at data + 16*i (any alignment).
 *
 * A "group" is 8 rows = two 64-byte loads Z0 = [lo0 hi0 .. lo3 hi3],
 * Z1 = [lo4 hi4 .. lo7 hi7]. vpermt2q with the index vectors zmm14
 * (0,2,..,14) and zmm15 (1,3,..,15) de-interleaves them into
 *   L = [lo0 .. lo7] and H = [hi0 .. hi7]   (natural row order),
 * so k-mask bit j is row j and validity bytes can be used directly as
 * write masks. AVX-512 has unsigned compares, so signed 128-bit
 *   x < c  <=>  (x.hi <s c.hi) | (x.hi == c.hi & x.lo <u c.lo)
 * is vpcmpq + vpcmpq + vpcmpuq{masked} + korb. Tails use zero-masked loads
 * (architectural fault suppression); the hot loops use plain loads.
 * ====================================================================== */

        .section .rodata
        .p2align 6
        .type   c_idx_even, @object
c_idx_even:     .quad 0, 2, 4, 6, 8, 10, 12, 14
        .size   c_idx_even, . - c_idx_even
        .type   c_idx_odd, @object
c_idx_odd:      .quad 1, 3, 5, 7, 9, 11, 13, 15
        .size   c_idx_odd, . - c_idx_odd
/* [0, 2^63]: biases the high word of a row (sum_i128) */
        .type   c_hibias, @object
c_hibias:       .quad 0, 0x8000000000000000
        .size   c_hibias, . - c_hibias
/* kinds -> inversion for count_i128 (EQ NE LT LE GT GE BETWEEN) */
        .type   kinv128, @object
kinv128:        .byte 0, 1, 0, 1, 0, 1, 0
        .size   kinv128, . - kinv128
        .text

/* LG128 off[, k0, k1]: load the group at off(%rdi) into zmm0 = L, zmm1 = H
 * (zmm2 scratch). With k0/k1, zero-masked loads of the two halves. */
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

/* GLANES r: k4/k5 = lane masks for the first r (1..8) rows of a group
 * (2r qwords). in: \r (32-bit gpr, doubled on exit), clobbers edx. */
.macro GLANES r
        mov     $0xffff, %edx
        add     \r, \r                  /* clobbered: callers pass a copy */
        bzhi    \r, %edx, %edx
        kmovw   %edx, %k4
        kshiftrw $8, %k4, %k5
.endm

/* ------------------------------------------------------------------------
 * KP128 kind, k: predicate on L (zmm0) / H (zmm1) into \k (not k6/k7).
 * Constants: zmm8 = bcast a.lo, zmm9 = bcast a.hi, zmm10/zmm11 = b (BETWEEN).
 * Kinds: 0 EQ, 1 LT (x < a), 2 GT (x > a), 3 IN (a <= x <= b); operators are
 * (kind, invert) = EQ (0,0) NE (0,1) LT (1,0) LE (2,1) GT (2,0) GE (1,1)
 * BETWEEN (3,0). IN with a > b is empty automatically. clobbers k6, k7.
 * ---------------------------------------------------------------------- */
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

/* ------------------------------------------------------------------------
 * Mask routines kop128_*: in rdi = block ptr, esi = len (1..64), constants
 * as above, zmm14/zmm15 = de-interleave indices. out rax = mask with
 * exactly len bits. clobbers rcx, rdx, rdi, rsi, r10, r11, k1-k7,
 * zmm0-zmm2.
 * Full block: 8 groups, k-masks merged with kunpckbw/wd/dq. Partial block:
 * groups with zero-masked loads, kmovb + shlx, then bzhi to len.
 * ---------------------------------------------------------------------- */
.macro KOP128 name, kind, inv
LFUNC \name
        cmp     $64, %esi
        jne     .Lpart\@
        LG128   0
        KP128   \kind, %k1
        LG128   128
        KP128   \kind, %k2
        kunpckbw %k1, %k2, %k1
        LG128   256
        KP128   \kind, %k2
        LG128   384
        KP128   \kind, %k3
        kunpckbw %k2, %k3, %k2
        kunpckwd %k1, %k2, %k1
        LG128   512
        KP128   \kind, %k2
        LG128   640
        KP128   \kind, %k3
        kunpckbw %k2, %k3, %k2
        LG128   768
        KP128   \kind, %k3
        LG128   896
        KP128   \kind, %k4
        kunpckbw %k3, %k4, %k3
        kunpckwd %k2, %k3, %k2
        kunpckdq %k1, %k2, %k1
        kmovq   %k1, %rax
.if \inv
        not     %rax
.endif
        ret
.Lpart\@:
        mov     %esi, %r10d
        xor     %eax, %eax
        xor     %ecx, %ecx
1:      mov     $8, %edx
        cmp     %edx, %esi
        cmovb   %esi, %edx
        mov     %edx, %r11d
        GLANES  %r11d
        LG128   0, %k4, %k5
        KP128   \kind, %k1
        kmovb   %k1, %edx
        shlx    %rcx, %rdx, %rdx
        or      %rdx, %rax
        sub     $-128, %rdi
        add     $8, %ecx
        sub     $8, %esi
        jg      1b
.if \inv
        not     %rax
.endif
        bzhi    %r10, %rax, %rax
        ret
ENDF \name
.endm

        KOP128 kop128_eq, 0, 0
        KOP128 kop128_ne, 0, 1
        KOP128 kop128_lt, 1, 0
        KOP128 kop128_le, 2, 1
        KOP128 kop128_gt, 2, 0
        KOP128 kop128_ge, 1, 1
        KOP128 kop128_bt, 3, 0

/* Direct counters for count_i128 without validity: in rdi = data,
 * rdx = rows (>= 1). out rax = number of rows where the KIND holds
 * (inversion applied by the caller). Two groups per step: predicate -> k,
 * merge-masked "acc -= -1"; the last 1..15 rows use zero-masked groups whose
 * k is ANDed with the row mask. clobbers rcx, rdx, rdi, r10, zmm0-zmm5,
 * k1-k7. */
.macro KCNT128 name, kind
LFUNC \name
        vpxorq  %zmm4, %zmm4, %zmm4
        vpxorq  %zmm5, %zmm5, %zmm5
        vpternlogd $0xff, %zmm3, %zmm3, %zmm3   /* all ones = -1 */
        mov     %rdx, %r10
1:      cmp     $16, %r10
        jb      2f
        LG128   0
        KP128   \kind, %k1
        vpsubq  %zmm3, %zmm4, %zmm4{%k1}
        LG128   128
        KP128   \kind, %k2
        vpsubq  %zmm3, %zmm5, %zmm5{%k2}
        add     $256, %rdi
        sub     $16, %r10
        jmp     1b
2:      test    %r10, %r10
        jz      3f
        mov     $8, %ecx
        cmp     %rcx, %r10
        cmovb   %r10, %rcx
        mov     $0xff, %edx
        bzhi    %ecx, %edx, %edx
        kmovb   %edx, %k3               /* rows */
        GLANES  %ecx
        LG128   0, %k4, %k5
        KP128   \kind, %k1
        kandb   %k3, %k1, %k1
        vpsubq  %zmm3, %zmm4, %zmm4{%k1}
        sub     $-128, %rdi
        sub     $8, %r10
        jg      2b
3:      vpaddq  %zmm5, %zmm4, %zmm4
        HSUMZ   %zmm4, %ymm4, %xmm4, %ymm0, %xmm0, %rax
        ret
ENDF \name
.endm

        KCNT128 kcnt128_k0, 0
        KCNT128 kcnt128_k1, 1
        KCNT128 kcnt128_k2, 2
        KCNT128 kcnt128_k3, 3

        .section .rodata
        .p2align 2
        .type   kop128_table, @object
kop128_table:
        .long   kop128_eq - kop128_table, kop128_ne - kop128_table
        .long   kop128_lt - kop128_table, kop128_le - kop128_table
        .long   kop128_gt - kop128_table, kop128_ge - kop128_table
        .long   kop128_bt - kop128_table
        .size   kop128_table, . - kop128_table
        .type   kcnt128_table, @object
kcnt128_table:
        .long   kcnt128_k0 - kcnt128_table, kcnt128_k0 - kcnt128_table
        .long   kcnt128_k1 - kcnt128_table, kcnt128_k2 - kcnt128_table
        .long   kcnt128_k2 - kcnt128_table, kcnt128_k1 - kcnt128_table
        .long   kcnt128_k3 - kcnt128_table
        .size   kcnt128_table, . - kcnt128_table
        .text

/* ------------------------------------------------------------------------
 * Predicate driver for filter_i128 (mode 0) and count_i128 (mode 2).
 * Args: rdi = data, rsi = validity, rdx = n, ecx = op, r8 = &a, r9 = &b,
 *       [rsp+8] = out_idx (mode 0).
 * The op is checked first (unsigned compare, so negative ints are rejected
 * too); an invalid op returns (size_t)-1 before a or b is touched. b is read
 * only for BETWEEN; a always (also for n == 0).
 * Registers: r12 = block data ptr, r13 = validity ptr (0 = all valid),
 * r14 = rows remaining, r15 = mask routine, rbx = row base (mode 0) /
 * count (mode 2), rbp = output ptr, (%rsp) = output start; zmm8-11 = a/b
 * constants, zmm14/15 = indices, zmm4 = row indices for vpcompressd,
 * zmm5 = iota, zmm6 = bcast(16).
 * Per 64-row block: mask & validity word (8-byte load, or exactly
 * ceil(len/8) bytes via lvp for the last block); filter emits with
 * vpcompressd (16 rows per step; the 64-byte store stays inside out_idx
 * since outputs-so-far <= rows consumed) for full blocks and tzcnt/blsr for
 * the last one; count popcnts. count without validity uses KCNT128.
 * ---------------------------------------------------------------------- */
.macro P128_DRIVER mode
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
        lea     kop128_table(%rip), %rax
        movslq  (%rax,%rcx,4), %r15
        add     %rax, %r15
        cmp     $6, %ecx
        jne     1f
        vpbroadcastq (%r9), %zmm10      /* b (BETWEEN only) */
        vpbroadcastq 8(%r9), %zmm11
1:      vpbroadcastq (%r8), %zmm8       /* a */
        vpbroadcastq 8(%r8), %zmm9
        vmovdqu64 c_idx_even(%rip), %zmm14
        vmovdqu64 c_idx_odd(%rip), %zmm15
        mov     %rdi, %r12
        mov     %rsi, %r13
        mov     %rdx, %r14
        xor     %ebx, %ebx
.if \mode == 0
        vmovdqu32 iota16(%rip), %zmm5
        vpbroadcastd c_sixteen_d(%rip), %zmm6
.endif
.if \mode == 2
        test    %r13, %r13
        jnz     .Lstart\@
        test    %r14, %r14
        jz      .Lstart\@
        lea     kcnt128_table(%rip), %rax
        movslq  (%rax,%rcx,4), %r10
        add     %rax, %r10
        mov     %r12, %rdi
        mov     %r14, %rdx
        push    %rcx
        call    *%r10
        pop     %rcx
        lea     kinv128(%rip), %r10
        cmpb    $0, (%r10,%rcx)
        je      1f
        neg     %rax
        add     %r14, %rax
1:      mov     %rax, %rbx
        jmp     .Ldone\@
.Lstart\@:
.endif
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
        cmp     $64, %r14
        jb      .Lsparse\@
        test    %rax, %rax
        jz      .Lnext\@
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
.else
        popcnt  %rax, %rax
        add     %rax, %rbx
.endif
        add     $1024, %r12
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

/* size_t pqk_x86_avx512_filter_i128(data, validity, n, op, a, b, out_idx)
 * Register usage / algorithm: P128_DRIVER mode 0, KOP128, KP128, LG128. */
FUNC pqk_x86_avx512_filter_i128
        P128_DRIVER 0
ENDF pqk_x86_avx512_filter_i128

/* size_t pqk_x86_avx512_count_i128(data, validity, n, op, a, b)
 * Register usage / algorithm: P128_DRIVER mode 2, KCNT128, KOP128. */
FUNC pqk_x86_avx512_count_i128
        P128_DRIVER 2
ENDF pqk_x86_avx512_count_i128

/* ------------------------------------------------------------------------
 * int pqk_x86_avx512_sum_i128(data=rdi, validity=rsi, n=rdx, out_sum=rcx)
 *
 * Same exact algorithm as pqk_x86_avx2_sum_i128, on 4 rows per zmm:
 * each 64-bit word is accumulated unsigned (high words biased by 2^63:
 * x = lo + 2^64 (hi ^ 2^63) - 2^127) as S = sum mod 2^64 and H = sum(v>>>32);
 * the exact lane sum is E = H*2^32 + L with L = (S - H*2^32) mod 2^64
 * (chunks <= SUM128_CHUNK_ROWS = 2^28 rows keep H, L < 2^60). fold512 adds
 * the lanes (even: weight 1, odd: 2^64) into the 192-bit total r10:r9:r8,
 * and at the end T -= cnt * 2^127, cnt = number of rows that were biased.
 * Overflow iff T's top word != sign extension of its middle word; *out_sum
 * is written only on PQK_OK.
 * Rows that must not count (invalid, or beyond n in a tail) are removed by
 * a zero-masking vpxorq: their lanes become 0 (not biased, not counted).
 * Validity: a 64-row word is expanded to a 128-bit lane mask (each bit
 * doubled: pdep with 0x5555.. then *3); one byte per 4-row load goes to k1.
 * Tails (< 16 rows without validity, final partial block with validity)
 * use zero-masked loads with the same lane mask.
 * Registers: rdi = row ptr, rsi = validity ptr, r11 = rows remaining,
 * r12 = chunk counter, rbx = cnt, (%rsp) = out_sum, r8-r10 = T,
 * rax/rcx/rdx scratch (lane masks); zmm4/zmm5 = S0/S1, zmm6/zmm7 = H0/H1,
 * zmm8 = [0, 2^63] x 4, zmm0 scratch.
 * ---------------------------------------------------------------------- */
#ifndef SUM128_CHUNK_ROWS               /* overridable to test the fold path */
#define SUM128_CHUNK_ROWS (1 << 28)     /* multiple of 64 */
#endif

/* fold512: T += exact value of (S0+S1, H0+H1); zeroes zmm4-zmm7.
 * clobbers rax, rcx, rdx, zmm0, zmm1. */
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
        ret
ENDF fold512

/* ZS128 s, h: accumulate zmm0 into S\s / H\h */
.macro ZS128 s, h
        vpaddq  %zmm0, %zmm\s, %zmm\s
        vpsrlq  $32, %zmm0, %zmm0
        vpaddq  %zmm0, %zmm\h, %zmm\h
.endm

/* DOUBLE2 w(gpr64, clobbered), lo, hi: 128-bit lane mask hi:lo from the
 * 64-row validity word: bit j -> bits 2j, 2j+1. clobbers rcx. */
.macro DOUBLE2 w, lo, hi
        movabs  $0x5555555555555555, %rcx
        pdep    %rcx, \w, \lo
        shr     $32, \w
        pdep    %rcx, \w, \hi
        lea     (\lo,\lo,2), \lo
        lea     (\hi,\hi,2), \hi
.endm

FUNC pqk_x86_avx512_sum_i128
        push    %rbx
        push    %r12
        push    %rcx                    /* (%rsp) = out_sum */
        xor     %r8d, %r8d
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
        jnz     .Lz128s_valid
        cmp     $16, %r11
        jb      .Lz128s_tail
        mov     $(SUM128_CHUNK_ROWS / 16), %r12d
.Lz128s_unit:
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
        jnz     1f
        call    fold512
        mov     $(SUM128_CHUNK_ROWS / 16), %r12d
1:      cmp     $16, %r11
        jae     .Lz128s_unit
.Lz128s_tail:                           /* 0..15 rows, all valid */
        test    %r11, %r11
        jz      .Lz128s_end
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
        jmp     .Lz128s_tail
.Lz128s_valid:
        mov     $(SUM128_CHUNK_ROWS / 64), %r12d
.Lz128s_blk:
        cmp     $64, %r11
        jb      .Lz128s_vpart
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
        jnz     .Lz128s_blk
        call    fold512
        mov     $(SUM128_CHUNK_ROWS / 64), %r12d
        jmp     .Lz128s_blk
.Lz128s_vpart:                          /* 0..63 rows */
        test    %r11, %r11
        jz      .Lz128s_end
        mov     %r11d, %ecx
        call    lvp                     /* exactly ceil(rows/8) bytes */
        bzhi    %r11, %rax, %rax        /* only rows < len */
        popcnt  %rax, %rdx
        add     %rdx, %rbx
        DOUBLE2 %rax, %rdx, %rax
        lea     3(%r11), %r11
        shr     $2, %r11                /* loads of 4 rows */
1:      kmovb   %edx, %k1
        shrd    $8, %rax, %rdx
        shr     $8, %rax
        vmovdqu64 (%rdi), %zmm0{%k1}{z}
        vpxorq  %zmm8, %zmm0, %zmm0{%k1}{z}
        ZS128   4, 6
        add     $64, %rdi
        dec     %r11
        jnz     1b
.Lz128s_end:
        call    fold512
        mov     %rbx, %rax              /* T -= cnt * 2^127 */
        shr     $1, %rax
        sub     %rax, %r10
        test    $1, %bl
        jz      1f
        movabs  $0x8000000000000000, %rax
        sub     %rax, %r9
        sbb     $0, %r10
1:      mov     %r9, %rax
        sar     $63, %rax
        cmp     %rax, %r10
        jne     .Lz128s_ovf
        pop     %rcx
        mov     %r8, (%rcx)
        mov     %r9, 8(%rcx)
        xor     %eax, %eax
        jmp     .Lz128s_ret
.Lz128s_ovf:
        pop     %rcx
        mov     $1, %eax
.Lz128s_ret:
        pop     %r12
        pop     %rbx
        vzeroupper
        ret
ENDF pqk_x86_avx512_sum_i128

/* ------------------------------------------------------------------------
 * size_t pqk_x86_avx512_minmax_i128(data=rdi, validity=rsi, n=rdx,
 *                                   out_min=rcx, out_max=r8)
 *
 * Lane-wise 128-bit min/max over de-interleaved 8-row groups:
 *   lt = (x.hi <s min.hi) | (x.hi == min.hi & x.lo <u min.lo)   (k-masks)
 *   min.{lo,hi} = lt ? x : min   (merge-masked vmovdqa64), same for max.
 * The compares are write-masked with the group's validity byte (k3), so
 * invalid rows never update anything. Two accumulator sets (A: zmm4-7,
 * B: zmm8-11 = minL, minH, maxL, maxH) alternate between groups to halve
 * the dependency chains; they start at INT128_MAX / INT128_MIN (neutral).
 * The count is popcnt of the validity words (bzhi'd to n in the last
 * block) or n. Tail groups (< 8 rows, or the final partial block) use
 * zero-masked loads and a row mask. At the end B is merged into A, A is
 * spilled and its 8 lanes are folded in scalar code into r13:r12 (min) and
 * r15:r14 (max) with cmp/sbb + cmovl.
 * Registers: rdi = row ptr, rsi = validity ptr, r11 = rows remaining,
 * rbx = count, rbp = validity word, rax/rcx/rdx scratch; zmm0/zmm1 = L/H,
 * zmm2 scratch, zmm14/zmm15 = indices, k1/k2 compare temps, k3 = row mask,
 * k4/k5 = load lane masks. Stack: 0..255 spill, 256 = out_max,
 * 264 = out_min.
 * ---------------------------------------------------------------------- */

/* ZMM128 mnl, mnh, mxl, mxh, vk: update one accumulator set with the group
 * in zmm0/zmm1 (rows selected by \vk, or all rows if blank). */
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

/* scalar 128-bit updates: candidate rdx:rax; clobber rcx */
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

/* ZTAIL: masked group of r11 rows (1..8 used) selected by k3 & validity in
 * ebp's low byte (or all rows: ebp = -1); advances rdi/r11/rbp. */
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

FUNC pqk_x86_avx512_minmax_i128
        push    %rbx
        push    %rbp
        push    %r12
        push    %r13
        push    %r14
        push    %r15
        push    %rcx                    /* out_min */
        push    %r8                     /* out_max */
        sub     $256, %rsp
        vmovdqu64 c_idx_even(%rip), %zmm14
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
        jnz     .Lz128m_vblk
        mov     %r11, %rbx              /* count = n */
        cmp     $16, %r11
        jb      2f
1:      LG128   0
        ZMM128  4, 5, 6, 7
        LG128   128
        ZMM128  8, 9, 10, 11
        add     $256, %rdi
        sub     $16, %r11
        cmp     $16, %r11
        jae     1b
2:      mov     $-1, %rbp
3:      test    %r11, %r11
        jz      .Lz128m_reduce
        ZTAIL
        sub     $8, %r11
        ja      3b
        jmp     .Lz128m_reduce
.Lz128m_vblk:
        test    %r11, %r11
        jz      .Lz128m_reduce
        cmp     $64, %r11
        jb      .Lz128m_vpart
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
        jmp     .Lz128m_vblk
.Lz128m_vpart:
        mov     %r11d, %ecx
        call    lvp                     /* exactly ceil(rows/8) bytes */
        bzhi    %r11, %rax, %rbp
        popcnt  %rbp, %rax
        add     %rax, %rbx
3:      ZTAIL
        sub     $8, %r11
        ja      3b
.Lz128m_reduce:
        /* merge B into A: B.min / B.max as candidates */
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
        vmovdqu64 %zmm4, 0(%rsp)
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
        jz      1f
        mov     264(%rsp), %rcx
        mov     256(%rsp), %rdx
        mov     %r12, (%rcx)
        mov     %r13, 8(%rcx)
        mov     %r14, (%rdx)
        mov     %r15, 8(%rdx)
1:      add     $272, %rsp
        pop     %r15
        pop     %r14
        pop     %r13
        pop     %r12
        pop     %rbp
        pop     %rbx
        vzeroupper
        ret
ENDF pqk_x86_avx512_minmax_i128

        .section .note.GNU-stack, "", @progbits
