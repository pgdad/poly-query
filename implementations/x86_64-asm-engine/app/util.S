/*
 * util.S - pqledger helpers: fatal errors, growable byte buffers (ABUF),
 * whole-file reading, the buffered standard output (g_out) and small
 * string / path helpers.
 *
 * Every function follows the System V AMD64 ABI.
 */
#include "app.inc"

    .section .note.GNU-stack, "", @progbits

/* ======================================================================
 * data
 * ====================================================================== */
    .bss
    .p2align 3
    .globl g_out
g_out:  .zero AB_SIZE                 /* ABUF: the command's standard output */

    .section .rodata
s_prefix:   .asciz "pqledger: error: "
s_nl:       .asciz "\n"
s_engfmt:   .asciz "pqledger: error: %s: %s\n"
s_i64fmt:   .asciz "%ld"

    .text

/* ======================================================================
 * die(code edi, fmt rsi, a1 rdx, a2 rcx, a3 r8, a4 r9)  noreturn
 * Writes "pqledger: error: " + printf(fmt, a1..a4) + "\n" to stderr and
 * exits with `code`.  Nothing is written to stdout (g_out is discarded).
 * ====================================================================== */
FUNC die
    ENTER 48
    mov %edi, %ebx                    /* exit code */
    mov %rsi, %r12                    /* format */
    mov %rdx, 0(%rsp)                 /* keep the printf arguments */
    mov %rcx, 8(%rsp)
    mov %r8, 16(%rsp)
    mov %r9, 24(%rsp)
    mov $2, %edi
    lea s_prefix(%rip), %rsi
    xor %eax, %eax
    call dprintf
    mov $2, %edi
    mov %r12, %rsi
    mov 0(%rsp), %rdx
    mov 8(%rsp), %rcx
    mov 16(%rsp), %r8
    mov 24(%rsp), %r9
    xor %eax, %eax
    call dprintf
    mov $2, %edi
    lea s_nl(%rip), %rsi
    xor %eax, %eax
    call dprintf
    mov %ebx, %edi
    call exit
ENDF die

/* ======================================================================
 * die_engine(code edi, db rsi)  noreturn
 * "pqledger: error: CODE: MESSAGE" from the instance's last error.
 * ====================================================================== */
FUNC die_engine
    ENTER 16
    mov %edi, %ebx
    mov %rsi, %r12
    mov %r12, %rdi
    call pq_errcode
    mov %eax, %edi
    call pq_error_name
    mov %rax, %r13                    /* code name */
    mov %r12, %rdi
    call pq_errmsg
    mov %rax, %rcx                    /* message */
    test %rcx, %rcx
    jnz 1f
    lea s_nl+1(%rip), %rcx            /* "" */
1:  mov %r13, %rdx
    mov $2, %edi
    lea s_engfmt(%rip), %rsi
    xor %eax, %eax
    call dprintf
    mov %ebx, %edi
    call exit
ENDF die_engine

/* ======================================================================
 * xmalloc(n rdi) -> rax ; xrealloc(p rdi, n rsi) -> rax
 * Exit 7 when memory is exhausted.
 * ====================================================================== */
FUNC xmalloc
    ENTER
    test %rdi, %rdi
    jnz 1f
    mov $1, %edi
1:  call malloc
    test %rax, %rax
    jz oom
    LEAVE
ENDF xmalloc

FUNC xrealloc
    ENTER
    test %rsi, %rsi
    jnz 1f
    mov $1, %esi
1:  call realloc
    test %rax, %rax
    jz oom
    LEAVE
ENDF xrealloc

oom:
    DIE EX_OTHER, "out of memory"

/* xstrdup(s rdi) -> rax  malloc'd copy */
FUNC xstrdup
    ENTER
    mov %rdi, %rbx
    call strlen
    mov %rax, %rsi
    mov %rbx, %rdi
    call xstrndup
    LEAVE
ENDF xstrdup

/* xstrndup(p rdi, n rsi) -> rax  malloc'd NUL-terminated copy of n bytes */
FUNC xstrndup
    ENTER
    mov %rdi, %rbx
    mov %rsi, %r12
    lea 1(%rsi), %rdi
    call xmalloc
    mov %rax, %r13
    mov %rax, %rdi
    mov %rbx, %rsi
    mov %r12, %rdx
    call memcpy
    movb $0, (%r13,%r12)
    mov %r13, %rax
    LEAVE
ENDF xstrndup

/* ======================================================================
 * ABUF functions.  A zeroed ABUF is a valid empty buffer as well.
 * ====================================================================== */

/* ab_init(ab rdi): empty buffer with a small allocation */
FUNC ab_init
    ENTER
    mov %rdi, %rbx
    mov $64, %edi
    call xmalloc
    mov %rax, AB_DATA(%rbx)
    movb $0, (%rax)
    movq $0, AB_LEN(%rbx)
    movq $64, AB_CAP(%rbx)
    LEAVE
ENDF ab_init

/* ab_free(ab rdi): releases the storage, leaves a zeroed ABUF */
FUNC ab_free
    ENTER
    mov %rdi, %rbx
    mov AB_DATA(%rbx), %rdi
    call free
    movq $0, AB_DATA(%rbx)
    movq $0, AB_LEN(%rbx)
    movq $0, AB_CAP(%rbx)
    LEAVE
ENDF ab_free

/* ab_clear(ab rdi): length 0 (keeps the storage) */
FUNC ab_clear
    movq $0, AB_LEN(%rdi)
    mov AB_DATA(%rdi), %rax
    test %rax, %rax
    jz 1f
    movb $0, (%rax)
1:  ret
ENDF ab_clear

/* ab_reserve(ab rdi, n rsi): room for n more bytes plus the NUL */
FUNC ab_reserve
    ENTER
    mov %rdi, %rbx
    mov AB_LEN(%rbx), %rax
    lea 1(%rax,%rsi), %r12            /* needed capacity */
    cmp AB_CAP(%rbx), %r12
    jbe 9f
    mov AB_CAP(%rbx), %r13
    test %r13, %r13
    jnz 1f
    mov $64, %r13d
1:  cmp %r12, %r13
    jae 2f
    add %r13, %r13
    jmp 1b
2:  mov AB_DATA(%rbx), %rdi
    mov %r13, %rsi
    call xrealloc
    mov %rax, AB_DATA(%rbx)
    mov %r13, AB_CAP(%rbx)
    mov AB_LEN(%rbx), %rcx
    movb $0, (%rax,%rcx)
9:  LEAVE
ENDF ab_reserve

/* ab_put(ab rdi, ptr rsi, len rdx): append len bytes */
FUNC ab_put
    ENTER
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rdx, %rsi
    call ab_reserve
    mov AB_DATA(%rbx), %rdi
    add AB_LEN(%rbx), %rdi
    mov %r12, %rsi
    mov %r13, %rdx
    call memcpy
    add %r13, AB_LEN(%rbx)
    mov AB_DATA(%rbx), %rax
    mov AB_LEN(%rbx), %rcx
    movb $0, (%rax,%rcx)
    LEAVE
ENDF ab_put

/* ab_puts(ab rdi, s rsi): append a C string */
FUNC ab_puts
    ENTER
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rsi, %rdi
    call strlen
    mov %rax, %rdx
    mov %rbx, %rdi
    mov %r12, %rsi
    call ab_put
    LEAVE
ENDF ab_puts

/* ab_putc(ab rdi, c sil): append one byte */
FUNC ab_putc
    ENTER
    mov %rdi, %rbx
    movzbl %sil, %r12d
    mov $1, %esi
    call ab_reserve
    mov AB_DATA(%rbx), %rax
    mov AB_LEN(%rbx), %rcx
    mov %r12b, (%rax,%rcx)
    movb $0, 1(%rax,%rcx)
    incq AB_LEN(%rbx)
    LEAVE
ENDF ab_putc

/* ab_put_i64(ab rdi, v rsi): append v in decimal */
FUNC ab_put_i64
    ENTER 32
    mov %rdi, %rbx
    mov %rsi, %rcx
    mov %rsp, %rdi
    mov $32, %esi
    lea s_i64fmt(%rip), %rdx
    xor %eax, %eax
    call snprintf
    mov %rbx, %rdi
    mov %rsp, %rsi
    mov %rax, %rdx
    call ab_put
    LEAVE
ENDF ab_put_i64

/* ab_put_sqlstr(ab rdi, s rsi): append s as an SQL string literal
 * ('...' with ' doubled) */
FUNC ab_put_sqlstr
    ENTER
    mov %rdi, %rbx
    mov %rsi, %r12
    mov $'\'', %esi
    call ab_putc
1:  movzbl (%r12), %r13d
    test %r13d, %r13d
    jz 3f
    cmp $'\'', %r13d
    jne 2f
    mov %rbx, %rdi
    mov $'\'', %esi
    call ab_putc
2:  mov %rbx, %rdi
    mov %r13d, %esi
    call ab_putc
    inc %r12
    jmp 1b
3:  mov %rbx, %rdi
    mov $'\'', %esi
    call ab_putc
    LEAVE
ENDF ab_put_sqlstr

/* ab_put_csvstr(ab rdi, s rsi): append s as a quoted CSV field
 * ("..." with " doubled; always quoted so that "" is an empty string) */
FUNC ab_put_csvstr
    ENTER
    mov %rdi, %rbx
    mov %rsi, %r12
    mov $'"', %esi
    call ab_putc
1:  movzbl (%r12), %r13d
    test %r13d, %r13d
    jz 3f
    cmp $'"', %r13d
    jne 2f
    mov %rbx, %rdi
    mov $'"', %esi
    call ab_putc
2:  mov %rbx, %rdi
    mov %r13d, %esi
    call ab_putc
    inc %r12
    jmp 1b
3:  mov %rbx, %rdi
    mov $'"', %esi
    call ab_putc
    LEAVE
ENDF ab_put_csvstr

/* ======================================================================
 * read_file(path rdi, ab rsi) -> eax 0 ok, -1 error (errno set)
 * Appends the whole file to the ABUF (initialized or zeroed).
 * ====================================================================== */
FUNC read_file
    ENTER 16
    mov %rsi, %rbx
    xor %esi, %esi                    /* O_RDONLY */
    xor %eax, %eax
    call open
    test %eax, %eax
    js 8f
    mov %eax, %r12d                   /* fd */
1:  mov %rbx, %rdi
    mov $65536, %esi
    call ab_reserve
    mov %r12d, %edi
    mov AB_DATA(%rbx), %rsi
    add AB_LEN(%rbx), %rsi
    mov $65536, %edx
    call read
    test %rax, %rax
    js 7f
    jz 2f
    add %rax, AB_LEN(%rbx)
    jmp 1b
2:  mov AB_DATA(%rbx), %rax
    mov AB_LEN(%rbx), %rcx
    movb $0, (%rax,%rcx)
    mov %r12d, %edi
    call close
    xor %eax, %eax
    LEAVE
7:  call __errno_location           /* read failed: keep errno over close */
    mov (%rax), %r13d
    mov %r12d, %edi
    call close
    call __errno_location
    mov %r13d, (%rax)
8:  mov $-1, %eax
    LEAVE
ENDF read_file

/* ======================================================================
 * out_flush(): writes g_out to standard output (fd 1); exit 7 on error
 * ====================================================================== */
FUNC out_flush
    ENTER
    mov AB_DATA+g_out(%rip), %rbx
    mov AB_LEN+g_out(%rip), %r12
1:  test %r12, %r12
    jz 9f
    mov $1, %edi
    mov %rbx, %rsi
    mov %r12, %rdx
    call write
    test %rax, %rax
    jg 2f
    call __errno_location
    cmpl $4, (%rax)                   /* EINTR */
    je 1b
    DIE EX_OTHER, "cannot write standard output"
2:  add %rax, %rbx
    sub %rax, %r12
    jmp 1b
9:  LEAVE
ENDF out_flush

/* ======================================================================
 * string helpers
 * ====================================================================== */

/* trim_span(p rdi, n rsi) -> rax p', rdx n'
 * Removes leading and trailing spaces and tabs from the span. */
FUNC trim_span
    mov %rdi, %rax
    mov %rsi, %rdx
1:  test %rdx, %rdx
    jz 9f
    movzbl (%rax), %ecx
    cmp $' ', %ecx
    je 2f
    cmp $'\t', %ecx
    jne 3f
2:  inc %rax
    dec %rdx
    jmp 1b
3:  movzbl -1(%rax,%rdx), %ecx
    cmp $' ', %ecx
    je 4f
    cmp $'\t', %ecx
    jne 9f
4:  dec %rdx
    jnz 3b
9:  ret
ENDF trim_span

/* is_name(s rdi) -> eax 1 if s matches [a-z0-9_-]{1,32}, else 0
 * (account and category names) */
FUNC is_name
    xor %ecx, %ecx
1:  movzbl (%rdi,%rcx), %eax
    test %eax, %eax
    jz 8f
    cmp $32, %ecx
    jae 7f
    cmp $'-', %eax
    je 2f
    cmp $'_', %eax
    je 2f
    lea -'0'(%rax), %edx
    cmp $9, %edx
    jbe 2f
    lea -'a'(%rax), %edx
    cmp $25, %edx
    ja 7f
2:  inc %ecx
    jmp 1b
8:  test %ecx, %ecx
    jz 7f
    mov $1, %eax
    ret
7:  xor %eax, %eax
    ret
ENDF is_name

/* is_category(s rdi) -> eax 1 if s is a valid category name
 * ([a-z0-9_-]{1,32}, not "uncategorized") */
FUNC is_category
    ENTER
    mov %rdi, %rbx
    call is_name
    test %eax, %eax
    jz 9f
    mov %rbx, %rdi
    CSTR %rsi, "uncategorized"
    call strcmp
    test %eax, %eax
    setnz %al
    movzbl %al, %eax
9:  LEAVE
ENDF is_category

/* parse_u64(s rdi, max_digits esi) -> rax value, or -1 if s is not
 * [0-9]{1,max_digits} (max_digits <= 18) */
FUNC parse_u64
    xor %eax, %eax
    xor %ecx, %ecx
1:  movzbl (%rdi,%rcx), %edx
    test %edx, %edx
    jz 8f
    sub $'0', %edx
    cmp $9, %edx
    ja 7f
    cmp %esi, %ecx
    jae 7f
    imul $10, %rax, %rax
    add %rdx, %rax
    inc %ecx
    jmp 1b
8:  test %ecx, %ecx
    jz 7f
    ret
7:  mov $-1, %rax
    ret
ENDF parse_u64

/* path_dirname(path rdi) -> rax malloc'd directory part ("." if none,
 * "/" for files in the root) */
FUNC path_dirname
    ENTER
    mov %rdi, %rbx
    mov $'/', %esi
    call strrchr
    test %rax, %rax
    jnz 1f
    CSTR %rdi, "."
    call xstrdup
    LEAVE
1:  mov %rax, %rsi
    sub %rbx, %rsi                    /* length up to the last slash */
    jnz 2f
    mov $1, %esi                      /* "/x" -> "/" */
2:  mov %rbx, %rdi
    call xstrndup
    LEAVE
ENDF path_dirname

/* path_join(dir rdi, path rsi) -> rax malloc'd: path if it is absolute,
 * else dir "/" path */
FUNC path_join
    ENTER 32
    mov %rdi, %rbx
    mov %rsi, %r12
    cmpb $'/', (%r12)
    jne 1f
    mov %r12, %rdi
    call xstrdup
    LEAVE
1:  lea 0(%rsp), %rdi
    call ab_init
    lea 0(%rsp), %rdi
    mov %rbx, %rsi
    call ab_puts
    mov AB_LEN(%rsp), %rax
    test %rax, %rax
    jz 2f
    mov AB_DATA(%rsp), %rcx
    cmpb $'/', -1(%rcx,%rax)
    je 2f
    lea 0(%rsp), %rdi
    mov $'/', %esi
    call ab_putc
2:  lea 0(%rsp), %rdi
    mov %r12, %rsi
    call ab_puts
    mov AB_DATA(%rsp), %rax
    LEAVE
ENDF path_join
