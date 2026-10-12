// =============================================================================
// sort.S — sorting of result rows by normalized keys (Phase 5, modes and
// option "threads").
//
//   sort_rows_par(x0 Row** rows, x1 n, x2 key descriptors, x3 unused)
//       sorts like exec.S sort_rows (qsort_r with cmp_rows; mode "row" and
//       small inputs). In vectorized mode: rsort_rows.
//
// rsort_rows — normalized-key radix sort:
//   1. Field selection: the key list (ORDER BY keys, then every visible
//      column as a tie-breaker, exec.S order_keys) is walked in order; each
//      cell is encoded once (a later key on the same cell can never decide).
//      At most RX_MAXF fields; selection stops before a second STRING / wide
//      DECIMAL key. Keys left over make the encoding "tail inexact".
//   2. Encode (parallel over row windows): per field and row a 64-bit code
//      whose unsigned order is the key order (integer-like payloads biased,
//      FLOAT64 sign-folded with -0.0 = 0.0, STRING: the first 7 bytes
//      big-endian and min(length, 8) in the low byte, wide DECIMAL: the high
//      word; inverted for DESC), a NULL flag, and the per-window minimum /
//      maximum code. A STRING of 8 or more bytes (any wide DECIMAL) is
//      "inexact": equal codes do not imply equal values.
//   3. Layout (serial): each field gets 1 NULL bit (only if it has NULLs,
//      ordered by NULLS FIRST / LAST) and just enough bits for max - min.
//      The fields are packed most significant first into a composite key of
//      at most RX_MAXW words; fields that do not fit are dropped (tail
//      inexact).
//   4. Pack (parallel): element = composite key words + row index (bit 63:
//      the row is inexact), plus a histogram of the top D0 <= 11 key bits.
//   5. Scatter (parallel, stable) by the top D0 bits; the buckets are dealt
//      to tasks in contiguous groups of about n / tasks elements, and every
//      bucket is sorted by MSD radix on the following bits (8 per level,
//      insertion sort below RX_SMALL elements), mostly in cache.
//   6. Gather (parallel): the rows in element order.
//   7. Fix-up (serial): rows whose composite keys tie only because of an
//      inexact STRING prefix (equal up to the end of that field) or of
//      dropped keys (equal composite) are sorted by the full comparator.
// The result is the comparator's order (cmp_rows); only rows equal on every
// key, i.e. identical in every visible column, may come out in any order.
// =============================================================================
#include "pq.inc"
#include "frame.inc"

#define SK_OFF      0               // exec.S key descriptor
#define SK_TYPE     8
#define SK_DESC     12
#define SK_NFIRST   16
#define SK_SIZE     24

#define RX_MAXF     8               // encoded fields at most
#define RX_MAXW     3               // composite key words at most
#define RX_MINN     256             // smaller inputs: comparator sort
#define RX_SMALL    24              // insertion sort below this many elements
#define RX_D0MAX    11              // top-level digit bits

// field kinds
#define FK_INT      0               // BOOL, INT64, narrow DECIMAL, DATE, TS
#define FK_FLOAT    1
#define FK_STR      2
#define FK_WIDE     3

// Field descriptor
#define FD_OFF      0               // u64 cell offset in the row
#define FD_DESC     8               // u32
#define FD_NFIRST   12              // u32
#define FD_KIND     16              // u32 FK_*
#define FD_NBIT     20              // u32 1 = a NULL bit precedes the value
#define FD_VBITS    24              // u64 value bits
#define FD_MIN      32              // u64 smallest non-NULL code
#define FD_END      40              // u64 composite bit offset after the field
#define FD_SIZE     48

// Sort state (shared by the tasks)
#define RX_ROWS     0               // Row** input order (a copy while gathering)
#define RX_N        8
#define RX_NF       16              // fields encoded / used
#define RX_FIELDS   24              // FD [RX_MAXF]
#define RX_CODES    32              // u64 [nf][n]
#define RX_NULLS    40              // u8 [nf][n]
#define RX_INEX     48              // u8 [n] inexact rows
#define RX_INEXF    56              // field that may be inexact, or -1
#define RX_W        64              // composite key words
#define RX_E        72              // element bytes ((W + 1) * 8)
#define RX_TBITS    80              // composite key bits
#define RX_D0       88              // top-level digit bits
#define RX_ELEM     96              // elements
#define RX_TMP      104             // elements, scattered / sorted
#define RX_BSTART   112             // u64 bucket starts [2^D0 + 1]
#define RX_OUT      120             // Row** sorted rows (the caller's array)
#define RX_SIZE     128

// Task record
#define RT_RX       0
#define RT_LO       8               // window [lo, hi) (rows / elements)
#define RT_HI       16
#define RT_MIN      24              // u64* [nf] window minimum codes
#define RT_MAX      32              // u64* [nf] window maximum codes
#define RT_NULLM    40              // u64 bit f: field f has a NULL
#define RT_INEXA    48              // u64 1: an inexact row
#define RT_HIST     56              // u64* [2^D0] counts, then offsets
#define RT_B0       64              // buckets [b0, b1) (sort phase)
#define RT_B1       72
#define RT_SIZE     80

    .text

// =============================================================================
// sort_rows_par(x0 rows, x1 n, x2 keys, x3 unused)
// =============================================================================
FUNC sort_rows_par
    TLS_ADDR x9, g_x_mode
    ldr  w9, [x9]
    cmp  w9, #XM_ROW
    b.eq 1f
    cmp  x1, #RX_MINN
    b.lo 1f
    b    rsort_rows                     // tail call
1:  b    sort_rows                      // row mode / small: qsort_r
ENDF sort_rows_par

// =============================================================================
// rsort_rows(x0 Row** rows, x1 n, x2 keys)
//   x19 rows, x20 n, x21 keys, x22 rx, x23 task records, x24 tasks,
//   x25 index, x26 scratch, x27 scratch, x28 fields
// =============================================================================
LFUNC rsort_rows
    ENTER 5
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x0, #RX_SIZE
    bl   arena_zalloc
    mov  x22, x0
    stp  x19, x20, [x22, #RX_ROWS]
    str  x19, [x22, #RX_OUT]
    mov  x0, #(FD_SIZE * RX_MAXF)
    bl   arena_zalloc
    mov  x28, x0
    str  x28, [x22, #RX_FIELDS]
    // ---- 1. fields ---------------------------------------------------------
    mov  x9, #-1
    str  x9, [x22, #RX_INEXF]
    mov  x26, #0                        // tail inexact
    mov  x27, #0                        // fields
    mov  x25, #0                        // key
.Lrs_key:
    ldr  x9, [x21]
    cmp  x25, x9
    b.hs .Lrs_keys_done
    mov  x9, #SK_SIZE
    madd x10, x25, x9, x21
    add  x10, x10, #8                   // descriptor
    add  x25, x25, #1
    ldr  x11, [x10, #SK_OFF]
    mov  x12, #0                        // same cell as a field: skip
1:  cmp  x12, x27
    b.hs 2f
    mov  x13, #FD_SIZE
    madd x13, x12, x13, x28
    ldr  x13, [x13, #FD_OFF]
    cmp  x13, x11
    b.eq .Lrs_key
    add  x12, x12, #1
    b    1b
2:  cmp  x27, #RX_MAXF
    b.hs .Lrs_tail
    ldr  w12, [x10, #SK_TYPE]
    mov  w13, #FK_WIDE
    BR_WIDE w12, w14, 3f
    and  w12, w12, #T_KIND_MASK
    mov  w13, #FK_FLOAT
    cmp  w12, #T_FLOAT
    b.eq 4f
    mov  w13, #FK_INT
    cmp  w12, #T_STR
    b.ne 4f
    mov  w13, #FK_STR
3:  ldr  x14, [x22, #RX_INEXF]          // STRING / wide: the first only
    tbz  x14, #63, .Lrs_tail
    str  x27, [x22, #RX_INEXF]
4:  mov  x14, #FD_SIZE
    madd x14, x27, x14, x28
    str  x11, [x14, #FD_OFF]
    ldr  w12, [x10, #SK_DESC]
    str  w12, [x14, #FD_DESC]
    ldr  w12, [x10, #SK_NFIRST]
    str  w12, [x14, #FD_NFIRST]
    str  w13, [x14, #FD_KIND]
    add  x27, x27, #1
    b    .Lrs_key
.Lrs_tail:
    mov  x26, #1
.Lrs_keys_done:
    str  x27, [x22, #RX_NF]
    str  x26, [sp, #-16]!               // [sp] tail inexact
    // ---- buffers -----------------------------------------------------------
    mul  x0, x27, x20                   // codes
    lsl  x0, x0, #3
    add  x0, x0, #8
    bl   arena_alloc
    str  x0, [x22, #RX_CODES]
    mul  x0, x27, x20                   // NULL flags
    add  x0, x0, #8
    bl   arena_alloc
    str  x0, [x22, #RX_NULLS]
    add  x0, x20, #8                    // inexact rows
    bl   arena_alloc
    str  x0, [x22, #RX_INEX]
    // ---- tasks: threads, at most one per g_par_min_rows rows ---------------
    mov  x24, #1
    TLS_LDR x9, g_x_threads
    cmp  x9, #1
    b.ls 1f
    LDR_G x10, g_par_min_rows
    udiv x10, x20, x10
    cmp  x10, x9
    csel x10, x10, x9, lo
    cmp  x10, #2
    csel x24, x10, x24, hs
1:  mov  x9, #RT_SIZE
    mul  x0, x9, x24
    bl   arena_zalloc
    mov  x23, x0
    add  x9, x20, x24                   // window: ceil(n / tasks)
    sub  x9, x9, #1
    udiv x26, x9, x24
    mov  x25, #0
2:  cmp  x25, x24
    b.hs 3f
    mov  x9, #RT_SIZE
    madd x27, x25, x9, x23
    str  x22, [x27, #RT_RX]
    mul  x9, x25, x26
    cmp  x9, x20
    csel x9, x9, x20, lo
    str  x9, [x27, #RT_LO]
    add  x9, x9, x26
    cmp  x9, x20
    csel x9, x9, x20, lo
    str  x9, [x27, #RT_HI]
    ldr  x0, [x22, #RX_NF]
    lsl  x0, x0, #4
    add  x0, x0, #16
    bl   arena_alloc
    str  x0, [x27, #RT_MIN]
    ldr  x9, [x22, #RX_NF]
    add  x0, x0, x9, lsl #3
    str  x0, [x27, #RT_MAX]
    add  x25, x25, #1
    b    2b
    // ---- 2. encode ---------------------------------------------------------
3:  ADR_L x0, rx_encode_task
    bl   .Lrs_run
    // ---- 3. layout ---------------------------------------------------------
    mov  x26, #0                        // NULL mask
    mov  x27, #0                        // any inexact row
    mov  x25, #0
1:  cmp  x25, x24
    b.hs 2f
    mov  x9, #RT_SIZE
    madd x9, x25, x9, x23
    ldr  x10, [x9, #RT_NULLM]
    orr  x26, x26, x10
    ldr  x10, [x9, #RT_INEXA]
    orr  x27, x27, x10
    add  x25, x25, #1
    b    1b
2:  str  x27, [sp, #8]                  // [sp+8] any inexact row
    mov  x15, #0                        // bit cursor
    mov  x25, #0                        // field
.Lrs_lay:
    ldr  x9, [x22, #RX_NF]
    cmp  x25, x9
    b.hs .Lrs_lay_done
    mov  x10, #-1                       // min / max over the windows
    mov  x11, #0
    mov  x12, #0
1:  cmp  x12, x24
    b.hs 2f
    mov  x9, #RT_SIZE
    madd x9, x12, x9, x23
    ldr  x13, [x9, #RT_MIN]
    ldr  x13, [x13, x25, lsl #3]
    cmp  x13, x10
    csel x10, x13, x10, lo
    ldr  x13, [x9, #RT_MAX]
    ldr  x13, [x13, x25, lsl #3]
    cmp  x13, x11
    csel x11, x13, x11, hi
    add  x12, x12, #1
    b    1b
2:  mov  x14, #0                        // value bits
    cmp  x10, x11
    b.ls 3f
    mov  x10, #0                        // only NULLs
    b    4f
3:  sub  x13, x11, x10
    clz  x13, x13
    mov  x14, #64
    sub  x14, x14, x13
4:  lsr  x13, x26, x25                  // NULL bit
    and  x13, x13, #1
    add  x12, x13, x14
    add  x12, x12, x15
    cmp  x12, #(64 * RX_MAXW)
    b.hi .Lrs_lay_drop
    mov  x9, #FD_SIZE
    madd x9, x25, x9, x28
    str  w13, [x9, #FD_NBIT]
    str  x14, [x9, #FD_VBITS]
    str  x10, [x9, #FD_MIN]
    str  x12, [x9, #FD_END]
    mov  x15, x12
    add  x25, x25, #1
    b    .Lrs_lay
.Lrs_lay_drop:                          // the rest does not fit
    str  x25, [x22, #RX_NF]
    mov  x9, #1
    str  x9, [sp]
    ldr  x9, [x22, #RX_INEXF]
    cmp  x9, x25
    b.lo .Lrs_lay_done
    mov  x9, #-1
    str  x9, [x22, #RX_INEXF]
.Lrs_lay_done:
    str  x15, [x22, #RX_TBITS]
    add  x9, x15, #63                   // words: ceil(bits / 64), >= 1
    lsr  x9, x9, #6
    cmp  x9, #1
    csinc x9, x9, xzr, hs
    str  x9, [x22, #RX_W]
    add  x10, x9, #1
    lsl  x10, x10, #3
    str  x10, [x22, #RX_E]
    cmp  x15, #RX_D0MAX
    mov  x9, #RX_D0MAX
    csel x9, x15, x9, lo
    str  x9, [x22, #RX_D0]
    // ---- 4. pack -----------------------------------------------------------
    ldr  x9, [x22, #RX_E]
    mul  x0, x9, x20
    bl   arena_alloc
    str  x0, [x22, #RX_ELEM]
    ldr  x9, [x22, #RX_E]
    mul  x0, x9, x20
    bl   arena_alloc
    str  x0, [x22, #RX_TMP]
    ldr  x9, [x22, #RX_D0]
    mov  x10, #8
    lsl  x26, x10, x9                   // histogram bytes
    mov  x25, #0
1:  cmp  x25, x24
    b.hs 2f
    mov  x0, x26
    bl   arena_zalloc
    mov  x9, #RT_SIZE
    madd x9, x25, x9, x23
    str  x0, [x9, #RT_HIST]
    add  x25, x25, #1
    b    1b
2:  ADR_L x0, rx_pack_task
    bl   .Lrs_run
    // ---- 5. scatter by the top bits, sort the buckets ----------------------
    ldr  x9, [x22, #RX_D0]
    mov  x10, #1
    lsl  x26, x10, x9                   // buckets
    add  x0, x26, #1
    lsl  x0, x0, #3
    bl   arena_alloc
    str  x0, [x22, #RX_BSTART]
    mov  x10, #0                        // offsets: bucket-major, task order
    mov  x25, #0
1:  cmp  x25, x26
    b.hs 3f
    str  x10, [x0, x25, lsl #3]
    mov  x11, #0
2:  cmp  x11, x24
    b.hs 21f
    mov  x9, #RT_SIZE
    madd x9, x11, x9, x23
    ldr  x9, [x9, #RT_HIST]
    ldr  x12, [x9, x25, lsl #3]
    str  x10, [x9, x25, lsl #3]
    add  x10, x10, x12
    add  x11, x11, #1
    b    2b
21: add  x25, x25, #1
    b    1b
3:  str  x10, [x0, x26, lsl #3]
    ADR_L x0, rx_scatter_task
    bl   .Lrs_run
    ldr  x0, [x22, #RX_BSTART]          // bucket groups of ~ n / tasks
    add  x9, x20, x24
    sub  x9, x9, #1
    udiv x9, x9, x24                    // target per task
    mov  x10, #0                        // bucket
    mov  x11, #0                        // task
4:  cmp  x11, x24
    b.hs 6f
    mov  x12, #RT_SIZE
    madd x12, x11, x12, x23
    str  x10, [x12, #RT_B0]
    add  x13, x11, #1                   // end: first bucket starting at or
    mul  x13, x13, x9                   // after (task + 1) * target
5:  cmp  x10, x26
    b.hs 51f
    ldr  x14, [x0, x10, lsl #3]
    cmp  x14, x13
    b.hs 51f
    add  x10, x10, #1
    b    5b
51: add  x14, x11, #1                   // the last task takes the rest
    cmp  x14, x24
    csel x10, x26, x10, eq
    str  x10, [x12, #RT_B1]
    add  x11, x11, #1
    b    4b
6:  ADR_L x0, rx_bucket_task
    bl   .Lrs_run
    // ---- 6. gather ---------------------------------------------------------
    lsl  x0, x20, #3
    bl   arena_alloc
    str  x0, [x22, #RX_ROWS]
    mov  x1, x19
    lsl  x2, x20, #3
    bl   memcpy
    ADR_L x0, rx_gather_task
    bl   .Lrs_run
    // ---- 7. fix-up ---------------------------------------------------------
    ldp  x9, x10, [sp]                  // tail inexact, any inexact row
    ldr  x11, [x22, #RX_INEXF]
    tbz  x11, #63, 1f
    mov  x10, #0                        // no inexact field left
1:  orr  x9, x9, x10
    cbz  x9, .Lrs_ret
    mov  x0, x22
    mov  x1, x21
    ldr  x2, [sp]
    bl   rx_fixup
.Lrs_ret:
    add  sp, sp, #16
    LEAVE 5

// local helper: runs task function x0 over the x24 task records at x23
// (serially when there is one task)
.Lrs_run:
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    cmp  x24, #1
    b.ne 1f
    mov  x9, x0
    mov  x0, x23
    blr  x9
    b    2f
1:  mov  x1, x23
    mov  x2, #RT_SIZE
    mov  x3, x24
    bl   par_run
2:  ldp  x29, x30, [sp], #16
    ret
ENDF rsort_rows

// =============================================================================
// rx_encode_task(x0 task) — codes, NULL flags, inexact flags and the window's
// min / max code per field for rows [lo, hi)
//   x19 task, x20 rx, x21 row index, x22 hi, x23 fields, x24 field count,
//   x25 field index, x26 row, x27 min array, x28 max array
// =============================================================================
LFUNC rx_encode_task
    ENTER 5
    mov  x19, x0
    ldr  x20, [x19, #RT_RX]
    ldp  x21, x22, [x19, #RT_LO]
    ldr  x23, [x20, #RX_FIELDS]
    ldr  x24, [x20, #RX_NF]
    ldp  x27, x28, [x19, #RT_MIN]
    mov  x9, #0
1:  cmp  x9, x24
    b.hs .Lre_row
    mov  x10, #-1
    str  x10, [x27, x9, lsl #3]
    str  xzr, [x28, x9, lsl #3]
    add  x9, x9, #1
    b    1b
.Lre_row:
    cmp  x21, x22
    b.hs .Lre_end
    tst  x21, #0xffff
    b.ne 1f
    bl   check_deadline
1:  ldr  x9, [x20, #RX_ROWS]
    ldr  x26, [x9, x21, lsl #3]
    ldr  x9, [x20, #RX_INEX]
    strb wzr, [x9, x21]
    mov  x25, #0
.Lre_field:
    cmp  x25, x24
    b.hs .Lre_next
    mov  x9, #FD_SIZE
    madd x10, x25, x9, x23              // field
    ldr  x11, [x10, #FD_OFF]
    add  x11, x26, x11
    ldp  x0, x12, [x11]                 // payload, NULL
    ldr  x13, [x20, #RX_N]
    madd x13, x25, x13, x21             // f * n + i
    ldr  x14, [x20, #RX_NULLS]
    cmp  x12, #0
    cset w15, ne
    strb w15, [x14, x13]
    cbz  x12, 1f
    ldr  x14, [x20, #RX_CODES]          // NULL: code 0, field has NULLs
    str  xzr, [x14, x13, lsl #3]
    ldr  x15, [x19, #RT_NULLM]
    mov  x14, #1
    lsl  x14, x14, x25
    orr  x15, x15, x14
    str  x15, [x19, #RT_NULLM]
    b    .Lre_fnext
1:  ldr  w15, [x10, #FD_KIND]
    cmp  w15, #FK_FLOAT
    b.eq 2f
    cmp  w15, #FK_STR
    b.eq 3f
    cmp  w15, #FK_WIDE
    b.eq 6f
    eor  x0, x0, #0x8000000000000000    // signed -> unsigned order
    b    8f
2:  mov  x12, #0x8000000000000000       // FLOAT64: -0.0 = 0.0, then fold
    cmp  x0, x12
    csel x0, xzr, x0, eq
    tbz  x0, #63, 21f
    mvn  x0, x0                         // negative: invert everything
    b    8f
21: orr  x0, x0, x12                    // positive: set the sign bit
    b    8f
3:  ldr  x12, [x0, #STR_LEN]            // STRING
    add  x14, x0, #STR_DATA
    cmp  x12, #8
    b.lo 4f
    ldr  x0, [x14]                      // 7 bytes, length code 8: inexact
    rev  x0, x0
    and  x0, x0, #0xffffffffffffff00
    orr  x0, x0, #8
    b    7f
4:  mov  x0, x12                        // shorter: exact, length code
    mov  x15, #0
    mov  x11, #56
5:  cmp  x15, x12
    b.hs 8f
    ldrb w16, [x14, x15]
    lsl  x16, x16, x11
    orr  x0, x0, x16
    add  x15, x15, #1
    sub  x11, x11, #8
    b    5b
6:  ldr  x0, [x0, #8]                   // wide DECIMAL: high word, inexact
    eor  x0, x0, #0x8000000000000000
7:  ldr  x15, [x20, #RX_INEXF]          // inexact row (of the inexact field)
    cmp  x15, x25
    b.ne 8f
    ldr  x15, [x20, #RX_INEX]
    mov  w14, #1
    strb w14, [x15, x21]
    str  x14, [x19, #RT_INEXA]
8:  ldr  w15, [x10, #FD_DESC]
    cbz  w15, 9f
    mvn  x0, x0
9:  ldr  x14, [x20, #RX_CODES]
    str  x0, [x14, x13, lsl #3]
    ldr  x15, [x27, x25, lsl #3]
    cmp  x0, x15
    csel x15, x0, x15, lo
    str  x15, [x27, x25, lsl #3]
    ldr  x15, [x28, x25, lsl #3]
    cmp  x0, x15
    csel x15, x0, x15, hi
    str  x15, [x28, x25, lsl #3]
.Lre_fnext:
    add  x25, x25, #1
    b    .Lre_field
.Lre_next:
    add  x21, x21, #1
    b    .Lre_row
.Lre_end:
    LEAVE 5
ENDF rx_encode_task

// =============================================================================
// rx_pack_task(x0 task) — elements of rows [lo, hi) and the histogram of
// their top D0 key bits
//   x19 task, x20 rx, x21 row index, x22 hi, x23 fields, x24 field count,
//   x25 field index, x26 element, x27 words, x28 cursor
// =============================================================================
LFUNC rx_pack_task
    ENTER 5
    mov  x19, x0
    ldr  x20, [x19, #RT_RX]
    ldp  x21, x22, [x19, #RT_LO]
    ldr  x23, [x20, #RX_FIELDS]
    ldr  x24, [x20, #RX_NF]
    ldr  x27, [x20, #RX_W]
.Lpk_row:
    cmp  x21, x22
    b.hs .Lpk_end
    tst  x21, #0xffff
    b.ne 1f
    bl   check_deadline
1:  ldr  x9, [x20, #RX_ELEM]
    ldr  x10, [x20, #RX_E]
    madd x26, x21, x10, x9
    mov  x9, #0                         // key words
0:  str  xzr, [x26, x9, lsl #3]
    add  x9, x9, #1
    cmp  x9, x27
    b.lo 0b
    mov  x28, #0
    mov  x25, #0
.Lpk_field:
    cmp  x25, x24
    b.hs .Lpk_idx
    mov  x9, #FD_SIZE
    madd x7, x25, x9, x23               // field
    ldr  x9, [x20, #RX_N]
    madd x8, x25, x9, x21               // f * n + i
    ldr  x9, [x20, #RX_NULLS]
    ldrb w6, [x9, x8]                   // NULL?
    ldr  w9, [x7, #FD_NBIT]
    cbz  w9, 1f
    ldr  w9, [x7, #FD_NFIRST]           // NULL bit: NULLS FIRST -> NULL = 0
    eor  w0, w6, w9
    and  x0, x0, #1
    mov  x1, #1
    bl   .Lpk_append
1:  ldr  x1, [x7, #FD_VBITS]
    cbz  x1, 2f
    mov  x0, #0
    cbnz w6, 11f
    ldr  x9, [x20, #RX_CODES]
    ldr  x0, [x9, x8, lsl #3]
    ldr  x9, [x7, #FD_MIN]
    sub  x0, x0, x9
11: bl   .Lpk_append
2:  add  x25, x25, #1
    b    .Lpk_field
.Lpk_idx:
    mov  x9, x21                        // row index, bit 63: inexact
    ldr  x10, [x20, #RX_INEXF]
    tbnz x10, #63, 1f
    ldr  x10, [x20, #RX_INEX]
    ldrb w10, [x10, x21]
    orr  x9, x9, x10, lsl #63
1:  str  x9, [x26, x27, lsl #3]
    ldr  x10, [x20, #RX_D0]             // histogram of the top bits
    mov  x9, #0                         // (D0 = 0: one bucket)
    cbz  x10, 2f
    ldr  x9, [x26]
    mov  x11, #64
    sub  x11, x11, x10
    lsr  x9, x9, x11
2:  ldr  x10, [x19, #RT_HIST]
    ldr  x11, [x10, x9, lsl #3]
    add  x11, x11, #1
    str  x11, [x10, x9, lsl #3]
    add  x21, x21, #1
    b    .Lpk_row
.Lpk_end:
    LEAVE 5

// local helper: appends the x1 (1..64) low bits of x0 to the key at x26,
// bit cursor x28 (clobbers x2-x5, x9-x11)
.Lpk_append:
    lsr  x2, x28, #6                    // word
    and  x3, x28, #63                   // bits used in it
    mov  x4, #64
    sub  x4, x4, x3                     // room
    add  x28, x28, x1
    cmp  x1, x4
    b.hi 1f
    sub  x5, x4, x1                     // fits: shift left by room - width
    lsl  x5, x0, x5
    ldr  x9, [x26, x2, lsl #3]
    orr  x9, x9, x5
    str  x9, [x26, x2, lsl #3]
    ret
1:  sub  x5, x1, x4                     // spills over by x5 (1..63) bits
    lsr  x10, x0, x5
    ldr  x9, [x26, x2, lsl #3]
    orr  x9, x9, x10
    str  x9, [x26, x2, lsl #3]
    mov  x11, #64
    sub  x11, x11, x5
    lsl  x10, x0, x11
    add  x2, x2, #1
    ldr  x9, [x26, x2, lsl #3]
    orr  x9, x9, x10
    str  x9, [x26, x2, lsl #3]
    ret
ENDF rx_pack_task

// =============================================================================
// rx_scatter_task(x0 task) — elements [lo, hi) to their places in RX_TMP by
// the top D0 bits (offsets in RT_HIST; stable)
//   x19 task, x20 rx, x21 index, x22 hi, x23 element bytes, x24 shift,
//   x25 offsets, x26 source, x27 destination base
// =============================================================================
LFUNC rx_scatter_task
    ENTER 5
    mov  x19, x0
    ldr  x20, [x19, #RT_RX]
    ldp  x21, x22, [x19, #RT_LO]
    ldr  x23, [x20, #RX_E]
    ldr  x9, [x20, #RX_D0]
    mov  x24, #64
    sub  x24, x24, x9
    ldr  x25, [x19, #RT_HIST]
    ldr  x27, [x20, #RX_TMP]
    ldr  x9, [x20, #RX_ELEM]
    madd x26, x21, x23, x9
    ldr  x28, [x20, #RX_D0]
1:  cmp  x21, x22
    b.hs 9f
    tst  x21, #0xffff
    b.ne 2f
    bl   check_deadline
2:  mov  x9, #0                         // bucket (D0 = 0: one)
    cbz  x28, 3f
    ldr  x9, [x26]
    lsr  x9, x9, x24
3:  ldr  x10, [x25, x9, lsl #3]
    add  x11, x10, #1
    str  x11, [x25, x9, lsl #3]
    madd x10, x10, x23, x27             // destination
    mov  x11, #0
4:  ldr  x12, [x26, x11]
    str  x12, [x10, x11]
    add  x11, x11, #8
    cmp  x11, x23
    b.lo 4b
    add  x26, x26, x23
    add  x21, x21, #1
    b    1b
9:  LEAVE 5
ENDF rx_scatter_task

// =============================================================================
// rx_bucket_task(x0 task) — sorts the buckets [b0, b1) of RX_TMP on the key
// bits below the top D0 (RX_ELEM is the scratch space)
//   x19 task, x20 rx, x21 bucket, x22 starts
// =============================================================================
LFUNC rx_bucket_task
    ENTER 3
    mov  x19, x0
    ldr  x20, [x19, #RT_RX]
    ldr  x21, [x19, #RT_B0]
    ldr  x22, [x20, #RX_BSTART]
1:  ldr  x9, [x19, #RT_B1]
    cmp  x21, x9
    b.hs 9f
    ldr  x10, [x22, x21, lsl #3]
    add  x21, x21, #1
    ldr  x11, [x22, x21, lsl #3]
    sub  x2, x11, x10
    cmp  x2, #2
    b.lo 1b
    cmp  x2, #4096                      // large bucket: interruption point
    b.lo 2f
    stp  x2, x10, [sp, #-16]!
    bl   check_deadline
    ldp  x2, x10, [sp], #16
2:  ldr  x9, [x20, #RX_E]
    mul  x10, x10, x9
    ldr  x0, [x20, #RX_TMP]
    add  x0, x0, x10
    ldr  x1, [x20, #RX_ELEM]
    add  x1, x1, x10
    ldr  x3, [x20, #RX_D0]
    mov  x4, x20
    bl   rx_msd
    b    1b
9:  LEAVE 3
ENDF rx_bucket_task

// =============================================================================
// rx_msd(x0 elements, x1 scratch, x2 n, x3 bit, x4 rx) — sorts n elements
// that are equal on the key bits above `bit` by the remaining bits (MSD
// radix, 8 bits per level; insertion sort for small n). The result is in
// place.
//   x19 elements, x20 scratch, x21 n, x22 bit, x23 rx, x24 digit bits,
//   x25 element bytes, x26 index, x27 words, x28 key bits
// Stack: [sp] 256 u64 counters / bucket ends
// =============================================================================
LFUNC rx_msd
    ENTER 5
    sub  sp, sp, #2048
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x22, x3
    mov  x23, x4
    ldr  x25, [x23, #RX_E]
    ldr  x27, [x23, #RX_W]
    ldr  x28, [x23, #RX_TBITS]
.Lms_again:
    cmp  x21, #2
    b.lo .Lms_ret
    cmp  x22, x28                       // no bits left: all equal
    b.hs .Lms_ret
    cmp  x21, #RX_SMALL
    b.ls .Lms_ins
    sub  x24, x28, x22                  // digit: min(8, bits left)
    cmp  x24, #8
    mov  x9, #8
    csel x24, x24, x9, lo
    mov  x0, sp
    mov  w1, #0
    mov  x2, #2048
    bl   memset
    mov  x26, #0
1:  cmp  x26, x21
    b.hs 2f
    madd x0, x26, x25, x19
    bl   .Lms_digit
    ldr  x9, [sp, x0, lsl #3]
    add  x9, x9, #1
    str  x9, [sp, x0, lsl #3]
    add  x26, x26, #1
    b    1b
2:  mov  x9, #1                         // buckets
    lsl  x9, x9, x24
    mov  x10, #0                        // all in one bucket: next digit
3:  cmp  x10, x9
    b.hs 4f
    ldr  x11, [sp, x10, lsl #3]
    add  x10, x10, #1
    cmp  x11, x21
    b.ne 3b
    add  x22, x22, x24
    b    .Lms_again
4:  mov  x10, #0                        // counts -> starts
    mov  x11, #0
5:  cmp  x10, x9
    b.hs 6f
    ldr  x12, [sp, x10, lsl #3]
    str  x11, [sp, x10, lsl #3]
    add  x11, x11, x12
    add  x10, x10, #1
    b    5b
6:  mov  x26, #0                        // scatter to the scratch (stable)
7:  cmp  x26, x21
    b.hs 8f
    madd x13, x26, x25, x19
    mov  x0, x13
    bl   .Lms_digit
    ldr  x9, [sp, x0, lsl #3]
    add  x10, x9, #1
    str  x10, [sp, x0, lsl #3]
    madd x10, x9, x25, x20
    mov  x11, #0
71: ldr  x12, [x13, x11]
    str  x12, [x10, x11]
    add  x11, x11, #8
    cmp  x11, x25
    b.lo 71b
    add  x26, x26, #1
    b    7b
8:  mov  x0, x19                        // back in place
    mov  x1, x20
    mul  x2, x21, x25
    bl   memcpy
    mov  x26, #0                        // every bucket by the next digit
9:  mov  x9, #1
    lsl  x9, x9, x24
    cmp  x26, x9
    b.hs .Lms_ret
    mov  x10, #0                        // [sp] now holds bucket ends
    cbz  x26, 91f
    sub  x11, x26, #1
    ldr  x10, [sp, x11, lsl #3]
91: ldr  x11, [sp, x26, lsl #3]
    add  x26, x26, #1
    sub  x2, x11, x10
    cmp  x2, #2
    b.lo 9b
    madd x0, x10, x25, x19
    madd x1, x10, x25, x20
    add  x3, x22, x24
    mov  x4, x23
    bl   rx_msd
    b    9b
.Lms_ins:                               // insertion sort (stable); [sp] = key
    mov  x26, #1
1:  cmp  x26, x21
    b.hs .Lms_ret
    madd x13, x26, x25, x19             // element i -> [sp]
    mov  x11, #0
2:  ldr  x12, [x13, x11]
    str  x12, [sp, x11]
    add  x11, x11, #8
    cmp  x11, x25
    b.lo 2b
    mov  x14, x26                       // j
3:  cbz  x14, 6f
    sub  x9, x14, #1
    madd x15, x9, x25, x19              // element j - 1
    mov  x11, #0                        // compare its key with [sp]
4:  ldr  x12, [x15, x11, lsl #3]
    ldr  x10, [sp, x11, lsl #3]
    cmp  x12, x10
    b.hi 5f                             // greater: shift it up
    b.lo 6f
    add  x11, x11, #1
    cmp  x11, x27
    b.lo 4b
    b    6f                             // equal: keep the order
5:  add  x10, x15, x25                  // element j - 1 -> j
    mov  x11, #0
51: ldr  x12, [x15, x11]
    str  x12, [x10, x11]
    add  x11, x11, #8
    cmp  x11, x25
    b.lo 51b
    sub  x14, x14, #1
    b    3b
6:  madd x10, x14, x25, x19             // [sp] -> element j
    mov  x11, #0
7:  ldr  x12, [sp, x11]
    str  x12, [x10, x11]
    add  x11, x11, #8
    cmp  x11, x25
    b.lo 7b
    add  x26, x26, #1
    b    1b
.Lms_ret:
    add  sp, sp, #2048
    LEAVE 5

// local helper: x0 element -> x0 its key bits [x22, x22 + x24)
// (clobbers x9-x12)
.Lms_digit:
    lsr  x9, x22, #6                    // word
    and  x10, x22, #63                  // offset in it
    ldr  x11, [x0, x9, lsl #3]
    lsl  x11, x11, x10
    add  x12, x10, x24
    cmp  x12, #64
    b.ls 1f
    add  x9, x9, #1                     // the digit straddles two words
    cmp  x9, x27
    b.hs 1f
    ldr  x12, [x0, x9, lsl #3]
    mov  x9, #64
    sub  x9, x9, x10
    lsr  x12, x12, x9
    orr  x11, x11, x12
1:  mov  x9, #64
    sub  x9, x9, x24
    lsr  x0, x11, x9
    ret
ENDF rx_msd

// =============================================================================
// rx_gather_task(x0 task) — rows [lo, hi) of the output in element order
// =============================================================================
LFUNC rx_gather_task
    ENTER 3
    mov  x19, x0
    ldr  x20, [x19, #RT_RX]
    ldp  x21, x22, [x19, #RT_LO]
    ldr  x9, [x20, #RX_E]
    ldr  x10, [x20, #RX_TMP]
    madd x11, x21, x9, x10              // element
    ldr  x12, [x20, #RX_W]
    lsl  x12, x12, #3                   // its index word
    ldr  x13, [x20, #RX_ROWS]           // input order (copy)
    ldr  x14, [x20, #RX_OUT]
1:  cmp  x21, x22
    b.hs 9f
    ldr  x10, [x11, x12]
    and  x10, x10, #0x7fffffffffffffff
    ldr  x10, [x13, x10, lsl #3]
    str  x10, [x14, x21, lsl #3]
    add  x11, x11, x9
    add  x21, x21, #1
    b    1b
9:  LEAVE 3
ENDF rx_gather_task

// =============================================================================
// rx_fixup(x0 rx, x1 keys, x2 tail inexact) — sorts the runs of rows whose
// keys tie only by encoding: an inexact row with the following rows equal
// on the composite bits up to the end of the inexact field; with dropped
// keys (tail inexact), any rows with equal composite keys.
//   x19 rx, x20 keys, x21 tail, x22 i, x23 j, x24 elements, x25 element
//   bytes, x26 bits compared, x27 n, x28 element i
// =============================================================================
LFUNC rx_fixup
    ENTER 5
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    ldr  x24, [x19, #RX_TMP]
    ldr  x25, [x19, #RX_E]
    ldr  x27, [x19, #RX_N]
    mov  x22, #0
1:  cmp  x22, x27
    b.hs 9f
    madd x28, x22, x25, x24
    ldr  x9, [x19, #RX_W]
    ldr  x9, [x28, x9, lsl #3]
    tbz  x9, #63, 2f
    ldr  x9, [x19, #RX_INEXF]           // inexact: up to the field's end
    mov  x10, #FD_SIZE
    ldr  x11, [x19, #RX_FIELDS]
    madd x9, x9, x10, x11
    ldr  x26, [x9, #FD_END]
    b    3f
2:  add  x22, x22, #1
    cbz  x21, 1b
    sub  x22, x22, #1
    ldr  x26, [x19, #RX_TBITS]          // tail: the whole key
3:  add  x23, x22, #1
4:  cmp  x23, x27
    b.hs 6f
    madd x0, x23, x25, x24
    mov  x1, x28
    mov  x2, x26
    bl   .Lfx_eq
    cbz  w0, 6f
    add  x23, x23, #1
    b    4b
6:  sub  x1, x23, x22
    cmp  x1, #2
    b.lo 7f
    bl   check_deadline
    ldr  x9, [x19, #RX_OUT]
    add  x0, x9, x22, lsl #3
    sub  x1, x23, x22
    mov  x2, x20
    bl   sort_rows
7:  mov  x22, x23
    b    1b
9:  LEAVE 5

// local helper: w0 1 if keys x0 and x1 are equal on their top x2 bits
// (clobbers x3-x6)
.Lfx_eq:
    mov  x3, #0
1:  cmp  x2, #64
    b.lo 2f
    ldr  x4, [x0, x3, lsl #3]
    ldr  x5, [x1, x3, lsl #3]
    cmp  x4, x5
    b.ne 8f
    add  x3, x3, #1
    sub  x2, x2, #64
    b    1b
2:  cbz  x2, 7f
    ldr  x4, [x0, x3, lsl #3]
    ldr  x5, [x1, x3, lsl #3]
    eor  x4, x4, x5
    mov  x6, #64
    sub  x6, x6, x2
    lsr  x4, x4, x6
    cbnz x4, 8f
7:  mov  w0, #1
    ret
8:  mov  w0, #0
    ret
ENDF rx_fixup

    NOTE_GNU_STACK
