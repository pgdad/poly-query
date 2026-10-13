// =============================================================================
// vagg.S — vectorized hash aggregation with parallel partial aggregation
// (Phase 5, mode "vectorized", option "threads").
//
//   vagg_ok(x0 BoundQuery*) -> w0 1 if the query can use vagg_aggregate
//       (at most VAGG_MAXKEYS GROUP BY expressions, no DISTINCT SUM / AVG
//       over FLOAT64)
//   vagg_aggregate(x0 Aggregate PlanNode*, x1 ctx) -> x0 ResultSet*
//   vdistinct(x0 BoundQuery*, x1 ResultSet*) -> x0 ResultSet*   hash DISTINCT
//
// The input tuple set is cut into contiguous windows, one per task
// (agg_task); each task builds a hash table of groups over its window in
// batches of VBATCH tuples: the GROUP BY expressions are evaluated as
// vectors (veval), every tuple is hashed into its group (open addressing,
// linear probing), then every aggregate argument is evaluated as a vector
// and accumulated into the groups' states (the same state records and
// accumulation rules as eval.S agg_accum / agg_finish). With several tasks
// (threads > 1) the partial tables are merged by parallel merge tasks, one
// per hash partition (gt_pmerge), and the groups ordered by their first
// tuple. Result rows (agg_finish, HAVING, projection) are emitted by
// parallel tasks over windows of the groups (emit_groups). Groups are kept
// in order of first appearance in the input, so the result does not depend
// on the number of threads. Parallel tasks are only used
// when every expression is safe for worker threads (no subqueries) and no
// FLOAT64 SUM / AVG is involved (floating-point addition is not
// associative; the serial order is kept for them).
//
// DISTINCT aggregates are skipped by that pass and computed afterwards by
// vagg_distinct, one slot at a time: the distinct (GROUP BY keys, argument)
// pairs are collected by hashing (the same partial tables + partitioned
// merge, keys only), then each pair is accumulated once into the state of
// its group, found through an index over the final groups.
// =============================================================================
#include "pq.inc"
#include "frame.inc"

#define VAGG_MAXKEYS 16

// Aggregate state record: same layout as eval.S (AS_*), AGG_STATE_SIZE
#define AS_CNT      0
#define AS_LO       8
#define AS_HI       16
#define AS_TOP      24      // wide DECIMAL sums: bits 128..191 (eval.S)

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
#define GT_PIDX     72             // u32* record indexes by merge partition
#define GT_PSTART   80             // u64* [partitions + 1] starts in GT_PIDX
#define GT_SCRATCH  88             // gt_ids: hashes [VBATCH], cells [VBATCH]
#define GT_SIZE     96
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

// Partition merge task (gt_pmerge)
#define MT_TASKS    0              // agg task records (partial tables)
#define MT_T        8              // number of partial tables = partitions
#define MT_PART     16             // this task's partition
#define MT_BQ       24
#define MT_CTX      32
#define MT_GT       40             // GroupTable* result
#define MT_SIZE     48

// First-appearance merge slice (gt_pmerge, km_task)
#define KM_MT       0              // merge records (MT_GT per table)
#define KM_T        8
#define KM_FROM     16             // u64* first record per table
#define KM_TO       24             // u64* end per table
#define KM_OUT      32             // output cursor
#define KM_SIZE     48

// DISTINCT task (vdistinct): XT_SIZE records, the table at XT_GT
#define DT_RS       0              // ResultSet* (rows to dedupe)
#define DT_TYPES    8              // u32* visible column types
#define DT_GT       16             // GroupTable* result (= XT_GT)
#define DT_NKEYS    24
#define DT_LO       32             // rows [lo, hi)
#define DT_HI       40

// DISTINCT-aggregate task (vagg_distinct): XT_SIZE records like agg tasks
// (XT_CTX, XT_GT, XT_TS, XT_LO, XT_HI); the first field is the spec
#define DS_SPEC     0              // DistinctSpec*
// DistinctSpec: the keys of one DISTINCT slot = GROUP BY keys + argument
#define DSP_BQ      0
#define DSP_ARG     8              // argument expression
#define DSP_TYPES   16             // u32 key types [ngroup + 1]
#define DSP_NKEYS   24             // ngroup + 1
#define DSP_SIZE    32

// Group emission task (emit_groups)
#define ET_NODE     0
#define ET_CTX      8              // EvalCtx* (own copy for worker tasks)
#define ET_TS       16             // input TupleSet (representative tuples)
#define ET_GROUPS   24             // group record pointers
#define ET_LO       32             // groups [lo, hi)
#define ET_HI       40
#define ET_OUT      48             // u8** row slots of the window
#define ET_COUNT    56             // rows written (HAVING)
#define ET_SIZE     64

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
    ldr  w12, [x11, #N_FLAGS]
    sub  x9, x9, #1
    tbz  w12, #1, 1b                    // NF_DISTINCT
    ldr  w12, [x11, #N_OP]              // DISTINCT SUM / AVG over FLOAT64:
    cmp  w12, #F_SUM                    // sorted serial accumulation
    ccmp w12, #F_AVG, #4, ne            // (ex_aggregate)
    b.ne 1b
    ldr  x12, [x11, #N_A]
    ldrb w12, [x12, #N_TYPE]
    cmp  w12, #T_FLOAT
    b.ne 1b
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
    GUARD_TICK                          // CR-6: recursive
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
    ldr  x0, [x24, #XT_GT]
    bl   gt_list
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
    mov  x0, x24                        // partitioned parallel merge
    mov  x1, x23
    mov  x2, x21
    mov  x3, x20
    ldr  x4, [x21, #BQ_NORDER]          // group order matters without
    cmp  x4, #0                         // ORDER BY only (its key list ends
    cset x4, eq                         // with every visible column)
    bl   gt_pmerge
6:  // x0 group records in order of first appearance, x1 count
    mov  x25, x0
    mov  x27, x1
    cbz  x27, 61f
    mov  x0, x19                        // DISTINCT aggregates
    mov  x1, x20
    mov  x2, x22
    mov  x3, x25
    mov  x4, x27
    mov  x5, x23
    bl   vagg_distinct
    b    7f
61:
    mov  x0, x21
    mov  x1, #1
    bl   rs_new
    mov  x26, x0
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
7:  mov  x0, x19                        // result rows, one per group
    mov  x1, x20
    mov  x2, x22
    mov  x3, x25
    mov  x4, x27
    bl   emit_groups
    mov  x26, x0
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
    mov  x22, #0
1:  ldr  x9, [x20, #GT_NKEYS]
    cmp  x22, x9
    b.hs 2f
    ldr  x11, [x19, #BQ_GROUP]
    ldr  x0, [x11, x22, lsl #3]
    mov  x1, x21
    bl   gt_key_type
    ldr  x9, [x20, #GT_TYPES]
    str  w0, [x9, x22, lsl #2]
    add  x22, x22, #1
    b    1b
2:  mov  x0, x20
    LEAVE 3
ENDF gt_new

// gt_key_type(x0 key expression, x1 ctx) -> w0 type used to hash / compare
// the key: its type, or T_INT for a column of a dictionary-encoded STRING
// column (the cell is the entry)   (leaf)
LFUNC gt_key_type
    ldr  w9, [x0, #N_TYPE]
    ldr  w10, [x0, #N_KIND]             // dictionary column?
    cmp  w10, #NK_COL
    b.ne 1f
    ldr  w10, [x0, #N_OP]
    cbnz w10, 1f
    ldr  x10, [x0, #N_B]
    ldr  x11, [x1, #EC_TABLES]
    ldr  x11, [x11, x10, lsl #3]
    cbz  x11, 1f
    ldr  w10, [x11, #TBL_LAYOUT]
    cbnz w10, 1f
    ldr  x11, [x11, #TBL_COLS]
    ldr  x10, [x0, #N_VAL]
    add  x11, x11, x10, lsl #5
    ldr  w10, [x11, #COL_ENC]
    cmp  w10, #CENC_DICT
    b.ne 1f
    mov  w9, #T_INT                     // compare entries, not bytes
1:  mov  w0, w9
    ret
ENDF gt_key_type

// cells_hash(x0 cells, x1 n, x2 u32* types) -> x0 hash of n key cells, the
// same fold as agg_task / distinct_task
//   x19 cells, x20 left, x21 types, x22 hash
LFUNC cells_hash
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x22, #0
1:  cbz  x20, 3f
    ldp  x0, x9, [x19], #16
    ldr  w1, [x21], #4
    sub  x20, x20, #1
    ldr  x10, =NULL_HASH
    cbnz x9, 2f
    bl   hash_cell
    mov  x10, x0
2:  eor  x22, x22, x10
    ldr  x9, =0x9e3779b97f4a7c15
    mul  x22, x22, x9
    add  x22, x22, #1
    b    1b
3:  mov  x0, x22
    LEAVE 2
ENDF cells_hash

// gt_alloc(x0 nkeys, x1 nagg, x2 u32* key types, x3 expected groups or 0)
//   -> x0 empty GroupTable* with the given layout (the types array is
//   shared), sized for the expected groups (at least 64) without rehashing
//   x19 table, x20 capacity
LFUNC gt_alloc
    ENTER 2
    stp  x0, x1, [sp, #-16]!
    stp  x2, x3, [sp, #-16]!
    mov  x0, #GT_SIZE
    bl   arena_zalloc
    mov  x19, x0
    ldp  x2, x20, [sp], #16
    ldp  x0, x1, [sp], #16
    str  x0, [x19, #GT_NKEYS]
    str  x1, [x19, #GT_NAGG]
    str  x2, [x19, #GT_TYPES]
    lsl  x9, x0, #4
    add  x9, x9, #GR_KEYS
    add  x9, x9, x1, lsl #5             // AGG_STATE_SIZE = 32
    str  x9, [x19, #GT_RECSZ]
    cmp  x20, #64
    mov  x10, #64
    csel x20, x20, x10, hi
    str  x20, [x19, #GT_CAP]
    mul  x0, x9, x20
    bl   arena_alloc
    str  x0, [x19, #GT_RECS]
    mov  x10, #128                      // slots: power of two > 2 * capacity
1:  cmp  x10, x20, lsl #1
    b.hi 2f
    lsl  x10, x10, #1
    b    1b
2:  sub  x9, x10, #1
    str  x9, [x19, #GT_MASK]
    lsl  x0, x10, #2
    bl   arena_zalloc
    str  x0, [x19, #GT_HT]
    mov  x0, x19
    LEAVE 2
ENDF gt_alloc

// =============================================================================
// vdistinct(x0 BoundQuery*, x1 ResultSet*) -> x0 ResultSet*
// SELECT DISTINCT by hashing (vectorized mode): the visible cells of every
// row are looked up in a group table without aggregates; the first row of
// every distinct value survives, in order of first appearance. With threads
// > 1 tasks dedupe windows of the rows into partial tables that are merged
// like partial aggregates (gt_pmerge).
//   x19 bq, x20 rs, x21 types, x22 tasks, x23 records, x24 list, x25 count,
//   x26 index
// =============================================================================
FUNC vdistinct
    ENTER 5
    mov  x19, x0
    mov  x20, x1
    ldr  x9, [x19, #BQ_NOUT]            // key types: the visible columns
    lsl  x0, x9, #2
    add  x0, x0, #4
    bl   arena_alloc
    mov  x21, x0
    mov  x26, #0
1:  ldr  x9, [x19, #BQ_NOUT]
    cmp  x26, x9
    b.hs 2f
    ldr  x10, [x19, #BQ_OUT]
    mov  x11, #OC_SIZE
    madd x10, x26, x11, x10
    ldr  w10, [x10, #OC_TYPE]
    str  w10, [x21, x26, lsl #2]
    add  x26, x26, #1
    b    1b
2:  mov  x22, #1                        // tasks (no expressions: always safe)
    TLS_LDR x9, g_x_threads
    cmp  x9, #1
    b.ls 3f
    LDR_G x10, g_par_min_rows
    ldr  x11, [x20, #RS_NROWS]
    udiv x10, x11, x10
    cmp  x10, x9
    csel x10, x10, x9, lo
    cmp  x10, #2
    csel x22, x10, x22, hs
3:  mov  x9, #XT_SIZE
    mul  x0, x9, x22
    bl   arena_alloc
    mov  x23, x0
    ldr  x11, [x20, #RS_NROWS]          // window: ceil(n / tasks)
    add  x9, x11, x22
    sub  x9, x9, #1
    udiv x9, x9, x22
    mov  x26, #0
4:  cmp  x26, x22
    b.hs 5f
    mov  x10, #XT_SIZE
    madd x10, x26, x10, x23
    str  x20, [x10, #DT_RS]
    str  x21, [x10, #DT_TYPES]
    ldr  x12, [x19, #BQ_NOUT]
    str  x12, [x10, #DT_NKEYS]
    mul  x12, x26, x9
    cmp  x12, x11
    csel x12, x12, x11, lo
    str  x12, [x10, #DT_LO]
    add  x12, x12, x9
    cmp  x12, x11
    csel x12, x12, x11, lo
    str  x12, [x10, #DT_HI]
    add  x26, x26, #1
    b    4b
5:  cmp  x22, #1
    b.ne 6f
    mov  x0, x23
    bl   distinct_task
    ldr  x0, [x23, #DT_GT]
    bl   gt_list
    b    7f
6:  ADR_L x0, distinct_task
    mov  x1, x23
    mov  x2, #XT_SIZE
    mov  x3, x22
    bl   par_run
    mov  x0, x23
    mov  x1, x22
    mov  x2, x19
    mov  x3, #0
    ldr  x4, [x19, #BQ_NORDER]          // row order matters without ORDER BY
    cmp  x4, #0
    cset x4, eq
    bl   gt_pmerge
7:  mov  x24, x0                        // first row of every group, in order
    mov  x25, x1
    lsl  x0, x25, #3
    add  x0, x0, #16
    bl   arena_alloc
    ldr  x10, [x20, #RS_ROWS]
    mov  x26, #0
8:  cmp  x26, x25
    b.hs 9f
    ldr  x11, [x24, x26, lsl #3]
    ldr  x11, [x11, #GR_FIRST]
    ldr  x11, [x10, x11, lsl #3]
    str  x11, [x0, x26, lsl #3]
    add  x26, x26, #1
    b    8b
9:  str  x0, [x20, #RS_ROWS]
    str  x25, [x20, #RS_NROWS]
    mov  x0, x20
    LEAVE 5
ENDF vdistinct

// distinct_task(x0 record): rows [lo, hi) into a key-only group table
//   x19 record, x20 table, x21 row index, x22 rows, x23 nkeys, x24 hash,
//   x25 key, x26 row
LFUNC distinct_task
    ENTER 5
    mov  x19, x0
    ldr  x0, [x19, #DT_NKEYS]
    mov  x1, #0
    ldr  x2, [x19, #DT_TYPES]
    mov  x3, #0
    bl   gt_alloc
    mov  x20, x0
    str  x20, [x19, #DT_GT]
    ldr  x9, [x19, #DT_RS]
    ldr  x22, [x9, #RS_ROWS]
    ldr  x23, [x19, #DT_NKEYS]
    ldr  x21, [x19, #DT_LO]
1:  ldr  x9, [x19, #DT_HI]
    cmp  x21, x9
    b.hs 9f
    tst  x21, #0xfff
    b.ne 2f
    bl   check_deadline
2:  ldr  x26, [x22, x21, lsl #3]
    mov  x24, #0
    mov  x25, #0
3:  cmp  x25, x23                       // hash of the visible cells
    b.hs 5f
    add  x9, x26, x25, lsl #4
    ldp  x0, x10, [x9]
    ldr  x11, =NULL_HASH
    cbnz x10, 4f
    ldr  x9, [x19, #DT_TYPES]
    ldr  w1, [x9, x25, lsl #2]
    and  w9, w1, #T_KIND_MASK
    cbz  w9, 4f                         // null type (all NULL)
    bl   hash_cell
    mov  x11, x0
4:  eor  x24, x24, x11
    ldr  x9, =0x9e3779b97f4a7c15
    mul  x24, x24, x9
    add  x24, x24, #1
    add  x25, x25, #1
    b    3b
5:  mov  x0, x20
    mov  x1, x24
    mov  x2, x26
    mov  x3, x21
    bl   gt_get
    add  x21, x21, #1
    b    1b
9:  LEAVE 5
ENDF distinct_task

// =============================================================================
// gt_ids(x0 GroupTable*, x1 Vec** key vectors (GT_NKEYS), x2 n, x3 u32* ids,
//        x4 tuple index of position 0, x5 1 = skip positions whose last key
//        is NULL)
// The group of each batch position 0..n-1 (created when new: gt_get, first
// tuple = x4 + position; skipped positions get no id). Keys whose types
// compare by payload (no STRING, FLOAT64 or wide DECIMAL key; dictionary
// entries count as payloads) take the inline path: the cells and hashes
// (mix64, as hash_cell) of the whole batch first, then the probes, each
// prefetching the slot 8 positions and the record 4 positions ahead (the
// tables of high-cardinality groupings do not fit in cache). Other keys go
// through hash_cell / gt_get per position.
//   x19 table, x20 vectors, x21 n, x22 ids, x23 base, x24 position,
//   x25 cells, x26 1 = inline path, x27 key, x28 hash
// Stack: [sp] skip flag, [sp+8] hashes (inline path)
// =============================================================================
LFUNC gt_ids
    ENTER 5
    sub  sp, sp, #16
    str  x5, [sp]
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x22, x3
    mov  x23, x4
    ldr  x25, [x19, #GT_SCRATCH]        // scratch: hashes, then cells
    cbnz x25, 0f
    ldr  x9, [x19, #GT_NKEYS]
    lsl  x0, x9, #4
    add  x0, x0, #8
    mov  x9, #VBATCH
    mul  x0, x0, x9
    add  x0, x0, #16
    bl   arena_alloc
    mov  x25, x0
    str  x25, [x19, #GT_SCRATCH]
0:  str  x25, [sp, #8]
    add  x25, x25, #(VBATCH * 8)        // cells of position 0
    mov  x26, #1                        // inline path?
    mov  x27, #0
1:  ldr  x9, [x19, #GT_NKEYS]
    cmp  x27, x9
    b.hs 2f
    ldr  x9, [x19, #GT_TYPES]
    ldr  w9, [x9, x27, lsl #2]
    add  x27, x27, #1
    BR_WIDE w9, w10, 11f
    and  w9, w9, #T_KIND_MASK
    cmp  w9, #T_STR
    b.eq 11f
    cmp  w9, #T_FLOAT
    b.ne 1b
11: mov  x26, #0
2:  cbz  x26, .Lgi_slow
    // ---- inline path, pass 1: cells and hashes of every position ------------
    ldr  x2, [x19, #GT_NKEYS]
    ldr  x3, [sp, #8]                   // hashes
    lsl  x4, x2, #4                     // cell bytes per position
    ldr  x5, =0xff51afd7ed558ccd
    ldr  x6, =0xc4ceb9fe1a85ec53
    ldr  x7, =0x9e3779b97f4a7c15
    ldr  x8, =NULL_HASH
    mov  x24, #0
3:  cmp  x24, x21
    b.hs .Lgi_probe
    mul  x11, x24, x4
    add  x11, x25, x11                  // cells of this position
    mov  x28, #0
    mov  x27, #0
4:  cmp  x27, x2
    b.hs 6f
    ldr  x10, [x20, x27, lsl #3]        // key vector
    ldr  x0, [x10, x24, lsl #3]
    add  x10, x10, #VEC_NULLS
    ldrb w1, [x10, x24]
    stp  x0, x1, [x11], #16
    mov  x9, x8
    cbnz w1, 5f
    eor  x0, x0, x0, lsr #33            // mix64 (inline)
    mul  x0, x0, x5
    eor  x0, x0, x0, lsr #33
    mul  x0, x0, x6
    eor  x9, x0, x0, lsr #33
5:  eor  x28, x28, x9
    mul  x28, x28, x7
    add  x28, x28, #1
    add  x27, x27, #1
    b    4b
6:  str  x28, [x3, x24, lsl #3]
    add  x24, x24, #1
    b    3b
    // ---- pass 2: probes with prefetching ---------------------------------------
.Lgi_probe:
    mov  x24, #0
.Lgi_ppos:
    cmp  x24, x21
    b.hs .Lgi_end
    ldr  x9, [sp]                       // NULL last key: skipped?
    cbz  x9, 1f
    ldr  x9, [x19, #GT_NKEYS]
    sub  x9, x9, #1
    ldr  x9, [x20, x9, lsl #3]
    add  x9, x9, #VEC_NULLS
    ldrb w9, [x9, x24]
    cbz  w9, 1f
    add  x24, x24, #1
    b    .Lgi_ppos
1:  ldr  x9, [x19, #GT_MASK]
    ldr  x11, [x19, #GT_HT]
    ldr  x12, [x19, #GT_RECS]
    ldr  x13, [x19, #GT_RECSZ]
    ldr  x3, [sp, #8]
    add  x10, x24, #8                   // prefetch the slot 8 ahead
    cmp  x10, x21
    b.hs 2f
    ldr  x10, [x3, x10, lsl #3]
    and  x10, x10, x9
    add  x10, x11, x10, lsl #2
    prfm pldl1keep, [x10]
    add  x10, x24, #4                   // and the record 4 ahead
    cmp  x10, x21
    b.hs 2f
    ldr  x10, [x3, x10, lsl #3]
    and  x10, x10, x9
    ldr  w10, [x11, x10, lsl #2]
    cbz  w10, 2f
    sub  w10, w10, #1
    madd x10, x10, x13, x12
    prfm pldl1keep, [x10]
2:  ldr  x28, [x3, x24, lsl #3]         // hash
    ldr  x2, [x19, #GT_NKEYS]
    lsl  x4, x2, #4
    mul  x4, x4, x24
    add  x17, x25, x4                   // cells
    and  x10, x28, x9
3:  ldr  w14, [x11, x10, lsl #2]
    cbz  w14, .Lgi_new                  // empty slot: new group
    sub  w14, w14, #1
    madd x15, x14, x13, x12             // record
    ldr  x16, [x15, #GR_HASH]
    cmp  x16, x28
    b.ne 5f
    add  x15, x15, #GR_KEYS             // keys: NULL flags equal and,
    mov  x7, x17                        // where not NULL, payloads
    mov  x8, x2
4:  cbz  x8, .Lgi_found
    ldp  x3, x4, [x15], #16
    ldp  x5, x6, [x7], #16
    sub  x8, x8, #1
    cmp  x4, x6
    b.ne 5f
    cbnz x4, 4b
    cmp  x3, x5
    b.eq 4b
5:  add  x10, x10, #1
    and  x10, x10, x9
    b    3b
.Lgi_found:
    str  w14, [x22, x24, lsl #2]
    add  x24, x24, #1
    b    .Lgi_ppos
.Lgi_new:
    mov  x0, x19
    mov  x1, x28
    mov  x2, x17
    add  x3, x23, x24
    bl   gt_get
    str  w0, [x22, x24, lsl #2]
    add  x24, x24, #1
    b    .Lgi_ppos
    // ---- other key types: hash_cell / gt_get per position ---------------------
.Lgi_slow:
    mov  x24, #0
.Lgi_pos:
    cmp  x24, x21
    b.hs .Lgi_end
    ldr  x9, [sp]                       // NULL last key: skipped?
    cbz  x9, 21f
    ldr  x9, [x19, #GT_NKEYS]
    sub  x9, x9, #1
    ldr  x9, [x20, x9, lsl #3]
    add  x9, x9, #VEC_NULLS
    ldrb w9, [x9, x24]
    cbz  w9, 21f
    add  x24, x24, #1
    b    .Lgi_pos
21: mov  x28, #0                        // gather the key cells, hash
    mov  x27, #0
3:  ldr  x9, [x19, #GT_NKEYS]
    cmp  x27, x9
    b.hs 6f
    ldr  x10, [x20, x27, lsl #3]        // key vector
    ldr  x0, [x10, x24, lsl #3]
    add  x10, x10, #VEC_NULLS
    ldrb w1, [x10, x24]
    add  x11, x25, x27, lsl #4
    stp  x0, x1, [x11]
    ldr  x9, =NULL_HASH
    cbnz w1, 5f
    ldr  x9, [x19, #GT_TYPES]
    ldr  w1, [x9, x27, lsl #2]
    bl   hash_cell
    mov  x9, x0
5:  eor  x28, x28, x9
    ldr  x9, =0x9e3779b97f4a7c15
    mul  x28, x28, x9
    add  x28, x28, #1
    add  x27, x27, #1
    b    3b
6:  mov  x0, x19
    mov  x1, x28
    mov  x2, x25
    add  x3, x23, x24
    bl   gt_get
    str  w0, [x22, x24, lsl #2]
    add  x24, x24, #1
    b    .Lgi_pos
.Lgi_end:
    add  sp, sp, #16
    LEAVE 5
ENDF gt_ids

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
2:  BR_WIDE w2, w11, 3f
    and  w11, w2, #T_KIND_MASK
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
    GUARD_TICK                          // CR-6: recursive
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
41: mov  x0, x23
    ldr  x1, [sp]                       // key vectors
    mov  x2, x26
    mov  x3, x27
    mov  x4, x25
    mov  x5, #0
    bl   gt_ids
.Lat_aggs:
    // ---- every aggregate: argument vector, accumulate per tuple
    str  xzr, [sp, #32]
9:  ldr  x9, [sp, #32]
    ldr  x10, [x21, #BQ_NAGG]
    cmp  x9, x10
    b.hs .Lat_next
    ldr  x10, [x21, #BQ_AGGS]
    ldr  x28, [x10, x9, lsl #3]         // NK_AGG node
    ldr  w9, [x28, #N_FLAGS]
    tbnz w9, #1, .Lat_slot_done         // DISTINCT: vagg_distinct
    ldr  w9, [x28, #N_OP]
    cmp  w9, #F_COUNT_STAR
    b.eq .Lat_countstar
    ldr  x0, [x28, #N_A]
    mov  x1, x24
    ADR_L x2, vsel_ident
    mov  x3, x26
    ldr  x4, [sp, #8]
    bl   veval
    bl   .Lat_mode                      // inline accumulation?
    cbnz x15, .Lat_fast
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
    ldr  w10, [x10, #N_TYPE]
    BR_WIDE w10, w11, 12f
    and  w10, w10, #T_KIND_MASK
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
12: mov  x0, x28                        // MIN / MAX / FLOAT64 / wide SUM, AVG
    bl   agg_accum
    b    10b
    // ---- COUNT, exact SUM / AVG, MIN / MAX of integer-like values: inline
.Lat_fast:
    ldr  x10, [sp, #8]                  // argument vector
    add  x11, x10, #VEC_NULLS
    ldr  x12, [x23, #GT_RECS]
    ldr  x13, [x23, #GT_RECSZ]
    ldr  x14, [x23, #GT_NKEYS]          // state offset in a record
    lsl  x14, x14, #4
    add  x14, x14, #GR_KEYS
    ldr  x9, [sp, #32]
    add  x14, x14, x9, lsl #5
    mov  x9, #0
1:  cmp  x9, x26
    b.hs .Lat_slot_done
    ldrb w16, [x11, x9]
    cbnz w16, 6f                        // NULL input: ignored
    ldr  x2, [x10, x9, lsl #3]
    ldr  w17, [x27, x9, lsl #2]
    madd x1, x17, x13, x12
    add  x1, x1, x14                    // state
    ldr  x3, [x1, #AS_CNT]
    add  x3, x3, #1
    str  x3, [x1, #AS_CNT]
    cmp  x15, #2
    b.lo 6f                             // COUNT
    b.hi 3f
    ldp  x4, x5, [x1, #AS_LO]           // SUM / AVG: exact 128-bit sum
    asr  x6, x2, #63
    adds x4, x4, x2
    adc  x5, x5, x6
    stp  x4, x5, [x1, #AS_LO]
    b    6f
3:  cmp  x3, #1                         // MIN / MAX: first value
    b.eq 5f
    ldr  x4, [x1, #AS_LO]
    cmp  x15, #3
    b.ne 4f
    cmp  x2, x4                         // MIN: replace if smaller
    b.lt 5f
    b    6f
4:  cmp  x2, x4                         // MAX: replace if larger
    b.le 6f
5:  str  x2, [x1, #AS_LO]
6:  add  x9, x9, #1
    b    1b

// local helper: x15 = inline accumulation mode of aggregate x28 (0 = call
// agg_accum, 1 COUNT, 2 exact SUM / AVG, 3 MIN, 4 MAX of values compared
// as signed payloads: BOOLEAN, INT64, narrow DECIMAL, DATE, TIMESTAMP)
// (clobbers x9-x11; leaf)
.Lat_mode:
    mov  x15, #0
    ldr  w9, [x28, #N_OP]
    ldr  x10, [x28, #N_A]
    ldr  w10, [x10, #N_TYPE]
    BR_WIDE w10, w11, 91f
    and  w10, w10, #T_KIND_MASK
    cmp  w9, #F_COUNT
    b.ne 1f
    mov  x15, #1
    ret
1:  cmp  w10, #T_FLOAT                  // FLOAT64 and STRING: agg_accum
    b.eq 91f
    cmp  w10, #T_STR
    b.eq 91f
    cbz  w10, 91f                        // null type
    cmp  w9, #F_SUM
    ccmp w9, #F_AVG, #4, ne
    b.ne 2f
    mov  x15, #2
    ret
2:  cmp  w9, #F_MIN
    b.ne 3f
    mov  x15, #3
    ret
3:  cmp  w9, #F_MAX
    b.ne 91f
    mov  x15, #4
91: ret

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
// vagg_distinct(x0 Aggregate node, x1 ctx, x2 input ts, x3 final group
//               records, x4 count, x5 tasks)
// Accumulates every DISTINCT aggregate slot into the final groups: per slot,
// tasks (as many as the aggregation pass used, so the expressions are known
// to be safe on workers) hash the (GROUP BY keys, argument) pairs of their
// windows into key-only tables, merged like partial aggregates; then every
// distinct pair is accumulated once (agg_accum) into its group, looked up in
// an index over the final groups. NULL arguments are ignored.
//   x19 node, x20 ctx, x21 bq, x22 ts, x23 groups, x24 count, x25 slot,
//   x26 aggregate node, x27 index, x28 scratch
// Stack: [sp] tasks, [sp+8] group index, [sp+16] spec, [sp+24] task records,
//        [sp+32] distinct records, [sp+40] their count
// =============================================================================
LFUNC vagg_distinct
    GUARD_TICK                          // CR-6: recursive
    ENTER 5
    sub  sp, sp, #48
    mov  x19, x0
    mov  x20, x1
    ldr  x21, [x19, #PN_BQ]
    mov  x22, x2
    mov  x23, x3
    mov  x24, x4
    str  x5, [sp]
    ldr  x9, [x21, #BQ_NAGG]            // any DISTINCT slot?
    ldr  x10, [x21, #BQ_AGGS]
1:  cbz  x9, .Lvd_end
    ldr  x11, [x10], #8
    ldr  w11, [x11, #N_FLAGS]
    sub  x9, x9, #1
    tbz  w11, #1, 1b
    mov  x0, #DSP_SIZE                  // the spec: key types
    bl   arena_alloc
    str  x0, [sp, #16]
    str  x21, [x0, #DSP_BQ]
    ldr  x9, [x21, #BQ_NGROUP]
    add  x9, x9, #1
    str  x9, [x0, #DSP_NKEYS]
    lsl  x0, x9, #2
    bl   arena_alloc
    ldr  x28, [sp, #16]
    str  x0, [x28, #DSP_TYPES]
    mov  x27, #0
2:  ldr  x9, [x21, #BQ_NGROUP]
    cmp  x27, x9
    b.hs 3f
    ldr  x9, [x21, #BQ_GROUP]
    ldr  x0, [x9, x27, lsl #3]
    mov  x1, x20
    bl   gt_key_type
    ldr  x9, [x28, #DSP_TYPES]
    str  w0, [x9, x27, lsl #2]
    add  x27, x27, #1
    b    2b
3:  ldr  x0, [x21, #BQ_NGROUP]          // index: group keys -> list position
    mov  x1, #0
    ldr  x2, [x28, #DSP_TYPES]
    mov  x3, x24
    bl   gt_alloc
    str  x0, [sp, #8]
    mov  x27, #0
4:  cmp  x27, x24
    b.hs 5f
    ldr  x9, [x23, x27, lsl #3]
    ldr  x0, [sp, #8]
    ldr  x1, [x9, #GR_HASH]
    add  x2, x9, #GR_KEYS
    mov  x3, x27
    bl   gt_get
    add  x27, x27, #1
    b    4b
5:  ldr  x9, [sp]                       // task records
    mov  x10, #XT_SIZE
    mul  x0, x9, x10
    bl   arena_zalloc
    str  x0, [sp, #24]
    mov  x27, #0
6:  ldr  x9, [sp]
    cmp  x27, x9
    b.hs 8f
    ldr  x10, [sp, #24]
    mov  x11, #XT_SIZE
    madd x28, x27, x11, x10
    ldr  x10, [sp, #16]
    str  x10, [x28, #DS_SPEC]
    str  x20, [x28, #XT_CTX]
    str  x22, [x28, #XT_TS]
    ldr  x11, [x22, #TS_N]              // window: ceil(n / tasks)
    add  x10, x11, x9
    sub  x10, x10, #1
    udiv x10, x10, x9
    mul  x12, x27, x10
    cmp  x12, x11
    csel x12, x12, x11, lo
    str  x12, [x28, #XT_LO]
    add  x12, x12, x10
    cmp  x12, x11
    csel x12, x12, x11, lo
    str  x12, [x28, #XT_HI]
    cmp  x9, #1
    b.eq 7f
    mov  x0, #EC_SIZE                   // worker tasks: own contexts
    bl   arena_alloc
    ldp  x12, x13, [x20]
    stp  x12, x13, [x0]
    ldp  x12, x13, [x20, #16]
    stp  x12, x13, [x0, #16]
    ldp  x12, x13, [x20, #32]
    stp  x12, x13, [x0, #32]
    str  x0, [x28, #XT_CTX]
7:  add  x27, x27, #1
    b    6b
8:  mov  x25, #0
.Lvd_slot:
    ldr  x9, [x21, #BQ_NAGG]
    cmp  x25, x9
    b.hs .Lvd_end
    ldr  x9, [x21, #BQ_AGGS]
    ldr  x26, [x9, x25, lsl #3]
    ldr  w9, [x26, #N_FLAGS]
    tbz  w9, #1, .Lvd_next
    ldr  x28, [sp, #16]                 // the argument is the last key
    ldr  x0, [x26, #N_A]
    str  x0, [x28, #DSP_ARG]
    mov  x1, x20
    bl   gt_key_type
    ldr  x9, [x28, #DSP_TYPES]
    ldr  x10, [x21, #BQ_NGROUP]
    str  w0, [x9, x10, lsl #2]
    ldr  x9, [sp]
    cmp  x9, #1
    b.ne 1f
    ldr  x0, [sp, #24]
    bl   dagg_task
    ldr  x0, [sp, #24]
    ldr  x0, [x0, #XT_GT]
    bl   gt_list
    b    2f
1:  ADR_L x0, dagg_task
    ldr  x1, [sp, #24]
    mov  x2, #XT_SIZE
    ldr  x3, [sp]
    bl   par_run
    ldr  x0, [sp, #24]
    ldr  x1, [sp]
    mov  x2, x21
    mov  x3, x20
    mov  x4, #0                         // pair order does not matter
    bl   gt_pmerge
2:  stp  x0, x1, [sp, #32]
    mov  x27, #0
3:  ldr  x9, [sp, #40]
    cmp  x27, x9
    b.hs .Lvd_next
    tst  x27, #0xfff
    b.ne 4f
    bl   check_deadline
4:  ldr  x9, [sp, #32]
    ldr  x28, [x9, x27, lsl #3]         // distinct (keys, argument) record
    add  x27, x27, #1
    add  x0, x28, #GR_KEYS
    ldr  x1, [x21, #BQ_NGROUP]
    ldr  x2, [sp, #16]
    ldr  x2, [x2, #DSP_TYPES]
    bl   cells_hash
    mov  x1, x0
    ldr  x0, [sp, #8]
    add  x2, x28, #GR_KEYS
    mov  x3, #0
    bl   gt_get
    ldr  x9, [x23, x0, lsl #3]          // its group's state of this slot
    ldr  x10, [x21, #BQ_NGROUP]
    add  x9, x9, #GR_KEYS
    add  x9, x9, x10, lsl #4
    add  x1, x9, x25, lsl #5            // AGG_STATE_SIZE = 32
    add  x11, x28, #GR_KEYS
    lsl  x10, x10, #4
    ldr  x2, [x11, x10]
    mov  x0, x26
    bl   agg_accum
    b    3b
.Lvd_next:
    add  x25, x25, #1
    b    .Lvd_slot
.Lvd_end:
    add  sp, sp, #48
    LEAVE 5
ENDF vagg_distinct

// =============================================================================
// dagg_task(x0 task record) — the distinct (GROUP BY keys, argument) pairs
// of the tuples [XT_LO, XT_HI) with a non-NULL argument, into a key-only
// group table (XT_GT)
//   x19 task, x20 ctx, x21 spec, x22 ts, x23 table, x24 vb, x25 batch start,
//   x26 batch size, x27 keys, x28 key index
// Stack: [sp] key vectors (Vec* [keys], the argument last), [sp+16] ids
// =============================================================================
LFUNC dagg_task
    GUARD_TICK                          // CR-6: recursive
    ENTER 5
    sub  sp, sp, #32
    mov  x19, x0
    ldr  x20, [x19, #XT_CTX]
    ldr  x21, [x19, #DS_SPEC]
    ldr  x22, [x19, #XT_TS]
    ldr  x27, [x21, #DSP_NKEYS]
    mov  x0, x27
    mov  x1, #0
    ldr  x2, [x21, #DSP_TYPES]
    mov  x3, #0
    bl   gt_alloc
    mov  x23, x0
    str  x23, [x19, #XT_GT]
    mov  x0, x20
    ldr  x1, [x22, #TS_W]
    bl   vb_new
    mov  x24, x0
    lsl  x0, x27, #3
    bl   arena_alloc
    str  x0, [sp]
    mov  x28, #0
1:  cmp  x28, x27
    b.hs 2f
    mov  x0, x24
    bl   vpool_get
    ldr  x9, [sp]
    str  x0, [x9, x28, lsl #3]
    add  x28, x28, #1
    b    1b
2:  mov  x0, #(VBATCH * 4)             // group ids (unused)
    bl   arena_alloc
    str  x0, [sp, #16]
    ldr  x25, [x19, #XT_LO]
.Ldt_batch:
    ldr  x9, [x19, #XT_HI]
    cmp  x25, x9
    b.hs .Ldt_end
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
    mov  x28, #0                        // keys and argument as vectors
3:  cmp  x28, x27
    b.hs 5f
    sub  x9, x27, #1
    cmp  x28, x9
    b.ne 31f
    ldr  x0, [x21, #DSP_ARG]
    b    4f
31: ldr  x9, [x21, #DSP_BQ]
    ldr  x9, [x9, #BQ_GROUP]
    ldr  x0, [x9, x28, lsl #3]
4:  mov  x1, x24
    ADR_L x2, vsel_ident
    mov  x3, x26
    ldr  x9, [sp]
    ldr  x4, [x9, x28, lsl #3]
    bl   veval
    add  x28, x28, #1
    b    3b
5:  mov  x0, x23                        // pairs with a non-NULL argument
    ldr  x1, [sp]
    mov  x2, x26
    ldr  x3, [sp, #16]
    mov  x4, x25
    mov  x5, #1
    bl   gt_ids
.Ldt_next:
    add  x25, x25, x26
    b    .Ldt_batch
.Ldt_end:
    add  sp, sp, #32
    LEAVE 5
ENDF dagg_task

// =============================================================================
// gt_list(x0 GroupTable*) -> x0 record pointers (table order), x1 count
// =============================================================================
LFUNC gt_list
    ENTER 2
    mov  x19, x0
    ldr  x9, [x19, #GT_N]
    lsl  x0, x9, #3
    add  x0, x0, #8
    bl   arena_alloc
    ldr  x9, [x19, #GT_N]
    ldr  x10, [x19, #GT_RECS]
    ldr  x11, [x19, #GT_RECSZ]
    mov  x12, #0
1:  cmp  x12, x9
    b.hs 2f
    madd x13, x12, x11, x10
    str  x13, [x0, x12, lsl #3]
    add  x12, x12, #1
    b    1b
2:  mov  x1, x9
    LEAVE 2
ENDF gt_list

// =============================================================================
// gt_pmerge(x0 agg task records, x1 count T, x2 BoundQuery*, x3 ctx, x4 1 =
//           order by first appearance)
//   -> x0 group record pointers (in order of first appearance if x4 = 1),
//      x1 count
// Partitioned parallel merge of the partial tables: merge task p takes the
// groups whose hash falls into partition p from every partial table, in
// task order (so its first insertion of a key carries the key's earliest
// tuple), into its own table. Every partial table is first indexed by
// partition (part_task, in parallel), so a merge task reads only its own
// groups. On request the final groups are then put in order of their first
// tuple (a k-way merge of the merge tables); otherwise they come partition
// by partition.
//   x19 tasks, x20 T, x21 merge records, x22 index, x23 total, x24 list
// =============================================================================
LFUNC gt_pmerge
    ENTER 5
    mov  x19, x0
    mov  x20, x1
    mov  x25, x4
    stp  x2, x3, [sp, #-16]!
    mov  x9, #MT_SIZE
    mul  x0, x9, x20
    bl   arena_zalloc
    mov  x21, x0
    ldp  x2, x3, [sp], #16
    mov  x22, #0
1:  cmp  x22, x20
    b.hs 2f
    mov  x9, #MT_SIZE
    madd x9, x22, x9, x21
    mov  x10, #XT_SIZE                  // (MT_GT: partial table to index)
    madd x10, x22, x10, x19
    ldr  x10, [x10, #XT_GT]
    str  x10, [x9, #MT_GT]
    str  x19, [x9, #MT_TASKS]
    str  x20, [x9, #MT_T]
    str  x22, [x9, #MT_PART]
    str  x2, [x9, #MT_BQ]
    str  x3, [x9, #MT_CTX]
    add  x22, x22, #1
    b    1b
2:  ADR_L x0, part_task
    mov  x1, x21
    mov  x2, #MT_SIZE
    mov  x3, x20
    bl   par_run
    ADR_L x0, merge_task
    mov  x1, x21
    mov  x2, #MT_SIZE
    mov  x3, x20
    bl   par_run
    mov  x23, #0                        // all final groups
    mov  x22, #0
3:  cmp  x22, x20
    b.hs 4f
    mov  x9, #MT_SIZE
    madd x9, x22, x9, x21
    ldr  x9, [x9, #MT_GT]
    ldr  x9, [x9, #GT_N]
    add  x23, x23, x9
    add  x22, x22, #1
    b    3b
4:  lsl  x0, x23, #3
    add  x0, x0, #8
    bl   arena_alloc
    mov  x24, x0
    cbnz x25, .Lpm_kmerge
    mov  x14, #0                        // partition by partition
    mov  x22, #0
5:  cmp  x22, x20
    b.hs 7f
    mov  x9, #MT_SIZE
    madd x9, x22, x9, x21
    ldr  x9, [x9, #MT_GT]
    ldr  x10, [x9, #GT_N]
    ldr  x11, [x9, #GT_RECS]
    ldr  x12, [x9, #GT_RECSZ]
    mov  x13, #0
6:  cmp  x13, x10
    b.hs 61f
    madd x15, x13, x12, x11
    str  x15, [x24, x14, lsl #3]
    add  x14, x14, #1
    add  x13, x13, #1
    b    6b
61: add  x22, x22, #1
    b    5b
7:  mov  x0, x24
    mov  x1, x23
    LEAVE 5
    // In order of first appearance: every merge table created its groups
    // in increasing GR_FIRST order (it takes the partial tables in task
    // order, the windows of the tasks ascend, and a partial table holds its
    // groups in order of first appearance), so the order is a k-way merge
    // of the merge tables' record sequences: the GR_FIRST range is cut into
    // one slice per task, each table's records of a slice are found by
    // binary search, and the slices are merged in parallel (km_task) into
    // their places of the list.
.Lpm_kmerge:
    mov  x0, #KM_SIZE
    mul  x0, x0, x20
    bl   arena_zalloc
    mov  x26, x0                        // slice records
    add  x0, x20, #1                    // starts [T + 1][T]
    mul  x0, x0, x20
    lsl  x0, x0, #3
    bl   arena_alloc
    mov  x27, x0
    mov  x28, #0                        // largest GR_FIRST + 1: the end
    mov  x22, #0
1:  cmp  x22, x20
    b.hs 2f
    mov  x9, #MT_SIZE
    madd x9, x22, x9, x21
    ldr  x9, [x9, #MT_GT]
    ldr  x10, [x9, #GT_N]
    cbz  x10, 11f
    sub  x10, x10, #1
    ldr  x11, [x9, #GT_RECS]
    ldr  x12, [x9, #GT_RECSZ]
    madd x11, x10, x12, x11
    ldr  x11, [x11, #GR_FIRST]
    add  x11, x11, #1
    cmp  x11, x28
    csel x28, x11, x28, hi
11: add  x22, x22, #1
    b    1b
2:  mov  x22, #0                        // starts of slice k in every table
3:  cmp  x22, x20
    b.hi 6f
    mul  x13, x22, x28                  // slice boundary: k * end / T
    udiv x13, x13, x20
    mov  x14, #0                        // table
4:  cmp  x14, x20
    b.hs 5f
    mov  x9, #MT_SIZE
    madd x9, x14, x9, x21
    ldr  x9, [x9, #MT_GT]
    ldr  x15, [x9, #GT_RECS]
    ldr  x16, [x9, #GT_RECSZ]
    mov  x10, #0                        // first record with GR_FIRST >= it
    ldr  x11, [x9, #GT_N]
41: cmp  x10, x11
    b.hs 42f
    add  x12, x10, x11
    lsr  x12, x12, #1
    madd x17, x12, x16, x15
    ldr  x17, [x17, #GR_FIRST]
    cmp  x17, x13
    b.hs 43f
    add  x10, x12, #1
    b    41b
43: mov  x11, x12
    b    41b
42: madd x12, x22, x20, x14
    str  x10, [x27, x12, lsl #3]
    add  x14, x14, #1
    b    4b
5:  add  x22, x22, #1
    b    3b
6:  mov  x22, #0                        // slice records; output offsets
    mov  x15, #0
7:  cmp  x22, x20
    b.hs 8f
    mov  x9, #KM_SIZE
    madd x9, x22, x9, x26
    str  x21, [x9, #KM_MT]
    str  x20, [x9, #KM_T]
    mul  x10, x22, x20
    add  x10, x27, x10, lsl #3
    str  x10, [x9, #KM_FROM]
    add  x11, x10, x20, lsl #3
    str  x11, [x9, #KM_TO]
    add  x12, x24, x15, lsl #3
    str  x12, [x9, #KM_OUT]
    mov  x13, #0                        // slice size
71: cmp  x13, x20
    b.hs 72f
    ldr  x14, [x11, x13, lsl #3]
    ldr  x16, [x10, x13, lsl #3]
    sub  x14, x14, x16
    add  x15, x15, x14
    add  x13, x13, #1
    b    71b
72: add  x22, x22, #1
    b    7b
8:  ADR_L x0, km_task
    mov  x1, x26
    mov  x2, #KM_SIZE
    mov  x3, x20
    bl   par_run
    b    9f
9:  mov  x0, x24
    mov  x1, x23
    LEAVE 5
ENDF gt_pmerge

// km_task(x0 slice record): k-way merge of the slice's records of every
// merge table (each ascending by GR_FIRST) into KM_OUT
//   x19 record, x20 tables, x21 heads (GR_FIRST, -1 = done) [T], x22
//   cursors [T], x23 ends, x24 output, x25 table index, x26 T
LFUNC km_task
    ENTER 5
    mov  x19, x0
    ldr  x20, [x19, #KM_MT]
    ldr  x26, [x19, #KM_T]
    ldr  x23, [x19, #KM_TO]
    ldr  x24, [x19, #KM_OUT]
    lsl  x0, x26, #4
    bl   arena_alloc
    mov  x21, x0
    add  x22, x21, x26, lsl #3
    ldr  x9, [x19, #KM_FROM]
    mov  x25, #0
1:  cmp  x25, x26
    b.hs 2f
    ldr  x10, [x9, x25, lsl #3]
    str  x10, [x22, x25, lsl #3]
    mov  x0, x25
    bl   .Lkm_head
    ldr  x9, [x19, #KM_FROM]
    add  x25, x25, #1
    b    1b
2:  mov  x12, #-1                       // the smallest head
    mov  x13, #0
    mov  x25, #0
3:  ldr  x14, [x21, x25, lsl #3]
    cmp  x14, x12
    csel x12, x14, x12, lo
    csel x13, x25, x13, lo
    add  x25, x25, #1
    cmp  x25, x26
    b.lo 3b
    cmn  x12, #1
    b.eq 9f                             // every table done
    mov  x9, #MT_SIZE                   // its record goes next
    madd x9, x13, x9, x20
    ldr  x9, [x9, #MT_GT]
    ldr  x11, [x22, x13, lsl #3]
    ldr  x14, [x9, #GT_RECS]
    ldr  x15, [x9, #GT_RECSZ]
    madd x14, x11, x15, x14
    str  x14, [x24], #8
    add  x11, x11, #1
    str  x11, [x22, x13, lsl #3]
    mov  x0, x13
    bl   .Lkm_head
    b    2b
9:  LEAVE 5

// local helper: heads[x0] = GR_FIRST of table x0's record at its cursor,
// or -1 at the slice's end (clobbers x9-x15)
.Lkm_head:
    mov  x9, #MT_SIZE
    madd x9, x0, x9, x20
    ldr  x9, [x9, #MT_GT]
    ldr  x11, [x22, x0, lsl #3]
    ldr  x12, [x23, x0, lsl #3]
    mov  x15, #-1
    cmp  x11, x12
    b.hs 1f
    ldr  x13, [x9, #GT_RECS]
    ldr  x14, [x9, #GT_RECSZ]
    madd x13, x11, x14, x13
    ldr  x15, [x13, #GR_FIRST]
1:  str  x15, [x21, x0, lsl #3]
    ret
ENDF km_task

// part_task(x0 merge record): indexes the partial table at MT_GT by merge
// partition, (hash >> 32) mod MT_T: GT_PSTART / GT_PIDX (counting sort,
// record order kept within a partition)
//   x19 record, x20 table, x21 partitions, x22 counts / starts, x23 index,
//   x24 cursors
LFUNC part_task
    ENTER 4
    mov  x19, x0
    ldr  x20, [x19, #MT_GT]
    ldr  x21, [x19, #MT_T]
    add  x0, x21, #2
    lsl  x0, x0, #3
    bl   arena_zalloc
    mov  x22, x0
    str  x22, [x20, #GT_PSTART]
    lsl  x0, x21, #3
    add  x0, x0, #8
    bl   arena_alloc
    mov  x24, x0
    ldr  x9, [x20, #GT_N]
    lsl  x0, x9, #2
    add  x0, x0, #4
    bl   arena_alloc
    str  x0, [x20, #GT_PIDX]
    ldr  x10, [x20, #GT_RECS]           // counts (at p + 1)
    ldr  x11, [x20, #GT_RECSZ]
    ldr  x12, [x20, #GT_N]
    mov  x23, #0
1:  cmp  x23, x12
    b.hs 2f
    madd x13, x23, x11, x10
    ldr  x9, [x13, #GR_HASH]
    lsr  x9, x9, #32
    udiv x13, x9, x21
    msub x9, x13, x21, x9
    add  x9, x9, #1
    ldr  x13, [x22, x9, lsl #3]
    add  x13, x13, #1
    str  x13, [x22, x9, lsl #3]
    add  x23, x23, #1
    b    1b
2:  mov  x9, #0                         // starts; cursors
3:  cmp  x9, x21
    b.hs 4f
    ldr  x13, [x22, x9, lsl #3]
    add  x14, x9, #1
    ldr  x15, [x22, x14, lsl #3]
    add  x15, x15, x13
    str  x15, [x22, x14, lsl #3]
    str  x13, [x24, x9, lsl #3]
    mov  x9, x14
    b    3b
4:  mov  x23, #0                        // record indexes by partition
5:  cmp  x23, x12
    b.hs 6f
    madd x13, x23, x11, x10
    ldr  x9, [x13, #GR_HASH]
    lsr  x9, x9, #32
    udiv x13, x9, x21
    msub x9, x13, x21, x9
    ldr  x13, [x24, x9, lsl #3]
    add  x14, x13, #1
    str  x14, [x24, x9, lsl #3]
    str  w23, [x0, x13, lsl #2]
    add  x23, x23, #1
    b    5b
6:  LEAVE 4
ENDF part_task

// merge_task(x0 merge record): partition MT_PART of every partial table
//   x19 record, x20 table, x21 task index, x22 group, x23 source record,
//   x24 partitions
LFUNC merge_task
    ENTER 5
    mov  x19, x0
    ldr  x24, [x19, #MT_T]
    ldr  x9, [x19, #MT_TASKS]           // same key layout as the partial
    ldr  x9, [x9, #XT_GT]               // tables, sized for the groups of
    ldr  x0, [x9, #GT_NKEYS]            // this partition in all of them
    ldr  x1, [x9, #GT_NAGG]
    ldr  x2, [x9, #GT_TYPES]
    mov  x3, #0
    mov  x10, #0
0:  cmp  x10, x24
    b.hs 6f
    ldr  x11, [x19, #MT_TASKS]
    mov  x12, #XT_SIZE
    madd x11, x10, x12, x11
    ldr  x11, [x11, #XT_GT]
    ldr  x11, [x11, #GT_PSTART]
    ldr  x12, [x19, #MT_PART]
    add  x12, x11, x12, lsl #3
    ldp  x13, x14, [x12]
    sub  x14, x14, x13
    add  x3, x3, x14
    add  x10, x10, #1
    b    0b
6:  bl   gt_alloc
    mov  x20, x0
    str  x20, [x19, #MT_GT]
    mov  x21, #0
1:  cmp  x21, x24
    b.hs 9f
    bl   check_deadline
    ldr  x9, [x19, #MT_TASKS]
    mov  x10, #XT_SIZE
    madd x9, x21, x10, x9
    ldr  x25, [x9, #XT_GT]              // source table
    ldr  x9, [x25, #GT_PSTART]          // its groups of this partition
    ldr  x10, [x19, #MT_PART]
    ldr  x22, [x9, x10, lsl #3]
2:  ldr  x9, [x25, #GT_PSTART]
    ldr  x10, [x19, #MT_PART]
    add  x10, x10, #1
    ldr  x9, [x9, x10, lsl #3]
    cmp  x22, x9
    b.hs 4f
    ldr  x9, [x25, #GT_PIDX]
    ldr  w9, [x9, x22, lsl #2]
    ldr  x10, [x25, #GT_RECS]
    ldr  x11, [x25, #GT_RECSZ]
    madd x23, x9, x11, x10
    add  x22, x22, #1
    mov  x0, x20
    ldr  x1, [x23, #GR_HASH]
    add  x2, x23, #GR_KEYS
    ldr  x3, [x23, #GR_FIRST]
    bl   gt_get
    ldr  x10, [x20, #GT_RECS]           // destination states
    ldr  x11, [x20, #GT_RECSZ]
    madd x10, x0, x11, x10
    ldr  x12, [x20, #GT_NKEYS]
    add  x10, x10, #GR_KEYS
    add  x1, x10, x12, lsl #4
    add  x2, x23, #GR_KEYS              // source states
    add  x2, x2, x12, lsl #4
    ldr  x9, [x20, #GT_NAGG]
    cbz  x9, 2b                         // DISTINCT: keys only
    ldr  x0, [x19, #MT_BQ]
    bl   merge_states
    b    2b
4:  add  x21, x21, #1
    b    1b
9:  LEAVE 5
ENDF merge_task

// =============================================================================
// emit_groups(x0 Aggregate node, x1 ctx, x2 input ts, x3 group records,
//             x4 count) -> x0 ResultSet*
// Finishes every group (agg_finish), applies HAVING and projects its row, in
// group order. Large results are emitted by parallel tasks writing disjoint
// windows of the row array, compacted afterwards.
//   x19 node, x20 ctx, x21 bq, x22 tasks, x23 records, x24 rs, x25 index,
//   x26 window, x27 rows kept
// =============================================================================
LFUNC emit_groups
    GUARD_TICK                          // CR-6: recursive
    ENTER 5
    sub  sp, sp, #32
    mov  x19, x0
    mov  x20, x1
    ldr  x21, [x19, #PN_BQ]
    stp  x2, x3, [sp]
    str  x4, [sp, #16]
    mov  x0, x21
    add  x1, x4, #1
    bl   rs_new
    mov  x24, x0
    mov  x22, #1                        // tasks: >= g_par_min_rows / 4 groups
    TLS_LDR x9, g_x_threads
    cmp  x9, #1
    b.ls 1f
    LDR_G x10, g_par_min_rows
    lsr  x10, x10, #2
    cmp  x10, #1
    csinc x10, x10, xzr, hs
    ldr  x11, [sp, #16]
    udiv x10, x11, x10
    cmp  x10, x9
    csel x10, x10, x9, lo
    cmp  x10, #2
    b.lo 1f
    str  x10, [sp, #24]
    mov  x0, x21
    bl   bq_out_par_safe
    cbz  w0, 1f
    ldr  x0, [x19, #PN_EXPR]
    bl   expr_par_safe
    cbz  w0, 1f
    ldr  x22, [sp, #24]
1:  mov  x9, #ET_SIZE
    mul  x0, x9, x22
    bl   arena_alloc
    mov  x23, x0
    ldr  x9, [sp, #16]                  // window: ceil(n / tasks)
    add  x26, x9, x22
    sub  x26, x26, #1
    udiv x26, x26, x22
    mov  x25, #0
2:  cmp  x25, x22
    b.hs 4f
    mov  x9, #ET_SIZE
    madd x27, x25, x9, x23
    str  x19, [x27, #ET_NODE]
    str  x20, [x27, #ET_CTX]
    ldp  x9, x10, [sp]
    str  x9, [x27, #ET_TS]
    str  x10, [x27, #ET_GROUPS]
    ldr  x11, [sp, #16]
    mul  x12, x25, x26
    cmp  x12, x11
    csel x12, x12, x11, lo
    str  x12, [x27, #ET_LO]
    ldr  x13, [x24, #RS_ROWS]
    add  x13, x13, x12, lsl #3
    str  x13, [x27, #ET_OUT]
    add  x12, x12, x26
    cmp  x12, x11
    csel x12, x12, x11, lo
    str  x12, [x27, #ET_HI]
    str  xzr, [x27, #ET_COUNT]
    cmp  x22, #1
    b.eq 3f
    mov  x0, #EC_SIZE                   // worker tasks: own contexts
    bl   arena_alloc
    ldp  x12, x13, [x20]
    stp  x12, x13, [x0]
    ldp  x12, x13, [x20, #16]
    stp  x12, x13, [x0, #16]
    ldp  x12, x13, [x20, #32]
    stp  x12, x13, [x0, #32]
    str  x0, [x27, #ET_CTX]
3:  add  x25, x25, #1
    b    2b
4:  cmp  x22, #1
    b.ne 5f
    mov  x0, x23
    bl   emit_task
    b    6f
5:  ADR_L x0, emit_task
    mov  x1, x23
    mov  x2, #ET_SIZE
    mov  x3, x22
    bl   par_run
6:  mov  x27, #0                        // compact the windows in order
    mov  x25, #0
7:  cmp  x25, x22
    b.hs 8f
    mov  x9, #ET_SIZE
    madd x9, x25, x9, x23
    ldr  x2, [x9, #ET_COUNT]
    ldr  x1, [x9, #ET_OUT]
    ldr  x0, [x24, #RS_ROWS]
    add  x0, x0, x27, lsl #3
    add  x27, x27, x2
    lsl  x2, x2, #3
    bl   memmove
    add  x25, x25, #1
    b    7b
8:  str  x27, [x24, #RS_NROWS]
    mov  x0, x24
    add  sp, sp, #32
    LEAVE 5
ENDF emit_groups

// emit_task(x0 emit record): groups [lo, hi) -> rows at ET_OUT, ET_COUNT
//   x19 record, x20 ctx, x21 bq, x22 index, x23 group record, x24 rows kept,
//   x25 node
LFUNC emit_task
    GUARD_TICK                          // CR-6: recursive
    ENTER 5
    mov  x19, x0
    ldr  x20, [x19, #ET_CTX]
    ldr  x25, [x19, #ET_NODE]
    ldr  x21, [x25, #PN_BQ]
    mov  x24, #0
    ldr  x22, [x19, #ET_LO]
1:  ldr  x9, [x19, #ET_HI]
    cmp  x22, x9
    b.hs 9f
    tst  x22, #0xfff
    b.ne 2f
    bl   check_deadline
2:  ldr  x9, [x19, #ET_GROUPS]
    ldr  x23, [x9, x22, lsl #3]
    add  x22, x22, #1
    ldr  x9, [x21, #BQ_NGROUP]
    add  x1, x23, #GR_KEYS
    add  x1, x1, x9, lsl #4             // states
    mov  x0, x21
    bl   agg_finish
    str  x0, [x20, #EC_AGGV]
    add  x9, x23, #GR_KEYS
    str  x9, [x20, #EC_GKEYS]
    ldr  x0, [x19, #ET_TS]
    ldr  x1, [x23, #GR_FIRST]
    bl   ts_tuple
    str  x0, [x20, #EC_TUPLE]
    ldr  x0, [x25, #PN_EXPR]            // HAVING
    cbz  x0, 3f
    mov  x1, x20
    bl   eval_true
    cbz  w0, 1b
3:  ldr  x9, [x21, #BQ_NOUT]
    ldr  x10, [x21, #BQ_NEXTRA]
    add  x9, x9, x10
    lsl  x0, x9, #4
    add  x0, x0, #16
    bl   arena_alloc
    ldr  x9, [x19, #ET_OUT]
    str  x0, [x9, x24, lsl #3]
    add  x24, x24, #1
    mov  x2, x0
    mov  x0, x21
    mov  x1, x20
    bl   project_row
    b    1b
9:  str  x24, [x19, #ET_COUNT]
    LEAVE 5
ENDF emit_task

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
    ldp  x11, x12, [x20, #AS_LO]        // COUNT / SUM / AVG (192 bits; the
    ldp  x13, x14, [x21, #AS_LO]        // top word matters for wide sums)
    ldr  x15, [x20, #AS_TOP]
    ldr  x16, [x21, #AS_TOP]
    adds x11, x11, x13
    adcs x12, x12, x14
    adc  x15, x15, x16
    stp  x11, x12, [x20, #AS_LO]
    str  x15, [x20, #AS_TOP]
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
