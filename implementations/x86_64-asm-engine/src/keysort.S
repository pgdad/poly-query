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
 *   STRING: the first 8 bytes, big-endian, zero padded (a prefix: only a
 *     difference is decisive);
 *   DESC keys are complemented.
 * Encoding stops at a STRING key, a wide DECIMAL, the word limit or the
 * last key; when it stopped early the key words are *incomplete*: entries
 * with equal words are ordered by row_cmp, then by sequence.
 *
 * The rows are split into P runs (par.S).  Each run is encoded and sorted
 * on its own thread by an MSD radix sort over the bytes of the key words
 * (bytes that are equal in the whole run are skipped; buckets of up to
 * KS_SMALL entries are insertion sorted; buckets whose words are exhausted
 * are already in sequence order, or sorted with qsort_r when incomplete).
 * The sorted runs are then merged pairwise in parallel rounds, as in
 * pexec_sort.  Radix scatters are stable and the comparisons end with the
 * sequence number, so the result is deterministic and equals sort_rows.
 */
#include "pq.inc"
#include "sql.inc"

    .section .note.GNU-stack, "", @progbits

#define KS_MAXW  4      /* key words per entry */
#define KS_SMALL 32     /* insertion sort below this bucket size */

/* word kinds */
#define WK_NULL  0
#define WK_INT   1
#define WK_FLOAT 2
#define WK_STR   3

/* word spec */
#define SP_KIND  0
#define SP_OFF   8      /* byte offset of the key cell in the row */
#define SP_XOR   16     /* -1 for DESC keys, else 0 */
#define SP_NULLW 24     /* WK_NULL: word of a NULL (0 first, 2 last) */
#define SP_SIZE  32

/* sort task */
#define KS_ROWS   0
#define KS_N      8
#define KS_PLAN   16
#define KS_W      24
#define KS_STRIDE 32    /* entry bytes: 8 * (W + 2) */
#define KS_INCOMP 40    /* key words incomplete: ties go to row_cmp */
#define KS_A      48    /* entries (source of a merge round) */
#define KS_B      56    /* scratch (destination of a merge round) */
#define KS_BOUNDS 64    /* u64[runs + 1] */
#define KS_NULLS  72    /* u8[8]: key k has NULLs */
#define KS_SPEC   80    /* spec[KS_MAXW] */
#define KS_SIZE   (80 + SP_SIZE * KS_MAXW)

    .text

/* ks_null_part(task rdi, part rsi, lo rdx, hi rcx): flags the keys (up to
 * 8) that are NULL in some row of [lo, hi) */
FUNC ks_null_part
    ENTER 0
    mov %rdi, %rbx
    mov KS_PLAN(%rbx), %r8
    mov QP_NKEYS(%r8), %r9
    mov $8, %eax
    cmp %rax, %r9
    cmova %rax, %r9                 /* keys checked */
    mov QP_NOUT(%r8), %r10
    shl $4, %r10                    /* offset of the first key cell */
    mov KS_ROWS(%rbx), %r11
    xor %r12d, %r12d                /* key */
1:  cmp %r9, %r12
    jae 9f
    mov %r12, %rax
    shl $4, %rax
    add %r10, %rax                  /* cell offset */
    mov %rdx, %rsi
2:  cmp %rcx, %rsi
    jae 4f
    mov (%r11, %rsi, 8), %rdi
    cmpq $0, VAL_NULL(%rdi, %rax)
    jne 3f
    inc %rsi
    jmp 2b
3:  movb $1, KS_NULLS(%rbx, %r12)
4:  inc %r12
    jmp 1b
9:  LEAVE
ENDF ks_null_part

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
3:  mov PSTR_LEN(%rax), %rcx        /* STRING: 8-byte big-endian prefix */
    cmp $8, %rcx
    jb 4f
    mov PSTR_DATA(%rax), %rax
    bswap %rax
    jmp 6f
4:  lea PSTR_DATA(%rax), %rsi
    mov %rcx, %r8
    xor %edx, %edx
41: test %rcx, %rcx
    jz 42f
    shl $8, %rdx
    movzbl (%rsi), %eax
    or %rax, %rdx
    inc %rsi
    dec %rcx
    jmp 41b
42: mov $8, %ecx
    sub %r8d, %ecx
    shl $3, %ecx                    /* pad: shift by 8 * (8 - len) < 64 */
    shl %cl, %rdx                   /* (empty string: 0) */
    mov %rdx, %rax
6:  xor SP_XOR(%rdi), %rax
    ret
7:  mov $1, %eax                    /* NULL indicator of a value */
    ret
8:  xor %eax, %eax                  /* NULL */
    cmp $WK_NULL, %ecx
    jne 9f
    mov SP_NULLW(%rdi), %rax
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
    ENTER 64                        /* 0..47: the entry being inserted */
    mov %rdi, %rbx
    mov %rsi, %r12                  /* lo */
    mov %rdx, %r13
    lea 1(%r12), %r14               /* i */
1:  cmp %r13, %r14
    jae 9f
    mov KS_STRIDE(%rbx), %rax
    imul %r14, %rax
    add KS_A(%rbx), %rax
    mov %rax, %r15                  /* &A[j], j = i */
    lea 0(%rsp), %rdi
    mov %rax, %rsi
    mov KS_W(%rbx), %rcx
    add $2, %rcx
    call ks_copy
    mov %r14, 56(%rsp)              /* j */
2:  cmp %r12, 56(%rsp)
    jbe 3f
    mov %r15, %rdi
    sub KS_STRIDE(%rbx), %rdi       /* A[j - 1] */
    lea 0(%rsp), %rsi
    mov %rbx, %rdx
    call ks_cmp
    cmp $0, %eax
    jle 3f
    mov %r15, %rdi                  /* A[j] = A[j - 1] */
    mov %r15, %rsi
    sub KS_STRIDE(%rbx), %rsi
    mov KS_W(%rbx), %rcx
    add $2, %rcx
    call ks_copy
    sub KS_STRIDE(%rbx), %r15
    decq 56(%rsp)
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

/* ks_msd(task rdi, vary rsi, lo rdx, hi rcx, digit r8): sorts A[lo, hi),
 * whose entries agree on every digit before `digit` (digit 0 = the most
 * significant byte of word 0).  vary: u64[W], the bits that differ
 * somewhere in the run. */
#define MS_CNT   0      /* u64[256] bucket counts, then bucket ends */
#define MS_VARY  2048
#define MS_LO    2056
#define MS_HI    2064
#define MS_D     2072
#define MS_SHIFT 2080
#define MS_WORD  2088
FUNC ks_msd
    ENTER 2096
    mov %rdi, %rbx
    mov %rsi, MS_VARY(%rsp)
    mov %rdx, MS_LO(%rsp)
    mov %rcx, MS_HI(%rsp)
    mov %r8, MS_D(%rsp)
    sub %rdx, %rcx                  /* n */
    cmp $KS_SMALL, %rcx
    ja 1f
    mov %rbx, %rdi
    mov MS_LO(%rsp), %rsi
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
    mov MS_VARY(%rsp), %rsi
    mov (%rsi, %rdx, 8), %rsi
    shr %cl, %rsi
    test $0xff, %esi
    jnz 2f
    incq MS_D(%rsp)                 /* constant in the run */
    jmp 1b
2:  /* histogram */
    lea MS_CNT(%rsp), %rdi
    xor %eax, %eax
    mov $256, %ecx
    rep stosq
    mov MS_LO(%rsp), %rax
    mov KS_STRIDE(%rbx), %r12
    imul %r12, %rax
    add KS_A(%rbx), %rax
    mov MS_WORD(%rsp), %rdx
    lea (%rax, %rdx, 8), %rsi       /* &A[lo].word */
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
    /* all in one bucket: the digit is constant here */
    sub %r12, %rsi                  /* the last entry's word */
    mov (%rsi), %rax
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
    mov MS_LO(%rsp), %r14
    imul %r12, %r14
    add KS_A(%rbx), %r14            /* source entry */
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
    mov MS_VARY(%rsp), %rsi
    mov %r14, %rdx
    mov %r13, %rcx
    mov MS_D(%rsp), %r8
    inc %r8
    call ks_msd
71: mov %r13, %r14
    inc %r15
    cmp $256, %r15
    jb 7b
    LEAVE
80: /* equal key words: production order, or row_cmp when incomplete */
    cmpq $0, KS_INCOMP(%rbx)
    je 89f
    mov MS_LO(%rsp), %rdi
    imul KS_STRIDE(%rbx), %rdi
    add KS_A(%rbx), %rdi
    mov MS_HI(%rsp), %rsi
    sub MS_LO(%rsp), %rsi
    mov KS_STRIDE(%rbx), %rdx
    lea ks_cmp(%rip), %rcx
    mov %rbx, %r8
    call qsort_r
89: LEAVE
ENDF ks_msd

/* ks_sort_part(task rdi, part rsi, lo rdx, hi rcx): encodes rows [lo, hi)
 * into A[lo, hi) and sorts them */
FUNC ks_sort_part
    ENTER 80                        /* 0: OR[4], 32: AND[4], 64: hi */
    mov %rdi, %rbx
    mov %rdx, %r12                  /* lo */
    mov %rcx, 64(%rsp)
    xor %ecx, %ecx
1:  movq $0, 0(%rsp, %rcx, 8)
    movq $-1, 32(%rsp, %rcx, 8)
    inc %ecx
    cmp $KS_MAXW, %ecx
    jb 1b
    mov %r12, %r13                  /* i */
    mov %r12, %r15
    imul KS_STRIDE(%rbx), %r15
    add KS_A(%rbx), %r15            /* &A[i] */
2:  cmp 64(%rsp), %r13
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
    or %rax, 0(%rsp, %r14, 8)
    and %rax, 32(%rsp, %r14, 8)
    inc %r14
    jmp 3b
4:  add KS_STRIDE(%rbx), %r15
    inc %r13
    jmp 2b
5:  call check_deadline
    xor %ecx, %ecx                  /* differing bits: OR ^ AND */
6:  mov 32(%rsp, %rcx, 8), %rax
    xor %rax, 0(%rsp, %rcx, 8)
    inc %ecx
    cmp $KS_MAXW, %ecx
    jb 6b
    mov %rbx, %rdi
    lea 0(%rsp), %rsi
    mov %r12, %rdx
    mov 64(%rsp), %rcx
    xor %r8d, %r8d
    call ks_msd
    LEAVE
ENDF ks_sort_part

/* ks_merge_part(task rdi, part k rsi): merges the sorted runs 2k and 2k+1
 * of A into B */
FUNC ks_merge_part
    ENTER 16
    mov %rdi, %rbx
    mov KS_BOUNDS(%rbx), %rax
    lea (%rsi, %rsi), %rcx
    mov (%rax, %rcx, 8), %r12       /* i: first run */
    mov 8(%rax, %rcx, 8), %r13      /* j: second run (= end of the first) */
    mov %r13, 0(%rsp)
    mov 16(%rax, %rcx, 8), %rax
    mov %rax, 8(%rsp)               /* end of the second run */
    mov %r12, %r14                  /* output position */
    mov KS_STRIDE(%rbx), %r15
1:  cmp 0(%rsp), %r12
    jae 5f
    cmp 8(%rsp), %r13
    jae 5f
    mov %r13, %rdi
    imul %r15, %rdi
    add KS_A(%rbx), %rdi
    mov %r12, %rsi
    imul %r15, %rsi
    add KS_A(%rbx), %rsi
    mov %rbx, %rdx
    call ks_cmp
    mov %r12, %rsi
    cmp $0, %eax
    jge 2f
    mov %r13, %rsi                  /* the second run's entry first */
    inc %r13
    jmp 3f
2:  inc %r12
3:  imul %r15, %rsi
    add KS_A(%rbx), %rsi
    mov %r14, %rdi
    imul %r15, %rdi
    add KS_B(%rbx), %rdi
    mov KS_W(%rbx), %rcx
    add $2, %rcx
    call ks_copy
    inc %r14
    jmp 1b
5:  mov %r14, %rdi                  /* the rest of either run */
    imul %r15, %rdi
    add KS_B(%rbx), %rdi
    mov %r12, %rsi
    imul %r15, %rsi
    add KS_A(%rbx), %rsi
    mov 0(%rsp), %rdx
    sub %r12, %rdx
    add %rdx, %r14
    imul %r15, %rdx
    call memcpy
    mov %r14, %rdi
    imul %r15, %rdi
    add KS_B(%rbx), %rdi
    mov %r13, %rsi
    imul %r15, %rsi
    add KS_A(%rbx), %rsi
    mov 8(%rsp), %rdx
    sub %r13, %rdx
    imul %r15, %rdx
    call memcpy
    LEAVE
ENDF ks_merge_part

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
    lea 1(%r14, %rcx), %rax
    cmp $KS_MAXW, %rax
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
    jne 21f
    mov $2, %ecx
21: mov %rcx, SP_NULLW(%rdi)
    inc %r14
3:  mov %r14, %rdi                  /* value word */
    shl $5, %rdi
    lea KS_SPEC(%rbx, %rdi), %rdi
    mov %rdx, SP_KIND(%rdi)
    mov %rax, SP_OFF(%rdi)
    xor %ecx, %ecx
    cmpq $0, SK_DESC(%r15)
    je 31f
    mov $-1, %rcx
31: mov %rcx, SP_XOR(%rdi)
    movq $0, SP_NULLW(%rdi)
    inc %r14
    inc %r13
    cmp $WK_STR, %edx
    jne 1b                          /* a STRING prefix ends the words */
7:  movq $1, KS_INCOMP(%rbx)
8:  mov %r14, KS_W(%rbx)
    xor %eax, %eax
    test %r14, %r14
    setnz %al
    LEAVE
ENDF ks_plan

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
    mov %rax, %r14                  /* runs */
    mov %r12, %rdi                  /* which keys have NULLs */
    mov %r14, %rsi
    lea ks_null_part(%rip), %rdx
    mov %r15, %rcx
    call par_run
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
    lea 8(, %r14, 8), %rdi
    call tmp_alloc
    mov %rax, KS_BOUNDS(%r15)       /* bounds of run p: n * p / P */
    xor %ecx, %ecx
1:  cmp %r14, %rcx
    ja 2f
    mov %r12, %rax
    mul %rcx
    div %r14
    mov KS_BOUNDS(%r15), %rdx
    mov %rax, (%rdx, %rcx, 8)
    inc %rcx
    jmp 1b
2:  mov %r12, %rdi                  /* sorted runs */
    mov %r14, %rsi
    lea ks_sort_part(%rip), %rdx
    mov %r15, %rcx
    call par_run
3:  cmp $1, %r14                    /* merge rounds */
    jbe 8f
    mov %r14, %rdi
    shr $1, %rdi
    mov %rdi, %rsi
    lea ks_merge_part(%rip), %rdx
    mov %r15, %rcx
    call par_run
    test $1, %r14                   /* odd run count: the last run moves */
    jz 4f
    mov KS_BOUNDS(%r15), %rax
    mov -8(%rax, %r14, 8), %rsi     /* start of the last run */
    mov (%rax, %r14, 8), %rdx
    sub %rsi, %rdx
    imul KS_STRIDE(%r15), %rdx
    imul KS_STRIDE(%r15), %rsi
    mov KS_B(%r15), %rdi
    add %rsi, %rdi
    add KS_A(%r15), %rsi
    call memcpy
4:  mov KS_BOUNDS(%r15), %rax       /* bounds of the merged runs */
    xor %ecx, %ecx
5:  lea (%rcx, %rcx), %rdx
    cmp %r14, %rdx
    jae 6f
    mov (%rax, %rdx, 8), %rdx
    mov %rdx, (%rax, %rcx, 8)
    inc %rcx
    jmp 5b
6:  mov (%rax, %r14, 8), %rdx       /* final bound */
    mov %rdx, (%rax, %rcx, 8)
    mov %rcx, %r14                  /* runs = ceil(runs / 2) */
    mov KS_A(%r15), %rax            /* swap source and destination */
    mov KS_B(%r15), %rcx
    mov %rcx, KS_A(%r15)
    mov %rax, KS_B(%r15)
    jmp 3b
8:  mov KS_A(%r15), %rsi            /* rows in sorted order */
    mov KS_W(%r15), %rax
    lea (%rsi, %rax, 8), %rsi       /* &A[0].row */
    mov KS_STRIDE(%r15), %rcx
    xor %edx, %edx
81: cmp %r12, %rdx
    jae 82f
    mov (%rsi), %rax
    mov %rax, (%rbx, %rdx, 8)
    add %rcx, %rsi
    inc %rdx
    jmp 81b
82: mov $1, %eax
99: LEAVE
ENDF keysort
