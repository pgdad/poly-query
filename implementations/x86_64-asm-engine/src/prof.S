/*
 * prof.S - opt-in sampling profiler for engine development.
 *
 *   prof_start()  with PQ_PROF=FILE in the environment: samples the
 *       instruction pointer of the running thread every millisecond of
 *       process CPU time (ITIMER_PROF / SIGPROF) and writes one line per
 *       sample to FILE at exit: the address, the thread (its TLS base) and
 *       the time stamp counter, in hex.  Without PQ_PROF it does nothing.
 *
 * `bench/prof.sh FILE` maps the addresses to the engine's symbols (the
 * binary is not position independent) and prints a flat profile.
 */
#include "pq.inc"

    .section .note.GNU-stack, "", @progbits

#define PROF_MAX    (1 << 22)       /* samples kept */
#define PROF_REC    24              /* bytes per sample: rip, thread, tsc */
#define SIGPROF_    27
#define ITIMER_PROF_ 2
#define UC_RIP      168             /* ucontext_t: uc_mcontext.gregs[REG_RIP] */

    .data
    .p2align 3
prof_buf:  .quad 0
prof_n:    .quad 0
prof_path: .quad 0

    .text

/* prof_start() */
FUNC prof_start
    ENTER 192
    CSTR %rdi, "PQ_PROF"
    call getenv
    test %rax, %rax
    jz 9f
    mov %rax, prof_path(%rip)
    mov $(PROF_MAX * PROF_REC), %edi
    call xmalloc
    mov %rax, prof_buf(%rip)
    /* struct sigaction at 0(%rsp): handler, mask[128], flags, restorer */
    lea 0(%rsp), %rdi
    xor %esi, %esi
    mov $152, %edx
    call memset
    lea prof_handler(%rip), %rax
    mov %rax, 0(%rsp)
    movl $0x10000004, 136(%rsp)     /* SA_RESTART | SA_SIGINFO */
    mov $SIGPROF_, %edi
    lea 0(%rsp), %rsi
    xor %edx, %edx
    call sigaction
    lea prof_dump(%rip), %rdi
    call atexit
    /* struct itimerval at 160(%rsp): interval and first expiry 1 ms */
    movq $0, 160(%rsp)
    movq $1000, 168(%rsp)
    movq $0, 176(%rsp)
    movq $1000, 184(%rsp)
    mov $ITIMER_PROF_, %edi
    lea 160(%rsp), %rsi
    xor %edx, %edx
    call setitimer
9:  LEAVE
ENDF prof_start

/* prof_handler(sig, siginfo, ucontext): records the interrupted RIP */
prof_handler:
    mov $1, %eax
    lock xadd %rax, prof_n(%rip)
    cmp $PROF_MAX, %rax
    jae 1f
    imul $PROF_REC, %rax, %rcx
    add prof_buf(%rip), %rcx
    mov UC_RIP(%rdx), %rdx
    mov %rdx, (%rcx)
    mov %fs:0, %rax
    mov %rax, 8(%rcx)
    rdtsc
    shl $32, %rdx
    or %rdx, %rax
    mov %rax, 16(%rcx)
1:  ret

/* prof_dump(): atexit handler writing the samples */
prof_dump:
    ENTER 0
    mov $ITIMER_PROF_, %edi         /* stop sampling */
    lea zero_itv(%rip), %rsi
    xor %edx, %edx
    call setitimer
    mov prof_path(%rip), %rdi
    CSTR %rsi, "w"
    call fopen
    test %rax, %rax
    jz 9f
    mov %rax, %rbx
    mov prof_n(%rip), %r12
    mov $PROF_MAX, %eax
    cmp %rax, %r12
    cmova %rax, %r12
    xor %r13d, %r13d
1:  cmp %r12, %r13
    jae 2f
    imul $PROF_REC, %r13, %rax
    add prof_buf(%rip), %rax
    mov (%rax), %rdx
    mov 8(%rax), %rcx
    mov 16(%rax), %r8
    mov %rbx, %rdi
    CSTR %rsi, "%lx %lx %lx\n"
    xor %eax, %eax
    call fprintf
    inc %r13
    jmp 1b
2:  mov %rbx, %rdi
    call fclose
9:  LEAVE

    .section .rodata
    .p2align 3
zero_itv: .quad 0, 0, 0, 0
