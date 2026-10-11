/*
 * util.S - runtime support: global state, error raising, arenas, growable
 * byte buffers, u64 vectors, length-prefixed strings and string helpers.
 */
#include "pq.inc"

    .section .note.GNU-stack, "", @progbits

/* ======================================================== global state */
    .data
    .p2align 3
    .globl g_arena, g_jmpbuf, g_err_code, g_max_table_rows, g_max_ingest_bytes
    .globl g_max_query_mem, g_test_functions, g_data_dir, g_deadline_ns, g_pending_arena
    .globl g_max_join_rows, g_err_line, g_err_col
g_arena:            .quad 0        /* Arena* for the current request */
g_jmpbuf:           .quad 0        /* jmp_buf* of the active error handler */
g_err_code:         .quad 0
g_max_table_rows:   .quad 200000000
g_max_ingest_bytes: .quad 0x7fffffffffffffff
g_max_query_mem:    .quad 4096*1024*1024
g_max_join_rows:    .quad 100000000
g_err_line:         .quad 0        /* SQL position of the error (details), 0 = none */
g_err_col:          .quad 0
g_test_functions:   .quad 0
g_data_dir:         .quad 0        /* C string */
g_deadline_ns:      .quad 0        /* CLOCK_MONOTONIC deadline of the running query, 0 = none */
g_pending_arena:    .quad 0        /* arena of a table under construction; destroyed on error */
    .globl g_cancel_flag
g_cancel_flag:      .quad 0        /* set asynchronously when the running query is cancelled */

    .bss
    .p2align 4
    .globl g_err_msg
g_err_msg:          .zero 512

/* Thread-local overrides used by parallel workers (par.S): a worker
 * allocates from its own arena and reports errors to its own handler.
 * Both are 0 on every other thread, which then uses the globals. */
    .section .tbss, "awT", @nobits
    .p2align 4
    .globl t_arena, t_jmpbuf, t_err_code, t_err_msg
t_arena:    .zero 8
t_jmpbuf:   .zero 8
t_err_code: .zero 8
    .zero 8
t_err_msg:  .zero 512

    .text

/* ======================================================== errors */

/* err_slot() -> rax error code slot, rdx 512-byte message buffer: the
 * worker's thread-local ones inside a parallel worker, else the globals */
err_slot:
    cmpq $0, %fs:t_jmpbuf@tpoff
    jne 1f
    lea g_err_code(%rip), %rax
    lea g_err_msg(%rip), %rdx
    ret
1:  mov %fs:0, %rax
    lea t_err_msg@tpoff(%rax), %rdx
    lea t_err_code@tpoff(%rax), %rax
    ret

/* pq_raise(code edi, msg rsi) - noreturn */
FUNC pq_raise
    push %rbp
    mov %rsp, %rbp
    and $-16, %rsp
    mov %edi, %edi
    call err_slot
    mov %rdi, (%rax)
    mov %rdx, %rdi
    push %rdx
    push %rdx
    mov $511, %edx
    call strncpy
    pop %rdx
    pop %rdx
    movb $0, 511(%rdx)
    jmp raise_jump
ENDF pq_raise

/* pq_raisef(code edi, fmt rsi, a rdx, b rcx, c r8) - snprintf-formatted message, noreturn */
FUNC pq_raisef
    push %rbp
    mov %rsp, %rbp
    and $-16, %rsp
    mov %edi, %edi
    mov %r8, %r9
    mov %rcx, %r8
    mov %rdx, %rcx
    mov %rsi, %r10
    call err_slot                   /* clobbers only rax, rdx */
    mov %rdi, (%rax)
    mov %rdx, %rdi
    mov %r10, %rdx
    mov $512, %esi
    xor %eax, %eax
    call snprintf
    jmp raise_jump
ENDF pq_raisef

raise_jump:
    mov %fs:t_jmpbuf@tpoff, %rdi
    test %rdi, %rdi
    jnz 2f
    mov g_jmpbuf(%rip), %rdi
    test %rdi, %rdi
    jz 1f
    mov $1, %esi
    call longjmp
2:  mov $1, %esi                    /* parallel worker */
    call longjmp
1:  /* no handler: fatal */
    mov stderr(%rip), %rdi
    lea g_err_msg(%rip), %rsi
    call fputs
    mov $1, %edi
    call exit

/* ======================================================== malloc wrappers */

/* xmalloc(size) -> ptr; RESOURCE_LIMIT on failure */
FUNC xmalloc
    sub $8, %rsp
    test %rdi, %rdi
    jnz 1f
    mov $1, %edi
1:  call malloc
    test %rax, %rax
    jz 2f
    add $8, %rsp
    ret
2:  RAISE E_RESOURCE_LIMIT, "out of memory"
ENDF xmalloc

/* xrealloc(ptr, size) -> ptr */
FUNC xrealloc
    sub $8, %rsp
    call realloc
    test %rax, %rax
    jz 2f
    add $8, %rsp
    ret
2:  RAISE E_RESOURCE_LIMIT, "out of memory"
ENDF xrealloc

/* ======================================================== arenas */

#define CHUNK_MIN (256*1024)

/* arena_new() -> Arena* (zeroed, unlimited) */
FUNC arena_new
    sub $8, %rsp
    mov $1, %edi
    mov $ARENA_SIZE, %esi
    call calloc
    test %rax, %rax
    jz 1f
    add $8, %rsp
    ret
1:  RAISE E_RESOURCE_LIMIT, "out of memory"
ENDF arena_new

/* arena_alloc(arena rdi, size rsi) -> 16-byte aligned ptr (not zeroed) */
FUNC arena_alloc
    add $15, %rsi
    and $-16, %rsi
    mov AR_CUR(%rdi), %rax
    lea (%rax, %rsi), %rdx
    cmp AR_END(%rdi), %rdx
    ja arena_alloc_slow
    test %rax, %rax
    jz arena_alloc_slow
    mov %rdx, AR_CUR(%rdi)
    ret
ENDF arena_alloc

arena_alloc_slow:
    ENTER 0
    mov %rdi, %rbx                  /* arena */
    mov %rsi, %r12                  /* rounded size */
    /* chunk size = max(size + 16, CHUNK_MIN, total/2 capped at 64MiB) */
    lea 16(%rsi), %r13
    mov $CHUNK_MIN, %rax
    cmp %rax, %r13
    cmovb %rax, %r13
    mov AR_TOTAL(%rbx), %rax
    shr $1, %rax
    mov $(64*1024*1024), %rcx
    cmp %rcx, %rax
    cmova %rcx, %rax
    cmp %rax, %r13
    cmovb %rax, %r13
    /* limit check */
    mov AR_TOTAL(%rbx), %rax
    add %r13, %rax
    mov AR_LIMIT(%rbx), %rcx
    test %rcx, %rcx
    jz 1f
    cmp %rcx, %rax
    jbe 1f
    RAISE E_RESOURCE_LIMIT, "query memory budget exceeded"
1:  mov %rax, AR_TOTAL(%rbx)
    mov %r13, %rdi
    call malloc
    test %rax, %rax
    jnz 2f
    RAISE E_RESOURCE_LIMIT, "out of memory"
2:  mov AR_CHUNKS(%rbx), %rcx
    mov %rcx, (%rax)
    mov %rax, AR_CHUNKS(%rbx)
    lea (%rax, %r13), %rcx
    mov %rcx, AR_END(%rbx)
    lea 16(%rax), %rdx              /* result */
    lea (%rdx, %r12), %rcx
    mov %rcx, AR_CUR(%rbx)
    mov %rdx, %rax
    LEAVE

/* arena_zalloc(arena, size) -> zeroed ptr */
FUNC arena_zalloc
    push %rbx
    mov %rsi, %rbx
    call arena_alloc
    mov %rax, %rdi
    xor %esi, %esi
    mov %rbx, %rdx
    call memset
    pop %rbx
    ret
ENDF arena_zalloc

/* arena_reset(arena): frees all chunks, keeps the Arena object and its limit */
FUNC arena_reset
    push %rbx
    push %r12
    sub $8, %rsp
    mov %rdi, %rbx
    mov AR_CHUNKS(%rbx), %r12
1:  test %r12, %r12
    jz 2f
    mov %r12, %rdi
    mov (%r12), %r12
    call free
    jmp 1b
2:  movq $0, AR_CUR(%rbx)
    movq $0, AR_END(%rbx)
    movq $0, AR_CHUNKS(%rbx)
    movq $0, AR_TOTAL(%rbx)
    add $8, %rsp
    pop %r12
    pop %rbx
    ret
ENDF arena_reset

/* arena_destroy(arena) */
FUNC arena_destroy
    push %rbx
    mov %rdi, %rbx
    test %rdi, %rdi
    jz 1f
    call arena_reset
    mov %rbx, %rdi
    call free
1:  pop %rbx
    ret
ENDF arena_destroy

/* cur_arena() -> rax the arena for per-request allocations of this thread:
 * a parallel worker's own arena, else the request arena g_arena */
FUNC cur_arena
    mov %fs:t_arena@tpoff, %rax
    test %rax, %rax
    jnz 1f
    mov g_arena(%rip), %rax
1:  ret
ENDF cur_arena

/* tmp_alloc(size) -> ptr from the current request arena (cur_arena) */
FUNC tmp_alloc
    mov %rdi, %rsi
    mov %fs:t_arena@tpoff, %rdi
    test %rdi, %rdi
    jnz arena_alloc
    mov g_arena(%rip), %rdi
    jmp arena_alloc
ENDF tmp_alloc

FUNC tmp_zalloc
    mov %rdi, %rsi
    mov %fs:t_arena@tpoff, %rdi
    test %rdi, %rdi
    jnz arena_zalloc
    mov g_arena(%rip), %rdi
    jmp arena_zalloc
ENDF tmp_zalloc

/* ======================================================== pstr */

/* pstr_new(arena rdi, ptr rsi, len rdx) -> pstr* (copy, NUL terminated) */
FUNC pstr_new
    push %rbx
    push %r12
    push %r13
    mov %rsi, %r12
    mov %rdx, %r13
    lea 9(%rdx), %rsi
    call arena_alloc
    mov %rax, %rbx
    mov %r13, (%rbx)
    lea 8(%rbx), %rdi
    mov %r12, %rsi
    mov %r13, %rdx
    call memcpy
    movb $0, 8(%rbx, %r13)
    mov %rbx, %rax
    pop %r13
    pop %r12
    pop %rbx
    ret
ENDF pstr_new

/* pstr_tmp(ptr, len) -> pstr* in request arena */
FUNC pstr_tmp
    mov %rsi, %rdx
    mov %rdi, %rsi
    mov %fs:t_arena@tpoff, %rdi     /* cur_arena */
    test %rdi, %rdi
    jnz pstr_new
    mov g_arena(%rip), %rdi
    jmp pstr_new
ENDF pstr_tmp

/* ======================================================== string helpers */

/* mem_ieq(p1, l1, p2, l2) -> eax 1 if equal ignoring ASCII case */
FUNC mem_ieq
    xor %eax, %eax
    cmp %rsi, %rcx
    jne 9f
    xor %r8, %r8
1:  cmp %rsi, %r8
    jae 8f
    movzbl (%rdi, %r8), %r9d
    movzbl (%rdx, %r8), %r10d
    lea -'A'(%r9), %r11d
    cmp $25, %r11d
    ja 2f
    or $0x20, %r9d
2:  lea -'A'(%r10), %r11d
    cmp $25, %r11d
    ja 3f
    or $0x20, %r10d
3:  cmp %r9d, %r10d
    jne 9f
    inc %r8
    jmp 1b
8:  mov $1, %eax
9:  ret
ENDF mem_ieq

/* mem_icmp(p1, l1, p2, l2) -> eax <0,0,>0 comparing ASCII-lowercased bytes */
FUNC mem_icmp
    xor %r8, %r8
1:  cmp %rsi, %r8
    jae 7f
    cmp %rcx, %r8
    jae 6f
    movzbl (%rdi, %r8), %r9d
    movzbl (%rdx, %r8), %r10d
    lea -'A'(%r9), %r11d
    cmp $25, %r11d
    ja 2f
    or $0x20, %r9d
2:  lea -'A'(%r10), %r11d
    cmp $25, %r11d
    ja 3f
    or $0x20, %r10d
3:  sub %r10d, %r9d
    jnz 5f
    inc %r8
    jmp 1b
5:  mov %r9d, %eax
    ret
6:  mov $1, %eax                    /* p1 longer */
    ret
7:  xor %eax, %eax
    cmp %rcx, %rsi
    je 8f
    mov $-1, %eax                   /* p1 shorter */
8:  ret
ENDF mem_icmp

/* mem_cmp(p1, l1, p2, l2) -> eax -1/0/1, bytewise unsigned then by length */
FUNC mem_cmp
    push %rbx
    push %r12
    push %r13
    mov %rsi, %rbx
    mov %rcx, %r12
    mov %rdx, %rsi
    mov %rbx, %rdx
    cmp %r12, %rdx
    cmova %r12, %rdx
    call memcmp
    test %eax, %eax
    jnz 2f
    cmp %r12, %rbx
    je 3f
    mov $-1, %eax
    jb 3f
    mov $1, %eax
    jmp 3f
2:  sar $31, %eax
    or $1, %eax
3:  pop %r13
    pop %r12
    pop %rbx
    ret
ENDF mem_cmp

/* pstr_cmp(a, b) -> eax -1/0/1 */
FUNC pstr_cmp
    lea 8(%rdi), %rax
    mov (%rdi), %rcx
    lea 8(%rsi), %rdx
    mov %rax, %rdi
    mov (%rsi), %r8
    mov %rcx, %rsi
    mov %r8, %rcx
    jmp mem_cmp
ENDF pstr_cmp

/* pstr_ieq(a, b) -> eax */
FUNC pstr_ieq
    lea 8(%rdi), %rax
    mov (%rdi), %r8
    lea 8(%rsi), %rdx
    mov (%rsi), %rcx
    mov %rax, %rdi
    mov %r8, %rsi
    jmp mem_ieq
ENDF pstr_ieq

/* cstr_ieq(ptr, len, cstr) -> eax: case-insensitive equality with a C string */
FUNC cstr_ieq
    push %rbx
    push %r12
    push %r13
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rdx, %rdi
    call strlen
    mov %rax, %rcx
    mov %rbx, %rdi
    mov %r12, %rsi
    mov %r13, %rdx
    call mem_ieq
    pop %r13
    pop %r12
    pop %rbx
    ret
ENDF cstr_ieq

/* ======================================================== Buf */

/* buf_init(buf) */
FUNC buf_init
    movq $0, BUF_DATA(%rdi)
    movq $0, BUF_LEN(%rdi)
    movq $0, BUF_CAP(%rdi)
    ret
ENDF buf_init

/* buf_free(buf) */
FUNC buf_free
    push %rbx
    mov %rdi, %rbx
    mov BUF_DATA(%rdi), %rdi
    call free
    mov %rbx, %rdi
    call buf_init
    pop %rbx
    ret
ENDF buf_free

/* buf_reserve(buf, n): ensure room for n more bytes (+1 for a NUL) */
FUNC buf_reserve
    mov BUF_LEN(%rdi), %rax
    lea 1(%rax, %rsi), %rax
    cmp BUF_CAP(%rdi), %rax
    ja 1f
    ret
1:  push %rbx
    push %r12
    sub $8, %rsp
    mov %rdi, %rbx
    mov BUF_CAP(%rbx), %r12
    add %r12, %r12
    cmp $256, %r12
    jae 2f
    mov $256, %r12
2:  cmp %rax, %r12
    jae 3f
    mov %rax, %r12
3:  mov BUF_DATA(%rbx), %rdi
    mov %r12, %rsi
    call xrealloc
    mov %rax, BUF_DATA(%rbx)
    mov %r12, BUF_CAP(%rbx)
    add $8, %rsp
    pop %r12
    pop %rbx
    ret
ENDF buf_reserve

/* buf_put(buf, ptr, len) */
FUNC buf_put
    push %rbx
    push %r12
    push %r13
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rdx, %rsi
    call buf_reserve
    mov BUF_DATA(%rbx), %rdi
    add BUF_LEN(%rbx), %rdi
    mov %r12, %rsi
    mov %r13, %rdx
    call memcpy
    add %r13, BUF_LEN(%rbx)
    pop %r13
    pop %r12
    pop %rbx
    ret
ENDF buf_put

/* buf_putc(buf, c) */
FUNC buf_putc
    mov BUF_LEN(%rdi), %rax
    inc %rax
    cmp BUF_CAP(%rdi), %rax
    jae 1f
    mov BUF_DATA(%rdi), %rdx
    mov %sil, -1(%rdx, %rax)
    mov %rax, BUF_LEN(%rdi)
    ret
1:  push %rbx
    push %r12
    sub $8, %rsp
    mov %rdi, %rbx
    mov %esi, %r12d
    mov $1, %esi
    call buf_reserve
    mov BUF_LEN(%rbx), %rax
    mov BUF_DATA(%rbx), %rdx
    mov %r12b, (%rdx, %rax)
    incq BUF_LEN(%rbx)
    add $8, %rsp
    pop %r12
    pop %rbx
    ret
ENDF buf_putc

/* buf_puts(buf, cstr) */
FUNC buf_puts
    push %rbx
    push %r12
    sub $8, %rsp
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rsi, %rdi
    call strlen
    mov %rbx, %rdi
    mov %r12, %rsi
    mov %rax, %rdx
    call buf_put
    add $8, %rsp
    pop %r12
    pop %rbx
    ret
ENDF buf_puts

/* buf_put_pstr(buf, pstr) */
FUNC buf_put_pstr
    mov (%rsi), %rdx
    add $8, %rsi
    jmp buf_put
ENDF buf_put_pstr

/* buf_put_u64(buf, v) */
FUNC buf_put_u64
    sub $40, %rsp
    lea 32(%rsp), %rcx              /* end of scratch */
    mov %rcx, %r8
    mov %rsi, %rax
    mov $10, %r9
1:  xor %edx, %edx
    div %r9
    add $'0', %dl
    dec %rcx
    mov %dl, (%rcx)
    test %rax, %rax
    jnz 1b
    mov %rcx, %rsi
    mov %r8, %rdx
    sub %rcx, %rdx
    call buf_put
    add $40, %rsp
    ret
ENDF buf_put_u64

/* buf_put_i64(buf, v) */
FUNC buf_put_i64
    test %rsi, %rsi
    jns buf_put_u64
    push %rbx
    push %r12
    sub $8, %rsp
    mov %rdi, %rbx
    mov %rsi, %r12
    mov $'-', %esi
    call buf_putc
    mov %rbx, %rdi
    mov %r12, %rsi
    neg %rsi                        /* INT64_MIN stays 0x8000.. = correct as unsigned */
    call buf_put_u64
    add $8, %rsp
    pop %r12
    pop %rbx
    ret
ENDF buf_put_i64

    .section .rodata
hexdigits: .ascii "0123456789abcdef"
    .text

/* buf_put_json_str(buf, ptr, len): writes a quoted, escaped JSON string */
FUNC buf_put_json_str
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    /* reserve worst case: 6 bytes per input byte + 2 quotes */
    lea (%rdx, %rdx, 2), %rsi
    add %rsi, %rsi
    add $2, %rsi
    call buf_reserve
    mov BUF_DATA(%rbx), %rdi
    add BUF_LEN(%rbx), %rdi         /* output cursor */
    movb $'"', (%rdi)
    inc %rdi
    xor %ecx, %ecx
    lea hexdigits(%rip), %r8
1:  cmp %r13, %rcx
    jae 9f
    movzbl (%r12, %rcx), %eax
    inc %rcx
    cmp $'"', %al
    je 3f
    cmp $'\\', %al
    je 3f
    cmp $0x20, %al
    jb 4f
2:  mov %al, (%rdi)
    inc %rdi
    jmp 1b
3:  movb $'\\', (%rdi)
    mov %al, 1(%rdi)
    add $2, %rdi
    jmp 1b
4:  cmp $'\n', %al
    jne 5f
    movw $0x6e5c, (%rdi)            /* \n */
    add $2, %rdi
    jmp 1b
5:  cmp $'\t', %al
    jne 6f
    movw $0x745c, (%rdi)            /* \t */
    add $2, %rdi
    jmp 1b
6:  cmp $'\r', %al
    jne 7f
    movw $0x725c, (%rdi)            /* \r */
    add $2, %rdi
    jmp 1b
7:  movl $0x3030755c, (%rdi)        /* \u00 */
    mov %eax, %edx
    shr $4, %edx
    movzbl (%r8, %rdx), %edx
    mov %dl, 4(%rdi)
    mov %eax, %edx
    and $15, %edx
    movzbl (%r8, %rdx), %edx
    mov %dl, 5(%rdi)
    add $6, %rdi
    jmp 1b
9:  movb $'"', (%rdi)
    inc %rdi
    sub BUF_DATA(%rbx), %rdi
    mov %rdi, BUF_LEN(%rbx)
    LEAVE
ENDF buf_put_json_str

/* buf_put_json_pstr(buf, pstr) */
FUNC buf_put_json_pstr
    mov (%rsi), %rdx
    add $8, %rsi
    jmp buf_put_json_str
ENDF buf_put_json_pstr

/* ======================================================== Vec (u64 elements, arena-backed) */

/* vec_init(vec, arena) */
FUNC vec_init
    movq $0, VEC_DATA(%rdi)
    movq $0, VEC_LEN(%rdi)
    movq $0, VEC_CAP(%rdi)
    mov %rsi, VEC_ARENA(%rdi)
    ret
ENDF vec_init

/* vec_new(arena) -> Vec* allocated in arena */
FUNC vec_new
    push %rbx
    mov %rdi, %rbx
    mov $VEC_SIZE, %esi
    call arena_alloc
    mov %rax, %rdi
    mov %rbx, %rsi
    call vec_init
    mov %rax, %rax
    pop %rbx
    ret
ENDF vec_new

/* vec_push(vec, value) */
FUNC vec_push
    mov VEC_LEN(%rdi), %rax
    cmp VEC_CAP(%rdi), %rax
    jae 1f
    mov VEC_DATA(%rdi), %rdx
    mov %rsi, (%rdx, %rax, 8)
    inc %rax
    mov %rax, VEC_LEN(%rdi)
    ret
1:  push %rbx
    push %r12
    push %r13
    mov %rdi, %rbx
    mov %rsi, %r12
    mov VEC_CAP(%rbx), %r13
    add %r13, %r13
    cmp $8, %r13
    jae 2f
    mov $8, %r13
2:  mov VEC_ARENA(%rbx), %rdi
    lea (,%r13,8), %rsi
    call arena_alloc
    mov %rax, %rdi
    mov VEC_DATA(%rbx), %rsi
    mov VEC_LEN(%rbx), %rdx
    shl $3, %rdx
    mov %rax, VEC_DATA(%rbx)
    call memcpy
    mov %r13, VEC_CAP(%rbx)
    mov VEC_LEN(%rbx), %rax
    mov VEC_DATA(%rbx), %rdx
    mov %r12, (%rdx, %rax, 8)
    incq VEC_LEN(%rbx)
    pop %r13
    pop %r12
    pop %rbx
    ret
ENDF vec_push

/* ======================================================== time */

/* now_ns() -> rax monotonic nanoseconds */
FUNC now_ns
    sub $24, %rsp
    mov $1, %edi                    /* CLOCK_MONOTONIC */
    mov %rsp, %rsi
    call clock_gettime
    mov (%rsp), %rax
    imul $1000000000, %rax, %rax
    add 8(%rsp), %rax
    add $24, %rsp
    ret
ENDF now_ns

/* check_deadline(): raises CANCELLED when the query was cancelled (server
 * child: SIGUSR1) and TIMEOUT when the current query deadline has passed */
FUNC check_deadline
    cmpq $0, g_cancel_flag(%rip)
    jne 3f
    cmpq $0, g_deadline_ns(%rip)
    jne 1f
    ret
1:  sub $8, %rsp
    call now_ns
    add $8, %rsp
    cmp g_deadline_ns(%rip), %rax
    jae 2f
    ret
2:  sub $8, %rsp
    RAISE E_TIMEOUT, "query timeout exceeded"
3:  sub $8, %rsp
    RAISE E_CANCELLED, "query cancelled"
ENDF check_deadline
