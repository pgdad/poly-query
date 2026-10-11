// =============================================================================
// storage.S — in-memory table representations (indexes-and-planning.md §1).
//
// A table is stored either column-oriented (LAYOUT_COLUMN: one payload vector
// or dictionary-encoded vector per column plus a null bitmap) or
// row-oriented (LAYOUT_ROW: a row store of fixed-size records, each holding
// the row's payloads followed by its null bitmap). See include/pq.inc.
//
//   tbl_get(x0 Table*, x1 col, x2 row) -> x0 payload, x1 isnull
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

    NOTE_GNU_STACK
