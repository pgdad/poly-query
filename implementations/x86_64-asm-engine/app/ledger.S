/*
 * ledger.S - the embedded engine instance and the ledger tables
 * (spec/apps/pqledger.md §4, §5): creating the instance, opening and
 * saving the PQCF tables, the in-memory `rules` and `budgets` tables and
 * the category-resolution SQL.
 *
 * The instance's data directory is the ledger directory, so the engine
 * paths are just "transactions.pqcf" etc.
 */
#include "app.inc"

    .section .note.GNU-stack, "", @progbits

    .section .rodata
t_int64:    .asciz "INT64"
t_string:   .asciz "STRING"
t_date:     .asciz "DATE"
t_dec:      .asciz "DECIMAL(18,2)"
c_id:       .asciz "id"
c_account:  .asciz "account"
c_date:     .asciz "date"
c_desc:     .asciz "description"
c_merchant: .asciz "merchant"
c_amount:   .asciz "amount"
c_batch:    .asciz "batch"
c_file:     .asciz "file"
c_imported: .asciz "imported"
c_dups:     .asciz "duplicates"
c_category: .asciz "category"
c_rule_no:  .asciz "rule_no"
c_pattern:  .asciz "pattern"
s_tx:       .asciz "transactions"
s_batches:  .asciz "batches"
s_overrides: .asciz "overrides"
s_rules:    .asciz "rules"
s_budgets:  .asciz "budgets"
s_txfile:   .asciz "transactions.pqcf"

/* explicit load schemas (pq_column_def arrays) of the ledger tables */
    .p2align 3
    .globl g_schema_transactions, g_schema_batches, g_schema_overrides
g_schema_transactions:
    .quad c_id, t_int64
    .quad c_account, t_string
    .quad c_date, t_date
    .quad c_desc, t_string
    .quad c_merchant, t_string
    .quad c_amount, t_dec
    .quad c_batch, t_int64
g_schema_batches:
    .quad c_batch, t_int64
    .quad c_account, t_string
    .quad c_file, t_string
    .quad c_imported, t_int64
    .quad c_dups, t_int64
g_schema_overrides:
    .quad c_id, t_int64
    .quad c_category, t_string
schema_rules:
    .quad c_rule_no, t_int64
    .quad c_category, t_string
    .quad c_pattern, t_string
schema_budgets:
    .quad c_category, t_string
    .quad c_amount, t_dec

/* the category resolution (§5.1) as common table expressions; `ledger` =
 * transactions + resolved category.  Patterns contain neither % nor _, so
 * mapping * -> % and ? -> _ gives an equivalent LIKE pattern; merchants and
 * patterns are both ASCII upper-cased, so LIKE's case sensitivity is right. */
s_cte:
    .ascii "WITH lm AS (SELECT DISTINCT merchant FROM transactions), "
    .ascii "lh AS (SELECT lm.merchant, MIN(r.rule_no) AS rn FROM lm JOIN rules r "
    .ascii "ON lm.merchant LIKE REPLACE(REPLACE(r.pattern, '*', '%'), '?', '_') "
    .ascii "GROUP BY lm.merchant), "
    .ascii "lc AS (SELECT lh.merchant, r.category FROM lh JOIN rules r ON r.rule_no = lh.rn), "
    .ascii "ledger AS (SELECT t.id, t.account, t.\"date\", t.description, t.merchant, "
    .ascii "t.amount, t.batch, COALESCE(o.category, lc.category, 'uncategorized') AS category "
    .ascii "FROM transactions t LEFT JOIN overrides o ON o.id = t.id "
    .asciz "LEFT JOIN lc ON lc.merchant = t.merchant) "

    .bss
    .p2align 3
    .globl g_db, g_qopts
g_db:       .quad 0                   /* pq_db* */
g_qopts:    .zero PQ_QOPT_SIZE        /* query options ([engine] threads) */
pqcfg:      .zero PQ_CONFIG_SIZE

    .text

/* ======================================================================
 * ledger_create(): creates the engine instance on the ledger directory
 * (which must exist); exit 7 on failure.
 * ====================================================================== */
FUNC ledger_create
    ENTER
    lea pqcfg(%rip), %rdi
    mov g_cfg_data_dir(%rip), %rax
    mov %rax, PQ_CONFIG_DATA_DIR(%rdi)
    mov g_cfg_memory_mb(%rip), %rax
    mov %rax, PQ_CONFIG_MAX_QUERY_MEM(%rdi)
    mov g_cfg_threads(%rip), %rax
    mov %rax, PQ_CONFIG_THREADS(%rdi)
    mov %rax, g_qopts+PQ_QOPT_THREADS(%rip)
    movq $-1, g_qopts+PQ_QOPT_MAX_ROWS(%rip)
    lea g_db(%rip), %rsi
    call pq_create
    test %eax, %eax
    jz 1f
    mov $EX_OTHER, %edi
    xor %esi, %esi
    call die_engine
1:  LEAVE
ENDF ledger_create

/* ledger_exists() -> eax 1 if <data_dir>/transactions.pqcf exists */
FUNC ledger_exists
    ENTER
    mov g_cfg_data_dir(%rip), %rdi
    lea s_txfile(%rip), %rsi
    call path_join
    mov %rax, %rbx
    mov %rax, %rdi
    xor %esi, %esi                    /* F_OK */
    call access
    mov %eax, %r12d
    mov %rbx, %rdi
    call free
    xor %eax, %eax
    test %r12d, %r12d
    sete %al
    LEAVE
ENDF ledger_exists

/* open_table(name rdi): pq_open(name, "<name>.pqcf"), exit 7 on error */
FUNC open_table
    ENTER 64
    mov %rdi, %rbx
    mov %rsp, %rdi
    mov $64, %esi
    CSTR %rdx, "%s.pqcf"
    mov %rbx, %rcx
    xor %eax, %eax
    call snprintf
    mov g_db(%rip), %rdi
    mov %rbx, %rsi
    mov %rsp, %rdx
    xor %ecx, %ecx
    call pq_open
    test %eax, %eax
    jz 1f
    mov $EX_OTHER, %edi
    mov g_db(%rip), %rsi
    call die_engine
1:  LEAVE
ENDF open_table

/* ======================================================================
 * ledger_open(): exit 6 without a ledger; creates the instance, opens
 * transactions, batches, overrides and loads the rules table (g_rules,
 * possibly empty).
 * ====================================================================== */
FUNC ledger_open
    ENTER
    call ledger_exists
    test %eax, %eax
    jnz 1f
    mov g_cfg_data_dir(%rip), %rdx
    DIE EX_LEDGER, "no ledger in %s (run 'pqledger init' first)"
1:  call ledger_create
    lea s_tx(%rip), %rdi
    call open_table
    lea s_batches(%rip), %rdi
    call open_table
    lea s_overrides(%rip), %rdi
    call open_table
    call ledger_load_rules
    LEAVE
ENDF ledger_open

/* ======================================================================
 * ledger_load_csv(table rdi, ABUF* rsi, schema rdx, ncols rcx)
 * Loads (replacing) `table` from CSV text without header; exit 7 on error.
 * ====================================================================== */
FUNC ledger_load_csv
    ENTER PQ_LOAD_SIZE
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rsp, %rdi
    mov %rdx, %r13
    mov %rcx, %r14
    xor %esi, %esi
    mov $PQ_LOAD_SIZE, %edx
    call memset
    movq $PQ_HEADER_NO, PQ_LOAD_HEADER(%rsp)
    movq $1, PQ_LOAD_REPLACE(%rsp)
    mov %r13, PQ_LOAD_SCHEMA(%rsp)
    mov %r14, PQ_LOAD_SCHEMA_LEN(%rsp)
    mov g_db(%rip), %rdi
    mov %rbx, %rsi
    mov AB_DATA(%r12), %rdx
    test %rdx, %rdx
    jnz 1f
    lea s_txfile+17(%rip), %rdx       /* "" */
1:  mov AB_LEN(%r12), %rcx
    mov %rsp, %r8
    xor %r9d, %r9d
    call pq_load_text
    test %eax, %eax
    jz 2f
    mov $EX_OTHER, %edi
    mov g_db(%rip), %rsi
    call die_engine
2:  LEAVE
ENDF ledger_load_csv

/* ledger_load_rules(): the `rules` table (rule_no, category, pattern) */
FUNC ledger_load_rules
    ENTER 32
    movq $0, 0(%rsp)                  /* ABUF */
    movq $0, 8(%rsp)
    movq $0, 16(%rsp)
    mov g_rules(%rip), %rbx
    mov g_rules_n(%rip), %r12
1:  test %r12, %r12
    jz 2f
    mov %rsp, %rdi
    mov RULE_NO(%rbx), %rsi
    call ab_put_i64
    mov %rsp, %rdi
    mov $',', %esi
    call ab_putc
    mov %rsp, %rdi
    mov RULE_CATEGORY(%rbx), %rsi
    call ab_put_csvstr
    mov %rsp, %rdi
    mov $',', %esi
    call ab_putc
    mov %rsp, %rdi
    mov RULE_PATTERN(%rbx), %rsi
    call ab_put_csvstr
    mov %rsp, %rdi
    mov $'\n', %esi
    call ab_putc
    add $RULE_SIZE, %rbx
    dec %r12
    jmp 1b
2:  lea s_rules(%rip), %rdi
    mov %rsp, %rsi
    lea schema_rules(%rip), %rdx
    mov $3, %ecx
    call ledger_load_csv
    mov %rsp, %rdi
    call ab_free
    LEAVE
ENDF ledger_load_rules

/* ledger_load_budgets(): the `budgets` table (category, amount) */
FUNC ledger_load_budgets
    ENTER 64
    movq $0, 0(%rsp)                  /* ABUF */
    movq $0, 8(%rsp)
    movq $0, 16(%rsp)
    mov g_budgets(%rip), %rbx
    mov g_budget_n(%rip), %r12
1:  test %r12, %r12
    jz 2f
    mov %rsp, %rdi
    mov BUD_CATEGORY(%rbx), %rsi
    call ab_put_csvstr
    mov BUD_CENTS(%rbx), %rax         /* ,UNITS.CC */
    xor %edx, %edx
    mov $100, %ecx
    div %rcx
    mov %rax, %rcx
    lea 32(%rsp), %rdi
    mov $32, %esi
    mov %rdx, %r8
    CSTR %rdx, ",%lu.%02lu\n"
    xor %eax, %eax
    call snprintf
    mov %rsp, %rdi
    lea 32(%rsp), %rsi
    call ab_puts
    add $BUD_SIZE, %rbx
    dec %r12
    jmp 1b
2:  lea s_budgets(%rip), %rdi
    mov %rsp, %rsi
    lea schema_budgets(%rip), %rdx
    mov $2, %ecx
    call ledger_load_csv
    mov %rsp, %rdi
    call ab_free
    LEAVE
ENDF ledger_load_budgets

/* ======================================================================
 * ledger_save(table rdi): saves the table to "<table>.pqcf"; exit 7 on
 * engine error.
 * ====================================================================== */
FUNC ledger_save
    ENTER 64
    mov %rdi, %rbx
    mov %rsp, %rdi
    mov $64, %esi
    CSTR %rdx, "%s.pqcf"
    mov %rbx, %rcx
    xor %eax, %eax
    call snprintf
    mov g_db(%rip), %rdi
    mov %rbx, %rsi
    mov %rsp, %rdx
    xor %ecx, %ecx
    call pq_save
    test %eax, %eax
    jz 1f
    mov $EX_OTHER, %edi
    mov g_db(%rip), %rsi
    call die_engine
1:  LEAVE
ENDF ledger_save

/* ======================================================================
 * ledger_query(sql rdi) -> rax pq_result*; exit 7 on engine error.
 * ledger_try_query(sql rdi) -> rax pq_result* or 0 (error in g_db).
 * ====================================================================== */
FUNC ledger_try_query
    ENTER 16
    mov %rdi, %rsi
    mov g_db(%rip), %rdi
    lea g_qopts(%rip), %rdx
    mov %rsp, %rcx
    movq $0, (%rsp)
    call pq_query
    test %eax, %eax
    jnz 1f
    mov (%rsp), %rax
    LEAVE
1:  xor %eax, %eax
    LEAVE
ENDF ledger_try_query

FUNC ledger_query
    ENTER
    call ledger_try_query
    test %rax, %rax
    jnz 1f
    mov $EX_OTHER, %edi
    mov g_db(%rip), %rsi
    call die_engine
1:  LEAVE
ENDF ledger_query

/* ledger_create_table(table rdi, sql rsi): replaces `table` with the
 * query's result; exit 7 on engine error */
FUNC ledger_create_table
    ENTER
    mov %rsi, %rdx
    mov %rdi, %rsi
    mov g_db(%rip), %rdi
    lea g_qopts(%rip), %rcx
    mov $1, %r8d
    xor %r9d, %r9d
    call pq_create_table
    test %eax, %eax
    jz 1f
    mov $EX_OTHER, %edi
    mov g_db(%rip), %rsi
    call die_engine
1:  LEAVE
ENDF ledger_create_table

/* ledger_cte(ab rdi): appends "WITH ..., ledger AS (...) " */
FUNC ledger_cte
    ENTER
    lea s_cte(%rip), %rsi
    call ab_puts
    LEAVE
ENDF ledger_cte
