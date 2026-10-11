// =============================================================================
// frame.inc — function prologue/epilogue macros (AAPCS64 frame records).
//
//   ENTER np        push x29/x30 and np pairs of callee-saved registers
//                   (np = 0..5 covering x19..x28); sets x29 = sp
//   LEAVE np        undo ENTER and return
//   LEAVE_NORET np  undo ENTER without returning (before a tail call)
//
// The frame is 16 + 16*np bytes, so sp stays 16-byte aligned. Local stack
// space is allocated separately with sub/add sp.
// =============================================================================
#ifndef FRAME_INC
#define FRAME_INC

.macro ENTER np
    stp  x29, x30, [sp, #-(16 + 16 * \np)]!
    mov  x29, sp
    .if \np >= 1
    stp  x19, x20, [sp, #16]
    .endif
    .if \np >= 2
    stp  x21, x22, [sp, #32]
    .endif
    .if \np >= 3
    stp  x23, x24, [sp, #48]
    .endif
    .if \np >= 4
    stp  x25, x26, [sp, #64]
    .endif
    .if \np >= 5
    stp  x27, x28, [sp, #80]
    .endif
.endm

.macro LEAVE_NORET np
    .if \np >= 5
    ldp  x27, x28, [sp, #80]
    .endif
    .if \np >= 4
    ldp  x25, x26, [sp, #64]
    .endif
    .if \np >= 3
    ldp  x23, x24, [sp, #48]
    .endif
    .if \np >= 2
    ldp  x21, x22, [sp, #32]
    .endif
    .if \np >= 1
    ldp  x19, x20, [sp, #16]
    .endif
    ldp  x29, x30, [sp], #(16 + 16 * \np)
.endm

.macro LEAVE np
    LEAVE_NORET \np
    ret
.endm

// RAISE_S code, "prefix", strreg: raise with message prefix + 'Str contents'
.macro RAISE_S code, msg, sreg
    ldr  x3, [\sreg, #STR_LEN]
    add  x2, \sreg, #STR_DATA
    mov  w0, #\code
    adr  x1, 9996f
    b    pq_raise_s
9996: .asciz "\msg"
    .p2align 2
.endm

#endif
