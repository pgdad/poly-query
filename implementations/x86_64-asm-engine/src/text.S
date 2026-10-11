/*
 * text.S - text <-> value conversion: parsing of numbers, booleans, dates,
 * timestamps and type names; canonical formatting of values; decimal and
 * float helpers.
 *
 * Parser convention: value in %rax (float parser: %xmm0), status in %edx
 * (float parser: %eax): 0 = ok, 1 = syntax error, 2 = out of range /
 * overflow, 3 = too many fractional digits (exact decimal mode only).
 * On error the value returned is 0.
 */
#include "pq.inc"

    .section .note.GNU-stack, "", @progbits

/* ======================================================== constants */
    .section .rodata
    .p2align 3
    .globl pow10_u64
pow10_u64:
    .quad 1, 10, 100, 1000, 10000, 100000, 1000000, 10000000
    .quad 100000000, 1000000000, 10000000000, 100000000000
    .quad 1000000000000, 10000000000000, 100000000000000
    .quad 1000000000000000, 10000000000000000, 100000000000000000
    .quad 1000000000000000000
    .size pow10_u64, .-pow10_u64

d_two63:     .double 9223372036854775808.0
d_mtwo63:    .double -9223372036854775808.0

/* days per month (index 1..12) */
mdays:      .byte 0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31

/* type name table: kind byte, length byte, lowercase name; 0xff ends */
type_names:
    .byte T_BOOL, 7
    .ascii "boolean"
    .byte T_BOOL, 4
    .ascii "bool"
    .byte T_INT, 5
    .ascii "int64"
    .byte T_INT, 3
    .ascii "int"
    .byte T_INT, 7
    .ascii "integer"
    .byte T_INT, 6
    .ascii "bigint"
    .byte T_FLOAT, 7
    .ascii "float64"
    .byte T_FLOAT, 6
    .ascii "double"
    .byte T_FLOAT, 5
    .ascii "float"
    .byte T_FLOAT, 4
    .ascii "real"
    .byte T_STR, 6
    .ascii "string"
    .byte T_STR, 7
    .ascii "varchar"
    .byte T_STR, 4
    .ascii "text"
    .byte T_DATE, 4
    .ascii "date"
    .byte T_TS, 9
    .ascii "timestamp"
    .byte T_DEC, 7
    .ascii "decimal"
    .byte T_DEC, 7
    .ascii "numeric"
    .byte 0xff, 0

/* printf formats for fmt_float, each exactly 6 bytes */
float_fmts:
    .asciz "%.15g"
    .asciz "%.16g"
    .asciz "%.17g"

    .text

/* ======================================================== trimming */

/* text_trim(ptr rdi, len rsi) -> rax ptr, rdx len (strips ASCII space/tab) */
FUNC text_trim
    mov %rdi, %rax
    mov %rsi, %rdx
1:  test %rdx, %rdx
    jz 9f
    movzbl (%rax), %ecx
    cmp $32, %ecx
    je 2f
    cmp $9, %ecx
    jne 3f
2:  inc %rax
    dec %rdx
    jmp 1b
3:  movzbl -1(%rax, %rdx), %ecx     /* first byte is not blank, so len stays >= 1 */
    cmp $32, %ecx
    je 4f
    cmp $9, %ecx
    jne 9f
4:  dec %rdx
    jmp 3b
9:  ret
ENDF text_trim

/* ======================================================== integers */

/* text_parse_int64(ptr rdi, len rsi) -> rax value, edx status
 * syntax ^[+-]?[0-9]+$ ; out of range -> 2 */
FUNC text_parse_int64
    xor %eax, %eax                  /* magnitude */
    xor %r8d, %r8d                  /* 1 = negative */
    xor %ecx, %ecx                  /* index */
    xor %r10d, %r10d                /* overflow seen */
    test %rsi, %rsi
    jz .Lpi_syn
    movzbl (%rdi), %edx
    cmp $'+', %edx
    je 1f
    cmp $'-', %edx
    jne 2f
    mov $1, %r8d
1:  inc %rcx
2:  cmp %rsi, %rcx
    jae .Lpi_syn                    /* need at least one digit */
    movabs $922337203685477580, %r9
    movabs $0x8000000000000000, %r11
3:  movzbl (%rdi, %rcx), %edx
    sub $'0', %edx
    cmp $9, %edx
    ja .Lpi_syn
    test %r10d, %r10d
    jnz 5f
    cmp %r9, %rax
    ja 4f
    lea (%rax, %rax, 4), %rax
    add %rax, %rax
    add %rdx, %rax                  /* <= 9223372036854775809, fits unsigned */
    cmp %r11, %rax
    jbe 5f
4:  mov $1, %r10d
5:  inc %rcx
    cmp %rsi, %rcx
    jb 3b
    test %r10d, %r10d
    jnz .Lpi_ovf
    test %r8d, %r8d
    jz 6f
    neg %rax                        /* 2^63 -> INT64_MIN */
    xor %edx, %edx
    ret
6:  test %rax, %rax
    js .Lpi_ovf                     /* +2^63 does not fit */
    xor %edx, %edx
    ret
.Lpi_ovf:
    xor %eax, %eax
    mov $2, %edx
    ret
.Lpi_syn:
    xor %eax, %eax
    mov $1, %edx
    ret
ENDF text_parse_int64

/* ======================================================== floats */

/* text_parse_float(ptr rdi, len rsi) -> xmm0 value, eax status
 * syntax ^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$ ; non-finite -> 2 */
FUNC text_parse_float
    ENTER 288
    mov %rdi, %rbx
    mov %rsi, %r12
    xor %ecx, %ecx
    test %r12, %r12
    jz .Lpf_syn
    movzbl (%rbx), %eax
    cmp $'+', %eax
    je 1f
    cmp $'-', %eax
    jne 2f
1:  inc %rcx
2:  xor %r8d, %r8d                  /* mantissa digit count */
3:  cmp %r12, %rcx
    jae 5f
    movzbl (%rbx, %rcx), %eax
    sub $'0', %eax
    cmp $9, %eax
    ja 4f
    inc %rcx
    inc %r8
    jmp 3b
4:  cmpb $'.', (%rbx, %rcx)
    jne 5f
    inc %rcx
6:  cmp %r12, %rcx
    jae 5f
    movzbl (%rbx, %rcx), %eax
    sub $'0', %eax
    cmp $9, %eax
    ja 5f
    inc %rcx
    inc %r8
    jmp 6b
5:  test %r8, %r8
    jz .Lpf_syn
    cmp %r12, %rcx
    je .Lpf_conv
    movzbl (%rbx, %rcx), %eax
    or $0x20, %eax
    cmp $'e', %eax
    jne .Lpf_syn
    inc %rcx
    cmp %r12, %rcx
    jae .Lpf_syn
    movzbl (%rbx, %rcx), %eax
    cmp $'+', %eax
    je 7f
    cmp $'-', %eax
    jne 8f
7:  inc %rcx
8:  xor %r8d, %r8d
9:  cmp %r12, %rcx
    jae 10f
    movzbl (%rbx, %rcx), %eax
    sub $'0', %eax
    cmp $9, %eax
    ja .Lpf_syn
    inc %rcx
    inc %r8
    jmp 9b
10: test %r8, %r8
    jz .Lpf_syn
.Lpf_conv:
    /* NUL-terminated copy: 256-byte stack buffer at 16(%rsp), else malloc */
    xor %r14d, %r14d
    lea 16(%rsp), %r13
    cmp $255, %r12
    jbe 11f
    lea 1(%r12), %rdi
    call xmalloc
    mov %rax, %r13
    mov %rax, %r14
11: mov %r13, %rdi
    mov %rbx, %rsi
    mov %r12, %rdx
    call memcpy
    movb $0, (%r13, %r12)
    mov %r13, %rdi
    xor %esi, %esi
    call strtod
    movsd %xmm0, (%rsp)
    test %r14, %r14
    jz 12f
    mov %r14, %rdi
    call free
12: mov (%rsp), %rax
    mov %rax, %rcx
    shl $1, %rcx
    shr $53, %rcx
    cmp $0x7ff, %ecx
    je .Lpf_ovf
    movq %rax, %xmm0
    xor %eax, %eax
    LEAVE
.Lpf_ovf:
    pxor %xmm0, %xmm0
    mov $2, %eax
    LEAVE
.Lpf_syn:
    pxor %xmm0, %xmm0
    mov $1, %eax
    LEAVE
ENDF text_parse_float

/* ======================================================== decimals */

/* text_parse_decimal(ptr rdi, len rsi, prec edx, scale ecx, mode r8d)
 *   -> rax unscaled, edx status
 * syntax ^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)$
 * mode 0 = exact (more than `scale` fractional digits -> 3),
 * mode 1 = round half away from zero. |unscaled| >= 10^prec -> 2. */
FUNC text_parse_decimal
    ENTER 16
    mov %rdi, %rbx                  /* ptr */
    mov %rsi, %r12                  /* len */
    mov %edx, %r13d                 /* prec */
    mov %ecx, %r14d                 /* scale */
    mov %r8d, %r15d                 /* mode */
    cmp $18, %r13d
    jbe 1f
    mov $18, %r13d                  /* also catches negative values */
1:  cmp $18, %r14d
    jbe 2f
    mov $18, %r14d
2:  movq $0, (%rsp)                 /* negative flag */
    xor %ecx, %ecx
    test %r12, %r12
    jz .Lpd_syn
    movzbl (%rbx), %eax
    cmp $'+', %eax
    je 3f
    cmp $'-', %eax
    jne 4f
    movq $1, (%rsp)
3:  inc %rcx
4:  mov %rcx, %r9                   /* int start */
5:  cmp %r12, %rcx
    jae 6f
    movzbl (%rbx, %rcx), %eax
    sub $'0', %eax
    cmp $9, %eax
    ja 6f
    inc %rcx
    jmp 5b
6:  mov %rcx, %r10                  /* int end */
    mov %rcx, %r11                  /* frac start */
    mov %rcx, %rdi                  /* frac end */
    cmp %r12, %rcx
    jae 8f
    cmpb $'.', (%rbx, %rcx)
    jne .Lpd_syn
    inc %rcx
    mov %rcx, %r11
7:  cmp %r12, %rcx
    jae 71f
    movzbl (%rbx, %rcx), %eax
    sub $'0', %eax
    cmp $9, %eax
    ja .Lpd_syn
    inc %rcx
    jmp 7b
71: mov %rcx, %rdi
8:  /* need at least one digit overall */
    mov %r10, %rax
    sub %r9, %rax
    mov %rdi, %rdx
    sub %r11, %rdx
    add %rdx, %rax
    jz .Lpd_syn
    /* fractional digits vs scale */
    xor %esi, %esi                  /* round-up flag */
    mov %r14d, %eax
    cmp %rax, %rdx
    jbe 9f
    test %r15d, %r15d
    jz .Lpd_frac
    lea (%r11, %rax), %rdi          /* use only `scale` digits */
    movzbl (%rbx, %rdi), %eax
    cmp $'5', %eax
    setae %sil
9:  /* integer part: skip leading zeros */
    cmp %r10, %r9
    jae 10f
    cmpb $'0', (%rbx, %r9)
    jne 10f
    inc %r9
    jmp 9b
10: mov %r10, %rax
    sub %r9, %rax
    cmp $18, %rax
    ja .Lpd_ovf
    xor %r8d, %r8d                  /* int value */
11: cmp %r10, %r9
    jae 12f
    movzbl (%rbx, %r9), %eax
    sub $'0', %eax
    lea (%r8, %r8, 4), %r8
    lea (%rax, %r8, 2), %r8
    inc %r9
    jmp 11b
12: /* fraction value over digits r11..rdi */
    xor %ecx, %ecx                  /* frac value */
    mov %rdi, %rdx
    sub %r11, %rdx                  /* digit count (<= scale) */
13: cmp %rdi, %r11
    jae 14f
    movzbl (%rbx, %r11), %eax
    sub $'0', %eax
    lea (%rcx, %rcx, 4), %rcx
    lea (%rax, %rcx, 2), %rcx
    inc %r11
    jmp 13b
14: lea pow10_u64(%rip), %r9
    mov %r14d, %eax
    sub %rdx, %rax                  /* padding digits */
    imul (%r9, %rax, 8), %rcx       /* frac * 10^(scale - n) < 10^18 */
    mov %r14d, %eax
    mov (%r9, %rax, 8), %rax
    mul %r8                         /* int * 10^scale */
    test %rdx, %rdx
    jnz .Lpd_ovf
    add %rcx, %rax
    jc .Lpd_ovf
    add %rsi, %rax
    jc .Lpd_ovf
    mov %r13d, %ecx
    cmp (%r9, %rcx, 8), %rax
    jae .Lpd_ovf
    cmpq $0, (%rsp)
    je 15f
    neg %rax
15: xor %edx, %edx
    LEAVE
.Lpd_syn:
    xor %eax, %eax
    mov $1, %edx
    LEAVE
.Lpd_ovf:
    xor %eax, %eax
    mov $2, %edx
    LEAVE
.Lpd_frac:
    xor %eax, %eax
    mov $3, %edx
    LEAVE
ENDF text_parse_decimal

/* ======================================================== booleans */

/* text_parse_bool(ptr rdi, len rsi) -> rax 0/1, edx status ("true"/"false", any case) */
FUNC text_parse_bool
    cmp $4, %rsi
    jne 1f
    mov (%rdi), %eax
    or $0x20202020, %eax
    cmp $0x65757274, %eax           /* "true" */
    jne 9f
    mov $1, %eax
    xor %edx, %edx
    ret
1:  cmp $5, %rsi
    jne 9f
    mov (%rdi), %eax
    or $0x20202020, %eax
    cmp $0x736c6166, %eax           /* "fals" */
    jne 9f
    movzbl 4(%rdi), %eax
    or $0x20, %eax
    cmp $'e', %eax
    jne 9f
    xor %eax, %eax
    xor %edx, %edx
    ret
9:  xor %eax, %eax
    mov $1, %edx
    ret
ENDF text_parse_bool

/* ======================================================== calendar */

/* days_from_civil(y edi, m esi, d edx) -> rax days since 1970-01-01
 * (proleptic Gregorian, H. Hinnant's algorithm; leaf) */
FUNC days_from_civil
    movslq %edi, %rdi
    movslq %esi, %rsi
    movslq %edx, %r8
    cmp $2, %rsi
    jg 1f
    dec %rdi                        /* y -= (m <= 2) */
1:  mov %rdi, %rax
    test %rax, %rax
    jns 2f
    sub $399, %rax
2:  cqo
    mov $400, %ecx
    idiv %rcx
    mov %rax, %r9                   /* era */
    imul $400, %rax, %rcx
    mov %rdi, %r10
    sub %rcx, %r10                  /* yoe 0..399 */
    lea -3(%rsi), %rax
    lea 9(%rsi), %rcx
    cmp $2, %rsi
    cmovle %rcx, %rax               /* m > 2 ? m-3 : m+9 */
    imul $153, %rax, %rax
    add $2, %rax
    cqo
    mov $5, %ecx
    idiv %rcx
    lea -1(%rax, %r8), %r11         /* doy */
    mov %r10, %rax
    xor %edx, %edx
    mov $100, %ecx
    div %rcx                        /* yoe / 100 */
    imul $365, %r10, %rcx
    sub %rax, %rcx
    mov %r10, %rax
    shr $2, %rax
    add %rax, %rcx
    add %r11, %rcx                  /* doe */
    imul $146097, %r9, %rax
    add %rcx, %rax
    sub $719468, %rax
    ret
ENDF days_from_civil

/* civil_from_days(days rdi) -> rax year, rdx month (1..12), rcx day (1..31)
 * NOTE: non-standard 3-register return. Clobbers only caller-saved regs. */
FUNC civil_from_days
    lea 719468(%rdi), %rax
    mov %rax, %r8                   /* z */
    test %rax, %rax
    jns 1f
    sub $146096, %rax
1:  cqo
    mov $146097, %ecx
    idiv %rcx
    mov %rax, %r9                   /* era */
    imul $146097, %rax, %rcx
    mov %r8, %r10
    sub %rcx, %r10                  /* doe 0..146096 */
    mov %r10, %r11
    mov %r10, %rax
    xor %edx, %edx
    mov $1460, %ecx
    div %rcx
    sub %rax, %r11
    mov %r10, %rax
    xor %edx, %edx
    mov $36524, %ecx
    div %rcx
    add %rax, %r11
    mov %r10, %rax
    xor %edx, %edx
    mov $146096, %ecx
    div %rcx
    sub %rax, %r11
    mov %r11, %rax
    xor %edx, %edx
    mov $365, %ecx
    div %rcx
    mov %rax, %r11                  /* yoe */
    imul $400, %r9, %r9
    add %r11, %r9                   /* y */
    imul $365, %r11, %rcx
    mov %r11, %rax
    shr $2, %rax
    add %rax, %rcx
    mov %r11, %rax
    xor %edx, %edx
    mov $100, %r8d
    div %r8
    sub %rax, %rcx
    mov %r10, %rsi
    sub %rcx, %rsi                  /* doy */
    lea 2(%rsi, %rsi, 4), %rax
    xor %edx, %edx
    mov $153, %ecx
    div %rcx
    mov %rax, %rdi                  /* mp */
    imul $153, %rdi, %rax
    add $2, %rax
    xor %edx, %edx
    mov $5, %ecx
    div %rcx
    sub %rax, %rsi
    inc %rsi                        /* d */
    lea 3(%rdi), %rdx
    lea -9(%rdi), %rax
    cmp $10, %rdi
    cmovae %rax, %rdx               /* m */
    cmp $2, %rdx
    ja 2f
    inc %r9
2:  mov %r9, %rax
    mov %rsi, %rcx
    ret
ENDF civil_from_days

/* rd_digits(ptr rdi, n esi) -> rax value, or -1 if a non-digit is found (leaf, internal) */
rd_digits:
    xor %eax, %eax
    test %esi, %esi
    jz 2f
1:  movzbl (%rdi), %ecx
    sub $'0', %ecx
    cmp $9, %ecx
    ja 3f
    lea (%rax, %rax, 4), %rax
    lea (%rcx, %rax, 2), %rax
    inc %rdi
    dec %esi
    jnz 1b
2:  ret
3:  mov $-1, %rax
    ret

/* parse_ymd(ptr rdi) -> rax days, edx status; reads exactly 10 bytes "YYYY-MM-DD" (internal) */
parse_ymd:
    ENTER 0
    mov %rdi, %rbx
    cmpb $'-', 4(%rbx)
    jne 9f
    cmpb $'-', 7(%rbx)
    jne 9f
    mov %rbx, %rdi
    mov $4, %esi
    call rd_digits
    test %rax, %rax
    jle 9f                          /* non-digit or year 0000 */
    mov %rax, %r12
    lea 5(%rbx), %rdi
    mov $2, %esi
    call rd_digits
    mov %rax, %r13
    lea 8(%rbx), %rdi
    mov $2, %esi
    call rd_digits
    mov %rax, %r14
    dec %r13
    cmp $11, %r13
    ja 9f                           /* month not 1..12 (also catches -1) */
    inc %r13
    test %r14, %r14
    jle 9f
    lea mdays(%rip), %rax
    movzbl (%rax, %r13), %ecx
    cmp $2, %r13
    jne 2f
    /* leap year: y%4==0 && (y%100!=0 || y%400==0) */
    test $3, %r12d
    jnz 2f
    mov %r12, %rax
    xor %edx, %edx
    mov $100, %r8d
    div %r8
    test %rdx, %rdx
    jnz 1f
    mov %r12, %rax
    xor %edx, %edx
    mov $400, %r8d
    div %r8
    test %rdx, %rdx
    jnz 2f
1:  mov $29, %ecx
2:  cmp %rcx, %r14
    ja 9f
    mov %r12d, %edi
    mov %r13d, %esi
    mov %r14d, %edx
    call days_from_civil
    xor %edx, %edx
    LEAVE
9:  xor %eax, %eax
    mov $1, %edx
    LEAVE

/* text_parse_date(ptr rdi, len rsi) -> rax days, edx status ("YYYY-MM-DD", valid date) */
FUNC text_parse_date
    cmp $10, %rsi
    jne 1f
    jmp parse_ymd
1:  xor %eax, %eax
    mov $1, %edx
    ret
ENDF text_parse_date

/* text_parse_timestamp(ptr rdi, len rsi, allow_date_only edx) -> rax micros, edx status
 * "YYYY-MM-DD[ T]HH:MM:SS(.f{1,6})?"; bare date accepted when allow_date_only != 0 */
FUNC text_parse_timestamp
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %edx, %r13d
    cmp $10, %r12
    jne 1f
    test %r13d, %r13d
    jz .Lpt_syn
    xor %r14d, %r14d
    xor %r15d, %r15d
    jmp 5f
1:  cmp $19, %r12
    jb .Lpt_syn
    cmp $26, %r12
    ja .Lpt_syn
    cmp $20, %r12
    je .Lpt_syn
    movzbl 10(%rbx), %eax
    cmp $' ', %eax
    je 2f
    cmp $'T', %eax
    jne .Lpt_syn
2:  cmpb $':', 13(%rbx)
    jne .Lpt_syn
    cmpb $':', 16(%rbx)
    jne .Lpt_syn
    lea 11(%rbx), %rdi
    mov $2, %esi
    call rd_digits
    cmp $23, %rax
    ja .Lpt_syn                     /* also -1 */
    imul $60, %rax, %r14
    lea 14(%rbx), %rdi
    mov $2, %esi
    call rd_digits
    cmp $59, %rax
    ja .Lpt_syn
    add %rax, %r14
    imul $60, %r14, %r14
    lea 17(%rbx), %rdi
    mov $2, %esi
    call rd_digits
    cmp $59, %rax
    ja .Lpt_syn
    add %rax, %r14                  /* seconds of day */
    xor %r15d, %r15d                /* fractional micros */
    cmp $19, %r12
    je 5f
    cmpb $'.', 19(%rbx)
    jne .Lpt_syn
    lea 20(%rbx), %rdi
    lea -20(%r12), %rsi             /* 1..6 digits */
    call rd_digits
    test %rax, %rax
    js .Lpt_syn
    mov $26, %ecx
    sub %r12, %rcx                  /* 6 - ndigits */
    lea pow10_u64(%rip), %rdx
    imul (%rdx, %rcx, 8), %rax
    mov %rax, %r15
5:  mov %rbx, %rdi
    call parse_ymd
    test %edx, %edx
    jnz .Lpt_syn
    movabs $86400000000, %rcx
    imul %rcx, %rax
    imul $1000000, %r14, %r14
    add %r14, %rax
    add %r15, %rax
    xor %edx, %edx
    LEAVE
.Lpt_syn:
    xor %eax, %eax
    mov $1, %edx
    LEAVE
ENDF text_parse_timestamp

/* ======================================================== type names */

/* type_lookup_name(ptr rdi, len rsi) -> eax kind T_* or -1,
 * edx = 1 if the name is DECIMAL/NUMERIC (takes optional parameters) */
FUNC type_lookup_name
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    lea type_names(%rip), %r13
1:  movzbl (%r13), %eax
    cmp $0xff, %eax
    je 3f
    movzbl 1(%r13), %ecx
    mov %rbx, %rdi
    mov %r12, %rsi
    lea 2(%r13), %rdx
    call mem_ieq
    test %eax, %eax
    jnz 2f
    movzbl 1(%r13), %eax
    lea 2(%r13, %rax), %r13
    jmp 1b
2:  movzbl (%r13), %eax
    xor %edx, %edx
    cmp $T_DEC, %eax
    sete %dl
    LEAVE
3:  mov $-1, %eax
    xor %edx, %edx
    LEAVE
ENDF type_lookup_name

/* tp_skipws: internal helper for type_parse; rbx ptr, r12 len, r13 idx (updated).
 * Skips space, tab, CR, LF. Clobbers eax. */
tp_skipws:
1:  cmp %r12, %r13
    jae 2f
    movzbl (%rbx, %r13), %eax
    cmp $32, %eax
    je 3f
    cmp $9, %eax
    jb 2f
    cmp $13, %eax
    ja 2f
    cmp $11, %eax
    je 2f
    cmp $12, %eax
    je 2f
3:  inc %r13
    jmp 1b
2:  ret

/* tp_num: internal; reads digits at r13 (rbx/r12 as above) -> rax value
 * (saturated at 100000), rax = -1 if no digit. Clobbers ecx, edx. */
tp_num:
    xor %eax, %eax
    xor %edx, %edx                  /* digit count */
1:  cmp %r12, %r13
    jae 2f
    movzbl (%rbx, %r13), %ecx
    sub $'0', %ecx
    cmp $9, %ecx
    ja 2f
    cmp $100000, %rax
    jae 3f
    lea (%rax, %rax, 4), %rax
    lea (%rcx, %rax, 2), %rax
3:  inc %r13
    inc %edx
    jmp 1b
2:  test %edx, %edx
    jnz 4f
    mov $-1, %rax
4:  ret

/* type_parse(ptr rdi, len rsi) -> rax packed type, edx status
 * (1 = unknown name / bad syntax, 2 = invalid DECIMAL parameters) */
FUNC type_parse
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    xor %r13d, %r13d
    call tp_skipws
    mov %r13, %r14                  /* name start */
1:  cmp %r12, %r13
    jae 2f
    movzbl (%rbx, %r13), %eax
    cmp $'_', %eax
    je 11f
    lea -'0'(%rax), %ecx
    cmp $9, %ecx
    jbe 11f
    or $0x20, %eax
    sub $'a', %eax
    cmp $25, %eax
    ja 2f
11: inc %r13
    jmp 1b
2:  cmp %r14, %r13
    je .Ltp_syn
    lea (%rbx, %r14), %rdi
    mov %r13, %rsi
    sub %r14, %rsi
    call type_lookup_name
    cmp $-1, %eax
    je .Ltp_syn
    mov %eax, %r15d                 /* kind */
    test %edx, %edx
    jnz 3f
    call tp_skipws
    cmp %r12, %r13
    jne .Ltp_syn
    mov %r15d, %eax
    xor %edx, %edx
    LEAVE
3:  /* DECIMAL / NUMERIC */
    mov $18, %r14d                  /* p */
    xor %r15d, %r15d                /* s */
    call tp_skipws
    cmp %r12, %r13
    je 6f
    cmpb $'(', (%rbx, %r13)
    jne .Ltp_syn
    inc %r13
    call tp_skipws
    call tp_num
    test %rax, %rax
    js .Ltp_syn
    mov %rax, %r14
    call tp_skipws
    cmp %r12, %r13
    jae .Ltp_syn
    cmpb $',', (%rbx, %r13)
    jne 4f
    inc %r13
    call tp_skipws
    call tp_num
    test %rax, %rax
    js .Ltp_syn
    mov %rax, %r15
    call tp_skipws
    cmp %r12, %r13
    jae .Ltp_syn
4:  cmpb $')', (%rbx, %r13)
    jne .Ltp_syn
    inc %r13
    call tp_skipws
    cmp %r12, %r13
    jne .Ltp_syn
    /* validate 1 <= p <= 18, s <= p */
    test %r14, %r14
    jz .Ltp_bad
    cmp $18, %r14
    ja .Ltp_bad
    cmp %r14, %r15
    ja .Ltp_bad
6:  mov %r15, %rax
    shl $16, %rax
    shl $8, %r14
    or %r14, %rax
    or $T_DEC, %rax
    xor %edx, %edx
    LEAVE
.Ltp_syn:
    xor %eax, %eax
    mov $1, %edx
    LEAVE
.Ltp_bad:
    xor %eax, %eax
    mov $2, %edx
    LEAVE
ENDF type_parse

/* fmt_type(buf rdi, type rsi): canonical type name; T_NULL prints STRING */
FUNC fmt_type
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    movzbl %r12b, %eax
    cmp $T_BOOL, %eax
    jne 1f
    PUTS %rbx, "BOOLEAN"
    jmp 9f
1:  cmp $T_INT, %eax
    jne 2f
    PUTS %rbx, "INT64"
    jmp 9f
2:  cmp $T_FLOAT, %eax
    jne 3f
    PUTS %rbx, "FLOAT64"
    jmp 9f
3:  cmp $T_DEC, %eax
    jne 4f
    PUTS %rbx, "DECIMAL("
    mov %rbx, %rdi
    mov %r12, %rsi
    shr $8, %rsi
    movzbl %sil, %esi
    call buf_put_u64
    mov %rbx, %rdi
    mov $',', %esi
    call buf_putc
    mov %rbx, %rdi
    mov %r12, %rsi
    shr $16, %rsi
    movzbl %sil, %esi
    call buf_put_u64
    mov %rbx, %rdi
    mov $')', %esi
    call buf_putc
    jmp 9f
4:  cmp $T_DATE, %eax
    jne 5f
    PUTS %rbx, "DATE"
    jmp 9f
5:  cmp $T_TS, %eax
    jne 6f
    PUTS %rbx, "TIMESTAMP"
    jmp 9f
6:  PUTS %rbx, "STRING"
9:  LEAVE
ENDF fmt_type

/* ======================================================== formatting helpers */

/* wr_upad(dst rdi, value rsi, minwidth edx) -> rax chars written (leaf, internal;
 * unsigned decimal, zero padded to minwidth <= 40; uses the red zone) */
wr_upad:
    lea -8(%rsp), %r8               /* scratch end */
    mov %r8, %r9
    mov %rsi, %rax
    mov %edx, %r10d
    mov $10, %ecx
1:  xor %edx, %edx
    div %rcx
    add $'0', %edx
    dec %r9
    mov %dl, (%r9)
    dec %r10d
    test %rax, %rax
    jnz 1b
2:  test %r10d, %r10d
    jle 3f
    dec %r9
    movb $'0', (%r9)
    dec %r10d
    jmp 2b
3:  mov %r8, %rax
    sub %r9, %rax
    xor %ecx, %ecx
4:  cmp %rax, %rcx
    jae 5f
    movzbl (%r9, %rcx), %edx
    mov %dl, (%rdi, %rcx)
    inc %rcx
    jmp 4b
5:  ret

/* date_chars(dst rdi, days rsi) -> rax chars written ("YYYY-MM-DD"; internal) */
date_chars:
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15                       /* 5 pushes: stack now 16-byte aligned */
    mov %rdi, %rbx
    mov %rdi, %r15
    mov %rsi, %rdi
    call civil_from_days
    mov %rdx, %r12
    mov %rcx, %r13
    test %rax, %rax
    jns 1f
    movb $'-', (%r15)
    inc %r15
    neg %rax
1:  mov %r15, %rdi
    mov %rax, %rsi
    mov $4, %edx
    call wr_upad
    add %rax, %r15
    movb $'-', (%r15)
    inc %r15
    mov %r15, %rdi
    mov %r12, %rsi
    mov $2, %edx
    call wr_upad
    add %rax, %r15
    movb $'-', (%r15)
    inc %r15
    mov %r15, %rdi
    mov %r13, %rsi
    mov $2, %edx
    call wr_upad
    add %rax, %r15
    mov %r15, %rax
    sub %rbx, %rax
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    ret

/* fmt_date(buf rdi, days rsi) -> appends YYYY-MM-DD */
FUNC fmt_date
    ENTER 32
    mov %rdi, %rbx
    mov %rsp, %rdi
    call date_chars
    mov %rbx, %rdi
    mov %rsp, %rsi
    mov %rax, %rdx
    call buf_put
    LEAVE
ENDF fmt_date

/* fmt_timestamp(buf rdi, micros rsi) -> "YYYY-MM-DD HH:MM:SS[.ffffff]" */
FUNC fmt_timestamp
    ENTER 64
    mov %rdi, %rbx
    mov %rsi, %rax
    movabs $86400000000, %rcx
    cqo
    idiv %rcx
    test %rdx, %rdx
    jns 1f
    add %rcx, %rdx                  /* floor division */
    dec %rax
1:  mov %rdx, %r13                  /* micros of day */
    mov %rsp, %rdi
    mov %rax, %rsi
    call date_chars
    lea (%rsp, %rax), %r14          /* cursor */
    movb $' ', (%r14)
    inc %r14
    mov %r13, %rax
    xor %edx, %edx
    mov $1000000, %ecx
    div %rcx
    mov %rdx, %r15                  /* fractional micros */
    xor %edx, %edx
    mov $60, %ecx
    div %rcx
    mov %rdx, %r12                  /* seconds */
    xor %edx, %edx
    div %rcx
    mov %rdx, 48(%rsp)              /* minutes */
    mov %r14, %rdi
    mov %rax, %rsi                  /* hours */
    mov $2, %edx
    call wr_upad
    add %rax, %r14
    movb $':', (%r14)
    inc %r14
    mov %r14, %rdi
    mov 48(%rsp), %rsi
    mov $2, %edx
    call wr_upad
    add %rax, %r14
    movb $':', (%r14)
    inc %r14
    mov %r14, %rdi
    mov %r12, %rsi
    mov $2, %edx
    call wr_upad
    add %rax, %r14
    test %r15, %r15
    jz 2f
    movb $'.', (%r14)
    inc %r14
    mov %r14, %rdi
    mov %r15, %rsi
    mov $6, %edx
    call wr_upad
    add %rax, %r14
2:  mov %rbx, %rdi
    mov %rsp, %rsi
    mov %r14, %rdx
    sub %rsp, %rdx
    call buf_put
    LEAVE
ENDF fmt_timestamp

/* fmt_decimal(buf rdi, unscaled rsi, scale edx) -> exactly `scale` fraction digits */
FUNC fmt_decimal
    ENTER 32
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %edx, %r13d
    cmp $18, %r13d
    jbe 1f
    mov $18, %r13d
1:  test %r12, %r12
    jns 2f
    mov $'-', %esi
    call buf_putc
    neg %r12                        /* magnitude as unsigned (INT64_MIN ok) */
2:  test %r13d, %r13d
    jnz 3f
    mov %rbx, %rdi
    mov %r12, %rsi
    call buf_put_u64
    LEAVE
3:  lea pow10_u64(%rip), %rax
    mov (%rax, %r13, 8), %rcx
    mov %r12, %rax
    xor %edx, %edx
    div %rcx
    mov %rdx, %r14                  /* fraction */
    mov %rbx, %rdi
    mov %rax, %rsi
    call buf_put_u64
    mov %rbx, %rdi
    mov $'.', %esi
    call buf_putc
    mov %rsp, %rdi
    mov %r14, %rsi
    mov %r13d, %edx
    call wr_upad
    mov %rbx, %rdi
    mov %rsp, %rsi
    mov %rax, %rdx
    call buf_put
    LEAVE
ENDF fmt_decimal

/* fmt_float(buf rdi, x xmm0): shortest of %.15g/%.16g/%.17g that round-trips;
 * -0.0 and 0.0 print "0" */
FUNC fmt_float
    ENTER 64
    mov %rdi, %rbx
    movsd %xmm0, 48(%rsp)
    pxor %xmm1, %xmm1
    ucomisd %xmm1, %xmm0
    jp 1f
    jne 1f
    PUTS %rbx, "0"
    LEAVE
1:  xor %r12d, %r12d
    lea float_fmts(%rip), %r13
2:  mov %rsp, %rdi
    mov $40, %esi
    imul $6, %r12, %rdx
    add %r13, %rdx
    movsd 48(%rsp), %xmm0
    mov $1, %eax
    call snprintf
    cmp $2, %r12
    je 3f
    mov %rsp, %rdi
    xor %esi, %esi
    call strtod
    movq %xmm0, %rax
    cmp 48(%rsp), %rax
    je 3f
    inc %r12
    jmp 2b
3:  mov %rbx, %rdi
    mov %rsp, %rsi
    call buf_puts
    LEAVE
ENDF fmt_float

/* fmt_value_text(buf rdi, type rsi, payload rdx): CAST-to-STRING text form */
FUNC fmt_value_text
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    movzbl %r12b, %eax
    cmp $T_BOOL, %eax
    jne 2f
    test %r13, %r13
    jz 1f
    PUTS %rbx, "true"
    LEAVE
1:  PUTS %rbx, "false"
    LEAVE
2:  cmp $T_INT, %eax
    jne 3f
    mov %r13, %rsi
    call buf_put_i64
    LEAVE
3:  cmp $T_FLOAT, %eax
    jne 4f
    movq %r13, %xmm0
    call fmt_float
    LEAVE
4:  cmp $T_DEC, %eax
    jne 5f
    mov %r13, %rsi
    mov %r12, %rdx
    shr $16, %rdx
    movzbl %dl, %edx
    call fmt_decimal
    LEAVE
5:  cmp $T_STR, %eax
    jne 6f
    test %r13, %r13
    jz 9f
    mov %r13, %rsi
    call buf_put_pstr
    LEAVE
6:  cmp $T_DATE, %eax
    jne 7f
    mov %r13, %rsi
    call fmt_date
    LEAVE
7:  cmp $T_TS, %eax
    jne 9f
    mov %r13, %rsi
    call fmt_timestamp
9:  LEAVE
ENDF fmt_value_text

/* fmt_value_json(buf rdi, type rsi, payload rdx): JSON value (types.md section 9) */
FUNC fmt_value_json
    movzbl %sil, %eax
    cmp $T_FLOAT, %eax
    jbe 1f                          /* BOOL, INT, FLOAT (and NULL below) */
    cmp $T_STR, %eax
    je 2f
    cmp $T_TS, %eax
    jbe 3f
    jmp 4f
1:  test %eax, %eax
    jz 4f
    jmp fmt_value_text
2:  test %rdx, %rdx
    jz 4f
    mov %rdx, %rsi
    jmp buf_put_json_pstr
3:  ENTER 0                         /* DEC, DATE, TIMESTAMP: quoted text */
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov $'"', %esi
    call buf_putc
    mov %rbx, %rdi
    mov %r12, %rsi
    mov %r13, %rdx
    call fmt_value_text
    mov %rbx, %rdi
    mov $'"', %esi
    call buf_putc
    LEAVE
4:  lea null_str(%rip), %rsi
    jmp buf_puts
ENDF fmt_value_json

    .section .rodata
null_str: .asciz "null"
    .text

/* ======================================================== decimal / float helpers */

/* dec_rescale(unscaled rdi, from_scale esi, to_scale edx) -> rax, edx status
 * increase: exact, |result| > 999999999999999999 -> 2; decrease: round half away */
FUNC dec_rescale
    mov %edx, %ecx
    sub %esi, %ecx                  /* k = to - from */
    jl 3f
    cmp $18, %ecx
    jg 2f
    lea pow10_u64(%rip), %r8
    mov %rdi, %rax
    imul (%r8, %rcx, 8), %rax
    jo 9f
    mov %rax, %rdx
    sar $63, %rdx
    mov %rax, %rcx
    xor %rdx, %rcx
    sub %rdx, %rcx                  /* |result| */
    movabs $999999999999999999, %r8
    cmp %r8, %rcx
    ja 9f
    xor %edx, %edx
    ret
2:  test %rdi, %rdi
    jnz 9f
    xor %eax, %eax
    xor %edx, %edx
    ret
3:  neg %ecx                        /* k = from - to > 0 */
    cmp $18, %ecx
    jg 4f
    mov %rdi, %r10
    sar $63, %r10                   /* sign mask */
    mov %rdi, %rax
    xor %r10, %rax
    sub %r10, %rax                  /* |v| as unsigned */
    lea pow10_u64(%rip), %r8
    mov (%r8, %rcx, 8), %r9
    xor %edx, %edx
    div %r9
    add %rdx, %rdx
    cmp %r9, %rdx
    jb 5f
    inc %rax
5:  xor %r10, %rax
    sub %r10, %rax
    xor %edx, %edx
    ret
4:  xor %eax, %eax
    xor %edx, %edx
    ret
9:  xor %eax, %eax
    mov $2, %edx
    ret
ENDF dec_rescale

/* dec_fits(unscaled rdi, prec esi) -> eax 1 if |unscaled| < 10^prec */
FUNC dec_fits
    mov %rdi, %rdx
    sar $63, %rdx
    mov %rdi, %rcx
    xor %rdx, %rcx
    sub %rdx, %rcx                  /* |v| unsigned */
    mov $1, %eax
    cmp $18, %esi
    jg 1f
    xor %eax, %eax
    test %esi, %esi
    jle 2f
    movslq %esi, %rsi
    lea pow10_u64(%rip), %rdx
    cmp (%rdx, %rsi, 8), %rcx
    setb %al
1:  ret
2:  test %rcx, %rcx
    sete %al
    ret
ENDF dec_fits

/* dec_to_float(unscaled rdi, scale esi) -> xmm0 = (double)unscaled / 10^scale */
FUNC dec_to_float
    cvtsi2sdq %rdi, %xmm0
    test %esi, %esi
    jle 1f
    cmp $18, %esi
    jbe 2f
    mov $18, %esi
2:  movslq %esi, %rsi
    lea pow10_u64(%rip), %rax
    cvtsi2sdq (%rax, %rsi, 8), %xmm1
    divsd %xmm1, %xmm0
1:  ret
ENDF dec_to_float

/* float_to_dec(x xmm0, prec edi, scale esi) -> rax unscaled, edx status
 * round(x * 10^scale) half away from zero; doesn't fit prec / i64 -> 2 */
FUNC float_to_dec
    ENTER 16
    mov %edi, %r12d
    mov %esi, %r13d
    test %r13d, %r13d
    jns 1f
    xor %r13d, %r13d
1:  cmp $18, %r13d
    jbe 2f
    mov $18, %r13d
2:  lea pow10_u64(%rip), %rax
    cvtsi2sdq (%rax, %r13, 8), %xmm1
    mulsd %xmm1, %xmm0
    call round
    movq %xmm0, %rax
    btr $63, %rax
    movq %rax, %xmm1
    ucomisd d_two63(%rip), %xmm1
    jp 9f
    jae 9f
    cvttsd2si %xmm0, %rbx
    mov %rbx, %rdi
    mov %r12d, %esi
    call dec_fits
    test %eax, %eax
    jz 9f
    mov %rbx, %rax
    xor %edx, %edx
    LEAVE
9:  xor %eax, %eax
    mov $2, %edx
    LEAVE
ENDF float_to_dec

/* float_to_int64(x xmm0) -> rax (truncated toward zero), edx status (2 = out of range) */
FUNC float_to_int64
    ucomisd d_two63(%rip), %xmm0
    jp 9f
    jae 9f
    ucomisd d_mtwo63(%rip), %xmm0
    jb 9f
    cvttsd2si %xmm0, %rax
    xor %edx, %edx
    ret
9:  xor %eax, %eax
    mov $2, %edx
    ret
ENDF float_to_int64
