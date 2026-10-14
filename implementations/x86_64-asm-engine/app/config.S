/*
 * config.S - the configuration file (spec/apps/pqledger.md §3), the
 * rules file (§5.1) and the budget file (§5.2).
 *
 * All three share the line syntax of §3.2: a line iterator (LINEIT)
 * returns the trimmed, non-empty, non-comment lines; cfg_split_assignment
 * splits `KEY = VALUE` (with the quoted-value form).  Every error exits 2
 * with a message "FILE:LINE: ...".
 *
 * Configuration storage: one SEC record per section holding the raw
 * (unquoted) value and line of every key; [import] and [account NAME]
 * share the import key table.  Values are validated while parsing and
 * converted on demand (cfg_account_settings).
 */
#include "app.inc"

    .section .note.GNU-stack, "", @progbits

/* line iterator */
#define LI_P    0
#define LI_END  8
#define LI_NO   16
#define LI_SIZE 24

/* section record */
#define SEC_NAME   0                  /* account name (char*) or 0 */
#define SEC_VALS   8                  /* 16 x char* raw values (0 = unset) */
#define SEC_LINES  136                /* 16 x line numbers */
#define SEC_SIZE   264

/* section kinds = key tables */
#define K_LEDGER 0
#define K_IMPORT 1
#define K_OUTPUT 2
#define K_ENGINE 3

/* value validators / converters */
#define V_PATH    0
#define V_TEXT    1
#define V_DELIM   2
#define V_BOOL    3
#define V_UINT    4
#define V_POSINT  5
#define V_CREF    6
#define V_DATEFMT 7
#define V_AMODE   8
#define V_DECSEP  9
#define V_THOUSEP 10
#define V_FORMAT  11

/* key table entry: name, validator, ACC offset (import keys) */
#define KT_NAME 0
#define KT_VID  8
#define KT_OFF  16
#define KT_SIZE 24

/* indexes of keys used directly */
#define KEY_DATA_DIR 0
#define KEY_RULES    1
#define KEY_BUDGET   2
#define KEY_DEC_SEP  10
#define KEY_THOU_SEP 11

    .section .rodata
    .p2align 3
keys_ledger:
    .quad k_data_dir, V_PATH, 0
    .quad k_rules_file, V_PATH, 0
    .quad k_budget_file, V_PATH, 0
    .quad 0, 0, 0
keys_import:
    .quad k_delimiter, V_DELIM, ACC_DELIM
    .quad k_header, V_BOOL, ACC_HEADER
    .quad k_skip_lines, V_UINT, ACC_SKIP
    .quad k_date_column, V_CREF, ACC_DATE_COL
    .quad k_date_format, V_DATEFMT, ACC_DATE_FMT
    .quad k_description_column, V_CREF, ACC_DESC_COL
    .quad k_amount_mode, V_AMODE, ACC_AMOUNT_MODE
    .quad k_amount_column, V_CREF, ACC_AMOUNT_COL
    .quad k_debit_column, V_CREF, ACC_DEBIT_COL
    .quad k_credit_column, V_CREF, ACC_CREDIT_COL
    .quad k_decimal_separator, V_DECSEP, ACC_DEC_SEP
    .quad k_thousands_separator, V_THOUSEP, ACC_THOU_SEP
    .quad k_currency_symbol, V_TEXT, ACC_CURRENCY
    .quad k_invert_sign, V_BOOL, ACC_INVERT
    .quad 0, 0, 0
keys_output:
    .quad k_format, V_FORMAT, 0
    .quad 0, 0, 0
keys_engine:
    .quad k_threads, V_POSINT, 0
    .quad k_memory_mb, V_POSINT, 0
    .quad 0, 0, 0
key_tables:
    .quad keys_ledger, keys_import, keys_output, keys_engine

/* thousands separator words -> byte */
thou_map:   .quad 0, ',', '.', ' ', '\''

k_data_dir:     .asciz "data_dir"
k_rules_file:   .asciz "rules_file"
k_budget_file:  .asciz "budget_file"
k_delimiter:    .asciz "delimiter"
k_header:       .asciz "header"
k_skip_lines:   .asciz "skip_lines"
k_date_column:  .asciz "date_column"
k_date_format:  .asciz "date_format"
k_description_column: .asciz "description_column"
k_amount_mode:  .asciz "amount_mode"
k_amount_column: .asciz "amount_column"
k_debit_column: .asciz "debit_column"
k_credit_column: .asciz "credit_column"
k_decimal_separator: .asciz "decimal_separator"
k_thousands_separator: .asciz "thousands_separator"
k_currency_symbol: .asciz "currency_symbol"
k_invert_sign:  .asciz "invert_sign"
k_format:       .asciz "format"
k_threads:      .asciz "threads"
k_memory_mb:    .asciz "memory_mb"

/* word lists: NUL-separated, terminated by an empty word */
w_bool:     .asciz "false", "true", ""
w_datefmt:  .asciz "YYYY-MM-DD", "YYYYMMDD", "MM/DD/YYYY", "DD/MM/YYYY", "DD.MM.YYYY", ""
w_amode:    .asciz "signed", "debit_credit", ""
w_decsep:   .asciz ".", ",", ""
w_thousep:  .asciz "none", ",", ".", "space", "'", ""
w_format:   .asciz "table", "csv", "json", ""
w_sections: .asciz "ledger", "import", "output", "engine", ""

s_default_conf: .asciz "pqledger.conf"
s_env_conf:     .asciz "PQLEDGER_CONFIG"
s_def_date:     .asciz "Date"
s_def_desc:     .asciz "Description"
s_def_amount:   .asciz "Amount"
s_def_debit:    .asciz "Debit"
s_def_credit:   .asciz "Credit"
s_empty:        .asciz ""

/* ======================================================================
 * globals
 * ====================================================================== */
    .bss
    .p2align 3
    .globl g_cfg_path, g_cfg_dir, g_cfg_data_dir, g_cfg_rules_file
    .globl g_cfg_budget_file, g_cfg_format, g_cfg_threads, g_cfg_memory_mb
    .globl g_rules, g_rules_n, g_budgets, g_budget_n
g_cfg_path:         .quad 0           /* configuration file path as given */
g_cfg_dir:          .quad 0           /* its directory */
g_cfg_data_dir:     .quad 0
g_cfg_rules_file:   .quad 0
g_cfg_budget_file:  .quad 0
g_cfg_format:       .quad 0
g_cfg_threads:      .quad 0
g_cfg_memory_mb:    .quad 0
g_rules:            .quad 0           /* RULE array */
g_rules_n:          .quad 0
g_budgets:          .quad 0           /* BUD array */
g_budget_n:         .quad 0

sec_fixed:          .zero 4*SEC_SIZE  /* ledger, import, output, engine */
sec_seen:           .zero 4*8
acc_secs:           .quad 0           /* array of SEC for [account NAME] */
acc_n:              .quad 0
cfg_text:           .zero AB_SIZE

    .text

/* ======================================================================
 * Line iteration (shared by the three files)
 * ====================================================================== */

/* check_utf8(ab rdi, path rsi): exits 2 ("PATH:LINE: not valid UTF-8")
 * unless the ABUF's text is well-formed UTF-8 (§3.2). */
FUNC check_utf8
    ENTER
    mov %rdi, %rbx
    mov %rsi, %r12
    mov AB_DATA(%rbx), %rdi
    mov AB_LEN(%rbx), %rsi
    call utf8_check
    test %rax, %rax
    js 9f
    mov AB_DATA(%rbx), %rdi           /* line = 1 + newlines before it */
    lea (%rdi,%rax), %rsi
    mov $1, %ecx
1:  cmp %rsi, %rdi
    jae 2f
    cmpb $'\n', (%rdi)
    jne 3f
    inc %rcx
3:  inc %rdi
    jmp 1b
2:  mov %r12, %rdx
    DIE EX_CONFIG, "%s:%ld: the text is not valid UTF-8"
9:  LEAVE
ENDF check_utf8

/* lines_init(it rdi, ab rsi): iterate over the ABUF's text, BOM skipped */
FUNC lines_init
    mov AB_DATA(%rsi), %rax
    mov AB_LEN(%rsi), %rcx
    lea (%rax,%rcx), %rdx
    mov %rdx, LI_END(%rdi)
    movq $0, LI_NO(%rdi)
    cmp $3, %rcx
    jb 1f
    cmpb $0xEF, (%rax)
    jne 1f
    cmpb $0xBB, 1(%rax)
    jne 1f
    cmpb $0xBF, 2(%rax)
    jne 1f
    add $3, %rax
1:  mov %rax, LI_P(%rdi)
    ret
ENDF lines_init

/* lines_next(it rdi) -> rax line start (0 at the end), rdx length
 * Returns the next line that, trimmed of spaces and tabs (and a final
 * CR), is neither empty nor a comment.  LI_NO is its 1-based number. */
FUNC lines_next
    ENTER
    mov %rdi, %rbx
1:  mov LI_P(%rbx), %r12
    cmp LI_END(%rbx), %r12
    jae 8f
    incq LI_NO(%rbx)
    mov %r12, %rdi
    mov $'\n', %esi
    mov LI_END(%rbx), %rdx
    sub %r12, %rdx
    call memchr
    test %rax, %rax
    jnz 2f
    mov LI_END(%rbx), %rax
    mov %rax, LI_P(%rbx)
    jmp 3f
2:  lea 1(%rax), %rcx
    mov %rcx, LI_P(%rbx)
3:  mov %rax, %r13
    sub %r12, %r13                    /* length without the LF */
    jz 1b
    cmpb $'\r', -1(%r12,%r13)
    jne 4f
    dec %r13
4:  mov %r12, %rdi
    mov %r13, %rsi
    call trim_span
    test %rdx, %rdx
    jz 1b
    cmpb $'#', (%rax)
    je 1b
    cmpb $';', (%rax)
    je 1b
    LEAVE
8:  xor %eax, %eax
    xor %edx, %edx
    LEAVE
ENDF lines_next

/* cfg_split_assignment(p rdi, n rsi, out rdx) -> eax 0 ok, -1 no '='
 * out[0] = key (malloc'd, trimmed), out[1] = value (malloc'd, trimmed,
 * quotes removed with \" and \\ unescaped). */
FUNC cfg_split_assignment
    ENTER 32
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov $'=', %esi
    mov %r12, %rdx
    call memchr
    test %rax, %rax
    jz 9f
    mov %rax, %r14                    /* position of '=' */
    mov %rbx, %rdi
    mov %r14, %rsi
    sub %rbx, %rsi
    call trim_span
    mov %rax, %rdi
    mov %rdx, %rsi
    call xstrndup
    mov %rax, 0(%r13)
    lea 1(%r14), %rdi                 /* value span */
    lea (%rbx,%r12), %rsi
    sub %rdi, %rsi
    call trim_span
    mov %rax, %rbx
    mov %rdx, %r12
    cmp $2, %r12
    jb 5f
    cmpb $'"', (%rbx)
    jne 5f
    cmpb $'"', -1(%rbx,%r12)
    jne 5f
    /* quoted form: unescape the inside */
    lea 1(%r12), %rdi
    call xmalloc
    mov %rax, 8(%r13)
    mov %rax, %rdi                    /* output cursor */
    lea 1(%rbx), %rsi                 /* input cursor */
    lea -1(%rbx,%r12), %rcx           /* end (closing quote) */
1:  cmp %rcx, %rsi
    jae 3f
    movzbl (%rsi), %eax
    cmp $'\\', %eax
    jne 2f
    lea 1(%rsi), %rdx
    cmp %rcx, %rdx
    jae 2f
    movzbl 1(%rsi), %edx
    cmp $'"', %edx
    je 4f
    cmp $'\\', %edx
    jne 2f
4:  mov %edx, %eax
    inc %rsi
2:  mov %al, (%rdi)
    inc %rdi
    inc %rsi
    jmp 1b
3:  movb $0, (%rdi)
    xor %eax, %eax
    LEAVE
5:  mov %rbx, %rdi
    mov %r12, %rsi
    call xstrndup
    mov %rax, 8(%r13)
    xor %eax, %eax
    LEAVE
9:  mov $-1, %eax
    LEAVE
ENDF cfg_split_assignment

/* ======================================================================
 * value helpers
 * ====================================================================== */

/* word_index(s rdi, list rsi) -> eax index of s in the word list, or -1 */
FUNC word_index
    ENTER
    mov %rdi, %rbx
    mov %rsi, %r12
    xor %r13d, %r13d
1:  cmpb $0, (%r12)
    je 8f
    mov %rbx, %rdi
    mov %r12, %rsi
    call strcmp
    test %eax, %eax
    jz 7f
    mov %r12, %rdi
    call strlen
    lea 1(%r12,%rax), %r12
    inc %r13d
    jmp 1b
7:  mov %r13d, %eax
    LEAVE
8:  mov $-1, %eax
    LEAVE
ENDF word_index

/* validate(vid edi, value rsi) -> eax 0 valid, 1 invalid */
FUNC validate
    ENTER
    mov %rsi, %rbx
    cmp $V_TEXT, %edi
    je 0f
    cmp $V_PATH, %edi
    je 10f
    cmp $V_CREF, %edi
    je 10f
    cmp $V_DELIM, %edi
    je 20f
    cmp $V_UINT, %edi
    je 30f
    cmp $V_POSINT, %edi
    je 40f
    lea w_bool(%rip), %rsi
    cmp $V_BOOL, %edi
    je 50f
    lea w_datefmt(%rip), %rsi
    cmp $V_DATEFMT, %edi
    je 50f
    lea w_amode(%rip), %rsi
    cmp $V_AMODE, %edi
    je 50f
    lea w_decsep(%rip), %rsi
    cmp $V_DECSEP, %edi
    je 50f
    lea w_thousep(%rip), %rsi
    cmp $V_THOUSEP, %edi
    je 50f
    lea w_format(%rip), %rsi
50: mov %rbx, %rdi
    call word_index
    test %eax, %eax
    js 1f
0:  xor %eax, %eax
    LEAVE
10: cmpb $0, (%rbx)                   /* non-empty text */
    je 1f
    jmp 0b
20: mov %rbx, %rdi                    /* delimiter: "tab" or one ASCII char */
    CSTR %rsi, "tab"
    call strcmp
    test %eax, %eax
    jz 0b
    movzbl (%rbx), %eax
    test %eax, %eax
    jz 1f
    cmpb $0, 1(%rbx)
    jne 1f
    cmp $0x80, %eax
    jae 1f
    cmp $'"', %eax
    je 1f
    cmp $'\n', %eax
    je 1f
    cmp $'\r', %eax
    je 1f
    jmp 0b
30: mov %rbx, %rdi
    mov $18, %esi
    call parse_u64
    test %rax, %rax
    js 1f
    jmp 0b
40: mov %rbx, %rdi
    mov $18, %esi
    call parse_u64
    test %rax, %rax
    jle 1f
    jmp 0b
1:  mov $1, %eax
    LEAVE
ENDF validate

/* convert(vid edi, value rsi) -> rax converted scalar (rdx name for
 * V_CREF: rax position or 0, rdx name or 0).  value must be valid. */
FUNC convert
    ENTER
    mov %rsi, %rbx
    mov %edi, %r12d
    cmp $V_DELIM, %r12d
    je 20f
    cmp $V_CREF, %r12d
    je 30f
    cmp $V_UINT, %r12d
    je 40f
    cmp $V_POSINT, %r12d
    je 40f
    cmp $V_DECSEP, %r12d
    je 50f
    lea w_bool(%rip), %rsi
    cmp $V_BOOL, %r12d
    je 60f
    lea w_datefmt(%rip), %rsi
    cmp $V_DATEFMT, %r12d
    je 60f
    lea w_amode(%rip), %rsi
    cmp $V_AMODE, %r12d
    je 60f
    lea w_format(%rip), %rsi
    cmp $V_FORMAT, %r12d
    je 60f
    lea w_thousep(%rip), %rsi
    cmp $V_THOUSEP, %r12d
    je 70f
    mov %rbx, %rax                    /* text / path: the string itself */
    LEAVE
20: mov %rbx, %rdi
    CSTR %rsi, "tab"
    call strcmp
    mov $9, %ecx
    movzbl (%rbx), %edx
    test %eax, %eax
    cmovnz %edx, %ecx
    mov %ecx, %eax
    LEAVE
30: mov %rbx, %rdi                    /* column reference */
    mov $18, %esi
    call parse_u64
    test %rax, %rax
    jle 31f
    xor %edx, %edx
    LEAVE
31: xor %eax, %eax
    mov %rbx, %rdx
    LEAVE
40: mov %rbx, %rdi
    mov $18, %esi
    call parse_u64
    LEAVE
50: movzbl (%rbx), %eax
    LEAVE
60: mov %rbx, %rdi
    call word_index
    LEAVE
70: mov %rbx, %rdi
    call word_index
    lea thou_map(%rip), %rcx
    mov (%rcx,%rax,8), %rax
    LEAVE
ENDF convert

/* key_lookup(table rdi, key rsi) -> rax index or -1 */
FUNC key_lookup
    ENTER
    mov %rdi, %rbx
    mov %rsi, %r12
    xor %r13d, %r13d
1:  mov KT_NAME(%rbx), %rdi
    test %rdi, %rdi
    jz 8f
    mov %r12, %rsi
    call strcmp
    test %eax, %eax
    jz 7f
    add $KT_SIZE, %rbx
    inc %r13
    jmp 1b
7:  mov %r13, %rax
    LEAVE
8:  mov $-1, %rax
    LEAVE
ENDF key_lookup

/* find_account(name rdi) -> rax SEC* of [account name] or 0 */
FUNC find_account
    ENTER
    mov %rdi, %r12
    mov acc_secs(%rip), %rbx
    mov acc_n(%rip), %r13
1:  test %r13, %r13
    jz 8f
    mov SEC_NAME(%rbx), %rdi
    mov %r12, %rsi
    call strcmp
    test %eax, %eax
    jz 7f
    add $SEC_SIZE, %rbx
    dec %r13
    jmp 1b
7:  mov %rbx, %rax
    LEAVE
8:  xor %eax, %eax
    LEAVE
ENDF find_account

/* ======================================================================
 * cfg_load(path rdi or 0)
 * Locates, reads and parses the configuration; resolves the paths.
 * ====================================================================== */
FUNC cfg_load
    ENTER 64
    /* 0(%rsp) LINEIT, 32(%rsp) key, 40(%rsp) value */
    mov %rdi, %rbx
    test %rbx, %rbx
    jnz 2f
    lea s_env_conf(%rip), %rdi
    call getenv
    mov %rax, %rbx
    test %rbx, %rbx
    jz 1f
    cmpb $0, (%rbx)
    jne 2f
1:  lea s_default_conf(%rip), %rbx
2:  mov %rbx, g_cfg_path(%rip)
    mov %rbx, %rdi
    call path_dirname
    mov %rax, g_cfg_dir(%rip)
    mov %rbx, %rdi
    lea cfg_text(%rip), %rsi
    call read_file
    test %eax, %eax
    jz 3f
    call __errno_location
    mov (%rax), %edi
    call strerror
    mov %rax, %rcx
    mov g_cfg_path(%rip), %rdx
    DIE EX_CONFIG, "cannot read configuration file %s: %s"
3:  lea cfg_text(%rip), %rdi
    mov g_cfg_path(%rip), %rsi
    call check_utf8
    lea 0(%rsp), %rdi
    lea cfg_text(%rip), %rsi
    call lines_init
    xor %r14d, %r14d                  /* current SEC* (0 before any section) */
    xor %r15d, %r15d                  /* its key table */
cl_next:
    lea 0(%rsp), %rdi
    call lines_next
    test %rax, %rax
    jz cl_done
    mov %rax, %r12
    mov %rdx, %r13
    cmpb $'[', (%r12)
    jne cl_assign
    cmpb $']', -1(%r12,%r13)
    jne cl_assign
    /* section header: name = inside of the brackets */
    lea 1(%r12), %rdi
    lea -2(%r13), %rsi
    call xstrndup
    mov %rax, %r12
    mov %r12, %rdi
    lea w_sections(%rip), %rsi
    call word_index
    test %eax, %eax
    js cl_account
    movslq %eax, %rax
    lea sec_seen(%rip), %rcx
    cmpq $0, (%rcx,%rax,8)
    jne cl_err_repsec
    movq $1, (%rcx,%rax,8)
    imul $SEC_SIZE, %rax, %rdx
    lea sec_fixed(%rip), %r14
    add %rdx, %r14
    lea key_tables(%rip), %rcx
    mov (%rcx,%rax,8), %r15
    jmp cl_next
cl_account:
    mov %r12, %rdi
    CSTR %rsi, "account "
    mov $8, %edx
    call strncmp
    test %eax, %eax
    jnz cl_err_section
    lea 8(%r12), %r13                 /* account name */
    mov %r13, %rdi
    call is_name
    test %eax, %eax
    jz cl_err_accname
    mov %r13, %rdi
    call find_account
    test %rax, %rax
    jnz cl_err_repsec
    mov acc_secs(%rip), %rdi
    mov acc_n(%rip), %rsi
    inc %rsi
    imul $SEC_SIZE, %rsi, %rsi
    call xrealloc
    mov %rax, acc_secs(%rip)
    mov acc_n(%rip), %r14
    imul $SEC_SIZE, %r14, %r14
    add %rax, %r14
    incq acc_n(%rip)
    mov %r14, %rdi
    xor %esi, %esi
    mov $SEC_SIZE, %edx
    call memset
    mov %r13, SEC_NAME(%r14)
    lea keys_import(%rip), %r15
    jmp cl_next
cl_assign:
    mov %r12, %rdi
    mov %r13, %rsi
    lea 32(%rsp), %rdx
    call cfg_split_assignment
    test %eax, %eax
    jnz cl_err_syntax
    test %r14, %r14
    jz cl_err_before
    mov %r15, %rdi
    mov 32(%rsp), %rsi
    call key_lookup
    test %rax, %rax
    js cl_err_key
    mov %rax, %r12                    /* key index */
    cmpq $0, SEC_VALS(%r14,%r12,8)
    jne cl_err_repkey
    imul $KT_SIZE, %r12, %rax
    mov KT_VID(%r15,%rax), %rdi
    mov 40(%rsp), %rsi
    call validate
    test %eax, %eax
    jnz cl_err_value
    mov 40(%rsp), %rax
    mov %rax, SEC_VALS(%r14,%r12,8)
    mov 16(%rsp), %rax
    mov %rax, SEC_LINES(%r14,%r12,8)
    jmp cl_next

cl_err_repsec:
    mov g_cfg_path(%rip), %rdx
    mov 16(%rsp), %rcx
    mov %r12, %r8
    DIE EX_CONFIG, "%s:%ld: repeated section [%s]"
cl_err_section:
    mov g_cfg_path(%rip), %rdx
    mov 16(%rsp), %rcx
    mov %r12, %r8
    DIE EX_CONFIG, "%s:%ld: unknown section [%s]"
cl_err_accname:
    mov g_cfg_path(%rip), %rdx
    mov 16(%rsp), %rcx
    mov %r13, %r8
    DIE EX_CONFIG, "%s:%ld: invalid account name '%s'"
cl_err_syntax:
    mov g_cfg_path(%rip), %rdx
    mov 16(%rsp), %rcx
    DIE EX_CONFIG, "%s:%ld: syntax error (expected [SECTION] or KEY = VALUE)"
cl_err_before:
    mov g_cfg_path(%rip), %rdx
    mov 16(%rsp), %rcx
    DIE EX_CONFIG, "%s:%ld: assignment before the first section header"
cl_err_key:
    mov g_cfg_path(%rip), %rdx
    mov 16(%rsp), %rcx
    mov 32(%rsp), %r8
    DIE EX_CONFIG, "%s:%ld: unknown key '%s' in this section"
cl_err_repkey:
    mov g_cfg_path(%rip), %rdx
    mov 16(%rsp), %rcx
    mov 32(%rsp), %r8
    DIE EX_CONFIG, "%s:%ld: repeated key '%s'"
cl_err_value:
    mov g_cfg_path(%rip), %rdx
    mov 16(%rsp), %rcx
    mov 32(%rsp), %r8
    mov 40(%rsp), %r9
    DIE EX_CONFIG, "%s:%ld: invalid value for '%s': '%s'"

cl_done:
    /* [ledger] with data_dir is required */
    cmpq $0, sec_seen(%rip)
    jne 1f
    mov g_cfg_path(%rip), %rdx
    DIE EX_CONFIG, "%s: missing [ledger] section"
1:  lea sec_fixed(%rip), %rbx         /* [ledger] */
    mov SEC_VALS+8*KEY_DATA_DIR(%rbx), %rsi
    test %rsi, %rsi
    jnz 2f
    mov g_cfg_path(%rip), %rdx
    DIE EX_CONFIG, "%s: [ledger] data_dir is required"
2:  mov g_cfg_dir(%rip), %rdi
    call path_join
    mov %rax, g_cfg_data_dir(%rip)
    mov SEC_VALS+8*KEY_RULES(%rbx), %rsi
    test %rsi, %rsi
    jz 3f
    mov g_cfg_dir(%rip), %rdi
    call path_join
    mov %rax, g_cfg_rules_file(%rip)
3:  mov SEC_VALS+8*KEY_BUDGET(%rbx), %rsi
    test %rsi, %rsi
    jz 4f
    mov g_cfg_dir(%rip), %rdi
    call path_join
    mov %rax, g_cfg_budget_file(%rip)
4:  lea sec_fixed+2*SEC_SIZE(%rip), %rbx      /* [output] */
    mov SEC_VALS(%rbx), %rsi
    test %rsi, %rsi
    jz 5f
    mov $V_FORMAT, %edi
    call convert
    mov %rax, g_cfg_format(%rip)
5:  lea sec_fixed+3*SEC_SIZE(%rip), %rbx      /* [engine] */
    mov SEC_VALS(%rbx), %rsi
    test %rsi, %rsi
    jz 6f
    mov $V_POSINT, %edi
    call convert
    mov %rax, g_cfg_threads(%rip)
6:  mov SEC_VALS+8(%rbx), %rsi
    test %rsi, %rsi
    jz 7f
    mov $V_POSINT, %edi
    call convert
    mov %rax, g_cfg_memory_mb(%rip)
7:  /* decimal and thousands separators must differ: [import] and each account */
    lea sec_fixed+SEC_SIZE(%rip), %rdi
    call check_separators
    mov acc_secs(%rip), %rbx
    mov acc_n(%rip), %r12
8:  test %r12, %r12
    jz 9f
    mov %rbx, %rdi
    call check_separators
    add $SEC_SIZE, %rbx
    dec %r12
    jmp 8b
9:  LEAVE
ENDF cfg_load

/* check_separators(sec rdi): exit 2 if the effective decimal and thousands
 * separators of the section ([import] or [account NAME]) are equal */
FUNC check_separators
    ENTER ACC_SIZE
    mov %rdi, %rbx
    mov SEC_NAME(%rbx), %rdi
    mov %rsp, %rsi
    call cfg_account_settings
    mov ACC_DEC_SEP(%rsp), %rax
    cmp ACC_THOU_SEP(%rsp), %rax
    jne 9f
    mov SEC_LINES+8*KEY_THOU_SEP(%rbx), %rcx
    test %rcx, %rcx
    jnz 1f
    mov SEC_LINES+8*KEY_DEC_SEP(%rbx), %rcx
    test %rcx, %rcx
    jnz 1f
    mov sec_fixed+SEC_SIZE+SEC_LINES+8*KEY_THOU_SEP(%rip), %rcx
1:  mov g_cfg_path(%rip), %rdx
    DIE EX_CONFIG, "%s:%ld: decimal_separator and thousands_separator must differ"
9:  LEAVE
ENDF check_separators

/* apply_section(sec rdi, acc rsi): stores the section's import keys */
FUNC apply_section
    ENTER
    mov %rdi, %rbx
    mov %rsi, %r12
    lea keys_import(%rip), %r13
    xor %r14d, %r14d
1:  cmpq $0, KT_NAME(%r13)
    je 9f
    mov SEC_VALS(%rbx,%r14,8), %rsi
    test %rsi, %rsi
    jz 3f
    mov KT_VID(%r13), %rdi
    mov KT_OFF(%r13), %r15
    call convert
    mov %rax, (%r12,%r15)
    cmpq $V_CREF, KT_VID(%r13)
    jne 3f
    mov %rdx, CREF_NAME(%r12,%r15)
3:  add $KT_SIZE, %r13
    inc %r14
    jmp 1b
9:  LEAVE
ENDF apply_section

/* ======================================================================
 * cfg_account_settings(name rdi or 0, acc rsi)
 * Effective import settings: [account name] value, else [import] value,
 * else the default.
 * ====================================================================== */
FUNC cfg_account_settings
    ENTER
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %r12, %rdi
    xor %esi, %esi
    mov $ACC_SIZE, %edx
    call memset
    movq $',', ACC_DELIM(%r12)
    movq $1, ACC_HEADER(%r12)
    lea s_def_date(%rip), %rax
    mov %rax, ACC_DATE_COL+CREF_NAME(%r12)
    movq $DF_ISO, ACC_DATE_FMT(%r12)
    lea s_def_desc(%rip), %rax
    mov %rax, ACC_DESC_COL+CREF_NAME(%r12)
    movq $AM_SIGNED, ACC_AMOUNT_MODE(%r12)
    lea s_def_amount(%rip), %rax
    mov %rax, ACC_AMOUNT_COL+CREF_NAME(%r12)
    lea s_def_debit(%rip), %rax
    mov %rax, ACC_DEBIT_COL+CREF_NAME(%r12)
    lea s_def_credit(%rip), %rax
    mov %rax, ACC_CREDIT_COL+CREF_NAME(%r12)
    movq $'.', ACC_DEC_SEP(%r12)
    lea s_empty(%rip), %rax
    mov %rax, ACC_CURRENCY(%r12)
    lea sec_fixed+SEC_SIZE(%rip), %rdi        /* [import] */
    mov %r12, %rsi
    call apply_section
    test %rbx, %rbx
    jz 9f
    mov %rbx, %rdi
    call find_account
    test %rax, %rax
    jz 9f
    mov %rax, %rdi
    mov %r12, %rsi
    call apply_section
9:  LEAVE
ENDF cfg_account_settings

/* ======================================================================
 * rules_load(): parses the rules file (if configured) into g_rules.
 * Line `CATEGORY = PATTERN [, PATTERN ...]`; patterns trimmed, non-empty,
 * without % and _, stored ASCII upper-cased; rule_no 1, 2, ... in order.
 * ====================================================================== */
FUNC rules_load
    ENTER 80
    /* 0 LINEIT, 32 key, 40 value, 48 ABUF text, 72 capacity */
    movq $0, 72(%rsp)
    mov g_cfg_rules_file(%rip), %rdi
    test %rdi, %rdi
    jz rl_ret
    lea 48(%rsp), %rsi
    movq $0, 48(%rsp)
    movq $0, 56(%rsp)
    movq $0, 64(%rsp)
    call read_file
    test %eax, %eax
    jz 1f
    call __errno_location
    mov (%rax), %edi
    call strerror
    mov %rax, %rcx
    mov g_cfg_rules_file(%rip), %rdx
    DIE EX_CONFIG, "cannot read rules file %s: %s"
1:  lea 48(%rsp), %rdi
    mov g_cfg_rules_file(%rip), %rsi
    call check_utf8
    lea 0(%rsp), %rdi
    lea 48(%rsp), %rsi
    call lines_init
rl_line:
    lea 0(%rsp), %rdi
    call lines_next
    test %rax, %rax
    jz rl_ret
    mov %rax, %rdi
    mov %rdx, %rsi
    lea 32(%rsp), %rdx
    call cfg_split_assignment
    test %eax, %eax
    jnz rl_err_syntax
    mov 32(%rsp), %rdi
    call is_category
    test %eax, %eax
    jz rl_err_cat
    mov 40(%rsp), %rbx                /* cursor in the value */
rl_pattern:
    mov %rbx, %rdi                    /* piece up to the next ',' */
    mov $',', %esi
    call strchr
    mov %rax, %r12
    test %rax, %rax
    jnz 2f
    mov %rbx, %rdi
    call strlen
    lea (%rbx,%rax), %r12             /* end of the value */
2:  mov %rbx, %rdi
    mov %r12, %rsi
    sub %rbx, %rsi
    call trim_span
    test %rdx, %rdx
    jz rl_err_empty
    mov %rax, %rdi
    mov %rdx, %rsi
    call xstrndup
    mov %rax, %r13                    /* pattern copy */
    mov %r13, %rcx
3:  movzbl (%rcx), %eax               /* check and upper-case */
    test %eax, %eax
    jz 5f
    cmp $'%', %eax
    je rl_err_wild
    cmp $'_', %eax
    je rl_err_wild
    lea -'a'(%rax), %edx
    cmp $25, %edx
    ja 4f
    sub $32, %eax
    mov %al, (%rcx)
4:  inc %rcx
    jmp 3b
5:  /* append RULE {no, category, pattern} */
    mov g_rules_n(%rip), %rax
    cmp 72(%rsp), %rax
    jb 6f
    lea 16(%rax,%rax), %rsi
    mov %rsi, 72(%rsp)
    imul $RULE_SIZE, %rsi, %rsi
    mov g_rules(%rip), %rdi
    call xrealloc
    mov %rax, g_rules(%rip)
6:  mov g_rules_n(%rip), %rax
    imul $RULE_SIZE, %rax, %rcx
    add g_rules(%rip), %rcx
    inc %rax
    mov %rax, g_rules_n(%rip)
    mov %rax, RULE_NO(%rcx)
    mov 32(%rsp), %rdx
    mov %rdx, RULE_CATEGORY(%rcx)
    mov %r13, RULE_PATTERN(%rcx)
    cmpb $0, (%r12)
    je rl_line
    lea 1(%r12), %rbx
    jmp rl_pattern
rl_ret:
    LEAVE

rl_err_syntax:
    mov g_cfg_rules_file(%rip), %rdx
    mov 16(%rsp), %rcx
    DIE EX_CONFIG, "%s:%ld: syntax error (expected CATEGORY = PATTERN, ...)"
rl_err_cat:
    mov g_cfg_rules_file(%rip), %rdx
    mov 16(%rsp), %rcx
    mov 32(%rsp), %r8
    DIE EX_CONFIG, "%s:%ld: invalid category name '%s'"
rl_err_empty:
    mov g_cfg_rules_file(%rip), %rdx
    mov 16(%rsp), %rcx
    DIE EX_CONFIG, "%s:%ld: empty pattern"
rl_err_wild:
    mov g_cfg_rules_file(%rip), %rdx
    mov 16(%rsp), %rcx
    DIE EX_CONFIG, "%s:%ld: a pattern must not contain '%%' or '_'"
ENDF rules_load

/* parse_cents(s rdi) -> rax amount in cents, or -1 unless s matches
 * [0-9]{1,16}(\.[0-9]{1,2})? */
FUNC parse_cents
    xor %eax, %eax
    xor %ecx, %ecx                    /* integer digits */
1:  movzbl (%rdi), %edx
    sub $'0', %edx
    cmp $9, %edx
    ja 2f
    cmp $16, %ecx
    jae 7f
    imul $10, %rax, %rax
    add %rdx, %rax
    inc %ecx
    inc %rdi
    jmp 1b
2:  test %ecx, %ecx
    jz 7f
    imul $100, %rax, %rax
    movzbl (%rdi), %edx
    test %edx, %edx
    jz 9f
    cmp $'.', %edx
    jne 7f
    movzbl 1(%rdi), %edx
    sub $'0', %edx
    cmp $9, %edx
    ja 7f
    imul $10, %rdx, %rdx
    add %rdx, %rax
    movzbl 2(%rdi), %edx
    test %edx, %edx
    jz 9f
    sub $'0', %edx
    cmp $9, %edx
    ja 7f
    add %rdx, %rax
    cmpb $0, 3(%rdi)
    jne 7f
9:  ret
7:  mov $-1, %rax
    ret
ENDF parse_cents

/* ======================================================================
 * budget_load(): parses the budget file (if configured) into g_budgets.
 * Lines `CATEGORY = AMOUNT`; a repeated category is an error.
 * ====================================================================== */
FUNC budget_load
    ENTER 80
    movq $0, 72(%rsp)
    mov g_cfg_budget_file(%rip), %rdi
    test %rdi, %rdi
    jz bl_ret
    lea 48(%rsp), %rsi
    movq $0, 48(%rsp)
    movq $0, 56(%rsp)
    movq $0, 64(%rsp)
    call read_file
    test %eax, %eax
    jz 1f
    call __errno_location
    mov (%rax), %edi
    call strerror
    mov %rax, %rcx
    mov g_cfg_budget_file(%rip), %rdx
    DIE EX_CONFIG, "cannot read budget file %s: %s"
1:  lea 48(%rsp), %rdi
    mov g_cfg_budget_file(%rip), %rsi
    call check_utf8
    lea 0(%rsp), %rdi
    lea 48(%rsp), %rsi
    call lines_init
bl_line:
    lea 0(%rsp), %rdi
    call lines_next
    test %rax, %rax
    jz bl_ret
    mov %rax, %rdi
    mov %rdx, %rsi
    lea 32(%rsp), %rdx
    call cfg_split_assignment
    test %eax, %eax
    jnz bl_err_syntax
    mov 32(%rsp), %rdi
    call is_category
    test %eax, %eax
    jz bl_err_cat
    mov 40(%rsp), %rdi
    call parse_cents
    test %rax, %rax
    js bl_err_amount
    mov %rax, %r13
    mov g_budgets(%rip), %rbx         /* repeated category? */
    mov g_budget_n(%rip), %r12
2:  test %r12, %r12
    jz 3f
    mov BUD_CATEGORY(%rbx), %rdi
    mov 32(%rsp), %rsi
    call strcmp
    test %eax, %eax
    jz bl_err_rep
    add $BUD_SIZE, %rbx
    dec %r12
    jmp 2b
3:  mov g_budget_n(%rip), %rax
    cmp 72(%rsp), %rax
    jb 4f
    lea 16(%rax,%rax), %rsi
    mov %rsi, 72(%rsp)
    shl $4, %rsi                      /* BUD_SIZE = 16 */
    mov g_budgets(%rip), %rdi
    call xrealloc
    mov %rax, g_budgets(%rip)
4:  mov g_budget_n(%rip), %rax
    mov %rax, %rcx
    shl $4, %rcx
    add g_budgets(%rip), %rcx
    inc %rax
    mov %rax, g_budget_n(%rip)
    mov 32(%rsp), %rdx
    mov %rdx, BUD_CATEGORY(%rcx)
    mov %r13, BUD_CENTS(%rcx)
    jmp bl_line
bl_ret:
    LEAVE

bl_err_syntax:
    mov g_cfg_budget_file(%rip), %rdx
    mov 16(%rsp), %rcx
    DIE EX_CONFIG, "%s:%ld: syntax error (expected CATEGORY = AMOUNT)"
bl_err_cat:
    mov g_cfg_budget_file(%rip), %rdx
    mov 16(%rsp), %rcx
    mov 32(%rsp), %r8
    DIE EX_CONFIG, "%s:%ld: invalid category name '%s'"
bl_err_amount:
    mov g_cfg_budget_file(%rip), %rdx
    mov 16(%rsp), %rcx
    mov 40(%rsp), %r8
    DIE EX_CONFIG, "%s:%ld: invalid amount '%s'"
bl_err_rep:
    mov g_cfg_budget_file(%rip), %rdx
    mov 16(%rsp), %rcx
    mov 32(%rsp), %r8
    DIE EX_CONFIG, "%s:%ld: category '%s' listed twice"
ENDF budget_load
