// =============================================================================
// index.S — secondary indexes (indexes-and-planning.md §2).
//
//   index_list(x0 Table*) -> x0 Index** (request arena), x1 count
//   index_check_specs(x0 XS* specs, x1 count, x2 Table* being replaced or 0)
//       raises ALREADY_EXISTS if a spec's name is already used by an index
//       (ignoring indexes of the table being replaced)
//   index_create_specs(x0 Table*, x1 XS* specs, x2 count)
//       creates (builds) the indexes described by the specs
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

// (stub)
FUNC index_check_specs
    ret
ENDF index_check_specs

// (stub)
FUNC index_create_specs
    ret
ENDF index_create_specs

    NOTE_GNU_STACK
