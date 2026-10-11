// =============================================================================
// ingest.S — CSV / JSON / JSON Lines ingestion into an in-memory Table.
//
//   ingest(x0 Table*, x1 data, x2 len, w3 format, x4 Schema* or 0,
//          w5 header, w6 delimiter)
//
// Spec: spec/data-types/ingestion.md. Everything that persists (Column
// array, names, payload/null arrays, string values) is allocated in the
// table's own arena (tbl+TBL_ARENA); scratch data lives in the request arena.
//
// Internal convention: all local helpers (LFUNC) run with x19 = Ctx* (the
// ingestion context below, living in ingest's stack frame). x19 is
// callee-saved, so it stays valid across calls into rt/value/json/glibc;
// helpers never modify it.
//
// CSV strategy (linear time, no per-field storage):
//   pass 1  tokenise every record into a small reusable field buffer,
//           validate field counts, infer column types (no schema);
//   pass 2  rewind and tokenise again, converting fields directly into the
//           column arrays (row count now known).
// JSON strategy: json_parse builds a DOM (request arena); pass A discovers
// columns / validates / infers, pass B converts into the column arrays.
// =============================================================================
#include "pq.inc"

// ------------------------------------------------------------ Ctx layout -----
#define C_TBL      0       // Table*
#define C_ARENA    8       // Arena* of the table (tbl + TBL_ARENA)
#define C_DATA     16      // input start (BOM skipped)
#define C_END      24      // input end
#define C_SCHEMA   32      // Schema* or 0
#define C_FMT      40      // u32 FMT_*
#define C_HEADER   44      // u32 CSV header flag
#define C_DELIM    48      // u32 CSV delimiter byte
#define C_CONVERR  52      // u32 error code for value conversion failures
#define C_NCOLS    56      // u64
#define C_NROWS    64      // u64
#define C_NAMES    72      // Str** column names (request arena or schema)
#define C_TYPES    80      // u32* column types
#define C_STATE    88      // u32* per-column inference state
#define C_COLS     96      // Column* (table arena)
#define C_POS      104     // CSV cursor
#define C_FB       112     // CSV field buffer (FE_SIZE entries)
#define C_FBCAP    120     // CSV field buffer capacity (entries)
#define C_REC      128     // current 1-based record number (diagnostics)
#define C_COLCAP   136     // JSON: capacity of the growable column arrays
#define C_STAMP    144     // JSON: u64* per column, last record that set it
#define C_EMPTY    152     // Str* "" in the table arena (shared)
#define C_SIZE     160

// CSV field buffer entry
#define FE_PTR     0       // u64 pointer to the field text (inside quotes)
#define FE_LEN     8       // u32 raw length
#define FE_FLAGS   12      // u32 FL_*
#define FE_SIZE    16
#define FL_QUOTED  1       // field was quoted
#define FL_ESC     2       // quoted field contains "" escapes (bit 1)

// CSV inference state bits (candidate types still possible)
#define CB_BOOL    1
#define CB_INT     2
#define CB_FLOAT   4
#define CB_DATE    8
#define CB_TS      16
#define CB_ALL     31
#define CB_SEEN    0x100   // at least one considered (non-blank) value

// JSON inference state bits
#define JS_BOOL    1       // saw a boolean
#define JS_NUM     2       // saw a number
#define JS_STR     4       // saw a string
#define JS_NONINT  8       // some number is not an INT64 literal
#define JS_NOTDATE 16      // some string is not a valid DATE
#define JS_NOTTS   32      // some string is neither DATE nor TIMESTAMP

#define MAX_FIELD  (16*1024*1024)
#define MSG_MAX    512

// =============================================================================
// ingest — public entry point (see API.md).
// Registers: x19 Ctx* (on our stack frame).
// =============================================================================
FUNC ingest
    stp  x29, x30, [sp, #-(96+C_SIZE)]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    stp  x25, x26, [sp, #64]
    stp  x27, x28, [sp, #80]
    add  x19, sp, #96               // Ctx
    // zero the context
    mov  x8, x19
    add  x9, x19, #C_SIZE
1:  stp  xzr, xzr, [x8], #16
    cmp  x8, x9
    b.lo 1b
    str  x0, [x19, #C_TBL]
    add  x7, x0, #TBL_ARENA
    str  x7, [x19, #C_ARENA]
    add  x8, x1, x2                 // end of input
    // skip a leading UTF-8 BOM (EF BB BF)
    cmp  x2, #3
    b.lo 2f
    ldrb w9, [x1]
    cmp  w9, #0xEF
    b.ne 2f
    ldrb w9, [x1, #1]
    cmp  w9, #0xBB
    b.ne 2f
    ldrb w9, [x1, #2]
    cmp  w9, #0xBF
    b.ne 2f
    add  x1, x1, #3
2:  str  x1, [x19, #C_DATA]
    str  x8, [x19, #C_END]
    str  x4, [x19, #C_SCHEMA]
    str  w3, [x19, #C_FMT]
    str  w5, [x19, #C_HEADER]
    and  w6, w6, #0xff
    str  w6, [x19, #C_DELIM]
    // inferred columns can only fail in "malformed input" ways
    mov  w9, #ERR_INGEST
    mov  w10, #ERR_CONVERSION
    cmp  x4, #0
    csel w9, w9, w10, eq
    str  w9, [x19, #C_CONVERR]
    // shared empty string for quoted-empty STRING fields
    ldr  x0, [x19, #C_ARENA]
    mov  x2, #0
    bl   str_new_in
    str  x0, [x19, #C_EMPTY]

    ldr  w0, [x19, #C_FMT]
    cmp  w0, #FMT_CSV
    b.ne 3f
    bl   csv_ingest
    b    4f
3:  bl   json_ingest
4:  ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x23, x24, [sp, #48]
    ldp  x25, x26, [sp, #64]
    ldp  x27, x28, [sp, #80]
    ldp  x29, x30, [sp], #(96+C_SIZE)
    ret
ENDF ingest

// =============================================================================
// raise_fmt(w0 code, x1 printf format, x2..x6 up to five arguments)
// Formats the message with snprintf into a stack buffer and raises (noreturn).
// pq_raise copies the message, so the stack buffer is fine.
// =============================================================================
LFUNC raise_fmt
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    str  x20, [sp, #16]
    sub  sp, sp, #MSG_MAX
    mov  w20, w0
    mov  x7, x6
    mov  x6, x5
    mov  x5, x4
    mov  x4, x3
    mov  x3, x2
    mov  x2, x1
    mov  x1, #MSG_MAX
    mov  x0, sp
    bl   snprintf
    mov  w0, w20
    mov  x1, sp
    bl   pq_raise
    brk  #0
ENDF raise_fmt

// =============================================================================
// conv_fail(x0 column index, x1 text ptr, x2 text len) — noreturn.
// Raises C_CONVERR with "cannot convert 'text' to TYPE (column 'c', record n)".
// =============================================================================
LFUNC conv_fail
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    mov  x3, x1                     // text ptr
    cmp  x2, #100                   // clamp the quoted text
    mov  x9, #100
    csel x2, x9, x2, hi             // precision (int)
    ldr  x9, [x19, #C_TYPES]
    ldr  w10, [x9, x0, lsl #2]
    and  w10, w10, #T_KIND_MASK
    cmp  w10, #T_TS
    b.ls 1f
    mov  w10, #T_STR
1:  ADR_L x11, type_names
    ldr  x4, [x11, x10, lsl #3]     // type name
    ldr  x9, [x19, #C_NAMES]
    ldr  x5, [x9, x0, lsl #3]
    add  x5, x5, #STR_DATA          // column name
    ldr  x6, [x19, #C_REC]
    ldr  w0, [x19, #C_CONVERR]
    ADR_L x1, msg_conv
    bl   raise_fmt
ENDF conv_fail

// =============================================================================
// unescape_in(x0 Arena*, x1 ptr, x2 len) -> x0 Str*
// Copies a quoted CSV field body collapsing every "" pair into one quote.
// Registers: x20 src, x21 len, x22 Str*.
// =============================================================================
LFUNC unescape_in
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x20, x21, [sp, #16]
    str  x22, [sp, #32]
    mov  x20, x1
    mov  x21, x2
    add  x1, x2, #STR_DATA+1
    bl   arena_alloc_in
    mov  x22, x0
    add  x3, x0, #STR_DATA          // dst
    mov  x4, x20                    // src
    add  x5, x20, x21               // src end
1:  cmp  x4, x5
    b.hs 2f
    ldrb w6, [x4], #1
    strb w6, [x3], #1
    cmp  w6, #'"'
    b.ne 1b
    add  x4, x4, #1                 // skip the second quote of the pair
    b    1b
2:  strb wzr, [x3]
    add  x6, x22, #STR_DATA
    sub  x6, x3, x6
    str  x6, [x22, #STR_LEN]
    mov  x0, x22
    ldp  x20, x21, [sp, #16]
    ldr  x22, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
ENDF unescape_in

// =============================================================================
// alloc_columns — build the Column array from C_NCOLS/C_NROWS/C_NAMES/C_TYPES
// in the table arena, payloads zeroed and all null flags set to 1; fills
// TBL_NCOLS/TBL_NROWS/TBL_COLS and C_COLS.
// Registers: x20 ncols, x21 i, x22 Column*, x23 nrows, x24 arena,
//            x25 names, x26 types, x27 current Column*.
// =============================================================================
LFUNC alloc_columns
    stp  x29, x30, [sp, #-80]!
    mov  x29, sp
    stp  x20, x21, [sp, #16]
    stp  x22, x23, [sp, #32]
    stp  x24, x25, [sp, #48]
    stp  x26, x27, [sp, #64]
    ldr  x20, [x19, #C_NCOLS]
    ldr  x23, [x19, #C_NROWS]
    ldr  x24, [x19, #C_ARENA]
    ldr  x25, [x19, #C_NAMES]
    ldr  x26, [x19, #C_TYPES]
    mov  x0, x24
    lsl  x1, x20, #5
    add  x1, x1, #COL_SIZE          // never a zero-sized request
    bl   arena_alloc_in
    mov  x22, x0
    mov  x21, #0
1:  cmp  x21, x20
    b.hs 2f
    add  x27, x22, x21, lsl #5
    ldr  x9, [x25, x21, lsl #3]     // Str* name
    ldr  x2, [x9, #STR_LEN]
    add  x1, x9, #STR_DATA
    mov  x0, x24
    bl   str_new_in
    str  x0, [x27, #COL_NAME]
    ldr  w0, [x26, x21, lsl #2]
    str  x0, [x27, #COL_TYPE]       // u32 type, upper half zero
    mov  x0, x24
    lsl  x1, x23, #3
    add  x1, x1, #8
    bl   arena_alloc_in
    str  x0, [x27, #COL_DATA]
    mov  w1, #0
    lsl  x2, x23, #3
    bl   memset
    mov  x0, x24                    // null bitmap, all NULL
    add  x1, x23, #7
    lsr  x1, x1, #3
    add  x1, x1, #8
    bl   arena_alloc_in
    str  x0, [x27, #COL_NULLS]
    mov  w1, #0xff
    add  x2, x23, #7
    lsr  x2, x2, #3
    add  x2, x2, #8
    bl   memset
    add  x21, x21, #1
    b    1b
2:  str  x22, [x19, #C_COLS]
    ldr  x0, [x19, #C_TBL]
    str  x20, [x0, #TBL_NCOLS]
    str  x23, [x0, #TBL_NROWS]
    str  x22, [x0, #TBL_COLS]
    ldp  x20, x21, [sp, #16]
    ldp  x22, x23, [sp, #32]
    ldp  x24, x25, [sp, #48]
    ldp  x26, x27, [sp, #64]
    ldp  x29, x30, [sp], #80
    ret
ENDF alloc_columns

// =============================================================================
// store_text(x0 column, x1 ptr, x2 len, x3 row)
// Converts a text value to the column's type (CSV rules) and stores it:
//   STRING: raw text copied into the table arena;
//   others: text trimmed of spaces/tabs; blank => NULL (left as is);
//           conversion failure => conv_fail.
// Registers: x20 column, x21 row, x22/x23 trimmed text, w24 type.
// =============================================================================
LFUNC store_text
    stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    stp  x20, x21, [sp, #16]
    stp  x22, x23, [sp, #32]
    str  x24, [sp, #48]
    mov  x20, x0
    mov  x21, x3
    mov  x22, x1
    mov  x23, x2
    ldr  x9, [x19, #C_TYPES]
    ldr  w24, [x9, x20, lsl #2]
    and  w9, w24, #T_KIND_MASK
    cmp  w9, #T_STR
    b.ne 1f
    ldr  x0, [x19, #C_ARENA]
    bl   str_new_in                 // x1/x2 still hold the raw text
    b    .Lst_store
1:  mov  x0, x22
    mov  x1, x23
    bl   trim_ws
    cbz  x1, .Lst_done              // blank => NULL
    mov  x22, x0
    mov  x23, x1
    and  w9, w24, #T_KIND_MASK
    cmp  w9, #T_BOOL
    b.eq .Lst_bool
    cmp  w9, #T_INT
    b.eq .Lst_int
    cmp  w9, #T_DEC
    b.eq .Lst_dec
    cmp  w9, #T_FLOAT
    b.eq .Lst_float
    cmp  w9, #T_DATE
    b.eq .Lst_date
    cmp  w9, #T_TS
    b.eq .Lst_ts
    b    .Lst_fail
.Lst_bool:
    bl   parse_bool
    b    .Lst_check
.Lst_int:
    bl   parse_int64
    b    .Lst_check
.Lst_dec:
    ubfx w2, w24, #T_PREC_SHIFT, #8
    ubfx w3, w24, #T_SCALE_SHIFT, #8
    mov  w4, #0                     // exact: never round
    bl   parse_decimal
    b    .Lst_check
.Lst_float:
    bl   parse_float
    fmov x0, d0
    b    .Lst_check
.Lst_date:
    bl   parse_date
    b    .Lst_check
.Lst_ts:
    mov  w2, #1                     // a DATE text means midnight
    bl   parse_timestamp
.Lst_check:
    cbnz w1, .Lst_fail
.Lst_store:
    ldr  x9, [x19, #C_COLS]
    add  x9, x9, x20, lsl #5
    ldr  x10, [x9, #COL_DATA]
    str  x0, [x10, x21, lsl #3]
    ldr  x10, [x9, #COL_NULLS]
    NULLBIT_CLEAR 10, 21, 11, 12, 13, 14
.Lst_done:
    ldp  x20, x21, [sp, #16]
    ldp  x22, x23, [sp, #32]
    ldr  x24, [sp, #48]
    ldp  x29, x30, [sp], #64
    ret
.Lst_fail:
    mov  x0, x20
    mov  x1, x22
    mov  x2, x23
    bl   conv_fail
ENDF store_text

// =============================================================================
//                                   CSV
// =============================================================================

// -----------------------------------------------------------------------------
// fb_grow(x0 used entries): double the field buffer (request arena).
// Registers: x20 used, x21 new capacity, x22 new buffer.
// -----------------------------------------------------------------------------
LFUNC fb_grow
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x20, x21, [sp, #16]
    str  x22, [sp, #32]
    mov  x20, x0
    ldr  x21, [x19, #C_FBCAP]
    lsl  x21, x21, #1
    lsl  x0, x21, #4
    bl   arena_alloc
    mov  x22, x0
    ldr  x1, [x19, #C_FB]
    lsl  x2, x20, #4
    bl   memcpy
    str  x22, [x19, #C_FB]
    str  x21, [x19, #C_FBCAP]
    ldp  x20, x21, [sp, #16]
    ldr  x22, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
ENDF fb_grow

// -----------------------------------------------------------------------------
// csv_next_record -> x0 number of fields, or -1 at end of input.
// Tokenises one record starting at C_POS into the field buffer C_FB and
// advances C_POS / C_REC. Completely empty lines are skipped. A field's text
// is the raw bytes (for quoted fields: between the quotes, "" not collapsed).
// Raises INGEST_ERROR for unterminated quotes, garbage after a closing quote
// and fields longer than 16 MiB.
// Registers: x20 cursor, x21 input end, x22 field buffer, x23 field count,
//            x24 buffer capacity, w25 delimiter, x26 field start,
//            x27 field flags, x28 quote scan position.
// -----------------------------------------------------------------------------
LFUNC csv_next_record
    stp  x29, x30, [sp, #-96]!
    mov  x29, sp
    stp  x20, x21, [sp, #16]
    stp  x22, x23, [sp, #32]
    stp  x24, x25, [sp, #48]
    stp  x26, x27, [sp, #64]
    str  x28, [sp, #80]
    ldr  x20, [x19, #C_POS]
    ldr  x21, [x19, #C_END]
    ldr  x22, [x19, #C_FB]
    ldr  x24, [x19, #C_FBCAP]
    ldr  w25, [x19, #C_DELIM]
    // ---- skip completely empty lines ("\n", "\r\n", lone "\r" at EOF)
.Lnr_skip:
    cmp  x20, x21
    b.hs .Lnr_eof
    ldrb w0, [x20]
    cmp  w0, #'\n'
    b.eq .Lnr_skip1
    cmp  w0, #'\r'
    b.ne .Lnr_rec
    add  x1, x20, #1
    cmp  x1, x21
    b.hs .Lnr_skip1
    ldrb w2, [x1]
    cmp  w2, #'\n'
    b.ne .Lnr_rec
    add  x20, x20, #2
    b    .Lnr_skip
.Lnr_skip1:
    add  x20, x20, #1
    b    .Lnr_skip
.Lnr_rec:
    ldr  x0, [x19, #C_REC]
    add  x0, x0, #1
    str  x0, [x19, #C_REC]
    mov  x23, #0
    // ---- one field
.Lnr_field:
    cmp  x23, x24
    b.lo 1f
    mov  x0, x23
    bl   fb_grow
    ldr  x22, [x19, #C_FB]
    ldr  x24, [x19, #C_FBCAP]
1:  cmp  x20, x21
    b.hs .Lnr_empty_eof             // empty last field after a delimiter
    ldrb w0, [x20]
    cmp  w0, #'"'
    b.eq .Lnr_quoted
    // ---- unquoted field: up to delimiter, '\n' or end of input
    mov  x26, x20
2:  cmp  x20, x21
    b.hs 3f
    ldrb w0, [x20]
    cmp  w0, w25
    b.eq 3f
    cmp  w0, #'\n'
    b.eq 3f
    add  x20, x20, #1
    b    2b
3:  mov  x1, x20                    // field end
    cmp  x20, x21
    b.hs 4f
    ldrb w0, [x20]
    cmp  w0, #'\n'
    b.ne 5f                         // ended by the delimiter: keep any CR
4:  cmp  x1, x26                    // ended by \n / EOF: drop the CR of CRLF
    b.ls 5f
    ldrb w2, [x1, #-1]
    cmp  w2, #'\r'
    b.ne 5f
    sub  x1, x1, #1
5:  sub  x1, x1, x26
    mov  x9, #MAX_FIELD
    cmp  x1, x9
    b.hi .Lnr_toolong
    add  x9, x22, x23, lsl #4
    str  x26, [x9, #FE_PTR]
    str  w1, [x9, #FE_LEN]
    str  wzr, [x9, #FE_FLAGS]
    add  x23, x23, #1
    cmp  x20, x21
    b.hs .Lnr_done
    ldrb w0, [x20], #1
    cmp  w0, w25
    b.eq .Lnr_field
    b    .Lnr_done                  // it was '\n'
    // ---- quoted field
.Lnr_quoted:
    add  x26, x20, #1               // body start
    mov  x27, #FL_QUOTED
    mov  x28, x26
6:  mov  x0, x28
    mov  w1, #'"'
    sub  x2, x21, x28
    bl   memchr
    cbz  x0, .Lnr_unterminated
    add  x1, x0, #1
    cmp  x1, x21
    b.hs 7f
    ldrb w2, [x1]
    cmp  w2, #'"'
    b.ne 7f
    orr  x27, x27, #FL_ESC          // "" escape: keep scanning after it
    add  x28, x0, #2
    b    6b
7:  sub  x1, x0, x26                // x0 = closing quote
    mov  x9, #MAX_FIELD
    cmp  x1, x9
    b.hi .Lnr_toolong
    add  x9, x22, x23, lsl #4
    str  x26, [x9, #FE_PTR]
    str  w1, [x9, #FE_LEN]
    str  w27, [x9, #FE_FLAGS]
    add  x23, x23, #1
    add  x20, x0, #1
    cmp  x20, x21
    b.hs .Lnr_done
    ldrb w0, [x20]
    cmp  w0, w25
    b.ne 8f
    add  x20, x20, #1
    b    .Lnr_field
8:  cmp  w0, #'\n'
    b.ne 9f
    add  x20, x20, #1
    b    .Lnr_done
9:  cmp  w0, #'\r'
    b.ne .Lnr_garbage
    add  x1, x20, #1
    cmp  x1, x21
    b.hs 10f                        // CR at end of input
    ldrb w2, [x1]
    cmp  w2, #'\n'
    b.ne .Lnr_garbage
    add  x20, x20, #2
    b    .Lnr_done
10: mov  x20, x1
    b    .Lnr_done
.Lnr_empty_eof:
    add  x9, x22, x23, lsl #4
    str  x20, [x9, #FE_PTR]
    str  xzr, [x9, #FE_LEN]         // len 0, flags 0
    add  x23, x23, #1
.Lnr_done:
    str  x20, [x19, #C_POS]
    mov  x0, x23
    b    .Lnr_ret
.Lnr_eof:
    str  x20, [x19, #C_POS]
    mov  x0, #-1
.Lnr_ret:
    ldp  x20, x21, [sp, #16]
    ldp  x22, x23, [sp, #32]
    ldp  x24, x25, [sp, #48]
    ldp  x26, x27, [sp, #64]
    ldr  x28, [sp, #80]
    ldp  x29, x30, [sp], #96
    ret
.Lnr_unterminated:
    mov  w0, #ERR_INGEST
    ADR_L x1, msg_unterminated
    b    .Lnr_raise
.Lnr_garbage:
    mov  w0, #ERR_INGEST
    ADR_L x1, msg_garbage
    b    .Lnr_raise
.Lnr_toolong:
    mov  w0, #ERR_INGEST
    ADR_L x1, msg_toolong
.Lnr_raise:
    ldr  x2, [x19, #C_REC]
    bl   raise_fmt
ENDF csv_next_record

// -----------------------------------------------------------------------------
// csv_header_names(x0 field count) -> x0 Str** names (request arena)
// Builds the header names from the field buffer; empty or case-insensitively
// duplicated names raise INGEST_ERROR.
// Registers: x20 count, x21 i, x22 names, x23 field buffer, x24 j.
// -----------------------------------------------------------------------------
LFUNC csv_header_names
    stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    stp  x20, x21, [sp, #16]
    stp  x22, x23, [sp, #32]
    str  x24, [sp, #48]
    mov  x20, x0
    lsl  x0, x0, #3
    add  x0, x0, #8
    bl   arena_alloc
    mov  x22, x0
    ldr  x23, [x19, #C_FB]
    mov  x21, #0
1:  cmp  x21, x20
    b.hs 6f
    add  x9, x23, x21, lsl #4
    ldr  x1, [x9, #FE_PTR]
    ldr  w2, [x9, #FE_LEN]
    ldr  w3, [x9, #FE_FLAGS]
    cbz  w2, .Lhn_empty
    tbz  w3, #1, 2f                 // FL_ESC?
    TLS_ADDR x0, g_arena
    bl   unescape_in
    b    3f
2:  mov  x0, x1
    mov  x1, x2
    bl   str_new
3:  str  x0, [x22, x21, lsl #3]
    mov  x24, #0                    // compare with all previous names
4:  cmp  x24, x21
    b.hs 5f
    ldr  x0, [x22, x24, lsl #3]
    ldr  x1, [x22, x21, lsl #3]
    bl   str_ieq
    cbnz w0, .Lhn_dup
    add  x24, x24, #1
    b    4b
5:  add  x21, x21, #1
    b    1b
6:  mov  x0, x22
    ldp  x20, x21, [sp, #16]
    ldp  x22, x23, [sp, #32]
    ldr  x24, [sp, #48]
    ldp  x29, x30, [sp], #64
    ret
.Lhn_empty:
    RAISE ERR_INGEST, "empty column name in CSV header"
.Lhn_dup:
    ldr  x2, [x22, x21, lsl #3]
    add  x2, x2, #STR_DATA
    mov  w0, #ERR_INGEST
    ADR_L x1, msg_dupcol
    bl   raise_fmt
ENDF csv_header_names

// -----------------------------------------------------------------------------
// csv_infer(x0 column, x1 field entry): narrow the column's candidate types
// (ingestion.md §1.1) by one field. Empty (quoted or not) and blank fields
// are not considered; a field containing a quote can only be a STRING.
// Registers: x20 &state[col], w21 state, x22/x23 trimmed text.
// -----------------------------------------------------------------------------
LFUNC csv_infer
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x20, x21, [sp, #16]
    stp  x22, x23, [sp, #32]
    ldr  x9, [x19, #C_STATE]
    add  x20, x9, x0, lsl #2
    ldr  w21, [x20]
    tst  w21, #CB_ALL
    b.eq .Lci_ret                   // already STRING
    ldr  w2, [x1, #FE_LEN]
    cbz  w2, .Lci_ret               // empty: not considered
    ldr  w3, [x1, #FE_FLAGS]
    tbz  w3, #1, 1f
    mov  w21, #CB_SEEN              // contains '"': STRING
    b    .Lci_store
1:  ldr  x0, [x1, #FE_PTR]
    mov  x1, x2
    bl   trim_ws
    cbz  x1, .Lci_ret               // blank: not considered
    mov  x22, x0
    mov  x23, x1
    orr  w21, w21, #CB_SEEN
    // cheap pre-filters: BOOLEAN must start with t/f, DATE/TIMESTAMP need
    // at least 10 bytes with '-' at offset 4.
    ldrb w9, [x22]
    orr  w9, w9, #0x20
    cmp  w9, #'t'
    b.eq 2f
    cmp  w9, #'f'
    b.eq 2f
    bic  w21, w21, #CB_BOOL
2:  cmp  x23, #10
    b.lo 3f
    ldrb w9, [x22, #4]
    cmp  w9, #'-'
    b.eq 4f
3:  bic  w21, w21, #(CB_DATE | CB_TS)
4:  tbz  w21, #0, 5f                // CB_BOOL
    mov  x0, x22
    mov  x1, x23
    bl   parse_bool
    cbz  w1, 5f
    bic  w21, w21, #CB_BOOL
5:  tbz  w21, #1, 6f                // CB_INT
    mov  x0, x22
    mov  x1, x23
    bl   parse_int64
    cbz  w1, 6f
    bic  w21, w21, #CB_INT
6:  tbz  w21, #2, 7f                // CB_FLOAT
    mov  x0, x22
    mov  x1, x23
    bl   parse_float
    cbz  w1, 7f
    bic  w21, w21, #CB_FLOAT
7:  tbz  w21, #3, 8f                // CB_DATE
    mov  x0, x22
    mov  x1, x23
    bl   parse_date
    cbz  w1, 8f
    bic  w21, w21, #CB_DATE
8:  tbz  w21, #4, .Lci_store        // CB_TS (dates accepted as midnight)
    mov  x0, x22
    mov  x1, x23
    mov  w2, #1
    bl   parse_timestamp
    cbz  w1, .Lci_store
    bic  w21, w21, #CB_TS
.Lci_store:
    str  w21, [x20]
.Lci_ret:
    ldp  x20, x21, [sp, #16]
    ldp  x22, x23, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
ENDF csv_infer

// -----------------------------------------------------------------------------
// csv_finish_types: C_STATE -> C_TYPES (first remaining candidate, STRING if
// none remain or no value was considered).
// Registers: x0 ncols, x1 states, x2 types, x3 cb_types, x4 i, w5-w7 temps.
// -----------------------------------------------------------------------------
LFUNC csv_finish_types
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    ldr  x0, [x19, #C_NCOLS]
    ldr  x1, [x19, #C_STATE]
    ldr  x2, [x19, #C_TYPES]
    ADR_L x3, cb_types
    mov  x4, #0
1:  cmp  x4, x0
    b.hs 3f
    ldr  w5, [x1, x4, lsl #2]
    mov  w6, #T_STR
    tbz  w5, #8, 2f                 // CB_SEEN clear: no considered values
    ands w7, w5, #CB_ALL
    b.eq 2f
    rbit w7, w7
    clz  w7, w7                     // index of the first candidate
    ldrb w6, [x3, x7]
2:  str  w6, [x2, x4, lsl #2]
    add  x4, x4, #1
    b    1b
3:  ldp  x29, x30, [sp], #16
    ret
ENDF csv_finish_types

// -----------------------------------------------------------------------------
// csv_convert(x0 column, x1 field entry, x2 row): store one CSV field.
// Unquoted empty => NULL; quoted empty => "" for STRING, NULL otherwise;
// STRING fields with "" escapes are unescaped; the rest goes to store_text.
// Registers: x20 column, x21 row, x22 ptr, w23 len, w24 flags, w25 kind.
// -----------------------------------------------------------------------------
LFUNC csv_convert
    stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    stp  x20, x21, [sp, #16]
    stp  x22, x23, [sp, #32]
    stp  x24, x25, [sp, #48]
    mov  x20, x0
    mov  x21, x2
    ldr  x22, [x1, #FE_PTR]
    ldr  w23, [x1, #FE_LEN]
    ldr  w24, [x1, #FE_FLAGS]
    ldr  x9, [x19, #C_TYPES]
    ldr  w25, [x9, x20, lsl #2]
    and  w25, w25, #T_KIND_MASK
    cbnz w23, 1f
    tbz  w24, #0, .Lcc_ret          // unquoted empty: NULL
    cmp  w25, #T_STR
    b.ne .Lcc_ret                   // quoted empty, non-STRING: NULL
    ldr  x0, [x19, #C_EMPTY]
    b    .Lcc_store
1:  cmp  w25, #T_STR
    b.ne 2f
    tbz  w24, #1, 2f
    ldr  x0, [x19, #C_ARENA]        // STRING with "" escapes
    mov  x1, x22
    mov  x2, x23
    bl   unescape_in
    b    .Lcc_store
2:  mov  x0, x20
    mov  x1, x22
    mov  x2, x23
    mov  x3, x21
    bl   store_text
    b    .Lcc_ret
.Lcc_store:
    ldr  x9, [x19, #C_COLS]
    add  x9, x9, x20, lsl #5
    ldr  x10, [x9, #COL_DATA]
    str  x0, [x10, x21, lsl #3]
    ldr  x10, [x9, #COL_NULLS]
    NULLBIT_CLEAR 10, 21, 11, 12, 13, 14
.Lcc_ret:
    ldp  x20, x21, [sp, #16]
    ldp  x22, x23, [sp, #32]
    ldp  x24, x25, [sp, #48]
    ldp  x29, x30, [sp], #64
    ret
ENDF csv_convert

// -----------------------------------------------------------------------------
// csv_ingest — CSV driver (header / schema handling, pass 1, pass 2).
// Registers: x20 ncols, x21 field index, x22 field buffer / names,
//            x23 header field count, x24 row count, x25 first data record
//            position, x26 Schema*, x27 schema names / row index.
// -----------------------------------------------------------------------------
LFUNC csv_ingest
    stp  x29, x30, [sp, #-96]!
    mov  x29, sp
    stp  x20, x21, [sp, #16]
    stp  x22, x23, [sp, #32]
    stp  x24, x25, [sp, #48]
    stp  x26, x27, [sp, #64]
    mov  x0, #(64*FE_SIZE)
    bl   arena_alloc
    str  x0, [x19, #C_FB]
    mov  x0, #64
    str  x0, [x19, #C_FBCAP]
    ldr  x0, [x19, #C_DATA]
    str  x0, [x19, #C_POS]
    str  xzr, [x19, #C_REC]
    ldr  x26, [x19, #C_SCHEMA]
    ldr  w0, [x19, #C_HEADER]
    cbz  w0, .Lcsv_nohdr
    // ---- header record
    bl   csv_next_record
    tbnz x0, #63, .Lcsv_empty
    mov  x23, x0
    bl   csv_header_names
    mov  x22, x0
    cbz  x26, .Lcsv_hdr_infer
    ldr  x20, [x26, #SCH_N]         // header must match the schema names
    cmp  x20, x23
    b.ne .Lcsv_hdr_mismatch
    ldr  x27, [x26, #SCH_NAMES]
    mov  x21, #0
1:  cmp  x21, x20
    b.hs .Lcsv_schema_cols
    ldr  x0, [x22, x21, lsl #3]
    ldr  x1, [x27, x21, lsl #3]
    bl   str_ieq
    cbz  w0, .Lcsv_hdr_mismatch
    add  x21, x21, #1
    b    1b
.Lcsv_hdr_infer:
    mov  x20, x23
    str  x22, [x19, #C_NAMES]
    lsl  x0, x20, #2
    add  x0, x0, #4
    bl   arena_alloc
    str  x0, [x19, #C_TYPES]
    lsl  x0, x20, #2
    add  x0, x0, #4
    bl   arena_alloc
    str  x0, [x19, #C_STATE]
    mov  w1, #CB_ALL                // every candidate still possible
    mov  x2, #0
2:  cmp  x2, x20
    b.hs .Lcsv_have_cols
    str  w1, [x0, x2, lsl #2]
    add  x2, x2, #1
    b    2b
.Lcsv_nohdr:
    cbz  x26, .Lcsv_noschema
.Lcsv_schema_cols:
    ldr  x20, [x26, #SCH_N]
    ldr  x0, [x26, #SCH_NAMES]
    str  x0, [x19, #C_NAMES]
    ldr  x0, [x26, #SCH_TYPES]
    str  x0, [x19, #C_TYPES]
.Lcsv_have_cols:
    str  x20, [x19, #C_NCOLS]
    ldr  x25, [x19, #C_POS]
    ldr  x27, [x19, #C_REC]         // records consumed by the header
    // ---- pass 1: structure check + inference
    mov  x24, #0
3:  bl   csv_next_record
    tbnz x0, #63, 5f
    cmp  x0, x20
    b.ne .Lcsv_arity
    add  x24, x24, #1
    cbnz x26, 3b                    // explicit schema: nothing to infer
    ldr  x22, [x19, #C_FB]
    mov  x21, #0
4:  cmp  x21, x20
    b.hs 3b
    mov  x0, x21
    add  x1, x22, x21, lsl #4
    bl   csv_infer
    add  x21, x21, #1
    b    4b
5:  LDR_G x0, g_max_table_rows
    cmp  x24, x0
    b.hi .Lcsv_rows
    str  x24, [x19, #C_NROWS]
    cbnz x26, 6f
    bl   csv_finish_types
6:  bl   alloc_columns
    // ---- pass 2: conversion
    str  x25, [x19, #C_POS]
    str  x27, [x19, #C_REC]
    mov  x27, #0                    // row index
7:  bl   csv_next_record
    tbnz x0, #63, 9f
    ldr  x22, [x19, #C_FB]
    mov  x21, #0
8:  cmp  x21, x20
    b.hs 85f
    mov  x0, x21
    add  x1, x22, x21, lsl #4
    mov  x2, x27
    bl   csv_convert
    add  x21, x21, #1
    b    8b
85: add  x27, x27, #1
    b    7b
9:  ldp  x20, x21, [sp, #16]
    ldp  x22, x23, [sp, #32]
    ldp  x24, x25, [sp, #48]
    ldp  x26, x27, [sp, #64]
    ldp  x29, x30, [sp], #96
    ret
.Lcsv_empty:
    RAISE ERR_INGEST, "empty CSV input: header record expected"
.Lcsv_noschema:
    RAISE ERR_INGEST, "CSV without header requires an explicit schema"
.Lcsv_hdr_mismatch:
    RAISE ERR_INGEST, "CSV header does not match the schema column names"
.Lcsv_rows:
    RAISE ERR_RESOURCE_LIMIT, "table row limit exceeded"
.Lcsv_arity:
    mov  x3, x0
    mov  x4, x20
    ldr  x2, [x19, #C_REC]
    mov  w0, #ERR_INGEST
    ADR_L x1, msg_arity
    bl   raise_fmt
ENDF csv_ingest

// =============================================================================
//                              JSON / JSON Lines
// =============================================================================

// -----------------------------------------------------------------------------
// jsonl_split -> x0 JNode** objects (request arena), x1 count
// Parses every non-blank line (trimmed of whitespace) as one JSON object.
// Registers: x20 cursor, x21 end, x22 array, x23 count, x24 capacity,
//            x25 line number, x26 line end.
// -----------------------------------------------------------------------------
LFUNC jsonl_split
    stp  x29, x30, [sp, #-80]!
    mov  x29, sp
    stp  x20, x21, [sp, #16]
    stp  x22, x23, [sp, #32]
    stp  x24, x25, [sp, #48]
    str  x26, [sp, #64]
    mov  x24, #64
    lsl  x0, x24, #3
    bl   arena_alloc
    mov  x22, x0
    mov  x23, #0
    mov  x25, #0
    ldr  x20, [x19, #C_DATA]
    ldr  x21, [x19, #C_END]
1:  cmp  x20, x21
    b.hs 5f
    add  x25, x25, #1
    mov  x0, x20
    mov  w1, #'\n'
    sub  x2, x21, x20
    bl   memchr
    cmp  x0, #0
    csel x26, x0, x21, ne           // line end (newline or end of input)
    mov  x0, x20
    sub  x1, x26, x20
    add  x20, x26, #1
    bl   trim_all_ws
    cbz  x1, 1b                     // blank line
    bl   json_parse
    cbz  x0, .Ljl_invalid
    ldr  w1, [x0, #JN_TYPE]
    cmp  w1, #J_OBJ
    b.ne .Ljl_notobj
    cmp  x23, x24
    b.lo 4f
    mov  x26, x0                    // grow (line end no longer needed)
    lsl  x0, x24, #4
    bl   arena_alloc
    mov  x1, x22
    lsl  x2, x23, #3
    mov  x22, x0
    bl   memcpy
    lsl  x24, x24, #1
    mov  x0, x26
4:  str  x0, [x22, x23, lsl #3]
    add  x23, x23, #1
    b    1b
5:  mov  x0, x22
    mov  x1, x23
    ldp  x20, x21, [sp, #16]
    ldp  x22, x23, [sp, #32]
    ldp  x24, x25, [sp, #48]
    ldr  x26, [sp, #64]
    ldp  x29, x30, [sp], #80
    ret
.Ljl_invalid:
    mov  w0, #ERR_INGEST
    ADR_L x1, msg_jl_invalid
    mov  x2, x25
    bl   raise_fmt
.Ljl_notobj:
    mov  w0, #ERR_INGEST
    ADR_L x1, msg_jl_notobj
    mov  x2, x25
    bl   raise_fmt
ENDF jsonl_split

// -----------------------------------------------------------------------------
// json_col_lookup(x0 key Str*, x1 guess index) -> x0 column index or -1
// Case-insensitive match against C_NAMES; the guess is tried first (keys
// usually come in the same order in every object).
// Registers: x20 key, x21 guess, x22 ncols, x23 names, x24 i.
// -----------------------------------------------------------------------------
LFUNC json_col_lookup
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x20, x21, [sp, #16]
    stp  x22, x23, [sp, #32]
    mov  x20, x0
    mov  x21, x1
    ldr  x22, [x19, #C_NCOLS]
    ldr  x23, [x19, #C_NAMES]
    cmp  x21, x22
    b.hs 1f
    ldr  x0, [x23, x21, lsl #3]
    mov  x1, x20
    bl   str_ieq
    cbz  w0, 1f
    mov  x0, x21
    b    3f
1:  mov  x21, #0                    // linear search
2:  cmp  x21, x22
    b.hs 4f
    ldr  x0, [x23, x21, lsl #3]
    mov  x1, x20
    bl   str_ieq
    cbnz w0, 21f
    add  x21, x21, #1
    b    2b
21: mov  x0, x21
    b    3f
4:  mov  x0, #-1
3:  ldp  x20, x21, [sp, #16]
    ldp  x22, x23, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
ENDF json_col_lookup

// -----------------------------------------------------------------------------
// json_add_col(x0 key Str*) -> x0 new column index (inference mode).
// Grows C_NAMES / C_STATE / C_STAMP when full. Empty names raise.
// Registers: x20 key, x21 ncols, x22 new capacity, x23 new array.
// -----------------------------------------------------------------------------
LFUNC json_add_col
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x20, x21, [sp, #16]
    stp  x22, x23, [sp, #32]
    mov  x20, x0
    ldr  x9, [x20, #STR_LEN]
    cbz  x9, .Lac_empty
    ldr  x21, [x19, #C_NCOLS]
    ldr  x22, [x19, #C_COLCAP]
    cmp  x21, x22
    b.lo 1f
    lsl  x22, x22, #1
    // names (8 bytes each)
    lsl  x0, x22, #3
    bl   arena_alloc
    mov  x23, x0
    ldr  x1, [x19, #C_NAMES]
    lsl  x2, x21, #3
    bl   memcpy
    str  x23, [x19, #C_NAMES]
    // stamps (8 bytes each)
    lsl  x0, x22, #3
    bl   arena_alloc
    mov  x23, x0
    ldr  x1, [x19, #C_STAMP]
    lsl  x2, x21, #3
    bl   memcpy
    str  x23, [x19, #C_STAMP]
    // states (4 bytes each)
    lsl  x0, x22, #2
    bl   arena_alloc
    mov  x23, x0
    ldr  x1, [x19, #C_STATE]
    lsl  x2, x21, #2
    bl   memcpy
    str  x23, [x19, #C_STATE]
    str  x22, [x19, #C_COLCAP]
1:  ldr  x9, [x19, #C_NAMES]
    str  x20, [x9, x21, lsl #3]
    ldr  x9, [x19, #C_STAMP]
    str  xzr, [x9, x21, lsl #3]
    ldr  x9, [x19, #C_STATE]
    str  wzr, [x9, x21, lsl #2]
    add  x9, x21, #1
    str  x9, [x19, #C_NCOLS]
    mov  x0, x21
    ldp  x20, x21, [sp, #16]
    ldp  x22, x23, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
.Lac_empty:
    RAISE ERR_INGEST, "empty column name (JSON key)"
ENDF json_add_col

// -----------------------------------------------------------------------------
// json_infer(x0 column, x1 value JNode*) — update the column's inference
// state (ingestion.md §2.1); mixed value kinds raise INGEST_ERROR.
// Registers: x20 &state[col], w21 state, x22 Str* (number/string text),
//            x23 column.
// -----------------------------------------------------------------------------
LFUNC json_infer
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x20, x21, [sp, #16]
    stp  x22, x23, [sp, #32]
    mov  x23, x0
    ldr  x9, [x19, #C_STATE]
    add  x20, x9, x0, lsl #2
    ldr  w21, [x20]
    ldr  w2, [x1, #JN_TYPE]
    ldr  x22, [x1, #JN_PTR]
    cmp  w2, #J_NULL
    b.eq .Lji_ret
    cmp  w2, #J_NUM
    b.eq .Lji_num
    cmp  w2, #J_STR
    b.eq .Lji_str
    orr  w21, w21, #JS_BOOL         // J_TRUE / J_FALSE
    b    .Lji_mix
.Lji_num:
    orr  w21, w21, #JS_NUM
    tbnz w21, #3, .Lji_mix          // already known non-integer
    ldr  x1, [x22, #STR_LEN]
    add  x0, x22, #STR_DATA
    mov  x3, #0                     // look for '.', 'e', 'E'
1:  cmp  x3, x1
    b.hs 2f
    ldrb w4, [x0, x3]
    add  x3, x3, #1
    cmp  w4, #'.'
    b.eq 3f
    orr  w4, w4, #0x20
    cmp  w4, #'e'
    b.eq 3f
    b    1b
2:  bl   parse_int64                // x0/x1 = text
    cbz  w1, .Lji_mix
3:  orr  w21, w21, #JS_NONINT
    b    .Lji_mix
.Lji_str:
    orr  w21, w21, #JS_STR
    tbnz w21, #5, .Lji_mix          // already STRING
    tbnz w21, #4, 4f                // already not all DATE
    add  x0, x22, #STR_DATA
    ldr  x1, [x22, #STR_LEN]
    bl   parse_date
    cbz  w1, .Lji_mix
    orr  w21, w21, #JS_NOTDATE
4:  add  x0, x22, #STR_DATA
    ldr  x1, [x22, #STR_LEN]
    mov  w2, #1
    bl   parse_timestamp
    cbz  w1, .Lji_mix
    orr  w21, w21, #JS_NOTTS
.Lji_mix:
    and  w9, w21, #(JS_BOOL | JS_NUM | JS_STR)
    sub  w10, w9, #1
    tst  w9, w10
    b.ne .Lji_mixed                 // more than one kind of value
    str  w21, [x20]
.Lji_ret:
    ldp  x20, x21, [sp, #16]
    ldp  x22, x23, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
.Lji_mixed:
    ldr  x9, [x19, #C_NAMES]
    ldr  x2, [x9, x23, lsl #3]
    add  x2, x2, #STR_DATA
    mov  w0, #ERR_INGEST
    ADR_L x1, msg_mixed
    bl   raise_fmt
ENDF json_infer

// -----------------------------------------------------------------------------
// json_finish_types: allocate C_TYPES and derive each type from C_STATE.
// Registers: x20 ncols.
// -----------------------------------------------------------------------------
LFUNC json_finish_types
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    str  x20, [sp, #16]
    ldr  x20, [x19, #C_NCOLS]
    lsl  x0, x20, #2
    add  x0, x0, #4
    bl   arena_alloc
    str  x0, [x19, #C_TYPES]
    ldr  x1, [x19, #C_STATE]
    mov  x2, #0
1:  cmp  x2, x20
    b.hs 9f
    ldr  w3, [x1, x2, lsl #2]
    mov  w4, #T_STR                 // no values / non-date strings
    tbz  w3, #0, 2f
    mov  w4, #T_BOOL
    b    8f
2:  tbz  w3, #1, 3f
    mov  w4, #T_INT
    tbz  w3, #3, 8f
    mov  w4, #T_FLOAT
    b    8f
3:  tbz  w3, #2, 8f
    mov  w4, #T_DATE
    tbz  w3, #4, 8f
    mov  w4, #T_TS
    tbz  w3, #5, 8f
    mov  w4, #T_STR
8:  str  w4, [x0, x2, lsl #2]
    add  x2, x2, #1
    b    1b
9:  ldr  x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF json_finish_types

// -----------------------------------------------------------------------------
// json_convert(x0 column, x1 value JNode*, x2 row) — store one JSON value
// (ingestion.md §2.2; also used for inferred columns where it cannot fail
// except for non-finite numbers).
// Registers: x20 column, x21 node, x22 row, w23 kind.
// -----------------------------------------------------------------------------
LFUNC json_convert
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x20, x21, [sp, #16]
    stp  x22, x23, [sp, #32]
    mov  x20, x0
    mov  x21, x1
    mov  x22, x2
    ldr  x9, [x19, #C_TYPES]
    ldr  w23, [x9, x20, lsl #2]
    and  w23, w23, #T_KIND_MASK
    ldr  w9, [x21, #JN_TYPE]
    cmp  w9, #J_NULL
    b.eq .Ljc_ret
    cmp  w9, #J_NUM
    b.eq .Ljc_num
    cmp  w9, #J_STR
    b.eq .Ljc_str
    // boolean
    cmp  w23, #T_BOOL
    b.ne .Ljc_fail_bool
    cmp  w9, #J_TRUE
    cset x0, eq
    ldr  x9, [x19, #C_COLS]
    add  x9, x9, x20, lsl #5
    ldr  x10, [x9, #COL_DATA]
    str  x0, [x10, x22, lsl #3]
    ldr  x10, [x9, #COL_NULLS]
    NULLBIT_CLEAR 10, 22, 11, 12, 13, 14
    b    .Ljc_ret
.Ljc_num:
    cmp  w23, #T_INT
    b.eq .Ljc_text
    cmp  w23, #T_FLOAT
    b.eq .Ljc_text
    cmp  w23, #T_DEC
    b.eq .Ljc_text
    b    .Ljc_fail_text
.Ljc_str:
    cmp  w23, #T_BOOL
    b.eq .Ljc_fail_text
.Ljc_text:
    ldr  x9, [x21, #JN_PTR]
    mov  x0, x20
    add  x1, x9, #STR_DATA
    ldr  x2, [x9, #STR_LEN]
    mov  x3, x22
    bl   store_text
.Ljc_ret:
    ldp  x20, x21, [sp, #16]
    ldp  x22, x23, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
.Ljc_fail_text:
    ldr  x9, [x21, #JN_PTR]
    add  x1, x9, #STR_DATA
    ldr  x2, [x9, #STR_LEN]
    b    1f
.Ljc_fail_bool:
    ADR_L x1, s_true
    mov  x2, #4
    cmp  w9, #J_TRUE
    b.eq 1f
    ADR_L x1, s_false
    mov  x2, #5
1:  mov  w10, #ERR_CONVERSION       // a JSON kind / column type mismatch
    str  w10, [x19, #C_CONVERR]     // is always a CONVERSION_ERROR
    mov  x0, x20
    bl   conv_fail
ENDF json_convert

// -----------------------------------------------------------------------------
// json_ingest — JSON / JSONL driver.
// Registers: x20 JNode** objects, x21 object count, x22 record index,
//            x23 object, x24 pair array, x25 pair index, x26 pair count,
//            x27 current column, x28 Schema*.
// -----------------------------------------------------------------------------
LFUNC json_ingest
    stp  x29, x30, [sp, #-96]!
    mov  x29, sp
    stp  x20, x21, [sp, #16]
    stp  x22, x23, [sp, #32]
    stp  x24, x25, [sp, #48]
    stp  x26, x27, [sp, #64]
    str  x28, [sp, #80]
    ldr  x28, [x19, #C_SCHEMA]
    ldr  w0, [x19, #C_FMT]
    cmp  w0, #FMT_JSON
    b.ne 1f
    ldr  x0, [x19, #C_DATA]
    ldr  x1, [x19, #C_END]
    sub  x1, x1, x0
    bl   json_parse
    cbz  x0, .Ljs_invalid
    ldr  w1, [x0, #JN_TYPE]
    cmp  w1, #J_ARR
    b.ne .Ljs_notarr
    ldr  w21, [x0, #JN_COUNT]
    ldr  x20, [x0, #JN_PTR]
    b    2f
1:  bl   jsonl_split
    mov  x20, x0
    mov  x21, x1
2:  LDR_G x0, g_max_table_rows
    cmp  x21, x0
    b.hi .Ljs_rows
    str  x21, [x19, #C_NROWS]
    // ---- column set-up
    cbz  x28, 3f
    ldr  x0, [x28, #SCH_N]
    str  x0, [x19, #C_NCOLS]
    ldr  x1, [x28, #SCH_NAMES]
    str  x1, [x19, #C_NAMES]
    ldr  x1, [x28, #SCH_TYPES]
    str  x1, [x19, #C_TYPES]
    lsl  x0, x0, #3
    add  x0, x0, #8
    bl   arena_zalloc
    str  x0, [x19, #C_STAMP]
    b    4f
3:  str  xzr, [x19, #C_NCOLS]
    mov  x0, #16
    str  x0, [x19, #C_COLCAP]
    mov  x0, #(16*8)
    bl   arena_alloc
    str  x0, [x19, #C_NAMES]
    mov  x0, #(16*8)
    bl   arena_alloc
    str  x0, [x19, #C_STAMP]
    mov  x0, #(16*4)
    bl   arena_alloc
    str  x0, [x19, #C_STATE]
    // ---- pass A: columns, validation, inference
4:  mov  x22, #0
5:  cmp  x22, x21
    b.hs 10f
    ldr  x23, [x20, x22, lsl #3]
    add  x0, x22, #1
    str  x0, [x19, #C_REC]
    ldr  w0, [x23, #JN_TYPE]
    cmp  w0, #J_OBJ
    b.ne .Ljs_notobj
    ldr  w26, [x23, #JN_COUNT]
    ldr  x24, [x23, #JN_PTR]
    mov  x25, #0
    mov  x27, #-1
6:  cmp  x25, x26
    b.hs 9f
    add  x9, x24, x25, lsl #4
    ldr  x0, [x9]                   // key node
    ldr  x0, [x0, #JN_PTR]          // key Str*
    add  x1, x27, #1                // guess: column after the previous one
    bl   json_col_lookup
    tbz  x0, #63, 7f
    cbnz x28, .Ljs_unknown
    add  x9, x24, x25, lsl #4
    ldr  x0, [x9]
    ldr  x0, [x0, #JN_PTR]
    bl   json_add_col
7:  mov  x27, x0
    ldr  x9, [x19, #C_STAMP]        // duplicate key in this object?
    ldr  x1, [x9, x27, lsl #3]
    add  x2, x22, #1
    cmp  x1, x2
    b.eq .Ljs_dup
    str  x2, [x9, x27, lsl #3]
    add  x9, x24, x25, lsl #4
    ldr  x1, [x9, #8]               // value node
    ldr  w2, [x1, #JN_TYPE]
    cmp  w2, #J_ARR
    b.hs .Ljs_nested                // J_ARR / J_OBJ
    cmp  w2, #J_STR
    b.ne 8f
    ldr  x3, [x1, #JN_PTR]
    ldr  x3, [x3, #STR_LEN]
    mov  x4, #MAX_FIELD
    cmp  x3, x4
    b.hi .Ljs_toolong
8:  cbnz x28, 85f
    mov  x0, x27
    bl   json_infer
85: add  x25, x25, #1
    b    6b
9:  add  x22, x22, #1
    b    5b
10: cbnz x28, 11f
    bl   json_finish_types
11: bl   alloc_columns
    // ---- pass B: conversion
    mov  x22, #0
12: cmp  x22, x21
    b.hs 15f
    ldr  x23, [x20, x22, lsl #3]
    add  x0, x22, #1
    str  x0, [x19, #C_REC]
    ldr  w26, [x23, #JN_COUNT]
    ldr  x24, [x23, #JN_PTR]
    mov  x25, #0
    mov  x27, #-1
13: cmp  x25, x26
    b.hs 14f
    add  x9, x24, x25, lsl #4
    ldr  x0, [x9]
    ldr  x0, [x0, #JN_PTR]
    add  x1, x27, #1
    bl   json_col_lookup
    mov  x27, x0
    add  x9, x24, x25, lsl #4
    ldr  x1, [x9, #8]
    mov  x2, x22
    bl   json_convert
    add  x25, x25, #1
    b    13b
14: add  x22, x22, #1
    b    12b
15: ldp  x20, x21, [sp, #16]
    ldp  x22, x23, [sp, #32]
    ldp  x24, x25, [sp, #48]
    ldp  x26, x27, [sp, #64]
    ldr  x28, [sp, #80]
    ldp  x29, x30, [sp], #96
    ret
.Ljs_invalid:
    RAISE ERR_INGEST, "invalid JSON document"
.Ljs_notarr:
    RAISE ERR_INGEST, "JSON document must be an array of objects"
.Ljs_rows:
    RAISE ERR_RESOURCE_LIMIT, "table row limit exceeded"
.Ljs_toolong:
    mov  w0, #ERR_INGEST
    ADR_L x1, msg_toolong
    ldr  x2, [x19, #C_REC]
    bl   raise_fmt
.Ljs_notobj:
    mov  w0, #ERR_INGEST
    ADR_L x1, msg_notobj
    ldr  x2, [x19, #C_REC]
    bl   raise_fmt
.Ljs_unknown:
    ADR_L x1, msg_unknown_key
    b    .Ljs_keyerr
.Ljs_dup:
    ADR_L x1, msg_dup_key
    b    .Ljs_keyerr
.Ljs_nested:
    ADR_L x1, msg_nested
.Ljs_keyerr:                        // message(key, record)
    add  x9, x24, x25, lsl #4
    ldr  x2, [x9]
    ldr  x2, [x2, #JN_PTR]
    add  x2, x2, #STR_DATA
    ldr  x3, [x19, #C_REC]
    mov  w0, #ERR_INGEST
    bl   raise_fmt
ENDF json_ingest

// ------------------------------------------------------------- constants -----
    .section .rodata
    .p2align 3
type_names:
    .quad s_tstr, s_tbool, s_tint, s_tdec, s_tfloat, s_tstr, s_tdate, s_tts
cb_types:                           // candidate bit index -> type
    .byte T_BOOL, T_INT, T_FLOAT, T_DATE, T_TS
s_tbool:   .asciz "BOOLEAN"
s_tint:    .asciz "INT64"
s_tdec:    .asciz "DECIMAL"
s_tfloat:  .asciz "FLOAT64"
s_tstr:    .asciz "STRING"
s_tdate:   .asciz "DATE"
s_tts:     .asciz "TIMESTAMP"
s_true:    .asciz "true"
s_false:   .asciz "false"
msg_conv:         .asciz "cannot convert '%.*s' to %s (column '%s', record %lu)"
msg_unterminated: .asciz "unterminated quoted field in CSV record %lu"
msg_garbage:      .asciz "unexpected character after closing quote in CSV record %lu"
msg_toolong:      .asciz "field longer than 16 MiB in record %lu"
msg_dupcol:       .asciz "duplicate column name '%s'"
msg_arity:        .asciz "CSV record %lu has %lu fields, expected %lu"
msg_jl_invalid:   .asciz "invalid JSON on line %lu"
msg_jl_notobj:    .asciz "line %lu is not a JSON object"
msg_notobj:       .asciz "JSON array element %lu is not an object"
msg_unknown_key:  .asciz "key '%s' is not a schema column (record %lu)"
msg_dup_key:      .asciz "duplicate key '%s' in record %lu"
msg_nested:       .asciz "nested object or array for key '%s' (record %lu)"
msg_mixed:        .asciz "column '%s' mixes JSON value types"

    NOTE_GNU_STACK
