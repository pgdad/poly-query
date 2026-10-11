// =============================================================================
// vagg.S — vectorized hash aggregation with parallel partial aggregation
// (Phase 5, mode "vectorized", option "threads").
//
//   vagg_ok(x0 BoundQuery*) -> w0 1 if the query can use vagg_aggregate
//       (no DISTINCT aggregate, at most VAGG_MAXKEYS GROUP BY expressions)
//   vagg_aggregate(x0 Aggregate PlanNode*, x1 ctx) -> x0 ResultSet*
//
// The input tuple set is cut into contiguous windows, one per task
// (agg_task); each task builds a hash table of groups over its window in
// batches of VBATCH tuples: the GROUP BY expressions are evaluated as
// vectors (veval), every tuple is hashed into its group (open addressing,
// linear probing), then every aggregate argument is evaluated as a vector
// and accumulated into the groups' states (the same state records and
// accumulation rules as eval.S agg_accum / agg_finish). With several tasks
// (threads > 1) the partial tables are merged in task order (gt_merge).
// Groups are kept in order of first appearance in the input, so the result
// does not depend on the number of threads. Parallel tasks are only used
// when every expression is safe for worker threads (no subqueries) and no
// FLOAT64 SUM / AVG is involved (floating-point addition is not
// associative; the serial order is kept for them).
// =============================================================================
#include "pq.inc"
#include "frame.inc"

#define VAGG_MAXKEYS 16

// Aggregate state record: same layout as eval.S (AS_*), AGG_STATE_SIZE
#define AS_CNT      0
#define AS_LO       8
#define AS_HI       16

// Group table
#define GT_NKEYS    0              // u64
#define GT_NAGG     8              // u64
#define GT_RECSZ    16             // u64 bytes per group record
#define GT_N        24             // u64 groups
#define GT_CAP      32             // u64 record capacity
#define GT_RECS     40             // u8* records
#define GT_HT       48             // u32* slots: group index + 1, 0 = empty
#define GT_MASK     56             // u64 slot mask
#define GT_TYPES    64             // u32* key types
#define GT_SIZE     80
// Group record: hash, first tuple index, key cells, aggregate states
#define GR_HASH     0
#define GR_FIRST    8
#define GR_KEYS     16

// Aggregation task (one per thread)
#define XT_NODE     0              // Aggregate PlanNode*
#define XT_CTX      8              // EvalCtx* (own copy for worker tasks)
#define XT_GT       16             // GroupTable* result
#define XT_TS       24             // TupleSet* input
#define XT_LO       32             // tuple window [lo, hi)
#define XT_HI       40
#define XT_SIZE     48

#define NULL_HASH   0x5bd1e995

    .text

// =============================================================================
// vagg_ok(x0 BoundQuery*) -> w0
// =============================================================================
FUNC vagg_ok
    ldr  x9, [x0, #BQ_NGROUP]
    cmp  x9, #VAGG_MAXKEYS
    b.hi 2f
    ldr  x9, [x0, #BQ_NAGG]
    ldr  x10, [x0, #BQ_AGGS]
1:  cbz  x9, 3f
    ldr  x11, [x10], #8
    ldr  w11, [x11, #N_FLAGS]
    sub  x9, x9, #1
    tbz  w11, #1, 1b                    // NF_DISTINCT
2:  mov  w0, #0
    ret
3:  mov  w0, #1
    ret
ENDF vagg_ok

// agg_par_ok(x0 BoundQuery*) -> w0 1 if partial aggregation on worker
// threads is allowed
//   x19 bq, x20 index, x21 node
LFUNC agg_par_ok
    ENTER 3
    mov  x19, x0
    mov  x20, #0
1:  ldr  x9, [x19, #BQ_NGROUP]
    cmp  x20, x9
    b.hs 2f
    ldr  x9, [x19, #BQ_GROUP]
    ldr  x0, [x9, x20, lsl #3]
    bl   expr_par_safe
    cbz  w0, 9f
    add  x20, x20, #1
    b    1b
2:  mov  x20, #0
3:  ldr  x9, [x19, #BQ_NAGG]
    cmp  x20, x9
    b.hs 8f
    ldr  x9, [x19, #BQ_AGGS]
    ldr  x21, [x9, x20, lsl #3]
    add  x20, x20, #1
    ldr  x0, [x21, #N_A]
    cbz  x0, 3b                         // COUNT(*)
    ldr  w9, [x21, #N_OP]
    cmp  w9, #F_SUM
    ccmp w9, #F_AVG, #4, ne
    b.ne 4f
    ldrb w9, [x0, #N_TYPE]
    cmp  w9, #T_FLOAT
    b.eq 9f
4:  bl   expr_par_safe
    cbz  w0, 9f
    b    3b
8:  mov  w0, #1
    LEAVE 3
9:  mov  w0, #0
    LEAVE 3
ENDF agg_par_ok

// =============================================================================
// vagg_aggregate(x0 node, x1 ctx) -> x0 ResultSet*
//   x19 node, x20 ctx, x21 bq, x22 input ts, x23 tasks, x24 task records,
//   x25 group table, x26 rs, x27 group index, x28 scratch
// =============================================================================
FUNC vagg_aggregate
    ENTER 5
    sub  sp, sp, #16
    mov  x19, x0
    mov  x20, x1
    ldr  x21, [x19, #PN_BQ]
    ldr  x0, [x19, #PN_LEFT]
    bl   ex_tuples
    mov  x22, x0
    // tasks: threads, at most one per g_par_min_rows tuples
    mov  x23, #1
    TLS_LDR x9, g_x_threads
    cmp  x9, #1
    b.ls 1f
    LDR_G x10, g_par_min_rows
    ldr  x11, [x22, #TS_N]
    udiv x10, x11, x10
    cmp  x10, x9
    csel x10, x10, x9, lo
    cmp  x10, #2
    b.lo 1f
    str  x10, [sp]
    mov  x0, x21
    bl   agg_par_ok
    cbz  w0, 1f
    ldr  x23, [sp]
1:  mov  x9, #XT_SIZE
    mul  x0, x9, x23
    bl   arena_zalloc
    mov  x24, x0
    ldr  x9, [x22, #TS_N]               // window: ceil(n / tasks)
    add  x9, x9, x23
    sub  x9, x9, #1
    udiv x9, x9, x23
    mov  x10, #0
2:  cmp  x10, x23
    b.hs 3f
    mov  x11, #XT_SIZE
    madd x28, x10, x11, x24
    str  x19, [x28, #XT_NODE]
    str  x20, [x28, #XT_CTX]
    str  x22, [x28, #XT_TS]
    ldr  x11, [x22, #TS_N]
    mul  x12, x10, x9
    cmp  x12, x11
    csel x12, x12, x11, lo
    str  x12, [x28, #XT_LO]
    add  x12, x12, x9
    cmp  x12, x11
    csel x12, x12, x11, lo
    str  x12, [x28, #XT_HI]
    add  x10, x10, #1
    b    2b
3:  cmp  x23, #1
    b.ne 4f
    mov  x0, x24
    bl   agg_task
    ldr  x25, [x24, #XT_GT]
    b    6f
4:  mov  x27, #0                        // worker tasks: own contexts
5:  cmp  x27, x23
    b.hs 51f
    mov  x0, #EC_SIZE
    bl   arena_alloc
    ldp  x12, x13, [x20]
    stp  x12, x13, [x0]
    ldp  x12, x13, [x20, #16]
    stp  x12, x13, [x0, #16]
    ldp  x12, x13, [x20, #32]
    stp  x12, x13, [x0, #32]
    mov  x11, #XT_SIZE
    madd x28, x27, x11, x24
    str  x0, [x28, #XT_CTX]
    add  x27, x27, #1
    b    5b
51: ADR_L x0, agg_task
    mov  x1, x24
    mov  x2, #XT_SIZE
    mov  x3, x23
    bl   par_run
    mov  x0, x24
    mov  x1, x23
    mov  x2, x21
    bl   gt_merge
    mov  x25, x0
6:  // result rows, one per group in order of first appearance
    ldr  x1, [x25, #GT_N]
    add  x1, x1, #1
    mov  x0, x21
    bl   rs_new
    mov  x26, x0
    ldr  x9, [x25, #GT_N]
    cbnz x9, 7f
    ldr  x9, [x21, #BQ_NGROUP]
    cbnz x9, 9f                         // GROUP BY on empty input: no rows
    mov  x0, x21                        // one group without input
    bl   agg_init
    mov  x1, x0
    mov  x0, x21
    bl   agg_finish
    str  x0, [x20, #EC_AGGV]
    str  xzr, [x20, #EC_GKEYS]
    ldr  x0, [x22, #TS_W]
    bl   null_tuple
    str  x0, [x20, #EC_TUPLE]
    mov  x0, x19
    mov  x1, x20
    mov  x2, x26
    bl   agg_emit_row
    b    9f
7:  mov  x27, #0
8:  ldr  x9, [x25, #GT_N]
    cmp  x27, x9
    b.hs 9f
    ldr  x10, [x25, #GT_RECS]
    ldr  x11, [x25, #GT_RECSZ]
    madd x28, x27, x11, x10             // record
    ldr  x9, [x25, #GT_NKEYS]
    add  x1, x28, #GR_KEYS
    add  x1, x1, x9, lsl #4             // states
    mov  x0, x21
    bl   agg_finish
    str  x0, [x20, #EC_AGGV]
    add  x9, x28, #GR_KEYS
    str  x9, [x20, #EC_GKEYS]
    mov  x0, x22
    ldr  x1, [x28, #GR_FIRST]
    bl   ts_tuple
    str  x0, [x20, #EC_TUPLE]
    mov  x0, x19
    mov  x1, x20
    mov  x2, x26
    bl   agg_emit_row
    add  x27, x27, #1
    b    8b
9:  mov  x0, x26
    add  sp, sp, #16
    LEAVE 5
ENDF vagg_aggregate

// =============================================================================
// gt_new(x0 BoundQuery*, x1 ctx) -> x0 GroupTable*
// Key types drive hashing and equality inside the table. A key that is a
// column of a dictionary-encoded STRING column is hashed and compared by
// its dictionary entry (Str*): within one column every distinct string has
// exactly one entry, so entry identity is value equality.
//   x19 bq, x20 table, x21 ctx
// =============================================================================
LFUNC gt_new
    ENTER 3
    mov  x21, x1
    mov  x19, x0
    mov  x0, #GT_SIZE
    bl   arena_zalloc
    mov  x20, x0
    ldr  x9, [x19, #BQ_NGROUP]
    str  x9, [x20, #GT_NKEYS]
    ldr  x10, [x19, #BQ_NAGG]
    str  x10, [x20, #GT_NAGG]
    lsl  x9, x9, #4
    add  x9, x9, #GR_KEYS
    add  x9, x9, x10, lsl #5            // AGG_STATE_SIZE = 32
    str  x9, [x20, #GT_RECSZ]
    mov  x9, #64
    str  x9, [x20, #GT_CAP]
    ldr  x10, [x20, #GT_RECSZ]
    mul  x0, x9, x10
    bl   arena_alloc
    str  x0, [x20, #GT_RECS]
    mov  x0, #(128 * 4)
    bl   arena_zalloc
    str  x0, [x20, #GT_HT]
    mov  x9, #127
    str  x9, [x20, #GT_MASK]
    ldr  x9, [x20, #GT_NKEYS]           // key types
    lsl  x0, x9, #2
    add  x0, x0, #4
    bl   arena_alloc
    str  x0, [x20, #GT_TYPES]
    mov  x10, #0
1:  ldr  x9, [x20, #GT_NKEYS]
    cmp  x10, x9
    b.hs 2f
    ldr  x11, [x19, #BQ_GROUP]
    ldr  x11, [x11, x10, lsl #3]
    ldr  w12, [x11, #N_TYPE]
    ldr  w13, [x11, #N_KIND]            // dictionary column?
    cmp  w13, #NK_COL
    b.ne 11f
    ldr  w13, [x11, #N_OP]
    cbnz w13, 11f
    ldr  x13, [x11, #N_B]
    ldr  x14, [x21, #EC_TABLES]
    ldr  x14, [x14, x13, lsl #3]
    cbz  x14, 11f
    ldr  w13, [x14, #TBL_LAYOUT]
    cbnz w13, 11f
    ldr  x14, [x14, #TBL_COLS]
    ldr  x13, [x11, #N_VAL]
    add  x14, x14, x13, lsl #5
    ldr  w13, [x14, #COL_ENC]
    cmp  w13, #CENC_DICT
    b.ne 11f
    mov  w12, #T_INT                    // compare entries, not bytes
11: str  w12, [x0, x10, lsl #2]
    add  x10, x10, #1
    b    1b
2:  mov  x0, x20
    LEAVE 3
ENDF gt_new

// gt_keys_eq(x0 cells a, x1 cells b, x2 GroupTable*) -> w0 1 if equal
// (NULL equals NULL)
//   x19 a, x20 b, x21 keys left, x22 types
LFUNC gt_keys_eq
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    ldr  x21, [x2, #GT_NKEYS]
    ldr  x22, [x2, #GT_TYPES]
1:  cbz  x21, 5f
    ldp  x0, x9, [x19], #16
    ldp  x1, x10, [x20], #16
    ldr  w2, [x22], #4
    sub  x21, x21, #1
    orr  x11, x9, x10
    cbz  x11, 2f
    and  x11, x9, x10                   // one NULL: different
    cbz  x11, 6f
    b    1b                             // both NULL
2:  and  w11, w2, #T_KIND_MASK
    cmp  w11, #T_STR
    b.eq 3f
    cmp  w11, #T_FLOAT
    b.eq 3f
    cmp  x0, x1
    b.ne 6f
    b    1b
3:  mov  w3, w2
    bl   cmp_typed
    cbnz w0, 6f
    b    1b
5:  mov  w0, #1
    LEAVE 3
6:  mov  w0, #0
    LEAVE 3
ENDF gt_keys_eq

// =============================================================================
// gt_get(x0 GroupTable*, x1 hash, x2 key cells, x3 first tuple index)
//   -> x0 group index, x1 1 if the group was created
//   x19 table, x20 hash, x21 cells, x22 first, x23 slot, x24 record
// =============================================================================
LFUNC gt_get
    ENTER 5
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x22, x3
    ldr  x9, [x19, #GT_MASK]
    and  x23, x20, x9
1:  ldr  x9, [x19, #GT_HT]
    ldr  w10, [x9, x23, lsl #2]
    cbz  w10, 3f
    sub  w25, w10, #1
    ldr  x11, [x19, #GT_RECS]
    ldr  x12, [x19, #GT_RECSZ]
    madd x24, x25, x12, x11
    ldr  x9, [x24, #GR_HASH]
    cmp  x9, x20
    b.ne 2f
    add  x0, x24, #GR_KEYS
    mov  x1, x21
    mov  x2, x19
    bl   gt_keys_eq
    cbz  w0, 2f
    mov  x0, x25
    mov  x1, #0
    LEAVE 5
2:  ldr  x9, [x19, #GT_MASK]
    add  x23, x23, #1
    and  x23, x23, x9
    b    1b
3:  // new group
    ldr  x9, [x19, #GT_N]
    ldr  x10, [x19, #GT_CAP]
    cmp  x9, x10
    b.lo 4f
    lsl  x10, x10, #1                   // grow the records
    str  x10, [x19, #GT_CAP]
    ldr  x11, [x19, #GT_RECSZ]
    mul  x0, x10, x11
    bl   arena_alloc
    mov  x24, x0
    ldr  x1, [x19, #GT_RECS]
    ldr  x9, [x19, #GT_N]
    ldr  x11, [x19, #GT_RECSZ]
    mul  x2, x9, x11
    bl   memcpy
    str  x24, [x19, #GT_RECS]
4:  ldr  x25, [x19, #GT_N]
    ldr  x11, [x19, #GT_RECS]
    ldr  x12, [x19, #GT_RECSZ]
    madd x24, x25, x12, x11
    str  x20, [x24, #GR_HASH]
    str  x22, [x24, #GR_FIRST]
    add  x0, x24, #GR_KEYS
    mov  x1, x21
    ldr  x2, [x19, #GT_NKEYS]
    lsl  x2, x2, #4
    bl   memcpy
    ldr  x9, [x19, #GT_NKEYS]           // zeroed states
    add  x0, x24, #GR_KEYS
    add  x0, x0, x9, lsl #4
    mov  w1, #0
    ldr  x2, [x19, #GT_NAGG]
    lsl  x2, x2, #5
    bl   memset
    add  w10, w25, #1
    ldr  x9, [x19, #GT_HT]
    str  w10, [x9, x23, lsl #2]
    add  x9, x25, #1
    str  x9, [x19, #GT_N]
    ldr  x10, [x19, #GT_MASK]           // keep the load factor <= 1/2
    cmp  x9, x10, lsr #1
    b.ls 5f
    mov  x0, x19
    bl   gt_rehash
5:  mov  x0, x25
    mov  x1, #1
    LEAVE 5
ENDF gt_get

// gt_rehash(x0 GroupTable*) — doubles the slot array
//   x19 table, x20 new mask, x21 slots, x22 group
LFUNC gt_rehash
    ENTER 3
    mov  x19, x0
    ldr  x9, [x19, #GT_MASK]
    lsl  x20, x9, #1
    add  x20, x20, #1
    add  x0, x20, #1
    lsl  x0, x0, #2
    bl   arena_zalloc
    mov  x21, x0
    mov  x22, #0
1:  ldr  x9, [x19, #GT_N]
    cmp  x22, x9
    b.hs 3f
    ldr  x10, [x19, #GT_RECS]
    ldr  x11, [x19, #GT_RECSZ]
    madd x10, x22, x11, x10
    ldr  x10, [x10, #GR_HASH]
    and  x10, x10, x20
2:  ldr  w11, [x21, x10, lsl #2]
    cbz  w11, 21f
    add  x10, x10, #1
    and  x10, x10, x20
    b    2b
21: add  w11, w22, #1
    str  w11, [x21, x10, lsl #2]
    add  x22, x22, #1
    b    1b
3:  str  x21, [x19, #GT_HT]
    str  x20, [x19, #GT_MASK]
    LEAVE 3
ENDF gt_rehash

// =============================================================================
// agg_task(x0 AggTask*) — partial aggregation of the tuples [XT_LO, XT_HI)
//   x19 task, x20 ctx, x21 bq, x22 ts, x23 group table, x24 vb, x25 batch
//   start, x26 batch size, x27 group ids (u32 [VBATCH]), x28 scratch
// Stack: [sp] key vectors (Vec* [nkeys]), [sp+8] argument vector,
//        [sp+16] key cells, [sp+24] position, [sp+32] slot, [sp+40] hash
// =============================================================================
FUNC agg_task
    ENTER 5
    sub  sp, sp, #64
    mov  x19, x0
    ldr  x20, [x19, #XT_CTX]
    ldr  x9, [x19, #XT_NODE]
    ldr  x21, [x9, #PN_BQ]
    ldr  x22, [x19, #XT_TS]
    mov  x0, x21
    mov  x1, x20
    bl   gt_new
    mov  x23, x0
    str  x23, [x19, #XT_GT]
    mov  x0, x20
    ldr  x1, [x22, #TS_W]
    bl   vb_new
    mov  x24, x0
    ldr  x9, [x21, #BQ_NGROUP]
    lsl  x0, x9, #3
    add  x0, x0, #8
    bl   arena_alloc
    str  x0, [sp]
    mov  x28, #0
1:  ldr  x9, [x21, #BQ_NGROUP]
    cmp  x28, x9
    b.hs 2f
    mov  x0, x24
    bl   vpool_get
    ldr  x9, [sp]
    str  x0, [x9, x28, lsl #3]
    add  x28, x28, #1
    b    1b
2:  mov  x0, x24
    bl   vpool_get
    str  x0, [sp, #8]
    ldr  x9, [x21, #BQ_NGROUP]
    lsl  x0, x9, #4
    add  x0, x0, #16
    bl   arena_alloc
    str  x0, [sp, #16]
    mov  x0, #(VBATCH * 4)
    bl   arena_alloc
    mov  x27, x0
    ldr  x25, [x19, #XT_LO]
.Lat_batch:
    ldr  x9, [x19, #XT_HI]
    cmp  x25, x9
    b.hs .Lat_end
    bl   check_deadline
    ldr  x9, [x19, #XT_HI]
    sub  x26, x9, x25
    mov  x10, #VBATCH
    cmp  x26, x10
    csel x26, x26, x10, lo
    ldr  x9, [x22, #TS_DATA]            // the batch: tuples in place
    ldr  x10, [x22, #TS_W]
    mul  x10, x10, x25
    add  x9, x9, x10, lsl #2
    str  x9, [x24, #VB_TUP]
    str  x26, [x24, #VB_N]
    // ---- group keys as vectors
    mov  x28, #0
3:  ldr  x9, [x21, #BQ_NGROUP]
    cmp  x28, x9
    b.hs 4f
    ldr  x9, [x21, #BQ_GROUP]
    ldr  x0, [x9, x28, lsl #3]
    mov  x1, x24
    ADR_L x2, vsel_ident
    mov  x3, x26
    ldr  x9, [sp]
    ldr  x4, [x9, x28, lsl #3]
    bl   veval
    add  x28, x28, #1
    b    3b
4:  // ---- group of every tuple
    ldr  x9, [x21, #BQ_NGROUP]
    cbnz x9, 41f
    mov  x0, x23                        // no GROUP BY: one group (index 0)
    mov  x1, #0
    ldr  x2, [sp, #16]
    mov  x3, x25
    bl   gt_get
    mov  x0, x27
    mov  w1, #0
    lsl  x2, x26, #2
    bl   memset
    b    .Lat_aggs
41: str  xzr, [sp, #24]
5:  ldr  x9, [sp, #24]
    cmp  x9, x26
    b.hs .Lat_aggs
    mov  x28, #0                        // gather the key cells, hash
    str  xzr, [sp, #40]
6:  ldr  x10, [x21, #BQ_NGROUP]
    cmp  x28, x10
    b.hs 8f
    ldr  x10, [sp]
    ldr  x10, [x10, x28, lsl #3]        // key vector
    ldr  x9, [sp, #24]
    ldr  x0, [x10, x9, lsl #3]
    add  x10, x10, #VEC_NULLS
    ldrb w1, [x10, x9]
    ldr  x11, [sp, #16]
    add  x11, x11, x28, lsl #4
    stp  x0, x1, [x11]
    ldr  x0, =NULL_HASH
    cbnz w1, 7f
    ldr  x0, [x11]
    ldr  x9, [x23, #GT_TYPES]
    ldr  w1, [x9, x28, lsl #2]
    bl   hash_cell
7:  ldr  x9, [sp, #40]
    eor  x9, x9, x0
    ldr  x10, =0x9e3779b97f4a7c15
    mul  x9, x9, x10
    add  x9, x9, #1
    str  x9, [sp, #40]
    add  x28, x28, #1
    b    6b
8:  mov  x0, x23
    ldr  x1, [sp, #40]
    ldr  x2, [sp, #16]
    ldr  x3, [sp, #24]
    add  x3, x3, x25
    bl   gt_get
    ldr  x9, [sp, #24]
    str  w0, [x27, x9, lsl #2]
    add  x9, x9, #1
    str  x9, [sp, #24]
    b    5b
.Lat_aggs:
    // ---- every aggregate: argument vector, accumulate per tuple
    str  xzr, [sp, #32]
9:  ldr  x9, [sp, #32]
    ldr  x10, [x21, #BQ_NAGG]
    cmp  x9, x10
    b.hs .Lat_next
    ldr  x10, [x21, #BQ_AGGS]
    ldr  x28, [x10, x9, lsl #3]         // NK_AGG node
    ldr  w9, [x28, #N_OP]
    cmp  w9, #F_COUNT_STAR
    b.eq .Lat_countstar
    ldr  x0, [x28, #N_A]
    mov  x1, x24
    ADR_L x2, vsel_ident
    mov  x3, x26
    ldr  x4, [sp, #8]
    bl   veval
    str  xzr, [sp, #24]
10: ldr  x9, [sp, #24]
    cmp  x9, x26
    b.hs .Lat_slot_done
    add  x10, x9, #1
    str  x10, [sp, #24]
    ldr  x10, [sp, #8]
    add  x11, x10, #VEC_NULLS
    ldrb w11, [x11, x9]
    cbnz w11, 10b                       // NULL input: ignored
    ldr  x2, [x10, x9, lsl #3]          // value
    ldr  w9, [x27, x9, lsl #2]          // group
    bl   .Lat_state
    ldr  w9, [x28, #N_OP]
    cmp  w9, #F_COUNT
    b.ne 11f
    ldr  x10, [x1, #AS_CNT]
    add  x10, x10, #1
    str  x10, [x1, #AS_CNT]
    b    10b
11: cmp  w9, #F_SUM
    ccmp w9, #F_AVG, #4, ne
    b.ne 12f
    ldr  x10, [x28, #N_A]
    ldrb w10, [x10, #N_TYPE]
    cmp  w10, #T_FLOAT
    b.eq 12f
    ldr  x10, [x1, #AS_CNT]             // exact 128-bit sum
    add  x10, x10, #1
    str  x10, [x1, #AS_CNT]
    ldp  x10, x11, [x1, #AS_LO]
    asr  x12, x2, #63
    adds x10, x10, x2
    adc  x11, x11, x12
    stp  x10, x11, [x1, #AS_LO]
    b    10b
12: mov  x0, x28                        // MIN / MAX / FLOAT64 SUM, AVG
    bl   agg_accum
    b    10b
.Lat_countstar:
    ldr  x9, [x21, #BQ_NGROUP]
    cbnz x9, 130f
    mov  w9, #0                         // one group: add the batch size
    bl   .Lat_state
    ldr  x11, [x1, #AS_CNT]
    add  x11, x11, x26
    str  x11, [x1, #AS_CNT]
    b    .Lat_slot_done
130:
    mov  x10, #0
13: cmp  x10, x26
    b.hs .Lat_slot_done
    ldr  w9, [x27, x10, lsl #2]
    add  x10, x10, #1
    bl   .Lat_state
    ldr  x11, [x1, #AS_CNT]
    add  x11, x11, #1
    str  x11, [x1, #AS_CNT]
    b    13b
.Lat_slot_done:
    ldr  x9, [sp, #32]
    add  x9, x9, #1
    str  x9, [sp, #32]
    b    9b
.Lat_next:
    add  x25, x25, x26
    b    .Lat_batch
.Lat_end:
    add  sp, sp, #64
    LEAVE 5

// local helper: x1 = state record of slot [sp+32] in group w9 (clobbers
// x11-x13; leaf)
.Lat_state:
    ldr  x11, [x23, #GT_RECS]
    ldr  x12, [x23, #GT_RECSZ]
    madd x1, x9, x12, x11
    ldr  x13, [x23, #GT_NKEYS]
    add  x1, x1, #GR_KEYS
    add  x1, x1, x13, lsl #4
    ldr  x13, [sp, #32]
    add  x1, x1, x13, lsl #5
    ret
ENDF agg_task

// =============================================================================
// gt_merge(x0 task records, x1 count, x2 BoundQuery*) -> x0 GroupTable*
// Merges the tables of tasks 1.. into the table of task 0, in task order.
//   x19 tasks, x20 count, x21 bq, x22 destination, x23 task index,
//   x24 source table, x25 group index, x26 source record
// =============================================================================
LFUNC gt_merge
    ENTER 5
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    ldr  x22, [x19, #XT_GT]
    mov  x23, #1
1:  cmp  x23, x20
    b.hs 5f
    mov  x9, #XT_SIZE
    madd x9, x23, x9, x19
    ldr  x24, [x9, #XT_GT]
    mov  x25, #0
2:  ldr  x9, [x24, #GT_N]
    cmp  x25, x9
    b.hs 4f
    ldr  x10, [x24, #GT_RECS]
    ldr  x11, [x24, #GT_RECSZ]
    madd x26, x25, x11, x10
    mov  x0, x22
    ldr  x1, [x26, #GR_HASH]
    add  x2, x26, #GR_KEYS
    ldr  x3, [x26, #GR_FIRST]
    bl   gt_get
    ldr  x10, [x22, #GT_RECS]           // destination states
    ldr  x11, [x22, #GT_RECSZ]
    madd x10, x0, x11, x10
    ldr  x12, [x22, #GT_NKEYS]
    add  x10, x10, #GR_KEYS
    add  x10, x10, x12, lsl #4
    add  x11, x26, #GR_KEYS             // source states
    add  x11, x11, x12, lsl #4
    mov  x0, x21
    mov  x1, x10
    mov  x2, x11
    bl   merge_states
    add  x25, x25, #1
    b    2b
4:  add  x23, x23, #1
    b    1b
5:  mov  x0, x22
    LEAVE 5
ENDF gt_merge

// merge_states(x0 BoundQuery*, x1 destination states, x2 source states)
// Adds partial aggregate states (never DISTINCT, never FLOAT64 SUM / AVG).
//   x19 aggs cursor, x20 dst, x21 src, x22 slots left, x23 node
LFUNC merge_states
    ENTER 4
    ldr  x19, [x0, #BQ_AGGS]
    ldr  x22, [x0, #BQ_NAGG]
    mov  x20, x1
    mov  x21, x2
1:  cbz  x22, 9f
    ldr  x23, [x19], #8
    ldr  w9, [x23, #N_OP]
    ldr  x10, [x21, #AS_CNT]
    cbz  x10, 8f                        // empty source
    cmp  w9, #F_MIN
    b.eq 3f
    cmp  w9, #F_MAX
    b.eq 3f
    ldp  x11, x12, [x20, #AS_LO]        // COUNT / SUM / AVG
    ldp  x13, x14, [x21, #AS_LO]
    adds x11, x11, x13
    adc  x12, x12, x14
    stp  x11, x12, [x20, #AS_LO]
    b    7f
3:  ldr  x11, [x20, #AS_CNT]
    cbz  x11, 6f                        // destination empty: take source
    ldr  x0, [x21, #AS_LO]
    ldr  x1, [x20, #AS_LO]
    ldr  x2, [x23, #N_A]
    ldr  w2, [x2, #N_TYPE]
    mov  w3, w2
    bl   cmp_typed
    ldr  w9, [x23, #N_OP]
    cmp  w9, #F_MIN
    b.ne 4f
    tbz  w0, #31, 7f                    // MIN: replace if source < dest
    b    6f
4:  cmp  w0, #1                         // MAX: replace if source > dest
    b.ne 7f
6:  ldr  x11, [x21, #AS_LO]
    str  x11, [x20, #AS_LO]
7:  ldr  x10, [x21, #AS_CNT]
    ldr  x11, [x20, #AS_CNT]
    add  x11, x11, x10
    str  x11, [x20, #AS_CNT]
8:  add  x20, x20, #AGG_STATE_SIZE
    add  x21, x21, #AGG_STATE_SIZE
    sub  x22, x22, #1
    b    1b
9:  LEAVE 4
ENDF merge_states

    .ltorg
    NOTE_GNU_STACK
