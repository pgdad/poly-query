/*
 * table.S - physical table representations (indexes-and-planning.md §1)
 * and table statistics (§3).
 *
 * Ingestion and the PQCF reader produce tables in the *staging* form
 * (u64 slots + one NULL byte per row, see pq.inc); table_finalize turns
 * them into one of the two in-memory layouts:
 *
 *   column  one typed vector per column plus a NULL bitmap (omitted when the
 *           column has no NULLs); STRING columns are dictionary encoded
 *           (u32 codes + dictionary) when beneficial or when forced
 *   row     one row-major block of tuples: ncols u64 slots followed by the
 *           tuple's NULL bitmap (whole u64 words)
 *
 * Every reader goes through col_get, so both layouts give identical results.
 *
 *   col_get(col rdi, row rsi) -> rax payload, edx 1 if NULL     (leaf)
 *   table_finalize(table rdi, layout esi, dict edx)   dict: DICT_*
 *   table_stats(table rdi) -> rax ColStats[ncols] (lazily computed, cached)
 *   table_col_stats(table rdi, col rsi) -> rax ColStats* of one column
 *   table_free(table rdi)  destroys the table's indexes and its arena
 *   table_new(arena rdi, name pstr rsi, ncols rdx, nrows rcx) -> rax Table*
 *                          staging table with zeroed columns
 *   col_stage(arena rdi, col rsi, name pstr rdx, type rcx, nrows r8)
 *                          names a column and allocates its staging vectors
 */
#include "pq.inc"
#include "sql.inc"

    .section .note.GNU-stack, "", @progbits
    .text

/* col_get(col rdi, row rsi) -> rax payload (0 when NULL), edx NULL flag */
FUNC col_get
    cmpb $0, COL_LAZY(%rdi)
    jne col_get_lazy
    mov COL_NULLS(%rdi), %rdx
    test %rdx, %rdx
    jz 1f
    mov %rsi, %rax
    imul COL_NSTRIDE(%rdi), %rax
    add COL_NBIT(%rdi), %rax
    mov %rax, %rcx
    shr $3, %rcx
    and $7, %eax
    movzbl (%rdx, %rcx), %edx
    bt %eax, %edx
    jc 8f
1:  mov COL_STRIDE(%rdi), %rax
    imul %rsi, %rax
    add COL_DATA(%rdi), %rax
    mov COL_DICT(%rdi), %rcx
    test %rcx, %rcx
    jnz 2f
    mov (%rax), %rax
    xor %edx, %edx
    ret
2:  mov (%rax), %eax                /* dictionary code */
    mov (%rcx, %rax, 8), %rax
    xor %edx, %edx
    ret
8:  xor %eax, %eax
    mov $1, %edx
    ret
ENDF col_get

/* col_get_lazy: first access to a lazily decoded PQCF column (entered by a
 * jump from col_get with its arguments): decodes it, then reads the value */
FUNC col_get_lazy
    push %rdi
    push %rsi
    sub $8, %rsp
    call pqcf_load_col
    add $8, %rsp
    pop %rsi
    pop %rdi
    jmp col_get
ENDF col_get_lazy

/* table_new(arena, name pstr, ncols, nrows) -> Table* (staging) */
FUNC table_new
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rcx, %r14
    mov %rbx, %rdi
    mov $TB_SIZE, %esi
    call arena_zalloc
    mov %rax, %r15
    mov %rbx, TB_ARENA(%r15)
    mov %r13, TB_NCOLS(%r15)
    mov %r14, TB_NROWS(%r15)
    mov %rbx, %rdi
    lea 8(%r12), %rsi
    mov (%r12), %rdx
    call pstr_new
    mov %rax, TB_NAME(%r15)
    mov %rbx, %rdi
    mov %r13, %rsi
    shl $COL_SHIFT, %rsi
    add $8, %rsi
    call arena_zalloc
    mov %rax, TB_COLS(%r15)
    mov %r15, %rax
    LEAVE
ENDF table_new

/* col_stage(arena, col, name pstr, type, nrows): staging vectors (u64 slots,
 * zeroed NULL bytes) */
FUNC col_stage
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rcx, COL_TYPE(%r12)
    mov %r8, %r13
    mov %rbx, %rdi
    lea 8(%rdx), %rsi
    mov (%rdx), %rdx
    call pstr_new
    mov %rax, COL_NAME(%r12)
    mov %rbx, %rdi
    lea 8(, %r13, 8), %rsi
    call arena_alloc
    mov %rax, COL_DATA(%r12)
    mov %rbx, %rdi
    lea 8(%r13), %rsi
    call arena_zalloc
    mov %rax, COL_NULLS(%r12)
    LEAVE
ENDF col_stage

/* ================================================================ finalize */

/* any_null(bytes rdi, n rsi) -> eax 1 if some byte is non-zero (leaf) */
any_null:
    xor %eax, %eax
    xor %ecx, %ecx
1:  cmp %rsi, %rcx
    jae 9f
    cmpb $0, (%rdi, %rcx)
    jne 8f
    inc %rcx
    jmp 1b
8:  mov $1, %eax
9:  ret

/* table_finalize(t rdi, layout esi, dict edx) */
FUNC table_finalize
    ENTER 32
    mov %rdi, %rbx
    mov %rsi, 0(%rsp)
    mov %rdx, 8(%rsp)
    mov %esi, %eax
    mov %rax, TB_LAYOUT(%rbx)
    cmp $LAYOUT_ROW, %eax
    je 20f
    /* ---- column layout */
    mov %rdx, TB_DICTMODE(%rbx)
    xor %r12d, %r12d
1:  cmp TB_NCOLS(%rbx), %r12
    jae 99f
    mov %r12, %r13
    shl $COL_SHIFT, %r13
    add TB_COLS(%rbx), %r13         /* Column* */
    cmpb $0, COL_LAZY(%r13)         /* decoded on first access */
    jne 2f
    mov %rbx, %rdi
    mov %r13, %rsi
    mov 8(%rsp), %rdx
    call col_finalize
2:  inc %r12
    jmp 1b

20: /* ---- row layout: tuples of ncols slots + NULL bitmap words */
    mov TB_NCOLS(%rbx), %rax
    lea 63(%rax), %rcx
    shr $6, %rcx                    /* bitmap words */
    add %rcx, %rax
    shl $3, %rax
    mov %rax, TB_ROWW(%rbx)
    mov %rax, %rsi
    imul TB_NROWS(%rbx), %rsi
    add $8, %rsi
    mov TB_ARENA(%rbx), %rdi
    call arena_zalloc
    mov %rax, TB_ROWS(%rbx)
    movq $0, 16(%rsp)               /* any NULL in the table */
    xor %r12d, %r12d                /* column */
21: cmp TB_NCOLS(%rbx), %r12
    jae 25f
    mov %r12, %r13
    shl $COL_SHIFT, %r13
    add TB_COLS(%rbx), %r13
    mov COL_DATA(%r13), %r8         /* staging slots */
    mov COL_NULLS(%r13), %r9        /* staging NULL bytes */
    mov TB_ROWS(%rbx), %r10
    lea (%r10, %r12, 8), %r10       /* slot of row 0 */
    mov TB_NCOLS(%rbx), %r11
    shl $6, %r11
    add %r12, %r11                  /* NULL bit of row 0 */
    mov TB_ROWW(%rbx), %r14
    xor %ecx, %ecx
22: cmp TB_NROWS(%rbx), %rcx
    jae 24f
    mov (%r8, %rcx, 8), %rax
    mov %rax, (%r10)
    cmpb $0, (%r9, %rcx)
    je 23f
    mov %r11, %rax
    shr $3, %rax
    mov %r11, %rdx
    and $7, %edx
    mov TB_ROWS(%rbx), %rsi
    movzbl (%rsi, %rax), %edi
    bts %edx, %edi
    mov %dil, (%rsi, %rax)
    movq $1, 16(%rsp)
23: add %r14, %r10
    lea (%r11, %r14, 8), %r11
    inc %rcx
    jmp 22b
24: inc %r12
    jmp 21b
25: xor %r12d, %r12d
26: cmp TB_NCOLS(%rbx), %r12
    jae 99f
    mov %r12, %r13
    shl $COL_SHIFT, %r13
    add TB_COLS(%rbx), %r13
    mov TB_ROWS(%rbx), %rax
    lea (%rax, %r12, 8), %rcx
    mov %rcx, COL_DATA(%r13)
    mov TB_ROWW(%rbx), %rcx
    mov %rcx, COL_STRIDE(%r13)
    shl $3, %rcx
    mov %rcx, COL_NSTRIDE(%r13)
    mov TB_NCOLS(%rbx), %rcx
    shl $6, %rcx
    add %r12, %rcx
    mov %rcx, COL_NBIT(%r13)
    xor %ecx, %ecx
    cmpq $0, 16(%rsp)
    cmovne %rax, %rcx
    mov %rcx, COL_NULLS(%r13)
    movq $0, COL_DICT(%r13)
    inc %r12
    jmp 26b
99: LEAVE
ENDF table_finalize

/* col_finalize(t rdi, col rsi, dict rdx): turns one staging column into the
 * column layout (NULL bitmap or none, optional dictionary encoding; the
 * dictionary is built by reading the column through col_get) */
FUNC col_finalize
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r13
    mov %rdx, 0(%rsp)
    movq $8, COL_STRIDE(%r13)
    movq $1, COL_NSTRIDE(%r13)
    movq $0, COL_NBIT(%r13)
    mov COL_NULLS(%r13), %rdi
    mov TB_NROWS(%rbx), %rsi
    call any_null
    test %eax, %eax
    jnz 2f
    movq $0, COL_NULLS(%r13)
    jmp 5f
2:  /* bytes -> bitmap */
    mov TB_NROWS(%rbx), %rsi
    add $71, %rsi
    shr $3, %rsi
    mov TB_ARENA(%rbx), %rdi
    call arena_zalloc
    mov COL_NULLS(%r13), %rsi       /* bytes */
    xor %ecx, %ecx
3:  cmp TB_NROWS(%rbx), %rcx
    jae 4f
    cmpb $0, (%rsi, %rcx)
    je 31f
    bts %rcx, (%rax)
31: inc %rcx
    jmp 3b
4:  mov %rax, COL_NULLS(%r13)
5:  cmpb $T_STR, COL_TYPE(%r13)
    jne 9f
    cmpq $DICT_OFF, 0(%rsp)
    je 9f
    mov %rbx, %rdi
    mov %r13, %rsi
    mov 0(%rsp), %rdx
    call dict_encode
9:  LEAVE
ENDF col_finalize

/* dict_encode(t rdi, col rsi, mode rdx): dictionary-encodes a finalized
 * STRING column (column layout).  DICT_AUTO encodes only when the distinct
 * count is at most half the row count (and the column has >= 16 rows). */
FUNC dict_encode
    ENTER 64
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, 0(%rsp)
    mov TB_NROWS(%rbx), %r13
    cmp $DICT_ON, %rdx
    je 1f
    cmp $16, %r13
    jb 99f
1:  movq $T_STR, 8(%rsp)
    mov $1, %edi
    lea 8(%rsp), %rsi
    call ht_new
    mov %rax, 16(%rsp)              /* value -> code */
    mov g_arena(%rip), %rdi
    call vec_new
    mov %rax, 24(%rsp)              /* dictionary (first pstr of each value) */
    lea 4(, %r13, 4), %rdi
    call tmp_alloc
    mov %rax, 32(%rsp)              /* codes (scratch) */
    xor %r14d, %r14d
2:  cmp %r13, %r14
    jae 5f
    mov 32(%rsp), %rax
    movl $0, (%rax, %r14, 4)
    mov %r12, %rdi
    mov %r14, %rsi
    call col_get
    test %edx, %edx
    jnz 4f
    mov %rax, 40(%rsp)              /* probe cell 40..55 */
    movq $0, 48(%rsp)
    mov 16(%rsp), %rdi
    lea 40(%rsp), %rsi
    xor %edx, %edx
    call ht_lookup
    test %rax, %rax
    jnz 3f
    mov $VAL_SIZE, %edi
    call tmp_zalloc
    mov 40(%rsp), %rcx
    mov %rcx, VAL_P(%rax)
    mov 16(%rsp), %rdi
    mov %rax, %rsi
    mov $1, %edx
    call ht_lookup
    mov %rax, %r15
    mov 24(%rsp), %rdi
    mov VEC_LEN(%rdi), %rcx
    mov %rcx, EN_D0(%r15)
    mov 40(%rsp), %rsi
    call vec_push
    mov %r15, %rax
3:  mov EN_D0(%rax), %rcx
    mov 32(%rsp), %rax
    mov %ecx, (%rax, %r14, 4)
4:  inc %r14
    jmp 2b
5:  mov 24(%rsp), %rax
    mov VEC_LEN(%rax), %r15         /* D */
    cmpq $DICT_ON, 0(%rsp)
    je 6f
    lea (%r15, %r15), %rax
    cmp %r13, %rax
    ja 99f
6:  /* install: codes and dictionary in the table arena */
    mov TB_ARENA(%rbx), %rdi
    lea 8(, %r13, 4), %rsi
    call arena_alloc
    mov %rax, %r14
    mov %rax, %rdi
    mov 32(%rsp), %rsi
    lea (, %r13, 4), %rdx
    call memcpy
    mov TB_ARENA(%rbx), %rdi
    lea 8(, %r15, 8), %rsi
    call arena_alloc
    mov %rax, 56(%rsp)
    mov %rax, %rdi
    mov 24(%rsp), %rax
    mov VEC_DATA(%rax), %rsi
    lea (, %r15, 8), %rdx
    call memcpy
    mov %r14, COL_DATA(%r12)
    movq $4, COL_STRIDE(%r12)
    mov 56(%rsp), %rax
    mov %rax, COL_DICT(%r12)
99: LEAVE
ENDF dict_encode

/* ================================================================ statistics */

/* table_stats(t) -> rax ColStats[ncols], every column computed */
FUNC table_stats
    ENTER 0
    mov %rdi, %rbx
    xor %r12d, %r12d
1:  cmp TB_NCOLS(%rbx), %r12
    jae 9f
    mov %rbx, %rdi
    mov %r12, %rsi
    call table_col_stats
    inc %r12
    jmp 1b
9:  mov TB_STATS(%rbx), %rax
    LEAVE
ENDF table_stats

#define HLL_P     14
#define HLL_M     (1 << HLL_P)
#define EXACT_MAX 200000   /* distinct values counted exactly up to here */

    .section .rodata
    .p2align 3
hll_alpha_m2: .double 193376882.84  /* 0.7213 / (1 + 1.079 / m) * m^2, m = 2^14 */
hll_m:        .double 16384.0
hll_lin:      .double 40960.0       /* 2.5 m: linear counting below */
f_half:       .double 0.5
    .text

/* hll_add(registers rdi, hash rsi): HyperLogLog register update (leaf) */
FUNC hll_add
    mov %rsi, %rax                  /* fmix64 finalizer */
    shr $33, %rax
    xor %rax, %rsi
    mov $0xff51afd7ed558ccd, %rax
    imul %rax, %rsi
    mov %rsi, %rax
    shr $33, %rax
    xor %rax, %rsi
    mov $0xc4ceb9fe1a85ec53, %rax
    imul %rax, %rsi
    mov %rsi, %rax
    shr $33, %rax
    xor %rax, %rsi
    mov %rsi, %rcx
    shr $(64 - HLL_P), %rcx         /* register index */
    shl $HLL_P, %rsi
    or $(1 << (HLL_P - 1)), %rsi    /* bounds the rank */
    bsr %rsi, %rax
    mov $64, %edx
    sub %eax, %edx                  /* rank = leading zeros + 1 */
    cmp (%rdi, %rcx), %dl
    jbe 1f
    mov %dl, (%rdi, %rcx)
1:  ret
ENDF hll_add

/* hll_estimate(registers rdi) -> rax estimated distinct count */
FUNC hll_estimate
    xorpd %xmm0, %xmm0              /* sum of 2^-register */
    xor %ecx, %ecx
    xor %r8d, %r8d                  /* zero registers */
1:  movzbl (%rdi, %rcx), %eax
    test %eax, %eax
    jnz 2f
    inc %r8
2:  mov $1023, %edx                 /* 2^-r as a double: exponent 1023 - r */
    sub %eax, %edx
    shl $52, %rdx
    movq %rdx, %xmm1
    addsd %xmm1, %xmm0
    inc %ecx
    cmp $HLL_M, %ecx
    jb 1b
    movsd hll_alpha_m2(%rip), %xmm1
    divsd %xmm0, %xmm1              /* raw estimate */
    ucomisd hll_lin(%rip), %xmm1
    ja 8f
    test %r8, %r8
    jz 8f
    sub $24, %rsp                   /* linear counting: m ln(m / zeros) */
    movsd %xmm1, 0(%rsp)
    cvtsi2sd %r8, %xmm1
    movsd hll_m(%rip), %xmm0
    divsd %xmm1, %xmm0
    call log
    mulsd hll_m(%rip), %xmm0
    add $24, %rsp
    movapd %xmm0, %xmm1
8:  addsd f_half(%rip), %xmm1
    cvttsd2si %xmm1, %rax
    ret
ENDF hll_estimate

/* ------------------------------------------------ column statistics
 * table_col_stats computes a column's statistics in parallel over row ranges
 * (par_run): every part counts its NULLs, keeps its first minimum / maximum,
 * fills its own HyperLogLog registers and an exact set of its distinct
 * values (cells of 24 bytes: the value cell and the row of the value's first
 * occurrence in the part), each in a private arena (the statistics are
 * cached table metadata, not query memory).  The merge reproduces the
 * serial definition exactly:
 *   NULLs   the sum;
 *   min/max part order with strict comparisons (first occurrence wins);
 *   HLL     register-wise maximum (order independent);
 *   exact   the serial scan keeps a set of up to EXACT_MAX values and gives
 *           it up at the first non-NULL row it sees when full: the count is
 *           exact when the column has fewer than EXACT_MAX distinct values,
 *           or exactly EXACT_MAX of them with no non-NULL row after the
 *           first occurrence of the last new one; otherwise the HLL
 *           estimate.  A part that sees more than EXACT_MAX distinct values
 *           decides the HLL case at once (STK_OVER, also read by the other
 *           parts to stop collecting); else the part sets are merged in
 *           part order into part 0's set, so that each value keeps its
 *           first row in the column. */
#define STATS_MIN_ROWS 16384    /* rows per part at least */

/* per part results (StatsPart) */
#define SPT_NULLS 0
#define SPT_HAS   8
#define SPT_MIN   16
#define SPT_MAX   24
#define SPT_LAST  32            /* 1 + the part's last non-NULL row (0 = none) */
#define SPT_HLL   40            /* u8[HLL_M] registers */
#define SPT_SET   48            /* exact set (HashTable*), 0 when given up */
#define SPT_ARENA 56            /* the part's private arena */
#define SPT_SIZE  64
#define SC_ROW    16            /* first row, after the value cell */
#define SC_SIZE   24

/* statistics task (on the stack of table_col_stats) */
#define STK_COL   0             /* Column* */
#define STK_TYPE  8             /* packed type (u64: the set's key type) */
#define STK_PARTS 16            /* StatsPart[P] */
#define STK_OVER  24            /* 1 = more than EXACT_MAX distinct values */
#define STK_SIZE  32

/* stats_part(task rdi, part rsi, lo rdx, hi rcx): statistics of rows [lo, hi) */
FUNC stats_part
    ENTER 48
    mov %rdi, %rbx
    imul $SPT_SIZE, %rsi, %r12
    add STK_PARTS(%rbx), %r12       /* the part's results (zeroed) */
    mov %rdx, %r14                  /* row */
    mov %rcx, 0(%rsp)               /* hi */
    mov %fs:t_arena@tpoff, %rax
    mov %rax, 8(%rsp)               /* the thread's arena, restored below */
    call arena_new
    mov %rax, SPT_ARENA(%r12)
    mov %rax, %fs:t_arena@tpoff
    mov $1, %edi
    lea STK_TYPE(%rbx), %rsi
    call ht_new
    mov %rax, SPT_SET(%r12)
    mov $HLL_M, %edi
    call tmp_zalloc
    mov %rax, SPT_HLL(%r12)
    mov STK_COL(%rbx), %r13
1:  cmp 0(%rsp), %r14
    jae 8f
    mov %r13, %rdi
    mov %r14, %rsi
    call col_get
    test %edx, %edx
    jz 2f
    incq SPT_NULLS(%r12)
    jmp 7f
2:  mov %rax, %r15                  /* value */
    lea 1(%r14), %rcx
    mov %rcx, SPT_LAST(%r12)
    cmpq $0, SPT_HAS(%r12)
    jne 3f
    movq $1, SPT_HAS(%r12)
    mov %rax, SPT_MIN(%r12)
    mov %rax, SPT_MAX(%r12)
    jmp 5f
3:  mov STK_TYPE(%rbx), %rdi
    mov %r15, %rsi
    mov SPT_MIN(%r12), %rdx
    call value_cmp
    test %eax, %eax
    jns 4f
    mov %r15, SPT_MIN(%r12)
4:  mov STK_TYPE(%rbx), %rdi
    mov %r15, %rsi
    mov SPT_MAX(%r12), %rdx
    call value_cmp
    test %eax, %eax
    jle 5f
    mov %r15, SPT_MAX(%r12)
5:  mov %r15, 16(%rsp)              /* probe cell 16..31 */
    movq $0, 24(%rsp)
    lea 16(%rsp), %rdi              /* distinct values: sketch ... */
    mov $1, %esi
    lea STK_TYPE(%rbx), %rdx
    call hash_cells
    mov %rax, 40(%rsp)
    mov SPT_HLL(%r12), %rdi
    mov %rax, %rsi
    call hll_add
    cmpq $0, SPT_SET(%r12)          /* ... and the exact set */
    je 7f
    cmpq $0, STK_OVER(%rbx)         /* decided by another part */
    jne 6f
    mov SPT_SET(%r12), %rdi
    lea 16(%rsp), %rsi
    xor %edx, %edx
    mov 40(%rsp), %rcx
    call ht_lookup_h
    test %rax, %rax
    jnz 7f
    mov $SC_SIZE, %edi              /* a new value */
    call tmp_alloc
    mov %r15, VAL_P(%rax)
    movq $0, VAL_NULL(%rax)
    mov %r14, SC_ROW(%rax)
    mov SPT_SET(%r12), %rdi
    mov %rax, %rsi
    mov $1, %edx
    mov 40(%rsp), %rcx
    call ht_lookup_h
    mov SPT_SET(%r12), %rax
    cmpq $EXACT_MAX, HT_N(%rax)
    jbe 7f
    movq $1, STK_OVER(%rbx)
6:  movq $0, SPT_SET(%r12)
7:  inc %r14
    jmp 1b
8:  mov 8(%rsp), %rax
    mov %rax, %fs:t_arena@tpoff
    LEAVE
ENDF stats_part

/* stats_union(set0 rdi, set rsi) -> eax 1 when set0 grew past EXACT_MAX:
 * adds the values of `set` missing in set0 (keeping their cells) */
FUNC stats_union
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    xor %r13d, %r13d                /* bucket */
1:  cmp HT_NB(%r12), %r13
    jae 8f
    mov HT_BKT(%r12), %rax
    mov (%rax, %r13, 8), %r14       /* chain */
2:  test %r14, %r14
    jz 4f
    mov %rbx, %rdi
    mov EN_KEY(%r14), %rsi
    mov $1, %edx
    mov EN_HASH(%r14), %rcx
    call ht_lookup_h
    cmpq $EXACT_MAX, HT_N(%rbx)
    ja 9f
    mov EN_NEXT(%r14), %r14
    jmp 2b
4:  inc %r13
    jmp 1b
8:  xor %eax, %eax
    LEAVE
9:  mov $1, %eax
    LEAVE
ENDF stats_union

/* stats_last_first(set rdi) -> rax the latest first-occurrence row of the
 * set's values */
FUNC stats_last_first
    xor %eax, %eax
    xor %ecx, %ecx                  /* bucket */
1:  cmp HT_NB(%rdi), %rcx
    jae 9f
    mov HT_BKT(%rdi), %rdx
    mov (%rdx, %rcx, 8), %rdx
2:  test %rdx, %rdx
    jz 3f
    mov EN_KEY(%rdx), %rsi
    mov SC_ROW(%rsi), %rsi
    cmp %rax, %rsi
    cmova %rsi, %rax
    mov EN_NEXT(%rdx), %rdx
    jmp 2b
3:  inc %rcx
    jmp 1b
9:  ret
ENDF stats_last_first

/* table_col_stats(t rdi, c rsi) -> rax ColStats* of column c (computed on
 * first use and cached in the table: tables are immutable).  Distinct values
 * are counted exactly with a hash set up to EXACT_MAX, beyond that by a
 * HyperLogLog sketch (bounded memory, ~1% error); see above. */
#define CS_P    (STK_SIZE + 0)      /* parts */
#define CS_LAST (STK_SIZE + 8)      /* 1 + last non-NULL row */
#define CS_ARENA (STK_SIZE + 16)    /* the thread's arena during the merge */
FUNC table_col_stats
    ENTER STK_SIZE + 32
    mov %rdi, %rbx
    mov %rsi, %r12
    cmpq $0, TB_STATS(%rbx)
    jne 1f
    mov TB_NCOLS(%rbx), %rsi
    imul $CST_SIZE, %rsi
    add $8, %rsi
    mov TB_ARENA(%rbx), %rdi
    call arena_zalloc
    mov %rax, TB_STATS(%rbx)
1:  imul $CST_SIZE, %r12, %r15
    add TB_STATS(%rbx), %r15        /* ColStats* */
    cmpq $0, CST_DONE(%r15)
    jne 99f
    mov %r12, %r13
    shl $COL_SHIFT, %r13
    add TB_COLS(%rbx), %r13         /* Column* */
    cmpq $0, TB_NROWS(%rbx)         /* workers only read: decode a lazily */
    je 11f                          /* opened column first */
    cmpb $0, COL_LAZY(%r13)
    je 11f
    mov %r13, %rdi
    call pqcf_load_col
11: mov %r13, STK_COL(%rsp)
    mov COL_TYPE(%r13), %rax
    mov %rax, STK_TYPE(%rsp)
    movq $0, STK_OVER(%rsp)
    /* parts: the request's threads, STATS_MIN_ROWS rows each at least */
    mov TB_NROWS(%rbx), %rax
    add $(STATS_MIN_ROWS - 1), %rax
    xor %edx, %edx
    mov $STATS_MIN_ROWS, %ecx
    div %rcx
    mov g_opt_threads(%rip), %rcx
    mov $MAX_THREADS, %edx
    cmp %rdx, %rcx
    cmova %rdx, %rcx
    cmp %rcx, %rax
    cmova %rcx, %rax
    mov $1, %ecx
    cmp %rcx, %rax
    cmovb %rcx, %rax
    mov %rax, CS_P(%rsp)
    imul $SPT_SIZE, %rax, %rdi
    call tmp_zalloc
    mov %rax, STK_PARTS(%rsp)
    mov TB_NROWS(%rbx), %rdi
    mov CS_P(%rsp), %rsi
    lea stats_part(%rip), %rdx
    lea 0(%rsp), %rcx
    call par_run
    /* merge: NULLs, min / max, last non-NULL row, HLL registers */
    movq $0, CST_NULLS(%r15)
    movq $0, CST_HAS(%r15)
    movq $0, CS_LAST(%rsp)
    xor %r12d, %r12d                /* part */
2:  cmp CS_P(%rsp), %r12
    jae 5f
    imul $SPT_SIZE, %r12, %r13
    add STK_PARTS(%rsp), %r13
    mov SPT_NULLS(%r13), %rax
    add %rax, CST_NULLS(%r15)
    mov SPT_LAST(%r13), %rax
    cmp CS_LAST(%rsp), %rax
    jbe 21f
    mov %rax, CS_LAST(%rsp)
21: cmpq $0, SPT_HAS(%r13)
    je 4f
    cmpq $0, CST_HAS(%r15)
    jne 22f
    movq $1, CST_HAS(%r15)
    mov SPT_MIN(%r13), %rax
    mov %rax, CST_MIN(%r15)
    mov SPT_MAX(%r13), %rax
    mov %rax, CST_MAX(%r15)
    jmp 4f
22: mov STK_TYPE(%rsp), %rdi
    mov SPT_MIN(%r13), %rsi
    mov CST_MIN(%r15), %rdx
    call value_cmp
    test %eax, %eax
    jns 23f
    mov SPT_MIN(%r13), %rax
    mov %rax, CST_MIN(%r15)
23: mov STK_TYPE(%rsp), %rdi
    mov SPT_MAX(%r13), %rsi
    mov CST_MAX(%r15), %rdx
    call value_cmp
    test %eax, %eax
    jle 4f
    mov SPT_MAX(%r13), %rax
    mov %rax, CST_MAX(%r15)
4:  test %r12, %r12                 /* registers into part 0's */
    jz 45f
    mov STK_PARTS(%rsp), %rax
    mov SPT_HLL(%rax), %rdi
    mov SPT_HLL(%r13), %rsi
    xor %ecx, %ecx
41: movdqu (%rdi, %rcx), %xmm0
    movdqu (%rsi, %rcx), %xmm1
    pmaxub %xmm1, %xmm0
    movdqu %xmm0, (%rdi, %rcx)
    add $16, %ecx
    cmp $HLL_M, %ecx
    jb 41b
45: inc %r12
    jmp 2b
5:  /* distinct values */
    mov STK_PARTS(%rsp), %r13       /* part 0 */
    cmpq $0, STK_OVER(%rsp)
    jne 7f
    mov %fs:t_arena@tpoff, %rax     /* merge the sets in part 0's arena */
    mov %rax, CS_ARENA(%rsp)
    mov SPT_ARENA(%r13), %rax
    mov %rax, %fs:t_arena@tpoff
    mov $1, %r12d
51: cmp CS_P(%rsp), %r12
    jae 52f
    imul $SPT_SIZE, %r12, %rax
    add STK_PARTS(%rsp), %rax
    mov SPT_SET(%r13), %rdi
    mov SPT_SET(%rax), %rsi
    call stats_union
    test %eax, %eax
    jnz 53f
    inc %r12
    jmp 51b
53: movq $1, STK_OVER(%rsp)
52: mov CS_ARENA(%rsp), %rax
    mov %rax, %fs:t_arena@tpoff
    cmpq $0, STK_OVER(%rsp)
    jne 7f
    mov SPT_SET(%r13), %rdi
    mov HT_N(%rdi), %rax
    cmp $EXACT_MAX, %rax
    jb 8f                           /* exact */
    call stats_last_first           /* exactly EXACT_MAX: given up at a */
    inc %rax                        /* later non-NULL row */
    cmp CS_LAST(%rsp), %rax
    jb 7f
    mov $EXACT_MAX, %eax
    jmp 8f
7:  mov SPT_HLL(%r13), %rdi
    call hll_estimate
8:  mov %rax, CST_DISTINCT(%r15)
    movq $1, CST_DONE(%r15)
    xor %r12d, %r12d                /* release the parts' memory */
9:  cmp CS_P(%rsp), %r12
    jae 99f
    imul $SPT_SIZE, %r12, %rax
    add STK_PARTS(%rsp), %rax
    mov SPT_ARENA(%rax), %rdi
    call arena_destroy
    inc %r12
    jmp 9b
99: mov %r15, %rax
    LEAVE
ENDF table_col_stats

/* table_free(t): destroys the table's indexes, then its arena */
FUNC table_free
    ENTER 0
    mov %rdi, %rbx
    mov TB_INDEXES(%rbx), %r12
    test %r12, %r12
    jz 2f
    xor %r13d, %r13d
1:  cmp VEC_LEN(%r12), %r13
    jae 2f
    mov VEC_DATA(%r12), %rax
    mov (%rax, %r13, 8), %rdi
    call idx_free
    inc %r13
    jmp 1b
2:  mov TB_MAP(%rbx), %rdi          /* lazily decoded PQCF file */
    test %rdi, %rdi
    jz 3f
    mov TB_MAPLEN(%rbx), %rsi
    call munmap
3:  mov TB_ARENA(%rbx), %rdi
    call arena_destroy
    LEAVE
ENDF table_free
