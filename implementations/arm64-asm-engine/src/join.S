// =============================================================================
// join.S — join operators of the executor (exec.S calls them through
// ex_tuples). All of them combine tuple sets (one u32 row id per range
// variable, pq.inc TS_*), handle LEFT JOIN padding and enforce
// --max-join-rows; NULL keys never match.
//
//   ex_hashjoin    build a chained hash table on the right input's key
//                  cells, probe with every left tuple
//   ex_mergejoin   sort both inputs' key records, merge runs of equal keys
//   ex_nljoin      every pair; equi keys (forced join: "nested_loop") are
//                  compared from precomputed key cells before the residual
// For a given pair of tuples all three evaluate the same expressions (all
// keys of both inputs, the residual only on key-equal pairs), so results and
// errors do not depend on the algorithm.
// =============================================================================
#include "pq.inc"
#include "frame.inc"

#define DEADLINE_MASK 4095

    .text

// =============================================================================
// combine(x0 dest tuple, x1 left tuple, x2 right tuple or 0, x3 width,
//         w4 right lo, w5 right hi)
// dest = left; dest[lo..hi) = right[lo..hi) (or ROW_NULL if right is 0). (leaf)
// =============================================================================
FUNC combine
    mov  x9, #0
1:  cmp  x9, x3
    b.hs 2f
    ldr  w10, [x1, x9, lsl #2]
    str  w10, [x0, x9, lsl #2]
    add  x9, x9, #1
    b    1b
2:  mov  w9, w4
    mov  w11, #ROW_NULL
3:  cmp  w9, w5
    b.hs 5f
    mov  w10, w11
    cbz  x2, 4f
    ldr  w10, [x2, x9, lsl #2]
4:  str  w10, [x0, x9, lsl #2]
    add  w9, w9, #1
    b    3b
5:  ret
ENDF combine

// join_emit(x0 TupleSet*, x1 tuple) — append with the --max-join-rows check
FUNC join_emit
    ENTER 0
    ldr  x9, [x0, #TS_N]
    LDR_G x10, g_max_join_rows
    cmp  x9, x10
    b.hs 1f
    bl   ts_push
    LEAVE 0
1:  RAISE ERR_RESOURCE_LIMIT, "join result exceeds --max-join-rows"
ENDF join_emit

// =============================================================================
// key_records(x0 TupleSet*, x1 Node** keys, x2 nkeys, x3 ctx)
//   -> x0 records, x1 u8* NULL-key flags
// One record per tuple: [u64 tuple index][nkeys key cells], in tuple order.
//   x19 ts, x20 keys, x21 nkeys, x22 ctx, x23 records, x24 flags, x25 index,
//   x26 record size
// =============================================================================
FUNC key_records
    ENTER 5
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x22, x3
    lsl  x26, x21, #4
    add  x26, x26, #8
    ldr  x9, [x19, #TS_N]
    mul  x0, x9, x26
    add  x0, x0, #16
    bl   arena_alloc
    mov  x23, x0
    ldr  x0, [x19, #TS_N]
    add  x0, x0, #16
    bl   arena_alloc
    mov  x24, x0
    mov  x25, #0
1:  ldr  x9, [x19, #TS_N]
    cmp  x25, x9
    b.hs 3f
    tst  x25, #DEADLINE_MASK
    b.ne 2f
    bl   check_deadline
2:  mov  x0, x19
    mov  x1, x25
    bl   ts_tuple
    str  x0, [x22, #EC_TUPLE]
    madd x3, x25, x26, x23
    str  x25, [x3], #8
    mov  x0, x20
    mov  x1, x21
    mov  x2, x22
    bl   eval_keys
    strb w1, [x24, x25]
    add  x25, x25, #1
    b    1b
3:  mov  x0, x23
    mov  x1, x24
    LEAVE 5
ENDF key_records

// =============================================================================
// ex_nljoin(x0 PlanNode*, x1 ctx) -> x0 TupleSet*   nested loop join
// Every (left, right) pair is combined and tested: first the equi keys (if
// the planner kept any: forced "nested_loop"), then the condition PN_EXPR.
//   x19 node, x20 ctx, x21 left ts, x22 right ts, x23 out, x24 li,
//   x25 ri, x26 matched, x27 combined tuple, x28 iteration counter
// Stack: [sp] right key records, [sp+8] right NULL flags, [sp+16] left key
//        cells, [sp+24] left key NULL, [sp+32] record size
// =============================================================================
FUNC ex_nljoin
    ENTER 5
    sub  sp, sp, #48
    mov  x19, x0
    mov  x20, x1
    ldr  x0, [x19, #PN_LEFT]
    bl   ex_tuples
    mov  x21, x0
    ldr  x0, [x19, #PN_RIGHT]
    mov  x1, x20
    bl   ex_tuples
    mov  x22, x0
    ldr  x9, [x19, #PN_NKEYS]
    lsl  x10, x9, #4
    add  x10, x10, #8
    str  x10, [sp, #32]
    cbz  x9, 1f
    mov  x0, x22                        // keys of every right tuple
    ldr  x1, [x19, #PN_RKEYS]
    ldr  x2, [x19, #PN_NKEYS]
    mov  x3, x20
    bl   key_records
    stp  x0, x1, [sp]
    ldr  x0, [sp, #32]
    bl   arena_alloc
    str  x0, [sp, #16]
1:  ldr  x0, [x21, #TS_W]
    ldr  x1, [x21, #TS_N]
    bl   ts_new
    mov  x23, x0
    ldr  x9, [x21, #TS_W]
    lsl  x0, x9, #2
    add  x0, x0, #16
    bl   arena_alloc
    mov  x27, x0
    mov  x28, #0
    mov  x24, #0
.Lnl_left:
    ldr  x9, [x21, #TS_N]
    cmp  x24, x9
    b.hs .Lnl_end
    mov  x26, #0
    mov  x25, #0
    ldr  x9, [x19, #PN_NKEYS]
    cbz  x9, .Lnl_right
    mov  x0, x21                        // this left tuple's keys
    mov  x1, x24
    bl   ts_tuple
    str  x0, [x20, #EC_TUPLE]
    ldr  x0, [x19, #PN_LKEYS]
    ldr  x1, [x19, #PN_NKEYS]
    mov  x2, x20
    ldr  x3, [sp, #16]
    bl   eval_keys
    cbnz x1, .Lnl_pad                   // NULL key: no partner
.Lnl_right:
    ldr  x9, [x22, #TS_N]
    cmp  x25, x9
    b.hs .Lnl_pad
    add  x28, x28, #1
    tst  x28, #DEADLINE_MASK
    b.ne 1f
    bl   check_deadline
1:  ldr  x9, [x19, #PN_NKEYS]
    cbz  x9, 11f
    ldr  x10, [sp, #8]
    ldrb w10, [x10, x25]
    cbnz w10, 3f                        // right key NULL
    ldp  x10, x11, [sp]
    ldr  x12, [sp, #32]
    madd x1, x25, x12, x10
    add  x1, x1, #8
    ldr  x0, [sp, #16]
    ldr  x2, [x19, #PN_LKEYS]
    mov  x3, x9
    bl   keys_equal
    cbz  w0, 3f
11: mov  x0, x22
    mov  x1, x25
    bl   ts_tuple
    mov  x2, x0
    mov  x0, x21
    mov  x1, x24
    str  x2, [sp, #-16]!
    bl   ts_tuple
    mov  x1, x0
    ldr  x2, [sp], #16
    mov  x0, x27
    ldr  x3, [x21, #TS_W]
    ldr  x9, [x19, #PN_RIGHT]
    ldr  w4, [x9, #PN_LO]
    ldr  w5, [x9, #PN_HI]
    bl   combine
    ldr  x0, [x19, #PN_EXPR]
    cbz  x0, 2f
    str  x27, [x20, #EC_TUPLE]
    mov  x1, x20
    bl   eval_true
    cbz  w0, 3f
2:  mov  x0, x23
    mov  x1, x27
    bl   join_emit
    mov  x26, #1
3:  add  x25, x25, #1
    b    .Lnl_right
.Lnl_pad:
    cbnz x26, 4f
    ldr  w9, [x19, #PN_JT]
    cmp  w9, #JT_LEFT
    b.ne 4f
    mov  x0, x21
    mov  x1, x24
    bl   ts_tuple
    mov  x1, x0
    mov  x0, x27
    mov  x2, #0
    ldr  x3, [x21, #TS_W]
    ldr  x9, [x19, #PN_RIGHT]
    ldr  w4, [x9, #PN_LO]
    ldr  w5, [x9, #PN_HI]
    bl   combine
    mov  x0, x23
    mov  x1, x27
    bl   join_emit
4:  add  x24, x24, #1
    b    .Lnl_left
.Lnl_end:
    mov  x0, x23
    add  sp, sp, #48
    LEAVE 5
ENDF ex_nljoin

// =============================================================================
// ex_mergejoin(x0 PlanNode*, x1 ctx) -> x0 TupleSet*   sort-merge join
// Key records of both inputs (key_records) without NULL keys are sorted by
// key (ties by tuple index, cmp_key_rec), then merged: for every run of
// equal keys each left tuple of the run is paired with each right tuple of
// the run and the residual PN_EXPR is checked. LEFT JOIN pads left tuples
// without a partner (including those with a NULL key).
//   x19 node, x20 ctx, x21 left ts, x22 right ts, x23 out, x24 i (left),
//   x25 j (right), x26 matched, x27 combined tuple, x28 key info
// Stack: [sp] left records, [sp+8] n left, [sp+16] right records,
//        [sp+24] n right, [sp+32] record size, [sp+40] right run end,
//        [sp+48] k (right cursor), [sp+56] left NULL flags,
//        [sp+64] iteration counter
// =============================================================================
FUNC ex_mergejoin
    ENTER 5
    sub  sp, sp, #80
    mov  x19, x0
    mov  x20, x1
    ldr  x0, [x19, #PN_LEFT]
    bl   ex_tuples
    mov  x21, x0
    ldr  x0, [x19, #PN_RIGHT]
    mov  x1, x20
    bl   ex_tuples
    mov  x22, x0
    str  xzr, [sp, #64]
    // key info for the comparators: [0] nkeys, [8..] u32 types
    ldr  x9, [x19, #PN_NKEYS]
    lsl  x10, x9, #4
    add  x10, x10, #8
    str  x10, [sp, #32]
    lsl  x0, x9, #2
    add  x0, x0, #16
    bl   arena_alloc
    mov  x28, x0
    ldr  x9, [x19, #PN_NKEYS]
    str  x9, [x28]
    mov  x10, #0
1:  cmp  x10, x9
    b.hs 2f
    ldr  x11, [x19, #PN_LKEYS]
    ldr  x11, [x11, x10, lsl #3]
    ldr  w11, [x11, #N_TYPE]
    add  x12, x28, #8
    str  w11, [x12, x10, lsl #2]
    add  x10, x10, #1
    b    1b
2:  mov  x0, x21                        // left records
    ldr  x1, [x19, #PN_LKEYS]
    ldr  x2, [x19, #PN_NKEYS]
    mov  x3, x20
    bl   key_records
    str  x1, [sp, #56]
    ldr  x2, [x21, #TS_N]
    ldr  x3, [sp, #32]
    bl   drop_null_keys
    stp  x0, x1, [sp]
    mov  x0, x22                        // right records
    ldr  x1, [x19, #PN_RKEYS]
    ldr  x2, [x19, #PN_NKEYS]
    mov  x3, x20
    bl   key_records
    ldr  x2, [x22, #TS_N]
    ldr  x3, [sp, #32]
    bl   drop_null_keys
    stp  x0, x1, [sp, #16]
    ldp  x0, x1, [sp]                   // sort both
    ldr  x2, [sp, #32]
    ADR_L x3, cmp_key_rec
    mov  x4, x28
    bl   qsort_r
    ldp  x0, x1, [sp, #16]
    ldr  x2, [sp, #32]
    ADR_L x3, cmp_key_rec
    mov  x4, x28
    bl   qsort_r
    ldr  x0, [x21, #TS_W]
    ldr  x1, [x21, #TS_N]
    bl   ts_new
    mov  x23, x0
    ldr  x9, [x21, #TS_W]
    lsl  x0, x9, #2
    add  x0, x0, #16
    bl   arena_alloc
    mov  x27, x0
    mov  x24, #0
    mov  x25, #0
.Lmj_loop:
    ldr  x9, [sp, #8]
    cmp  x24, x9
    b.hs .Lmj_nullkeys
    ldr  x9, [sp, #24]
    cmp  x25, x9
    b.hs .Lmj_unmatched                 // right exhausted
    ldp  x9, x10, [sp, #24]             // n right, record size
    ldr  x11, [sp]
    madd x0, x24, x10, x11
    ldr  x11, [sp, #16]
    madd x1, x25, x10, x11
    mov  x2, x28
    bl   cmp_group_rec
    cmp  w0, #0
    b.lt .Lmj_unmatched
    b.eq .Lmj_run
    add  x25, x25, #1                   // right key smaller: skip it
    b    .Lmj_loop
.Lmj_unmatched:                         // left tuple without partner
    bl   .Lmj_pad
    add  x24, x24, #1
    b    .Lmj_loop
.Lmj_run:
    // right run [j, end) of keys equal to right[j]
    add  x9, x25, #1
    str  x9, [sp, #40]
3:  ldr  x9, [sp, #40]
    ldr  x10, [sp, #24]
    cmp  x9, x10
    b.hs 4f
    ldr  x10, [sp, #32]
    ldr  x11, [sp, #16]
    madd x0, x25, x10, x11
    madd x1, x9, x10, x11
    mov  x2, x28
    bl   cmp_group_rec
    cbnz w0, 4f
    ldr  x9, [sp, #40]
    add  x9, x9, #1
    str  x9, [sp, #40]
    b    3b
4:  // every left tuple with this key against the run
    mov  x26, #0
    str  x25, [sp, #48]
5:  ldr  x9, [sp, #48]
    ldr  x10, [sp, #40]
    cmp  x9, x10
    b.hs 7f
    ldr  x10, [sp, #64]
    add  x10, x10, #1
    str  x10, [sp, #64]
    tst  x10, #DEADLINE_MASK
    b.ne 51f
    bl   check_deadline
51: ldr  x9, [sp, #48]                  // right tuple
    ldp  x10, x11, [sp, #16]
    ldr  x11, [sp, #32]
    madd x10, x9, x11, x10
    ldr  x1, [x10]
    mov  x0, x22
    bl   ts_tuple
    str  x0, [sp, #-16]!
    ldr  x10, [sp, #16]                 // left tuple
    ldr  x11, [sp, #48]
    madd x10, x24, x11, x10
    ldr  x1, [x10]
    mov  x0, x21
    bl   ts_tuple
    mov  x1, x0
    ldr  x2, [sp], #16
    mov  x0, x27
    ldr  x3, [x21, #TS_W]
    ldr  x9, [x19, #PN_RIGHT]
    ldr  w4, [x9, #PN_LO]
    ldr  w5, [x9, #PN_HI]
    bl   combine
    ldr  x0, [x19, #PN_EXPR]
    cbz  x0, 6f
    str  x27, [x20, #EC_TUPLE]
    mov  x1, x20
    bl   eval_true
    cbz  w0, 61f
6:  mov  x0, x23
    mov  x1, x27
    bl   join_emit
    mov  x26, #1
61: ldr  x9, [sp, #48]
    add  x9, x9, #1
    str  x9, [sp, #48]
    b    5b
7:  cbnz x26, 8f
    bl   .Lmj_pad
8:  add  x24, x24, #1               // next left tuple: same key => same run
    ldr  x9, [sp, #8]
    cmp  x24, x9
    b.hs .Lmj_nullkeys
    ldr  x10, [sp, #32]
    ldr  x11, [sp]
    sub  x9, x24, #1
    madd x0, x9, x10, x11
    madd x1, x24, x10, x11
    mov  x2, x28
    bl   cmp_group_rec
    cbz  w0, 4b
    ldr  x25, [sp, #40]                 // continue after the run
    b    .Lmj_loop
.Lmj_nullkeys:                          // LEFT: tuples with a NULL key
    ldr  w9, [x19, #PN_JT]
    cmp  w9, #JT_LEFT
    b.ne .Lmj_end
    mov  x24, #0
9:  ldr  x9, [x21, #TS_N]
    cmp  x24, x9
    b.hs .Lmj_end
    ldr  x10, [sp, #56]
    ldrb w10, [x10, x24]
    cbz  w10, 10f
    mov  x0, x21
    mov  x1, x24
    bl   ts_tuple
    bl   .Lmj_pad_tuple
10: add  x24, x24, #1
    b    9b
.Lmj_end:
    mov  x0, x23
    add  sp, sp, #80
    LEAVE 5

// local helpers sharing the frame: pad left record x24 / tuple x0 (LEFT JOIN)
.Lmj_pad:
    ldr  w9, [x19, #PN_JT]
    cmp  w9, #JT_LEFT
    b.ne 99f
    ldr  x10, [sp]
    ldr  x11, [sp, #32]
    madd x10, x24, x11, x10
    ldr  x1, [x10]
    mov  x0, x21
    stp  x29, x30, [sp, #-16]!
    bl   ts_tuple
    ldp  x29, x30, [sp], #16
.Lmj_pad_tuple:
    stp  x29, x30, [sp, #-16]!
    mov  x1, x0
    mov  x0, x27
    mov  x2, #0
    ldr  x3, [x21, #TS_W]
    ldr  x9, [x19, #PN_RIGHT]
    ldr  w4, [x9, #PN_LO]
    ldr  w5, [x9, #PN_HI]
    bl   combine
    mov  x0, x23
    mov  x1, x27
    bl   join_emit
    ldp  x29, x30, [sp], #16
99: ret
ENDF ex_mergejoin

// drop_null_keys(x0 records, x1 u8* NULL flags, x2 n, x3 record size)
//   -> x0 records, x1 count
// Compacts (in place, order kept) the records whose keys are all non-NULL.
// (leaf)
FUNC drop_null_keys
    mov  x9, #0                         // records read
    mov  x10, #0                        // records kept
    mov  x11, x0                        // write cursor
    mov  x12, x0                        // read cursor
1:  cmp  x9, x2
    b.hs 4f
    ldrb w13, [x1, x9]
    cbnz w13, 3f
    cmp  x11, x12
    b.eq 21f
    mov  x14, #0
2:  cmp  x14, x3
    b.hs 21f
    ldr  x15, [x12, x14]
    str  x15, [x11, x14]
    add  x14, x14, #8
    b    2b
21: add  x11, x11, x3
    add  x10, x10, #1
3:  add  x12, x12, x3
    add  x9, x9, #1
    b    1b
4:  mov  x1, x10
    ret
ENDF drop_null_keys

// cmp_key_rec(x0 rec a, x1 rec b, x2 key info) -> w0: key order, then tuple
// index (deterministic order for qsort_r)
FUNC cmp_key_rec
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    bl   cmp_group_rec
    cbnz w0, 1f
    ldr  x9, [x19]
    ldr  x10, [x20]
    cmp  x9, x10
    cset w0, hi
    csinv w0, w0, wzr, hs
1:  LEAVE 2
ENDF cmp_key_rec

// =============================================================================
// Hashing of key cells
// hash_cell(x0 payload, w1 type) -> x0 64-bit hash (non-NULL value)
//   x19 payload
// =============================================================================
FUNC hash_cell
    and  w9, w1, #T_KIND_MASK
    cmp  w9, #T_STR
    b.eq 2f
    cmp  w9, #T_FLOAT
    b.ne 1f
    mov  x10, #0x8000000000000000       // -0.0 hashes like 0.0
    cmp  x0, x10
    csel x0, xzr, x0, eq
1:  b    mix64
2:  ldr  x10, [x0, #STR_LEN]            // FNV-1a over the bytes
    add  x11, x0, #STR_DATA
    ldr  x0, =0xcbf29ce484222325
    ldr  x12, =0x100000001b3
3:  cbz  x10, 1b
    ldrb w13, [x11], #1
    eor  x0, x0, x13
    mul  x0, x0, x12
    sub  x10, x10, #1
    b    3b
ENDF hash_cell

// mix64(x0) -> x0 (finaliser of MurmurHash3)   (leaf)
FUNC mix64
    eor  x0, x0, x0, lsr #33
    ldr  x9, =0xff51afd7ed558ccd
    mul  x0, x0, x9
    eor  x0, x0, x0, lsr #33
    ldr  x9, =0xc4ceb9fe1a85ec53
    mul  x0, x0, x9
    eor  x0, x0, x0, lsr #33
    ret
ENDF mix64

// eval_keys(x0 Node** keys, x1 count, x2 ctx, x3 dest cells)
//   -> x0 hash of the cells, x1 1 if any key is NULL
//   x19 keys, x20 count, x21 ctx, x22 dest, x23 hash, x24 anynull, x25 key
FUNC eval_keys
    ENTER 4
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x22, x3
    mov  x23, #0
    mov  x24, #0
1:  cbz  x20, 3f
    ldr  x25, [x19], #8
    mov  x0, x25
    mov  x1, x21
    bl   eval
    stp  x0, x1, [x22], #16
    cbz  x1, 2f
    mov  x24, #1
    b    21f
2:  ldr  w1, [x25, #N_TYPE]
    bl   hash_cell
    eor  x23, x23, x0
    ldr  x9, =0x9e3779b97f4a7c15
    mul  x23, x23, x9
    add  x23, x23, #1
21: sub  x20, x20, #1
    b    1b
3:  mov  x0, x23
    mov  x1, x24
    LEAVE 4
ENDF eval_keys

// keys_equal(x0 cells a, x1 cells b, x2 Node** keys (types), x3 count)
//   -> w0 1 if all key values are equal (both non-NULL)
//   x19 a, x20 b, x21 keys, x22 count
FUNC keys_equal
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x22, x3
1:  cbz  x22, 3f
    ldr  x0, [x19], #16
    ldr  x1, [x20], #16
    ldr  x9, [x21], #8
    ldr  w2, [x9, #N_TYPE]
    and  w10, w2, #T_KIND_MASK
    cmp  w10, #T_STR
    b.eq 2f
    cmp  w10, #T_FLOAT
    b.eq 2f
    cmp  x0, x1                         // same encoding: payload equality
    b.ne 4f
    sub  x22, x22, #1
    b    1b
2:  mov  w3, w2
    bl   cmp_typed
    cbnz w0, 4f
    sub  x22, x22, #1
    b    1b
3:  mov  w0, #1
    LEAVE 3
4:  mov  w0, #0
    LEAVE 3
ENDF keys_equal

// =============================================================================
// ex_hashjoin(x0 PlanNode*, x1 ctx) -> x0 TupleSet*
// Build: hash the right input's key cells into a chained table (NULL keys are
// skipped). Probe: for each left tuple walk the chain, compare keys, check
// the residual condition; LEFT JOIN pads unmatched left tuples.
//   x19 node, x20 ctx, x21 left ts, x22 right ts, x23 out, x24 index,
//   x25 key cells of the right input, x26 heads, x27 next, x28 mask
// Stack: [sp] combined tuple, [sp+8] left key cells, [sp+16] chain cursor,
//        [sp+24] matched, [sp+32] probe counter, [sp+40] nkeys*16
// =============================================================================
FUNC ex_hashjoin
    ENTER 5
    sub  sp, sp, #48
    mov  x19, x0
    mov  x20, x1
    ldr  x0, [x19, #PN_LEFT]
    bl   ex_tuples
    mov  x21, x0
    ldr  x0, [x19, #PN_RIGHT]
    mov  x1, x20
    bl   ex_tuples
    mov  x22, x0
    ldr  x9, [x19, #PN_NKEYS]
    lsl  x9, x9, #4
    str  x9, [sp, #40]
    // ---- build -------------------------------------------------------------
    ldr  x9, [x22, #TS_N]
    ldr  x10, [sp, #40]
    mul  x0, x9, x10
    add  x0, x0, #16
    bl   arena_alloc
    mov  x25, x0
    ldr  x9, [x22, #TS_N]               // table size: power of two >= 2n
    lsl  x9, x9, #1
    mov  x28, #16
1:  cmp  x28, x9
    b.hs 2f
    lsl  x28, x28, #1
    b    1b
2:  lsl  x0, x28, #2
    bl   arena_alloc
    mov  x26, x0
    mov  w1, #0xff
    lsl  x2, x28, #2
    bl   memset
    sub  x28, x28, #1                   // mask
    ldr  x9, [x22, #TS_N]
    lsl  x0, x9, #2
    add  x0, x0, #16
    bl   arena_alloc
    mov  x27, x0
    mov  x24, #0
3:  ldr  x9, [x22, #TS_N]
    cmp  x24, x9
    b.hs .Lhj_probe
    tst  x24, #DEADLINE_MASK
    b.ne 31f
    bl   check_deadline
31: mov  x0, x22
    mov  x1, x24
    bl   ts_tuple
    str  x0, [x20, #EC_TUPLE]
    ldr  x0, [x19, #PN_RKEYS]
    ldr  x1, [x19, #PN_NKEYS]
    mov  x2, x20
    ldr  x9, [sp, #40]
    madd x3, x24, x9, x25
    bl   eval_keys
    cbnz x1, 4f                         // NULL key: never matches
    and  x0, x0, x28
    ldr  w9, [x26, x0, lsl #2]
    str  w9, [x27, x24, lsl #2]
    str  w24, [x26, x0, lsl #2]
4:  add  x24, x24, #1
    b    3b
    // ---- probe -------------------------------------------------------------
.Lhj_probe:
    ldr  x0, [x21, #TS_W]
    ldr  x1, [x21, #TS_N]
    bl   ts_new
    mov  x23, x0
    ldr  x9, [x21, #TS_W]
    lsl  x0, x9, #2
    add  x0, x0, #16
    bl   arena_alloc
    str  x0, [sp]
    ldr  x0, [sp, #40]
    add  x0, x0, #16
    bl   arena_alloc
    str  x0, [sp, #8]
    str  xzr, [sp, #32]
    mov  x24, #0
.Lhj_left:
    ldr  x9, [x21, #TS_N]
    cmp  x24, x9
    b.hs .Lhj_end
    str  xzr, [sp, #24]                 // matched = 0
    mov  x0, x21
    mov  x1, x24
    bl   ts_tuple
    str  x0, [x20, #EC_TUPLE]
    ldr  x0, [x19, #PN_LKEYS]
    ldr  x1, [x19, #PN_NKEYS]
    mov  x2, x20
    ldr  x3, [sp, #8]
    bl   eval_keys
    cbnz x1, .Lhj_pad
    and  x0, x0, x28
    ldr  w9, [x26, x0, lsl #2]
.Lhj_chain:
    cmn  w9, #1
    b.eq .Lhj_pad
    str  x9, [sp, #16]
    ldr  x10, [sp, #32]
    add  x10, x10, #1
    str  x10, [sp, #32]
    tst  x10, #DEADLINE_MASK
    b.ne 5f
    bl   check_deadline
5:  ldr  x9, [sp, #16]
    ldr  x0, [sp, #8]
    ldr  x10, [sp, #40]
    madd x1, x9, x10, x25
    ldr  x2, [x19, #PN_LKEYS]
    ldr  x3, [x19, #PN_NKEYS]
    bl   keys_equal
    cbz  w0, .Lhj_next
    ldr  x1, [sp, #16]                  // combine left + right tuple
    mov  x0, x22
    bl   ts_tuple
    mov  x2, x0
    mov  x0, x21
    mov  x1, x24
    str  x2, [sp, #-16]!
    bl   ts_tuple
    mov  x1, x0
    ldr  x2, [sp], #16
    ldr  x0, [sp]
    ldr  x3, [x21, #TS_W]
    ldr  x9, [x19, #PN_RIGHT]
    ldr  w4, [x9, #PN_LO]
    ldr  w5, [x9, #PN_HI]
    bl   combine
    ldr  x0, [x19, #PN_EXPR]
    cbz  x0, 6f
    ldr  x9, [sp]
    str  x9, [x20, #EC_TUPLE]
    mov  x1, x20
    bl   eval_true
    cbz  w0, .Lhj_next
6:  mov  x0, x23
    ldr  x1, [sp]
    bl   join_emit
    mov  x9, #1
    str  x9, [sp, #24]
.Lhj_next:
    ldr  x9, [sp, #16]
    ldr  w9, [x27, x9, lsl #2]
    b    .Lhj_chain
.Lhj_pad:
    ldr  x9, [sp, #24]
    cbnz x9, 7f
    ldr  w9, [x19, #PN_JT]
    cmp  w9, #JT_LEFT
    b.ne 7f
    mov  x0, x21
    mov  x1, x24
    bl   ts_tuple
    mov  x1, x0
    ldr  x0, [sp]
    mov  x2, #0
    ldr  x3, [x21, #TS_W]
    ldr  x9, [x19, #PN_RIGHT]
    ldr  w4, [x9, #PN_LO]
    ldr  w5, [x9, #PN_HI]
    bl   combine
    mov  x0, x23
    ldr  x1, [sp]
    bl   join_emit
7:  add  x24, x24, #1
    b    .Lhj_left
.Lhj_end:
    mov  x0, x23
    add  sp, sp, #48
    LEAVE 5
ENDF ex_hashjoin


    .ltorg
    NOTE_GNU_STACK
