/* TEMPORARY stubs until functions.S is merged */
#include "pq.inc"
#include "sql.inc"
    .section .note.GNU-stack, "", @progbits
    .text
FUNC bind_scalar_func
    sub $8, %rsp
    RAISE E_UNSUPPORTED, "stub"
ENDF bind_scalar_func
FUNC bind_special
    sub $8, %rsp
    RAISE E_UNSUPPORTED, "stub"
ENDF bind_special
FUNC eval_scalar_func
    sub $8, %rsp
    RAISE E_UNSUPPORTED, "stub"
ENDF eval_scalar_func
FUNC eval_special
    sub $8, %rsp
    RAISE E_UNSUPPORTED, "stub"
ENDF eval_special
