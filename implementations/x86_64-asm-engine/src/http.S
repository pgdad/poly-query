/*
 * http.S - HTTP/1.1 message layer (protocol.md §7): incremental request
 * parsing (Content-Length and chunked bodies), response and chunk writing,
 * URL helpers and the error code -> HTTP status mapping.  Stateless: the
 * server (server.S) owns connections and buffers.
 *
 *   http_parse(buf, len, max_body, Req*) -> eax HP_*
 *   http_send(fd, status, ctype, body, len, flags) -> eax 0 / -1
 *   http_send_head_chunked(fd, ctype) -> eax 0 / -1
 *   http_send_chunk(fd, ptr, len) -> eax 0 / -1 (len 0 = last chunk)
 *   writev_all(fd, iov*, count) -> eax 0 / -1
 *   url_decode(src, len, dst) -> rax decoded length
 *   query_param(qs, qslen, name) -> rax value ptr or 0, rdx length
 *   http_status_for(code) -> eax HTTP status of an error code
 */
#include "pq.inc"
#include "http.inc"

    .section .note.GNU-stack, "", @progbits

    .data
    .p2align 3
    .globl g_resp_qid
g_resp_qid: .quad 0             /* C string: X-PolyQuery-Query-Id of the next response, or 0 */

    .bss
    .p2align 4
head_buf:   .zero BUF_SIZE      /* response head being built */

    .section .rodata
    .p2align 2
/* HTTP status per error code (pq.inc E_* order) */
err_status:
    .long 500                   /* 0 */
    .long 400, 400, 400, 400, 400, 400, 400, 400    /* PARSE .. SUBQUERY_CARDINALITY */
    .long 400, 400, 400         /* INVALID_REQUEST, INGEST_ERROR, UNSUPPORTED */
    .long 403, 404, 409, 409    /* ACCESS_DENIED, NOT_FOUND, ALREADY_EXISTS, CANCELLED */
    .long 413, 500, 500, 500, 500   /* RESOURCE_LIMIT, IO, CORRUPT, VERSION, INTERNAL */
    .long 503, 503, 504         /* OVERLOADED, SHUTTING_DOWN, TIMEOUT */

    .text

/* ================================================================ parsing */

/* hexval(al byte in edi) -> eax value 0..15 or -1 */
FUNC hexval
    lea -'0'(%rdi), %eax
    cmp $9, %eax
    jbe 9f
    mov %edi, %eax
    or $0x20, %eax
    sub $'a', %eax
    cmp $5, %eax
    ja 8f
    add $10, %eax
9:  ret
8:  mov $-1, %eax
    ret
ENDF hexval

/* chunk_line(buf rdi, pos rsi, len rdx) -> rax chunk size, rdx offset of its
 * data; rax = -1 incomplete, -2 malformed.  Validates "1*HEXDIG [ext] CRLF". */
FUNC chunk_line
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12                  /* p */
    mov %rdx, %r13                  /* len */
    xor %r14d, %r14d                /* size */
    xor %r15d, %r15d                /* digits */
1:  cmp %r13, %r12
    jae 7f                          /* need more */
    movzbl (%rbx, %r12), %edi
    call hexval
    test %eax, %eax
    js 2f
    cmp $15, %r15
    jae 8f                          /* absurd size */
    shl $4, %r14
    or %rax, %r14
    inc %r15
    inc %r12
    jmp 1b
2:  test %r15, %r15
    jz 8f                           /* no digits (e.g. "-5") */
    movzbl (%rbx, %r12), %eax
    cmp $';', %eax
    je 3f
    cmp $'\r', %eax
    je 3f
    cmp $'\n', %eax
    je 3f
    cmp $' ', %eax
    je 3f
    cmp $'\t', %eax
    jne 8f
3:  lea (%rbx, %r12), %rdi
    mov $'\n', %esi
    mov %r13, %rdx
    sub %r12, %rdx
    call memchr
    test %rax, %rax
    jz 6f
    sub %rbx, %rax
    lea 1(%rax), %rdx
    mov %r14, %rax
    LEAVE
6:  mov %r13, %rax                  /* unterminated: tolerate a short extension */
    sub %r12, %rax
    cmp $1024, %rax
    ja 8f
7:  mov $-1, %rax
    LEAVE
8:  mov $-2, %rax
    LEAVE
ENDF chunk_line

/* trailer_end(buf rdi, pos rsi, len rdx) -> rax offset after the blank line
 * ending the trailer section, or -1 if incomplete */
FUNC trailer_end
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
1:  cmp %r13, %r12
    jae 8f
    lea (%rbx, %r12), %rdi
    mov $'\n', %esi
    mov %r13, %rdx
    sub %r12, %rdx
    call memchr
    test %rax, %rax
    jz 8f
    sub %rbx, %rax                  /* offset of '\n' */
    mov %rax, %rcx
    sub %r12, %rcx                  /* line length */
    lea 1(%rax), %r12
    test %rcx, %rcx
    jz 9f
    cmp $1, %rcx
    jne 1b
    cmpb $'\r', -2(%rbx, %r12)
    jne 1b
9:  mov %r12, %rax
    LEAVE
8:  mov $-1, %rax
    LEAVE
ENDF trailer_end

/* chunked_body(buf rdi, len rsi, max rdx, Req* rcx) -> eax HP_*: scans the
 * chunked body after the header; when complete, decodes it in place */
#define CB_MAX   0
#define CB_TOTAL 8
#define CB_W     16
#define CB_DONE  24
FUNC chunked_body
    ENTER 32
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, CB_MAX(%rsp)
    mov %rcx, %r13
    movq $0, CB_TOTAL(%rsp)
    mov RQ_HDRLEN(%r13), %r14       /* pos */
1:  mov %rbx, %rdi                  /* pass 1: validate, find the end */
    mov %r14, %rsi
    mov %r12, %rdx
    call chunk_line
    cmp $-2, %rax
    je 8f
    cmp $-1, %rax
    je 7f
    mov %rdx, %r15                  /* data offset */
    test %rax, %rax
    jz 3f
    add %rax, CB_TOTAL(%rsp)
    mov CB_TOTAL(%rsp), %rcx
    cmp CB_MAX(%rsp), %rcx
    ja 6f
    lea 2(%r15, %rax), %rcx         /* data + CRLF */
    cmp %r12, %rcx
    ja 7f
    cmpb $'\r', -2(%rbx, %rcx)
    jne 8f
    cmpb $'\n', -1(%rbx, %rcx)
    jne 8f
    mov %rcx, %r14
    jmp 1b
3:  mov %rbx, %rdi                  /* last chunk: trailers */
    mov %r15, %rsi
    mov %r12, %rdx
    call trailer_end
    cmp $-1, %rax
    je 7f
    mov %rax, RQ_TOTAL(%r13)
    /* pass 2: move the chunk data together */
    mov RQ_HDRLEN(%r13), %r14
    mov %r14, CB_W(%rsp)
4:  mov %rbx, %rdi
    mov %r14, %rsi
    mov %r12, %rdx
    call chunk_line
    test %rax, %rax
    jz 5f
    mov %rax, %r15                  /* size */
    lea 2(%rdx, %rax), %r14         /* next chunk line */
    mov CB_W(%rsp), %rdi
    add %rbx, %rdi
    lea (%rbx, %rdx), %rsi
    mov %r15, %rdx
    call memmove
    add %r15, CB_W(%rsp)
    jmp 4b
5:  mov RQ_HDRLEN(%r13), %rax
    lea (%rbx, %rax), %rcx
    mov %rcx, RQ_BODY(%r13)
    mov CB_TOTAL(%rsp), %rcx
    mov %rcx, RQ_BODYLEN(%r13)
    mov $HP_OK, %eax
    LEAVE
6:  mov $HP_TOOBIG, %eax
    LEAVE
7:  mov $HP_NEED, %eax
    LEAVE
8:  mov $HP_BAD, %eax
    LEAVE
ENDF chunked_body

/* parse_clen(ptr rdi, len rsi) -> rax value or -1 if not 1*DIGIT */
FUNC parse_clen
    xor %eax, %eax
    test %rsi, %rsi
    jz 8f
    cmp $18, %rsi
    ja 8f
    xor %ecx, %ecx
1:  cmp %rsi, %rcx
    jae 9f
    movzbl (%rdi, %rcx), %edx
    sub $'0', %edx
    cmp $9, %edx
    ja 8f
    imul $10, %rax, %rax
    add %rdx, %rax
    inc %rcx
    jmp 1b
8:  mov $-1, %rax
9:  ret
ENDF parse_clen

/* http_parse(buf rdi, len rsi, max_body rdx, Req* rcx) -> eax HP_* */
#define HPL_MAX  0
#define HPL_LE   8      /* end of the current line (offset of '\n') */
#define HPL_HDR  16     /* header field: name ptr */
#define HPL_HLEN 24
#define HPL_VAL  32
#define HPL_VLEN 40
#define HPL_HASCL 48
#define HPL_SKIP 56     /* blank lines skipped before the request line */
FUNC http_parse
    ENTER 64
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, HPL_MAX(%rsp)
    mov %rcx, %r13
    movq $0, HPL_HASCL(%rsp)
    movq $0, HPL_SKIP(%rsp)
    mov %r13, %rdi
    xor %esi, %esi
    mov $RQ_SIZE, %edx
    call memset
    /* skip empty lines before a request line (RFC 9112 §2.2) */
0:  test %r12, %r12
    jz hp_need
    movzbl (%rbx), %eax
    cmp $'\r', %eax
    je 71f
    cmp $'\n', %eax
    jne 72f
71: inc %rbx
    dec %r12
    incq HPL_SKIP(%rsp)             /* consumed with the request */
    jmp 0b
72: mov %rbx, %rdi
    mov %r12, %rsi
    CSTR %rdx, "\r\n\r\n"
    mov $4, %ecx
    call memmem
    test %rax, %rax
    jz hp_nohead
    lea 4(%rax), %r14
    sub %rbx, %r14                  /* header length */
    mov %r14, RQ_HDRLEN(%r13)
    /* request line: METHOD SP target SP HTTP/1.x */
    mov %rbx, %rdi
    mov $'\n', %esi
    mov %r14, %rdx
    call memchr
    sub %rbx, %rax
    mov %rax, HPL_LE(%rsp)
    mov %rax, %r15                  /* line length without CR */
    cmpb $'\r', -1(%rbx, %rax)
    jne 1f
    dec %r15
1:  mov %rbx, %rdi
    mov $' ', %esi
    mov %r15, %rdx
    call memchr
    test %rax, %rax
    jz hp_bad
    mov %rbx, RQ_METH(%r13)
    mov %rax, %rcx
    sub %rbx, %rcx
    jz hp_bad
    mov %rcx, RQ_METHLEN(%r13)
    lea 1(%rax), %r14               /* target start */
    mov %r14, %rdi
    mov $' ', %esi
    lea (%rbx, %r15), %rdx
    sub %r14, %rdx
    call memchr
    test %rax, %rax
    jz hp_bad
    mov %r14, RQ_PATH(%r13)
    mov %rax, %rcx
    sub %r14, %rcx
    jz hp_bad
    mov %rcx, RQ_PATHLEN(%r13)
    /* version */
    lea 1(%rax), %rdi
    lea (%rbx, %r15), %rsi
    sub %rdi, %rsi                  /* version length */
    cmp $8, %rsi
    jne hp_bad
    mov %rdi, %r14
    CSTR %rsi, "HTTP/1."
    mov $7, %edx
    call strncmp
    test %eax, %eax
    jnz hp_bad
    cmpb $'0', 7(%r14)
    jne 2f
    movq $1, RQ_CLOSE(%r13)         /* HTTP/1.0: close unless keep-alive */
2:  /* split the query string */
    mov RQ_PATH(%r13), %rdi
    mov $'?', %esi
    mov RQ_PATHLEN(%r13), %rdx
    call memchr
    test %rax, %rax
    jz 3f
    lea 1(%rax), %rcx
    mov %rcx, RQ_QS(%r13)
    mov RQ_PATH(%r13), %rdx
    add RQ_PATHLEN(%r13), %rdx
    sub %rcx, %rdx
    mov %rdx, RQ_QSLEN(%r13)
    sub RQ_PATH(%r13), %rax
    mov %rax, RQ_PATHLEN(%r13)
3:  /* header fields */
    mov HPL_LE(%rsp), %r14
    inc %r14                        /* start of the next line */
4:  lea (%rbx, %r14), %rdi
    mov $'\n', %esi
    mov RQ_HDRLEN(%r13), %rdx
    sub %r14, %rdx
    call memchr
    test %rax, %rax
    jz 20f
    sub %rbx, %rax
    mov %rax, HPL_LE(%rsp)
    mov %rax, %r15
    cmp %r14, %r15
    je 20f
    cmpb $'\r', -1(%rbx, %r15)
    jne 5f
    dec %r15                        /* r15 = end of the field line */
5:  cmp %r14, %r15
    je 20f                          /* blank line */
    lea (%rbx, %r14), %rdi
    mov $':', %esi
    mov %r15, %rdx
    sub %r14, %rdx
    call memchr
    test %rax, %rax
    jz hp_bad
    lea (%rbx, %r14), %rcx
    mov %rcx, HPL_HDR(%rsp)
    mov %rax, %rdx
    sub %rcx, %rdx
    mov %rdx, HPL_HLEN(%rsp)
    /* trim the value */
    lea 1(%rax), %rsi
    lea (%rbx, %r15), %rdi
6:  cmp %rdi, %rsi
    jae 7f
    cmpb $' ', (%rsi)
    je 61f
    cmpb $'\t', (%rsi)
    jne 7f
61: inc %rsi
    jmp 6b
7:  cmp %rsi, %rdi
    jbe 8f
    cmpb $' ', -1(%rdi)
    je 71f
    cmpb $'\t', -1(%rdi)
    jne 8f
71: dec %rdi
    jmp 7b
8:  mov %rsi, HPL_VAL(%rsp)
    sub %rsi, %rdi
    mov %rdi, HPL_VLEN(%rsp)
    /* known fields */
    mov HPL_HDR(%rsp), %rdi
    mov HPL_HLEN(%rsp), %rsi
    CSTR %rdx, "content-length"
    call cstr_ieq
    test %eax, %eax
    jz 9f
    mov HPL_VAL(%rsp), %rdi
    mov HPL_VLEN(%rsp), %rsi
    call parse_clen
    test %rax, %rax
    js hp_bad
    cmpq $0, HPL_HASCL(%rsp)
    je 81f
    cmp RQ_CLEN(%r13), %rax         /* conflicting duplicates */
    jne hp_bad
81: mov %rax, RQ_CLEN(%r13)
    movq $1, HPL_HASCL(%rsp)
    jmp 19f
9:  mov HPL_HDR(%rsp), %rdi
    mov HPL_HLEN(%rsp), %rsi
    CSTR %rdx, "transfer-encoding"
    call cstr_ieq
    test %eax, %eax
    jz 10f
    mov HPL_VLEN(%rsp), %rsi
    cmp $7, %rsi
    jb hp_bad
    mov HPL_VAL(%rsp), %rdi
    lea -7(%rdi, %rsi), %rdi        /* the final coding must be chunked */
    mov $7, %esi
    CSTR %rdx, "chunked"
    call cstr_ieq
    test %eax, %eax
    jz hp_bad
    movq $1, RQ_CHUNKED(%r13)
    jmp 19f
10: mov HPL_HDR(%rsp), %rdi
    mov HPL_HLEN(%rsp), %rsi
    CSTR %rdx, "connection"
    call cstr_ieq
    test %eax, %eax
    jz 11f
    mov HPL_VAL(%rsp), %rdi
    mov HPL_VLEN(%rsp), %rsi
    CSTR %rdx, "close"
    call cstr_ieq
    test %eax, %eax
    jz 101f
    movq $1, RQ_CLOSE(%r13)
    jmp 19f
101: mov HPL_VAL(%rsp), %rdi
    mov HPL_VLEN(%rsp), %rsi
    CSTR %rdx, "keep-alive"
    call cstr_ieq
    test %eax, %eax
    jz 19f
    movq $0, RQ_CLOSE(%r13)
    jmp 19f
11: mov HPL_HDR(%rsp), %rdi
    mov HPL_HLEN(%rsp), %rsi
    CSTR %rdx, "expect"
    call cstr_ieq
    test %eax, %eax
    jz 19f
    mov HPL_VAL(%rsp), %rdi
    mov HPL_VLEN(%rsp), %rsi
    CSTR %rdx, "100-continue"
    call cstr_ieq
    mov %rax, RQ_EXPECT(%r13)
19: mov HPL_LE(%rsp), %r14
    inc %r14
    jmp 4b
20: /* body */
    cmpq $0, RQ_CHUNKED(%r13)
    je 21f
    mov %rbx, %rdi
    mov %r12, %rsi
    mov HPL_MAX(%rsp), %rdx
    mov %r13, %rcx
    call chunked_body
    jmp 29f
21: mov RQ_CLEN(%r13), %rax
    cmp HPL_MAX(%rsp), %rax
    ja hp_toobig
    mov RQ_HDRLEN(%r13), %rcx
    lea (%rcx, %rax), %rdx
    cmp %r12, %rdx
    ja hp_need
    lea (%rbx, %rcx), %rcx
    mov %rcx, RQ_BODY(%r13)
    mov %rax, RQ_BODYLEN(%r13)
    mov %rdx, RQ_TOTAL(%r13)
    mov $HP_OK, %eax
29: /* offsets are relative to the original buffer start */
    mov HPL_SKIP(%rsp), %rcx
    add %rcx, RQ_TOTAL(%r13)
    add %rcx, RQ_HDRLEN(%r13)
    LEAVE
hp_nohead:
    cmp $65536, %r12
    ja hp_bad
hp_need:
    movq $0, RQ_TOTAL(%r13)
    mov $HP_NEED, %eax
    jmp 29b
hp_bad:
    mov $HP_BAD, %eax
    jmp 29b
hp_toobig:
    mov $HP_TOOBIG, %eax
    jmp 29b
ENDF http_parse

/* ================================================================ writing */

/* writev_all(fd edi, iov rsi, count edx) -> eax 0, or -1 on error (iov is
 * consumed) */
FUNC writev_all
    ENTER 0
    mov %edi, %ebx
    mov %rsi, %r12
    mov %edx, %r13d
1:  test %r13d, %r13d
    jz 8f
    cmpq $0, 8(%r12)
    jne 2f
    add $16, %r12
    dec %r13d
    jmp 1b
2:  mov %ebx, %edi
    mov %r12, %rsi
    mov %r13d, %edx
    call writev
    test %rax, %rax
    jns 3f
    call __errno_location
    cmpl $4, (%rax)                 /* EINTR */
    je 1b
    mov $-1, %eax
    LEAVE
3:  test %rax, %rax                 /* advance over what was written */
    jz 1b
    mov 8(%r12), %rcx
    cmp %rcx, %rax
    jb 4f
    sub %rcx, %rax
    movq $0, 8(%r12)
    add $16, %r12
    dec %r13d
    jmp 3b
4:  add %rax, (%r12)
    sub %rax, 8(%r12)
    jmp 1b
8:  xor %eax, %eax
    LEAVE
ENDF writev_all

/* status_reason(status edi) -> rax C string */
FUNC status_reason
    CSTR %rax, "OK"
    cmp $200, %edi
    je 9f
    CSTR %rax, "Created"
    cmp $201, %edi
    je 9f
    CSTR %rax, "Bad Request"
    cmp $400, %edi
    je 9f
    CSTR %rax, "Forbidden"
    cmp $403, %edi
    je 9f
    CSTR %rax, "Not Found"
    cmp $404, %edi
    je 9f
    CSTR %rax, "Method Not Allowed"
    cmp $405, %edi
    je 9f
    CSTR %rax, "Conflict"
    cmp $409, %edi
    je 9f
    CSTR %rax, "Content Too Large"
    cmp $413, %edi
    je 9f
    CSTR %rax, "Service Unavailable"
    cmp $503, %edi
    je 9f
    CSTR %rax, "Gateway Timeout"
    cmp $504, %edi
    je 9f
    CSTR %rax, "Internal Server Error"
9:  ret
ENDF status_reason

/* put_head(status edi, ctype rsi, flags edx): status line and the common
 * header fields into head_buf (without the terminating blank line) */
FUNC put_head
    ENTER 0
    mov %edi, %ebx
    mov %rsi, %r12
    mov %edx, %r13d
    lea head_buf(%rip), %r15
    movq $0, BUF_LEN(%r15)
    PUTS %r15, "HTTP/1.1 "
    mov %r15, %rdi
    mov %ebx, %esi
    call buf_put_u64
    mov %r15, %rdi
    mov $' ', %esi
    call buf_putc
    mov %ebx, %edi
    call status_reason
    mov %r15, %rdi
    mov %rax, %rsi
    call buf_puts
    PUTS %r15, "\r\nContent-Type: "
    mov %r15, %rdi
    mov %r12, %rsi
    call buf_puts
    mov g_resp_qid(%rip), %rax
    test %rax, %rax
    jz 1f
    PUTS %r15, "\r\nX-PolyQuery-Query-Id: "
    mov %r15, %rdi
    mov g_resp_qid(%rip), %rsi
    call buf_puts
1:  test $HS_CLOSE, %r13d
    jz 2f
    PUTS %r15, "\r\nConnection: close"
    jmp 3f
2:  PUTS %r15, "\r\nConnection: keep-alive"
3:  LEAVE
ENDF put_head

/* http_send(fd edi, status esi, ctype rdx, body rcx, len r8, flags r9d)
 * -> eax 0 / -1: a complete response with Content-Length */
FUNC http_send
    ENTER 48
    mov %edi, %ebx
    mov %rcx, %r12
    mov %r8, %r13
    mov %esi, %edi
    mov %rdx, %rsi
    mov %r9d, %edx
    call put_head
    lea head_buf(%rip), %r15
    PUTS %r15, "\r\nContent-Length: "
    mov %r15, %rdi
    mov %r13, %rsi
    call buf_put_u64
    PUTS %r15, "\r\n\r\n"
    mov BUF_DATA(%r15), %rax
    mov %rax, 0(%rsp)
    mov BUF_LEN(%r15), %rax
    mov %rax, 8(%rsp)
    mov %r12, 16(%rsp)
    mov %r13, 24(%rsp)
    mov %ebx, %edi
    lea 0(%rsp), %rsi
    mov $2, %edx
    call writev_all
    LEAVE
ENDF http_send

/* http_send_head_chunked(fd edi, ctype rsi) -> eax 0 / -1 */
FUNC http_send_head_chunked
    ENTER 16
    mov %edi, %ebx
    mov $200, %edi
    xor %edx, %edx
    call put_head
    lea head_buf(%rip), %r15
    PUTS %r15, "\r\nTransfer-Encoding: chunked\r\n\r\n"
    mov %ebx, %edi
    mov BUF_DATA(%r15), %rsi
    mov BUF_LEN(%r15), %rdx
    mov %rsi, 0(%rsp)
    mov %rdx, 8(%rsp)
    lea 0(%rsp), %rsi
    mov $1, %edx
    call writev_all
    LEAVE
ENDF http_send_head_chunked

/* http_send_chunk(fd edi, ptr rsi, len rdx) -> eax 0 / -1; len 0 writes the
 * last chunk (end of the body) */
FUNC http_send_chunk
    ENTER 80
    mov %edi, %ebx
    mov %rsi, %r12
    mov %rdx, %r13
    lea 48(%rsp), %rdi              /* chunk-size line */
    mov $24, %esi
    CSTR %rdx, "%lx\r\n"
    mov %r13, %rcx
    xor %eax, %eax
    call snprintf
    lea 48(%rsp), %rcx
    mov %rcx, 0(%rsp)
    mov %rax, 8(%rsp)
    mov %r12, 16(%rsp)
    mov %r13, 24(%rsp)
    CSTR %rcx, "\r\n"
    mov %rcx, 32(%rsp)
    movq $2, 40(%rsp)
    mov %ebx, %edi
    lea 0(%rsp), %rsi
    mov $3, %edx
    call writev_all
    LEAVE
ENDF http_send_chunk

/* ================================================================ URLs */

/* url_decode(src rdi, len rsi, dst rdx) -> rax length (%XX escapes) */
FUNC url_decode
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    xor %r14d, %r14d                /* in */
    xor %r15d, %r15d                /* out */
1:  cmp %r12, %r14
    jae 9f
    movzbl (%rbx, %r14), %eax
    cmp $'%', %eax
    jne 3f
    lea 2(%r14), %rcx
    cmp %r12, %rcx
    jae 3f
    movzbl 1(%rbx, %r14), %edi
    call hexval
    test %eax, %eax
    js 2f
    mov %eax, %ecx
    shl $4, %ecx
    push %rcx
    push %rcx
    movzbl 2(%rbx, %r14), %edi
    call hexval
    pop %rcx
    pop %rcx
    test %eax, %eax
    js 2f
    or %ecx, %eax
    mov %al, (%r13, %r15)
    inc %r15
    add $3, %r14
    jmp 1b
2:  movzbl (%rbx, %r14), %eax
3:  mov %al, (%r13, %r15)
    inc %r15
    inc %r14
    jmp 1b
9:  movb $0, (%r13, %r15)
    mov %r15, %rax
    LEAVE
ENDF url_decode

/* query_param(qs rdi, qslen rsi, name rdx) -> rax value ptr or 0, rdx len */
FUNC query_param
    ENTER 16
    mov %rdi, %rbx                  /* cursor */
    lea (%rdi, %rsi), %r12          /* end */
    mov %rdx, %r13
    mov %r13, %rdi
    call strlen
    mov %rax, %r14                  /* name length */
1:  cmp %r12, %rbx
    jae 8f
    mov %rbx, %rdi                  /* end of this pair */
    mov $'&', %esi
    mov %r12, %rdx
    sub %rbx, %rdx
    call memchr
    test %rax, %rax
    jnz 2f
    mov %r12, %rax
2:  mov %rax, %r15                  /* pair end */
    lea (%rbx, %r14), %rcx
    cmp %r15, %rcx
    jae 3f
    cmpb $'=', (%rcx)
    jne 3f
    mov %rbx, %rdi
    mov %r13, %rsi
    mov %r14, %rdx
    call strncmp
    test %eax, %eax
    jnz 3f
    lea 1(%rbx, %r14), %rax
    mov %r15, %rdx
    sub %rax, %rdx
    LEAVE
3:  lea 1(%r15), %rbx
    jmp 1b
8:  xor %eax, %eax
    xor %edx, %edx
    LEAVE
ENDF query_param

/* http_status_for(code edi) -> eax HTTP status */
FUNC http_status_for
    cmp $E_TIMEOUT, %edi
    jbe 1f
    xor %edi, %edi
1:  lea err_status(%rip), %rax
    mov (%rax, %rdi, 4), %eax
    ret
ENDF http_status_for
