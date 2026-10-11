/*
 * test_json.S - unit tests for src/json.S (json_parse / json_write /
 * json_obj_get / json_is_int).
 *
 * Table cases are pairs of C strings: input, expected compact output; an
 * expected value of "!" means the input must be rejected.  Every table input
 * is copied to the very end of a page followed by a PROT_NONE guard page so
 * any read past the given length crashes the test.
 */
#include "pq.inc"

    .section .note.GNU-stack, "", @progbits

    .data
    .p2align 3
n_pass:     .quad 0
n_fail:     .quad 0
guard_page: .quad 0                 /* start of the readable page before the guard */

    .section .rodata
/* ---------------------------------------------------------------- table */
cases:
    /* literals, whitespace */
    .asciz "null"
    .asciz "null"
    .asciz "true"
    .asciz "true"
    .asciz "false"
    .asciz "false"
    .asciz " \t\r\n 42 \n"
    .asciz "42"
    .asciz "[]"
    .asciz "[]"
    .asciz "{}"
    .asciz "{}"
    .asciz "[ ]"
    .asciz "[]"
    .asciz "{ \n }"
    .asciz "{}"
    .asciz "[[]]"
    .asciz "[[]]"
    .asciz "[1,2,3]"
    .asciz "[1,2,3]"
    .asciz " [ 1 , [ 2 , { \"a\" : null } ] , { } ] "
    .asciz "[1,[2,{\"a\":null}],{}]"
    .asciz "{\"a\":1,\"a\":2}"
    .asciz "{\"a\":1,\"a\":2}"
    .asciz "{\"x\":[true,false,null],\"y\":{\"z\":\"w\"}}"
    .asciz "{\"x\":[true,false,null],\"y\":{\"z\":\"w\"}}"
    /* numbers */
    .asciz "0"
    .asciz "0"
    .asciz "-0"
    .asciz "-0"
    .asciz "0.5"
    .asciz "0.5"
    .asciz "-1.25e+10"
    .asciz "-1.25e+10"
    .asciz "1E5"
    .asciz "1E5"
    .asciz "1e-0"
    .asciz "1e-0"
    .asciz "10.0001E-007"
    .asciz "10.0001E-007"
    .asciz "123456789012345678901234567890"
    .asciz "123456789012345678901234567890"
    .asciz "[0,-0,0.0,-0.0e0]"
    .asciz "[0,-0,0.0,-0.0e0]"
    /* strings */
    .asciz "\"\""
    .asciz "\"\""
    .asciz "\"abc\""
    .asciz "\"abc\""
    .asciz "\"\\\"\\\\\\/\\b\\f\\n\\r\\t\""
    .asciz "\"\\\"\\\\/\\u0008\\u000c\\n\\r\\t\""
    .asciz "\"\\u0041\\u00e9\""
    .asciz "\"A\303\251\""
    .asciz "\"\\u00E9\""
    .asciz "\"\303\251\""
    .asciz "\"\\u20AC\""
    .asciz "\"\342\202\254\""
    .asciz "\"\\uD83D\\uDE00\""
    .asciz "\"\360\237\230\200\""
    .asciz "\"\\ud83d\\ude00x\""
    .asciz "\"\360\237\230\200x\""
    .asciz "\"\\uDBFF\\uDFFF\""
    .asciz "\"\364\217\277\277\""
    .asciz "\"\303\251\342\202\254\360\237\230\200\""
    .asciz "\"\303\251\342\202\254\360\237\230\200\""
    .asciz "\"a\\u0000b\""
    .asciz "\"a\\u0000b\""
    .asciz "\"\\u001f\""
    .asciz "\"\\u001f\""
    .asciz "\"\\u007f\177\""
    .asciz "\"\177\177\""
    .asciz "\"\\uFFFF\""
    .asciz "\"\357\277\277\""
    .asciz "{\"k\\u00e9\\n\":\"v\"}"
    .asciz "{\"k\303\251\\n\":\"v\"}"
    .asciz "[\"a,b\",\"]\",\"}\"]"
    .asciz "[\"a,b\",\"]\",\"}\"]"

    /* ---- invalid */
    .asciz ""
    .asciz "!"
    .asciz " "
    .asciz "!"
    .asciz "\r\n"
    .asciz "!"
    .asciz "["
    .asciz "!"
    .asciz "]"
    .asciz "!"
    .asciz "{"
    .asciz "!"
    .asciz "}"
    .asciz "!"
    .asciz "[1,]"
    .asciz "!"
    .asciz "[,1]"
    .asciz "!"
    .asciz "[,]"
    .asciz "!"
    .asciz "[1,,2]"
    .asciz "!"
    .asciz "[1,2"
    .asciz "!"
    .asciz "[1 2]"
    .asciz "!"
    .asciz "[[]"
    .asciz "!"
    .asciz "[]]"
    .asciz "!"
    .asciz "{\"a\":1,}"
    .asciz "!"
    .asciz "{,}"
    .asciz "!"
    .asciz "{\"a\"}"
    .asciz "!"
    .asciz "{\"a\" 1}"
    .asciz "!"
    .asciz "{\"a\":}"
    .asciz "!"
    .asciz "{a:1}"
    .asciz "!"
    .asciz "{1:1}"
    .asciz "!"
    .asciz "{'a':1}"
    .asciz "!"
    .asciz "{\"a\":1}}"
    .asciz "!"
    .asciz "{\"a\":1]"
    .asciz "!"
    .asciz "[1}"
    .asciz "!"
    .asciz "1 2"
    .asciz "!"
    .asciz "[] []"
    .asciz "!"
    .asciz "01"
    .asciz "!"
    .asciz "-01"
    .asciz "!"
    .asciz "00"
    .asciz "!"
    .asciz "+1"
    .asciz "!"
    .asciz "1."
    .asciz "!"
    .asciz "1.e5"
    .asciz "!"
    .asciz ".5"
    .asciz "!"
    .asciz "-.5"
    .asciz "!"
    .asciz "1e"
    .asciz "!"
    .asciz "1e+"
    .asciz "!"
    .asciz "1E-"
    .asciz "!"
    .asciz "-"
    .asciz "!"
    .asciz "--1"
    .asciz "!"
    .asciz "0x10"
    .asciz "!"
    .asciz "1e5.5"
    .asciz "!"
    .asciz "NaN"
    .asciz "!"
    .asciz "Infinity"
    .asciz "!"
    .asciz "-Infinity"
    .asciz "!"
    .asciz "tru"
    .asciz "!"
    .asciz "fals"
    .asciz "!"
    .asciz "nul"
    .asciz "!"
    .asciz "truex"
    .asciz "!"
    .asciz "nulll"
    .asciz "!"
    .asciz "True"
    .asciz "!"
    .asciz "/* c */ 1"
    .asciz "!"
    .asciz "1 // c"
    .asciz "!"
    .asciz "[1]//"
    .asciz "!"
    .asciz "\"abc"
    .asciz "!"
    .asciz "\""
    .asciz "!"
    .asciz "\"\\"
    .asciz "!"
    .asciz "\"\\\""
    .asciz "!"
    .asciz "\"\\u"
    .asciz "!"
    .asciz "\"\\u12\""
    .asciz "!"
    .asciz "\"\\u12"
    .asciz "!"
    .asciz "\"\\uZZZZ\""
    .asciz "!"
    .asciz "\"\\u00g0\""
    .asciz "!"
    .asciz "\"\\x\""
    .asciz "!"
    .asciz "\"\\U0041\""
    .asciz "!"
    .asciz "\"\\'\""
    .asciz "!"
    .asciz "\"\\uD83D\""
    .asciz "!"
    .asciz "\"\\uD83Dx\""
    .asciz "!"
    .asciz "\"\\uD83D\\u0041\""
    .asciz "!"
    .asciz "\"\\uD83D\\uD83D\""
    .asciz "!"
    .asciz "\"\\uDE00\""
    .asciz "!"
    .asciz "\"\\uDE00\\uD83D\""
    .asciz "!"
    .asciz "\"\\uD83D\\n\""
    .asciz "!"
    .asciz "\"a\tb\""
    .asciz "!"
    .asciz "\"a\nb\""
    .asciz "!"
    .asciz "\"\037\""
    .asciz "!"
    .asciz "\"\377\""
    .asciz "!"
    .asciz "\"\200\""
    .asciz "!"
    .asciz "\"\300\200\""
    .asciz "!"
    .asciz "\"\301\277\""
    .asciz "!"
    .asciz "\"\340\200\200\""
    .asciz "!"
    .asciz "\"\355\240\200\""
    .asciz "!"
    .asciz "\"\360\200\200\200\""
    .asciz "!"
    .asciz "\"\364\220\200\200\""
    .asciz "!"
    .asciz "\"\365\200\200\200\""
    .asciz "!"
    .asciz "\"\303\""
    .asciz "!"
    .asciz "\"\303"
    .asciz "!"
    .asciz "\"\342\202\""
    .asciz "!"
    .asciz "\"\303x\""
    .asciz "!"
    .asciz "\"\\\303\251\""
    .asciz "!"
    .asciz "\357\273\277{}"
    .asciz "!"
    .asciz "\f1"
    .asciz "!"
    .asciz "\v1"
    .asciz "!"
    .byte 0xff                      /* end of table */

/* raw NUL byte inside a string (5 bytes) */
nul_str: .ascii "\"a\000b\""

/* truncation document: every proper prefix must be rejected */
trunc_doc:
    .asciz "{\"a\":[1,-2.5e3,true,false,null,\"x\\u00e9\\uD83D\\uDE00\\n\303\251\"],\"b\":{\"c\":{}},\"d\":[],\"e\":0}"

    .text

/* t_assert(cond edi, msg rsi) */
t_assert:
    sub $8, %rsp
    test %edi, %edi
    jz 1f
    incq n_pass(%rip)
    add $8, %rsp
    ret
1:  incq n_fail(%rip)
    CSTR %rdi, "FAIL: %s\n"
    xor %eax, %eax
    call printf
    add $8, %rsp
    ret

/* CHECK cc, "msg": asserts that condition code cc holds */
.macro CHECK cc, msg
    set\cc %dil
    movzbl %dil, %edi
    CSTR %rsi, "\msg"
    call t_assert
.endm

/* pj(cstr) -> rax node* (parse a C string in g_arena) */
pj:
    push %rbx
    mov %rdi, %rbx
    call strlen
    mov %rbx, %rdi
    mov %rax, %rsi
    mov g_arena(%rip), %rdx
    call json_parse
    pop %rbx
    ret

/* check_len(ptr rdi, len rsi, expected rdx or 0, guard ecx)
 * ecx != 0: copy the input to the end of the guarded page first (len <= 4096) */
check_len:
    ENTER 32                        /* 0..23: Buf */
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    test %ecx, %ecx
    jz 1f
    mov guard_page(%rip), %rdi
    add $4096, %rdi
    sub %r12, %rdi
    mov %rbx, %rsi
    mov %r12, %rdx
    mov %rdi, %rbx
    call memcpy
1:  mov %rbx, %rdi
    mov %r12, %rsi
    mov g_arena(%rip), %rdx
    call json_parse
    mov %rax, %r14
    test %r13, %r13
    jnz 3f
    test %r14, %r14
    jz 8f
    CSTR %rdi, "FAIL: accepted invalid input [%.*s]\n"
    mov %r12d, %esi
    mov %rbx, %rdx
    xor %eax, %eax
    call printf
    jmp 9f
3:  test %r14, %r14
    jnz 4f
    CSTR %rdi, "FAIL: rejected valid input [%.*s]\n"
    mov %r12d, %esi
    mov %rbx, %rdx
    xor %eax, %eax
    call printf
    jmp 9f
4:  mov %rsp, %rdi
    call buf_init
    mov %rsp, %rdi
    mov %r14, %rsi
    call json_write
    mov BUF_DATA(%rsp), %rdi
    mov BUF_LEN(%rsp), %rax
    movb $0, (%rdi, %rax)
    mov %r13, %rsi
    call strcmp
    test %eax, %eax
    jz 5f
    CSTR %rdi, "FAIL: [%.*s] wrote [%s] expected [%s]\n"
    mov %r12d, %esi
    mov %rbx, %rdx
    mov BUF_DATA(%rsp), %rcx
    mov %r13, %r8
    xor %eax, %eax
    call printf
    mov %rsp, %rdi
    call buf_free
    jmp 9f
5:  mov %rsp, %rdi
    call buf_free
8:  incq n_pass(%rip)
    LEAVE
9:  incq n_fail(%rip)
    LEAVE

/* run_table(): walk `cases` */
run_table:
    ENTER 0
    lea cases(%rip), %r12
1:  cmpb $0xff, (%r12)
    je 9f
    mov %r12, %rdi
    call strlen
    mov %rax, %r13                  /* input len */
    lea 1(%r12, %rax), %r14         /* expected */
    mov %r14, %rdi
    call strlen
    mov %rax, %r15
    mov %r14, %rdx
    cmp $1, %r15
    jne 2f
    cmpb $0x21, (%r14)              /* "!" = must fail */
    jne 2f
    xor %edx, %edx
2:  mov %r12, %rdi
    mov %r13, %rsi
    mov $1, %ecx
    call check_len
    lea 1(%r14, %r15), %r12
    jmp 1b
9:  LEAVE

/* nested(n rdi, kind esi: 0 = arrays, 1 = objects, closed edx) -> rax malloc'd cstr
 * arrays: "[" * n + "]" * n ; objects: "{\"a\":" * n + "0" + "}" * n
 * closed = 0 omits the closing part */
nested:
    ENTER 0
    mov %rdi, %r12
    mov %esi, %r13d
    mov %edx, %r14d
    lea 16(, %r12, 8), %rdi
    call malloc
    mov %rax, %rbx
    mov %rax, %rdi
    xor %ecx, %ecx
1:  cmp %r12, %rcx
    jae 3f
    test %r13d, %r13d
    jnz 2f
    movb $0x5b, (%rdi)
    inc %rdi
    inc %rcx
    jmp 1b
2:  movl $0x2261227b, (%rdi)        /* {"a" */
    movb $0x3a, 4(%rdi)             /* : */
    add $5, %rdi
    inc %rcx
    jmp 1b
3:  test %r14d, %r14d
    jz 6f
    test %r13d, %r13d
    jz 4f
    movb $0x30, (%rdi)
    inc %rdi
4:  xor %ecx, %ecx
5:  cmp %r12, %rcx
    jae 6f
    mov $0x5d, %eax
    test %r13d, %r13d
    jz 7f
    mov $0x7d, %eax
7:  mov %al, (%rdi)
    inc %rdi
    inc %rcx
    jmp 5b
6:  movb $0, (%rdi)
    mov %rbx, %rax
    LEAVE

/* depth_case(n, kind, closed, expect_ok) */
depth_case:
    ENTER 0
    mov %ecx, %r15d
    call nested
    mov %rax, %rbx
    mov %rax, %rdi
    call strlen
    mov %rbx, %rdi
    mov %rax, %rsi
    xor %edx, %edx
    test %r15d, %r15d
    jz 1f
    mov %rbx, %rdx                  /* compact input == expected output */
1:  xor %ecx, %ecx
    call check_len
    mov %rbx, %rdi
    call free
    LEAVE

/* ---------------------------------------------------------------- main */
FUNC main
    ENTER 64
    call arena_new
    mov %rax, g_arena(%rip)

    /* guard page */
    xor %edi, %edi
    mov $8192, %esi
    mov $3, %edx                    /* PROT_READ|PROT_WRITE */
    mov $0x22, %ecx                 /* MAP_PRIVATE|MAP_ANONYMOUS */
    mov $-1, %r8d
    xor %r9d, %r9d
    call mmap
    mov %rax, guard_page(%rip)
    lea 4096(%rax), %rdi
    mov $4096, %esi
    xor %edx, %edx                  /* PROT_NONE */
    call mprotect

    call run_table

    /* explicit length: trailing bytes beyond len are ignored */
    CSTR %rdi, "[1]xyz"
    mov $3, %esi
    CSTR %rdx, "[1]"
    mov $1, %ecx
    call check_len
    CSTR %rdi, " 7 , "
    mov $2, %esi
    CSTR %rdx, "7"
    mov $1, %ecx
    call check_len
    /* embedded raw NUL byte inside a string is a control character */
    lea nul_str(%rip), %rdi
    mov $5, %esi
    xor %edx, %edx
    mov $1, %ecx
    call check_len
    /* NULL pointer with zero length */
    xor %edi, %edi
    xor %esi, %esi
    xor %edx, %edx
    xor %ecx, %ecx
    call check_len

    /* every proper prefix of trunc_doc is invalid, the whole doc valid */
    lea trunc_doc(%rip), %rdi
    call strlen
    mov %rax, %r12
    xor %r13d, %r13d
1:  cmp %r12, %r13
    jae 2f
    lea trunc_doc(%rip), %rdi
    mov %r13, %rsi
    xor %edx, %edx
    mov $1, %ecx
    call check_len
    inc %r13
    jmp 1b
2:  lea trunc_doc(%rip), %rdi
    call pj
    test %rax, %rax
    CHECK nz, "trunc_doc full parse"

    /* depth limit */
    mov $512, %edi
    xor %esi, %esi
    mov $1, %edx
    mov $1, %ecx
    call depth_case                 /* 512 arrays ok */
    mov $513, %edi
    xor %esi, %esi
    mov $1, %edx
    xor %ecx, %ecx
    call depth_case                 /* 513 arrays rejected */
    mov $512, %edi
    mov $1, %esi
    mov $1, %edx
    mov $1, %ecx
    call depth_case                 /* 512 objects ok */
    mov $513, %edi
    mov $1, %esi
    mov $1, %edx
    xor %ecx, %ecx
    call depth_case                 /* 513 objects rejected */
    mov $200000, %edi
    xor %esi, %esi
    xor %edx, %edx
    xor %ecx, %ecx
    call depth_case                 /* 200000 unclosed [ */
    mov $200000, %edi
    xor %esi, %esi
    mov $1, %edx
    xor %ecx, %ecx
    call depth_case                 /* 200000 deep, closed */

    /* ---- json_obj_get and DOM layout */
    CSTR %rdi, "{\"a\":1,\"b\":[true],\"a\":2,\"k\\u00e9\":\"v\\n\",\"\":3.5}"
    call pj
    mov %rax, %rbx
    test %rbx, %rbx
    CHECK nz, "obj parse"
    test %rbx, %rbx
    jz 10f
    cmpq $J_OBJECT, JN_TYPE(%rbx)
    CHECK e, "obj type"
    cmpq $5, JN_LEN(%rbx)
    CHECK e, "obj member count incl duplicate"
    mov JN_PTR(%rbx), %rax
    mov JM_KEY+2*JM_SIZE(%rax), %rcx
    cmpq $1, -8(%rcx)
    CHECK e, "dup key pstr len"
    cmpb $0x61, (%rcx)
    CHECK e, "dup key byte"
    cmpb $0, 1(%rcx)
    CHECK e, "key NUL terminated"
    mov JM_VAL+2*JM_SIZE(%rax), %rcx
    mov JN_PTR(%rcx), %rcx
    cmpb $0x32, (%rcx)
    CHECK e, "dup value kept in order"

    mov %rbx, %rdi
    CSTR %rsi, "a"
    call json_obj_get
    mov %rax, %r12
    test %r12, %r12
    CHECK nz, "get a"
    test %r12, %r12
    jz 11f
    cmpq $J_NUMBER, JN_TYPE(%r12)
    CHECK e, "get a type"
    mov JN_PTR(%r12), %rax
    cmpb $0x31, (%rax)
    CHECK e, "get a returns first duplicate"
    mov %r12, %rdi
    call json_is_int
    cmp $1, %eax
    CHECK e, "is_int 1"
    cmp $1, %rdx
    CHECK e, "is_int value 1"
11:
    mov %rbx, %rdi
    CSTR %rsi, "b"
    call json_obj_get
    mov %rax, %r12
    test %r12, %r12
    jz 12f
    cmpq $J_ARRAY, JN_TYPE(%r12)
    CHECK e, "get b array"
    cmpq $1, JN_LEN(%r12)
    CHECK e, "get b len"
    mov JN_PTR(%r12), %rax
    mov (%rax), %rax
    cmpq $J_TRUE, JN_TYPE(%rax)
    CHECK e, "get b[0] true"
    mov %r12, %rdi
    CSTR %rsi, "a"
    call json_obj_get
    test %rax, %rax
    CHECK z, "get on array -> 0"
12:
    mov %rbx, %rdi
    CSTR %rsi, "k\303\251"
    call json_obj_get
    mov %rax, %r12
    test %r12, %r12
    CHECK nz, "get utf8 key"
    test %r12, %r12
    jz 13f
    cmpq $J_STRING, JN_TYPE(%r12)
    CHECK e, "utf8 key value string"
    cmpq $2, JN_LEN(%r12)
    CHECK e, "string len"
    mov JN_PTR(%r12), %rax
    cmpq $2, -8(%rax)
    CHECK e, "string pstr prefix"
    mov JN_PTR(%r12), %rax
    cmpb $0x0a, 1(%rax)
    CHECK e, "string escape decoded"
    mov JN_PTR(%r12), %rax
    cmpb $0, 2(%rax)
    CHECK e, "string NUL terminated"
13:
    mov %rbx, %rdi
    CSTR %rsi, ""
    call json_obj_get
    mov %rax, %r12
    test %r12, %r12
    CHECK nz, "get empty key"
    test %r12, %r12
    jz 14f
    mov %r12, %rdi
    call json_is_int
    test %eax, %eax
    CHECK z, "is_int 3.5 -> 0"
    testq $1, JN_FLAGS(%r12)
    CHECK nz, "3.5 flag"
14:
    mov %rbx, %rdi
    CSTR %rsi, "c"
    call json_obj_get
    test %rax, %rax
    CHECK z, "get missing"
    mov %rbx, %rdi
    CSTR %rsi, "A"
    call json_obj_get
    test %rax, %rax
    CHECK z, "get case sensitive"
    mov %rbx, %rdi
    CSTR %rsi, "aa"
    call json_obj_get
    test %rax, %rax
    CHECK z, "get longer key"
    mov %rbx, %rdi
    CSTR %rsi, "k"
    call json_obj_get
    test %rax, %rax
    CHECK z, "get prefix key"
10:
    xor %edi, %edi
    CSTR %rsi, "a"
    call json_obj_get
    test %rax, %rax
    CHECK z, "get on NULL"

    /* ---- json_is_int */
    CSTR %rdi, "9223372036854775807"
    call pj
    mov %rax, %rdi
    call json_is_int
    mov %rdx, %rbx
    cmp $1, %eax
    CHECK e, "is_int max"
    mov $0x7fffffffffffffff, %rax
    cmp %rax, %rbx
    CHECK e, "is_int max value"
    CSTR %rdi, "-9223372036854775808"
    call pj
    mov %rax, %rdi
    call json_is_int
    mov %rdx, %rbx
    cmp $1, %eax
    CHECK e, "is_int min"
    mov $0x8000000000000000, %rax
    cmp %rax, %rbx
    CHECK e, "is_int min value"
    CSTR %rdi, "9223372036854775808"
    call pj
    mov %rax, %rdi
    call json_is_int
    test %eax, %eax
    CHECK z, "is_int max+1"
    CSTR %rdi, "-9223372036854775809"
    call pj
    mov %rax, %rdi
    call json_is_int
    test %eax, %eax
    CHECK z, "is_int min-1"
    CSTR %rdi, "99999999999999999999999"
    call pj
    mov %rax, %rdi
    call json_is_int
    test %eax, %eax
    CHECK z, "is_int huge"
    CSTR %rdi, " -42 "
    call pj
    mov %rax, %rdi
    call json_is_int
    mov %rdx, %rbx
    cmp $1, %eax
    CHECK e, "is_int -42"
    cmp $-42, %rbx
    CHECK e, "is_int -42 value"
    CSTR %rdi, "-0"
    call pj
    mov %rax, %rdi
    call json_is_int
    mov %rdx, %rbx
    cmp $1, %eax
    CHECK e, "is_int -0"
    test %rbx, %rbx
    CHECK z, "is_int -0 value"
    CSTR %rdi, "1e2"
    call pj
    mov %rax, %rbx
    mov %rax, %rdi
    call json_is_int
    test %eax, %eax
    CHECK z, "is_int 1e2"
    testq $1, JN_FLAGS(%rbx)
    CHECK nz, "1e2 flag"
    CSTR %rdi, "1E2"
    call pj
    testq $1, JN_FLAGS(%rax)
    CHECK nz, "1E2 flag"
    CSTR %rdi, "120"
    call pj
    mov %rax, %rbx
    testq $1, JN_FLAGS(%rbx)
    CHECK z, "120 no flag"
    mov JN_PTR(%rbx), %rax
    cmpq $3, -8(%rax)
    CHECK e, "number pstr prefix"
    mov JN_PTR(%rbx), %rax
    cmpb $0, 3(%rax)
    CHECK e, "number NUL terminated"
    cmpq $3, JN_LEN(%rbx)
    CHECK e, "number len"
    CSTR %rdi, "\"5\""
    call pj
    mov %rax, %rdi
    call json_is_int
    test %eax, %eax
    CHECK z, "is_int string"
    xor %edi, %edi
    call json_is_int
    test %eax, %eax
    CHECK z, "is_int NULL"
    CSTR %rdi, "\"a\\u0000b\""
    call pj
    cmpq $3, JN_LEN(%rax)
    CHECK e, "embedded NUL len"
    mov JN_PTR(%rax), %rax
    cmpb $0, 1(%rax)
    CHECK e, "embedded NUL byte"

    call big_test

    mov n_fail(%rip), %rax
    test %rax, %rax
    jz 20f
    CSTR %rdi, "test_json: %ld failed, %ld passed\n"
    mov n_fail(%rip), %rsi
    mov n_pass(%rip), %rdx
    xor %eax, %eax
    call printf
    mov $1, %eax
    LEAVE
20: CSTR %rdi, "test_json: %ld passed\n"
    mov n_pass(%rip), %rsi
    xor %eax, %eax
    call printf
    xor %eax, %eax
    LEAVE
ENDF main

/* big_test: 100k objects, parse, inspect, round trip */
#define BIG_N 100000
big_test:
    ENTER 64                        /* 0: Buf in, 24: Buf out1 */
    lea 0(%rsp), %rdi
    call buf_init
    lea 24(%rsp), %rdi
    call buf_init
    lea 0(%rsp), %rbx
    mov %rbx, %rdi
    mov $0x5b, %esi
    call buf_putc
    xor %r12d, %r12d
1:  cmp $BIG_N, %r12
    jae 2f
    test %r12, %r12
    jz 3f
    PUTS %rbx, ",\n  "
3:  PUTS %rbx, "{\"id\": "
    mov %rbx, %rdi
    mov %r12, %rsi
    call buf_put_i64
    PUTS %rbx, ", \"name\":\"n\\u00e9\\\"q\", \"v\":[1.5e-3,true,null,{}], \"neg\":-"
    mov %rbx, %rdi
    mov %r12, %rsi
    call buf_put_i64
    mov %rbx, %rdi
    mov $0x7d, %esi
    call buf_putc
    inc %r12
    jmp 1b
2:  mov %rbx, %rdi
    mov $0x5d, %esi
    call buf_putc
    mov BUF_DATA(%rbx), %rdi
    mov BUF_LEN(%rbx), %rsi
    mov g_arena(%rip), %rdx
    call json_parse
    mov %rax, %r13
    test %r13, %r13
    CHECK nz, "big parse"
    test %r13, %r13
    jz 9f
    cmpq $BIG_N, JN_LEN(%r13)
    CHECK e, "big count"
    mov JN_PTR(%r13), %rax
    mov 8*(BIG_N-1)(%rax), %rdi
    CSTR %rsi, "neg"
    call json_obj_get
    mov %rax, %rdi
    call json_is_int
    mov %rdx, %r14
    cmp $1, %eax
    CHECK e, "big last neg is int"
    cmp $-(BIG_N-1), %r14
    CHECK e, "big last neg value"
    /* round trip: write, parse the output, write again, compare */
    lea 24(%rsp), %rdi
    mov %r13, %rsi
    call json_write
    mov 24+BUF_DATA(%rsp), %rdi
    mov 24+BUF_LEN(%rsp), %rsi
    mov g_arena(%rip), %rdx
    call json_parse
    mov %rax, %r14
    test %r14, %r14
    CHECK nz, "big reparse"
    test %r14, %r14
    jz 9f
    mov %rbx, %rdi                  /* reuse input buffer for second output */
    movq $0, BUF_LEN(%rbx)
    mov %r14, %rsi
    call json_write
    mov BUF_LEN(%rbx), %rax
    cmp 24+BUF_LEN(%rsp), %rax
    CHECK e, "big round trip length"
    mov BUF_DATA(%rbx), %rdi
    mov 24+BUF_DATA(%rsp), %rsi
    mov BUF_LEN(%rbx), %rdx
    call memcmp
    test %eax, %eax
    CHECK z, "big round trip bytes"
9:  lea 0(%rsp), %rdi
    call buf_free
    lea 24(%rsp), %rdi
    call buf_free
    LEAVE
