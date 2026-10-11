/*
 * explain.S - EXPLAIN: renders a bound plan as the JSON plan tree of
 * indexes-and-planning.md §4.  Every node has "op" and "children".
 *
 *   explain_plan(plan rdi, buf rsi)
 *
 * Shape (outermost first, each present only when needed):
 *   Limit > Sort > Distinct > Project > Filter(HAVING) > Aggregate >
 *   Filter(WHERE) > FROM tree (TableScan | SubqueryScan | HashJoin |
 *   MergeJoin | NestedLoopJoin) or Values for a SELECT without FROM.
 */
#include "pq.inc"
#include "sql.inc"

    .section .note.GNU-stack, "", @progbits

    .section .rodata
jt_names:
    .quad 0, jt_inner, jt_left, jt_cross
jt_inner: .asciz "INNER"
jt_left:  .asciz "LEFT"
jt_cross: .asciz "CROSS"
    .p2align 3
ja_names:
    .quad ja_nl, ja_hash, ja_merge
ja_nl:    .asciz "NestedLoopJoin"
ja_hash:  .asciz "HashJoin"
ja_merge: .asciz "MergeJoin"

    .text

/* open_node(buf rdi, op cstr rsi): writes {"op":"<op>" */
FUNC open_node
    push %rbx
    push %r12
    sub $8, %rsp
    mov %rdi, %rbx
    mov %rsi, %r12
    PUTS %rbx, "{\"op\":\""
    mov %rbx, %rdi
    mov %r12, %rsi
    call buf_puts
    mov %rbx, %rdi
    mov $'"', %esi
    call buf_putc
    add $8, %rsp
    pop %r12
    pop %rbx
    ret
ENDF open_node

/* put_int_prop(buf rdi, key cstr rsi, value rdx): writes ,"key":value */
FUNC put_int_prop
    push %rbx
    push %r12
    push %r13
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    PUTS %rbx, ",\""
    mov %rbx, %rdi
    mov %r12, %rsi
    call buf_puts
    PUTS %rbx, "\":"
    mov %rbx, %rdi
    mov %r13, %rsi
    call buf_put_i64
    pop %r13
    pop %r12
    pop %rbx
    ret
ENDF put_int_prop

/* explain_from(buf rdi, plan rsi, fp rdx) */
FUNC explain_from
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    cmpq $FK_JOIN, FP_KIND(%r13)
    je 5f
    mov QP_RVS(%r12), %rax
    mov FP_RV(%r13), %rcx
    mov (%rax, %rcx, 8), %r14       /* rv */
    cmpq $0, FP_FILTER(%r13)        /* pushed-down WHERE conjuncts */
    je 81f
    mov %rbx, %rdi
    CSTR %rsi, "Filter"
    call open_node
    PUTS %rbx, ",\"predicate\":\"WHERE (pushed down)\",\"children\":["
81: cmpq $0, RV_TABLE(%r14)
    je 4f
    /* TableScan / IndexScan: catalog name and the columns actually read */
    cmpq $0, FP_INDEX(%r13)
    jne 82f
    mov %rbx, %rdi
    CSTR %rsi, "TableScan"
    call open_node
    jmp 83f
82: mov %rbx, %rdi
    CSTR %rsi, "IndexScan"
    call open_node
    PUTS %rbx, ",\"index\":"
    mov FP_INDEX(%r13), %rax
    mov IX_NAME(%rax), %rsi
    mov %rbx, %rdi
    call buf_put_json_pstr
    PUTS %rbx, ",\"kind\":\""
    mov FP_INDEX(%r13), %rax
    mov IX_KIND(%rax), %rdi
    call idx_kind_name
    mov %rbx, %rdi
    mov %rax, %rsi
    call buf_puts
    cmpq $IM_EQ, FP_IMODE(%r13)
    jne 821f
    PUTS %rbx, "\",\"lookup\":\"equality\""
    jmp 83f
821: PUTS %rbx, "\",\"lookup\":\"range\""
83: PUTS %rbx, ",\"table\":"
    mov RV_TABLE(%r14), %rax
    mov TB_NAME(%rax), %rsi
    mov %rbx, %rdi
    call buf_put_json_pstr
    cmpq $0, FP_RGSKIP(%r13)
    je 84f
    mov %rbx, %rdi
    CSTR %rsi, "row_groups_skipped"
    mov FP_NSKIP(%r13), %rdx
    call put_int_prop
84: mov %rbx, %rdi
    CSTR %rsi, "estimated_rows"
    mov FP_EST(%r13), %rdx
    call put_int_prop
    PUTS %rbx, ",\"alias\":"
    mov RV_NAME(%r14), %rsi
    mov %rbx, %rdi
    call buf_put_json_pstr
    PUTS %rbx, ",\"columns\":["
    xor %r15d, %r15d
    movq $0, 0(%rsp)                /* columns written */
1:  cmp RV_NCOLS(%r14), %r15
    jae 3f
    mov RV_USED(%r14), %rax
    cmpb $0, (%rax, %r15)
    je 2f
    cmpq $0, 0(%rsp)
    je 11f
    mov %rbx, %rdi
    mov $',', %esi
    call buf_putc
11: incq 0(%rsp)
    mov %r15, %rax
    shl $4, %rax
    add RV_COLS(%r14), %rax
    mov RVC_NAME(%rax), %rsi
    mov %rbx, %rdi
    call buf_put_json_pstr
2:  inc %r15
    jmp 1b
3:  PUTS %rbx, "],\"children\":[]}"
    jmp 49f
4:  /* derived table / CTE */
    mov %rbx, %rdi
    CSTR %rsi, "SubqueryScan"
    call open_node
    PUTS %rbx, ",\"alias\":"
    mov RV_NAME(%r14), %rsi
    mov %rbx, %rdi
    call buf_put_json_pstr
    PUTS %rbx, ",\"children\":["
    mov %rbx, %rsi
    mov RV_PLAN(%r14), %rdi
    call explain_plan
    PUTS %rbx, "]}"
49: cmpq $0, FP_FILTER(%r13)
    je 491f
    PUTS %rbx, "]}"
491: LEAVE
5:  /* join */
    lea ja_names(%rip), %rax
    mov FP_ALGO(%r13), %rcx
    mov (%rax, %rcx, 8), %rsi
    mov %rbx, %rdi
    call open_node
    PUTS %rbx, ",\"join_type\":\""
    lea jt_names(%rip), %rax
    mov FP_JTYPE(%r13), %rcx
    mov (%rax, %rcx, 8), %rsi
    mov %rbx, %rdi
    call buf_puts
    cmpq $JA_HASH, FP_ALGO(%r13)
    jne 7f
    cmpq $0, FP_BUILDL(%r13)
    jne 61f
    PUTS %rbx, "\",\"build\":\"right"
    jmp 7f
61: PUTS %rbx, "\",\"build\":\"left"
7:  PUTS %rbx, "\",\"children\":["
    mov %rbx, %rdi
    mov %r12, %rsi
    mov FP_LEFT(%r13), %rdx
    call explain_from
    mov %rbx, %rdi
    mov $',', %esi
    call buf_putc
    mov %rbx, %rdi
    mov %r12, %rsi
    mov FP_RIGHT(%r13), %rdx
    call explain_from
    PUTS %rbx, "]}"
    LEAVE
ENDF explain_from

/* explain_plan(plan rdi, buf rsi) */
FUNC explain_plan
    ENTER 16
    mov %rdi, %r12
    mov %rsi, %rbx
    xor %r13d, %r13d                /* wrappers opened */
    /* Limit */
    cmpq $0, QP_LIMIT(%r12)
    jge 1f
    cmpq $0, QP_OFFSET(%r12)
    je 2f
1:  mov %rbx, %rdi
    CSTR %rsi, "Limit"
    call open_node
    mov %rbx, %rdi
    CSTR %rsi, "limit"
    mov QP_LIMIT(%r12), %rdx
    call put_int_prop
    mov %rbx, %rdi
    CSTR %rsi, "offset"
    mov QP_OFFSET(%r12), %rdx
    call put_int_prop
    PUTS %rbx, ",\"children\":["
    inc %r13
2:  /* Sort */
    cmpq $0, QP_NKEYS(%r12)
    je 3f
    mov %rbx, %rdi
    CSTR %rsi, "Sort"
    call open_node
    mov %rbx, %rdi
    CSTR %rsi, "keys"
    mov QP_NKEYS(%r12), %rdx
    call put_int_prop
    PUTS %rbx, ",\"children\":["
    inc %r13
3:  /* Distinct */
    cmpq $0, QP_DISTINCT(%r12)
    je 4f
    mov %rbx, %rdi
    CSTR %rsi, "Distinct"
    call open_node
    PUTS %rbx, ",\"children\":["
    inc %r13
4:  /* Project */
    mov %rbx, %rdi
    CSTR %rsi, "Project"
    call open_node
    PUTS %rbx, ",\"columns\":["
    xor %r14d, %r14d
41: cmp QP_NOUT(%r12), %r14
    jae 42f
    test %r14, %r14
    jz 411f
    mov %rbx, %rdi
    mov $',', %esi
    call buf_putc
411: imul $OC_SIZE, %r14, %rax
    add QP_OUT(%r12), %rax
    mov OC_NAME(%rax), %rsi
    mov %rbx, %rdi
    call buf_put_json_pstr
    inc %r14
    jmp 41b
42: PUTS %rbx, "],\"children\":["
    inc %r13
    /* HAVING */
    cmpq $0, QP_HAVING(%r12)
    je 5f
    mov %rbx, %rdi
    CSTR %rsi, "Filter"
    call open_node
    PUTS %rbx, ",\"predicate\":\"HAVING\",\"children\":["
    inc %r13
5:  /* Aggregate */
    cmpq $0, QP_AGG(%r12)
    je 6f
    mov %rbx, %rdi
    CSTR %rsi, "Aggregate"
    call open_node
    mov %rbx, %rdi
    CSTR %rsi, "group_by"
    mov QP_NGROUP(%r12), %rdx
    call put_int_prop
    mov %rbx, %rdi
    CSTR %rsi, "aggregates"
    mov QP_NAGGS(%r12), %rdx
    call put_int_prop
    PUTS %rbx, ",\"children\":["
    inc %r13
6:  /* WHERE */
    cmpq $0, QP_WHERE(%r12)
    je 7f
    mov %rbx, %rdi
    CSTR %rsi, "Filter"
    call open_node
    PUTS %rbx, ",\"predicate\":\"WHERE\",\"children\":["
    inc %r13
7:  /* input */
    mov QP_FROM(%r12), %rdx
    test %rdx, %rdx
    jz 8f
    mov %rbx, %rdi
    mov %r12, %rsi
    call explain_from
    jmp 9f
8:  PUTS %rbx, "{\"op\":\"Values\",\"rows\":1,\"children\":[]}"
9:  test %r13, %r13
    jz 10f
    PUTS %rbx, "]}"
    dec %r13
    jmp 9b
10: LEAVE
ENDF explain_plan
