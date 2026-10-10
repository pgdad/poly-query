/* TEST TOOL (not part of libpqkernels; not matched by the Makefile's
 * x86_64/*.S wildcard). uint64_t abi_call(void *fn, const uint64_t args[7], uint64_t out[2])
 * returns violation bits: 1<<k callee-saved reg k changed (rbx,rbp,r12..r15),
 * 64 = rsp changed, 128 = DF set, 256 = upper YMM/ZMM state dirty. */
        .bss
        .p2align 3
saved_rsp: .quad 0
        .text
        .globl abi_call
abi_call:
        push %rbx
        push %rbp
        push %r12
        push %r13
        push %r14
        push %r15
        push %rdx                  /* out ptr; rsp = 8 mod 16 */
        mov %rdi, %r11
        mov %rsi, %r10
        push 48(%r10)              /* 7th arg; rsp = 0 mod 16 at call */
        mov %rsp, saved_rsp(%rip)
        vzeroupper
        movabs $0x1111111111111111, %rbx
        movabs $0x2222222222222222, %rbp
        movabs $0x3333333333333333, %r12
        movabs $0x4444444444444444, %r13
        movabs $0x5555555555555555, %r14
        movabs $0x6666666666666666, %r15
        mov (%r10), %rdi
        mov 8(%r10), %rsi
        mov 16(%r10), %rdx
        mov 24(%r10), %rcx
        mov 32(%r10), %r8
        mov 40(%r10), %r9
        call *%r11
        movq %xmm0, %r9
        mov %rax, %r8
        xor %r10d, %r10d
        movabs $0x1111111111111111, %r11
        cmp %r11, %rbx
        je 1f
        or $1, %r10
1:      movabs $0x2222222222222222, %r11
        cmp %r11, %rbp
        je 1f
        or $2, %r10
1:      movabs $0x3333333333333333, %r11
        cmp %r11, %r12
        je 1f
        or $4, %r10
1:      movabs $0x4444444444444444, %r11
        cmp %r11, %r13
        je 1f
        or $8, %r10
1:      movabs $0x5555555555555555, %r11
        cmp %r11, %r14
        je 1f
        or $16, %r10
1:      movabs $0x6666666666666666, %r11
        cmp %r11, %r15
        je 1f
        or $32, %r10
1:      cmp saved_rsp(%rip), %rsp
        je 1f
        or $64, %r10
1:      pushf
        pop %r11
        bt $10, %r11
        jnc 1f
        or $128, %r10
1:      mov $1, %ecx
        xgetbv                     /* XINUSE */
        test $0x44, %eax           /* YMM_Hi128 | ZMM_Hi256 */
        jz 1f
        or $256, %r10
1:      mov saved_rsp(%rip), %rsp
        add $8, %rsp
        pop %rdx
        mov %r8, (%rdx)
        mov %r9, 8(%rdx)
        mov %r10, %rax
        pop %r15
        pop %r14
        pop %r13
        pop %r12
        pop %rbp
        pop %rbx
        ret
        .section .note.GNU-stack,"",@progbits
