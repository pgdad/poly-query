// =============================================================================
// test_ingest.S — unit tests for src/ingest.S (standalone program).
//
// Every case ingests an inline CSV / JSON / JSONL text and either
//   * renders the resulting table into a canonical text form and compares it
//     with the expected rendering, or
//   * expects ingest to raise a given error code (caught via setjmp on
//     g_jmpbuf, code read from g_err_code).
// Two generated performance cases (200k-row CSV, 100k-line JSONL) check
// linear-time behaviour and spot-check values.
//
// Rendering: first line "name:TYPE,name:TYPE", then one line per row with
// comma separated cells: NULL => ~, BOOLEAN true/false, INT64 / DATE (days) /
// TIMESTAMP (µs) / DECIMAL (unscaled) as signed integers, FLOAT64 with %.15g,
// STRING as 'raw text'.
//
// Prints one line per failure; exit status 0 only if every case passes.
// =============================================================================
#include "pq.inc"

// Test case record
#define TC_IN      0       // input ptr
#define TC_LEN     8       // input length
#define TC_FMT     16      // u32 FMT_*
#define TC_HDR     20      // u32 header flag
#define TC_DELIM   24      // u32 delimiter byte
#define TC_ERR     28      // u32 expected error code (0 = success)
#define TC_SCHEMA  32      // Schema* or 0
#define TC_EXP     40      // expected rendering (cstr) or 0
#define TC_MAXROWS 48      // row limit override (0 = keep default)
#define TC_NAME    56      // cstr test name
#define TC_SIZE    64

#define RBUF_SIZE  65536

// CASE in, fmt, hdr, delim, schema, err, exp [, maxrows]
// `in` is a label; `in_e` must mark the end of the input text.
.macro CASE in, fmt, hdr, delim, schema, err, exp, maxrows=0
    .quad \in, \in\()_e - \in
    .word \fmt, \hdr, \delim, \err
    .quad \schema, \exp, \maxrows
    .pushsection .rodata.names, "a"
8:  .asciz "\in"
    .popsection
    .quad 8b
.endm

// Static Str object: STRC label, "text"
.macro STRC label, text
    .p2align 3
\label: .quad 9f - 8f
8:  .ascii "\text"
9:  .byte 0
.endm

// Static Schema: SCHEMA label, n, names_label, types_label
.macro SCHEMA label, n, names, types
    .p2align 3
\label: .quad \n, \names, \types
.endm

// =============================================================================
//                                 test data
// =============================================================================
    .section .rodata

// ------------------------------------------------------------------ CSV ok ---
c_basic:  .ascii "id,name,score,ok,d\n1,Alice,1.5,true,2020-01-15\n2,,2,FALSE,\n"
c_basic_e:
x_basic:  .asciz "id:INT64,name:STRING,score:FLOAT64,ok:BOOLEAN,d:DATE\n1,'Alice',1.5,true,18276\n2,~,2,false,~\n"

c_quote:  .ascii "id,s\n1,\"a,b\"\n2,\"say \"\"hi\"\"\"\n3,\"\"\n4,\n5,\"multi\nline\"\n6,  sp  \n"
c_quote_e:
x_quote:  .asciz "id:INT64,s:STRING\n1,'a,b'\n2,'say \"hi\"'\n3,''\n4,~\n5,'multi\nline'\n6,'  sp  '\n"

c_crlf:   .ascii "\xEF\xBB\xBF" "a;b\r\n1;x\r\n\r\n2;y"
c_crlf_e:
x_crlf:   .asciz "a:INT64,b:STRING\n1,'x'\n2,'y'\n"

c_crlfq:  .ascii "a,b\r\n\"q\",\"r\"\r\n\"s\",t\r\n"
c_crlfq_e:
x_crlfq:  .asciz "a:STRING,b:STRING\n'q','r'\n's','t'\n"

c_tab:    .ascii "a\tb\n1\t2\n"
c_tab_e:
x_tab:    .asciz "a:INT64,b:INT64\n1,2\n"

c_emptyl: .ascii "\n\na\n\n1\n\n\n2\n\n"
c_emptyl_e:
x_emptyl: .asciz "a:INT64\n1\n2\n"

c_ovf:    .ascii "n\n9223372036854775808\n1\n"
c_ovf_e:
x_ovf:    .asciz "n:FLOAT64\n9.22337203685478e+18\n1\n"

c_minint: .ascii "n\n-9223372036854775808\n+7\n"
c_minint_e:
x_minint: .asciz "n:INT64\n-9223372036854775808\n7\n"

c_dates:  .ascii "d,t\n2024-02-29,2024-02-29\n2023-12-31,2023-12-31 23:59:59.5\n"
c_dates_e:
x_dates:  .asciz "d:DATE,t:TIMESTAMP\n19782,1709164800000000\n19722,1704067199500000\n"

c_baddt:  .ascii "v\n2023-02-29\n"
c_baddt_e:
x_baddt:  .asciz "v:STRING\n'2023-02-29'\n"

c_qempty: .ascii "n,s\n\"\",\"\"\n1,x\n"
c_qempty_e:
x_qempty: .asciz "n:INT64,s:STRING\n~,''\n1,'x'\n"

c_honly:  .ascii "a,b\n"
c_honly_e:
x_honly:  .asciz "a:STRING,b:STRING\n"

c_honly2: .ascii "a,b"
c_honly2_e:

c_ws:     .ascii "n,s\n 5 , x \n"
c_ws_e:
x_ws:     .asciz "n:INT64,s:STRING\n5,' x '\n"

c_allnull: .ascii "a,b\n1,\n2,\"\"\n"
c_allnull_e:
x_allnull: .asciz "a:INT64,b:STRING\n1,~\n2,''\n"

c_blank:  .ascii "a,b\n1, \n2,\n"
c_blank_e:
x_blank:  .asciz "a:INT64,b:STRING\n1,' '\n2,~\n"

c_blankint: .ascii "a,b\n1, \n2,3\n"
c_blankint_e:
x_blankint: .asciz "a:INT64,b:INT64\n1,~\n2,3\n"

c_mixnum: .ascii "v\n1\n2.5\n-.5e1\n"
c_mixnum_e:
x_mixnum: .asciz "v:FLOAT64\n1\n2.5\n-5\n"

c_boolint: .ascii "v\ntrue\n1\n"
c_boolint_e:
x_boolint: .asciz "v:STRING\n'true'\n'1'\n"

c_quotednum: .ascii "v,w\n\"12\",\" 3 \"\n"
c_quotednum_e:
x_quotednum: .asciz "v:INT64,w:INT64\n12,3\n"

c_lastempty: .ascii "a,b,c\n1,,\n"
c_lastempty_e:
x_lastempty: .asciz "a:INT64,b:STRING,c:STRING\n1,~,~\n"

c_qhdr:   .ascii "\"x \"\"y\"\"\",z\n1,2\n"
c_qhdr_e:
x_qhdr:   .asciz "x \"y\":INT64,z:INT64\n1,2\n"

c_cr_inner: .ascii "a,b\nx\ry,1\n"
c_cr_inner_e:
x_cr_inner: .asciz "a:STRING,b:INT64\n'x\ry',1\n"

c_utf8:   .ascii "s\n\xC3\x9Cn\xC3\xAFc\xC3\xB6d\xC3\xA9\n"
c_utf8_e:
x_utf8:   .asciz "s:STRING\n'\xC3\x9Cn\xC3\xAFc\xC3\xB6d\xC3\xA9'\n"

// ------------------------------------------------------- CSV with schema ---
c_sdec:   .ascii "id,amt\n1,10.25\n2,-0.5\n3,\n4, +7 \n"
c_sdec_e:
x_sdec:   .asciz "id:INT64,amt:DECIMAL(10,2)\n1,1025\n2,-50\n3,~\n4,700\n"

c_snohdr: .ascii "1,a\n2,b\n"
c_snohdr_e:
x_snohdr: .asciz "x:INT64,y:STRING\n1,'a'\n2,'b'\n"

c_sts:    .ascii "t\n2024-01-01\n2024-05-01T12:00:00\n"
c_sts_e:
x_sts:    .asciz "t:TIMESTAMP\n1704067200000000\n1714564800000000\n"

c_sstr:   .ascii "x\n 007 \n\"\"\n\n"
c_sstr_e:
x_sstr:   .asciz "x:STRING\n' 007 '\n''\n"

c_scase:  .ascii "ID,AMT\n1,0.5\n"
c_scase_e:
x_scase:  .asciz "id:INT64,amt:DECIMAL(10,2)\n1,50\n"

c_shonly: .ascii "id,amt\n"
c_shonly_e:
x_shonly: .asciz "id:INT64,amt:DECIMAL(10,2)\n"

c_sempty: .ascii ""
c_sempty_e:
x_sempty: .asciz "x:INT64,y:STRING\n"

c_sbool:  .ascii "b\nTRUE\nfalse\n\"\"\n"
c_sbool_e:
x_sbool:  .asciz "b:BOOLEAN\ntrue\nfalse\n~\n"

c_sfloat: .ascii "f\n1e3\n-2.5\n.5\n"
c_sfloat_e:
x_sfloat: .asciz "f:FLOAT64\n1000\n-2.5\n0.5\n"

// --------------------------------------------------------------- CSV errors ---
c_arity:  .ascii "a,b\n1,2\n3\n"
c_arity_e:
c_arity2: .ascii "a,b\n1,2,3\n"
c_arity2_e:
c_dup:    .ascii "a,A\n1,2\n"
c_dup_e:
c_emptyname: .ascii "a,,c\n1,2,3\n"
c_emptyname_e:
c_qemptyname: .ascii "a,\"\"\n1,2\n"
c_qemptyname_e:
c_unterm: .ascii "id,v\n1,\"abc\n"
c_unterm_e:
c_garbage: .ascii "a\n\"x\"y\n"
c_garbage_e:
c_noinput: .ascii ""
c_noinput_e:
c_onlynl: .ascii "\n\r\n\n"
c_onlynl_e:
c_dec3:   .ascii "v\n10.005\n"
c_dec3_e:
c_dec0:   .ascii "v\n1.500\n"
c_dec0_e:
c_decp:   .ascii "v\n123.4\n"
c_decp_e:
c_sovf:   .ascii "n\n9223372036854775808\n"
c_sovf_e:
c_snan:   .ascii "v\nNaN\n"
c_snan_e:
c_syes:   .ascii "v\nyes\n"
c_syes_e:
c_sbaddate: .ascii "v\n2023-02-29\n"
c_sbaddate_e:
c_shdrn:  .ascii "x,y\n1,2\n"
c_shdrn_e:
c_shdrname: .ascii "x,z\n1,2\n"
c_shdrname_e:
c_sqq:    .ascii "v\n\"1\"\"2\"\n"
c_sqq_e:
c_rows3:  .ascii "a\n1\n2\n3\n"
c_rows3_e:
x_rows3:  .asciz "a:INT64\n1\n2\n3\n"

// --------------------------------------------------------------- JSON ok ---
j_events: .ascii "[{\"id\":1,\"kind\":\"click\",\"ts\":\"2024-05-01T12:00:00\",\"v\":1.5,\"ok\":true},\n"
          .ascii " {\"id\":2,\"kind\":\"view\",\"ts\":\"2024-05-02\",\"v\":-2,\"ok\":null}]"
j_events_e:
x_events: .asciz "id:INT64,kind:STRING,ts:TIMESTAMP,v:FLOAT64,ok:BOOLEAN\n1,'click',1714564800000000,1.5,true\n2,'view',1714608000000000,-2,~\n"

j_sparse: .ascii "{\"a\": 1}\n{\"b\": \"x\", \"A\": 2}\n\n  {\"c\": true}  \r\n"
j_sparse_e:
x_sparse: .asciz "a:INT64,b:STRING,c:BOOLEAN\n1,~,~\n2,'x',~\n~,~,true\n"

j_misc:   .ascii "{\"n\":null,\"x\":1e3}\n{\"n\":null,\"x\":2}"
j_misc_e:
x_misc:   .asciz "n:STRING,x:FLOAT64\n~,1000\n~,2\n"

j_ovf:    .ascii "[{\"n\":9223372036854775808},{\"n\":1}]"
j_ovf_e:
x_ovf_j:  .asciz "n:FLOAT64\n9.22337203685478e+18\n1\n"

j_dates:  .ascii "[{\"d\":\"2024-01-01\"},{\"d\":\"2024-01-02\"},{\"d\":null}]"
j_dates_e:
x_dates_j: .asciz "d:DATE\n19723\n19724\n~\n"

j_baddate: .ascii "[{\"d\":\"2024-01-01\"},{\"d\":\"2023-02-29\"}]"
j_baddate_e:
x_baddate_j: .asciz "d:STRING\n'2024-01-01'\n'2023-02-29'\n"

j_empty:  .ascii " [ ] "
j_empty_e:
x_empty_j: .asciz "\n"

j_emptyl: .ascii "\n  \n"
j_emptyl_e:

j_money:  .ascii "[{\"id\": 1, \"amt\": 12.5, \"day\": \"2024-01-31\"}, {\"id\": 2, \"amt\": \"-0.125\", \"day\": null}, {\"ID\": 3, \"amt\": 7}]"
j_money_e:
x_money:  .asciz "id:INT64,amt:DECIMAL(8,3),day:DATE\n1,12500,19753\n2,-125,~\n3,7000,~\n"

j_sall:   .ascii "{\"b\":true,\"i\":\"42\",\"f\":3,\"s\":\"x\",\"t\":\"2024-01-01\"}"
j_sall_e:
x_sall:   .asciz "b:BOOLEAN,i:INT64,f:FLOAT64,s:STRING,t:TIMESTAMP\ntrue,42,3,'x',1704067200000000\n"

j_uni:    .ascii "{\"s\": \"caf\\u00e9 \\\"q\\\" \\\\ /\"}"
j_uni_e:
x_uni:    .asciz "s:STRING\n'caf\xC3\xA9 \"q\" \\ /'\n"

j_strempty: .ascii "{\"s\":\"\"}"
j_strempty_e:
x_strempty: .asciz "s:STRING\n''\n"

// ------------------------------------------------------------ JSON errors ---
j_mixed:  .ascii "[{\"a\":1},{\"a\":\"x\"}]"
j_mixed_e:
j_mixed2: .ascii "[{\"a\":true},{\"a\":0}]"
j_mixed2_e:
j_nested: .ascii "{\"a\":1}\n{\"a\":{\"nested\":true}}\n"
j_nested_e:
j_broken: .ascii "{\"a\":1,\n"
j_broken_e:
j_notarr: .ascii "{\"a\": 1}"
j_notarr_e:
j_elem:   .ascii "[{\"a\": 1}, 2]"
j_elem_e:
j_dupkey: .ascii "{\"a\": 1, \"a\": 2}"
j_dupkey_e:
j_dupci:  .ascii "{\"a\": 1, \"A\": 2}"
j_dupci_e:
j_nan:    .ascii "{\"a\": NaN}"
j_nan_e:
j_arrval: .ascii "{\"a\": [1, 2]}"
j_arrval_e:
j_unknown: .ascii "{\"a\": 1, \"b\": 2}"
j_unknown_e:
j_int15:  .ascii "{\"a\": 1.5}"
j_int15_e:
j_strbool: .ascii "{\"a\": \"true\"}"
j_strbool_e:
j_numstr: .ascii "{\"a\": 5}"
j_numstr_e:
j_boolint: .ascii "{\"a\": true}"
j_boolint_e:
j_trail:  .ascii "[{\"a\": 1},]"
j_trail_e:
j_linearr: .ascii "{\"a\":1}\n[1]\n"
j_linearr_e:
j_emptykey: .ascii "{\"\":1}"
j_emptykey_e:
j_garbage: .ascii "[{\"a\":1}] x"
j_garbage_e:
j_huge:   .ascii "{\"a\": 1e999}"
j_huge_e:

// ---------------------------------------------------------------- schemas ---
STRC n_x, "x"
STRC n_y, "y"
STRC n_v, "v"
STRC n_n, "n"
STRC n_t, "t"
STRC n_b, "b"
STRC n_f, "f"
STRC n_i, "i"
STRC n_s, "s"
STRC n_a, "a"
STRC n_id, "id"
STRC n_amt, "amt"
STRC n_day, "day"

    .p2align 3
nm_xy:    .quad n_x, n_y
ty_int_str: .word T_INT, T_STR
SCHEMA s_xy, 2, nm_xy, ty_int_str

nm_idamt: .quad n_id, n_amt
ty_iddec: .word T_INT, DEC_TYPE(10,2)
SCHEMA s_idamt, 2, nm_idamt, ty_iddec

nm_t:     .quad n_t
ty_ts:    .word T_TS
SCHEMA s_t, 1, nm_t, ty_ts

nm_x:     .quad n_x
ty_str:   .word T_STR
SCHEMA s_xstr, 1, nm_x, ty_str

nm_v:     .quad n_v
ty_dec102: .word DEC_TYPE(10,2)
SCHEMA s_vdec102, 1, nm_v, ty_dec102
ty_dec31: .word DEC_TYPE(3,1)
SCHEMA s_vdec31, 1, nm_v, ty_dec31
ty_float: .word T_FLOAT
SCHEMA s_vfloat, 1, nm_v, ty_float
ty_bool:  .word T_BOOL
SCHEMA s_vbool, 1, nm_v, ty_bool
ty_date:  .word T_DATE
SCHEMA s_vdate, 1, nm_v, ty_date
ty_int:   .word T_INT
SCHEMA s_vint, 1, nm_v, ty_int

nm_n:     .quad n_n
SCHEMA s_nint, 1, nm_n, ty_int

nm_b:     .quad n_b
SCHEMA s_bbool, 1, nm_b, ty_bool
nm_f:     .quad n_f
SCHEMA s_ffloat, 1, nm_f, ty_float

nm_a:     .quad n_a
SCHEMA s_aint, 1, nm_a, ty_int
SCHEMA s_abool, 1, nm_a, ty_bool
SCHEMA s_astr, 1, nm_a, ty_str
SCHEMA s_afloat, 1, nm_a, ty_float

nm_money: .quad n_id, n_amt, n_day
ty_money: .word T_INT, DEC_TYPE(8,3), T_DATE
SCHEMA s_money, 3, nm_money, ty_money

nm_sall:  .quad n_b, n_i, n_f, n_s, n_t
ty_sall:  .word T_BOOL, T_INT, T_FLOAT, T_STR, T_TS
SCHEMA s_sall, 5, nm_sall, ty_sall

// ------------------------------------------------------------- case table ---
    .p2align 3
cases:
    CASE c_basic,   FMT_CSV, 1, ',', 0, 0, x_basic
    CASE c_quote,   FMT_CSV, 1, ',', 0, 0, x_quote
    CASE c_crlf,    FMT_CSV, 1, ';', 0, 0, x_crlf
    CASE c_crlfq,   FMT_CSV, 1, ',', 0, 0, x_crlfq
    CASE c_tab,     FMT_CSV, 1, '\t', 0, 0, x_tab
    CASE c_emptyl,  FMT_CSV, 1, ',', 0, 0, x_emptyl
    CASE c_ovf,     FMT_CSV, 1, ',', 0, 0, x_ovf
    CASE c_minint,  FMT_CSV, 1, ',', 0, 0, x_minint
    CASE c_dates,   FMT_CSV, 1, ',', 0, 0, x_dates
    CASE c_baddt,   FMT_CSV, 1, ',', 0, 0, x_baddt
    CASE c_qempty,  FMT_CSV, 1, ',', 0, 0, x_qempty
    CASE c_honly,   FMT_CSV, 1, ',', 0, 0, x_honly
    CASE c_honly2,  FMT_CSV, 1, ',', 0, 0, x_honly
    CASE c_ws,      FMT_CSV, 1, ',', 0, 0, x_ws
    CASE c_allnull, FMT_CSV, 1, ',', 0, 0, x_allnull
    CASE c_blank,   FMT_CSV, 1, ',', 0, 0, x_blank
    CASE c_blankint, FMT_CSV, 1, ',', 0, 0, x_blankint
    CASE c_mixnum,  FMT_CSV, 1, ',', 0, 0, x_mixnum
    CASE c_boolint, FMT_CSV, 1, ',', 0, 0, x_boolint
    CASE c_quotednum, FMT_CSV, 1, ',', 0, 0, x_quotednum
    CASE c_lastempty, FMT_CSV, 1, ',', 0, 0, x_lastempty
    CASE c_qhdr,    FMT_CSV, 1, ',', 0, 0, x_qhdr
    CASE c_cr_inner, FMT_CSV, 1, ',', 0, 0, x_cr_inner
    CASE c_utf8,    FMT_CSV, 1, ',', 0, 0, x_utf8
    CASE c_sdec,    FMT_CSV, 1, ',', s_idamt, 0, x_sdec
    CASE c_snohdr,  FMT_CSV, 0, ',', s_xy, 0, x_snohdr
    CASE c_sts,     FMT_CSV, 1, ',', s_t, 0, x_sts
    CASE c_sstr,    FMT_CSV, 1, ',', s_xstr, 0, x_sstr
    CASE c_scase,   FMT_CSV, 1, ',', s_idamt, 0, x_scase
    CASE c_shonly,  FMT_CSV, 1, ',', s_idamt, 0, x_shonly
    CASE c_sempty,  FMT_CSV, 0, ',', s_xy, 0, x_sempty
    CASE c_sbool,   FMT_CSV, 1, ',', s_bbool, 0, x_sbool
    CASE c_sfloat,  FMT_CSV, 1, ',', s_ffloat, 0, x_sfloat
    CASE c_arity,   FMT_CSV, 1, ',', 0, ERR_INGEST, 0
    CASE c_arity2,  FMT_CSV, 1, ',', 0, ERR_INGEST, 0
    CASE c_dup,     FMT_CSV, 1, ',', 0, ERR_INGEST, 0
    CASE c_emptyname, FMT_CSV, 1, ',', 0, ERR_INGEST, 0
    CASE c_qemptyname, FMT_CSV, 1, ',', 0, ERR_INGEST, 0
    CASE c_unterm,  FMT_CSV, 1, ',', 0, ERR_INGEST, 0
    CASE c_garbage, FMT_CSV, 1, ',', 0, ERR_INGEST, 0
    CASE c_noinput, FMT_CSV, 1, ',', 0, ERR_INGEST, 0
    CASE c_onlynl,  FMT_CSV, 1, ',', 0, ERR_INGEST, 0
    CASE c_dec3,    FMT_CSV, 1, ',', s_vdec102, ERR_CONVERSION, 0
    CASE c_dec0,    FMT_CSV, 1, ',', s_vdec102, ERR_CONVERSION, 0
    CASE c_decp,    FMT_CSV, 1, ',', s_vdec31, ERR_CONVERSION, 0
    CASE c_sovf,    FMT_CSV, 1, ',', s_nint, ERR_CONVERSION, 0
    CASE c_snan,    FMT_CSV, 1, ',', s_vfloat, ERR_CONVERSION, 0
    CASE c_syes,    FMT_CSV, 1, ',', s_vbool, ERR_CONVERSION, 0
    CASE c_sbaddate, FMT_CSV, 1, ',', s_vdate, ERR_CONVERSION, 0
    CASE c_shdrn,   FMT_CSV, 1, ',', s_xstr, ERR_INGEST, 0
    CASE c_shdrname, FMT_CSV, 1, ',', s_xy, ERR_INGEST, 0
    CASE c_sqq,     FMT_CSV, 1, ',', s_vint, ERR_CONVERSION, 0
    CASE c_rows3,   FMT_CSV, 1, ',', 0, ERR_RESOURCE_LIMIT, 0, 2
    CASE c_rows3,   FMT_CSV, 1, ',', 0, 0, x_rows3, 3
    CASE j_events,  FMT_JSON, 0, 0, 0, 0, x_events
    CASE j_sparse,  FMT_JSONL, 0, 0, 0, 0, x_sparse
    CASE j_misc,    FMT_JSONL, 0, 0, 0, 0, x_misc
    CASE j_ovf,     FMT_JSON, 0, 0, 0, 0, x_ovf_j
    CASE j_dates,   FMT_JSON, 0, 0, 0, 0, x_dates_j
    CASE j_baddate, FMT_JSON, 0, 0, 0, 0, x_baddate_j
    CASE j_empty,   FMT_JSON, 0, 0, 0, 0, x_empty_j
    CASE j_emptyl,  FMT_JSONL, 0, 0, 0, 0, x_empty_j
    CASE j_money,   FMT_JSON, 0, 0, s_money, 0, x_money
    CASE j_sall,    FMT_JSONL, 0, 0, s_sall, 0, x_sall
    CASE j_uni,     FMT_JSONL, 0, 0, 0, 0, x_uni
    CASE j_strempty, FMT_JSONL, 0, 0, 0, 0, x_strempty
    CASE j_mixed,   FMT_JSON, 0, 0, 0, ERR_INGEST, 0
    CASE j_mixed2,  FMT_JSON, 0, 0, 0, ERR_INGEST, 0
    CASE j_nested,  FMT_JSONL, 0, 0, 0, ERR_INGEST, 0
    CASE j_broken,  FMT_JSONL, 0, 0, 0, ERR_INGEST, 0
    CASE j_notarr,  FMT_JSON, 0, 0, 0, ERR_INGEST, 0
    CASE j_elem,    FMT_JSON, 0, 0, 0, ERR_INGEST, 0
    CASE j_dupkey,  FMT_JSONL, 0, 0, 0, ERR_INGEST, 0
    CASE j_dupci,   FMT_JSONL, 0, 0, 0, ERR_INGEST, 0
    CASE j_nan,     FMT_JSONL, 0, 0, 0, ERR_INGEST, 0
    CASE j_arrval,  FMT_JSONL, 0, 0, 0, ERR_INGEST, 0
    CASE j_unknown, FMT_JSONL, 0, 0, s_aint, ERR_INGEST, 0
    CASE j_int15,   FMT_JSONL, 0, 0, s_aint, ERR_CONVERSION, 0
    CASE j_strbool, FMT_JSONL, 0, 0, s_abool, ERR_CONVERSION, 0
    CASE j_numstr,  FMT_JSONL, 0, 0, s_astr, ERR_CONVERSION, 0
    CASE j_boolint, FMT_JSONL, 0, 0, s_aint, ERR_CONVERSION, 0
    CASE j_trail,   FMT_JSON, 0, 0, 0, ERR_INGEST, 0
    CASE j_linearr, FMT_JSONL, 0, 0, 0, ERR_INGEST, 0
    CASE j_emptykey, FMT_JSONL, 0, 0, 0, ERR_INGEST, 0
    CASE j_garbage, FMT_JSON, 0, 0, 0, ERR_INGEST, 0
    CASE j_huge,    FMT_JSONL, 0, 0, 0, ERR_INGEST, 0
    CASE j_huge,    FMT_JSONL, 0, 0, s_afloat, ERR_CONVERSION, 0
cases_end:

// ------------------------------------------------------------------ strings ---
f_fail_ok:   .asciz "FAIL %s: expected error %u, ingest succeeded\n"
f_fail_err:  .asciz "FAIL %s: expected %s, got error %u (%s)\n"
f_fail_cmp:  .asciz "FAIL %s:\n--- expected\n%s--- got\n%s---\n"
s_success:   .asciz "success"
f_errcode:   .asciz "error %u"
f_summary:   .asciz "test_ingest: %lu/%lu passed\n"
f_name:      .asciz "%s:%s"
f_dec:       .asciz "DECIMAL(%u,%u)"
f_i64:       .asciz "%ld"
f_f64:       .asciz "%.15g"
f_str:       .asciz "'%s'"
s_comma:     .asciz ","
s_nl:        .asciz "\n"
s_null:      .asciz "~"
s_true:      .asciz "true"
s_false:     .asciz "false"
s_tbool:     .asciz "BOOLEAN"
s_tint:      .asciz "INT64"
s_tfloat:    .asciz "FLOAT64"
s_tstr:      .asciz "STRING"
s_tdate:     .asciz "DATE"
s_tts:       .asciz "TIMESTAMP"
s_tnull:     .asciz "NULL?"
    .p2align 3
tnames:      .quad s_tnull, s_tbool, s_tint, 0, s_tfloat, s_tstr, s_tdate, s_tts
// perf generation
f_pcsv_hdr:  .asciz "id,name,val,flag,day\n"
f_pcsv_row:  .asciz "%ld,name%ld,%ld.5,%s,2024-01-%02ld\n"
f_pjl_row:   .asciz "{\"id\":%ld,\"s\":\"x%ld\",\"f\":%ld.25,\"b\":%s,\"d\":\"2024-01-%02ld\"}\n"
f_perf:      .asciz "perf %s: %lu rows in %lu ms\n"
s_pcsv:      .asciz "csv"
s_pjl:       .asciz "jsonl"
x_pcsv:      .asciz "id:INT64,name:STRING,val:FLOAT64,flag:BOOLEAN,day:DATE\n"
x_pjl:       .asciz "id:INT64,s:STRING,f:FLOAT64,b:BOOLEAN,d:DATE\n"
f_pfail:     .asciz "FAIL perf %s: %s\n"
s_perr:      .asciz "ingest raised an error"
s_prows:     .asciz "wrong row count"
s_ptypes:    .asciz "wrong header/types"
s_pvals:     .asciz "wrong values"

// =============================================================================
//                                    state
// =============================================================================
    .bss
    .p2align 4
tbl:     .skip TBL_SIZE
rbuf:    .skip RBUF_SIZE
rcur:    .skip 8
saved_maxrows: .skip 8

    .text
// -----------------------------------------------------------------------------
// rprintf(x0 fmt, x1, x2, x3) — append formatted text to rbuf at rcur.
// -----------------------------------------------------------------------------
LFUNC rprintf
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    mov  x5, x3
    mov  x4, x2
    mov  x3, x1
    mov  x2, x0
    ADR_L x8, rcur
    ldr  x0, [x8]
    ADR_L x9, rbuf + RBUF_SIZE
    sub  x1, x9, x0
    bl   snprintf
    ADR_L x8, rcur
    ldr  x1, [x8]
    ADR_L x9, rbuf + RBUF_SIZE - 1
    sub  x2, x9, x1                 // room left (excluding NUL)
    sxtw x0, w0
    cmp  x0, x2
    csel x0, x0, x2, lt
    add  x1, x1, x0
    str  x1, [x8]
    ldp  x29, x30, [sp], #16
    ret
ENDF rprintf

// -----------------------------------------------------------------------------
// render(x0 Table*, x1 max rows to render) -> x0 rbuf (NUL terminated)
// Registers: x20 Table*, x21 Column*, x22 ncols, x23 row, x24 col,
//            x25 current Column*, x26 type, x27 rows to render.
// -----------------------------------------------------------------------------
LFUNC render
    stp  x29, x30, [sp, #-80]!
    mov  x29, sp
    stp  x20, x21, [sp, #16]
    stp  x22, x23, [sp, #32]
    stp  x24, x25, [sp, #48]
    stp  x26, x27, [sp, #64]
    mov  x20, x0
    ldr  x27, [x20, #TBL_NROWS]
    cmp  x1, x27
    csel x27, x1, x27, lo
    ADR_L x8, rcur
    ADR_L x9, rbuf
    str  x9, [x8]
    strb wzr, [x9]
    ldr  x21, [x20, #TBL_COLS]
    ldr  x22, [x20, #TBL_NCOLS]
    // header line
    mov  x24, #0
1:  cmp  x24, x22
    b.hs 4f
    cbz  x24, 2f
    ADR_L x0, s_comma
    bl   rprintf
2:  add  x25, x21, x24, lsl #5
    ldr  x1, [x25, #COL_NAME]
    add  x1, x1, #STR_DATA
    ADR_L x0, f_name
    ldr  w26, [x25, #COL_TYPE]
    and  w9, w26, #T_KIND_MASK
    cmp  w9, #T_DEC
    b.eq 3f
    cmp  w9, #T_TS
    b.hi 21f
    ADR_L x10, tnames
    ldr  x2, [x10, x9, lsl #3]
    bl   rprintf
    b    35f
21: ADR_L x2, s_tnull
    bl   rprintf
    b    35f
3:  ADR_L x0, f_namecolon           // "name:" then DECIMAL(p,s)
    bl   rprintf
    ADR_L x0, f_dec
    ubfx w1, w26, #T_PREC_SHIFT, #8
    ubfx w2, w26, #T_SCALE_SHIFT, #8
    bl   rprintf
35: add  x24, x24, #1
    b    1b
4:  ADR_L x0, s_nl
    bl   rprintf
    // rows
    mov  x23, #0
5:  cmp  x23, x27
    b.hs 9f
    mov  x24, #0
6:  cmp  x24, x22
    b.hs 8f
    cbz  x24, 61f
    ADR_L x0, s_comma
    bl   rprintf
61: add  x25, x21, x24, lsl #5
    ldr  x9, [x25, #COL_NULLS]
    NULLBIT_TEST 9, 9, 23, 10
    cbz  w9, 62f
    ADR_L x0, s_null
    bl   rprintf
    b    7f
62: ldr  x9, [x25, #COL_DATA]
    ldr  x1, [x9, x23, lsl #3]
    ldr  w26, [x25, #COL_TYPE]
    and  w26, w26, #T_KIND_MASK
    cmp  w26, #T_BOOL
    b.eq 63f
    cmp  w26, #T_FLOAT
    b.eq 64f
    cmp  w26, #T_STR
    b.eq 65f
    ADR_L x0, f_i64                 // INT / DEC / DATE / TS
    bl   rprintf
    b    7f
63: ADR_L x0, s_true
    cbnz x1, 631f
    ADR_L x0, s_false
631: bl  rprintf
    b    7f
64: fmov d0, x1                     // snprintf takes the double in d0
    ADR_L x8, rcur
    ldr  x0, [x8]
    ADR_L x9, rbuf + RBUF_SIZE
    sub  x1, x9, x0
    ADR_L x2, f_f64
    bl   snprintf
    ADR_L x8, rcur
    ldr  x1, [x8]
    sxtw x0, w0
    add  x1, x1, x0
    str  x1, [x8]
    b    7f
65: add  x1, x1, #STR_DATA
    ADR_L x0, f_str
    bl   rprintf
7:  add  x24, x24, #1
    b    6b
8:  ADR_L x0, s_nl
    bl   rprintf
    add  x23, x23, #1
    b    5b
9:  ADR_L x0, rbuf
    ldp  x20, x21, [sp, #16]
    ldp  x22, x23, [sp, #32]
    ldp  x24, x25, [sp, #48]
    ldp  x26, x27, [sp, #64]
    ldp  x29, x30, [sp], #80
    ret
ENDF render

    .section .rodata
f_namecolon: .asciz "%s:"
    .text

// -----------------------------------------------------------------------------
// reset_state: free the table arena and the request arena, zero the table.
// -----------------------------------------------------------------------------
LFUNC reset_state
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    ADR_L x0, tbl + TBL_ARENA
    bl   arena_free
    ADR_L x0, g_arena
    bl   arena_free
    ADR_L x0, tbl
    mov  w1, #0
    mov  x2, #TBL_SIZE
    bl   memset
    ldp  x29, x30, [sp], #16
    ret
ENDF reset_state

// -----------------------------------------------------------------------------
// run_case(x0 case*) -> w0 1 pass / 0 fail
// Registers: x20 case, x21 saved g_max_table_rows.
// -----------------------------------------------------------------------------
LFUNC run_case
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x20, x21, [sp, #16]
    str  x22, [sp, #32]
    mov  x20, x0
    bl   reset_state
    LDR_G x21, g_max_table_rows
    ldr  x0, [x20, #TC_MAXROWS]
    cbz  x0, 1f
    ADR_L x1, g_max_table_rows
    str  x0, [x1]
1:  ADR_L x0, g_jmpbuf
    bl   setjmp
    cbnz w0, .Lrc_raised
    ADR_L x0, tbl
    ldr  x1, [x20, #TC_IN]
    ldr  x2, [x20, #TC_LEN]
    ldr  w3, [x20, #TC_FMT]
    ldr  x4, [x20, #TC_SCHEMA]
    ldr  w5, [x20, #TC_HDR]
    ldr  w6, [x20, #TC_DELIM]
    bl   ingest
    ldr  w2, [x20, #TC_ERR]
    cbz  w2, 2f
    ADR_L x0, f_fail_ok
    ldr  x1, [x20, #TC_NAME]
    bl   printf
    b    .Lrc_fail
2:  ADR_L x0, tbl
    mov  x1, #-1
    bl   render
    mov  x22, x0
    ldr  x1, [x20, #TC_EXP]
    bl   strcmp
    cbz  w0, .Lrc_pass
    ADR_L x0, f_fail_cmp
    ldr  x1, [x20, #TC_NAME]
    ldr  x2, [x20, #TC_EXP]
    mov  x3, x22
    bl   printf
    b    .Lrc_fail
.Lrc_raised:
    ADR_L x9, g_err_code
    ldr  w9, [x9]
    ldr  w10, [x20, #TC_ERR]
    cmp  w9, w10
    b.eq .Lrc_pass
    // describe the expectation
    sub  sp, sp, #64
    ADR_L x1, s_success
    cbz  w10, 3f
    mov  x0, sp
    mov  x1, #64
    ADR_L x2, f_errcode
    mov  w3, w10
    bl   snprintf
    mov  x1, sp
3:  mov  x2, x1
    ldr  x1, [x20, #TC_NAME]
    ADR_L x9, g_err_code
    ldr  w3, [x9]
    ADR_L x4, g_err_msg
    ADR_L x0, f_fail_err
    bl   printf
    add  sp, sp, #64
.Lrc_fail:
    mov  w22, #0
    b    4f
.Lrc_pass:
    mov  w22, #1
4:  ADR_L x1, g_max_table_rows
    str  x21, [x1]
    bl   reset_state
    mov  w0, w22
    ldp  x20, x21, [sp, #16]
    ldr  x22, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
ENDF run_case

// -----------------------------------------------------------------------------
// perf_case(w0 format) -> w0 1 pass / 0 fail
// Generates N rows (CSV: 200000 with header; JSONL: 100000 lines), ingests
// them, checks row count / names / types and spot-checks row 12345.
// Registers: x20 buffer, x21 cursor, x22 i, x23 N, w24 format,
//            x25 start time, x26 label.
// -----------------------------------------------------------------------------
LFUNC perf_case
    stp  x29, x30, [sp, #-80]!
    mov  x29, sp
    stp  x20, x21, [sp, #16]
    stp  x22, x23, [sp, #32]
    stp  x24, x25, [sp, #48]
    str  x26, [sp, #64]
    mov  w24, w0
    bl   reset_state
    ldr  x23, =200000
    ADR_L x26, s_pcsv
    cmp  w24, #FMT_CSV
    b.eq 1f
    ldr  x23, =100000
    ADR_L x26, s_pjl
1:  mov  x0, #128
    mul  x0, x0, x23
    bl   malloc
    mov  x20, x0
    mov  x21, x0
    cmp  w24, #FMT_CSV
    b.ne 2f
    mov  x0, x21
    ADR_L x1, f_pcsv_hdr
    bl   strcpy
    mov  x0, x21
    bl   strlen
    add  x21, x21, x0
2:  mov  x22, #0
3:  cmp  x22, x23
    b.hs 4f
    mov  x0, x21
    mov  x1, #128
    ADR_L x2, f_pcsv_row
    cmp  w24, #FMT_CSV
    b.eq 31f
    ADR_L x2, f_pjl_row
31: mov  x3, x22
    mov  x4, x22
    mov  x5, x22
    ADR_L x6, s_true
    tst  x22, #1
    b.eq 32f
    ADR_L x6, s_false
32: mov  x9, #28
    udiv x10, x22, x9
    msub x7, x10, x9, x22
    add  x7, x7, #1
    bl   snprintf
    sxtw x0, w0
    add  x21, x21, x0
    add  x22, x22, #1
    b    3b
4:  bl   now_us
    mov  x25, x0
    ADR_L x0, g_jmpbuf
    bl   setjmp
    cbnz w0, .Lpf_err
    ADR_L x0, tbl
    mov  x1, x20
    sub  x2, x21, x20
    mov  w3, w24
    mov  x4, #0
    mov  w5, #1
    mov  w6, #','
    bl   ingest
    bl   now_us
    sub  x9, x0, x25
    mov  x10, #1000
    udiv x3, x9, x10
    ADR_L x0, f_perf
    mov  x1, x26
    ADR_L x9, tbl
    ldr  x2, [x9, #TBL_NROWS]
    bl   printf
    ADR_L x9, tbl
    ldr  x9, [x9, #TBL_NROWS]
    cmp  x9, x23
    b.ne .Lpf_rows
    ADR_L x0, tbl
    mov  x1, #0
    bl   render
    ADR_L x1, x_pcsv
    cmp  w24, #FMT_CSV
    b.eq 5f
    ADR_L x1, x_pjl
5:  bl   strcmp
    cbnz w0, .Lpf_types
    // spot check row 12345: id 12345, name "name12345"/"x12345",
    // val 12345.5 / 12345.25, flag false (odd), day 2024-01-(12345%28+1)
    ADR_L x9, tbl
    ldr  x9, [x9, #TBL_COLS]
    mov  x10, #12345
    ldr  x11, [x9, #COL_DATA]
    ldr  x11, [x11, x10, lsl #3]
    cmp  x11, x10
    b.ne .Lpf_vals
    ldr  x11, [x9, #(2*COL_SIZE + COL_DATA)]
    ldr  d0, [x11, x10, lsl #3]
    ldr  x12, =0x40C81CC000000000   // 12345.5
    cmp  w24, #FMT_CSV
    b.eq 6f
    ldr  x12, =0x40C81CA000000000   // 12345.25
6:  fmov x13, d0
    cmp  x13, x12
    b.ne .Lpf_vals
    ldr  x11, [x9, #(3*COL_SIZE + COL_DATA)]
    ldr  x11, [x11, x10, lsl #3]
    cbnz x11, .Lpf_vals
    ldr  x11, [x9, #(4*COL_SIZE + COL_DATA)]
    ldr  x11, [x11, x10, lsl #3]
    mov  x12, #(19722 + 12345 % 28 + 1)
    cmp  x11, x12
    b.ne .Lpf_vals
    ldr  x11, [x9, #(1*COL_SIZE + COL_DATA)]
    ldr  x11, [x11, x10, lsl #3]
    ldr  x12, [x11, #STR_LEN]
    cmp  w24, #FMT_CSV
    mov  x13, #9                    // "name12345"
    mov  x14, #6                    // "x12345"
    csel x13, x13, x14, eq
    cmp  x12, x13
    b.ne .Lpf_vals
    mov  w22, #1
    b    .Lpf_out
.Lpf_err:
    ADR_L x2, s_perr
    b    .Lpf_report
.Lpf_rows:
    ADR_L x2, s_prows
    b    .Lpf_report
.Lpf_types:
    ADR_L x2, s_ptypes
    b    .Lpf_report
.Lpf_vals:
    ADR_L x2, s_pvals
.Lpf_report:
    ADR_L x0, f_pfail
    mov  x1, x26
    bl   printf
    mov  w22, #0
.Lpf_out:
    mov  x0, x20
    bl   free
    bl   reset_state
    mov  w0, w22
    ldp  x20, x21, [sp, #16]
    ldp  x22, x23, [sp, #32]
    ldp  x24, x25, [sp, #48]
    ldr  x26, [sp, #64]
    ldp  x29, x30, [sp], #80
    ret
    .ltorg
ENDF perf_case

// -----------------------------------------------------------------------------
// dump_file(x0 argv, w1 argc) -> w0 exit status
// Developer aid: `test_ingest FILE csv|json|jsonl [delimiter]` ingests a file
// (CSV with header, schema inferred) and prints the first 20 rendered rows.
// Registers: x20 argv, w21 argc, x22 buffer, x23 length, w24 format,
//            x25 FILE*.
// -----------------------------------------------------------------------------
LFUNC dump_file
    stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    stp  x20, x21, [sp, #16]
    stp  x22, x23, [sp, #32]
    stp  x24, x25, [sp, #48]
    mov  x20, x0
    mov  w21, w1
    ldr  x0, [x20, #8]
    ADR_L x1, s_rb
    bl   fopen
    cbz  x0, .Ldf_ioerr
    mov  x25, x0
    mov  x1, #0
    mov  w2, #2                     // SEEK_END
    bl   fseek
    mov  x0, x25
    bl   ftell
    mov  x23, x0
    mov  x0, x25
    bl   rewind
    add  x0, x23, #1
    bl   malloc
    mov  x22, x0
    mov  x1, #1
    mov  x2, x23
    mov  x3, x25
    bl   fread
    mov  x0, x25
    bl   fclose
    mov  w24, #FMT_CSV
    ldr  x0, [x20, #16]
    ADR_L x1, s_json
    bl   strcmp
    cbnz w0, 1f
    mov  w24, #FMT_JSON
1:  ldr  x0, [x20, #16]
    ADR_L x1, s_pjl
    bl   strcmp
    cbnz w0, 2f
    mov  w24, #FMT_JSONL
2:  bl   reset_state
    ADR_L x0, g_jmpbuf
    bl   setjmp
    cbnz w0, .Ldf_raised
    mov  w6, #','
    cmp  w21, #4
    b.lt 3f
    ldr  x9, [x20, #24]
    ldrb w6, [x9]
3:  ADR_L x0, tbl
    mov  x1, x22
    mov  x2, x23
    mov  w3, w24
    mov  x4, #0
    mov  w5, #1
    bl   ingest
    ADR_L x0, tbl
    mov  x1, #20
    bl   render
    mov  x1, x0
    ADR_L x0, f_s
    bl   printf
    ADR_L x9, tbl
    ldr  x1, [x9, #TBL_NROWS]
    ADR_L x0, f_rows
    bl   printf
    mov  w0, #0
    b    .Ldf_out
.Ldf_raised:
    ADR_L x9, g_err_code
    ldr  w1, [x9]
    ADR_L x2, g_err_msg
    ADR_L x0, f_dferr
    bl   printf
    mov  w0, #1
    b    .Ldf_out
.Ldf_ioerr:
    ldr  x0, [x20, #8]
    bl   perror
    mov  w0, #2
.Ldf_out:
    ldp  x20, x21, [sp, #16]
    ldp  x22, x23, [sp, #32]
    ldp  x24, x25, [sp, #48]
    ldp  x29, x30, [sp], #64
    ret
ENDF dump_file

    .section .rodata
s_rb:    .asciz "rb"
s_json:  .asciz "json"
f_s:     .asciz "%s"
f_rows:  .asciz "rows: %lu\n"
f_dferr: .asciz "error %u: %s\n"
    .text

// -----------------------------------------------------------------------------
// main: run every case, print a summary, exit 0 iff all passed.
// With arguments, runs dump_file instead (see above).
// Registers: x19 case cursor, x20 end, x21 passed, x22 total.
// -----------------------------------------------------------------------------
FUNC main
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    cmp  w0, #3
    b.lt 0f
    mov  x9, x1
    mov  w1, w0
    mov  x0, x9
    bl   dump_file
    b    3f
0:  ADR_L x19, cases
    ADR_L x20, cases_end
    mov  x21, #0
    mov  x22, #0
1:  cmp  x19, x20
    b.hs 2f
    mov  x0, x19
    bl   run_case
    add  x21, x21, x0
    add  x22, x22, #1
    add  x19, x19, #TC_SIZE
    b    1b
2:  mov  w0, #FMT_CSV
    bl   perf_case
    add  x21, x21, x0
    add  x22, x22, #1
    mov  w0, #FMT_JSONL
    bl   perf_case
    add  x21, x21, x0
    add  x22, x22, #1
    ADR_L x0, f_summary
    mov  x1, x21
    mov  x2, x22
    bl   printf
    cmp  x21, x22
    cset w0, ne
3:  ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
ENDF main

    NOTE_GNU_STACK
