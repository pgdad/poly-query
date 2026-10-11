/*
 * pqk_x86_scalar.h — building blocks of the x86_scalar variant that are
 * used by more than one of its kernels (included by pqk_x86_scalar.S only).
 * Baseline x86-64: no POPCNT/BMI/AVX. Requires pqk_x86_common.h. Emits
 * nothing by itself.
 *
 *   SWAR_POPCNT, DEFINE_POPCNT64, POPC      SWAR population count
 *   SPRED, SOP                              i64 predicate mask routines
 *   PRED_DRIVER                             filter_i64 / _bitmap / count_i64
 *   BQ, BITOP                               bitmap and / or / andnot
 *   P128, P128_BODY, P128_KERNEL            filter_i128 / count_i128
 */
#ifndef PQK_X86_SCALAR_H
#define PQK_X86_SCALAR_H

/* ------------------------------------------------------------------------
 * SWAR population count (no POPCNT instruction).
 * SWAR_POPCNT t, c   rax = popcount(rax); clobbers t, c.
 * DEFINE_POPCNT64    emits the file-local helper
 *                    popcnt64: rax = popcount(rax); clobbers rdx, r11.
 * POPC src           rax = popcount(src) inline; clobbers rcx, rdx.
 * ---------------------------------------------------------------------- */
.macro SWAR_POPCNT t, c
        mov     %rax, \t
        shr     $1, \t
        movabs  $C_BITS_EVEN, \c
        and     \c, \t
        sub     \t, %rax
        movabs  $C_BITS_2OF4, \c
        mov     %rax, \t
        shr     $2, \t
        and     \c, %rax
        and     \c, \t
        add     \t, %rax
        mov     %rax, \t
        shr     $4, \t
        add     \t, %rax
        movabs  $C_NIBBLE_LO, \c
        and     \c, %rax
        movabs  $C_BYTE_ONES, \c
        imul    \c, %rax
        shr     $56, %rax
.endm
.macro DEFINE_POPCNT64
LFUNC popcnt64
        SWAR_POPCNT %rdx, %r11
        ret
ENDF popcnt64
.endm
.macro POPC src
        mov     \src, %rax
        SWAR_POPCNT %rdx, %rcx
.endm

/* ------------------------------------------------------------------------
 * i64 predicate mask routines sop_* (driver convention, pqk_x86_common.h 6)
 * in:  rdi = pointer to the first row of the block, esi = len (1..64),
 *      r8 = a, r9 = b (sop_bt: r9 = b - a with a <= b, see PRED_DRIVER).
 * out: rax = mask, bit j set iff the predicate holds for row j (bits >= len
 *      are 0). clobbers rcx, rdx, rdi, rsi, r10, r11.
 * Algorithm: forward walk (prefetch friendly), 8 rows per step with fixed
 * shifts (independent setcc chains); the byte is then shifted into place by
 * cl = row offset. Tail: 1..7 leftover rows one at a time.
 * SPRED cc: r10b = predicate of x = rdx (setcc on the flags of x - a);
 *           cc = bt: BETWEEN via the unsigned range trick (x-a) <=u (b-a).
 * SOP name, cc: emits mask routine `name`.
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
        jb      .L\name\()_tail
.L\name\()_step:                        /* [main] 8 rows */
        xor     %r11d, %r11d
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
        jae     .L\name\()_step
.L\name\()_tail:                        /* [tail] 0..7 rows */
        test    %esi, %esi
        jz      .L\name\()_done
.L\name\()_row:
        mov     (%rdi), %rdx
        xor     %r10d, %r10d
        SPRED   \cc
        shl     %cl, %r10
        or      %r10, %rax
        add     $8, %rdi
        inc     %ecx
        dec     %esi
        jnz     .L\name\()_row
.L\name\()_done:
        ret
ENDF \name
.endm

/* ------------------------------------------------------------------------
 * PRED_DRIVER mode, k: body of filter_i64 (MODE_FILTER), filter_i64_bitmap
 * (MODE_BITMAP) and count_i64 (MODE_COUNT); k = kernel name (labels).
 * Args: rdi = data, rsi = validity, rdx = n, ecx = op, r8 = a, r9 = b,
 *       8(%rsp) = out (MODE_FILTER, MODE_BITMAP).
 * Driver registers: pqk_x86_common.h section 6. r15 = sop_* routine;
 * BETWEEN uses r9 = b - a, or the always-false routine if a > b.
 * [check] OP_CHECK; n == 0 skips the block loop. [main] 64-row blocks:
 * mask routine, & validity word, consume (EMIT_IDX_BITS / 8-byte store +
 * popcnt64 / popcnt64). [tail] the last block (len < 64) runs through the
 * same loop: routine gets len, lvp loads ceil(len/8) validity bytes, the
 * bitmap stores ceil(len/8) bytes. [result] index count / set-bit count.
 * ---------------------------------------------------------------------- */
.macro PRED_DRIVER mode, k
        DRV_ENTER PQK_OP_LAST, .L\k\()_inval            /* [check] */
        JTAB_LOAD sop_table, %r15
        cmp     $PQK_BETWEEN, %ecx      /* BETWEEN: r9 = b - a, or empty */
        jne     .L\k\()_args
        lea     sop_false(%rip), %rax
        cmp     %r9, %r8
        cmovg   %rax, %r15
        sub     %r8, %r9
.L\k\()_args:
        DRV_ARGS
        test    %r14, %r14
        jz      .L\k\()_result
.L\k\()_main:                                           /* [main] + [tail] */
        DRV_MASK
        DRV_VALIDITY
.if \mode == MODE_FILTER
        EMIT_IDX_BITS %rax
        add     $64, %rbx
.elseif \mode == MODE_BITMAP
        cmp     $64, %r14
        jb      .L\k\()_tail
        STORE_BITS_FULL
        jmp     .L\k\()_count
.L\k\()_tail:
        mov     %rax, %r10
        STORE_BITS_TAIL
        mov     %r10, %rax
.L\k\()_count:
        call    popcnt64
        add     %rax, %rbx
.else
        call    popcnt64
        add     %rax, %rbx
.endif
        DRV_NEXT 512, .L\k\()_main
.L\k\()_result:                                         /* [result] */
        DRV_LEAVE \mode
        ret
.L\k\()_inval:
        OP_INVALID
.endm

/* ------------------------------------------------------------------------
 * Bitmap and/or/andnot body (a = rdi, b = rsi, out = rdx, nbytes = rcx);
 * k = kernel name. [main] 32 bytes per iteration (4 qwords; all loads of a
 * step precede its stores, and positions coincide, so out may alias a or
 * b). [tail] 8-byte steps, then single bytes (BYTE_BITOP). rax, r8-r11
 * scratch, rbx/rbp saved.
 * BQ op, neg, off, ra, rb: ra = a[off] op (neg ? ~b[off] : b[off]).
 * ---------------------------------------------------------------------- */
.macro BQ op, neg, off, ra, rb
        mov     \off(%rsi), \rb
.if \neg
        not     \rb
.endif
        mov     \off(%rdi), \ra
        \op     \rb, \ra
.endm

.macro BITOP k, op, neg
#define SAVED %rbx, %rbp
        PROLOGUE SAVED                  /* [check] none: nbytes may be 0 */
        cmp     $32, %rcx
        jb      .L\k\()_tail
.L\k\()_main:                           /* [main] 32 bytes */
        BQ      \op, \neg, 0, %rax, %r8
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
        jae     .L\k\()_main
.L\k\()_tail:                           /* [tail] qwords, then bytes */
        cmp     $8, %rcx
        jb      .L\k\()_bytes
        BQ      \op, \neg, 0, %rax, %r8
        mov     %rax, (%rdx)
        add     $8, %rdi
        add     $8, %rsi
        add     $8, %rdx
        sub     $8, %rcx
        jmp     .L\k\()_tail
.L\k\()_bytes:
        BYTE_BITOP \op, \neg
        EPILOGUE SAVED                  /* [result] */
        ret
#undef SAVED
.endm

/* ------------------------------------------------------------------------
 * filter_i128 / count_i128.
 * P128 kind, off: the "raw" predicate KIND for the row at off(%rdi) into
 * CF (the operator's inversion is applied to the whole block mask later):
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

/* P128_BODY mode, kind, inv, done, op: complete block loop of filter_i128
 * (MODE_FILTER) / count_i128 (MODE_COUNT) for one operator (kind, inv),
 * entered through the operator jump table, leaving to \done; op = label
 * prefix of this operator's body (.L<kernel>_<op>).
 * Registers: rdi = row ptr, rsi = validity ptr (0 = all valid), r12 = rows
 * remaining, r13 = block mask, r14 = loop counter, rbx = row base of the
 * block (MODE_FILTER) / count (MODE_COUNT), rbp = output ptr, r8..r11 and
 * r15 as for P128; rax, rcx, rdx scratch.
 * The block mask is built by rotating each row's CF in from the top
 * (rcr $1): after len rows, row j sits at bit 64-len+j, so one shift right by
 * 64-len (partial block only) moves it to bit j and clears everything above
 * len. Walking forward keeps the hardware prefetcher happy; rcr is a 1-cycle
 * op, so the mask chain costs at most one cycle per row.
 * [main] full blocks: 8 x 8 rows. [tail] last block: row by row, then the
 * shift; validity via lvp (ceil(len/8) bytes). */
.macro P128_BODY mode, kind, inv, done, op
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
\op\()_blk:
        cmp     $64, %r12
        jb      \op\()_part
        mov     $8, %r14d
\op\()_full:                            /* [main] full block */
        .set j, 0
        .rept 8
        P128    \kind, j*16
        rcr     $1, %r13
        .set j, j + 1
        .endr
        sub     $-128, %rdi
        dec     %r14d
        jnz     \op\()_full
.if \inv
        not     %r13
.endif
        test    %rsi, %rsi
        jz      \op\()_vok
        and     (%rsi), %r13
        add     $8, %rsi
        jmp     \op\()_vok
\op\()_part:                            /* [tail] last block, len < 64 */
        mov     %r12d, %r14d
\op\()_prow:
        P128    \kind, 0
        rcr     $1, %r13
        add     $16, %rdi
        dec     %r14d
        jnz     \op\()_prow
.if \inv
        not     %r13
.endif
        mov     $64, %ecx
        sub     %r12d, %ecx
        shr     %cl, %r13               /* row j -> bit j, bits >= len = 0 */
        test    %rsi, %rsi
        jz      \op\()_vok
        mov     %r12d, %ecx
        call    lvp                     /* exactly ceil(len/8) bytes */
        and     %rax, %r13
\op\()_vok:
.if \mode == MODE_FILTER
        EMIT_IDX_BITS %r13
        add     $64, %rbx
.else
        POPC    %r13
        add     %rax, %rbx
.endif
        sub     $64, %r12
        ja      \op\()_blk
        jmp     \done
.endm

/* P128_KERNEL mode, k: body of filter_i128 (MODE_FILTER) / count_i128
 * (MODE_COUNT); k = kernel name (labels).
 * Args: rdi = data, rsi = validity, rdx = n, ecx = op, r8 = &a, r9 = &b,
 *       8(%rsp) = out_idx (MODE_FILTER).
 * [check] The op is checked first (unsigned, so negative ints are rejected
 * too); an invalid op returns (size_t)-1 before a or b is touched. Then b is
 * loaded (BETWEEN only) into r10:r11, a into r8:r9, and the operator-
 * specialised P128_BODY is entered through a PIC-relative jump table.
 * [result] (%rsp) holds the start of out_idx; filter returns
 * (rbp - start) / 4, count returns rbx. */
.macro P128_KERNEL mode, k
        DRV_ENTER PQK_OP_LAST, .L\k\()_inval            /* [check] */
        cmp     $PQK_BETWEEN, %ecx
        jne     .L\k\()_a
        mov     (%r9), %r10             /* b (BETWEEN only) */
        mov     8(%r9), %r11
.L\k\()_a:
        mov     8(%r8), %r9             /* a */
        mov     (%r8), %r8
        movabs  $C_SIGN64, %r15
        mov     %rdx, %r12
        xor     %ebx, %ebx
        xor     %r13d, %r13d
        JTAB_LOAD .L\k\()_tab, %rdx
        jmp     *%rdx
.L\k\()_eq:                                             /* [main] + [tail] */
        P128_BODY \mode, 0, 1, .L\k\()_result, .L\k\()_eq
.L\k\()_ne:
        P128_BODY \mode, 0, 0, .L\k\()_result, .L\k\()_ne
.L\k\()_lt:
        P128_BODY \mode, 1, 0, .L\k\()_result, .L\k\()_lt
.L\k\()_le:
        P128_BODY \mode, 2, 1, .L\k\()_result, .L\k\()_le
.L\k\()_gt:
        P128_BODY \mode, 2, 0, .L\k\()_result, .L\k\()_gt
.L\k\()_ge:
        P128_BODY \mode, 1, 1, .L\k\()_result, .L\k\()_ge
.L\k\()_bt:
        P128_BODY \mode, 3, 1, .L\k\()_result, .L\k\()_bt
.L\k\()_result:                                         /* [result] */
        DRV_LEAVE \mode
        ret
.L\k\()_inval:
        OP_INVALID
        OPTABLE .L\k\()_tab, .L\k
.endm

#endif /* PQK_X86_SCALAR_H */
