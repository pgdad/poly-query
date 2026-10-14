/*
 * output.S - rendering of a query result as table, csv or json
 * (spec/apps/pqledger.md §7).
 *
 * Exported:
 *   out_result(pq_result* rdi)
 *        Appends the rendering of the result to g_out (util.S) in the
 *        format g_format (main.S: 0 table, 1 csv, 2 json).  The result is
 *        not freed.
 *
 * Value text (o_value_text) is produced without any per-cell allocation:
 * STRING values point straight into the result, everything else is
 * formatted into one static scratch buffer.  The table renderer stores all
 * cell texts in one ABUF (o_cells) with an offset array and computes the
 * column widths in the same pass, so a result is formatted once.
 *
 * Every function follows the System V AMD64 ABI.
 */
#include "app.inc"

    .section .note.GNU-stack, "", @progbits

/* ====================================================================== */
    .bss
    .p2align 4
o_tmp:      .zero 512           /* value text scratch (%.6f of 1e308 fits) */
o_cells:    .zero AB_SIZE       /* table: all cell texts; json: object keys */

    .section .rodata
o_spaces:   .ascii "                                                                "
o_dashes:   .ascii "----------------------------------------------------------------"
o_hex:      .ascii "0123456789abcdef"
o_true:     .ascii "true"
o_false:    .ascii "false"
o_null:     .ascii "null"

/* OUTS "text": append a constant string to g_out */
.macro OUTS msg
    lea g_out(%rip), %rdi
    CSTR %rsi, "\msg"
    call ab_puts
.endm

    .text

/* ======================================================================
 * out_result(res rdi): dispatch on g_format
 * ====================================================================== */
FUNC out_result
    mov g_format(%rip), %rax
    cmp $1, %rax
    je o_csv
    cmp $2, %rax
    je o_json
    jmp o_table
ENDF out_result

/* ======================================================================
 * small helpers
 * ====================================================================== */

/* o_col(res rdi, col rsi) -> rax pq_column* */
o_col:
    mov %rsi, %rax
    shl $PQ_COL_SHIFT, %rax
    add PQ_RES_COLUMNS(%rdi), %rax
    ret

/* o_col_type(res rdi, col rsi) -> eax PQ_TYPE_* */
o_col_type:
    call o_col
    movl PQ_COL_TYPE(%rax), %eax
    ret

/* o_is_numeric(res rdi, col rsi) -> eax 1 for INT64 / DECIMAL / FLOAT64
 * (right-aligned table columns), else 0 */
o_is_numeric:
    call o_col
    movl PQ_COL_TYPE(%rax), %ecx
    xor %eax, %eax
    cmp $PQ_TYPE_INT64, %ecx
    je 1f
    cmp $PQ_TYPE_DECIMAL, %ecx
    je 1f
    cmp $PQ_TYPE_FLOAT64, %ecx
    je 1f
    ret
1:  mov $1, %eax
    ret

/* o_name(res rdi, col rsi) -> rax ptr, rdx len of the column name */
o_name:
    call o_col
    mov PQ_COL_NAME(%rax), %rdi
    push %rdi
    call strlen
    mov %rax, %rdx
    pop %rax
    ret

/* o_utf8_width(ptr rdi, len rsi) -> rax number of code points
 * (bytes that are not UTF-8 continuation bytes 10xxxxxx) */
o_utf8_width:
    xor %eax, %eax
    xor %ecx, %ecx
1:  cmp %rsi, %rcx
    jae 2f
    movzbl (%rdi,%rcx), %edx
    and $0xC0, %edx
    cmp $0x80, %edx
    setne %dl
    add %rdx, %rax
    inc %rcx
    jmp 1b
2:  ret

/* o_fmt_i64(v rdi, buf rsi) -> rax length of the decimal text written to
 * buf (at most 20 bytes, not NUL-terminated).  Leaf; uses the red zone. */
o_fmt_i64:
    mov %rdi, %rax
    xor %r9d, %r9d
    test %rax, %rax
    jns 1f
    neg %rax                    /* INT64_MIN stays 2^63 as unsigned */
    mov $1, %r9d
1:  lea -1(%rsp), %rcx          /* digits are written backwards */
    mov $10, %r10d
2:  xor %edx, %edx
    div %r10
    add $'0', %dl
    mov %dl, (%rcx)
    dec %rcx
    test %rax, %rax
    jnz 2b
    test %r9d, %r9d
    jz 3f
    movb $'-', (%rcx)
    dec %rcx
3:  inc %rcx                    /* first character */
    mov %rsp, %rax
    sub %rcx, %rax              /* length */
    xor %edx, %edx
4:  cmp %rax, %rdx
    jae 5f
    movzbl (%rcx,%rdx), %r8d
    mov %r8b, (%rsi,%rdx)
    inc %rdx
    jmp 4b
5:  ret

/* ======================================================================
 * o_value_text(res rdi, row rsi, col rdx) -> rax ptr, rdx len, ecx 1 if NULL
 * The value text of §7.  The text stays valid until the next call (it
 * points into the result or into o_tmp / constant storage).
 * ====================================================================== */
o_value_text:
    ENTER 16
    mov %rdi, %r12              /* res */
    mov %rsi, %r13              /* row */
    mov %rdx, %r14              /* col */
    mov PQ_RES_NCOLS(%rdi), %rax
    imul %rsi, %rax
    add %rdx, %rax
    lea (%rax,%rax,2), %rax
    mov PQ_RES_VALUES(%rdi), %rbx
    lea (%rbx,%rax,8), %rbx     /* pq_value* */
    cmpq $0, PQ_VAL_IS_NULL(%rbx)
    jne .Lv_null
    mov %r14, %rsi
    call o_col_type
    cmp $PQ_TYPE_STRING, %eax
    je .Lv_string
    cmp $PQ_TYPE_INT64, %eax
    je .Lv_int
    cmp $PQ_TYPE_BOOLEAN, %eax
    je .Lv_bool
    cmp $PQ_TYPE_FLOAT64, %eax
    je .Lv_float
    /* DECIMAL, DATE, TIMESTAMP (and anything else): the library's text */
    mov %r12, %rdi
    mov %r13, %rsi
    mov %r14, %rdx
    lea o_tmp(%rip), %rcx
    mov $512, %r8d
    call pq_value_text
    mov %rax, %rdx
    cmp $511, %rdx
    jbe 1f
    mov $511, %edx
1:  lea o_tmp(%rip), %rax
    xor %ecx, %ecx
    LEAVE
.Lv_string:
    mov PQ_VAL_STR_PTR(%rbx), %rax
    mov PQ_VAL_STR_LEN(%rbx), %rdx
    xor %ecx, %ecx
    LEAVE
.Lv_int:
    mov PQ_VAL_I64(%rbx), %rdi
    lea o_tmp(%rip), %rsi
    call o_fmt_i64
    mov %rax, %rdx
    lea o_tmp(%rip), %rax
    xor %ecx, %ecx
    LEAVE
.Lv_bool:
    cmpq $0, PQ_VAL_BOOL(%rbx)
    je 1f
    lea o_true(%rip), %rax
    mov $4, %edx
    xor %ecx, %ecx
    LEAVE
1:  lea o_false(%rip), %rax
    mov $5, %edx
    xor %ecx, %ecx
    LEAVE
.Lv_float:
    lea o_tmp(%rip), %rdi
    mov $512, %esi
    CSTR %rdx, "%.6f"
    movsd PQ_VAL_F64(%rbx), %xmm0
    mov $1, %eax
    call snprintf
    movslq %eax, %rdx
    cmp $511, %rdx
    jbe 1f
    mov $511, %edx
1:  lea o_tmp(%rip), %rax
    xor %ecx, %ecx
    cmpb $'-', (%rax)
    jne 4f
    /* "-0.000000" (only zeros and the point after the sign) -> "0.000000" */
    mov $1, %r8d
2:  cmp %rdx, %r8
    jae 3f
    movzbl (%rax,%r8), %r9d
    cmp $'0', %r9d
    je 5f
    cmp $'.', %r9d
    jne 4f
5:  inc %r8
    jmp 2b
3:  inc %rax
    dec %rdx
4:  LEAVE
.Lv_null:
    lea o_tmp(%rip), %rax
    movb $0, (%rax)
    xor %edx, %edx
    mov $1, %ecx
    LEAVE

/* ======================================================================
 * table format
 * ====================================================================== */

/* o_run(c edi, n rsi): append n copies of ' ' (c = 0) or '-' (c = 1) */
o_run:
    ENTER
    lea o_spaces(%rip), %r12
    test %edi, %edi
    jz 1f
    lea o_dashes(%rip), %r12
1:  mov %rsi, %rbx
2:  test %rbx, %rbx
    jle 3f
    mov %rbx, %rdx
    cmp $64, %rdx
    jbe 4f
    mov $64, %edx
4:  sub %rdx, %rbx
    lea g_out(%rip), %rdi
    mov %r12, %rsi
    call ab_put
    jmp 2b
3:  LEAVE

/* o_sep(): the two-space cell separator */
o_sep:
    xor %edi, %edi
    mov $2, %esi
    jmp o_run

/* o_cell(ptr rdi, len rsi, width rdx, right ecx): one padded cell */
o_cell:
    ENTER
    mov %rdi, %r12
    mov %rsi, %r13
    mov %rdx, %r14
    mov %ecx, %r15d
    call o_utf8_width
    sub %rax, %r14              /* padding */
    test %r15d, %r15d
    jz 1f
    xor %edi, %edi
    mov %r14, %rsi
    call o_run
    lea g_out(%rip), %rdi
    mov %r12, %rsi
    mov %r13, %rdx
    call ab_put
    LEAVE
1:  lea g_out(%rip), %rdi
    mov %r12, %rsi
    mov %r13, %rdx
    call ab_put
    xor %edi, %edi
    mov %r14, %rsi
    call o_run
    LEAVE

/* o_endline(start rdi): remove trailing spaces of the line that starts at
 * offset `start` of g_out, then append '\n' */
o_endline:
    mov g_out+AB_DATA(%rip), %rax
    mov g_out+AB_LEN(%rip), %rcx
1:  cmp %rdi, %rcx
    jbe 2f
    cmpb $' ', -1(%rax,%rcx)
    jne 2f
    dec %rcx
    jmp 1b
2:  mov %rcx, g_out+AB_LEN(%rip)
    test %rax, %rax
    jz 3f
    movb $0, (%rax,%rcx)
3:  lea g_out(%rip), %rdi
    mov $'\n', %esi
    jmp ab_putc

/*
 * o_table(res rdi)
 * Locals: 0 widths[], 8 offs[] (cell text offsets in o_cells, ncells + 1),
 * 16 ncells, 24 line start, 32 row, 40 col, 48/56 current text ptr/len.
 */
o_table:
    ENTER 64
    mov %rdi, %r12              /* res */
    mov PQ_RES_NCOLS(%rdi), %r13
    mov PQ_RES_NROWS(%rdi), %r14
    lea 8(,%r13,8), %rdi
    call xmalloc
    mov %rax, %r15              /* widths */
    mov %rax, 0(%rsp)
    /* widths start with the names */
    xor %ebx, %ebx
1:  cmp %r13, %rbx
    jge 2f
    mov %r12, %rdi
    mov %rbx, %rsi
    call o_name
    mov %rax, %rdi
    mov %rdx, %rsi
    call o_utf8_width
    mov %rax, (%r15,%rbx,8)
    inc %rbx
    jmp 1b
2:  mov %r13, %rax
    imul %r14, %rax
    mov %rax, 16(%rsp)
    lea 8(,%rax,8), %rdi
    call xmalloc
    mov %rax, 8(%rsp)
    lea o_cells(%rip), %rdi
    call ab_init
    /* one pass: all value texts into o_cells, widths */
    xor %ebx, %ebx              /* cell index */
    movq $0, 32(%rsp)
3:  mov 32(%rsp), %rax
    cmp %r14, %rax
    jge 6f
    movq $0, 40(%rsp)
4:  mov 40(%rsp), %rax
    cmp %r13, %rax
    jge 5f
    mov %r12, %rdi
    mov 32(%rsp), %rsi
    mov %rax, %rdx
    call o_value_text
    mov %rax, 48(%rsp)
    mov %rdx, 56(%rsp)
    mov 8(%rsp), %r8
    mov o_cells+AB_LEN(%rip), %r9
    mov %r9, (%r8,%rbx,8)
    lea o_cells(%rip), %rdi
    mov %rax, %rsi
    call ab_put
    mov 48(%rsp), %rdi
    mov 56(%rsp), %rsi
    call o_utf8_width
    mov 40(%rsp), %rcx
    cmp (%r15,%rcx,8), %rax
    jle 7f
    mov %rax, (%r15,%rcx,8)
7:  inc %rbx
    incq 40(%rsp)
    jmp 4b
5:  incq 32(%rsp)
    jmp 3b
6:  mov 8(%rsp), %r8
    mov o_cells+AB_LEN(%rip), %r9
    mov %r9, (%r8,%rbx,8)

    /* header line */
    mov g_out+AB_LEN(%rip), %rax
    mov %rax, 24(%rsp)
    xor %ebx, %ebx
1:  cmp %r13, %rbx
    jge 2f
    test %rbx, %rbx
    jz 3f
    call o_sep
3:  mov %r12, %rdi
    mov %rbx, %rsi
    call o_is_numeric
    mov %eax, 48(%rsp)
    mov %r12, %rdi
    mov %rbx, %rsi
    call o_name
    mov %rax, %rdi
    mov %rdx, %rsi
    mov (%r15,%rbx,8), %rdx
    mov 48(%rsp), %ecx
    call o_cell
    inc %rbx
    jmp 1b
2:  mov 24(%rsp), %rdi
    call o_endline

    /* dash line */
    mov g_out+AB_LEN(%rip), %rax
    mov %rax, 24(%rsp)
    xor %ebx, %ebx
1:  cmp %r13, %rbx
    jge 2f
    test %rbx, %rbx
    jz 3f
    call o_sep
3:  mov $1, %edi
    mov (%r15,%rbx,8), %rsi
    call o_run
    inc %rbx
    jmp 1b
2:  mov 24(%rsp), %rdi
    call o_endline

    /* rows */
    xor %ebx, %ebx              /* cell index */
    movq $0, 32(%rsp)
3:  mov 32(%rsp), %rax
    cmp %r14, %rax
    jge 6f
    mov g_out+AB_LEN(%rip), %rax
    mov %rax, 24(%rsp)
    movq $0, 40(%rsp)
4:  mov 40(%rsp), %rax
    cmp %r13, %rax
    jge 5f
    test %rax, %rax
    jz 7f
    call o_sep
7:  mov %r12, %rdi
    mov 40(%rsp), %rsi
    call o_is_numeric
    mov %eax, %ecx
    mov 8(%rsp), %r8
    mov (%r8,%rbx,8), %rdi      /* offset */
    mov 8(%r8,%rbx,8), %rsi
    sub %rdi, %rsi              /* len */
    add o_cells+AB_DATA(%rip), %rdi
    mov 40(%rsp), %rdx
    mov (%r15,%rdx,8), %rdx
    call o_cell
    inc %rbx
    incq 40(%rsp)
    jmp 4b
5:  mov 24(%rsp), %rdi
    call o_endline
    incq 32(%rsp)
    jmp 3b

    /* footer */
6:  cmp $1, %r14
    jne 1f
    OUTS "(1 row)\n"
    jmp 2f
1:  lea g_out(%rip), %rdi
    mov $'(', %esi
    call ab_putc
    lea g_out(%rip), %rdi
    mov %r14, %rsi
    call ab_put_i64
    OUTS " rows)\n"
2:  mov 8(%rsp), %rdi
    call free
    mov 0(%rsp), %rdi
    call free
    lea o_cells(%rip), %rdi
    call ab_free
    LEAVE

/* ======================================================================
 * csv format
 * ====================================================================== */

/* o_csv_field(ptr rdi, len rsi): one non-NULL field, quoted when it is
 * empty, contains , " CR or LF, or starts or ends with a space */
o_csv_field:
    ENTER
    mov %rdi, %r12
    mov %rsi, %r13
    test %r13, %r13
    jz .Lq_quote
    cmpb $' ', (%r12)
    je .Lq_quote
    cmpb $' ', -1(%r12,%r13)
    je .Lq_quote
    xor %ecx, %ecx
1:  cmp %r13, %rcx
    jae 2f
    movzbl (%r12,%rcx), %eax
    cmp $',', %eax
    je .Lq_quote
    cmp $'"', %eax
    je .Lq_quote
    cmp $'\r', %eax
    je .Lq_quote
    cmp $'\n', %eax
    je .Lq_quote
    inc %rcx
    jmp 1b
2:  lea g_out(%rip), %rdi
    mov %r12, %rsi
    mov %r13, %rdx
    call ab_put
    LEAVE
.Lq_quote:
    lea g_out(%rip), %rdi
    mov $'"', %esi
    call ab_putc
    xor %ebx, %ebx              /* start of the pending run */
    xor %r14d, %r14d            /* index */
1:  cmp %r13, %r14
    jae 3f
    cmpb $'"', (%r12,%r14)
    jne 2f
    /* run including this quote, then the doubling quote */
    lea g_out(%rip), %rdi
    lea (%r12,%rbx), %rsi
    lea 1(%r14), %rdx
    sub %rbx, %rdx
    call ab_put
    lea g_out(%rip), %rdi
    mov $'"', %esi
    call ab_putc
    lea 1(%r14), %rbx
2:  inc %r14
    jmp 1b
3:  lea g_out(%rip), %rdi
    lea (%r12,%rbx), %rsi
    mov %r13, %rdx
    sub %rbx, %rdx
    call ab_put
    lea g_out(%rip), %rdi
    mov $'"', %esi
    call ab_putc
    LEAVE

/* o_csv(res rdi) */
o_csv:
    ENTER
    mov %rdi, %r12
    mov PQ_RES_NCOLS(%rdi), %r13
    mov PQ_RES_NROWS(%rdi), %r14
    xor %ebx, %ebx
1:  cmp %r13, %rbx
    jge 2f
    test %rbx, %rbx
    jz 3f
    lea g_out(%rip), %rdi
    mov $',', %esi
    call ab_putc
3:  mov %r12, %rdi
    mov %rbx, %rsi
    call o_name
    mov %rax, %rdi
    mov %rdx, %rsi
    call o_csv_field
    inc %rbx
    jmp 1b
2:  lea g_out(%rip), %rdi
    mov $'\n', %esi
    call ab_putc
    xor %r15d, %r15d            /* row */
4:  cmp %r14, %r15
    jge 9f
    xor %ebx, %ebx
5:  cmp %r13, %rbx
    jge 7f
    test %rbx, %rbx
    jz 6f
    lea g_out(%rip), %rdi
    mov $',', %esi
    call ab_putc
6:  mov %r12, %rdi
    mov %r15, %rsi
    mov %rbx, %rdx
    call o_value_text
    test %ecx, %ecx
    jnz 8f                      /* NULL: empty, unquoted */
    mov %rax, %rdi
    mov %rdx, %rsi
    call o_csv_field
8:  inc %rbx
    jmp 5b
7:  lea g_out(%rip), %rdi
    mov $'\n', %esi
    call ab_putc
    inc %r15
    jmp 4b
9:  LEAVE

/* ======================================================================
 * json lines format
 * ====================================================================== */

/* o_json_str(ab rdi, ptr rsi, len rdx): append a JSON string literal:
 * " \ escaped, \b \t \n \f \r, other bytes < 0x20 as \u00xx, all other
 * bytes (UTF-8) as they are.  Local 0..7: escape sequence buffer. */
o_json_str:
    ENTER 16
    mov %rdi, %rbx              /* ab */
    mov %rsi, %r12              /* ptr */
    mov %rdx, %r13              /* len */
    mov $'"', %esi
    call ab_putc
    xor %r14d, %r14d            /* index */
    xor %r15d, %r15d            /* start of the pending run */
1:  cmp %r13, %r14
    jae 9f
    movzbl (%r12,%r14), %eax
    cmp $'"', %eax
    je 2f
    cmp $'\\', %eax
    je 2f
    cmp $0x20, %eax
    jb 2f
    inc %r14
    jmp 1b
2:  /* flush the run before the special byte */
    mov %eax, 8(%rsp)
    mov %rbx, %rdi
    lea (%r12,%r15), %rsi
    mov %r14, %rdx
    sub %r15, %rdx
    call ab_put
    mov 8(%rsp), %eax
    movb $'\\', 0(%rsp)
    mov $2, %edx                /* escape length */
    mov %al, 1(%rsp)            /* " and \ themselves */
    cmp $'"', %eax
    je 3f
    cmp $'\\', %eax
    je 3f
    movb $'b', 1(%rsp)
    cmp $0x08, %eax
    je 3f
    movb $'t', 1(%rsp)
    cmp $0x09, %eax
    je 3f
    movb $'n', 1(%rsp)
    cmp $0x0a, %eax
    je 3f
    movb $'f', 1(%rsp)
    cmp $0x0c, %eax
    je 3f
    movb $'r', 1(%rsp)
    cmp $0x0d, %eax
    je 3f
    movb $'u', 1(%rsp)
    movb $'0', 2(%rsp)
    movb $'0', 3(%rsp)
    lea o_hex(%rip), %rcx
    mov %eax, %r8d
    shr $4, %r8d
    movzbl (%rcx,%r8), %r8d
    mov %r8b, 4(%rsp)
    and $15, %eax
    movzbl (%rcx,%rax), %r8d
    mov %r8b, 5(%rsp)
    mov $6, %edx
3:  mov %rbx, %rdi
    mov %rsp, %rsi
    call ab_put
    inc %r14
    mov %r14, %r15
    jmp 1b
9:  mov %rbx, %rdi
    lea (%r12,%r15), %rsi
    mov %r14, %rdx
    sub %r15, %rdx
    call ab_put
    mov %rbx, %rdi
    mov $'"', %esi
    call ab_putc
    LEAVE

/*
 * o_json(res rdi)
 * The object keys `"name":` are escaped once into o_cells (offsets in
 * koffs[], ncols + 1 entries).  Locals: 0 koffs, 8 row, 16 col.
 */
o_json:
    ENTER 32
    mov %rdi, %r12
    mov PQ_RES_NCOLS(%rdi), %r13
    mov PQ_RES_NROWS(%rdi), %r14
    test %r14, %r14
    jz 9f                       /* nothing for zero rows */
    lea 8(,%r13,8), %rdi
    call xmalloc
    mov %rax, %r15              /* koffs */
    lea o_cells(%rip), %rdi
    call ab_init
    xor %ebx, %ebx
1:  mov o_cells+AB_LEN(%rip), %rax
    mov %rax, (%r15,%rbx,8)
    cmp %r13, %rbx
    jge 2f
    mov %r12, %rdi
    mov %rbx, %rsi
    call o_name
    lea o_cells(%rip), %rdi
    mov %rax, %rsi
    call o_json_str
    lea o_cells(%rip), %rdi
    mov $':', %esi
    call ab_putc
    inc %rbx
    jmp 1b
2:  movq $0, 8(%rsp)
3:  mov 8(%rsp), %rax
    cmp %r14, %rax
    jge 8f
    lea g_out(%rip), %rdi
    mov $'{', %esi
    call ab_putc
    xor %ebx, %ebx
4:  cmp %r13, %rbx
    jge 7f
    test %rbx, %rbx
    jz 5f
    lea g_out(%rip), %rdi
    mov $',', %esi
    call ab_putc
5:  lea g_out(%rip), %rdi
    mov (%r15,%rbx,8), %rsi
    mov 8(%r15,%rbx,8), %rdx
    sub %rsi, %rdx
    add o_cells+AB_DATA(%rip), %rsi
    call ab_put
    mov %r12, %rdi
    mov 8(%rsp), %rsi
    mov %rbx, %rdx
    call o_value_text
    test %ecx, %ecx
    jnz .Lj_null
    mov %rax, 16(%rsp)
    mov %rdx, 24(%rsp)
    mov %r12, %rdi
    mov %rbx, %rsi
    call o_col_type
    cmp $PQ_TYPE_INT64, %eax
    je .Lj_raw
    cmp $PQ_TYPE_FLOAT64, %eax
    je .Lj_raw
    cmp $PQ_TYPE_BOOLEAN, %eax
    je .Lj_raw
    lea g_out(%rip), %rdi
    mov 16(%rsp), %rsi
    mov 24(%rsp), %rdx
    call o_json_str
    jmp 6f
.Lj_raw:
    lea g_out(%rip), %rdi
    mov 16(%rsp), %rsi
    mov 24(%rsp), %rdx
    call ab_put
    jmp 6f
.Lj_null:
    lea g_out(%rip), %rdi
    lea o_null(%rip), %rsi
    mov $4, %edx
    call ab_put
6:  inc %rbx
    jmp 4b
7:  lea g_out(%rip), %rdi
    mov $'}', %esi
    call ab_putc
    lea g_out(%rip), %rdi
    mov $'\n', %esi
    call ab_putc
    incq 8(%rsp)
    jmp 3b
8:  mov %r15, %rdi
    call free
    lea o_cells(%rip), %rdi
    call ab_free
9:  LEAVE
