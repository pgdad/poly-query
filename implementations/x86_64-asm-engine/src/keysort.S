/*
 * keysort.S - ORDER BY with normalized keys (batch / parallel modes).
 *
 *   keysort(rows rdi, n rsi, plan rdx) -> eax 1 if the rows were sorted,
 *       0 when the first ORDER BY key cannot be normalized (the caller then
 *       uses the comparison sort).  Same order as sort_rows: the ORDER BY
 *       keys, ties in production order.
 *
 * Every row becomes an entry of W <= KS_MAXW u64 words followed by the row
 * pointer and its sequence number.  The words encode the leading ORDER BY
 * keys so that comparing them as unsigned integers orders the rows like
 * row_cmp does:
 *   NULL indicator (only for keys that have NULLs): 0 / 2 for NULL (first /
 *     last), 1 otherwise;
 *   BOOLEAN, INT64, DATE, TIMESTAMP, DECIMAL(p <= 18): value ^ 2^63;
 *   FLOAT64: IEEE bits with the sign handled (-0.0 = 0.0, no NaN exists);
 *   STRING: two words, bytes 0..14 big-endian and zero padded, then
 *     min(length, 16) as the last byte.  Exact for strings shorter than 16
 *     bytes (padding and length order a proper prefix first); with longer
 *     strings present only a difference is decisive;
 *   DESC keys are complemented.
 * Encoding stops at a wide DECIMAL, a STRING key with long values, the
 * word limit or the last key; when it stopped early the key words are
 * *incomplete*: entries with equal words are ordered by row_cmp, then by
 * sequence.  Entries are thus totally ordered (ks_cmp).
 *
 * Sorting is a parallel sample sort over P parts (par.S): (1) every part
 * encodes its rows; (2) P - 1 splitters are taken from a sorted sample;
 * (3) every part assigns its entries to buckets by binary search over the
 * splitters and (4) scatters them, so that bucket b holds the entries
 * between splitters b - 1 and b; (5) every bucket is sorted on its own
 * thread by an MSD radix sort over the bytes of the key words (bytes that
 * are equal in all entries are skipped; buckets of up to KS_SMALL entries
 * are insertion sorted; entries with equal words are already in sequence
 * order - scatters are stable - or, when incomplete, sorted with qsort_r).
 * The buckets are adjacent in the output, no merging is needed.
 */
#include "pq.inc"
#include "sql.inc"

    .section .note.GNU-stack, "", @progbits

#define KS_MAXW   6     /* key words per entry */
#define KS_SMALL  32    /* insertion sort below this bucket size */
#define KS_SAMPLE 64    /* sample entries per part (splitter selection) */
#define KS_LONG_STR 16  /* strings this long make STRING words inexact */

/* word kinds */
#define WK_NULL  0
#define WK_INT   1
#define WK_FLOAT 2
#define WK_STR   3

/* word spec */
#define SP_KIND  0
#define SP_OFF   8      /* byte offset of the key cell in the row */
#define SP_XOR   16     /* -1 for DESC keys, else 0 */
#define SP_ARG   24     /* WK_NULL: word of a NULL (0 first, 2 last);
                           WK_STR: 0 = bytes 0..7, 1 = bytes 8..14 + length */
#define SP_SIZE  32

/* sort task */
#define KS_ROWS   0
#define KS_N      8
#define KS_PLAN   16
#define KS_W      24
#define KS_STRIDE 32    /* entry bytes: 8 * (W + 2) */
#define KS_INCOMP 40    /* key words incomplete: ties go to row_cmp */
#define KS_A      48    /* entries */
#define KS_B      56    /* scratch */
#define KS_BOUNDS 64    /* u64[P + 1]: bucket bounds */
#define KS_NULLS  72    /* u8[8]: key k has NULLs */
#define KS_LONG   80    /* u8[8]: STRING key k has long values */
#define KS_P      88    /* parts */
#define KS_OR     96    /* u64[P][KS_MAXW]: OR of each part's words */
#define KS_AND    104   /* u64[P][KS_MAXW]: AND of each part's words */
#define KS_CNT    112   /* u64[P][P]: bucket counts per part, then offsets */
#define KS_BID    120   /* u8[n]: bucket of each entry */
#define KS_SPL    128   /* splitter entries [P - 1] */
#define KS_VARY   136   /* u64[KS_MAXW]: bits that differ between entries */
#define KS_SCAN   184   /* u8[8]: key k must be checked by ks_null_part */
#define KS_NSCAN  192   /* keys to check */
#define KS_SPEC   200
#define KS_SIZE   (KS_SPEC + SP_SIZE * KS_MAXW)

    .text

/* ks_entry: local macro, reg = &A[idx] (idx register, clobbers reg) */
.macro KS_ENTRY task, idx, reg, base=KS_A
    mov \idx, \reg
    imul KS_STRIDE(\task), \reg
    add \base(\task), \reg
.endm

/* ks_null_part(task rdi, part rsi, lo rdx, hi rcx): flags the keys (up to
 * 8) that are NULL in some row of [lo, hi), and the STRING keys with a
 * value of KS_LONG_STR or more bytes (one pass over the rows; the flags
 * are collected on the stack and published at the end) */
#define NP_NULLS 0      /* u8[8] */
#define NP_LONG  8      /* u8[8] */
#define NP_STR   16     /* u8[8]: key k is a STRING */
#define NP_HI    24
FUNC ks_null_part
    ENTER NP_HI + 8
    mov %rdi, %rbx
    mov %rdx, %r14                  /* row */
    mov %rcx, NP_HI(%rsp)
    movq $0, NP_NULLS(%rsp)
    movq $0, NP_LONG(%rsp)
    movq $0, NP_STR(%rsp)
    mov KS_PLAN(%rbx), %r8
    mov QP_NKEYS(%r8), %r12
    mov $8, %eax
    cmp %rax, %r12
    cmova %rax, %r12                /* keys checked */
    mov QP_NOUT(%r8), %r13
    shl $4, %r13                    /* offset of the first key cell */
    xor %ecx, %ecx
1:  cmp %r12, %rcx
    jae 2f
    imul $SK_SIZE, %rcx, %rax
    add QP_KEYS(%r8), %rax
    movzbl SK_TYPE(%rax), %eax
    cmp $T_STR, %eax
    sete NP_STR(%rsp, %rcx)
    inc %rcx
    jmp 1b
2:  mov KS_ROWS(%rbx), %r15
3:  cmp NP_HI(%rsp), %r14
    jae 8f
    mov (%r15, %r14, 8), %rdi
    add %r13, %rdi                  /* first key cell */
    xor %ecx, %ecx
4:  cmp %r12, %rcx
    jae 7f
    cmpb $0, KS_SCAN(%rbx, %rcx)
    je 6f
    cmpq $0, VAL_NULL(%rdi)
    jne 5f
    cmpb $0, NP_STR(%rsp, %rcx)
    je 6f
    mov VAL_P(%rdi), %rax
    cmpq $KS_LONG_STR, PSTR_LEN(%rax)
    jb 6f
    movb $1, NP_LONG(%rsp, %rcx)
    jmp 6f
5:  movb $1, NP_NULLS(%rsp, %rcx)
6:  add $VAL_SIZE, %rdi
    inc %rcx
    jmp 4b
7:  inc %r14
    jmp 3b
8:  xor %ecx, %ecx                  /* publish (shared flags: written */
9:  cmp %r12, %rcx                  /* only when newly set) */
    jae 99f
    cmpb $0, NP_NULLS(%rsp, %rcx)
    je 91f
    cmpb $0, KS_NULLS(%rbx, %rcx)
    jne 91f
    movb $1, KS_NULLS(%rbx, %rcx)
91: cmpb $0, NP_LONG(%rsp, %rcx)
    je 92f
    cmpb $0, KS_LONG(%rbx, %rcx)
    jne 92f
    movb $1, KS_LONG(%rbx, %rcx)
92: inc %rcx
    jmp 9b
99: LEAVE
ENDF ks_null_part

/* ks_known(task rdi): KS_SCAN[k] = 0 for the keys (of the first 8) that
 * are known never to be NULL - a plain column without NULLs of the only
 * (base table) range variable - and are not STRINGs (whose lengths are
 * checked); KS_NSCAN = keys left to check */
FUNC ks_known
    ENTER 0
    mov %rdi, %rbx
    mov KS_PLAN(%rbx), %r12
    xor %r13d, %r13d                /* key */
1:  cmp QP_NKEYS(%r12), %r13
    jae 9f
    cmp $8, %r13
    jae 9f
    movb $1, KS_SCAN(%rbx, %r13)
    imul $SK_SIZE, %r13, %r14
    add QP_KEYS(%r12), %r14
    cmpb $T_STR, SK_TYPE(%r14)
    je 8f
    mov SK_EXPR(%r14), %rax
    mov SK_OUT(%r14), %rcx
    cmp $-1, %rcx
    je 2f
    imul $OC_SIZE, %rcx, %rcx
    add QP_OUT(%r12), %rcx
    mov OC_EXPR(%rcx), %rax
2:  test %rax, %rax
    jz 8f
    cmpl $EK_COL, N_KIND(%rax)
    jne 8f
    cmpq $1, QP_NRV(%r12)
    jne 8f
    cmpq $0, N_V2(%rax)
    jne 8f
    mov QP_RVS(%r12), %rcx
    mov (%rcx), %rcx
    mov RV_TABLE(%rcx), %rcx
    test %rcx, %rcx
    jz 8f
    mov N_V1(%rax), %rdx
    cmp TB_NCOLS(%rcx), %rdx
    jae 8f
    shl $COL_SHIFT, %rdx
    add TB_COLS(%rcx), %rdx         /* Column */
    cmpb $0, COL_LAZY(%rdx)
    jne 8f
    cmpq $0, COL_NULLS(%rdx)
    jne 8f
    movb $0, KS_SCAN(%rbx, %r13)    /* never NULL */
    jmp 81f
8:  incq KS_NSCAN(%rbx)
81: inc %r13
    jmp 1b
9:  LEAVE
ENDF ks_known

/* ks_enc(spec rdi, row rsi) -> rax the key word of the row (leaf) */
FUNC ks_enc
    mov SP_OFF(%rdi), %rdx
    add %rsi, %rdx                  /* key cell */
    mov SP_KIND(%rdi), %ecx
    cmpq $0, VAL_NULL(%rdx)
    jne 8f
    cmp $WK_NULL, %ecx
    je 7f
    mov VAL_P(%rdx), %rax
    cmp $WK_INT, %ecx
    jne 2f
    btc $63, %rax
    jmp 6f
2:  cmp $WK_FLOAT, %ecx
    jne 3f
    mov %rax, %rdx
    shl $1, %rdx
    jnz 21f
    xor %eax, %eax                  /* -0.0 = 0.0 */
21: test %rax, %rax
    js 22f
    btc $63, %rax                   /* positive: above every negative */
    jmp 6f
22: not %rax                        /* negative: larger magnitude first */
    jmp 6f
3:  mov PSTR_LEN(%rax), %r8         /* STRING: 8 bytes from offset 0 / 8 */
    mov SP_ARG(%rdi), %r9
    shl $3, %r9
    lea PSTR_DATA(%rax, %r9), %rsi
    mov %r8, %rcx
    sub %r9, %rcx                   /* bytes available from the offset */
    xor %edx, %edx
    test %rcx, %rcx
    jle 5f
    cmp $8, %rcx
    jb 4f
    mov (%rsi), %rdx
    bswap %rdx
    jmp 5f
4:  mov %rcx, %r10                  /* 1..7 bytes, zero padded */
41: shl $8, %rdx
    movzbl (%rsi), %eax
    or %rax, %rdx
    inc %rsi
    dec %r10
    jnz 41b
    neg %ecx
    add $8, %ecx
    shl $3, %ecx
    shl %cl, %rdx
5:  test %r9, %r9
    jz 51f
    mov $KS_LONG_STR, %eax          /* second word: the length last */
    cmp %rax, %r8
    cmova %rax, %r8
    xor %dl, %dl
    or %r8, %rdx
51: mov %rdx, %rax
6:  xor SP_XOR(%rdi), %rax
    ret
7:  mov $1, %eax                    /* NULL indicator of a value */
    ret
8:  xor %eax, %eax                  /* NULL */
    cmp $WK_NULL, %ecx
    jne 9f
    mov SP_ARG(%rdi), %rax
9:  ret
ENDF ks_enc

/* ks_cmp(a rdi, b rsi, task rdx) -> eax -1/0/1: entry order (qsort_r
 * comparator): key words, then row_cmp when incomplete, then sequence */
FUNC ks_cmp
    push %rbx
    push %r12
    push %r13
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov KS_W(%r13), %rcx
    xor %r8d, %r8d
1:  cmp %rcx, %r8
    jae 3f
    mov (%rbx, %r8, 8), %rax
    cmp (%r12, %r8, 8), %rax
    jb 7f
    ja 8f
    inc %r8
    jmp 1b
3:  cmpq $0, KS_INCOMP(%r13)
    je 4f
    lea (%rbx, %rcx, 8), %rdi       /* &row */
    lea (%r12, %rcx, 8), %rsi
    mov KS_PLAN(%r13), %rdx
    call row_cmp
    test %eax, %eax
    jnz 9f
    mov KS_W(%r13), %rcx
4:  mov 8(%rbx, %rcx, 8), %rax      /* sequence */
    cmp 8(%r12, %rcx, 8), %rax
    jb 7f
    ja 8f
    xor %eax, %eax
    jmp 9f
7:  mov $-1, %eax
    jmp 9f
8:  mov $1, %eax
9:  pop %r13
    pop %r12
    pop %rbx
    ret
ENDF ks_cmp

/* ks_copy: local helper, copies one entry: rdi dst, rsi src, rcx qwords */
ks_copy:
1:  mov -8(%rsi, %rcx, 8), %rax
    mov %rax, -8(%rdi, %rcx, 8)
    dec %rcx
    jnz 1b
    ret

/* ks_isort(task rdi, lo rsi, hi rdx): insertion sort of A[lo, hi) */
FUNC ks_isort
    ENTER 80                        /* 0..63: the entry being inserted */
    mov %rdi, %rbx
    mov %rsi, %r12                  /* lo */
    mov %rdx, %r13
    lea 1(%r12), %r14               /* i */
1:  cmp %r13, %r14
    jae 9f
    KS_ENTRY %rbx, %r14, %r15       /* &A[j], j = i */
    lea 0(%rsp), %rdi
    mov %r15, %rsi
    mov KS_W(%rbx), %rcx
    add $2, %rcx
    call ks_copy
    mov %r14, 72(%rsp)              /* j */
2:  cmp %r12, 72(%rsp)
    jbe 3f
    mov %r15, %rdi
    sub KS_STRIDE(%rbx), %rdi       /* A[j - 1] */
    mov KS_W(%rbx), %rcx            /* (inline: the key words) */
    xor %edx, %edx
21: mov (%rdi, %rdx, 8), %rax
    cmp 0(%rsp, %rdx, 8), %rax
    jb 3f
    ja 23f
    inc %rdx
    cmp %rcx, %rdx
    jb 21b
    cmpq $0, KS_INCOMP(%rbx)        /* equal words */
    je 22f
    lea 0(%rsp), %rsi
    mov %rbx, %rdx
    call ks_cmp
    cmp $0, %eax
    jle 3f
    jmp 23f
22: mov 8(%rdi, %rcx, 8), %rax      /* sequence */
    cmp 8(%rsp, %rcx, 8), %rax
    jbe 3f
23:
    mov %r15, %rdi                  /* A[j] = A[j - 1] */
    mov %r15, %rsi
    sub KS_STRIDE(%rbx), %rsi
    mov KS_W(%rbx), %rcx
    add $2, %rcx
    call ks_copy
    sub KS_STRIDE(%rbx), %r15
    decq 72(%rsp)
    jmp 2b
3:  mov %r15, %rdi
    lea 0(%rsp), %rsi
    mov KS_W(%rbx), %rcx
    add $2, %rcx
    call ks_copy
    inc %r14
    jmp 1b
9:  LEAVE
ENDF ks_isort

/* ks_msd(task rdi, lo rsi, hi rdx, digit rcx): sorts A[lo, hi) (B[lo, hi)
 * is scratch), whose entries agree on every digit before `digit` (digit 0
 * = the most significant byte of word 0) */
#define MS_CNT   0      /* u64[256] bucket counts, then bucket ends */
#define MS_LO    2048
#define MS_HI    2056
#define MS_D     2064
#define MS_SHIFT 2072
#define MS_WORD  2080
FUNC ks_msd
    ENTER 2088
    mov %rdi, %rbx
    mov %rsi, MS_LO(%rsp)
    mov %rdx, MS_HI(%rsp)
    mov %rcx, MS_D(%rsp)
    sub %rsi, %rdx                  /* n */
    cmp $KS_SMALL, %rdx
    ja 1f
    mov MS_HI(%rsp), %rdx
    call ks_isort
    LEAVE
1:  /* next digit that varies in this bucket */
    mov MS_D(%rsp), %rax
    mov KS_W(%rbx), %rcx
    shl $3, %rcx
    cmp %rcx, %rax
    jae 80f                         /* words exhausted */
    mov %rax, %rdx
    shr $3, %rdx                    /* word */
    mov %rdx, MS_WORD(%rsp)
    mov %eax, %ecx
    not %ecx
    and $7, %ecx
    shl $3, %ecx                    /* shift = 8 * (7 - digit % 8) */
    mov %rcx, MS_SHIFT(%rsp)
    mov KS_VARY(%rbx, %rdx, 8), %rsi
    shr %cl, %rsi
    test $0xff, %esi
    jnz 2f
    incq MS_D(%rsp)                 /* constant in every entry */
    jmp 1b
2:  /* histogram */
    lea MS_CNT(%rsp), %rdi
    xor %eax, %eax
    mov $256, %ecx
    rep stosq
    mov KS_STRIDE(%rbx), %r12
    mov MS_LO(%rsp), %rax
    KS_ENTRY %rbx, %rax, %rsi
    mov MS_WORD(%rsp), %rdx
    lea (%rsi, %rdx, 8), %rsi       /* &A[lo].word */
    mov MS_HI(%rsp), %r13
    sub MS_LO(%rsp), %r13           /* n */
    mov MS_SHIFT(%rsp), %rcx
    mov %r13, %r8
3:  mov (%rsi), %rax
    shr %cl, %rax
    movzbl %al, %eax
    incq MS_CNT(%rsp, %rax, 8)
    add %r12, %rsi
    dec %r8
    jnz 3b
    sub %r12, %rsi                  /* all in one bucket (the last */
    mov (%rsi), %rax                /* entry's): constant here */
    shr %cl, %rax
    movzbl %al, %eax
    cmp %r13, MS_CNT(%rsp, %rax, 8)
    jne 4f
    incq MS_D(%rsp)
    jmp 1b
4:  cmp $65536, %r13
    jb 41f
    call check_deadline
41: /* bucket starts */
    mov MS_LO(%rsp), %rdx
    xor %ecx, %ecx
5:  mov MS_CNT(%rsp, %rcx, 8), %rax
    mov %rdx, MS_CNT(%rsp, %rcx, 8)
    add %rax, %rdx
    inc %ecx
    cmp $256, %ecx
    jb 5b
    /* scatter A[lo, hi) into B by the digit (stable) */
    mov MS_LO(%rsp), %rax
    KS_ENTRY %rbx, %rax, %r14       /* source entry */
    mov KS_W(%rbx), %r15
    add $2, %r15                    /* qwords per entry */
    mov MS_WORD(%rsp), %rdx
6:  mov (%r14, %rdx, 8), %rax
    mov MS_SHIFT(%rsp), %rcx
    shr %cl, %rax
    movzbl %al, %eax
    mov MS_CNT(%rsp, %rax, 8), %rdi
    incq MS_CNT(%rsp, %rax, 8)
    imul %r12, %rdi
    add KS_B(%rbx), %rdi
    mov %r14, %rsi
    mov %r15, %rcx
    call ks_copy
    mov MS_WORD(%rsp), %rdx
    add %r12, %r14
    dec %r13
    jnz 6b
    /* back into A */
    mov MS_LO(%rsp), %rsi
    imul %r12, %rsi
    mov KS_A(%rbx), %rdi
    add %rsi, %rdi
    add KS_B(%rbx), %rsi
    mov MS_HI(%rsp), %rdx
    sub MS_LO(%rsp), %rdx
    imul %r12, %rdx
    call memcpy
    /* recurse into the buckets (MS_CNT now holds the bucket ends) */
    mov MS_LO(%rsp), %r14           /* bucket start */
    xor %r15d, %r15d
7:  mov MS_CNT(%rsp, %r15, 8), %r13 /* bucket end */
    mov %r13, %rax
    sub %r14, %rax
    cmp $1, %rax
    jbe 71f
    mov %rbx, %rdi
    mov %r14, %rsi
    mov %r13, %rdx
    mov MS_D(%rsp), %rcx
    inc %rcx
    call ks_msd
71: mov %r13, %r14
    inc %r15
    cmp $256, %r15
    jb 7b
    LEAVE
80: /* equal key words: production order, or row_cmp when incomplete */
    cmpq $0, KS_INCOMP(%rbx)
    je 89f
    mov MS_LO(%rsp), %rax
    KS_ENTRY %rbx, %rax, %rdi
    mov MS_HI(%rsp), %rsi
    sub MS_LO(%rsp), %rsi
    mov KS_STRIDE(%rbx), %rdx
    lea ks_cmp(%rip), %rcx
    mov %rbx, %r8
    call qsort_r
89: LEAVE
ENDF ks_msd

/* ks_enc_part(task rdi, part rsi, lo rdx, hi rcx): encodes rows [lo, hi)
 * into A[lo, hi); the OR / AND of the part's words go to KS_OR / KS_AND
 * (accumulated on the stack: parts must not share written cache lines) */
#define EP_OR   0       /* u64[KS_MAXW] */
#define EP_AND  (8 * KS_MAXW)
#define EP_HI   (16 * KS_MAXW)
#define EP_PART (EP_HI + 8)
FUNC ks_enc_part
    ENTER EP_PART + 8
    mov %rdi, %rbx
    mov %rcx, EP_HI(%rsp)
    mov %rsi, EP_PART(%rsp)
    xor %ecx, %ecx
1:  movq $0, EP_OR(%rsp, %rcx, 8)
    movq $-1, EP_AND(%rsp, %rcx, 8)
    inc %ecx
    cmp $KS_MAXW, %ecx
    jb 1b
    mov %rdx, %r13                  /* i */
    KS_ENTRY %rbx, %r13, %r15       /* &A[i] */
2:  cmp EP_HI(%rsp), %r13
    jae 5f
    mov KS_ROWS(%rbx), %rax
    mov (%rax, %r13, 8), %rsi       /* row */
    mov KS_W(%rbx), %rcx
    mov %rsi, (%r15, %rcx, 8)
    mov %r13, 8(%r15, %rcx, 8)
    xor %r14d, %r14d                /* word */
3:  cmp KS_W(%rbx), %r14
    jae 4f
    mov %r14, %rdi
    shl $5, %rdi                    /* SP_SIZE = 32 */
    lea KS_SPEC(%rbx, %rdi), %rdi
    mov KS_W(%rbx), %rcx
    mov (%r15, %rcx, 8), %rsi
    call ks_enc
    mov %rax, (%r15, %r14, 8)
    or %rax, EP_OR(%rsp, %r14, 8)
    and %rax, EP_AND(%rsp, %r14, 8)
    inc %r14
    jmp 3b
4:  add KS_STRIDE(%rbx), %r15
    inc %r13
    jmp 2b
5:  imul $8 * KS_MAXW, EP_PART(%rsp), %rax
    mov KS_OR(%rbx), %rdi
    add %rax, %rdi
    mov KS_AND(%rbx), %rsi
    add %rax, %rsi
    xor %ecx, %ecx
6:  mov EP_OR(%rsp, %rcx, 8), %rax
    mov %rax, (%rdi, %rcx, 8)
    mov EP_AND(%rsp, %rcx, 8), %rax
    mov %rax, (%rsi, %rcx, 8)
    inc %ecx
    cmp $KS_MAXW, %ecx
    jb 6b
    call check_deadline
    LEAVE
ENDF ks_enc_part

/* ks_class_part(task rdi, part rsi, lo rdx, hi rcx): the bucket of every
 * entry of A[lo, hi) (the number of splitters below it) -> KS_BID, and
 * the part's bucket counts -> KS_CNT[part] (counted on the stack) */
#define CP_CNT  0       /* u64[MAX_THREADS] */
#define CP_HI   (8 * MAX_THREADS)
#define CP_H    (CP_HI + 8)
#define CP_M    (CP_HI + 16)
#define CP_PART (CP_HI + 24)
FUNC ks_class_part
    ENTER CP_PART + 8
    mov %rdi, %rbx
    mov %rdx, %r12                  /* i */
    mov %rcx, CP_HI(%rsp)
    mov %rsi, CP_PART(%rsp)
    lea CP_CNT(%rsp), %rdi
    xor %eax, %eax
    mov $MAX_THREADS, %ecx
    rep stosq
1:  cmp CP_HI(%rsp), %r12
    jae 8f
    test $0xffff, %r12d
    jnz 2f
    call check_deadline
2:  KS_ENTRY %rbx, %r12, %r14
    xor %r15d, %r15d                /* l */
    mov KS_P(%rbx), %rax
    dec %rax
    mov %rax, CP_H(%rsp)            /* h */
3:  cmp CP_H(%rsp), %r15
    jae 5f
    mov CP_H(%rsp), %rax
    add %r15, %rax
    shr $1, %rax
    mov %rax, CP_M(%rsp)            /* m */
    KS_ENTRY %rbx, %rax, %rdi, KS_SPL
    mov %r14, %rsi
    mov %rbx, %rdx
    call ks_cmp
    mov CP_M(%rsp), %rcx
    cmp $0, %eax
    jge 4f
    lea 1(%rcx), %r15               /* splitter m below the entry */
    jmp 3b
4:  mov %rcx, CP_H(%rsp)
    jmp 3b
5:  mov KS_BID(%rbx), %rax
    mov %r15b, (%rax, %r12)
    incq CP_CNT(%rsp, %r15, 8)
    inc %r12
    jmp 1b
8:  mov CP_PART(%rsp), %rdi         /* publish the counts */
    imul KS_P(%rbx), %rdi
    shl $3, %rdi
    add KS_CNT(%rbx), %rdi
    lea CP_CNT(%rsp), %rsi
    mov KS_P(%rbx), %rdx
    shl $3, %rdx
    call memcpy
    LEAVE
ENDF ks_class_part

/* ks_scatter_part(task rdi, part rsi, lo rdx, hi rcx): moves the entries
 * of A[lo, hi) to their bucket positions in B (KS_CNT[part]: offsets,
 * advanced in a stack copy) */
FUNC ks_scatter_part
    ENTER CP_PART + 8
    mov %rdi, %rbx
    mov %rdx, %r12                  /* i */
    mov %rcx, CP_HI(%rsp)
    imul KS_P(%rbx), %rsi
    shl $3, %rsi
    add KS_CNT(%rbx), %rsi
    lea CP_CNT(%rsp), %rdi
    mov KS_P(%rbx), %rdx
    shl $3, %rdx
    call memcpy
    mov KS_W(%rbx), %r15
    add $2, %r15
1:  cmp CP_HI(%rsp), %r12
    jae 9f
    mov KS_BID(%rbx), %rax
    movzbl (%rax, %r12), %eax
    mov CP_CNT(%rsp, %rax, 8), %rdi
    incq CP_CNT(%rsp, %rax, 8)
    KS_ENTRY %rbx, %rdi, %r14, KS_B
    KS_ENTRY %rbx, %r12, %rsi
    mov %r14, %rdi
    mov %r15, %rcx
    call ks_copy
    inc %r12
    jmp 1b
9:  LEAVE
ENDF ks_scatter_part

/* ks_bucket_part(task rdi, part p rsi): sorts bucket p */
FUNC ks_bucket_part
    sub $8, %rsp
    mov KS_BOUNDS(%rdi), %rax
    mov 8(%rax, %rsi, 8), %rdx
    mov (%rax, %rsi, 8), %rsi
    mov %rdx, %rax
    sub %rsi, %rax
    cmp $1, %rax
    jbe 1f
    xor %ecx, %ecx
    call ks_msd
1:  add $8, %rsp
    ret
ENDF ks_bucket_part

/* ks_out_part(task rdi, part rsi, lo rdx, hi rcx): rows[i] = A[i].row */
FUNC ks_out_part
    KS_ENTRY %rdi, %rdx, %rsi
    mov KS_W(%rdi), %rax
    lea (%rsi, %rax, 8), %rsi       /* &A[lo].row */
    mov KS_STRIDE(%rdi), %r8
    mov KS_ROWS(%rdi), %r9
1:  cmp %rcx, %rdx
    jae 9f
    mov (%rsi), %rax
    mov %rax, (%r9, %rdx, 8)
    add %r8, %rsi
    inc %rdx
    jmp 1b
9:  ret
ENDF ks_out_part

/* ks_plan(task rdi) -> eax 1 if at least one key word: the word specs */
FUNC ks_plan
    ENTER 0
    mov %rdi, %rbx
    mov KS_PLAN(%rbx), %r12
    xor %r13d, %r13d                /* key */
    xor %r14d, %r14d                /* words */
1:  cmp QP_NKEYS(%r12), %r13
    jae 8f                          /* every key encoded */
    cmp $8, %r13
    jae 7f
    imul $SK_SIZE, %r13, %r15
    add QP_KEYS(%r12), %r15
    mov SK_TYPE(%r15), %rax
    movzbl %al, %ecx
    mov $WK_INT, %edx
    cmp $T_BOOL, %ecx
    je 2f
    cmp $T_INT, %ecx
    je 2f
    cmp $T_DATE, %ecx
    je 2f
    cmp $T_TS, %ecx
    je 2f
    mov $WK_FLOAT, %edx
    cmp $T_FLOAT, %ecx
    je 2f
    mov $WK_STR, %edx
    cmp $T_STR, %ecx
    je 2f
    cmp $T_DEC, %ecx
    jne 7f
    shr $8, %eax
    cmp $18, %al
    ja 7f                           /* wide DECIMAL: not normalized */
    mov $WK_INT, %edx
2:  movzbl KS_NULLS(%rbx, %r13), %ecx
    lea 1(%r14, %rcx), %rax         /* words needed */
    cmp $WK_STR, %edx
    jne 21f
    inc %rax
21: cmp $KS_MAXW, %rax
    ja 7f                           /* no room */
    mov QP_NOUT(%r12), %rax
    add %r13, %rax
    shl $4, %rax                    /* key cell offset */
    test %ecx, %ecx
    jz 3f
    mov %r14, %rdi                  /* NULL indicator word */
    shl $5, %rdi
    lea KS_SPEC(%rbx, %rdi), %rdi
    movq $WK_NULL, SP_KIND(%rdi)
    mov %rax, SP_OFF(%rdi)
    movq $0, SP_XOR(%rdi)
    xor %ecx, %ecx
    cmpq $0, SK_NFIRST(%r15)
    jne 22f
    mov $2, %ecx
22: mov %rcx, SP_ARG(%rdi)
    inc %r14
3:  mov %r14, %rdi                  /* value word(s) */
    shl $5, %rdi
    lea KS_SPEC(%rbx, %rdi), %rdi
    mov %rdx, SP_KIND(%rdi)
    mov %rax, SP_OFF(%rdi)
    xor %ecx, %ecx
    cmpq $0, SK_DESC(%r15)
    je 31f
    mov $-1, %rcx
31: mov %rcx, SP_XOR(%rdi)
    movq $0, SP_ARG(%rdi)
    inc %r14
    inc %r13
    cmp $WK_STR, %edx
    jne 1b
    movq $WK_STR, SP_SIZE+SP_KIND(%rdi)     /* second STRING word */
    mov %rax, SP_SIZE+SP_OFF(%rdi)
    mov %rcx, SP_SIZE+SP_XOR(%rdi)
    movq $1, SP_SIZE+SP_ARG(%rdi)
    inc %r14
    cmpb $0, KS_LONG-1(%rbx, %r13)
    je 1b                           /* exact: continue with the next key */
7:  movq $1, KS_INCOMP(%rbx)
8:  mov %r14, KS_W(%rbx)
    xor %eax, %eax
    test %r14, %r14
    setnz %al
    LEAVE
ENDF ks_plan

/* ks_split(task rdi): splitter selection - sorts a regular sample of A and
 * copies every KS_SAMPLE-th entry to KS_SPL */
FUNC ks_split
    ENTER 16
    mov %rdi, %rbx
    mov KS_P(%rbx), %r12
    imul $KS_SAMPLE, %r12           /* sample size S */
    mov %r12, %rdi
    imul KS_STRIDE(%rbx), %rdi
    call tmp_alloc
    mov %rax, %r13                  /* sample */
    xor %r14d, %r14d
1:  cmp %r12, %r14
    jae 2f
    lea (%r14, %r14), %rax          /* index (2s + 1) * n / 2S */
    inc %rax
    mulq KS_N(%rbx)
    lea (%r12, %r12), %rcx
    div %rcx
    KS_ENTRY %rbx, %rax, %rsi
    mov %r14, %rdi
    imul KS_STRIDE(%rbx), %rdi
    add %r13, %rdi
    mov KS_W(%rbx), %rcx
    add $2, %rcx
    call ks_copy
    inc %r14
    jmp 1b
2:  mov %r13, %rdi
    mov %r12, %rsi
    mov KS_STRIDE(%rbx), %rdx
    lea ks_cmp(%rip), %rcx
    mov %rbx, %r8
    call qsort_r
    mov KS_P(%rbx), %rdi
    imul KS_STRIDE(%rbx), %rdi
    call tmp_alloc
    mov %rax, KS_SPL(%rbx)
    xor %r14d, %r14d                /* splitter b = sample[(b + 1) * K - 1] */
3:  mov KS_P(%rbx), %rax
    dec %rax
    cmp %rax, %r14
    jae 9f
    lea 1(%r14), %rsi
    imul $KS_SAMPLE, %rsi
    dec %rsi
    imul KS_STRIDE(%rbx), %rsi
    add %r13, %rsi
    KS_ENTRY %rbx, %r14, %rdi, KS_SPL
    mov KS_W(%rbx), %rcx
    add $2, %rcx
    call ks_copy
    inc %r14
    jmp 3b
9:  LEAVE
ENDF ks_split

/* keysort(rows rdi, n rsi, plan rdx) -> eax 1 if sorted */
FUNC keysort
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov g_exec_threads(%rip), %rax  /* sorting evaluates no expressions */
    mov %rax, g_par_threads(%rip)
    mov $KS_SIZE, %edi
    call tmp_zalloc
    mov %rax, %r15
    mov %rbx, KS_ROWS(%r15)
    mov %r12, KS_N(%r15)
    mov %r13, KS_PLAN(%r15)
    mov %r12, %rdi
    call par_parts
    mov %rax, %r14                  /* parts */
    mov %r14, KS_P(%r15)
    mov %r15, %rdi                  /* NULLs and long strings per key */
    call ks_known
    cmpq $0, KS_NSCAN(%r15)
    je 1f
    mov %r12, %rdi
    mov %r14, %rsi
    lea ks_null_part(%rip), %rdx
    mov %r15, %rcx
    call par_run
1:
    mov %r15, %rdi
    call ks_plan
    test %eax, %eax
    jz 99f
    mov KS_W(%r15), %rax
    lea 16(, %rax, 8), %rax
    mov %rax, KS_STRIDE(%r15)
    imul %r12, %rax
    mov %rax, 0(%rsp)
    mov %rax, %rdi
    call tmp_alloc
    mov %rax, KS_A(%r15)
    mov 0(%rsp), %rdi
    call tmp_alloc
    mov %rax, KS_B(%r15)
    imul $8 * KS_MAXW, %r14, %rdi
    call tmp_alloc
    mov %rax, KS_OR(%r15)
    imul $8 * KS_MAXW, %r14, %rdi
    call tmp_alloc
    mov %rax, KS_AND(%r15)
    mov %r12, %rdi                  /* (1) encode */
    mov %r14, %rsi
    lea ks_enc_part(%rip), %rdx
    mov %r15, %rcx
    call par_run
    xor %ecx, %ecx                  /* differing bits: OR ^ AND over all */
1:  xor %eax, %eax
    mov $-1, %rdx
    xor %esi, %esi
2:  imul $KS_MAXW, %rsi, %rdi
    add %rcx, %rdi
    mov KS_OR(%r15), %r8
    or (%r8, %rdi, 8), %rax
    mov KS_AND(%r15), %r8
    and (%r8, %rdi, 8), %rdx
    inc %rsi
    cmp %r14, %rsi
    jb 2b
    xor %rdx, %rax
    mov %rax, KS_VARY(%r15, %rcx, 8)
    inc %ecx
    cmp $KS_MAXW, %ecx
    jb 1b
    cmp $1, %r14
    ja 3f
    mov %r15, %rdi                  /* one part: sort A directly */
    xor %esi, %esi
    mov %r12, %rdx
    xor %ecx, %ecx
    call ks_msd
    jmp 8f
3:  mov %r15, %rdi                  /* (2) splitters */
    call ks_split
    mov %r14, %rdi
    imul %r14, %rdi
    shl $3, %rdi
    call tmp_zalloc
    mov %rax, KS_CNT(%r15)
    mov %r12, %rdi
    call tmp_alloc
    mov %rax, KS_BID(%r15)
    mov %r12, %rdi                  /* (3) bucket of every entry */
    mov %r14, %rsi
    lea ks_class_part(%rip), %rdx
    mov %r15, %rcx
    call par_run
    lea 8(, %r14, 8), %rdi          /* bucket bounds; counts -> offsets */
    call tmp_alloc
    mov %rax, KS_BOUNDS(%r15)
    xor %edx, %edx                  /* running position */
    xor %ecx, %ecx                  /* bucket */
4:  mov KS_BOUNDS(%r15), %rax
    mov %rdx, (%rax, %rcx, 8)
    xor %esi, %esi                  /* part */
5:  mov %rsi, %rdi
    imul %r14, %rdi
    add %rcx, %rdi
    shl $3, %rdi
    add KS_CNT(%r15), %rdi
    mov (%rdi), %rax
    mov %rdx, (%rdi)
    add %rax, %rdx
    inc %rsi
    cmp %r14, %rsi
    jb 5b
    inc %rcx
    cmp %r14, %rcx
    jb 4b
    mov KS_BOUNDS(%r15), %rax
    mov %rdx, (%rax, %r14, 8)
    mov %r12, %rdi                  /* (4) scatter into B */
    mov %r14, %rsi
    lea ks_scatter_part(%rip), %rdx
    mov %r15, %rcx
    call par_run
    mov KS_A(%r15), %rax            /* B holds the entries now */
    mov KS_B(%r15), %rcx
    mov %rcx, KS_A(%r15)
    mov %rax, KS_B(%r15)
    mov %r14, %rdi                  /* (5) sort every bucket */
    mov %r14, %rsi
    lea ks_bucket_part(%rip), %rdx
    mov %r15, %rcx
    call par_run
8:  mov %r12, %rdi                  /* rows in sorted order */
    mov %r14, %rsi
    lea ks_out_part(%rip), %rdx
    mov %r15, %rcx
    call par_run
    mov $1, %eax
99: LEAVE
ENDF keysort
