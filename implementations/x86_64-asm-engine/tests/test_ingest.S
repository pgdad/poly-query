/*
 * test_ingest.S - unit tests for ingest_csv / ingest_json (src/ingest.S).
 * Prints "FAIL: ..." lines for failures and "test_ingest: N passed" at the
 * end; exit status is non-zero if anything failed.
 */
#include "pq.inc"

    .section .note.GNU-stack, "", @progbits

    .bss
    .p2align 4
jbuf:       .zero 256
npass:      .quad 0
nfail:      .quad 0
last_pend:  .quad 0
bigbuf:     .quad 0

    .data
    .p2align 3
tname:      .quad 1
            .asciz "t"

/* ---------------------------------------------------------------- macros */

/* PSTR label, "text": static pstr */
.macro PSTR lbl, s
    .p2align 3
\lbl:
    .quad 7771f - 7770f
7770:
    .ascii "\s"
7771:
    .byte 0
.endm

.macro CSV d, hdr, delim, sch
    lea \d(%rip), %rdi
    lea \d\()_e(%rip), %rsi
    mov $\hdr, %edx
    mov $\delim, %ecx
    mov $\sch, %r8
    call try_csv
    mov %rax, %r12
.endm

.macro JSN d, lines, sch
    lea \d(%rip), %rdi
    lea \d\()_e(%rip), %rsi
    mov $\lines, %edx
    mov $\sch, %rcx
    call try_json
    mov %rax, %r12
.endm

.macro OK nm
    mov %r12, %rdi
    CSTR %rsi, "\nm"
    call chk_ok
.endm

.macro ERR code, nm
    mov %r12, %rdi
    mov $\code, %esi
    CSTR %rdx, "\nm"
    call chk_err
.endm

.macro MSG sub, nm
    CSTR %rdi, "\sub"
    CSTR %rsi, "\nm"
    call chk_msg
.endm

.macro SHAPE nc, nr, nm
    mov %r12, %rdi
    mov $\nc, %esi
    mov $\nr, %edx
    CSTR %rcx, "\nm"
    call chk_shape
.endm

.macro COL ci, cname, type, nm
    mov %r12, %rdi
    mov $\ci, %esi
    CSTR %rdx, "\cname"
    mov $\type, %ecx
    CSTR %r8, "\nm"
    call chk_col
.endm

.macro VAL ci, row, src, nm
    mov %r12, %rdi
    mov $\ci, %esi
    mov $\row, %edx
    mov \src, %rcx
    CSTR %r8, "\nm"
    call chk_val
.endm

.macro NUL ci, row, nm
    mov %r12, %rdi
    mov $\ci, %esi
    mov $\row, %edx
    CSTR %rcx, "\nm"
    call chk_null
.endm

.macro STR ci, row, s, nm
    mov %r12, %rdi
    mov $\ci, %esi
    mov $\row, %edx
    CSTR %rcx, "\s"
    CSTR %r8, "\nm"
    call chk_str
.endm

/* STRL: expected string given by a label (for texts with quotes) */
.macro STRL ci, row, lbl, nm
    mov %r12, %rdi
    mov $\ci, %esi
    mov $\row, %edx
    lea \lbl(%rip), %rcx
    CSTR %r8, "\nm"
    call chk_str
.endm

    .text

/* ---------------------------------------------------------------- runners */

/* try_csv(data rdi, end rsi, header rdx, delim rcx, schema r8) -> Table* | 0 */
try_csv:
    ENTER 48
    mov %rdi, 0(%rsp)
    sub %rdi, %rsi
    mov %rsi, 8(%rsp)
    mov %rdx, 16(%rsp)
    mov %rcx, 24(%rsp)
    mov %r8, 32(%rsp)
    movq $0, g_err_code(%rip)
    movb $0, g_err_msg(%rip)
    movq $0, g_pending_arena(%rip)
    lea jbuf(%rip), %rdi
    mov %rdi, g_jmpbuf(%rip)
    call _setjmp
    test %eax, %eax
    jnz 1f
    lea tname(%rip), %rdi
    mov 0(%rsp), %rsi
    mov 8(%rsp), %rdx
    mov 32(%rsp), %rcx
    mov 16(%rsp), %r8
    mov 24(%rsp), %r9
    call ingest_csv
    mov g_pending_arena(%rip), %rcx
    mov %rcx, last_pend(%rip)
    movq $0, g_pending_arena(%rip)
    LEAVE
1:  mov g_pending_arena(%rip), %rdi
    call arena_destroy
    movq $0, g_pending_arena(%rip)
    xor %eax, %eax
    LEAVE

/* try_json(data rdi, end rsi, lines rdx, schema rcx) -> Table* | 0 */
try_json:
    ENTER 48
    mov %rdi, 0(%rsp)
    sub %rdi, %rsi
    mov %rsi, 8(%rsp)
    mov %rdx, 16(%rsp)
    mov %rcx, 24(%rsp)
    movq $0, g_err_code(%rip)
    movb $0, g_err_msg(%rip)
    movq $0, g_pending_arena(%rip)
    lea jbuf(%rip), %rdi
    mov %rdi, g_jmpbuf(%rip)
    call _setjmp
    test %eax, %eax
    jnz 1f
    lea tname(%rip), %rdi
    mov 0(%rsp), %rsi
    mov 8(%rsp), %rdx
    mov 24(%rsp), %rcx
    mov 16(%rsp), %r8
    call ingest_json
    mov g_pending_arena(%rip), %rcx
    mov %rcx, last_pend(%rip)
    movq $0, g_pending_arena(%rip)
    LEAVE
1:  mov g_pending_arena(%rip), %rdi
    call arena_destroy
    movq $0, g_pending_arena(%rip)
    xor %eax, %eax
    LEAVE

/* ---------------------------------------------------------------- checks */

pass:
    incq npass(%rip)
    ret

/* chk_ok(t, nm) */
chk_ok:
    ENTER 0
    test %rdi, %rdi
    jz 1f
    mov TB_ARENA(%rdi), %rax
    cmp last_pend(%rip), %rax
    jne 2f
    test %rax, %rax
    jz 2f
    call pass
    LEAVE
1:  incq nfail(%rip)
    CSTR %rdi, "FAIL: %s: unexpected error %ld: %s\n"
    mov g_err_code(%rip), %rdx
    lea g_err_msg(%rip), %rcx
    xor %eax, %eax
    call printf
    LEAVE
2:  incq nfail(%rip)
    CSTR %rdi, "FAIL: %s: TB_ARENA is not the pending arena\n"
    xor %eax, %eax
    call printf
    LEAVE

/* chk_err(t, code, nm) */
chk_err:
    ENTER 0
    test %rdi, %rdi
    jnz 1f
    cmp g_err_code(%rip), %rsi
    jne 1f
    call pass
    LEAVE
1:  incq nfail(%rip)
    mov %rdx, %rax
    mov %rsi, %rdx
    mov %rax, %rsi
    CSTR %rdi, "FAIL: %s: expected error %ld, got %ld (%s)\n"
    mov g_err_code(%rip), %rcx
    lea g_err_msg(%rip), %r8
    xor %eax, %eax
    call printf
    LEAVE

/* chk_msg(substr, nm): g_err_msg contains substr */
chk_msg:
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    lea g_err_msg(%rip), %rdi
    mov %rbx, %rsi
    call strstr
    test %rax, %rax
    jz 1f
    call pass
    LEAVE
1:  incq nfail(%rip)
    CSTR %rdi, "FAIL: %s: message '%s' lacks '%s'\n"
    mov %r12, %rsi
    lea g_err_msg(%rip), %rdx
    mov %rbx, %rcx
    xor %eax, %eax
    call printf
    LEAVE

/* chk_shape(t, ncols, nrows, nm) */
chk_shape:
    ENTER 0
    test %rdi, %rdi
    jz 9f
    cmp TB_NCOLS(%rdi), %rsi
    jne 1f
    cmp TB_NROWS(%rdi), %rdx
    jne 1f
    call pass
    LEAVE
1:  incq nfail(%rip)
    mov %rcx, %rax
    mov TB_NCOLS(%rdi), %rcx
    mov TB_NROWS(%rdi), %r8
    mov %rsi, %rdx
    mov %rax, %rsi
    CSTR %rdi, "FAIL: %s: shape mismatch, expected %ld cols, got %ld cols / %ld rows\n"
    xor %eax, %eax
    call printf
9:  LEAVE

/* col_ptr(t rdi, ci rsi) -> rax Column* */
col_ptr:
    shl $COL_SHIFT, %rsi
    mov TB_COLS(%rdi), %rax
    add %rsi, %rax
    ret

/* chk_col(t, ci, name cstr, type, nm) */
chk_col:
    ENTER 0
    test %rdi, %rdi
    jz 9f
    mov %rdx, %r12
    mov %rcx, %r13
    mov %r8, %r14
    call col_ptr
    mov %rax, %rbx
    cmp COL_TYPE(%rbx), %r13
    jne 1f
    mov COL_NAME(%rbx), %rdi
    add $8, %rdi
    mov %r12, %rsi
    call strcmp
    test %eax, %eax
    jnz 1f
    call pass
    LEAVE
1:  incq nfail(%rip)
    CSTR %rdi, "FAIL: %s: column expected %s/%#lx got %s/%#lx\n"
    mov %r14, %rsi
    mov %r12, %rdx
    mov %r13, %rcx
    mov COL_NAME(%rbx), %r8
    add $8, %r8
    mov COL_TYPE(%rbx), %r9
    xor %eax, %eax
    call printf
9:  LEAVE

/* chk_val(t, ci, row, v, nm) */
chk_val:
    ENTER 0
    test %rdi, %rdi
    jz 9f
    mov %rdx, %r12
    mov %rcx, %r13
    mov %r8, %r14
    call col_ptr
    mov COL_NULLS(%rax), %rcx
    movzbl (%rcx, %r12), %r15d
    mov COL_DATA(%rax), %rcx
    mov (%rcx, %r12, 8), %rbx
    test %r15d, %r15d
    jnz 1f
    cmp %rbx, %r13
    jne 1f
    call pass
    LEAVE
1:  incq nfail(%rip)
    CSTR %rdi, "FAIL: %s: expected %ld (%#lx), got %ld null=%d\n"
    mov %r14, %rsi
    mov %r13, %rdx
    mov %r13, %rcx
    mov %rbx, %r8
    mov %r15d, %r9d
    xor %eax, %eax
    call printf
9:  LEAVE

/* chk_null(t, ci, row, nm) */
chk_null:
    ENTER 0
    test %rdi, %rdi
    jz 9f
    mov %rdx, %r12
    mov %rcx, %r14
    call col_ptr
    mov COL_NULLS(%rax), %rcx
    movzbl (%rcx, %r12), %r15d
    mov COL_DATA(%rax), %rcx
    mov (%rcx, %r12, 8), %rbx
    cmp $1, %r15d
    jne 1f
    test %rbx, %rbx
    jnz 1f
    call pass
    LEAVE
1:  incq nfail(%rip)
    CSTR %rdi, "FAIL: %s: expected NULL, got data %ld null=%d\n"
    mov %r14, %rsi
    mov %rbx, %rdx
    mov %r15d, %ecx
    xor %eax, %eax
    call printf
9:  LEAVE

/* chk_str(t, ci, row, s cstr, nm) */
chk_str:
    ENTER 0
    test %rdi, %rdi
    jz 9f
    mov %rdx, %r12
    mov %rcx, %r13
    mov %r8, %r14
    call col_ptr
    mov COL_NULLS(%rax), %rcx
    cmpb $0, (%rcx, %r12)
    jne 1f
    mov COL_DATA(%rax), %rcx
    mov (%rcx, %r12, 8), %rbx       /* pstr* */
    mov %r13, %rdi
    call strlen
    cmp (%rbx), %rax
    jne 2f
    lea 8(%rbx), %rdi
    mov %r13, %rsi
    mov %rax, %rdx
    call memcmp
    test %eax, %eax
    jnz 2f
    call pass
    LEAVE
1:  incq nfail(%rip)
    CSTR %rdi, "FAIL: %s: expected '%s', got NULL\n"
    mov %r14, %rsi
    mov %r13, %rdx
    xor %eax, %eax
    call printf
    LEAVE
2:  incq nfail(%rip)
    CSTR %rdi, "FAIL: %s: expected '%s', got '%.*s'\n"
    mov %r14, %rsi
    mov %r13, %rdx
    mov (%rbx), %rcx
    lea 8(%rbx), %r8
    xor %eax, %eax
    call printf
9:  LEAVE

/* ---------------------------------------------------------------- main */

FUNC main
    ENTER 16
    call arena_new
    mov %rax, g_arena(%rip)

    /* ===== CSV inference */
    CSV c_basic, 1, ',', 0
    OK "csv basic"
    SHAPE 7, 3, "csv basic shape"
    COL 0, "id", T_INT, "basic id"
    COL 1, "name", T_STR, "basic name"
    COL 2, "age", T_INT, "basic age"
    COL 3, "score", T_FLOAT, "basic score"
    COL 4, "active", T_BOOL, "basic active"
    COL 5, "joined", T_DATE, "basic joined"
    COL 6, "ts", T_TS, "basic ts"
    VAL 0, 2, $3, "basic id[2]"
    STR 1, 0, "Alice", "basic name[0]"
    STR 1, 2, "Carol, X", "basic name[2]"
    VAL 2, 0, $34, "basic age[0]"
    NUL 2, 1, "basic age[1]"
    VAL 2, 2, $-5, "basic age[2]"
    VAL 3, 0, $0x4056200000000000, "basic score[0]"
    VAL 3, 1, $0x4052000000000000, "basic score[1]"
    VAL 3, 2, $0x408f400000000000, "basic score[2]"
    VAL 4, 0, $1, "basic active[0]"
    VAL 4, 1, $0, "basic active[1]"
    VAL 4, 2, $1, "basic active[2]"
    VAL 5, 0, $18276, "basic joined[0]"
    NUL 5, 1, "basic joined[1]"
    VAL 5, 2, $19782, "basic joined[2]"
    VAL 6, 0, $1579082400000000, "basic ts[0]"
    VAL 6, 1, $1579046400000000, "basic ts[1]"
    VAL 6, 2, $1709251199500000, "basic ts[2]"

    /* quoting, CRLF, NULL vs empty, whitespace, no final newline */
    CSV c_strings, 1, ',', 0
    OK "csv strings"
    SHAPE 2, 8, "strings shape"
    COL 1, "s", T_STR, "strings s"
    STR 1, 0, "plain", "strings[0]"
    STR 1, 1, "with, comma", "strings[1]"
    STRL 1, 2, e_quote, "strings[2]"
    STR 1, 3, "", "strings[3] quoted empty"
    NUL 1, 4, "strings[4] unquoted empty"
    STR 1, 5, "multi\nline", "strings[5]"
    STR 1, 6, "  spaced  ", "strings[6]"
    STR 1, 7, "x", "strings[7] CR at EOF stripped"
    VAL 0, 7, $8, "strings id[7]"

    /* BOM, delimiter option, empty lines, case-insensitive booleans */
    CSV c_semi, 1, ';', 0
    OK "csv semi"
    SHAPE 3, 3, "semi shape"
    COL 0, "a", T_INT, "semi a"
    COL 1, "b", T_STR, "semi b"
    COL 2, "c", T_BOOL, "semi c"
    NUL 1, 2, "semi b[2]"
    VAL 2, 1, $0, "semi c[1]"
    VAL 2, 2, $1, "semi c[2]"

    /* header only */
    CSV c_hdronly, 1, ',', 0
    OK "csv header only"
    SHAPE 2, 0, "header only shape"
    COL 0, "a", T_STR, "header only a"
    COL 1, "b", T_STR, "header only b"

    /* quoted empty: NULL for non-strings, "" for strings */
    CSV c_qe, 1, ',', 0
    OK "csv qe"
    COL 0, "n", T_INT, "qe n"
    COL 1, "s", T_STR, "qe s"
    NUL 0, 0, "qe n[0]"
    STR 1, 0, "", "qe s[0]"
    VAL 0, 1, $1, "qe n[1]"

    /* whitespace trimmed for non-strings only */
    CSV c_ws, 1, ',', 0
    OK "csv ws"
    COL 0, "n", T_INT, "ws n"
    COL 1, "s", T_STR, "ws s"
    VAL 0, 0, $5, "ws n[0]"
    STR 1, 0, " x ", "ws s[0]"
    NUL 0, 1, "ws blank is NULL"

    /* int overflow falls through to FLOAT64 */
    CSV c_ovf, 1, ',', 0
    OK "csv ovf"
    COL 0, "n", T_FLOAT, "ovf n"
    VAL 0, 0, $0x43e0000000000000, "ovf n[0]"
    VAL 0, 1, $0x3ff0000000000000, "ovf n[1]"

    /* invalid date => STRING; date+timestamp mix => TIMESTAMP; empty => STRING */
    CSV c_dates, 1, ',', 0
    OK "csv dates"
    COL 0, "bad", T_STR, "dates bad"
    COL 1, "mix", T_TS, "dates mix"
    COL 2, "none", T_STR, "dates none"
    COL 3, "nan", T_STR, "dates nan"
    COL 4, "q", T_STR, "dates escaped quote"
    VAL 1, 0, $1704067200000000, "dates mix[0]"
    VAL 1, 1, $1704067201000000, "dates mix[1]"
    NUL 2, 0, "dates none[0]"
    STR 2, 1, "", "dates none[1]"

    /* ===== CSV errors */
    CSV c_arity, 1, ',', 0
    ERR E_INGEST_ERROR, "csv arity"
    MSG "record 3", "csv arity message"
    CSV c_duphdr, 1, ',', 0
    ERR E_INGEST_ERROR, "csv dup header"
    CSV c_unterm, 1, ',', 0
    ERR E_INGEST_ERROR, "csv unterminated quote"
    CSV c_garbage, 1, ',', 0
    ERR E_INGEST_ERROR, "csv garbage after quote"
    CSV c_emptyname, 1, ',', 0
    ERR E_INGEST_ERROR, "csv empty column name"
    CSV c_empty, 1, ',', 0
    ERR E_INGEST_ERROR, "csv empty input"
    CSV c_arity_long, 1, ',', 0
    ERR E_INGEST_ERROR, "csv too many fields"

    /* ===== CSV explicit schema */
    CSV c_ledger, 1, ',', sch_ledger
    OK "csv ledger"
    SHAPE 4, 4, "ledger shape"
    COL 0, "id", T_INT, "ledger id"
    COL 1, "account", T_STR, "ledger account"
    COL 2, "amount", MKDEC(10,2), "ledger amount"
    COL 3, "fee", MKDEC(4,2), "ledger fee"
    VAL 2, 0, $10025, "ledger amount[0]"
    VAL 2, 1, $-4010, "ledger amount[1]"
    NUL 2, 2, "ledger amount[2]"
    VAL 2, 3, $1200, "ledger amount[3]"
    VAL 3, 0, $50, "ledger fee[0]"
    VAL 3, 1, $25, "ledger fee[1]"
    VAL 3, 2, $10, "ledger fee[2]"
    NUL 3, 3, "ledger fee[3]"
    STR 1, 0, "A", "ledger account[0]"

    /* schema names win; header match is case-insensitive; strings forced */
    CSV c_case, 1, ',', sch_case
    OK "csv case header"
    COL 0, "id", T_STR, "case id"
    COL 1, "v", T_FLOAT, "case v"
    STR 0, 0, " 007", "case id[0] raw"
    VAL 1, 0, $0x4008000000000000, "case v[0]"

    /* header=false */
    CSV c_nohdr, 0, ',', sch_nohdr
    OK "csv no header"
    SHAPE 2, 2, "no header shape"
    COL 0, "x", T_INT, "nohdr x"
    COL 1, "y", T_STR, "nohdr y"
    VAL 0, 1, $2, "nohdr x[1]"
    STR 1, 0, "a", "nohdr y[0]"

    CSV c_dec_ok, 1, ',', sch_dec41
    OK "csv dec ok"
    VAL 0, 0, $1234, "dec ok[0]"
    VAL 0, 1, $-5, "dec ok[1]"
    VAL 0, 2, $70, "dec ok[2]"
    NUL 0, 3, "dec ok[3]"

    CSV c_precise, 1, ',', sch_precise
    ERR E_CONVERSION_ERROR, "csv too precise"
    MSG "amount", "csv conversion message names column"
    CSV c_dec_big, 1, ',', sch_dec31
    ERR E_CONVERSION_ERROR, "csv dec too big"
    CSV c_ovf, 1, ',', sch_n_int
    ERR E_CONVERSION_ERROR, "csv int overflow schema"
    CSV c_yes, 1, ',', sch_v_bool
    ERR E_CONVERSION_ERROR, "csv bool yes"
    CSV c_nan, 1, ',', sch_v_float
    ERR E_CONVERSION_ERROR, "csv float NaN"
    CSV c_baddate, 1, ',', sch_v_date
    ERR E_CONVERSION_ERROR, "csv bad date schema"
    CSV c_qint, 1, ',', sch_v_int
    ERR E_CONVERSION_ERROR, "csv escaped quote in int"
    CSV c_case, 1, ',', sch_short
    ERR E_INGEST_ERROR, "csv header count mismatch"
    CSV c_case, 1, ',', sch_wrongname
    ERR E_INGEST_ERROR, "csv header name mismatch"
    CSV c_nohdr, 0, ',', sch_dup
    ERR E_INGEST_ERROR, "csv duplicate schema names"

    /* row limit */
    movq $2, g_max_table_rows(%rip)
    CSV c_basic, 1, ',', 0
    ERR E_RESOURCE_LIMIT, "csv row limit"
    movq $3, g_max_table_rows(%rip)
    CSV c_basic, 1, ',', 0
    OK "csv row limit exact"
    movq $200000000, g_max_table_rows(%rip)

    /* input size limit */
    movq $10, g_max_ingest_bytes(%rip)
    CSV c_basic, 1, ',', 0
    ERR E_RESOURCE_LIMIT, "csv ingest bytes limit"
    JSN j_sparse, 1, 0
    ERR E_RESOURCE_LIMIT, "json ingest bytes limit"
    movabs $0x7fffffffffffffff, %rax
    mov %rax, g_max_ingest_bytes(%rip)

    /* field longer than 16 MiB */
    mov $(16*1024*1024 + 8), %edi
    call malloc
    mov %rax, bigbuf(%rip)
    mov %rax, %rdi
    mov $'a', %esi
    mov $(16*1024*1024 + 8), %edx
    call memset
    mov bigbuf(%rip), %rdi
    movb $'\n', 1(%rdi)
    lea (16*1024*1024 + 8)(%rdi), %rsi
    mov $1, %edx
    mov $',', %ecx
    xor %r8d, %r8d
    call try_csv
    mov %rax, %r12
    ERR E_INGEST_ERROR, "csv field > 16 MiB"
    /* exactly 16 MiB is fine */
    mov bigbuf(%rip), %rdi
    lea (16*1024*1024 + 2)(%rdi), %rsi
    mov $1, %edx
    mov $',', %ecx
    xor %r8d, %r8d
    call try_csv
    mov %rax, %r12
    OK "csv field = 16 MiB"
    SHAPE 1, 1, "16 MiB shape"
    mov bigbuf(%rip), %rdi
    call free

    /* ===== JSON Lines inference */
    JSN j_products, 1, 0
    OK "jsonl products"
    SHAPE 4, 3, "products shape"
    COL 0, "sku", T_STR, "products sku"
    COL 1, "price", T_FLOAT, "products price"
    COL 2, "stock", T_INT, "products stock"
    COL 3, "released", T_DATE, "products released"
    STR 0, 1, "B-1", "products sku[1]"
    VAL 1, 0, $0x4023fae147ae147b, "products price[0]"
    VAL 1, 1, $0x4008000000000000, "products price[1]"
    NUL 1, 2, "products price[2]"
    VAL 2, 2, $7, "products stock[2]"
    VAL 3, 0, $19358, "products released[0]"
    NUL 3, 1, "products released[1]"

    /* JSON array document */
    JSN j_events, 0, 0
    OK "json events"
    SHAPE 5, 4, "events shape"
    COL 0, "id", T_INT, "events id"
    COL 1, "kind", T_STR, "events kind"
    COL 2, "ts", T_TS, "events ts"
    COL 3, "value", T_FLOAT, "events value"
    COL 4, "ok", T_BOOL, "events ok"
    VAL 2, 0, $1714564800000000, "events ts[0]"
    VAL 2, 1, $1714564801250000, "events ts[1]"
    VAL 2, 2, $1714608000000000, "events ts[2]"
    VAL 3, 0, $0x3ff8000000000000, "events value[0]"
    NUL 3, 1, "events value[1]"
    VAL 3, 2, $0xc000000000000000, "events value[2]"
    VAL 3, 3, $0x4059000000000000, "events value[3]"
    VAL 4, 1, $0, "events ok[1]"
    NUL 4, 3, "events ok[3]"
    STRL 1, 0, e_uni, "events kind[0] unicode escape"

    /* union of keys, case-insensitive matching, missing keys */
    JSN j_sparse, 1, 0
    OK "jsonl sparse"
    SHAPE 3, 3, "sparse shape"
    COL 0, "a", T_INT, "sparse a"
    COL 1, "b", T_STR, "sparse b"
    COL 2, "c", T_BOOL, "sparse c"
    VAL 0, 0, $1, "sparse a[0]"
    VAL 0, 1, $2, "sparse a[1]"
    NUL 0, 2, "sparse a[2]"
    NUL 1, 0, "sparse b[0]"
    STR 1, 1, "x", "sparse b[1]"
    VAL 2, 2, $1, "sparse c[2]"

    /* all-null => STRING; exponent => FLOAT64; big int => FLOAT64; strings */
    JSN j_misc, 1, 0
    OK "jsonl misc"
    COL 0, "n", T_STR, "misc n"
    COL 1, "x", T_FLOAT, "misc x"
    COL 2, "big", T_FLOAT, "misc big"
    COL 3, "d", T_STR, "misc d"
    COL 4, "e", T_STR, "misc e (bad date)"
    NUL 0, 0, "misc n[0]"
    VAL 1, 0, $0x408f400000000000, "misc x[0]"
    VAL 1, 1, $0x4000000000000000, "misc x[1]"

    /* explicit schema */
    JSN j_money, 0, sch_money
    OK "json money"
    SHAPE 3, 3, "money shape"
    COL 1, "amt", MKDEC(8,3), "money amt"
    VAL 1, 0, $12500, "money amt[0]"
    VAL 1, 1, $-125, "money amt[1]"
    VAL 1, 2, $7000, "money amt[2]"
    VAL 2, 0, $19753, "money day[0]"
    NUL 2, 1, "money day[1]"
    NUL 2, 2, "money day[2]"
    VAL 0, 1, $2, "money id[1]"

    JSN j_empty, 0, 0
    OK "json []"
    SHAPE 0, 0, "json [] shape"
    JSN j_blank, 1, 0
    OK "jsonl blank"
    SHAPE 0, 0, "jsonl blank shape"
    JSN j_blank, 1, sch_a_int
    OK "jsonl blank with schema"
    SHAPE 1, 0, "jsonl blank schema shape"

    /* ===== JSON errors */
    JSN j_mixed, 0, 0
    ERR E_INGEST_ERROR, "json mixed types"
    JSN j_nested, 1, 0
    ERR E_INGEST_ERROR, "jsonl nested"
    JSN j_broken, 1, 0
    ERR E_INGEST_ERROR, "jsonl broken"
    JSN j_obj, 0, 0
    ERR E_INGEST_ERROR, "json not array"
    JSN j_nonobj, 0, 0
    ERR E_INGEST_ERROR, "json non-object element"
    JSN j_dup, 1, 0
    ERR E_INGEST_ERROR, "jsonl duplicate key"
    JSN j_dupcase, 1, 0
    ERR E_INGEST_ERROR, "jsonl duplicate key case"
    JSN j_nan, 1, 0
    ERR E_INGEST_ERROR, "jsonl NaN"
    JSN j_arr, 1, 0
    ERR E_INGEST_ERROR, "jsonl nested array"
    JSN j_trail, 0, 0
    ERR E_INGEST_ERROR, "json trailing comma"
    JSN j_line_arr, 1, 0
    ERR E_INGEST_ERROR, "jsonl line not object"
    JSN j_extra, 1, sch_a_int
    ERR E_INGEST_ERROR, "jsonl key not in schema"
    JSN j_a15, 1, sch_a_int
    ERR E_CONVERSION_ERROR, "jsonl 1.5 to INT64"
    JSN j_atrue_s, 1, sch_a_bool
    ERR E_CONVERSION_ERROR, "jsonl string to BOOLEAN"
    JSN j_a15, 1, sch_a_str
    ERR E_CONVERSION_ERROR, "jsonl number to STRING"
    JSN j_atrue, 1, sch_a_int
    ERR E_CONVERSION_ERROR, "jsonl bool to INT64"
    JSN j_aexp, 1, sch_a_dec
    ERR E_CONVERSION_ERROR, "jsonl exponent to DECIMAL"
    JSN j_a15, 1, sch_a_date
    ERR E_CONVERSION_ERROR, "jsonl number to DATE"
    JSN j_atrue, 1, sch_a_bool
    OK "jsonl bool schema"
    VAL 0, 0, $1, "jsonl bool schema value"
    JSN j_astr, 1, sch_a_float
    OK "jsonl string to FLOAT64"
    VAL 0, 0, $0x3ff8000000000000, "jsonl string to FLOAT64 value"

    movq $1, g_max_table_rows(%rip)
    JSN j_sparse, 1, 0
    ERR E_RESOURCE_LIMIT, "jsonl row limit"
    movq $200000000, g_max_table_rows(%rip)

    /* ===== summary */
    cmpq $0, nfail(%rip)
    jne 1f
    CSTR %rdi, "test_ingest: %ld passed\n"
    mov npass(%rip), %rsi
    xor %eax, %eax
    call printf
    xor %eax, %eax
    LEAVE
1:  CSTR %rdi, "test_ingest: %ld passed, %ld FAILED\n"
    mov npass(%rip), %rsi
    mov nfail(%rip), %rdx
    xor %eax, %eax
    call printf
    mov $1, %eax
    LEAVE
ENDF main

/* ---------------------------------------------------------------- data */
    .section .rodata
e_quote:    .asciz "with \"quote\""
e_uni:      .asciz "cl\303\251ck \"q\" \\ /"

c_basic:
    .ascii "id,name,age,score,active,joined,ts\n"
    .ascii "1,Alice,34,88.5,true,2020-01-15,2020-01-15 10:00:00\n"
    .ascii "2,Bob,,72,FALSE,,2020-01-15\n"
    .ascii "3,\"Carol, X\",-5,1e3,True,2024-02-29,2024-02-29T23:59:59.5\n"
c_basic_e:

c_strings:
    .ascii "id,s\r\n"
    .ascii "1,plain\r\n"
    .ascii "2,\"with, comma\"\r\n"
    .ascii "3,\"with \"\"quote\"\"\"\r\n"
    .ascii "4,\"\"\r\n"
    .ascii "5,\r\n"
    .ascii "6,\"multi\nline\"\n"
    .ascii "7,  spaced  \n"
    .ascii "8,x\r"
c_strings_e:

c_semi:
    .ascii "\357\273\277a;b;c\r\n"
    .ascii "\r\n"
    .ascii "1;x;true\r\n"
    .ascii "\n"
    .ascii "2;y;FALSE\r\n"
    .ascii "3;;True\r\n\n"
c_semi_e:

c_hdronly:  .ascii "a,b\n"
c_hdronly_e:

c_qe:       .ascii "n,s\n\"\",\"\"\n1,x\n"
c_qe_e:

c_ws:       .ascii "n,s\n 5 , x \n\t ,\n"
c_ws_e:

c_ovf:      .ascii "n\n9223372036854775808\n1\n"
c_ovf_e:

c_dates:
    .ascii "bad,mix,none,nan,q\n"
    .ascii "2023-02-29,2024-01-01,,NaN,\"1\"\"\"\n"
    .ascii "2024-01-01,2024-01-01 00:00:01,\"\",1.5,2\n"
c_dates_e:

c_arity:    .ascii "a,b\n1,2\n3\n"
c_arity_e:
c_arity_long: .ascii "a,b\n1,2,3\n"
c_arity_long_e:
c_duphdr:   .ascii "a,A\n1,2\n"
c_duphdr_e:
c_unterm:   .ascii "id,v\n1,\"unterminated\n"
c_unterm_e:
c_garbage:  .ascii "a\n\"x\"y\n"
c_garbage_e:
c_emptyname: .ascii "a,,c\n1,2,3\n"
c_emptyname_e:
c_empty:
c_empty_e:

c_ledger:
    .ascii "id,account,amount,fee\n"
    .ascii "1,A,100.25,0.5\n"
    .ascii "2,A,-40.10,0.25\n"
    .ascii "5,C,,0.1\n"
    .ascii "6,A, 12.00 ,\n"
c_ledger_e:

c_case:     .ascii "ID,V\n 007,3\n"
c_case_e:
c_nohdr:    .ascii "1,a\n2,b"
c_nohdr_e:
c_dec_ok:   .ascii "v\n123.4\n-0.5\n+7\n\"\"\n"
c_dec_ok_e:
c_precise:  .ascii "id,amount\n1,10.005\n"
c_precise_e:
c_dec_big:  .ascii "v\n123.4\n"
c_dec_big_e:
c_yes:      .ascii "v\nyes\n"
c_yes_e:
c_nan:      .ascii "v\nNaN\n"
c_nan_e:
c_baddate:  .ascii "v\n2023-02-29\n"
c_baddate_e:
c_qint:     .ascii "v\n\"1\"\"\"\n"
c_qint_e:

j_products:
    .ascii "{\"sku\":\"A-1\",\"price\":9.99,\"stock\":120,\"released\":\"2023-01-01\"}\r\n"
    .ascii "\r\n"
    .ascii "{\"sku\":\"B-1\",\"price\":3,\"stock\":55}\n"
    .ascii "   \n"
    .ascii "{\"sku\":\"B-2\",\"price\":null,\"stock\":7,\"released\":\"2024-02-29\"}"
j_products_e:

j_events:
    .ascii "\357\273\277[\n"
    .ascii "  {\"id\": 1, \"kind\": \"cl\\u00e9ck \\\"q\\\" \\\\ \\/\", \"ts\": \"2024-05-01T12:00:00\", \"value\": 1.5, \"ok\": true},\n"
    .ascii "  {\"id\": 2, \"kind\": \"view\", \"ts\": \"2024-05-01 12:00:01.250\", \"value\": null, \"ok\": false},\n"
    .ascii "  {\"id\": 3, \"kind\": \"click\", \"ts\": \"2024-05-02\", \"value\": -2, \"ok\": true},\n"
    .ascii "  {\"id\": 4, \"kind\": \"buy\", \"ts\": \"2024-05-03T08:30:00\", \"value\": 100, \"ok\": null}\n"
    .ascii "]\n"
j_events_e:

j_sparse:
    .ascii "{\"a\": 1}\n{\"b\": \"x\", \"A\": 2}\n{\"c\": true}\n"
j_sparse_e:

j_misc:
    .ascii "{\"n\": null, \"x\": 1e3, \"big\": 9223372036854775808, \"d\": \"2024-01-01\", \"e\": \"2023-02-29\"}\n"
    .ascii "{\"n\": null, \"x\": 2, \"big\": 1, \"d\": \"x\"}\n"
j_misc_e:

j_money:
    .ascii "[{\"id\": 1, \"amt\": 12.5, \"day\": \"2024-01-31\"}, {\"id\": 2, \"amt\": \"-0.125\", \"day\": null}, {\"id\": 3, \"amt\": 7}]"
j_money_e:

j_empty:    .ascii " [ ] "
j_empty_e:
j_blank:    .ascii "\n  \r\n\n"
j_blank_e:
j_mixed:    .ascii "[{\"a\":1},{\"a\":\"x\"}]"
j_mixed_e:
j_nested:   .ascii "{\"a\":1}\n{\"a\":{\"nested\":true}}\n"
j_nested_e:
j_broken:   .ascii "{\"a\":1,\n"
j_broken_e:
j_obj:      .ascii "{\"a\": 1}\n"
j_obj_e:
j_nonobj:   .ascii "[{\"a\": 1}, 2]"
j_nonobj_e:
j_dup:      .ascii "{\"a\": 1, \"a\": 2}\n"
j_dup_e:
j_dupcase:  .ascii "{\"a\": 1, \"A\": 2}\n"
j_dupcase_e:
j_nan:      .ascii "{\"a\": NaN}\n"
j_nan_e:
j_arr:      .ascii "{\"a\": [1, 2]}\n"
j_arr_e:
j_trail:    .ascii "[{\"a\": 1},]"
j_trail_e:
j_line_arr: .ascii "{\"a\": 1}\n[1]\n"
j_line_arr_e:
j_extra:    .ascii "{\"a\": 1, \"b\": 2}\n"
j_extra_e:
j_a15:      .ascii "{\"a\": 1.5}\n"
j_a15_e:
j_atrue_s:  .ascii "{\"a\": \"true\"}\n"
j_atrue_s_e:
j_atrue:    .ascii "{\"A\": true}\n"
j_atrue_e:
j_aexp:     .ascii "{\"a\": 1e2}\n"
j_aexp_e:
j_astr:     .ascii "{\"a\": \" 1.5 \"}\n"
j_astr_e:

/* ---------------------------------------------------------------- schemas */
    .data
    .p2align 3
sch_ledger: .quad 4, 1f
1:  .quad ps_id, T_INT, ps_account, T_STR, ps_amount, MKDEC(10,2), ps_fee, MKDEC(4,2)
sch_case:   .quad 2, 1f
1:  .quad ps_id, T_STR, ps_v, T_FLOAT
sch_short:  .quad 1, 1f
1:  .quad ps_id, T_STR
sch_wrongname: .quad 2, 1f
1:  .quad ps_id, T_STR, ps_w, T_FLOAT
sch_nohdr:  .quad 2, 1f
1:  .quad ps_x, T_INT, ps_y, T_STR
sch_dup:    .quad 2, 1f
1:  .quad ps_x, T_INT, ps_X, T_STR
sch_dec41:  .quad 1, 1f
1:  .quad ps_v, MKDEC(4,1)
sch_dec31:  .quad 1, 1f
1:  .quad ps_v, MKDEC(3,1)
sch_precise: .quad 2, 1f
1:  .quad ps_id, T_INT, ps_amount, MKDEC(10,2)
sch_n_int:  .quad 1, 1f
1:  .quad ps_n, T_INT
sch_v_bool: .quad 1, 1f
1:  .quad ps_v, T_BOOL
sch_v_float: .quad 1, 1f
1:  .quad ps_v, T_FLOAT
sch_v_date: .quad 1, 1f
1:  .quad ps_v, T_DATE
sch_v_int:  .quad 1, 1f
1:  .quad ps_v, T_INT
sch_money:  .quad 3, 1f
1:  .quad ps_id, T_INT, ps_amt, MKDEC(8,3), ps_day, T_DATE
sch_a_int:  .quad 1, 1f
1:  .quad ps_a, T_INT
sch_a_bool: .quad 1, 1f
1:  .quad ps_a, T_BOOL
sch_a_str:  .quad 1, 1f
1:  .quad ps_a, T_STR
sch_a_dec:  .quad 1, 1f
1:  .quad ps_a, MKDEC(10,2)
sch_a_date: .quad 1, 1f
1:  .quad ps_a, T_DATE
sch_a_float: .quad 1, 1f
1:  .quad ps_a, T_FLOAT

PSTR ps_id, "id"
PSTR ps_account, "account"
PSTR ps_amount, "amount"
PSTR ps_fee, "fee"
PSTR ps_v, "v"
PSTR ps_w, "w"
PSTR ps_x, "x"
PSTR ps_X, "X"
PSTR ps_y, "y"
PSTR ps_n, "n"
PSTR ps_a, "a"
PSTR ps_amt, "amt"
PSTR ps_day, "day"
