/*
 * ingest.S - CSV / JSON / JSON Lines ingestion into column-major Tables.
 *
 * Exported (System V ABI):
 *   ingest_csv(name rdi pstr*, data rsi, len rdx, schema rcx Schema*|0,
 *              header r8 0/1, delim r9b) -> rax Table*
 *   ingest_json(name rdi pstr*, data rsi, len rdx, schema rcx Schema*|0,
 *               lines r8 0 = JSON array document, 1 = JSON Lines) -> rax Table*
 *
 * Both create the table arena first and publish it in g_pending_arena so the
 * caller can destroy it when an error is raised.  Everything reachable from
 * the returned Table lives in that arena; scratch data (header names, JSON
 * DOM, per-column inference state) goes to the request arena g_arena.
 *
 * CSV is processed in two linear passes over the input with a small field
 * scanner (csv_field): pass 1 validates arity, counts rows and infers column
 * types; pass 2 converts every field straight into the column arrays.  No
 * per-cell scratch storage is needed.
 *
 * JSON is parsed into a DOM (json_parse); each column gets a scratch array of
 * node* per row (0 = key missing), which is then inferred and converted.
 */
#include "pq.inc"

    .section .note.GNU-stack, "", @progbits

#define MAX_FIELD (16*1024*1024)

/* CSV scanner state */
#define CS_POS    0      /* cursor */
#define CS_END    8      /* end of input */
#define CS_DELIM  16     /* delimiter byte */
#define CS_FPTR   24     /* last field: content start (inside quotes if quoted) */
#define CS_FLEN   32     /* last field: raw content length */
#define CS_FFLAGS 40     /* last field: FQ_* bits */
#define CS_TERM   48     /* 0 = delimiter followed, 1 = end of record */
#define CS_SIZE   56

#define FQ_QUOTED 1
#define FQ_ESC    2      /* quoted field containing "" escapes */

/* CSV inference mask bits (set = candidate ruled out) */
#define IM_BOOL  1
#define IM_INT   2
#define IM_FLOAT 4
#define IM_DATE  8
#define IM_TS    16
#define IM_ALL   31
#define IM_SEEN  32

    .section .rodata
mask_types: .byte T_BOOL, T_INT, T_FLOAT, T_DATE, T_TS

    .text

/* ======================================================== small helpers */

/* ing_trim(ptr rdi, len rsi) -> rax ptr, rdx len without leading/trailing
 * ASCII spaces and tabs.  Leaf; clobbers rcx only. */
ing_trim:
    mov %rdi, %rax
    mov %rsi, %rdx
1:  test %rdx, %rdx
    jz 5f
    movzbl (%rax), %ecx
    cmp $' ', %ecx
    je 2f
    cmp $'\t', %ecx
    jne 3f
2:  inc %rax
    dec %rdx
    jmp 1b
3:  movzbl -1(%rax, %rdx), %ecx
    cmp $' ', %ecx
    je 4f
    cmp $'\t', %ecx
    jne 5f
4:  dec %rdx
    jnz 3b
5:  ret

/* ing_is_bool(ptr rdi, len rsi) -> eax 1 (true), 0 (false), -1 (not a
 * boolean literal); case-insensitive.  Leaf. */
ing_is_bool:
    cmp $4, %rsi
    jne 1f
    mov (%rdi), %eax
    or $0x20202020, %eax
    cmp $0x65757274, %eax           /* "true" */
    jne 9f
    mov $1, %eax
    ret
1:  cmp $5, %rsi
    jne 9f
    mov (%rdi), %eax
    or $0x20202020, %eax
    cmp $0x736c6166, %eax           /* "fals" */
    jne 9f
    movzbl 4(%rdi), %eax
    or $0x20, %eax
    cmp $'e', %eax
    jne 9f
    xor %eax, %eax
    ret
9:  mov $-1, %eax
    ret

/* parse_typed(ptr rdi, len rsi, type rdx) -> rax value, edx status (0 ok).
 * Text must already be trimmed and non-empty.  Not valid for STRING. */
parse_typed:
    sub $8, %rsp
    movzbl %dl, %eax
    cmp $T_BOOL, %eax
    je 1f
    cmp $T_INT, %eax
    je 2f
    cmp $T_FLOAT, %eax
    je 3f
    cmp $T_DEC, %eax
    je 4f
    cmp $T_DATE, %eax
    je 5f
    cmp $T_TS, %eax
    je 6f
    mov $1, %edx
    jmp 9f
1:  call ing_is_bool
    xor %edx, %edx
    test %eax, %eax
    jns 9f
    mov $1, %edx
    jmp 9f
2:  call text_parse_int64
    jmp 9f
3:  call text_parse_float
    mov %eax, %edx
    movq %xmm0, %rax
    jmp 9f
4:  mov %rdx, %rcx
    shr $16, %rcx
    and $0xff, %ecx                 /* scale */
    shr $8, %rdx
    and $0xff, %edx                 /* precision */
    xor %r8d, %r8d                  /* exact mode */
    cmp $18, %edx
    ja parse_wide
    call text_parse_decimal
    jmp 9f
5:  call text_parse_date
    jmp 9f
6:  mov $1, %edx                    /* a DATE text is accepted */
    call text_parse_timestamp
9:  add $8, %rsp
    ret

/* parse_wide: parse_typed of a wide DECIMAL (prec edx, scale ecx, mode r8d
 * set; entered by a jump inside parse_typed's frame).  The value is boxed
 * in the table arena. */
parse_wide:
    sub $32, %rsp                   /* i128 at 0(%rsp) */
    mov %rsp, %r9
    call dec_parse
    mov %eax, %edx
    xor %eax, %eax
    test %edx, %edx
    jnz 1f
    mov g_pending_arena(%rip), %rdi
    mov 0(%rsp), %rsi
    mov 8(%rsp), %rdx
    call dec_box_in
    xor %edx, %edx
1:  add $40, %rsp
    ret

/* check_names(base rdi, n rsi, stride rdx): every *(pstr**)(base + i*stride)
 * must be non-empty and unique (ASCII case-insensitive), else INGEST_ERROR. */
check_names:
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    xor %r14d, %r14d                /* i */
1:  cmp %r12, %r14
    jae 9f
    mov %r14, %rax
    imul %r13, %rax
    mov (%rbx, %rax), %r15          /* name i */
    cmpq $0, (%r15)
    jne 2f
    RAISE E_INGEST_ERROR, "empty column name"
2:  movq $0, (%rsp)                 /* j */
3:  mov (%rsp), %rax
    cmp %r14, %rax
    jae 5f
    imul %r13, %rax
    mov (%rbx, %rax), %rax
    lea 8(%r15), %rdi
    mov (%r15), %rsi
    lea 8(%rax), %rdx
    mov (%rax), %rcx
    call mem_ieq
    test %eax, %eax
    jz 4f
    mov $E_INGEST_ERROR, %edi
    CSTR %rsi, "duplicate column name '%s'"
    lea 8(%r15), %rdx
    call pq_raisef
4:  incq (%rsp)
    jmp 3b
5:  inc %r14
    jmp 1b
9:  LEAVE

/* tbl_new(name pstr* rdi, ncols rsi, nrows rdx) -> rax Table* (in the
 * pending table arena) with a zeroed Column array. */
tbl_new:
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov g_pending_arena(%rip), %r15
    mov %r15, %rdi
    mov $TB_SIZE, %esi
    call arena_zalloc
    mov %rax, %r14
    xor %esi, %esi                  /* name length */
    lea 1f(%rip), %rax
    test %rbx, %rbx
    jz 2f
    mov (%rbx), %rsi
    lea 8(%rbx), %rax
2:  mov %rsi, %rdx
    mov %rax, %rsi
    mov %r15, %rdi
    call pstr_new
    mov %rax, TB_NAME(%r14)
    mov %r12, TB_NCOLS(%r14)
    mov %r13, TB_NROWS(%r14)
    mov %r15, TB_ARENA(%r14)
    mov %r15, %rdi
    mov %r12, %rsi
    shl $COL_SHIFT, %rsi
    call arena_zalloc
    mov %rax, TB_COLS(%r14)
    mov %r14, %rax
    LEAVE
    .section .rodata
1:  .byte 0
    .text

/* col_init(col rdi, name pstr* rsi, type rdx, nrows rcx): copies the name and
 * allocates data (u64[nrows]) and zeroed nulls (u8[nrows]) in the table arena. */
col_init:
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, COL_TYPE(%rbx)
    mov %rcx, %r14
    mov g_pending_arena(%rip), %r15
    mov %r15, %rdi
    lea 8(%r12), %rsi
    mov (%r12), %rdx
    call pstr_new
    mov %rax, COL_NAME(%rbx)
    mov %r15, %rdi
    lea (, %r14, 8), %rsi
    call arena_alloc
    mov %rax, COL_DATA(%rbx)
    mov %r15, %rdi
    mov %r14, %rsi
    call arena_zalloc
    mov %rax, COL_NULLS(%rbx)
    LEAVE

/* check_input_size(len rdi): RESOURCE_LIMIT above g_max_ingest_bytes */
check_input_size:
    cmp g_max_ingest_bytes(%rip), %rdi
    ja 1f
    ret
1:  sub $8, %rsp
    mov $E_RESOURCE_LIMIT, %edi
    CSTR %rsi, "input exceeds the maximum ingest size (%ld bytes)"
    mov g_max_ingest_bytes(%rip), %rdx
    call pq_raisef

/* raise_row_limit(): RESOURCE_LIMIT */
raise_row_limit:
    sub $8, %rsp
    mov $E_RESOURCE_LIMIT, %edi
    CSTR %rsi, "table exceeds the maximum row count (%ld)"
    mov g_max_table_rows(%rip), %rdx
    call pq_raisef

/* ======================================================== CSV scanner */

/* csv_skip_empty(st rdi) -> eax 1 if a record starts at CS_POS, 0 at end of
 * input.  Skips completely empty lines ("\n" or "\r\n").  Leaf. */
csv_skip_empty:
    mov CS_POS(%rdi), %rax
    mov CS_END(%rdi), %rdx
1:  cmp %rdx, %rax
    jae 8f
    movzbl (%rax), %ecx
    cmp $'\n', %ecx
    jne 2f
    inc %rax
    jmp 1b
2:  cmp $'\r', %ecx
    jne 5f
    lea 1(%rax), %rcx
    cmp %rdx, %rcx
    jae 3f                          /* lone CR at end of input */
    cmpb $'\n', (%rcx)
    jne 5f
    add $2, %rax
    jmp 1b
3:  mov %rdx, %rax
    jmp 8f
5:  mov %rax, CS_POS(%rdi)
    mov $1, %eax
    ret
8:  mov %rax, CS_POS(%rdi)
    xor %eax, %eax
    ret

/* csv_field(st rdi): scans one field at CS_POS and fills CS_FPTR, CS_FLEN,
 * CS_FFLAGS, CS_TERM; advances CS_POS past the delimiter / terminator.
 * Raises INGEST_ERROR on unterminated quotes, garbage after a closing quote
 * and fields longer than 16 MiB.  Leaf (except when raising). */
csv_field:
    mov CS_POS(%rdi), %rsi
    mov CS_END(%rdi), %rdx
    movzbl CS_DELIM(%rdi), %r8d
    cmp %rdx, %rsi
    jae .Lcf_eof_empty
    cmpb $'"', (%rsi)
    je .Lcf_quoted
    mov %rsi, %rax                  /* field start */
.Lcf_u:
    cmp %rdx, %rsi
    jae .Lcf_u_eof
    movzbl (%rsi), %ecx
    cmp %r8d, %ecx
    je .Lcf_u_delim
    cmp $'\n', %ecx
    je .Lcf_u_nl
    inc %rsi
    jmp .Lcf_u
.Lcf_u_delim:
    lea 1(%rsi), %rcx
    mov %rcx, CS_POS(%rdi)
    movq $0, CS_TERM(%rdi)
    jmp .Lcf_u_done
.Lcf_u_nl:
    lea 1(%rsi), %rcx
    mov %rcx, CS_POS(%rdi)
    jmp .Lcf_u_cr
.Lcf_u_eof:
    mov %rdx, CS_POS(%rdi)
.Lcf_u_cr:
    movq $1, CS_TERM(%rdi)
    cmp %rax, %rsi
    je .Lcf_u_done
    cmpb $'\r', -1(%rsi)
    jne .Lcf_u_done
    dec %rsi
.Lcf_u_done:
    sub %rax, %rsi
    mov %rax, CS_FPTR(%rdi)
    mov %rsi, CS_FLEN(%rdi)
    movq $0, CS_FFLAGS(%rdi)
    cmp $MAX_FIELD, %rsi
    ja .Lcf_toolong
    ret

.Lcf_quoted:
    lea 1(%rsi), %rax               /* content start */
    mov %rax, %rsi
    mov $FQ_QUOTED, %r9d
.Lcf_q:
    cmp %rdx, %rsi
    jae .Lcf_unterminated
    cmpb $'"', (%rsi)
    je .Lcf_q_quote
    inc %rsi
    jmp .Lcf_q
.Lcf_q_quote:
    lea 1(%rsi), %rcx
    cmp %rdx, %rcx
    jae .Lcf_q_end
    cmpb $'"', (%rcx)
    jne .Lcf_q_end
    or $FQ_ESC, %r9d
    lea 1(%rcx), %rsi
    jmp .Lcf_q
.Lcf_q_end:                         /* rsi = closing quote, rcx = rsi + 1 */
    mov %rax, CS_FPTR(%rdi)
    mov %r9, CS_FFLAGS(%rdi)
    mov %rsi, %r10
    sub %rax, %r10
    mov %r10, CS_FLEN(%rdi)
    cmp %rdx, %rcx
    jae .Lcf_q_eof
    movzbl (%rcx), %r10d
    cmp %r8d, %r10d
    je .Lcf_q_delim
    cmp $'\n', %r10d
    je .Lcf_q_nl
    cmp $'\r', %r10d
    jne .Lcf_garbage
    lea 1(%rcx), %r11
    cmp %rdx, %r11
    jae .Lcf_q_eof
    cmpb $'\n', (%r11)
    jne .Lcf_garbage
    lea 1(%r11), %rcx
    mov %rcx, CS_POS(%rdi)
    movq $1, CS_TERM(%rdi)
    jmp .Lcf_q_chk
.Lcf_q_delim:
    inc %rcx
    mov %rcx, CS_POS(%rdi)
    movq $0, CS_TERM(%rdi)
    jmp .Lcf_q_chk
.Lcf_q_nl:
    inc %rcx
    mov %rcx, CS_POS(%rdi)
    movq $1, CS_TERM(%rdi)
    jmp .Lcf_q_chk
.Lcf_q_eof:
    mov %rdx, CS_POS(%rdi)
    movq $1, CS_TERM(%rdi)
.Lcf_q_chk:
    cmpq $MAX_FIELD, CS_FLEN(%rdi)
    ja .Lcf_toolong
    ret

.Lcf_eof_empty:                     /* empty last field after a delimiter */
    mov %rsi, CS_FPTR(%rdi)
    movq $0, CS_FLEN(%rdi)
    movq $0, CS_FFLAGS(%rdi)
    movq $1, CS_TERM(%rdi)
    ret

.Lcf_unterminated:
    sub $8, %rsp
    RAISE E_INGEST_ERROR, "CSV: unterminated quoted field"
.Lcf_garbage:
    sub $8, %rsp
    RAISE E_INGEST_ERROR, "CSV: unexpected character after closing quote"
.Lcf_toolong:
    sub $8, %rsp
    RAISE E_INGEST_ERROR, "CSV: field longer than 16 MiB"

/* csv_unescape(arena rdi, ptr rsi, len rdx) -> pstr* with every "" pair of
 * a quoted field's content collapsed into a single quote. */
csv_unescape:
    push %rbx
    push %r12
    push %r13
    mov %rsi, %r12
    mov %rdx, %r13
    lea 9(%rdx), %rsi
    call arena_alloc
    mov %rax, %rbx
    lea 8(%rax), %rdi               /* output cursor */
    xor %ecx, %ecx                  /* input index */
1:  cmp %r13, %rcx
    jae 3f
    movzbl (%r12, %rcx), %edx
    mov %dl, (%rdi)
    inc %rdi
    inc %rcx
    cmp $'"', %edx
    jne 1b
    inc %rcx                        /* skip the second quote of the pair */
    jmp 1b
3:  movb $0, (%rdi)
    lea 8(%rbx), %rax
    sub %rax, %rdi
    mov %rdi, (%rbx)
    mov %rbx, %rax
    pop %r13
    pop %r12
    pop %rbx
    ret

/* csv_field_pstr(arena rdi, st rsi) -> pstr* copy of the last field's text */
csv_field_pstr:
    mov CS_FFLAGS(%rsi), %rax
    mov CS_FLEN(%rsi), %rdx
    mov CS_FPTR(%rsi), %rsi
    test $FQ_ESC, %eax
    jnz csv_unescape
    jmp pstr_new

/* csv_infer(maskp rdi, ptr rsi, len rdx, flags rcx): folds one field into
 * the column's inference mask (IM_* bits = candidates ruled out). */
csv_infer:
    ENTER 0
    mov %rdi, %rbx
    mov (%rbx), %r14                /* mask */
    test %rdx, %rdx
    jz 9f                           /* unquoted or quoted empty: ignored */
    mov %r14, %r15
    not %r15
    and $IM_ALL, %r15               /* remaining candidates */
    jz 9f
    test $FQ_ESC, %ecx
    jnz 7f                          /* contains a quote: STRING */
    mov %rsi, %rdi
    mov %rdx, %rsi
    call ing_trim
    test %rdx, %rdx
    jz 9f
    mov %rax, %r12
    mov %rdx, %r13
    or $IM_SEEN, %r14
    test $IM_BOOL, %r15
    jz 1f
    mov %r12, %rdi
    mov %r13, %rsi
    call ing_is_bool
    test %eax, %eax
    js 1f
    or $(IM_INT | IM_FLOAT | IM_DATE | IM_TS), %r14
    jmp 8f
1:  test $IM_INT, %r15
    jz 2f
    mov %r12, %rdi
    mov %r13, %rsi
    call text_parse_int64
    test %edx, %edx
    jnz 2f
    or $(IM_BOOL | IM_DATE | IM_TS), %r14
    jmp 8f
2:  test $IM_FLOAT, %r15
    jz 3f
    mov %r12, %rdi
    mov %r13, %rsi
    call text_parse_float
    test %eax, %eax
    jnz 3f
    or $(IM_BOOL | IM_INT | IM_DATE | IM_TS), %r14
    jmp 8f
3:  test $IM_DATE, %r15
    jz 4f
    mov %r12, %rdi
    mov %r13, %rsi
    call text_parse_date
    test %edx, %edx
    jnz 4f
    or $(IM_BOOL | IM_INT | IM_FLOAT), %r14
    jmp 8f
4:  test $IM_TS, %r15
    jz 7f
    mov %r12, %rdi
    mov %r13, %rsi
    mov $1, %edx
    call text_parse_timestamp
    test %edx, %edx
    jnz 7f
    or $(IM_BOOL | IM_INT | IM_FLOAT | IM_DATE), %r14
    jmp 8f
7:  or $(IM_ALL | IM_SEEN), %r14
8:  mov %r14, (%rbx)
9:  LEAVE

/* csv_mask_type(mask rdi) -> rax packed type */
csv_mask_type:
    mov $T_STR, %eax
    test $IM_SEEN, %edi
    jz 9f
    not %edi
    and $IM_ALL, %edi
    jz 9f
    bsf %edi, %ecx
    lea mask_types(%rip), %rdx
    movzbl (%rdx, %rcx), %eax
9:  ret

/* csv_convert(col rdi, row rsi, st rdx, rec rcx): stores the last scanned
 * field into column `col` at `row`; CONVERSION_ERROR on bad values. */
csv_convert:
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rcx, (%rsp)                /* record number */
    mov CS_FFLAGS(%rdx), %rax
    mov %rax, 8(%rsp)
    mov CS_FPTR(%rdx), %r14
    mov CS_FLEN(%rdx), %r15
    mov %rdx, %r13
    test %r15, %r15
    jnz 1f
    test $FQ_QUOTED, %eax
    jz .Lcc_null                    /* unquoted empty: NULL for every type */
1:  movzbl COL_TYPE(%rbx), %ecx
    cmp $T_STR, %ecx
    je .Lcc_str
    test %r15, %r15
    jz .Lcc_null                    /* quoted empty: NULL for non-strings */
    test $FQ_ESC, %eax
    jnz .Lcc_err
    mov %r14, %rdi
    mov %r15, %rsi
    call ing_trim
    test %rdx, %rdx
    jz .Lcc_null
    mov %rax, %r14
    mov %rdx, %r15
    mov %rax, %rdi
    mov %rdx, %rsi
    mov COL_TYPE(%rbx), %rdx
    call parse_typed
    test %edx, %edx
    jnz .Lcc_err
.Lcc_store:
    mov COL_DATA(%rbx), %rcx
    mov %rax, (%rcx, %r12, 8)
    LEAVE
.Lcc_str:
    mov g_pending_arena(%rip), %rdi
    mov %r13, %rsi
    call csv_field_pstr
    jmp .Lcc_store
.Lcc_null:
    mov COL_DATA(%rbx), %rcx
    movq $0, (%rcx, %r12, 8)
    mov COL_NULLS(%rbx), %rcx
    movb $1, (%rcx, %r12)
    LEAVE
.Lcc_err:
    cmp $200, %r15
    jbe 2f
    mov $200, %r15d
2:  mov %r14, %rdi
    mov %r15, %rsi
    call pstr_tmp
    lea 8(%rax), %r8
    mov $E_CONVERSION_ERROR, %edi
    CSTR %rsi, "CSV record %ld, column '%s': cannot convert value '%s'"
    mov (%rsp), %rdx
    mov COL_NAME(%rbx), %rcx
    add $8, %rcx
    call pq_raisef

/* ======================================================== ingest_csv */

#define C_ST     0
#define C_NAME   64
#define C_SCHEMA 72
#define C_HEADER 80
#define C_NCOLS  88
#define C_NROWS  96
#define C_NAMES  104
#define C_STRIDE 112
#define C_MASKS  120
#define C_START  128
#define C_TABLE  136
#define C_REC    144
#define C_VEC    160
#define C_LOCALS 192

FUNC ingest_csv
    ENTER C_LOCALS
    mov %rdi, C_NAME(%rsp)
    mov %rcx, C_SCHEMA(%rsp)
    mov %r8, C_HEADER(%rsp)
    mov %rsi, %r12                  /* data */
    mov %rdx, %r13                  /* len */
    movzbl %r9b, %r14d              /* delimiter */
    call arena_new
    mov %rax, g_pending_arena(%rip)
    mov %r13, %rdi
    call check_input_size
    /* skip a UTF-8 BOM */
    cmp $3, %r13
    jb 1f
    cmpb $0xEF, (%r12)
    jne 1f
    cmpb $0xBB, 1(%r12)
    jne 1f
    cmpb $0xBF, 2(%r12)
    jne 1f
    add $3, %r12
    sub $3, %r13
1:  mov %r12, C_ST+CS_POS(%rsp)
    lea (%r12, %r13), %rax
    mov %rax, C_ST+CS_END(%rsp)
    mov %r14, C_ST+CS_DELIM(%rsp)
    movq $0, C_REC(%rsp)
    cmpq $0, C_HEADER(%rsp)
    je .Lic_noheader

    /* ---- header record */
    lea C_ST(%rsp), %rdi
    call csv_skip_empty
    test %eax, %eax
    jnz 2f
    RAISE E_INGEST_ERROR, "CSV input has no header record"
2:  movq $1, C_REC(%rsp)
    lea C_VEC(%rsp), %rdi
    mov g_arena(%rip), %rsi
    call vec_init
3:  lea C_ST(%rsp), %rdi
    call csv_field
    mov g_arena(%rip), %rdi
    lea C_ST(%rsp), %rsi
    call csv_field_pstr
    lea C_VEC(%rsp), %rdi
    mov %rax, %rsi
    call vec_push
    cmpq $0, C_ST+CS_TERM(%rsp)
    je 3b
    mov C_SCHEMA(%rsp), %rbx
    test %rbx, %rbx
    jnz .Lic_hdr_schema
    mov C_VEC+VEC_DATA(%rsp), %rax
    mov %rax, C_NAMES(%rsp)
    mov C_VEC+VEC_LEN(%rsp), %rax
    mov %rax, C_NCOLS(%rsp)
    movq $8, C_STRIDE(%rsp)
    jmp .Lic_names

.Lic_hdr_schema:                    /* header must match the schema names */
    mov SC_NCOLS(%rbx), %rcx
    mov C_VEC+VEC_LEN(%rsp), %rdx
    cmp %rcx, %rdx
    je 4f
    mov $E_INGEST_ERROR, %edi
    CSTR %rsi, "CSV header has %ld columns but the schema has %ld"
    call pq_raisef
4:  xor %r15d, %r15d
5:  cmp SC_NCOLS(%rbx), %r15
    jae .Lic_schema_names
    mov C_VEC+VEC_DATA(%rsp), %rax
    mov (%rax, %r15, 8), %r12       /* header name */
    mov SC_COLS(%rbx), %rax
    mov %r15, %rcx
    shl $4, %rcx
    mov SCE_NAME(%rax, %rcx), %r13  /* schema name */
    lea 8(%r12), %rdi
    mov (%r12), %rsi
    lea 8(%r13), %rdx
    mov (%r13), %rcx
    call mem_ieq
    test %eax, %eax
    jnz 6f
    mov $E_INGEST_ERROR, %edi
    CSTR %rsi, "CSV header column '%s' does not match schema column '%s'"
    lea 8(%r12), %rdx
    lea 8(%r13), %rcx
    call pq_raisef
6:  inc %r15
    jmp 5b

.Lic_noheader:
    cmpq $0, C_SCHEMA(%rsp)
    jne .Lic_schema_names
    RAISE E_INGEST_ERROR, "CSV without a header requires a schema"
.Lic_schema_names:
    mov C_SCHEMA(%rsp), %rbx
    mov SC_NCOLS(%rbx), %rax
    mov %rax, C_NCOLS(%rsp)
    mov SC_COLS(%rbx), %rax
    mov %rax, C_NAMES(%rsp)
    movq $SCE_SIZE, C_STRIDE(%rsp)
.Lic_names:
    mov C_NAMES(%rsp), %rdi
    mov C_NCOLS(%rsp), %rsi
    mov C_STRIDE(%rsp), %rdx
    call check_names

    /* ---- pass 1: arity, row count, inference */
    mov C_ST+CS_POS(%rsp), %rax
    mov %rax, C_START(%rsp)
    movq $0, C_MASKS(%rsp)
    cmpq $0, C_SCHEMA(%rsp)
    jne 1f
    mov C_NCOLS(%rsp), %rdi
    shl $3, %rdi
    call tmp_zalloc
    mov %rax, C_MASKS(%rsp)
1:  movq $0, C_NROWS(%rsp)
.Lic_p1_rec:
    lea C_ST(%rsp), %rdi
    call csv_skip_empty
    test %eax, %eax
    jz .Lic_p1_done
    incq C_REC(%rsp)
    mov C_NROWS(%rsp), %rax
    inc %rax
    mov %rax, C_NROWS(%rsp)
    cmp g_max_table_rows(%rip), %rax
    jbe 2f
    call raise_row_limit
2:  xor %r15d, %r15d                /* field index */
.Lic_p1_field:
    lea C_ST(%rsp), %rdi
    call csv_field
    mov C_MASKS(%rsp), %rdi
    test %rdi, %rdi
    jz 3f
    cmp C_NCOLS(%rsp), %r15
    jae 3f
    lea (%rdi, %r15, 8), %rdi
    mov C_ST+CS_FPTR(%rsp), %rsi
    mov C_ST+CS_FLEN(%rsp), %rdx
    mov C_ST+CS_FFLAGS(%rsp), %rcx
    call csv_infer
3:  inc %r15
    cmpq $0, C_ST+CS_TERM(%rsp)
    je .Lic_p1_field
    cmp C_NCOLS(%rsp), %r15
    je .Lic_p1_rec
    mov $E_INGEST_ERROR, %edi
    CSTR %rsi, "CSV record %ld has %ld fields, expected %ld"
    mov C_REC(%rsp), %rdx
    mov %r15, %rcx
    mov C_NCOLS(%rsp), %r8
    call pq_raisef
.Lic_p1_done:

    /* ---- table and columns */
    mov C_NAME(%rsp), %rdi
    mov C_NCOLS(%rsp), %rsi
    mov C_NROWS(%rsp), %rdx
    call tbl_new
    mov %rax, C_TABLE(%rsp)
    xor %r15d, %r15d
.Lic_cols:
    cmp C_NCOLS(%rsp), %r15
    jae .Lic_cols_done
    mov C_SCHEMA(%rsp), %rax
    test %rax, %rax
    jz 1f
    mov SC_COLS(%rax), %rax
    mov %r15, %rcx
    shl $4, %rcx
    mov SCE_TYPE(%rax, %rcx), %rdx
    jmp 2f
1:  mov C_MASKS(%rsp), %rax
    mov (%rax, %r15, 8), %rdi
    call csv_mask_type
    mov %rax, %rdx
2:  mov C_STRIDE(%rsp), %rax
    imul %r15, %rax
    add C_NAMES(%rsp), %rax
    mov (%rax), %rsi
    mov C_TABLE(%rsp), %rax
    mov TB_COLS(%rax), %rdi
    mov %r15, %rcx
    shl $COL_SHIFT, %rcx
    add %rcx, %rdi
    mov C_NROWS(%rsp), %rcx
    call col_init
    inc %r15
    jmp .Lic_cols
.Lic_cols_done:

    /* ---- pass 2: conversion */
    mov C_START(%rsp), %rax
    mov %rax, C_ST+CS_POS(%rsp)
    xor %eax, %eax
    cmpq $0, C_HEADER(%rsp)
    setne %al
    mov %rax, C_REC(%rsp)
    xor %r12d, %r12d                /* row */
.Lic_p2_rec:
    lea C_ST(%rsp), %rdi
    call csv_skip_empty
    test %eax, %eax
    jz .Lic_done
    incq C_REC(%rsp)
    xor %r15d, %r15d
.Lic_p2_field:
    lea C_ST(%rsp), %rdi
    call csv_field
    mov C_TABLE(%rsp), %rax
    mov TB_COLS(%rax), %rdi
    mov %r15, %rcx
    shl $COL_SHIFT, %rcx
    add %rcx, %rdi
    mov %r12, %rsi
    lea C_ST(%rsp), %rdx
    mov C_REC(%rsp), %rcx
    call csv_convert
    inc %r15
    cmpq $0, C_ST+CS_TERM(%rsp)
    je .Lic_p2_field
    inc %r12
    jmp .Lic_p2_rec
.Lic_done:
    mov C_TABLE(%rsp), %rax
    LEAVE
ENDF ingest_csv

/* ======================================================== JSON */

/* json_find_col(key rdi, keylen rsi, hint rdx, names Vec* rcx) -> rax index
 * of the column whose name equals key (case-insensitive) or -1. */
json_find_col:
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rcx, %r13
    mov %rdx, %r14
    cmp VEC_LEN(%r13), %r14
    jae 2f
    mov VEC_DATA(%r13), %rax
    mov (%rax, %r14, 8), %rax
    mov %rbx, %rdi
    mov %r12, %rsi
    lea 8(%rax), %rdx
    mov (%rax), %rcx
    call mem_ieq
    test %eax, %eax
    jnz 8f
2:  xor %r14d, %r14d
3:  cmp VEC_LEN(%r13), %r14
    jae 7f
    mov VEC_DATA(%r13), %rax
    mov (%rax, %r14, 8), %rax
    mov %rbx, %rdi
    mov %r12, %rsi
    lea 8(%rax), %rdx
    mov (%rax), %rcx
    call mem_ieq
    test %eax, %eax
    jnz 8f
    inc %r14
    jmp 3b
7:  mov $-1, %rax
    LEAVE
8:  mov %r14, %rax
    LEAVE

/* json_infer(vals rdi node*[n], n rsi, name pstr* rdx) -> rax packed type */
json_infer:
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, (%rsp)
    xor %r13d, %r13d                /* index */
    xor %r14d, %r14d                /* kinds: 1 bool, 2 number, 4 string */
    xor %r15d, %r15d                /* 1 not-int, 2 not-date, 4 not-timestamp */
1:  cmp %r12, %r13
    jae 8f
    mov (%rbx, %r13, 8), %rax
    inc %r13
    test %rax, %rax
    jz 1b
    mov JN_TYPE(%rax), %rcx
    cmp $J_NULL, %rcx
    je 1b
    cmp $J_TRUE, %rcx
    ja 2f
    or $1, %r14d                    /* J_FALSE / J_TRUE */
    jmp 1b
2:  cmp $J_NUMBER, %rcx
    jne 4f
    or $2, %r14d
    test $1, %r15d
    jnz 1b
    testq $1, JN_FLAGS(%rax)
    jnz 3f
    mov JN_PTR(%rax), %rdi
    mov JN_LEN(%rax), %rsi
    call text_parse_int64
    test %edx, %edx
    jz 1b
3:  or $1, %r15d
    jmp 1b
4:  or $4, %r14d                    /* J_STRING (nested values were rejected) */
    test $4, %r15d
    jnz 1b
    push %rax
    push %rax
    mov JN_PTR(%rax), %rdi
    mov JN_LEN(%rax), %rsi
    call text_parse_date
    pop %rax
    pop %rax
    test %edx, %edx
    jz 1b
    or $2, %r15d
    mov JN_PTR(%rax), %rdi
    mov JN_LEN(%rax), %rsi
    mov $1, %edx
    call text_parse_timestamp
    test %edx, %edx
    jz 1b
    or $4, %r15d
    jmp 1b
8:  lea -1(%r14), %rax
    test %r14, %rax
    jz 9f
    mov $E_INGEST_ERROR, %edi
    CSTR %rsi, "JSON column '%s' mixes value types"
    mov (%rsp), %rdx
    add $8, %rdx
    call pq_raisef
9:  mov $T_STR, %eax
    cmp $1, %r14d
    jne 10f
    mov $T_BOOL, %eax
    jmp 12f
10: cmp $2, %r14d
    jne 11f
    mov $T_INT, %eax
    test $1, %r15d
    jz 12f
    mov $T_FLOAT, %eax
    jmp 12f
11: cmp $4, %r14d
    jne 12f
    mov $T_DATE, %eax
    test $2, %r15d
    jz 12f
    mov $T_TS, %eax
    test $4, %r15d
    jz 12f
    mov $T_STR, %eax
12: LEAVE

/* json_convert(col rdi, row rsi, node rdx | 0): stores one JSON value into
 * the column; CONVERSION_ERROR for unsupported combinations / bad text. */
json_convert:
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    test %r13, %r13
    jz .Ljc_null
    mov JN_TYPE(%r13), %r14
    cmp $J_NULL, %r14
    je .Ljc_null
    movzbl COL_TYPE(%rbx), %ecx
    cmp $T_BOOL, %ecx
    jne 1f
    cmp $J_TRUE, %r14
    je 2f
    cmp $J_FALSE, %r14
    jne .Ljc_err
    xor %eax, %eax
    jmp .Ljc_store
2:  mov $1, %eax
    jmp .Ljc_store
1:  cmp $T_STR, %ecx
    jne 3f
    cmp $J_STRING, %r14
    jne .Ljc_err
    mov g_pending_arena(%rip), %rdi
    mov JN_PTR(%r13), %rsi
    mov JN_LEN(%r13), %rdx
    call pstr_new
    jmp .Ljc_store
3:  cmp $J_STRING, %r14
    je 4f
    cmp $J_NUMBER, %r14
    jne .Ljc_err
    cmp $T_DATE, %ecx               /* numbers only become INT/FLOAT/DEC */
    je .Ljc_err
    cmp $T_TS, %ecx
    je .Ljc_err
4:  mov JN_PTR(%r13), %rdi
    mov JN_LEN(%r13), %rsi
    call ing_trim
    test %rdx, %rdx
    jz .Ljc_null
    mov %rax, %rdi
    mov %rdx, %rsi
    mov COL_TYPE(%rbx), %rdx
    call parse_typed
    test %edx, %edx
    jnz .Ljc_err
.Ljc_store:
    mov COL_DATA(%rbx), %rcx
    mov %rax, (%rcx, %r12, 8)
    LEAVE
.Ljc_null:
    mov COL_DATA(%rbx), %rcx
    movq $0, (%rcx, %r12, 8)
    mov COL_NULLS(%rbx), %rcx
    movb $1, (%rcx, %r12)
    LEAVE
.Ljc_err:
    mov $E_CONVERSION_ERROR, %edi
    CSTR %rsi, "JSON row %ld, column '%s': cannot convert value"
    lea 1(%r12), %rdx
    mov COL_NAME(%rbx), %rcx
    add $8, %rcx
    call pq_raisef

#define J_NAME   0
#define J_DATA   8
#define J_LEN    16
#define J_SCHEMA 24
#define J_LINES  32
#define J_ROWS   40
#define J_NROWS  48
#define J_LINENO 56
#define J_VROWS  64
#define J_VNAMES 96
#define J_VVALS  128
#define J_TABLE  160
#define J_NCOLS  168
#define J_NEXT   176
#define J_LOCALS 192

FUNC ingest_json
    ENTER J_LOCALS
    mov %rdi, J_NAME(%rsp)
    mov %rsi, J_DATA(%rsp)
    mov %rdx, J_LEN(%rsp)
    mov %rcx, J_SCHEMA(%rsp)
    mov %r8, J_LINES(%rsp)
    call arena_new
    mov %rax, g_pending_arena(%rip)
    mov J_DATA(%rsp), %r12
    mov J_LEN(%rsp), %r13
    mov %r13, %rdi
    call check_input_size
    cmp $3, %r13
    jb 1f
    cmpb $0xEF, (%r12)
    jne 1f
    cmpb $0xBB, 1(%r12)
    jne 1f
    cmpb $0xBF, 2(%r12)
    jne 1f
    add $3, %r12
    sub $3, %r13
1:  lea J_VNAMES(%rsp), %rdi
    mov g_arena(%rip), %rsi
    call vec_init
    lea J_VVALS(%rsp), %rdi
    mov g_arena(%rip), %rsi
    call vec_init
    cmpq $0, J_LINES(%rsp)
    jne .Lij_lines

    /* ---- JSON array document */
    mov %r12, %rdi
    mov %r13, %rsi
    mov g_arena(%rip), %rdx
    call json_parse
    test %rax, %rax
    jnz 2f
    RAISE E_INGEST_ERROR, "invalid JSON input"
2:  cmpq $J_ARRAY, JN_TYPE(%rax)
    je 3f
    RAISE E_INGEST_ERROR, "JSON input must be an array of objects"
3:  mov JN_PTR(%rax), %rcx
    mov %rcx, J_ROWS(%rsp)
    mov JN_LEN(%rax), %rcx
    mov %rcx, J_NROWS(%rsp)
    jmp .Lij_rows

    /* ---- JSON Lines */
.Lij_lines:
    lea J_VROWS(%rsp), %rdi
    mov g_arena(%rip), %rsi
    call vec_init
    add %r12, %r13                  /* r13 = end */
    movq $0, J_LINENO(%rsp)
.Lij_line:
    cmp %r13, %r12
    jae .Lij_lines_done
    incq J_LINENO(%rsp)
    mov %r12, %rdi
    mov $'\n', %esi
    mov %r13, %rdx
    sub %r12, %rdx
    call memchr
    lea 1(%rax), %rcx
    test %rax, %rax
    jnz 1f
    mov %r13, %rax
    mov %r13, %rcx
1:  mov %rcx, J_NEXT(%rsp)
    mov %r12, %rdi                  /* trim [rdi, rax) */
2:  cmp %rax, %rdi
    jae 6f
    movzbl (%rdi), %ecx
    cmp $' ', %ecx
    je 3f
    cmp $'\t', %ecx
    je 3f
    cmp $'\r', %ecx
    je 3f
    cmp $'\n', %ecx
    jne 4f
3:  inc %rdi
    jmp 2b
4:  movzbl -1(%rax), %ecx
    cmp $' ', %ecx
    je 5f
    cmp $'\t', %ecx
    je 5f
    cmp $'\r', %ecx
    je 5f
    cmp $'\n', %ecx
    jne 7f
5:  dec %rax
    jmp 4b                          /* rdi < rax holds: rdi is non-space */
7:  mov %rax, %rsi
    sub %rdi, %rsi
    mov g_arena(%rip), %rdx
    call json_parse
    test %rax, %rax
    jnz 8f
    mov $E_INGEST_ERROR, %edi
    CSTR %rsi, "invalid JSON on line %ld"
    mov J_LINENO(%rsp), %rdx
    call pq_raisef
8:  cmpq $J_OBJECT, JN_TYPE(%rax)
    je 9f
    mov $E_INGEST_ERROR, %edi
    CSTR %rsi, "JSON Lines line %ld is not an object"
    mov J_LINENO(%rsp), %rdx
    call pq_raisef
9:  lea J_VROWS(%rsp), %rdi
    mov %rax, %rsi
    call vec_push
6:  mov J_NEXT(%rsp), %r12
    jmp .Lij_line
.Lij_lines_done:
    mov J_VROWS+VEC_DATA(%rsp), %rax
    mov %rax, J_ROWS(%rsp)
    mov J_VROWS+VEC_LEN(%rsp), %rax
    mov %rax, J_NROWS(%rsp)

.Lij_rows:
    mov J_NROWS(%rsp), %rax
    cmp g_max_table_rows(%rip), %rax
    jbe 1f
    call raise_row_limit
1:  mov J_SCHEMA(%rsp), %rbx
    test %rbx, %rbx
    jz .Lij_dist
    mov SC_COLS(%rbx), %rdi
    mov SC_NCOLS(%rbx), %rsi
    mov $SCE_SIZE, %edx
    call check_names
    xor %r15d, %r15d
2:  cmp SC_NCOLS(%rbx), %r15
    jae .Lij_dist
    mov SC_COLS(%rbx), %rax
    mov %r15, %rcx
    shl $4, %rcx
    lea J_VNAMES(%rsp), %rdi
    mov SCE_NAME(%rax, %rcx), %rsi
    call vec_push
    mov J_NROWS(%rsp), %rdi
    shl $3, %rdi
    call tmp_zalloc
    lea J_VVALS(%rsp), %rdi
    mov %rax, %rsi
    call vec_push
    inc %r15
    jmp 2b

    /* ---- distribute member values into per-column node arrays */
.Lij_dist:
    xor %r12d, %r12d                /* row */
.Lij_row:
    cmp J_NROWS(%rsp), %r12
    jae .Lij_build
    mov J_ROWS(%rsp), %rax
    mov (%rax, %r12, 8), %rax
    cmpq $J_OBJECT, JN_TYPE(%rax)
    je 1f
    mov $E_INGEST_ERROR, %edi
    CSTR %rsi, "JSON array element %ld is not an object"
    lea 1(%r12), %rdx
    call pq_raisef
1:  mov JN_PTR(%rax), %r13          /* members */
    mov JN_LEN(%rax), %r14          /* member count */
    xor %r15d, %r15d
.Lij_mem:
    cmp %r14, %r15
    jae .Lij_row_next
    lea (%r15, %r15, 2), %rbx
    lea (%r13, %rbx, 8), %rbx       /* member */
    mov JM_VAL(%rbx), %rax
    cmpq $J_ARRAY, JN_TYPE(%rax)
    jb 2f
    mov $E_INGEST_ERROR, %edi
    CSTR %rsi, "nested JSON value for key '%s' in row %ld"
    mov JM_KEY(%rbx), %rdx
    lea 1(%r12), %rcx
    call pq_raisef
2:  mov JM_KEY(%rbx), %rdi
    mov JM_KEYLEN(%rbx), %rsi
    mov %r15, %rdx
    lea J_VNAMES(%rsp), %rcx
    call json_find_col
    test %rax, %rax
    jns 5f
    cmpq $0, J_SCHEMA(%rsp)
    je 3f
    mov $E_INGEST_ERROR, %edi
    CSTR %rsi, "JSON key '%s' is not in the schema"
    mov JM_KEY(%rbx), %rdx
    call pq_raisef
3:  cmpq $0, JM_KEYLEN(%rbx)
    jne 4f
    RAISE E_INGEST_ERROR, "empty column name"
4:  mov JM_KEY(%rbx), %rdi
    mov JM_KEYLEN(%rbx), %rsi
    call pstr_tmp
    lea J_VNAMES(%rsp), %rdi
    mov %rax, %rsi
    call vec_push
    mov J_NROWS(%rsp), %rdi
    shl $3, %rdi
    call tmp_zalloc
    lea J_VVALS(%rsp), %rdi
    mov %rax, %rsi
    call vec_push
    mov J_VNAMES+VEC_LEN(%rsp), %rax
    dec %rax
5:  mov J_VVALS+VEC_DATA(%rsp), %rcx
    mov (%rcx, %rax, 8), %rcx
    cmpq $0, (%rcx, %r12, 8)
    je 6f
    mov $E_INGEST_ERROR, %edi
    CSTR %rsi, "duplicate key '%s' in JSON row %ld"
    mov JM_KEY(%rbx), %rdx
    lea 1(%r12), %rcx
    call pq_raisef
6:  mov JM_VAL(%rbx), %rax
    mov %rax, (%rcx, %r12, 8)
    inc %r15
    jmp .Lij_mem
.Lij_row_next:
    inc %r12
    jmp .Lij_row

    /* ---- build the table */
.Lij_build:
    mov J_VNAMES+VEC_LEN(%rsp), %rax
    mov %rax, J_NCOLS(%rsp)
    mov J_NAME(%rsp), %rdi
    mov %rax, %rsi
    mov J_NROWS(%rsp), %rdx
    call tbl_new
    mov %rax, J_TABLE(%rsp)
    xor %r15d, %r15d
.Lij_col:
    cmp J_NCOLS(%rsp), %r15
    jae .Lij_done
    mov J_VVALS+VEC_DATA(%rsp), %rax
    mov (%rax, %r15, 8), %r13       /* node*[nrows] */
    mov J_VNAMES+VEC_DATA(%rsp), %rax
    mov (%rax, %r15, 8), %r14       /* name */
    mov J_SCHEMA(%rsp), %rax
    test %rax, %rax
    jz 1f
    mov SC_COLS(%rax), %rax
    mov %r15, %rcx
    shl $4, %rcx
    mov SCE_TYPE(%rax, %rcx), %rdx
    jmp 2f
1:  mov %r13, %rdi
    mov J_NROWS(%rsp), %rsi
    mov %r14, %rdx
    call json_infer
    mov %rax, %rdx
2:  mov J_TABLE(%rsp), %rax
    mov TB_COLS(%rax), %rbx
    mov %r15, %rcx
    shl $COL_SHIFT, %rcx
    add %rcx, %rbx                  /* Column* */
    mov %rbx, %rdi
    mov %r14, %rsi
    mov J_NROWS(%rsp), %rcx
    call col_init
    xor %r12d, %r12d
3:  cmp J_NROWS(%rsp), %r12
    jae 4f
    mov %rbx, %rdi
    mov %r12, %rsi
    mov (%r13, %r12, 8), %rdx
    call json_convert
    inc %r12
    jmp 3b
4:  inc %r15
    jmp .Lij_col
.Lij_done:
    mov J_TABLE(%rsp), %rax
    LEAVE
ENDF ingest_json
