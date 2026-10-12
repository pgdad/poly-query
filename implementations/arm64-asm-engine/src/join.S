// =============================================================================
// join.S — join operators of the executor (exec.S calls them through
// ex_tuples). All of them combine tuple sets (one u32 row id per range
// variable, pq.inc TS_*), handle LEFT JOIN padding and enforce
// --max-join-rows; NULL keys never match.
//
//   ex_hashjoin    build a chained hash table on the right input's key
//                  cells, probe with every left tuple (key cells of both
//                  inputs computed up front, vectorized in mode
//                  "vectorized"; parallel probe tasks with threads > 1)
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

// Hash join state shared by the probe tasks
#define HS_L        0               // TupleSet* left (probe) input
#define HS_R        8               // TupleSet* right (build) input
#define HS_LCELLS   16              // key cells of the left tuples
#define HS_LHASH    24              // u64* their hashes
#define HS_LNULL    32              // u8* 1 = a key is NULL
#define HS_RCELLS   40              // key cells of the right tuples
#define HS_HEADS    48              // u32* bucket heads (ROW_NULL = empty)
#define HS_NEXT     56              // u32* chain links per right tuple
#define HS_MASK     64              // u64 bucket mask
#define HS_KS       72              // u64 bytes of key cells per tuple
#define HS_RHASH    80              // u64* hashes of the right tuples
#define HS_FAST     88              // u64 1: one key compared by payload
#define HS_LBUILD   96              // u64 1: LEFT join building on its left
#define HS_MATCHED  104             // u8* build tuples matched (HS_LBUILD)
#define HS_SIZE     112
// Probe task (one per thread)
#define HJ_NODE     0
#define HJ_CTX      8               // EvalCtx* (own copy for worker tasks)
#define HJ_TS       16              // TupleSet* output (ts_concat: offset 16)
#define HJ_LO       24              // left tuples [lo, hi)
#define HJ_HI       32
#define HJ_SH       40              // shared state
#define HJ_SIZE     48

    .text

// =============================================================================
// combine(x0 dest, x1 left tuple, x2 right tuple or 0, x3 width)
// dest = left joined with right. The two inputs of a join cover disjoint
// sets of range variables and hold ROW_NULL (all ones) in every other slot,
// so a slot-wise AND merges them; right = 0 pads the right side with NULLs
// (dest = left). (leaf)
// =============================================================================
FUNC combine
    mov  x9, #0
    cbz  x2, 3f
1:  cmp  x9, x3
    b.hs 2f
    ldr  w10, [x1, x9, lsl #2]
    ldr  w11, [x2, x9, lsl #2]
    and  w10, w10, w11
    str  w10, [x0, x9, lsl #2]
    add  x9, x9, #1
    b    1b
2:  ret
3:  cmp  x9, x3
    b.hs 2b
    ldr  w10, [x1, x9, lsl #2]
    str  w10, [x0, x9, lsl #2]
    add  x9, x9, #1
    b    3b
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
// Both inputs are sorted (mj_side: key cells via join_keys, an index array
// of the tuples without NULL keys sorted by key, ties by tuple index), then
// merged: for every run of equal keys each left tuple of the run is paired
// with each right tuple of the run and the residual PN_EXPR is checked.
// LEFT JOIN pads left tuples without a partner (including NULL keys).
//   x19 node, x20 ctx, x21 left ts, x22 right ts, x23 out, x24 i (left),
//   x25 j (right), x26 matched, x27 combined tuple, x28 key info
// Stack: [sp] left cells, [sp+8] left order, [sp+16] n left,
//        [sp+24] right cells, [sp+32] right order, [sp+40] n right,
//        [sp+48] key bytes, [sp+56] right run end, [sp+64] k (right
//        cursor), [sp+72] left NULL flags, [sp+80] iteration counter
// =============================================================================
FUNC ex_mergejoin
    ENTER 5
    sub  sp, sp, #96
    mov  x19, x0
    mov  x20, x1
    ldr  x0, [x19, #PN_LEFT]
    bl   ex_tuples
    mov  x21, x0
    ldr  x0, [x19, #PN_RIGHT]
    mov  x1, x20
    bl   ex_tuples
    mov  x22, x0
    str  xzr, [sp, #80]
    // key info for the comparators: [0] nkeys, [8..] u32 types
    ldr  x9, [x19, #PN_NKEYS]
    lsl  x10, x9, #4
    str  x10, [sp, #48]
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
2:  mov  x0, x21
    ldr  x1, [x19, #PN_LKEYS]
    mov  x2, x28
    mov  x3, x20
    bl   mj_side
    stp  x0, x1, [sp]
    str  x2, [sp, #16]
    str  x3, [sp, #72]
    mov  x0, x22
    ldr  x1, [x19, #PN_RKEYS]
    mov  x2, x28
    mov  x3, x20
    bl   mj_side
    stp  x0, x1, [sp, #24]
    str  x2, [sp, #40]
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
    ldr  x9, [sp, #16]
    cmp  x24, x9
    b.hs .Lmj_nullkeys
    ldr  x9, [sp, #40]
    cmp  x25, x9
    b.hs .Lmj_unmatched                 // right exhausted
    mov  x0, x24
    mov  x1, x25
    bl   .Lmj_cmp_lr
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
    str  x9, [sp, #56]
3:  ldr  x9, [sp, #56]
    ldr  x10, [sp, #40]
    cmp  x9, x10
    b.hs 4f
    mov  x0, x24
    mov  x1, x9
    bl   .Lmj_cmp_lr
    cbnz w0, 4f
    ldr  x9, [sp, #56]
    add  x9, x9, #1
    str  x9, [sp, #56]
    b    3b
4:  // the left tuple against the run
    mov  x26, #0
    str  x25, [sp, #64]
5:  ldr  x9, [sp, #64]
    ldr  x10, [sp, #56]
    cmp  x9, x10
    b.hs 7f
    ldr  x10, [sp, #80]
    add  x10, x10, #1
    str  x10, [sp, #80]
    tst  x10, #DEADLINE_MASK
    b.ne 51f
    bl   check_deadline
51: ldr  x9, [sp, #64]                  // right tuple
    ldr  x10, [sp, #32]
    ldr  x1, [x10, x9, lsl #3]
    mov  x0, x22
    bl   ts_tuple
    str  x0, [sp, #-16]!
    ldr  x10, [sp, #(16 + 8)]           // left tuple
    ldr  x1, [x10, x24, lsl #3]
    mov  x0, x21
    bl   ts_tuple
    mov  x1, x0
    ldr  x2, [sp], #16
    mov  x0, x27
    ldr  x3, [x21, #TS_W]
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
61: ldr  x9, [sp, #64]
    add  x9, x9, #1
    str  x9, [sp, #64]
    b    5b
7:  cbnz x26, 8f
    bl   .Lmj_pad
8:  add  x24, x24, #1               // next left tuple: same key => same run
    ldr  x9, [sp, #16]
    cmp  x24, x9
    b.hs .Lmj_nullkeys
    mov  x0, x24
    mov  x1, x25
    bl   .Lmj_cmp_lr
    cbz  w0, 4b
    ldr  x25, [sp, #56]                 // continue after the run
    b    .Lmj_loop
.Lmj_nullkeys:                          // LEFT: tuples with a NULL key
    ldr  w9, [x19, #PN_JT]
    cmp  w9, #JT_LEFT
    b.ne .Lmj_end
    mov  x24, #0
9:  ldr  x9, [x21, #TS_N]
    cmp  x24, x9
    b.hs .Lmj_end
    ldr  x10, [sp, #72]
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
    add  sp, sp, #96
    LEAVE 5

// local helpers sharing the frame
// .Lmj_cmp_lr: x0 left position, x1 right position -> w0 key order
.Lmj_cmp_lr:
    stp  x29, x30, [sp, #-16]!
    ldr  x9, [sp, #(16 + 48)]           // key bytes
    ldr  x10, [sp, #(16 + 8)]
    ldr  x10, [x10, x0, lsl #3]         // left tuple index
    ldr  x11, [sp, #(16 + 0)]
    madd x0, x10, x9, x11
    sub  x0, x0, #8                     // "record": cells at +8
    ldr  x10, [sp, #(16 + 32)]
    ldr  x10, [x10, x1, lsl #3]
    ldr  x11, [sp, #(16 + 24)]
    madd x1, x10, x9, x11
    sub  x1, x1, #8
    mov  x2, x28
    bl   cmp_group_rec
    ldp  x29, x30, [sp], #16
    ret
// .Lmj_pad: pad left position x24; .Lmj_pad_tuple: pad tuple x0
.Lmj_pad:
    ldr  w9, [x19, #PN_JT]
    cmp  w9, #JT_LEFT
    b.ne 99f
    ldr  x10, [sp, #8]
    ldr  x1, [x10, x24, lsl #3]
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
    bl   combine
    mov  x0, x23
    mov  x1, x27
    bl   join_emit
    ldp  x29, x30, [sp], #16
99: ret
ENDF ex_mergejoin

// =============================================================================
// mj_side(x0 TupleSet*, x1 Node** keys, x2 key info, x3 ctx)
//   -> x0 key cells, x1 u64* order, x2 count, x3 u8* NULL flags
// The tuples whose keys are all non-NULL, sorted by key (ties by tuple
// index): LSD radix sort for one integer-like key (BOOLEAN, INT64,
// DECIMAL, DATE, TIMESTAMP: stable, so ties keep the index order), qsort_r
// with cmp_key_idx otherwise.
//   x19 ts, x20 key info, x21 cells, x22 order, x23 count, x24 flags,
//   x25 key bytes
// =============================================================================
FUNC mj_side
    ENTER 5
    sub  sp, sp, #32
    mov  x19, x0
    mov  x20, x2
    mov  x2, x1                         // keys
    mov  x1, x2
    ldr  x2, [x20]
    mov  x0, x19
    bl   join_keys
    mov  x21, x0
    mov  x24, x2
    ldr  x25, [x20]
    lsl  x25, x25, #4
    ldr  x9, [x19, #TS_N]
    lsl  x0, x9, #3
    add  x0, x0, #16
    bl   arena_alloc
    mov  x22, x0
    mov  x23, #0
    mov  x9, #0
1:  ldr  x10, [x19, #TS_N]
    cmp  x9, x10
    b.hs 2f
    ldrb w11, [x24, x9]
    cbnz w11, 11f
    str  x9, [x22, x23, lsl #3]
    add  x23, x23, #1
11: add  x9, x9, #1
    b    1b
2:  cmp  x23, #2
    b.lo 9f
    ldr  x9, [x20]                      // one integer-like key: radix
    cmp  x9, #1
    b.ne 3f
    ldr  w9, [x20, #8]
    BR_WIDE w9, w10, 3f
    and  w9, w9, #T_KIND_MASK
    cmp  w9, #T_FLOAT
    b.eq 3f
    cmp  w9, #T_STR
    b.eq 3f
    mov  x0, x22
    mov  x1, x23
    mov  x2, x21
    mov  x3, x25
    bl   radix_sort_idx
    b    9f
3:  stp  x21, x25, [sp]                 // comparator argument
    str  x20, [sp, #16]
    mov  x0, x22
    mov  x1, x23
    mov  x2, #8
    ADR_L x3, cmp_key_idx
    mov  x4, sp
    bl   qsort_r
9:  mov  x0, x21
    mov  x1, x22
    mov  x2, x23
    mov  x3, x24
    add  sp, sp, #32
    LEAVE 5
ENDF mj_side

// cmp_key_idx(x0 u64* a, x1 u64* b, x2 {cells, key bytes, key info})
//   -> w0 key order of the tuples, then tuple index
//   x19 index a, x20 index b
LFUNC cmp_key_idx
    ENTER 2
    ldr  x19, [x0]
    ldr  x20, [x1]
    ldp  x9, x10, [x2]
    madd x0, x19, x10, x9
    sub  x0, x0, #8
    madd x1, x20, x10, x9
    sub  x1, x1, #8
    ldr  x2, [x2, #16]
    bl   cmp_group_rec
    cbnz w0, 1f
    cmp  x19, x20
    cset w0, hi
    csinv w0, w0, wzr, hs
1:  LEAVE 2
ENDF cmp_key_idx

// =============================================================================
// radix_sort_idx(x0 u64* order, x1 n, x2 key cells, x3 key bytes)
// Stable LSD radix sort (8 passes of 8 bits, constant bytes skipped) of the
// tuple indexes by their first key payload as a signed 64-bit integer.
//   x19 order, x20 n, x21 keys (biased), x22 tmp keys, x23 tmp order,
//   x24 shift, x25 histogram (257 u64), x26 the caller's array
// =============================================================================
FUNC radix_sort_idx
    ENTER 5
    mov  x26, x0                        // the caller's array
    mov  x19, x0
    mov  x20, x1
    stp  x2, x3, [sp, #-16]!
    lsl  x0, x20, #3
    add  x0, x0, #16
    bl   arena_alloc
    mov  x21, x0
    lsl  x0, x20, #3
    add  x0, x0, #16
    bl   arena_alloc
    mov  x22, x0
    lsl  x0, x20, #3
    add  x0, x0, #16
    bl   arena_alloc
    mov  x23, x0
    mov  x0, #(257 * 8)
    bl   arena_alloc
    mov  x25, x0
    ldp  x2, x3, [sp], #16
    mov  x9, #0                         // biased keys: signed -> unsigned
1:  cmp  x9, x20
    b.hs 2f
    ldr  x10, [x19, x9, lsl #3]
    mul  x10, x10, x3
    ldr  x10, [x2, x10]
    eor  x10, x10, #0x8000000000000000
    str  x10, [x21, x9, lsl #3]
    add  x9, x9, #1
    b    1b
2:  mov  x24, #0
.Lrs_pass:
    cmp  x24, #64
    b.hs .Lrs_end
    mov  x0, x25
    mov  w1, #0
    mov  x2, #(257 * 8)
    bl   memset
    mov  x9, #0                         // histogram of this byte
3:  cmp  x9, x20
    b.hs 4f
    ldr  x10, [x21, x9, lsl #3]
    lsr  x10, x10, x24
    and  x10, x10, #0xff
    add  x10, x10, #1
    ldr  x11, [x25, x10, lsl #3]
    add  x11, x11, #1
    str  x11, [x25, x10, lsl #3]
    add  x9, x9, #1
    b    3b
4:  mov  x9, #1                         // all keys share this byte: skip
41: cmp  x9, #256
    b.hi 42f
    ldr  x10, [x25, x9, lsl #3]
    cmp  x10, x20
    b.eq .Lrs_next
    add  x9, x9, #1
    b    41b
42: mov  x9, #1                         // prefix sums: start of each bucket
    mov  x11, #0
5:  cmp  x9, #256
    b.hi 6f
    ldr  x10, [x25, x9, lsl #3]
    str  x11, [x25, x9, lsl #3]
    add  x11, x11, x10
    add  x9, x9, #1
    b    5b
6:  mov  x9, #0                         // scatter (stable)
7:  cmp  x9, x20
    b.hs 8f
    ldr  x10, [x21, x9, lsl #3]
    lsr  x12, x10, x24
    and  x12, x12, #0xff
    add  x12, x12, #1
    ldr  x13, [x25, x12, lsl #3]
    add  x14, x13, #1
    str  x14, [x25, x12, lsl #3]
    str  x10, [x22, x13, lsl #3]
    ldr  x15, [x19, x9, lsl #3]
    str  x15, [x23, x13, lsl #3]
    add  x9, x9, #1
    b    7b
8:  mov  x9, x21                        // swap the buffers
    mov  x21, x22
    mov  x22, x9
    mov  x9, x19
    mov  x19, x23
    mov  x23, x9
.Lrs_next:
    add  x24, x24, #8
    b    .Lrs_pass
.Lrs_end:
    cmp  x19, x26                       // result in the caller's array?
    b.eq 9f
    mov  x0, x26
    mov  x1, x19
    lsl  x2, x20, #3
    bl   memcpy
9:  LEAVE 5
ENDF radix_sort_idx


// =============================================================================
// Hashing of key cells
// hash_cell(x0 payload, w1 type) -> x0 64-bit hash (non-NULL value)
//   x19 payload
// =============================================================================
FUNC hash_cell
    BR_WIDE w1, w9, dec_hash
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
    BR_WIDE w2, w10, 2f
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
// Build: the key cells and hashes of every right tuple (join_keys), a
// chained hash table over them (NULL keys are skipped). Probe: the key cells
// of every left tuple are computed up front as well; the left tuples are
// then cut into windows probed by hj_probe tasks (in parallel with option
// threads > 1 when the residual condition is safe for worker threads), whose
// outputs are concatenated in order. A LEFT join with PN_SWAP = SWAP_LBUILD
// builds on its left input instead and probes with the right one: matched
// build tuples are flagged (HS_MATCHED), and the unmatched ones are appended
// NULL-padded after the probes.
//   x19 node, x20 ctx, x21 shared state, x22 tasks, x23 task records,
//   x24 index, x25 scratch
// =============================================================================
FUNC ex_hashjoin
    ENTER 5
    sub  sp, sp, #16
    mov  x19, x0
    mov  x20, x1
    mov  x0, #HS_SIZE
    bl   arena_zalloc
    mov  x21, x0
    ldr  x0, [x19, #PN_LEFT]
    mov  x1, x20
    bl   ex_tuples
    str  x0, [x21, #HS_L]
    ldr  x0, [x19, #PN_RIGHT]
    mov  x1, x20
    bl   ex_tuples
    str  x0, [x21, #HS_R]
    ldr  x9, [x19, #PN_NKEYS]
    lsl  x9, x9, #4
    str  x9, [x21, #HS_KS]
    ldr  w9, [x19, #PN_JT]              // LEFT join building on the left:
    cmp  w9, #JT_LEFT                   // the inputs trade roles
    b.ne 1f
    ldr  w9, [x19, #PN_SWAP]
    cmp  w9, #SWAP_LBUILD
    b.ne 1f
    mov  x9, #1
    str  x9, [x21, #HS_LBUILD]
    ldp  x9, x10, [x21, #HS_L]
    stp  x10, x9, [x21, #HS_L]
    ldr  x9, [x21, #HS_R]
    ldr  x0, [x9, #TS_N]
    add  x0, x0, #16
    bl   arena_zalloc
    str  x0, [x21, #HS_MATCHED]
1:  // ---- build -------------------------------------------------------------
    ldr  x0, [x21, #HS_R]
    ldr  x1, [x19, #PN_RKEYS]
    ldr  x9, [x21, #HS_LBUILD]
    cbz  x9, 2f
    ldr  x1, [x19, #PN_LKEYS]
2:
    ldr  x2, [x19, #PN_NKEYS]
    mov  x3, x20
    bl   join_keys
    str  x0, [x21, #HS_RCELLS]
    str  x1, [x21, #HS_RHASH]
    ldr  x0, [x21, #HS_R]
    bl   hj_table
    str  x0, [x21, #HS_HEADS]
    str  x1, [x21, #HS_NEXT]
    str  x2, [x21, #HS_MASK]
    ldr  x9, [x19, #PN_NKEYS]           // one key with payload equality
    cmp  x9, #1                         // (keys_equal's rule)?
    b.ne 1f
    ldr  x9, [x19, #PN_LKEYS]
    ldr  x9, [x9]
    ldr  w9, [x9, #N_TYPE]
    BR_WIDE w9, w10, 1f
    and  w9, w9, #T_KIND_MASK
    cmp  w9, #T_STR
    b.eq 1f
    cmp  w9, #T_FLOAT
    b.eq 1f
    mov  x9, #1
    str  x9, [x21, #HS_FAST]
1:
    // ---- probe -------------------------------------------------------------
    ldr  x0, [x21, #HS_L]
    ldr  x1, [x19, #PN_LKEYS]
    ldr  x9, [x21, #HS_LBUILD]
    cbz  x9, 2f
    ldr  x1, [x19, #PN_RKEYS]
2:
    ldr  x2, [x19, #PN_NKEYS]
    mov  x3, x20
    bl   join_keys
    str  x0, [x21, #HS_LCELLS]
    str  x1, [x21, #HS_LHASH]
    str  x2, [x21, #HS_LNULL]
    mov  x22, #1                        // tasks: 4 per thread (skewed
    TLS_LDR x9, g_x_threads             // keys make windows unequal; the
    cmp  x9, #1                         // pool balances), at least
    b.ls 5f                             // g_par_min_rows / 4 tuples each
    lsl  x9, x9, #2
    LDR_G x10, g_par_min_rows
    lsr  x10, x10, #2
    cmp  x10, #1
    csinc x10, x10, xzr, hs
    ldr  x11, [x21, #HS_L]
    ldr  x11, [x11, #TS_N]
    udiv x10, x11, x10
    cmp  x10, x9
    csel x10, x10, x9, lo
    cmp  x10, #2
    b.lo 5f
    str  x10, [sp]
    ldr  x0, [x19, #PN_EXPR]
    bl   expr_par_safe
    cbz  w0, 5f
    ldr  x22, [sp]
5:  mov  x9, #HJ_SIZE
    mul  x0, x9, x22
    bl   arena_zalloc
    mov  x23, x0
    ldr  x9, [x21, #HS_L]               // window: ceil(n / tasks)
    ldr  x11, [x9, #TS_N]
    add  x9, x11, x22
    sub  x9, x9, #1
    udiv x9, x9, x22
    mov  x24, #0
6:  cmp  x24, x22
    b.hs 7f
    mov  x10, #HJ_SIZE
    madd x25, x24, x10, x23
    str  x19, [x25, #HJ_NODE]
    str  x21, [x25, #HJ_SH]
    mul  x12, x24, x9
    cmp  x12, x11
    csel x12, x12, x11, lo
    str  x12, [x25, #HJ_LO]
    add  x12, x12, x9
    cmp  x12, x11
    csel x12, x12, x11, lo
    str  x12, [x25, #HJ_HI]
    str  x20, [x25, #HJ_CTX]
    cmp  x22, #1
    b.eq 61f
    stp  x9, x11, [sp]                  // worker tasks: own contexts
    mov  x0, #EC_SIZE
    bl   arena_alloc
    ldp  x9, x11, [sp]
    ldp  x12, x13, [x20]
    stp  x12, x13, [x0]
    ldp  x12, x13, [x20, #16]
    stp  x12, x13, [x0, #16]
    ldp  x12, x13, [x20, #32]
    stp  x12, x13, [x0, #32]
    str  x0, [x25, #HJ_CTX]
61: add  x24, x24, #1
    b    6b
7:  cmp  x22, #1
    b.ne 8f
    mov  x0, x23
    bl   hj_probe
    ldr  x0, [x23, #HJ_TS]
    b    10f
8:  ADR_L x0, hj_probe
    mov  x1, x23
    mov  x2, #HJ_SIZE
    mov  x3, x22
    bl   par_run
    mov  x0, x23
    mov  x1, x22
    mov  x2, #HJ_SIZE
    bl   ts_concat
    ldr  x9, [x0, #TS_N]                // the limit applies to the total
    LDR_G x10, g_max_join_rows
    cmp  x9, x10
    b.hi 9f
10: ldr  x9, [x21, #HS_LBUILD]
    cbz  x9, 12f
    mov  x22, x0                        // unmatched build (left) tuples,
    mov  x24, #0                        // NULL-padded
11: ldr  x9, [x21, #HS_R]
    ldr  x10, [x9, #TS_N]
    cmp  x24, x10
    b.hs 111f
    ldr  x10, [x21, #HS_MATCHED]
    ldrb w10, [x10, x24]
    cbnz w10, 110f
    mov  x0, x9
    mov  x1, x24
    bl   ts_tuple
    mov  x1, x0
    mov  x0, x22
    bl   join_emit
110:add  x24, x24, #1
    b    11b
111:mov  x0, x22
12: add  sp, sp, #16
    LEAVE 5
9:  RAISE ERR_RESOURCE_LIMIT, "join result exceeds --max-join-rows"
ENDF ex_hashjoin

// =============================================================================
// hj_table(x0 TupleSet* build input, x1 u64* hashes, x2 u8* NULL flags)
//   -> x0 u32* bucket heads, x1 u32* chain links, x2 bucket mask
// Chained hash table over the build tuples (in tuple order; NULL keys are
// left out: they never match).
//   x19 ts, x20 hashes, x21 flags, x22 heads, x23 links, x24 mask
// =============================================================================
FUNC hj_table
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    ldr  x9, [x19, #TS_N]               // size: power of two >= 2n
    lsl  x9, x9, #1
    mov  x10, #16
1:  cmp  x10, x9
    b.hs 2f
    lsl  x10, x10, #1
    b    1b
2:  sub  x24, x10, #1
    lsl  x0, x10, #2
    bl   arena_alloc
    mov  x22, x0
    mov  w1, #0xff
    add  x2, x24, #1
    lsl  x2, x2, #2
    bl   memset
    ldr  x9, [x19, #TS_N]
    lsl  x0, x9, #2
    add  x0, x0, #16
    bl   arena_alloc
    mov  x23, x0
    ldr  x9, [x19, #TS_N]
    mov  x13, #0
3:  cmp  x13, x9
    b.hs 4f
    ldrb w14, [x21, x13]
    cbnz w14, 31f
    ldr  x14, [x20, x13, lsl #3]
    and  x14, x14, x24
    ldr  w15, [x22, x14, lsl #2]
    str  w15, [x23, x13, lsl #2]
    str  w13, [x22, x14, lsl #2]
31: add  x13, x13, #1
    b    3b
4:  mov  x0, x22
    mov  x1, x23
    mov  x2, x24
    LEAVE 3
ENDF hj_table

// =============================================================================
// join_keys(x0 TupleSet*, x1 Node** keys, x2 nkeys, x3 ctx)
//   -> x0 key cells (nkeys cells per tuple), x1 u64* hashes, x2 u8* NULL
//      flags (1 = some key is NULL)
// Vectorized mode: vkey_cells; row mode: eval_keys per tuple. Both use the
// same hash function.
//   x19 ts, x20 keys, x21 nkeys, x22 ctx, x23 cells, x24 hashes, x25 flags,
//   x26 index
// =============================================================================
FUNC join_keys
    ENTER 5
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x22, x3
    ldr  x9, [x19, #TS_N]
    lsl  x10, x21, #4
    mul  x0, x9, x10
    add  x0, x0, #16
    bl   arena_alloc
    mov  x23, x0
    ldr  x9, [x19, #TS_N]
    lsl  x0, x9, #3
    add  x0, x0, #16
    bl   arena_alloc
    mov  x24, x0
    ldr  x0, [x19, #TS_N]
    add  x0, x0, #16
    bl   arena_alloc
    mov  x25, x0
    TLS_ADDR x9, g_x_mode
    ldr  w9, [x9]
    cmp  w9, #XM_ROW
    b.eq 1f
    cmp  x21, #VKEY_MAX
    b.hi 1f
    bl   .Ljk_tasks
    b    3f
1:  mov  x26, #0
2:  ldr  x9, [x19, #TS_N]
    cmp  x26, x9
    b.hs 3f
    tst  x26, #DEADLINE_MASK
    b.ne 21f
    bl   check_deadline
21: mov  x0, x19
    mov  x1, x26
    bl   ts_tuple
    str  x0, [x22, #EC_TUPLE]
    mov  x0, x20
    mov  x1, x21
    mov  x2, x22
    lsl  x9, x21, #4
    mul  x9, x9, x26
    add  x3, x23, x9
    bl   eval_keys
    str  x0, [x24, x26, lsl #3]
    strb w1, [x25, x26]
    add  x26, x26, #1
    b    2b
3:  mov  x0, x23
    mov  x1, x24
    mov  x2, x25
    LEAVE 5

// local helper: vectorized key cells by vkey_cells tasks over windows of
// the tuples (in parallel with threads > 1, at most one task per
// g_par_min_rows tuples, when the keys are safe for worker threads)
//   uses x26 (tasks), x27 (records), x28 (index)
.Ljk_tasks:
    stp  x29, x30, [sp, #-16]!
    mov  x26, #1
    TLS_LDR x9, g_x_threads
    cmp  x9, #1
    b.ls 2f
    LDR_G x10, g_par_min_rows
    ldr  x11, [x19, #TS_N]
    udiv x10, x11, x10
    cmp  x10, x9
    csel x10, x10, x9, lo
    cmp  x10, #2
    b.lo 2f
    mov  x26, x10
    mov  x28, #0                        // every key safe for workers?
1:  cmp  x28, x21
    b.hs 2f
    ldr  x0, [x20, x28, lsl #3]
    bl   expr_par_safe
    add  x28, x28, #1
    cbnz w0, 1b
    mov  x26, #1
2:  mov  x9, #VK_SIZE
    mul  x0, x9, x26
    bl   arena_alloc
    mov  x27, x0
    ldr  x9, [x19, #TS_N]               // window: ceil(n / tasks)
    add  x10, x9, x26
    sub  x10, x10, #1
    udiv x10, x10, x26
    mov  x28, #0
3:  cmp  x28, x26
    b.hs 5f
    mov  x11, #VK_SIZE
    madd x12, x28, x11, x27
    str  x19, [x12, #VK_TS]
    str  x20, [x12, #VK_KEYS]
    str  x21, [x12, #VK_NKEYS]
    str  x22, [x12, #VK_CTX]
    str  x23, [x12, #VK_CELLS]
    str  x24, [x12, #VK_HASH]
    str  x25, [x12, #VK_FLAGS]
    ldr  x9, [x19, #TS_N]
    mul  x13, x28, x10
    cmp  x13, x9
    csel x13, x13, x9, lo
    str  x13, [x12, #VK_LO]
    add  x13, x13, x10
    cmp  x13, x9
    csel x13, x13, x9, lo
    str  x13, [x12, #VK_HI]
    cmp  x26, #1
    b.eq 4f
    stp  x10, x12, [sp, #-16]!          // worker tasks: own contexts
    mov  x0, #EC_SIZE
    bl   arena_alloc
    ldp  x10, x12, [sp], #16
    ldp  x13, x14, [x22]
    stp  x13, x14, [x0]
    ldp  x13, x14, [x22, #16]
    stp  x13, x14, [x0, #16]
    ldp  x13, x14, [x22, #32]
    stp  x13, x14, [x0, #32]
    str  x0, [x12, #VK_CTX]
4:  add  x28, x28, #1
    b    3b
5:  cmp  x26, #1
    b.ne 6f
    mov  x0, x27
    bl   vkey_cells
    b    7f
6:  ADR_L x0, vkey_cells
    mov  x1, x27
    mov  x2, #VK_SIZE
    mov  x3, x26
    bl   par_run
7:  ldp  x29, x30, [sp], #16
    ret
ENDF join_keys

// =============================================================================
// hj_probe(x0 HashJoin task) — probes the left tuples [HJ_LO, HJ_HI). A chain
// entry is a candidate only if its full 64-bit hash equals the probe's; with
// HS_FAST the single key is then compared by payload, otherwise keys_equal.
// Joined (or NULL-padded) tuples are written straight into the output set.
//   x19 task, x20 ctx, x21 shared, x22 node, x23 out, x24 left index,
//   x25 chain entry, x26 matched, x27 scratch tuple (residual), x28 counter
// Stack: [sp] probe hash
// =============================================================================
FUNC hj_probe
    ENTER 5
    sub  sp, sp, #16
    mov  x19, x0
    ldr  x20, [x19, #HJ_CTX]
    ldr  x21, [x19, #HJ_SH]
    ldr  x22, [x19, #HJ_NODE]
    ldr  x9, [x21, #HS_L]
    ldr  x0, [x9, #TS_W]
    ldp  x10, x11, [x19, #HJ_LO]
    sub  x1, x11, x10
    bl   ts_new
    mov  x23, x0
    str  x23, [x19, #HJ_TS]
    ldr  x9, [x21, #HS_L]
    ldr  x9, [x9, #TS_W]
    lsl  x0, x9, #2
    add  x0, x0, #16
    bl   arena_alloc
    mov  x27, x0
    mov  x28, #0
    ldr  x24, [x19, #HJ_LO]
.Lhp_left:
    ldr  x9, [x19, #HJ_HI]
    cmp  x24, x9
    b.hs .Lhp_end
    mov  x26, #0
    ldr  x9, [x21, #HS_LNULL]
    ldrb w9, [x9, x24]
    cbnz w9, .Lhp_pad                   // NULL key: no partner
    ldr  x9, [x21, #HS_LHASH]
    ldr  x9, [x9, x24, lsl #3]
    str  x9, [sp]
    ldr  x10, [x21, #HS_MASK]
    and  x9, x9, x10
    ldr  x10, [x21, #HS_HEADS]
    ldr  w25, [x10, x9, lsl #2]
.Lhp_chain:
    cmn  w25, #1
    b.eq .Lhp_pad
    add  x28, x28, #1
    tst  x28, #DEADLINE_MASK
    b.ne 1f
    bl   check_deadline
1:  ldr  x9, [x21, #HS_RHASH]          // different hash: different keys
    ldr  x9, [x9, x25, lsl #3]
    ldr  x10, [sp]
    cmp  x9, x10
    b.ne .Lhp_next
    ldr  x9, [x21, #HS_FAST]
    cbz  x9, 2f
    ldr  x9, [x21, #HS_LCELLS]          // (one key: 16-byte cells)
    add  x9, x9, x24, lsl #4
    ldr  x9, [x9]
    ldr  x10, [x21, #HS_RCELLS]
    add  x10, x10, x25, lsl #4
    ldr  x10, [x10]
    cmp  x9, x10
    b.ne .Lhp_next
    b    3f
2:  ldr  x9, [x21, #HS_KS]
    ldr  x0, [x21, #HS_LCELLS]
    madd x0, x24, x9, x0
    ldr  x1, [x21, #HS_RCELLS]
    madd x1, x25, x9, x1
    ldr  x2, [x22, #PN_LKEYS]
    ldr  x3, [x22, #PN_NKEYS]
    bl   keys_equal
    cbz  w0, .Lhp_next
3:  ldr  x0, [x22, #PN_EXPR]            // residual condition
    cbz  x0, 4f
    ldr  x0, [x21, #HS_R]               // on left + right in the scratch
    mov  x1, x25
    bl   ts_tuple
    str  x0, [sp, #-16]!
    ldr  x0, [x21, #HS_L]
    mov  x1, x24
    bl   ts_tuple
    mov  x1, x0
    ldr  x2, [sp], #16
    mov  x0, x27
    ldr  x9, [x21, #HS_L]
    ldr  x3, [x9, #TS_W]
    bl   combine
    ldr  x0, [x22, #PN_EXPR]
    str  x27, [x20, #EC_TUPLE]
    mov  x1, x20
    bl   eval_true
    cbz  w0, .Lhp_next
4:  ldr  x9, [x21, #HS_MATCHED]        // (LEFT join building on the left)
    cbz  x9, 41f
    mov  w10, #1
    strb w10, [x9, x25]
41: mov  x1, #1
    bl   .Lhp_put
    mov  x26, #1
.Lhp_next:
    ldr  x9, [x21, #HS_NEXT]
    ldr  w25, [x9, x25, lsl #2]
    b    .Lhp_chain
.Lhp_pad:
    cbnz x26, 5f
    ldr  x9, [x21, #HS_LBUILD]          // probes are right tuples then
    cbnz x9, 5f
    ldr  w9, [x22, #PN_JT]
    cmp  w9, #JT_LEFT
    b.ne 5f
    mov  x1, #0
    bl   .Lhp_put
5:  add  x24, x24, #1
    b    .Lhp_left
.Lhp_end:
    add  sp, sp, #16
    LEAVE 5

// local helper: appends left tuple x24 joined with right tuple x25 (x1 = 1)
// or padded with NULLs (x1 = 0) to the output (--max-join-rows checked;
// clobbers x0-x15)
.Lhp_put:
    ldr  x9, [x23, #TS_N]
    LDR_G x10, g_max_join_rows
    cmp  x9, x10
    b.hs 9f
    ldr  x10, [x23, #TS_CAP]
    cmp  x9, x10
    b.lo 1f
    stp  x29, x30, [sp, #-16]!          // full: grow
    stp  x1, xzr, [sp, #-16]!
    mov  x0, x23
    mov  x1, #1
    bl   ts_reserve
    ldp  x1, x9, [sp], #16
    ldp  x29, x30, [sp], #16
    ldr  x9, [x23, #TS_N]
1:  ldr  x10, [x23, #TS_W]
    ldr  x11, [x23, #TS_DATA]
    mul  x12, x9, x10
    add  x11, x11, x12, lsl #2          // destination
    add  x9, x9, #1
    str  x9, [x23, #TS_N]
    ldr  x12, [x21, #HS_L]              // left tuple (both inputs have the
    ldr  x13, [x12, #TS_DATA]           // output's width)
    mul  x14, x24, x10
    add  x13, x13, x14, lsl #2
    cbz  x1, 3f
    ldr  x12, [x21, #HS_R]
    ldr  x14, [x12, #TS_DATA]
    mul  x15, x25, x10
    add  x14, x14, x15, lsl #2
2:  cbz  x10, 4f                        // slot-wise AND (see combine)
    ldr  w12, [x13], #4
    ldr  w15, [x14], #4
    and  w12, w12, w15
    str  w12, [x11], #4
    sub  x10, x10, #1
    b    2b
3:  cbz  x10, 4f
    ldr  w12, [x13], #4
    str  w12, [x11], #4
    sub  x10, x10, #1
    b    3b
4:  ret
9:  RAISE ERR_RESOURCE_LIMIT, "join result exceeds --max-join-rows"
ENDF hj_probe

    .ltorg
    NOTE_GNU_STACK
