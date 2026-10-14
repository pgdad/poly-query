/*
 * main.S - pqledger entry point (spec/apps/pqledger.md §2, §10):
 * global options, command-line parsing of every command, usage errors
 * (exit 1), configuration loading and command dispatch.
 *
 * The whole command line is checked before the configuration is read.
 * A command handler returns its exit status (0, or 3 for budget over);
 * main then writes the accumulated standard output (g_out) and exits.
 */
#include "app.inc"

    .section .note.GNU-stack, "", @progbits

/* option bits */
#define O_MONTH   0x01
#define O_FROM    0x02
#define O_TO      0x04
#define O_ACCOUNT 0x08
#define O_CATEGORY 0x10
#define O_UNCAT   0x20
#define O_TOP     0x40
#define O_CLEAR   0x80
#define O_FILTERS (O_MONTH | O_FROM | O_TO | O_ACCOUNT)

/* option table entry: name, bit, takes a value (1/0), global address */
#define OT_NAME 0
#define OT_BIT  8
#define OT_VAL  16
#define OT_DST  24
#define OT_SIZE 32

/* command flags */
#define CF_NOCONFIG 1                 /* help, version */
#define CF_NORULES  2                 /* init: rules file not read */
#define CF_BUDGET   4                 /* budget, query: budget file read */

/* command table entry */
#define CT_NAME    0
#define CT_HANDLER 8
#define CT_OPTS    16
#define CT_MINPOS  24
#define CT_MAXPOS  32
#define CT_FLAGS   40
#define CT_SIZE    48

    .section .rodata
    .p2align 3
opt_table:
    .quad o_month, O_MONTH, 1, g_opt_month
    .quad o_from, O_FROM, 1, g_opt_from
    .quad o_to, O_TO, 1, g_opt_to
    .quad o_account, O_ACCOUNT, 1, g_opt_account
    .quad o_category, O_CATEGORY, 1, g_opt_category
    .quad o_uncat, O_UNCAT, 0, g_opt_uncat
    .quad o_top, O_TOP, 1, g_opt_top_text
    .quad o_clear, O_CLEAR, 0, g_opt_clear
    .quad 0, 0, 0, 0

cmd_table:
    .quad n_init, cmd_init, 0, 0, 0, CF_NORULES
    .quad n_import, cmd_import_main, O_ACCOUNT, 1, 1, 0
    .quad n_report, cmd_report, O_FILTERS | O_TOP, 1, 1, 0
    .quad n_budget, cmd_budget, O_MONTH | O_ACCOUNT, 0, 0, CF_BUDGET
    .quad n_accounts, cmd_accounts, 0, 0, 0, 0
    .quad n_list, cmd_list, O_FILTERS | O_CATEGORY | O_UNCAT, 0, 0, 0
    .quad n_export, cmd_export, O_FILTERS, 0, 0, 0
    .quad n_setcat, cmd_set_category, O_CLEAR, 1, 2, 0
    .quad n_query, cmd_query, 0, 1, 1, CF_BUDGET
    .quad n_help, cmd_help, 0, 0, 0, CF_NOCONFIG
    .quad n_version, cmd_version, 0, 0, 0, CF_NOCONFIG
    .quad 0, 0, 0, 0, 0, 0

o_month:    .asciz "--month"
o_from:     .asciz "--from"
o_to:       .asciz "--to"
o_account:  .asciz "--account"
o_category: .asciz "--category"
o_uncat:    .asciz "--uncategorized"
o_top:      .asciz "--top"
o_clear:    .asciz "--clear"
n_init:     .asciz "init"
n_import:   .asciz "import"
n_report:   .asciz "report"
n_budget:   .asciz "budget"
n_accounts: .asciz "accounts"
n_list:     .asciz "list"
n_export:   .asciz "export"
n_setcat:   .asciz "set-category"
n_query:    .asciz "query"
n_help:     .asciz "help"
n_version:  .asciz "version"
w_reports:  .asciz "monthly", "categories", "merchants", ""
w_formats:  .asciz "table", "csv", "json", ""

/* ======================================================================
 * globals: the parsed command line
 * ====================================================================== */
    .bss
    .p2align 3
    .globl g_format, g_opt_month, g_opt_from, g_opt_to, g_opt_account
    .globl g_opt_category, g_opt_uncat, g_opt_top, g_opt_clear
    .globl g_pos, g_npos, g_report_kind, g_setcat_id
g_format:       .quad 0               /* 0 table, 1 csv, 2 json */
g_opt_config:   .quad 0               /* --config PATH */
g_opt_format:   .quad 0               /* --format: 0 absent, else format + 1 */
g_opt_month:    .quad 0               /* char* "YYYY-MM" or 0 */
g_opt_from:     .quad 0
g_opt_to:       .quad 0
g_opt_account:  .quad 0
g_opt_category: .quad 0
g_opt_uncat:    .quad 0               /* 1 if --uncategorized */
g_opt_top_text: .quad 0
g_opt_top:      .quad 0               /* --top N (default 10) */
g_opt_clear:    .quad 0               /* 1 if --clear */
g_pos:          .zero 16              /* positional arguments */
g_npos:         .quad 0
g_report_kind:  .quad 0               /* 0 monthly, 1 categories, 2 merchants */
g_setcat_id:    .quad 0
opts_seen:      .quad 0

    .text

/* usage_error helpers: exit 1 */
usage_unknown_option:
    DIE EX_USAGE, "unknown option '%s' (see 'pqledger help')"
usage_missing_value:
    DIE EX_USAGE, "option %s needs a value"
usage_repeated:
    DIE EX_USAGE, "option %s given more than once"

/* ======================================================================
 * is_month(s rdi) -> eax 1 if s is YYYY-MM with year 0001-9999 and
 * month 01-12
 * ====================================================================== */
FUNC is_month
    xor %eax, %eax
    xor %ecx, %ecx
1:  movzbl (%rdi,%rcx), %edx          /* digits at 0-3, 5-6, '-' at 4 */
    cmp $4, %ecx
    je 2f
    sub $'0', %edx
    cmp $9, %edx
    ja 8f
    jmp 3f
2:  cmp $'-', %edx
    jne 8f
3:  inc %ecx
    cmp $7, %ecx
    jb 1b
    cmpb $0, 7(%rdi)
    jne 8f
    cmpl $0x30303030, (%rdi)          /* year 0000 */
    je 8f
    movzbl 5(%rdi), %ecx
    movzbl 6(%rdi), %edx
    sub $'0', %ecx
    sub $'0', %edx
    imul $10, %ecx, %ecx
    add %edx, %ecx
    cmp $1, %ecx
    jb 8f
    cmp $12, %ecx
    ja 8f
    mov $1, %eax
8:  ret
ENDF is_month

/* check_month_opt(value rdi, option name rsi): usage error unless a month */
FUNC check_month_opt
    ENTER
    mov %rdi, %rbx
    mov %rsi, %r12
    test %rbx, %rbx
    jz 9f
    call is_month
    test %eax, %eax
    jnz 9f
    mov %r12, %rdx
    mov %rbx, %rcx
    DIE EX_USAGE, "%s: invalid month '%s' (expected YYYY-MM)"
9:  LEAVE
ENDF check_month_opt

/* ======================================================================
 * parse_command(cmd rdi = CT entry, argv rsi, argc edx)
 * Parses the command's options and positional arguments (argv = the
 * arguments after the command name) into the g_opt_* / g_pos globals.
 * ====================================================================== */
FUNC parse_command
    ENTER
    mov %rdi, %rbx                    /* CT entry */
    mov %rsi, %r12                    /* argv cursor */
    movslq %edx, %r13                 /* remaining */
pc_loop:
    test %r13, %r13
    jz pc_done
    mov (%r12), %r14                  /* argument */
    cmpb $'-', (%r14)
    jne pc_positional
    cmpb $'-', 1(%r14)
    jne pc_positional
    lea opt_table(%rip), %r15
1:  mov OT_NAME(%r15), %rdi
    test %rdi, %rdi
    jz pc_unknown
    mov %r14, %rsi
    call strcmp
    test %eax, %eax
    jz 2f
    add $OT_SIZE, %r15
    jmp 1b
2:  mov OT_BIT(%r15), %rax
    test %rax, CT_OPTS(%rbx)
    jz pc_unknown
    test %rax, opts_seen(%rip)
    jnz pc_repeated
    or %rax, opts_seen(%rip)
    mov OT_DST(%r15), %rcx
    cmpq $0, OT_VAL(%r15)
    jne 3f
    movq $1, (%rcx)                   /* flag */
    add $8, %r12
    dec %r13
    jmp pc_loop
3:  cmp $2, %r13
    jb pc_novalue
    mov 8(%r12), %rax
    mov %rax, (%rcx)
    add $16, %r12
    sub $2, %r13
    jmp pc_loop
pc_positional:
    mov g_npos(%rip), %rax
    cmp CT_MAXPOS(%rbx), %rax
    jae pc_surplus
    lea g_pos(%rip), %rcx
    mov %r14, (%rcx,%rax,8)
    incq g_npos(%rip)
    add $8, %r12
    dec %r13
    jmp pc_loop
pc_done:
    mov g_npos(%rip), %rax
    cmp CT_MINPOS(%rbx), %rax
    jb pc_missing
    LEAVE
pc_unknown:
    mov %r14, %rdx
    mov CT_NAME(%rbx), %rcx
    DIE EX_USAGE, "unknown option '%s' for '%s' (see 'pqledger help')"
pc_repeated:
    mov %r14, %rdx
    jmp usage_repeated
pc_novalue:
    mov %r14, %rdx
    jmp usage_missing_value
pc_surplus:
    mov %r14, %rdx
    DIE EX_USAGE, "unexpected argument '%s'"
pc_missing:
    mov CT_NAME(%rbx), %rdx
    DIE EX_USAGE, "missing argument for '%s' (see 'pqledger help')"
ENDF parse_command

/* ======================================================================
 * check_command(cmd rdi = CT entry): command-specific checks of the
 * parsed arguments (usage errors).
 * ====================================================================== */
FUNC check_command
    ENTER
    mov %rdi, %rbx
    /* filters */
    mov g_opt_month(%rip), %rdi
    lea o_month(%rip), %rsi
    call check_month_opt
    mov g_opt_from(%rip), %rdi
    lea o_from(%rip), %rsi
    call check_month_opt
    mov g_opt_to(%rip), %rdi
    lea o_to(%rip), %rsi
    call check_month_opt
    cmpq $0, g_opt_month(%rip)
    je 1f
    cmpq $0, g_opt_from(%rip)
    jne cc_month_range
    cmpq $0, g_opt_to(%rip)
    jne cc_month_range
1:  mov g_opt_from(%rip), %rdi
    mov g_opt_to(%rip), %rsi
    test %rdi, %rdi
    jz 2f
    test %rsi, %rsi
    jz 2f
    call strcmp
    test %eax, %eax
    jg cc_from_to
2:  mov g_opt_account(%rip), %rdi
    test %rdi, %rdi
    jz 3f
    call is_name
    test %eax, %eax
    jz cc_account
3:  mov g_opt_category(%rip), %rdi
    test %rdi, %rdi
    jz 4f
    cmpq $0, g_opt_uncat(%rip)
    jne cc_cat_uncat
    call is_category
    test %eax, %eax
    jz cc_category
4:  movq $10, g_opt_top(%rip)
    mov g_opt_top_text(%rip), %rdi
    test %rdi, %rdi
    jz 5f
    mov $19, %esi
    call parse_u64
    test %rax, %rax
    jle cc_top
    mov %rax, g_opt_top(%rip)
5:  /* per command */
    mov CT_NAME(%rbx), %r12
    lea n_import(%rip), %rax
    cmp %rax, %r12
    je cc_import
    lea n_report(%rip), %rax
    cmp %rax, %r12
    je cc_report
    lea n_budget(%rip), %rax
    cmp %rax, %r12
    je cc_budget
    lea n_setcat(%rip), %rax
    cmp %rax, %r12
    je cc_setcat
cc_ok:
    LEAVE
cc_import:
    cmpq $0, g_opt_account(%rip)
    jne cc_ok
    DIE EX_USAGE, "import needs --account NAME"
cc_report:
    mov g_pos(%rip), %rdi
    lea w_reports(%rip), %rsi
    call word_index
    test %eax, %eax
    js cc_report_kind
    mov %rax, g_report_kind(%rip)
    cmp $2, %eax
    je cc_ok
    cmpq $0, g_opt_top_text(%rip)
    je cc_ok
    lea o_top(%rip), %rdx
    mov g_pos(%rip), %rcx
    DIE EX_USAGE, "option %s is not valid for 'report %s'"
cc_report_kind:
    mov g_pos(%rip), %rdx
    DIE EX_USAGE, "unknown report '%s' (monthly, categories or merchants)"
cc_budget:
    cmpq $0, g_opt_month(%rip)
    jne cc_ok
    DIE EX_USAGE, "budget needs --month YYYY-MM"
cc_setcat:
    mov g_npos(%rip), %rax
    mov g_opt_clear(%rip), %rcx
    add %rcx, %rax
    cmp $2, %rax
    jne cc_setcat_args
    mov g_pos(%rip), %rdi
    mov $19, %esi
    call parse_u64
    test %rax, %rax
    jle cc_setcat_id
    mov %rax, g_setcat_id(%rip)
    cmpq $0, g_opt_clear(%rip)
    jne cc_ok
    mov g_pos+8(%rip), %rdi
    call is_category
    test %eax, %eax
    jnz cc_ok
    mov g_pos+8(%rip), %rdx
    DIE EX_USAGE, "invalid category name '%s' ([a-z0-9_-]{1,32}, not 'uncategorized')"
cc_setcat_args:
    DIE EX_USAGE, "usage: pqledger set-category ID (CATEGORY | --clear)"
cc_setcat_id:
    mov g_pos(%rip), %rdx
    DIE EX_USAGE, "invalid transaction id '%s'"
cc_month_range:
    DIE EX_USAGE, "--month cannot be combined with --from or --to"
cc_from_to:
    DIE EX_USAGE, "--from is later than --to"
cc_account:
    mov g_opt_account(%rip), %rdx
    DIE EX_USAGE, "invalid account name '%s' ([a-z0-9_-]{1,32})"
cc_cat_uncat:
    DIE EX_USAGE, "--category and --uncategorized exclude each other"
cc_category:
    mov g_opt_category(%rip), %rdx
    DIE EX_USAGE, "invalid category name '%s'"
cc_top:
    mov g_opt_top_text(%rip), %rdx
    DIE EX_USAGE, "--top: invalid count '%s' (an integer >= 1)"
ENDF check_command

/* ======================================================================
 * main(argc edi, argv rsi) -> exit status
 * ====================================================================== */
FUNC main
    ENTER
    mov %edi, %r12d                   /* argc */
    mov %rsi, %r13                    /* argv */
    mov $1, %r14d                     /* index */
    lea g_out(%rip), %rdi
    call ab_init
    /* global options before the command */
m_global:
    cmp %r12d, %r14d
    jge m_nocommand
    mov (%r13,%r14,8), %rbx
    cmpb $'-', (%rbx)
    jne m_command
    mov %rbx, %rdi
    CSTR %rsi, "--help"
    call strcmp
    test %eax, %eax
    jz m_help
    mov %rbx, %rdi
    CSTR %rsi, "--config"
    call strcmp
    test %eax, %eax
    jz m_config
    mov %rbx, %rdi
    CSTR %rsi, "--format"
    call strcmp
    test %eax, %eax
    jz m_format
    mov %rbx, %rdx
    jmp usage_unknown_option
m_config:
    cmpq $0, g_opt_config(%rip)
    jne m_repeated
    lea 1(%r14), %eax
    cmp %r12d, %eax
    jge m_novalue
    mov 8(%r13,%r14,8), %rax
    mov %rax, g_opt_config(%rip)
    add $2, %r14d
    jmp m_global
m_format:
    cmpq $0, g_opt_format(%rip)
    jne m_repeated
    lea 1(%r14), %eax
    cmp %r12d, %eax
    jge m_novalue
    mov 8(%r13,%r14,8), %rdi
    mov %rdi, %r15
    lea w_formats(%rip), %rsi
    call word_index
    test %eax, %eax
    js m_badformat
    inc %eax
    mov %rax, g_opt_format(%rip)
    add $2, %r14d
    jmp m_global
m_repeated:
    mov %rbx, %rdx
    jmp usage_repeated
m_novalue:
    mov %rbx, %rdx
    jmp usage_missing_value
m_badformat:
    mov %r15, %rdx
    DIE EX_USAGE, "--format: unknown format '%s' (table, csv or json)"
m_nocommand:
    DIE EX_USAGE, "no command given (see 'pqledger help')"
m_help:
    lea cmd_table+9*CT_SIZE(%rip), %rbx       /* the help entry */
    jmp m_run
m_command:
    lea cmd_table(%rip), %r15
1:  mov CT_NAME(%r15), %rdi
    test %rdi, %rdi
    jz m_unknown
    mov %rbx, %rsi
    call strcmp
    test %eax, %eax
    jz 2f
    add $CT_SIZE, %r15
    jmp 1b
m_unknown:
    mov %rbx, %rdx
    DIE EX_USAGE, "unknown command '%s' (see 'pqledger help')"
2:  mov %r15, %rdi
    lea 8(%r13,%r14,8), %rsi
    mov %r12d, %edx
    sub %r14d, %edx
    dec %edx
    call parse_command
    mov %r15, %rdi
    call check_command
    mov %r15, %rbx
m_run:
    /* configuration, rules, budgets */
    testq $CF_NOCONFIG, CT_FLAGS(%rbx)
    jnz m_exec
    mov g_opt_config(%rip), %rdi
    call cfg_load
    mov g_cfg_format(%rip), %rax
    mov g_opt_format(%rip), %rcx
    test %rcx, %rcx
    jz 3f
    lea -1(%rcx), %rax
3:  mov %rax, g_format(%rip)
    testq $CF_NORULES, CT_FLAGS(%rbx)
    jnz 4f
    call rules_load
4:  testq $CF_BUDGET, CT_FLAGS(%rbx)
    jz m_exec
    call budget_load
m_exec:
    mov g_opt_format(%rip), %rax      /* help/version: --format still applies */
    test %rax, %rax
    jz 5f
    dec %rax
    mov %rax, g_format(%rip)
5:  call *CT_HANDLER(%rbx)
    mov %eax, %r12d
    call out_flush
    mov %r12d, %edi
    call exit
ENDF main

/* ======================================================================
 * cmd_import_main() -> eax exit status: `import FILE --account NAME`
 * (the import itself is cmd_import in import.S)
 * ====================================================================== */
FUNC cmd_import_main
    ENTER
    mov g_pos(%rip), %rdi
    mov g_opt_account(%rip), %rsi
    call cmd_import
    xor %eax, %eax
    LEAVE
ENDF cmd_import_main
