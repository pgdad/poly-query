// =============================================================================
// catalog.S — the catalog of tables: immutable, reference-counted versions.
//
// concurrency.md §1: every request works on one catalog *version* (CV_*,
// pq.inc) held in the thread-local g_cat:
//   * readers pin the current version (cat_read_begin) and see exactly its
//     tables and indexes until the request ends, whatever other requests do;
//   * a mutation (load, open, drop, reset, CREATE/DROP INDEX) takes the
//     writer mutex, edits a private copy of the current version
//     (cat_write_begin) and publishes it atomically when the request
//     succeeds (cat_end 1); on failure the copy is discarded (cat_end 0), so
//     a failed request never changes the catalog.
// Versions hold references to their tables (TBL_REFS) and indexes
// (IX_REFS); a dropped or replaced table is freed when the last version
// referring to it is released. The heavy work of a load (parsing) happens
// before anything is published and never blocks readers.
//
// Name matching is ASCII case-insensitive (ingestion.md, semantics.md §1).
//
//   cat_init()                      create the empty current version
//   cat_read_begin()                pin the current version (no-op if pinned)
//   cat_write_begin()               private writable copy (writer mutex)
//   cat_end(w0 commit)              release / publish (end of a request)
//   cat_cur() -> x0 CatVer*         version of this request (begins a write
//                                   transaction if none: unit tests)
//   catalog_find(x0 ptr, x1 len) -> x0 Table* or 0
//   catalog_add(x0 Table*)          (write) computes the table statistics
//   catalog_remove(x0 Table*)       (write) also drops its indexes
//   catalog_reset()                 (write)
//   catalog_snapshot() -> x0 Table** (request arena), x1 count
//   catalog_count() -> x0 tables in the current version (metrics)
//   table_free(x0 Table*)           free a table no version refers to
// =============================================================================
#include "pq.inc"
#include "frame.inc"

#define MODE_NONE   0
#define MODE_READ   1
#define MODE_WRITE  2

    .bss
    .p2align 4
g_cat_cur:  .skip 8         // CatVer* current (published) version
    .p2align 4
g_cat_lock: .skip 64        // pthread_mutex_t: guards g_cat_cur
g_cat_wlock: .skip 64       // pthread_mutex_t: serialises mutations

    TBSS
    .p2align 3
    .global g_cat
g_cat:      .skip 8         // CatVer* used by this thread's request
g_cat_mode: .skip 8         // MODE_*

    .text

// cv_clone(x0 CatVer* or 0) -> x0 new CatVer* (refs 1) with the same tables
// and indexes (each referenced once more).
//   x19 source, x20 copy, x21 i
LFUNC cv_clone
    ENTER 3
    mov  x19, x0
    mov  x0, #1
    mov  x1, #CV_SIZE
    bl   calloc
    cbz  x0, .Lcv_oom
    mov  x20, x0
    mov  x9, #1
    str  x9, [x20, #CV_REFS]
    cbz  x19, 9f
    // tables
    ldr  x0, [x19, #CV_TCAP]
    cbz  x0, 3f
    lsl  x0, x0, #3
    bl   malloc
    cbz  x0, .Lcv_oom
    str  x0, [x20, #CV_TABLES]
    ldr  x9, [x19, #CV_TCAP]
    str  x9, [x20, #CV_TCAP]
    ldr  x9, [x19, #CV_NT]
    str  x9, [x20, #CV_NT]
    mov  x21, #0
1:  ldr  x9, [x19, #CV_NT]
    cmp  x21, x9
    b.hs 3f
    ldr  x9, [x19, #CV_TABLES]
    ldr  x0, [x9, x21, lsl #3]
    ldr  x9, [x20, #CV_TABLES]
    str  x0, [x9, x21, lsl #3]
    add  x0, x0, #TBL_REFS
    mov  x1, #1
    bl   atomic_fetch_add
    add  x21, x21, #1
    b    1b
3:  // indexes
    ldr  x0, [x19, #CV_ICAP]
    cbz  x0, 9f
    lsl  x0, x0, #3
    bl   malloc
    cbz  x0, .Lcv_oom
    str  x0, [x20, #CV_IDX]
    ldr  x9, [x19, #CV_ICAP]
    str  x9, [x20, #CV_ICAP]
    ldr  x9, [x19, #CV_NI]
    str  x9, [x20, #CV_NI]
    mov  x21, #0
4:  ldr  x9, [x19, #CV_NI]
    cmp  x21, x9
    b.hs 9f
    ldr  x9, [x19, #CV_IDX]
    ldr  x0, [x9, x21, lsl #3]
    ldr  x9, [x20, #CV_IDX]
    str  x0, [x9, x21, lsl #3]
    add  x0, x0, #IX_REFS
    mov  x1, #1
    bl   atomic_fetch_add
    add  x21, x21, #1
    b    4b
9:  mov  x0, x20
    LEAVE 3
.Lcv_oom:
    // out of memory while cloning: give up (cannot unwind safely here)
    bl   abort
ENDF cv_clone

// cat_release(x0 CatVer*): drop one reference; the last one frees the
// version and releases its tables and indexes.
//   x19 version, x20 i
FUNC cat_release
    ENTER 2
    mov  x19, x0
    cbz  x0, 9f
    mov  x1, #-1
    bl   atomic_fetch_add
    cmp  x0, #1
    b.ne 9f
    mov  x20, #0
1:  ldr  x9, [x19, #CV_NI]
    cmp  x20, x9
    b.hs 2f
    ldr  x9, [x19, #CV_IDX]
    ldr  x0, [x9, x20, lsl #3]
    bl   index_unref
    add  x20, x20, #1
    b    1b
2:  mov  x20, #0
3:  ldr  x9, [x19, #CV_NT]
    cmp  x20, x9
    b.hs 4f
    ldr  x9, [x19, #CV_TABLES]
    ldr  x0, [x9, x20, lsl #3]
    bl   table_unref
    add  x20, x20, #1
    b    3b
4:  ldr  x0, [x19, #CV_IDX]
    bl   free
    ldr  x0, [x19, #CV_TABLES]
    bl   free
    mov  x0, x19
    bl   free
9:  LEAVE 2
ENDF cat_release

// cat_init(): the initial (empty) current version.
FUNC cat_init
    ENTER 0
    mov  x0, #0
    bl   cv_clone
    ADR_L x1, g_cat_cur
    str  x0, [x1]
    LEAVE 0
ENDF cat_init

// cat_read_begin(): pin the current version for this request.
FUNC cat_read_begin
    ENTER 1
    TLS_LDR x0, g_cat_mode
    cbnz x0, 9f
    ADR_L x0, g_cat_lock
    bl   pthread_mutex_lock
    LDR_G x19, g_cat_cur
    cbz  x19, 1f
    add  x0, x19, #CV_REFS
    mov  x1, #1
    bl   atomic_fetch_add
1:  ADR_L x0, g_cat_lock
    bl   pthread_mutex_unlock
    cbnz x19, 2f
    mov  x0, #0                         // no catalog yet (unit tests)
    bl   cv_clone
    mov  x19, x0
2:  TLS_ADDR x0, g_cat
    str  x19, [x0]
    mov  x9, #MODE_READ
    str  x9, [x0, #8]                   // g_cat_mode follows g_cat
9:  LEAVE 1
ENDF cat_read_begin

// cat_write_begin(): serialise with other mutations and edit a private copy
// of the latest version (a pinned read snapshot is released first).
FUNC cat_write_begin
    ENTER 1
    TLS_LDR x0, g_cat_mode
    cmp  x0, #MODE_WRITE
    b.eq 9f
    cmp  x0, #MODE_READ
    b.ne 1f
    TLS_LDR x0, g_cat
    bl   cat_release
1:  ADR_L x0, g_cat_wlock
    bl   pthread_mutex_lock
    ADR_L x0, g_cat_lock
    bl   pthread_mutex_lock
    LDR_G x0, g_cat_cur
    bl   cv_clone
    mov  x19, x0
    ADR_L x0, g_cat_lock
    bl   pthread_mutex_unlock
    TLS_ADDR x0, g_cat
    str  x19, [x0]
    mov  x9, #MODE_WRITE
    str  x9, [x0, #8]
9:  LEAVE 1
ENDF cat_write_begin

// cat_end(w0 commit): end of a request. A read snapshot is released; a write
// copy is published (commit) or discarded, and the writer mutex released.
FUNC cat_end
    ENTER 2
    mov  w20, w0
    TLS_LDR x19, g_cat
    TLS_LDR x9, g_cat_mode
    TLS_ADDR x10, g_cat
    stp  xzr, xzr, [x10]                // g_cat = 0, g_cat_mode = NONE
    cmp  x9, #MODE_READ
    b.ne 1f
    mov  x0, x19
    bl   cat_release
    b    9f
1:  cmp  x9, #MODE_WRITE
    b.ne 9f
    cbz  w20, 2f
    ADR_L x0, g_cat_lock
    bl   pthread_mutex_lock
    ADR_L x9, g_cat_cur
    ldr  x20, [x9]                      // old current
    str  x19, [x9]
    ADR_L x0, g_cat_lock
    bl   pthread_mutex_unlock
    mov  x19, x20                       // release the old version
2:  mov  x0, x19
    bl   cat_release
    ADR_L x0, g_cat_wlock
    bl   pthread_mutex_unlock
9:  LEAVE 2
ENDF cat_end

// cat_cur() -> x0 CatVer* of this request (starts a write transaction when
// none is active, e.g. in unit tests that build catalogs directly).
FUNC cat_cur
    TLS_LDR x0, g_cat
    cbz  x0, 1f
    ret
1:  stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    bl   cat_write_begin
    TLS_LDR x0, g_cat
    ldp  x29, x30, [sp], #16
    ret
ENDF cat_cur

// catalog_count() -> x0 number of tables in the current version
FUNC catalog_count
    ENTER 1
    ADR_L x0, g_cat_lock
    bl   pthread_mutex_lock
    LDR_G x9, g_cat_cur
    mov  x19, #0
    cbz  x9, 1f
    ldr  x19, [x9, #CV_NT]
1:  ADR_L x0, g_cat_lock
    bl   pthread_mutex_unlock
    mov  x0, x19
    LEAVE 1
ENDF catalog_count

// catalog_find(x0 name ptr, x1 len) -> x0 Table* or 0
//   x19 name, x20 len, x21 version, x22 i, x23 table
FUNC catalog_find
    ENTER 4
    mov  x19, x0
    mov  x20, x1
    bl   cat_cur
    mov  x21, x0
    mov  x22, #0
1:  ldr  x9, [x21, #CV_NT]
    cmp  x22, x9
    b.hs 8f
    ldr  x9, [x21, #CV_TABLES]
    ldr  x23, [x9, x22, lsl #3]
    ldr  x2, [x23, #TBL_NAME]
    ldr  x3, [x2, #STR_LEN]
    add  x2, x2, #STR_DATA
    mov  x0, x19
    mov  x1, x20
    bl   ci_eq
    cbnz w0, 9f
    add  x22, x22, #1
    b    1b
8:  mov  x23, #0
9:  mov  x0, x23
    LEAVE 4
ENDF catalog_find

// catalog_add(x0 Table*): append to this request's (writable) version. The
// statistics are computed now, so published tables are never modified.
//   x19 table, x20 version, x21 new capacity
FUNC catalog_add
    ENTER 3
    mov  x19, x0
    bl   table_stats
    bl   cat_cur
    mov  x20, x0
    ldr  x1, [x20, #CV_NT]
    ldr  x2, [x20, #CV_TCAP]
    cmp  x1, x2
    b.lo 2f
    lsl  x2, x2, #1
    cmp  x2, #16
    mov  x3, #16
    csel x21, x2, x3, hs
    ldr  x0, [x20, #CV_TABLES]
    lsl  x1, x21, #3
    bl   realloc
    cbnz x0, 1f
    RAISE ERR_RESOURCE_LIMIT, "out of memory"
1:  str  x0, [x20, #CV_TABLES]
    str  x21, [x20, #CV_TCAP]
2:  ldr  x0, [x20, #CV_TABLES]
    ldr  x1, [x20, #CV_NT]
    str  x19, [x0, x1, lsl #3]
    add  x1, x1, #1
    str  x1, [x20, #CV_NT]
    add  x0, x19, #TBL_REFS
    mov  x1, #1
    bl   atomic_fetch_add
    LEAVE 3
ENDF catalog_add

// table_free(x0 Table*): release the table's arena and the table record.
FUNC table_free
    ENTER 1
    mov  x19, x0
    add  x0, x0, #TBL_ARENA
    bl   arena_free
    mov  x0, x19
    bl   free
    LEAVE 1
ENDF table_free

// table_unref(x0 Table*): drop a version's reference; the last frees it.
FUNC table_unref
    ENTER 1
    mov  x19, x0
    add  x0, x0, #TBL_REFS
    mov  x1, #-1
    bl   atomic_fetch_add
    cmp  x0, #1
    b.ne 9f
    mov  x0, x19
    bl   table_free
9:  LEAVE 1
ENDF table_unref

// catalog_remove(x0 Table*): unlink from this request's version and drop
// its indexes. The table itself lives on while older versions use it.
//   x19 table, x20 version
FUNC catalog_remove
    ENTER 2
    mov  x19, x0
    bl   cat_cur
    mov  x20, x0
    ldr  x1, [x20, #CV_TABLES]
    ldr  x2, [x20, #CV_NT]
    mov  x3, #0
1:  cmp  x3, x2
    b.hs 9f                     // not in catalog: nothing to do
    ldr  x4, [x1, x3, lsl #3]
    cmp  x4, x19
    b.eq 2f
    add  x3, x3, #1
    b    1b
2:  // shift the tail down to keep insertion order
    sub  x2, x2, #1
3:  cmp  x3, x2
    b.hs 4f
    add  x5, x3, #1
    ldr  x4, [x1, x5, lsl #3]
    str  x4, [x1, x3, lsl #3]
    mov  x3, x5
    b    3b
4:  str  x2, [x20, #CV_NT]
    mov  x0, x19
    bl   index_drop_table           // its indexes go with it
    mov  x0, x19
    bl   table_unref
9:  LEAVE 2
ENDF catalog_remove

// catalog_reset(): drop every table (and index) of this request's version.
//   x19 version, x20 i
FUNC catalog_reset
    ENTER 2
    bl   index_reset
    bl   cat_cur
    mov  x19, x0
    ldr  x20, [x19, #CV_NT]
1:  cbz  x20, 2f
    sub  x20, x20, #1
    ldr  x9, [x19, #CV_TABLES]
    ldr  x0, [x9, x20, lsl #3]
    bl   table_unref
    b    1b
2:  str  xzr, [x19, #CV_NT]
    LEAVE 2
ENDF catalog_reset

// catalog_snapshot() -> x0 Table** (request-arena copy), x1 count
//   x19 copy, x20 count, x21 version
FUNC catalog_snapshot
    ENTER 3
    bl   cat_cur
    mov  x21, x0
    ldr  x20, [x21, #CV_NT]
    lsl  x0, x20, #3
    add  x0, x0, #8
    bl   arena_alloc
    mov  x19, x0
    ldr  x1, [x21, #CV_TABLES]
    lsl  x2, x20, #3
    cbz  x2, 1f
    bl   memcpy
1:  mov  x0, x19
    mov  x1, x20
    LEAVE 3
ENDF catalog_snapshot

    NOTE_GNU_STACK
