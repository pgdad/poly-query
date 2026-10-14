// =============================================================================
// test_output.S — tests of app/output.S (render_result, spec/apps/pqledger.md
// §7). Results are built by hand (columns and values in .data); every case
// compares the exact bytes rendered for one format with the expected text.
// A large 100,000 x 8 result checks the rendered sizes of all three formats.
//
// Build and run from implementations/arm64-asm-engine:
//   gcc -Iinclude -Iapp -g -Wa,--fatal-warnings -o /tmp/test_output \
//       app/tests/test_output.S app/output.S app/util.S \
//       lib/libpolyquery.a -lm -lpthread && /tmp/test_output
// =============================================================================
#include "ledger.inc"

// ------------------------------------------------------------- builders -----

// COL name, type, precision, scale: one pq_column (type_name unused here)
.macro COL name, type, prec=0, scale=0
    .quad \name, 0
    .word \type, \prec, \scale, 0
.endm

// V_I type, v, aux: non-NULL BOOLEAN / INT64 / DATE / DECIMAL (aux = high
// 64 bits of a DECIMAL: -1 for negative values)
.macro V_I type, v, aux=0
    .quad \v, \aux
    .word 0, \type
.endm

// V_F v: non-NULL FLOAT64
.macro V_F v
    .double \v
    .quad 0
    .word 0, PQ_T_FLOAT64
.endm

// V_S lbl: non-NULL STRING with the bytes lbl .. lbl_e
.macro V_S lbl
    .quad \lbl, \lbl\()_e - \lbl
    .word 0, PQ_T_STRING
.endm

// V_NULL type: NULL value
.macro V_NULL type
    .quad 0, 0
    .word 1, \type
.endm

// RESULT lbl, ncols, nrows, columns, values: one pq_result
.macro RESULT lbl, ncols, nrows, cols, vals
    .p2align 3
\lbl: .quad \ncols, \nrows, \cols, \vals
.endm

// CASE "name", result, format, expected[, prefix]: one test case; `prefix`
// (a C string, 0 = none) is put into the buffer before rendering
#define CASE_NAME   0
#define CASE_RES    8
#define CASE_FMT    16
#define CASE_EXP    24
#define CASE_EXPLEN 32
#define CASE_PREFIX 40
#define CASE_SIZE   48
.macro CASE name, res, fmt, exp, prefix=0
    .quad .Lcase_name\@, \res, \fmt, \exp, \exp\()_e - \exp, \prefix
    .pushsection .rodata
.Lcase_name\@: .asciz "\name"
    .popsection
.endm

// ------------------------------------------------------- column names -------
    .section .rodata
n_month:    .asciz "month"
n_income:   .asciz "income"
n_expenses: .asciz "expenses"
n_net:      .asciz "net"
n_trans:    .asciz "transactions"
n_id:       .asciz "id"
n_name:     .asciz "name"
n_d:        .asciz "d"
n_label:    .asciz "label"
n_ok:       .asciz "ok"
n_n:        .asciz "n"
n_f:        .asciz "f"
n_ab:       .asciz "a,b"
n_key:      .asciz "k\"ey\\"
n_b:        .asciz "b"
n_x:        .asciz "x"
n_dt:       .asciz "dt"
n_amt:      .asciz "amt"
n_note:     .asciz "note"
n_col:      .asciz "col"
s_prefix:   .asciz "pre  "

// ------------------------------------------------------- string values ------
// Each STRING value: bytes between lbl and lbl_e, then a NUL.
v_aug:      .ascii "2026-08"
v_aug_e:    .byte 0
v_sep:      .ascii "2026-09"
v_sep_e:    .byte 0
v_uni:      .ascii "\303\234N\303\257C\303\266D\303\251 \342\234\223"  // ÜNïCöDé ✓
v_uni_e:    .byte 0
v_comma:    .ascii "Comma, Inc"
v_comma_e:  .byte 0
v_sayhi:    .ascii "Say \"hi\""
v_sayhi_e:  .byte 0
v_emptys:
v_emptys_e: .byte 0
v_lead:     .ascii " lead"
v_lead_e:   .byte 0
v_trail:    .ascii "trail "
v_trail_e:  .byte 0
v_lines:    .ascii "line1\nline2"
v_lines_e:  .byte 0
v_cr:       .ascii "cr\rx"
v_cr_e:     .byte 0
v_plain:    .ascii "plain"
v_plain_e:  .byte 0
v_ctl:      .ascii "tab\there\nnew \\ back \"q\" \001 ctl \037 \010\014\015"
v_ctl_e:    .byte 0
v_x:        .ascii "x"
v_x_e:      .byte 0

// ------------------------------------------------------------- results ------
    .data
    .p2align 3
// the example of spec §7
c_spec:
    COL n_month, PQ_T_STRING
    COL n_income, PQ_T_DECIMAL, 18, 2
    COL n_expenses, PQ_T_DECIMAL, 18, 2
    COL n_net, PQ_T_DECIMAL, 18, 2
    COL n_trans, PQ_T_INT64
r_spec_vals:
    V_S v_aug
    V_I PQ_T_DECIMAL, 10000
    V_I PQ_T_DECIMAL, 4510
    V_I PQ_T_DECIMAL, 5490
    V_I PQ_T_INT64, 3
    V_S v_sep
    V_I PQ_T_DECIMAL, 0
    V_I PQ_T_DECIMAL, 120000
    V_I PQ_T_DECIMAL, -120000, -1
    V_I PQ_T_INT64, 1
    RESULT r_spec, 5, 2, c_spec, r_spec_vals

// zero rows
c_empty:
    COL n_id, PQ_T_INT64
    COL n_name, PQ_T_STRING
    RESULT r_empty, 2, 0, c_empty, 0

// one row: DATE, unicode width, BOOLEAN, INT64 header narrower than its value,
// FLOAT64
c_one:
    COL n_d, PQ_T_DATE
    COL n_label, PQ_T_STRING
    COL n_ok, PQ_T_BOOLEAN
    COL n_n, PQ_T_INT64
    COL n_f, PQ_T_FLOAT64
r_one_vals:
    V_I PQ_T_DATE, 20697                // 2026-09-01
    V_S v_uni
    V_I PQ_T_BOOLEAN, 1
    V_I PQ_T_INT64, 12345
    V_F 1.5
    RESULT r_one, 5, 1, c_one, r_one_vals

// CSV quoting (also a header name that needs quoting)
c_quote:
    COL n_name, PQ_T_STRING
    COL n_ab, PQ_T_INT64
r_quote_vals:
    V_S v_comma
    V_I PQ_T_INT64, 1
    V_S v_sayhi
    V_I PQ_T_INT64, 2
    V_S v_emptys
    V_I PQ_T_INT64, 3
    V_NULL PQ_T_STRING
    V_I PQ_T_INT64, 4
    V_S v_lead
    V_I PQ_T_INT64, 5
    V_S v_trail
    V_NULL PQ_T_INT64
    V_S v_lines
    V_I PQ_T_INT64, 7
    V_S v_cr
    V_I PQ_T_INT64, 8
    V_S v_plain
    V_I PQ_T_INT64, 9
    RESULT r_quote, 2, 9, c_quote, r_quote_vals

// escapes, BOOLEAN, NULL, negative values
c_esc:
    COL n_key, PQ_T_STRING
    COL n_b, PQ_T_BOOLEAN
    COL n_n, PQ_T_INT64
    COL n_x, PQ_T_DECIMAL, 18, 2
    COL n_f, PQ_T_FLOAT64
    COL n_dt, PQ_T_DATE
r_esc_vals:
    V_S v_ctl
    V_I PQ_T_BOOLEAN, 1
    V_I PQ_T_INT64, -42
    V_I PQ_T_DECIMAL, -1250, -1
    V_F -2.25
    V_I PQ_T_DATE, 20484                // 2026-01-31
    V_NULL PQ_T_STRING
    V_NULL PQ_T_BOOLEAN
    V_NULL PQ_T_INT64
    V_NULL PQ_T_DECIMAL
    V_NULL PQ_T_FLOAT64
    V_NULL PQ_T_DATE
    V_S v_uni
    V_I PQ_T_BOOLEAN, 0
    V_I PQ_T_INT64, 0
    V_I PQ_T_DECIMAL, 5
    V_F 0.0
    V_I PQ_T_DATE, 0
    RESULT r_esc, 6, 3, c_esc, r_esc_vals

// alignment: INT64 header narrower than the values, negative DECIMALs,
// trailing NULL cells
c_align:
    COL n_n, PQ_T_INT64
    COL n_amt, PQ_T_DECIMAL, 18, 2
    COL n_note, PQ_T_STRING
r_align_vals:
    V_I PQ_T_INT64, 1234567
    V_I PQ_T_DECIMAL, -5, -1
    V_S v_x
    V_NULL PQ_T_INT64
    V_I PQ_T_DECIMAL, -123456, -1
    V_NULL PQ_T_STRING
    RESULT r_align, 3, 2, c_align, r_align_vals

// --------------------------------------------------------------- cases ------
    .p2align 3
cases:
    CASE "spec table", r_spec, OF_TABLE, x_spec_table
    CASE "spec csv", r_spec, OF_CSV, x_spec_csv
    CASE "spec json", r_spec, OF_JSON, x_spec_json
    CASE "empty table", r_empty, OF_TABLE, x_empty_table
    CASE "empty csv", r_empty, OF_CSV, x_empty_csv
    CASE "empty json", r_empty, OF_JSON, x_empty_json
    CASE "one table", r_one, OF_TABLE, x_one_table
    CASE "one csv", r_one, OF_CSV, x_one_csv
    CASE "one json", r_one, OF_JSON, x_one_json
    CASE "quote table", r_quote, OF_TABLE, x_quote_table
    CASE "quote csv", r_quote, OF_CSV, x_quote_csv
    CASE "quote json", r_quote, OF_JSON, x_quote_json
    CASE "esc table", r_esc, OF_TABLE, x_esc_table
    CASE "esc csv", r_esc, OF_CSV, x_esc_csv
    CASE "esc json", r_esc, OF_JSON, x_esc_json
    CASE "align table", r_align, OF_TABLE, x_align_table
    CASE "align csv", r_align, OF_CSV, x_align_csv
    CASE "align json", r_align, OF_JSON, x_align_json
    CASE "append table", r_empty, OF_TABLE, x_prefix, s_prefix
cases_end:

// ------------------------------------------------------ expected output -----
    .section .rodata
x_spec_table:
    .ascii "month    income  expenses       net  transactions\n"
    .ascii "-------  ------  --------  --------  ------------\n"
    .ascii "2026-08  100.00     45.10     54.90             3\n"
    .ascii "2026-09    0.00   1200.00  -1200.00             1\n"
    .ascii "(2 rows)\n"
x_spec_table_e:
x_spec_csv:
    .ascii "month,income,expenses,net,transactions\n"
    .ascii "2026-08,100.00,45.10,54.90,3\n"
    .ascii "2026-09,0.00,1200.00,-1200.00,1\n"
x_spec_csv_e:
x_spec_json:
    .ascii "{\"month\":\"2026-08\",\"income\":\"100.00\",\"expenses\":\"45.10\",\"net\":\"54.90\",\"transactions\":3}\n"
    .ascii "{\"month\":\"2026-09\",\"income\":\"0.00\",\"expenses\":\"1200.00\",\"net\":\"-1200.00\",\"transactions\":1}\n"
x_spec_json_e:

x_empty_table:
    .ascii "id  name\n"
    .ascii "--  ----\n"
    .ascii "(0 rows)\n"
x_empty_table_e:
x_empty_csv:
    .ascii "id,name\n"
x_empty_csv_e:
x_empty_json:                           // nothing at all
x_empty_json_e:

x_one_table:
    .ascii "d           label      ok        n         f\n"
    .ascii "----------  ---------  ----  -----  --------\n"
    .ascii "2026-09-01  \303\234N\303\257C\303\266D\303\251 \342\234\223  true  12345  1.500000\n"
    .ascii "(1 row)\n"
x_one_table_e:
x_one_csv:
    .ascii "d,label,ok,n,f\n"
    .ascii "2026-09-01,\303\234N\303\257C\303\266D\303\251 \342\234\223,true,12345,1.500000\n"
x_one_csv_e:
x_one_json:
    .ascii "{\"d\":\"2026-09-01\",\"label\":\"\303\234N\303\257C\303\266D\303\251 \342\234\223\",\"ok\":true,\"n\":12345,\"f\":1.500000}\n"
x_one_json_e:

x_quote_table:
    .ascii "name         a,b\n"
    .ascii "-----------  ---\n"
    .ascii "Comma, Inc     1\n"
    .ascii "Say \"hi\"       2\n"
    .ascii "               3\n"
    .ascii "               4\n"
    .ascii " lead          5\n"
    .ascii "trail\n"
    .ascii "line1\n"
    .ascii "line2    7\n"
    .ascii "cr\rx           8\n"
    .ascii "plain          9\n"
    .ascii "(9 rows)\n"
x_quote_table_e:
x_quote_csv:
    .ascii "name,\"a,b\"\n"
    .ascii "\"Comma, Inc\",1\n"
    .ascii "\"Say \"\"hi\"\"\",2\n"
    .ascii "\"\",3\n"
    .ascii ",4\n"
    .ascii "\" lead\",5\n"
    .ascii "\"trail \",\n"
    .ascii "\"line1\n"
    .ascii "line2\",7\n"
    .ascii "\"cr\rx\",8\n"
    .ascii "plain,9\n"
x_quote_csv_e:
x_quote_json:
    .ascii "{\"name\":\"Comma, Inc\",\"a,b\":1}\n"
    .ascii "{\"name\":\"Say \\\"hi\\\"\",\"a,b\":2}\n"
    .ascii "{\"name\":\"\",\"a,b\":3}\n"
    .ascii "{\"name\":null,\"a,b\":4}\n"
    .ascii "{\"name\":\" lead\",\"a,b\":5}\n"
    .ascii "{\"name\":\"trail \",\"a,b\":null}\n"
    .ascii "{\"name\":\"line1\\nline2\",\"a,b\":7}\n"
    .ascii "{\"name\":\"cr\\rx\",\"a,b\":8}\n"
    .ascii "{\"name\":\"plain\",\"a,b\":9}\n"
x_quote_json_e:

x_esc_table:
    .ascii "k\"ey\\                                b        n       x          f  dt\n"
    .ascii "-----------------------------------  -----  ---  ------  ---------  ----------\n"
    .ascii "tab\there\n"
    .ascii "new \\ back \"q\" \001 ctl \037 \010\014\015  true   -42  -12.50  -2.250000  2026-01-31\n"
    .ascii "\n"
    .ascii "\303\234N\303\257C\303\266D\303\251 \342\234\223                            false    0    0.05   0.000000  1970-01-01\n"
    .ascii "(3 rows)\n"
x_esc_table_e:
x_esc_csv:
    .ascii "\"k\"\"ey\\\",b,n,x,f,dt\n"
    .ascii "\"tab\there\n"
    .ascii "new \\ back \"\"q\"\" \001 ctl \037 \010\014\015\",true,-42,-12.50,-2.250000,2026-01-31\n"
    .ascii ",,,,,\n"
    .ascii "\303\234N\303\257C\303\266D\303\251 \342\234\223,false,0,0.05,0.000000,1970-01-01\n"
x_esc_csv_e:
x_esc_json:
    .ascii "{\"k\\\"ey\\\\\":\"tab\\there\\nnew \\\\ back \\\"q\\\" \\u0001 ctl \\u001f \\b\\f\\r\",\"b\":true,\"n\":-42,\"x\":\"-12.50\",\"f\":-2.250000,\"dt\":\"2026-01-31\"}\n"
    .ascii "{\"k\\\"ey\\\\\":null,\"b\":null,\"n\":null,\"x\":null,\"f\":null,\"dt\":null}\n"
    .ascii "{\"k\\\"ey\\\\\":\"\303\234N\303\257C\303\266D\303\251 \342\234\223\",\"b\":false,\"n\":0,\"x\":\"0.05\",\"f\":0.000000,\"dt\":\"1970-01-01\"}\n"
x_esc_json_e:

x_align_table:
    .ascii "      n       amt  note\n"
    .ascii "-------  --------  ----\n"
    .ascii "1234567     -0.05  x\n"
    .ascii "         -1234.56\n"
    .ascii "(2 rows)\n"
x_align_table_e:
x_align_csv:
    .ascii "n,amt,note\n"
    .ascii "1234567,-0.05,x\n"
    .ascii ",-1234.56,\n"
x_align_csv_e:
x_align_json:
    .ascii "{\"n\":1234567,\"amt\":\"-0.05\",\"note\":\"x\"}\n"
    .ascii "{\"n\":null,\"amt\":\"-1234.56\",\"note\":null}\n"
x_align_json_e:

x_prefix:                               // appended after existing bytes
    .ascii "pre  id  name\n"
    .ascii "--  ----\n"
    .ascii "(0 rows)\n"
x_prefix_e:

// ------------------------------------------------------- large result -------
// 100,000 rows x 8 INT64 columns named "col", every value 12345:
//   table  header, dashes and rows: 8 * 5 + 7 * 2 + 1 = 55 bytes each,
//          footer "(100000 rows)\n" = 14
//   csv    header 8 * 3 + 7 + 1 = 32, rows 8 * 5 + 7 + 1 = 48
//   json   rows 2 + 8 * 11 + 7 + 1 = 98 ("col":12345 is 11 bytes)
#define BIG_ROWS    100000
#define BIG_COLS    8
big_expect:
    .quad 55 * (BIG_ROWS + 2) + 14
    .quad 32 + 48 * BIG_ROWS
    .quad 98 * BIG_ROWS

s_fail:     .ascii "FAIL %s\n--- expected (%lu bytes):\n%.*s"
            .asciz "--- got (%lu bytes):\n%.*s---\n"
s_big_fail: .asciz "FAIL large result format %d: %lu bytes, expected %lu\n"
s_passed:   .asciz "test_output: %lu passed\n"
s_failed:   .asciz "test_output: %lu passed, %lu FAILED\n"

    .bss
    .p2align 3
big_res:    .skip PQR_SIZE

    .text

// check(x0 name, x1 expected, x2 expected len, x3 Buf*) -> x0 1 pass / 0 fail
//   x19 name, x20 expected, x21 expected len, x22 Buf*
LFUNC check
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x22, x3
    ldr  x9, [x22, #BUF_LEN]
    cmp  x9, x21
    b.ne 8f
    cbz  x21, 9f
    ldr  x0, [x22, #BUF_PTR]
    mov  x1, x20
    mov  x2, x21
    bl   memcmp
    cbz  w0, 9f
8:  ADR_L x0, s_fail
    mov  x1, x19
    mov  x2, x21
    mov  w3, w21
    mov  x4, x20
    ldr  x5, [x22, #BUF_LEN]
    mov  w6, w5
    ldr  x7, [x22, #BUF_PTR]
    bl   printf
    mov  x0, #0
    LEAVE 2
9:  mov  x0, #1
    LEAVE 2
ENDF check

// build_big(): fill big_res with the large result (see big_expect)
//   x19 columns, x20 values, x21 counter
LFUNC build_big
    ENTER 2
    mov  x0, #(BIG_COLS * PQC_SIZE)
    bl   xmalloc
    mov  x19, x0
    ADR_L x9, n_col
    mov  w10, #PQ_T_INT64
    mov  x11, x19
    mov  x21, #BIG_COLS
1:  stp  x9, xzr, [x11]             // name, type_name
    stp  w10, wzr, [x11, #PQC_TYPE] // type, precision
    stp  wzr, wzr, [x11, #PQC_SCALE]
    add  x11, x11, #PQC_SIZE
    subs x21, x21, #1
    b.ne 1b
    mov  x21, #((BIG_ROWS * BIG_COLS) & 0xffff)
    movk x21, #((BIG_ROWS * BIG_COLS) >> 16), lsl #16
    mov  x9, #PQV_SIZE
    mul  x0, x21, x9
    bl   xmalloc
    mov  x20, x0
    mov  x9, #12345
    mov  w10, #PQ_T_INT64
    mov  x11, x20
2:  stp  x9, xzr, [x11]             // v, aux
    stp  wzr, w10, [x11, #PQV_IS_NULL]
    add  x11, x11, #PQV_SIZE
    subs x21, x21, #1
    b.ne 2b
    ADR_L x0, big_res
    mov  x9, #BIG_COLS
    mov  x10, #(BIG_ROWS & 0xffff)
    movk x10, #(BIG_ROWS >> 16), lsl #16
    stp  x9, x10, [x0, #PQR_NCOLS]
    stp  x19, x20, [x0, #PQR_COLUMNS]
    LEAVE 2
ENDF build_big

// main: run the cases, then the large result
//   x19 case cursor, x20 cases end, x21 passed, x22 failed, x23 format,
//   x24 &big_expect; sp: Buf
FUNC main
    ENTER 3
    sub  sp, sp, #BUF_SIZE
    ADR_L x19, cases
    ADR_L x20, cases_end
    mov  x21, #0
    mov  x22, #0
1:  cmp  x19, x20
    b.hs 4f
    stp  xzr, xzr, [sp]
    stp  xzr, xzr, [sp, #16]
    ldr  x1, [x19, #CASE_PREFIX]
    cbz  x1, 2f
    mov  x0, sp
    bl   buf_puts
2:  ldr  x0, [x19, #CASE_RES]
    ldr  w1, [x19, #CASE_FMT]
    mov  x2, sp
    bl   render_result
    ldr  x0, [x19, #CASE_NAME]
    ldr  x1, [x19, #CASE_EXP]
    ldr  x2, [x19, #CASE_EXPLEN]
    mov  x3, sp
    bl   check
    add  x21, x21, x0
    eor  x0, x0, #1
    add  x22, x22, x0
    mov  x0, sp
    bl   buf_free
    add  x19, x19, #CASE_SIZE
    b    1b

    // large result: the three formats, sizes only
4:  bl   build_big
    ADR_L x24, big_expect
    mov  w23, #OF_TABLE
5:  stp  xzr, xzr, [sp]
    stp  xzr, xzr, [sp, #16]
    ADR_L x0, big_res
    mov  w1, w23
    mov  x2, sp
    bl   render_result
    ldr  x9, [sp, #BUF_LEN]
    ldr  x10, [x24, w23, uxtw #3]
    cmp  x9, x10
    b.eq 6f
    ADR_L x0, s_big_fail
    mov  w1, w23
    mov  x2, x9
    mov  x3, x10
    bl   printf
    add  x22, x22, #1
    b    7f
6:  add  x21, x21, #1
7:  mov  x0, sp
    bl   buf_free
    add  w23, w23, #1
    cmp  w23, #OF_JSON
    b.ls 5b

    mov  x1, x21
    cbnz x22, 8f
    ADR_L x0, s_passed
    bl   printf
    mov  w0, #0
    b    9f
8:  ADR_L x0, s_failed
    mov  x2, x22
    bl   printf
    mov  w0, #1
9:  add  sp, sp, #BUF_SIZE
    LEAVE 3
ENDF main

    NOTE_GNU_STACK
