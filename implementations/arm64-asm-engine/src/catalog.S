// =============================================================================
// catalog.S — the in-memory catalog of tables.
//
// Tables live in a malloc-backed pointer array. Each Table owns an arena with
// all its data; removing a table frees that arena. Name matching is ASCII
// case-insensitive (ingestion.md, semantics.md §1).
// =============================================================================
#include "pq.inc"

    .bss
    .p2align 3
g_tables:   .skip 8         // Table** array
g_ntables:  .skip 8
g_tcap:     .skip 8
    .text

// catalog_find(x0 name ptr, x1 len) -> x0 Table* or 0
FUNC catalog_find
    stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    mov  x19, x0
    mov  x20, x1
    LDR_G x21, g_tables
    LDR_G x22, g_ntables
    mov  x23, #0
1:  cmp  x23, x22
    b.hs 8f
    ldr  x24, [x21, x23, lsl #3]
    ldr  x2, [x24, #TBL_NAME]
    ldr  x3, [x2, #STR_LEN]
    add  x2, x2, #STR_DATA
    mov  x0, x19
    mov  x1, x20
    bl   ci_eq
    cbnz w0, 9f
    add  x23, x23, #1
    b    1b
8:  mov  x24, #0
9:  mov  x0, x24
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x23, x24, [sp, #48]
    ldp  x29, x30, [sp], #64
    ret
ENDF catalog_find

// catalog_add(x0 Table*)
FUNC catalog_add
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    mov  x19, x0
    LDR_G x1, g_ntables
    LDR_G x2, g_tcap
    cmp  x1, x2
    b.lo 2f
    lsl  x2, x2, #1
    cmp  x2, #16
    mov  x3, #16
    csel x20, x2, x3, hs
    LDR_G x0, g_tables
    lsl  x1, x20, #3
    bl   realloc
    cbnz x0, 1f
    RAISE ERR_RESOURCE_LIMIT, "out of memory"
1:  ADR_L x1, g_tables
    str  x0, [x1]
    ADR_L x1, g_tcap
    str  x20, [x1]
2:  LDR_G x0, g_tables
    LDR_G x1, g_ntables
    str  x19, [x0, x1, lsl #3]
    add  x1, x1, #1
    ADR_L x2, g_ntables
    str  x1, [x2]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF catalog_add

// table_free(x0 Table*): release the table's arena and the table record.
FUNC table_free
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    str  x19, [sp, #16]
    mov  x19, x0
    add  x0, x0, #TBL_ARENA
    bl   arena_free
    mov  x0, x19
    bl   free
    ldr  x19, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF table_free

// catalog_remove(x0 Table*): unlink and free.
FUNC catalog_remove
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    LDR_G x1, g_tables
    LDR_G x2, g_ntables
    mov  x3, #0
1:  cmp  x3, x2
    b.hs 9f                     // not in catalog: nothing to do
    ldr  x4, [x1, x3, lsl #3]
    cmp  x4, x0
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
4:  ADR_L x4, g_ntables
    str  x2, [x4]
    bl   table_free
9:  ldp  x29, x30, [sp], #16
    ret
ENDF catalog_remove

// catalog_reset(): drop every table.
FUNC catalog_reset
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    LDR_G x19, g_tables
    LDR_G x20, g_ntables
1:  cbz  x20, 2f
    sub  x20, x20, #1
    ldr  x0, [x19, x20, lsl #3]
    bl   table_free
    b    1b
2:  ADR_L x0, g_ntables
    str  xzr, [x0]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF catalog_reset

// catalog_snapshot() -> x0 Table** (request-arena copy), x1 count
FUNC catalog_snapshot
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    LDR_G x20, g_ntables
    lsl  x0, x20, #3
    add  x0, x0, #8
    bl   arena_alloc
    mov  x19, x0
    LDR_G x1, g_tables
    lsl  x2, x20, #3
    cbz  x2, 1f
    bl   memcpy
1:  mov  x0, x19
    mov  x1, x20
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF catalog_snapshot

    NOTE_GNU_STACK
