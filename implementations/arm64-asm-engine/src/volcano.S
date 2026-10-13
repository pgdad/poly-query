// =============================================================================
// volcano.S — row-at-a-time iterator (Volcano) execution of the tuple
// operators: the executor of mode "row", the unoptimized baseline.
//
//   it_open(x0 PlanNode*, x1 ctx) -> x0 Iterator*   opens an operator tree
//   it_next(x0 Iterator*) -> x0 u32* tuple, or 0 at the end
//       the tuple stays valid until the next call on the same iterator
//   it_drain(x0 PlanNode*, x1 ctx) -> x0 TupleSet*  all tuples of a tree
//   it_project(x0 Project PlanNode*, x1 ctx, x2 offset, x3 limit (-1 none))
//       -> x0 ResultSet*   pulls tuples one at a time and projects them
//
// Operators: TableScan (candidate rows of scan_ranges through the pushed-down
// filter), Filter, Values, NestedLoopJoin and HashJoin (the right input is
// materialised when the iterator is opened — the build side — and the left
// input is pulled one tuple at a time), MergeJoin (blocking: sorts both
// inputs when opened, then returns its result tuple by tuple). Aggregation,
// Distinct and Sort consume the whole input (it_drain); Project pulls rows
// and stops projecting after OFFSET + LIMIT rows (the remaining input is
// still pulled, so every row passes the same filters and raises the same
// errors as in the other modes).
// =============================================================================
#include "pq.inc"
#include "frame.inc"

#define DEADLINE_MASK 4095

// Iterator
#define IT_NEXT     0               // next function
#define IT_NODE     8               // PlanNode*
#define IT_CTX      16              // EvalCtx*
#define IT_LEFT     24              // child iterator (left input)
#define IT_TUP      32              // u32* output tuple buffer
#define IT_W        40              // tuple width
#define IT_CUR      48              // joins: current left tuple or 0
#define IT_A        56              // operator state (see each operator)
#define IT_B        64
#define IT_C        72
#define IT_D        80
#define IT_E        88
#define IT_F        96
#define IT_G        104
#define IT_H        112
#define IT_EMIT     120             // joins: rows returned (--max-join-rows)
#define IT_TICK     128             // iterations (deadline checks)
#define IT_SIZE     144

    .text

// it_next(x0 Iterator*) -> x0 tuple or 0   (tail call)
FUNC it_next
    ldr  x9, [x0, #IT_NEXT]
    br   x9
ENDF it_next

// it_tick(x0 Iterator*): counts an iteration, checks the deadline every
// DEADLINE_MASK + 1 of them
LFUNC it_tick
    ldr  x9, [x0, #IT_TICK]
    add  x9, x9, #1
    str  x9, [x0, #IT_TICK]
    tst  x9, #DEADLINE_MASK
    b.eq check_deadline                 // tail call
    ret
ENDF it_tick

// it_emit(x0 Iterator*): counts a join result row (--max-join-rows)
LFUNC it_emit
    ldr  x9, [x0, #IT_EMIT]
    LDR_G x10, g_max_join_rows
    cmp  x9, x10
    b.hs 1f
    add  x9, x9, #1
    str  x9, [x0, #IT_EMIT]
    ret
1:  RAISE ERR_RESOURCE_LIMIT, "join result exceeds --max-join-rows"
ENDF it_emit

// =============================================================================
// it_open(x0 node, x1 ctx) -> x0 Iterator*
//   x19 node, x20 ctx, x21 iterator
// =============================================================================
FUNC it_open
    GUARD_TICK                          // CR-6: recursive
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    mov  x0, #IT_SIZE
    bl   arena_zalloc
    mov  x21, x0
    str  x19, [x21, #IT_NODE]
    str  x20, [x21, #IT_CTX]
    ldr  x9, [x19, #PN_BQ]
    ldr  x0, [x9, #BQ_NRV]
    str  x0, [x21, #IT_W]
    bl   null_tuple
    str  x0, [x21, #IT_TUP]
    ldr  w9, [x19, #PN_OP]
    cmp  w9, #PO_SCAN
    b.eq .Lio_scan
    cmp  w9, #PO_FILTER
    b.eq .Lio_filter
    cmp  w9, #PO_HASHJOIN
    b.eq .Lio_hash
    cmp  w9, #PO_NLJOIN
    b.eq .Lio_nl
    cmp  w9, #PO_MERGEJOIN
    b.eq .Lio_merge
    cmp  w9, #PO_VALUES
    b.eq .Lio_values
    RAISE ERR_INTERNAL, "executor: unexpected tuple operator"

.Lio_scan:          // A ranges, B range count, C next range, D row, E end
    mov  x0, x19
    mov  x1, x20
    bl   scan_ranges
    stp  x0, x1, [x21, #IT_A]
    ADR_L x9, it_scan_next
    b    .Lio_ret
.Lio_filter:
    ldr  x0, [x19, #PN_LEFT]
    mov  x1, x20
    bl   it_open
    str  x0, [x21, #IT_LEFT]
    ADR_L x9, it_filter_next
    b    .Lio_ret
.Lio_values:        // A 1 = returned
    ADR_L x9, it_values_next
    b    .Lio_ret
.Lio_merge:         // A materialised result, B position
    mov  x0, x19
    mov  x1, x20
    bl   ex_mergejoin
    str  x0, [x21, #IT_A]
    ADR_L x9, it_ts_next
    b    .Lio_ret
.Lio_nl:            // A right tuples, B right key records, C right NULL
                    // flags, D left key cells, E right position,
                    // F matched, G left key NULL
    ldr  x0, [x19, #PN_RIGHT]
    mov  x1, x20
    bl   it_drain
    str  x0, [x21, #IT_A]
    ldr  x9, [x19, #PN_NKEYS]
    cbz  x9, 1f
    ldr  x1, [x19, #PN_RKEYS]
    mov  x2, x9
    mov  x3, x20
    bl   key_records
    stp  x0, x1, [x21, #IT_B]
    ldr  x9, [x19, #PN_NKEYS]
    lsl  x0, x9, #4
    add  x0, x0, #16
    bl   arena_alloc
    str  x0, [x21, #IT_D]
1:  ldr  x0, [x19, #PN_LEFT]
    mov  x1, x20
    bl   it_open
    str  x0, [x21, #IT_LEFT]
    ADR_L x9, it_nl_next
    b    .Lio_ret
.Lio_hash:          // A right tuples, B right key cells, C heads, D links,
                    // E mask, F left key cells, G chain entry, H matched
    ldr  x0, [x19, #PN_RIGHT]
    mov  x1, x20
    bl   it_drain
    str  x0, [x21, #IT_A]
    ldr  x1, [x19, #PN_RKEYS]
    ldr  x2, [x19, #PN_NKEYS]
    mov  x3, x20
    bl   join_keys
    str  x0, [x21, #IT_B]
    ldr  x0, [x21, #IT_A]
    bl   hj_table
    stp  x0, x1, [x21, #IT_C]
    str  x2, [x21, #IT_E]
    ldr  x9, [x19, #PN_NKEYS]
    lsl  x0, x9, #4
    add  x0, x0, #16
    bl   arena_alloc
    str  x0, [x21, #IT_F]
    ldr  x0, [x19, #PN_LEFT]
    mov  x1, x20
    bl   it_open
    str  x0, [x21, #IT_LEFT]
    ADR_L x9, it_hj_next
.Lio_ret:
    str  x9, [x21, #IT_NEXT]
    mov  x0, x21
    LEAVE 3
ENDF it_open

// =============================================================================
// it_scan_next(x0 it) -> x0 tuple or 0
//   x19 it, x20 node, x21 ctx, x22 row
// =============================================================================
LFUNC it_scan_next
    ENTER 3
    mov  x19, x0
    ldr  x20, [x19, #IT_NODE]
    ldr  x21, [x19, #IT_CTX]
1:  ldp  x22, x10, [x19, #IT_D]         // row, end of the current range
    cmp  x22, x10
    b.lo 2f
    ldp  x9, x10, [x19, #IT_B]          // next range
    cmp  x10, x9
    b.hs 9f
    ldr  x11, [x19, #IT_A]
    add  x11, x11, x10, lsl #4
    add  x10, x10, #1
    str  x10, [x19, #IT_C]
    ldp  x12, x13, [x11]
    stp  x12, x13, [x19, #IT_D]
    b    1b
2:  add  x9, x22, #1
    str  x9, [x19, #IT_D]
    mov  x0, x19
    bl   it_tick
    ldr  x9, [x19, #IT_TUP]
    ldr  x10, [x20, #PN_RV]
    str  w22, [x9, x10, lsl #2]
    ldr  x0, [x20, #PN_EXPR]
    cbz  x0, 3f
    str  x9, [x21, #EC_TUPLE]
    mov  x1, x21
    bl   eval_true
    cbz  w0, 1b
3:  ldr  x0, [x19, #IT_TUP]
    LEAVE 3
9:  mov  x0, #0
    LEAVE 3
ENDF it_scan_next

// it_filter_next(x0 it) -> x0 tuple or 0
//   x19 it, x20 tuple
LFUNC it_filter_next
    ENTER 2
    mov  x19, x0
1:  ldr  x0, [x19, #IT_LEFT]
    bl   it_next
    mov  x20, x0
    cbz  x20, 2f
    ldr  x1, [x19, #IT_CTX]
    str  x20, [x1, #EC_TUPLE]
    ldr  x9, [x19, #IT_NODE]
    ldr  x0, [x9, #PN_EXPR]
    bl   eval_true
    cbz  w0, 1b
2:  mov  x0, x20
    LEAVE 2
ENDF it_filter_next

// it_values_next(x0 it) -> x0 the all-NULL tuple once, then 0   (leaf)
LFUNC it_values_next
    ldr  x9, [x0, #IT_A]
    cbnz x9, 1f
    mov  x9, #1
    str  x9, [x0, #IT_A]
    ldr  x0, [x0, #IT_TUP]
    ret
1:  mov  x0, #0
    ret
ENDF it_values_next

// it_ts_next(x0 it) -> x0 next tuple of the materialised set IT_A, or 0
LFUNC it_ts_next
    ldr  x9, [x0, #IT_A]
    ldr  x1, [x0, #IT_B]
    ldr  x10, [x9, #TS_N]
    cmp  x1, x10
    b.hs 1f
    add  x10, x1, #1
    str  x10, [x0, #IT_B]
    mov  x0, x9
    b    ts_tuple                       // tail call
1:  mov  x0, #0
    ret
ENDF it_ts_next

// it_combine(x0 it, x1 right tuple or 0) -> x0 IT_TUP = current left tuple
// joined with the right tuple (or NULL-padded)
LFUNC it_combine
    ENTER 1
    mov  x19, x0
    mov  x2, x1
    ldr  x0, [x19, #IT_TUP]
    ldr  x1, [x19, #IT_CUR]
    ldr  x3, [x19, #IT_W]
    ldr  x9, [x19, #IT_NODE]
    bl   combine
    ldr  x0, [x19, #IT_TUP]
    LEAVE 1
ENDF it_combine

// =============================================================================
// it_nl_next(x0 it) -> x0 tuple or 0   nested loop join
//   x19 it, x20 node, x21 ctx, x22 right position
// =============================================================================
LFUNC it_nl_next
    ENTER 3
    mov  x19, x0
    ldr  x20, [x19, #IT_NODE]
    ldr  x21, [x19, #IT_CTX]
.Lin_loop:
    ldr  x9, [x19, #IT_CUR]
    cbnz x9, 2f
    ldr  x0, [x19, #IT_LEFT]            // next left tuple
    bl   it_next
    cbz  x0, .Lin_end
    str  x0, [x19, #IT_CUR]
    stp  xzr, xzr, [x19, #IT_E]         // right position, matched
    str  xzr, [x19, #IT_G]
    ldr  x9, [x20, #PN_NKEYS]
    cbz  x9, 2f
    str  x0, [x21, #EC_TUPLE]
    ldr  x0, [x20, #PN_LKEYS]
    mov  x1, x9
    mov  x2, x21
    ldr  x3, [x19, #IT_D]
    bl   eval_keys
    str  x1, [x19, #IT_G]
2:  ldr  x22, [x19, #IT_E]
    ldr  x9, [x19, #IT_A]
    ldr  x9, [x9, #TS_N]
    cmp  x22, x9
    b.hs .Lin_done
    add  x9, x22, #1
    str  x9, [x19, #IT_E]
    mov  x0, x19
    bl   it_tick
    ldr  x9, [x20, #PN_NKEYS]
    cbz  x9, 3f
    ldr  x10, [x19, #IT_G]
    cbnz x10, .Lin_done                 // NULL left key: no partner
    ldr  x10, [x19, #IT_C]
    ldrb w10, [x10, x22]
    cbnz w10, 2b                        // NULL right key
    lsl  x10, x9, #4
    add  x10, x10, #8                   // key record size
    ldr  x11, [x19, #IT_B]
    madd x1, x22, x10, x11
    add  x1, x1, #8
    ldr  x0, [x19, #IT_D]
    ldr  x2, [x20, #PN_LKEYS]
    mov  x3, x9
    bl   keys_equal
    cbz  w0, 2b
3:  ldr  x0, [x19, #IT_A]
    mov  x1, x22
    bl   ts_tuple
    mov  x1, x0
    mov  x0, x19
    bl   it_combine
    ldr  x0, [x20, #PN_EXPR]
    cbz  x0, 4f
    ldr  x9, [x19, #IT_TUP]
    str  x9, [x21, #EC_TUPLE]
    mov  x1, x21
    bl   eval_true
    cbz  w0, 2b
4:  mov  x0, x19
    bl   it_emit
    mov  x9, #1
    str  x9, [x19, #IT_F]
    ldr  x0, [x19, #IT_TUP]
    LEAVE 3
.Lin_done:                              // left tuple finished
    ldr  x9, [x19, #IT_F]
    cbnz x9, 5f
    ldr  w9, [x20, #PN_JT]
    cmp  w9, #JT_LEFT
    b.ne 5f
    mov  x0, x19                        // LEFT JOIN: NULL-padded once
    mov  x1, #0
    bl   it_combine
    str  xzr, [x19, #IT_CUR]
    mov  x0, x19
    bl   it_emit
    ldr  x0, [x19, #IT_TUP]
    LEAVE 3
5:  str  xzr, [x19, #IT_CUR]
    b    .Lin_loop
.Lin_end:
    mov  x0, #0
    LEAVE 3
ENDF it_nl_next

// =============================================================================
// it_hj_next(x0 it) -> x0 tuple or 0   hash join probe
//   x19 it, x20 node, x21 ctx, x22 right tuple
// =============================================================================
LFUNC it_hj_next
    ENTER 3
    mov  x19, x0
    ldr  x20, [x19, #IT_NODE]
    ldr  x21, [x19, #IT_CTX]
.Lih_loop:
    ldr  x9, [x19, #IT_CUR]
    cbnz x9, 2f
    ldr  x0, [x19, #IT_LEFT]            // next left tuple: its keys, bucket
    bl   it_next
    cbz  x0, .Lih_end
    str  x0, [x19, #IT_CUR]
    str  xzr, [x19, #IT_H]
    str  x0, [x21, #EC_TUPLE]
    ldr  x0, [x20, #PN_LKEYS]
    ldr  x1, [x20, #PN_NKEYS]
    mov  x2, x21
    ldr  x3, [x19, #IT_F]
    bl   eval_keys
    mov  x9, #-1
    cbnz x1, 1f
    ldr  x10, [x19, #IT_E]
    and  x0, x0, x10
    ldr  x10, [x19, #IT_C]
    ldr  w9, [x10, x0, lsl #2]
    sxtw x9, w9
1:  str  x9, [x19, #IT_G]
2:  ldr  x22, [x19, #IT_G]              // walk the chain
    cmn  x22, #1
    b.eq .Lih_done
    ldr  x9, [x19, #IT_D]
    ldr  w9, [x9, x22, lsl #2]
    sxtw x9, w9
    str  x9, [x19, #IT_G]
    mov  x0, x19
    bl   it_tick
    ldr  x9, [x20, #PN_NKEYS]
    lsl  x10, x9, #4
    ldr  x11, [x19, #IT_B]
    madd x1, x22, x10, x11
    ldr  x0, [x19, #IT_F]
    ldr  x2, [x20, #PN_LKEYS]
    mov  x3, x9
    bl   keys_equal
    cbz  w0, 2b
    ldr  x0, [x19, #IT_A]
    mov  x1, x22
    bl   ts_tuple
    mov  x1, x0
    mov  x0, x19
    bl   it_combine
    ldr  x0, [x20, #PN_EXPR]
    cbz  x0, 3f
    ldr  x9, [x19, #IT_TUP]
    str  x9, [x21, #EC_TUPLE]
    mov  x1, x21
    bl   eval_true
    cbz  w0, 2b
3:  mov  x0, x19
    bl   it_emit
    mov  x9, #1
    str  x9, [x19, #IT_H]
    ldr  x0, [x19, #IT_TUP]
    LEAVE 3
.Lih_done:
    ldr  x9, [x19, #IT_H]
    cbnz x9, 5f
    ldr  w9, [x20, #PN_JT]
    cmp  w9, #JT_LEFT
    b.ne 5f
    mov  x0, x19                        // LEFT JOIN: NULL-padded once
    mov  x1, #0
    bl   it_combine
    str  xzr, [x19, #IT_CUR]
    mov  x0, x19
    bl   it_emit
    ldr  x0, [x19, #IT_TUP]
    LEAVE 3
5:  str  xzr, [x19, #IT_CUR]
    b    .Lih_loop
.Lih_end:
    mov  x0, #0
    LEAVE 3
ENDF it_hj_next

// =============================================================================
// it_drain(x0 node, x1 ctx) -> x0 TupleSet* of every tuple of the tree
//   x19 iterator, x20 set
// =============================================================================
FUNC it_drain
    GUARD_TICK                          // CR-6: recursive
    ENTER 2
    bl   it_open
    mov  x19, x0
    ldr  x0, [x19, #IT_W]
    mov  x1, #64
    bl   ts_new
    mov  x20, x0
1:  mov  x0, x19
    bl   it_next
    cbz  x0, 2f
    mov  x1, x0
    mov  x0, x20
    bl   ts_push
    b    1b
2:  mov  x0, x20
    LEAVE 2
ENDF it_drain

// =============================================================================
// it_project(x0 Project node, x1 ctx, x2 offset, x3 limit) -> x0 ResultSet*
// Rows [offset, offset + limit) of the input are projected; the input is
// pulled to its end either way.
//   x19 node, x20 ctx, x21 bq, x22 iterator, x23 input position, x24 rows,
//   x25 rs, x26 row capacity, x27 offset, x28 end (offset + limit)
// Stack: [sp] next free cells in the current block, [sp+8] rows left there
// =============================================================================
FUNC it_project
    ENTER 5
    sub  sp, sp, #16
    stp  xzr, xzr, [sp]                 // cell block cursor, rows left
    mov  x19, x0
    mov  x20, x1
    ldr  x21, [x19, #PN_BQ]
    mov  x27, x2
    mov  x28, #-1
    tbnz x3, #63, 1f
    adds x28, x2, x3
    csinv x28, x28, xzr, cc             // saturate
1:  ldr  x0, [x19, #PN_LEFT]
    mov  x1, x20
    bl   it_open
    mov  x22, x0
    mov  x26, #64
    mov  x0, x21
    mov  x1, x26
    bl   rs_new
    mov  x25, x0
    mov  x23, #0
    mov  x24, #0
2:  mov  x0, x22
    bl   it_next
    cbz  x0, 5f
    cmp  x23, x27                       // outside [offset, end): skip
    b.lo 4f
    cmp  x23, x28
    b.hs 4f
    str  x0, [x20, #EC_TUPLE]
    cmp  x24, x26                       // grow the row pointers
    b.lo 3f
    lsl  x26, x26, #1
    lsl  x0, x26, #3
    bl   arena_alloc
    ldr  x1, [x25, #RS_ROWS]
    str  x0, [x25, #RS_ROWS]
    lsl  x2, x24, #3
    bl   memcpy
3:  ldp  x0, x10, [sp]                 // cells: from blocks of 256 rows
    cbnz x10, 31f
    ldr  x9, [x25, #RS_WIDTH]
    lsl  x0, x9, #12                    // 256 rows * 16 bytes per cell
    add  x0, x0, #16
    bl   arena_alloc
    mov  x10, #256
31: sub  x10, x10, #1
    ldr  x9, [x25, #RS_WIDTH]
    add  x11, x0, x9, lsl #4
    stp  x11, x10, [sp]
    ldr  x9, [x25, #RS_ROWS]
    str  x0, [x9, x24, lsl #3]
    add  x24, x24, #1
    mov  x2, x0
    mov  x0, x21
    mov  x1, x20
    bl   project_row
4:  add  x23, x23, #1
    b    2b
5:  str  x24, [x25, #RS_NROWS]
    mov  x0, x25
    add  sp, sp, #16
    LEAVE 5
ENDF it_project

    NOTE_GNU_STACK
