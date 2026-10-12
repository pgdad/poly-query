// =============================================================================
// sort.S — parallel sorting of result rows (Phase 5, option "threads").
//
//   sort_rows_par(x0 Row** rows, x1 n, x2 key descriptors, x3 number of
//                 leading keys that are ORDER BY keys)
//       sorts like exec.S sort_rows (qsort_r with cmp_rows; mode "row"). In
//       vectorized mode with sort_rows_fast (normalized-key radix sort) when
//       the first ORDER BY key is not a STRING; otherwise, with threads > 1
//       and at least 2 * g_par_min_rows rows: the array is cut into one
//       chunk per task, the chunks are sorted in parallel, then merged
//       pairwise in rounds (the merges of a round run in parallel),
//       alternating between the array and a scratch array.
//
// The ORDER BY / DISTINCT key lists end with every visible column as a
// tie-breaker (exec.S order_keys), so only identical rows compare equal and
// the parallel result is exactly the serial one.
// =============================================================================
#include "pq.inc"
#include "frame.inc"

// Sort / merge task
#define SO_SRC      0               // Row** source
#define SO_DST      8               // Row** destination (merges)
#define SO_LO       16              // [lo, mid) and [mid, hi)
#define SO_MID      24
#define SO_HI       32
#define SO_KEYS     40
#define SO_NK       48              // leading keys sort_rows_fast may radix
#define SO_SIZE     64

    .text

// =============================================================================
// sort_rows_par(x0 rows, x1 n, x2 keys, x3 nk: leading keys that may be
// radix sorted)
//   x19 rows, x20 n, x21 keys, x22 runs, x23 run bounds (u64 [runs + 1]),
//   x24 tasks, x25 source, x26 destination, x27 index, x28 pairs
// =============================================================================
FUNC sort_rows_par
    ENTER 5
    sub  sp, sp, #16
    str  x3, [sp]                       // nk
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    TLS_ADDR x9, g_x_mode
    ldr  w9, [x9]
    cmp  w9, #XM_ROW
    b.eq .Lsp_serial
    ldr  x9, [sp]                       // radix-able first ORDER BY key:
    cbz  x9, 1f                         // the single-threaded radix sort
    ldr  x9, [x21]                      // beats chunk sorts + comparator
    cbz  x9, 1f                         // merges
    ldr  w9, [x21, #(8 + 8)]
    BR_WIDE w9, w10, 1f                 // wide DECIMAL: like STRING
    and  w9, w9, #T_KIND_MASK
    cbz  w9, 1f
    cmp  w9, #T_STR
    b.ne .Lsp_fast
1:  TLS_LDR x9, g_x_threads
    cmp  x9, #1
    b.ls .Lsp_fast
    LDR_G x10, g_par_min_rows
    udiv x10, x20, x10
    cmp  x10, x9
    csel x22, x10, x9, lo
    cmp  x22, #2
    b.lo .Lsp_fast
    // ---- chunks ------------------------------------------------------------
    add  x0, x22, #1
    lsl  x0, x0, #3
    bl   arena_alloc
    mov  x23, x0
    add  x9, x20, x22                   // chunk size: ceil(n / runs)
    sub  x9, x9, #1
    udiv x9, x9, x22
    mov  x27, #0
1:  cmp  x27, x22
    b.hi 2f
    mul  x10, x27, x9
    cmp  x10, x20
    csel x10, x10, x20, lo
    str  x10, [x23, x27, lsl #3]
    add  x27, x27, #1
    b    1b
2:  mov  x9, #SO_SIZE
    mul  x0, x9, x22
    bl   arena_alloc
    mov  x24, x0
    mov  x27, #0
3:  cmp  x27, x22
    b.hs 4f
    mov  x9, #SO_SIZE
    madd x10, x27, x9, x24
    str  x19, [x10, #SO_SRC]
    ldr  x11, [x23, x27, lsl #3]
    str  x11, [x10, #SO_LO]
    add  x12, x27, #1
    ldr  x11, [x23, x12, lsl #3]
    str  x11, [x10, #SO_HI]
    str  x21, [x10, #SO_KEYS]
    ldr  x12, [sp]
    str  x12, [x10, #SO_NK]
    add  x27, x27, #1
    b    3b
4:  ADR_L x0, sort_chunk_task
    mov  x1, x24
    mov  x2, #SO_SIZE
    mov  x3, x22
    bl   par_run
    // ---- merge rounds ------------------------------------------------------
    lsl  x0, x20, #3
    bl   arena_alloc
    mov  x26, x0
    mov  x25, x19
.Lsp_round:
    cmp  x22, #1
    b.ls .Lsp_done
    add  x28, x22, #1                   // pairs: ceil(runs / 2)
    lsr  x28, x28, #1
    mov  x27, #0
5:  cmp  x27, x28
    b.hs 6f
    mov  x9, #SO_SIZE
    madd x10, x27, x9, x24
    str  x25, [x10, #SO_SRC]
    str  x26, [x10, #SO_DST]
    str  x21, [x10, #SO_KEYS]
    lsl  x11, x27, #1                   // runs 2i and 2i + 1 (may be empty)
    ldr  x12, [x23, x11, lsl #3]
    str  x12, [x10, #SO_LO]
    add  x11, x11, #1
    cmp  x11, x22
    csel x11, x11, x22, lo
    ldr  x12, [x23, x11, lsl #3]
    str  x12, [x10, #SO_MID]
    lsl  x11, x27, #1
    add  x11, x11, #2
    cmp  x11, x22
    csel x11, x11, x22, lo
    ldr  x12, [x23, x11, lsl #3]
    str  x12, [x10, #SO_HI]
    add  x27, x27, #1
    b    5b
6:  cmp  x28, #1
    b.ne 7f
    mov  x0, x24                        // last round: one merge, here
    bl   smerge_task
    b    8f
7:  ADR_L x0, smerge_task
    mov  x1, x24
    mov  x2, #SO_SIZE
    mov  x3, x28
    bl   par_run
8:  mov  x27, #0                        // run bounds of the merged runs
9:  cmp  x27, x28
    b.hs 10f
    lsl  x11, x27, #1
    ldr  x12, [x23, x11, lsl #3]
    str  x12, [x23, x27, lsl #3]
    add  x27, x27, #1
    b    9b
10: str  x20, [x23, x28, lsl #3]
    mov  x22, x28
    mov  x9, x25                        // swap source and destination
    mov  x25, x26
    mov  x26, x9
    b    .Lsp_round
.Lsp_done:
    cmp  x25, x19
    b.eq 11f
    mov  x0, x19
    mov  x1, x25
    lsl  x2, x20, #3
    bl   memcpy
11: add  sp, sp, #16
    LEAVE 5
.Lsp_serial:                            // row mode: qsort_r
    mov  x0, x19
    mov  x1, x20
    mov  x2, x21
    add  sp, sp, #16
    LEAVE_NORET 5
    b    sort_rows                      // tail call
.Lsp_fast:                              // vectorized, one thread
    mov  x0, x19
    mov  x1, x20
    mov  x2, x21
    ldr  x3, [sp]
    add  sp, sp, #16
    LEAVE_NORET 5
    b    sort_rows_fast                 // tail call
ENDF sort_rows_par

// =============================================================================
// sk_encode(x0 row, x1 key descriptor) -> x0 64-bit code, x1 1 if NULL
// A code whose unsigned order agrees with the key order: integer-like
// payloads biased, FLOAT64 sign-folded (-0.0 = 0.0), STRING: the first 8
// bytes big-endian (only a prefix: equal codes need the comparator);
// inverted for DESC.   (leaf)
// =============================================================================
LFUNC sk_encode
    ldr  x9, [x1, #0]                   // SK_OFF
    add  x9, x0, x9
    ldp  x0, x10, [x9]
    cbnz x10, 9f
    ldr  w11, [x1, #8]                  // SK_TYPE
    BR_WIDE w11, w12, 6f
    and  w11, w11, #T_KIND_MASK
    cmp  w11, #T_STR
    b.eq 3f
    cmp  w11, #T_FLOAT
    b.eq 2f
    eor  x0, x0, #0x8000000000000000    // signed -> unsigned order
    b    7f
2:  mov  x12, #0x8000000000000000       // FLOAT64: -0.0 = 0.0, then fold
    cmp  x0, x12
    csel x0, xzr, x0, eq
    tbz  x0, #63, 21f
    mvn  x0, x0                         // negative: invert everything
    b    7f
21: orr  x0, x0, x12                    // positive: set the sign bit
    b    7f
3:  ldr  x12, [x0, #STR_LEN]
    add  x13, x0, #STR_DATA
    cmp  x12, #8
    b.lo 4f
    ldr  x0, [x13]
    rev  x0, x0
    b    7f
4:  mov  x0, #0
    mov  x14, #0
    mov  x15, #56
5:  cmp  x14, x12
    b.hs 7f
    ldrb w16, [x13, x14]
    lsl  x16, x16, x15
    orr  x0, x0, x16
    add  x14, x14, #1
    sub  x15, x15, #8
    b    5b
    b    7f
6:  ldr  x0, [x0, #8]                   // wide DECIMAL: high word (prefix
    eor  x0, x0, #0x8000000000000000    // only, like a STRING)
7:  ldr  w12, [x1, #12]                 // SK_DESC
    cbz  w12, 8f
    mvn  x0, x0
8:  mov  x1, #0
    ret
9:  mov  x1, #1
    ret
ENDF sk_encode

// =============================================================================
// sort_rows_fast(x0 Row** rows, x1 n, x2 keys, x3 nk) — the same order as
// sort_rows, computed by normalized keys. The leading ORDER BY keys (at
// most nk; each column once) that are not STRING get exact 64-bit codes
// (sk_encode), computed once per row and key; a permutation of the rows is
// radix sorted on them, last key first (stable LSD passes, constant bytes
// skipped). When the first key is a STRING its 8-byte prefix code is used
// instead. Only runs of rows with equal codes are then sorted by the full
// comparator (the remaining keys and the tie-breaker columns). Falls back to
// sort_rows for small inputs and when a radix key has a NULL.
//   x19 rows, x20 n, x21 keys, x22 pairs, x23 tmp pairs, x24 key,
//   x25 histogram, x26 index / run start, x27 radix keys, x28 codes
//   (n u64 per key) / run end
// =============================================================================
FUNC sort_rows_fast
    ENTER 5
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    cmp  x20, #64
    b.lo .Lsf_fallback
    ldr  x9, [x21]                      // radix keys: descriptor pointers
    cmp  x3, x9                         // of the leading non-STRING keys
    csel x3, x3, x9, lo                 // among the first nk (the ORDER BY
    str  x3, [sp, #-16]!                // keys), a column only once
    lsl  x0, x9, #3
    add  x0, x0, #8
    bl   arena_alloc
    ldr  x3, [sp]
    stp  x0, x3, [sp]                   // [sp] pointers, [sp+8] nk
    mov  x27, #0
    mov  x9, #0
1:  ldr  x10, [sp, #8]
    cmp  x9, x10
    b.hs 2f
    mov  x10, #24                       // SK_SIZE
    madd x10, x9, x10, x21
    add  x10, x10, #8                   // descriptor
    ldr  w11, [x10, #8]
    BR_WIDE w11, w12, 2f
    and  w11, w11, #T_KIND_MASK
    cbz  w11, 2f
    cmp  w11, #T_STR
    b.eq 2f
    add  x9, x9, #1
    ldr  x11, [x10]                     // same cell as a selected key?
    mov  x12, #0
11: cmp  x12, x27
    b.hs 12f
    ldr  x13, [x0, x12, lsl #3]
    ldr  x13, [x13]
    cmp  x13, x11
    b.eq 1b
    add  x12, x12, #1
    b    11b
12: str  x10, [x0, x27, lsl #3]
    add  x27, x27, #1
    b    1b
2:  cbnz x27, 3f
    ldr  x10, [sp, #8]
    cbz  x10, .Lsf_fallback1
    ldr  w10, [x21, #(8 + 8)]           // first key a STRING (or a wide
    BR_WIDE w10, w11, 31f               // DECIMAL): its prefix
    and  w10, w10, #T_KIND_MASK
    cmp  w10, #T_STR
    b.ne .Lsf_fallback1
31:
    add  x10, x21, #8
    str  x10, [x0]
    mov  x27, #1
3:  mul  x0, x20, x27                   // codes [key][row]
    lsl  x0, x0, #3
    bl   arena_alloc
    mov  x28, x0
    mov  x24, #0
4:  cmp  x24, x27
    b.hs 6f
    mov  x26, #0
5:  cmp  x26, x20
    b.hs 51f
    ldr  x0, [x19, x26, lsl #3]
    ldr  x1, [sp]
    ldr  x1, [x1, x24, lsl #3]
    bl   sk_encode
    cbnz x1, .Lsf_fallback1             // NULL: comparator only
    madd x10, x24, x20, x26
    str  x0, [x28, x10, lsl #3]
    add  x26, x26, #1
    b    5b
51: add  x24, x24, #1
    b    4b
6:  lsl  x0, x20, #4
    bl   arena_alloc
    mov  x22, x0
    lsl  x0, x20, #4
    bl   arena_alloc
    mov  x23, x0
    mov  x0, #(257 * 8)
    bl   arena_alloc
    mov  x25, x0
    mov  x9, #0                         // pairs (code, row index): identity
7:  cmp  x9, x20
    b.hs 8f
    add  x10, x22, x9, lsl #4
    str  x9, [x10, #8]
    add  x9, x9, #1
    b    7b
8:  mov  x24, x27                       // keys last to first
.Lsf_key:
    cbz  x24, .Lsf_perm
    sub  x24, x24, #1
    mul  x11, x24, x20                  // codes of this key, current order
    add  x11, x28, x11, lsl #3
    mov  x9, #0
1:  cmp  x9, x20
    b.hs 2f
    add  x10, x22, x9, lsl #4
    ldr  x12, [x10, #8]
    ldr  x12, [x11, x12, lsl #3]
    str  x12, [x10]
    add  x9, x9, #1
    b    1b
2:  bl   .Lsf_radix                     // stable sort of the pairs
    b    .Lsf_key
.Lsf_perm:                              // rows in the sorted order (via the
    lsl  x0, x20, #3                    // scratch: rows -> tmp -> rows)
    bl   arena_alloc
    mov  x9, #0
1:  cmp  x9, x20
    b.hs 2f
    add  x10, x22, x9, lsl #4
    ldr  x10, [x10, #8]
    ldr  x10, [x19, x10, lsl #3]
    str  x10, [x0, x9, lsl #3]
    add  x9, x9, #1
    b    1b
2:  mov  x1, x0
    mov  x0, x19
    lsl  x2, x20, #3
    bl   memcpy
    mov  x26, #0                        // runs equal on every radix code
.Lsf_runs:
    cmp  x26, x20
    b.hs .Lsf_ret
    add  x12, x26, #1
1:  cmp  x12, x20
    b.hs 4f
    add  x10, x22, x26, lsl #4          // original indexes of both rows
    ldr  x10, [x10, #8]
    add  x11, x22, x12, lsl #4
    ldr  x11, [x11, #8]
    mov  x13, #0
2:  cmp  x13, x27
    b.hs 3f
    madd x14, x13, x20, x10
    ldr  x14, [x28, x14, lsl #3]
    madd x15, x13, x20, x11
    ldr  x15, [x28, x15, lsl #3]
    cmp  x14, x15
    b.ne 4f
    add  x13, x13, #1
    b    2b
3:  add  x12, x12, #1
    b    1b
4:  sub  x1, x12, x26
    mov  x24, x12
    cmp  x1, #2
    b.lo 5f
    add  x0, x19, x26, lsl #3
    mov  x2, x21
    bl   sort_rows
5:  mov  x26, x24
    b    .Lsf_runs
.Lsf_ret:
    add  sp, sp, #16
    LEAVE 5
.Lsf_fallback1:
    add  sp, sp, #16
.Lsf_fallback:
    mov  x0, x19
    mov  x1, x20
    mov  x2, x21
    LEAVE_NORET 5
    b    sort_rows                      // tail call

// local helper: stable LSD radix sort of the n (code, row) pairs at x22
// (x23 scratch; the result ends in x22)
.Lsf_radix:
    stp  x29, x30, [sp, #-16]!
    str  x24, [sp, #-16]!
    mov  x24, #0
.Lsr_pass:
    cmp  x24, #64
    b.hs .Lsr_done
    mov  x0, x25
    mov  w1, #0
    mov  x2, #(257 * 8)
    bl   memset
    mov  x9, #0
1:  cmp  x9, x20
    b.hs 2f
    lsl  x10, x9, #4
    ldr  x10, [x22, x10]
    lsr  x10, x10, x24
    and  x10, x10, #0xff
    add  x10, x10, #1
    ldr  x11, [x25, x10, lsl #3]
    add  x11, x11, #1
    str  x11, [x25, x10, lsl #3]
    add  x9, x9, #1
    b    1b
2:  mov  x9, #1                         // constant byte: skip the pass
3:  cmp  x9, #256
    b.hi 4f
    ldr  x10, [x25, x9, lsl #3]
    cmp  x10, x20
    b.eq .Lsr_next
    add  x9, x9, #1
    b    3b
4:  mov  x9, #1                         // bucket starts
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
    add  x12, x22, x9, lsl #4
    ldp  x13, x14, [x12]
    lsr  x10, x13, x24
    and  x10, x10, #0xff
    add  x10, x10, #1
    ldr  x15, [x25, x10, lsl #3]
    add  x16, x15, #1
    str  x16, [x25, x10, lsl #3]
    add  x15, x23, x15, lsl #4
    stp  x13, x14, [x15]
    add  x9, x9, #1
    b    7b
8:  mov  x9, x22
    mov  x22, x23
    mov  x23, x9
.Lsr_next:
    add  x24, x24, #8
    b    .Lsr_pass
.Lsr_done:
    ldr  x24, [sp], #16
    ldp  x29, x30, [sp], #16
    ret
ENDF sort_rows_fast

// sort_chunk_task(x0 task): sorts rows [lo, hi)
LFUNC sort_chunk_task
    ldr  x9, [x0, #SO_SRC]
    ldr  x10, [x0, #SO_LO]
    ldr  x1, [x0, #SO_HI]
    ldr  x2, [x0, #SO_KEYS]
    ldr  x3, [x0, #SO_NK]
    sub  x1, x1, x10
    add  x0, x9, x10, lsl #3
    b    sort_rows_fast                 // tail call
ENDF sort_chunk_task

// =============================================================================
// smerge_task(x0 task): merges the sorted runs src[lo, mid) and src[mid, hi)
// into dst[lo, hi) (equal rows: the left run first)
//   x19 task, x20 i, x21 j, x22 k, x23 src, x24 dst, x25 counter
// =============================================================================
LFUNC smerge_task
    ENTER 5
    mov  x19, x0
    ldr  x23, [x19, #SO_SRC]
    ldr  x24, [x19, #SO_DST]
    ldr  x20, [x19, #SO_LO]
    ldr  x21, [x19, #SO_MID]
    mov  x22, x20
    mov  x25, #0
1:  ldr  x9, [x19, #SO_MID]
    cmp  x20, x9
    b.hs 4f
    ldr  x9, [x19, #SO_HI]
    cmp  x21, x9
    b.hs 4f
    add  x25, x25, #1
    tst  x25, #0xfff
    b.ne 2f
    bl   check_deadline
2:  add  x0, x23, x21, lsl #3           // right < left: take right
    add  x1, x23, x20, lsl #3
    ldr  x2, [x19, #SO_KEYS]
    bl   cmp_rows
    tbz  w0, #31, 3f
    ldr  x9, [x23, x21, lsl #3]
    str  x9, [x24, x22, lsl #3]
    add  x21, x21, #1
    add  x22, x22, #1
    b    1b
3:  ldr  x9, [x23, x20, lsl #3]
    str  x9, [x24, x22, lsl #3]
    add  x20, x20, #1
    add  x22, x22, #1
    b    1b
4:  ldr  x9, [x19, #SO_MID]             // the rest of either run
5:  cmp  x20, x9
    b.hs 6f
    ldr  x10, [x23, x20, lsl #3]
    str  x10, [x24, x22, lsl #3]
    add  x20, x20, #1
    add  x22, x22, #1
    b    5b
6:  ldr  x9, [x19, #SO_HI]
7:  cmp  x21, x9
    b.hs 8f
    ldr  x10, [x23, x21, lsl #3]
    str  x10, [x24, x22, lsl #3]
    add  x21, x21, #1
    add  x22, x22, #1
    b    7b
8:  LEAVE 5
ENDF smerge_task

    NOTE_GNU_STACK
