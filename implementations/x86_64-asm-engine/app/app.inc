/*
 * app.inc - shared constants, structure layouts and macros of pqledger
 * (spec/apps/pqledger.md).  pqledger is an external client of the
 * embedding API: it includes only polyquery.inc from the engine, never the
 * engine's internal headers.
 *
 * Conventions (same as the engine): AT&T syntax, System V AMD64 ABI for
 * every function, ENTER/LEAVE frames keep %rsp 16-byte aligned, %al = 0
 * before every variadic call without vector arguments.
 *
 * Module map (each module owns its functions; "exported" = .globl):
 *   main.S     entry point, global options, command dispatch, usage errors
 *   util.S     die/fail helpers, growable byte buffers (ABUF), file reading,
 *              small string helpers
 *   config.S   configuration file, rules file, budget file
 *   ledger.S   engine instance, opening/saving the ledger tables, the
 *              category-resolution SQL, rules/budgets tables
 *   output.S   table / csv / json rendering of results
 *   report.S   init, report monthly|categories|merchants, budget,
 *              accounts, list, export, set-category, query, help, version
 *   import.S   import: bank CSV reading and conversion, merchant
 *              normalization, duplicate detection, ledger update
 */
#ifndef APP_INC
#define APP_INC

#include "polyquery.inc"

/* ------------------------------------------------------------ exit codes */
#define EX_OK      0
#define EX_USAGE   1
#define EX_CONFIG  2
#define EX_OVER    3
#define EX_IMPORT  4
#define EX_QUERY   5
#define EX_LEDGER  6
#define EX_OTHER   7

/* ------------------------------------------------------------ ABUF: growable byte buffer (util.S)
 * malloc-backed; data is always NUL-terminated after len bytes. */
#define AB_DATA 0
#define AB_LEN  8
#define AB_CAP  16
#define AB_SIZE 24

/* ------------------------------------------------------------ column reference */
#define CREF_POS   0      /* > 0: 1-based column position; 0: by name */
#define CREF_NAME  8      /* C string (header name) when CREF_POS = 0 */
#define CREF_SIZE  16

/* date formats */
#define DF_ISO    0       /* YYYY-MM-DD */
#define DF_COMPACT 1      /* YYYYMMDD */
#define DF_US     2       /* MM/DD/YYYY */
#define DF_EU     3       /* DD/MM/YYYY */
#define DF_DOT    4       /* DD.MM.YYYY */

/* amount modes */
#define AM_SIGNED 0
#define AM_DEBIT_CREDIT 1

/* ------------------------------------------------------------ ACC: effective import settings of an account
 * (config.S cfg_account_settings fills it: [account NAME] value, else
 * [import] value, else the default) */
#define ACC_DELIM       0     /* u64 delimiter byte (',' default; tab = 9) */
#define ACC_HEADER      8     /* u64 1/0 */
#define ACC_SKIP        16    /* u64 skip_lines */
#define ACC_DATE_COL    24    /* CREF (16 bytes) default name "Date" */
#define ACC_DATE_FMT    40    /* u64 DF_* */
#define ACC_DESC_COL    48    /* CREF default "Description" */
#define ACC_AMOUNT_MODE 64    /* u64 AM_* */
#define ACC_AMOUNT_COL  72    /* CREF default "Amount" */
#define ACC_DEBIT_COL   88    /* CREF default "Debit" */
#define ACC_CREDIT_COL  104   /* CREF default "Credit" */
#define ACC_DEC_SEP     120   /* u64 '.' or ',' */
#define ACC_THOU_SEP    128   /* u64 0 = none, else ',', '.', ' ' or '\'' */
#define ACC_CURRENCY    136   /* C string ("" = none) */
#define ACC_INVERT      144   /* u64 1/0 */
#define ACC_SIZE        152

/* ------------------------------------------------------------ rules and budgets (config.S) */
#define RULE_NO       0     /* u64 1, 2, ... in file order */
#define RULE_CATEGORY 8     /* char* */
#define RULE_PATTERN  16    /* char* pattern as written, ASCII upper-cased */
#define RULE_SIZE     24

#define BUD_CATEGORY  0     /* char* */
#define BUD_CENTS     8     /* u64 amount in cents */
#define BUD_SIZE      16

/* ------------------------------------------------------------ macros */
.macro FUNC name
    .globl \name
    .type \name, @function
    .p2align 4
\name:
.endm

.macro ENDF name
    .size \name, .-\name
.endm

/* Standard frame: saves rbp, rbx, r12-r15; reserves `locals` bytes at (%rsp). */
.macro ENTER locals=0
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    sub $((((\locals) + 15) & ~15) + 8), %rsp
.endm

.macro LEAVE
    lea -40(%rbp), %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
.endm

/* lea of an inline constant C string: CSTR reg, "text" */
.macro CSTR reg, msg
    .pushsection .rodata.str1.1, "aMS", @progbits, 1
9875:
    .asciz "\msg"
    .popsection
    lea 9875b(%rip), \reg
.endm

/* append an inline constant C string to the ABUF whose address is in reg */
.macro APUTS buf, msg
    .pushsection .rodata.str1.1, "aMS", @progbits, 1
9874:
    .asciz "\msg"
    .popsection
    mov \buf, %rdi
    lea 9874b(%rip), %rsi
    call ab_puts
.endm

/* DIE code, "printf format" : report `pqledger: error: <msg>` and exit.
 * Up to 4 extra printf arguments may be set beforehand in rdx, rcx, r8, r9
 * (die takes exit code in edi, format in rsi). */
.macro DIE code, msg
    .pushsection .rodata.str1.1, "aMS", @progbits, 1
9873:
    .asciz "\msg"
    .popsection
    mov $\code, %edi
    lea 9873b(%rip), %rsi
    xor %eax, %eax
    call die
.endm

/*
 * ------------------------------------------------------------ interfaces
 *
 * util.S
 *   die(code edi, fmt rsi, ...)          noreturn; flushes stdout? NO: on
 *        error nothing may be on stdout, so commands print only at the end
 *        (output is assembled in an ABUF and written by out_flush).  Writes
 *        "pqledger: error: " + formatted message + "\n" to stderr, exit(code).
 *   die_engine(code edi, db rsi)         noreturn: "pqledger: error: CODE: MESSAGE"
 *        from pq_error_name(pq_errcode(db)) / pq_errmsg(db), exit(code).
 *   xmalloc(n) / xrealloc(p, n)          abort with exit 7 on failure
 *   ab_init(ab) ab_free(ab) ab_reserve(ab, n) ab_putc(ab, c) ab_puts(ab, cstr)
 *   ab_put(ab, ptr, len) ab_put_i64(ab, v) ab_clear(ab)
 *   read_file(path rdi, ABUF* rsi) -> eax 0 ok, -1 error (errno set)
 *   g_out: ABUF   standard output of the command; out_flush() writes it to
 *        fd 1 (called once by main after the command succeeded, also for
 *        exit status 3).
 *
 * config.S (after cfg_load)
 *   cfg_load(path rdi or 0)  locates and parses the configuration
 *        (--config path, else PQLEDGER_CONFIG, else ./pqledger.conf), exit 2
 *        on errors.
 *   g_cfg_data_dir, g_cfg_rules_file, g_cfg_budget_file : C strings (paths
 *        already resolved against the configuration file's directory; 0 if
 *        not configured), g_cfg_format (0 table, 1 csv, 2 json),
 *        g_cfg_threads, g_cfg_memory_mb (0 = absent).
 *   cfg_account_settings(name rdi, ACC* rsi): fills the effective settings.
 *   rules_load()  parses the rules file (exit 2 on error): g_rules_n,
 *        g_rules (array of RULE entries: u64 rule_no, char* category,
 *        char* pattern upper-cased).
 *   budget_load() parses the budget file: g_budget_n, g_budgets (BUD_*
 *        entries).
 *
 * ledger.S
 *   g_db : pq_db*
 *   ledger_open()     creates the engine instance (data dir = ledger dir),
 *        exit 6 if transactions.pqcf is missing, opens the three tables
 *        transactions, batches, overrides.
 *   ledger_save(table C string) saves table to "<table>.pqcf" (exit 7 on
 *        engine error).
 *   ledger_query(sql rdi) -> rax pq_result* (exit 7 on engine error).
 *
 * import.S
 *   cmd_import(file rdi, account rsi)   the whole import command; appends
 *        "batch B: imported N, duplicates D\n" to g_out.
 *
 * ------------------------------------------------------------ additional exports
 *
 * main.S
 *   g_format (u64 0 table / 1 csv / 2 json: --format, else [output] format)
 *   parsed command line: g_opt_month, g_opt_from, g_opt_to, g_opt_account,
 *        g_opt_category (char* or 0), g_opt_uncat, g_opt_clear (0/1),
 *        g_opt_top (u64), g_pos[2], g_npos, g_report_kind, g_setcat_id.
 *
 * util.S
 *   read_file appends to an initialized or zeroed ABUF (a zeroed ABUF is a
 *        valid empty buffer for every ab_* function).
 *   xstrdup(s) / xstrndup(p, n) -> malloc'd C string (exit 7 on OOM)
 *   ab_put_sqlstr(ab, s)  appends 'SQL literal' ('' doubled)
 *   ab_put_csvstr(ab, s)  appends "CSV field" ("" doubled, always quoted)
 *   trim_span(p, n) -> rax p', rdx n'  without leading/trailing space/tab
 *   is_name(s) / is_category(s) -> eax 1/0  ([a-z0-9_-]{1,32}; category:
 *        also not "uncategorized")
 *   parse_u64(s, max_digits) -> rax value or -1 unless [0-9]{1,max}
 *   utf8_check(p, n) -> rax -1 if well-formed UTF-8, else the offset of
 *        the first ill-formed sequence
 *   path_dirname(path) / path_join(dir, path) -> malloc'd path
 *
 * config.S
 *   g_cfg_path (configuration file as given), g_cfg_dir (its directory)
 *   check_utf8(ab, path)  exit 2 ("PATH:LINE: ...") unless the text is UTF-8
 *   word_index(s, list) -> eax index in a NUL-separated word list ending
 *        with an empty word, or -1
 *
 * ledger.S
 *   g_schema_transactions (7), g_schema_batches (5), g_schema_overrides (2):
 *        pq_column_def arrays of the ledger tables (§4).
 *   g_qopts: pq_query_options used for every query (threads, max_rows -1)
 *   ledger_create()        instance only (init: no tables yet)
 *   ledger_exists() -> eax 1 if <data_dir>/transactions.pqcf exists
 *   ledger_load_csv(table, ABUF*, schema, ncols)  replaces `table` with
 *        the header-less CSV text of the ABUF (exit 7 on engine error)
 *   ledger_load_rules() / ledger_load_budgets()  the `rules` / `budgets`
 *        tables from g_rules / g_budgets (ledger_open loads `rules`)
 *   ledger_try_query(sql) -> rax pq_result* or 0 (error left in g_db)
 *   ledger_create_table(table, sql)  replaces `table` by the query result
 *   ledger_cte(ab)  appends "WITH ..., ledger AS (...) " (category
 *        resolution, §5.1); note `date` is a reserved word: write "date".
 */

#endif
