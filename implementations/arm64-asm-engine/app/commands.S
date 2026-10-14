// =============================================================================
// commands.S — the pqledger commands (spec/apps/pqledger.md §4-§9).
//
// Every command (except init) opens the ledger in an embedded engine
// instance: the three PQCF files become the tables transactions, batches and
// overrides; the rules file becomes the table rules (rule_no, category,
// pattern) and, for budget / query, the budget file the table budgets.
// Reports, lists, budgets and category resolution are SQL statements run
// by the engine; category resolution is the common table expression
// CTE_CATEGORIES:
//   pql_m  first matching rule (MIN rule_no) per distinct merchant, the
//          rule's `*` / `?` turned into LIKE's `%` / `_`
//   pql_c  merchant -> category of that rule
//   pql_l  transactions + resolved category (override, else rule, else
//          'uncategorized')
// The host program converts bank records, decides duplicates (with the
// help of one SQL statement), formats output and computes `share`.
//
// Updates build the new table with pq_query_into (old rows UNION ALL new
// rows) and write it with pq_save (atomic rename), so a failing command
// leaves the ledger unchanged.
//
//   cmd_*() -> w0 exit status (0, or 3 for an over-budget `budget`);
//   output is appended to g_out (main.S). ledger_close() ends the engine.
// =============================================================================
#include "ledger.inc"

#define LO_BUDGET_REQ   1           // ledger_open: budget file required
#define LO_BUDGET_OPT   2           // ledger_open: budgets if configured

// S "text": append constant SQL text to g_sql
.macro S text
    ADR_L x0, g_sql
    adr  x1, .Ls_str\@
    bl   buf_puts
    b    .Ls_end\@
.Ls_str\@: .asciz "\text"
    .p2align 2
.Ls_end\@:
.endm

    .bss
    .p2align 3
g_db:       .skip 8                 // pq_db* (0 until ledger_open / init)
g_rules:    .skip 8                 // RULE* / count (rules file)
g_nrules:   .skip 8
g_buds:     .skip 8                 // BUD* / count (budget file)
g_nbuds:    .skip 8
g_sql:      .skip BUF_SIZE          // SQL text being built
g_tmp:      .skip BUF_SIZE          // CSV text for pq_load_text
g_qopts:    .skip PQQO_SIZE         // query options ([engine] threads)

    .section .rodata
t_int:      .asciz "INT64"
t_str:      .asciz "STRING"
t_date:     .asciz "DATE"
t_dec:      .asciz "DECIMAL(18,2)"
t_dec1:     .asciz "DECIMAL(18,1)"
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
c_seq:      .asciz "seq"
c_share:    .asciz "share"
n_tx:       .asciz "transactions"
n_batches:  .asciz "batches"
n_overrides: .asciz "overrides"
n_rules:    .asciz "rules"
n_budgets:  .asciz "budgets"
n_ledger:   .asciz "ledger"
n_in:       .asciz "pql_in"
n_new:      .asciz "pql_new"
f_tx:       .asciz "transactions.pqcf"
f_batches:  .asciz "batches.pqcf"
f_overrides: .asciz "overrides.pqcf"
h_tx:       .asciz "id,account,date,description,merchant,amount,batch\n"
h_batches:  .asciz "batch,account,file,imported,duplicates\n"
h_overrides: .asciz "id,category\n"
h_rules:    .asciz "rule_no,category,pattern\n"
h_budgets:  .asciz "category,amount\n"
h_in:       .asciz "seq,date,amount,merchant\n"
s_txfile:   .asciz "/transactions.pqcf"
s_over:     .asciz "over"
m_engine:   .asciz "%s: %s"
m_start:    .asciz "cannot start the engine: %s: %s"
m_noledger: .asciz "no ledger in %s (run 'pqledger init' first)"
m_exists:   .asciz "a ledger already exists in %s"
m_mkdir:    .asciz "cannot create the data directory %s"
m_nobudget: .asciz "no budget_file configured"
m_unknown:  .asciz "unknown transaction id %s"
o_init:     .asciz "initialized ledger\n"
o_batch:    .asciz "batch "
o_imported: .asciz ": imported "
o_dups:     .asciz ", duplicates "
o_trans:    .asciz "transaction "
o_category: .asciz ": category "
o_cleared:  .asciz ": category cleared\n"

    .data
    .p2align 3
// explicit schemas for pq_load_text (pq_coldef arrays + pq_load_opts)
cd_tx:      .quad c_id, t_int, c_account, t_str, c_date, t_date, c_desc, t_str
            .quad c_merchant, t_str, c_amount, t_dec, c_batch, t_int
cd_batches: .quad c_batch, t_int, c_account, t_str, c_file, t_str
            .quad c_imported, t_int, c_dups, t_int
cd_over:    .quad c_id, t_int, c_category, t_str
cd_rules:   .quad c_rule_no, t_int, c_category, t_str, c_pattern, t_str
cd_budgets: .quad c_category, t_str, c_amount, t_dec
cd_in:      .quad c_seq, t_int, c_date, t_date, c_amount, t_dec, c_merchant, t_str
lo_tx:      .quad cd_tx, 7, 0, 0
lo_batches: .quad cd_batches, 5, 0, 0
lo_over:    .quad cd_over, 2, 0, 0
lo_rules:   .quad cd_rules, 3, 0, 0
lo_budgets: .quad cd_budgets, 2, 0, 0
lo_in:      .quad cd_in, 4, 0, 0
// the ledger's tables: name, file, header, load options
ledger_tables:
    .quad n_batches, f_batches, h_batches, lo_batches
    .quad n_overrides, f_overrides, h_overrides, lo_over
    .quad n_tx, f_tx, h_tx, lo_tx
    .quad 0, 0, 0, 0
    .text

// =============================================================================
// Engine helpers
// =============================================================================

// eng_fail(w0 exit status): the engine reported an error => exit
LFUNC eng_fail
    ENTER 2
    mov  w19, w0
    LDR_G x0, g_db
    bl   pq_errname
    mov  x20, x0
    LDR_G x0, g_db
    bl   pq_errmsg
    mov  x3, x0
    mov  x2, x20
    mov  w0, w19
    ADR_L x1, m_engine
    bl   fail
ENDF eng_fail

// check(w0 status): exit 7 on an engine error
LFUNC check
    cbnz w0, 1f
    ret
1:  mov  w0, #EX_OTHER
    b    eng_fail
ENDF check

// engine_start(): the embedded engine on data_dir with the [engine] settings
//   sp: pq_config
LFUNC engine_start
    ENTER 0
    sub  sp, sp, #64
    stp  xzr, xzr, [sp]
    stp  xzr, xzr, [sp, #16]
    stp  xzr, xzr, [sp, #32]
    stp  xzr, xzr, [sp, #48]
    LDR_G x9, g_cfg_data_dir
    str  x9, [sp, #PQCFG_DATA_DIR]
    LDR_G x9, g_cfg_memory_mb
    str  x9, [sp, #PQCFG_QUERY_MEM_MB]
    LDR_G x9, g_cfg_threads
    str  x9, [sp, #PQCFG_THREADS]
    ADR_L x10, g_qopts              // also the query option (spec §3.3)
    str  x9, [x10, #PQQO_THREADS]
    mov  x0, sp
    ADR_L x1, g_db
    bl   pq_create
    cbz  w0, 1f
    mov  x0, #0
    bl   pq_errname
    stp  x0, xzr, [sp]
    mov  x0, #0
    bl   pq_errmsg
    mov  x3, x0
    ldr  x2, [sp]
    mov  w0, #EX_OTHER
    ADR_L x1, m_start
    bl   fail
1:  add  sp, sp, #64
    LEAVE 0
ENDF engine_start

// ledger_close(): end the engine instance (if any)
FUNC ledger_close
    ENTER 0
    LDR_G x0, g_db
    cbz  x0, 1f
    bl   pq_close
    ADR_L x9, g_db
    str  xzr, [x9]
1:  LEAVE 0
ENDF ledger_close

// sql_reset(): empty g_sql
LFUNC sql_reset
    ADR_L x9, g_sql
    str  xzr, [x9, #BUF_LEN]
    ret
ENDF sql_reset

// run_sql() -> x0 pq_result* of g_sql (exit 7 on an engine error)
LFUNC run_sql
    ENTER 0
    sub  sp, sp, #16
    ADR_L x0, g_sql
    bl   buf_cstr
    mov  x1, x0
    LDR_G x0, g_db
    ADR_L x2, g_qopts
    mov  x3, sp
    bl   pq_query
    bl   check
    ldr  x0, [sp]
    add  sp, sp, #16
    LEAVE 0
ENDF run_sql

// run_sql_into(x0 table): replace the table by the result of g_sql
LFUNC run_sql_into
    ENTER 1
    mov  x19, x0
    ADR_L x0, g_sql
    bl   buf_cstr
    mov  x2, x0
    LDR_G x0, g_db
    mov  x1, x19
    ADR_L x3, g_qopts
    mov  w4, #1
    bl   pq_query_into
    bl   check
    LEAVE 1
ENDF run_sql_into

// load_tmp(x0 table, x1 pq_load_opts*): load the CSV text in g_tmp
LFUNC load_tmp
    ENTER 1
    mov  x19, x1
    mov  x1, x0
    ADR_L x9, g_tmp
    ldr  x2, [x9, #BUF_PTR]
    ldr  x3, [x9, #BUF_LEN]
    LDR_G x0, g_db
    mov  x4, x19
    orr  x9, x2, x3
    cbnz x9, 1f
    ADR_L x2, h_in                  // never NULL (empty text)
1:  bl   pq_load_text
    bl   check
    LEAVE 1
ENDF load_tmp

// tmp_reset(x0 header cstr): g_tmp = header line
LFUNC tmp_reset
    mov  x1, x0
    ADR_L x0, g_tmp
    str  xzr, [x0, #BUF_LEN]
    b    buf_puts
ENDF tmp_reset

// csv_quoted(x0 Buf*, x1 ptr, x2 len, w3 1 = upper-case ASCII): a quoted
// CSV field ("" for ")
//   x19 Buf, x20 cursor, x21 end, w22 upper
LFUNC csv_quoted
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    add  x21, x1, x2
    mov  w22, w3
    mov  w1, #'"'
    bl   buf_putc
1:  cmp  x20, x21
    b.hs 3f
    ldrb w1, [x20], #1
    cbz  w22, 11f
    sub  w9, w1, #'a'
    cmp  w9, #25
    b.hi 11f
    sub  w1, w1, #32
11: cmp  w1, #'"'
    b.ne 2f
    mov  x0, x19
    bl   buf_putc
    mov  w1, #'"'
2:  mov  x0, x19
    bl   buf_putc
    b    1b
3:  mov  x0, x19
    mov  w1, #'"'
    bl   buf_putc
    LEAVE 3
ENDF csv_quoted

// csv_cquoted(x0 Buf*, x1 cstr, w2 upper): csv_quoted of a C string
LFUNC csv_cquoted
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    stp  x2, xzr, [sp, #-16]!
    mov  x0, x1
    bl   strlen
    mov  x2, x0
    ldp  x3, xzr, [sp], #16
    mov  x0, x19
    mov  x1, x20
    bl   csv_quoted
    LEAVE 2
ENDF csv_cquoted

// put_ymd(x0 Buf*, x1 YYYYMMDD): YYYY-MM-DD
//   x19 Buf, x20 value
LFUNC put_ymd
    ENTER 2
    sub  sp, sp, #16
    mov  x19, x0
    mov  x20, x1
    mov  x9, #10000
    udiv x10, x20, x9               // year
    msub x11, x10, x9, x20          // MMDD
    mov  x9, #100
    udiv x12, x11, x9               // month
    msub x13, x12, x9, x11          // day
    mov  x0, sp
    mov  x14, #10
    .irp pos, 3, 2, 1, 0
    udiv x15, x10, x14
    msub x16, x15, x14, x10
    add  w16, w16, #'0'
    strb w16, [sp, #\pos]
    mov  x10, x15
    .endr
    mov  w16, #'-'
    strb w16, [sp, #4]
    strb w16, [sp, #7]
    udiv x15, x12, x14
    msub x16, x15, x14, x12
    add  w15, w15, #'0'
    add  w16, w16, #'0'
    strb w15, [sp, #5]
    strb w16, [sp, #6]
    udiv x15, x13, x14
    msub x16, x15, x14, x13
    add  w15, w15, #'0'
    add  w16, w16, #'0'
    strb w15, [sp, #8]
    strb w16, [sp, #9]
    mov  x0, x19
    mov  x1, sp
    mov  x2, #10
    bl   buf_put
    add  sp, sp, #16
    LEAVE 2
ENDF put_ymd

// =============================================================================
// Opening the ledger
// =============================================================================

// ledger_path_exists() -> w0 1 if data_dir/transactions.pqcf exists
LFUNC ledger_path_exists
    ENTER 0
    sub  sp, sp, #BUF_SIZE
    stp  xzr, xzr, [sp]
    stp  xzr, xzr, [sp, #16]
    mov  x0, sp
    LDR_G x1, g_cfg_data_dir
    bl   buf_puts
    mov  x0, sp
    ADR_L x1, s_txfile
    bl   buf_puts
    mov  x0, sp
    bl   buf_cstr
    mov  w1, #0                     // F_OK
    bl   access
    cmp  w0, #0
    cset w0, eq
    stp  x0, xzr, [sp, #-16]!
    add  x0, sp, #16
    bl   buf_free
    ldp  x0, xzr, [sp], #16
    add  sp, sp, #BUF_SIZE
    LEAVE 0
ENDF ledger_path_exists

// ledger_open(w0 LO_* flags): read the rules (and budget) file, check the
// ledger exists, start the engine and load every table
//   w19 flags, x20 table record / index, x21 count
LFUNC ledger_open
    ENTER 3
    mov  w19, w0
    LDR_G x0, g_cfg_rules_file      // rules: exit 2 if missing / invalid
    cbz  x0, 1f
    bl   rules_load
    STR_G x0, g_rules, x9
    STR_G x1, g_nrules, x9
1:  tbz  w19, #0, 2f                // budget file
    LDR_G x9, g_cfg_budget_file
    cbnz x9, 2f
    mov  w0, #EX_CONFIG
    ADR_L x1, m_nobudget
    bl   fail
2:  tst  w19, #3
    b.eq 3f
    LDR_G x0, g_cfg_budget_file
    cbz  x0, 3f
    bl   budget_load
    STR_G x0, g_buds, x9
    STR_G x1, g_nbuds, x9
3:  bl   ledger_path_exists
    cbnz w0, 4f
    mov  w0, #EX_STATE
    ADR_L x1, m_noledger
    LDR_G x2, g_cfg_data_dir
    bl   fail
4:  bl   engine_start
    ADR_L x20, ledger_tables        // transactions, batches, overrides
5:  ldr  x1, [x20]
    cbz  x1, 6f
    LDR_G x0, g_db
    ldr  x2, [x20, #8]
    mov  w3, #0
    bl   pq_open
    bl   check
    add  x20, x20, #32
    b    5b
6:  ADR_L x0, h_rules               // rules (rule_no, category, pattern)
    bl   tmp_reset
    mov  x20, #0
7:  LDR_G x9, g_nrules
    cmp  x20, x9
    b.hs 8f
    ADR_L x0, g_tmp
    add  x1, x20, #1
    bl   buf_put_u64
    ADR_L x0, g_tmp
    mov  w1, #','
    bl   buf_putc
    LDR_G x9, g_rules
    add  x9, x9, x20, lsl #4
    ldr  x1, [x9, #RULE_CAT]
    ADR_L x0, g_tmp
    mov  w2, #0
    bl   csv_cquoted
    ADR_L x0, g_tmp
    mov  w1, #','
    bl   buf_putc
    LDR_G x9, g_rules
    add  x9, x9, x20, lsl #4
    ldr  x1, [x9, #RULE_PAT]
    ADR_L x0, g_tmp
    mov  w2, #1                     // as written, upper-cased
    bl   csv_cquoted
    ADR_L x0, g_tmp
    mov  w1, #'\n'
    bl   buf_putc
    add  x20, x20, #1
    b    7b
8:  ADR_L x0, n_rules
    ADR_L x1, lo_rules
    bl   load_tmp
    tst  w19, #3                    // budgets (category, amount)
    b.eq 9f
    ADR_L x0, h_budgets
    bl   tmp_reset
    mov  x20, #0
81: LDR_G x9, g_nbuds
    cmp  x20, x9
    b.hs 82f
    LDR_G x9, g_buds
    add  x9, x9, x20, lsl #4
    ldr  x1, [x9, #BUD_CAT]
    ADR_L x0, g_tmp
    mov  w2, #0
    bl   csv_cquoted
    ADR_L x0, g_tmp
    mov  w1, #','
    bl   buf_putc
    LDR_G x9, g_buds
    add  x9, x9, x20, lsl #4
    ldr  x1, [x9, #BUD_CENTS]
    ADR_L x0, g_tmp
    bl   buf_put_cents
    ADR_L x0, g_tmp
    mov  w1, #'\n'
    bl   buf_putc
    add  x20, x20, #1
    b    81b
82: ADR_L x0, n_budgets
    ADR_L x1, lo_budgets
    bl   load_tmp
9:  LEAVE 3
ENDF ledger_open

// =============================================================================
// SQL fragments
// =============================================================================

// put_cte(): the category resolution CTEs (pql_m, pql_c, pql_l), ending
// without a trailing comma
LFUNC put_cte
    ENTER 0
    S "WITH pql_m AS (SELECT d.merchant, MIN(r.rule_no) AS rn FROM (SELECT DISTINCT merchant FROM transactions) d JOIN rules r ON d.merchant LIKE REPLACE(REPLACE(r.pattern, '*', '%'), '?', '_') GROUP BY d.merchant), "
    S "pql_c AS (SELECT pql_m.merchant, r.category FROM pql_m JOIN rules r ON r.rule_no = pql_m.rn), "
    S "pql_l AS (SELECT t.id, t.account, t.\"date\", t.description, t.merchant, t.amount, t.batch, COALESCE(o.category, pql_c.category, 'uncategorized') AS category FROM transactions t LEFT JOIN overrides o ON o.id = t.id LEFT JOIN pql_c ON pql_c.merchant = t.merchant) "
    LEAVE 0
ENDF put_cte

// put_month_date(x0 month index y*12+m-1): DATE 'YYYY-MM-01'
LFUNC put_month_date
    ENTER 1
    mov  x9, #12
    udiv x10, x0, x9
    msub x11, x10, x9, x0
    add  x11, x11, #1
    mov  x9, #10000
    mul  x19, x10, x9
    mov  x9, #100
    madd x19, x11, x9, x19
    add  x19, x19, #1               // YYYYMM01
    S "DATE '"
    ADR_L x0, g_sql
    mov  x1, x19
    bl   put_ymd
    ADR_L x0, g_sql
    mov  w1, #'\''
    bl   buf_putc
    LEAVE 1
ENDF put_month_date

// put_filters(): " AND ..." conditions of --month / --from / --to / --account
//   x19 month index
LFUNC put_filters
    ENTER 1
    LDR_G x0, g_opt_month
    cbz  x0, 1f
    bl   parse_month
    mov  x19, x0
    S " AND \"date\" >= "
    mov  x0, x19
    bl   put_month_date
    add  x19, x19, #1
    ldr  x9, =120000                // 10000-01: no upper bound needed
    cmp  x19, x9
    b.hs 1f
    S " AND \"date\" < "
    mov  x0, x19
    bl   put_month_date
1:  LDR_G x0, g_opt_from
    cbz  x0, 2f
    bl   parse_month
    mov  x19, x0
    S " AND \"date\" >= "
    mov  x0, x19
    bl   put_month_date
2:  LDR_G x0, g_opt_to
    cbz  x0, 3f
    bl   parse_month
    add  x19, x0, #1
    ldr  x9, =120000
    cmp  x19, x9
    b.hs 3f
    S " AND \"date\" < "
    mov  x0, x19
    bl   put_month_date
3:  LDR_G x19, g_opt_account
    cbz  x19, 4f
    S " AND account = "
    mov  x0, x19
    bl   strlen
    mov  x2, x0
    mov  x1, x19
    ADR_L x0, g_sql
    bl   buf_put_sqlstr
4:  LEAVE 1
    .ltorg
ENDF put_filters

// render(x0 pq_result*): append the result in the output format to g_out
LFUNC render
    ENTER 0
    LDR_G x1, g_format
    ADR_L x2, g_out
    bl   render_result
    LEAVE 0
ENDF render

// =============================================================================
// init / import
// =============================================================================

// mkdir_p(x0 path): create the directory and missing parents; exit 7 if
// the result is not a directory
//   x19 copy, x20 cursor
LFUNC mkdir_p
    ENTER 2
    bl   xstrdup
    mov  x19, x0
    add  x20, x19, #1               // a leading '/' is not a component end
1:  ldrb w9, [x20]
    cbz  w9, 3f
    cmp  w9, #'/'
    b.ne 2f
    strb wzr, [x20]
    mov  x0, x19
    mov  w1, #0777
    bl   mkdir
    mov  w9, #'/'
    strb w9, [x20]
2:  add  x20, x20, #1
    b    1b
3:  mov  x0, x19
    mov  w1, #0777
    bl   mkdir
    mov  x0, x19
    bl   opendir
    cbnz x0, 4f
    mov  w0, #EX_OTHER
    ADR_L x1, m_mkdir
    mov  x2, x19
    bl   fail
4:  bl   closedir
    mov  x0, x19
    bl   free
    LEAVE 2
ENDF mkdir_p

// cmd_init(): create data_dir and the three empty tables
//   x19 table record
FUNC cmd_init
    ENTER 1
    LDR_G x0, g_cfg_data_dir
    bl   mkdir_p
    bl   ledger_path_exists
    cbz  w0, 1f
    mov  w0, #EX_STATE
    ADR_L x1, m_exists
    LDR_G x2, g_cfg_data_dir
    bl   fail
1:  bl   engine_start
    ADR_L x19, ledger_tables        // transactions is written last
2:  ldr  x9, [x19]
    cbz  x9, 3f
    ldr  x0, [x19, #16]             // header only: zero rows
    bl   tmp_reset
    ldr  x0, [x19]
    ldr  x1, [x19, #24]
    bl   load_tmp
    LDR_G x0, g_db
    ldr  x1, [x19]
    ldr  x2, [x19, #8]
    bl   pq_save
    bl   check
    add  x19, x19, #32
    b    2b
3:  ADR_L x0, g_out
    ADR_L x1, o_init
    bl   buf_puts
    mov  w0, #EX_OK
    LEAVE 1
ENDF cmd_init

// cmd_import(): pqledger import FILE --account NAME (§6.2-§6.4)
//   x19 records, x20 count, x21 result (imported seqs), x22 i, x23 next id,
//   x24 batch, x25 record, x26 imported count; sp: IS settings
FUNC cmd_import
    ENTER 5
    sub  sp, sp, #IS_SIZE
    mov  w0, #0
    bl   ledger_open
    LDR_G x0, g_opt_account
    mov  x1, sp
    bl   cfg_import_settings
    LDR_G x0, g_pos0
    mov  x1, sp
    bl   bank_read
    mov  x19, x0
    mov  x20, x1
    // incoming records: seq, date, amount, merchant
    ADR_L x0, h_in
    bl   tmp_reset
    mov  x22, #0
1:  cmp  x22, x20
    b.hs 2f
    mov  x9, #REC_SIZE
    madd x25, x22, x9, x19
    ADR_L x0, g_tmp
    mov  x1, x22
    bl   buf_put_u64
    ADR_L x0, g_tmp
    mov  w1, #','
    bl   buf_putc
    ADR_L x0, g_tmp
    ldr  x1, [x25, #REC_DATE]
    bl   put_ymd
    ADR_L x0, g_tmp
    mov  w1, #','
    bl   buf_putc
    ADR_L x0, g_tmp
    ldr  x1, [x25, #REC_AMOUNT]
    bl   buf_put_cents
    ADR_L x0, g_tmp
    mov  w1, #','
    bl   buf_putc
    ADR_L x0, g_tmp
    ldr  x1, [x25, #REC_MERCH]
    ldr  x2, [x25, #REC_MERCH_LEN]
    mov  w3, #0
    bl   csv_quoted
    ADR_L x0, g_tmp
    mov  w1, #'\n'
    bl   buf_putc
    add  x22, x22, #1
    b    1b
2:  ADR_L x0, n_in
    ADR_L x1, lo_in
    bl   load_tmp
    // duplicates (§6.4): a record is imported iff the ledger holds no more
    // transactions with its key than the file has earlier records with it
    bl   sql_reset
    S "SELECT a.seq FROM pql_in a LEFT JOIN (SELECT \"date\", amount, merchant, COUNT(*) AS n FROM transactions WHERE account = "
    LDR_G x0, g_opt_account
    bl   strlen
    mov  x2, x0
    LDR_G x1, g_opt_account
    ADR_L x0, g_sql
    bl   buf_put_sqlstr
    S " GROUP BY \"date\", amount, merchant) l ON l.\"date\" = a.\"date\" AND l.amount = a.amount AND l.merchant = a.merchant "
    S "LEFT JOIN pql_in b ON b.\"date\" = a.\"date\" AND b.amount = a.amount AND b.merchant = a.merchant AND b.seq < a.seq "
    S "GROUP BY a.seq, l.n HAVING COALESCE(l.n, 0) <= COUNT(b.seq) ORDER BY a.seq"
    bl   run_sql
    mov  x21, x0
    ldr  x26, [x21, #PQR_NROWS]
    // next id and batch
    bl   sql_reset
    S "SELECT (SELECT COALESCE(MAX(id), 0) FROM transactions) AS i, (SELECT COALESCE(MAX(batch), 0) FROM batches) AS b"
    bl   run_sql
    ldr  x9, [x0, #PQR_VALUES]
    ldr  x23, [x9, #PQV_V]
    add  x23, x23, #1
    ldr  x24, [x9, #PQV_SIZE + PQV_V]
    add  x24, x24, #1
    bl   pq_result_free
    // the new transactions
    ADR_L x0, h_tx
    bl   tmp_reset
    mov  x22, #0
3:  cmp  x22, x26
    b.hs 4f
    ldr  x9, [x21, #PQR_VALUES]
    mov  x10, #PQV_SIZE
    madd x9, x22, x10, x9
    ldr  x9, [x9, #PQV_V]           // seq
    mov  x10, #REC_SIZE
    madd x25, x9, x10, x19
    ADR_L x0, g_tmp
    add  x1, x23, x22
    bl   buf_put_u64
    ADR_L x0, g_tmp
    mov  w1, #','
    bl   buf_putc
    ADR_L x0, g_tmp
    LDR_G x1, g_opt_account
    mov  w2, #0
    bl   csv_cquoted
    ADR_L x0, g_tmp
    mov  w1, #','
    bl   buf_putc
    ADR_L x0, g_tmp
    ldr  x1, [x25, #REC_DATE]
    bl   put_ymd
    ADR_L x0, g_tmp
    mov  w1, #','
    bl   buf_putc
    ADR_L x0, g_tmp
    ldr  x1, [x25, #REC_DESC]
    ldr  x2, [x25, #REC_DESC_LEN]
    mov  w3, #0
    bl   csv_quoted
    ADR_L x0, g_tmp
    mov  w1, #','
    bl   buf_putc
    ADR_L x0, g_tmp
    ldr  x1, [x25, #REC_MERCH]
    ldr  x2, [x25, #REC_MERCH_LEN]
    mov  w3, #0
    bl   csv_quoted
    ADR_L x0, g_tmp
    mov  w1, #','
    bl   buf_putc
    ADR_L x0, g_tmp
    ldr  x1, [x25, #REC_AMOUNT]
    bl   buf_put_cents
    ADR_L x0, g_tmp
    mov  w1, #','
    bl   buf_putc
    ADR_L x0, g_tmp
    mov  x1, x24
    bl   buf_put_u64
    ADR_L x0, g_tmp
    mov  w1, #'\n'
    bl   buf_putc
    add  x22, x22, #1
    b    3b
4:  ADR_L x0, n_new
    ADR_L x1, lo_tx
    bl   load_tmp
    bl   sql_reset
    S "SELECT id, account, \"date\", description, merchant, amount, batch FROM transactions UNION ALL SELECT id, account, \"date\", description, merchant, amount, batch FROM pql_new ORDER BY id"
    ADR_L x0, n_tx
    bl   run_sql_into
    // the batch record
    bl   sql_reset
    S "SELECT batch, account, file, imported, duplicates FROM batches UNION ALL SELECT "
    ADR_L x0, g_sql
    mov  x1, x24
    bl   buf_put_u64
    S ", "
    LDR_G x0, g_opt_account
    bl   strlen
    mov  x2, x0
    LDR_G x1, g_opt_account
    ADR_L x0, g_sql
    bl   buf_put_sqlstr
    S ", "
    LDR_G x0, g_pos0                // the file's base name
    mov  w1, #'/'
    bl   strrchr
    cbz  x0, 5f
    add  x22, x0, #1
    b    6f
5:  LDR_G x22, g_pos0
6:  mov  x0, x22
    bl   strlen
    mov  x2, x0
    mov  x1, x22
    ADR_L x0, g_sql
    bl   buf_put_sqlstr
    S ", "
    ADR_L x0, g_sql
    mov  x1, x26
    bl   buf_put_u64
    S ", "
    ADR_L x0, g_sql
    sub  x1, x20, x26
    bl   buf_put_u64
    S " ORDER BY batch"
    ADR_L x0, n_batches
    bl   run_sql_into
    // write the files (each atomically), batches after transactions
    LDR_G x0, g_db
    ADR_L x1, n_tx
    ADR_L x2, f_tx
    bl   pq_save
    bl   check
    LDR_G x0, g_db
    ADR_L x1, n_batches
    ADR_L x2, f_batches
    bl   pq_save
    bl   check
    // batch B: imported N, duplicates D
    ADR_L x0, g_out
    ADR_L x1, o_batch
    bl   buf_puts
    ADR_L x0, g_out
    mov  x1, x24
    bl   buf_put_u64
    ADR_L x0, g_out
    ADR_L x1, o_imported
    bl   buf_puts
    ADR_L x0, g_out
    mov  x1, x26
    bl   buf_put_u64
    ADR_L x0, g_out
    ADR_L x1, o_dups
    bl   buf_puts
    ADR_L x0, g_out
    sub  x1, x20, x26
    bl   buf_put_u64
    ADR_L x0, g_out
    mov  w1, #'\n'
    bl   buf_putc
    mov  x0, x21
    bl   pq_result_free
    mov  w0, #EX_OK
    add  sp, sp, #IS_SIZE
    LEAVE 5
ENDF cmd_import

// =============================================================================
// Reports
// =============================================================================

// cmd_report_monthly(): month, income, expenses, net, transactions (§9.1)
FUNC cmd_report_monthly
    ENTER 0
    mov  w0, #0
    bl   ledger_open
    bl   sql_reset
    S "SELECT SUBSTR(CAST(\"date\" AS STRING), 1, 7) AS month, SUM(CASE WHEN amount > 0 THEN amount ELSE CAST(0 AS DECIMAL(18,2)) END) AS income, "
    S "CAST(0 AS DECIMAL(18,2)) - SUM(CASE WHEN amount < 0 THEN amount ELSE CAST(0 AS DECIMAL(18,2)) END) AS expenses, SUM(amount) AS net, COUNT(*) AS transactions "
    S "FROM transactions WHERE 1 = 1"
    bl   put_filters
    S " GROUP BY SUBSTR(CAST(\"date\" AS STRING), 1, 7) ORDER BY month"
    bl   run_sql
    bl   render
    mov  w0, #EX_OK
    LEAVE 0
ENDF cmd_report_monthly

// udiv128(x0 lo, x1 hi, x2 divisor) -> x0 quotient (assumed < 2^64)  (leaf)
LFUNC udiv128
    mov  x3, #0                     // remainder
    mov  x4, #0                     // quotient
    mov  x5, #128
1:  lsl  x3, x3, #1                 // shift (rem:hi:lo) left by one
    orr  x3, x3, x1, lsr #63
    lsl  x1, x1, #1
    orr  x1, x1, x0, lsr #63
    lsl  x0, x0, #1
    lsl  x4, x4, #1
    cmp  x3, x2
    b.lo 2f
    sub  x3, x3, x2
    orr  x4, x4, #1
2:  subs x5, x5, #1
    b.ne 1b
    mov  x0, x4
    ret
ENDF udiv128

// add_share(x0 pq_result* [category, spent, transactions]) -> x0 new
// pq_result* [category, spent, share, transactions] (malloc; values point
// into the old result, which must stay alive). share = 100 * spent / total
// rounded half away from zero to one decimal, exactly in integer cents.
//   x19 old, x20 new, x21 rows, x22 total, x23 row, x24 old value,
//   x25 new value
LFUNC add_share
    ENTER 5
    mov  x19, x0
    ldr  x21, [x19, #PQR_NROWS]
    mov  x22, #0                    // total spent (cents)
    mov  x23, #0
1:  cmp  x23, x21
    b.hs 2f
    ldr  x9, [x19, #PQR_VALUES]
    mov  x10, #3 * PQV_SIZE
    madd x9, x23, x10, x9
    ldr  x10, [x9, #PQV_SIZE + PQV_V]
    add  x22, x22, x10
    add  x23, x23, #1
    b    1b
2:  mov  x9, #4 * PQV_SIZE
    mul  x0, x21, x9
    add  x0, x0, #PQR_SIZE + 4 * PQC_SIZE
    bl   xmalloc
    mov  x20, x0
    mov  x9, #4
    stp  x9, x21, [x20, #PQR_NCOLS]
    add  x9, x20, #PQR_SIZE
    str  x9, [x20, #PQR_COLUMNS]
    add  x10, x9, #4 * PQC_SIZE
    str  x10, [x20, #PQR_VALUES]
    ldr  x11, [x19, #PQR_COLUMNS]   // columns 0, 1 copied; 2 = share; 3 = old 2
    ldp  q0, q1, [x11]
    stp  q0, q1, [x9]
    ldp  q0, q1, [x11, #PQC_SIZE]
    stp  q0, q1, [x9, #PQC_SIZE]
    ldp  q0, q1, [x11, #2 * PQC_SIZE]
    stp  q0, q1, [x9, #3 * PQC_SIZE]
    add  x12, x9, #2 * PQC_SIZE
    ADR_L x13, c_share
    ADR_L x14, t_dec1
    stp  x13, x14, [x12, #PQC_NAME]
    mov  w13, #PQ_T_DECIMAL
    mov  w14, #18
    stp  w13, w14, [x12, #PQC_TYPE]
    mov  w13, #1
    stp  w13, wzr, [x12, #PQC_SCALE]
    mov  x23, #0
3:  cmp  x23, x21
    b.hs 6f
    ldr  x24, [x19, #PQR_VALUES]
    mov  x9, #3 * PQV_SIZE
    madd x24, x23, x9, x24
    ldr  x25, [x20, #PQR_VALUES]
    mov  x9, #4 * PQV_SIZE
    madd x25, x23, x9, x25
    ldp  q0, q1, [x24]              // values 0, 1 (48 bytes)
    stp  q0, q1, [x25]
    ldr  q0, [x24, #32]
    str  q0, [x25, #32]
    ldr  q0, [x24, #2 * PQV_SIZE]   // value 2 -> 3
    str  q0, [x25, #3 * PQV_SIZE]
    ldr  x9, [x24, #2 * PQV_SIZE + 16]
    str  x9, [x25, #3 * PQV_SIZE + 16]
    // share in tenths of a percent: (2000 * spent + total) / (2 * total)
    mov  x0, #0
    cbz  x22, 5f
    ldr  x9, [x24, #PQV_SIZE + PQV_V]
    mov  x10, #2000
    mul  x0, x9, x10
    umulh x1, x9, x10
    adds x0, x0, x22
    adc  x1, x1, xzr
    lsl  x2, x22, #1
    bl   udiv128
5:  add  x9, x25, #2 * PQV_SIZE
    stp  x0, xzr, [x9]
    mov  w10, #PQ_T_DECIMAL
    stp  wzr, w10, [x9, #PQV_IS_NULL]
    add  x23, x23, #1
    b    3b
6:  mov  x0, x20
    LEAVE 5
ENDF add_share

// cmd_report_categories(): category, spent, share, transactions (§9.2)
//   x19 result, x20 with share
FUNC cmd_report_categories
    ENTER 2
    mov  w0, #0
    bl   ledger_open
    bl   sql_reset
    bl   put_cte
    S "SELECT category, CAST(0 AS DECIMAL(18,2)) - SUM(amount) AS spent, COUNT(*) AS transactions FROM pql_l WHERE amount < 0"
    bl   put_filters
    S " GROUP BY category ORDER BY spent DESC, category"
    bl   run_sql
    mov  x19, x0
    bl   add_share
    mov  x20, x0
    bl   render
    mov  x0, x20
    bl   free
    mov  x0, x19
    bl   pq_result_free
    mov  w0, #EX_OK
    LEAVE 2
ENDF cmd_report_categories

// cmd_report_merchants(): merchant, spent, transactions; top N (§9.3)
FUNC cmd_report_merchants
    ENTER 1
    mov  w0, #0
    bl   ledger_open
    mov  x19, #10
    LDR_G x0, g_opt_top
    cbz  x0, 1f
    bl   strlen
    mov  x1, x0
    LDR_G x0, g_opt_top
    bl   parse_u64
    mov  x19, x0
1:  bl   sql_reset
    S "SELECT merchant, CAST(0 AS DECIMAL(18,2)) - SUM(amount) AS spent, COUNT(*) AS transactions FROM transactions WHERE amount < 0"
    bl   put_filters
    S " GROUP BY merchant ORDER BY spent DESC, merchant LIMIT "
    ADR_L x0, g_sql
    mov  x1, x19
    bl   buf_put_u64
    bl   run_sql
    bl   render
    mov  w0, #EX_OK
    LEAVE 1
ENDF cmd_report_merchants

// cmd_budget(): category, budget, spent, remaining, status (§9.4); exit 3
// if a category is over budget
//   x19 result, x20 row, w21 status
FUNC cmd_budget
    ENTER 3
    mov  w0, #LO_BUDGET_REQ
    bl   ledger_open
    bl   sql_reset
    bl   put_cte
    S ", pql_s AS (SELECT category, CAST(0 AS DECIMAL(18,2)) - SUM(amount) AS spent FROM pql_l WHERE amount < 0"
    bl   put_filters
    S " GROUP BY category) SELECT b.category, b.amount AS budget, COALESCE(s.spent, CAST(0 AS DECIMAL(18,2))) AS spent, "
    S "b.amount - COALESCE(s.spent, CAST(0 AS DECIMAL(18,2))) AS remaining, "
    S "CASE WHEN COALESCE(s.spent, CAST(0 AS DECIMAL(18,2))) <= b.amount THEN 'ok' ELSE 'over' END AS status "
    S "FROM budgets b LEFT JOIN pql_s s ON s.category = b.category ORDER BY b.category"
    bl   run_sql
    mov  x19, x0
    bl   render
    mov  w21, #EX_OK
    mov  x20, #0
1:  ldr  x9, [x19, #PQR_NROWS]
    cmp  x20, x9
    b.hs 2f
    mov  x0, x19
    mov  x1, x20
    mov  x2, #4
    bl   pq_value_at
    ldr  x0, [x0, #PQV_V]
    ADR_L x1, s_over
    bl   strcmp
    add  x20, x20, #1
    cbnz w0, 1b
    mov  w21, #EX_OVER
2:  mov  x0, x19
    bl   pq_result_free
    mov  w0, w21
    LEAVE 3
ENDF cmd_budget

// cmd_accounts(): account, transactions, balance, first, last (§8.4)
FUNC cmd_accounts
    ENTER 0
    mov  w0, #0
    bl   ledger_open
    bl   sql_reset
    S "SELECT account, COUNT(*) AS transactions, SUM(amount) AS balance, MIN(\"date\") AS \"first\", MAX(\"date\") AS \"last\" FROM transactions GROUP BY account ORDER BY account"
    bl   run_sql
    bl   render
    mov  w0, #EX_OK
    LEAVE 0
ENDF cmd_accounts

// =============================================================================
// list / export / set-category / query
// =============================================================================

// cmd_list(): id, date, account, description, amount, category (§8.1)
//   x19 category
FUNC cmd_list
    ENTER 1
    mov  w0, #0
    bl   ledger_open
    bl   sql_reset
    bl   put_cte
    S "SELECT id, \"date\", account, description, amount, category FROM pql_l WHERE 1 = 1"
    bl   put_filters
    LDR_G x19, g_opt_category
    LDR_G x9, g_opt_uncat
    cbz  x9, 1f
    CSTR x19, "uncategorized"
1:  cbz  x19, 2f
    S " AND category = "
    mov  x0, x19
    bl   strlen
    mov  x2, x0
    mov  x1, x19
    ADR_L x0, g_sql
    bl   buf_put_sqlstr
2:  S " ORDER BY \"date\", id"
    bl   run_sql
    bl   render
    mov  w0, #EX_OK
    LEAVE 1
ENDF cmd_list

// cmd_export(): every column plus category, ordered by id (§8.2)
FUNC cmd_export
    ENTER 0
    mov  w0, #0
    bl   ledger_open
    bl   sql_reset
    bl   put_cte
    S "SELECT id, account, \"date\", description, merchant, amount, category, batch FROM pql_l WHERE 1 = 1"
    bl   put_filters
    S " ORDER BY id"
    bl   run_sql
    bl   render
    mov  w0, #EX_OK
    LEAVE 0
ENDF cmd_export

// cmd_set_category(): set-category ID CATEGORY | ID --clear (§8.3)
//   x19 id
FUNC cmd_set_category
    ENTER 1
    mov  w0, #0
    bl   ledger_open
    LDR_G x0, g_pos0
    bl   strlen
    mov  x1, x0
    LDR_G x0, g_pos0
    bl   parse_u64
    mov  x19, x0
    bl   sql_reset                  // the transaction must exist
    S "SELECT COUNT(*) AS n FROM transactions WHERE id = "
    ADR_L x0, g_sql
    mov  x1, x19
    bl   buf_put_u64
    bl   run_sql
    ldr  x9, [x0, #PQR_VALUES]
    ldr  x9, [x9, #PQV_V]
    cbnz x9, 1f
    mov  w0, #EX_STATE
    ADR_L x1, m_unknown
    LDR_G x2, g_pos0
    bl   fail
1:  bl   pq_result_free
    bl   sql_reset                  // overrides without ID (+ the new one)
    S "SELECT id, category FROM overrides WHERE id <> "
    ADR_L x0, g_sql
    mov  x1, x19
    bl   buf_put_u64
    LDR_G x9, g_opt_clear
    cbnz x9, 2f
    S " UNION ALL SELECT "
    ADR_L x0, g_sql
    mov  x1, x19
    bl   buf_put_u64
    S ", "
    LDR_G x0, g_pos1
    bl   strlen
    mov  x2, x0
    LDR_G x1, g_pos1
    ADR_L x0, g_sql
    bl   buf_put_sqlstr
2:  S " ORDER BY id"
    ADR_L x0, n_overrides
    bl   run_sql_into
    LDR_G x0, g_db
    ADR_L x1, n_overrides
    ADR_L x2, f_overrides
    bl   pq_save
    bl   check
    ADR_L x0, g_out                 // transaction ID: category C / cleared
    ADR_L x1, o_trans
    bl   buf_puts
    ADR_L x0, g_out
    mov  x1, x19
    bl   buf_put_u64
    LDR_G x9, g_opt_clear
    cbz  x9, 3f
    ADR_L x0, g_out
    ADR_L x1, o_cleared
    bl   buf_puts
    b    4f
3:  ADR_L x0, g_out
    ADR_L x1, o_category
    bl   buf_puts
    ADR_L x0, g_out
    LDR_G x1, g_pos1
    bl   buf_puts
    ADR_L x0, g_out
    mov  w1, #'\n'
    bl   buf_putc
4:  mov  w0, #EX_OK
    LEAVE 1
ENDF cmd_set_category

// cmd_query(): pqledger query SQL (§9.5) on transactions, batches,
// overrides, ledger, rules, budgets; engine errors exit 5
//   sp: pq_result*
FUNC cmd_query
    ENTER 0
    sub  sp, sp, #16
    mov  w0, #LO_BUDGET_OPT
    bl   ledger_open
    LDR_G x9, g_cfg_budget_file     // without a budget file: empty budgets
    cbnz x9, 1f
    ADR_L x0, h_budgets
    bl   tmp_reset
    ADR_L x0, n_budgets
    ADR_L x1, lo_budgets
    bl   load_tmp
1:  bl   sql_reset                  // ledger = transactions + category
    bl   put_cte
    S "SELECT id, account, \"date\", description, merchant, amount, batch, category FROM pql_l ORDER BY id"
    ADR_L x0, n_ledger
    bl   run_sql_into
    LDR_G x0, g_db
    LDR_G x1, g_pos0
    ADR_L x2, g_qopts
    mov  x3, sp
    bl   pq_query
    cbz  w0, 2f
    mov  w0, #EX_QUERY
    bl   eng_fail
2:  ldr  x0, [sp]
    bl   render
    mov  w0, #EX_OK
    add  sp, sp, #16
    LEAVE 0
ENDF cmd_query

    NOTE_GNU_STACK
