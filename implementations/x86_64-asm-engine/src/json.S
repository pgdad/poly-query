/*
 * json.S - strict RFC 8259 JSON parser producing an arena-allocated DOM, plus
 * a compact serializer and small accessors.
 *
 * Exported (System V ABI):
 *   json_parse(ptr rdi, len rsi, arena rdx) -> rax node* | 0 on syntax error
 *   json_write(buf rdi, node rsi)
 *   json_obj_get(node rdi, key_cstr rsi) -> rax value node* | 0
 *   json_is_int(node rdi) -> eax 1/0, rdx = int64 value
 *
 * Strictness notes
 *   - exactly one value, optional surrounding space/tab/CR/LF
 *   - number grammar -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?
 *   - raw bytes inside strings must be well-formed UTF-8 (no overlongs, no
 *     encoded surrogates, nothing above U+10FFFF); bytes < 0x20 are errors
 *   - \uXXXX surrogate pairs become one 4-byte UTF-8 sequence; LONE
 *     SURROGATES (high without a following \uDC00-\uDFFF, or a bare low one)
 *     ARE REJECTED, so decoded strings are always valid UTF-8
 *   - \u0000 is accepted and yields an embedded NUL byte (JN_LEN counts it)
 *   - nesting depth limit 512 (arrays + objects); deeper input -> 0
 *
 * Parser internals (not ABI functions; they share global registers):
 *   r12 = cursor, r13 = end of input, r14 = arena, r15 = nesting depth,
 *   rbx = scratch Vec* (pending array elements / object member triples),
 *   rbp = frame of json_parse.  Any syntax error jumps to json_err, which
 *   unwinds the whole recursion through json_parse's rbp-based epilogue.
 */
#include "pq.inc"

    .section .note.GNU-stack, "", @progbits

#define MAX_DEPTH 512

    .text

/* SKIPWS: skip JSON whitespace at r12; eax = next byte or -1 at end */
.macro SKIPWS
.Lws_loop\@:
    mov $-1, %eax
    cmp %r13, %r12
    jae .Lws_done\@
    movzbl (%r12), %eax
    cmp $0x20, %eax
    ja .Lws_done\@
    je .Lws_adv\@
    cmp $0x0a, %eax
    je .Lws_adv\@
    cmp $0x09, %eax
    je .Lws_adv\@
    cmp $0x0d, %eax
    jne .Lws_done\@
.Lws_adv\@:
    inc %r12
    jmp .Lws_loop\@
.Lws_done\@:
.endm

/* VPUSH reg: append reg (not rcx/rdx/rsi/rdi) to the scratch Vec in rbx.
 * Requires 16-byte aligned rsp (may call vec_push). */
.macro VPUSH reg
    mov VEC_LEN(%rbx), %rcx
    cmp VEC_CAP(%rbx), %rcx
    jae .Lvp_slow\@
    mov VEC_DATA(%rbx), %rdx
    mov \reg, (%rdx, %rcx, 8)
    inc %rcx
    mov %rcx, VEC_LEN(%rbx)
    jmp .Lvp_done\@
.Lvp_slow\@:
    mov \reg, %rsi
    mov %rbx, %rdi
    call vec_push
.Lvp_done\@:
.endm

/* ======================================================== json_parse */

/* json_parse(ptr rdi, len rsi, arena rdx) -> rax node* or 0 */
FUNC json_parse
    ENTER 48                        /* 0..31: scratch Vec, 32: result */
    mov %rdi, %r12
    lea (%rdi, %rsi), %r13
    mov %rdx, %r14
    xor %r15d, %r15d
    mov %rsp, %rbx
    mov %rbx, %rdi
    mov %r14, %rsi
    call vec_init
    call jp_value
    mov %rax, 32(%rsp)
    SKIPWS
    cmp $-1, %eax
    jne json_err
    mov 32(%rsp), %rax
    LEAVE
ENDF json_parse

/* error exit for every parser routine: unwinds to json_parse's caller */
json_err:
    xor %eax, %eax
    LEAVE

/* jp_value: parse one value (leading whitespace allowed) -> rax node* */
jp_value:
    sub $8, %rsp                    /* rsp now 16-byte aligned */
    SKIPWS
    cmp $0x22, %eax                 /* " */
    je .Lv_str
    cmp $0x5b, %eax                 /* [ */
    je .Lv_arr
    cmp $0x7b, %eax                 /* { */
    je .Lv_obj
    cmp $0x74, %eax                 /* t */
    je .Lv_true
    cmp $0x66, %eax                 /* f */
    je .Lv_false
    cmp $0x6e, %eax                 /* n */
    je .Lv_null
    cmp $0x2d, %eax                 /* - */
    je .Lv_num
    lea -0x30(%rax), %ecx
    cmp $9, %ecx
    jbe .Lv_num
    jmp json_err

/* ---- literals */
.Lv_true:
    mov %r13, %rcx
    sub %r12, %rcx
    cmp $4, %rcx
    jb json_err
    cmpl $0x65757274, (%r12)        /* "true" */
    jne json_err
    add $4, %r12
    mov $J_TRUE, %edi
    jmp .Lv_lit
.Lv_null:
    mov %r13, %rcx
    sub %r12, %rcx
    cmp $4, %rcx
    jb json_err
    cmpl $0x6c6c756e, (%r12)        /* "null" */
    jne json_err
    add $4, %r12
    mov $J_NULL, %edi
    jmp .Lv_lit
.Lv_false:
    mov %r13, %rcx
    sub %r12, %rcx
    cmp $5, %rcx
    jb json_err
    cmpl $0x736c6166, (%r12)        /* "fals" */
    jne json_err
    cmpb $0x65, 4(%r12)             /* e */
    jne json_err
    add $5, %r12
    mov $J_FALSE, %edi
.Lv_lit:
    xor %esi, %esi
    xor %edx, %edx
    xor %ecx, %ecx
    call jp_node
    add $8, %rsp
    ret

/* ---- string */
.Lv_str:
    call jp_string                  /* rax = bytes, rdx = len */
    mov %rax, %rsi
    mov $J_STRING, %edi
    xor %ecx, %ecx
    call jp_node
    add $8, %rsp
    ret

/* ---- number: rsi = scan cursor, r8 = flags */
.Lv_num:
    mov %r12, %rsi
    xor %r8d, %r8d
    cmpb $0x2d, (%rsi)
    jne .Ln_int
    inc %rsi
.Ln_int:
    cmp %r13, %rsi
    jae json_err
    movzbl (%rsi), %eax
    cmp $0x30, %eax
    je .Ln_zero
    lea -0x31(%rax), %ecx
    cmp $8, %ecx
    ja json_err
.Ln_intdig:
    inc %rsi
    cmp %r13, %rsi
    jae .Ln_done
    movzbl (%rsi), %eax
    lea -0x30(%rax), %ecx
    cmp $9, %ecx
    jbe .Ln_intdig
    jmp .Ln_frac
.Ln_zero:
    inc %rsi
    cmp %r13, %rsi
    jae .Ln_done
    movzbl (%rsi), %eax
.Ln_frac:                           /* eax = current byte, rsi < end */
    cmp $0x2e, %eax                 /* . */
    jne .Ln_exp
    mov $1, %r8d
    inc %rsi
    cmp %r13, %rsi
    jae json_err
    movzbl (%rsi), %eax
    lea -0x30(%rax), %ecx
    cmp $9, %ecx
    ja json_err
.Ln_fracdig:
    inc %rsi
    cmp %r13, %rsi
    jae .Ln_done
    movzbl (%rsi), %eax
    lea -0x30(%rax), %ecx
    cmp $9, %ecx
    jbe .Ln_fracdig
.Ln_exp:                            /* eax = current byte, rsi < end */
    mov %eax, %ecx
    or $0x20, %ecx
    cmp $0x65, %ecx                 /* e or E */
    jne .Ln_done
    mov $1, %r8d
    inc %rsi
    cmp %r13, %rsi
    jae json_err
    movzbl (%rsi), %eax
    cmp $0x2b, %eax                 /* + */
    je .Ln_sign
    cmp $0x2d, %eax                 /* - */
    jne .Ln_expfirst
.Ln_sign:
    inc %rsi
    cmp %r13, %rsi
    jae json_err
    movzbl (%rsi), %eax
.Ln_expfirst:
    lea -0x30(%rax), %ecx
    cmp $9, %ecx
    ja json_err
.Ln_expdig:
    inc %rsi
    cmp %r13, %rsi
    jae .Ln_done
    movzbl (%rsi), %eax
    lea -0x30(%rax), %ecx
    cmp $9, %ecx
    jbe .Ln_expdig
.Ln_done:
    sub $16, %rsp                   /* 0: number end, 8: flags */
    mov %rsi, 0(%rsp)
    mov %r8, 8(%rsp)
    mov %rsi, %rdx
    sub %r12, %rdx
    mov %r12, %rsi
    mov %r14, %rdi
    call pstr_new                   /* NUL-terminated pstr copy */
    mov 0(%rsp), %r12
    lea PSTR_DATA(%rax), %rsi
    mov PSTR_LEN(%rax), %rdx
    mov 8(%rsp), %rcx
    mov $J_NUMBER, %edi
    call jp_node
    add $24, %rsp
    ret

/* ---- array */
.Lv_arr:
    inc %r15
    cmp $MAX_DEPTH, %r15
    ja json_err
    inc %r12
    pushq VEC_LEN(%rbx)             /* 8(%rsp): first scratch index */
    sub $8, %rsp
    SKIPWS
    cmp $0x5d, %eax                 /* ] */
    je .La_end
.La_next:
    call jp_value
    VPUSH %rax
    SKIPWS
    cmp $0x2c, %eax                 /* , */
    jne .La_close
    inc %r12
    jmp .La_next                    /* jp_value rejects a following ']' */
.La_close:
    cmp $0x5d, %eax
    jne json_err
.La_end:
    inc %r12
    dec %r15
    mov 8(%rsp), %rdi
    call jp_collect                 /* rax = node*[], rdx = count */
    mov %rax, %rsi
    mov $J_ARRAY, %edi
    xor %ecx, %ecx
    call jp_node
    add $24, %rsp
    ret

/* ---- object: members are pushed as key, keylen, value triples */
.Lv_obj:
    inc %r15
    cmp $MAX_DEPTH, %r15
    ja json_err
    inc %r12
    pushq VEC_LEN(%rbx)             /* 8(%rsp): first scratch index */
    sub $8, %rsp                    /* 0(%rsp): temp */
    SKIPWS
    cmp $0x7d, %eax                 /* } */
    je .Lo_end
.Lo_member:
    cmp $0x22, %eax                 /* key must be a string */
    jne json_err
    call jp_string
    mov %rdx, 0(%rsp)
    VPUSH %rax
    mov 0(%rsp), %rax
    VPUSH %rax
    SKIPWS
    cmp $0x3a, %eax                 /* : */
    jne json_err
    inc %r12
    call jp_value
    VPUSH %rax
    SKIPWS
    cmp $0x2c, %eax                 /* , */
    jne .Lo_close
    inc %r12
    SKIPWS
    jmp .Lo_member
.Lo_close:
    cmp $0x7d, %eax
    jne json_err
.Lo_end:
    inc %r12
    dec %r15
    mov 8(%rsp), %rdi
    call jp_collect                 /* rax = member[], rdx = 3 * count */
    mov %rax, %rsi
    mov %rdx, %rax
    xor %edx, %edx
    mov $3, %ecx
    div %rcx
    mov %rax, %rdx
    mov $J_OBJECT, %edi
    xor %ecx, %ecx
    call jp_node
    add $24, %rsp
    ret

/* jp_node(type edi, ptr rsi, len rdx, flags rcx) -> rax new node */
jp_node:
    sub $40, %rsp
    mov %rdi, 0(%rsp)
    mov %rsi, 8(%rsp)
    mov %rdx, 16(%rsp)
    mov %rcx, 24(%rsp)
    mov %r14, %rdi
    mov $JN_SIZE, %esi
    call arena_alloc
    mov 0(%rsp), %rcx
    mov %rcx, JN_TYPE(%rax)
    mov 8(%rsp), %rcx
    mov %rcx, JN_PTR(%rax)
    mov 16(%rsp), %rcx
    mov %rcx, JN_LEN(%rax)
    mov 24(%rsp), %rcx
    mov %rcx, JN_FLAGS(%rax)
    add $40, %rsp
    ret

/* jp_collect(start rdi): move scratch entries [start, len) into a fresh arena
 * array and truncate the scratch Vec back to start.
 * -> rax array (0 when empty), rdx entry count */
jp_collect:
    push %rdi                       /* 16(%rsp) */
    sub $16, %rsp                   /* 0: count, 8: array */
    mov VEC_LEN(%rbx), %rax
    sub %rdi, %rax
    mov %rax, 0(%rsp)
    movq $0, 8(%rsp)
    test %rax, %rax
    jz .Lc_done
    mov %r14, %rdi
    lea (, %rax, 8), %rsi
    call arena_alloc
    mov %rax, 8(%rsp)
    mov %rax, %rdi
    mov 16(%rsp), %rsi
    shl $3, %rsi
    add VEC_DATA(%rbx), %rsi
    mov 0(%rsp), %rdx
    shl $3, %rdx
    call memcpy
.Lc_done:
    mov 16(%rsp), %rax
    mov %rax, VEC_LEN(%rbx)
    mov 8(%rsp), %rax
    mov 0(%rsp), %rdx
    add $24, %rsp
    ret

/* jp_hex4(ptr r8) -> ecx value of 4 hex digits, r8 += 4.
 * Clobbers eax, edx, r9.  Caller guarantees 4 readable bytes. */
jp_hex4:
    xor %ecx, %ecx
    mov $4, %edx
.Lh_loop:
    movzbl (%r8), %eax
    lea -0x30(%rax), %r9d
    cmp $9, %r9d
    jbe .Lh_dig
    or $0x20, %eax
    lea -0x61(%rax), %r9d
    cmp $5, %r9d
    ja json_err
    add $10, %r9d
.Lh_dig:
    shl $4, %ecx
    or %r9d, %ecx
    inc %r8
    dec %edx
    jnz .Lh_loop
    ret

/* jp_string: r12 at the opening quote.  Decodes into a fresh pstr.
 * -> rax = pstr data (pstr + 8), rdx = byte length; r12 past closing quote */
jp_string:
    sub $24, %rsp                   /* 0: closing quote ptr, 8: has escapes, 16: pstr */
    inc %r12
    mov %r12, %rsi
    xor %ecx, %ecx
    /* pass 1: find the closing quote, validate raw bytes */
.Ls_scan:
    cmp %r13, %rsi
    jae json_err
    movzbl (%rsi), %eax
    cmp $0x22, %eax
    je .Ls_scanned
    cmp $0x5c, %eax
    je .Ls_bs
    cmp $0x20, %eax
    jb json_err
    cmp $0x80, %eax
    jae .Ls_utf8
    inc %rsi
    jmp .Ls_scan
.Ls_bs:
    mov $1, %ecx                    /* escape; next byte checked in pass 2 */
    add $2, %rsi
    jmp .Ls_scan
.Ls_utf8:
    /* edx = continuation count, r8d/r9d = allowed range of 2nd byte */
    mov $0x80, %r8d
    mov $0xbf, %r9d
    cmp $0xc2, %eax
    jb json_err
    cmp $0xdf, %eax
    ja .Ls_u3
    mov $1, %edx
    jmp .Ls_uchk
.Ls_u3:
    cmp $0xef, %eax
    ja .Ls_u4
    mov $2, %edx
    cmp $0xe0, %eax
    jne .Ls_u3b
    mov $0xa0, %r8d                 /* no overlongs */
.Ls_u3b:
    cmp $0xed, %eax
    jne .Ls_uchk
    mov $0x9f, %r9d                 /* no surrogates */
    jmp .Ls_uchk
.Ls_u4:
    cmp $0xf4, %eax
    ja json_err
    mov $3, %edx
    cmp $0xf0, %eax
    jne .Ls_u4b
    mov $0x90, %r8d                 /* no overlongs */
.Ls_u4b:
    cmp $0xf4, %eax
    jne .Ls_uchk
    mov $0x8f, %r9d                 /* <= U+10FFFF */
.Ls_uchk:
    mov %r13, %r10
    sub %rsi, %r10
    cmp %rdx, %r10
    jbe json_err                    /* need 1 + edx bytes */
    movzbl 1(%rsi), %eax
    cmp %r8d, %eax
    jb json_err
    cmp %r9d, %eax
    ja json_err
    cmp $2, %edx
    jb .Ls_uok
    movzbl 2(%rsi), %eax
    and $0xc0, %eax
    cmp $0x80, %eax
    jne json_err
    cmp $3, %edx
    jb .Ls_uok
    movzbl 3(%rsi), %eax
    and $0xc0, %eax
    cmp $0x80, %eax
    jne json_err
.Ls_uok:
    lea 1(%rsi, %rdx), %rsi
    jmp .Ls_scan

.Ls_scanned:
    mov %rsi, 0(%rsp)
    mov %rcx, 8(%rsp)
    mov %rsi, %rax
    sub %r12, %rax                  /* raw length >= decoded length */
    lea 9(%rax), %rsi
    mov %r14, %rdi
    call arena_alloc
    mov %rax, 16(%rsp)
    lea PSTR_DATA(%rax), %rdi
    cmpq $0, 8(%rsp)
    jne .Ls_decode
    mov 0(%rsp), %rdx
    sub %r12, %rdx
    mov %r12, %rsi
    call memcpy
    mov 0(%rsp), %rdx
    sub %r12, %rdx
    jmp .Ls_fin

    /* pass 2: decode escapes; r10 = closing quote, rdi = output cursor */
.Ls_decode:
    mov 0(%rsp), %r10
.Ls_d:
    cmp %r10, %r12
    jae .Ls_ddone
    movzbl (%r12), %eax
    cmp $0x5c, %eax
    je .Ls_desc
    mov %al, (%rdi)
    inc %rdi
    inc %r12
    jmp .Ls_d
.Ls_desc:
    movzbl 1(%r12), %eax            /* in bounds: pass 1 skipped it */
    add $2, %r12
    cmp $0x75, %eax                 /* u */
    je .Ls_du
    cmp $0x22, %eax
    je .Ls_dput
    cmp $0x5c, %eax
    je .Ls_dput
    cmp $0x2f, %eax
    je .Ls_dput
    mov $0x08, %ecx
    cmp $0x62, %eax                 /* b */
    je .Ls_dputc
    mov $0x0c, %ecx
    cmp $0x66, %eax                 /* f */
    je .Ls_dputc
    mov $0x0a, %ecx
    cmp $0x6e, %eax                 /* n */
    je .Ls_dputc
    mov $0x0d, %ecx
    cmp $0x72, %eax                 /* r */
    je .Ls_dputc
    mov $0x09, %ecx
    cmp $0x74, %eax                 /* t */
    je .Ls_dputc
    jmp json_err
.Ls_dputc:
    mov %ecx, %eax
.Ls_dput:
    mov %al, (%rdi)
    inc %rdi
    jmp .Ls_d
.Ls_du:
    lea 4(%r12), %rax
    cmp %r10, %rax
    ja json_err
    mov %r12, %r8
    call jp_hex4
    mov %r8, %r12
    mov %ecx, %eax
    and $0xfffff800, %eax
    cmp $0xd800, %eax
    jne .Ls_enc
    cmp $0xdc00, %ecx
    jae json_err                    /* lone low surrogate */
    lea 6(%r12), %rax
    cmp %r10, %rax
    ja json_err                     /* lone high surrogate */
    cmpb $0x5c, (%r12)
    jne json_err
    cmpb $0x75, 1(%r12)
    jne json_err
    mov %ecx, %r11d
    lea 2(%r12), %r8
    call jp_hex4
    mov %r8, %r12
    lea -0xdc00(%rcx), %eax
    cmp $0x3ff, %eax
    ja json_err
    lea -0xd800(%r11), %ecx
    shl $10, %ecx
    lea 0x10000(%rcx, %rax), %ecx
.Ls_enc:                            /* UTF-8 encode code point ecx */
    cmp $0x80, %ecx
    jae .Ls_e2
    mov %cl, (%rdi)
    inc %rdi
    jmp .Ls_d
.Ls_e2:
    cmp $0x800, %ecx
    jae .Ls_e3
    mov %ecx, %eax
    shr $6, %eax
    or $0xc0, %eax
    mov %al, (%rdi)
    mov %ecx, %eax
    and $0x3f, %eax
    or $0x80, %eax
    mov %al, 1(%rdi)
    add $2, %rdi
    jmp .Ls_d
.Ls_e3:
    cmp $0x10000, %ecx
    jae .Ls_e4
    mov %ecx, %eax
    shr $12, %eax
    or $0xe0, %eax
    mov %al, (%rdi)
    mov %ecx, %eax
    shr $6, %eax
    and $0x3f, %eax
    or $0x80, %eax
    mov %al, 1(%rdi)
    mov %ecx, %eax
    and $0x3f, %eax
    or $0x80, %eax
    mov %al, 2(%rdi)
    add $3, %rdi
    jmp .Ls_d
.Ls_e4:
    mov %ecx, %eax
    shr $18, %eax
    or $0xf0, %eax
    mov %al, (%rdi)
    mov %ecx, %eax
    shr $12, %eax
    and $0x3f, %eax
    or $0x80, %eax
    mov %al, 1(%rdi)
    mov %ecx, %eax
    shr $6, %eax
    and $0x3f, %eax
    or $0x80, %eax
    mov %al, 2(%rdi)
    mov %ecx, %eax
    and $0x3f, %eax
    or $0x80, %eax
    mov %al, 3(%rdi)
    add $4, %rdi
    jmp .Ls_d
.Ls_ddone:
    mov 16(%rsp), %rax
    lea PSTR_DATA(%rax), %rdx
    neg %rdx
    add %rdi, %rdx                  /* decoded length */
.Ls_fin:
    mov 16(%rsp), %rax
    mov %rdx, PSTR_LEN(%rax)
    movb $0, PSTR_DATA(%rax, %rdx)
    add $PSTR_DATA, %rax
    mov 0(%rsp), %r12
    inc %r12                        /* past closing quote */
    add $24, %rsp
    ret

/* ======================================================== json_write */

/* json_write(buf rdi, node rsi): compact serialization */
FUNC json_write
    STACK_CHECK
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov JN_TYPE(%r12), %rax
    cmp $J_NUMBER, %rax
    je .Lw_num
    cmp $J_STRING, %rax
    je .Lw_str
    cmp $J_ARRAY, %rax
    je .Lw_arr
    cmp $J_OBJECT, %rax
    je .Lw_obj
    cmp $J_TRUE, %rax
    je .Lw_true
    cmp $J_FALSE, %rax
    je .Lw_false
    PUTS %rbx, "null"
    jmp .Lw_ret
.Lw_true:
    PUTS %rbx, "true"
    jmp .Lw_ret
.Lw_false:
    PUTS %rbx, "false"
    jmp .Lw_ret
.Lw_num:
    mov %rbx, %rdi
    mov JN_PTR(%r12), %rsi
    mov JN_LEN(%r12), %rdx
    call buf_put
    jmp .Lw_ret
.Lw_str:
    mov %rbx, %rdi
    mov JN_PTR(%r12), %rsi
    mov JN_LEN(%r12), %rdx
    call buf_put_json_str
    jmp .Lw_ret
.Lw_arr:
    mov %rbx, %rdi
    mov $0x5b, %esi
    call buf_putc
    mov JN_PTR(%r12), %r13
    mov JN_LEN(%r12), %r14
    xor %r15d, %r15d
.Lw_aloop:
    cmp %r14, %r15
    jae .Lw_aend
    test %r15, %r15
    jz .Lw_aelem
    mov %rbx, %rdi
    mov $0x2c, %esi
    call buf_putc
.Lw_aelem:
    mov %rbx, %rdi
    mov (%r13, %r15, 8), %rsi
    call json_write
    inc %r15
    jmp .Lw_aloop
.Lw_aend:
    mov %rbx, %rdi
    mov $0x5d, %esi
    call buf_putc
    jmp .Lw_ret
.Lw_obj:
    mov %rbx, %rdi
    mov $0x7b, %esi
    call buf_putc
    mov JN_PTR(%r12), %r13          /* member cursor */
    mov JN_LEN(%r12), %r14
    xor %r15d, %r15d
.Lw_oloop:
    cmp %r14, %r15
    jae .Lw_oend
    test %r15, %r15
    jz .Lw_omem
    mov %rbx, %rdi
    mov $0x2c, %esi
    call buf_putc
.Lw_omem:
    mov %rbx, %rdi
    mov JM_KEY(%r13), %rsi
    mov JM_KEYLEN(%r13), %rdx
    call buf_put_json_str
    mov %rbx, %rdi
    mov $0x3a, %esi
    call buf_putc
    mov %rbx, %rdi
    mov JM_VAL(%r13), %rsi
    call json_write
    add $JM_SIZE, %r13
    inc %r15
    jmp .Lw_oloop
.Lw_oend:
    mov %rbx, %rdi
    mov $0x7d, %esi
    call buf_putc
.Lw_ret:
    LEAVE
ENDF json_write

/* ======================================================== accessors */

/* json_obj_get(node rdi, key_cstr rsi) -> rax value of first matching member or 0 */
FUNC json_obj_get
    test %rdi, %rdi
    jz .Lg_none
    cmpq $J_OBJECT, JN_TYPE(%rdi)
    jne .Lg_none
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    mov JN_PTR(%rdi), %rbx          /* member cursor */
    mov JN_LEN(%rdi), %r14          /* remaining */
    mov %rsi, %r12
    mov %rsi, %rdi
    call strlen
    mov %rax, %r13
.Lg_loop:
    test %r14, %r14
    jz .Lg_miss
    cmp %r13, JM_KEYLEN(%rbx)
    jne .Lg_next
    mov JM_KEY(%rbx), %rdi
    mov %r12, %rsi
    mov %r13, %rdx
    call memcmp
    test %eax, %eax
    jnz .Lg_next
    mov JM_VAL(%rbx), %rax
    jmp .Lg_out
.Lg_next:
    add $JM_SIZE, %rbx
    dec %r14
    jmp .Lg_loop
.Lg_miss:
    xor %eax, %eax
.Lg_out:
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    ret
.Lg_none:
    xor %eax, %eax
    ret
ENDF json_obj_get

/* json_is_int(node rdi) -> eax 1 if an integer literal fitting int64, rdx = value */
FUNC json_is_int
    xor %eax, %eax
    xor %edx, %edx
    test %rdi, %rdi
    jz .Li_ret
    cmpq $J_NUMBER, JN_TYPE(%rdi)
    jne .Li_ret
    testq $1, JN_FLAGS(%rdi)
    jnz .Li_ret
    mov JN_PTR(%rdi), %rsi
    mov JN_LEN(%rdi), %rcx
    xor %r8d, %r8d                  /* negative flag */
    test %rcx, %rcx
    jz .Li_no
    cmpb $0x2d, (%rsi)
    jne .Li_digits
    mov $1, %r8d
    inc %rsi
    dec %rcx
    jz .Li_no
.Li_digits:
    xor %r9d, %r9d                  /* unsigned magnitude */
    mov $10, %r10d
.Li_loop:
    movzbl (%rsi), %r11d
    sub $0x30, %r11d
    cmp $9, %r11d
    ja .Li_no
    mov %r9, %rax
    mul %r10
    jc .Li_no
    add %r11, %rax
    jc .Li_no
    mov %rax, %r9
    inc %rsi
    dec %rcx
    jnz .Li_loop
    mov $0x8000000000000000, %rax
    test %r8d, %r8d
    jnz .Li_neg
    cmp %rax, %r9
    jae .Li_no
    mov %r9, %rdx
    mov $1, %eax
    ret
.Li_neg:
    cmp %rax, %r9
    ja .Li_no
    mov %r9, %rdx
    neg %rdx
    mov $1, %eax
    ret
.Li_no:
    xor %eax, %eax
    xor %edx, %edx
.Li_ret:
    ret
ENDF json_is_int
