// =============================================================================
// test_catalog.S — unit tests for the versioned catalog (catalog.S, index
// registry in index.S): snapshot isolation between threads, atomic publish
// of mutations, discarded failed mutations, index versioning.
//
// Scenario (main thread M, reader thread R):
//   M  publishes table t (values 1..3)
//   R  pins a snapshot, finds t (T1), signals M, waits
//   M  replaces t by T2 (values 7..8), adds u, creates index ix on T2;
//      signals R
//   R  must still see T1 with its data, and neither u nor ix
//   M  sees T2, u and ix; a mutation ended with cat_end(0) changes nothing
//
// Exit status 0 iff all checks pass.
// =============================================================================
#include "pq.inc"
#include "frame.inc"

    .section .rodata
csv1:       .ascii "k\n1\n2\n3\n"
csv1_end:
csv2:       .ascii "k\n7\n8\n"
csv2_end:
n_t:        .asciz "t"
n_u:        .asciz "u"
n_v:        .asciz "v"
n_ix:       .asciz "ix"
fmt_fail:   .asciz "FAIL: %s\n"
fmt_sum:    .asciz "test_catalog: %d checks, %d failures\n"
m_r_same:   .asciz "reader keeps its snapshot of t after a replace"
m_r_data:   .asciz "replaced table data still readable by the reader"
m_r_nou:    .asciz "reader does not see a table added later"
m_r_noix:   .asciz "reader does not see an index created later"
m_new_t:    .asciz "new requests see the replacement of t"
m_new_data: .asciz "replacement data"
m_new_u:    .asciz "new requests see u"
m_new_ix:   .asciz "new requests see index ix"
m_count:    .asciz "catalog_count after mutations"
m_discard:  .asciz "a failed mutation is discarded"
m_drop:     .asciz "drop removes table and its index"
m_first:    .asciz "first table published"

    .bss
    .p2align 3
g_checks:   .skip 4
g_fails:    .skip 4
g_t1:       .skip 8             // T1 as seen by the reader
g_r_same:   .skip 8             // reader results
g_r_data:   .skip 8
g_r_nou:    .skip 8
g_r_noix:   .skip 8
    .p2align 4
g_sem_pinned:  .skip 64         // sem_t
g_sem_mutated: .skip 64
g_thread:   .skip 8

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
    ADR_L x0, fmt_fail
    bl   printf
1:  LEAVE 0
ENDF check

// make_table(x0 csv, x1 end, x2 name cstr) -> x0 Table* (named, finalized)
//   x19 table, x20 name
LFUNC make_table
    ENTER 2
    stp  x0, x1, [sp, #-16]!
    mov  x20, x2
    mov  x0, #1
    mov  x1, #TBL_SIZE
    bl   calloc
    mov  x19, x0
    ldp  x1, x2, [sp], #16
    sub  x2, x2, x1
    mov  x0, x19
    mov  w3, #FMT_CSV
    mov  x4, #0
    mov  w5, #1
    mov  w6, #','
    bl   ingest
    mov  x0, x19
    mov  w1, #-1
    mov  w2, #0
    bl   table_finalize
    mov  x0, x20
    bl   strlen
    mov  x2, x0
    mov  x1, x20
    add  x0, x19, #TBL_ARENA
    bl   str_new_in
    str  x0, [x19, #TBL_NAME]
    mov  x0, x19
    LEAVE 2
ENDF make_table

// find(x0 cstr) -> x0 Table* or 0
LFUNC find
    ENTER 1
    mov  x19, x0
    bl   strlen
    mov  x1, x0
    mov  x0, x19
    bl   catalog_find
    LEAVE 1
ENDF find

// find_ix(x0 cstr) -> x0 Index* or 0
LFUNC find_ix
    ENTER 1
    mov  x19, x0
    bl   strlen
    mov  x1, x0
    mov  x0, x19
    bl   index_find
    LEAVE 1
ENDF find_ix

// reader(): the thread R
//   x19 T1
LFUNC reader
    ENTER 1
    bl   cat_read_begin
    ADR_L x0, n_t
    bl   find
    mov  x19, x0
    ADR_L x9, g_t1
    str  x19, [x9]
    ADR_L x0, g_sem_pinned
    bl   sem_post
    ADR_L x0, g_sem_mutated
    bl   sem_wait
    ADR_L x0, n_t                       // same table object
    bl   find
    cmp  x0, x19
    cset x9, eq
    ADR_L x10, g_r_same
    str  x9, [x10]
    mov  x0, x19                        // its data: row 2 = 3
    mov  x1, #0
    mov  x2, #2
    bl   tbl_get
    cmp  x0, #3
    ccmp x1, #0, #0, eq
    cset x9, eq
    ADR_L x10, g_r_data
    str  x9, [x10]
    ADR_L x0, n_u
    bl   find
    cmp  x0, #0
    cset x9, eq
    ADR_L x10, g_r_nou
    str  x9, [x10]
    ADR_L x0, n_ix
    bl   find_ix
    cmp  x0, #0
    cset x9, eq
    ADR_L x10, g_r_noix
    str  x9, [x10]
    mov  w0, #0
    bl   cat_end
    TLS_ADDR x0, g_arena
    bl   arena_free
    mov  x0, #0
    LEAVE 1
ENDF reader

FUNC main
    ENTER 2
    bl   cat_init
    ADR_L x0, g_sem_pinned
    mov  w1, #0
    mov  w2, #0
    bl   sem_init
    ADR_L x0, g_sem_mutated
    mov  w1, #0
    mov  w2, #0
    bl   sem_init
    // M: publish t
    bl   cat_write_begin
    ADR_L x0, csv1
    ADR_L x1, csv1_end
    ADR_L x2, n_t
    bl   make_table
    bl   catalog_add
    mov  w0, #1
    bl   cat_end
    bl   cat_read_begin
    ADR_L x0, n_t
    bl   find
    cmp  x0, #0
    cset w0, ne
    ADR_L x1, m_first
    bl   check
    mov  w0, #1
    bl   cat_end
    // R pins its snapshot
    ADR_L x0, g_thread
    mov  x1, #0
    ADR_L x2, reader
    mov  x3, #0
    bl   pthread_create
    ADR_L x0, g_sem_pinned
    bl   sem_wait
    // M: replace t, add u, create ix — one mutation
    bl   cat_write_begin
    ADR_L x0, n_t
    bl   find
    bl   catalog_remove
    ADR_L x0, csv2
    ADR_L x1, csv2_end
    ADR_L x2, n_t
    bl   make_table
    mov  x19, x0
    bl   catalog_add
    ADR_L x0, csv2
    ADR_L x1, csv2_end
    ADR_L x2, n_u
    bl   make_table
    bl   catalog_add
    ADR_L x0, n_ix
    mov  x1, #2
    bl   str_new
    mov  x1, x0
    mov  x0, x19
    mov  x2, #0
    mov  w3, #IXK_HASH
    bl   index_create
    mov  w0, #1
    bl   cat_end
    ADR_L x0, g_sem_mutated
    bl   sem_post
    LDR_G x0, g_thread
    mov  x1, #0
    bl   pthread_join
    // reader results
    LDR_G x0, g_r_same
    ADR_L x1, m_r_same
    bl   check
    LDR_G x0, g_r_data
    ADR_L x1, m_r_data
    bl   check
    LDR_G x0, g_r_nou
    ADR_L x1, m_r_nou
    bl   check
    LDR_G x0, g_r_noix
    ADR_L x1, m_r_noix
    bl   check
    // new requests see the new version
    bl   cat_read_begin
    ADR_L x0, n_t
    bl   find
    mov  x20, x0
    cmp  x0, x19
    cset w0, eq
    ADR_L x1, m_new_t
    bl   check
    mov  x0, x20
    mov  x1, #0
    mov  x2, #1
    bl   tbl_get
    cmp  x0, #8
    cset w0, eq
    ADR_L x1, m_new_data
    bl   check
    ADR_L x0, n_u
    bl   find
    cmp  x0, #0
    cset w0, ne
    ADR_L x1, m_new_u
    bl   check
    ADR_L x0, n_ix
    bl   find_ix
    cmp  x0, #0
    cset w0, ne
    ADR_L x1, m_new_ix
    bl   check
    mov  w0, #1
    bl   cat_end
    bl   catalog_count
    cmp  x0, #2
    cset w0, eq
    ADR_L x1, m_count
    bl   check
    // a mutation that fails (cat_end 0) changes nothing
    bl   cat_write_begin
    ADR_L x0, csv1
    ADR_L x1, csv1_end
    ADR_L x2, n_v
    bl   make_table
    bl   catalog_add
    ADR_L x0, n_t
    bl   find
    bl   catalog_remove
    mov  w0, #0
    bl   cat_end
    bl   cat_read_begin
    ADR_L x0, n_v
    bl   find
    mov  x20, x0
    ADR_L x0, n_t
    bl   find
    cmp  x0, x19
    ccmp x20, #0, #0, eq
    cset w0, eq
    ADR_L x1, m_discard
    bl   check
    mov  w0, #1
    bl   cat_end
    // drop t: its index goes too
    bl   cat_write_begin
    ADR_L x0, n_t
    bl   find
    bl   catalog_remove
    mov  w0, #1
    bl   cat_end
    bl   cat_read_begin
    ADR_L x0, n_t
    bl   find
    mov  x20, x0
    ADR_L x0, n_ix
    bl   find_ix
    orr  x0, x0, x20
    cmp  x0, #0
    cset w0, eq
    ADR_L x1, m_drop
    bl   check
    mov  w0, #1
    bl   cat_end
    // summary
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
    LEAVE 2
ENDF main

    NOTE_GNU_STACK
