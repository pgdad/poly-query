// =============================================================================
// index.S — secondary indexes (indexes-and-planning.md §2).
//
// Indexes are single-column and global by name (ASCII case-insensitive).
// Each Index record is malloc'ed with its own arena holding its structures:
//   HASH   chained hash table over the row ids: IX_HEADS[bucket] -> first
//          row, IX_NEXT[row] -> next row in the bucket (ROW_NULL ends)
//   BTREE  the equivalent ordered structure: a sorted permutation of the
//          non-NULL row ids (IX_ROWS) with the matching sorted values
//          (IX_VALS) for binary search
// NULLs are never indexed, so no lookup returns them. Indexes are bound to
// a Table*; dropping or replacing the table drops them (catalog.S).
//
//   index_find(x0 name ptr, x1 len) -> x0 Index* or 0
//   index_create(x0 Table*, x1 name Str*, x2 column, w3 IXK_*) -> x0 Index*
//   index_drop(x0 Index*)
//   index_drop_table(x0 Table*)            drop every index of the table
//   index_reset()                          drop every index
//   index_list(x0 Table*) -> x0 Index** (request arena), x1 count
//   index_for_column(x0 Table*, x1 column, w2 need ordered)
//       -> x0 Index* or 0 (prefers BTREE if ordered access is needed)
//   index_check_specs(x0 XS* specs, x1 count, x2 Table* being replaced or 0)
//       raises ALREADY_EXISTS if a spec's name is already used by an index
//       (ignoring indexes of the table being replaced)
//   index_create_specs(x0 Table*, x1 XS* specs, x2 count)
//   index_stmt(x0 Statement*)              CREATE INDEX / DROP INDEX
//   index_lookup_eq(x0 Index*, x1 key, w2 key type, x3 RowVec*)
//       appends the rows whose value equals the key
//   index_lookup_range(x0 Index*, x1 Range*, x2 RowVec*)   (BTREE only)
//       appends the rows within the range
//   rowvec_sort_unique(x0 RowVec*)         sorts ascending, drops duplicates
// =============================================================================
#include "pq.inc"
#include "frame.inc"

// IX_VALS: BTREE sorted payloads (shares the record tail)
#define IX_VALS    104

    .bss
    .p2align 3
g_indexes:  .skip 8         // Index** (malloc)
g_nindexes: .skip 8
g_icap:     .skip 8

    .text

// =============================================================================
// index_find(x0 name ptr, x1 len) -> x0 Index* or 0
//   x19 name, x20 len, x21 i
// =============================================================================
FUNC index_find
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    mov  x21, #0
1:  LDR_G x9, g_nindexes
    cmp  x21, x9
    b.hs 8f
    LDR_G x9, g_indexes
    ldr  x22, [x9, x21, lsl #3]
    ldr  x2, [x22, #IX_NAME]
    ldr  x3, [x2, #STR_LEN]
    add  x2, x2, #STR_DATA
    mov  x0, x19
    mov  x1, x20
    bl   ci_eq
    cbnz w0, 9f
    add  x21, x21, #1
    b    1b
8:  mov  x22, #0
9:  mov  x0, x22
    LEAVE 3
ENDF index_find

// =============================================================================
// index_create(x0 Table*, x1 name Str*, x2 column, w3 kind) -> x0 Index*
// Builds the index and registers it (the caller checked the name).
//   x19 table, x20 name, x21 column, w22 kind, x23 Index*
// =============================================================================
FUNC index_create
    ENTER 4
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  w22, w3
    mov  x0, #1
    mov  x1, #IX_SIZE
    bl   calloc
    cbnz x0, 1f
    RAISE ERR_RESOURCE_LIMIT, "out of memory"
1:  mov  x23, x0
    str  x19, [x23, #IX_TABLE]
    str  x21, [x23, #IX_COL]
    str  w22, [x23, #IX_KIND]
    add  x0, x23, #IX_ARENA
    add  x1, x20, #STR_DATA
    ldr  x2, [x20, #STR_LEN]
    bl   str_new_in
    str  x0, [x23, #IX_NAME]
    mov  x0, x23
    cmp  w22, #IXK_HASH
    b.ne 2f
    bl   build_hash
    b    3f
2:  bl   build_btree
3:  // register
    LDR_G x9, g_nindexes
    LDR_G x10, g_icap
    cmp  x9, x10
    b.lo 4f
    lsl  x10, x10, #1
    cmp  x10, #16
    mov  x11, #16
    csel x22, x10, x11, hs
    LDR_G x0, g_indexes
    lsl  x1, x22, #3
    bl   realloc
    cbnz x0, 31f
    RAISE ERR_RESOURCE_LIMIT, "out of memory"
31: ADR_L x9, g_indexes
    str  x0, [x9]
    ADR_L x9, g_icap
    str  x22, [x9]
4:  LDR_G x9, g_nindexes
    LDR_G x10, g_indexes
    str  x23, [x10, x9, lsl #3]
    add  x9, x9, #1
    ADR_L x10, g_nindexes
    str  x9, [x10]
    mov  x0, x23
    LEAVE 4
ENDF index_create

// =============================================================================
// build_hash(x0 Index*) — chained hash table over the non-NULL rows.
// Rows are inserted in descending order so every chain is ascending.
//   x19 index, x20 table, x21 column, x22 nrows, x23 heads, x24 next,
//   x25 mask, x26 row, x27 type, x28 count
// =============================================================================
LFUNC build_hash
    ENTER 5
    mov  x19, x0
    ldr  x20, [x19, #IX_TABLE]
    ldr  x21, [x19, #IX_COL]
    ldr  x22, [x20, #TBL_NROWS]
    ldr  x9, [x20, #TBL_COLS]
    add  x9, x9, x21, lsl #5
    ldr  w27, [x9, #COL_TYPE]
    lsl  x9, x22, #1
    mov  x25, #16
1:  cmp  x25, x9
    b.hs 2f
    lsl  x25, x25, #1
    b    1b
2:  add  x0, x19, #IX_ARENA
    lsl  x1, x25, #2
    bl   arena_alloc_in
    mov  x23, x0
    mov  w1, #0xff
    lsl  x2, x25, #2
    bl   memset
    sub  x25, x25, #1
    add  x0, x19, #IX_ARENA
    lsl  x1, x22, #2
    add  x1, x1, #8
    bl   arena_alloc_in
    mov  x24, x0
    mov  x28, #0
    mov  x26, x22
3:  cbz  x26, 5f
    sub  x26, x26, #1
    mov  x0, x20
    mov  x1, x21
    mov  x2, x26
    bl   tbl_get
    cbnz x1, 3b                         // NULLs are not indexed
    mov  w1, w27
    bl   hash_cell
    and  x0, x0, x25
    ldr  w9, [x23, x0, lsl #2]
    str  w9, [x24, x26, lsl #2]
    str  w26, [x23, x0, lsl #2]
    add  x28, x28, #1
    b    3b
5:  str  x23, [x19, #IX_HEADS]
    str  x24, [x19, #IX_NEXT]
    str  x25, [x19, #IX_MASK]
    str  x28, [x19, #IX_N]
    LEAVE 5
ENDF build_hash

// =============================================================================
// build_btree(x0 Index*) — sorted (value, row) pairs of the non-NULL rows.
//   x19 index, x20 table, x21 column, x22 nrows, x23 pairs, x24 count,
//   x25 row, x26 type
// =============================================================================
LFUNC build_btree
    ENTER 5
    mov  x19, x0
    ldr  x20, [x19, #IX_TABLE]
    ldr  x21, [x19, #IX_COL]
    ldr  x22, [x20, #TBL_NROWS]
    ldr  x9, [x20, #TBL_COLS]
    add  x9, x9, x21, lsl #5
    ldr  w26, [x9, #COL_TYPE]
    lsl  x0, x22, #4
    add  x0, x0, #16
    bl   arena_alloc
    mov  x23, x0
    mov  x24, #0
    mov  x25, #0
1:  cmp  x25, x22
    b.hs 2f
    mov  x0, x20
    mov  x1, x21
    mov  x2, x25
    bl   tbl_get
    cbnz x1, 11f
    add  x9, x23, x24, lsl #4
    stp  x0, x25, [x9]
    add  x24, x24, #1
11: add  x25, x25, #1
    b    1b
2:  mov  x0, x23                        // sort by (value, row)
    mov  x1, x24
    mov  x2, #16
    ADR_L x3, cmp_pairs
    mov  x4, x26
    bl   qsort_r
    add  x0, x19, #IX_ARENA
    lsl  x1, x24, #3
    add  x1, x1, #8
    bl   arena_alloc_in
    str  x0, [x19, #IX_VALS]
    add  x0, x19, #IX_ARENA
    lsl  x1, x24, #2
    add  x1, x1, #8
    bl   arena_alloc_in
    str  x0, [x19, #IX_ROWS]
    ldr  x10, [x19, #IX_VALS]
    mov  x9, #0
3:  cmp  x9, x24
    b.hs 4f
    add  x11, x23, x9, lsl #4
    ldp  x12, x13, [x11]
    str  x12, [x10, x9, lsl #3]
    str  w13, [x0, x9, lsl #2]
    add  x9, x9, #1
    b    3b
4:  str  x24, [x19, #IX_N]
    LEAVE 5
ENDF build_btree

// cmp_pairs(x0 pair*, x1 pair*, x2 type) -> w0  (qsort_r comparator)
LFUNC cmp_pairs
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    ldr  x0, [x19]
    ldr  x1, [x20]
    bl   value_cmp
    cbnz w0, 1f
    ldr  x9, [x19, #8]
    ldr  x10, [x20, #8]
    cmp  x9, x10
    cset w0, hi
    csinv w0, w0, wzr, hs
1:  LEAVE 2
ENDF cmp_pairs

// =============================================================================
// index_drop(x0 Index*) — unregister and free.
// =============================================================================
FUNC index_drop
    ENTER 1
    mov  x19, x0
    LDR_G x1, g_indexes
    LDR_G x2, g_nindexes
    mov  x3, #0
1:  cmp  x3, x2
    b.hs 9f
    ldr  x4, [x1, x3, lsl #3]
    cmp  x4, x19
    b.eq 2f
    add  x3, x3, #1
    b    1b
2:  sub  x2, x2, #1                     // keep creation order
3:  cmp  x3, x2
    b.hs 4f
    add  x5, x3, #1
    ldr  x4, [x1, x5, lsl #3]
    str  x4, [x1, x3, lsl #3]
    mov  x3, x5
    b    3b
4:  ADR_L x4, g_nindexes
    str  x2, [x4]
    add  x0, x19, #IX_ARENA
    bl   arena_free
    mov  x0, x19
    bl   free
9:  LEAVE 1
ENDF index_drop

// index_drop_table(x0 Table*) — drops every index of the table.
//   x19 table, x20 i
FUNC index_drop_table
    ENTER 2
    mov  x19, x0
    mov  x20, #0
1:  LDR_G x9, g_nindexes
    cmp  x20, x9
    b.hs 3f
    LDR_G x9, g_indexes
    ldr  x0, [x9, x20, lsl #3]
    ldr  x10, [x0, #IX_TABLE]
    cmp  x10, x19
    b.ne 2f
    bl   index_drop                     // list shifts: same i again
    b    1b
2:  add  x20, x20, #1
    b    1b
3:  LEAVE 2
ENDF index_drop_table

// index_reset() — drops every index.
FUNC index_reset
    ENTER 0
1:  LDR_G x9, g_nindexes
    cbz  x9, 2f
    LDR_G x10, g_indexes
    sub  x9, x9, #1
    ldr  x0, [x10, x9, lsl #3]
    bl   index_drop
    b    1b
2:  LEAVE 0
ENDF index_reset

// =============================================================================
// index_list(x0 Table*) -> x0 Index** (request arena), x1 count
// The table's indexes in creation order.
//   x19 table, x20 list, x21 count, x22 i
// =============================================================================
FUNC index_list
    ENTER 3
    mov  x19, x0
    LDR_G x0, g_nindexes
    lsl  x0, x0, #3
    add  x0, x0, #8
    bl   arena_alloc
    mov  x20, x0
    mov  x21, #0
    mov  x22, #0
1:  LDR_G x9, g_nindexes
    cmp  x22, x9
    b.hs 3f
    LDR_G x9, g_indexes
    ldr  x10, [x9, x22, lsl #3]
    ldr  x11, [x10, #IX_TABLE]
    cmp  x11, x19
    b.ne 2f
    str  x10, [x20, x21, lsl #3]
    add  x21, x21, #1
2:  add  x22, x22, #1
    b    1b
3:  mov  x0, x20
    mov  x1, x21
    LEAVE 3
ENDF index_list

// =============================================================================
// index_for_column(x0 Table*, x1 column, w2 need ordered) -> x0 Index* or 0
// First index on the column (a BTREE if need ordered, else BTREE or HASH;
// a HASH index is preferred for pure equality).
//   (leaf)
// =============================================================================
FUNC index_for_column
    LDR_G x9, g_indexes
    LDR_G x10, g_nindexes
    mov  x11, #0                        // best so far
1:  cbz  x10, 4f
    ldr  x12, [x9], #8
    sub  x10, x10, #1
    ldr  x13, [x12, #IX_TABLE]
    cmp  x13, x0
    b.ne 1b
    ldr  x13, [x12, #IX_COL]
    cmp  x13, x1
    b.ne 1b
    ldr  w13, [x12, #IX_KIND]
    cbz  w2, 2f
    cmp  w13, #IXK_BTREE                // ordered access: BTREE only
    b.ne 1b
    mov  x0, x12
    ret
2:  cmp  w13, #IXK_HASH                 // equality: HASH first
    b.ne 3f
    mov  x0, x12
    ret
3:  cbnz x11, 1b
    mov  x11, x12
    b    1b
4:  mov  x0, x11
    ret
ENDF index_for_column

// =============================================================================
// index_check_specs(x0 XS*, x1 count, x2 replaced Table* or 0)
//   x19 specs, x20 count, x21 replaced, x22 i
// =============================================================================
FUNC index_check_specs
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x22, #0
1:  cmp  x22, x20
    b.hs 9f
    mov  x9, #XS_SIZE
    madd x9, x22, x9, x19
    ldr  x9, [x9, #XS_NAME]
    add  x0, x9, #STR_DATA
    ldr  x1, [x9, #STR_LEN]
    bl   index_find
    cbz  x0, 2f
    ldr  x10, [x0, #IX_TABLE]
    cbz  x21, 3f
    cmp  x10, x21
    b.eq 2f
3:  mov  x9, #XS_SIZE
    madd x9, x22, x9, x19
    ldr  x9, [x9, #XS_NAME]
    RAISE_S ERR_ALREADY_EXISTS, "index already exists ", x9
2:  add  x22, x22, #1
    b    1b
9:  LEAVE 3
ENDF index_check_specs

// =============================================================================
// index_create_specs(x0 Table*, x1 XS*, x2 count)
//   x19 table, x20 specs, x21 count, x22 i
// =============================================================================
FUNC index_create_specs
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x22, #0
1:  cmp  x22, x21
    b.hs 9f
    mov  x9, #XS_SIZE
    madd x9, x22, x9, x20
    mov  x0, x19
    ldr  x1, [x9, #XS_NAME]
    ldr  x2, [x9, #XS_COL]
    ldr  w3, [x9, #XS_KIND]
    bl   index_create
    add  x22, x22, #1
    b    1b
9:  LEAVE 3
ENDF index_create_specs

// =============================================================================
// index_stmt(x0 Statement*) — executes CREATE INDEX / DROP INDEX.
//   CREATE: unknown table / column => SEMANTIC_ERROR; existing name =>
//           ALREADY_EXISTS unless IF NOT EXISTS (then a no-op)
//   DROP:   unknown name => NOT_FOUND unless IF EXISTS
//   x19 statement, x20 table, x21 column index, x22 Index* / scratch
// =============================================================================
FUNC index_stmt
    ENTER 3
    mov  x19, x0
    ldr  x22, [x19, #ST_INDEX]
    add  x0, x22, #STR_DATA
    ldr  x1, [x22, #STR_LEN]
    bl   index_find
    ldr  w9, [x19, #ST_KIND]
    cmp  w9, #SK_DROP_INDEX
    b.ne .Lis_create
    cbnz x0, 1f
    ldr  w9, [x19, #ST_FLAGS]
    tbnz w9, #0, 9f
    RAISE_S ERR_NOT_FOUND, "unknown index ", x22
1:  bl   index_drop
    b    9f
.Lis_create:
    cbz  x0, 2f
    ldr  w9, [x19, #ST_FLAGS]
    tbnz w9, #0, 9f
    RAISE_S ERR_ALREADY_EXISTS, "index already exists ", x22
2:  ldr  x9, [x19, #ST_TABLE]
    add  x0, x9, #STR_DATA
    ldr  x1, [x9, #STR_LEN]
    bl   catalog_find
    mov  x20, x0
    cbnz x0, 3f
    ldr  x9, [x19, #ST_TABLE]
    RAISE_S ERR_SEMANTIC, "unknown table ", x9
3:  mov  x21, #0                        // resolve the column
4:  ldr  x9, [x20, #TBL_NCOLS]
    cmp  x21, x9
    b.hs 5f
    ldr  x9, [x20, #TBL_COLS]
    add  x9, x9, x21, lsl #5
    ldr  x0, [x9, #COL_NAME]
    ldr  x1, [x19, #ST_COLUMN]
    bl   str_ieq
    cbnz w0, 6f
    add  x21, x21, #1
    b    4b
5:  ldr  x9, [x19, #ST_COLUMN]
    RAISE_S ERR_SEMANTIC, "unknown column ", x9
6:  ldr  w3, [x19, #ST_USING]
    mov  w9, #IXK_BTREE                 // default: ordered index
    cmp  w3, #1
    mov  w10, #IXK_HASH
    csel w3, w10, w9, eq
    mov  x0, x20
    mov  x1, x22
    mov  x2, x21
    bl   index_create
9:  LEAVE 3
ENDF index_stmt

// =============================================================================
// Row id vectors (request arena): RV_N u64, RV_CAP u64, RV_DATA u32*
// =============================================================================
#define RVEC_N     0
#define RVEC_CAP   8
#define RVEC_DATA  16

// rowvec_push(x0 RowVec*, w1 row)
//   x19 vec, w20 row, x21 new cap
FUNC rowvec_push
    ldp  x9, x10, [x0]
    cmp  x9, x10
    b.hs 1f
    ldr  x10, [x0, #RVEC_DATA]
    str  w1, [x10, x9, lsl #2]
    add  x9, x9, #1
    str  x9, [x0]
    ret
1:  ENTER 3
    mov  x19, x0
    mov  w20, w1
    lsl  x21, x10, #1
    cmp  x21, #64
    mov  x9, #64
    csel x21, x9, x21, lo
    lsl  x0, x21, #2
    bl   arena_alloc
    ldr  x1, [x19, #RVEC_DATA]
    ldr  x2, [x19, #RVEC_N]
    lsl  x2, x2, #2
    str  x0, [x19, #RVEC_DATA]
    str  x21, [x19, #RVEC_CAP]
    cbz  x2, 2f
    bl   memcpy
2:  mov  x0, x19
    mov  w1, w20
    LEAVE_NORET 3
    b    rowvec_push
ENDF rowvec_push

// cmp_u32(x0 u32*, x1 u32*) -> w0   (qsort comparator, leaf)
LFUNC cmp_u32
    ldr  w9, [x0]
    ldr  w10, [x1]
    cmp  w9, w10
    cset w0, hi
    csinv w0, w0, wzr, hs
    ret
ENDF cmp_u32

// rowvec_sort_unique(x0 RowVec*) — ascending row ids without duplicates
//   x19 vec
FUNC rowvec_sort_unique
    ENTER 1
    mov  x19, x0
    ldr  x1, [x19, #RVEC_N]
    cmp  x1, #2
    b.lo 9f
    ldr  x0, [x19, #RVEC_DATA]
    mov  x2, #4
    ADR_L x3, cmp_u32
    bl   qsort
    ldr  x9, [x19, #RVEC_DATA]
    ldr  x10, [x19, #RVEC_N]
    mov  x11, #1                        // write position
    mov  x12, #1                        // read position
1:  cmp  x12, x10
    b.hs 3f
    ldr  w13, [x9, x12, lsl #2]
    sub  x14, x11, #1
    ldr  w14, [x9, x14, lsl #2]
    cmp  w13, w14
    b.eq 2f
    str  w13, [x9, x11, lsl #2]
    add  x11, x11, #1
2:  add  x12, x12, #1
    b    1b
3:  str  x11, [x19, #RVEC_N]
9:  LEAVE 1
ENDF rowvec_sort_unique

// =============================================================================
// key_to_col(x0 key payload, w1 key type, w2 column type) -> x0 payload in
// the column's encoding, w1 1 if exact (0: no column value can equal the key)
// Only DECIMAL keys of another scale need converting.   (leaf-like)
// =============================================================================
LFUNC key_to_col
    and  w9, w1, #T_KIND_MASK
    cmp  w9, #T_DEC
    b.ne 8f
    ubfx w10, w1, #T_SCALE_SHIFT, #8    // key scale
    ubfx w11, w2, #T_SCALE_SHIFT, #8    // column scale
    cmp  w10, w11
    b.eq 8f
    ENTER 2
    mov  x19, x0                        // key
    mov  w20, w10                       // key scale
    mov  w21, w11                       // column scale
    mov  w1, w10
    mov  w2, w11
    bl   dec_rescale
    cbnz w1, 7f                         // too many digits: no match
    mov  x22, x0
    mov  w1, w21                        // back to the key scale: exact?
    mov  w2, w20
    bl   dec_rescale
    cbnz w1, 7f
    cmp  x0, x19
    b.ne 7f
    mov  x0, x22
    mov  w1, #1
    LEAVE 2
7:  mov  w1, #0
    LEAVE 2
8:  mov  w1, #1
    ret
ENDF key_to_col

// =============================================================================
// index_lookup_eq(x0 Index*, x1 key payload, w2 key type, x3 RowVec*)
// Appends every row whose (non-NULL) value equals the key. The key has the
// column's type kind (DECIMAL scales may differ).
//   x19 index, x20 key, w21 key type, x22 vec, x23 table, x24 column,
//   w25 column type, x26 row
// =============================================================================
FUNC index_lookup_eq
    ENTER 5
    mov  x19, x0
    mov  x20, x1
    mov  w21, w2
    mov  x22, x3
    ldr  x23, [x19, #IX_TABLE]
    ldr  x24, [x19, #IX_COL]
    ldr  x9, [x23, #TBL_COLS]
    add  x9, x9, x24, lsl #5
    ldr  w25, [x9, #COL_TYPE]
    ldr  w9, [x19, #IX_KIND]
    cmp  w9, #IXK_HASH
    b.ne .Lle_btree
    mov  x0, x20
    mov  w1, w21
    mov  w2, w25
    bl   key_to_col
    cbz  w1, 9f
    mov  x20, x0
    mov  w1, w25
    bl   hash_cell
    ldr  x9, [x19, #IX_MASK]
    and  x0, x0, x9
    ldr  x9, [x19, #IX_HEADS]
    ldr  w26, [x9, x0, lsl #2]
1:  cmn  w26, #1
    b.eq 9f
    mov  x0, x23
    mov  x1, x24
    mov  x2, x26
    bl   tbl_get
    mov  x1, x20
    mov  w2, w25
    bl   value_cmp
    cbnz w0, 2f
    mov  x0, x22
    mov  w1, w26
    bl   rowvec_push
2:  ldr  x9, [x19, #IX_NEXT]
    ldr  w26, [x9, x26, lsl #2]
    b    1b
.Lle_btree:
    sub  sp, sp, #48                    // Range [key, key]
    mov  x9, #1
    stp  x20, x9, [sp]
    stp  x20, x9, [sp, #16]
    str  w21, [sp, #32]
    str  w21, [sp, #36]
    mov  x0, x19
    mov  x1, sp
    mov  x2, x22
    bl   index_lookup_range
    add  sp, sp, #48
9:  LEAVE 5
ENDF index_lookup_eq

// =============================================================================
// index_lookup_range(x0 Index* (BTREE), x1 Range*, x2 RowVec*)
// Range (40 bytes): [0] lo payload, [8] lo kind, [16] hi payload, [24] hi
// kind, [32] u32 lo type, [36] u32 hi type; kind 0 = unbounded,
// 1 = inclusive, 2 = exclusive. Rows are appended in value order.
//   x19 index, x20 range, x21 vec, w22 column type, x23 first, x24 end,
//   x25 sorted values
// =============================================================================
FUNC index_lookup_range
    ENTER 5
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    ldr  x9, [x19, #IX_TABLE]
    ldr  x10, [x19, #IX_COL]
    ldr  x9, [x9, #TBL_COLS]
    add  x9, x9, x10, lsl #5
    ldr  w22, [x9, #COL_TYPE]
    ldr  x25, [x19, #IX_VALS]
    mov  x23, #0                        // first: incl => first v >= lo,
    ldr  x9, [x20, #8]                  //        excl => first v > lo
    cbz  x9, 2f
    ldr  x0, [x20]
    mov  x1, x9
    ldr  w2, [x20, #32]
    bl   bsearch_bound
    mov  x23, x0
2:  ldr  x24, [x19, #IX_N]              // end: incl => first v > hi,
    ldr  x9, [x20, #24]                 //      excl => first v >= hi
    cbz  x9, 3f
    ldr  x0, [x20, #16]
    eor  x1, x9, #3                     // 1 <-> 2
    ldr  w2, [x20, #36]
    bl   bsearch_bound
    mov  x24, x0
3:  cmp  x23, x24
    b.hs 9f
    ldr  x9, [x19, #IX_ROWS]
    ldr  w1, [x9, x23, lsl #2]
    mov  x0, x21
    bl   rowvec_push
    add  x23, x23, #1
    b    3b
9:  LEAVE 5
ENDF index_lookup_range

// bsearch_bound(x0 key, x1 mode, w2 key type) -> x0 position in the sorted
// values; mode 1: first v >= key, mode 2: first v > key. Helper of
// index_lookup_range: reads its x19 (Index*), w22 (column type) and x25
// (sorted values), which are callee-saved and unchanged.
//   x26 key, x27 lo, x28 hi; [sp+40] mode, [sp+44] key type
LFUNC bsearch_bound
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x26, x27, [sp, #16]
    str  x28, [sp, #32]
    mov  x26, x0
    mov  x27, #0
    ldr  x28, [x19, #IX_N]
    str  w1, [sp, #40]
    str  w2, [sp, #44]
1:  cmp  x27, x28
    b.hs 4f
    add  x9, x27, x28
    lsr  x9, x9, #1
    ldr  x0, [x25, x9, lsl #3]
    mov  x1, x26
    mov  w2, w22
    ldr  w3, [sp, #44]
    bl   cmp_typed
    add  x9, x27, x28
    lsr  x9, x9, #1
    ldr  w10, [sp, #40]
    cmp  w10, #1
    b.ne 2f
    tbnz w0, #31, 3f                    // mode 1: v < key => right half
    mov  x28, x9
    b    1b
2:  cmp  w0, #0                         // mode 2: v <= key => right half
    b.gt 21f
3:  add  x27, x9, #1
    b    1b
21: mov  x28, x9
    b    1b
4:  mov  x0, x27
    ldp  x26, x27, [sp, #16]
    ldr  x28, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
ENDF bsearch_bound

    NOTE_GNU_STACK
