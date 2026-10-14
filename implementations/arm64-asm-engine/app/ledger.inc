// =============================================================================
// ledger.inc — shared definitions of the pqledger application
// (spec/apps/pqledger.md). The application uses the engine only through the
// public embedding API (include/polyquery.inc, lib/libpolyquery.a).
//
// Module map (app/*.S):
//   main.S      command line, configuration lookup, command dispatch
//   commands.S  the commands (SQL built here, executed by the engine)
//   config.S    configuration file, rules file, budget file
//   bankcsv.S   bank statement CSV reader: dates, amounts, merchants
//   output.S    result rendering: table / csv / json
//   util.S      byte buffers, files, strings, errors
//
// Conventions: AAPCS64 everywhere (frame records, x19-x28 preserved, 16-byte
// stack alignment). Errors that end the program call `fail` (never returns),
// which prints `pqledger: error: MESSAGE` to stderr and exits with the
// given status; stdout is only written after a command succeeded, so a
// failing command prints nothing to stdout.
// =============================================================================
#ifndef LEDGER_INC
#define LEDGER_INC

#include "polyquery.inc"

// ---------------------------------------------------------------- macros -----
.macro FUNC name
    .text
    .global \name
    .type \name, %function
    .p2align 2
\name:
.endm

.macro LFUNC name
    .text
    .type \name, %function
    .p2align 2
\name:
.endm

.macro ENDF name
    .size \name, .-\name
.endm

// address of a symbol (PC relative, PIE)
.macro ADR_L reg, sym
    adrp \reg, \sym
    add  \reg, \reg, :lo12:\sym
.endm

// 64-bit load of a global
.macro LDR_G reg, sym
    adrp \reg, \sym
    ldr  \reg, [\reg, :lo12:\sym]
.endm

// 64-bit store of a register into a global (tmp is clobbered)
.macro STR_G reg, sym, tmp
    adrp \tmp, \sym
    str  \reg, [\tmp, :lo12:\sym]
.endm

// value of a glibc data symbol (stdin, stdout, stderr) through the GOT
.macro GOT_LOAD reg, sym
    adrp \reg, :got:\sym
    ldr  \reg, [\reg, :got_lo12:\sym]
    ldr  \reg, [\reg]
.endm

// ENTER np / LEAVE np: frame record plus np pairs of x19..x28 (np = 0..5)
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

// FAIL code, "message": fail with a constant message (never returns)
.macro FAIL code, msg
    mov  w0, #\code
    adr  x1, 9995f
    bl   fail
9995: .asciz "\msg"
    .p2align 2
.endm

// CSTR reg, "text": address of a constant C string
.macro CSTR reg, text
    adr  \reg, 9994f
    b    9993f
9994: .asciz "\text"
    .p2align 2
9993:
.endm

.macro NOTE_GNU_STACK
    .section .note.GNU-stack,"",%progbits
.endm

// ------------------------------------------------------------ exit codes -----
#define EX_OK       0
#define EX_USAGE    1
#define EX_CONFIG   2
#define EX_OVER     3
#define EX_IMPORT   4
#define EX_QUERY    5
#define EX_STATE    6
#define EX_OTHER    7

// ---------------------------------------------------------------- Buf --------
// Growable byte buffer (util.S). Zero-initialised = empty. The bytes are
// malloc'ed; buf_cstr NUL-terminates without changing the length.
#define BUF_PTR     0
#define BUF_LEN     8
#define BUF_CAP     16
#define BUF_SIZE    32

// ------------------------------------------------------ output formats -------
#define OF_UNSET    -1
#define OF_TABLE    0
#define OF_CSV      1
#define OF_JSON     2

// --------------------------------------------------- import settings (IS) ----
// Effective [import] settings of one account (config.S cfg_import_settings).
// Column references are C strings exactly as configured (a positive decimal
// integer = 1-based position, otherwise a header name).
#define IS_DELIM        0       // u8 delimiter byte
#define IS_HEADER       4       // u32 1 = header row
#define IS_SKIP         8       // u64 skip_lines
#define IS_DATE_COL     16      // cstr
#define IS_DATE_FMT     24      // u32 DF_*
#define IS_DESC_COL     32      // cstr
#define IS_AMOUNT_MODE  40      // u32 AM_*
#define IS_AMOUNT_COL   48      // cstr
#define IS_DEBIT_COL    56      // cstr
#define IS_CREDIT_COL   64      // cstr
#define IS_DEC_SEP      72      // u8 '.' or ','
#define IS_THOU_SEP     76      // u8: 0 = none, ',', '.', ' ', '\''
#define IS_CURRENCY     80      // cstr (may be empty "")
#define IS_INVERT       88      // u32 1 = invert_sign
#define IS_SIZE         96

#define DF_YMD_DASH     0       // YYYY-MM-DD
#define DF_YMD          1       // YYYYMMDD
#define DF_MDY_SLASH    2       // MM/DD/YYYY
#define DF_DMY_SLASH    3       // DD/MM/YYYY
#define DF_DMY_DOT      4       // DD.MM.YYYY

#define AM_SIGNED       0
#define AM_DEBIT_CREDIT 1

// ------------------------------------------------------ bank records (REC) ---
// One converted bank-statement record (bankcsv.S bank_read).
#define REC_DATE        0       // u64 date as YYYYMMDD (e.g. 20260131)
#define REC_AMOUNT      8       // i64 amount in cents (negative = money out)
#define REC_DESC        16      // u8* description (trimmed; not NUL-terminated)
#define REC_DESC_LEN    24      // u64
#define REC_MERCH       32      // u8* merchant (normalized, §6.3)
#define REC_MERCH_LEN   40      // u64
#define REC_SIZE        48

// --------------------------------------------------------- rules (RULE) ------
#define RULE_CAT        0       // cstr category
#define RULE_PAT        8       // cstr pattern as written (trimmed)
#define RULE_SIZE       16

// -------------------------------------------------------- budgets (BUD) ------
#define BUD_CAT         0       // cstr category
#define BUD_CENTS       8       // i64 monthly budget in cents
#define BUD_SIZE        16

#endif
