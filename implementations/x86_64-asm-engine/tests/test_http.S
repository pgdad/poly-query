/*
 * test_http.S - unit tests for src/http.S: http_parse (request line,
 * header fields, Content-Length / chunked bodies, limits, malformed
 * framing), url_decode, query_param and http_status_for.
 *
 * Parse cases are triples: request text, max body size (decimal string),
 * expected outcome.  The outcome is "NEED", "BAD", "TOOBIG", or for a
 * complete request "method|path|query|body|total|close".
 */
#include "pq.inc"
#include "http.inc"

    .section .note.GNU-stack, "", @progbits

    .data
    .p2align 3
n_pass:     .quad 0
n_fail:     .quad 0

    .bss
    .p2align 4
req:        .zero RQ_SIZE
scratch:    .zero 4096
sum:        .zero BUF_SIZE

    .section .rodata
cases:
    .asciz "GET /health HTTP/1.1\r\nHost: x\r\n\r\n"
    .asciz "100"
    .asciz "GET|/health|||33|0"
    .asciz "GET /health HTTP/1.1\r\nHost: x\r\n"
    .asciz "100"
    .asciz "NEED"
    .asciz "\r\nGET /a?b=1&c HTTP/1.1\r\n\r\n"
    .asciz "100"
    .asciz "GET|/a|b=1&c||27|0"
    .asciz "POST /v1/query HTTP/1.1\r\nContent-Length: 5\r\n\r\nhelloGET / HTTP/1.1\r\n"
    .asciz "100"
    .asciz "POST|/v1/query||hello|51|0"
    .asciz "POST /v1/query HTTP/1.1\r\ncontent-length:  10 \r\n\r\nhello"
    .asciz "100"
    .asciz "NEED"
    .asciz "POST /q HTTP/1.1\r\nContent-Length: 11\r\n\r\nhello world"
    .asciz "10"
    .asciz "TOOBIG"
    .asciz "POST /q HTTP/1.1\r\nContent-Length: 1x\r\n\r\n"
    .asciz "100"
    .asciz "BAD"
    .asciz "POST /q HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab"
    .asciz "100"
    .asciz "BAD"
    .asciz "PUT /t HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\n\r\n"
    .asciz "100"
    .asciz "PUT|/t||hello world|79|0"
    .asciz "PUT /t HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nA\r\n0123456789\r\n0\r\nX-T: 1\r\n\r\nNEXT"
    .asciz "100"
    .asciz "PUT|/t||0123456789|75|0"
    .asciz "PUT /t HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel"
    .asciz "100"
    .asciz "NEED"
    .asciz "PUT /t HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n"
    .asciz "100"
    .asciz "NEED"
    .asciz "PUT /t HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n-5\r\na\n1\n"
    .asciz "100"
    .asciz "BAD"
    .asciz "PUT /t HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n-"
    .asciz "100"
    .asciz "BAD"
    .asciz "PUT /t HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhelloXX0\r\n\r\n"
    .asciz "100"
    .asciz "BAD"
    .asciz "PUT /t HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n3\r\ndef\r\n0\r\n\r\n"
    .asciz "5"
    .asciz "TOOBIG"
    .asciz "PUT /t HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n"
    .asciz "100"
    .asciz "BAD"
    .asciz "GET /x HTTP/1.0\r\n\r\n"
    .asciz "100"
    .asciz "GET|/x|||19|1"
    .asciz "GET /x HTTP/1.0\r\nConnection: Keep-Alive\r\n\r\n"
    .asciz "100"
    .asciz "GET|/x|||43|0"
    .asciz "GET /x HTTP/1.1\r\nConnection: close\r\n\r\n"
    .asciz "100"
    .asciz "GET|/x|||38|1"
    .asciz "GARBAGE\r\n\r\n"
    .asciz "100"
    .asciz "BAD"
    .asciz "GET /x HTTP/2.0\r\n\r\n"
    .asciz "100"
    .asciz "BAD"
    .asciz "GET /x HTTP/1.1\r\nNoColon\r\n\r\n"
    .asciz "100"
    .asciz "BAD"
    .byte 0xff

    .text

/* t_assert(cond edi, msg rsi, detail rdx) */
t_assert:
    sub $8, %rsp
    test %edi, %edi
    jz 1f
    incq n_pass(%rip)
    add $8, %rsp
    ret
1:  incq n_fail(%rip)
    CSTR %rdi, "FAIL: %s [%s]\n"
    xor %eax, %eax
    call printf
    add $8, %rsp
    ret

/* summarize(): "method|path|query|body|total|close" of req into sum */
summarize:
    push %rbx
    lea sum(%rip), %rbx
    movq $0, BUF_LEN(%rbx)
    mov %rbx, %rdi
    mov req+RQ_METH(%rip), %rsi
    mov req+RQ_METHLEN(%rip), %rdx
    call buf_put
    mov %rbx, %rdi
    mov $'|', %esi
    call buf_putc
    mov %rbx, %rdi
    mov req+RQ_PATH(%rip), %rsi
    mov req+RQ_PATHLEN(%rip), %rdx
    call buf_put
    mov %rbx, %rdi
    mov $'|', %esi
    call buf_putc
    mov %rbx, %rdi
    mov req+RQ_QS(%rip), %rsi
    mov req+RQ_QSLEN(%rip), %rdx
    call buf_put
    mov %rbx, %rdi
    mov $'|', %esi
    call buf_putc
    mov %rbx, %rdi
    mov req+RQ_BODY(%rip), %rsi
    mov req+RQ_BODYLEN(%rip), %rdx
    call buf_put
    mov %rbx, %rdi
    mov $'|', %esi
    call buf_putc
    mov %rbx, %rdi
    mov req+RQ_TOTAL(%rip), %rsi
    call buf_put_u64
    mov %rbx, %rdi
    mov $'|', %esi
    call buf_putc
    mov %rbx, %rdi
    mov req+RQ_CLOSE(%rip), %rsi
    call buf_put_u64
    mov BUF_DATA(%rbx), %rax
    mov BUF_LEN(%rbx), %rcx
    movb $0, (%rax, %rcx)
    pop %rbx
    ret

/* parse_cases(): runs the table */
parse_cases:
    ENTER 16
    lea cases(%rip), %rbx
1:  cmpb $0xff, (%rbx)
    je 9f
    mov %rbx, %rdi
    call strlen
    mov %rax, %r12                  /* input length */
    lea scratch(%rip), %rdi
    mov %rbx, %rsi
    mov %r12, %rdx
    call memcpy
    lea 1(%rbx, %r12), %r13         /* max */
    mov %r13, %rdi
    call atol
    mov %rax, %r14
    mov %r13, %rdi
    call strlen
    lea 1(%r13, %rax), %r15         /* expected */
    lea scratch(%rip), %rdi
    mov %r12, %rsi
    mov %r14, %rdx
    lea req(%rip), %rcx
    xor %r8d, %r8d
    call http_parse
    CSTR %rdi, "NEED"
    cmp $HP_NEED, %eax
    je 2f
    CSTR %rdi, "BAD"
    cmp $HP_BAD, %eax
    je 2f
    CSTR %rdi, "TOOBIG"
    cmp $HP_TOOBIG, %eax
    je 2f
    call summarize
    mov sum+BUF_DATA(%rip), %rdi
2:  mov %rdi, 0(%rsp)
    mov %r15, %rsi
    call strcmp
    test %eax, %eax
    sete %al
    movzbl %al, %edi
    mov %rbx, %rsi
    mov 0(%rsp), %rdx
    call t_assert
    mov %r15, %rdi                  /* next case */
    call strlen
    lea 1(%r15, %rax), %rbx
    jmp 1b
9:  LEAVE

    .section .rodata
inc_req: .asciz "PUT /t HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\n\r\n"
    .text

/* incremental(): feeds growing prefixes of a chunked request with a resume
 * state (as the server does); every proper prefix is incomplete and the
 * whole request decodes to the same body */
incremental:
    ENTER 32
    movq $0, 0(%rsp)                /* resume state */
    movq $0, 8(%rsp)
    lea inc_req(%rip), %rdi
    call strlen
    mov %rax, %r12                  /* full length */
    mov $1, %r13d                   /* prefix length */
    xor %r14d, %r14d                /* bad results */
1:  lea scratch(%rip), %rdi
    lea inc_req(%rip), %rsi
    mov %r13, %rdx
    call memcpy
    lea scratch(%rip), %rdi
    mov %r13, %rsi
    mov $100, %edx
    lea req(%rip), %rcx
    lea 0(%rsp), %r8
    call http_parse
    cmp %r12, %r13
    je 2f
    cmp $HP_NEED, %eax
    je 3f
    inc %r14
3:  inc %r13
    jmp 1b
2:  cmp $HP_OK, %eax
    jne 4f
    call summarize
    mov sum+BUF_DATA(%rip), %rdi
    CSTR %rsi, "PUT|/t||hello world|79|0"
    call strcmp
    test %eax, %eax
    jz 5f
4:  inc %r14
5:  test %r14, %r14
    sete %al
    movzbl %al, %edi
    CSTR %rsi, "incremental chunked parse"
    mov sum+BUF_DATA(%rip), %rdx
    call t_assert
    LEAVE

/* misc(): url_decode, query_param, http_status_for */
misc:
    ENTER 64
    CSTR %rdi, "a%20b%zz%4"
    mov $10, %esi
    lea 0(%rsp), %rdx
    call url_decode
    lea 0(%rsp), %rdi
    CSTR %rsi, "a b%zz%4"
    call strcmp
    test %eax, %eax
    sete %al
    movzbl %al, %edi
    CSTR %rsi, "url_decode"
    lea 0(%rsp), %rdx
    call t_assert
    CSTR %rbx, "format=csv&replace=true&header"
    mov %rbx, %rdi
    mov $30, %esi
    CSTR %rdx, "replace"
    call query_param
    test %rax, %rax
    jz 1f
    cmp $4, %rdx
    jne 1f
    cmpl $0x65757274, (%rax)        /* "true" */
1:  sete %al
    movzbl %al, %edi
    CSTR %rsi, "query_param replace"
    CSTR %rdx, ""
    call t_assert
    mov %rbx, %rdi
    mov $30, %esi
    CSTR %rdx, "header"
    call query_param
    test %rax, %rax
    sete %al
    movzbl %al, %edi
    CSTR %rsi, "query_param without '='"
    CSTR %rdx, ""
    call t_assert
    mov %rbx, %rdi
    mov $30, %esi
    CSTR %rdx, "form"
    call query_param
    test %rax, %rax
    sete %al
    movzbl %al, %edi
    CSTR %rsi, "query_param prefix"
    CSTR %rdx, ""
    call t_assert
    /* status mapping (protocol.md §7.1) */
    mov $E_PARSE_ERROR, %edi
    call http_status_for
    cmp $400, %eax
    sete %al
    movzbl %al, %edi
    CSTR %rsi, "PARSE_ERROR -> 400"
    CSTR %rdx, ""
    call t_assert
    mov $E_CANCELLED, %edi
    call http_status_for
    cmp $409, %eax
    sete %al
    movzbl %al, %edi
    CSTR %rsi, "CANCELLED -> 409"
    CSTR %rdx, ""
    call t_assert
    mov $E_RESOURCE_LIMIT, %edi
    call http_status_for
    cmp $413, %eax
    sete %al
    movzbl %al, %edi
    CSTR %rsi, "RESOURCE_LIMIT -> 413"
    CSTR %rdx, ""
    call t_assert
    mov $E_ACCESS_DENIED, %edi
    call http_status_for
    cmp $403, %eax
    sete %al
    movzbl %al, %edi
    CSTR %rsi, "ACCESS_DENIED -> 403"
    CSTR %rdx, ""
    call t_assert
    mov $E_STORAGE_VERSION, %edi
    call http_status_for
    cmp $500, %eax
    sete %al
    movzbl %al, %edi
    CSTR %rsi, "STORAGE_VERSION_UNSUPPORTED -> 500"
    CSTR %rdx, ""
    call t_assert
    mov $E_OVERLOADED, %edi
    call http_status_for
    cmp $503, %eax
    sete %al
    movzbl %al, %edi
    CSTR %rsi, "OVERLOADED -> 503"
    CSTR %rdx, ""
    call t_assert
    mov $E_TIMEOUT, %edi
    call http_status_for
    cmp $504, %eax
    sete %al
    movzbl %al, %edi
    CSTR %rsi, "TIMEOUT -> 504"
    CSTR %rdx, ""
    call t_assert
    LEAVE

FUNC main
    ENTER 0
    call arena_new
    mov %rax, g_arena(%rip)
    call parse_cases
    call incremental
    call misc
    CSTR %rdi, "test_http: %ld passed, %ld failed\n"
    mov n_pass(%rip), %rsi
    mov n_fail(%rip), %rdx
    xor %eax, %eax
    call printf
    xor %eax, %eax
    cmpq $0, n_fail(%rip)
    setne %al
    LEAVE
ENDF main
