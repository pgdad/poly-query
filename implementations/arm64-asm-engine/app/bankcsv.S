// =============================================================================
// bankcsv.S — pqledger bank statement reader: CSV records, dates, amounts and
// merchant normalization (spec/apps/pqledger.md §6.2, §6.3;
// spec/data-types/ingestion.md §1).
//
//   bank_read(x0 path cstr, x1 IS*) -> x0 REC array (xmalloc), x1 count
//       Reads and converts the whole file; every failure is fatal:
//       fail(EX_IMPORT, "FILE:LINE: reason") for a bad record (LINE = 1-based
//       physical line on which the record starts), fail(EX_IMPORT, "FILE: ...")
//       for an unreadable file or an unresolvable column reference.
//       REC_DESC points into the (never freed) file buffer; REC_MERCH is a
//       separate allocation per record.
//   merchant_normalize(x0 ptr, x1 len) -> x0 bytes (xmalloc, NUL-terminated),
//       x1 len                                                         (§6.3)
//   bank_parse_date(x0 ptr, x1 len, w2 DF_*) -> x0 YYYYMMDD, or 0 if invalid
//   bank_parse_amount(x0 ptr, x1 len, x2 IS*) -> x0 cents, w1 0 ok / 1 invalid
//       (§6.2 amount conversion, without invert_sign)
//
// Internal:
//   csv_record(x0 BR*) -> w0 1 = one record parsed into the field array,
//       0 = end of input
//   resolve_columns(x0 BR*, x1 IS*, w2 has_header): column refs -> indexes
//   resolve_col(x0 ref cstr, x1 BR*, w2 has_header) -> x0 0-based index
//
// CSV dialect (RFC 4180): fields separated by IS_DELIM, records end at "\n"
// or "\r\n" (final terminator optional), lines with zero characters ("\n" or
// "\r\n" alone) are skipped. A field is quoted only if its first byte is '"';
// inside, '""' is a literal quote and delimiters / newlines are data. A quote
// inside an unquoted field is literal. Decisions on unspecified input:
//   * any byte other than the delimiter / end of record after a closing quote
//     is an error ("unexpected text after a closing quote");
//   * an unterminated quoted field is an error at the record's start line;
//   * a lone '\r' not followed by '\n' is data;
//   * an empty file, or a file holding only the header, yields 0 records;
//   * column references are resolved against the header as soon as it has
//     been read (so a missing column fails even without data records), or,
//     without a header, against the first record; a name reference without a
//     header, or a position 0 / beyond the field count, is exit 4.
// Quoted fields are unescaped in place inside the file buffer (the unescaped
// text is never longer than the raw text), so no per-field allocation is
// needed and descriptions can point into the buffer.
// =============================================================================
#include "ledger.inc"

// ------------------------------------------- reader state (BR, on stack) -----
// The CSV cursor and the field array of the current record, followed by the
// resolved column indexes. Fields are (ptr, len) pairs, 16 bytes each.
#define BR_POS          0       // u8* next unread byte
#define BR_END          8       // u8* end of the input
#define BR_LINE         16      // u64 physical line of BR_POS (1-based)
#define BR_RLINE        24      // u64 line on which the current record starts
#define BR_FLD          32      // (ptr,len)* field array
#define BR_NF           40      // u64 fields in the current record
#define BR_FCAP         48      // u64 capacity of the field array (entries)
#define BR_PATH         56      // cstr file name (messages)
#define BR_DELIM        64      // u8 delimiter
#define BR_NFIELDS      72      // u64 expected field count (0 = not yet known)
#define BR_IDX_DATE     80      // u64 column indexes (0-based)
#define BR_IDX_DESC     88
#define BR_IDX_A        96      // amount (signed) or debit (debit_credit)
#define BR_IDX_C        104     // credit (debit_credit)
#define BR_CR_PTR       112     // trimmed credit field while converting
#define BR_CR_LEN       120
#define BR_SIZE         128

#define FLD_INIT        16      // initial field array capacity
#define REC_INIT        256     // initial REC array capacity

    .section .rodata
// date format table, 8 bytes per DF_* value:
//   min/max digits of the three numbers, separator (0 = none), order
//   (0 = Y M D, 1 = M D Y, 2 = D M Y)
date_formats:
    .byte 4, 4, 2, 2, 2, 2, '-', 0      // DF_YMD_DASH   YYYY-MM-DD
    .byte 4, 4, 2, 2, 2, 2, 0,   0      // DF_YMD        YYYYMMDD
    .byte 1, 2, 1, 2, 4, 4, '/', 1      // DF_MDY_SLASH  M/D/YYYY
    .byte 1, 2, 1, 2, 4, 4, '/', 2      // DF_DMY_SLASH  D/M/YYYY
    .byte 1, 2, 1, 2, 4, 4, '.', 2      // DF_DMY_DOT    D.M.YYYY
days_in_month:
    .byte 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31
    .text

// ---------------------------------------------------------- bank_read --------

// bank_read(x0 path, x1 IS*) -> x0 REC array, x1 count
//   x19 path, x20 IS*, x21 amount being built, x22 REC array, x23 count,
//   x24 capacity, x25 current REC*, x26 field array, x27/x28 field ptr/len
//   sp: BR
FUNC bank_read
    ENTER 5
    sub  sp, sp, #BR_SIZE
    mov  x19, x0
    mov  x20, x1
    bl   read_file
    cbnz x0, 1f
    mov  x2, x19
    FAIL EX_IMPORT, "%s: cannot read file"
1:  add  x9, x0, x1                     // end of input
    cmp  x1, #3                         // a leading UTF-8 BOM is ignored
    b.lo 2f
    ldrb w10, [x0]
    cmp  w10, #0xEF
    b.ne 2f
    ldrb w10, [x0, #1]
    cmp  w10, #0xBB
    b.ne 2f
    ldrb w10, [x0, #2]
    cmp  w10, #0xBF
    b.ne 2f
    add  x0, x0, #3
2:  stp  x0, x9, [sp, #BR_POS]
    mov  x21, #1                        // line of BR_POS
    ldr  x22, [x20, #IS_SKIP]
3:  cbz  x22, 5f                        // skip the preamble lines
    ldp  x0, x9, [sp, #BR_POS]
    cmp  x0, x9
    b.hs 5f
    mov  w1, #'\n'
    sub  x2, x9, x0
    bl   memchr
    cbnz x0, 4f
    ldr  x0, [sp, #BR_END]              // last line without '\n'
    str  x0, [sp, #BR_POS]
    b    5f
4:  add  x0, x0, #1
    str  x0, [sp, #BR_POS]
    add  x21, x21, #1
    sub  x22, x22, #1
    b    3b

5:  str  x21, [sp, #BR_LINE]
    str  x21, [sp, #BR_RLINE]
    mov  x0, #(FLD_INIT * 16)
    bl   xmalloc
    str  x0, [sp, #BR_FLD]
    mov  x9, #FLD_INIT
    stp  xzr, x9, [sp, #BR_NF]          // BR_NF = 0, BR_FCAP
    str  x19, [sp, #BR_PATH]
    ldrb w9, [x20, #IS_DELIM]
    str  x9, [sp, #BR_DELIM]
    str  xzr, [sp, #BR_NFIELDS]
    mov  x0, #(REC_INIT * REC_SIZE)
    bl   xmalloc
    mov  x22, x0
    mov  x23, #0
    mov  x24, #REC_INIT

    ldr  w9, [x20, #IS_HEADER]          // header: first record, resolve names
    cbz  w9, 10f
    mov  x0, sp
    bl   csv_record
    cbz  w0, 90f
    mov  x0, sp
    mov  x1, x20
    mov  w2, #1
    bl   resolve_columns

10: mov  x0, sp                         // ---- next data record
    bl   csv_record
    cbz  w0, 90f
    ldr  x9, [sp, #BR_NFIELDS]
    cbnz x9, 11f
    mov  x0, sp                         // no header: the first record decides
    mov  x1, x20
    mov  w2, #0
    bl   resolve_columns
11: ldr  x9, [sp, #BR_NFIELDS]
    ldr  x10, [sp, #BR_NF]
    cmp  x9, x10
    b.ne 80f
    cmp  x23, x24                       // room for one more REC
    b.lo 12f
    lsl  x24, x24, #1
    mov  x9, #REC_SIZE
    mul  x1, x24, x9
    mov  x0, x22
    bl   xrealloc
    mov  x22, x0
12: mov  x9, #REC_SIZE
    madd x25, x23, x9, x22
    ldr  x26, [sp, #BR_FLD]

    ldr  x9, [sp, #BR_IDX_DATE]         // date
    add  x9, x26, x9, lsl #4
    ldp  x0, x1, [x9]
    bl   trim_ws
    mov  x27, x0
    mov  x28, x1
    ldr  w2, [x20, #IS_DATE_FMT]
    bl   bank_parse_date
    cbz  x0, 81f
    str  x0, [x25, #REC_DATE]

    ldr  x9, [sp, #BR_IDX_DESC]         // description and merchant
    add  x9, x26, x9, lsl #4
    ldp  x0, x1, [x9]
    bl   trim_ws
    stp  x0, x1, [x25, #REC_DESC]
    bl   merchant_normalize
    stp  x0, x1, [x25, #REC_MERCH]

    ldr  w9, [x20, #IS_AMOUNT_MODE]     // amount
    cmp  w9, #AM_DEBIT_CREDIT
    b.eq 20f
    ldr  x9, [sp, #BR_IDX_A]
    add  x9, x26, x9, lsl #4
    ldp  x27, x28, [x9]
    mov  x0, x27
    mov  x1, x28
    mov  x2, x20
    bl   bank_parse_amount
    cbnz w1, 82f
    mov  x21, x0
    b    30f

20: ldr  x9, [sp, #BR_IDX_C]            // debit_credit: credit - debit
    add  x9, x26, x9, lsl #4
    ldp  x0, x1, [x9]
    bl   trim_ws
    stp  x0, x1, [sp, #BR_CR_PTR]
    ldr  x9, [sp, #BR_IDX_A]
    add  x9, x26, x9, lsl #4
    ldp  x0, x1, [x9]
    bl   trim_ws
    mov  x27, x0
    mov  x28, x1
    ldr  x9, [sp, #BR_CR_LEN]
    orr  x9, x9, x28
    cbz  x9, 83f                        // both empty
    mov  x21, #0
    cbz  x28, 21f                       // empty debit counts as 0
    mov  x0, x27
    mov  x1, x28
    mov  x2, x20
    bl   bank_parse_amount
    cbnz w1, 82f
    neg  x21, x0
21: ldp  x27, x28, [sp, #BR_CR_PTR]
    cbz  x28, 30f                       // empty credit counts as 0
    mov  x0, x27
    mov  x1, x28
    mov  x2, x20
    bl   bank_parse_amount
    cbnz w1, 82f
    add  x21, x21, x0

30: ldr  w9, [x20, #IS_INVERT]
    cmp  w9, #0
    cneg x21, x21, ne
    str  x21, [x25, #REC_AMOUNT]
    add  x23, x23, #1
    b    10b

80: ldr  x2, [sp, #BR_PATH]             // ---- record errors
    ldr  x3, [sp, #BR_RLINE]
    ldr  x4, [sp, #BR_NFIELDS]
    ldr  x5, [sp, #BR_NF]
    FAIL EX_IMPORT, "%s:%d: expected %d fields, found %d"
81: ldr  x2, [sp, #BR_PATH]
    ldr  x3, [sp, #BR_RLINE]
    mov  x4, x28
    mov  x5, x27
    FAIL EX_IMPORT, "%s:%d: invalid date '%.*s'"
82: ldr  x2, [sp, #BR_PATH]
    ldr  x3, [sp, #BR_RLINE]
    mov  x4, x28
    mov  x5, x27
    FAIL EX_IMPORT, "%s:%d: invalid amount '%.*s'"
83: ldr  x2, [sp, #BR_PATH]
    ldr  x3, [sp, #BR_RLINE]
    FAIL EX_IMPORT, "%s:%d: debit and credit are both empty"

90: ldr  x0, [sp, #BR_FLD]              // ---- end of input
    bl   free
    mov  x0, x22
    mov  x1, x23
    add  sp, sp, #BR_SIZE
    LEAVE 5
ENDF bank_read

// csv_record(x0 BR*) -> w0 1 record read / 0 end of input
//   x19 BR*, x20 pos, x21 end, x22 line, x23 field array, x24 field count,
//   x25 capacity, w26 delimiter, x27 field start / unescape write pointer,
//   x28 current field slot
LFUNC csv_record
    ENTER 5
    mov  x19, x0
    ldp  x20, x21, [x19, #BR_POS]
    ldr  x22, [x19, #BR_LINE]
    ldr  x23, [x19, #BR_FLD]
    ldr  x25, [x19, #BR_FCAP]
    ldrb w26, [x19, #BR_DELIM]

1:  cmp  x20, x21                       // skip empty lines ("\n", "\r\n")
    b.hs 90f
    ldrb w9, [x20]
    cmp  w9, #'\n'
    b.ne 2f
    add  x20, x20, #1
    add  x22, x22, #1
    b    1b
2:  cmp  w9, #'\r'
    b.ne 3f
    add  x10, x20, #1
    cmp  x10, x21
    b.hs 3f
    ldrb w10, [x10]
    cmp  w10, #'\n'
    b.ne 3f
    add  x20, x20, #2
    add  x22, x22, #1
    b    1b
3:  str  x22, [x19, #BR_RLINE]
    mov  x24, #0

10: cmp  x24, x25                       // ---- next field: make room
    b.lo 11f
    lsl  x25, x25, #1
    mov  x0, x23
    lsl  x1, x25, #4
    bl   xrealloc
    mov  x23, x0
11: add  x28, x23, x24, lsl #4
    add  x24, x24, #1
    cmp  x20, x21
    b.hs 20f
    ldrb w9, [x20]
    cmp  w9, #'"'
    b.eq 30f

20: mov  x27, x20                       // ---- unquoted field
21: cmp  x20, x21
    b.hs 25f
    ldrb w9, [x20]
    cmp  w9, w26
    b.eq 23f
    cmp  w9, #'\n'
    b.eq 24f
    add  x20, x20, #1
    b    21b
23: sub  x9, x20, x27                   // delimiter: another field follows
    stp  x27, x9, [x28]
    add  x20, x20, #1
    b    10b
24: sub  x9, x20, x27                   // newline: drop a '\r' before it
    cbz  x9, 26f
    ldurb w10, [x20, #-1]
    cmp  w10, #'\r'
    b.ne 26f
    sub  x9, x9, #1
26: stp  x27, x9, [x28]
    add  x20, x20, #1
    add  x22, x22, #1
    b    80f
25: sub  x9, x20, x27                   // end of input
    stp  x27, x9, [x28]
    b    80f

30: add  x20, x20, #1                   // ---- quoted field, unescaped in place
    mov  x27, x20
    str  x20, [x28]
31: cmp  x20, x21
    b.hs 70f
    ldrb w9, [x20], #1
    cmp  w9, #'"'
    b.eq 33f
    cmp  w9, #'\n'
    cinc x22, x22, eq
    strb w9, [x27], #1
    b    31b
33: cmp  x20, x21                       // '""' = literal quote
    b.hs 34f
    ldrb w9, [x20]
    cmp  w9, #'"'
    b.ne 34f
    add  x20, x20, #1
    strb w9, [x27], #1
    b    31b
34: ldr  x9, [x28]                      // closing quote
    sub  x9, x27, x9
    str  x9, [x28, #8]
    cmp  x20, x21
    b.hs 80f
    ldrb w9, [x20]
    cmp  w9, w26
    b.ne 35f
    add  x20, x20, #1
    b    10b
35: cmp  w9, #'\n'
    b.ne 36f
    add  x20, x20, #1
    add  x22, x22, #1
    b    80f
36: cmp  w9, #'\r'
    b.ne 71f
    add  x10, x20, #1
    cmp  x10, x21
    b.hs 71f
    ldrb w10, [x10]
    cmp  w10, #'\n'
    b.ne 71f
    add  x20, x20, #2
    add  x22, x22, #1
    b    80f

70: ldr  x2, [x19, #BR_PATH]
    ldr  x3, [x19, #BR_RLINE]
    FAIL EX_IMPORT, "%s:%d: unterminated quoted field"
71: ldr  x2, [x19, #BR_PATH]
    ldr  x3, [x19, #BR_RLINE]
    FAIL EX_IMPORT, "%s:%d: unexpected text after a closing quote"

80: stp  x20, x21, [x19, #BR_POS]       // record complete
    str  x22, [x19, #BR_LINE]
    stp  x23, x24, [x19, #BR_FLD]
    str  x25, [x19, #BR_FCAP]
    mov  w0, #1
    LEAVE 5
90: str  x20, [x19, #BR_POS]            // end of input
    str  x22, [x19, #BR_LINE]
    mov  w0, #0
    LEAVE 5
ENDF csv_record

// resolve_columns(x0 BR*, x1 IS*, w2 has_header): the current record (header
// or first record) fixes BR_NFIELDS and the BR_IDX_* column indexes
//   x19 BR*, x20 IS*, w21 has_header
LFUNC resolve_columns
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    mov  w21, w2
    ldr  x9, [x19, #BR_NF]
    str  x9, [x19, #BR_NFIELDS]
    ldr  x0, [x20, #IS_DATE_COL]
    mov  x1, x19
    mov  w2, w21
    bl   resolve_col
    str  x0, [x19, #BR_IDX_DATE]
    ldr  x0, [x20, #IS_DESC_COL]
    mov  x1, x19
    mov  w2, w21
    bl   resolve_col
    str  x0, [x19, #BR_IDX_DESC]
    ldr  w9, [x20, #IS_AMOUNT_MODE]
    cmp  w9, #AM_DEBIT_CREDIT
    b.eq 1f
    ldr  x0, [x20, #IS_AMOUNT_COL]
    mov  x1, x19
    mov  w2, w21
    bl   resolve_col
    str  x0, [x19, #BR_IDX_A]
    LEAVE 2
1:  ldr  x0, [x20, #IS_DEBIT_COL]
    mov  x1, x19
    mov  w2, w21
    bl   resolve_col
    str  x0, [x19, #BR_IDX_A]
    ldr  x0, [x20, #IS_CREDIT_COL]
    mov  x1, x19
    mov  w2, w21
    bl   resolve_col
    str  x0, [x19, #BR_IDX_C]
    LEAVE 2
ENDF resolve_columns

// resolve_col(x0 ref, x1 BR*, w2 has_header) -> x0 0-based column index
//   all decimal digits = 1-based position, else a header name (fields
//   trimmed, ASCII case-insensitive, first match)
//   x19 ref, x20 BR*, w21 has_header, x22 ref length, x23 index
LFUNC resolve_col
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    mov  w21, w2
    bl   strlen
    mov  x22, x0
    cbz  x22, 3f                        // "" is a (strange) name
    mov  x9, #0
1:  ldrb w10, [x19, x9]
    sub  w10, w10, #'0'
    cmp  w10, #9
    b.hi 3f
    add  x9, x9, #1
    cmp  x9, x22
    b.lo 1b
    mov  x0, x19                        // position
    mov  x1, x22
    bl   parse_u64
    cbnz w1, 2f
    cbz  x0, 2f
    ldr  x9, [x20, #BR_NFIELDS]
    cmp  x0, x9
    b.hi 2f
    sub  x0, x0, #1
    LEAVE 3
2:  ldr  x2, [x20, #BR_PATH]
    mov  x3, x19
    ldr  x4, [x20, #BR_NFIELDS]
    FAIL EX_IMPORT, "%s: column '%s' is out of range (records have %d fields)"

3:  cbz  w21, 8f                        // name
    mov  x23, #0
4:  ldr  x9, [x20, #BR_NFIELDS]
    cmp  x23, x9
    b.hs 9f
    ldr  x9, [x20, #BR_FLD]
    add  x9, x9, x23, lsl #4
    ldp  x0, x1, [x9]
    bl   trim_ws
    mov  x2, x19
    mov  x3, x22
    bl   ascii_ieq
    cbnz w0, 5f
    add  x23, x23, #1
    b    4b
5:  mov  x0, x23
    LEAVE 3
8:  ldr  x2, [x20, #BR_PATH]
    mov  x3, x19
    FAIL EX_IMPORT, "%s: column '%s' is a name but the file has no header"
9:  ldr  x2, [x20, #BR_PATH]
    mov  x3, x19
    FAIL EX_IMPORT, "%s: column '%s' not found in the header"
ENDF resolve_col

// ------------------------------------------------------------- dates ---------

// bank_parse_date(x0 ptr, x1 len, w2 DF_*) -> x0 YYYYMMDD or 0
//   x9 cursor, x10 end, x11 format row, x3/x4/x5 the three numbers,
//   w6 separator; then x0 year, x1 month, x2 day
FUNC bank_parse_date
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    cmp  w2, #DF_DMY_DOT
    b.hi 90f
    ADR_L x11, date_formats
    add  x11, x11, w2, uxtw #3
    mov  x9, x0
    add  x10, x0, x1
    ldrb w6, [x11, #6]
    ldrb w12, [x11, #0]                 // first number
    ldrb w13, [x11, #1]
    bl   pd_num
    cbz  w15, 90f
    mov  x3, x14
    cbz  w6, 1f
    cmp  x9, x10
    b.hs 90f
    ldrb w12, [x9], #1
    cmp  w12, w6
    b.ne 90f
1:  ldrb w12, [x11, #2]                 // second number
    ldrb w13, [x11, #3]
    bl   pd_num
    cbz  w15, 90f
    mov  x4, x14
    cbz  w6, 2f
    cmp  x9, x10
    b.hs 90f
    ldrb w12, [x9], #1
    cmp  w12, w6
    b.ne 90f
2:  ldrb w12, [x11, #4]                 // third number
    ldrb w13, [x11, #5]
    bl   pd_num
    cbz  w15, 90f
    mov  x5, x14
    cmp  x9, x10                        // nothing may follow
    b.ne 90f

    ldrb w7, [x11, #7]                  // order -> x0 year, x1 month, x2 day
    cbnz w7, 3f
    mov  x0, x3
    mov  x1, x4
    mov  x2, x5
    b    5f
3:  cmp  w7, #1
    b.ne 4f
    mov  x1, x3
    mov  x2, x4
    mov  x0, x5
    b    5f
4:  mov  x2, x3
    mov  x1, x4
    mov  x0, x5

5:  cbz  x0, 90f                        // year 0001..9999 (4 digits)
    sub  x7, x1, #1                     // month 1..12
    cmp  x7, #11
    b.hi 90f
    cbz  x2, 90f
    ADR_L x8, days_in_month
    ldrb w8, [x8, x7]
    cmp  x1, #2
    b.ne 7f
    tst  x0, #3                         // leap: /4 and (not /100 or /400)
    b.ne 7f
    mov  x12, #100
    udiv x13, x0, x12
    msub x13, x13, x12, x0
    cbnz x13, 6f
    mov  x12, #400
    udiv x13, x0, x12
    msub x13, x13, x12, x0
    cbnz x13, 7f
6:  add  w8, w8, #1
7:  cmp  x2, x8
    b.hi 90f
    mov  x12, #10000
    mov  x13, #100
    mul  x0, x0, x12
    madd x0, x1, x13, x0
    add  x0, x0, x2
    ldp  x29, x30, [sp], #16
    ret
90: mov  x0, #0
    ldp  x29, x30, [sp], #16
    ret
ENDF bank_parse_date

// pd_num: read min..max decimal digits at x9 (< x10)                 (leaf)
//   in: x9 cursor, x10 end, w12 min, w13 max
//   out: x14 value, w15 1 ok / 0 too few digits, x9 advanced; clobbers x7, x8
LFUNC pd_num
    mov  x14, #0
    mov  w15, #0
    mov  x7, #10
1:  cmp  w15, w13
    b.hs 2f
    cmp  x9, x10
    b.hs 2f
    ldrb w8, [x9]
    sub  w8, w8, #'0'
    cmp  w8, #9
    b.hi 2f
    add  x9, x9, #1
    madd x14, x14, x7, x8
    add  w15, w15, #1
    b    1b
2:  cmp  w15, w12
    cset w15, hs
    ret
ENDF pd_num

// ----------------------------------------------------------- amounts ---------

// bank_parse_amount(x0 ptr, x1 len, x2 IS*) -> x0 cents, w1 0 ok / 1 invalid
//   trim; "(...)" or leading '-' = negative, leading '+' dropped; currency
//   symbol removed once (prefix, else suffix); trim; thousands separators
//   skipped, decimal separator (or a remaining '.') = the point; then
//   [0-9]{1,16}(\.[0-9]{1,2})?
//   x19 IS*, w20 negative; scan: x0 cursor, x4 end, w2 thousands, w3 decimal,
//   x5 integer value, x6 integer digits, x7 fraction value, x8 fraction digits
//   (-1 = no point yet)
FUNC bank_parse_amount
    ENTER 1
    mov  x19, x2
    mov  w20, #0
    bl   trim_ws
    cbz  x1, 90f
    ldrb w9, [x0]
    cmp  w9, #'('
    b.ne 2f
    sub  x10, x1, #1
    ldrb w10, [x0, x10]
    cmp  w10, #')'
    b.ne 2f
    mov  w20, #1                        // (...)
    add  x0, x0, #1
    sub  x1, x1, #2
    b    4f
2:  cmp  w9, #'-'
    b.ne 3f
    mov  w20, #1
    add  x0, x0, #1
    sub  x1, x1, #1
    b    4f
3:  cmp  w9, #'+'
    b.ne 4f
    add  x0, x0, #1
    sub  x1, x1, #1

4:  ldr  x2, [x19, #IS_CURRENCY]        // currency symbol: prefix, else suffix
    cbz  x2, 6f
    mov  x3, #0
41: ldrb w9, [x2, x3]
    cbz  w9, 42f
    add  x3, x3, #1
    b    41b
42: cbz  x3, 6f
    cmp  x1, x3
    b.lo 6f
    mov  x4, #0
43: cmp  x4, x3
    b.hs 44f
    ldrb w9, [x0, x4]
    ldrb w10, [x2, x4]
    cmp  w9, w10
    b.ne 45f
    add  x4, x4, #1
    b    43b
44: add  x0, x0, x3
    sub  x1, x1, x3
    b    6f
45: sub  x5, x1, x3
    add  x5, x0, x5
    mov  x4, #0
46: cmp  x4, x3
    b.hs 47f
    ldrb w9, [x5, x4]
    ldrb w10, [x2, x4]
    cmp  w9, w10
    b.ne 6f
    add  x4, x4, #1
    b    46b
47: sub  x1, x1, x3

6:  bl   trim_ws
    ldrb w2, [x19, #IS_THOU_SEP]
    ldrb w3, [x19, #IS_DEC_SEP]
    add  x4, x0, x1
    mov  x5, #0
    mov  x6, #0
    mov  x7, #0
    mov  x8, #-1
    mov  x12, #10
7:  cmp  x0, x4
    b.hs 8f
    ldrb w9, [x0], #1
    cbz  w2, 71f
    cmp  w9, w2                         // thousands separator: removed
    b.eq 7b
71: cmp  w9, w3
    b.eq 72f
    cmp  w9, #'.'
    b.ne 73f
72: tbz  x8, #63, 90f                   // a second point
    mov  x8, #0
    b    7b
73: sub  w9, w9, #'0'
    cmp  w9, #9
    b.hi 90f
    tbz  x8, #63, 74f
    add  x6, x6, #1                     // integer digit (at most 16)
    cmp  x6, #16
    b.hi 90f
    madd x5, x5, x12, x9
    b    7b
74: add  x8, x8, #1                     // fraction digit (at most 2)
    cmp  x8, #2
    b.hi 90f
    madd x7, x7, x12, x9
    b    7b
8:  cbz  x6, 90f                        // at least one integer digit
    cbz  x8, 90f                        // a point needs a fraction digit
    cmp  x8, #1
    b.ne 81f
    mul  x7, x7, x12                    // ".5" = 50 cents
81: mov  x9, #100
    madd x0, x5, x9, x7
    cmp  w20, #0
    cneg x0, x0, ne
    mov  w1, #0
    LEAVE 1
90: mov  x0, #0
    mov  w1, #1
    LEAVE 1
ENDF bank_parse_amount

// --------------------------------------------------------- merchants ---------

// merchant_normalize(x0 ptr, x1 len) -> x0 new bytes (NUL-terminated), x1 len
//   x19 src, x20 len; copy loop: x0 out, x2 cursor, x3 end, x4 out length,
//   w5 space pending; token check: x5 last space, x6 cursor, x7 token left,
//   x9 minimum digits
FUNC merchant_normalize
    ENTER 1
    mov  x19, x0
    mov  x20, x1
    add  x0, x1, #1
    bl   xmalloc
    mov  x2, x19
    add  x3, x19, x20
    mov  x4, #0
    mov  w5, #0
1:  cmp  x2, x3                         // upper-case, collapse blanks
    b.hs 4f
    ldrb w6, [x2], #1
    cmp  w6, #' '
    ccmp w6, #'\t', #4, ne
    b.ne 2f
    cbz  x4, 1b                         // leading blanks vanish
    mov  w5, #1
    b    1b
2:  cbz  w5, 3f
    mov  w7, #' '
    strb w7, [x0, x4]
    add  x4, x4, #1
    mov  w5, #0
3:  sub  w7, w6, #'a'
    cmp  w7, #25
    b.hi 31f
    sub  w6, w6, #32
31: strb w6, [x0, x4]
    add  x4, x4, #1
    b    1b

4:  mov  x5, x4                         // last space-separated token
41: cbz  x5, 8f                         // no space: keep everything
    sub  x5, x5, #1
    ldrb w6, [x0, x5]
    cmp  w6, #' '
    b.ne 41b
    add  x6, x5, #1
    sub  x7, x4, x6
    mov  x9, #3                         // digits only: 3 or more
    ldrb w8, [x0, x6]
    cmp  w8, #'#'
    b.ne 42f
    add  x6, x6, #1                     // '#' + 1 or more digits
    sub  x7, x7, #1
    mov  x9, #1
42: cmp  x7, x9
    b.lo 8f
43: cbz  x7, 44f
    ldrb w8, [x0, x6]
    sub  w8, w8, #'0'
    cmp  w8, #9
    b.hi 8f
    add  x6, x6, #1
    sub  x7, x7, #1
    b    43b
44: mov  x4, x5                         // drop " token"
8:  strb wzr, [x0, x4]
    mov  x1, x4
    LEAVE 1
ENDF merchant_normalize

    NOTE_GNU_STACK
