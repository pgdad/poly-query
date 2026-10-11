// =============================================================================
// test_storage.S — unit tests for storage.S (layouts, dictionary encoding,
// null bitmaps, statistics) and index.S (HASH / BTREE lookups).
//
// A small CSV is ingested three times and finalized as column layout (auto
// dictionary), column layout with forced dictionary and row layout; each
// table is checked through tbl_get, table_stats and two indexes:
//
//   k INT64   1  2  3  4  5  6
//   s STRING  a  b  a  c  a  b
//   v INT64  10  - 30 40  - 60       (- = NULL)
//
// Exit status 0 iff all checks pass.
// =============================================================================
#include "pq.inc"
#include "frame.inc"

    .section .rodata
csv:        .ascii "k,s,v\n1,a,10\n2,b,\n3,a,30\n4,c,40\n5,a,\n6,b,60\n"
csv_end:
fmt_fail:   .asciz "FAIL [mode %d]: %s\n"
fmt_sum:    .asciz "test_storage: %d checks, %d failures\n"
m_get_s:    .asciz "tbl_get string value"
m_get_null: .asciz "tbl_get NULL"
m_get_v:    .asciz "tbl_get INT64 value"
m_enc:      .asciz "representation (layout / encoding)"
m_nobitmap: .asciz "NULL-free column has no bitmap"
m_st_null:  .asciz "stats null count"
m_st_dist:  .asciz "stats distinct count"
m_st_min:   .asciz "stats min"
m_st_max:   .asciz "stats max"
m_st_sdist: .asciz "stats distinct strings"
m_hash:     .asciz "hash lookup 'a'"
m_hash_rows: .asciz "hash lookup rows ascending after sort"
m_hash_none: .asciz "hash lookup of a missing key"
m_range:    .asciz "btree range [30, 60)"
m_range_eq: .asciz "btree equality 40"
m_range_open: .asciz "btree range > 10 (NULLs excluded)"
    .p2align 3
s_a:        .quad 1
            .asciz "a"
            .p2align 3
s_zz:       .quad 2
            .asciz "zz"
            .p2align 3
s_h:        .quad 1
            .asciz "h"
            .p2align 3
s_b:        .quad 1
            .asciz "b"

    .bss
    .p2align 3
g_checks:   .skip 4
g_fails:    .skip 4
g_mode:     .skip 4

    .text

// check(w0 condition, x1 message)
LFUNC check
    ENTER 0
    ADR_L x9, g_checks
    ldr  w10, [x9]
    add  w10, w10, #1
    str  w10, [x9]
    cbnz w0, 1f
    ADR_L x9, g_fails
    ldr  w10, [x9]
    add  w10, w10, #1
    str  w10, [x9]
    mov  x2, x1
    ADR_L x9, g_mode
    ldr  w1, [x9]
    ADR_L x0, fmt_fail
    bl   printf
1:  LEAVE 0
ENDF check

// lookup_count(x0 Index*, x1 key, w2 key type) -> x0 number of rows
LFUNC lookup_count
    ENTER 0
    sub  sp, sp, #32
    stp  xzr, xzr, [sp]
    str  xzr, [sp, #16]
    mov  x3, sp
    bl   index_lookup_eq
    mov  x0, sp
    bl   rowvec_sort_unique
    ldr  x0, [sp]
    add  sp, sp, #32
    LEAVE 0
ENDF lookup_count

// range_count(x0 Index*, x1 lo, x2 lo kind, x3 hi, x4 hi kind) -> x0 rows
LFUNC range_count
    ENTER 0
    sub  sp, sp, #80
    stp  x1, x2, [sp, #32]
    stp  x3, x4, [sp, #48]
    mov  w9, #T_INT
    str  w9, [sp, #64]
    str  w9, [sp, #68]
    stp  xzr, xzr, [sp]
    str  xzr, [sp, #16]
    add  x1, sp, #32
    mov  x2, sp
    bl   index_lookup_range
    ldr  x0, [sp]
    add  sp, sp, #80
    LEAVE 0
ENDF range_count

// =============================================================================
// run_mode(w0 mode): 0 column/auto, 1 column/forced dictionary, 2 row
//   x19 table, w20 mode, x21 scratch, x22 hash index, x23 btree index,
//   x24 stats; [sp] RowVec
// =============================================================================
LFUNC run_mode
    ENTER 5
    sub  sp, sp, #32
    mov  w20, w0
    ADR_L x9, g_mode
    str  w20, [x9]
    mov  x0, #1
    mov  x1, #TBL_SIZE
    bl   calloc
    mov  x19, x0
    ADR_L x1, csv
    ADR_L x2, csv_end
    sub  x2, x2, x1
    mov  w3, #FMT_CSV
    mov  x4, #0
    mov  w5, #1
    mov  w6, #','
    bl   ingest
    mov  x0, x19                        // finalize
    mov  w1, #-1
    mov  w2, #0
    cmp  w20, #1
    cset w2, eq
    cmp  w20, #2
    b.ne 1f
    mov  w1, #LAYOUT_ROW
1:  bl   table_finalize
    // representation
    cmp  w20, #2
    b.ne 2f
    ldr  w0, [x19, #TBL_LAYOUT]
    cmp  w0, #LAYOUT_ROW
    cset w0, eq
    b    3f
2:  ldr  x9, [x19, #TBL_COLS]           // column s dictionary-encoded
    ldr  w0, [x9, #(COL_SIZE + COL_ENC)]
    cmp  w0, #CENC_DICT
    cset w0, eq
    ADR_L x1, m_enc
    bl   check
    ldr  x9, [x19, #TBL_COLS]
    ldr  x9, [x9, #COL_NULLS]
    cmp  x9, #0
    cset w0, eq
    ADR_L x1, m_nobitmap
    b    31f
3:  ADR_L x1, m_enc
31: bl   check
    // values
    mov  x0, x19
    mov  x1, #1
    mov  x2, #2
    bl   tbl_get
    ldr  x9, [x0, #STR_LEN]
    ldrb w10, [x0, #STR_DATA]
    sub  w10, w10, #'a'
    cmp  x9, #1
    ccmp w10, #0, #0, eq
    cset w0, eq
    ADR_L x1, m_get_s
    bl   check
    mov  x0, x19
    mov  x1, #2
    mov  x2, #4
    bl   tbl_get
    mov  w0, w1
    ADR_L x1, m_get_null
    bl   check
    mov  x0, x19
    mov  x1, #2
    mov  x2, #5
    bl   tbl_get
    cmp  x0, #60
    ccmp x1, #0, #0, eq
    cset w0, eq
    ADR_L x1, m_get_v
    bl   check
    // statistics
    mov  x0, x19
    bl   table_stats
    mov  x24, x0
    ldr  x9, [x24, #(2*CST_SIZE + CST_NULLS)]
    cmp  x9, #2
    cset w0, eq
    ADR_L x1, m_st_null
    bl   check
    ldr  x9, [x24, #(2*CST_SIZE + CST_DISTINCT)]
    cmp  x9, #4
    cset w0, eq
    ADR_L x1, m_st_dist
    bl   check
    ldr  x9, [x24, #(2*CST_SIZE + CST_MIN)]
    cmp  x9, #10
    cset w0, eq
    ADR_L x1, m_st_min
    bl   check
    ldr  x9, [x24, #(2*CST_SIZE + CST_MAX)]
    cmp  x9, #60
    cset w0, eq
    ADR_L x1, m_st_max
    bl   check
    ldr  x9, [x24, #(CST_SIZE + CST_DISTINCT)]
    cmp  x9, #3
    cset w0, eq
    ADR_L x1, m_st_sdist
    bl   check
    // indexes
    mov  x0, x19
    ADR_L x1, s_h
    mov  x2, #1
    mov  w3, #IXK_HASH
    bl   index_create
    mov  x22, x0
    mov  x0, x19
    ADR_L x1, s_b
    mov  x2, #2
    mov  w3, #IXK_BTREE
    bl   index_create
    mov  x23, x0
    stp  xzr, xzr, [sp]                 // hash lookup of 'a': rows 0, 2, 4
    str  xzr, [sp, #16]
    mov  x0, x22
    ADR_L x1, s_a
    mov  w2, #T_STR
    mov  x3, sp
    bl   index_lookup_eq
    mov  x0, sp
    bl   rowvec_sort_unique
    ldr  x9, [sp]
    cmp  x9, #3
    cset w0, eq
    ADR_L x1, m_hash
    bl   check
    ldr  x9, [sp, #16]
    ldr  w10, [x9]
    ldr  w11, [x9, #4]
    ldr  w12, [x9, #8]
    cmp  w10, #0
    ccmp w11, #2, #0, eq
    ccmp w12, #4, #0, eq
    cset w0, eq
    ADR_L x1, m_hash_rows
    bl   check
    mov  x0, x22
    ADR_L x1, s_zz
    mov  w2, #T_STR
    bl   lookup_count
    cmp  x0, #0
    cset w0, eq
    ADR_L x1, m_hash_none
    bl   check
    mov  x0, x23                        // [30, 60): rows 2, 3
    mov  x1, #30
    mov  x2, #1
    mov  x3, #60
    mov  x4, #2
    bl   range_count
    cmp  x0, #2
    cset w0, eq
    ADR_L x1, m_range
    bl   check
    mov  x0, x23
    mov  x1, #40
    mov  w2, #T_INT
    bl   lookup_count
    cmp  x0, #1
    cset w0, eq
    ADR_L x1, m_range_eq
    bl   check
    mov  x0, x23                        // > 10: 30, 40, 60
    mov  x1, #10
    mov  x2, #2
    mov  x3, #0
    mov  x4, #0
    bl   range_count
    cmp  x0, #3
    cset w0, eq
    ADR_L x1, m_range_open
    bl   check
    mov  x0, x19
    bl   index_drop_table
    mov  x0, x19
    bl   table_free
    ADR_L x0, g_arena
    bl   arena_free
    add  sp, sp, #32
    LEAVE 5
ENDF run_mode

FUNC main
    ENTER 0
    mov  w0, #0
    bl   run_mode
    mov  w0, #1
    bl   run_mode
    mov  w0, #2
    bl   run_mode
    ADR_L x0, fmt_sum
    ADR_L x9, g_checks
    ldr  w1, [x9]
    ADR_L x9, g_fails
    ldr  w2, [x9]
    bl   printf
    mov  x0, #0
    bl   fflush
    ADR_L x9, g_fails
    ldr  w0, [x9]
    cmp  w0, #0
    cset w0, ne
    LEAVE 0
ENDF main

    NOTE_GNU_STACK
