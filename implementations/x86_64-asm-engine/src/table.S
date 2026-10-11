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
    xor %r12d, %r12d
1:  cmp TB_NCOLS(%rbx), %r12
    jae 99f
    mov %r12, %r13
    shl $COL_SHIFT, %r13
    add TB_COLS(%rbx), %r13         /* Column* */
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
    jne 6f
    cmpq $DICT_OFF, 8(%rsp)
    je 6f
    mov %rbx, %rdi
    mov %r13, %rsi
    mov 8(%rsp), %rdx
    call dict_encode
6:  inc %r12
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

/* table_stats(t) -> rax ColStats[ncols] */
FUNC table_stats
    ENTER 64
    mov %rdi, %rbx
    mov TB_STATS(%rbx), %rax
    test %rax, %rax
    jnz 99f
    mov TB_NCOLS(%rbx), %rsi
    imul $CST_SIZE, %rsi
    add $8, %rsi
    mov TB_ARENA(%rbx), %rdi
    call arena_zalloc
    mov %rax, 0(%rsp)               /* stats */
    xor %r12d, %r12d                /* column */
1:  cmp TB_NCOLS(%rbx), %r12
    jae 9f
    mov %r12, %r13
    shl $COL_SHIFT, %r13
    add TB_COLS(%rbx), %r13         /* Column* */
    imul $CST_SIZE, %r12, %r15
    add 0(%rsp), %r15               /* ColStats* */
    mov COL_TYPE(%r13), %rax
    mov %rax, 8(%rsp)
    mov $1, %edi
    lea 8(%rsp), %rsi
    call ht_new
    mov %rax, 16(%rsp)
    xor %r14d, %r14d                /* row */
2:  cmp TB_NROWS(%rbx), %r14
    jae 8f
    mov %r13, %rdi
    mov %r14, %rsi
    call col_get
    test %edx, %edx
    jz 3f
    incq CST_NULLS(%r15)
    jmp 7f
3:  mov %rax, 24(%rsp)              /* value; probe cell 24..39 */
    movq $0, 32(%rsp)
    cmpq $0, CST_HAS(%r15)
    jne 4f
    movq $1, CST_HAS(%r15)
    mov %rax, CST_MIN(%r15)
    mov %rax, CST_MAX(%r15)
    jmp 6f
4:  mov 8(%rsp), %rdi
    mov %rax, %rsi
    mov CST_MIN(%r15), %rdx
    call value_cmp
    test %eax, %eax
    jns 5f
    mov 24(%rsp), %rax
    mov %rax, CST_MIN(%r15)
5:  mov 8(%rsp), %rdi
    mov 24(%rsp), %rsi
    mov CST_MAX(%r15), %rdx
    call value_cmp
    test %eax, %eax
    jle 6f
    mov 24(%rsp), %rax
    mov %rax, CST_MAX(%r15)
6:  mov 16(%rsp), %rdi              /* distinct values */
    lea 24(%rsp), %rsi
    xor %edx, %edx
    call ht_lookup
    test %rax, %rax
    jnz 7f
    mov $VAL_SIZE, %edi
    call tmp_zalloc
    mov 24(%rsp), %rcx
    mov %rcx, VAL_P(%rax)
    mov 16(%rsp), %rdi
    mov %rax, %rsi
    mov $1, %edx
    call ht_lookup
7:  inc %r14
    jmp 2b
8:  mov 16(%rsp), %rax
    mov HT_N(%rax), %rax
    mov %rax, CST_DISTINCT(%r15)
    inc %r12
    jmp 1b
9:  mov 0(%rsp), %rax
    mov %rax, TB_STATS(%rbx)
99: LEAVE
ENDF table_stats

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
2:  mov TB_ARENA(%rbx), %rdi
    call arena_destroy
    LEAVE
ENDF table_free
