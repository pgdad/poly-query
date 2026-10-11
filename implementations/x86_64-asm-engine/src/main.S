/*
 * main.S - command line interface (protocol.md §2): version, capabilities,
 * session (JSON lines on stdin/stdout) and exec (--request FILE|-).
 * Also installs a fault handler that turns crashes inside a request into
 * INTERNAL_ERROR responses.
 */
#include "pq.inc"

    .section .note.GNU-stack, "", @progbits

#define MODE_VERSION 1
#define MODE_CAPS    2
#define MODE_SESSION 3
#define MODE_EXEC    4
#define MODE_SERVE   5

    .data
    .p2align 3
opt_request: .quad 0

    .section .rodata
/* options taking a value; the value is stored by index in option handling */
valopts:
    .asciz "--data-dir"
    .asciz "--max-query-memory-mb"
    .asciz "--max-ingest-bytes"
    .asciz "--max-table-rows"
    .asciz "--max-join-rows"
    .asciz "--threads"
    .asciz "--log-level"
    .asciz "--native-kernels"
    .asciz "--request"
    .asciz "--host"
    .asciz "--port"
    .asciz "--workers"
    .asciz "--queue-depth"
    .asciz "--query-timeout-ms"
    .asciz "--shutdown-grace-ms"
    .asciz "--max-request-bytes"
    .byte 0

    .text

/* usage_error(msg rdi, arg rsi) - prints to stderr and exits 2 */
FUNC usage_error
    sub $8, %rsp
    mov %rsi, %rcx
    mov %rdi, %rdx
    mov stderr(%rip), %rdi
    lea usage_fmt(%rip), %rsi
    xor %eax, %eax
    call fprintf
    mov $2, %edi
    call exit
ENDF usage_error
    .section .rodata
usage_fmt: .asciz "polyquery: %s%s\nusage: polyquery (version|capabilities|session|exec|serve) [options]\n"
    .text

/* fault handler: report INTERNAL_ERROR for the current request */
FUNC fault_handler
    and $-16, %rsp
    cmpq $0, g_jmpbuf(%rip)
    je 1f
    mov $E_INTERNAL_ERROR, %edi
    CSTR %rsi, "internal error (fault)"
    call pq_raise
1:  mov $1, %edi
    call _exit
ENDF fault_handler

/* install_fault_handlers() */
FUNC install_fault_handlers
    ENTER 176
    /* alternate signal stack so stack overflows can be reported */
    mov $(256*1024), %edi
    call xmalloc
    mov %rax, 152(%rsp)             /* stack_t.ss_sp */
    movl $0, 160(%rsp)              /* ss_flags */
    movq $(256*1024), 168(%rsp)     /* ss_size */
    lea 152(%rsp), %rdi
    xor %esi, %esi
    call sigaltstack
    /* struct sigaction at 0(%rsp): handler, mask[128], flags, restorer */
    lea 0(%rsp), %rdi
    xor %esi, %esi
    mov $152, %edx
    call memset
    lea fault_handler(%rip), %rax
    mov %rax, 0(%rsp)
    movl $0x48000000, 136(%rsp)     /* SA_ONSTACK | SA_NODEFER */
    lea 0(%rsp), %rsi
    mov $11, %edi                   /* SIGSEGV */
    xor %edx, %edx
    call sigaction
    lea 0(%rsp), %rsi
    mov $7, %edi                    /* SIGBUS */
    xor %edx, %edx
    call sigaction
    lea 0(%rsp), %rsi
    mov $8, %edi                    /* SIGFPE */
    xor %edx, %edx
    call sigaction
    /* ignore SIGPIPE: write errors are handled */
    mov $13, %edi
    mov $1, %esi                    /* SIG_IGN */
    call signal
    LEAVE
ENDF install_fault_handlers

/* parse_size(str rdi, name rsi) -> rax non-negative integer (exit 2 if invalid) */
FUNC parse_size
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    lea 0(%rsp), %rsi
    mov $10, %edx
    call strtoll
    mov 0(%rsp), %rcx
    cmp %rbx, %rcx
    je 1f
    cmpb $0, (%rcx)
    jne 1f
    test %rax, %rax
    js 1f
    LEAVE
1:  CSTR %rdi, "invalid value for "
    mov %r12, %rsi
    call usage_error
ENDF parse_size

/* main(argc, argv) */
FUNC main
    ENTER 32
    mov %edi, %r12d                 /* argc */
    mov %rsi, %r13                  /* argv */
    call arena_new
    mov %rax, g_arena(%rip)
    CSTR %rax, "."
    mov %rax, g_data_dir(%rip)
    cmp $2, %r12d
    jl m_usage
    /* mode */
    mov 8(%r13), %rbx
    mov %rbx, %rdi
    CSTR %rsi, "version"
    call strcmp
    mov $MODE_VERSION, %r14d
    test %eax, %eax
    jz 1f
    mov %rbx, %rdi
    CSTR %rsi, "capabilities"
    call strcmp
    mov $MODE_CAPS, %r14d
    test %eax, %eax
    jz 1f
    mov %rbx, %rdi
    CSTR %rsi, "session"
    call strcmp
    mov $MODE_SESSION, %r14d
    test %eax, %eax
    jz 1f
    mov %rbx, %rdi
    CSTR %rsi, "exec"
    call strcmp
    mov $MODE_EXEC, %r14d
    test %eax, %eax
    jz 1f
    mov %rbx, %rdi
    CSTR %rsi, "serve"
    call strcmp
    mov $MODE_SERVE, %r14d
    test %eax, %eax
    jz 1f
    CSTR %rdi, "unknown command "
    mov %rbx, %rsi
    call usage_error
1:  /* options */
    mov $2, %r15d
2:  cmp %r12d, %r15d
    jge 20f
    mov (%r13, %r15, 8), %rbx       /* option */
    mov %rbx, %rdi
    CSTR %rsi, "--enable-test-functions"
    call strcmp
    test %eax, %eax
    jnz 3f
    movq $1, g_test_functions(%rip)
    inc %r15d
    jmp 2b
3:  /* --name=value or --name value */
    mov %rbx, %rdi
    mov $'=', %esi
    call strchr
    test %rax, %rax
    jz 4f
    movb $0, (%rax)                 /* split in place */
    lea 1(%rax), %rcx
    mov %rcx, 0(%rsp)               /* value */
    jmp 5f
4:  lea 1(%r15), %eax
    cmp %r12d, %eax
    jge m_missing_value
    mov 8(%r13, %r15, 8), %rcx
    mov %rcx, 0(%rsp)
    inc %r15d
5:  inc %r15d
    /* which option? */
    lea valopts(%rip), %rax
    mov %rax, 8(%rsp)
    xor %ecx, %ecx
    mov %rcx, 16(%rsp)
6:  mov 8(%rsp), %rsi
    cmpb $0, (%rsi)
    je m_unknown_option
    mov %rbx, %rdi
    call strcmp
    test %eax, %eax
    jz 7f
    mov 8(%rsp), %rdi
    call strlen
    mov 8(%rsp), %rcx
    lea 1(%rcx, %rax), %rcx
    mov %rcx, 8(%rsp)
    incq 16(%rsp)
    jmp 6b
7:  mov 16(%rsp), %rax
    mov 0(%rsp), %rdi
    cmp $0, %rax
    jne 8f
    mov %rdi, g_data_dir(%rip)      /* --data-dir */
    jmp 2b
8:  cmp $1, %rax
    jne 9f
    mov %rbx, %rsi                  /* --max-query-memory-mb */
    call parse_size
    shl $20, %rax
    mov %rax, g_max_query_mem(%rip)
    jmp 2b
9:  cmp $2, %rax
    jne 10f
    mov %rbx, %rsi
    call parse_size
    mov %rax, g_max_ingest_bytes(%rip)
    jmp 2b
10: cmp $3, %rax
    jne 11f
    mov %rbx, %rsi
    call parse_size
    mov %rax, g_max_table_rows(%rip)
    jmp 2b
11: cmp $8, %rax
    jne 12f
    mov %rdi, opt_request(%rip)     /* --request */
    jmp 2b
12: cmp $4, %rax                    /* --max-join-rows, --threads: numeric */
    je 13f
    cmp $5, %rax
    je 13f
    cmp $10, %rax
    jb 2b                           /* log level, native kernels: accepted */
    cmp $9, %rax
    je 2b                           /* --host */
13: mov %rbx, %rsi
    call parse_size
    jmp 2b

20: /* dispatch */
    cmp $MODE_VERSION, %r14d
    jne 21f
    xor %edi, %edi
    call proto_write_static
    xor %eax, %eax
    LEAVE
21: cmp $MODE_CAPS, %r14d
    jne 22f
    mov $1, %edi
    call proto_write_static
    xor %eax, %eax
    LEAVE
22: cmp $MODE_SERVE, %r14d
    jne 23f
    mov stderr(%rip), %rdi
    CSTR %rsi, "polyquery: serve mode is not supported by this engine (phase 1)\n"
    call fputs
    mov $1, %eax
    LEAVE
23: call install_fault_handlers
    cmp $MODE_EXEC, %r14d
    je m_exec
    call session_loop
    xor %eax, %eax
    LEAVE

m_exec:
    mov opt_request(%rip), %rdi
    test %rdi, %rdi
    jz m_no_request
    call exec_requests
    xor %eax, %eax
    LEAVE

m_usage:
    CSTR %rdi, "missing command"
    CSTR %rsi, ""
    call usage_error
m_missing_value:
    CSTR %rdi, "missing value for "
    mov %rbx, %rsi
    call usage_error
m_unknown_option:
    CSTR %rdi, "unknown option "
    mov %rbx, %rsi
    call usage_error
m_no_request:
    CSTR %rdi, "exec requires --request FILE|-"
    CSTR %rsi, ""
    call usage_error
ENDF main

/* read_fd_all(fd edi, Buf* rsi): appends the whole stream */
FUNC read_fd_all
    ENTER 0
    mov %edi, %ebx
    mov %rsi, %r12
1:  mov %r12, %rdi
    mov $65536, %esi
    call buf_reserve
    mov %ebx, %edi
    mov BUF_DATA(%r12), %rsi
    add BUF_LEN(%r12), %rsi
    mov $65536, %edx
    call read
    test %rax, %rax
    jz 9f
    jg 2f
    call __errno_location
    cmpl $4, (%rax)
    je 1b
    jmp 9f
2:  add %rax, BUF_LEN(%r12)
    jmp 1b
9:  LEAVE
ENDF read_fd_all

/* exec_requests(path): runs a JSON request or an array of requests */
FUNC exec_requests
    ENTER 32
    mov %rdi, %rbx
    lea 0(%rsp), %rdi
    call buf_init
    xor %r12d, %r12d                /* fd 0 for "-" */
    mov %rbx, %rdi
    CSTR %rsi, "-"
    call strcmp
    test %eax, %eax
    jz 1f
    mov %rbx, %rdi
    xor %esi, %esi
    xor %eax, %eax
    call open
    test %eax, %eax
    js 8f
    mov %eax, %r12d
1:  mov %r12d, %edi
    lea 0(%rsp), %rsi
    call read_fd_all
    /* parse into a dedicated arena (the request arena is reset per request) */
    call arena_new
    mov %rax, %r13
    mov 0(%rsp), %rdi
    mov 8(%rsp), %rsi
    mov %r13, %rdx
    call json_parse
    test %rax, %rax
    jz 5f
    cmpq $J_ARRAY, JN_TYPE(%rax)
    jne 5f
    mov JN_PTR(%rax), %r14
    mov JN_LEN(%rax), %r15
2:  test %r15, %r15
    jz 9f
    mov (%r14), %rdi
    call proto_handle_request
    add $8, %r14
    dec %r15
    jmp 2b
5:  mov %rax, %rdi                  /* single request (or invalid JSON) */
    call proto_handle_request
9:  LEAVE
8:  mov stderr(%rip), %rdi
    CSTR %rsi, "polyquery: cannot open request file\n"
    call fputs
    mov $1, %edi
    call exit
ENDF exec_requests

/* session_loop(): one JSON request per line until EOF */
FUNC session_loop
    ENTER 32
    lea 0(%rsp), %rdi
    call buf_init
    xor %r12d, %r12d                /* consumed offset */
1:  /* find a newline in data[r12 .. len) */
    mov 0(%rsp), %rdi
    add %r12, %rdi
    mov 8(%rsp), %rdx
    sub %r12, %rdx
    jz 3f
    mov $'\n', %esi
    call memchr
    test %rax, %rax
    jz 3f
    mov %rax, %r13                  /* newline position */
    mov 0(%rsp), %rdi
    add %r12, %rdi
    mov %r13, %rsi
    sub %rdi, %rsi
    call handle_text_line
    mov %r13, %r12
    sub 0(%rsp), %r12
    inc %r12
    jmp 1b
3:  /* compact and read more */
    mov 8(%rsp), %rdx
    sub %r12, %rdx
    mov %rdx, %r13
    test %r12, %r12
    jz 4f
    mov 0(%rsp), %rdi
    mov %rdi, %rsi
    add %r12, %rsi
    call memmove
    mov %r13, 8(%rsp)
    xor %r12d, %r12d
4:  lea 0(%rsp), %rdi
    mov $65536, %esi
    call buf_reserve
    xor %edi, %edi
    mov 0(%rsp), %rsi
    add 8(%rsp), %rsi
    mov $65536, %edx
    call read
    test %rax, %rax
    jg 5f
    jz 6f
    call __errno_location
    cmpl $4, (%rax)
    je 4b
6:  /* EOF: process a final unterminated line */
    mov 8(%rsp), %rsi
    test %rsi, %rsi
    jz 9f
    mov 0(%rsp), %rdi
    call handle_text_line
9:  LEAVE
5:  add %rax, 8(%rsp)
    jmp 1b
ENDF session_loop

/* handle_text_line(ptr, len): skips blank lines */
FUNC handle_text_line
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    xor %ecx, %ecx
1:  cmp %r12, %rcx
    jae 9f                          /* blank */
    movzbl (%rbx, %rcx), %eax
    inc %rcx
    cmp $' ', %al
    je 1b
    cmp $'\t', %al
    je 1b
    cmp $'\r', %al
    je 1b
    mov %rbx, %rdi
    mov %r12, %rsi
    call proto_handle_line
9:  LEAVE
ENDF handle_text_line
