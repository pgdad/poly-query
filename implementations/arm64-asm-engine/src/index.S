// =============================================================================
// index.S — secondary indexes (indexes-and-planning.md §2).
//
//   index_list(x0 Table*) -> x0 Index** (request arena), x1 count
// =============================================================================
#include "pq.inc"
#include "frame.inc"

    .text

// index_list(x0 Table*) -> x0 Index** (request arena), x1 count
FUNC index_list
    mov  x0, #0
    mov  x1, #0
    ret
ENDF index_list

    NOTE_GNU_STACK
