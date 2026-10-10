/*
 * pqk_x86_scalar.S — PolyQuery native kernels, variant "x86_scalar".
 *
 * Baseline x86-64 only (no POPCNT/BMI/AVX; SSE2 scalar double ops only), so
 * this variant runs on every x86-64 CPU. All 16 kernels of pq_kernels.h are
 * provided as global symbols pqk_x86_scalar_<kernel>, System V AMD64 ABI.
 *
 * Common structure of the predicate kernels (filter_i64, filter_i64_bitmap,
 * count_i64, compare_i64):
 *   rows are processed in blocks of 64. A per-operator "mask routine"
 *   (sop_* / scmp_*) evaluates the predicate for one block and returns a
 *   64-bit row mask in rax (bit j = row j of the block, bits >= len zero). The
 *   routine is selected once per call through a PIC-relative jump table and
 *   called once per block. The driver ANDs the mask with the 64-bit validity
 *   word (one unaligned 8-byte load for full blocks, byte loads for the final
 *   partial block so nothing past ceil(n/8) is touched) and then consumes it:
 *   bit iteration (bsf / x&(x-1)) for filter_i64, an 8-byte (or per-byte for
 *   the tail) store for bitmaps, SWAR popcount for counts.
 *
 * Internal (non-ABI) helper calling conventions are documented at each
 * helper. They never touch the stack except for call/ret, so the ABI stack
 * alignment of the public entry points is irrelevant to them. No red zone is
 * used anywhere. Public functions save/restore every callee-saved register
 * they use (rbx, rbp, r12-r15).
 *
 * Register usage per kernel is described in front of each function.
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

/* ------------------------------------------------------------------------
 * Helpers
 * ---------------------------------------------------------------------- */

/* popcnt64: rax <- popcount(rax) (SWAR, no POPCNT instruction).
 * clobbers rdx, r11. */
LFUNC popcnt64
        mov     %rax, %rdx
        shr     $1, %rdx
        movabs  $0x5555555555555555, %r11
        and     %r11, %rdx
        sub     %rdx, %rax
        movabs  $0x3333333333333333, %r11
        mov     %rax, %rdx
        shr     $2, %rdx
        and     %r11, %rax
        and     %r11, %rdx
        add     %rdx, %rax
        mov     %rax, %rdx
        shr     $4, %rdx
        add     %rdx, %rax
        movabs  $0x0f0f0f0f0f0f0f0f, %r11
        and     %r11, %rax
        movabs  $0x0101010101010101, %r11
        imul    %r11, %rax
        shr     $56, %rax
        ret
ENDF popcnt64

/* lvp: load a partial little-endian validity word.
 * in: rsi = pointer to validity byte of the block's first row,
 *     ecx = len (1..64) rows. Loads exactly ceil(len/8) bytes.
 * out: rax (bits beyond the loaded bytes are 0; bits >= len inside the last
 *      byte are NOT cleared — callers AND with an already len-limited mask).
 * clobbers rcx, rdx. */
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
 * Predicate mask routines for x op (a, b).
 * in:  rdi = pointer to first row of the block, esi = len (1..64),
 *      r8 = a, r9 = b (sop_bt: r9 = b - a with a <= b, see PRED_DRIVER).
 * out: rax = mask, bit j set iff predicate holds for row j (bits >= len 0).
 * clobbers rcx, rdx, rdi, rsi, r10, r11.
 * Algorithm: forward walk (prefetch friendly), 8 rows per step with fixed
 * shifts (independent setcc chains), the byte is then shifted into place by
 * cl = row offset; 1..7 leftover rows one at a time.
 * BETWEEN uses the unsigned range trick (x - a) <=u (b - a).
 * ---------------------------------------------------------------------- */
.macro SPRED cc
.ifc \cc, bt
        sub     %r8, %rdx
        cmp     %r9, %rdx
        setbe   %r10b
.else
        cmp     %r8, %rdx               /* flags of x - a */
        set\cc  %r10b
.endif
.endm

.macro SOP name, cc
LFUNC \name
        xor     %eax, %eax
        xor     %ecx, %ecx
        cmp     $8, %esi
        jb      3f
1:      xor     %r11d, %r11d
        .set j, 0
        .rept 8
        mov     j*8(%rdi), %rdx
        xor     %r10d, %r10d
        SPRED   \cc
        .if j
        shl     $j, %r10d
        .endif
        or      %r10d, %r11d
        .set j, j + 1
        .endr
        shl     %cl, %r11
        or      %r11, %rax
        add     $64, %rdi
        add     $8, %ecx
        sub     $8, %esi
        cmp     $8, %esi
        jae     1b
3:      test    %esi, %esi
        jz      5f
4:      mov     (%rdi), %rdx
        xor     %r10d, %r10d
        SPRED   \cc
        shl     %cl, %r10
        or      %r10, %rax
        add     $8, %rdi
        inc     %ecx
        dec     %esi
        jnz     4b
5:      ret
ENDF \name
.endm

        SOP sop_eq, e
        SOP sop_ne, ne
        SOP sop_lt, l
        SOP sop_le, le
        SOP sop_gt, g
        SOP sop_ge, ge
        SOP sop_bt, bt

/* BETWEEN with a > b: empty predicate. */
LFUNC sop_false
        xor     %eax, %eax
        ret
ENDF sop_false

/* Element-wise compare routines for a[i] op b[i].
 * in:  rdi = &a[block], rsi = &b[block], edx = len (1..64).
 * out: rax = mask (bits >= len 0).
 * clobbers rcx, rdx, rdi, rsi, r9, r10, r11. Same forward 8-row scheme. */
.macro SCMP name, cc
LFUNC \name
        xor     %eax, %eax
        xor     %ecx, %ecx
        mov     %edx, %r9d
        cmp     $8, %r9d
        jb      3f
1:      xor     %r11d, %r11d
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
        jae     1b
3:      test    %r9d, %r9d
        jz      5f
4:      mov     (%rdi), %rdx
        xor     %r10d, %r10d
        cmp     (%rsi), %rdx
        set\cc  %r10b
        shl     %cl, %r10
        or      %r10, %rax
        add     $8, %rdi
        add     $8, %rsi
        inc     %ecx
        dec     %r9d
        jnz     4b
5:      ret
ENDF \name
.endm

        SCMP scmp_eq, e
        SCMP scmp_ne, ne
        SCMP scmp_lt, l
        SCMP scmp_le, le
        SCMP scmp_gt, g
        SCMP scmp_ge, ge

        .section .rodata
        .p2align 2
        .type   sop_table, @object
sop_table:
        .long   sop_eq - sop_table, sop_ne - sop_table, sop_lt - sop_table
        .long   sop_le - sop_table, sop_gt - sop_table, sop_ge - sop_table
        .long   sop_bt - sop_table
        .size   sop_table, . - sop_table
        .type   scmp_table, @object
scmp_table:
        .long   scmp_eq - scmp_table, scmp_ne - scmp_table, scmp_lt - scmp_table
        .long   scmp_le - scmp_table, scmp_gt - scmp_table, scmp_ge - scmp_table
        .size   scmp_table, . - scmp_table
        .text

/* ------------------------------------------------------------------------
 * Predicate driver shared by filter_i64 (mode 0), filter_i64_bitmap (mode 1)
 * and count_i64 (mode 2).
 * Args: rdi=data rsi=validity rdx=n ecx=op r8=a r9=b [rsp+8]=out (modes 0,1)
 * Registers: r12 = block data ptr, r13 = validity ptr (0 = all valid),
 *            r14 = rows remaining, r15 = mask routine, rbx = row index of
 *            block (mode 0) / set-bit count (modes 1,2), rbp = output ptr.
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
        mov     56(%rsp), %rbp          /* 7th argument (out) */
        push    %rbp                    /* (%rsp) = start of output */
        mov     %ecx, %ecx
        lea     sop_table(%rip), %rax
        movslq  (%rax,%rcx,4), %r15
        add     %rax, %r15
        cmp     $6, %ecx                /* BETWEEN: r9 = b - a, or empty */
        jne     .Lnotbt\@
        lea     sop_false(%rip), %rax
        cmp     %r9, %r8
        cmovg   %rax, %r15
        sub     %r8, %r9
.Lnotbt\@:
        mov     %rdi, %r12
        mov     %rsi, %r13
        mov     %rdx, %r14
        xor     %ebx, %ebx
        test    %r14, %r14
        jz      .Ldone\@
.Lloop\@:
        mov     $64, %esi
        cmp     %rsi, %r14
        cmovb   %r14, %rsi              /* len = min(64, remaining) */
        mov     %r12, %rdi
        call    *%r15                   /* rax = predicate mask */
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
        test    %rax, %rax
        jz      .Lnext\@
.Lbits\@:
        bsf     %rax, %rcx
        add     %ebx, %ecx
        mov     %ecx, (%rbp)
        add     $4, %rbp
        lea     -1(%rax), %rdx
        and     %rdx, %rax
        jnz     .Lbits\@
.Lnext\@:
        add     $64, %rbx
.elseif \mode == 1
        cmp     $64, %r14
        jb      .Lspart\@
        mov     %rax, (%rbp)
        add     $8, %rbp
        jmp     .Lcnt\@
.Lspart\@:
        mov     %rax, %r10
        lea     7(%r14), %ecx
        shr     $3, %ecx                /* ceil(len/8) bytes */
.Lsb\@: mov     %al, (%rbp)
        inc     %rbp
        shr     $8, %rax
        dec     %ecx
        jnz     .Lsb\@
        mov     %r10, %rax
.Lcnt\@:
        call    popcnt64
        add     %rax, %rbx
.else
        call    popcnt64
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
        ret
.Linval\@:
        mov     $-1, %rax
        ret
.endm

/* size_t pqk_x86_scalar_filter_i64(data, validity, n, op, a, b, out_idx) */
FUNC pqk_x86_scalar_filter_i64
        PRED_DRIVER 0
ENDF pqk_x86_scalar_filter_i64

/* size_t pqk_x86_scalar_filter_i64_bitmap(data, validity, n, op, a, b, out_bits) */
FUNC pqk_x86_scalar_filter_i64_bitmap
        PRED_DRIVER 1
ENDF pqk_x86_scalar_filter_i64_bitmap

/* size_t pqk_x86_scalar_count_i64(data, validity, n, op, a, b) */
FUNC pqk_x86_scalar_count_i64
        PRED_DRIVER 2
ENDF pqk_x86_scalar_count_i64

/* ------------------------------------------------------------------------
 * size_t pqk_x86_scalar_compare_i64(a=rdi, b=rsi, n=rdx, op=ecx, out=r8)
 * r12 = a block, r13 = b block, r14 = remaining, r15 = routine,
 * rbx = set-bit count, rbp = out ptr.
 * ---------------------------------------------------------------------- */
FUNC pqk_x86_scalar_compare_i64
        cmp     $5, %ecx
        ja      .Lci_inval
        push    %rbx
        push    %rbp
        push    %r12
        push    %r13
        push    %r14
        push    %r15
        mov     %ecx, %ecx
        lea     scmp_table(%rip), %rax
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
        cmp     $64, %r14
        jb      .Lci_part
        mov     %rax, (%rbp)
        add     $8, %rbp
        jmp     .Lci_cnt
.Lci_part:
        mov     %rax, %r10
        lea     7(%r14), %ecx
        shr     $3, %ecx
1:      mov     %al, (%rbp)
        inc     %rbp
        shr     $8, %rax
        dec     %ecx
        jnz     1b
        mov     %r10, %rax
.Lci_cnt:
        call    popcnt64
        add     %rax, %rbx
        add     $512, %r12
        add     $512, %r13
        sub     $64, %r14
        ja      .Lci_loop
.Lci_done:
        mov     %rbx, %rax
        pop     %r15
        pop     %r14
        pop     %r13
        pop     %r12
        pop     %rbp
        pop     %rbx
        ret
.Lci_inval:
        mov     $-1, %rax
        ret
ENDF pqk_x86_scalar_compare_i64

/* ------------------------------------------------------------------------
 * int pqk_x86_scalar_sum_i64(data=rdi, validity=rsi, n=rdx, out_sum=rcx)
 * Exact 128-bit accumulation in r9:r8 (hi:lo): add x; adc sign(x) (cqo).
 * Invalid rows are zeroed branchlessly: shr validity word -> CF, sbb -> mask.
 * r10 = remaining rows, r11 = out_sum, rbx = validity word.
 * Overflow iff hi != sign-extension of lo.
 * ---------------------------------------------------------------------- */
FUNC pqk_x86_scalar_sum_i64
        push    %rbx
        xor     %r8d, %r8d
        xor     %r9d, %r9d
        mov     %rcx, %r11
        mov     %rdx, %r10
        test    %r10, %r10
        jz      .Lsi_fin
        test    %rsi, %rsi
        jnz     .Lsi_vblk
        /* no validity: 4x unrolled, then single rows */
        cmp     $4, %r10
        jb      .Lsi_one
.Lsi_four:
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
        jae     .Lsi_four
        test    %r10, %r10
        jz      .Lsi_fin
.Lsi_one:
        mov     (%rdi), %rax
        cqo
        add     %rax, %r8
        adc     %rdx, %r9
        add     $8, %rdi
        dec     %r10
        jnz     .Lsi_one
        jmp     .Lsi_fin
.Lsi_vblk:
        mov     $64, %ecx
        cmp     %rcx, %r10
        jb      .Lsi_vpart
        mov     (%rsi), %rbx
        jmp     .Lsi_vrow
.Lsi_vpart:
        mov     %r10d, %ecx
        call    lvp
        mov     %rax, %rbx
        mov     %r10d, %ecx
.Lsi_vrow:
        mov     (%rdi), %rax
        shr     $1, %rbx                /* CF = validity bit */
        sbb     %rdx, %rdx
        and     %rdx, %rax
        cqo
        add     %rax, %r8
        adc     %rdx, %r9
        add     $8, %rdi
        dec     %ecx
        jnz     .Lsi_vrow
        add     $8, %rsi
        sub     $64, %r10
        ja      .Lsi_vblk
.Lsi_fin:
        mov     %r8, %rax
        sar     $63, %rax
        cmp     %rax, %r9
        jne     .Lsi_ovf
        mov     %r8, (%r11)
        xor     %eax, %eax
        pop     %rbx
        ret
.Lsi_ovf:
        mov     $1, %eax
        pop     %rbx
        ret
ENDF pqk_x86_scalar_sum_i64

/* ------------------------------------------------------------------------
 * double pqk_x86_scalar_sum_f64(data=rdi, validity=rsi, n=rdx)
 * Sequential addsd in row order into xmm0 (bit-identical to the reference).
 * Invalid rows are replaced by +0.0 (bit pattern 0) branchlessly; since the
 * running sum starts at +0.0 it can never be -0.0, so s + 0.0 == s exactly.
 * r10 = remaining rows, rbx = validity word, rax/rdx scratch.
 * ---------------------------------------------------------------------- */
FUNC pqk_x86_scalar_sum_f64
        push    %rbx
        xorpd   %xmm0, %xmm0
        mov     %rdx, %r10
        test    %r10, %r10
        jz      .Lsf64_done
        test    %rsi, %rsi
        jnz     .Lsf64_vblk
1:      addsd   (%rdi), %xmm0
        add     $8, %rdi
        dec     %r10
        jnz     1b
        jmp     .Lsf64_done
.Lsf64_vblk:
        mov     $64, %ecx
        cmp     %rcx, %r10
        jb      .Lsf64_vpart
        mov     (%rsi), %rbx
        jmp     .Lsf64_vrow
.Lsf64_vpart:
        mov     %r10d, %ecx
        call    lvp
        mov     %rax, %rbx
        mov     %r10d, %ecx
.Lsf64_vrow:
        mov     (%rdi), %rax
        shr     $1, %rbx
        sbb     %rdx, %rdx
        and     %rdx, %rax
        movq    %rax, %xmm1
        addsd   %xmm1, %xmm0
        add     $8, %rdi
        dec     %ecx
        jnz     .Lsf64_vrow
        add     $8, %rsi
        sub     $64, %r10
        ja      .Lsf64_vblk
.Lsf64_done:
        pop     %rbx
        ret
ENDF pqk_x86_scalar_sum_f64

/* ------------------------------------------------------------------------
 * size_t pqk_x86_scalar_minmax_i64(data=rdi, validity=rsi, n=rdx,
 *                                  out_min=rcx, out_max=r8)
 * r12 = lo, r13 = hi, r14 = count, r15 = out_min, rbp = out_max,
 * r10 = remaining, rbx = validity word, r9 = INT64_MAX, r11 = INT64_MIN.
 * Invalid rows: x is replaced by the neutral element (cmovnc on the CF from
 * shifting the validity word) and the count is incremented with adc.
 * ---------------------------------------------------------------------- */
FUNC pqk_x86_scalar_minmax_i64
        push    %rbx
        push    %rbp
        push    %r12
        push    %r13
        push    %r14
        push    %r15
        mov     %rcx, %r15
        mov     %r8, %rbp
        movabs  $0x7fffffffffffffff, %r9
        movabs  $0x8000000000000000, %r11
        mov     %r9, %r12
        mov     %r11, %r13
        xor     %r14d, %r14d
        mov     %rdx, %r10
        test    %r10, %r10
        jz      .Lmi_fin
        test    %rsi, %rsi
        jnz     .Lmi_vblk
        mov     %r10, %r14
1:      mov     (%rdi), %rax
        cmp     %rax, %r12
        cmovg   %rax, %r12
        cmp     %rax, %r13
        cmovl   %rax, %r13
        add     $8, %rdi
        dec     %r10
        jnz     1b
        jmp     .Lmi_fin
.Lmi_vblk:
        mov     $64, %ecx
        cmp     %rcx, %r10
        jb      .Lmi_vpart
        mov     (%rsi), %rbx
        jmp     .Lmi_vrow
.Lmi_vpart:
        mov     %r10d, %ecx
        call    lvp
        mov     %rax, %rbx
        mov     %r10d, %ecx
.Lmi_vrow:
        mov     (%rdi), %rax
        mov     %rax, %rdx
        shr     $1, %rbx                /* CF = valid */
        cmovnc  %r9, %rax               /* invalid -> INT64_MAX for min */
        cmovnc  %r11, %rdx              /* invalid -> INT64_MIN for max */
        adc     $0, %r14
        cmp     %rax, %r12
        cmovg   %rax, %r12
        cmp     %rdx, %r13
        cmovl   %rdx, %r13
        add     $8, %rdi
        dec     %ecx
        jnz     .Lmi_vrow
        add     $8, %rsi
        sub     $64, %r10
        ja      .Lmi_vblk
.Lmi_fin:
        mov     %r14, %rax
        test    %rax, %rax
        jz      1f
        mov     %r12, (%r15)
        mov     %r13, (%rbp)
1:      pop     %r15
        pop     %r14
        pop     %r13
        pop     %r12
        pop     %rbp
        pop     %rbx
        ret
ENDF pqk_x86_scalar_minmax_i64

/* ------------------------------------------------------------------------
 * size_t pqk_x86_scalar_minmax_f64(data=rdi, validity=rsi, n=rdx,
 *                                  out_min=rcx, out_max=r8)
 * xmm0 = lo (init +inf), xmm1 = hi (init -inf). Update rule matches the
 * reference exactly: lo = (x < lo) ? x : lo via "minsd lo, x" (MINSD returns
 * the second operand when not strictly less), likewise for max. Invalid rows
 * are replaced by +inf / -inf, which never replace anything (inputs finite).
 * r9 = +inf bits, r11 = -inf bits, r14 = count, r10 = remaining,
 * rbx = validity word.
 * ---------------------------------------------------------------------- */
FUNC pqk_x86_scalar_minmax_f64
        push    %rbx
        push    %r14
        movabs  $0x7ff0000000000000, %r9
        movabs  $0xfff0000000000000, %r11
        movq    %r9, %xmm0
        movq    %r11, %xmm1
        xor     %r14d, %r14d
        mov     %rdx, %r10
        test    %r10, %r10
        jz      .Lmf_fin
        test    %rsi, %rsi
        jnz     .Lmf_vblk
        mov     %r10, %r14
1:      movsd   (%rdi), %xmm2
        movapd  %xmm2, %xmm3
        minsd   %xmm0, %xmm2            /* x < lo ? x : lo */
        maxsd   %xmm1, %xmm3            /* x > hi ? x : hi */
        movapd  %xmm2, %xmm0
        movapd  %xmm3, %xmm1
        add     $8, %rdi
        dec     %r10
        jnz     1b
        jmp     .Lmf_fin
.Lmf_vblk:
        push    %rcx
        mov     $64, %ecx
        cmp     %rcx, %r10
        jb      .Lmf_vpart
        mov     (%rsi), %rbx
        jmp     .Lmf_vgo
.Lmf_vpart:
        mov     %r10d, %ecx
        call    lvp
        mov     %rax, %rbx
        mov     %r10d, %ecx
.Lmf_vgo:
.Lmf_vrow:
        mov     (%rdi), %rax
        mov     %rax, %rdx
        shr     $1, %rbx
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
        jnz     .Lmf_vrow
        pop     %rcx
        add     $8, %rsi
        sub     $64, %r10
        ja      .Lmf_vblk
.Lmf_fin:
        mov     %r14, %rax
        test    %rax, %rax
        jz      1f
        movsd   %xmm0, (%rcx)
        movsd   %xmm1, (%r8)
1:      pop     %r14
        pop     %rbx
        ret
ENDF pqk_x86_scalar_minmax_f64

/* ------------------------------------------------------------------------
 * Bitmap and/or/andnot(a=rdi, b=rsi, out=rdx, nbytes=rcx)
 * 32 bytes per iteration (4 qwords; all loads of a step precede its stores,
 * and positions coincide, so out may alias a or b), then 8-byte steps, then
 * single bytes. rax, r8-r11 scratch.
 * ---------------------------------------------------------------------- */
.macro BQ op, neg, off, ra, rb
        mov     \off(%rsi), \rb
.if \neg
        not     \rb
.endif
        mov     \off(%rdi), \ra
        \op     \rb, \ra
.endm

.macro BITOP name, op, neg
FUNC \name
        push    %rbx
        push    %rbp
        cmp     $32, %rcx
        jb      2f
1:      BQ      \op, \neg, 0, %rax, %r8
        BQ      \op, \neg, 8, %r9, %r10
        BQ      \op, \neg, 16, %r11, %rbx
        BQ      \op, \neg, 24, %rbp, %r8
        mov     %rax, (%rdx)
        mov     %r9, 8(%rdx)
        mov     %r11, 16(%rdx)
        mov     %rbp, 24(%rdx)
        add     $32, %rdi
        add     $32, %rsi
        add     $32, %rdx
        sub     $32, %rcx
        cmp     $32, %rcx
        jae     1b
2:      cmp     $8, %rcx
        jb      3f
        BQ      \op, \neg, 0, %rax, %r8
        mov     %rax, (%rdx)
        add     $8, %rdi
        add     $8, %rsi
        add     $8, %rdx
        sub     $8, %rcx
        jmp     2b
3:      test    %rcx, %rcx
        jz      5f
4:      movzbl  (%rsi), %r8d
.if \neg
        not     %r8d
.endif
        movzbl  (%rdi), %eax
        \op     %r8d, %eax
        mov     %al, (%rdx)
        inc     %rdi
        inc     %rsi
        inc     %rdx
        dec     %rcx
        jnz     4b
5:      pop     %rbp
        pop     %rbx
        ret
ENDF \name
.endm

        BITOP pqk_x86_scalar_bitmap_and, and, 0
        BITOP pqk_x86_scalar_bitmap_or, or, 0
        BITOP pqk_x86_scalar_bitmap_andnot, and, 1

/* ------------------------------------------------------------------------
 * size_t pqk_x86_scalar_bitmap_popcount(bits=rdi, nbits=rsi)
 * Whole 64-bit words with SWAR popcount; the remaining 0..63 bits are loaded
 * bytewise (lvp, exactly ceil(rem/8) bytes) and masked to rem bits.
 * r8 = total, r9 = words left, r10 = remaining bits.
 * ---------------------------------------------------------------------- */
FUNC pqk_x86_scalar_bitmap_popcount
        xor     %r8d, %r8d
        mov     %rsi, %r9
        shr     $6, %r9
        mov     %rsi, %r10
        and     $63, %r10
        test    %r9, %r9
        jz      2f
1:      mov     (%rdi), %rax
        call    popcnt64
        add     %rax, %r8
        add     $8, %rdi
        dec     %r9
        jnz     1b
2:      test    %r10, %r10
        jz      3f
        mov     %rdi, %rsi
        mov     %r10d, %ecx
        call    lvp
        mov     %r10d, %ecx
        mov     $1, %edx
        shl     %cl, %rdx
        dec     %rdx
        and     %rdx, %rax
        call    popcnt64
        add     %rax, %r8
3:      mov     %r8, %rax
        ret
ENDF pqk_x86_scalar_bitmap_popcount

/* ------------------------------------------------------------------------
 * void pqk_x86_scalar_hash_i64(data=rdi, n=rsi, seed=rdx, out=rcx)
 * fmix64(x ^ seed) per row, 2 rows interleaved for ILP.
 * r8 = C1 (0xff51afd7ed558ccd), r9 = C2 (0xc4ceb9fe1a85ec53),
 * rax/r10 = k for row 0/1, r11/rdx... scratch (seed kept in rdx -> r11).
 * ---------------------------------------------------------------------- */
.macro FMIX k, t
        mov     \k, \t
        shr     $33, \t
        xor     \t, \k
        imul    %r8, \k
        mov     \k, \t
        shr     $33, \t
        xor     \t, \k
        imul    %r9, \k
        mov     \k, \t
        shr     $33, \t
        xor     \t, \k
.endm

FUNC pqk_x86_scalar_hash_i64
        push    %rbx
        movabs  $0xff51afd7ed558ccd, %r8
        movabs  $0xc4ceb9fe1a85ec53, %r9
        mov     %rdx, %r11              /* seed */
        cmp     $2, %rsi
        jb      2f
1:      mov     (%rdi), %rax
        mov     8(%rdi), %r10
        xor     %r11, %rax
        xor     %r11, %r10
        FMIX    %rax, %rdx
        FMIX    %r10, %rbx
        mov     %rax, (%rcx)
        mov     %r10, 8(%rcx)
        add     $16, %rdi
        add     $16, %rcx
        sub     $2, %rsi
        cmp     $2, %rsi
        jae     1b
2:      test    %rsi, %rsi
        jz      3f
        mov     (%rdi), %rax
        xor     %r11, %rax
        FMIX    %rax, %rdx
        mov     %rax, (%rcx)
3:      pop     %rbx
        ret
ENDF pqk_x86_scalar_hash_i64

/* ------------------------------------------------------------------------
 * void pqk_x86_scalar_compare_fixed(a=rdi, b=rsi, width=rdx, n=rcx, out=r8)
 * Per record: 8-byte chunks (bswap turns the first differing byte into the
 * most significant one, so an unsigned compare gives memcmp order), then
 * single bytes. Never reads beyond the record.
 * r9 = offset inside record, r10/r11 = loaded chunks, rax = result.
 * ---------------------------------------------------------------------- */
FUNC pqk_x86_scalar_compare_fixed
        test    %rcx, %rcx
        jz      .Lcf_ret
.Lcf_rec:
        xor     %r9d, %r9d
        lea     8(%r9), %rax
        cmp     %rdx, %rax
        ja      .Lcf_bytes
.Lcf_q:
        mov     (%rdi,%r9), %r10
        mov     (%rsi,%r9), %r11
        cmp     %r11, %r10
        jne     .Lcf_qdiff
        add     $8, %r9
        lea     8(%r9), %rax
        cmp     %rdx, %rax
        jbe     .Lcf_q
.Lcf_bytes:
        cmp     %rdx, %r9
        jae     .Lcf_eq
        movzbl  (%rdi,%r9), %r10d
        movzbl  (%rsi,%r9), %r11d
        cmp     %r11d, %r10d
        jne     .Lcf_diff
        inc     %r9
        jmp     .Lcf_bytes
.Lcf_qdiff:
        bswap   %r10
        bswap   %r11
        cmp     %r11, %r10
.Lcf_diff:
        sbb     %eax, %eax              /* -1 if a < b (unsigned) else 0 */
        or      $1, %eax                /* -1 or 1 */
        jmp     .Lcf_store
.Lcf_eq:
        xor     %eax, %eax
.Lcf_store:
        mov     %al, (%r8)
        inc     %r8
        add     %rdx, %rdi
        add     %rdx, %rsi
        dec     %rcx
        jnz     .Lcf_rec
.Lcf_ret:
        ret
ENDF pqk_x86_scalar_compare_fixed

/* ------------------------------------------------------------------------
 * int pqk_x86_scalar_group_sum_i64(gid=rdi, values=rsi, validity=rdx, n=rcx,
 *                                  sums=r8, counts=r9, ngroups=[rsp+8])
 * Pass 1 validates every valid row's group id (outputs untouched on error):
 * straight loop without validity, else per row with the validity byte.
 * Pass 2 adds in row order (so the overflow flag equals the reference's):
 *  - no validity: straight loop; the first jo sets the flag and continues in
 *    a copy of the loop without the check (flag is final by then);
 *  - validity: per 64 rows, iterate set validity bits (bsf, x &= x-1),
 *    seto/or collects wrap-around.
 * r10 = row, r11 = ngroups / group id, r12b = overflow flag, rbx = value or
 * validity byte, r13 = rows left, r14 = row base, r15 = validity bits,
 * rbp = validity ptr.
 * ---------------------------------------------------------------------- */
FUNC pqk_x86_scalar_group_sum_i64
        push    %rbx
        push    %rbp
        push    %r12
        push    %r13
        push    %r14
        push    %r15
        mov     56(%rsp), %r11          /* ngroups */
        xor     %r12d, %r12d
        xor     %r10d, %r10d
        test    %rcx, %rcx
        jz      .Lgs_ok
        test    %rdx, %rdx
        jnz     .Lgs_p1v
.Lgs_p1n:
        mov     (%rdi,%r10,4), %eax
        cmp     %r11, %rax
        jae     .Lgs_einval
        inc     %r10
        cmp     %rcx, %r10
        jb      .Lgs_p1n
        jmp     .Lgs_p2
.Lgs_p1v:
        test    $7, %r10b
        jnz     1f
        mov     %r10, %rax
        shr     $3, %rax
        movzbl  (%rdx,%rax), %ebx
1:      shr     $1, %ebx                /* CF = valid */
        jnc     2f
        mov     (%rdi,%r10,4), %eax
        cmp     %r11, %rax
        jae     .Lgs_einval
2:      inc     %r10
        cmp     %rcx, %r10
        jb      .Lgs_p1v

.Lgs_p2:
        test    %rdx, %rdx
        jnz     .Lgs_p2v
        xor     %r10d, %r10d
        test    %r9, %r9
        jz      .Lgs_p2n
.Lgs_p2c:
        mov     (%rdi,%r10,4), %eax
        mov     (%rsi,%r10,8), %rbx
        add     %rbx, (%r8,%rax,8)
        jo      .Lgs_p2c_of
        incq    (%r9,%rax,8)
        inc     %r10
        cmp     %rcx, %r10
        jb      .Lgs_p2c
        jmp     .Lgs_ok
.Lgs_p2c_of:
        mov     $1, %r12d
        incq    (%r9,%rax,8)
        inc     %r10
        cmp     %rcx, %r10
        jae     .Lgs_ok
.Lgs_p2c_nc:
        mov     (%rdi,%r10,4), %eax
        mov     (%rsi,%r10,8), %rbx
        add     %rbx, (%r8,%rax,8)
        incq    (%r9,%rax,8)
        inc     %r10
        cmp     %rcx, %r10
        jb      .Lgs_p2c_nc
        jmp     .Lgs_ok
.Lgs_p2n:
        mov     (%rdi,%r10,4), %eax
        mov     (%rsi,%r10,8), %rbx
        add     %rbx, (%r8,%rax,8)
        jo      .Lgs_p2n_of
        inc     %r10
        cmp     %rcx, %r10
        jb      .Lgs_p2n
        jmp     .Lgs_ok
.Lgs_p2n_of:
        mov     $1, %r12d
        inc     %r10
        cmp     %rcx, %r10
        jae     .Lgs_ok
.Lgs_p2n_nc:
        mov     (%rdi,%r10,4), %eax
        mov     (%rsi,%r10,8), %rbx
        add     %rbx, (%r8,%rax,8)
        inc     %r10
        cmp     %rcx, %r10
        jb      .Lgs_p2n_nc
        jmp     .Lgs_ok

.Lgs_p2v:
        mov     %rcx, %r13
        xor     %r14d, %r14d
        mov     %rdx, %rbp
.Lgs_vblk:
        cmp     $64, %r13
        jb      .Lgs_vpart
        mov     (%rbp), %r15
        jmp     .Lgs_vbits
.Lgs_vpart:
        push    %rsi
        mov     %rbp, %rsi
        mov     %r13d, %ecx
        call    lvp
        pop     %rsi
        mov     %r13d, %ecx
        mov     $1, %edx
        shl     %cl, %rdx
        dec     %rdx
        and     %rax, %rdx
        mov     %rdx, %r15
.Lgs_vbits:
        test    %r15, %r15
        jz      .Lgs_vnext
.Lgs_vrow:
        bsf     %r15, %r10
        add     %r14, %r10
        mov     (%rdi,%r10,4), %r11d
        mov     (%rsi,%r10,8), %rbx
        add     %rbx, (%r8,%r11,8)
        seto    %al
        or      %al, %r12b
        test    %r9, %r9
        jz      1f
        incq    (%r9,%r11,8)
1:      lea     -1(%r15), %rax
        and     %rax, %r15
        jnz     .Lgs_vrow
.Lgs_vnext:
        add     $64, %r14
        add     $8, %rbp
        sub     $64, %r13
        ja      .Lgs_vblk
.Lgs_ok:
        movzbl  %r12b, %eax
        jmp     .Lgs_ret
.Lgs_einval:
        mov     $2, %eax
.Lgs_ret:
        pop     %r15
        pop     %r14
        pop     %r13
        pop     %r12
        pop     %rbp
        pop     %rbx
        ret
ENDF pqk_x86_scalar_group_sum_i64

/* ------------------------------------------------------------------------
 * void pqk_x86_scalar_gather_i64(data=rdi, idx=rsi, m=rdx, out=rcx)
 * out[j] = data[idx[j]] (idx zero-extended), 4x unrolled.
 * ---------------------------------------------------------------------- */
FUNC pqk_x86_scalar_gather_i64
        cmp     $4, %rdx
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
        add     $16, %rsi
        add     $32, %rcx
        sub     $4, %rdx
        cmp     $4, %rdx
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
ENDF pqk_x86_scalar_gather_i64

        .section .note.GNU-stack, "", @progbits
