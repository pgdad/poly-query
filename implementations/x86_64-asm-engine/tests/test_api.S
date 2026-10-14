/*
 * test_api.S - unit tests of the embedding API (include/polyquery.h),
 * using only the public functions and polyquery.inc: instances, load with
 * an explicit schema, typed result values (INT64, STRING, DECIMAL narrow
 * and wide, DATE, BOOLEAN, FLOAT64, NULL), pq_value_text, errors leaving the
 * instance usable, pq_create_table, save / drop / open, tables, schema, and
 * the isolation of two instances.
 */
#include "pq.inc"
#include "sql.inc"
#include "polyquery.inc"

    .section .note.GNU-stack, "", @progbits

#include "test_lib.inc"

    .data
    .p2align 3
db1:      .quad 0
db2:      .quad 0
res:      .quad 0
rows:     .quad 0
cfg:      .zero PQ_CONFIG_SIZE
lopts:    .zero PQ_LOAD_SIZE
schema:   .quad c_id, t_int, c_name, t_str, c_amt, t_dec, c_d, t_date
tmpl:     .asciz "/tmp/pq-api-test-XXXXXX"
textbuf:  .zero 128

    .section .rodata
c_id:     .asciz "id"
c_name:   .asciz "name"
c_amt:    .asciz "amt"
c_d:      .asciz "d"
t_int:    .asciz "INT64"
t_str:    .asciz "STRING"
t_dec:    .asciz "DECIMAL(18,2)"
t_date:   .asciz "DATE"
csv:      .asciz "1,ann,10.50,2026-01-02\n2,,-3.25,\n"
tbl_t:    .asciz "t"
tbl_u:    .asciz "u"
file_u:   .asciz "u.pqcf"
q_typed:  .asciz "SELECT id, name, amt, d, id > 1 AS b, CAST(id AS FLOAT64) / 4 AS f, CAST(amt AS DECIMAL(38,2)) * 10000000000000000 AS w FROM t ORDER BY id"
q_bad:    .asciz "SELEC 1"
q_count:  .asciz "SELECT COUNT(*) AS n FROM u"
q_ct:     .asciz "SELECT id, name FROM t WHERE id = 1"
q_t:      .asciz "SELECT * FROM t"
w_text:   .asciz "105000000000000000.00"
amt_text: .asciz "-3.25"
date_text: .asciz "2026-01-02"
dec_name: .asciz "DECIMAL(18,2)"
    .text

/* value(row rdi, col rsi) -> rax pq_value* of the current result */
value:
    mov res(%rip), %rax
    mov PQ_RES_NCOLS(%rax), %rcx
    imul %rdi, %rcx
    add %rsi, %rcx
    imul $PQ_VAL_SIZE, %rcx, %rcx
    add PQ_RES_VALUES(%rax), %rcx
    mov %rcx, %rax
    ret

/* text_is(row rdi, col rsi, expected rdx) -> eax 1 if pq_value_text matches */
text_is:
    push %rbx
    mov %rdx, %rbx
    mov %rsi, %rdx
    mov %rdi, %rsi
    mov res(%rip), %rdi
    lea textbuf(%rip), %rcx
    mov $128, %r8d
    call pq_value_text
    lea textbuf(%rip), %rdi
    mov %rbx, %rsi
    call strcmp
    test %eax, %eax
    sete %al
    movzbl %al, %eax
    pop %rbx
    ret

/* CHK cond-setting instruction already executed: eax = 0/1 */
.macro CHK name
    mov %eax, %edi
    CSTR %rsi, "\name"
    call check
.endm

/* OKCALL: eax status == 0 */
.macro OKST name
    xor %edi, %edi
    test %eax, %eax
    sete %dil
    CSTR %rsi, "\name"
    call check
.endm

FUNC main
    ENTER 16
    lea tmpl(%rip), %rdi
    call mkdtemp
    mov %rax, cfg+PQ_CONFIG_DATA_DIR(%rip)
    movq $64, cfg+PQ_CONFIG_MAX_QUERY_MEM(%rip)
    movq $2, cfg+PQ_CONFIG_THREADS(%rip)
    lea cfg(%rip), %rdi
    lea db1(%rip), %rsi
    call pq_create
    OKST "create db1"
    xor %edi, %edi
    lea db2(%rip), %rsi
    call pq_create
    OKST "create db2 (defaults)"

    /* load with an explicit schema, no header */
    lea schema(%rip), %rax
    mov %rax, lopts+PQ_LOAD_SCHEMA(%rip)
    movq $4, lopts+PQ_LOAD_SCHEMA_LEN(%rip)
    movq $PQ_HEADER_NO, lopts+PQ_LOAD_HEADER(%rip)
    lea csv(%rip), %rdi
    call strlen
    mov db1(%rip), %rdi
    lea tbl_t(%rip), %rsi
    lea csv(%rip), %rdx
    mov %rax, %rcx
    lea lopts(%rip), %r8
    lea rows(%rip), %r9
    call pq_load_text
    OKST "load_text"
    xor %eax, %eax
    cmpq $2, rows(%rip)
    sete %al
    CHK "load_text rows"

    /* typed values */
    mov db1(%rip), %rdi
    lea q_typed(%rip), %rsi
    xor %edx, %edx
    lea res(%rip), %rcx
    call pq_query
    OKST "query typed"
    mov res(%rip), %rbx
    xor %eax, %eax
    cmpq $7, PQ_RES_NCOLS(%rbx)
    sete %al
    CHK "ncols"
    xor %eax, %eax
    cmpq $2, PQ_RES_NROWS(%rbx)
    sete %al
    CHK "nrows"
    mov PQ_RES_COLUMNS(%rbx), %r12
    xor %eax, %eax
    cmpl $PQ_TYPE_DECIMAL, 2*PQ_COL_SIZE+PQ_COL_TYPE(%r12)
    sete %al
    CHK "amt type"
    xor %eax, %eax
    cmpl $2, 2*PQ_COL_SIZE+PQ_COL_SCALE(%r12)
    sete %al
    CHK "amt scale"
    mov 2*PQ_COL_SIZE+PQ_COL_TYPE_NAME(%r12), %rdi
    lea dec_name(%rip), %rsi
    call strcmp
    test %eax, %eax
    sete %al
    movzbl %al, %eax
    CHK "amt type name"
    xor %edi, %edi                  /* row 0 */
    xor %esi, %esi
    call value
    xor %ecx, %ecx
    cmpq $1, PQ_VAL_I64(%rax)
    sete %cl
    mov %ecx, %eax
    CHK "id = 1"
    xor %edi, %edi
    mov $1, %esi
    call value
    xor %ecx, %ecx
    cmpq $3, PQ_VAL_STR_LEN(%rax)
    sete %cl
    mov %ecx, %eax
    CHK "name length"
    xor %edi, %edi
    mov $2, %esi
    call value
    xor %ecx, %ecx
    cmpq $1050, PQ_VAL_DEC_LO(%rax)
    sete %cl
    mov %ecx, %eax
    CHK "amt unscaled"
    xor %edi, %edi
    mov $3, %esi
    call value
    xor %ecx, %ecx
    cmpq $20455, PQ_VAL_DAYS(%rax)
    sete %cl
    mov %ecx, %eax
    CHK "date days"
    xor %edi, %edi
    mov $3, %esi
    lea date_text(%rip), %rdx
    call text_is
    CHK "date text"
    xor %edi, %edi
    mov $4, %esi
    call value
    xor %ecx, %ecx
    cmpq $0, PQ_VAL_BOOL(%rax)
    sete %cl
    mov %ecx, %eax
    CHK "boolean false"
    xor %edi, %edi
    mov $5, %esi
    call value
    mov $0x3fd0000000000000, %rcx   /* 0.25 */
    xor %edx, %edx
    cmp %rcx, PQ_VAL_F64(%rax)
    sete %dl
    mov %edx, %eax
    CHK "float 0.25"
    xor %edi, %edi
    mov $6, %esi
    lea w_text(%rip), %rdx
    call text_is
    CHK "wide decimal text"
    xor %edi, %edi
    mov $6, %esi
    call value
    xor %ecx, %ecx
    cmpq $0, PQ_VAL_DEC_HI(%rax)    /* 1.05e19 > 2^63: needs the high word */
    sete %cl
    mov PQ_VAL_DEC_LO(%rax), %rdx
    test %rdx, %rdx
    sets %dl
    and %edx, %ecx
    mov %ecx, %eax
    CHK "wide decimal 128-bit"
    mov $1, %edi                    /* row 1: NULLs, negative decimal */
    mov $1, %esi
    call value
    xor %ecx, %ecx
    cmpq $0, PQ_VAL_IS_NULL(%rax)
    setne %cl
    mov %ecx, %eax
    CHK "name NULL"
    mov $1, %edi
    mov $3, %esi
    call value
    xor %ecx, %ecx
    cmpq $0, PQ_VAL_IS_NULL(%rax)
    setne %cl
    mov %ecx, %eax
    CHK "date NULL"
    mov $1, %edi
    mov $2, %esi
    lea amt_text(%rip), %rdx
    call text_is
    CHK "negative decimal text"
    mov $1, %edi
    mov $2, %esi
    call value
    xor %ecx, %ecx
    cmpq $-1, PQ_VAL_DEC_HI(%rax)
    sete %cl
    mov %ecx, %eax
    CHK "negative decimal sign extension"
    mov res(%rip), %rdi
    call pq_result_free

    /* an error carries its code and leaves the instance usable */
    mov db1(%rip), %rdi
    lea q_bad(%rip), %rsi
    xor %edx, %edx
    lea res(%rip), %rcx
    call pq_query
    xor %ecx, %ecx
    cmp $PQ_E_PARSE_ERROR, %eax
    sete %cl
    mov %ecx, %eax
    CHK "parse error code"
    mov db1(%rip), %rdi
    call pq_errcode
    xor %ecx, %ecx
    cmp $PQ_E_PARSE_ERROR, %eax
    sete %cl
    mov %ecx, %eax
    CHK "pq_errcode"
    mov db1(%rip), %rdi
    call pq_errmsg
    xor %ecx, %ecx
    cmpb $0, (%rax)
    setne %cl
    mov %ecx, %eax
    CHK "pq_errmsg"
    xor %eax, %eax
    cmpq $0, res(%rip)
    sete %al
    CHK "no result on error"

    /* create table from a query; ALREADY_EXISTS without replace */
    mov db1(%rip), %rdi
    lea tbl_u(%rip), %rsi
    lea q_ct(%rip), %rdx
    xor %ecx, %ecx
    xor %r8d, %r8d
    lea rows(%rip), %r9
    call pq_create_table
    OKST "create_table"
    xor %eax, %eax
    cmpq $1, rows(%rip)
    sete %al
    CHK "create_table rows"
    mov db1(%rip), %rdi
    lea tbl_u(%rip), %rsi
    lea q_t(%rip), %rdx
    xor %ecx, %ecx
    xor %r8d, %r8d
    xor %r9d, %r9d
    call pq_create_table
    xor %ecx, %ecx
    cmp $PQ_E_ALREADY_EXISTS, %eax
    sete %cl
    mov %ecx, %eax
    CHK "create_table exists"

    /* save, drop, open */
    mov db1(%rip), %rdi
    lea tbl_u(%rip), %rsi
    lea file_u(%rip), %rdx
    xor %ecx, %ecx
    call pq_save
    OKST "save"
    mov db1(%rip), %rdi
    lea tbl_u(%rip), %rsi
    call pq_drop
    OKST "drop"
    mov db1(%rip), %rdi
    lea tbl_u(%rip), %rsi
    call pq_drop
    xor %ecx, %ecx
    cmp $PQ_E_NOT_FOUND, %eax
    sete %cl
    mov %ecx, %eax
    CHK "drop unknown"
    mov db1(%rip), %rdi
    lea tbl_u(%rip), %rsi
    lea file_u(%rip), %rdx
    mov $PQ_OPEN_MMAP, %ecx
    call pq_open
    OKST "open"
    mov db1(%rip), %rdi
    lea q_count(%rip), %rsi
    xor %edx, %edx
    lea res(%rip), %rcx
    call pq_query
    OKST "count after open"
    xor %edi, %edi
    xor %esi, %esi
    call value
    xor %ecx, %ecx
    cmpq $1, PQ_VAL_I64(%rax)
    sete %cl
    mov %ecx, %eax
    CHK "count = 1"
    mov res(%rip), %rdi
    call pq_result_free

    /* tables and schema */
    mov db1(%rip), %rdi
    lea 0(%rsp), %rsi
    call pq_tables
    OKST "tables"
    mov 0(%rsp), %rbx
    xor %eax, %eax
    cmpq $2, PQ_TL_COUNT(%rbx)
    sete %al
    CHK "two tables"
    mov PQ_TL_TABLES(%rbx), %rax
    mov PQ_TI_NAME(%rax), %rdi
    lea tbl_t(%rip), %rsi
    call strcmp
    test %eax, %eax
    sete %al
    movzbl %al, %eax
    CHK "first table t"
    mov %rbx, %rdi
    call pq_table_list_free
    mov db1(%rip), %rdi
    lea tbl_t(%rip), %rsi
    lea 0(%rsp), %rdx
    call pq_schema
    OKST "schema"
    mov 0(%rsp), %rbx
    xor %eax, %eax
    cmpq $4, PQ_SCH_NCOLS(%rbx)
    sete %al
    CHK "schema ncols"
    mov PQ_SCH_COLUMNS(%rbx), %rax
    mov 2*PQ_COL_SIZE+PQ_COL_TYPE_NAME(%rax), %rdi
    lea dec_name(%rip), %rsi
    call strcmp
    test %eax, %eax
    sete %al
    movzbl %al, %eax
    CHK "schema type name"
    mov %rbx, %rdi
    call pq_schema_free

    /* instances are isolated */
    mov db2(%rip), %rdi
    lea q_t(%rip), %rsi
    xor %edx, %edx
    lea res(%rip), %rcx
    call pq_query
    xor %ecx, %ecx
    test %eax, %eax
    setnz %cl
    mov %ecx, %eax
    CHK "db2 has no table t"
    mov db1(%rip), %rdi
    lea q_t(%rip), %rsi
    xor %edx, %edx
    lea res(%rip), %rcx
    call pq_query
    OKST "db1 still has t"
    mov res(%rip), %rdi
    call pq_result_free

    mov db2(%rip), %rdi
    call pq_close
    mov db1(%rip), %rdi
    call pq_close
    /* clean up the data directory */
    mov cfg+PQ_CONFIG_DATA_DIR(%rip), %rdi
    CSTR %rsi, "/u.pqcf"
    lea textbuf(%rip), %rdi
    mov $128, %esi
    CSTR %rdx, "%s/u.pqcf"
    mov cfg+PQ_CONFIG_DATA_DIR(%rip), %rcx
    xor %eax, %eax
    call snprintf
    lea textbuf(%rip), %rdi
    call unlink
    mov cfg+PQ_CONFIG_DATA_DIR(%rip), %rdi
    call rmdir
    CSTR %rdi, "test_api"
    call test_done
    LEAVE
ENDF main
