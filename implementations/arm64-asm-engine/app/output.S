// =============================================================================
// output.S — result rendering (spec/apps/pqledger.md §7): table / csv / json.
//
//   render_result(x0 pq_result*, w1 format OF_*, x2 Buf* out)
//       Appends the complete rendering of the result to `out` (the existing
//       contents are kept). Unknown formats render as OF_TABLE.
//
// Value text (table, csv, json values of non-BOOLEAN types) comes from the
// engine: pq_format_value(col, val, PQ_FMT_FLOAT_FIXED6, buf, cap), except
// STRING values, whose stored bytes (v.str, aux bytes) are used directly, and
// NULL, which is empty text. Formatted text goes to a module scratch buffer
// that lives for the duration of one render_result call.
//
// Every pass is linear in the size of the result: the table format measures
// all column widths in one pass and renders in a second one; CSV and JSON
// fields are escaped straight into space reserved in bulk with buf_reserve;
// JSON object keys are escaped once per result, not once per row.
// =============================================================================
#include "ledger.inc"

// cell flags of table_cell
#define CF_RIGHT    1               // right-aligned (INT64, DECIMAL, FLOAT64)
#define CF_SEP      2               // two-space separator before the cell

    .section .rodata
s_empty:    .byte 0
s_null:     .ascii "null"
s_true:     .ascii "true"
s_false:    .ascii "false"
s_obj_end:  .ascii "}\n"
s_row:      .ascii " row)\n"
    .equ S_ROW_LEN, . - s_row
s_rows:     .ascii " rows)\n"
    .equ S_ROWS_LEN, . - s_rows
hex_digits: .ascii "0123456789abcdef"
// JSON escapes of the bytes 0x00..0x1f: the letter after '\', 0 = \u00xx
json_esc:
    .byte 0, 0, 0, 0, 0, 0, 0, 0, 'b', 't', 'n', 0, 'f', 'r', 0, 0
    .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0

    .bss
    .p2align 3
fmt_scratch: .skip BUF_SIZE         // Buf: pq_format_value output (len stays 0)

    .text

// CELL_FLAGS wd, xcol, xidx: CF_* flags of the cell of column `xcol` (a
// pq_column*) at column index `xidx`. Clobbers w9.
.macro CELL_FLAGS wd, xcol, xidx
    ldr  w9, [\xcol, #PQC_TYPE]
    sub  w9, w9, #PQ_T_INT64        // INT64, DECIMAL, FLOAT64 are consecutive
    cmp  w9, #(PQ_T_FLOAT64 - PQ_T_INT64)
    cset \wd, ls                    // CF_RIGHT
    cmp  \xidx, #0
    cset w9, ne
    orr  \wd, \wd, w9, lsl #1       // CF_SEP unless first column
.endm

// render_result(x0 pq_result*, w1 format, x2 Buf* out)
//   x19 result, w20 format, x21 out
FUNC render_result
    ENTER 2
    mov  x19, x0
    mov  w20, w1
    mov  x21, x2
    ADR_L x0, fmt_scratch           // scratch for pq_format_value
    mov  x1, #127
    bl   buf_reserve
    mov  x0, x19
    mov  x1, x21
    cmp  w20, #OF_CSV
    b.eq 1f
    cmp  w20, #OF_JSON
    b.eq 2f
    bl   render_table
    b    3f
1:  bl   render_csv
    b    3f
2:  bl   render_json
3:  ADR_L x0, fmt_scratch
    bl   buf_free
    LEAVE 2
ENDF render_result

// ------------------------------------------------------------ cell text ------

// cell_text(x0 pq_column*, x1 pq_value*) -> x0 ptr, x1 len
//   Value text of one cell: NULL => empty, STRING => the stored bytes, other
//   types => pq_format_value into fmt_scratch (valid until the next call).
//   x19 column, x20 value, x21 &fmt_scratch
LFUNC cell_text
    ldr  w2, [x1, #PQV_IS_NULL]
    cbnz w2, 8f
    ldr  w2, [x0, #PQC_TYPE]
    cmp  w2, #PQ_T_STRING
    b.ne 1f
    ldr  x0, [x1, #PQV_V]
    ldr  x1, [x1, #PQV_AUX]
    ret
8:  ADR_L x0, s_empty
    mov  x1, #0
    ret
1:  ENTER 2
    mov  x19, x0
    mov  x20, x1
    ADR_L x21, fmt_scratch
    mov  w2, #PQ_FMT_FLOAT_FIXED6
    ldr  x3, [x21, #BUF_PTR]
    ldr  x4, [x21, #BUF_CAP]
    bl   pq_format_value
    ldr  x4, [x21, #BUF_CAP]
    cmp  x0, x4
    b.lo 2f
    mov  x1, x0                     // truncated: grow to length + 1, again
    mov  x0, x21
    bl   buf_reserve
    mov  x0, x19
    mov  x1, x20
    mov  w2, #PQ_FMT_FLOAT_FIXED6
    ldr  x3, [x21, #BUF_PTR]
    ldr  x4, [x21, #BUF_CAP]
    bl   pq_format_value
2:  mov  x1, x0
    ldr  x0, [x21, #BUF_PTR]
    LEAVE 2
ENDF cell_text

// col_name(x0 pq_column*) -> x0 ptr, x1 len   (a NULL name is "")
LFUNC col_name
    ENTER 1
    ldr  x19, [x0, #PQC_NAME]
    cbnz x19, 1f
    ADR_L x19, s_empty
1:  mov  x0, x19
    bl   strlen
    mov  x1, x0
    mov  x0, x19
    LEAVE 1
ENDF col_name

// u8_width(x0 ptr, x1 len) -> x0 code points: the bytes that are not UTF-8
// continuation bytes (10xxxxxx)   (leaf)
LFUNC u8_width
    mov  x2, #0
    add  x1, x0, x1                 // end
1:  cmp  x0, x1
    b.hs 2f
    ldrb w3, [x0], #1
    and  w3, w3, #0xc0
    cmp  w3, #0x80
    cinc x2, x2, ne
    b    1b
2:  mov  x0, x2
    ret
ENDF u8_width

// fill_spaces(x0 p, x1 n) -> x0 p + n: store n spaces   (leaf)
LFUNC fill_spaces
    cbz  x1, 2f
    mov  w2, #' '
1:  strb w2, [x0], #1
    subs x1, x1, #1
    b.ne 1b
2:  ret
ENDF fill_spaces

// ---------------------------------------------------------------- table ------

// table_cell(x0 Buf*, x1 ptr, x2 len, x3 width, w4 CF_* flags): append one
// cell padded with spaces to `width` code points
//   x19 out, x20 ptr, x21 len, x22 padding, w23 flags, x24 write cursor
LFUNC table_cell
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x22, x3
    mov  w23, w4
    mov  x0, x1
    mov  x1, x2
    bl   u8_width
    sub  x22, x22, x0               // padding = width - code points
    add  x1, x21, x22
    add  x1, x1, #2
    mov  x0, x19
    bl   buf_reserve
    mov  x24, x0
    tbz  w23, #1, 1f                // CF_SEP
    mov  w9, #' '
    strb w9, [x24], #1
    strb w9, [x24], #1
1:  tbz  w23, #0, 2f                // CF_RIGHT: padding first
    mov  x0, x24
    mov  x1, x22
    bl   fill_spaces
    mov  x24, x0
2:  mov  x0, x24
    mov  x1, x20
    mov  x2, x21
    bl   memcpy
    add  x24, x24, x21
    tbnz w23, #0, 3f                // left-aligned: padding after the text
    mov  x0, x24
    mov  x1, x22
    bl   fill_spaces
    mov  x24, x0
3:  ldp  x9, x10, [x19, #BUF_PTR]   // BUF_PTR, BUF_LEN
    add  x9, x9, x10
    sub  x9, x24, x9                // bytes written
    add  x10, x10, x9
    str  x10, [x19, #BUF_LEN]
    LEAVE 3
ENDF table_cell

// table_eol(x0 Buf*, x1 line start offset): drop the trailing spaces of the
// current line (never before its start) and end it with '\n'
LFUNC table_eol
    ldr  x2, [x0, #BUF_PTR]
    ldr  x3, [x0, #BUF_LEN]
1:  cmp  x3, x1
    b.ls 2f
    sub  x4, x3, #1
    ldrb w5, [x2, x4]
    cmp  w5, #' '
    b.ne 2f
    mov  x3, x4
    b    1b
2:  str  x3, [x0, #BUF_LEN]
    mov  w1, #'\n'
    b    buf_putc
ENDF table_eol

// render_table(x0 pq_result*, x1 Buf* out)
//   x19 out, x20 ncols, x21 nrows, x22 columns, x23 widths[ncols] (u64),
//   x24 value cursor, x25 rows left, x26 column index, x27 line start,
//   x28 current column; sp+0 values, sp+8 line size estimate (bytes)
LFUNC render_table
    ENTER 5
    sub  sp, sp, #16
    mov  x19, x1
    ldr  x20, [x0, #PQR_NCOLS]
    ldr  x21, [x0, #PQR_NROWS]
    ldr  x22, [x0, #PQR_COLUMNS]
    ldr  x9, [x0, #PQR_VALUES]
    str  x9, [sp]
    lsl  x0, x20, #3
    bl   xmalloc
    mov  x23, x0

    // pass 1: widths = code points of the name and of every value text
    mov  x26, #0
1:  cmp  x26, x20
    b.hs 2f
    add  x0, x22, x26, lsl #5       // PQC_SIZE = 32
    bl   col_name
    bl   u8_width
    str  x0, [x23, x26, lsl #3]
    add  x26, x26, #1
    b    1b
2:  ldr  x24, [sp]
    mov  x25, x21
3:  cbz  x25, 6f
    mov  x26, #0
4:  cmp  x26, x20
    b.hs 5f
    add  x0, x22, x26, lsl #5
    mov  x1, x24
    bl   cell_text
    bl   u8_width
    ldr  x9, [x23, x26, lsl #3]
    cmp  x0, x9
    csel x9, x0, x9, hi
    str  x9, [x23, x26, lsl #3]
    add  x24, x24, #PQV_SIZE
    add  x26, x26, #1
    b    4b
5:  sub  x25, x25, #1
    b    3b

    // reserve the whole table: (sum of widths + separators + '\n') per line
6:  mov  x9, #1
    mov  x26, #0
7:  cmp  x26, x20
    b.hs 8f
    ldr  x10, [x23, x26, lsl #3]
    add  x9, x9, x10
    add  x9, x9, #2
    add  x26, x26, #1
    b    7b
8:  str  x9, [sp, #8]
    add  x10, x21, #2               // header + dashes + rows
    mul  x1, x9, x10
    add  x1, x1, #32                // footer
    mov  x0, x19
    bl   buf_reserve

    // header line
    ldr  x27, [x19, #BUF_LEN]
    mov  x26, #0
10: cmp  x26, x20
    b.hs 11f
    add  x28, x22, x26, lsl #5
    mov  x0, x28
    bl   col_name
    mov  x2, x1
    mov  x1, x0
    ldr  x3, [x23, x26, lsl #3]
    CELL_FLAGS w4, x28, x26
    mov  x0, x19
    bl   table_cell
    add  x26, x26, #1
    b    10b
11: mov  x0, x19
    mov  x1, x27
    bl   table_eol

    // line of '-' runs
    ldr  x27, [x19, #BUF_LEN]
    mov  x0, x19
    ldr  x1, [sp, #8]
    bl   buf_reserve                // x0 = write cursor
    mov  w10, #' '
    mov  w11, #'-'
    mov  x26, #0
12: cmp  x26, x20
    b.hs 15f
    cbz  x26, 13f
    strb w10, [x0], #1
    strb w10, [x0], #1
13: ldr  x9, [x23, x26, lsl #3]
14: cbz  x9, 16f
    strb w11, [x0], #1
    sub  x9, x9, #1
    b    14b
16: add  x26, x26, #1
    b    12b
15: ldr  x9, [x19, #BUF_PTR]
    sub  x0, x0, x9
    str  x0, [x19, #BUF_LEN]
    mov  x0, x19
    mov  x1, x27
    bl   table_eol

    // pass 2: the rows
    ldr  x24, [sp]
    mov  x25, x21
20: cbz  x25, 23f
    ldr  x27, [x19, #BUF_LEN]
    mov  x26, #0
21: cmp  x26, x20
    b.hs 22f
    add  x28, x22, x26, lsl #5
    mov  x0, x28
    mov  x1, x24
    bl   cell_text
    mov  x2, x1
    mov  x1, x0
    ldr  x3, [x23, x26, lsl #3]
    CELL_FLAGS w4, x28, x26
    mov  x0, x19
    bl   table_cell
    add  x24, x24, #PQV_SIZE
    add  x26, x26, #1
    b    21b
22: mov  x0, x19
    mov  x1, x27
    bl   table_eol
    sub  x25, x25, #1
    b    20b

    // footer: (N rows) / (1 row)
23: mov  x0, x19
    mov  w1, #'('
    bl   buf_putc
    mov  x0, x19
    mov  x1, x21
    bl   buf_put_i64
    mov  x0, x19
    ADR_L x1, s_rows
    mov  x2, #S_ROWS_LEN
    cmp  x21, #1
    b.ne 24f
    ADR_L x1, s_row
    mov  x2, #S_ROW_LEN
24: bl   buf_put
    mov  x0, x23
    bl   free
    add  sp, sp, #16
    LEAVE 5
ENDF render_table

// ------------------------------------------------------------------ csv ------

// csv_field(x0 Buf*, x1 ptr, x2 len): append one non-NULL field, enclosed in
// '"' (with '"' doubled) when it is empty, starts or ends with a space, or
// contains ',', '"', CR or LF; otherwise as is
//   x19 out, x20 input cursor, x21 len
LFUNC csv_field
    cbz  x2, 3f                     // empty string: ""
    ldrb w3, [x1]
    cmp  w3, #' '
    b.eq 3f
    sub  x4, x2, #1
    ldrb w3, [x1, x4]
    cmp  w3, #' '
    b.eq 3f
    mov  x7, #0x2400                // bits 10 (LF), 13 (CR),
    movk x7, #0x1004, lsl #32       //      34 ('"'), 44 (',')
    mov  x4, #0
1:  ldrb w3, [x1, x4]
    cmp  w3, #63
    b.hi 2f
    lsr  x5, x7, x3
    tbnz x5, #0, 3f
2:  add  x4, x4, #1
    cmp  x4, x2
    b.lo 1b
    b    buf_put                    // plain field (tail call, x0..x2 intact)
3:  ENTER 2
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    lsl  x1, x2, #1                 // worst case: every byte a '"'
    add  x1, x1, #2
    bl   buf_reserve
    mov  x3, x0                     // start of the field
    mov  w5, #'"'
    strb w5, [x0], #1
    add  x6, x20, x21               // end of the input
4:  cmp  x20, x6
    b.hs 5f
    ldrb w4, [x20], #1
    strb w4, [x0], #1
    cmp  w4, #'"'
    b.ne 4b
    strb w4, [x0], #1               // '"' doubled
    b    4b
5:  strb w5, [x0], #1
    sub  x0, x0, x3
    ldr  x9, [x19, #BUF_LEN]
    add  x9, x9, x0
    str  x9, [x19, #BUF_LEN]
    LEAVE 2
ENDF csv_field

// render_csv(x0 pq_result*, x1 Buf* out)
//   x19 out, x20 ncols, x21 nrows, x22 columns, x24 value cursor,
//   x25 rows left, x26 column index
LFUNC render_csv
    ENTER 4
    mov  x19, x1
    ldr  x20, [x0, #PQR_NCOLS]
    ldr  x21, [x0, #PQR_NROWS]
    ldr  x22, [x0, #PQR_COLUMNS]
    ldr  x24, [x0, #PQR_VALUES]

    // header record
    mov  x26, #0
1:  cmp  x26, x20
    b.hs 3f
    cbz  x26, 2f
    mov  x0, x19
    mov  w1, #','
    bl   buf_putc
2:  add  x0, x22, x26, lsl #5       // PQC_SIZE = 32
    bl   col_name
    mov  x2, x1
    mov  x1, x0
    mov  x0, x19
    bl   csv_field
    add  x26, x26, #1
    b    1b
3:  mov  x0, x19
    mov  w1, #'\n'
    bl   buf_putc

    // one record per row
    mov  x25, x21
4:  cbz  x25, 9f
    mov  x26, #0
5:  cmp  x26, x20
    b.hs 8f
    cbz  x26, 6f
    mov  x0, x19
    mov  w1, #','
    bl   buf_putc
6:  ldr  w9, [x24, #PQV_IS_NULL]
    cbnz w9, 7f                     // NULL: empty unquoted field
    add  x0, x22, x26, lsl #5
    mov  x1, x24
    bl   cell_text
    mov  x2, x1
    mov  x1, x0
    mov  x0, x19
    bl   csv_field
7:  add  x24, x24, #PQV_SIZE
    add  x26, x26, #1
    b    5b
8:  mov  x0, x19
    mov  w1, #'\n'
    bl   buf_putc
    sub  x25, x25, #1
    b    4b
9:  LEAVE 4
ENDF render_csv

// ----------------------------------------------------------------- json ------

// json_str(x0 Buf*, x1 ptr, x2 len): append a JSON string: '"' and '\'
// escaped, \b \t \n \f \r, other bytes < 0x20 as \u00xx, the rest as is
//   x19 out, x20 input cursor, x21 len
LFUNC json_str
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    add  x1, x2, x2, lsl #1
    lsl  x1, x1, #1                 // worst case: 6 bytes (\u00xx) per byte
    add  x1, x1, #2
    bl   buf_reserve
    mov  x3, x0                     // start of the string
    ADR_L x7, json_esc
    ADR_L x8, hex_digits
    mov  w9, #'"'
    mov  w10, #'\\'
    strb w9, [x0], #1
    add  x6, x20, x21               // end of the input
1:  cmp  x20, x6
    b.hs 5f
    ldrb w4, [x20], #1
    cmp  w4, #0x20
    b.lo 3f
    cmp  w4, #'"'
    ccmp w4, w10, #4, ne
    b.eq 2f
    strb w4, [x0], #1               // plain byte (UTF-8 passes through)
    b    1b
2:  strb w10, [x0], #1              // \" or \\ (backslash pair)
    strb w4, [x0], #1
    b    1b
3:  ldrb w5, [x7, x4]               // control byte
    strb w10, [x0], #1
    cbz  w5, 4f
    strb w5, [x0], #1               // \b \t \n \f \r
    b    1b
4:  mov  w5, #'u'
    strb w5, [x0], #1
    mov  w5, #'0'
    strb w5, [x0], #1
    strb w5, [x0], #1
    lsr  w5, w4, #4
    ldrb w5, [x8, x5]
    strb w5, [x0], #1
    and  w5, w4, #15
    ldrb w5, [x8, x5]
    strb w5, [x0], #1
    b    1b
5:  strb w9, [x0], #1
    sub  x0, x0, x3
    ldr  x9, [x19, #BUF_LEN]
    add  x9, x9, x0
    str  x9, [x19, #BUF_LEN]
    LEAVE 2
ENDF json_str

// render_json(x0 pq_result*, x1 Buf* out)
//   The key fragments `"name":` (with a leading ',' after the first column)
//   are built once into a local Buf; offsets[c]..offsets[c+1] delimit
//   column c's fragment.
//   x19 out, x20 ncols, x21 nrows, x22 columns, x23 offsets[ncols + 1],
//   x24 value cursor, x25 rows left, x26 column index, x27 fragment bytes,
//   x28 current column; sp: Buf of key fragments
LFUNC render_json
    ENTER 5
    sub  sp, sp, #BUF_SIZE
    stp  xzr, xzr, [sp]
    stp  xzr, xzr, [sp, #16]
    mov  x19, x1
    ldr  x20, [x0, #PQR_NCOLS]
    ldr  x21, [x0, #PQR_NROWS]
    ldr  x22, [x0, #PQR_COLUMNS]
    ldr  x24, [x0, #PQR_VALUES]
    add  x0, x20, #1
    lsl  x0, x0, #3
    bl   xmalloc
    mov  x23, x0

    // key fragments
    mov  x26, #0
1:  ldr  x9, [sp, #BUF_LEN]
    str  x9, [x23, x26, lsl #3]
    cmp  x26, x20
    b.hs 3f
    cbz  x26, 2f
    mov  x0, sp
    mov  w1, #','
    bl   buf_putc
2:  add  x0, x22, x26, lsl #5       // PQC_SIZE = 32
    bl   col_name
    mov  x2, x1
    mov  x1, x0
    mov  x0, sp
    bl   json_str
    mov  x0, sp
    mov  w1, #':'
    bl   buf_putc
    add  x26, x26, #1
    b    1b
3:  ldr  x27, [sp, #BUF_PTR]        // final: no more appends to the keys

    // one object per row
    mov  x25, x21
4:  cbz  x25, 9f
    mov  x0, x19
    mov  w1, #'{'
    bl   buf_putc
    mov  x26, #0
5:  cmp  x26, x20
    b.hs 8f
    ldr  x9, [x23, x26, lsl #3]
    add  x10, x26, #1
    ldr  x10, [x23, x10, lsl #3]
    add  x1, x27, x9
    sub  x2, x10, x9
    mov  x0, x19
    bl   buf_put                    // [,]"key":
    add  x28, x22, x26, lsl #5
    ldr  w9, [x24, #PQV_IS_NULL]
    cbnz w9, 61f
    ldr  w9, [x28, #PQC_TYPE]
    cmp  w9, #PQ_T_BOOLEAN
    b.eq 62f
    mov  x0, x28
    mov  x1, x24
    bl   cell_text
    mov  x2, x1
    mov  x1, x0
    mov  x0, x19
    ldr  w9, [x28, #PQC_TYPE]
    cmp  w9, #PQ_T_INT64
    b.eq 63f
    cmp  w9, #PQ_T_FLOAT64
    b.eq 63f
    bl   json_str                   // STRING, DECIMAL, DATE, TIMESTAMP
    b    7f
63: bl   buf_put                    // INT64, FLOAT64: a JSON number
    b    7f
61: ADR_L x1, s_null
    mov  x2, #4
    b    64f
62: ldr  x9, [x24, #PQV_V]
    ADR_L x1, s_true
    mov  x2, #4
    cbnz x9, 64f
    ADR_L x1, s_false
    mov  x2, #5
64: mov  x0, x19
    bl   buf_put
7:  add  x24, x24, #PQV_SIZE
    add  x26, x26, #1
    b    5b
8:  mov  x0, x19
    ADR_L x1, s_obj_end
    mov  x2, #2
    bl   buf_put
    sub  x25, x25, #1
    b    4b

9:  mov  x0, x23
    bl   free
    mov  x0, sp
    bl   buf_free
    add  sp, sp, #BUF_SIZE
    LEAVE 5
ENDF render_json

    NOTE_GNU_STACK
