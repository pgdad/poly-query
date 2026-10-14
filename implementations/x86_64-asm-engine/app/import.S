/*
 * import.S - `pqledger import FILE --account NAME` (spec/apps/pqledger.md
 * §6.2-§6.4): bank CSV reading and conversion, merchant normalization,
 * duplicate detection and the ledger update.
 *
 * Exported:
 *   cmd_import(file rdi, account rsi)
 *        The whole import command (C strings).  Appends
 *        "batch B: imported N, duplicates D\n" to g_out; exits 4 on bad
 *        input (message "FILE:LINE: reason"), 6 without a ledger, 7 on
 *        engine errors.  Nothing is changed unless every record converts.
 *
 * Pure helpers (exported for app/tests/test_import.S):
 *   imp_normalize_merchant(src rdi, len rsi, dst rdx) -> rax length
 *        §6.3 merchant normalization of the description src[0..len) into
 *        dst (room for len bytes; the result is never longer).
 *   imp_parse_date(ptr rdi, len rsi, fmt rdx) -> rax
 *        Parses the field (trimmed of spaces and tabs) in date format fmt
 *        (DF_* of app.inc).  Result: y*10000 + m*100 + d for a valid
 *        calendar date with year 0001-9999, else -1.
 *   imp_days_from_ymd(ymd rdi) -> rax days since 1970-01-01
 *        (ymd as returned by imp_parse_date).
 *   imp_parse_amount(ptr rdi, len rsi, acc rdx) -> rax cents, edx status
 *        Converts one amount field per §6.2 step 3 (parentheses, sign,
 *        currency symbol, thousands and decimal separators of the ACC
 *        settings; no invert_sign).  status 0 = ok (rax = signed amount in
 *        cents), 1 = empty after trimming (rax = 0), 2 = invalid (rax = 0).
 *
 * Data flow of cmd_import: the file is read into one buffer and parsed in
 * place (quoted fields are unescaped where they stand, so every field is a
 * (ptr, len) span of that buffer); each data record becomes a REC entry
 * (description span, normalized merchant in i_merch, date, cents).  The
 * ledger's per-key counts for the account come from one GROUP BY query and
 * go into an open-addressing hash table together with the file's keys;
 * walking the records in file order with a per-key occurrence counter k
 * imports a record iff k >= l (l = ledger count of the key), i.e. exactly
 * the last max(0, f - l) records of each key.  New rows are written as CSV
 * text, loaded with an explicit schema and appended with
 * CREATE TABLE AS (UNION ALL), then saved.
 *
 * Every function follows the System V AMD64 ABI.
 */
#include "app.inc"

    .section .note.GNU-stack, "", @progbits

/* REC: one converted data record */
#define R_DESC   0      /* description (trimmed), pointer into the file buffer */
#define R_DLEN   8
#define R_MOFF   16     /* merchant: offset in i_merch */
#define R_MLEN   24
#define R_CENTS  32     /* amount in cents */
#define R_DAYS   40     /* date: days since 1970-01-01 (duplicate key) */
#define R_YMD    48     /* date: y*10000 + m*100 + d */
#define R_FLAG   56     /* 1 = imported */
#define R_SIZE   64

/* hash table entry: key (account fixed) and the counters of §6.4 */
#define H_HASH   0      /* 0 = empty slot */
#define H_DAYS   8
#define H_CENTS  16
#define H_MPTR   24
#define H_MLEN   32
#define H_L      40     /* u32: transactions in the ledger */
#define H_K      44     /* u32: records of the file seen so far */
#define H_SIZE   48

/* ====================================================================== */
    .bss
    .p2align 4
i_acc:      .zero ACC_SIZE      /* effective import settings */
i_file:     .zero AB_SIZE       /* the file's contents (parsed in place) */
i_merch:    .zero AB_SIZE       /* normalized merchants, back to back */
i_buf:      .zero AB_SIZE       /* SQL / CSV text */
i_path:     .quad 0             /* FILE as given */
i_account:  .quad 0
i_acclen:   .quad 0
i_pos:      .quad 0             /* CSV reader: next byte */
i_end:      .quad 0             /*             end of the data */
i_line:     .quad 0             /*             physical line of i_pos */
i_rec_line: .quad 0             /*             line where the record starts */
i_delim:    .quad 0
i_fields:   .quad 0             /* (ptr, len) pairs of the current record */
i_fcap:     .quad 0
i_nexp:     .quad 0             /* fields per record */
i_cdate:    .quad 0             /* 0-based column indexes */
i_cdesc:    .quad 0
i_camt:     .quad 0
i_cdeb:     .quad 0
i_ccred:    .quad 0
i_recs:     .quad 0             /* REC array */
i_nrec:     .quad 0
i_rcap:     .quad 0
i_scr:      .quad 0             /* merchant scratch buffer */
i_scap:     .quad 0
i_ht:       .quad 0             /* hash table */
i_hmask:    .quad 0
i_nimp:     .quad 0
i_ndup:     .quad 0
i_next_id:  .quad 0
i_batch:    .quad 0

    .section .rodata
i_mdays:    .byte 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31
s_id:       .asciz "id"
s_account:  .asciz "account"
s_date:     .asciz "date"
s_desc:     .asciz "description"
s_merchant: .asciz "merchant"
s_amount:   .asciz "amount"
s_batch:    .asciz "batch"
s_file:     .asciz "file"
s_imported: .asciz "imported"
s_dups:     .asciz "duplicates"
s_INT64:    .asciz "INT64"
s_STRING:   .asciz "STRING"
s_DATE:     .asciz "DATE"
s_DEC:      .asciz "DECIMAL(18,2)"
s_new_tx:   .asciz "new_tx"
s_new_b:    .asciz "new_batch"
s_tx:       .asciz "transactions"
s_batches:  .asciz "batches"

    .data
    .p2align 3
/* explicit load schemas (pq_column_def arrays) and load options */
i_tx_schema:
    .quad s_id, s_INT64, s_account, s_STRING, s_date, s_DATE
    .quad s_desc, s_STRING, s_merchant, s_STRING, s_amount, s_DEC
    .quad s_batch, s_INT64
i_b_schema:
    .quad s_batch, s_INT64, s_account, s_STRING, s_file, s_STRING
    .quad s_imported, s_INT64, s_dups, s_INT64
i_tx_opts:      /* format, header, delimiter, replace, schema, schema_len */
    .quad 0, PQ_HEADER_NO, 0, 1, i_tx_schema, 7
i_b_opts:
    .quad 0, PQ_HEADER_NO, 0, 1, i_b_schema, 5

/* OUTS "text": append a constant string to g_out */
.macro OUTS msg
    lea g_out(%rip), %rdi
    CSTR %rsi, "\msg"
    call ab_puts
.endm

    .text

/* ======================================================================
 * cmd_import(file rdi, account rsi)
 * ====================================================================== */
FUNC cmd_import
    ENTER 16
    mov %rdi, i_path(%rip)
    mov %rsi, i_account(%rip)
    mov %rsi, %rdi
    call strlen
    mov %rax, i_acclen(%rip)
    mov i_account(%rip), %rdi
    lea i_acc(%rip), %rsi
    call cfg_account_settings
    call ledger_open
    mov i_path(%rip), %rdi
    lea i_file(%rip), %rsi
    call read_file
    test %eax, %eax
    jns 1f
    call __errno_location
    mov (%rax), %edi
    call strerror
    mov %rax, %rcx
    mov i_path(%rip), %rdx
    DIE EX_IMPORT, "%s: %s"
1:  call i_parse_file
    call i_find_duplicates
    call i_next_numbers
    call i_write_ledger
    OUTS "batch "
    lea g_out(%rip), %rdi
    mov i_batch(%rip), %rsi
    call ab_put_i64
    OUTS ": imported "
    lea g_out(%rip), %rdi
    mov i_nimp(%rip), %rsi
    call ab_put_i64
    OUTS ", duplicates "
    lea g_out(%rip), %rdi
    mov i_ndup(%rip), %rsi
    call ab_put_i64
    OUTS "\n"
    LEAVE
ENDF cmd_import

/* ======================================================================
 * small leaf helpers
 * ====================================================================== */

/* i_trim(p rdi, e rsi) -> rax p, rdx e: span without leading and trailing
 * spaces and tabs */
i_trim:
    mov %rdi, %rax
    mov %rsi, %rdx
1:  cmp %rdx, %rax
    jae 3f
    cmpb $' ', (%rax)
    je 2f
    cmpb $'\t', (%rax)
    jne 3f
2:  inc %rax
    jmp 1b
3:  cmp %rdx, %rax
    jae 5f
    cmpb $' ', -1(%rdx)
    je 4f
    cmpb $'\t', -1(%rdx)
    jne 5f
4:  dec %rdx
    jmp 3b
5:  ret

/* i_digits(p rdi, n rsi) -> rax value of exactly n decimal digits, or -1 */
i_digits:
    xor %eax, %eax
1:  test %rsi, %rsi
    jz 2f
    movzbl (%rdi), %ecx
    sub $'0', %ecx
    cmp $9, %ecx
    ja 3f
    imul $10, %rax, %rax
    add %rcx, %rax
    inc %rdi
    dec %rsi
    jmp 1b
2:  ret
3:  mov $-1, %rax
    ret

/* i_num12(p rdi, e rsi) -> rax value of 1 or 2 digits at p (-1 if none),
 * rdx = pointer after them */
i_num12:
    xor %eax, %eax
    xor %ecx, %ecx
1:  cmp %rsi, %rdi
    jae 2f
    cmp $2, %ecx
    jae 2f
    movzbl (%rdi), %r8d
    sub $'0', %r8d
    cmp $9, %r8d
    ja 2f
    imul $10, %rax, %rax
    add %r8, %rax
    inc %rdi
    inc %ecx
    jmp 1b
2:  mov %rdi, %rdx
    test %ecx, %ecx
    jnz 3f
    mov $-1, %rax
3:  ret

/* i_make_ymd(y rdi, m rsi, d rdx) -> rax y*10000+m*100+d if that is a valid
 * calendar date with year 1..9999, else -1 */
i_make_ymd:
    mov %rdx, %r9
    cmp $1, %rdi
    jl 9f
    cmp $9999, %rdi
    jg 9f
    cmp $1, %rsi
    jl 9f
    cmp $12, %rsi
    jg 9f
    cmp $1, %r9
    jl 9f
    lea i_mdays(%rip), %rcx
    movzbl -1(%rcx,%rsi), %r8d
    cmp $2, %rsi
    jne 2f
    /* leap year: y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) */
    test $3, %edi
    jnz 2f
    mov %rdi, %rax
    xor %edx, %edx
    mov $100, %ecx
    div %rcx
    test %rdx, %rdx
    jnz 1f
    mov %rdi, %rax
    xor %edx, %edx
    mov $400, %ecx
    div %rcx
    test %rdx, %rdx
    jnz 2f
1:  mov $29, %r8d
2:  cmp %r8, %r9
    jg 9f
    imul $10000, %rdi, %rax
    imul $100, %rsi, %rcx
    add %rcx, %rax
    add %r9, %rax
    ret
9:  mov $-1, %rax
    ret

/* i_ieq(a rdi, b rsi, n rdx) -> eax 1 if the n bytes are equal under ASCII
 * case folding */
i_ieq:
    xor %ecx, %ecx
1:  cmp %rdx, %rcx
    jae 4f
    movzbl (%rdi,%rcx), %eax
    lea -'A'(%rax), %r8d
    cmp $25, %r8d
    ja 2f
    add $32, %eax
2:  movzbl (%rsi,%rcx), %r9d
    lea -'A'(%r9), %r8d
    cmp $25, %r8d
    ja 3f
    add $32, %r9d
3:  cmp %r9d, %eax
    jne 5f
    inc %rcx
    jmp 1b
4:  mov $1, %eax
    ret
5:  xor %eax, %eax
    ret

/* writers: (w rdi, ...) -> rax = w after the written text (no NUL) */

/* i_w_u64(w rdi, v rsi): unsigned decimal.  Uses the red zone. */
i_w_u64:
    mov %rsi, %rax
    lea -1(%rsp), %rcx
    mov $10, %r8d
1:  xor %edx, %edx
    div %r8
    add $'0', %dl
    mov %dl, (%rcx)
    dec %rcx
    test %rax, %rax
    jnz 1b
2:  inc %rcx
    cmp %rsp, %rcx
    jae 3f
    movzbl (%rcx), %eax
    mov %al, (%rdi)
    inc %rdi
    jmp 2b
3:  mov %rdi, %rax
    ret

/* i_w_i64(w rdi, v rsi): signed decimal */
i_w_i64:
    test %rsi, %rsi
    jns i_w_u64
    movb $'-', (%rdi)
    inc %rdi
    neg %rsi
    jmp i_w_u64

/* i_w_digits(w rdi, v rsi, n rdx): exactly n digits, zero padded */
i_w_digits:
    lea (%rdi,%rdx), %rcx
    mov %rcx, %r8
    mov %rsi, %rax
    mov $10, %r9d
1:  cmp %rdi, %rcx
    jbe 2f
    dec %rcx
    xor %edx, %edx
    div %r9
    add $'0', %dl
    mov %dl, (%rcx)
    jmp 1b
2:  mov %r8, %rax
    ret

/* i_w_date(w rdi, ymd rsi): YYYY-MM-DD */
i_w_date:
    push %rbx
    push %r12
    mov %rdi, %rbx
    mov %rsi, %rax
    xor %edx, %edx
    mov $10000, %ecx
    div %rcx                    /* rax = y, rdx = m*100 + d */
    mov %rdx, %r12
    mov %rax, %rsi
    mov $4, %edx
    call i_w_digits
    movb $'-', (%rax)
    lea 1(%rax), %rbx
    mov %r12, %rax
    xor %edx, %edx
    mov $100, %ecx
    div %rcx
    mov %rdx, %r12              /* d */
    mov %rbx, %rdi
    mov %rax, %rsi
    mov $2, %edx
    call i_w_digits
    movb $'-', (%rax)
    lea 1(%rax), %rdi
    mov %r12, %rsi
    mov $2, %edx
    call i_w_digits
    pop %r12
    pop %rbx
    ret

/* i_w_cents(w rdi, cents rsi): e.g. -12.50 */
i_w_cents:
    push %rbx
    mov %rsi, %rax
    test %rax, %rax
    jns 1f
    movb $'-', (%rdi)
    inc %rdi
    neg %rax
1:  xor %edx, %edx
    mov $100, %ecx
    div %rcx
    mov %rdx, %rbx
    mov %rax, %rsi
    call i_w_u64
    movb $'.', (%rax)
    lea 1(%rax), %rdi
    mov %rbx, %rsi
    mov $2, %edx
    call i_w_digits
    pop %rbx
    ret

/* i_w_quoted(w rdi, p rsi, n rdx): "..." with " doubled (needs 2n+2) */
i_w_quoted:
    movb $'"', (%rdi)
    inc %rdi
    xor %ecx, %ecx
1:  cmp %rdx, %rcx
    jae 3f
    movzbl (%rsi,%rcx), %eax
    mov %al, (%rdi)
    inc %rdi
    cmp $'"', %eax
    jne 2f
    mov %al, (%rdi)
    inc %rdi
2:  inc %rcx
    jmp 1b
3:  movb $'"', (%rdi)
    lea 1(%rdi), %rax
    ret

/* ======================================================================
 * pure helpers (exported, unit-tested)
 * ====================================================================== */

/* imp_normalize_merchant(src rdi, len rsi, dst rdx) -> rax length (§6.3) */
FUNC imp_normalize_merchant
    xor %eax, %eax              /* output length */
    xor %r8d, %r8d              /* a space is pending */
    xor %ecx, %ecx
1:  cmp %rsi, %rcx
    jae 5f
    movzbl (%rdi,%rcx), %r9d
    inc %rcx
    cmp $' ', %r9d
    je 2f
    cmp $'\t', %r9d
    jne 3f
2:  test %rax, %rax             /* leading blanks vanish */
    jz 1b
    mov $1, %r8d
    jmp 1b
3:  test %r8d, %r8d             /* a run of blanks becomes one space */
    jz 4f
    movb $' ', (%rdx,%rax)
    inc %rax
    xor %r8d, %r8d
4:  lea -'a'(%r9), %r10d
    cmp $25, %r10d
    ja 6f
    sub $32, %r9d
6:  mov %r9b, (%rdx,%rax)
    inc %rax
    jmp 1b
    /* trailing blanks were never written; now the last token */
5:  mov %rax, %rcx
7:  test %rcx, %rcx
    jz 9f                       /* no space: unchanged */
    cmpb $' ', -1(%rdx,%rcx)
    je 8f
    dec %rcx
    jmp 7b
8:  lea (%rdx,%rcx), %r8        /* token */
    mov %rax, %r9
    sub %rcx, %r9               /* token length >= 1 */
    cmpb $'#', (%r8)
    jne 10f
    cmp $2, %r9                 /* '#' and one or more digits */
    jb 9f
    inc %r8
    dec %r9
    jmp 11f
10: cmp $3, %r9                 /* 3 or more digits */
    jb 9f
11: xor %r10d, %r10d
12: cmp %r9, %r10
    jae 13f
    movzbl (%r8,%r10), %r11d
    sub $'0', %r11d
    cmp $9, %r11d
    ja 9f
    inc %r10
    jmp 12b
13: lea -1(%rcx), %rax          /* drop the token and the space before it */
9:  ret
ENDF imp_normalize_merchant

/* imp_parse_date(ptr rdi, len rsi, fmt rdx) -> rax y*10000+m*100+d or -1
 * Locals: 0 first number, 8 second number of the / and . formats. */
FUNC imp_parse_date
    ENTER 16
    mov %rdx, %r14
    add %rdi, %rsi
    call i_trim
    mov %rax, %r12              /* p */
    mov %rdx, %r13              /* e */
    mov %r13, %rbx
    sub %r12, %rbx              /* length */
    cmp $DF_ISO, %r14
    je .Ld_iso
    cmp $DF_COMPACT, %r14
    je .Ld_compact
    cmp $DF_DOT, %r14
    ja .Ld_bad
    /* MM/DD/YYYY, DD/MM/YYYY, DD.MM.YYYY: 1-2 digit day and month */
    mov $'/', %ebx
    cmp $DF_DOT, %r14
    jne 1f
    mov $'.', %ebx
1:  mov %r12, %rdi
    mov %r13, %rsi
    call i_num12
    test %rax, %rax
    js .Ld_bad
    mov %rax, 0(%rsp)
    mov %rdx, %r12
    cmp %r13, %r12
    jae .Ld_bad
    movzbl (%r12), %eax
    cmp %ebx, %eax
    jne .Ld_bad
    inc %r12
    mov %r12, %rdi
    mov %r13, %rsi
    call i_num12
    test %rax, %rax
    js .Ld_bad
    mov %rax, 8(%rsp)
    mov %rdx, %r12
    cmp %r13, %r12
    jae .Ld_bad
    movzbl (%r12), %eax
    cmp %ebx, %eax
    jne .Ld_bad
    inc %r12
    mov %r13, %rax
    sub %r12, %rax
    cmp $4, %rax
    jne .Ld_bad
    mov %r12, %rdi
    mov $4, %esi
    call i_digits
    test %rax, %rax
    js .Ld_bad
    mov %rax, %rdi              /* year */
    cmp $DF_US, %r14
    jne 2f
    mov 0(%rsp), %rsi           /* MM/DD */
    mov 8(%rsp), %rdx
    jmp 3f
2:  mov 8(%rsp), %rsi           /* DD/MM, DD.MM */
    mov 0(%rsp), %rdx
3:  call i_make_ymd
    LEAVE
.Ld_iso:
    cmp $10, %rbx
    jne .Ld_bad
    cmpb $'-', 4(%r12)
    jne .Ld_bad
    cmpb $'-', 7(%r12)
    jne .Ld_bad
    mov %r12, %rdi
    mov $4, %esi
    call i_digits
    mov %rax, %r15
    lea 5(%r12), %rdi
    mov $2, %esi
    call i_digits
    mov %rax, %rbx
    lea 8(%r12), %rdi
    jmp .Ld_ymd
.Ld_compact:
    cmp $8, %rbx
    jne .Ld_bad
    mov %r12, %rdi
    mov $4, %esi
    call i_digits
    mov %rax, %r15
    lea 4(%r12), %rdi
    mov $2, %esi
    call i_digits
    mov %rax, %rbx
    lea 6(%r12), %rdi
.Ld_ymd:                        /* year r15, month rbx, day digits at rdi */
    mov $2, %esi
    call i_digits
    mov %rax, %rdx
    test %r15, %r15
    js .Ld_bad
    test %rbx, %rbx
    js .Ld_bad
    test %rdx, %rdx
    js .Ld_bad
    mov %r15, %rdi
    mov %rbx, %rsi
    call i_make_ymd
    LEAVE
.Ld_bad:
    mov $-1, %rax
    LEAVE
ENDF imp_parse_date

/* imp_days_from_ymd(ymd rdi) -> rax days since 1970-01-01 (proleptic
 * Gregorian, H. Hinnant's days_from_civil) */
FUNC imp_days_from_ymd
    mov %rdi, %rax
    xor %edx, %edx
    mov $10000, %ecx
    div %rcx
    mov %rax, %r8               /* y */
    mov %rdx, %rax
    xor %edx, %edx
    mov $100, %ecx
    div %rcx
    mov %rax, %r9               /* m */
    mov %rdx, %r10              /* d */
    cmp $2, %r9
    ja 1f
    dec %r8                     /* January and February count to the previous year */
1:  mov %r8, %rax
    xor %edx, %edx
    mov $400, %ecx
    div %rcx
    mov %rax, %r11              /* era */
    mov %rdx, %rsi              /* year of era */
    mov %r9, %rax               /* month counted from March: m > 2 ? m-3 : m+9 */
    cmp $2, %r9
    ja 2f
    add $12, %rax
2:  sub $3, %rax
    imul $153, %rax, %rax
    add $2, %rax
    xor %edx, %edx
    mov $5, %ecx
    div %rcx
    add %r10, %rax
    dec %rax
    mov %rax, %rdi              /* day of year */
    imul $365, %rsi, %r8
    mov %rsi, %rax
    shr $2, %rax
    add %rax, %r8
    mov %rsi, %rax
    xor %edx, %edx
    mov $100, %ecx
    div %rcx
    sub %rax, %r8
    add %rdi, %r8               /* day of era */
    imul $146097, %r11, %rax
    add %r8, %rax
    sub $719468, %rax
    ret
ENDF imp_days_from_ymd

/* imp_parse_amount(ptr rdi, len rsi, acc rdx) -> rax cents, edx status
 * Local 0: currency symbol length. */
FUNC imp_parse_amount
    ENTER 16
    mov %rdx, %r14              /* ACC */
    add %rdi, %rsi
    call i_trim
    mov %rax, %r12              /* p */
    mov %rdx, %r13              /* e */
    cmp %r12, %r13
    je .La_empty
    xor %r15d, %r15d            /* negative */
    movzbl (%r12), %eax
    cmp $'(', %eax
    jne 1f
    mov %r13, %rcx
    sub %r12, %rcx
    cmp $2, %rcx
    jb 1f
    cmpb $')', -1(%r13)
    jne 1f
    inc %r12
    dec %r13
    mov $1, %r15d
    jmp 3f
1:  cmp $'-', %eax
    jne 2f
    inc %r12
    mov $1, %r15d
    jmp 3f
2:  cmp $'+', %eax
    jne 3f
    inc %r12
    /* currency symbol at the start, else at the end */
3:  mov ACC_CURRENCY(%r14), %rbx
    test %rbx, %rbx
    jz 5f
    cmpb $0, (%rbx)
    je 5f
    mov %rbx, %rdi
    call strlen
    mov %rax, 0(%rsp)
    mov %r13, %rcx
    sub %r12, %rcx
    cmp %rax, %rcx
    jb 5f
    mov %r12, %rdi
    mov %rbx, %rsi
    mov %rax, %rdx
    call memcmp
    test %eax, %eax
    jnz 4f
    add 0(%rsp), %r12
    jmp 5f
4:  mov %r13, %rdi
    sub 0(%rsp), %rdi
    mov %rbx, %rsi
    mov 0(%rsp), %rdx
    call memcmp
    test %eax, %eax
    jnz 5f
    sub 0(%rsp), %r13
5:  mov %r12, %rdi
    mov %r13, %rsi
    call i_trim
    mov %rax, %r12
    mov %rdx, %r13
    /* digits with separators: [0-9]{1,16}(\.[0-9]{1,2})? */
    mov ACC_THOU_SEP(%r14), %r8
    mov ACC_DEC_SEP(%r14), %r9
    xor %eax, %eax              /* integer part */
    xor %r10d, %r10d            /* integer digits */
    xor %r11d, %r11d            /* fraction */
    xor %ecx, %ecx              /* fraction digits */
    xor %edi, %edi              /* point seen */
6:  cmp %r13, %r12
    jae 10f
    movzbl (%r12), %edx
    test %r8, %r8
    jz 7f
    cmp %r8d, %edx
    je 9f                       /* thousands separators are removed */
7:  cmp %r9d, %edx
    jne 8f
    mov $'.', %edx
8:  cmp $'.', %edx
    jne 11f
    test %edi, %edi
    jnz .La_bad
    test %r10, %r10
    jz .La_bad
    mov $1, %edi
    jmp 9f
11: sub $'0', %edx
    cmp $9, %edx
    ja .La_bad
    test %edi, %edi
    jnz 12f
    inc %r10
    cmp $16, %r10
    ja .La_bad
    imul $10, %rax, %rax
    add %rdx, %rax
    jmp 9f
12: inc %rcx
    cmp $2, %rcx
    ja .La_bad
    imul $10, %r11, %r11
    add %rdx, %r11
9:  inc %r12
    jmp 6b
10: test %r10, %r10
    jz .La_bad
    test %edi, %edi
    jz 13f
    test %rcx, %rcx
    jz .La_bad
    cmp $1, %rcx
    jne 13f
    imul $10, %r11, %r11
13: imul $100, %rax, %rax
    add %r11, %rax
    test %r15d, %r15d
    jz 14f
    neg %rax
14: xor %edx, %edx
    LEAVE
.La_empty:
    xor %eax, %eax
    mov $1, %edx
    LEAVE
.La_bad:
    xor %eax, %eax
    mov $2, %edx
    LEAVE
ENDF imp_parse_amount

/* ======================================================================
 * CSV reading
 * ====================================================================== */

/*
 * i_csv_record() -> rax number of fields of the next record (0 at the end)
 * Reads one RFC 4180 record at i_pos (delimiter i_delim, quote ", records
 * end with \n or \r\n, empty lines skipped) into i_fields as (ptr, len)
 * spans; quoted fields are unescaped in place.  i_rec_line = the physical
 * line on which the record starts.  Characters after a closing quote are
 * kept literally.  An unterminated quoted field exits 4.
 * Registers: r12 read pointer, r13 field start, r14 end, r15 line,
 * rbx field count, rdi write pointer inside quoted fields.
 */
i_csv_record:
    ENTER 16
    mov i_pos(%rip), %r12
    mov i_end(%rip), %r14
    mov i_line(%rip), %r15
    xor %ebx, %ebx
.Lr_skip:                       /* empty lines */
    cmp %r14, %r12
    jae .Lr_eof
    movzbl (%r12), %eax
    cmp $'\n', %eax
    jne 1f
    inc %r12
    inc %r15
    jmp .Lr_skip
1:  cmp $'\r', %eax
    jne .Lr_start
    lea 1(%r12), %rcx
    cmp %r14, %rcx
    jae .Lr_start
    cmpb $'\n', 1(%r12)
    jne .Lr_start
    add $2, %r12
    inc %r15
    jmp .Lr_skip
.Lr_start:
    mov %r15, i_rec_line(%rip)
.Lr_field:
    mov %r12, %r13
    movzbl i_delim(%rip), %edx
    cmp %r14, %r12
    jae .Lr_unq_end
    cmpb $'"', (%r12)
    je .Lr_quoted
.Lr_unq:                        /* unquoted: the span itself */
    cmp %r14, %r12
    jae .Lr_unq_end
    movzbl (%r12), %eax
    cmp %edx, %eax
    je .Lr_unq_end
    cmp $'\n', %eax
    je .Lr_unq_end
    cmp $'\r', %eax
    jne 2f
    lea 1(%r12), %rcx
    cmp %r14, %rcx
    jae .Lr_unq_end
    cmpb $'\n', 1(%r12)
    je .Lr_unq_end
2:  inc %r12
    jmp .Lr_unq
.Lr_unq_end:
    mov %r12, %rsi
    sub %r13, %rsi
    jmp .Lr_add
.Lr_quoted:
    inc %r12
    mov %r13, %rdi
.Lr_q:
    cmp %r14, %r12
    jae .Lr_unterminated
    movzbl (%r12), %eax
    cmp $'"', %eax
    jne 3f
    lea 1(%r12), %rcx
    cmp %r14, %rcx
    jae .Lr_qclose
    cmpb $'"', 1(%r12)
    jne .Lr_qclose
    movb $'"', (%rdi)           /* "" -> " */
    inc %rdi
    add $2, %r12
    jmp .Lr_q
3:  cmp $'\n', %eax
    jne 4f
    inc %r15
4:  mov %al, (%rdi)
    inc %rdi
    inc %r12
    jmp .Lr_q
.Lr_qclose:
    inc %r12
.Lr_qt:                         /* text after the closing quote */
    cmp %r14, %r12
    jae .Lr_q_end
    movzbl (%r12), %eax
    cmp %edx, %eax
    je .Lr_q_end
    cmp $'\n', %eax
    je .Lr_q_end
    cmp $'\r', %eax
    jne 5f
    lea 1(%r12), %rcx
    cmp %r14, %rcx
    jae .Lr_q_end
    cmpb $'\n', 1(%r12)
    je .Lr_q_end
5:  mov %al, (%rdi)
    inc %rdi
    inc %r12
    jmp .Lr_qt
.Lr_q_end:
    mov %rdi, %rsi
    sub %r13, %rsi
.Lr_add:                        /* field (r13, rsi) */
    cmp i_fcap(%rip), %rbx
    jb 6f
    mov %rsi, 0(%rsp)
    mov i_fcap(%rip), %rsi
    add %rsi, %rsi
    cmp $16, %rsi
    jae 7f
    mov $16, %esi
7:  mov %rsi, i_fcap(%rip)
    shl $4, %rsi
    mov i_fields(%rip), %rdi
    call xrealloc
    mov %rax, i_fields(%rip)
    mov 0(%rsp), %rsi
6:  mov i_fields(%rip), %rax
    mov %rbx, %rcx
    shl $4, %rcx
    mov %r13, (%rax,%rcx)
    mov %rsi, 8(%rax,%rcx)
    inc %rbx
    /* after the field: delimiter, end of record or end of data */
    cmp %r14, %r12
    jae .Lr_done
    movzbl (%r12), %eax
    movzbl i_delim(%rip), %edx
    cmp %edx, %eax
    jne 8f
    inc %r12
    jmp .Lr_field
8:  cmp $'\n', %eax
    jne 9f
    inc %r12
    inc %r15
    jmp .Lr_done
9:  inc %r12                    /* \r (of \r\n, or the last byte) */
    cmp %r14, %r12
    jae .Lr_done
    cmpb $'\n', (%r12)
    jne .Lr_done
    inc %r12
    inc %r15
.Lr_done:
    mov %r12, i_pos(%rip)
    mov %r15, i_line(%rip)
    mov %rbx, %rax
    LEAVE
.Lr_eof:
    mov %r12, i_pos(%rip)
    mov %r15, i_line(%rip)
    xor %eax, %eax
    LEAVE
.Lr_unterminated:
    mov i_path(%rip), %rdx
    mov i_rec_line(%rip), %rcx
    DIE EX_IMPORT, "%s:%ld: unterminated quoted field"

/* i_field(index rdi) -> rax ptr, rdx len of field `index` */
i_field:
    shl $4, %rdi
    add i_fields(%rip), %rdi
    mov (%rdi), %rax
    mov 8(%rdi), %rdx
    ret

/*
 * i_resolve(cref rdi, header esi) -> rax 0-based column index
 * A position must be within the record; a name needs the header (the
 * current record in i_fields) and is matched trimmed, ASCII
 * case-insensitively.  Exits 4 otherwise.
 */
i_resolve:
    ENTER 16
    mov %rdi, %rbx
    mov %esi, 0(%rsp)
    mov CREF_POS(%rbx), %rax
    test %rax, %rax
    jz 1f
    dec %rax
    cmp i_nexp(%rip), %rax
    jae 9f
    LEAVE
9:  mov i_path(%rip), %rdx
    mov CREF_POS(%rbx), %rcx
    mov i_nexp(%rip), %r8
    DIE EX_IMPORT, "%s: column %ld is beyond the record (%ld fields)"
1:  mov CREF_NAME(%rbx), %r12
    cmpl $0, 0(%rsp)
    jne 2f
    mov i_path(%rip), %rdx
    mov %r12, %rcx
    DIE EX_IMPORT, "%s: column '%s' is a name but the file has no header (header = false)"
2:  mov %r12, %rdi
    call strlen
    mov %rax, %r13
    xor %r14d, %r14d
3:  cmp i_nexp(%rip), %r14
    jae 5f
    mov %r14, %rdi
    call i_field
    mov %rax, %rdi
    lea (%rax,%rdx), %rsi
    call i_trim
    mov %rdx, %rcx
    sub %rax, %rcx
    cmp %r13, %rcx
    jne 4f
    mov %rax, %rdi
    mov %r12, %rsi
    mov %r13, %rdx
    call i_ieq
    test %eax, %eax
    jz 4f
    mov %r14, %rax
    LEAVE
4:  inc %r14
    jmp 3b
5:  mov i_path(%rip), %rdx
    mov %r12, %rcx
    DIE EX_IMPORT, "%s: the header has no column '%s'"

/* i_resolve_columns(header edi): all column references of the settings */
i_resolve_columns:
    ENTER 16
    mov %edi, %ebx
    lea i_acc+ACC_DATE_COL(%rip), %rdi
    mov %ebx, %esi
    call i_resolve
    mov %rax, i_cdate(%rip)
    lea i_acc+ACC_DESC_COL(%rip), %rdi
    mov %ebx, %esi
    call i_resolve
    mov %rax, i_cdesc(%rip)
    cmpq $AM_SIGNED, i_acc+ACC_AMOUNT_MODE(%rip)
    jne 1f
    lea i_acc+ACC_AMOUNT_COL(%rip), %rdi
    mov %ebx, %esi
    call i_resolve
    mov %rax, i_camt(%rip)
    LEAVE
1:  lea i_acc+ACC_DEBIT_COL(%rip), %rdi
    mov %ebx, %esi
    call i_resolve
    mov %rax, i_cdeb(%rip)
    lea i_acc+ACC_CREDIT_COL(%rip), %rdi
    mov %ebx, %esi
    call i_resolve
    mov %rax, i_ccred(%rip)
    LEAVE

/* i_bad_field(index rdi, what rsi): exits 4 with
 * "FILE:LINE: invalid WHAT 'TEXT'" for field `index` */
i_bad_field:
    ENTER 16
    mov %rsi, %rbx
    call i_field
    mov %rax, %r9
    mov %edx, %r8d
    mov i_path(%rip), %rdx
    mov i_rec_line(%rip), %rcx
    mov %rbx, %rsi              /* the format is chosen by `what` */
    mov $EX_IMPORT, %edi
    xor %eax, %eax
    call die

/* i_amount_field(index rdi) -> rax cents, edx status 0 ok / 1 empty;
 * an invalid amount exits 4 */
i_amount_field:
    ENTER 16
    mov %rdi, %rbx
    call i_field
    mov %rax, %rdi
    mov %rdx, %rsi
    lea i_acc(%rip), %rdx
    call imp_parse_amount
    cmp $2, %edx
    je 1f
    LEAVE
1:  mov %rbx, %rdi
    CSTR %rsi, "%s:%ld: invalid amount '%.*s'"
    call i_bad_field

/*
 * i_convert_record(): converts the record in i_fields into a new REC.
 * Registers: r15 ymd, r14 cents, r12/r13 description span.
 * Locals: 0 debit cents, 8 debit status, 16 merchant length, 24 offset.
 */
i_convert_record:
    ENTER 32
    /* date */
    mov i_cdate(%rip), %rdi
    call i_field
    mov %rax, %rdi
    mov %rdx, %rsi
    mov i_acc+ACC_DATE_FMT(%rip), %rdx
    call imp_parse_date
    test %rax, %rax
    jns 1f
    mov i_cdate(%rip), %rdi
    CSTR %rsi, "%s:%ld: invalid date '%.*s'"
    call i_bad_field
1:  mov %rax, %r15
    /* amount */
    cmpq $AM_SIGNED, i_acc+ACC_AMOUNT_MODE(%rip)
    jne 2f
    mov i_camt(%rip), %rdi
    call i_amount_field
    test %edx, %edx
    jz 3f
    mov i_camt(%rip), %rdi
    CSTR %rsi, "%s:%ld: invalid amount '%.*s'"
    call i_bad_field
2:  mov i_cdeb(%rip), %rdi      /* debit_credit: credit - debit */
    call i_amount_field
    mov %rax, 0(%rsp)
    mov %edx, 8(%rsp)
    mov i_ccred(%rip), %rdi
    call i_amount_field
    test %edx, %edx
    jz 4f
    cmpl $0, 8(%rsp)
    jz 4f
    mov i_path(%rip), %rdx
    mov i_rec_line(%rip), %rcx
    DIE EX_IMPORT, "%s:%ld: debit and credit are both empty"
4:  sub 0(%rsp), %rax
3:  mov %rax, %r14
    cmpq $0, i_acc+ACC_INVERT(%rip)
    je 5f
    neg %r14
5:  mov $999999999999999999, %rax     /* must fit DECIMAL(18,2) */
    cmp %rax, %r14
    jg 6f
    neg %rax
    cmp %rax, %r14
    jge 7f
6:  mov i_path(%rip), %rdx
    mov i_rec_line(%rip), %rcx
    DIE EX_IMPORT, "%s:%ld: amount out of range"
    /* description (trimmed) and merchant */
7:  mov i_cdesc(%rip), %rdi
    call i_field
    mov %rax, %rdi
    lea (%rax,%rdx), %rsi
    call i_trim
    mov %rax, %r12
    mov %rdx, %r13
    sub %r12, %r13
    cmp i_scap(%rip), %r13
    jbe 8f
    lea 64(%r13,%r13), %rsi
    mov %rsi, i_scap(%rip)
    mov i_scr(%rip), %rdi
    call xrealloc
    mov %rax, i_scr(%rip)
8:  mov %r12, %rdi
    mov %r13, %rsi
    mov i_scr(%rip), %rdx
    call imp_normalize_merchant
    mov %rax, 16(%rsp)
    mov i_merch+AB_LEN(%rip), %rcx
    mov %rcx, 24(%rsp)
    lea i_merch(%rip), %rdi
    mov i_scr(%rip), %rsi
    mov %rax, %rdx
    call ab_put
    /* append the REC */
    mov i_nrec(%rip), %rax
    cmp i_rcap(%rip), %rax
    jb 9f
    mov i_rcap(%rip), %rsi
    add %rsi, %rsi
    cmp $1024, %rsi
    jae 10f
    mov $1024, %esi
10: mov %rsi, i_rcap(%rip)
    shl $6, %rsi
    mov i_recs(%rip), %rdi
    call xrealloc
    mov %rax, i_recs(%rip)
9:  mov %r15, %rdi
    call imp_days_from_ymd
    mov i_nrec(%rip), %rbx
    shl $6, %rbx
    add i_recs(%rip), %rbx
    mov %r12, R_DESC(%rbx)
    mov %r13, R_DLEN(%rbx)
    mov 24(%rsp), %rcx
    mov %rcx, R_MOFF(%rbx)
    mov 16(%rsp), %rcx
    mov %rcx, R_MLEN(%rbx)
    mov %r14, R_CENTS(%rbx)
    mov %rax, R_DAYS(%rbx)
    mov %r15, R_YMD(%rbx)
    movq $0, R_FLAG(%rbx)
    incq i_nrec(%rip)
    LEAVE

/*
 * i_parse_file(): BOM, preamble, header, every data record -> i_recs.
 * Exits 4 on the first failing record.
 */
i_parse_file:
    ENTER 16
    mov i_file+AB_DATA(%rip), %rax
    mov i_file+AB_LEN(%rip), %rcx
    lea (%rax,%rcx), %rdx
    mov %rdx, i_end(%rip)
    cmp $3, %rcx
    jb 1f
    cmpb $0xEF, (%rax)
    jne 1f
    cmpb $0xBB, 1(%rax)
    jne 1f
    cmpb $0xBF, 2(%rax)
    jne 1f
    add $3, %rax
1:  mov %rax, i_pos(%rip)
    movq $1, i_line(%rip)
    mov i_acc+ACC_DELIM(%rip), %rax
    mov %rax, i_delim(%rip)
    /* skip_lines physical lines */
    mov i_acc+ACC_SKIP(%rip), %rbx
2:  test %rbx, %rbx
    jz 4f
    mov i_pos(%rip), %rdi
    mov i_end(%rip), %rdx
    sub %rdi, %rdx
    jz 4f
    mov $'\n', %esi
    call memchr
    test %rax, %rax
    jnz 3f
    mov i_end(%rip), %rax
    mov %rax, i_pos(%rip)
    jmp 4f
3:  inc %rax
    mov %rax, i_pos(%rip)
    incq i_line(%rip)
    dec %rbx
    jmp 2b
    /* first record: header, or the first data record */
4:  call i_csv_record
    test %rax, %rax
    jnz 5f
    cmpq $0, i_acc+ACC_HEADER(%rip)
    je 9f
    mov i_path(%rip), %rdx
    DIE EX_IMPORT, "%s: no header record"
5:  mov %rax, i_nexp(%rip)
    mov i_acc+ACC_HEADER(%rip), %rdi
    call i_resolve_columns
    mov i_nexp(%rip), %rax
    cmpq $0, i_acc+ACC_HEADER(%rip)
    je 7f
6:  call i_csv_record
    test %rax, %rax
    jz 9f
7:  cmp i_nexp(%rip), %rax
    je 8f
    mov %rax, %r9
    mov i_path(%rip), %rdx
    mov i_rec_line(%rip), %rcx
    mov i_nexp(%rip), %r8
    DIE EX_IMPORT, "%s:%ld: expected %ld fields, found %ld"
8:  call i_convert_record
    jmp 6b
9:  LEAVE

/* ======================================================================
 * duplicates (§6.4)
 * ====================================================================== */

/* i_key_hash(days rdi, cents rsi, ptr rdx, len rcx) -> rax (never 0) */
i_key_hash:
    mov $0xcbf29ce484222325, %rax       /* FNV-1a over the merchant */
    mov $0x100000001b3, %r8
    xor %r9d, %r9d
1:  cmp %rcx, %r9
    jae 2f
    movzbl (%rdx,%r9), %r10d
    xor %r10, %rax
    imul %r8, %rax
    inc %r9
    jmp 1b
2:  mov $0x9E3779B97F4A7C15, %r8
    mov %rdi, %r10
    imul %r8, %r10
    xor %r10, %rax
    rol $31, %rax
    mov %rsi, %r10
    imul %r8, %r10
    xor %r10, %rax
    mov %rax, %r10                      /* final avalanche */
    shr $29, %r10
    xor %r10, %rax
    mov $0xBF58476D1CE4E5B9, %r8
    imul %r8, %rax
    mov %rax, %r10
    shr $32, %r10
    xor %r10, %rax
    test %rax, %rax
    jnz 3f
    mov $1, %eax
3:  ret

/* i_ht_find(days rdi, cents rsi, ptr rdx, len rcx) -> rax entry of the key
 * (inserted with zero counters when new).  Linear probing.
 * Locals: 0 entry, 8 slot index. */
i_ht_find:
    ENTER 16
    mov %rdi, %r12
    mov %rsi, %r13
    mov %rdx, %r14
    mov %rcx, %r15
    call i_key_hash
    mov %rax, %rbx
    and i_hmask(%rip), %rax
    mov %rax, 8(%rsp)
1:  mov 8(%rsp), %rax
    imul $H_SIZE, %rax, %rax
    add i_ht(%rip), %rax
    mov %rax, 0(%rsp)
    mov H_HASH(%rax), %rcx
    test %rcx, %rcx
    jz 3f
    cmp %rbx, %rcx
    jne 2f
    cmp H_DAYS(%rax), %r12
    jne 2f
    cmp H_CENTS(%rax), %r13
    jne 2f
    cmp H_MLEN(%rax), %r15
    jne 2f
    mov H_MPTR(%rax), %rdi
    mov %r14, %rsi
    mov %r15, %rdx
    call memcmp
    test %eax, %eax
    jnz 2f
    mov 0(%rsp), %rax
    LEAVE
2:  mov 8(%rsp), %rax
    inc %rax
    and i_hmask(%rip), %rax
    mov %rax, 8(%rsp)
    jmp 1b
3:  mov %rbx, H_HASH(%rax)
    mov %r12, H_DAYS(%rax)
    mov %r13, H_CENTS(%rax)
    mov %r14, H_MPTR(%rax)
    mov %r15, H_MLEN(%rax)
    LEAVE

/*
 * i_find_duplicates(): marks the records to import (R_FLAG), counts
 * i_nimp / i_ndup.  Locals: 0 result, 8 ledger rows, 16 loop index.
 */
i_find_duplicates:
    ENTER 32
    lea i_buf(%rip), %rdi
    call ab_clear
    lea i_buf(%rip), %rdi
    CSTR %rsi, "SELECT \"date\", amount, merchant, COUNT(*) AS n FROM transactions WHERE account = "
    call ab_puts
    lea i_buf(%rip), %rdi
    mov i_account(%rip), %rsi
    call ab_put_sqlstr
    lea i_buf(%rip), %rdi
    CSTR %rsi, " GROUP BY \"date\", amount, merchant"
    call ab_puts
    mov i_buf+AB_DATA(%rip), %rdi
    call ledger_query
    mov %rax, 0(%rsp)
    mov PQ_RES_NROWS(%rax), %rcx
    mov %rcx, 8(%rsp)
    /* table: a power of two >= 2 * (records + ledger keys) */
    add i_nrec(%rip), %rcx
    add %rcx, %rcx
    mov $16, %eax
1:  cmp %rcx, %rax
    jae 2f
    add %rax, %rax
    jmp 1b
2:  lea -1(%rax), %rcx
    mov %rcx, i_hmask(%rip)
    imul $H_SIZE, %rax, %rbx
    mov %rbx, %rdi
    call xmalloc
    mov %rax, i_ht(%rip)
    mov %rax, %rdi
    xor %esi, %esi
    mov %rbx, %rdx
    call memset
    /* the ledger's keys: values (date, amount, merchant, n) per row */
    mov 0(%rsp), %rax
    mov PQ_RES_VALUES(%rax), %r12
    xor %r13d, %r13d
3:  cmp 8(%rsp), %r13
    jae 4f
    mov PQ_VAL_DAYS(%r12), %rdi
    mov PQ_VAL_SIZE+PQ_VAL_DEC_LO(%r12), %rsi
    mov 2*PQ_VAL_SIZE+PQ_VAL_STR_PTR(%r12), %rdx
    mov 2*PQ_VAL_SIZE+PQ_VAL_STR_LEN(%r12), %rcx
    call i_ht_find
    mov 3*PQ_VAL_SIZE+PQ_VAL_I64(%r12), %rcx
    add %ecx, H_L(%rax)
    add $4*PQ_VAL_SIZE, %r12
    inc %r13
    jmp 3b
    /* the file's records in order */
4:  mov i_recs(%rip), %r12
    xor %r13d, %r13d
    xor %r14d, %r14d            /* imported */
    xor %r15d, %r15d            /* duplicates */
5:  cmp i_nrec(%rip), %r13
    jae 8f
    mov R_DAYS(%r12), %rdi
    mov R_CENTS(%r12), %rsi
    mov R_MOFF(%r12), %rdx
    add i_merch+AB_DATA(%rip), %rdx
    mov R_MLEN(%r12), %rcx
    call i_ht_find
    mov H_K(%rax), %ecx
    incl H_K(%rax)
    cmp H_L(%rax), %ecx
    jb 6f
    movq $1, R_FLAG(%r12)
    inc %r14
    jmp 7f
6:  inc %r15
7:  add $R_SIZE, %r12
    inc %r13
    jmp 5b
8:  mov %r14, i_nimp(%rip)
    mov %r15, i_ndup(%rip)
    mov i_ht(%rip), %rdi
    call free
    mov 0(%rsp), %rdi
    call pq_result_free
    LEAVE

/* ======================================================================
 * ledger update
 * ====================================================================== */

/* i_scalar(sql rdi) -> rax the INT64 value of row 0, column 0 (0 when
 * the result is empty or NULL) */
i_scalar:
    ENTER
    call ledger_query
    mov %rax, %r12
    xor %ebx, %ebx
    cmpq $0, PQ_RES_NROWS(%r12)
    je 1f
    mov PQ_RES_VALUES(%r12), %rax
    cmpq $0, PQ_VAL_IS_NULL(%rax)
    jne 1f
    mov PQ_VAL_I64(%rax), %rbx
1:  mov %r12, %rdi
    call pq_result_free
    mov %rbx, %rax
    LEAVE

/* i_next_numbers(): i_next_id = max(id) + 1, i_batch = max(batch) + 1 */
i_next_numbers:
    ENTER
    CSTR %rdi, "SELECT COALESCE(MAX(id), 0) AS m FROM transactions"
    call i_scalar
    inc %rax
    mov %rax, i_next_id(%rip)
    CSTR %rdi, "SELECT COALESCE(MAX(batch), 0) AS m FROM batches"
    call i_scalar
    inc %rax
    mov %rax, i_batch(%rip)
    LEAVE

/* i_put_tx_row(rec rdi, id rsi): appends one CSV row of new_tx to i_buf:
 * id,"account",date,"description","merchant",amount,batch */
i_put_tx_row:
    ENTER
    mov %rdi, %rbx
    mov %rsi, %r12
    mov R_DLEN(%rbx), %rsi
    add R_MLEN(%rbx), %rsi
    add i_acclen(%rip), %rsi
    add %rsi, %rsi
    add $160, %rsi
    lea i_buf(%rip), %rdi
    call ab_reserve
    mov i_buf+AB_DATA(%rip), %rdi
    add i_buf+AB_LEN(%rip), %rdi
    mov %r12, %rsi
    call i_w_i64
    movb $',', (%rax)
    lea 1(%rax), %rdi
    mov i_account(%rip), %rsi
    mov i_acclen(%rip), %rdx
    call i_w_quoted
    movb $',', (%rax)
    lea 1(%rax), %rdi
    mov R_YMD(%rbx), %rsi
    call i_w_date
    movb $',', (%rax)
    lea 1(%rax), %rdi
    mov R_DESC(%rbx), %rsi
    mov R_DLEN(%rbx), %rdx
    call i_w_quoted
    movb $',', (%rax)
    lea 1(%rax), %rdi
    mov R_MOFF(%rbx), %rsi
    add i_merch+AB_DATA(%rip), %rsi
    mov R_MLEN(%rbx), %rdx
    call i_w_quoted
    movb $',', (%rax)
    lea 1(%rax), %rdi
    mov R_CENTS(%rbx), %rsi
    call i_w_cents
    movb $',', (%rax)
    lea 1(%rax), %rdi
    mov i_batch(%rip), %rsi
    call i_w_i64
    movb $'\n', (%rax)
    movb $0, 1(%rax)
    inc %rax
    sub i_buf+AB_DATA(%rip), %rax
    mov %rax, i_buf+AB_LEN(%rip)
    LEAVE

/* i_put_batch_row(): appends the batches row to i_buf:
 * batch,"account","file base name",imported,duplicates */
i_put_batch_row:
    ENTER
    mov i_path(%rip), %rdi
    mov $'/', %esi
    call strrchr
    lea 1(%rax), %rbx
    test %rax, %rax
    jnz 1f
    mov i_path(%rip), %rbx
1:  mov %rbx, %rdi
    call strlen
    mov %rax, %r12              /* base name length */
    lea 160(%rax,%rax), %rsi
    add i_acclen(%rip), %rsi
    add i_acclen(%rip), %rsi
    lea i_buf(%rip), %rdi
    call ab_reserve
    mov i_buf+AB_DATA(%rip), %rdi
    add i_buf+AB_LEN(%rip), %rdi
    mov i_batch(%rip), %rsi
    call i_w_i64
    movb $',', (%rax)
    lea 1(%rax), %rdi
    mov i_account(%rip), %rsi
    mov i_acclen(%rip), %rdx
    call i_w_quoted
    movb $',', (%rax)
    lea 1(%rax), %rdi
    mov %rbx, %rsi
    mov %r12, %rdx
    call i_w_quoted
    movb $',', (%rax)
    lea 1(%rax), %rdi
    mov i_nimp(%rip), %rsi
    call i_w_i64
    movb $',', (%rax)
    lea 1(%rax), %rdi
    mov i_ndup(%rip), %rsi
    call i_w_i64
    movb $'\n', (%rax)
    movb $0, 1(%rax)
    inc %rax
    sub i_buf+AB_DATA(%rip), %rax
    mov %rax, i_buf+AB_LEN(%rip)
    LEAVE

/* i_append(table rdi, opts rsi, sql rdx): loads i_buf as the scratch
 * table named by opts' caller (table), then replaces the ledger table by
 * `sql`.  Engine errors exit 7.
 * Arguments: rdi scratch table name, rsi load options, rdx ledger table,
 * rcx CREATE TABLE AS query. */
i_append:
    ENTER 16
    mov %rdx, %r12
    mov %rcx, %r13
    mov %rsi, %r8
    mov %rdi, %rsi
    mov g_db(%rip), %rdi
    mov i_buf+AB_DATA(%rip), %rdx
    mov i_buf+AB_LEN(%rip), %rcx
    xor %r9d, %r9d
    call pq_load_text
    test %eax, %eax
    jnz 9f
    mov g_db(%rip), %rdi
    mov %r12, %rsi
    mov %r13, %rdx
    xor %ecx, %ecx
    mov $1, %r8d
    xor %r9d, %r9d
    call pq_create_table
    test %eax, %eax
    jnz 9f
    LEAVE
9:  mov $EX_OTHER, %edi
    mov g_db(%rip), %rsi
    call die_engine

/* i_write_ledger(): new transactions and the batch row; saves batches,
 * then transactions */
i_write_ledger:
    ENTER
    cmpq $0, i_nimp(%rip)
    je 3f
    lea i_buf(%rip), %rdi
    call ab_clear
    mov i_recs(%rip), %rbx
    xor %r12d, %r12d
    mov i_next_id(%rip), %r13
1:  cmp i_nrec(%rip), %r12
    jae 2f
    cmpq $0, R_FLAG(%rbx)
    je 4f
    mov %rbx, %rdi
    mov %r13, %rsi
    call i_put_tx_row
    inc %r13
4:  add $R_SIZE, %rbx
    inc %r12
    jmp 1b
2:  lea s_new_tx(%rip), %rdi
    lea i_tx_opts(%rip), %rsi
    lea s_tx(%rip), %rdx
    CSTR %rcx, "SELECT * FROM transactions UNION ALL SELECT * FROM new_tx ORDER BY id"
    call i_append
    mov g_db(%rip), %rdi
    lea s_new_tx(%rip), %rsi
    call pq_drop
3:  lea i_buf(%rip), %rdi
    call ab_clear
    call i_put_batch_row
    lea s_new_b(%rip), %rdi
    lea i_b_opts(%rip), %rsi
    lea s_batches(%rip), %rdx
    CSTR %rcx, "SELECT * FROM batches UNION ALL SELECT * FROM new_batch ORDER BY batch"
    call i_append
    mov g_db(%rip), %rdi
    lea s_new_b(%rip), %rsi
    call pq_drop
    lea s_batches(%rip), %rdi
    call ledger_save
    cmpq $0, i_nimp(%rip)
    je 5f
    lea s_tx(%rip), %rdi
    call ledger_save
5:  LEAVE
