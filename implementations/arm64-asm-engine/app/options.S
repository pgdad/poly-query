// =============================================================================
// options.S — pqledger command-line state shared by the modules: the output
// buffer, the effective output format, the parsed option values and
// positional arguments (filled by main.S parse_args), and parse_month.
// Kept apart from main.S so the module tests can link without main.o.
// =============================================================================
#include "ledger.inc"

    .bss
    .p2align 3
    .global g_out, g_format, g_opt_month, g_opt_from, g_opt_to
    .global g_opt_account, g_opt_top, g_opt_category, g_opt_uncat
    .global g_opt_clear, g_pos0, g_pos1, g_npos, g_config_path
g_out:          .skip BUF_SIZE  // command output (stdout on success)
g_format:       .skip 8         // OF_* effective output format
g_opt_month:    .skip 8         // option values (cstr) or 0
g_opt_from:     .skip 8
g_opt_to:       .skip 8
g_opt_account:  .skip 8
g_opt_top:      .skip 8
g_opt_category: .skip 8
g_opt_uncat:    .skip 8         // flags: 1 if given
g_opt_clear:    .skip 8
g_pos0:         .skip 8         // positional arguments
g_pos1:         .skip 8
g_npos:         .skip 8
g_config_path:  .skip 8         // configuration file in use

    .text

// parse_month(x0 cstr) -> x0 month index y*12 + (m-1), or -1 if not a
// valid YYYY-MM (year 0001-9999, month 01-12)   (leaf)
FUNC parse_month
    mov  x9, x0
    mov  x0, #-1
    mov  x10, #0                    // year
    mov  x11, #0
1:  ldrb w12, [x9, x11]
    sub  w12, w12, #'0'
    cmp  w12, #9
    b.hi 9f
    mov  x13, #10
    madd x10, x10, x13, x12
    add  x11, x11, #1
    cmp  x11, #4
    b.lo 1b
    ldrb w12, [x9, #4]
    cmp  w12, #'-'
    b.ne 9f
    ldrb w12, [x9, #5]
    ldrb w13, [x9, #6]
    ldrb w14, [x9, #7]
    cbnz w14, 9f
    sub  w12, w12, #'0'
    sub  w13, w13, #'0'
    cmp  w12, #9
    b.hi 9f
    cmp  w13, #9
    b.hi 9f
    mov  w14, #10
    madd w12, w12, w14, w13         // month
    sub  w12, w12, #1
    cmp  w12, #11
    b.hi 9f
    cbz  x10, 9f
    mov  x13, #12
    madd x0, x10, x13, x12
9:  ret
ENDF parse_month

    NOTE_GNU_STACK
