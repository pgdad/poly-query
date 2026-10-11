// =============================================================================
// storage.S — in-memory table representations (indexes-and-planning.md §1).
//
// A table is stored either column-oriented (LAYOUT_COLUMN: one payload vector
// or dictionary-encoded vector per column plus a null bitmap) or
// row-oriented (LAYOUT_ROW: a row store of fixed-size records, each holding
// the row's payloads followed by its null bitmap). See include/pq.inc.
//
//   tbl_get(x0 Table*, x1 col, x2 row) -> x0 payload, x1 isnull
//   table_finalize(x0 Table*, w1 layout, w2 dict mode)
//       converts a freshly built plain columnar table (ingest / PQCF reader)
//       into its final representation, in place
//   table_stats(x0 Table*) -> x0 ColStats* [ncols] (computed once, cached)
// =============================================================================
#include "pq.inc"
#include "frame.inc"

    .text

// =============================================================================
// tbl_get(x0 Table*, x1 col, x2 row) -> x0 payload, x1 isnull   (leaf)
// Generic value access for any layout / encoding.
// =============================================================================
FUNC tbl_get
    ldr  w9, [x0, #TBL_LAYOUT]
    cbnz w9, 4f
    ldr  x9, [x0, #TBL_COLS]
    add  x9, x9, x1, lsl #5
    ldr  x12, [x9, #COL_NULLS]
    mov  x1, #0
    cbz  x12, 1f
    NULLBIT_TEST 1, 12, 2, 14
1:  ldr  w14, [x9, #COL_ENC]
    ldr  x13, [x9, #COL_DATA]
    cbnz w14, 2f
    ldr  x0, [x13, x2, lsl #3]
    ret
2:  ldr  x14, [x13, #DC_CODES]
    ldr  w14, [x14, x2, lsl #2]
    ldr  x13, [x13, #DC_DICT]
    ldr  x0, [x13, x14, lsl #3]
    ret
4:  ldr  x12, [x0, #TBL_STRIDE]
    ldr  x13, [x0, #TBL_ROWS]
    madd x13, x2, x12, x13
    ldr  x12, [x0, #TBL_NCOLS]
    mov  x11, x1
    ldr  x0, [x13, x11, lsl #3]
    add  x13, x13, x12, lsl #3
    NULLBIT_TEST 1, 13, 11, 14
    ret
ENDF tbl_get

// =============================================================================
// table_finalize(x0 Table*, w1 layout LAYOUT_* or -1 = default (column),
//                w2 dict mode: 0 = auto, 1 = force dictionary for STRING)
// Converts a freshly built plain columnar table (ingest / PQCF reader) into
// its final representation:
//   * null bitmaps without any NULL are dropped (COL_NULLS = 0)
//   * LAYOUT_COLUMN: STRING columns are dictionary-encoded when forced or
//     when it pays off (distinct values <= rows / 2)
//   * LAYOUT_ROW: the columns are transposed into the row store
// New structures are allocated in the table arena.
//   x19 table, w20 layout, w21 dict mode, x22 column index, x23 Column*
// =============================================================================
FUNC table_finalize
    ENTER 3
    mov  x19, x0
    mov  w20, w1
    mov  w21, w2
    mov  x22, #0
1:  ldr  x9, [x19, #TBL_NCOLS]          // drop NULL-free bitmaps
    cmp  x22, x9
    b.hs 2f
    ldr  x23, [x19, #TBL_COLS]
    add  x23, x23, x22, lsl #5
    ldr  x0, [x23, #COL_NULLS]
    ldr  x1, [x19, #TBL_NROWS]
    bl   bitmap_any
    cbnz w0, 11f
    str  xzr, [x23, #COL_NULLS]
11: add  x22, x22, #1
    b    1b
2:  cmp  w20, #LAYOUT_ROW
    b.ne 3f
    mov  x0, x19
    bl   to_row_layout
    LEAVE 3
3:  mov  x22, #0                        // column layout: dictionaries
4:  ldr  x9, [x19, #TBL_NCOLS]
    cmp  x22, x9
    b.hs 6f
    ldr  x23, [x19, #TBL_COLS]
    add  x23, x23, x22, lsl #5
    ldr  w9, [x23, #COL_TYPE]
    and  w9, w9, #T_KIND_MASK
    cmp  w9, #T_STR
    b.ne 5f
    ldr  w9, [x23, #COL_ENC]
    cbnz w9, 5f
    mov  x0, x19
    mov  x1, x23
    mov  w2, w21
    bl   dict_encode
5:  add  x22, x22, #1
    b    4b
6:  LEAVE 3
ENDF table_finalize

// bitmap_any(x0 bitmap or 0, x1 nbits) -> w0 1 if any of the first nbits
// bits is set   (leaf)
LFUNC bitmap_any
    cbz  x0, 9f
    lsr  x9, x1, #3                     // whole bytes
    mov  x10, #0
1:  cmp  x10, x9
    b.hs 2f
    ldrb w11, [x0, x10]
    cbnz w11, 8f
    add  x10, x10, #1
    b    1b
2:  ands x11, x1, #7                    // trailing bits
    b.eq 9f
    ldrb w12, [x0, x9]
    mov  w13, #1
    lsl  w13, w13, w11
    sub  w13, w13, #1
    tst  w12, w13
    b.ne 8f
9:  mov  w0, #0
    ret
8:  mov  w0, #1
    ret
ENDF bitmap_any

// =============================================================================
// dict_encode(x0 Table*, x1 Column* (PLAIN STRING), w2 force)
// Builds the dictionary with an open-addressing hash table (request arena).
// Unless forced, the column is converted only if distinct <= rows / 2.
//   x19 table, x20 column, w21 force, x22 nrows, x23 slots (u32 code+1),
//   x24 mask, x25 dict (Str**), x26 ndict, x27 codes, x28 row
// =============================================================================
LFUNC dict_encode
    ENTER 5
    mov  x19, x0
    mov  x20, x1
    mov  w21, w2
    ldr  x22, [x19, #TBL_NROWS]
    cbz  x22, .Lde_ret
    lsl  x9, x22, #1                    // slots: power of two >= 2n
    mov  x24, #16
1:  cmp  x24, x9
    b.hs 2f
    lsl  x24, x24, #1
    b    1b
2:  lsl  x0, x24, #2
    bl   arena_zalloc
    mov  x23, x0
    sub  x24, x24, #1
    lsl  x0, x22, #3
    bl   arena_alloc
    mov  x25, x0
    lsl  x0, x22, #2
    bl   arena_alloc
    mov  x27, x0
    mov  x26, #0
    mov  x28, #0
.Lde_row:
    cmp  x28, x22
    b.hs .Lde_built
    ldr  x9, [x20, #COL_NULLS]
    cbz  x9, 3f
    NULLBIT_TEST 10, 9, 28, 11
    cbz  w10, 3f
    str  wzr, [x27, x28, lsl #2]        // NULL slot: code 0
    b    .Lde_next
3:  ldr  x9, [x20, #COL_DATA]
    ldr  x0, [x9, x28, lsl #3]
    mov  w1, #T_STR
    bl   hash_cell
    and  x0, x0, x24
.Lde_probe:
    ldr  w9, [x23, x0, lsl #2]
    cbz  w9, .Lde_new
    sub  w9, w9, #1
    stp  x0, x9, [sp, #-16]!
    ldr  x10, [x25, x9, lsl #3]         // existing entry
    ldr  x11, [x20, #COL_DATA]
    ldr  x11, [x11, x28, lsl #3]        // this value
    ldr  x1, [x10, #STR_LEN]
    ldr  x3, [x11, #STR_LEN]
    add  x0, x10, #STR_DATA
    add  x2, x11, #STR_DATA
    bl   bytes_cmp
    mov  w12, w0
    ldp  x0, x9, [sp], #16
    cbz  w12, .Lde_found
    add  x0, x0, #1
    and  x0, x0, x24
    b    .Lde_probe
.Lde_new:
    add  w9, w26, #1
    str  w9, [x23, x0, lsl #2]
    ldr  x10, [x20, #COL_DATA]
    ldr  x10, [x10, x28, lsl #3]
    str  x10, [x25, x26, lsl #3]
    mov  x9, x26
    add  x26, x26, #1
.Lde_found:
    str  w9, [x27, x28, lsl #2]
.Lde_next:
    add  x28, x28, #1
    b    .Lde_row
.Lde_built:
    cbnz w21, 4f
    lsl  x9, x26, #1
    cmp  x9, x22
    b.hi .Lde_ret                       // not worth it
4:  add  x0, x19, #TBL_ARENA            // move codes + dictionary to the table
    mov  x1, #DC_SIZE
    bl   arena_alloc_in
    mov  x21, x0
    str  x26, [x21, #DC_NDICT]
    add  x0, x19, #TBL_ARENA
    lsl  x1, x22, #2
    add  x1, x1, #8
    bl   arena_alloc_in
    str  x0, [x21, #DC_CODES]
    mov  x1, x27
    lsl  x2, x22, #2
    bl   memcpy
    add  x0, x19, #TBL_ARENA
    lsl  x1, x26, #3
    add  x1, x1, #8
    bl   arena_alloc_in
    str  x0, [x21, #DC_DICT]
    mov  x1, x25
    lsl  x2, x26, #3
    bl   memcpy
    str  x21, [x20, #COL_DATA]
    mov  w9, #CENC_DICT
    str  w9, [x20, #COL_ENC]
.Lde_ret:
    LEAVE 5
ENDF dict_encode

// =============================================================================
// to_row_layout(x0 Table*) — builds the row store from the plain columns.
// Row record: ncols u64 payloads, then a null bitmap of ceil(ncols/8) bytes,
// padded to a multiple of 8 bytes.
//   x19 table, x20 ncols, x21 nrows, x22 stride, x23 rows, x24 row,
//   x25 col, x26 record
// =============================================================================
LFUNC to_row_layout
    ENTER 5
    mov  x19, x0
    ldr  x20, [x19, #TBL_NCOLS]
    ldr  x21, [x19, #TBL_NROWS]
    add  x9, x20, #7
    lsr  x9, x9, #3
    add  x22, x9, x20, lsl #3
    add  x22, x22, #7
    and  x22, x22, #~7
    mul  x1, x22, x21
    add  x1, x1, #8
    add  x0, x19, #TBL_ARENA
    bl   arena_alloc_in
    mov  x23, x0
    mov  x24, #0
1:  cmp  x24, x21
    b.hs 5f
    madd x26, x24, x22, x23
    add  x0, x26, x20, lsl #3           // clear the record's null bitmap
    mov  w1, #0
    sub  x2, x22, x20, lsl #3
    bl   memset
    mov  x25, #0
2:  cmp  x25, x20
    b.hs 4f
    mov  x0, x19
    mov  x1, x25
    mov  x2, x24
    bl   tbl_get
    str  x0, [x26, x25, lsl #3]
    cbz  x1, 3f
    add  x9, x26, x20, lsl #3
    lsr  x10, x25, #3
    ldrb w11, [x9, x10]
    and  w12, w25, #7
    mov  w13, #1
    lsl  w13, w13, w12
    orr  w11, w11, w13
    strb w11, [x9, x10]
3:  add  x25, x25, #1
    b    2b
4:  add  x24, x24, #1
    b    1b
5:  str  x23, [x19, #TBL_ROWS]
    str  x22, [x19, #TBL_STRIDE]
    mov  x25, #0                        // columns no longer hold data
6:  cmp  x25, x20
    b.hs 7f
    ldr  x9, [x19, #TBL_COLS]
    add  x9, x9, x25, lsl #5
    stp  xzr, xzr, [x9, #COL_DATA]
    str  wzr, [x9, #COL_ENC]
    add  x25, x25, #1
    b    6b
7:  mov  w9, #LAYOUT_ROW
    str  w9, [x19, #TBL_LAYOUT]
    LEAVE 5
ENDF to_row_layout

// =============================================================================
// table_stats(x0 Table*) -> x0 ColStats* [ncols]
// Per column: null count, min, max and the exact number of distinct non-NULL
// values (hash set over row ids). Tables are immutable, so the result is
// computed on first use and cached in the table arena (TBL_STATS).
//   x19 table, x20 stats, x21 column, x22 ColStats*, x23 row, x24 nrows,
//   x25 type, x26 slots (u32 row+1), x27 mask
// =============================================================================
FUNC table_stats
    ENTER 5
    mov  x19, x0
    ldr  x0, [x19, #TBL_STATS]
    cbz  x0, 1f
    LEAVE 5
1:  ldr  x24, [x19, #TBL_NROWS]
    ldr  x9, [x19, #TBL_NCOLS]
    add  x0, x19, #TBL_ARENA
    lsl  x1, x9, #5                     // CST_SIZE = 32
    add  x1, x1, #CST_SIZE
    bl   arena_alloc_in
    mov  x20, x0
    lsl  x9, x24, #1                    // hash slots: power of two >= 2n
    mov  x27, #16
2:  cmp  x27, x9
    b.hs 3f
    lsl  x27, x27, #1
    b    2b
3:  lsl  x0, x27, #2
    bl   arena_alloc
    mov  x26, x0
    sub  x27, x27, #1
    mov  x21, #0
.Lts_col:
    ldr  x9, [x19, #TBL_NCOLS]
    cmp  x21, x9
    b.hs .Lts_done
    add  x22, x20, x21, lsl #5
    stp  xzr, xzr, [x22]
    stp  xzr, xzr, [x22, #16]
    ldr  x9, [x19, #TBL_COLS]
    add  x9, x9, x21, lsl #5
    ldr  w25, [x9, #COL_TYPE]
    mov  x0, x26
    mov  w1, #0
    add  x2, x27, #1
    lsl  x2, x2, #2
    bl   memset
    mov  x23, #0
.Lts_row:
    cmp  x23, x24
    b.hs .Lts_next
    mov  x0, x19
    mov  x1, x21
    mov  x2, x23
    bl   tbl_get
    cbz  x1, 4f
    ldr  x9, [x22, #CST_NULLS]
    add  x9, x9, #1
    str  x9, [x22, #CST_NULLS]
    b    .Lts_nextrow
4:  mov  x28, x0                        // value
    ldr  x9, [x22, #CST_DISTINCT]       // first value: min = max = value
    cbnz x9, 5f
    stp  x28, x28, [x22, #CST_MIN]
    b    6f
5:  mov  x0, x28
    ldr  x1, [x22, #CST_MIN]
    mov  w2, w25
    bl   value_cmp
    tbz  w0, #31, 51f
    str  x28, [x22, #CST_MIN]
51: mov  x0, x28
    ldr  x1, [x22, #CST_MAX]
    mov  w2, w25
    bl   value_cmp
    cmp  w0, #0
    b.le 6f
    str  x28, [x22, #CST_MAX]
6:  mov  x0, x28                        // distinct: probe the hash set
    mov  w1, w25
    bl   hash_cell
    and  x0, x0, x27
7:  ldr  w9, [x26, x0, lsl #2]
    cbz  w9, 8f
    str  x0, [sp, #-16]!
    sub  w2, w9, #1
    mov  x0, x19
    mov  x1, x21
    bl   tbl_get
    mov  x1, x28
    mov  w2, w25
    bl   value_cmp
    mov  w9, w0
    ldr  x0, [sp], #16
    cbz  w9, .Lts_nextrow               // seen before
    add  x0, x0, #1
    and  x0, x0, x27
    b    7b
8:  add  w9, w23, #1
    str  w9, [x26, x0, lsl #2]
    ldr  x9, [x22, #CST_DISTINCT]
    add  x9, x9, #1
    str  x9, [x22, #CST_DISTINCT]
.Lts_nextrow:
    add  x23, x23, #1
    b    .Lts_row
.Lts_next:
    add  x21, x21, #1
    b    .Lts_col
.Lts_done:
    str  x20, [x19, #TBL_STATS]
    mov  x0, x20
    LEAVE 5
ENDF table_stats

    NOTE_GNU_STACK
