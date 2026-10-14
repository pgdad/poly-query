// =============================================================================
// pq-embed-demo — the minimal embedding example (spec/apps/embedding.md §5).
//
//   pq-embed-demo DATA_DIR CSV_FILE SQL
//
// Creates an engine instance on DATA_DIR, loads CSV_FILE (relative to
// DATA_DIR, header row, inferred schema) as table `t`, runs SQL and prints
// the result as CSV (spec/apps/pqledger.md §7). Engine errors print
// `error: CODE: MESSAGE` to stderr and exit 1.
//
// Uses only the public API (polyquery.inc / libpolyquery.a) and glibc.
// =============================================================================
#include "polyquery.inc"

    .section .rodata
s_table:    .asciz "t"
s_usage:    .asciz "usage: pq-embed-demo DATA_DIR CSV_FILE SQL\n"
s_error:    .asciz "error: %s: %s\n"

    .text

// main(w0 argc, x1 argv) -> w0 exit status
//   x19 argv, x20 pq_db*, x21 pq_result*, x22 row, x23 column,
//   x24 pq_column*, x25 value text buffer (malloc), x26 its capacity
//   stack: [sp] pq_config (56 bytes, zeroed), [sp+64] pq_db* / pq_result*
    .global main
    .type main, %function
    .p2align 2
main:
    stp  x29, x30, [sp, #-96]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    stp  x25, x26, [sp, #64]
    sub  sp, sp, #80
    mov  x19, x1
    cmp  w0, #4
    b.eq 1f
    adrp x0, :got:stderr
    ldr  x0, [x0, :got_lo12:stderr]
    ldr  x1, [x0]
    adrp x0, s_usage
    add  x0, x0, :lo12:s_usage
    bl   fputs
    mov  w0, #2
    b    .Lexit
1:  // pq_create(&config, &db): only the data directory is configured
    mov  x0, sp
    mov  w1, #0
    mov  x2, #PQCFG_SIZE
    bl   memset
    ldr  x9, [x19, #8]
    str  x9, [sp, #PQCFG_DATA_DIR]
    mov  x0, sp
    add  x1, sp, #64
    bl   pq_create
    ldr  x20, [sp, #64]             // 0 on failure: pq_errmsg(NULL)
    cbnz w0, .Lerror
    // pq_load_file(db, "t", CSV_FILE, NULL): defaults = CSV, header, inferred
    mov  x0, x20
    adrp x1, s_table
    add  x1, x1, :lo12:s_table
    ldr  x2, [x19, #16]
    mov  x3, #0
    bl   pq_load_file
    cbnz w0, .Lerror
    // pq_query(db, SQL, NULL, &result)
    mov  x0, x20
    ldr  x1, [x19, #24]
    mov  x2, #0
    add  x3, sp, #64
    bl   pq_query
    cbnz w0, .Lerror
    ldr  x21, [sp, #64]
    mov  x26, #256
    mov  x0, x26
    bl   malloc
    mov  x25, x0
    // header record
    mov  x23, #0
2:  ldr  x9, [x21, #PQR_NCOLS]
    cmp  x23, x9
    b.hs 3f
    mov  x0, x23
    bl   put_sep
    ldr  x9, [x21, #PQR_COLUMNS]
    lsl  x10, x23, #5               // PQC_SIZE = 32
    ldr  x0, [x9, x10]              // name
    bl   strlen
    mov  x1, x0
    ldr  x9, [x21, #PQR_COLUMNS]
    lsl  x10, x23, #5
    ldr  x0, [x9, x10]
    mov  w2, #1
    bl   put_field
    add  x23, x23, #1
    b    2b
3:  mov  w0, #'\n'
    bl   putchar
    // rows
    mov  x22, #0
4:  ldr  x9, [x21, #PQR_NROWS]
    cmp  x22, x9
    b.hs 8f
    mov  x23, #0
5:  ldr  x9, [x21, #PQR_NCOLS]
    cmp  x23, x9
    b.hs 7f
    mov  x0, x23
    bl   put_sep
    mov  x0, x21
    mov  x1, x22
    mov  x2, x23
    bl   pq_value_at
    mov  x24, x0                    // pq_value*
    ldr  w9, [x24, #PQV_IS_NULL]
    cbnz w9, 6f                     // NULL: empty unquoted field
    ldr  x9, [x21, #PQR_COLUMNS]
    add  x0, x9, x23, lsl #5
    mov  x1, x24
    mov  w2, #PQ_FMT_FLOAT_FIXED6
    mov  x3, x25
    mov  x4, x26
    bl   pq_format_value
    cmp  x0, x26
    b.lo 51f
    add  x26, x0, #1                // grow the text buffer and format again
    mov  x0, x25
    mov  x1, x26
    bl   realloc
    mov  x25, x0
    ldr  x9, [x21, #PQR_COLUMNS]
    add  x0, x9, x23, lsl #5
    mov  x1, x24
    mov  w2, #PQ_FMT_FLOAT_FIXED6
    mov  x3, x25
    mov  x4, x26
    bl   pq_format_value
51: mov  x1, x0
    mov  x0, x25
    ldr  w2, [x24, #PQV_TYPE]
    cmp  w2, #PQ_T_STRING
    cset w2, eq
    bl   put_field
6:  add  x23, x23, #1
    b    5b
7:  mov  w0, #'\n'
    bl   putchar
    add  x22, x22, #1
    b    4b
8:  mov  x0, x25
    bl   free
    mov  x0, x21
    bl   pq_result_free
    mov  x0, x20
    bl   pq_close
    mov  w0, #0
.Lexit:
    add  sp, sp, #80
    ldp  x25, x26, [sp, #64]
    ldp  x23, x24, [sp, #48]
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #96
    ret
.Lerror:                            // error: CODE: MESSAGE, exit 1
    adrp x0, :got:stderr
    ldr  x0, [x0, :got_lo12:stderr]
    ldr  x19, [x0]
    mov  x0, x20
    bl   pq_errname
    mov  x21, x0
    mov  x0, x20
    bl   pq_errmsg
    mov  x3, x0
    mov  x2, x21
    adrp x1, s_error
    add  x1, x1, :lo12:s_error
    mov  x0, x19
    bl   fprintf
    mov  x0, x20
    bl   pq_close                   // accepts 0
    mov  w0, #1
    b    .Lexit
    .size main, .-main

// put_sep(x0 column index): a ',' before every field but the first
    .type put_sep, %function
    .p2align 2
put_sep:
    cbz  x0, 1f
    mov  w0, #','
    b    putchar
1:  ret
    .size put_sep, .-put_sep

// put_field(x0 text, x1 length, w2 1 = STRING value): writes one CSV field,
// quoted (with `"` doubled) if it is an empty string or contains `,` `"`
// CR LF, or starts or ends with a space
//   x19 text, x20 length, x21 index
    .type put_field, %function
    .p2align 2
put_field:
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    str  x21, [sp, #32]
    mov  x19, x0
    mov  x20, x1
    cbnz x20, 1f
    cbz  w2, .Lpf_plain             // empty non-string text: nothing
    b    .Lpf_quoted
1:  ldrb w9, [x19]                  // leading / trailing space
    cmp  w9, #' '
    b.eq .Lpf_quoted
    sub  x9, x20, #1
    ldrb w9, [x19, x9]
    cmp  w9, #' '
    b.eq .Lpf_quoted
    mov  x21, #0
2:  cmp  x21, x20
    b.hs .Lpf_plain
    ldrb w9, [x19, x21]
    add  x21, x21, #1
    cmp  w9, #','
    b.eq .Lpf_quoted
    cmp  w9, #'"'
    b.eq .Lpf_quoted
    cmp  w9, #'\r'
    b.eq .Lpf_quoted
    cmp  w9, #'\n'
    b.eq .Lpf_quoted
    b    2b
.Lpf_plain:
    mov  x0, x19
    mov  x1, #1
    mov  x2, x20
    adrp x3, :got:stdout
    ldr  x3, [x3, :got_lo12:stdout]
    ldr  x3, [x3]
    bl   fwrite
    b    9f
.Lpf_quoted:
    mov  w0, #'"'
    bl   putchar
    mov  x21, #0
3:  cmp  x21, x20
    b.hs 4f
    ldrb w0, [x19, x21]
    add  x21, x21, #1
    cmp  w0, #'"'
    b.ne 31f
    bl   putchar
    mov  w0, #'"'
31: bl   putchar
    b    3b
4:  mov  w0, #'"'
    bl   putchar
9:  ldp  x19, x20, [sp, #16]
    ldr  x21, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
    .size put_field, .-put_field

    .section .note.GNU-stack,"",%progbits
