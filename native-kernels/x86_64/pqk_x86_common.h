/*
 * pqk_x86_common.h — building blocks shared by ALL x86-64 variants
 * (included by pqk_x86_scalar.S, pqk_x86_avx2.S and pqk_x86_avx512.S).
 *
 * Header rules (all pqk_x86_*.h files):
 *  - A header only defines cpp constants and gas macros. Including it emits
 *    no bytes; every instruction and table of a variant is emitted by a
 *    statement (usually a macro invocation) in that variant's .S file. Each
 *    variant object therefore stays self-contained (file-local helpers and
 *    tables, no cross-file symbols).
 *  - Every building block is defined in exactly one header. The README
 *    ("Shared building blocks") lists each block with the kernels using it.
 *  - Headers must not be named *.S: the Makefile assembles every x86_64/<name>.S
 *    file as a translation unit.
 *  - Blocks that depend on optional instructions test the gas symbol
 *    PQK_BMI, which every variant sets once before its first kernel:
 *    0 = baseline x86-64 (bsf, shifts), 1 = BMI1/BMI2 (tzcnt, blsr, bzhi).
 *
 * Includes pqk_x86_consts.h (constant values and tables).
 *
 * Contents
 *   1. ABI constants (mirror include/pq_kernels.h)
 *   2. Symbol directives                       FUNC LFUNC ENDF OBJ ENDOBJ
 *   3. Prologue / epilogue                     PROLOGUE EPILOGUE VRET
 *   4. Operator validation and dispatch        OP_CHECK OP_INVALID JTAB_LOAD
 *                                              JUMPTABLE OPTABLE CMPTABLE
 *   5. Validity-bit extraction                 DEFINE_LVP VBIT_CF VBIT_MASK
 *                                              VBIT_TEST VWORD_BLOCK
 *   6. 64-row block driver pieces              DRV_ENTER DRV_ARGS DRV_MASK
 *                                              DRV_VALIDITY DRV_NEXT DRV_LEAVE
 *                                              LOWEST_IDX CLEAR_LOWEST
 *                                              EMIT_IDX_BITS STORE_BITS_FULL
 *                                              STORE_BITS_TAIL
 *   7. Scalar (GPR) kernel parts               JNE_SEXT FMIX_CONSTS FMIX64
 *                                              LOWMASK BYTE_BITOP GATHER_I64
 *                                              GSUM_PASS2
 *
 * Kernel skeleton and label scheme (followed by every kernel of every
 * variant, see README "Kernel skeleton"): each kernel is laid out as
 *   [check]  argument check / empty input (operator validation, n == 0)
 *   [main]   main (vector) loop(s): full steps / full 64-row blocks
 *   [tail]   tail: the rows left over by the main loop
 *   [result] result: reduction, output stores, status, epilogue
 * and marks each part with a "[check]" / "[main]" / "[tail]" / "[result]"
 * comment. Labels inside a kernel are named .L<kernel>_<step> (kernel = the
 * ABI name without variant prefix, e.g. .Lsum_i64_vmain); helper functions
 * use .L<helper>_<step>; labels inside building-block macros are
 * .L<block>_<step>\@ (unique per expansion). Numeric labels (1:, 2f) appear
 * only inside building-block macros, never in kernel bodies.
 */
#ifndef PQK_X86_COMMON_H
#define PQK_X86_COMMON_H

/* All constant values first: cpp substitutes them while reading the macro
 * bodies below (an undefined name would silently become a symbol). */
#include "pqk_x86_consts.h"

/* ------------------------------------------------------------------------
 * 1. ABI constants (values of include/pq_kernels.h, which is C-only)
 * ---------------------------------------------------------------------- */
#define PQK_OK          0
#define PQK_OVERFLOW    1
#define PQK_EINVAL      2

#define PQK_EQ          0
#define PQK_NE          1
#define PQK_LT          2
#define PQK_LE          3
#define PQK_GT          4
#define PQK_GE          5
#define PQK_BETWEEN     6
#define PQK_OP_LAST     PQK_BETWEEN     /* filter / count: EQ..BETWEEN valid */
#define PQK_CMP_OP_LAST PQK_GE          /* compare_i64: BETWEEN is invalid   */

/* Stack offset of the 7th integer argument after npush 8-byte pushes
 * (return address + pushed registers). */
#define ARG7(npush)     (8 + 8 * (npush))

/* Predicate driver modes (which kernel a shared driver body implements). */
#define MODE_FILTER     0               /* filter_*: emit row indices  */
#define MODE_BITMAP     1               /* filter_i64_bitmap: store bits */
#define MODE_COUNT      2               /* count_*: popcount           */

/* ------------------------------------------------------------------------
 * 2. Symbol directives
 * FUNC name   global kernel entry (@function, 32-byte aligned)
 * LFUNC name  file-local helper (@function, 16-byte aligned)
 * ENDF name   .size of a function
 * OBJ name, align   start a file-local rodata object (2^align aligned)
 * ENDOBJ name       .size of the object; back to .text
 * ---------------------------------------------------------------------- */
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
.macro OBJ name, align
        .section .rodata
        .p2align \align
        .type   \name, @object
\name:
.endm
.macro ENDOBJ name
        .size   \name, . - \name
        .text
.endm

/* ------------------------------------------------------------------------
 * 3. Prologue / epilogue (System V AMD64)
 * PROLOGUE regs...  push the callee-saved registers the kernel uses, in
 *                   list order.
 * EPILOGUE regs...  pop the same list in reverse order (no ret).
 * A kernel names its list once, e.g.
 *     #define SAVED %rbx, %r12
 *     PROLOGUE SAVED ... EPILOGUE SAVED ... #undef SAVED
 * so the push and pop sequences cannot drift apart. No red zone is used;
 * internal helpers only use the stack for call/ret, so the alignment of
 * rsp is irrelevant to them.
 * VRET  return from a function that touched ymm/zmm state (vzeroupper,
 *       so no dirty upper state leaks into SSE code of the caller).
 * ---------------------------------------------------------------------- */
.macro PROLOGUE regs:vararg
        .irp r, \regs
        push    \r
        .endr
.endm
.macro EPILOGUE r, rest:vararg
.ifnb \rest
        EPILOGUE \rest
.endif
        pop     \r
.endm
.macro VRET
        vzeroupper
        ret
.endm

/* ------------------------------------------------------------------------
 * 4. Operator validation and dispatch
 * OP_CHECK last, inval   ecx = op; ops are 0..last. The compare is
 *                        unsigned, so negative ints are rejected as well.
 * OP_INVALID             the invalid-op exit: return (size_t)-1.
 * JTAB_LOAD table, dst[, base=%rax]
 *                        dst = target of entry rcx of a self-relative jump
 *                        table (rcx must be zero-extended). clobbers base.
 * JUMPTABLE name, targets...  rodata table of ".long target - name"
 *                        (PIC, no text relocations), 4-byte aligned.
 * OPTABLE name, prefix   jump table in ABI operator order EQ NE LT LE GT GE
 *                        BETWEEN to prefix_eq ... prefix_bt.
 * CMPTABLE name, prefix  the same without BETWEEN (compare_i64).
 * ---------------------------------------------------------------------- */
.macro OP_CHECK last, inval
        cmp     $\last, %ecx
        ja      \inval
.endm
.macro OP_INVALID
        mov     $-1, %rax
        ret
.endm
.macro JTAB_LOAD table, dst, base=%rax
        lea     \table(%rip), \base
        movslq  (\base,%rcx,4), \dst
        add     \base, \dst
.endm
.macro JUMPTABLE name, targets:vararg
        OBJ     \name, 2
        .irp t, \targets
        .long   \t - \name
        .endr
        ENDOBJ  \name
.endm
.macro OPTABLE name, prefix
        JUMPTABLE \name, \prefix\()_eq, \prefix\()_ne, \prefix\()_lt, \prefix\()_le, \prefix\()_gt, \prefix\()_ge, \prefix\()_bt
.endm
.macro CMPTABLE name, prefix
        JUMPTABLE \name, \prefix\()_eq, \prefix\()_ne, \prefix\()_lt, \prefix\()_le, \prefix\()_gt, \prefix\()_ge
.endm

/* ------------------------------------------------------------------------
 * 5. Validity-bit extraction (LSB-first bitmaps, 1 = valid)
 * DEFINE_LVP   emits the file-local helper
 *     lvp: load a partial little-endian validity word.
 *     in:  rsi = pointer to the validity byte of the block's first row,
 *          ecx = len (1..64) rows. Loads exactly ceil(len/8) bytes, so
 *          nothing past ceil(n/8) is ever read.
 *     out: rax (bits beyond the loaded bytes are 0; bits >= len inside the
 *          last byte are NOT cleared - callers AND with a len-limited mask
 *          or consume only len bits).
 *     clobbers rcx, rdx. Stack: call/ret only.
 * VBIT_CF w        CF = validity bit of the next row; w >>= 1.
 * VBIT_MASK w, m   as VBIT_CF, then m = 0 (invalid) / -1 (valid).
 * VBIT_TEST vp, row, row32, b32
 *                  CF = validity bit of row `row` of bitmap vp.
 *                  clobbers rax, \b32.
 * VWORD_BLOCK rem, rem32, w
 *                  start of a scalar 64-row validity block: rem = rows left
 *                  (> 0), rsi = validity ptr of the block. out: w = validity
 *                  word (8-byte load for a full block, lvp for the last
 *                  partial one), ecx = rows in the block. clobbers rax, rdx.
 * ---------------------------------------------------------------------- */
.macro DEFINE_LVP
LFUNC lvp
        add     $7, %ecx
        shr     $3, %ecx
        xor     %eax, %eax
.Llvp_byte:
        shl     $8, %rax
        movzbl  -1(%rsi,%rcx), %edx
        or      %rdx, %rax
        dec     %ecx
        jnz     .Llvp_byte
        ret
ENDF lvp
.endm

.macro VBIT_CF w
        shr     $1, \w
.endm
.macro VBIT_MASK w, m
        shr     $1, \w
        sbb     \m, \m
.endm
.macro VBIT_TEST vp, row, row32, b32
        mov     \row, %rax
        shr     $3, %rax
        movzbl  (\vp,%rax), %eax
        mov     \row32, \b32
        and     $7, \b32
        bt      \b32, %eax
.endm

.macro VWORD_BLOCK rem, rem32, w
        mov     $64, %ecx
        cmp     %rcx, \rem
        jb      .Lvw_part\@
        mov     (%rsi), \w
        jmp     .Lvw_done\@
.Lvw_part\@:
        mov     \rem32, %ecx
        call    lvp
        mov     %rax, \w
        mov     \rem32, %ecx
.Lvw_done\@:
.endm

/* ------------------------------------------------------------------------
 * 6. 64-row block driver pieces
 * The predicate kernels (filter_*, filter_i64_bitmap, count_*) of every
 * variant run the same block loop: a per-operator mask routine turns one
 * block of up to 64 rows into a 64-bit mask (bit j = row j, bits >= len 0),
 * the driver ANDs the block's validity word and consumes the mask.
 * Driver register convention:
 *   r12 = data ptr of the block, r13 = validity ptr (0 = all valid),
 *   r14 = rows remaining, r15 = mask routine, rbx = row base (MODE_FILTER)
 *   or count, rbp = output ptr, (%rsp) = output start (pushed by DRV_ENTER).
 * Mask routine convention: in rdi = block ptr, esi = len (1..64);
 *   out rax = mask; may clobber rcx, rdx, rdi, rsi, r10, r11 and the
 *   variant's documented vector scratch registers.
 *
 * DRV_ENTER last, inval   OP_CHECK, save rbx/rbp/r12-r15, rbp = 7th
 *                         argument (output), push it as output start,
 *                         zero-extend ecx (op) for JTAB_LOAD.
 * DRV_ARGS                r12 = data, r13 = validity, r14 = n, rbx = 0.
 * DRV_MASK                rax = mask of the next block (len = min(64, r14)).
 * DRV_VALIDITY            rax &= validity word of the block (full block:
 *                         one 8-byte load, r13 += 8; last partial block:
 *                         lvp, exactly ceil(len/8) bytes). clobbers rcx,
 *                         rdx, rsi, r10.
 * DRV_NEXT stride, loop   next block (stride = bytes per 64 rows).
 * DRV_LEAVE mode          rax = result (MODE_FILTER: (rbp - start) / 4
 *                         indices, else rbx); drop the output-start slot and
 *                         restore the callee-saved registers. Caller: ret /
 *                         VRET.
 * LOWEST_IDX m, dst       dst = index of the lowest set bit of m (m != 0).
 * CLEAR_LOWEST m, t       m &= m - 1, ZF = (m == 0). clobbers t (PQK_BMI 0).
 * EMIT_IDX_BITS m         for every set bit j of m (ascending):
 *                         *rbp++ = ebx + j (uint32). m = 0 afterwards.
 *                         clobbers rcx, rdx (PQK_BMI 0).
 * STORE_BITS_FULL         store the 64-bit mask rax at rbp, rbp += 8.
 * STORE_BITS_TAIL         store the low ceil(r14/8) bytes of rax at rbp++
 *                         (last partial block: trailing bits are already 0,
 *                         nothing past ceil(n/8) is written). clobbers rax,
 *                         ecx.
 * ---------------------------------------------------------------------- */
#define DRV_SAVED %rbx, %rbp, %r12, %r13, %r14, %r15

.macro DRV_ENTER last, inval
        OP_CHECK \last, \inval
        PROLOGUE DRV_SAVED
        mov     ARG7(6)(%rsp), %rbp     /* 7th argument (output) */
        push    %rbp                    /* (%rsp) = start of output */
        mov     %ecx, %ecx
.endm
.macro DRV_ARGS
        mov     %rdi, %r12
        mov     %rsi, %r13
        mov     %rdx, %r14
        xor     %ebx, %ebx
.endm
.macro DRV_MASK
        mov     $64, %esi
        cmp     %rsi, %r14
        cmovb   %r14, %rsi              /* len = min(64, remaining) */
        mov     %r12, %rdi
        call    *%r15                   /* rax = predicate mask */
.endm
.macro DRV_VALIDITY
        test    %r13, %r13
        jz      .Ldv_done\@
        cmp     $64, %r14
        jb      .Ldv_part\@
        and     (%r13), %rax
        add     $8, %r13
        jmp     .Ldv_done\@
.Ldv_part\@:
        mov     %rax, %r10
        mov     %r13, %rsi
        mov     %r14d, %ecx
        call    lvp
        and     %r10, %rax
.Ldv_done\@:
.endm
.macro DRV_NEXT stride, loop
        add     $\stride, %r12
        sub     $64, %r14
        ja      \loop
.endm
.macro DRV_LEAVE mode
.if \mode == MODE_FILTER
        mov     %rbp, %rax
        sub     (%rsp), %rax
        shr     $2, %rax
.else
        mov     %rbx, %rax
.endif
        pop     %rdx                    /* output start */
        EPILOGUE DRV_SAVED
.endm

.macro LOWEST_IDX m, dst
.if PQK_BMI
        tzcnt   \m, \dst
.else
        bsf     \m, \dst
.endif
.endm
.macro CLEAR_LOWEST m, t
.if PQK_BMI
        blsr    \m, \m
.else
        lea     -1(\m), \t
        and     \t, \m
.endif
.endm
.macro EMIT_IDX_BITS m
        test    \m, \m
        jz      .Lei_done\@
.Lei_bit\@:
        LOWEST_IDX \m, %rcx
        add     %ebx, %ecx
        mov     %ecx, (%rbp)
        add     $4, %rbp
        CLEAR_LOWEST \m, %rdx
        jnz     .Lei_bit\@
.Lei_done\@:
.endm

.macro STORE_BITS_FULL
        mov     %rax, (%rbp)
        add     $8, %rbp
.endm
.macro STORE_BITS_TAIL
        lea     7(%r14), %ecx
        shr     $3, %ecx                /* ceil(len/8) bytes */
.Lsb_byte\@:
        mov     %al, (%rbp)
        inc     %rbp
        shr     $8, %rax
        dec     %ecx
        jnz     .Lsb_byte\@
.endm

/* ------------------------------------------------------------------------
 * 7. Scalar (GPR) kernel parts
 * JNE_SEXT lo, hi, label  jump to label unless hi is the sign extension of
 *                    lo (sar 63), i.e. unless the two-word value hi:lo fits
 *                    in the signed width of lo. Used for the exact overflow
 *                    test of sum_i64 (128-bit total) and sum_i128 (192-bit
 *                    total). clobbers rax.
 * FMIX_CONSTS c1, c2 c1 = 0xff51afd7ed558ccd, c2 = 0xc4ceb9fe1a85ec53.
 * FMIX64 k, t, c1, c2  k = fmix64(k) (MurmurHash3 finalizer) with the
 *                    multipliers in c1/c2; clobbers t.
 * LOWMASK n32        rdx = (1 << n) - 1 for n = n32 in 0..63 (baseline
 *                    replacement of bzhi). clobbers ecx.
 * BYTE_BITOP op, neg byte loop of bitmap and/or/andnot: rcx bytes of
 *                    out[i] = a[i] op (neg ? ~b[i] : b[i]) (rdi = a, rsi = b,
 *                    rdx = out; each byte is loaded before it is stored, so
 *                    out may alias a or b). clobbers rax, rcx, r8.
 * GATHER_I64 unroll  complete gather_i64 body: out[j] = data[idx[j]],
 *                    `unroll` (4 or 8) rows per iteration as independent
 *                    32-bit-index loads (indices zero-extended), then single
 *                    rows. rdi = data, rsi = idx, rdx = m, rcx = out.
 *                    clobbers rax, rcx, rdx, rsi, r8-r10.
 * GSUM_PASS2         pass 2 of group_sum_i64 (after all group ids were
 *                    validated): scatter-add in row order, so the overflow
 *                    flag equals the reference's. Falls through when done.
 *                    No validity: straight loop; the first jo records the
 *                    flag and continues in a copy of the loop without the
 *                    check (the flag is final then; no mispredicts on
 *                    overflow-heavy data). Validity: per 64-row block the
 *                    set validity bits are iterated (LOWEST_IDX /
 *                    CLEAR_LOWEST), seto/or collects wrap-around.
 *                    in: rdi = gid, rsi = values, rdx = validity, rcx = n
 *                    (> 0), r8 = sums, r9 = counts (may be 0), r12 = 0.
 *                    out: r12b = overflow flag. clobbers rax, rcx, rdx,
 *                    r10, r11, rbx, rbp, r13-r15.
 * ---------------------------------------------------------------------- */
.macro JNE_SEXT lo, hi, label
        mov     \lo, %rax
        sar     $63, %rax
        cmp     %rax, \hi
        jne     \label
.endm

.macro FMIX_CONSTS c1, c2
        movabs  $C_FMIX1, \c1
        movabs  $C_FMIX2, \c2
.endm
.macro FMIX64 k, t, c1, c2
        mov     \k, \t
        shr     $33, \t
        xor     \t, \k
        imul    \c1, \k
        mov     \k, \t
        shr     $33, \t
        xor     \t, \k
        imul    \c2, \k
        mov     \k, \t
        shr     $33, \t
        xor     \t, \k
.endm

.macro LOWMASK n32
        mov     \n32, %ecx
        mov     $1, %edx
        shl     %cl, %rdx
        dec     %rdx
.endm

.macro BYTE_BITOP op, neg
        test    %rcx, %rcx
        jz      .Lbb_done\@
.Lbb_byte\@:
        movzbl  (%rsi), %r8d
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
        jnz     .Lbb_byte\@
.Lbb_done\@:
.endm

.macro GATHER_I64 unroll
        cmp     $\unroll, %rdx
        jb      .Lga_tail\@
.Lga_main\@:
        .set q, 0
        .rept \unroll / 4
        mov     q*16(%rsi), %eax
        mov     q*16+4(%rsi), %r8d
        mov     q*16+8(%rsi), %r9d
        mov     q*16+12(%rsi), %r10d
        mov     (%rdi,%rax,8), %rax
        mov     (%rdi,%r8,8), %r8
        mov     (%rdi,%r9,8), %r9
        mov     (%rdi,%r10,8), %r10
        mov     %rax, q*32(%rcx)
        mov     %r8, q*32+8(%rcx)
        mov     %r9, q*32+16(%rcx)
        mov     %r10, q*32+24(%rcx)
        .set q, q + 1
        .endr
        add     $(4 * \unroll), %rsi
        add     $(8 * \unroll), %rcx
        sub     $\unroll, %rdx
        cmp     $\unroll, %rdx
        jae     .Lga_main\@
.Lga_tail\@:
        test    %rdx, %rdx
        jz      .Lga_done\@
.Lga_row\@:
        mov     (%rsi), %eax
        mov     (%rdi,%rax,8), %rax
        mov     %rax, (%rcx)
        add     $4, %rsi
        add     $8, %rcx
        dec     %rdx
        jnz     .Lga_row\@
.Lga_done\@:
.endm

.macro GSUM_PASS2
        test    %rdx, %rdx
        jnz     .Lgs_valid\@
        xor     %r10d, %r10d
        test    %r9, %r9
        jz      .Lgs_nocnt\@
.Lgs_cnt\@:                             /* with counts */
        mov     (%rdi,%r10,4), %eax
        mov     (%rsi,%r10,8), %rbx
        add     %rbx, (%r8,%rax,8)
        jo      .Lgs_cnt_of\@
        incq    (%r9,%rax,8)
        inc     %r10
        cmp     %rcx, %r10
        jb      .Lgs_cnt\@
        jmp     .Lgs_done\@
.Lgs_cnt_of\@:
        mov     $1, %r12d
        incq    (%r9,%rax,8)
        inc     %r10
        cmp     %rcx, %r10
        jae     .Lgs_done\@
.Lgs_cnt_nc\@:                          /* flag final: no jo */
        mov     (%rdi,%r10,4), %eax
        mov     (%rsi,%r10,8), %rbx
        add     %rbx, (%r8,%rax,8)
        incq    (%r9,%rax,8)
        inc     %r10
        cmp     %rcx, %r10
        jb      .Lgs_cnt_nc\@
        jmp     .Lgs_done\@
.Lgs_nocnt\@:                           /* without counts, same scheme */
        mov     (%rdi,%r10,4), %eax
        mov     (%rsi,%r10,8), %rbx
        add     %rbx, (%r8,%rax,8)
        jo      .Lgs_nocnt_of\@
        inc     %r10
        cmp     %rcx, %r10
        jb      .Lgs_nocnt\@
        jmp     .Lgs_done\@
.Lgs_nocnt_of\@:
        mov     $1, %r12d
        inc     %r10
        cmp     %rcx, %r10
        jae     .Lgs_done\@
.Lgs_nocnt_nc\@:
        mov     (%rdi,%r10,4), %eax
        mov     (%rsi,%r10,8), %rbx
        add     %rbx, (%r8,%rax,8)
        inc     %r10
        cmp     %rcx, %r10
        jb      .Lgs_nocnt_nc\@
        jmp     .Lgs_done\@

.Lgs_valid\@:                           /* r13 = rows left, r14 = row base, */
        mov     %rcx, %r13              /* rbp = validity ptr,              */
        xor     %r14d, %r14d            /* r15 = validity bits of the block */
        mov     %rdx, %rbp
.Lgs_vblk\@:
        cmp     $64, %r13
        jb      .Lgs_vpart\@
        mov     (%rbp), %r15
        jmp     .Lgs_vbits\@
.Lgs_vpart\@:
        push    %rsi
        mov     %rbp, %rsi
        mov     %r13d, %ecx
        call    lvp
        pop     %rsi
.if PQK_BMI
        bzhi    %r13, %rax, %r15
.else
        LOWMASK %r13d
        and     %rax, %rdx
        mov     %rdx, %r15
.endif
.Lgs_vbits\@:
        test    %r15, %r15
        jz      .Lgs_vnext\@
.Lgs_vrow\@:
        LOWEST_IDX %r15, %r10
        add     %r14, %r10
        mov     (%rdi,%r10,4), %r11d
        mov     (%rsi,%r10,8), %rbx
        add     %rbx, (%r8,%r11,8)
        seto    %al
        or      %al, %r12b
        test    %r9, %r9
        jz      .Lgs_nocount\@
        incq    (%r9,%r11,8)
.Lgs_nocount\@:
        CLEAR_LOWEST %r15, %rax
        jnz     .Lgs_vrow\@
.Lgs_vnext\@:
        add     $64, %r14
        add     $8, %rbp
        sub     $64, %r13
        ja      .Lgs_vblk\@
.Lgs_done\@:
.endm

#endif /* PQK_X86_COMMON_H */
