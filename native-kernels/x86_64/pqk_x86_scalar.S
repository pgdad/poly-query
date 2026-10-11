/*
 * pqk_x86_scalar.S — PolyQuery native kernels, variant "x86_scalar".
 *
 * Baseline x86-64 only (no POPCNT/BMI/AVX; SSE2 scalar double ops only), so
 * this variant runs on every x86-64 CPU. All 16 kernels of pq_kernels.h are
 * provided as global symbols pqk_x86_scalar_<kernel>, System V AMD64 ABI.
 * Every kernel is bit-identical to the reference, including sum_f64 (same
 * sequential addition order) and the sign of zero in minmax_f64.
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


/* ========================================================================
 * 128-bit kernels (CR-4, ABI revision 1).
 * A pqk_i128 is 16 bytes {lo, hi} (little-endian int128); rows are 16 bytes
 * apart, so row i is at data + 16*i. All loads are plain unaligned GPR loads.
 * ====================================================================== */

/* POPC: rax <- popcount(\src) (SWAR, no POPCNT instruction). clobbers rcx,
 * rdx. */
.macro POPC src
        mov     \src, %rax
        mov     %rax, %rdx
        shr     $1, %rdx
        movabs  $0x5555555555555555, %rcx
        and     %rcx, %rdx
        sub     %rdx, %rax
        movabs  $0x3333333333333333, %rcx
        mov     %rax, %rdx
        shr     $2, %rdx
        and     %rcx, %rax
        and     %rcx, %rdx
        add     %rdx, %rax
        mov     %rax, %rdx
        shr     $4, %rdx
        add     %rdx, %rax
        movabs  $0x0f0f0f0f0f0f0f0f, %rcx
        and     %rcx, %rax
        movabs  $0x0101010101010101, %rcx
        imul    %rcx, %rax
        shr     $56, %rax
.endm

/* ------------------------------------------------------------------------
 * P128: evaluate the "raw" predicate KIND for the row at \off(%rdi) and
 * leave it in CF (the operator's inversion is applied to the whole block
 * mask afterwards). Kinds and the operators built from them:
 *   0 NE  : x != a                     EQ = !NE, NE
 *   1 LT  : x <s a                     LT, GE = !LT
 *   2 GT  : a <s x                     GT, LE = !GT
 *   3 OUT : (x - a) >u (b - a)         BETWEEN = !OUT (needs a <= b)
 * Registers: r8 = a.lo, r9 = a.hi (kinds 1, 2: a.hi ^ 2^63), r10:r11 =
 * b - a (kind 3), r15 = 2^63; clobbers rax, rcx, rdx.
 * Signed 128-bit comparison is done as an unsigned one on sign-biased high
 * words (hi ^ 2^63), so that "cmp lo; sbb hi" leaves the result in CF.
 * NE: (x.lo ^ a.lo) | (x.hi ^ a.hi) is non-zero; neg sets CF iff non-zero.
 * OUT: the unsigned range trick, a <= x <= b <=> (x-a) mod 2^128 <=u b-a.
 * ---------------------------------------------------------------------- */
.macro P128 kind, off
.if \kind == 0
        mov     \off(%rdi), %rax
        xor     %r8, %rax
        mov     \off+8(%rdi), %rdx
        xor     %r9, %rdx
        or      %rdx, %rax
        neg     %rax                    /* CF = (x != a) */
.elseif \kind == 1
        mov     \off+8(%rdi), %rdx
        xor     %r15, %rdx
        mov     \off(%rdi), %rax
        cmp     %r8, %rax
        sbb     %r9, %rdx               /* CF = x <s a */
.elseif \kind == 2
        mov     \off+8(%rdi), %rdx
        xor     %r15, %rdx
        mov     %r9, %rcx
        cmp     \off(%rdi), %r8
        sbb     %rdx, %rcx              /* CF = a <s x */
.else
        mov     \off(%rdi), %rax
        mov     \off+8(%rdi), %rdx
        sub     %r8, %rax
        sbb     %r9, %rdx               /* d = x - a */
        cmp     %rax, %r10
        mov     %r11, %rcx
        sbb     %rdx, %rcx              /* CF = (b - a) <u d */
.endif
.endm

/* ------------------------------------------------------------------------
 * P128_BODY: complete block loop of filter_i128 (mode 0) / count_i128
 * (mode 2) for one operator (kind, inv), entered from the kernel prologue
 * by the operator jump table and leaving to \done.
 * Registers: rdi = row ptr, rsi = validity ptr (0 = all valid), r12 = rows
 * remaining, r13 = block mask, r14 = loop counter, rbx = row base of the
 * block (mode 0) / count (mode 2), rbp = output ptr (mode 0), r8..r11 and
 * r15 as for P128; rax, rcx, rdx scratch.
 * The block mask is built by rotating each row's CF in from the top
 * (rcr $1): after len rows, row j sits at bit 64-len+j, so one shift right by
 * 64-len (partial block only) moves it to bit j and clears everything above
 * len. Walking forward keeps the hardware prefetcher happy; rcr is a 1-cycle
 * op, so the mask chain costs at most one cycle per row.
 * ---------------------------------------------------------------------- */
.macro P128_BODY mode, kind, inv, done
.if \kind == 1 || \kind == 2
        xor     %r15, %r9               /* sign-biased a.hi */
.endif
.if \kind == 3
        mov     %r10, %rax              /* a > b: no row can match */
        cmp     %r8, %rax
        mov     %r11, %rax
        sbb     %r9, %rax
        jl      \done
        sub     %r8, %r10
        sbb     %r9, %r11               /* r11:r10 = b - a (unsigned) */
.endif
        test    %r12, %r12
        jz      \done
.Lblk\@:
        cmp     $64, %r12
        jb      .Lpart\@
        mov     $8, %r14d
.Lfull\@:
        .set j, 0
        .rept 8
        P128    \kind, j*16
        rcr     $1, %r13
        .set j, j + 1
        .endr
        sub     $-128, %rdi
        dec     %r14d
        jnz     .Lfull\@
.if \inv
        not     %r13
.endif
        test    %rsi, %rsi
        jz      .Lvok\@
        and     (%rsi), %r13
        add     $8, %rsi
        jmp     .Lvok\@
.Lpart\@:
        mov     %r12d, %r14d
.Lprow\@:
        P128    \kind, 0
        rcr     $1, %r13
        add     $16, %rdi
        dec     %r14d
        jnz     .Lprow\@
.if \inv
        not     %r13
.endif
        mov     $64, %ecx
        sub     %r12d, %ecx
        shr     %cl, %r13               /* row j -> bit j, bits >= len = 0 */
        test    %rsi, %rsi
        jz      .Lvok\@
        mov     %r12d, %ecx
        call    lvp                     /* exactly ceil(len/8) bytes */
        and     %rax, %r13
.Lvok\@:
.if \mode == 0
        test    %r13, %r13
        jz      .Lnext\@
.Lbits\@:
        bsf     %r13, %rcx
        add     %ebx, %ecx
        mov     %ecx, (%rbp)
        add     $4, %rbp
        lea     -1(%r13), %rdx
        and     %rdx, %r13
        jnz     .Lbits\@
.Lnext\@:
        add     $64, %rbx
.else
        POPC    %r13
        add     %rax, %rbx
.endif
        sub     $64, %r12
        ja      .Lblk\@
        jmp     \done
.endm

/* ------------------------------------------------------------------------
 * P128_KERNEL: filter_i128 (mode 0) / count_i128 (mode 2).
 * Args: rdi = data, rsi = validity, rdx = n, ecx = op, r8 = &a, r9 = &b,
 *       [rsp+8] = out_idx (mode 0).
 * The op is checked first (unsigned, so negative ints are rejected too); an
 * invalid op returns (size_t)-1 before a or b is touched. Then b is loaded
 * (BETWEEN only) into r10:r11, a into r8:r9, and the operator-specialised
 * body is entered through a PIC-relative jump table. (%rsp) holds the start
 * of out_idx; the result of filter is (rbp - start) / 4.
 * ---------------------------------------------------------------------- */
.macro P128_KERNEL mode, pfx
        cmp     $6, %ecx
        ja      \pfx\()_inval
        push    %rbx
        push    %rbp
        push    %r12
        push    %r13
        push    %r14
        push    %r15
        mov     56(%rsp), %rbp          /* 7th argument (out_idx) */
        push    %rbp
        mov     %ecx, %ecx
        cmp     $6, %ecx
        jne     1f
        mov     (%r9), %r10             /* b (BETWEEN only) */
        mov     8(%r9), %r11
1:      mov     8(%r8), %r9             /* a */
        mov     (%r8), %r8
        movabs  $0x8000000000000000, %r15
        mov     %rdx, %r12
        xor     %ebx, %ebx
        xor     %r13d, %r13d
        lea     \pfx\()_tab(%rip), %rax
        movslq  (%rax,%rcx,4), %rdx
        add     %rdx, %rax
        jmp     *%rax
\pfx\()_eq:
        P128_BODY \mode, 0, 1, \pfx\()_done
\pfx\()_ne:
        P128_BODY \mode, 0, 0, \pfx\()_done
\pfx\()_lt:
        P128_BODY \mode, 1, 0, \pfx\()_done
\pfx\()_le:
        P128_BODY \mode, 2, 1, \pfx\()_done
\pfx\()_gt:
        P128_BODY \mode, 2, 0, \pfx\()_done
\pfx\()_ge:
        P128_BODY \mode, 1, 1, \pfx\()_done
\pfx\()_bt:
        P128_BODY \mode, 3, 1, \pfx\()_done
\pfx\()_done:
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
\pfx\()_inval:
        mov     $-1, %rax
        ret
        .section .rodata
        .p2align 2
        .type   \pfx\()_tab, @object
\pfx\()_tab:
        .long   \pfx\()_eq - \pfx\()_tab, \pfx\()_ne - \pfx\()_tab
        .long   \pfx\()_lt - \pfx\()_tab, \pfx\()_le - \pfx\()_tab
        .long   \pfx\()_gt - \pfx\()_tab, \pfx\()_ge - \pfx\()_tab
        .long   \pfx\()_bt - \pfx\()_tab
        .size   \pfx\()_tab, . - \pfx\()_tab
        .text
.endm

/* ------------------------------------------------------------------------
 * size_t pqk_x86_scalar_filter_i128(data, validity, n, op, a, b, out_idx)
 * Register usage: see P128_KERNEL / P128_BODY / P128 above.
 * Algorithm: 64-row blocks; per row one 128-bit compare (cmp/sbb on
 * sign-biased high words, or xor/or/neg for (in)equality, or the unsigned
 * range trick for BETWEEN) whose CF is rotated into a 64-bit block mask;
 * mask &= validity word; indices are emitted with bsf / x &= x-1.
 * ---------------------------------------------------------------------- */
FUNC pqk_x86_scalar_filter_i128
        P128_KERNEL 0, .Lsf128
ENDF pqk_x86_scalar_filter_i128

/* ------------------------------------------------------------------------
 * size_t pqk_x86_scalar_count_i128(data, validity, n, op, a, b)
 * Same block masks as filter_i128; each masked block is SWAR-popcounted.
 * ---------------------------------------------------------------------- */
FUNC pqk_x86_scalar_count_i128
        P128_KERNEL 2, .Lsc128
ENDF pqk_x86_scalar_count_i128

/* ------------------------------------------------------------------------
 * int pqk_x86_scalar_sum_i128(data=rdi, validity=rsi, n=rdx, out_sum=rcx)
 * Register usage: r10:r9:r8 = 192-bit two's-complement accumulator
 * (top:hi:lo), r11 = out_sum, r12 = rows remaining, r13 = 4-row steps
 * left in a full validity block, rbx = validity word, rax/rcx/rdx scratch.
 * Exact overflow detection: every row is sign-extended to 192 bits
 * (hi, sar 63 of hi) and added with add/adc/adc, so the accumulator holds the
 * exact sum (|sum| < 2^32 * 2^127 = 2^159 cannot wrap 192 bits). Wrap-arounds
 * of the low 128 bits that cancel out are therefore invisible, as required.
 * At the end the sum fits int128 iff the top word equals the sign extension
 * of the hi word (sar 63); otherwise PQK_OVERFLOW and *out_sum is untouched.
 * Invalid rows are zeroed branch-free (shr of the validity word -> CF,
 * sbb -> 0/-1 mask, and). Both paths are unrolled 4x; the final partial
 * validity block (exactly ceil(len/8) bytes via lvp) goes row by row.
 * n == 0 stores 0 and returns PQK_OK.
 * ---------------------------------------------------------------------- */

/* SVADD128 off: as SADD128 for a row whose validity bit is the next bit of
 * rbx (shr -> CF, sbb -> 0/-1 mask; invalid rows add 0). clobbers rax, rcx,
 * rdx. */
.macro SVADD128 off
        shr     $1, %rbx                /* CF = validity bit */
        sbb     %rdx, %rdx
        mov     \off(%rdi), %rax
        and     %rdx, %rax
        and     \off+8(%rdi), %rdx
        mov     %rdx, %rcx
        sar     $63, %rcx
        add     %rax, %r8
        adc     %rdx, %r9
        adc     %rcx, %r10
.endm

.macro SADD128 off
        mov     \off+8(%rdi), %rax
        mov     %rax, %rdx
        sar     $63, %rdx
        add     \off(%rdi), %r8
        adc     %rax, %r9
        adc     %rdx, %r10
.endm

FUNC pqk_x86_scalar_sum_i128
        push    %rbx
        push    %r12
        push    %r13
        xor     %r8d, %r8d
        xor     %r9d, %r9d
        xor     %r10d, %r10d
        mov     %rcx, %r11
        mov     %rdx, %r12
        test    %r12, %r12
        jz      .Ls128_fin
        test    %rsi, %rsi
        jnz     .Ls128_vblk
        cmp     $4, %r12
        jb      .Ls128_one
.Ls128_four:
        SADD128 0
        SADD128 16
        SADD128 32
        SADD128 48
        add     $64, %rdi
        sub     $4, %r12
        cmp     $4, %r12
        jae     .Ls128_four
        test    %r12, %r12
        jz      .Ls128_fin
.Ls128_one:
        SADD128 0
        add     $16, %rdi
        dec     %r12
        jnz     .Ls128_one
        jmp     .Ls128_fin
.Ls128_vblk:
        cmp     $64, %r12
        jb      .Ls128_vpart
        mov     (%rsi), %rbx
        mov     $16, %r13d
.Ls128_vfour:
        SVADD128 0
        SVADD128 16
        SVADD128 32
        SVADD128 48
        add     $64, %rdi
        dec     %r13d
        jnz     .Ls128_vfour
        add     $8, %rsi
        sub     $64, %r12
        jnz     .Ls128_vblk
        jmp     .Ls128_fin
.Ls128_vpart:
        mov     %r12d, %ecx
        call    lvp                     /* exactly ceil(len/8) bytes */
        mov     %rax, %rbx
.Ls128_vone:
        SVADD128 0
        add     $16, %rdi
        dec     %r12d
        jnz     .Ls128_vone
.Ls128_fin:
        mov     %r9, %rax
        sar     $63, %rax
        cmp     %rax, %r10
        jne     .Ls128_ovf
        mov     %r8, (%r11)
        mov     %r9, 8(%r11)
        xor     %eax, %eax
        pop     %r13
        pop     %r12
        pop     %rbx
        ret
.Ls128_ovf:
        mov     $1, %eax
        pop     %r13
        pop     %r12
        pop     %rbx
        ret
ENDF pqk_x86_scalar_sum_i128

/* ------------------------------------------------------------------------
 * size_t pqk_x86_scalar_minmax_i128(data=rdi, validity=rsi, n=rdx,
 *                                   out_min=rcx, out_max=r8)
 * Register usage: r13:r12 = min (hi:lo), r15:r14 = max, r10:r9 = w =
 * max - min (unsigned), rbx = valid count, rbp = validity word, r11 = rows
 * remaining, r8d = rows left in the block (validity path), rdi = row ptr,
 * rsi = validity ptr, rax/rcx/rdx scratch; out_min/out_max are kept on the
 * stack.
 * Algorithm: min and max start at the first valid row f (found by a byte
 * scan of the validity bitmap; f = 0 without validity). Then every row
 * from the 64-row block containing f on is tested with ONE 128-bit
 * compare: x is inside [min, max] iff (x - min) mod 2^128 <=u w. Inside
 * (the common case once a few rows were seen) needs no update; outside, the
 * out-of-line routine mm128_upd decides x < min or x > max (exactly one
 * holds), updates it and recomputes w. Invalid rows get d = 0 (and-masked),
 * i.e. they are always "inside". Rows of f's block before f are invalid, so
 * the count (sbb mask subtracted per row) is exact.
 * ---------------------------------------------------------------------- */

/* mm128_upd: rax = pointer to a row outside [min, max]; updates min or max
 * and w (registers as above). clobbers rax, rcx, rdx. */
LFUNC mm128_upd
        mov     8(%rax), %rdx
        mov     (%rax), %rax
        cmp     %r12, %rax
        mov     %rdx, %rcx
        sbb     %r13, %rcx
        jl      1f                      /* x <s min */
        mov     %rax, %r14
        mov     %rdx, %r15
        jmp     2f
1:      mov     %rax, %r12
        mov     %rdx, %r13
2:      mov     %r14, %r9
        mov     %r15, %r10
        sub     %r12, %r9
        sbb     %r13, %r10
        ret
ENDF mm128_upd

/* MM128_ROW off, valid: test the row at off(%rdi); valid = 1 consumes one
 * validity bit from rbp (count in rbx, invalid rows forced inside). */
.macro MM128_ROW off, valid
        mov     \off(%rdi), %rax
        mov     \off+8(%rdi), %rdx
        sub     %r12, %rax
        sbb     %r13, %rdx              /* d = x - min */
.if \valid
        shr     $1, %rbp                /* CF = validity bit */
        sbb     %rcx, %rcx
        sub     %rcx, %rbx
        and     %rcx, %rax
        and     %rcx, %rdx
.endif
        cmp     %rax, %r9
        mov     %r10, %rcx
        sbb     %rdx, %rcx              /* CF = w <u d: outside */
        jae     1f
        lea     \off(%rdi), %rax
        call    mm128_upd
1:
.endm

FUNC pqk_x86_scalar_minmax_i128
        push    %rbx
        push    %rbp
        push    %r12
        push    %r13
        push    %r14
        push    %r15
        push    %rcx                    /* 8(%rsp) = out_min */
        push    %r8                     /* (%rsp) = out_max */
        xor     %ebx, %ebx
        mov     %rdx, %r11
        test    %r11, %r11
        jz      .Lm128_fin
        test    %rsi, %rsi
        jnz     .Lm128_scan
        /* no validity: f = 0, count = n */
        mov     %r11, %rbx
        mov     (%rdi), %r12
        mov     8(%rdi), %r13
        mov     %r12, %r14
        mov     %r13, %r15
        xor     %r9d, %r9d
        xor     %r10d, %r10d
        cmp     $4, %r11
        jb      .Lm128_one
.Lm128_four:
        MM128_ROW 0, 0
        MM128_ROW 16, 0
        MM128_ROW 32, 0
        MM128_ROW 48, 0
        add     $64, %rdi
        sub     $4, %r11
        cmp     $4, %r11
        jae     .Lm128_four
        test    %r11, %r11
        jz      .Lm128_fin
.Lm128_one:
        MM128_ROW 0, 0
        add     $16, %rdi
        dec     %r11
        jnz     .Lm128_one
        jmp     .Lm128_fin
.Lm128_scan:
        /* first valid row f: first non-zero validity byte, then bsf */
        lea     7(%r11), %rcx
        shr     $3, %rcx                /* ceil(n/8) bytes */
        xor     %edx, %edx
1:      movzbl  (%rsi,%rdx), %eax
        test    %eax, %eax
        jnz     2f
        inc     %rdx
        cmp     %rcx, %rdx
        jb      1b
        jmp     .Lm128_fin              /* no valid row */
2:      bsf     %eax, %eax
        lea     (%rax,%rdx,8), %rax     /* f */
        cmp     %r11, %rax
        jae     .Lm128_fin              /* set bit beyond n only */
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
.Lm128_vblk:
        cmp     $64, %r11
        jb      .Lm128_vpart
        mov     (%rsi), %rbp
        mov     $16, %r8d
.Lm128_vfour:
        MM128_ROW 0, 1
        MM128_ROW 16, 1
        MM128_ROW 32, 1
        MM128_ROW 48, 1
        add     $64, %rdi
        dec     %r8d
        jnz     .Lm128_vfour
        add     $8, %rsi
        sub     $64, %r11
        jnz     .Lm128_vblk
        jmp     .Lm128_fin
.Lm128_vpart:
        mov     %r11d, %ecx
        call    lvp
        mov     %rax, %rbp
        mov     %r11d, %r8d
.Lm128_vone:
        MM128_ROW 0, 1
        add     $16, %rdi
        dec     %r8d
        jnz     .Lm128_vone
.Lm128_fin:
        mov     %rbx, %rax
        test    %rax, %rax
        jz      1f
        mov     8(%rsp), %rcx
        mov     (%rsp), %rdx
        mov     %r12, (%rcx)
        mov     %r13, 8(%rcx)
        mov     %r14, (%rdx)
        mov     %r15, 8(%rdx)
1:      add     $16, %rsp
        pop     %r15
        pop     %r14
        pop     %r13
        pop     %r12
        pop     %rbp
        pop     %rbx
        ret
ENDF pqk_x86_scalar_minmax_i128

        .section .note.GNU-stack, "", @progbits
