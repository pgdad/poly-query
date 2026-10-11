// =============================================================================
// lexer.S — SQL tokenizer (grammar.md §1)
//
// lex_tokenize converts the complete statement text into an array of Token
// records (layout in lexer.inc) allocated in the request arena and terminated
// by a TK_EOF token. Every token records its 1-based line and column; columns
// count UTF-8 characters (continuation bytes 10xxxxxx are not counted).
//
// Recognised:
//   * whitespace (space, tab, CR, LF), `-- ...` line comments and
//     `/* ... */` block comments (not nested; unterminated => PARSE_ERROR)
//   * unquoted identifiers [A-Za-z_][A-Za-z0-9_]*, checked against the
//     reserved keyword list (case-insensitive) -> KW_* token kinds
//   * double-quoted identifiers ("" = escaped quote), never keywords
//   * numbers: digits, digits.digits?, .digits, optional [eE][+-]?digits;
//     the form is recorded in TK_AUX (TKN_DOT / TKN_EXP). A number directly
//     followed by an identifier character is malformed (PARSE_ERROR).
//   * strings '...' ('' = escaped quote); unterminated => PARSE_ERROR
//   * operators / punctuation  + - * / % || = <> != < <= > >= ( ) , . ;
// Any other character => PARSE_ERROR.
// =============================================================================
#include "pq.inc"
#include "lexer.inc"

#define LEX_INITIAL_CAP  64     // initial token array capacity
#define ERRTEXT_MAX      64     // max bytes of source text quoted in messages

// ------------------------------------------------------------------ data -----
    .section .rodata
// Keyword table: entries of (u8 length, uppercase spelling), terminated by a
// zero length byte. The order MUST match the KW_* numbering in lexer.inc.
kw_table:
    .byte 3
    .ascii "ALL"
    .byte 3
    .ascii "AND"
    .byte 2
    .ascii "AS"
    .byte 3
    .ascii "ASC"
    .byte 7
    .ascii "BETWEEN"
    .byte 2
    .ascii "BY"
    .byte 4
    .ascii "CASE"
    .byte 4
    .ascii "CAST"
    .byte 6
    .ascii "CREATE"
    .byte 5
    .ascii "CROSS"
    .byte 4
    .ascii "DATE"
    .byte 4
    .ascii "DESC"
    .byte 8
    .ascii "DISTINCT"
    .byte 4
    .ascii "DROP"
    .byte 4
    .ascii "ELSE"
    .byte 3
    .ascii "END"
    .byte 6
    .ascii "EXISTS"
    .byte 7
    .ascii "EXPLAIN"
    .byte 5
    .ascii "FALSE"
    .byte 5
    .ascii "FIRST"
    .byte 4
    .ascii "FROM"
    .byte 4
    .ascii "FULL"
    .byte 5
    .ascii "GROUP"
    .byte 6
    .ascii "HAVING"
    .byte 2
    .ascii "IF"
    .byte 2
    .ascii "IN"
    .byte 5
    .ascii "INDEX"
    .byte 5
    .ascii "INNER"
    .byte 2
    .ascii "IS"
    .byte 4
    .ascii "JOIN"
    .byte 4
    .ascii "LAST"
    .byte 4
    .ascii "LEFT"
    .byte 4
    .ascii "LIKE"
    .byte 5
    .ascii "LIMIT"
    .byte 3
    .ascii "NOT"
    .byte 4
    .ascii "NULL"
    .byte 5
    .ascii "NULLS"
    .byte 6
    .ascii "OFFSET"
    .byte 2
    .ascii "ON"
    .byte 2
    .ascii "OR"
    .byte 5
    .ascii "ORDER"
    .byte 5
    .ascii "OUTER"
    .byte 5
    .ascii "RIGHT"
    .byte 6
    .ascii "SELECT"
    .byte 4
    .ascii "THEN"
    .byte 9
    .ascii "TIMESTAMP"
    .byte 4
    .ascii "TRUE"
    .byte 5
    .ascii "UNION"
    .byte 5
    .ascii "USING"
    .byte 4
    .ascii "WHEN"
    .byte 5
    .ascii "WHERE"
    .byte 4
    .ascii "WITH"
    .byte 0

msg_unterm_comment: .asciz "unterminated block comment"
msg_unterm_string:  .asciz "unterminated string literal"
msg_unterm_ident:   .asciz "unterminated quoted identifier"
msg_bad_number:     .asciz "malformed numeric literal"
msg_bad_char:       .asciz "unexpected character "
msg_bad_byte:       .asciz "unexpected non-ASCII character outside string literal"

    .text

// Advance the position tracker (x24 = position, x25 = line, x26 = column) up
// to the byte at x27. Clobbers w9, w10. Total work over a whole statement is
// linear because the tracker only moves forward.
.macro TRACK_TO_X27
71: cmp  x24, x27
    b.hs 73f
    ldrb w9, [x24], #1
    cmp  w9, #'\n'
    b.ne 72f
    add  x25, x25, #1
    mov  x26, #1
    b    71b
72: and  w10, w9, #0xC0
    cmp  w10, #0x80                 // UTF-8 continuation byte: same column
    b.eq 71b
    add  x26, x26, #1
    b    71b
73:
.endm

// Branch to \label if w-register \c is an identifier character [A-Za-z0-9_].
// Clobbers \tmp.
.macro IF_IDENT_CHAR c, tmp, label
    sub  \tmp, \c, #'0'
    cmp  \tmp, #9
    b.ls \label
    orr  \tmp, \c, #0x20
    sub  \tmp, \tmp, #'a'
    cmp  \tmp, #25
    b.ls \label
    cmp  \c, #'_'
    b.eq \label
.endm

// -----------------------------------------------------------------------------
// lex_tokenize(x0 ptr, x1 len) -> x0 Token*, x1 count (excluding the EOF token)
//
// Register usage:
//   x19 cursor            x20 end of input        x21 token array
//   x22 token count       x23 capacity (tokens)   x24 tracker position
//   x25 tracker line      x26 tracker column      x27 current token start
//   x28 current token record
// -----------------------------------------------------------------------------
FUNC lex_tokenize
    stp  x29, x30, [sp, #-96]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    stp  x25, x26, [sp, #64]
    stp  x27, x28, [sp, #80]
    mov  x19, x0
    add  x20, x0, x1
    mov  x23, #LEX_INITIAL_CAP
    mov  x0, #(LEX_INITIAL_CAP * TK_SIZE)
    bl   arena_alloc
    mov  x21, x0
    mov  x22, #0
    mov  x24, x19
    mov  x25, #1
    mov  x26, #1

// ---- skip whitespace and comments -------------------------------------------
.Lnext:
    cmp  x19, x20
    b.hs .Leof
    ldrb w9, [x19]
    cmp  w9, #' '
    b.eq .Lskip1
    cmp  w9, #'\t'
    b.eq .Lskip1
    cmp  w9, #'\n'
    b.eq .Lskip1
    cmp  w9, #'\r'
    b.eq .Lskip1
    cmp  w9, #'-'
    b.eq .Lline_comment
    cmp  w9, #'/'
    b.eq .Lblock_comment
    b    .Ltoken
.Lskip1:
    add  x19, x19, #1
    b    .Lnext

.Lline_comment:                     // "--" up to and including LF
    add  x10, x19, #1
    cmp  x10, x20
    b.hs .Ltoken
    ldrb w10, [x10]
    cmp  w10, #'-'
    b.ne .Ltoken
    add  x19, x19, #2
1:  cmp  x19, x20
    b.hs .Leof
    ldrb w9, [x19], #1
    cmp  w9, #'\n'
    b.ne 1b
    b    .Lnext

.Lblock_comment:                    // "/*" up to and including "*/"
    add  x10, x19, #1
    cmp  x10, x20
    b.hs .Ltoken
    ldrb w10, [x10]
    cmp  w10, #'*'
    b.ne .Ltoken
    mov  x27, x19                   // comment start, for the error position
    add  x19, x19, #2
1:  add  x10, x19, #1
    cmp  x10, x20
    b.hs .Lerr_comment              // fewer than 2 bytes left: no "*/"
    ldrb w9, [x19]
    cmp  w9, #'*'
    b.ne 2f
    ldrb w10, [x10]
    cmp  w10, #'/'
    b.ne 2f
    add  x19, x19, #2
    b    .Lnext
2:  add  x19, x19, #1
    b    1b

// ---- start a token ------------------------------------------------------------
.Ltoken:
    mov  x27, x19
    TRACK_TO_X27
    // Keep room for this token and the final EOF token: need count+2 <= cap.
    add  x9, x22, #2
    cmp  x9, x23
    b.ls 1f
    lsl  x23, x23, #1
    mov  x9, #TK_SIZE
    mul  x0, x23, x9
    bl   arena_alloc
    mov  x9, #TK_SIZE
    mul  x2, x22, x9
    mov  x1, x21
    mov  x21, x0
    bl   memcpy
1:  mov  x9, #TK_SIZE
    madd x28, x22, x9, x21
    str  xzr, [x28, #TK_KIND]       // kind = 0, aux = 0
    str  x27, [x28, #TK_PTR]
    str  xzr, [x28, #TK_LEN]
    str  xzr, [x28, #TK_STR]
    str  w25, [x28, #TK_LINE]
    str  w26, [x28, #TK_COL]

    ldrb w9, [x19]                  // w9 = first byte
    mov  w12, #0                    // w12 = following byte (0 at end of input)
    add  x10, x19, #1
    cmp  x10, x20
    b.hs 2f
    ldrb w12, [x19, #1]
2:
    sub  w10, w9, #'0'
    cmp  w10, #9
    b.ls .Lnumber
    orr  w10, w9, #0x20
    sub  w10, w10, #'a'
    cmp  w10, #25
    b.ls .Lident
    cmp  w9, #'_'
    b.eq .Lident
    cmp  w9, #'\''
    b.eq .Lstring
    cmp  w9, #'"'
    b.eq .Lqident
    cmp  w9, #'.'
    b.eq .Ldot
    mov  w11, #TK_PLUS
    cmp  w9, #'+'
    b.eq .Lpunct1
    mov  w11, #TK_MINUS
    cmp  w9, #'-'
    b.eq .Lpunct1
    mov  w11, #TK_STAR
    cmp  w9, #'*'
    b.eq .Lpunct1
    mov  w11, #TK_SLASH
    cmp  w9, #'/'
    b.eq .Lpunct1
    mov  w11, #TK_PERCENT
    cmp  w9, #'%'
    b.eq .Lpunct1
    mov  w11, #TK_EQ
    cmp  w9, #'='
    b.eq .Lpunct1
    mov  w11, #TK_LPAREN
    cmp  w9, #'('
    b.eq .Lpunct1
    mov  w11, #TK_RPAREN
    cmp  w9, #')'
    b.eq .Lpunct1
    mov  w11, #TK_COMMA
    cmp  w9, #','
    b.eq .Lpunct1
    mov  w11, #TK_SEMI
    cmp  w9, #';'
    b.eq .Lpunct1
    cmp  w9, #'<'
    b.eq .Lless
    cmp  w9, #'>'
    b.eq .Lgreater
    cmp  w9, #'|'
    b.eq .Lbar
    cmp  w9, #'!'
    b.eq .Lbang
    b    .Lerr_char

.Lless:                             // <  <=  <>
    mov  w11, #TK_LE
    cmp  w12, #'='
    b.eq .Lpunct2
    mov  w11, #TK_NE
    cmp  w12, #'>'
    b.eq .Lpunct2
    mov  w11, #TK_LT
    b    .Lpunct1
.Lgreater:                          // >  >=
    mov  w11, #TK_GE
    cmp  w12, #'='
    b.eq .Lpunct2
    mov  w11, #TK_GT
    b    .Lpunct1
.Lbar:                              // ||  (a single | is invalid)
    mov  w11, #TK_CONCAT
    cmp  w12, #'|'
    b.eq .Lpunct2
    b    .Lerr_char
.Lbang:                             // !=  (a single ! is invalid)
    mov  w11, #TK_NE
    cmp  w12, #'='
    b.eq .Lpunct2
    b    .Lerr_char
.Ldot:                              // "." or a number starting with ".digit"
    sub  w10, w12, #'0'
    cmp  w10, #9
    b.ls .Lnumber
    mov  w11, #TK_DOT
    // fall through
.Lpunct1:                           // single-byte token of kind w11
    str  w11, [x28, #TK_KIND]
    add  x19, x19, #1
    b    .Ldone
.Lpunct2:                           // two-byte token of kind w11
    str  w11, [x28, #TK_KIND]
    add  x19, x19, #2
    // fall through
.Ldone:                             // finish token: length, count
    sub  x9, x19, x27
    str  x9, [x28, #TK_LEN]
    add  x22, x22, #1
    b    .Lnext

// ---- identifiers and keywords -----------------------------------------------
.Lident:
    add  x19, x19, #1
1:  cmp  x19, x20
    b.hs 2f
    ldrb w9, [x19]
    IF_IDENT_CHAR w9, w10, 3f
    b    2f
3:  add  x19, x19, #1
    b    1b
2:  mov  x0, x27
    sub  x1, x19, x27
    bl   kw_lookup
    cbz  w0, 4f
    str  w0, [x28, #TK_KIND]        // reserved keyword
    b    .Ldone
4:  mov  w9, #TK_IDENT
    str  w9, [x28, #TK_KIND]
    mov  x0, x27
    sub  x1, x19, x27
    bl   str_new
    str  x0, [x28, #TK_STR]
    b    .Ldone

// ---- numbers --------------------------------------------------------------------
// w13 accumulates the TKN_* form bits.
.Lnumber:
    mov  w13, #0
1:  cmp  x19, x20                   // integer digits
    b.hs .Lnum_end
    ldrb w9, [x19]
    sub  w10, w9, #'0'
    cmp  w10, #9
    b.hi 2f
    add  x19, x19, #1
    b    1b
2:  cmp  w9, #'.'
    b.ne .Lnum_exp
    orr  w13, w13, #TKN_DOT
    add  x19, x19, #1
3:  cmp  x19, x20                   // fraction digits
    b.hs .Lnum_end
    ldrb w9, [x19]
    sub  w10, w9, #'0'
    cmp  w10, #9
    b.hi .Lnum_exp
    add  x19, x19, #1
    b    3b
.Lnum_exp:                          // w9 = byte at x19 (x19 < end)
    orr  w10, w9, #0x20
    cmp  w10, #'e'
    b.ne .Lnum_end
    add  x10, x19, #1               // x10 scans the exponent tentatively
    cmp  x10, x20
    b.hs .Lnum_end
    ldrb w11, [x10]
    cmp  w11, #'+'
    b.eq 4f
    cmp  w11, #'-'
    b.ne 5f
4:  add  x10, x10, #1
    cmp  x10, x20
    b.hs .Lnum_end
    ldrb w11, [x10]
5:  sub  w11, w11, #'0'
    cmp  w11, #9
    b.hi .Lnum_end                  // no digit: not an exponent
    orr  w13, w13, #TKN_EXP
    mov  x19, x10
6:  cmp  x19, x20                   // exponent digits
    b.hs .Lnum_end
    ldrb w9, [x19]
    sub  w10, w9, #'0'
    cmp  w10, #9
    b.hi .Lnum_end
    add  x19, x19, #1
    b    6b
.Lnum_end:
    cmp  x19, x20                   // e.g. "12abc", "1e", "3.x" are malformed
    b.hs 7f
    ldrb w9, [x19]
    IF_IDENT_CHAR w9, w10, .Lerr_number
7:  mov  w9, #TK_NUMBER
    str  w9, [x28, #TK_KIND]
    str  w13, [x28, #TK_AUX]
    b    .Ldone

// ---- quoted strings / identifiers ---------------------------------------------
// w14 = quote character
.Lstring:
    mov  w9, #TK_STRING
    str  w9, [x28, #TK_KIND]
    mov  w14, #'\''
    b    .Lquoted
.Lqident:
    mov  w9, #TK_IDENT
    str  w9, [x28, #TK_KIND]
    mov  w9, #1
    str  w9, [x28, #TK_AUX]
    mov  w14, #'"'
.Lquoted:
    add  x19, x19, #1
1:  cmp  x19, x20
    b.hs .Lerr_unterminated
    ldrb w9, [x19], #1
    cmp  w9, w14
    b.ne 1b
    cmp  x19, x20                   // quote: closing, or the first of a pair?
    b.hs 2f
    ldrb w9, [x19]
    cmp  w9, w14
    b.ne 2f
    add  x19, x19, #1               // doubled quote: part of the contents
    b    1b
2:  add  x0, x27, #1                // contents without the delimiters
    sub  x1, x19, x27
    sub  x1, x1, #2
    mov  w2, w14
    bl   lex_unquote
    str  x0, [x28, #TK_STR]
    b    .Ldone

// ---- end of input -------------------------------------------------------------
.Leof:
    mov  x27, x20
    TRACK_TO_X27
    mov  x9, #TK_SIZE               // capacity for the EOF slot is guaranteed
    madd x28, x22, x9, x21
    str  xzr, [x28, #TK_KIND]       // TK_EOF, aux 0
    str  x20, [x28, #TK_PTR]
    str  xzr, [x28, #TK_LEN]
    str  xzr, [x28, #TK_STR]
    str  w25, [x28, #TK_LINE]
    str  w26, [x28, #TK_COL]
    mov  x0, x21
    mov  x1, x22
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x23, x24, [sp, #48]
    ldp  x25, x26, [sp, #64]
    ldp  x27, x28, [sp, #80]
    ldp  x29, x30, [sp], #96
    ret

// ---- errors (position = x27, the start of the offending token/comment) --------
.Lerr_comment:
    ADR_L x1, msg_unterm_comment
    b    .Lraise
.Lerr_unterminated:
    ADR_L x1, msg_unterm_string
    cmp  w14, #'\''
    b.eq .Lraise
    ADR_L x1, msg_unterm_ident
    b    .Lraise
.Lerr_number:
    ADR_L x1, msg_bad_number
    b    .Lraise
.Lerr_char:
    ldrb w9, [x27]
    cmp  w9, #0x20                  // control or non-ASCII: no quoted text
    b.lo .Lerr_byte
    cmp  w9, #0x7f
    b.hs .Lerr_byte
    TRACK_TO_X27
    mov  w0, #ERR_PARSE
    ADR_L x1, msg_bad_char
    mov  x2, x27
    mov  x3, #1
    mov  w4, w25
    mov  w5, w26
    bl   lex_raise_text
.Lerr_byte:
    ADR_L x1, msg_bad_byte
.Lraise:                            // x1 = message
    TRACK_TO_X27
    mov  w0, #ERR_PARSE
    mov  w2, w25
    mov  w3, w26
    bl   pq_raise_pos
ENDF lex_tokenize

// -----------------------------------------------------------------------------
// kw_lookup(x0 ptr, x1 len) -> w0 KW_* kind, or 0 if not a reserved keyword.
// Leaf. ASCII case-insensitive comparison against kw_table.
// Registers: x2 table cursor, w3 current kind, x4 entry length, x5 index,
//            w6/w7 bytes being compared.
// -----------------------------------------------------------------------------
LFUNC kw_lookup
    cmp  x1, #2                     // keywords are 2..9 bytes long
    b.lo 9f
    cmp  x1, #9
    b.hi 9f
    ADR_L x2, kw_table
    mov  w3, #KW_BASE
1:  ldrb w4, [x2], #1               // entry length (0 = end of table)
    cbz  w4, 9f
    cmp  x4, x1
    b.ne 4f
    mov  x5, #0
2:  ldrb w6, [x0, x5]
    sub  w7, w6, #'a'               // to upper case
    cmp  w7, #25
    b.hi 3f
    sub  w6, w6, #32
3:  ldrb w7, [x2, x5]
    cmp  w6, w7
    b.ne 4f
    add  x5, x5, #1
    cmp  x5, x1
    b.lo 2b
    mov  w0, w3
    ret
4:  add  x2, x2, x4                 // next entry
    add  w3, w3, #1
    b    1b
9:  mov  w0, #0
    ret
ENDF kw_lookup

// -----------------------------------------------------------------------------
// lex_unquote(x0 ptr, x1 len, w2 quote) -> x0 Str*
// Copies the contents of a quoted token into a new Str, collapsing each
// doubled quote character into one (the scanner guarantees that every quote
// inside the contents is doubled).
// Registers: x19 src, x20 len, w21 quote, x22 Str*, x9 read index,
//            x10 write index (relative to Str data).
// -----------------------------------------------------------------------------
LFUNC lex_unquote
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    mov  x19, x0
    mov  x20, x1
    mov  w21, w2
    add  x0, x1, #(STR_DATA + 1)
    bl   arena_alloc
    mov  x22, x0
    add  x11, x0, #STR_DATA
    mov  x9, #0
    mov  x10, #0
1:  cmp  x9, x20
    b.hs 3f
    ldrb w12, [x19, x9]
    strb w12, [x11, x10]
    add  x10, x10, #1
    add  x9, x9, #1
    cmp  w12, w21
    b.ne 1b
    add  x9, x9, #1                 // skip the second quote of the pair
    b    1b
3:  strb wzr, [x11, x10]
    str  x10, [x22, #STR_LEN]
    mov  x0, x22
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
ENDF lex_unquote

// -----------------------------------------------------------------------------
// lex_raise_text(w0 code, x1 prefix cstr, x2 ptr, x3 len, w4 line, w5 col)
// noreturn. Raises `code` with message  prefix + "'" + text + "'"  where text
// is at most ERRTEXT_MAX bytes of [ptr, ptr+len) (cut at a UTF-8 boundary).
// Registers: w19 code, x20 prefix, x21 text, x22 text length, w23 line,
//            w24 col, x25 prefix length, x26 message buffer.
// -----------------------------------------------------------------------------
FUNC lex_raise_text
    stp  x29, x30, [sp, #-80]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    stp  x25, x26, [sp, #64]
    mov  w19, w0
    mov  x20, x1
    mov  x21, x2
    mov  x22, x3
    mov  w23, w4
    mov  w24, w5
    cmp  x22, #ERRTEXT_MAX
    b.ls 2f
    mov  x22, #ERRTEXT_MAX          // truncate, then back off to a char start
1:  ldrb w9, [x21, x22]
    and  w9, w9, #0xC0
    cmp  w9, #0x80
    b.ne 2f
    subs x22, x22, #1
    b.ne 1b
2:  mov  x0, x20
    bl   strlen
    mov  x25, x0
    add  x0, x25, x22
    add  x0, x0, #4                 // two quotes, NUL, spare
    bl   arena_alloc
    mov  x26, x0
    mov  x1, x20
    mov  x2, x25
    bl   memcpy
    add  x9, x26, x25
    mov  w10, #'\''
    strb w10, [x9]
    add  x0, x9, #1
    mov  x1, x21
    mov  x2, x22
    bl   memcpy
    add  x9, x26, x25
    add  x9, x9, x22
    mov  w10, #'\''
    strb w10, [x9, #1]
    strb wzr, [x9, #2]
    mov  w0, w19
    mov  x1, x26
    mov  w2, w23
    mov  w3, w24
    bl   pq_raise_pos
    brk  #0                         // not reached
ENDF lex_raise_text

    NOTE_GNU_STACK
