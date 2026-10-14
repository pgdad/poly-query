// =============================================================================
// test_config.S — unit test of app/config.S (configuration, rules and budget
// files). Build from the implementation directory:
//
//   gcc -Iinclude -Iapp -g -Wa,--fatal-warnings -o /tmp/test_config \
//       app/tests/test_config.S app/config.S app/util.S && /tmp/test_config
//
// The test works in a fresh directory made with mkdtemp (removed at the end).
// Error cases run the call in a fork()ed child (stderr sent to /dev/null
// unless PQL_TEST_VERBOSE is set) and expect exit status 2.
// Prints "test_config: N passed" and exits 0, or lists the failed checks and
// exits 1.
//
//   expect_eq(x0 actual, x1 expected, x2 label)
//   expect_str(x0 actual cstr or 0, x1 expected cstr, x2 label)
//   expect_exit2(x0 function, x1 its argument, x2 label)
//   expect_load_err(x0 load function, x1 file content, x2 label)
//   write_file(x0 name, x1 content)
// =============================================================================
#include "ledger.inc"

// --------------------------------------------------------------- macros -----
// STR_AT reg, "text": reg = address of a constant string in .rodata
.macro STR_AT reg, text
    .pushsection .rodata
9990: .asciz "\text"
    .popsection
    ADR_L \reg, 9990b
.endm

// EQI "label", value: expect x0 == value (small immediate)
.macro EQI label, value
    mov  x1, #\value
    STR_AT x2, "\label"
    bl   expect_eq
.endm

// EQL "label", value: expect x0 == value (any 64-bit constant)
.macro EQL label, value
    ldr  x1, =\value
    STR_AT x2, "\label"
    bl   expect_eq
.endm

// SEQ "label", "text": expect the cstr x0 to equal text
.macro SEQ label, text
    STR_AT x1, "\text"
    STR_AT x2, "\label"
    bl   expect_str
.endm

// field checks of the IS struct at x19
.macro ISW off, value, label
    ldr  w0, [x19, #\off]
    EQI  "\label", \value
.endm
.macro ISX off, value, label
    ldr  x0, [x19, #\off]
    EQI  "\label", \value
.endm
.macro ISS off, text, label
    ldr  x0, [x19, #\off]
    SEQ  "\label", "\text"
.endm

// SETTINGS "account": cfg_import_settings(account, x19)
.macro SETTINGS name
    STR_AT x0, "\name"
    mov  x1, x19
    bl   cfg_import_settings
.endm

// WRITE "name", "content"
.macro WRITE name, content
    STR_AT x0, "\name"
    STR_AT x1, "\content"
    bl   write_file
.endm

// CFG_ERR / RULES_ERR / BUDGET_ERR "content", "label": loading a file with
// this content must exit 2
.macro LOAD_ERR fn, content, label
    ADR_L x0, \fn
    STR_AT x1, "\content"
    STR_AT x2, "\label"
    bl   expect_load_err
.endm
.macro CFG_ERR content, label
    LOAD_ERR cfg_load, "\content", "\label"
.endm
.macro RULES_ERR content, label
    LOAD_ERR rules_load, "\content", "\label"
.endm
.macro BUDGET_ERR content, label
    LOAD_ERR budget_load, "\content", "\label"
.endm

// MISSING fn, "label": loading a file that does not exist must exit 2
.macro MISSING fn, label
    ADR_L x0, \fn
    STR_AT x1, "does-not-exist.conf"
    STR_AT x2, "\label"
    bl   expect_exit2
.endm

// ---------------------------------------------------------------- data ------
    .data
tmpdir:     .asciz "/tmp/pqlcfgXXXXXX"

    .bss
    .p2align 3
n_pass:     .skip 8
n_fail:     .skip 8
cmdbuf:     .skip 256

    .section .rodata
s_fail_eq:  .asciz "FAIL: %s: got %ld, want %ld\n"
s_fail_str: .asciz "FAIL: %s: got \"%s\", want \"%s\"\n"
s_ok:       .asciz "test_config: %ld passed\n"
s_bad:      .asciz "test_config: %ld passed, %ld FAILED\n"
s_errfile:  .asciz "err.txt"

    .text

// ============================================================== helpers =====

// die(x0 message): perror and exit 99 (test infrastructure broken)
LFUNC die
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    bl   perror
    mov  w0, #99
    bl   exit
ENDF die

// count_pass(): n_pass += 1   (leaf)
LFUNC count_pass
    ADR_L x9, n_pass
    ldr  x10, [x9]
    add  x10, x10, #1
    str  x10, [x9]
    ret
ENDF count_pass

// count_fail(): n_fail += 1   (leaf)
LFUNC count_fail
    ADR_L x9, n_fail
    ldr  x10, [x9]
    add  x10, x10, #1
    str  x10, [x9]
    ret
ENDF count_fail

// expect_eq(x0 actual, x1 expected, x2 label)
LFUNC expect_eq
    cmp  x0, x1
    b.eq count_pass                 // tail call
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    mov  x3, x1
    mov  x9, x2
    mov  x2, x0
    mov  x1, x9
    ADR_L x0, s_fail_eq
    bl   printf
    bl   count_fail
    ldp  x29, x30, [sp], #16
    ret
ENDF expect_eq

// expect_str(x0 actual or 0, x1 expected, x2 label)
//   x19 actual, x20 expected, x21 label
LFUNC expect_str
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    cbz  x19, 1f
    mov  x1, x20
    bl   strcmp
    cbnz w0, 1f
    bl   count_pass
    LEAVE 2
1:  ADR_L x0, s_fail_str
    mov  x1, x21
    mov  x2, x19
    mov  x3, x20
    bl   printf
    bl   count_fail
    LEAVE 2
ENDF expect_str

// write_file(x0 name, x1 content): create/overwrite the file
//   x19 name, x20 content, x21 FILE*
LFUNC write_file
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    STR_AT x1, "w"
    bl   fopen
    cbnz x0, 1f
    mov  x0, x19
    bl   die
1:  mov  x21, x0
    mov  x0, x20
    mov  x1, x21
    bl   fputs
    mov  x0, x21
    bl   fclose
    LEAVE 2
ENDF write_file

// expect_exit2(x0 function, x1 argument, x2 label): function(argument) in a
// child process must exit with status 2
//   x19 function, x20 argument, x21 label, x22 pid; sp: wait status
LFUNC expect_exit2
    ENTER 2
    sub  sp, sp, #16
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x0, #0
    bl   fflush                     // the child must not repeat our output
    bl   fork
    cmp  w0, #0
    b.eq .Lee_child
    b.gt 1f
    STR_AT x0, "fork"
    bl   die
1:  mov  w22, w0
    mov  w0, w22
    mov  x1, sp
    mov  w2, #0
    bl   waitpid
    cmp  w0, #0
    b.gt 2f
    STR_AT x0, "waitpid"
    bl   die
2:  ldr  w9, [sp]
    ands w10, w9, #0x7f             // killed by a signal: 1000 + signal
    b.eq 3f
    add  w0, w10, #1000
    b    4f
3:  ubfx w0, w9, #8, #8             // WEXITSTATUS
4:  mov  x1, #2
    mov  x2, x21
    bl   expect_eq
    add  sp, sp, #16
    LEAVE 2

.Lee_child:
    STR_AT x0, "PQL_TEST_VERBOSE"
    bl   getenv
    cbnz x0, 5f
    STR_AT x0, "/dev/null"
    mov  w1, #1                     // O_WRONLY
    bl   open
    cmp  w0, #0
    b.lt 5f
    mov  w1, #2
    bl   dup2
5:  mov  x0, x20
    blr  x19
    mov  w0, #0                     // returned: not an error
    bl   _exit
ENDF expect_exit2

// expect_load_err(x0 load function, x1 content, x2 label): write the content
// to err.txt; loading it must exit 2
//   x19 function, x20 label
LFUNC expect_load_err
    ENTER 1
    mov  x19, x0
    mov  x20, x2
    ADR_L x0, s_errfile
    bl   write_file
    mov  x0, x19
    ADR_L x1, s_errfile
    mov  x2, x20
    bl   expect_exit2
    LEAVE 1
ENDF expect_load_err

// ================================================================ tests =====

// The example configuration of spec §3.3.
//   x19 IS struct (on the stack)
LFUNC test_example
    ENTER 1
    sub  sp, sp, #IS_SIZE
    mov  x19, sp
    WRITE "ex.conf", "[ledger]\ndata_dir = ledger\nrules_file = rules.conf\nbudget_file = budgets.conf\n\n[import]\ndate_column = Date\ndescription_column = Description\namount_column = Amount\n\n[account visa]\ndate_format = MM/DD/YYYY\ninvert_sign = true\n\n[account sparkonto]\ndelimiter = ;\ndate_format = DD.MM.YYYY\ndecimal_separator = ,\nthousands_separator = .\namount_mode = debit_credit\ndebit_column = Soll\ncredit_column = Haben\n"
    STR_AT x0, "ex.conf"
    bl   cfg_load
    LDR_G x0, g_cfg_data_dir
    SEQ  "example data_dir", "ledger"
    LDR_G x0, g_cfg_rules_file
    SEQ  "example rules_file", "rules.conf"
    LDR_G x0, g_cfg_budget_file
    SEQ  "example budget_file", "budgets.conf"
    LDR_G x0, g_cfg_format
    EQI  "example format unset", OF_UNSET
    LDR_G x0, g_cfg_threads
    EQI  "example threads unset", 0
    LDR_G x0, g_cfg_memory_mb
    EQI  "example memory_mb unset", 0

    SETTINGS "visa"
    ISW  IS_DELIM, 44, "visa delimiter"
    ISW  IS_HEADER, 1, "visa header"
    ISX  IS_SKIP, 0, "visa skip_lines"
    ISS  IS_DATE_COL, "Date", "visa date_column"
    ISW  IS_DATE_FMT, DF_MDY_SLASH, "visa date_format"
    ISS  IS_DESC_COL, "Description", "visa description_column"
    ISW  IS_AMOUNT_MODE, AM_SIGNED, "visa amount_mode"
    ISS  IS_AMOUNT_COL, "Amount", "visa amount_column"
    ISW  IS_DEC_SEP, 46, "visa decimal_separator"
    ISW  IS_THOU_SEP, 0, "visa thousands_separator"
    ISS  IS_CURRENCY, "", "visa currency_symbol"
    ISW  IS_INVERT, 1, "visa invert_sign"

    SETTINGS "sparkonto"
    ISW  IS_DELIM, 59, "sparkonto delimiter"
    ISW  IS_HEADER, 1, "sparkonto header"
    ISS  IS_DATE_COL, "Date", "sparkonto date_column"
    ISW  IS_DATE_FMT, DF_DMY_DOT, "sparkonto date_format"
    ISW  IS_AMOUNT_MODE, AM_DEBIT_CREDIT, "sparkonto amount_mode"
    ISS  IS_DEBIT_COL, "Soll", "sparkonto debit_column"
    ISS  IS_CREDIT_COL, "Haben", "sparkonto credit_column"
    ISW  IS_DEC_SEP, 44, "sparkonto decimal_separator"
    ISW  IS_THOU_SEP, 46, "sparkonto thousands_separator"
    ISW  IS_INVERT, 0, "sparkonto invert_sign"

    SETTINGS "other"                // no section: [import] + defaults
    ISW  IS_DELIM, 44, "other delimiter"
    ISW  IS_DATE_FMT, DF_YMD_DASH, "other date_format"
    ISS  IS_DEBIT_COL, "Debit", "other debit_column"
    ISS  IS_CREDIT_COL, "Credit", "other credit_column"
    ISS  IS_CURRENCY, "", "other currency_symbol"
    add  sp, sp, #IS_SIZE
    LEAVE 1
ENDF test_example

// BOM, CRLF, comments, indentation, quoting, `tab`, [output], [engine],
// header = false with numeric columns, and reset by a second cfg_load.
//   x19 IS struct
LFUNC test_syntax
    ENTER 1
    sub  sp, sp, #IS_SIZE
    mov  x19, sp
    WRITE "syn.conf", "\357\273\277# comment\r\n; another comment\r\n[ledger]\r\n  data_dir = \"/abs/data\"  \r\n\r\n[output]\r\nformat = csv\r\n[engine]\r\nthreads = 4\r\nmemory_mb=256\r\n[import]\r\ndelimiter = tab\r\nheader = false\r\nskip_lines = 2\r\ndate_column = 1\r\ndescription_column = 2\r\namount_column = 3\r\ncurrency_symbol = \"  a\\\"b\\\\c\\d  \"\r\n\t[account x-1_y]\t\r\nheader = true\r\ndate_column = Datum\r\nthousands_separator = space\r\ndelimiter = \"|\"\r\ncurrency_symbol = \"\"\r\n[account q]\r\ndelimiter = \" \"\r\nthousands_separator = '\r\ninvert_sign = false\r\ndate_format = YYYYMMDD\r\ncurrency_symbol = \"x\"y\"\r\n"
    STR_AT x0, "syn.conf"
    bl   cfg_load
    LDR_G x0, g_cfg_data_dir
    SEQ  "syntax absolute data_dir", "/abs/data"
    LDR_G x0, g_cfg_rules_file
    EQI  "syntax no rules_file", 0
    LDR_G x0, g_cfg_budget_file
    EQI  "syntax no budget_file", 0
    LDR_G x0, g_cfg_format
    EQI  "syntax format csv", OF_CSV
    LDR_G x0, g_cfg_threads
    EQI  "syntax threads", 4
    LDR_G x0, g_cfg_memory_mb
    EQI  "syntax memory_mb", 256

    mov  x0, #0                     // no account: [import] + defaults
    mov  x1, x19
    bl   cfg_import_settings
    ISW  IS_DELIM, 9, "import tab delimiter"
    ISW  IS_HEADER, 0, "import header false"
    ISX  IS_SKIP, 2, "import skip_lines"
    ISS  IS_DATE_COL, "1", "import date_column"
    ISS  IS_DESC_COL, "2", "import description_column"
    ISS  IS_AMOUNT_COL, "3", "import amount_column"
    ISS  IS_CURRENCY, "  a\"b\\c\\d  ", "import quoted currency_symbol"

    SETTINGS "x-1_y"
    ISW  IS_DELIM, 124, "x-1_y quoted delimiter"
    ISW  IS_HEADER, 1, "x-1_y header"
    ISX  IS_SKIP, 2, "x-1_y skip_lines from [import]"
    ISS  IS_DATE_COL, "Datum", "x-1_y date_column"
    ISS  IS_DESC_COL, "2", "x-1_y description_column from [import]"
    ISW  IS_THOU_SEP, 32, "x-1_y thousands space"
    ISS  IS_CURRENCY, "", "x-1_y empty quoted currency"

    SETTINGS "q"
    ISW  IS_DELIM, 32, "q space delimiter"
    ISW  IS_THOU_SEP, 39, "q thousands apostrophe"
    ISW  IS_INVERT, 0, "q invert_sign false"
    ISW  IS_DATE_FMT, DF_YMD, "q date_format YYYYMMDD"
    ISS  IS_CURRENCY, "x\"y", "q inner quote kept"

    // a second load forgets everything of the first one
    WRITE "min.conf", "[ledger]\ndata_dir=d\n[import]\ndelimiter = ;\n[account a]\ndelimiter = ,\n[output]\nformat = json\n"
    STR_AT x0, "min.conf"
    bl   cfg_load
    LDR_G x0, g_cfg_threads
    EQI  "reload threads reset", 0
    LDR_G x0, g_cfg_format
    EQI  "reload format json", OF_JSON
    SETTINGS "x-1_y"
    ISW  IS_DELIM, 59, "reload old account gone"
    ISW  IS_HEADER, 1, "reload header default"
    SETTINGS "a"
    ISW  IS_DELIM, 44, "same key in another section"
    add  sp, sp, #IS_SIZE
    LEAVE 1
ENDF test_syntax

// Relative paths are resolved against the configuration file's directory.
LFUNC test_resolve
    ENTER 0
    STR_AT x0, "conf"
    mov  w1, #0755
    bl   mkdir
    WRITE "conf/main.conf", "[ledger]\ndata_dir = ../books\nrules_file = /etc/r.conf\nbudget_file = b.conf\n"
    STR_AT x0, "conf/main.conf"
    bl   cfg_load
    LDR_G x0, g_cfg_data_dir
    SEQ  "resolve data_dir", "conf/../books"
    LDR_G x0, g_cfg_rules_file
    SEQ  "resolve absolute rules_file", "/etc/r.conf"
    LDR_G x0, g_cfg_budget_file
    SEQ  "resolve budget_file", "conf/b.conf"
    LEAVE 0
ENDF test_resolve

// Every class of configuration error exits 2.
LFUNC test_cfg_errors
    ENTER 0
    MISSING cfg_load, "missing configuration file"
    CFG_ERR "[ledger]\ndata_dir = l\ncolour = blue\n", "unknown key"
    CFG_ERR "[ledger]\ndata_dir = l\ndata_dir = m\n", "repeated key"
    CFG_ERR "[ledger]\ndata_dir = l\n[output]\nformat = csv\nformat = csv\n", "repeated key in [output]"
    CFG_ERR "data_dir = l\n[ledger]\ndata_dir = l\n", "assignment before section"
    CFG_ERR "[ledger]\ndata_dir = l\n[accounts]\n", "unknown section"
    CFG_ERR "[ledger]\ndata_dir = l\n[account ]\n", "account without name"
    CFG_ERR "[ledger]\nrules_file = r\n", "missing data_dir"
    CFG_ERR "[import]\nheader = true\n", "missing [ledger]"
    CFG_ERR "", "empty configuration"
    CFG_ERR "[ledger]\ndata_dir = \"\"\n", "empty data_dir"
    CFG_ERR "[ledger]\ndata_dir = l\n[output]\nformat = xml\n", "bad format"
    CFG_ERR "[ledger]\ndata_dir = l\n[import]\nheader = yes\n", "header = yes"
    CFG_ERR "[ledger]\ndata_dir = l\n[import]\ninvert_sign = TRUE\n", "invert_sign = TRUE"
    CFG_ERR "[ledger]\ndata_dir = l\n[ledger]\n", "repeated section"
    CFG_ERR "[ledger]\ndata_dir = l\n[account a]\n[account a]\n", "repeated account section"
    CFG_ERR "[ledger]\ndata_dir = l\n[account eu]\ndecimal_separator = ,\nthousands_separator = ,\n", "same separators in account"
    CFG_ERR "[ledger]\ndata_dir = l\n[import]\nthousands_separator = ,\n[account eu]\ndecimal_separator = ,\n", "same separators merged"
    CFG_ERR "[ledger]\ndata_dir = l\n[import]\nthousands_separator = .\n", "same separators in [import]"
    CFG_ERR "[ledger]\ndata_dir = l\n[import]\nheader = false\ndate_column = 1\ndescription_column = 2\n", "default name column with header false"
    CFG_ERR "[ledger]\ndata_dir = l\n[import]\nheader = false\ndate_column = 1\ndescription_column = 2\namount_column = 3\n[account a]\ndate_column = Datum\n", "account name column with header false"
    CFG_ERR "[ledger]\ndata_dir = l\n[account a]\nheader = false\ndate_column = 1\ndescription_column = 2\namount_mode = debit_credit\ndebit_column = 3\n", "credit name column with header false"
    CFG_ERR "[ledger]\ndata_dir = l\n[account Visa]\n", "uppercase account name"
    CFG_ERR "[ledger]\ndata_dir = l\n[account  a]\n", "two spaces before account name"
    CFG_ERR "[ledger]\ndata_dir = l\n[account abcdefghijabcdefghijabcdefghijabc]\n", "33-character account name"
    CFG_ERR "[ledger]\ndata_dir = l\n[import]\ndelimiter = \"\\\"\"\n", "quote delimiter"
    CFG_ERR "[ledger]\ndata_dir = l\n[import]\ndelimiter = ab\n", "two-character delimiter"
    CFG_ERR "[ledger]\ndata_dir = l\n[import]\ndelimiter = \"\"\n", "empty delimiter"
    CFG_ERR "[ledger]\ndata_dir = l\n[import]\ndelimiter = \351\n", "non-ASCII delimiter"
    CFG_ERR "[ledger]\ndata_dir = l\n[import]\nskip_lines = -1\n", "negative skip_lines"
    CFG_ERR "[ledger]\ndata_dir = l\n[import]\ndate_column = 0\n", "column 0"
    CFG_ERR "[ledger]\ndata_dir = l\n[import]\ndate_column =\n", "empty column"
    CFG_ERR "[ledger]\ndata_dir = l\n[import]\ndate_format = yyyy-mm-dd\n", "bad date_format"
    CFG_ERR "[ledger]\ndata_dir = l\n[import]\namount_mode = Signed\n", "bad amount_mode"
    CFG_ERR "[ledger]\ndata_dir = l\n[import]\ndecimal_separator = ;\n", "bad decimal_separator"
    CFG_ERR "[ledger]\ndata_dir = l\n[import]\nthousands_separator = _\n", "bad thousands_separator"
    CFG_ERR "[ledger]\ndata_dir = l\n[engine]\nthreads = 0\n", "threads = 0"
    CFG_ERR "[ledger]\ndata_dir = l\n[engine]\nmemory_mb = 1k\n", "memory_mb = 1k"
    CFG_ERR "[ledger]\ndata_dir = l\njust text\n", "invalid line"
    CFG_ERR "[ledger]\n = x\ndata_dir = l\n", "empty key"
    CFG_ERR "[ledger]\ndata_dir = l\n[import\n", "unterminated section header"
    LEAVE 0
ENDF test_cfg_errors

// rules_load: order, trimming, quoting, errors.
//   x19 RULE array, x20 count
LFUNC test_rules
    ENTER 1
    WRITE "rules.conf", "# rules\r\ngroceries = WHOLE FOODS*,  TRADER JOE* ,SAFEWAY\n\n; x\n\tcoffee = \"SQ *BLUE BOTTLE*, CAF\303\251*\"\ngroceries = REWE*"
    STR_AT x0, "rules.conf"
    bl   rules_load
    mov  x19, x0
    mov  x20, x1
    mov  x0, x20
    EQI  "rules count", 6
    ldr  x0, [x19, #(0 * RULE_SIZE + RULE_CAT)]
    SEQ  "rule 0 category", "groceries"
    ldr  x0, [x19, #(0 * RULE_SIZE + RULE_PAT)]
    SEQ  "rule 0 pattern", "WHOLE FOODS*"
    ldr  x0, [x19, #(1 * RULE_SIZE + RULE_PAT)]
    SEQ  "rule 1 pattern trimmed", "TRADER JOE*"
    ldr  x0, [x19, #(2 * RULE_SIZE + RULE_PAT)]
    SEQ  "rule 2 pattern", "SAFEWAY"
    ldr  x0, [x19, #(3 * RULE_SIZE + RULE_CAT)]
    SEQ  "rule 3 category", "coffee"
    ldr  x0, [x19, #(3 * RULE_SIZE + RULE_PAT)]
    SEQ  "rule 3 quoted pattern", "SQ *BLUE BOTTLE*"
    ldr  x0, [x19, #(4 * RULE_SIZE + RULE_PAT)]
    SEQ  "rule 4 UTF-8 pattern", "CAF\303\251*"
    ldr  x0, [x19, #(5 * RULE_SIZE + RULE_CAT)]
    SEQ  "rule 5 category again", "groceries"
    ldr  x0, [x19, #(5 * RULE_SIZE + RULE_PAT)]
    SEQ  "rule 5 pattern (no final newline)", "REWE*"

    WRITE "empty.conf", ""
    STR_AT x0, "empty.conf"
    bl   rules_load
    mov  x0, x1
    EQI  "empty rules file", 0
    WRITE "comments.conf", "\357\273\277# only\r\n\r\n; comments\r\n"
    STR_AT x0, "comments.conf"
    bl   rules_load
    mov  x0, x1
    EQI  "comment-only rules file", 0

    MISSING rules_load, "missing rules file"
    RULES_ERR "groceries = SAFE_WAY\n", "rule with _"
    RULES_ERR "groceries = 100%\n", "rule with %"
    RULES_ERR "a = x,,y\n", "empty pattern"
    RULES_ERR "a = x,\n", "trailing comma"
    RULES_ERR "a =\n", "no pattern"
    RULES_ERR "uncategorized = X\n", "uncategorized rule"
    RULES_ERR "Groceries = X\n", "uppercase category"
    RULES_ERR "[rules]\na = X\n", "section in rules file"
    RULES_ERR "a = X\njust text\n", "invalid rules line"
    LEAVE 1
ENDF test_rules

// budget_load: amounts in cents, errors.
//   x19 BUD array, x20 count
LFUNC test_budget
    ENTER 1
    WRITE "budgets.conf", "groceries = 600\r\ncoffee = 30.00\n\n# c\nshopping = 150.5\nbig = 1234567890123456.99\nzero = 0\nquoted = \"7.05\"\n"
    STR_AT x0, "budgets.conf"
    bl   budget_load
    mov  x19, x0
    mov  x20, x1
    mov  x0, x20
    EQI  "budget count", 6
    ldr  x0, [x19, #(0 * BUD_SIZE + BUD_CAT)]
    SEQ  "budget 0 category", "groceries"
    ldr  x0, [x19, #(0 * BUD_SIZE + BUD_CENTS)]
    EQL  "budget 600", 60000
    ldr  x0, [x19, #(1 * BUD_SIZE + BUD_CENTS)]
    EQL  "budget 30.00", 3000
    ldr  x0, [x19, #(2 * BUD_SIZE + BUD_CAT)]
    SEQ  "budget 2 category", "shopping"
    ldr  x0, [x19, #(2 * BUD_SIZE + BUD_CENTS)]
    EQL  "budget 150.5", 15050
    ldr  x0, [x19, #(3 * BUD_SIZE + BUD_CENTS)]
    EQL  "budget 16 integer digits", 123456789012345699
    ldr  x0, [x19, #(4 * BUD_SIZE + BUD_CENTS)]
    EQL  "budget 0", 0
    ldr  x0, [x19, #(5 * BUD_SIZE + BUD_CENTS)]
    EQL  "budget quoted 7.05", 705

    MISSING budget_load, "missing budget file"
    BUDGET_ERR "a = 12.345\n", "three decimals"
    BUDGET_ERR "a = 12345678901234567\n", "17 integer digits"
    BUDGET_ERR "a = 1\nb = 2\na = 3\n", "duplicate category"
    BUDGET_ERR "a = .5\n", "no integer digits"
    BUDGET_ERR "a = 5.\n", "no decimals after the point"
    BUDGET_ERR "a = -1\n", "negative budget"
    BUDGET_ERR "a = 1 000\n", "space in amount"
    BUDGET_ERR "a = 1,50\n", "comma in amount"
    BUDGET_ERR "a =\n", "empty amount"
    BUDGET_ERR "uncategorized = 1\n", "uncategorized budget"
    BUDGET_ERR "[budget]\n", "section in budget file"
    LEAVE 1
ENDF test_budget
    .ltorg

// ================================================================= main =====

//   x19 temporary directory
FUNC main
    ENTER 1
    ADR_L x0, tmpdir
    bl   mkdtemp
    cbnz x0, 1f
    STR_AT x0, "mkdtemp"
    bl   die
1:  mov  x19, x0
    bl   chdir
    cbz  w0, 2f
    STR_AT x0, "chdir"
    bl   die
2:  bl   test_example
    bl   test_syntax
    bl   test_resolve
    bl   test_cfg_errors
    bl   test_rules
    bl   test_budget

    STR_AT x0, "/"                  // remove the temporary directory
    bl   chdir
    ADR_L x0, cmdbuf
    mov  x1, #256
    STR_AT x2, "rm -rf '%s'"
    mov  x3, x19
    bl   snprintf
    ADR_L x0, cmdbuf
    bl   system

    LDR_G x1, n_pass
    LDR_G x2, n_fail
    cbnz x2, 3f
    ADR_L x0, s_ok
    bl   printf
    mov  w0, #0
    LEAVE 1
3:  ADR_L x0, s_bad
    bl   printf
    mov  w0, #1
    LEAVE 1
ENDF main

    NOTE_GNU_STACK
