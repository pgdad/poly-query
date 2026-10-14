// =============================================================================
// config.S — pqledger configuration file (§3), rules file (§5.1) and budget
// file (§5.2).
//
//   cfg_load(x0 path)                     parse + validate the configuration;
//       sets g_cfg_data_dir, g_cfg_rules_file, g_cfg_budget_file (cstr, paths
//       resolved against the file's directory; rules/budget 0 if absent),
//       g_cfg_format (OF_UNSET if absent), g_cfg_threads, g_cfg_memory_mb
//       (0 if absent). Every error: exit 2 (EX_CONFIG).
//   cfg_import_settings(x0 account cstr or 0, x1 IS* out)
//       fill the IS_SIZE struct with the effective import settings:
//       [account NAME] value, else [import] value, else the default.
//   rules_load(x0 path) -> x0 RULE array (xmalloc), x1 count
//   budget_load(x0 path) -> x0 BUD array (xmalloc), x1 count
//
// All three files share the line syntax of §3.2, handled by the line
// scanner below (scan_begin / next_line / parse_line). Errors are reported as
// "PATH:LINE: message" through line_failf (the LFAIL macro).
//
// Internal storage: the [import] overrides and every [account NAME] section
// are kept as an OVR record: the values in an IS struct plus a bit mask of
// the keys actually set (bit i = entry i of imp_keys).
// =============================================================================
#include "ledger.inc"

// ------------------------------------------------------- OVR record ----------
#define OVR_NEXT    0       // next account record (list)
#define OVR_NAME    8       // cstr account name (0 for [import])
#define OVR_MASK    16      // u64 bit i set = imp_keys[i] given
#define OVR_LINE    24      // u64 line of the section header
#define OVR_IS      32      // IS struct with the given values
#define OVR_SIZE    (OVR_IS + IS_SIZE)

// sections (s_sect); SEC_LEDGER..SEC_ENGINE = 1 + index in sect_words
#define SEC_NONE    0
#define SEC_LEDGER  1
#define SEC_IMPORT  2
#define SEC_OUTPUT  3
#define SEC_ENGINE  4
#define SEC_ACCOUNT 5

// parse_line results
#define PL_SKIP     0       // blank line or comment
#define PL_SECTION  1       // [NAME]
#define PL_ASSIGN   2       // KEY = VALUE

// value kinds of the [import] keys; kinds >= K_U64 are 8-byte fields
#define K_DELIM     0
#define K_BOOL      1
#define K_DATEFMT   2
#define K_AMODE     3
#define K_DECSEP    4
#define K_THOUSEP   5
#define K_U64       6
#define K_COL       7
#define K_TEXT      8
#define NIMPKEYS    14

// LFAIL "msg": fail(EX_CONFIG, "%s:%d: msg", s_path, s_lineno, x1, x2);
// x1/x2 are the optional arguments of msg (never returns, clobbers x0)
.macro LFAIL msg
    adr  x0, 9996f
    bl   line_failf
9996: .asciz "%s:%d: \msg"
    .p2align 2
.endm

// FFAIL "msg": fail(EX_CONFIG, "%s: msg", s_path) (file-level error)
.macro FFAIL msg
    LDR_G x2, s_path
    mov  w0, #EX_CONFIG
    adr  x1, 9997f
    bl   fail
9997: .asciz "%s: \msg"
    .p2align 2
.endm

// ------------------------------------------------------------- tables -------
// Word lists: consecutive C strings ended by an empty string (word_index).
    .section .rodata
sect_words:     .asciz "ledger", "import", "output", "engine", ""
ledger_keys:    .asciz "data_dir", "rules_file", "budget_file", ""
output_keys:    .asciz "format", ""
engine_keys:    .asciz "threads", "memory_mb", ""
fmt_words:      .asciz "table", "csv", "json", ""          // = OF_*
bool_words:     .asciz "false", "true", ""
tab_words:      .asciz "tab", ""
df_words:       .asciz "YYYY-MM-DD", "YYYYMMDD", "MM/DD/YYYY", "DD/MM/YYYY"
                .asciz "DD.MM.YYYY", ""                   // = DF_*
am_words:       .asciz "signed", "debit_credit", ""        // = AM_*
dec_words:      .asciz ".", ",", ""
thou_words:     .asciz "none", ",", ".", "space", "'", ""
imp_keys:       .asciz "delimiter", "header", "skip_lines", "date_column"
                .asciz "date_format", "description_column", "amount_mode"
                .asciz "amount_column", "debit_column", "credit_column"
                .asciz "decimal_separator", "thousands_separator"
                .asciz "currency_symbol", "invert_sign", ""
// per imp_keys entry: value kind and IS field offset
imp_kinds:      .byte K_DELIM, K_BOOL, K_U64, K_COL, K_DATEFMT, K_COL, K_AMODE
                .byte K_COL, K_COL, K_COL, K_DECSEP, K_THOUSEP, K_TEXT, K_BOOL
imp_offs:       .byte IS_DELIM, IS_HEADER, IS_SKIP, IS_DATE_COL, IS_DATE_FMT
                .byte IS_DESC_COL, IS_AMOUNT_MODE, IS_AMOUNT_COL, IS_DEBIT_COL
                .byte IS_CREDIT_COL, IS_DEC_SEP, IS_THOU_SEP, IS_CURRENCY
                .byte IS_INVERT
dec_bytes:      .byte '.', ','
thou_bytes:     .byte 0, ',', '.', ' ', '\''

s_def_date:     .asciz "Date"
s_def_desc:     .asciz "Description"
s_def_amount:   .asciz "Amount"
s_def_debit:    .asciz "Debit"
s_def_credit:   .asciz "Credit"
s_empty:        .asciz ""
s_account_sp:   .ascii "account "                          // 8 bytes, no NUL
s_uncat:        .asciz "uncategorized"
s_err_cfg:      .asciz "cannot read configuration file %s"
s_err_rules:    .asciz "cannot read rules file %s"
s_err_budget:   .asciz "cannot read budget file %s"

// ------------------------------------------------------------ globals -------
    .data
    .p2align 3
    .global g_cfg_format
g_cfg_format:       .quad OF_UNSET

    .bss
    .p2align 3
    .global g_cfg_data_dir, g_cfg_rules_file, g_cfg_budget_file
    .global g_cfg_threads, g_cfg_memory_mb
g_cfg_data_dir:     .skip 8
g_cfg_rules_file:   .skip 8
g_cfg_budget_file:  .skip 8
g_cfg_threads:      .skip 8
g_cfg_memory_mb:    .skip 8

// line scanner state (all three file kinds)
s_path:             .skip 8         // file being parsed (messages)
s_lineno:           .skip 8         // 1-based number of the current line
s_cur:              .skip 8         // next unread byte
s_end:              .skip 8         // end of the text

// configuration parse state; zeroed by cfg_load [s_cfg_state, s_cfg_end)
s_cfg_state:
s_sect:             .skip 8         // SEC_* of the current section
s_currec:           .skip 8         // OVR record of the current section
s_curmask:          .skip 8         // address of the current section's key mask
s_seen:             .skip 8         // bit i: sect_words[i] section seen
s_masks:            .skip 32        // key masks of ledger, -, output, engine
s_ledger_vals:      .skip 24        // raw data_dir, rules_file, budget_file
s_accounts:         .skip 8         // list of [account] OVR records
    .p2align 4
s_import:           .skip OVR_SIZE  // the [import] OVR record
s_cfg_end:

    .text

// =============================================================== helpers ====

// line_failf(x0 fmt "%s:%d: ...", x1 arg1, x2 arg2): never returns
LFUNC line_failf
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    mov  x5, x2
    mov  x4, x1
    mov  x1, x0
    LDR_G x2, s_path
    LDR_G x3, s_lineno
    mov  w0, #EX_CONFIG
    bl   fail
ENDF line_failf

// word_index(x0 word list, x1 ptr, x2 len) -> x0 index or -1   (leaf)
//   x3 index, x5 position in the entry
LFUNC word_index
    mov  x3, #0
1:  ldrb w4, [x0]
    cbz  w4, 8f                     // empty string: end of the list
    mov  x5, #0
2:  ldrb w4, [x0, x5]
    cmp  x5, x2
    b.eq 3f
    cbz  w4, 4f                     // entry shorter than the text
    ldrb w6, [x1, x5]
    cmp  w4, w6
    b.ne 4f
    add  x5, x5, #1
    b    2b
3:  cbz  w4, 9f                     // same length and bytes: found
4:  ldrb w4, [x0], #1               // skip past the entry's NUL
    cbnz w4, 4b
    add  x3, x3, #1
    b    1b
8:  mov  x0, #-1
    ret
9:  mov  x0, x3
    ret
ENDF word_index

// all_digits(x0 cstr) -> w0 1 if every byte is 0-9 (also for "")   (leaf)
LFUNC all_digits
1:  ldrb w1, [x0], #1
    cbz  w1, 9f
    sub  w1, w1, #'0'
    cmp  w1, #9
    b.ls 1b
    mov  w0, #0
    ret
9:  mov  w0, #1
    ret
ENDF all_digits

// ======================================================== line scanner ======

// scan_begin(x0 text, x1 len): start scanning; a leading UTF-8 BOM is skipped
LFUNC scan_begin
    add  x2, x0, x1
    STR_G x2, s_end, x9
    cmp  x1, #3
    b.lo 1f
    ldrb w3, [x0]
    cmp  w3, #0xEF
    b.ne 1f
    ldrb w3, [x0, #1]
    cmp  w3, #0xBB
    b.ne 1f
    ldrb w3, [x0, #2]
    cmp  w3, #0xBF
    b.ne 1f
    add  x0, x0, #3
1:  STR_G x0, s_cur, x9
    STR_G xzr, s_lineno, x9
    ret
ENDF scan_begin

// next_line() -> x0 ptr, x1 len (CR/LF removed, spaces/tabs trimmed),
//   w2 1 = a line, 0 = end of text. Counts s_lineno.
//   x3 end of text, x4 scan pointer
LFUNC next_line
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    LDR_G x0, s_cur
    LDR_G x3, s_end
    cmp  x0, x3
    b.hs 8f
    mov  x4, x0
1:  cmp  x4, x3
    b.hs 2f
    ldrb w5, [x4]
    cmp  w5, #'\n'
    b.eq 2f
    add  x4, x4, #1
    b    1b
2:  sub  x1, x4, x0
    cmp  x4, x3
    cinc x4, x4, lo                 // step over the '\n'
    STR_G x4, s_cur, x9
    LDR_G x9, s_lineno
    add  x9, x9, #1
    STR_G x9, s_lineno, x10
    cbz  x1, 3f                     // drop the CR of a CRLF line end
    sub  x9, x1, #1
    ldrb w5, [x0, x9]
    cmp  w5, #'\r'
    csel x1, x9, x1, eq
3:  bl   trim_ws
    mov  w2, #1
    ldp  x29, x30, [sp], #16
    ret
8:  mov  x0, #0
    mov  x1, #0
    mov  w2, #0
    ldp  x29, x30, [sp], #16
    ret
ENDF next_line

// decode_value(x0 ptr, x1 len) -> x0 cstr (xmalloc), x1 len
//   "..." loses its quotes; inside, \" -> " and \\ -> \ (other \ kept)
//   x19 source, x20 source length
LFUNC decode_value
    ENTER 1
    mov  x19, x0
    mov  x20, x1
    cmp  x1, #2
    b.lo 8f
    ldrb w9, [x0]
    cmp  w9, #'"'
    b.ne 8f
    sub  x10, x1, #1
    ldrb w9, [x0, x10]
    cmp  w9, #'"'
    b.ne 8f
    add  x19, x19, #1               // quoted: decode the inside
    sub  x20, x20, #2
    add  x0, x20, #1
    bl   xmalloc                    // x0 start, x1 write cursor, x2 index
    mov  x1, x0
    mov  x2, #0
1:  cmp  x2, x20
    b.hs 3f
    ldrb w3, [x19, x2]
    add  x2, x2, #1
    cmp  w3, #'\\'
    b.ne 2f
    cmp  x2, x20
    b.hs 2f
    ldrb w4, [x19, x2]
    mov  w5, #'\\'
    cmp  w4, #'"'
    ccmp w4, w5, #4, ne
    b.ne 2f
    mov  w3, w4                     // \" or \\: the escaped byte
    add  x2, x2, #1
2:  strb w3, [x1], #1
    b    1b
3:  strb wzr, [x1]
    sub  x1, x1, x0
    LEAVE 1
8:  bl   xstrndup                   // unquoted: copy as is
    mov  x1, x20
    LEAVE 1
ENDF decode_value

// parse_line(x0 ptr, x1 len: a trimmed line) -> w0 PL_*
//   PL_SECTION: x1 name ptr, x2 name len (inside the brackets)
//   PL_ASSIGN:  x1 key ptr, x2 key len (trimmed), x3 value cstr (decoded,
//               xmalloc), x4 value len
//   any other line form: "invalid line" error
//   x19 line, x20 line end, x21 '=', x22 key length
LFUNC parse_line
    ENTER 2
    cbz  x1, 7f
    ldrb w9, [x0]
    cmp  w9, #'#'
    b.eq 7f
    cmp  w9, #';'
    b.eq 7f
    cmp  w9, #'['
    b.ne 1f
    sub  x10, x1, #1
    ldrb w11, [x0, x10]
    cmp  w11, #']'
    b.ne 1f
    sub  x2, x1, #2
    add  x1, x0, #1
    mov  w0, #PL_SECTION
    LEAVE 2
1:  mov  x19, x0                    // assignment
    add  x20, x0, x1
    mov  x2, x1
    mov  w1, #'='
    bl   memchr
    cbnz x0, 2f
    LFAIL "invalid line (expected [SECTION] or KEY = VALUE)"
2:  mov  x21, x0
    mov  x0, x19
    sub  x1, x21, x19
    bl   trim_ws
    cbnz x1, 3f
    LFAIL "missing key before '='"
3:  mov  x19, x0
    mov  x22, x1
    add  x0, x21, #1
    sub  x1, x20, x0
    bl   trim_ws
    bl   decode_value
    mov  x3, x0
    mov  x4, x1
    mov  x1, x19
    mov  x2, x22
    mov  w0, #PL_ASSIGN
    LEAVE 2
7:  mov  w0, #PL_SKIP
    LEAVE 2
ENDF parse_line

// ===================================================== configuration ========

// mark_key(x0 mask address, x1 key index, x2 key ptr, x3 key len): record
// that the key was given; error if it already was in this section   (leaf)
LFUNC mark_key
    ldr  x4, [x0]
    lsr  x5, x4, x1
    tbnz x5, #0, 1f
    mov  x5, #1
    lsl  x5, x5, x1
    orr  x4, x4, x5
    str  x4, [x0]
    ret
1:  mov  x1, x3
    LFAIL "key '%.*s' repeated in this section"
ENDF mark_key

// imp_value(w0 kind K_*, x1 value cstr, x2 len) -> x0 value, w1 0 ok / 1 bad
//   x19 value, x20 length
LFUNC imp_value
    ENTER 1
    mov  x19, x1
    mov  x20, x2
    cmp  w0, #K_DELIM
    b.eq .Liv_delim
    cmp  w0, #K_BOOL
    b.eq .Liv_bool
    cmp  w0, #K_DATEFMT
    b.eq .Liv_datefmt
    cmp  w0, #K_AMODE
    b.eq .Liv_amode
    cmp  w0, #K_DECSEP
    b.eq .Liv_decsep
    cmp  w0, #K_THOUSEP
    b.eq .Liv_thousep
    cmp  w0, #K_U64
    b.eq .Liv_u64
    cmp  w0, #K_COL
    b.eq .Liv_col
    mov  x0, x19                    // K_TEXT: any text
    b    .Liv_ok

.Liv_delim:                         // `tab`, or one ASCII byte except " CR LF
    ADR_L x0, tab_words
    bl   .Liv_lookup
    tbnz x0, #63, 1f
    mov  x0, #'\t'
    b    .Liv_ok
1:  cmp  x20, #1
    b.ne .Liv_bad
    ldrb w0, [x19]
    cmp  w0, #0x80
    b.hs .Liv_bad
    cmp  w0, #'"'
    b.eq .Liv_bad
    cmp  w0, #'\r'
    b.eq .Liv_bad
    cmp  w0, #'\n'
    b.eq .Liv_bad
    b    .Liv_ok
.Liv_bool:
    ADR_L x0, bool_words
    b    .Liv_word
.Liv_datefmt:
    ADR_L x0, df_words
    b    .Liv_word
.Liv_amode:
    ADR_L x0, am_words
.Liv_word:                          // value = index in the word list
    bl   .Liv_lookup
    tbnz x0, #63, .Liv_bad
    b    .Liv_ok
.Liv_decsep:
    ADR_L x0, dec_words
    bl   .Liv_lookup
    tbnz x0, #63, .Liv_bad
    ADR_L x9, dec_bytes
    ldrb w0, [x9, x0]
    b    .Liv_ok
.Liv_thousep:
    ADR_L x0, thou_words
    bl   .Liv_lookup
    tbnz x0, #63, .Liv_bad
    ADR_L x9, thou_bytes
    ldrb w0, [x9, x0]
    b    .Liv_ok
.Liv_u64:
    mov  x0, x19
    mov  x1, x20
    bl   parse_u64
    LEAVE 1
.Liv_col:                           // header name, or a positive integer
    cbz  x20, .Liv_bad
    mov  x0, x19
    bl   all_digits
    cbz  w0, 2f
    mov  x0, x19
    mov  x1, x20
    bl   parse_u64
    cbnz w1, .Liv_bad
    cbz  x0, .Liv_bad
2:  mov  x0, x19
.Liv_ok:
    mov  w1, #0
    LEAVE 1
.Liv_bad:
    mov  x0, #0
    mov  w1, #1
    LEAVE 1

// local subroutine: word_index(x0 list, x19, x20); only x0..x6 change, so
// a plain bl is enough (x30 is restored by LEAVE from the frame record)
.Liv_lookup:
    mov  x1, x19
    mov  x2, x20
    b    word_index
ENDF imp_value

// cfg_section(x0 name ptr, x1 name len): a section header
//   x19 name, x20 length, x21 account name cstr, x22 account record
LFUNC cfg_section
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    mov  x2, x1
    mov  x1, x0
    ADR_L x0, sect_words
    bl   word_index
    tbnz x0, #63, .Lcs_account
    LDR_G x9, s_seen                // fixed section: at most once
    lsr  x10, x9, x0
    tbnz x10, #0, .Lcs_repeated
    mov  x10, #1
    lsl  x10, x10, x0
    orr  x9, x9, x10
    STR_G x9, s_seen, x10
    add  x9, x0, #1
    STR_G x9, s_sect, x10
    cmp  x9, #SEC_IMPORT
    b.eq 1f
    ADR_L x10, s_masks
    add  x10, x10, x0, lsl #3
    STR_G x10, s_curmask, x11
    b    .Lcs_done
1:  ADR_L x10, s_import
    LDR_G x11, s_lineno
    str  x11, [x10, #OVR_LINE]
    STR_G x10, s_currec, x11
    add  x10, x10, #OVR_MASK
    STR_G x10, s_curmask, x11
    b    .Lcs_done

.Lcs_account:                       // "account NAME"
    cmp  x20, #8
    b.ls .Lcs_unknown
    mov  x0, x19
    ADR_L x1, s_account_sp
    mov  x2, #8
    bl   memcmp
    cbnz w0, .Lcs_unknown
    add  x0, x19, #8
    sub  x1, x20, #8
    bl   xstrndup
    mov  x21, x0
    bl   valid_name
    cbnz w0, 1f
    mov  x1, x21
    LFAIL "invalid account name '%s'"
1:  LDR_G x22, s_accounts           // same account twice?
2:  cbz  x22, 3f
    ldr  x0, [x22, #OVR_NAME]
    mov  x1, x21
    bl   strcmp
    cbz  w0, .Lcs_repeated
    ldr  x22, [x22, #OVR_NEXT]
    b    2b
3:  mov  x0, #OVR_SIZE
    bl   xmalloc
    mov  w1, #0
    mov  x2, #OVR_SIZE
    bl   memset
    mov  x22, x0
    LDR_G x9, s_accounts
    str  x9, [x22, #OVR_NEXT]
    str  x21, [x22, #OVR_NAME]
    LDR_G x9, s_lineno
    str  x9, [x22, #OVR_LINE]
    STR_G x22, s_accounts, x9
    STR_G x22, s_currec, x9
    add  x9, x22, #OVR_MASK
    STR_G x9, s_curmask, x10
    mov  x9, #SEC_ACCOUNT
    STR_G x9, s_sect, x10
.Lcs_done:
    LEAVE 2
.Lcs_unknown:
    mov  x1, x20
    mov  x2, x19
    LFAIL "unknown section [%.*s]"
.Lcs_repeated:
    mov  x1, x20
    mov  x2, x19
    LFAIL "repeated section [%.*s]"
ENDF cfg_section

// cfg_assign(x0 key ptr, x1 key len, x2 value cstr, x3 value len)
//   x19 key, x20 key len, x21 value, x22 value len, x23 key index, x24 kind
LFUNC cfg_assign
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x22, x3
    LDR_G x9, s_sect
    cbz  x9, .Lca_before
    cmp  x9, #SEC_LEDGER
    b.eq .Lca_ledger
    cmp  x9, #SEC_OUTPUT
    b.eq .Lca_output
    cmp  x9, #SEC_ENGINE
    b.eq .Lca_engine

    ADR_L x0, imp_keys              // [import] / [account NAME]
    bl   .Lca_key
    ADR_L x9, imp_kinds
    ldrb w24, [x9, x23]
    mov  w0, w24
    mov  x1, x21
    mov  x2, x22
    bl   imp_value
    cbnz w1, .Lca_invalid
    LDR_G x9, s_currec
    add  x9, x9, #OVR_IS
    ADR_L x10, imp_offs
    ldrb w10, [x10, x23]
    cmp  w24, #K_U64
    b.hs 1f
    str  w0, [x9, x10]              // u8 / u32 field (stored as 32 bits)
    b    .Lca_done
1:  str  x0, [x9, x10]              // u64 / cstr field
    b    .Lca_done

.Lca_ledger:                        // paths: any non-empty text
    ADR_L x0, ledger_keys
    bl   .Lca_key
    cbz  x22, .Lca_invalid
    ADR_L x9, s_ledger_vals
    str  x21, [x9, x23, lsl #3]
    b    .Lca_done

.Lca_output:
    ADR_L x0, output_keys
    bl   .Lca_key
    ADR_L x0, fmt_words
    mov  x1, x21
    mov  x2, x22
    bl   word_index
    tbnz x0, #63, .Lca_invalid
    STR_G x0, g_cfg_format, x9
    b    .Lca_done

.Lca_engine:                        // integers >= 1
    ADR_L x0, engine_keys
    bl   .Lca_key
    mov  x0, x21
    mov  x1, x22
    bl   parse_u64
    cbnz w1, .Lca_invalid
    cbz  x0, .Lca_invalid
    cbnz x23, 2f
    STR_G x0, g_cfg_threads, x9
    b    .Lca_done
2:  STR_G x0, g_cfg_memory_mb, x9
.Lca_done:
    LEAVE 3

// local subroutine: x23 = index of key x19/x20 in word list x0, marked as
// given in the current section (unknown / repeated key: error). Returns
// with ret through x30 saved in x24 (x24 is free at that point).
.Lca_key:
    mov  x24, x30
    mov  x1, x19
    mov  x2, x20
    bl   word_index
    tbnz x0, #63, .Lca_unknown
    mov  x23, x0
    LDR_G x0, s_curmask
    mov  x1, x23
    mov  x2, x19
    mov  x3, x20
    bl   mark_key
    ret  x24

.Lca_before:
    LFAIL "assignment before the first section header"
.Lca_unknown:
    mov  x1, x20
    mov  x2, x19
    LFAIL "unknown key '%.*s'"
.Lca_invalid:
    mov  x1, x20
    mov  x2, x19
    LFAIL "invalid value for '%.*s'"
ENDF cfg_assign

// is_defaults(x0 IS*): the built-in import settings   (leaf)
LFUNC is_defaults
    mov  w1, #','
    str  w1, [x0, #IS_DELIM]
    mov  w1, #1
    str  w1, [x0, #IS_HEADER]
    str  xzr, [x0, #IS_SKIP]
    ADR_L x1, s_def_date
    str  x1, [x0, #IS_DATE_COL]
    mov  x1, #DF_YMD_DASH
    str  x1, [x0, #IS_DATE_FMT]
    ADR_L x1, s_def_desc
    str  x1, [x0, #IS_DESC_COL]
    mov  x1, #AM_SIGNED
    str  x1, [x0, #IS_AMOUNT_MODE]
    ADR_L x1, s_def_amount
    str  x1, [x0, #IS_AMOUNT_COL]
    ADR_L x1, s_def_debit
    str  x1, [x0, #IS_DEBIT_COL]
    ADR_L x1, s_def_credit
    str  x1, [x0, #IS_CREDIT_COL]
    mov  w1, #'.'
    str  w1, [x0, #IS_DEC_SEP]
    str  wzr, [x0, #IS_THOU_SEP]
    ADR_L x1, s_empty
    str  x1, [x0, #IS_CURRENCY]
    str  xzr, [x0, #IS_INVERT]
    ret
ENDF is_defaults

// is_merge(x0 IS* out, x1 OVR*): copy the fields given in the record   (leaf)
//   x2 mask, x3 kinds, x4 offsets, x5 key index
LFUNC is_merge
    ldr  x2, [x1, #OVR_MASK]
    add  x1, x1, #OVR_IS
    ADR_L x3, imp_kinds
    ADR_L x4, imp_offs
    mov  x5, #0
1:  lsr  x6, x2, x5
    tbz  x6, #0, 3f
    ldrb w7, [x4, x5]
    ldrb w8, [x3, x5]
    cmp  w8, #K_U64
    b.hs 2f
    ldr  w9, [x1, x7]
    str  w9, [x0, x7]
    b    3f
2:  ldr  x9, [x1, x7]
    str  x9, [x0, x7]
3:  add  x5, x5, #1
    cmp  x5, #NIMPKEYS
    b.lo 1b
    ret
ENDF is_merge

// is_effective(x0 IS* out, x1 account OVR* or 0): defaults < [import] < account
//   x19 out, x20 account record
LFUNC is_effective
    ENTER 1
    mov  x19, x0
    mov  x20, x1
    bl   is_defaults
    mov  x0, x19
    ADR_L x1, s_import
    bl   is_merge
    cbz  x20, 1f
    mov  x0, x19
    mov  x1, x20
    bl   is_merge
1:  LEAVE 1
ENDF is_effective

// check_numcol(x0 column cstr): with header = false a column must be a number
LFUNC check_numcol
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    str  x0, [sp, #16]
    bl   all_digits
    cbz  w0, 1f
    ldp  x29, x30, [sp], #32
    ret
1:  ldr  x1, [sp, #16]
    LFAIL "column '%s' is a header name but header = false"
ENDF check_numcol

// cfg_validate(x0 account OVR* or 0 for [import] alone): check the effective
// settings. Errors name the line of the section header.
//   x19 record, sp: IS struct
LFUNC cfg_validate
    ENTER 1
    sub  sp, sp, #IS_SIZE
    mov  x19, x0
    mov  x1, x0
    mov  x0, sp
    bl   is_effective
    ADR_L x9, s_import
    cmp  x19, #0
    csel x9, x9, x19, eq
    ldr  x9, [x9, #OVR_LINE]
    STR_G x9, s_lineno, x10
    ldr  w9, [sp, #IS_DEC_SEP]
    ldr  w10, [sp, #IS_THOU_SEP]
    cmp  w9, w10
    b.ne 1f
    LFAIL "decimal_separator and thousands_separator must differ"
1:  ldr  w9, [sp, #IS_HEADER]
    cbnz w9, 3f
    ldr  x0, [sp, #IS_DATE_COL]     // header = false: the used columns
    bl   check_numcol               // must be positions
    ldr  x0, [sp, #IS_DESC_COL]
    bl   check_numcol
    ldr  w9, [sp, #IS_AMOUNT_MODE]
    cmp  w9, #AM_SIGNED
    b.ne 2f
    ldr  x0, [sp, #IS_AMOUNT_COL]
    bl   check_numcol
    b    3f
2:  ldr  x0, [sp, #IS_DEBIT_COL]
    bl   check_numcol
    ldr  x0, [sp, #IS_CREDIT_COL]
    bl   check_numcol
3:  add  sp, sp, #IS_SIZE
    LEAVE 1
ENDF cfg_validate

// resolve_path(x0 config path, x1 value or 0) -> x0 value with the config
// file's directory prepended if the value is relative (0 stays 0)
//   x19 config path, x20 value, x21 directory length, x22 value length,
//   x23 result
LFUNC resolve_path
    ENTER 3
    mov  x19, x0
    mov  x0, x1
    cbz  x1, 9f
    mov  x20, x1
    ldrb w9, [x20]
    cmp  w9, #'/'
    b.eq 9f
    mov  x0, x19
    mov  w1, #'/'
    bl   strrchr
    cbz  x0, 8f
    sub  x21, x0, x19
    add  x21, x21, #1               // directory including the '/'
    mov  x0, x20
    bl   strlen
    mov  x22, x0
    add  x0, x21, x22
    add  x0, x0, #1
    bl   xmalloc
    mov  x23, x0
    mov  x1, x19
    mov  x2, x21
    bl   memcpy
    add  x0, x23, x21
    mov  x1, x20
    add  x2, x22, #1                // with the NUL
    bl   memcpy
    mov  x0, x23
    b    9f
8:  mov  x0, x20
9:  LEAVE 3
ENDF resolve_path

// open_lines(x0 path, x1 "cannot read" format) -> x0 text (for free):
// read the file and start the line scanner on it; exit 2 if unreadable
//   x19 path, x20 format
LFUNC open_lines
    ENTER 1
    mov  x19, x0
    mov  x20, x1
    STR_G x0, s_path, x9
    bl   read_file
    cbnz x0, 1f
    mov  x2, x19
    mov  x1, x20
    mov  w0, #EX_CONFIG
    bl   fail
1:  mov  x19, x0
    bl   scan_begin
    mov  x0, x19
    LEAVE 1
ENDF open_lines

// cfg_load(x0 path): see the header
//   x19 path, x20 file text, x21 account record
FUNC cfg_load
    ENTER 2
    mov  x19, x0
    ADR_L x0, s_cfg_state           // forget any earlier configuration
    mov  w1, #0
    ADR_L x2, s_cfg_end
    sub  x2, x2, x0
    bl   memset
    STR_G xzr, g_cfg_data_dir, x9
    STR_G xzr, g_cfg_rules_file, x9
    STR_G xzr, g_cfg_budget_file, x9
    STR_G xzr, g_cfg_threads, x9
    STR_G xzr, g_cfg_memory_mb, x9
    mov  x9, #OF_UNSET
    STR_G x9, g_cfg_format, x10
    mov  x0, x19
    ADR_L x1, s_err_cfg
    bl   open_lines
    mov  x20, x0

.Lcl_line:
    bl   next_line
    cbz  w2, .Lcl_end
    bl   parse_line
    cmp  w0, #PL_SECTION
    b.eq 1f
    b.hi 2f
    b    .Lcl_line                  // PL_SKIP
1:  mov  x0, x1
    mov  x1, x2
    bl   cfg_section
    b    .Lcl_line
2:  mov  x0, x1
    mov  x1, x2
    mov  x2, x3
    mov  x3, x4
    bl   cfg_assign
    b    .Lcl_line

.Lcl_end:
    mov  x0, x20
    bl   free
    LDR_G x9, s_seen
    tbnz x9, #0, 1f                 // bit 0: [ledger]
    FFAIL "missing [ledger] section"
1:  ADR_L x9, s_ledger_vals
    ldr  x1, [x9]
    cbnz x1, 2f
    FFAIL "missing data_dir in [ledger]"
2:  mov  x0, x19
    bl   resolve_path
    STR_G x0, g_cfg_data_dir, x9
    ADR_L x9, s_ledger_vals
    ldr  x1, [x9, #8]
    mov  x0, x19
    bl   resolve_path
    STR_G x0, g_cfg_rules_file, x9
    ADR_L x9, s_ledger_vals
    ldr  x1, [x9, #16]
    mov  x0, x19
    bl   resolve_path
    STR_G x0, g_cfg_budget_file, x9

    mov  x0, #0                     // [import] on its own
    bl   cfg_validate
    LDR_G x21, s_accounts           // every account over [import]
3:  cbz  x21, 4f
    mov  x0, x21
    bl   cfg_validate
    ldr  x21, [x21, #OVR_NEXT]
    b    3b
4:  LEAVE 2
ENDF cfg_load

// cfg_import_settings(x0 account cstr or 0, x1 IS* out)
//   x19 name, x20 out, x21 account record
FUNC cfg_import_settings
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    mov  x21, #0
    cbz  x19, 3f
    LDR_G x21, s_accounts
1:  cbz  x21, 3f
    ldr  x0, [x21, #OVR_NAME]
    mov  x1, x19
    bl   strcmp
    cbz  w0, 3f
    ldr  x21, [x21, #OVR_NEXT]
    b    1b
3:  mov  x0, x20
    mov  x1, x21
    bl   is_effective
    LEAVE 2
ENDF cfg_import_settings

// ================================================= rules and budgets ========

// category_dup(x0 ptr, x1 len) -> x0 cstr: a category name
// ([a-z0-9_-]{1,32}, not `uncategorized`), else an error
//   x19 copy
LFUNC category_dup
    ENTER 1
    bl   xstrndup
    mov  x19, x0
    bl   valid_name
    cbz  w0, 1f
    mov  x0, x19
    ADR_L x1, s_uncat
    bl   strcmp
    cbz  w0, 1f
    mov  x0, x19
    LEAVE 1
1:  mov  x1, x19
    LFAIL "invalid category name '%s'"
ENDF category_dup

// rules_load(x0 path) -> x0 RULE array, x1 count
//   x19 path, x20 file text, x21 value cursor, x22 value end, x23 category,
//   x24 pattern start, x25 pattern end (',' or value end), x26 pattern length
//   sp: Buf of RULE entries
FUNC rules_load
    ENTER 4
    sub  sp, sp, #BUF_SIZE
    stp  xzr, xzr, [sp]
    stp  xzr, xzr, [sp, #16]
    mov  x19, x0
    ADR_L x1, s_err_rules
    bl   open_lines
    mov  x20, x0

.Lrl_line:
    bl   next_line
    cbz  w2, .Lrl_end
    bl   parse_line
    cmp  w0, #PL_SKIP
    b.eq .Lrl_line
    cmp  w0, #PL_ASSIGN
    b.eq 1f
    LFAIL "section headers are not allowed in the rules file"
1:  mov  x21, x3
    add  x22, x3, x4
    mov  x0, x1
    mov  x1, x2
    bl   category_dup
    mov  x23, x0

.Lrl_pattern:                       // one comma-separated pattern
    mov  x25, x21
2:  cmp  x25, x22
    b.hs 3f
    ldrb w9, [x25]
    cmp  w9, #','
    b.eq 3f
    add  x25, x25, #1
    b    2b
3:  mov  x0, x21
    sub  x1, x25, x21
    bl   trim_ws
    mov  x24, x0
    mov  x26, x1
    cbnz x1, 4f
    LFAIL "empty pattern"
4:  mov  x9, #0                     // no '%' or '_'
    mov  w11, #'_'
5:  ldrb w10, [x24, x9]
    cmp  w10, #'%'
    ccmp w10, w11, #4, ne
    b.ne 6f
    mov  x1, x26
    mov  x2, x24
    LFAIL "pattern '%.*s' contains '%%' or '_'"
6:  add  x9, x9, #1
    cmp  x9, x26
    b.lo 5b
    mov  x0, x24
    mov  x1, x26
    bl   xstrndup
    mov  x24, x0
    mov  x0, sp
    mov  x1, #RULE_SIZE
    bl   buf_reserve
    str  x23, [x0, #RULE_CAT]
    str  x24, [x0, #RULE_PAT]
    ldr  x9, [sp, #BUF_LEN]
    add  x9, x9, #RULE_SIZE
    str  x9, [sp, #BUF_LEN]
    cmp  x25, x22
    b.hs .Lrl_line
    add  x21, x25, #1               // after the ','
    b    .Lrl_pattern

.Lrl_end:
    mov  x0, x20
    bl   free
    ldr  x0, [sp, #BUF_PTR]
    ldr  x1, [sp, #BUF_LEN]
    lsr  x1, x1, #4                 // / RULE_SIZE
    add  sp, sp, #BUF_SIZE
    LEAVE 4
ENDF rules_load

// parse_amount(x0 ptr, x1 len) -> x0 cents, w1 0 ok / 1 invalid   (leaf)
// [0-9]{1,16}(\.[0-9]{1,2})?
//   x2 end, x3 integer digits, x4 value, x5 = 10
LFUNC parse_amount
    add  x2, x0, x1
    mov  x3, #0
    mov  x4, #0
    mov  x5, #10
1:  cmp  x0, x2
    b.hs 2f
    ldrb w6, [x0]
    sub  w6, w6, #'0'
    cmp  w6, #9
    b.hi 2f
    madd x4, x4, x5, x6
    add  x3, x3, #1
    add  x0, x0, #1
    b    1b
2:  cbz  x3, 8f
    cmp  x3, #16
    b.hi 8f
    mov  x7, #100
    mul  x4, x4, x7                 // whole units in cents
    cmp  x0, x2
    b.eq 9f
    ldrb w6, [x0], #1
    cmp  w6, #'.'
    b.ne 8f
    cmp  x0, x2                     // first decimal: tens of cents
    b.hs 8f
    ldrb w6, [x0], #1
    sub  w6, w6, #'0'
    cmp  w6, #9
    b.hi 8f
    madd x4, x6, x5, x4
    cmp  x0, x2                     // optional second decimal
    b.eq 9f
    ldrb w6, [x0], #1
    sub  w6, w6, #'0'
    cmp  w6, #9
    b.hi 8f
    add  x4, x4, x6
    cmp  x0, x2
    b.ne 8f
9:  mov  x0, x4
    mov  w1, #0
    ret
8:  mov  x0, #0
    mov  w1, #1
    ret
ENDF parse_amount

// budget_load(x0 path) -> x0 BUD array, x1 count
//   x19 path, x20 file text, x21 value cstr, x22 value length, x23 category,
//   x24 entry scan pointer, x25 entries end; sp: Buf of BUD entries
FUNC budget_load
    ENTER 4
    sub  sp, sp, #BUF_SIZE
    stp  xzr, xzr, [sp]
    stp  xzr, xzr, [sp, #16]
    mov  x19, x0
    ADR_L x1, s_err_budget
    bl   open_lines
    mov  x20, x0

.Lbl_line:
    bl   next_line
    cbz  w2, .Lbl_end
    bl   parse_line
    cmp  w0, #PL_SKIP
    b.eq .Lbl_line
    cmp  w0, #PL_ASSIGN
    b.eq 1f
    LFAIL "section headers are not allowed in the budget file"
1:  mov  x21, x3
    mov  x22, x4
    mov  x0, x1
    mov  x1, x2
    bl   category_dup
    mov  x23, x0
    ldr  x24, [sp, #BUF_PTR]        // listed before?
    ldr  x25, [sp, #BUF_LEN]
    add  x25, x24, x25
2:  cmp  x24, x25
    b.hs 3f
    ldr  x0, [x24, #BUD_CAT]
    mov  x1, x23
    bl   strcmp
    cbnz w0, 21f
    mov  x1, x23
    LFAIL "category '%s' listed twice"
21: add  x24, x24, #BUD_SIZE
    b    2b
3:  mov  x0, x21
    mov  x1, x22
    bl   parse_amount
    cbz  w1, 4f
    mov  x1, x21
    LFAIL "invalid budget amount '%s'"
4:  mov  x24, x0
    mov  x0, sp
    mov  x1, #BUD_SIZE
    bl   buf_reserve
    str  x23, [x0, #BUD_CAT]
    str  x24, [x0, #BUD_CENTS]
    ldr  x9, [sp, #BUF_LEN]
    add  x9, x9, #BUD_SIZE
    str  x9, [sp, #BUF_LEN]
    b    .Lbl_line

.Lbl_end:
    mov  x0, x20
    bl   free
    ldr  x0, [sp, #BUF_PTR]
    ldr  x1, [sp, #BUF_LEN]
    lsr  x1, x1, #4                 // / BUD_SIZE
    add  sp, sp, #BUF_SIZE
    LEAVE 4
ENDF budget_load

    NOTE_GNU_STACK
