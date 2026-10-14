// =============================================================================
// main.S — pqledger command line (spec/apps/pqledger.md §2, §10).
//
//   pqledger [--config PATH] [--format table|csv|json] [--help] COMMAND ...
//
// Parsing happens completely before anything else (usage errors exit 1),
// then the configuration is located and read (§3.1), then the command runs
// (commands.S) and appends its output to g_out; main writes g_out to stdout
// only when the command succeeded.
//
// Each command has an option table (OPT_* records): the options it accepts,
// whether they take a value, and the global that receives the value. A
// repeated option, an unknown option, a missing value or a surplus
// positional argument is a usage error.
// =============================================================================
#include "ledger.inc"

// command ids
#define C_HELP      0
#define C_VERSION   1
#define C_INIT      2
#define C_IMPORT    3
#define C_MONTHLY   4
#define C_CATS      5
#define C_MERCH     6
#define C_BUDGET    7
#define C_ACCOUNTS  8
#define C_LIST      9
#define C_EXPORT    10
#define C_SETCAT    11
#define C_QUERY     12

// option record: name cstr, kind (0 flag, 1 value), destination global
#define OPT_NAME    0
#define OPT_KIND    8
#define OPT_DEST    16
#define OPT_SIZE    24

// command record: name cstr, id, option table, positional count
#define CMD_NAME    0
#define CMD_ID      8
#define CMD_OPTS    16
#define CMD_NPOS    24
#define CMD_SIZE    32

    .bss
    .p2align 3
    .global g_out, g_format, g_opt_month, g_opt_from, g_opt_to
    .global g_opt_account, g_opt_top, g_opt_category, g_opt_uncat
    .global g_opt_clear, g_pos0, g_pos1, g_npos, g_config_path
g_out:          .skip BUF_SIZE  // command output (stdout on success)
g_format:       .skip 8         // OF_* effective output format
g_opt_format:   .skip 8         // --format value or 0
g_opt_config:   .skip 8         // --config value or 0
g_opt_help:     .skip 8
g_opt_month:    .skip 8         // option values (cstr) or 0
g_opt_from:     .skip 8
g_opt_to:       .skip 8
g_opt_account:  .skip 8
g_opt_top:      .skip 8
g_opt_category: .skip 8
g_opt_uncat:    .skip 8         // flags: 1 if given
g_opt_clear:    .skip 8
g_pos0:         .skip 8         // positional arguments
g_pos1:         .skip 8
g_npos:         .skip 8
g_config_path:  .skip 8         // configuration file in use

    .section .rodata
o_config:   .asciz "--config"
o_format:   .asciz "--format"
o_help:     .asciz "--help"
o_month:    .asciz "--month"
o_from:     .asciz "--from"
o_to:       .asciz "--to"
o_account:  .asciz "--account"
o_top:      .asciz "--top"
o_category: .asciz "--category"
o_uncat:    .asciz "--uncategorized"
o_clear:    .asciz "--clear"
n_help:     .asciz "help"
n_version:  .asciz "version"
n_init:     .asciz "init"
n_import:   .asciz "import"
n_report:   .asciz "report"
n_monthly:  .asciz "monthly"
n_cats:     .asciz "categories"
n_merch:    .asciz "merchants"
n_budget:   .asciz "budget"
n_accounts: .asciz "accounts"
n_list:     .asciz "list"
n_export:   .asciz "export"
n_setcat:   .asciz "set-category"
n_query:    .asciz "query"
f_table:    .asciz "table"
f_csv:      .asciz "csv"
f_json:     .asciz "json"
s_envconf:  .asciz "PQLEDGER_CONFIG"
s_defconf:  .asciz "pqledger.conf"
m_nocmd:    .asciz "missing command (try 'pqledger help')"
m_unkcmd:   .asciz "unknown command '%s'"
m_unkopt:   .asciz "unknown option '%s'"
m_repeat:   .asciz "option %s given more than once"
m_novalue:  .asciz "option %s requires a value"
m_surplus:  .asciz "unexpected argument '%s'"
m_missing:  .asciz "missing argument for %s"
m_badfmt:   .asciz "invalid output format '%s' (table, csv or json)"
m_report:   .asciz "report requires monthly, categories or merchants"
m_badmonth: .asciz "invalid month '%s' (YYYY-MM)"
m_mixmonth: .asciz "--month cannot be combined with --from or --to"
m_fromto:   .asciz "--from is later than --to"
m_badtop:   .asciz "--top requires a positive integer"
m_badacct:  .asciz "invalid account name '%s'"
m_badcat:   .asciz "invalid category name '%s'"
m_noacct:   .asciz "import requires --account NAME"
m_nomonth:  .asciz "budget requires --month YYYY-MM"
m_catuncat: .asciz "--category cannot be combined with --uncategorized"
m_badid:    .asciz "invalid transaction id '%s'"
m_setcat:   .asciz "set-category requires ID and CATEGORY or --clear"
m_write:    .asciz "cannot write the output"
s_usage:
    .ascii "usage: pqledger [--config PATH] [--format table|csv|json] COMMAND [ARGS]\n"
    .ascii "\n"
    .ascii "commands:\n"
    .ascii "  init                                  create the ledger (data_dir)\n"
    .ascii "  import FILE --account NAME            import a bank statement CSV\n"
    .ascii "  report monthly [FILTERS]              income, expenses, net per month\n"
    .ascii "  report categories [FILTERS]           spending per category with share\n"
    .ascii "  report merchants [FILTERS] [--top N]  top merchants by spending\n"
    .ascii "  budget --month YYYY-MM [--account A]  budget check (exit 3 if over)\n"
    .ascii "  accounts                              transactions and balance per account\n"
    .ascii "  list [FILTERS] [--category C | --uncategorized]\n"
    .ascii "  export [FILTERS]                      all columns, ordered by id\n"
    .ascii "  set-category ID CATEGORY | set-category ID --clear\n"
    .ascii "  query SQL                             SQL on transactions, batches, overrides,\n"
    .ascii "                                        ledger, rules, budgets\n"
    .ascii "  help, version\n"
    .ascii "\n"
    .ascii "filters: --month YYYY-MM | --from YYYY-MM | --to YYYY-MM, --account NAME\n"
    .ascii "configuration: --config PATH, else $PQLEDGER_CONFIG, else ./pqledger.conf\n"
    .asciz "see APP.md for the configuration reference and exit codes\n"
s_version:  .asciz "pqledger 1.0.0 (PolyQuery AArch64 assembly engine, embedded)\n"

    .data
    .p2align 3
// global options (before the command)
opts_global:
    .quad o_config, 1, g_opt_config
    .quad o_format, 1, g_opt_format
    .quad o_help, 0, g_opt_help
    .quad 0, 0, 0
opts_none:
    .quad 0, 0, 0
opts_import:
    .quad o_account, 1, g_opt_account
    .quad 0, 0, 0
opts_filters:
    .quad o_month, 1, g_opt_month
    .quad o_from, 1, g_opt_from
    .quad o_to, 1, g_opt_to
    .quad o_account, 1, g_opt_account
    .quad 0, 0, 0
opts_merch:
    .quad o_month, 1, g_opt_month
    .quad o_from, 1, g_opt_from
    .quad o_to, 1, g_opt_to
    .quad o_account, 1, g_opt_account
    .quad o_top, 1, g_opt_top
    .quad 0, 0, 0
opts_budget:
    .quad o_month, 1, g_opt_month
    .quad o_account, 1, g_opt_account
    .quad 0, 0, 0
opts_list:
    .quad o_month, 1, g_opt_month
    .quad o_from, 1, g_opt_from
    .quad o_to, 1, g_opt_to
    .quad o_account, 1, g_opt_account
    .quad o_category, 1, g_opt_category
    .quad o_uncat, 0, g_opt_uncat
    .quad 0, 0, 0
opts_setcat:
    .quad o_clear, 0, g_opt_clear
    .quad 0, 0, 0
// commands: name, id, options, positional arguments (max)
commands:
    .quad n_help, C_HELP, opts_none, 0
    .quad n_version, C_VERSION, opts_none, 0
    .quad n_init, C_INIT, opts_none, 0
    .quad n_import, C_IMPORT, opts_import, 1
    .quad n_budget, C_BUDGET, opts_budget, 0
    .quad n_accounts, C_ACCOUNTS, opts_none, 0
    .quad n_list, C_LIST, opts_list, 0
    .quad n_export, C_EXPORT, opts_filters, 0
    .quad n_setcat, C_SETCAT, opts_setcat, 2
    .quad n_query, C_QUERY, opts_none, 1
    .quad 0, 0, 0, 0
reports:
    .quad n_monthly, C_MONTHLY, opts_filters, 0
    .quad n_cats, C_CATS, opts_filters, 0
    .quad n_merch, C_MERCH, opts_merch, 0
    .quad 0, 0, 0, 0
// command handlers by id (commands.S); 0 = handled here
handlers:
    .quad 0, 0, cmd_init, cmd_import, cmd_report_monthly
    .quad cmd_report_categories, cmd_report_merchants, cmd_budget
    .quad cmd_accounts, cmd_list, cmd_export, cmd_set_category, cmd_query
    .text

// usage(x0 fmt, x1 arg): usage error (exit 1)
LFUNC usage
    mov  x2, x1
    mov  x1, x0
    mov  w0, #EX_USAGE
    b    fail
ENDF usage

// find_name(x0 cstr, x1 table, x2 record size) -> x0 record or 0   (names
// at offset 0, table ends with a 0 name)
//   x19 cstr, x20 record, x21 size
LFUNC find_name
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
1:  ldr  x1, [x20]
    cbz  x1, 2f
    mov  x0, x19
    bl   strcmp
    cbz  w0, 3f
    add  x20, x20, x21
    b    1b
2:  mov  x20, #0
3:  mov  x0, x20
    LEAVE 2
ENDF find_name

// parse_args(w0 argc, x1 argv, w2 first index, x3 option table, x4 max
// positional, w5 stop at first positional) -> w0 index after the parsed
// arguments
//   x19 argv, w20 argc, w21 index, x22 options, x23 max positional,
//   w24 stop flag, x25 current argument
LFUNC parse_args
    ENTER 5
    mov  w20, w0
    mov  x19, x1
    mov  w21, w2
    mov  x22, x3
    mov  x23, x4
    mov  w24, w5
1:  cmp  w21, w20
    b.ge 9f
    ldr  x25, [x19, w21, sxtw #3]
    ldrb w9, [x25]
    cmp  w9, #'-'
    b.ne 5f
    ldrb w9, [x25, #1]
    cmp  w9, #'-'
    b.ne 5f
    mov  x0, x25                    // an option
    mov  x1, x22
    mov  x2, #OPT_SIZE
    bl   find_name
    cbnz x0, 2f
    ADR_L x0, m_unkopt
    mov  x1, x25
    bl   usage
2:  ldr  x10, [x0, #OPT_DEST]
    ldr  x9, [x10]
    cbz  x9, 3f
    ADR_L x0, m_repeat
    mov  x1, x25
    bl   usage
3:  add  w21, w21, #1
    ldr  x9, [x0, #OPT_KIND]
    cbnz x9, 4f
    mov  x9, #1                     // flag
    str  x9, [x10]
    b    1b
4:  cmp  w21, w20                   // value: the next argument
    b.lt 41f
    ADR_L x0, m_novalue
    mov  x1, x25
    bl   usage
41: ldr  x9, [x19, w21, sxtw #3]
    str  x9, [x10]
    add  w21, w21, #1
    b    1b
5:  cbnz w24, 9f                    // positional argument
    LDR_G x9, g_npos
    cmp  x9, x23
    b.lo 6f
    ADR_L x0, m_surplus
    mov  x1, x25
    bl   usage
6:  ADR_L x10, g_pos0
    str  x25, [x10, x9, lsl #3]
    add  x9, x9, #1
    STR_G x9, g_npos, x10
    add  w21, w21, #1
    b    1b
9:  mov  w0, w21
    LEAVE 5
ENDF parse_args

// parse_month(x0 cstr) -> x0 month index y*12 + (m-1), or -1 if not a
// valid YYYY-MM (year 0001-9999, month 01-12)   (leaf)
FUNC parse_month
    mov  x9, x0
    mov  x0, #-1
    mov  x10, #0                    // year
    mov  x11, #0
1:  ldrb w12, [x9, x11]
    sub  w12, w12, #'0'
    cmp  w12, #9
    b.hi 9f
    mov  x13, #10
    madd x10, x10, x13, x12
    add  x11, x11, #1
    cmp  x11, #4
    b.lo 1b
    ldrb w12, [x9, #4]
    cmp  w12, #'-'
    b.ne 9f
    ldrb w12, [x9, #5]
    ldrb w13, [x9, #6]
    ldrb w14, [x9, #7]
    cbnz w14, 9f
    sub  w12, w12, #'0'
    sub  w13, w13, #'0'
    cmp  w12, #9
    b.hi 9f
    cmp  w13, #9
    b.hi 9f
    mov  w14, #10
    madd w12, w12, w14, w13         // month
    sub  w12, w12, #1
    cmp  w12, #11
    b.hi 9f
    cbz  x10, 9f
    mov  x13, #12
    madd x0, x10, x13, x12
9:  ret
ENDF parse_month

// check_month(x0 cstr or 0) -> x0 month index or -1 if absent (usage error
// if invalid)
LFUNC check_month
    cbz  x0, 8f
    ENTER 1
    mov  x19, x0
    bl   parse_month
    tbz  x0, #63, 1f
    ADR_L x0, m_badmonth
    mov  x1, x19
    bl   usage
1:  LEAVE 1
8:  mov  x0, #-1
    ret
ENDF check_month

// validate_options(w0 command id): checks of option values (usage errors)
//   w19 command, x20 from, x21 to
LFUNC validate_options
    ENTER 3
    mov  w19, w0
    LDR_G x0, g_opt_month
    bl   check_month
    LDR_G x0, g_opt_from
    bl   check_month
    mov  x20, x0
    LDR_G x0, g_opt_to
    bl   check_month
    mov  x21, x0
    LDR_G x9, g_opt_month
    cbz  x9, 1f
    LDR_G x10, g_opt_from
    LDR_G x11, g_opt_to
    orr  x10, x10, x11
    cbz  x10, 1f
    ADR_L x0, m_mixmonth
    bl   usage
1:  tbnz x20, #63, 2f
    tbnz x21, #63, 2f
    cmp  x20, x21
    b.le 2f
    ADR_L x0, m_fromto
    bl   usage
2:  LDR_G x0, g_opt_account
    cbz  x0, 3f
    bl   valid_name
    cbnz w0, 3f
    ADR_L x0, m_badacct
    LDR_G x1, g_opt_account
    bl   usage
3:  LDR_G x0, g_opt_top
    cbz  x0, 4f
    bl   strlen
    mov  x1, x0
    LDR_G x0, g_opt_top
    bl   parse_u64
    cbnz w1, 31f
    cbnz x0, 4f
31: ADR_L x0, m_badtop
    bl   usage
4:  LDR_G x0, g_opt_category
    cbz  x0, 5f
    LDR_G x9, g_opt_uncat
    cbz  x9, 41f
    ADR_L x0, m_catuncat
    bl   usage
41: bl   valid_name
    cbnz w0, 5f
    ADR_L x0, m_badcat
    LDR_G x1, g_opt_category
    bl   usage
5:  cmp  w19, #C_IMPORT
    b.ne 6f
    LDR_G x9, g_npos
    cbnz x9, 51f
    ADR_L x0, m_missing
    ADR_L x1, n_import
    bl   usage
51: LDR_G x9, g_opt_account
    cbnz x9, 6f
    ADR_L x0, m_noacct
    bl   usage
6:  cmp  w19, #C_BUDGET
    b.ne 7f
    LDR_G x9, g_opt_month
    cbnz x9, 7f
    ADR_L x0, m_nomonth
    bl   usage
7:  cmp  w19, #C_QUERY
    b.ne 8f
    LDR_G x9, g_npos
    cbnz x9, 8f
    ADR_L x0, m_missing
    ADR_L x1, n_query
    bl   usage
8:  cmp  w19, #C_SETCAT
    b.ne 9f
    bl   validate_setcat
9:  LEAVE 3
ENDF validate_options

// validate_setcat(): ID CATEGORY, or ID --clear
LFUNC validate_setcat
    ENTER 1
    LDR_G x9, g_npos
    LDR_G x10, g_opt_clear
    add  x9, x9, x10                // exactly ID + (CATEGORY xor --clear)
    cmp  x9, #2
    b.ne 8f
    LDR_G x9, g_npos
    cbz  x9, 8f
    LDR_G x19, g_pos0               // ID: positive integer
    mov  x0, x19
    bl   strlen
    mov  x1, x0
    mov  x0, x19
    bl   parse_u64
    cbnz w1, 1f
    cbnz x0, 2f
1:  ADR_L x0, m_badid
    mov  x1, x19
    bl   usage
2:  LDR_G x9, g_opt_clear
    cbnz x9, 9f
    LDR_G x19, g_pos1               // CATEGORY: a category name
    mov  x0, x19
    bl   valid_name
    cbz  w0, 3f
    mov  x0, x19
    CSTR x1, "uncategorized"
    bl   strcmp
    cbnz w0, 9f
3:  ADR_L x0, m_badcat
    mov  x1, x19
    bl   usage
8:  ADR_L x0, m_setcat
    bl   usage
9:  LEAVE 1
ENDF validate_setcat

// locate_config() -> x0 path: --config, else $PQLEDGER_CONFIG (non-empty),
// else ./pqledger.conf
LFUNC locate_config
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    LDR_G x0, g_opt_config
    cbnz x0, 9f
    ADR_L x0, s_envconf
    bl   getenv
    cbz  x0, 1f
    ldrb w9, [x0]
    cbnz w9, 9f
1:  ADR_L x0, s_defconf
9:  ldp  x29, x30, [sp], #16
    ret
ENDF locate_config

// main(w0 argc, x1 argv) -> exit status
//   w19 argc, x20 argv, w21 index, x22 command record, w23 command id,
//   w24 exit status
FUNC main
    ENTER 4
    mov  w19, w0
    mov  x20, x1
    // global options, up to the command word
    mov  w0, w19
    mov  x1, x20
    mov  w2, #1
    ADR_L x3, opts_global
    mov  x4, #0
    mov  w5, #1
    bl   parse_args
    mov  w21, w0
    LDR_G x9, g_opt_format          // --format
    cbz  x9, 2f
    mov  x0, x9
    ADR_L x1, f_table
    bl   strcmp
    mov  x10, #OF_TABLE
    cbz  w0, 1f
    LDR_G x0, g_opt_format
    ADR_L x1, f_csv
    bl   strcmp
    mov  x10, #OF_CSV
    cbz  w0, 1f
    LDR_G x0, g_opt_format
    ADR_L x1, f_json
    bl   strcmp
    mov  x10, #OF_JSON
    cbz  w0, 1f
    ADR_L x0, m_badfmt
    LDR_G x1, g_opt_format
    bl   usage
1:  STR_G x10, g_format, x9
    b    3f
2:  mov  x10, #OF_UNSET
    STR_G x10, g_format, x9
3:  LDR_G x9, g_opt_help            // --help = help
    cbz  x9, 4f
    mov  w23, #C_HELP
    cmp  w21, w19
    b.ge .Lmain_run
    ADR_L x0, m_surplus
    ldr  x1, [x20, w21, sxtw #3]
    bl   usage
4:  cmp  w21, w19
    b.lt 5f
    ADR_L x0, m_nocmd
    bl   usage
5:  ldr  x0, [x20, w21, sxtw #3]    // the command word
    add  w21, w21, #1
    ADR_L x1, n_report
    bl   strcmp
    cbnz w0, 6f
    cmp  w21, w19                   // report SUBCOMMAND
    b.lt 51f
    ADR_L x0, m_report
    bl   usage
51: ldr  x0, [x20, w21, sxtw #3]
    ADR_L x1, reports
    mov  x2, #CMD_SIZE
    bl   find_name
    cbnz x0, 52f
    ADR_L x0, m_report
    bl   usage
52: add  w21, w21, #1
    b    7f
6:  sub  w9, w21, #1
    ldr  x0, [x20, w9, sxtw #3]
    ADR_L x1, commands
    mov  x2, #CMD_SIZE
    bl   find_name
    cbnz x0, 7f
    ADR_L x0, m_unkcmd
    sub  w9, w21, #1
    ldr  x1, [x20, w9, sxtw #3]
    bl   usage
7:  mov  x22, x0
    ldr  x23, [x22, #CMD_ID]
    mov  w0, w19                    // command options and arguments
    mov  x1, x20
    mov  w2, w21
    ldr  x3, [x22, #CMD_OPTS]
    ldr  x4, [x22, #CMD_NPOS]
    mov  w5, #0
    bl   parse_args
    mov  w0, w23
    bl   validate_options
.Lmain_run:
    cmp  w23, #C_HELP
    b.ne 8f
    ADR_L x0, g_out
    ADR_L x1, s_usage
    bl   buf_puts
    mov  w24, #EX_OK
    b    .Lmain_out
8:  cmp  w23, #C_VERSION
    b.ne 9f
    ADR_L x0, g_out
    ADR_L x1, s_version
    bl   buf_puts
    mov  w24, #EX_OK
    b    .Lmain_out
9:  bl   locate_config              // configuration (exit 2 on errors)
    STR_G x0, g_config_path, x9
    bl   cfg_load
    LDR_G x9, g_format              // --format, else [output] format
    cmn  x9, #1
    b.ne 10f
    LDR_G x9, g_cfg_format
    cmn  x9, #1
    b.ne 91f
    mov  x9, #OF_TABLE
91: STR_G x9, g_format, x10
10: ADR_L x9, handlers
    ldr  x9, [x9, w23, uxtw #3]
    blr  x9                         // -> w0 exit status (0 or 3)
    mov  w24, w0
.Lmain_out:
    ADR_L x9, g_out
    mov  w0, #1
    ldr  x1, [x9, #BUF_PTR]
    ldr  x2, [x9, #BUF_LEN]
    bl   write_all
    cbz  w0, 11f
    mov  w0, #EX_OTHER
    ADR_L x1, m_write
    bl   fail
11: bl   ledger_close               // release the engine instance
    mov  w0, w24
    LEAVE 4
ENDF main

    NOTE_GNU_STACK
