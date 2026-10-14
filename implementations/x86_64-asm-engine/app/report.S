/*
 * report.S - the pqledger commands except import (spec/apps/pqledger.md
 * §6.1, §8, §9, §10): init, report monthly|categories|merchants, budget,
 * accounts, list, export, set-category, query, help, version.
 *
 * Every command builds its SQL in an ABUF, lets the engine do all the
 * filtering / joining / aggregation / sorting / category resolution, and
 * renders the result with out_result (output.S) into g_out.  The only
 * host-side computation is the `share` column of report categories.
 * Each cmd_* returns its exit status in eax.
 */
#include "app.inc"

    .section .note.GNU-stack, "", @progbits

    .section .rodata
s_tx:       .asciz "transactions"
s_batches:  .asciz "batches"
s_overrides: .asciz "overrides"
s_ledger:   .asciz "ledger"
s_share:    .asciz "share"
s_dec181:   .asciz "DECIMAL(18,1)"
s_over:     .asciz "over"

/* filters */
f_from:     .asciz " AND \"date\" >= DATE '"
f_to:       .asciz " AND \"date\" <= DATE '"
f_account:  .asciz " AND account = "
f_category: .asciz " AND category = "

q_monthly:
    .ascii "SELECT SUBSTR(CAST(\"date\" AS STRING), 1, 7) AS month, "
    .ascii "CAST(COALESCE(SUM(CASE WHEN amount > 0 THEN amount END), 0) AS DECIMAL(18,2)) AS income, "
    .ascii "CAST(COALESCE(-SUM(CASE WHEN amount < 0 THEN amount END), 0) AS DECIMAL(18,2)) AS expenses, "
    .ascii "CAST(SUM(amount) AS DECIMAL(18,2)) AS net, COUNT(*) AS transactions "
    .asciz "FROM transactions WHERE 1 = 1"
q_monthly_end:
    .asciz " GROUP BY SUBSTR(CAST(\"date\" AS STRING), 1, 7) ORDER BY month"
q_categories:
    .ascii "SELECT category, CAST(-SUM(amount) AS DECIMAL(18,2)) AS spent, "
    .asciz "COUNT(*) AS transactions FROM ledger WHERE amount < 0"
q_categories_end:
    .asciz " GROUP BY category ORDER BY spent DESC, category"
q_merchants:
    .ascii "SELECT merchant, CAST(-SUM(amount) AS DECIMAL(18,2)) AS spent, "
    .asciz "COUNT(*) AS transactions FROM transactions WHERE amount < 0"
q_merchants_end:
    .asciz " GROUP BY merchant ORDER BY spent DESC, merchant LIMIT "
q_budget:
    .asciz ", sp AS (SELECT category, -SUM(amount) AS spent FROM ledger WHERE amount < 0"
q_budget_end:
    .ascii " GROUP BY category) SELECT b.category, CAST(b.amount AS DECIMAL(18,2)) AS budget, "
    .ascii "CAST(COALESCE(sp.spent, 0) AS DECIMAL(18,2)) AS spent, "
    .ascii "CAST(b.amount - COALESCE(sp.spent, 0) AS DECIMAL(18,2)) AS remaining, "
    .ascii "CASE WHEN COALESCE(sp.spent, 0) <= b.amount THEN 'ok' ELSE 'over' END AS status "
    .asciz "FROM budgets b LEFT JOIN sp ON sp.category = b.category ORDER BY b.category"
q_accounts:
    .ascii "SELECT account, COUNT(*) AS transactions, CAST(SUM(amount) AS DECIMAL(18,2)) AS balance, "
    .ascii "MIN(\"date\") AS \"first\", MAX(\"date\") AS \"last\" FROM transactions "
    .asciz "GROUP BY account ORDER BY account"
q_list:
    .ascii "SELECT id, \"date\", account, description, amount, category "
    .asciz "FROM ledger WHERE 1 = 1"
q_list_end:
    .asciz " ORDER BY \"date\", id"
q_export:
    .ascii "SELECT id, account, \"date\", description, merchant, amount, category, batch "
    .asciz "FROM ledger WHERE 1 = 1"
q_export_end:
    .asciz " ORDER BY id"
q_ledger_all:
    .asciz "SELECT * FROM ledger ORDER BY id"
q_id_exists:
    .asciz "SELECT COUNT(*) AS n FROM transactions WHERE id = "
q_ovr_keep:
    .asciz "SELECT id, category FROM overrides WHERE id <> "
q_ovr_add:
    .asciz " UNION ALL SELECT "
q_order_id:
    .asciz " ORDER BY id"

days_in_month: .byte 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31

help_text:
    .ascii "usage: pqledger [--config PATH] [--format table|csv|json] COMMAND [ARGS]\n"
    .ascii "\n"
    .ascii "commands:\n"
    .ascii "  init                                  create an empty ledger in data_dir\n"
    .ascii "  import FILE --account NAME            import a bank CSV export\n"
    .ascii "  report monthly [FILTERS]              income, expenses and net per month\n"
    .ascii "  report categories [FILTERS]           spending per category with share\n"
    .ascii "  report merchants [FILTERS] [--top N]  top merchants by spending (default 10)\n"
    .ascii "  budget --month M [--account NAME]     budget status of one month (exit 3 if over)\n"
    .ascii "  accounts                              transactions, balance and date range per account\n"
    .ascii "  list [FILTERS] [--category C | --uncategorized]\n"
    .ascii "                                        list transactions\n"
    .ascii "  export [FILTERS]                      every column of the transactions\n"
    .ascii "  set-category ID CATEGORY              override the category of a transaction\n"
    .ascii "  set-category ID --clear               remove the override\n"
    .ascii "  query SQL                             run SQL on transactions, batches, overrides,\n"
    .ascii "                                        ledger, rules and budgets\n"
    .ascii "  help                                  this text\n"
    .ascii "  version                               print the version\n"
    .ascii "\n"
    .ascii "filters: --month YYYY-MM | --from YYYY-MM | --to YYYY-MM, --account NAME\n"
    .ascii "configuration: --config PATH, else $PQLEDGER_CONFIG, else ./pqledger.conf\n"
    .ascii "\n"
    .ascii "exit status: 0 ok, 1 usage, 2 configuration, 3 over budget, 4 import data,\n"
    .asciz "             5 query error, 6 ledger state, 7 other error\n"

    .text

/* ======================================================================
 * SQL building helpers
 * ====================================================================== */

/* append_date(ab rdi, month rsi, last edx): appends "YYYY-MM-DD'" with
 * DD = 01 (last = 0) or the month's last day (last = 1) */
FUNC append_date
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %edx, %r13d
    mov %rbx, %rdi
    mov %r12, %rsi
    mov $7, %edx
    call ab_put
    mov $1, %r14d                     /* day */
    test %r13d, %r13d
    jz 2f
    mov %r12, %rdi                    /* month number */
    add $5, %rdi
    xor %esi, %esi
    mov $10, %edx
    call strtol
    lea days_in_month(%rip), %rcx
    movzbl -1(%rcx,%rax), %r14d
    cmp $2, %eax
    jne 2f
    mov %r12, %rdi                    /* February: leap year? */
    xor %esi, %esi
    mov $10, %edx
    call strtol
    mov %rax, %rcx
    xor %edx, %edx
    mov $400, %r8d
    div %r8
    test %rdx, %rdx
    jz 1f
    mov %rcx, %rax
    xor %edx, %edx
    mov $100, %r8d
    div %r8
    test %rdx, %rdx
    jz 2f
    test $3, %ecx
    jnz 2f
1:  mov $29, %r14d
2:  mov %rbx, %rdi
    mov $'-', %esi
    call ab_putc
    mov %r14d, %eax                   /* two digits */
    xor %edx, %edx
    mov $10, %ecx
    div %ecx
    mov %edx, %r14d
    lea '0'(%rax), %esi
    mov %rbx, %rdi
    call ab_putc
    lea '0'(%r14), %esi
    mov %rbx, %rdi
    call ab_putc
    mov %rbx, %rdi
    mov $'\'', %esi
    call ab_putc
    LEAVE
ENDF append_date

/* append_filters(ab rdi): " AND ..." for --month / --from / --to /
 * --account (date ranges on the DATE column) */
FUNC append_filters
    ENTER
    mov %rdi, %rbx
    mov g_opt_month(%rip), %r12
    test %r12, %r12
    jz 1f
    mov %r12, g_opt_from(%rip)        /* --month M = --from M --to M */
    mov %r12, g_opt_to(%rip)
1:  mov g_opt_from(%rip), %r12
    test %r12, %r12
    jz 2f
    mov %rbx, %rdi
    lea f_from(%rip), %rsi
    call ab_puts
    mov %rbx, %rdi
    mov %r12, %rsi
    xor %edx, %edx
    call append_date
2:  mov g_opt_to(%rip), %r12
    test %r12, %r12
    jz 3f
    mov %rbx, %rdi
    lea f_to(%rip), %rsi
    call ab_puts
    mov %rbx, %rdi
    mov %r12, %rsi
    mov $1, %edx
    call append_date
3:  mov g_opt_account(%rip), %r12
    test %r12, %r12
    jz 4f
    mov %rbx, %rdi
    lea f_account(%rip), %rsi
    call ab_puts
    mov %rbx, %rdi
    mov %r12, %rsi
    call ab_put_sqlstr
4:  LEAVE
ENDF append_filters

/* run_and_print(ab rdi) -> rax result: runs the SQL in the ABUF (exit 7
 * on engine errors) and renders the result into g_out */
FUNC run_and_print
    ENTER
    mov AB_DATA(%rdi), %rdi
    call ledger_query
    mov %rax, %rbx
    mov %rax, %rdi
    call out_result
    mov %rbx, %rax
    LEAVE
ENDF run_and_print

/* ======================================================================
 * init (§6.1)
 * ====================================================================== */

/* mkdir_p(path rdi): creates the directory and its missing parents;
 * exit 7 on failure */
FUNC mkdir_p
    ENTER
    call xstrdup
    mov %rax, %rbx
    lea 1(%rbx), %r12                 /* skip a leading '/' */
1:  mov %r12, %rdi
    mov $'/', %esi
    call strchr
    test %rax, %rax
    jz 2f
    mov %rax, %r12
    movb $0, (%r12)
    mov %rbx, %rdi
    mov $0777, %esi
    call mkdir
    movb $'/', (%r12)
    inc %r12
    jmp 1b
2:  mov %rbx, %rdi
    mov $0777, %esi
    call mkdir
    test %eax, %eax
    jz 9f
    call __errno_location
    cmpl $17, (%rax)                  /* EEXIST */
    je 9f
    mov (%rax), %edi
    call strerror
    mov %rax, %rcx
    mov %rbx, %rdx
    DIE EX_OTHER, "cannot create directory %s: %s"
9:  LEAVE
ENDF mkdir_p

FUNC cmd_init
    ENTER 32
    call ledger_exists
    test %eax, %eax
    jz 1f
    mov g_cfg_data_dir(%rip), %rdx
    DIE EX_LEDGER, "a ledger already exists in %s"
1:  mov g_cfg_data_dir(%rip), %rdi
    call mkdir_p
    call ledger_create
    movq $0, 0(%rsp)                  /* empty ABUF: zero rows */
    movq $0, 8(%rsp)
    movq $0, 16(%rsp)
    lea s_overrides(%rip), %rdi
    mov %rsp, %rsi
    lea g_schema_overrides(%rip), %rdx
    mov $2, %ecx
    call ledger_load_csv
    lea s_batches(%rip), %rdi
    mov %rsp, %rsi
    lea g_schema_batches(%rip), %rdx
    mov $5, %ecx
    call ledger_load_csv
    lea s_tx(%rip), %rdi
    mov %rsp, %rsi
    lea g_schema_transactions(%rip), %rdx
    mov $7, %ecx
    call ledger_load_csv
    lea s_overrides(%rip), %rdi       /* transactions.pqcf last: it marks */
    call ledger_save                  /* the ledger as existing */
    lea s_batches(%rip), %rdi
    call ledger_save
    lea s_tx(%rip), %rdi
    call ledger_save
    lea g_out(%rip), %rbx
    APUTS %rbx, "initialized ledger\n"
    xor %eax, %eax
    LEAVE
ENDF cmd_init

/* ======================================================================
 * report monthly | categories | merchants (§9.1-9.3)
 * ====================================================================== */
FUNC cmd_report
    ENTER 32
    call ledger_open
    mov %rsp, %rdi
    call ab_init
    mov g_report_kind(%rip), %rax
    cmp $1, %rax
    je r_categories
    cmp $2, %rax
    je r_merchants
    /* monthly: no category needed, straight from transactions */
    mov %rsp, %rdi
    lea q_monthly(%rip), %rsi
    call ab_puts
    mov %rsp, %rdi
    call append_filters
    mov %rsp, %rdi
    lea q_monthly_end(%rip), %rsi
    call ab_puts
    mov %rsp, %rdi
    call run_and_print
    xor %eax, %eax
    LEAVE
r_merchants:
    mov %rsp, %rdi
    lea q_merchants(%rip), %rsi
    call ab_puts
    mov %rsp, %rdi
    call append_filters
    mov %rsp, %rdi
    lea q_merchants_end(%rip), %rsi
    call ab_puts
    mov %rsp, %rdi
    mov g_opt_top(%rip), %rsi
    call ab_put_i64
    mov %rsp, %rdi
    call run_and_print
    xor %eax, %eax
    LEAVE
r_categories:
    mov %rsp, %rdi
    call ledger_cte
    mov %rsp, %rdi
    lea q_categories(%rip), %rsi
    call ab_puts
    mov %rsp, %rdi
    call append_filters
    mov %rsp, %rdi
    lea q_categories_end(%rip), %rsi
    call ab_puts
    mov 0(%rsp), %rdi
    call ledger_query
    mov %rax, %rdi
    call add_share_column
    mov %rax, %rdi
    call out_result
    xor %eax, %eax
    LEAVE
ENDF cmd_report

/* add_share_column(res rdi) -> rax new result
 * res has columns category, spent DECIMAL(18,2), transactions; the new
 * result (one malloc'd block, sharing the strings of res, which must stay
 * alive) has category, spent, share DECIMAL(18,1), transactions with
 * share = 100 * spent / total rounded half away from zero to 0.1,
 * computed exactly in integers: tenths = round(1000 * spent / total). */
FUNC add_share_column
    ENTER
    mov %rdi, %rbx                    /* old result */
    mov PQ_RES_NROWS(%rbx), %r12      /* rows */
    imul $4*PQ_VAL_SIZE, %r12, %rdi
    add $PQ_RES_SIZE + 4*PQ_COL_SIZE, %rdi
    call xmalloc
    mov %rax, %r13                    /* new result */
    movq $4, PQ_RES_NCOLS(%r13)
    lea PQ_RES_SIZE(%r13), %rax
    mov %rax, PQ_RES_COLUMNS(%r13)
    mov %r12, PQ_RES_NROWS(%r13)
    lea PQ_RES_SIZE + 4*PQ_COL_SIZE(%r13), %rax
    mov %rax, PQ_RES_VALUES(%r13)
    /* columns 0, 1 and 3 copied, 2 = share */
    mov PQ_RES_COLUMNS(%rbx), %rsi
    mov PQ_RES_COLUMNS(%r13), %rdi
    mov $2*PQ_COL_SIZE, %edx
    call memcpy
    mov PQ_RES_COLUMNS(%rbx), %rsi
    add $2*PQ_COL_SIZE, %rsi
    mov PQ_RES_COLUMNS(%r13), %rdi
    add $3*PQ_COL_SIZE, %rdi
    mov $PQ_COL_SIZE, %edx
    call memcpy
    mov PQ_RES_COLUMNS(%r13), %rdi
    add $2*PQ_COL_SIZE, %rdi
    lea s_share(%rip), %rax
    mov %rax, PQ_COL_NAME(%rdi)
    lea s_dec181(%rip), %rax
    mov %rax, PQ_COL_TYPE_NAME(%rdi)
    movl $PQ_TYPE_DECIMAL, PQ_COL_TYPE(%rdi)
    movl $18, PQ_COL_PRECISION(%rdi)
    movl $1, PQ_COL_SCALE(%rdi)
    movl $0, 28(%rdi)
    /* total spent (128-bit) in r8:r9 (lo:hi) */
    xor %r8d, %r8d
    xor %r9d, %r9d
    mov PQ_RES_VALUES(%rbx), %rsi
    mov %r12, %rcx
1:  test %rcx, %rcx
    jz 2f
    add PQ_VAL_SIZE+PQ_VAL_DEC_LO(%rsi), %r8
    adc PQ_VAL_SIZE+PQ_VAL_DEC_HI(%rsi), %r9
    add $3*PQ_VAL_SIZE, %rsi
    dec %rcx
    jmp 1b
2:  /* if the total exceeds 64 bits, scale everything down (never happens
     * with DECIMAL(18,2) sums in practice) */
    xor %r15d, %r15d                  /* shift */
    test %r9, %r9
    jz 3f
    bsr %r9, %r15
    inc %r15
    mov %r15d, %ecx
    shrd %cl, %r9, %r8
3:  mov %r8, %r14                     /* total */
    mov PQ_RES_VALUES(%rbx), %rsi
    mov PQ_RES_VALUES(%r13), %rdi
    mov %r12, %r10
4:  test %r10, %r10
    jz 9f
    movdqu 0(%rsi), %xmm0             /* category */
    movdqu %xmm0, 0(%rdi)
    mov 16(%rsi), %rax
    mov %rax, 16(%rdi)
    movdqu PQ_VAL_SIZE(%rsi), %xmm0   /* spent */
    movdqu %xmm0, PQ_VAL_SIZE(%rdi)
    mov PQ_VAL_SIZE+16(%rsi), %rax
    mov %rax, PQ_VAL_SIZE+16(%rdi)
    movdqu 2*PQ_VAL_SIZE(%rsi), %xmm0 /* transactions -> column 3 */
    movdqu %xmm0, 3*PQ_VAL_SIZE(%rdi)
    mov 2*PQ_VAL_SIZE+16(%rsi), %rax
    mov %rax, 3*PQ_VAL_SIZE+16(%rdi)
    /* share */
    mov PQ_VAL_SIZE+PQ_VAL_DEC_LO(%rsi), %rax
    mov PQ_VAL_SIZE+PQ_VAL_DEC_HI(%rsi), %rdx
    mov %r15d, %ecx
    test %ecx, %ecx
    jz 5f
    shrd %cl, %rdx, %rax
5:  mov $1000, %r11d
    mul %r11                          /* rdx:rax = 1000 * spent */
    xor %r11d, %r11d
    test %r14, %r14
    jz 6f
    div %r14                          /* rax = quotient, rdx = remainder */
    mov %r14, %r11
    sub %rdx, %r11                    /* total - remainder */
    cmp %r11, %rdx                    /* 2 * rem >= total: round up */
    jb 7f
    inc %rax
7:  mov %rax, %r11
6:  mov %r11, 2*PQ_VAL_SIZE+PQ_VAL_DEC_LO(%rdi)
    movq $0, 2*PQ_VAL_SIZE+PQ_VAL_DEC_HI(%rdi)
    movq $0, 2*PQ_VAL_SIZE+PQ_VAL_IS_NULL(%rdi)
    add $3*PQ_VAL_SIZE, %rsi
    add $4*PQ_VAL_SIZE, %rdi
    dec %r10
    jmp 4b
9:  mov %r13, %rax
    LEAVE
ENDF add_share_column

/* ======================================================================
 * budget --month M [--account NAME] (§9.4) -> 0, or 3 if a row is over
 * ====================================================================== */
FUNC cmd_budget
    ENTER 32
    cmpq $0, g_cfg_budget_file(%rip)
    jne 1f
    mov g_cfg_path(%rip), %rdx
    DIE EX_CONFIG, "%s: budget needs a budget_file in [ledger]"
1:  call ledger_open
    call ledger_load_budgets
    mov %rsp, %rdi
    call ab_init
    mov %rsp, %rdi
    call ledger_cte
    mov %rsp, %rdi
    lea q_budget(%rip), %rsi
    call ab_puts
    mov %rsp, %rdi
    call append_filters
    mov %rsp, %rdi
    lea q_budget_end(%rip), %rsi
    call ab_puts
    mov %rsp, %rdi
    call run_and_print
    /* exit 3 if any status (column 4) is "over" */
    mov PQ_RES_NROWS(%rax), %r12
    mov PQ_RES_VALUES(%rax), %rbx
    add $4*PQ_VAL_SIZE, %rbx
    xor %r13d, %r13d
2:  test %r12, %r12
    jz 3f
    mov PQ_VAL_STR_PTR(%rbx), %rdi
    lea s_over(%rip), %rsi
    call strcmp
    test %eax, %eax
    jnz 4f
    mov $EX_OVER, %r13d
4:  add $5*PQ_VAL_SIZE, %rbx
    dec %r12
    jmp 2b
3:  mov %r13d, %eax
    LEAVE
ENDF cmd_budget

/* ======================================================================
 * accounts (§8.4), list (§8.1), export (§8.2)
 * ====================================================================== */
FUNC cmd_accounts
    ENTER 32
    call ledger_open
    mov %rsp, %rdi
    call ab_init
    mov %rsp, %rdi
    lea q_accounts(%rip), %rsi
    call ab_puts
    mov %rsp, %rdi
    call run_and_print
    xor %eax, %eax
    LEAVE
ENDF cmd_accounts

FUNC cmd_list
    ENTER 32
    call ledger_open
    mov %rsp, %rdi
    call ab_init
    mov %rsp, %rdi
    call ledger_cte
    mov %rsp, %rdi
    lea q_list(%rip), %rsi
    call ab_puts
    mov %rsp, %rdi
    call append_filters
    mov g_opt_category(%rip), %rbx
    cmpq $0, g_opt_uncat(%rip)
    je 1f
    CSTR %rbx, "uncategorized"
1:  test %rbx, %rbx
    jz 2f
    mov %rsp, %rdi
    lea f_category(%rip), %rsi
    call ab_puts
    mov %rsp, %rdi
    mov %rbx, %rsi
    call ab_put_sqlstr
2:  mov %rsp, %rdi
    lea q_list_end(%rip), %rsi
    call ab_puts
    mov %rsp, %rdi
    call run_and_print
    xor %eax, %eax
    LEAVE
ENDF cmd_list

FUNC cmd_export
    ENTER 32
    call ledger_open
    mov %rsp, %rdi
    call ab_init
    mov %rsp, %rdi
    call ledger_cte
    mov %rsp, %rdi
    lea q_export(%rip), %rsi
    call ab_puts
    mov %rsp, %rdi
    call append_filters
    mov %rsp, %rdi
    lea q_export_end(%rip), %rsi
    call ab_puts
    mov %rsp, %rdi
    call run_and_print
    xor %eax, %eax
    LEAVE
ENDF cmd_export

/* ======================================================================
 * set-category ID (CATEGORY | --clear) (§8.3)
 * ====================================================================== */
FUNC cmd_set_category
    ENTER 32
    call ledger_open
    mov %rsp, %rdi
    call ab_init
    /* the id must exist */
    mov %rsp, %rdi
    lea q_id_exists(%rip), %rsi
    call ab_puts
    mov %rsp, %rdi
    mov g_setcat_id(%rip), %rsi
    call ab_put_i64
    mov 0(%rsp), %rdi
    call ledger_query
    mov PQ_RES_VALUES(%rax), %rax
    cmpq $0, PQ_VAL_I64(%rax)
    jne 1f
    mov g_setcat_id(%rip), %rdx
    DIE EX_LEDGER, "unknown transaction id %ld"
1:  /* overrides := the other rows [+ (ID, CATEGORY)], ordered by id */
    mov %rsp, %rdi
    call ab_clear
    mov %rsp, %rdi
    lea q_ovr_keep(%rip), %rsi
    call ab_puts
    mov %rsp, %rdi
    mov g_setcat_id(%rip), %rsi
    call ab_put_i64
    cmpq $0, g_opt_clear(%rip)
    jne 2f
    mov %rsp, %rdi
    lea q_ovr_add(%rip), %rsi
    call ab_puts
    mov %rsp, %rdi
    mov g_setcat_id(%rip), %rsi
    call ab_put_i64
    mov %rsp, %rdi
    mov $',', %esi
    call ab_putc
    mov %rsp, %rdi
    mov g_pos+8(%rip), %rsi
    call ab_put_sqlstr
2:  mov %rsp, %rdi
    lea q_order_id(%rip), %rsi
    call ab_puts
    lea s_overrides(%rip), %rdi
    mov 0(%rsp), %rsi
    call ledger_create_table
    lea s_overrides(%rip), %rdi
    call ledger_save
    /* "transaction ID: category CATEGORY|cleared" */
    lea g_out(%rip), %rbx
    APUTS %rbx, "transaction "
    mov %rbx, %rdi
    mov g_setcat_id(%rip), %rsi
    call ab_put_i64
    APUTS %rbx, ": category "
    mov g_pos+8(%rip), %rsi
    cmpq $0, g_opt_clear(%rip)
    je 3f
    CSTR %rsi, "cleared"
3:  mov %rbx, %rdi
    call ab_puts
    mov %rbx, %rdi
    mov $'\n', %esi
    call ab_putc
    xor %eax, %eax
    LEAVE
ENDF cmd_set_category

/* ======================================================================
 * query SQL (§9.5): engine errors exit 5 with "CODE: MESSAGE"
 * ====================================================================== */
FUNC cmd_query
    ENTER 32
    call ledger_open
    call ledger_load_budgets
    mov %rsp, %rdi
    call ab_init
    mov %rsp, %rdi
    call ledger_cte
    mov %rsp, %rdi
    lea q_ledger_all(%rip), %rsi
    call ab_puts
    lea s_ledger(%rip), %rdi
    mov 0(%rsp), %rsi
    call ledger_create_table
    mov g_pos(%rip), %rdi
    call ledger_try_query
    test %rax, %rax
    jnz 1f
    mov $EX_QUERY, %edi
    mov g_db(%rip), %rsi
    call die_engine
1:  mov %rax, %rdi
    call out_result
    xor %eax, %eax
    LEAVE
ENDF cmd_query

/* ======================================================================
 * help, version (§10)
 * ====================================================================== */
FUNC cmd_help
    ENTER
    lea g_out(%rip), %rdi
    lea help_text(%rip), %rsi
    call ab_puts
    xor %eax, %eax
    LEAVE
ENDF cmd_help

FUNC cmd_version
    ENTER
    lea g_out(%rip), %rbx
    APUTS %rbx, "pqledger 1.0.0 (engine "
    call pq_version
    mov %rbx, %rdi
    mov %rax, %rsi
    call ab_puts
    APUTS %rbx, ")\n"
    xor %eax, %eax
    LEAVE
ENDF cmd_version
