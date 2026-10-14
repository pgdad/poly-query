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
    .globl g_par_mem
g_par_mem:          .quad 0        /* chunk bytes of the worker arenas (AR_PAR), reset by par_reset */

    .bss
    .p2align 4
    .globl g_err_msg
g_err_msg:          .zero 512

/* Thread-local overrides used by parallel workers (par.S): a worker
 * allocates from its own arena and reports errors to its own handler.
 * Both are 0 on every other thread, which then uses the globals. */
    .section .tbss, "awT", @nobits
    .p2align 4
    .globl t_arena, t_jmpbuf, t_err_code, t_err_msg, t_stack_lo
t_arena:    .zero 8
t_jmpbuf:   .zero 8
t_err_code: .zero 8
t_stack_lo: .zero 8            /* lowest safe %rsp of this thread (STACK_CHECK), 0 = unset */
t_err_msg:  .zero 512
t_tick:     .zero 8            /* deadline_tick calls of this thread */

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

/* ------------------------------------------------ arena chunk pool
 * Arena chunks are mmap'd directly (not malloc'd) and released chunks are
 * kept in a pool shared by all threads (spin lock) for later arenas: every
 * first touch of a fresh page faults and has the kernel zero it, and
 * unmapping a chunk shoots down its TLB entries on every CPU of the
 * process; with 10m-row tables a query's chunks run to gigabytes, and
 * mapping, faulting and unmapping them cost more than the query itself.
 *
 * A chunk starts with a 16-byte header: the next chunk of its arena (or of
 * the pool) and its real size.  Sizes are rounded up to size classes (four
 * per power of two, multiples of 2 MiB from 2 MiB on) so that the chunks a
 * query releases fit the next run of a query; a pooled chunk is reused for
 * requests of at least half its size.  A reused chunk serves exactly the
 * requested size, so arena accounting (AR_TOTAL, AR_LIMIT) does not depend
 * on the pool.
 *
 * Bound: the pool holds at most max(POOL_MIN, chunk_peak - chunk_live)
 * bytes, chunk_peak being the most chunk bytes ever in use at once.  Mapped
 * chunk memory (in use + pooled) thus never exceeds the larger of that peak
 * and POOL_MIN plus the chunks in use: the pool does not raise the peak
 * memory of the process.  When a fresh chunk would break the bound, the
 * least recently released chunks are unmapped first (pool_trim). */
#define POOL_MIN  (1024*1024*1024)
#define HUGE_PAGE (2*1024*1024)

    .data
    .p2align 3
pool_head:  .quad 0             /* free chunks, most recently released first */
pool_bytes: .quad 0
pool_lock:  .quad 0
chunk_live: .quad 0             /* bytes of chunks in use by arenas */
chunk_peak: .quad 0             /* highest chunk_live so far */
    .text

/* pool_acquire / pool_release: the pool's spin lock (leaf helpers) */
pool_acquire:
    mov $1, %eax
1:  xchg %rax, pool_lock(%rip)
    test %rax, %rax
    jz 2f
    pause
    mov $1, %eax
    jmp 1b
2:  ret
pool_release:
    movq $0, pool_lock(%rip)
    ret

/* chunk_class(size rdi) -> rax: the size class of a chunk of `size` bytes
 * (leaf: clobbers rcx, rdx) */
chunk_class:
    mov $CHUNK_MIN, %eax
    cmp %rax, %rdi
    jbe 9f
    lea -1(%rdi), %rax
    bsr %rax, %rcx                  /* 2^cl < size <= 2^(cl+1) */
    sub $1, %ecx
    mov $1, %edx
    shl %cl, %rdx                   /* step: a quarter of 2^(cl+1) */
    mov $HUGE_PAGE, %eax
    cmp %rax, %rdi
    jbe 1f
    cmp %rax, %rdx
    cmovb %rax, %rdx
1:  lea -1(%rdi, %rdx), %rax
    neg %rdx
    and %rdx, %rax
9:  ret

/* pool_trim() -> rax list of the chunks unlinked from the pool to keep it
 * within its bound (lock held; leaf: clobbers rcx, rdx, rsi, rdi, r8).
 * Keeps the most recently released chunks that fit the allowance. */
pool_trim:
    mov chunk_peak(%rip), %rax
    sub chunk_live(%rip), %rax
    jae 0f
    xor %eax, %eax
0:  mov $POOL_MIN, %ecx
    cmp %rcx, %rax
    cmovb %rcx, %rax                /* allowance */
    cmp %rax, pool_bytes(%rip)
    jbe 8f
    xor %r8d, %r8d                  /* unlinked chunks */
    xor %edx, %edx                  /* bytes kept */
    lea pool_head(%rip), %rcx       /* link to the current chunk */
1:  mov (%rcx), %rsi
    test %rsi, %rsi
    jz 3f
    mov 8(%rsi), %rdi
    add %rdx, %rdi
    cmp %rax, %rdi
    ja 2f
    mov %rdi, %rdx                  /* keep */
    mov %rsi, %rcx
    jmp 1b
2:  mov (%rsi), %rdi                /* unlink */
    mov %rdi, (%rcx)
    mov %r8, (%rsi)
    mov %rsi, %r8
    jmp 1b
3:  mov %rdx, pool_bytes(%rip)
    mov %r8, %rax
    ret
8:  xor %eax, %eax
    ret

/* chunk_unmap_list(list rdi): unmaps a list of chunks linked through
 * their headers */
chunk_unmap_list:
    push %rbx
    mov %rdi, %rbx
1:  test %rbx, %rbx
    jz 2f
    mov %rbx, %rdi
    mov 8(%rbx), %rsi
    mov (%rbx), %rbx
    call munmap
    jmp 1b
2:  pop %rbx
    ret

/* chunk_map(size rdi) -> rax a fresh anonymous mapping (-1 = failed).
 * Chunks of 2 MiB or more (their size classes are multiples of 2 MiB) are
 * 2 MiB-aligned and backed by transparent huge pages where the system
 * allows them on request (madvise mode): one fault per 2 MiB instead of
 * 512 and far fewer TLB misses in operators that hash or scatter over
 * hundreds of megabytes; a fork()ed `serve` child also copies one entry
 * per 2 MiB of table data instead of 512. */
chunk_map:
    push %rbx
    push %r12
    push %r13
    mov %rdi, %rbx                  /* size */
    xor %esi, %esi                  /* alignment slack */
    cmp $HUGE_PAGE, %rdi
    jb 1f
    mov $HUGE_PAGE, %esi
1:  mov %rsi, %r12
    add %rbx, %rsi
    xor %edi, %edi                  /* mmap(0, size + slack, PROT_READ|PROT_WRITE, */
    mov $3, %edx                    /* MAP_PRIVATE|MAP_ANONYMOUS, -1, 0) */
    mov $0x22, %ecx
    mov $-1, %r8d
    xor %r9d, %r9d
    call mmap
    cmp $-1, %rax
    je 9f
    test %r12, %r12
    jz 9f
    mov %rax, %r13                  /* the mapping */
    lea (HUGE_PAGE-1)(%rax), %r12
    and $-HUGE_PAGE, %r12           /* the aligned chunk */
    mov %r12, %rsi                  /* unmap the slack before ... */
    sub %r13, %rsi
    jz 2f
    mov %r13, %rdi
    call munmap
2:  lea (%r12, %rbx), %rdi          /* ... and after it */
    lea HUGE_PAGE(%r13, %rbx), %rsi
    sub %rdi, %rsi
    jz 3f
    call munmap
3:  mov %r12, %rdi
    mov %rbx, %rsi
    mov $14, %edx                   /* MADV_HUGEPAGE */
    call madvise
    mov %r12, %rax
9:  pop %r13
    pop %r12
    pop %rbx
    ret

/* chunk_get(size rdi) -> rax chunk of at least `size` bytes (header
 * included): the smallest pooled chunk of the size class or up to twice
 * its size, else a new one */
FUNC chunk_get
    push %rbx
    push %r12
    push %r13
    call chunk_class
    mov %rax, %rbx                  /* size class */
    call pool_acquire
    lea pool_head(%rip), %rcx       /* link to the current chunk */
    xor %r12d, %r12d                /* link to the best chunk */
    lea 1(%rbx, %rbx), %r13         /* its size (above the reuse limit) */
1:  mov (%rcx), %rax
    test %rax, %rax
    jz 3f
    mov 8(%rax), %rdx
    cmp %rbx, %rdx
    jb 2f
    cmp %r13, %rdx
    jae 2f
    mov %rcx, %r12
    mov %rdx, %r13
2:  mov %rax, %rcx
    jmp 1b
3:  test %r12, %r12
    jz 5f
    mov (%r12), %rax                /* unlink the best chunk */
    mov (%rax), %rdx
    mov %rdx, (%r12)
    sub %r13, pool_bytes(%rip)
    mov %rax, %r12
    mov %r13, %rbx
    call chunk_count
    call pool_release
    mov %r12, %rax
    jmp 9f
5:  call chunk_count
    call pool_trim
    mov %rax, %r12
    call pool_release
    mov %r12, %rdi
    call chunk_unmap_list
    mov %rbx, %rdi
    call chunk_map
    cmp $-1, %rax
    jne 6f
    call pool_acquire
    sub %rbx, chunk_live(%rip)
    call pool_release
    RAISE E_RESOURCE_LIMIT, "out of memory"
6:  mov %rbx, 8(%rax)
9:  pop %r13
    pop %r12
    pop %rbx
    ret
ENDF chunk_get

/* chunk_count: chunk_live += rbx, raising chunk_peak (lock held; leaf) */
chunk_count:
    mov chunk_live(%rip), %rax
    add %rbx, %rax
    mov %rax, chunk_live(%rip)
    cmp chunk_peak(%rip), %rax
    jbe 1f
    mov %rax, chunk_peak(%rip)
1:  ret

/* chunk_put(chunk rdi): keeps the chunk in the pool (unmapping the least
 * recently released chunks beyond the pool's bound) */
FUNC chunk_put
    push %rbx
    mov %rdi, %rbx
    call pool_acquire
    mov 8(%rbx), %rax
    sub %rax, chunk_live(%rip)
    add %rax, pool_bytes(%rip)
    mov pool_head(%rip), %rax
    mov %rax, (%rbx)
    mov %rbx, pool_head(%rip)
    call pool_trim
    mov %rax, %rbx
    call pool_release
    mov %rbx, %rdi
    call chunk_unmap_list
    pop %rbx
    ret
ENDF chunk_put

/* chunk_pool_forget(): drops the pool without freeing it (a fork()ed child:
 * another thread of the parent may have held the lock) */
FUNC chunk_pool_forget
    movq $0, pool_head(%rip)
    movq $0, pool_bytes(%rip)
    movq $0, pool_lock(%rip)
    ret
ENDF chunk_pool_forget

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
    /* limit check: a worker arena counts its chunks in g_par_mem and is
     * checked against the request total (request arena + all workers) */
    mov AR_TOTAL(%rbx), %rax
    add %r13, %rax
    mov AR_LIMIT(%rbx), %rcx
    test %rcx, %rcx
    jz 1f
    cmpq $0, AR_PAR(%rbx)
    jne 2f
    mov g_par_mem(%rip), %rdx       /* the request arena */
    add %rax, %rdx
    cmp %rcx, %rdx
    jbe 1f
    jmp 3f
2:  mov %r13, %rdx                  /* a worker arena */
    lock xadd %rdx, g_par_mem(%rip)
    add %r13, %rdx
    mov g_arena(%rip), %r8
    add AR_TOTAL(%r8), %rdx
    cmp %rcx, %rdx
    jbe 1f
    lock sub %r13, g_par_mem(%rip)
3:  RAISE E_RESOURCE_LIMIT, "query memory budget exceeded"
1:  mov %rax, AR_TOTAL(%rbx)
    mov %r13, %rdi
    call chunk_get
    mov AR_CHUNKS(%rbx), %rcx
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

/* arena_reset(arena): releases all chunks (to the chunk pool), keeps the
 * Arena object and its limit */
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
    call chunk_put
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

/* vec_reserve(vec rdi, cap rsi): capacity for at least `cap` elements */
FUNC vec_reserve
    cmp VEC_CAP(%rdi), %rsi
    jbe 9f
    push %rbx
    push %r12
    push %r13
    mov %rdi, %rbx
    mov %rsi, %r13
    mov VEC_ARENA(%rbx), %rdi
    lea (, %r13, 8), %rsi
    call arena_alloc
    mov %rax, %rdi
    mov VEC_DATA(%rbx), %rsi
    mov VEC_LEN(%rbx), %rdx
    shl $3, %rdx
    mov %rax, VEC_DATA(%rbx)
    call memcpy
    mov %r13, VEC_CAP(%rbx)
    pop %r13
    pop %r12
    pop %rbx
9:  ret
ENDF vec_reserve

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

/* deadline_tick(): check_deadline every DEADLINE_TICKS calls; called once
 * per node by the tree walkers of parsing, binding and planning, so that the
 * timeout also interrupts those stages (CR-6 §4) */
#define DEADLINE_TICKS 1024
FUNC deadline_tick                  /* preserves all registers but flags */
    incq %fs:t_tick@tpoff
    testq $(DEADLINE_TICKS - 1), %fs:t_tick@tpoff
    jz 1f
    ret
1:  push %rbp
    mov %rsp, %rbp
    and $-16, %rsp
    push %rax
    push %rcx
    push %rdx
    push %rsi
    push %rdi
    push %r8
    push %r9
    push %r10
    push %r11
    push %r11
    call check_deadline
    pop %r11
    pop %r11
    pop %r10
    pop %r9
    pop %r8
    pop %rdi
    pop %rsi
    pop %rdx
    pop %rcx
    pop %rax
    mov %rbp, %rsp                  /* (not `leave`: the LEAVE macro) */
    pop %rbp
    ret
ENDF deadline_tick

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

/* ======================================================== stack limits (CR-6) */

#define STACK_RESERVE  (1024*1024)     /* kept free below the STACK_CHECK limit */
#define ALT_STACK_SIZE (256*1024)

/* stack_set_bottom(lowest rdi): the calling thread's stack starts (lowest
 * usable address) at rdi; STACK_CHECK fails STACK_RESERVE bytes above it */
FUNC stack_set_bottom
    add $STACK_RESERVE, %rdi
    mov %rdi, %fs:t_stack_lo@tpoff
    ret
ENDF stack_set_bottom

/* thread_stack_init(): for a thread created by pthread_create: sets its
 * STACK_CHECK limit from its stack attributes and gives it an alternate
 * signal stack, so that a stack overflow that escapes the checks still
 * reaches the fault handler (main.S), which reports it as RESOURCE_LIMIT */
FUNC thread_stack_init
    ENTER 112
    call pthread_self
    mov %rax, %rdi
    lea 0(%rsp), %rsi               /* pthread_attr_t (56 bytes) */
    call pthread_getattr_np
    test %eax, %eax
    jnz 1f
    lea 0(%rsp), %rdi
    lea 64(%rsp), %rsi              /* stack address (lowest) */
    lea 72(%rsp), %rdx              /* stack size */
    call pthread_attr_getstack
    mov %eax, %ebx
    lea 0(%rsp), %rdi
    call pthread_attr_destroy
    test %ebx, %ebx
    jnz 1f
    mov 64(%rsp), %rdi
    call stack_set_bottom
1:  mov $ALT_STACK_SIZE, %edi
    call malloc
    test %rax, %rax
    jz 9f
    mov %rax, 80(%rsp)              /* stack_t.ss_sp */
    movl $0, 88(%rsp)               /* ss_flags */
    movq $ALT_STACK_SIZE, 96(%rsp)  /* ss_size */
    lea 80(%rsp), %rdi
    xor %esi, %esi
    call sigaltstack
9:  LEAVE
ENDF thread_stack_init

/* stack_exhausted(): target of STACK_CHECK (noreturn) */
FUNC stack_exhausted
    and $-16, %rsp
    RAISE E_RESOURCE_LIMIT, "statement too complex: stack exhausted (expression nesting depth or operand count)"
ENDF stack_exhausted
