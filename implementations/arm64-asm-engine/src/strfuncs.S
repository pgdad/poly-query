// =============================================================================
// strfuncs.S — string primitives behind the scalar string functions and LIKE
// (functions.md §1, semantics.md §11). Used by functions.S.
//
// Strings are Str objects (pq.inc: [0] u64 len, [8] bytes, NUL terminated),
// UTF-8 encoded. "Character" means Unicode code point; a code point starts at
// every byte that is not a continuation byte (10xxxxxx). Results are newly
// allocated in the request arena (the inputs are never modified).
//
//   str_alloc(x0 len)                          -> x0 Str* (bytes uninitialised)
//   utf8_len(x0 ptr, x1 len)                   -> x0 number of code points
//   utf8_skip(x0 ptr, x1 len, x2 n)            -> x0 byte offset after n code
//                                                 points (len if fewer)
//   str_casemap(x0 Str*, w1 upper)             -> x0 Str* (ASCII words only)
//   str_substr(x0 Str*, x1 start, x2 count, w3 has_count) -> x0 Str*
//                                                 raises INVALID_ARGUMENT if
//                                                 has_count and count < 0
//   str_trim(x0 Str*, w1 mode)                 -> x0 Str* (mode bit0 = leading,
//                                                 bit1 = trailing U+0020)
//   str_replace(x0 s, x1 from, x2 to)          -> x0 Str*
//   str_concat_n(x0 Str** parts, x1 n)         -> x0 Str* (0 entries skipped)
//   like_match(x0 s, x1 slen, x2 p, x3 plen)   -> w0 1 if s LIKE p
// =============================================================================
#include "pq.inc"
#include "frame.inc"

// ADV_CP ptr, i, len, tmp: advance byte index i past one code point
// (i < len on entry).
.macro ADV_CP ptr, i, len, tmp
    add  \i, \i, #1
8:  cmp  \i, \len
    b.hs 9f
    ldrb \tmp, [\ptr, \i]
    and  \tmp, \tmp, #0xc0
    cmp  \tmp, #0x80
    b.ne 9f
    add  \i, \i, #1
    b    8b
9:
.endm

    .text

// =============================================================================
// str_alloc(x0 len) -> x0 Str* with STR_LEN = len and the NUL terminator set.
//   x19 len
// =============================================================================
FUNC str_alloc
    ENTER 1
    mov  x19, x0
    add  x0, x0, #(STR_DATA + 1)
    bl   arena_alloc
    str  x19, [x0, #STR_LEN]
    add  x9, x0, #STR_DATA
    strb wzr, [x9, x19]
    LEAVE 1
ENDF str_alloc

// =============================================================================
// utf8_len(x0 ptr, x1 len) -> x0 number of code points               (leaf)
// =============================================================================
FUNC utf8_len
    mov  x9, #0                         // count
    add  x1, x0, x1                     // end
1:  cmp  x0, x1
    b.hs 2f
    ldrb w10, [x0], #1
    and  w10, w10, #0xc0
    cmp  w10, #0x80                     // continuation bytes do not count
    cinc x9, x9, ne
    b    1b
2:  mov  x0, x9
    ret
ENDF utf8_len

// =============================================================================
// utf8_skip(x0 ptr, x1 len, x2 n) -> x0 byte offset after n code points,
// or len if the string has fewer.                                     (leaf)
// =============================================================================
FUNC utf8_skip
    mov  x3, #0                         // byte index
1:  cbz  x2, 2f
    cmp  x3, x1
    b.hs 2f
    ADV_CP x0, x3, x1, w4
    sub  x2, x2, #1
    b    1b
2:  mov  x0, x3
    ret
ENDF utf8_skip

// =============================================================================
// str_casemap(x0 Str*, w1 upper) -> x0 Str*
// UPPER (w1 = 1) / LOWER (w1 = 0): only ASCII letters change. A word (maximal
// run of bytes > 0x20) that contains a non-ASCII character is copied
// unchanged as a whole — this is the reading of "ASCII letters only are
// case-mapped; other characters unchanged" that the conformance suite
// requires (UPPER('abc Ünï') = 'ABC Ünï').
//   x19 source, w20 upper flag
// Loop registers: x9 bytes left, x10 source, x11 destination, w12 letter
// range start, w13 delta, x14 word end scan, w15 word has non-ASCII
// =============================================================================
FUNC str_casemap
    ENTER 2
    mov  x19, x0
    mov  w20, w1
    ldr  x0, [x19, #STR_LEN]
    bl   str_alloc
    ldr  x9, [x19, #STR_LEN]
    add  x10, x19, #STR_DATA            // source cursor
    add  x11, x0, #STR_DATA             // destination cursor
    mov  w12, #'a'                      // range start of letters to map
    mov  w13, #-32                      // delta
    cbnz w20, 1f
    mov  w12, #'A'
    mov  w13, #32
1:  cbz  x9, 6f
    ldrb w16, [x10]
    cmp  w16, #0x20
    b.hi 2f
    strb w16, [x11], #1                 // separator byte
    add  x10, x10, #1
    sub  x9, x9, #1
    b    1b
2:  mov  x14, #0                        // scan the word
    mov  w15, #0
3:  cmp  x14, x9
    b.hs 4f
    ldrb w16, [x10, x14]
    cmp  w16, #0x20
    b.ls 4f
    cmp  w16, #0x80
    cset w17, hs
    orr  w15, w15, w17
    add  x14, x14, #1
    b    3b
4:  sub  x9, x9, x14                    // copy / map x14 bytes
5:  cbz  x14, 1b
    ldrb w16, [x10], #1
    cbnz w15, 51f
    sub  w17, w16, w12
    cmp  w17, #25
    b.hi 51f
    add  w16, w16, w13
51: strb w16, [x11], #1
    sub  x14, x14, #1
    b    5b
6:  LEAVE 2
ENDF str_casemap

// =============================================================================
// str_substr(x0 Str*, x1 start, x2 count, w3 has_count) -> x0 Str*
// Code points at 1-based positions i with max(start,1) <= i and, when a count
// is given, i < start + count (functions.md SUBSTR).
//   x19 Str*, x20 first position (lo), x21 end position (hi, exclusive),
//   x22 byte offset of lo
// =============================================================================
FUNC str_substr
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    mov  x21, #0x7fffffffffffffff       // no count: up to the end
    cbz  w3, 1f
    tbnz x2, #63, .Lss_negative
    adds x21, x1, x2                    // start + count, saturating
    b.vc 1f
    mov  x21, #0x7fffffffffffffff
1:  cmp  x20, #1                        // lo = max(start, 1)
    mov  x9, #1
    csel x20, x20, x9, gt
    cmp  x21, x20
    b.le .Lss_empty
    add  x0, x19, #STR_DATA             // byte offset of position lo
    ldr  x1, [x19, #STR_LEN]
    sub  x2, x20, #1
    bl   utf8_skip
    mov  x22, x0
    add  x0, x19, #STR_DATA             // bytes of the hi - lo code points
    add  x0, x0, x22
    ldr  x1, [x19, #STR_LEN]
    sub  x1, x1, x22
    sub  x2, x21, x20
    bl   utf8_skip
    mov  x1, x0
    add  x0, x19, #STR_DATA
    add  x0, x0, x22
    bl   str_new
    LEAVE 3
.Lss_empty:
    mov  x0, #0
    bl   str_alloc
    LEAVE 3
.Lss_negative:
    RAISE ERR_INVALID_ARGUMENT, "SUBSTR length must not be negative"
ENDF str_substr

// =============================================================================
// str_trim(x0 Str*, w1 mode) -> x0 Str*
// Removes U+0020 spaces: mode bit0 leading, bit1 trailing.            (tail)
// =============================================================================
FUNC str_trim
    ldr  x9, [x0, #STR_LEN]
    add  x10, x0, #STR_DATA             // first byte kept
    add  x11, x10, x9                   // one past the last byte kept
    tbz  w1, #0, 2f
1:  cmp  x10, x11
    b.hs 2f
    ldrb w12, [x10]
    cmp  w12, #' '
    b.ne 2f
    add  x10, x10, #1
    b    1b
2:  tbz  w1, #1, 4f
3:  cmp  x11, x10
    b.ls 4f
    ldrb w12, [x11, #-1]
    cmp  w12, #' '
    b.ne 4f
    sub  x11, x11, #1
    b    3b
4:  mov  x0, x10
    sub  x1, x11, x10
    b    str_new
ENDF str_trim

// =============================================================================
// str_replace(x0 s, x1 from, x2 to) -> x0 Str*
// Replaces all non-overlapping occurrences of `from`, left to right. An empty
// `from` returns s unchanged. Two passes: count matches, then build.
//   x19 s, x20 from, x21 to, x22 scan offset, x23 match count / write cursor,
//   x24 result
// =============================================================================
FUNC str_replace
    ENTER 4
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    ldr  x9, [x20, #STR_LEN]
    cbz  x9, .Lsr_same
    // ---- pass 1: count matches
    mov  x22, #0
    mov  x23, #0
1:  bl   .Lsr_find                      // x0 = match pointer or 0
    cbz  x0, 2f
    add  x23, x23, #1
    add  x9, x19, #STR_DATA
    sub  x22, x0, x9
    ldr  x9, [x20, #STR_LEN]
    add  x22, x22, x9
    b    1b
2:  cbz  x23, .Lsr_same
    // new length = len(s) + count * (len(to) - len(from))
    ldr  x9, [x21, #STR_LEN]
    ldr  x10, [x20, #STR_LEN]
    sub  x9, x9, x10
    ldr  x0, [x19, #STR_LEN]
    madd x0, x23, x9, x0
    bl   str_alloc
    mov  x24, x0
    // ---- pass 2: copy segments and replacements
    add  x23, x24, #STR_DATA            // write cursor
    mov  x22, #0
3:  bl   .Lsr_find
    cbz  x0, 4f
    mov  x2, x0                         // segment [s + x22, match)
    add  x1, x19, #STR_DATA
    add  x1, x1, x22
    sub  x2, x2, x1
    str  x0, [sp, #-16]!                // keep the match pointer
    add  x9, x23, x2
    mov  x0, x23
    mov  x23, x9
    bl   memcpy
    mov  x0, x23                        // replacement
    add  x1, x21, #STR_DATA
    ldr  x2, [x21, #STR_LEN]
    add  x23, x23, x2
    bl   memcpy
    ldr  x0, [sp], #16
    add  x9, x19, #STR_DATA
    sub  x22, x0, x9
    ldr  x9, [x20, #STR_LEN]
    add  x22, x22, x9
    b    3b
4:  mov  x0, x23                        // tail
    add  x1, x19, #STR_DATA
    add  x1, x1, x22
    ldr  x2, [x19, #STR_LEN]
    sub  x2, x2, x22
    bl   memcpy
    mov  x0, x24
    LEAVE 4
.Lsr_same:
    mov  x0, x19
    LEAVE 4

// .Lsr_find: memmem(s + x22, len(s) - x22, from, len(from)) -> x0 (local
// subroutine; clobbers caller-saved registers and x30, which the outer
// frame record already saved).
.Lsr_find:
    str  x30, [sp, #-16]!
    add  x0, x19, #STR_DATA
    add  x0, x0, x22
    ldr  x1, [x19, #STR_LEN]
    sub  x1, x1, x22
    add  x2, x20, #STR_DATA
    ldr  x3, [x20, #STR_LEN]
    bl   memmem
    ldr  x30, [sp], #16
    ret
ENDF str_replace

// =============================================================================
// str_concat_n(x0 Str** parts, x1 n) -> x0 Str*
// Concatenation of the non-zero entries (zero entries are skipped).
//   x19 parts, x20 n, x21 index, x22 result, x23 write cursor
// =============================================================================
FUNC str_concat_n
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    mov  x0, #0                         // total length
    mov  x21, #0
1:  cmp  x21, x20
    b.hs 2f
    ldr  x9, [x19, x21, lsl #3]
    add  x21, x21, #1
    cbz  x9, 1b
    ldr  x9, [x9, #STR_LEN]
    add  x0, x0, x9
    b    1b
2:  bl   str_alloc
    mov  x22, x0
    add  x23, x22, #STR_DATA
    mov  x21, #0
3:  cmp  x21, x20
    b.hs 4f
    ldr  x9, [x19, x21, lsl #3]
    add  x21, x21, #1
    cbz  x9, 3b
    mov  x0, x23
    add  x1, x9, #STR_DATA
    ldr  x2, [x9, #STR_LEN]
    add  x23, x23, x2
    bl   memcpy
    b    3b
4:  mov  x0, x22
    LEAVE 3
ENDF str_concat_n

// =============================================================================
// like_match(x0 s, x1 slen, x2 p, x3 plen) -> w0 1/0                   (leaf)
// `%` matches any sequence of code points, `_` exactly one code point, every
// other pattern byte matches itself (case-sensitive, whole string, no escape).
// Iterative matcher that remembers only the most recent `%` and, on a
// mismatch, retries with that `%` absorbing one more code point. This is
// O(slen * plen) in the worst case (never exponential) and correct because a
// later `%` subsumes every alternative of an earlier one.
//   x4 si, x5 pi, x6 pattern index after the last % (-1 none),
//   x7 string index that last % currently resumes from, w8/w9 bytes
// =============================================================================
FUNC like_match
    mov  x4, #0
    mov  x5, #0
    mov  x6, #-1
    mov  x7, #0
.Llm_loop:
    cmp  x4, x1
    b.hs .Llm_tail
    cmp  x5, x3
    b.hs .Llm_mismatch
    ldrb w8, [x2, x5]
    cmp  w8, #'%'
    b.ne 1f
    add  x5, x5, #1                     // %: remember, match empty first
    mov  x6, x5
    mov  x7, x4
    b    .Llm_loop
1:  cmp  w8, #'_'
    b.ne 2f
    add  x5, x5, #1                     // _: one code point
    ADV_CP x0, x4, x1, w9
    b    .Llm_loop
2:  ldrb w9, [x0, x4]
    cmp  w8, w9
    b.ne .Llm_mismatch
    add  x4, x4, #1
    add  x5, x5, #1
    b    .Llm_loop
.Llm_mismatch:
    tbnz x6, #63, .Llm_false            // no % to fall back to
    ADV_CP x0, x7, x1, w9               // the % absorbs one more code point
    mov  x4, x7
    mov  x5, x6
    b    .Llm_loop
.Llm_tail:                              // string consumed: only %s may remain
    cmp  x5, x3
    b.hs .Llm_true
    ldrb w8, [x2, x5]
    cmp  w8, #'%'
    b.ne .Llm_false
    add  x5, x5, #1
    b    .Llm_tail
.Llm_true:
    mov  w0, #1
    ret
.Llm_false:
    mov  w0, #0
    ret
ENDF like_match

    NOTE_GNU_STACK
