/*
 * index.S - single-column secondary indexes (indexes-and-planning.md §2).
 *
 *   HASH   chained hash over row ids: heads[hash(value) & (nb-1)] -> row,
 *          next[row] -> row; equality lookups.
 *   BTREE  an ordered structure realised as a sorted permutation: the
 *          non-NULL row ids sorted by (value, row id) plus the values in the
 *          same order; equality and range lookups by binary search.
 *
 * NULLs are never indexed, so no lookup returns them.  Indexes belong to
 * their table (TB_INDEXES) and own an arena; index names are global.
 *
 *   idx_find(ptr rdi, len rsi) -> rax Index* or 0
 *   idx_build(table rdi, col rsi, kind rdx, name pstr rcx) -> rax Index*
 *   idx_attach(table rdi, index rsi)      registers the index with its table
 *   idx_drop(ptr rdi, len rsi) -> eax 1 if dropped, 0 if unknown
 *   idx_free(index rdi)
 *   idx_eq(index rdi, value rsi, out Vec* rdx)     appends matching row ids
 *   idx_range(index rdi, lo rsi, hi rdx, flags rcx (RF_*), out Vec* r8)
 *   idx_kind_name(kind rdi) -> rax "HASH" / "BTREE"
 */
#include "pq.inc"
#include "sql.inc"

    .section .note.GNU-stack, "", @progbits

    .section .rodata
kn_hash:  .asciz "HASH"
kn_btree: .asciz "BTREE"

    .text

FUNC idx_kind_name
    lea kn_hash(%rip), %rax
    cmp $IXK_HASH, %rdi
    je 1f
    lea kn_btree(%rip), %rax
1:  ret
ENDF idx_kind_name

/* idx_find(ptr, len) -> rax Index* or 0 (searches every table's indexes) */
FUNC idx_find
    ENTER 16
    mov %rdi, 0(%rsp)
    mov %rsi, 8(%rsp)
    xor %r12d, %r12d                /* table */
1:  call cat_count
    cmp %rax, %r12
    jae 8f
    mov %r12, %rdi
    call cat_at
    mov TB_INDEXES(%rax), %r13
    test %r13, %r13
    jz 4f
    xor %r14d, %r14d
2:  cmp VEC_LEN(%r13), %r14
    jae 4f
    mov VEC_DATA(%r13), %rax
    mov (%rax, %r14, 8), %rbx
    mov IX_NAME(%rbx), %rax
    mov 0(%rsp), %rdi
    mov 8(%rsp), %rsi
    lea 8(%rax), %rdx
    mov (%rax), %rcx
    call mem_ieq
    test %eax, %eax
    jnz 9f
    inc %r14
    jmp 2b
4:  inc %r12
    jmp 1b
8:  xor %ebx, %ebx
9:  mov %rbx, %rax
    LEAVE
ENDF idx_find

/* idx_attach(table, index) */
FUNC idx_attach
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    cmpq $0, TB_INDEXES(%rbx)
    jne 1f
    mov TB_ARENA(%rbx), %rdi
    call vec_new
    mov %rax, TB_INDEXES(%rbx)
1:  mov TB_INDEXES(%rbx), %rdi
    mov %r12, %rsi
    call vec_push
    LEAVE
ENDF idx_attach

/* idx_drop(ptr, len) -> eax */
FUNC idx_drop
    ENTER 0
    call idx_find
    test %rax, %rax
    jz 9f
    mov %rax, %rbx
    mov IX_TABLE(%rbx), %rax
    mov TB_INDEXES(%rax), %r12      /* remove from the table's list, keep order */
    xor %ecx, %ecx
1:  mov VEC_DATA(%r12), %rdx
    cmp (%rdx, %rcx, 8), %rbx
    je 2f
    inc %rcx
    jmp 1b
2:  lea 1(%rcx), %rax
    cmp VEC_LEN(%r12), %rax
    jae 3f
    mov (%rdx, %rax, 8), %rsi
    mov %rsi, (%rdx, %rcx, 8)
    mov %rax, %rcx
    jmp 2b
3:  decq VEC_LEN(%r12)
    mov %rbx, %rdi
    call idx_free
    mov $1, %eax
9:  LEAVE
ENDF idx_drop

FUNC idx_free
    sub $8, %rsp
    mov IX_ARENA(%rdi), %rdi
    call arena_destroy
    add $8, %rsp
    ret
ENDF idx_free

/* ix_value(ix rdi, row rsi) -> rax value, edx NULL flag */
FUNC ix_value
    mov IX_TABLE(%rdi), %rax
    mov IX_COL(%rdi), %rcx
    shl $COL_SHIFT, %rcx
    add TB_COLS(%rax), %rcx
    mov %rcx, %rdi
    jmp col_get
ENDF ix_value

/* ix_hash(ix rdi, value rsi) -> rax hash */
FUNC ix_hash
    sub $24, %rsp
    mov %rsi, 0(%rsp)
    movq $0, 8(%rsp)
    lea IX_TYPE(%rdi), %rdx
    lea 0(%rsp), %rdi
    mov $1, %esi
    call hash_cells
    add $24, %rsp
    ret
ENDF ix_hash

/* ix_row_cmp(pa, pb, ix): qsort_r comparator on row ids by (value, row) */
FUNC ix_row_cmp
    ENTER 16
    mov (%rdi), %rbx
    mov (%rsi), %r12
    mov %rdx, %r13
    mov %r13, %rdi
    mov %rbx, %rsi
    call ix_value
    mov %rax, %r14
    mov %r13, %rdi
    mov %r12, %rsi
    call ix_value
    mov IX_TYPE(%r13), %rdi
    mov %r14, %rsi
    mov %rax, %rdx
    call value_cmp
    test %eax, %eax
    jnz 9f
    cmp %r12, %rbx
    je 9f
    mov $-1, %eax
    jb 9f
    mov $1, %eax
9:  LEAVE
ENDF ix_row_cmp

/* idx_build(table, col, kind, name pstr) -> rax Index* */
FUNC idx_build
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rcx, 0(%rsp)
    call arena_new
    mov %rax, %r15                  /* index arena */
    mov %r15, %rdi
    mov $IX_SIZE, %esi
    call arena_zalloc
    mov %rax, %r14                  /* ix */
    mov %r15, IX_ARENA(%r14)
    mov %rbx, IX_TABLE(%r14)
    mov %r12, IX_COL(%r14)
    mov %r13, IX_KIND(%r14)
    mov %r12, %rax
    shl $COL_SHIFT, %rax
    add TB_COLS(%rbx), %rax
    mov COL_TYPE(%rax), %rax
    mov %rax, IX_TYPE(%r14)
    mov 0(%rsp), %rax
    mov %r15, %rdi
    lea 8(%rax), %rsi
    mov (%rax), %rdx
    call pstr_new
    mov %rax, IX_NAME(%r14)
    cmp $IXK_HASH, %r13
    je 20f

    /* ---- BTREE: sorted permutation of the non-NULL rows */
    mov %r15, %rdi
    mov TB_NROWS(%rbx), %rsi
    lea 8(, %rsi, 8), %rsi
    call arena_alloc
    mov %rax, IX_ROWS(%r14)
    xor %r12d, %r12d                /* row */
    xor %r13d, %r13d                /* n */
1:  cmp TB_NROWS(%rbx), %r12
    jae 2f
    mov %r14, %rdi
    mov %r12, %rsi
    call ix_value
    test %edx, %edx
    jnz 11f
    mov IX_ROWS(%r14), %rax
    mov %r12, (%rax, %r13, 8)
    inc %r13
11: inc %r12
    jmp 1b
2:  mov %r13, IX_N(%r14)
    mov IX_ROWS(%r14), %rdi
    mov %r13, %rsi
    mov $8, %edx
    lea ix_row_cmp(%rip), %rcx
    mov %r14, %r8
    call qsort_r
    mov %r15, %rdi
    lea 8(, %r13, 8), %rsi
    call arena_alloc
    mov %rax, IX_KEYS(%r14)
    xor %r12d, %r12d
3:  cmp %r13, %r12
    jae 90f
    mov IX_ROWS(%r14), %rax
    mov (%rax, %r12, 8), %rsi
    mov %r14, %rdi
    call ix_value
    mov IX_KEYS(%r14), %rcx
    mov %rax, (%rcx, %r12, 8)
    inc %r12
    jmp 3b

20: /* ---- HASH: buckets = power of two >= 2 * rows */
    mov $16, %eax
    mov TB_NROWS(%rbx), %rcx
    add %rcx, %rcx
21: cmp %rcx, %rax
    jae 22f
    shl $1, %rax
    jmp 21b
22: mov %rax, IX_NB(%r14)
    mov %r15, %rdi
    lea (, %rax, 8), %rsi
    call arena_alloc
    mov %rax, IX_HEADS(%r14)
    mov %rax, %rdi
    mov $0xff, %esi
    mov IX_NB(%r14), %rdx
    shl $3, %rdx
    call memset
    mov %r15, %rdi
    mov TB_NROWS(%rbx), %rsi
    lea 8(, %rsi, 8), %rsi
    call arena_alloc
    mov %rax, IX_NEXT(%r14)
    mov TB_NROWS(%rbx), %r12        /* insert in reverse: chains ascend */
23: test %r12, %r12
    jz 90f
    dec %r12
    mov %r14, %rdi
    mov %r12, %rsi
    call ix_value
    test %edx, %edx
    jnz 23b
    incq IX_N(%r14)
    mov %r14, %rdi
    mov %rax, %rsi
    call ix_hash
    mov IX_NB(%r14), %rcx
    dec %rcx
    and %rcx, %rax
    mov IX_HEADS(%r14), %rcx
    mov (%rcx, %rax, 8), %rdx
    mov %r12, (%rcx, %rax, 8)
    mov IX_NEXT(%r14), %rcx
    mov %rdx, (%rcx, %r12, 8)
    jmp 23b
90: mov %r14, %rax
    LEAVE
ENDF idx_build

/* bt_bound(ix rdi, key rsi, strict edx) -> rax first position whose key is
 * >= key (strict = 0) or > key (strict = 1) */
FUNC bt_bound
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %edx, %r13d
    xor %r14d, %r14d                /* lo */
    mov IX_N(%rbx), %r15            /* hi */
1:  cmp %r15, %r14
    jae 9f
    lea (%r14, %r15), %rax
    shr $1, %rax
    mov %rax, 0(%rsp)               /* mid */
    mov IX_KEYS(%rbx), %rcx
    mov (%rcx, %rax, 8), %rsi
    mov IX_TYPE(%rbx), %rdi
    mov %r12, %rdx
    call value_cmp                  /* keys[mid] vs key */
    test %eax, %eax
    js 3f
    jnz 4f
    test %r13d, %r13d               /* equal: goes left unless strict */
    jz 4f
3:  mov 0(%rsp), %r14
    inc %r14
    jmp 1b
4:  mov 0(%rsp), %r15
    jmp 1b
9:  mov %r14, %rax
    LEAVE
ENDF bt_bound

/* idx_range(ix, lo, hi, flags, out) - BTREE only */
FUNC idx_range
    ENTER 32
    mov %rdi, %rbx
    mov %rsi, 0(%rsp)
    mov %rdx, 8(%rsp)
    mov %rcx, %r12                  /* flags */
    mov %r8, %r13                   /* out */
    xor %r14d, %r14d                /* start */
    test $RF_LO, %r12
    jz 1f
    mov %rbx, %rdi
    mov 0(%rsp), %rsi
    xor %edx, %edx
    test $RF_LOI, %r12
    sete %dl
    call bt_bound
    mov %rax, %r14
1:  mov IX_N(%rbx), %r15            /* end */
    test $RF_HI, %r12
    jz 2f
    mov %rbx, %rdi
    mov 8(%rsp), %rsi
    xor %edx, %edx
    test $RF_HII, %r12
    setne %dl
    call bt_bound
    mov %rax, %r15
2:  cmp %r15, %r14
    jae 9f
    mov IX_ROWS(%rbx), %rax
    mov (%rax, %r14, 8), %rsi
    mov %r13, %rdi
    call vec_push
    inc %r14
    jmp 2b
9:  LEAVE
ENDF idx_range

/* idx_eq(ix, value, out) */
FUNC idx_eq
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    cmpq $IXK_HASH, IX_KIND(%rbx)
    je 1f
    mov %r12, %rdx
    mov $RF_LO|RF_LOI|RF_HI|RF_HII, %ecx
    mov %r13, %r8
    call idx_range
    LEAVE
1:  mov %r12, %rsi
    call ix_hash
    mov IX_NB(%rbx), %rcx
    dec %rcx
    and %rcx, %rax
    mov IX_HEADS(%rbx), %rcx
    mov (%rcx, %rax, 8), %r14       /* row */
2:  cmp $-1, %r14
    je 9f
    mov %rbx, %rdi
    mov %r14, %rsi
    call ix_value
    mov IX_TYPE(%rbx), %rdi
    mov %rax, %rsi
    mov %r12, %rdx
    call value_cmp
    test %eax, %eax
    jnz 3f
    mov %r13, %rdi
    mov %r14, %rsi
    call vec_push
3:  mov IX_NEXT(%rbx), %rax
    mov (%rax, %r14, 8), %r14
    jmp 2b
9:  LEAVE
ENDF idx_eq
