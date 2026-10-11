/*
 * pqcf.S - PQCF v1 columnar files (storage/pqcf-v1.md): writer, validating
 * reader, CRC-32, atomic crash-safe replacement.
 *
 *   crc32(ptr rdi, len rsi) -> eax           ISO-HDLC / zlib CRC-32
 *   utf8_valid(ptr rdi, len rsi) -> eax 1 if well-formed UTF-8
 *   data_path(pstr rdi) -> rax C string "<data-dir>/<path>" (ACCESS_DENIED
 *                          for unsafe paths)
 *   pqcf_save(table rdi, path pstr rsi, encoding rdx (ENC_*), rg size rcx)
 *       -> rax bytes written.  The file is assembled in memory, written to
 *       ".<name>.tmp-<pid>-<seq>" in the target's directory, fsync'ed,
 *       renamed over the target, and the directory is fsync'ed.
 *   pqcf_read(path pstr rdi, name pstr rsi, mmap edx, index specs Vec* rcx)
 *       -> rax staging Table* (allocated in g_pending_arena).  Validates
 *       header, footer, metadata CRC and structure, every chunk CRC and every
 *       value (STORAGE_CORRUPT / STORAGE_VERSION_UNSUPPORTED) and decodes all
 *       chunks eagerly; the file is memory-mapped while decoding when mmap is
 *       requested.  Row-group statistics are kept for row-group skipping
 *       (TB_RGS).  Index entries are appended to the Vec as triples
 *       (name pstr, column index, IXK_*).
 */
#include "pq.inc"
#include "sql.inc"

    .section .note.GNU-stack, "", @progbits

/* chunk encodings */
#define EN_PLAIN 1
#define EN_DICT  2
#define EN_RLE   3

#define DEFAULT_RG 65536

/* chunk decoding context (on pqcf_read's frame) */
#define DC_P     0     /* chunk bytes */
#define DC_L     8     /* chunk length */
#define DC_N     16    /* rows in the group */
#define DC_NC    24    /* null_count */
#define DC_COL   32    /* staging Column* */
#define DC_ROW0  40    /* first table row of the group */
#define DC_ENC   48
#define DC_POS   56    /* read position */
#define DC_TYPE  64
#define DC_BM    72    /* validity bitmap or 0 */
#define DC_SIZE  80

#define MIN_DAYS -719162
#define MAX_DAYS 2932896

    .bss
    .p2align 4
crc_table:  .zero 1024
crc_ready:  .quad 0
wbuf:       .zero BUF_SIZE      /* file image being written */
mbuf:       .zero BUF_SIZE      /* metadata JSON being written */
save_seq:   .quad 0
    .globl g_pending_map, g_pending_map_len
g_pending_map:      .quad 0     /* mapping of a file being read; unmapped on error */
g_pending_map_len:  .quad 0

    .section .rodata
    .p2align 3
enc_names: .quad 0, en_plain, en_dict, en_rle
en_plain: .asciz "PLAIN"
en_dict:  .asciz "DICT"
en_rle:   .asciz "RLE"
min_ts:   .quad -62135596800000000
max_ts:   .quad 253402300799999999

    .text

/* ================================================================ CRC-32 */

FUNC crc32
    cmpq $0, crc_ready(%rip)
    jne 3f
    lea crc_table(%rip), %r8        /* build the table once */
    xor %ecx, %ecx
1:  mov %ecx, %eax
    mov $8, %edx
2:  shr $1, %eax
    jnc 21f
    xor $0xEDB88320, %eax
21: dec %edx
    jnz 2b
    mov %eax, (%r8, %rcx, 4)
    inc %ecx
    cmp $256, %ecx
    jb 1b
    movq $1, crc_ready(%rip)
3:  lea crc_table(%rip), %r8
    mov $-1, %eax
    test %rsi, %rsi
    jz 9f
4:  movzbl (%rdi), %ecx
    xor %al, %cl
    shr $8, %eax
    xor (%r8, %rcx, 4), %eax
    inc %rdi
    dec %rsi
    jnz 4b
9:  not %eax
    ret
ENDF crc32

/* ================================================================ UTF-8 */

FUNC utf8_valid
    xor %ecx, %ecx                  /* index */
1:  cmp %rsi, %rcx
    jae 8f
    movzbl (%rdi, %rcx), %eax
    cmp $0x80, %eax
    jae 2f
    inc %rcx
    jmp 1b
2:  cmp $0xC2, %eax
    jb 9f
    cmp $0xE0, %eax
    jae 3f
    mov $1, %edx                    /* 2-byte sequence */
    mov $0x80, %r8d
    mov $0xBF, %r9d
    jmp 5f
3:  cmp $0xF0, %eax
    jae 4f
    mov $2, %edx                    /* 3-byte: E0 A0.., ED ..9F */
    mov $0x80, %r8d
    mov $0xBF, %r9d
    cmp $0xE0, %eax
    jne 31f
    mov $0xA0, %r8d
31: cmp $0xED, %eax
    jne 5f
    mov $0x9F, %r9d
    jmp 5f
4:  cmp $0xF4, %eax
    ja 9f
    mov $3, %edx                    /* 4-byte: F0 90.., F4 ..8F */
    mov $0x80, %r8d
    mov $0xBF, %r9d
    cmp $0xF0, %eax
    jne 41f
    mov $0x90, %r8d
41: cmp $0xF4, %eax
    jne 5f
    mov $0x8F, %r9d
5:  lea (%rcx, %rdx), %rax          /* enough bytes? */
    cmp %rsi, %rax
    jae 9f
    inc %rcx
    movzbl (%rdi, %rcx), %eax       /* first continuation: restricted range */
    cmp %r8d, %eax
    jb 9f
    cmp %r9d, %eax
    ja 9f
    dec %edx
6:  inc %rcx
    test %edx, %edx
    jz 1b
    movzbl (%rdi, %rcx), %eax
    and $0xC0, %eax
    cmp $0x80, %eax
    jne 9f
    dec %edx
    jmp 6b
8:  mov $1, %eax
    ret
9:  xor %eax, %eax
    ret
ENDF utf8_valid

/* ================================================================ paths */

/* data_path(pstr) -> rax "<data-dir>/<path>" in the request arena */
FUNC data_path
    ENTER 0
    mov %rdi, %rbx
    call check_path
    mov g_data_dir(%rip), %rdi
    call strlen
    lea 16(%rax), %r13
    add (%rbx), %r13
    mov %r13, %rdi
    call tmp_alloc
    mov %rax, %r12
    mov %r12, %rdi
    mov %r13, %rsi
    CSTR %rdx, "%s/%s"
    mov g_data_dir(%rip), %rcx
    lea 8(%rbx), %r8
    xor %eax, %eax
    call snprintf
    mov %r12, %rax
    LEAVE
ENDF data_path

/* ================================================================ writer */

/* wb_put(ptr, len) */
FUNC wb_put
    mov %rsi, %rdx
    mov %rdi, %rsi
    lea wbuf(%rip), %rdi
    jmp buf_put
ENDF wb_put

/* wb_word(value rdi, bytes esi): little-endian u8/u32/u64 */
FUNC wb_word
    sub $24, %rsp
    mov %rdi, 0(%rsp)
    lea 0(%rsp), %rdi
    mov %esi, %esi
    call wb_put
    add $24, %rsp
    ret
ENDF wb_word

/* wb_pad8(): zero padding to an 8-byte boundary */
FUNC wb_pad8
    sub $8, %rsp
1:  testq $7, wbuf+BUF_LEN(%rip)
    jz 9f
    lea wbuf(%rip), %rdi
    xor %esi, %esi
    call buf_putc
    jmp 1b
9:  add $8, %rsp
    ret
ENDF wb_pad8

/* chunk writer state (on write_chunk's frame) */
#define WC_COL    0
#define WC_START  8
#define WC_N      16
#define WC_ENC    24    /* requested ENC_* */
#define WC_TYPE   32
#define WC_NULLS  40
#define WC_HAS    48
#define WC_MIN    56
#define WC_MAX    64
#define WC_OFF    72
#define WC_RUNS   80
#define WC_E      88    /* chosen EN_* */
#define WC_HT     96
#define WC_DICT   104   /* Vec of distinct pstr* */
#define WC_CODES  112   /* u32[n] */
#define WC_TMP    120   /* 120..151 scratch */
#define WC_SIZE   160

/* write_chunk(col rdi, start rsi, n rdx, requested encoding rcx) */
FUNC write_chunk
    ENTER WC_SIZE
    mov %rdi, WC_COL(%rsp)
    mov %rsi, WC_START(%rsp)
    mov %rdx, WC_N(%rsp)
    mov %rcx, WC_ENC(%rsp)
    mov COL_TYPE(%rdi), %rax
    mov %rax, WC_TYPE(%rsp)
    movq $0, WC_NULLS(%rsp)
    movq $0, WC_HAS(%rsp)
    movq $0, WC_RUNS(%rsp)
    call wb_pad8
    mov wbuf+BUF_LEN(%rip), %rax
    mov %rax, WC_OFF(%rsp)
    /* ---- pass 1: nulls, min/max, runs */
    xor %r12d, %r12d                /* i */
    xor %r13d, %r13d                /* previous slot value */
1:  cmp WC_N(%rsp), %r12
    jae 5f
    mov WC_COL(%rsp), %rdi
    mov WC_START(%rsp), %rsi
    add %r12, %rsi
    call col_get
    test %edx, %edx
    jz 2f
    incq WC_NULLS(%rsp)
    mov %r13, %rax                  /* NULL slots extend the current run */
    jmp 4f
2:  mov %rax, %r14
    cmpq $0, WC_HAS(%rsp)
    jne 21f
    movq $1, WC_HAS(%rsp)
    mov %rax, WC_MIN(%rsp)
    mov %rax, WC_MAX(%rsp)
    jmp 3f
21: mov WC_TYPE(%rsp), %rdi
    mov %r14, %rsi
    mov WC_MIN(%rsp), %rdx
    call value_cmp
    test %eax, %eax
    jns 22f
    mov %r14, WC_MIN(%rsp)
22: mov WC_TYPE(%rsp), %rdi
    mov %r14, %rsi
    mov WC_MAX(%rsp), %rdx
    call value_cmp
    test %eax, %eax
    jle 3f
    mov %r14, WC_MAX(%rsp)
3:  mov %r14, %rax
4:  test %r12, %r12
    jz 41f
    cmp %r13, %rax
    je 42f
41: incq WC_RUNS(%rsp)
42: mov %rax, %r13
    inc %r12
    jmp 1b

5:  /* ---- validity bitmap */
    cmpq $0, WC_NULLS(%rsp)
    je 7f
    xor %r12d, %r12d                /* byte index * 8 */
6:  cmp WC_N(%rsp), %r12
    jae 7f
    xor %r14d, %r14d                /* byte */
    xor %r15d, %r15d                /* bit */
61: cmp $8, %r15d
    jae 63f
    lea (%r12, %r15), %rsi
    cmp WC_N(%rsp), %rsi
    jae 63f
    add WC_START(%rsp), %rsi
    mov WC_COL(%rsp), %rdi
    call col_get
    test %edx, %edx
    jnz 62f
    bts %r15d, %r14d
62: inc %r15d
    jmp 61b
63: mov %r14, %rdi
    mov $1, %esi
    call wb_word
    add $8, %r12
    jmp 6b

7:  /* ---- encoding choice */
    movzbl WC_TYPE(%rsp), %r15d     /* kind */
    movq $EN_PLAIN, WC_E(%rsp)
    mov WC_ENC(%rsp), %rax
    cmp $ENC_PLAIN, %rax
    je 79f
    cmp $T_STR, %r15d
    je 73f
    cmp $T_FLOAT, %r15d
    je 79f
    /* RLE-capable type */
    cmp $ENC_RLE, %rax
    je 72f
    cmp $ENC_AUTO, %rax
    jne 79f
    mov WC_RUNS(%rsp), %rcx         /* auto: runs < n/4 */
    shl $2, %rcx
    cmp WC_N(%rsp), %rcx
    jae 79f
72: movq $EN_RLE, WC_E(%rsp)
    jmp 79f
73: cmp $ENC_RLE, %rax
    je 79f
    call build_dict                 /* STRING: DICT forced or worthwhile */
    cmpq $ENC_DICT, WC_ENC(%rsp)
    je 74f
    mov WC_DICT(%rsp), %rax
    mov VEC_LEN(%rax), %rax
    shl $1, %rax
    cmp WC_N(%rsp), %rax
    jae 79f
74: movq $EN_DICT, WC_E(%rsp)
79: mov WC_E(%rsp), %rax
    cmp $EN_DICT, %rax
    je 30f
    cmp $EN_RLE, %rax
    je 40f

    /* ---- PLAIN */
    cmp $T_BOOL, %r15d
    je 10f
    cmp $T_STR, %r15d
    je 20f
    xor %r12d, %r12d
8:  cmp WC_N(%rsp), %r12
    jae 90f
    mov WC_COL(%rsp), %rdi
    mov WC_START(%rsp), %rsi
    add %r12, %rsi
    call col_get
    mov %rax, %rdi
    mov $8, %esi
    cmp $T_DATE, %r15d
    jne 81f
    mov $4, %esi
81: call wb_word
    inc %r12
    jmp 8b
10: xor %r12d, %r12d                /* BOOLEAN bitmap */
11: cmp WC_N(%rsp), %r12
    jae 90f
    xor %r14d, %r14d
    xor %r13d, %r13d
12: cmp $8, %r13d
    jae 14f
    lea (%r12, %r13), %rsi
    cmp WC_N(%rsp), %rsi
    jae 14f
    add WC_START(%rsp), %rsi
    mov WC_COL(%rsp), %rdi
    call col_get
    test %rax, %rax
    jz 13f
    bts %r13d, %r14d
13: inc %r13d
    jmp 12b
14: mov %r14, %rdi
    mov $1, %esi
    call wb_word
    add $8, %r12
    jmp 11b
20: /* STRING: offsets, then bytes */
    xor %r12d, %r12d
    xor %r13d, %r13d                /* running offset */
    xor %edi, %edi
    mov $4, %esi
    call wb_word
21: cmp WC_N(%rsp), %r12
    jae 23f
    mov WC_COL(%rsp), %rdi
    mov WC_START(%rsp), %rsi
    add %r12, %rsi
    call col_get
    test %edx, %edx
    jnz 22f
    add (%rax), %r13
22: mov %r13, %rdi
    mov $4, %esi
    call wb_word
    inc %r12
    jmp 21b
23: xor %r12d, %r12d
24: cmp WC_N(%rsp), %r12
    jae 90f
    mov WC_COL(%rsp), %rdi
    mov WC_START(%rsp), %rsi
    add %r12, %rsi
    call col_get
    test %edx, %edx
    jnz 25f
    lea 8(%rax), %rdi
    mov (%rax), %rsi
    call wb_put
25: inc %r12
    jmp 24b

30: /* ---- DICT: D, offsets, bytes, codes */
    mov WC_DICT(%rsp), %rbx
    mov VEC_LEN(%rbx), %rdi
    mov $4, %esi
    call wb_word
    xor %edi, %edi
    mov $4, %esi
    call wb_word
    xor %r12d, %r12d
    xor %r13d, %r13d
31: cmp VEC_LEN(%rbx), %r12
    jae 32f
    mov VEC_DATA(%rbx), %rax
    mov (%rax, %r12, 8), %rax
    add (%rax), %r13
    mov %r13, %rdi
    mov $4, %esi
    call wb_word
    inc %r12
    jmp 31b
32: xor %r12d, %r12d
33: cmp VEC_LEN(%rbx), %r12
    jae 34f
    mov VEC_DATA(%rbx), %rax
    mov (%rax, %r12, 8), %rax
    lea 8(%rax), %rdi
    mov (%rax), %rsi
    call wb_put
    inc %r12
    jmp 33b
34: mov WC_CODES(%rsp), %rdi
    mov WC_N(%rsp), %rsi
    shl $2, %rsi
    call wb_put
    jmp 90f

40: /* ---- RLE: R, then (i64 value, u32 length) per run */
    mov WC_RUNS(%rsp), %rdi
    mov $4, %esi
    call wb_word
    xor %r12d, %r12d                /* i */
    xor %r13d, %r13d                /* run value */
    xor %r14d, %r14d                /* run length */
41: cmp WC_N(%rsp), %r12
    jae 44f
    mov WC_COL(%rsp), %rdi
    mov WC_START(%rsp), %rsi
    add %r12, %rsi
    call col_get
    test %edx, %edx
    jz 42f
    mov %r13, %rax                  /* NULL: continues the run */
42: test %r14, %r14
    jz 43f
    cmp %r13, %rax
    je 43f
    mov %rax, WC_TMP(%rsp)
    mov %r13, %rdi
    mov $8, %esi
    call wb_word
    mov %r14, %rdi
    mov $4, %esi
    call wb_word
    mov WC_TMP(%rsp), %rax
    xor %r14d, %r14d
43: mov %rax, %r13
    inc %r14
    inc %r12
    jmp 41b
44: test %r14, %r14
    jz 90f
    mov %r13, %rdi
    mov $8, %esi
    call wb_word
    mov %r14, %rdi
    mov $4, %esi
    call wb_word

90: /* ---- chunk metadata */
    lea mbuf(%rip), %rbx
    PUTS %rbx, "{\"offset\":"
    mov %rbx, %rdi
    mov WC_OFF(%rsp), %rsi
    call buf_put_u64
    PUTS %rbx, ",\"length\":"
    mov wbuf+BUF_LEN(%rip), %r12
    sub WC_OFF(%rsp), %r12
    mov %rbx, %rdi
    mov %r12, %rsi
    call buf_put_u64
    PUTS %rbx, ",\"crc32\":"
    mov wbuf+BUF_DATA(%rip), %rdi
    add WC_OFF(%rsp), %rdi
    mov %r12, %rsi
    call crc32
    mov %eax, %esi
    mov %rbx, %rdi
    call buf_put_u64
    PUTS %rbx, ",\"encoding\":\""
    lea enc_names(%rip), %rax
    mov WC_E(%rsp), %rcx
    mov (%rax, %rcx, 8), %rsi
    mov %rbx, %rdi
    call buf_puts
    PUTS %rbx, "\",\"null_count\":"
    mov %rbx, %rdi
    mov WC_NULLS(%rsp), %rsi
    call buf_put_u64
    cmpq $0, WC_HAS(%rsp)
    je 91f
    PUTS %rbx, ",\"min\":"
    mov %rbx, %rdi
    mov WC_TYPE(%rsp), %rsi
    mov WC_MIN(%rsp), %rdx
    call fmt_value_json
    PUTS %rbx, ",\"max\":"
    mov %rbx, %rdi
    mov WC_TYPE(%rsp), %rsi
    mov WC_MAX(%rsp), %rdx
    call fmt_value_json
91: mov %rbx, %rdi
    mov $'}', %esi
    call buf_putc
    LEAVE

/* build_dict: local helper on write_chunk's frame (called, so the frame is
 * at 8(%rsp)): distinct values in first-seen order and the u32 codes */
build_dict:
    sub $8, %rsp                    /* frame now at 16(%rsp) */
#define WF 16
    movq $T_STR, WC_TMP+WF(%rsp)
    mov $1, %edi
    lea WC_TMP+WF(%rsp), %rsi
    call ht_new
    mov %rax, WC_HT+WF(%rsp)
    mov g_arena(%rip), %rdi
    call vec_new
    mov %rax, WC_DICT+WF(%rsp)
    mov WC_N+WF(%rsp), %rdi
    lea 4(, %rdi, 4), %rdi
    call tmp_zalloc
    mov %rax, WC_CODES+WF(%rsp)
    xor %r12d, %r12d
1:  cmp WC_N+WF(%rsp), %r12
    jae 9f
    mov WC_COL+WF(%rsp), %rdi
    mov WC_START+WF(%rsp), %rsi
    add %r12, %rsi
    call col_get
    test %edx, %edx
    jnz 8f
    mov %rax, WC_TMP+8+WF(%rsp)     /* probe cell */
    movq $0, WC_TMP+16+WF(%rsp)
    mov WC_HT+WF(%rsp), %rdi
    lea WC_TMP+8+WF(%rsp), %rsi
    xor %edx, %edx
    call ht_lookup
    test %rax, %rax
    jnz 2f
    mov $VAL_SIZE, %edi
    call tmp_zalloc
    mov WC_TMP+8+WF(%rsp), %rcx
    mov %rcx, VAL_P(%rax)
    mov WC_HT+WF(%rsp), %rdi
    mov %rax, %rsi
    mov $1, %edx
    call ht_lookup
    mov %rax, %r14
    mov WC_DICT+WF(%rsp), %rdi
    mov VEC_LEN(%rdi), %rcx
    mov %rcx, EN_D0(%r14)
    mov WC_TMP+8+WF(%rsp), %rsi
    call vec_push
    mov %r14, %rax
2:  mov EN_D0(%rax), %rcx
    mov WC_CODES+WF(%rsp), %rax
    mov %ecx, (%rax, %r12, 4)
8:  inc %r12
    jmp 1b
9:  add $8, %rsp
    ret
#undef WF
ENDF write_chunk

/* write_atomic(path pstr rdi, data rsi, len rdx) */
FUNC write_atomic
    ENTER 64
    mov %rsi, 0(%rsp)
    mov %rdx, 8(%rsp)
    call data_path
    mov %rax, %rbx                  /* target */
    mov %rbx, %rdi
    mov $'/', %esi
    call strrchr
    mov %rax, %r12                  /* last slash */
    cmpb $0, 1(%r12)
    je 90f
    /* directory part */
    mov %r12, %r13
    sub %rbx, %r13                  /* dir length */
    lea 1(%r13), %rdi
    call tmp_alloc
    mov %rax, 16(%rsp)              /* dir */
    mov %rax, %rdi
    mov %rbx, %rsi
    mov %r13, %rdx
    call memcpy
    mov 16(%rsp), %rax
    movb $0, (%rax, %r13)
    /* temporary name */
    mov %rbx, %rdi
    call strlen
    lea 64(%rax), %r14
    mov %r14, %rdi
    call tmp_alloc
    mov %rax, 24(%rsp)              /* tmp path */
    call getpid
    mov %eax, %r15d
    incq save_seq(%rip)
    mov 24(%rsp), %rdi
    mov %r14, %rsi
    CSTR %rdx, "%s/.%s.tmp-%d-%ld"
    mov 16(%rsp), %rcx
    lea 1(%r12), %r8
    mov %r15d, %r9d
    sub $8, %rsp
    pushq save_seq(%rip)
    xor %eax, %eax
    call snprintf
    add $16, %rsp
    mov 24(%rsp), %rdi
    mov $01|0100|0200|02000000, %esi /* O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC */
    mov $0644, %edx
    xor %eax, %eax
    call open
    test %eax, %eax
    js 90f
    mov %eax, %r13d                 /* fd */
    mov 0(%rsp), %r14               /* data */
    mov 8(%rsp), %r15               /* remaining */
1:  test %r15, %r15
    jz 3f
    mov %r13d, %edi
    mov %r14, %rsi
    mov %r15, %rdx
    call write
    test %rax, %rax
    jg 2f
    call __errno_location
    cmpl $4, (%rax)                 /* EINTR */
    je 1b
    jmp 80f
2:  add %rax, %r14
    sub %rax, %r15
    jmp 1b
3:  mov %r13d, %edi
    call fsync
    test %eax, %eax
    jnz 80f
    mov %r13d, %edi
    call close
    test %eax, %eax
    jnz 81f
    mov 24(%rsp), %rdi
    mov %rbx, %rsi
    call rename
    test %eax, %eax
    jnz 81f
    /* make the rename durable */
    mov 16(%rsp), %rdi
    mov $0200000|02000000, %esi     /* O_RDONLY|O_DIRECTORY|O_CLOEXEC */
    xor %eax, %eax
    call open
    test %eax, %eax
    js 9f
    mov %eax, %r13d
    mov %r13d, %edi
    call fsync
    mov %r13d, %edi
    call close
9:  LEAVE
80: mov %r13d, %edi
    call close
81: mov 24(%rsp), %rdi
    call unlink
90: RAISE E_IO_ERROR, "cannot write the file (missing directory or I/O error)"
ENDF write_atomic

/* pqcf_save(table, path, encoding, row group size) -> rax bytes */
FUNC pqcf_save
    ENTER 48
    mov %rdi, %rbx
    mov %rsi, 0(%rsp)
    mov %rdx, 8(%rsp)
    mov %rcx, %r12
    test %r12, %r12
    jnz 1f
    mov $DEFAULT_RG, %r12d
1:  movq $0, wbuf+BUF_LEN(%rip)
    movq $0, mbuf+BUF_LEN(%rip)
    mov $0x0000000146435150, %rdi   /* "PQCF", version 1, flags 0 */
    mov $8, %esi
    call wb_word
    lea mbuf(%rip), %r15
    PUTS %r15, "{\"format_version\":1,\"writer\":\"polyquery-x86_64-asm 0.1.0\",\"table\":"
    mov %r15, %rdi
    mov TB_NAME(%rbx), %rsi
    call buf_put_json_pstr
    PUTS %r15, ",\"row_count\":"
    mov %r15, %rdi
    mov TB_NROWS(%rbx), %rsi
    call buf_put_u64
    PUTS %r15, ",\"columns\":["
    xor %r13d, %r13d
2:  cmp TB_NCOLS(%rbx), %r13
    jae 4f
    test %r13, %r13
    jz 3f
    mov %r15, %rdi
    mov $',', %esi
    call buf_putc
3:  mov %r13, %r14
    shl $COL_SHIFT, %r14
    add TB_COLS(%rbx), %r14
    PUTS %r15, "{\"name\":"
    mov %r15, %rdi
    mov COL_NAME(%r14), %rsi
    call buf_put_json_pstr
    PUTS %r15, ",\"type\":\""
    mov %r15, %rdi
    mov COL_TYPE(%r14), %rsi
    call fmt_type
    PUTS %r15, "\"}"
    inc %r13
    jmp 2b
4:  PUTS %r15, "],\"indexes\":"
    mov %r15, %rdi
    mov %rbx, %rsi
    call idx_put_list
    PUTS %r15, ",\"row_groups\":["
    xor %r13d, %r13d                /* first row of the group */
5:  cmp TB_NROWS(%rbx), %r13
    jae 9f
    mov TB_NROWS(%rbx), %r14
    sub %r13, %r14
    cmp %r12, %r14
    cmova %r12, %r14                /* rows in this group */
    test %r13, %r13
    jz 6f
    mov %r15, %rdi
    mov $',', %esi
    call buf_putc
6:  PUTS %r15, "{\"row_count\":"
    mov %r15, %rdi
    mov %r14, %rsi
    call buf_put_u64
    PUTS %r15, ",\"chunks\":["
    movq $0, 16(%rsp)               /* column */
7:  mov 16(%rsp), %rax
    cmp TB_NCOLS(%rbx), %rax
    jae 8f
    test %rax, %rax
    jz 71f
    mov %r15, %rdi
    mov $',', %esi
    call buf_putc
71: mov 16(%rsp), %rdi
    shl $COL_SHIFT, %rdi
    add TB_COLS(%rbx), %rdi
    mov %r13, %rsi
    mov %r14, %rdx
    mov 8(%rsp), %rcx
    call write_chunk
    incq 16(%rsp)
    jmp 7b
8:  PUTS %r15, "]}"
    add %r14, %r13
    jmp 5b
9:  PUTS %r15, "]}"
    call wb_pad8
    mov mbuf+BUF_DATA(%rip), %rdi
    mov mbuf+BUF_LEN(%rip), %rsi
    call wb_put
    mov mbuf+BUF_LEN(%rip), %rdi
    mov $4, %esi
    call wb_word
    mov mbuf+BUF_DATA(%rip), %rdi
    mov mbuf+BUF_LEN(%rip), %rsi
    call crc32
    mov %eax, %edi
    mov $4, %esi
    call wb_word
    mov $0x46435150, %edi           /* trailing "PQCF" */
    mov $4, %esi
    call wb_word
    mov 0(%rsp), %rdi
    mov wbuf+BUF_DATA(%rip), %rsi
    mov wbuf+BUF_LEN(%rip), %rdx
    call write_atomic
    mov wbuf+BUF_LEN(%rip), %rax
    LEAVE
ENDF pqcf_save

/* ================================================================ reader */

corrupt_frame:
    RAISE E_STORAGE_CORRUPT, "PQCF: invalid header, footer or metadata checksum"
corrupt_meta:
    RAISE E_STORAGE_CORRUPT, "PQCF: invalid metadata"
corrupt_chunk:
    RAISE E_STORAGE_CORRUPT, "PQCF: invalid column chunk"
corrupt_crc:
    RAISE E_STORAGE_CORRUPT, "PQCF: column chunk checksum mismatch"
corrupt_value:
    RAISE E_STORAGE_CORRUPT, "PQCF: invalid value in column chunk"

/* m_get(obj rdi, key rsi) -> rax member node or 0 (null counts as absent) */
FUNC m_get
    sub $8, %rsp
    call json_obj_get
    test %rax, %rax
    jz 9f
    cmpq $J_NULL, JN_TYPE(%rax)
    jne 9f
    xor %eax, %eax
9:  add $8, %rsp
    ret
ENDF m_get

/* m_int(obj, key) -> rax non-negative integer member (STORAGE_CORRUPT otherwise) */
FUNC m_int
    sub $8, %rsp
    call json_obj_get
    mov %rax, %rdi
    call json_is_int
    test %eax, %eax
    jz corrupt_meta
    test %rdx, %rdx
    js corrupt_meta
    mov %rdx, %rax
    add $8, %rsp
    ret
ENDF m_int

/* m_str(obj, key) -> rax pstr of a string member (STORAGE_CORRUPT otherwise) */
FUNC m_str
    sub $8, %rsp
    call json_obj_get
    test %rax, %rax
    jz corrupt_meta
    cmpq $J_STRING, JN_TYPE(%rax)
    jne corrupt_meta
    mov JN_PTR(%rax), %rax
    sub $8, %rax
    add $8, %rsp
    ret
ENDF m_str

/* m_arr(obj, key) -> rax array node (STORAGE_CORRUPT otherwise) */
FUNC m_arr
    sub $8, %rsp
    call json_obj_get
    test %rax, %rax
    jz corrupt_meta
    cmpq $J_ARRAY, JN_TYPE(%rax)
    jne corrupt_meta
    add $8, %rsp
    ret
ENDF m_arr

/* dc_need(dc rdi, k rsi) -> rax pointer to the next k bytes (advances) */
FUNC dc_need
    mov DC_L(%rdi), %rax
    sub DC_POS(%rdi), %rax
    cmp %rsi, %rax
    jb corrupt_chunk
    mov DC_POS(%rdi), %rax
    add %rsi, DC_POS(%rdi)
    add DC_P(%rdi), %rax
    ret
ENDF dc_need

/* dc_isnull(dc rdi, i rsi) -> eax 1 if row i of the group is NULL */
FUNC dc_isnull
    mov DC_BM(%rdi), %rdx
    xor %eax, %eax
    test %rdx, %rdx
    jz 9f
    mov %rsi, %rcx
    shr $3, %rcx
    movzbl (%rdx, %rcx), %edx
    mov %esi, %ecx
    and $7, %ecx
    bt %ecx, %edx
    setnc %al
9:  ret
ENDF dc_isnull

/* dc_store(dc rdi, i rsi, value rdx): validates and stores one non-NULL
 * fixed-width value of row i */
FUNC dc_store
    mov DC_TYPE(%rdi), %rcx
    movzbl %cl, %eax
    cmp $T_DEC, %eax
    je 3f
    cmp $T_DATE, %eax
    je 4f
    cmp $T_TS, %eax
    je 5f
    cmp $T_FLOAT, %eax
    je 6f
    cmp $T_BOOL, %eax
    jne 8f
    cmp $1, %rdx
    ja corrupt_value
    jmp 8f
3:  push %rdi
    push %rsi
    push %rdx
    mov %rdx, %rdi
    mov %rcx, %rsi
    shr $8, %esi
    and $0xff, %esi
    call dec_fits
    pop %rdx
    pop %rsi
    pop %rdi
    test %eax, %eax
    jz corrupt_value
    jmp 8f
4:  cmp $MIN_DAYS, %rdx
    jl corrupt_value
    cmp $MAX_DAYS, %rdx
    jg corrupt_value
    jmp 8f
5:  cmp min_ts(%rip), %rdx
    jl corrupt_value
    cmp max_ts(%rip), %rdx
    jg corrupt_value
    jmp 8f
6:  mov %rdx, %rax
    shr $52, %rax
    and $0x7ff, %eax
    cmp $0x7ff, %eax
    je corrupt_value
8:  mov DC_COL(%rdi), %rax
    add DC_ROW0(%rdi), %rsi
    mov COL_DATA(%rax), %rax
    mov %rdx, (%rax, %rsi, 8)
    ret
ENDF dc_store

/* dc_strings(dc rdi, n rsi) -> rax pstr*[n]: a STRING offsets + bytes block
 * (PLAIN values or a DICT dictionary), validated, copied to the table arena;
 * `nullable` rows (dc rows when rdx = 1) that are NULL get 0 */
FUNC dc_strings
    ENTER 32
    mov %rdi, %rbx
    mov %rsi, %r12                  /* n */
    mov %rdx, 0(%rsp)               /* 1 = PLAIN rows (NULLs skipped) */
    lea 1(%r12), %rsi
    shl $2, %rsi
    call dc_need
    mov %rax, %r13                  /* offsets */
    cmpl $0, (%r13)
    jne corrupt_chunk
    xor %ecx, %ecx                  /* monotonic */
1:  cmp %r12, %rcx
    jae 2f
    mov (%r13, %rcx, 4), %eax
    cmp 4(%r13, %rcx, 4), %eax
    ja corrupt_chunk
    inc %rcx
    jmp 1b
2:  mov (%r13, %r12, 4), %esi
    mov %rbx, %rdi
    call dc_need
    mov %rax, 8(%rsp)               /* bytes */
    lea 8(, %r12, 8), %rdi
    call tmp_zalloc
    mov %rax, 16(%rsp)              /* pstr*[] */
    xor %r14d, %r14d
3:  cmp %r12, %r14
    jae 9f
    cmpq $0, 0(%rsp)
    je 4f
    mov %rbx, %rdi
    mov %r14, %rsi
    call dc_isnull
    test %eax, %eax
    jnz 5f
4:  mov (%r13, %r14, 4), %eax
    mov 4(%r13, %r14, 4), %r15d
    sub %eax, %r15d                 /* length */
    mov 8(%rsp), %rdi
    add %rax, %rdi
    mov %rdi, 24(%rsp)
    mov %r15, %rsi
    call utf8_valid
    test %eax, %eax
    jz corrupt_value
    mov g_pending_arena(%rip), %rdi
    mov 24(%rsp), %rsi
    mov %r15, %rdx
    call pstr_new
    mov 16(%rsp), %rcx
    mov %rax, (%rcx, %r14, 8)
5:  inc %r14
    jmp 3b
9:  mov 16(%rsp), %rax
    LEAVE
ENDF dc_strings

/* decode_chunk(dc rdi) */
FUNC decode_chunk
    ENTER 32
    mov %rdi, %rbx
    movq $0, DC_POS(%rbx)
    movq $0, DC_BM(%rbx)
    mov DC_N(%rbx), %r12            /* n */
    movzbl DC_TYPE(%rbx), %r13d     /* kind */
    /* ---- validity bitmap */
    cmpq $0, DC_NC(%rbx)
    je 3f
    lea 7(%r12), %rsi
    shr $3, %rsi
    mov %rbx, %rdi
    call dc_need
    mov %rax, DC_BM(%rbx)
    xor %r14d, %r14d                /* NULLs counted */
    xor %r15d, %r15d
1:  cmp %r12, %r15
    jae 2f
    mov %rbx, %rdi
    mov %r15, %rsi
    call dc_isnull
    test %eax, %eax
    jz 11f
    inc %r14
    mov DC_COL(%rbx), %rcx
    mov COL_NULLS(%rcx), %rcx
    mov DC_ROW0(%rbx), %rdx
    add %r15, %rdx
    movb $1, (%rcx, %rdx)
    mov DC_COL(%rbx), %rcx
    mov COL_DATA(%rcx), %rcx
    movq $0, (%rcx, %rdx, 8)
11: inc %r15
    jmp 1b
2:  cmp DC_NC(%rbx), %r14
    jne corrupt_chunk
3:  mov DC_ENC(%rbx), %rax
    cmp $EN_DICT, %rax
    je 40f
    cmp $EN_RLE, %rax
    je 50f
    /* ---- PLAIN */
    cmp $T_STR, %r13d
    je 30f
    cmp $T_BOOL, %r13d
    je 20f
    mov $8, %esi
    cmp $T_DATE, %r13d
    jne 4f
    mov $4, %esi
4:  mov %rsi, 0(%rsp)               /* width */
    imul %r12, %rsi
    mov %rbx, %rdi
    call dc_need
    mov %rax, 8(%rsp)
    xor %r15d, %r15d
5:  cmp %r12, %r15
    jae 90f
    mov %rbx, %rdi
    mov %r15, %rsi
    call dc_isnull
    test %eax, %eax
    jnz 7f
    mov 8(%rsp), %rax
    cmpq $4, 0(%rsp)
    jne 6f
    movslq (%rax, %r15, 4), %rdx
    jmp 61f
6:  mov (%rax, %r15, 8), %rdx
61: mov %rbx, %rdi
    mov %r15, %rsi
    call dc_store
7:  inc %r15
    jmp 5b
20: lea 7(%r12), %rsi               /* BOOLEAN bitmap */
    shr $3, %rsi
    mov %rbx, %rdi
    call dc_need
    mov %rax, 8(%rsp)
    xor %r15d, %r15d
21: cmp %r12, %r15
    jae 90f
    mov %rbx, %rdi
    mov %r15, %rsi
    call dc_isnull
    test %eax, %eax
    jnz 22f
    mov %r15, %rcx
    shr $3, %rcx
    mov 8(%rsp), %rax
    movzbl (%rax, %rcx), %eax
    mov %r15d, %ecx
    and $7, %ecx
    xor %edx, %edx
    bt %ecx, %eax
    setc %dl
    mov %rbx, %rdi
    mov %r15, %rsi
    call dc_store
22: inc %r15
    jmp 21b
30: /* STRING */
    mov %rbx, %rdi
    mov %r12, %rsi
    mov $1, %edx
    call dc_strings
    mov %rax, 8(%rsp)
    xor %r15d, %r15d
31: cmp %r12, %r15
    jae 90f
    mov 8(%rsp), %rax
    mov (%rax, %r15, 8), %rdx
    mov DC_COL(%rbx), %rax
    mov COL_DATA(%rax), %rax
    mov DC_ROW0(%rbx), %rcx
    add %r15, %rcx
    mov %rdx, (%rax, %rcx, 8)
    inc %r15
    jmp 31b

40: /* ---- DICT (STRING only) */
    cmp $T_STR, %r13d
    jne corrupt_chunk
    mov %rbx, %rdi
    mov $4, %esi
    call dc_need
    mov (%rax), %eax
    mov %rax, 16(%rsp)              /* D */
    mov %rbx, %rdi
    mov %rax, %rsi
    xor %edx, %edx
    call dc_strings
    mov %rax, 8(%rsp)               /* dictionary */
    mov %r12, %rsi
    shl $2, %rsi
    mov %rbx, %rdi
    call dc_need
    mov %rax, 24(%rsp)              /* codes */
    xor %r15d, %r15d
41: cmp %r12, %r15
    jae 90f
    mov %rbx, %rdi
    mov %r15, %rsi
    call dc_isnull
    test %eax, %eax
    jnz 42f
    mov 24(%rsp), %rax
    mov (%rax, %r15, 4), %eax
    cmp 16(%rsp), %rax
    jae corrupt_value
    mov 8(%rsp), %rcx
    mov (%rcx, %rax, 8), %rdx
    mov DC_COL(%rbx), %rax
    mov COL_DATA(%rax), %rax
    mov DC_ROW0(%rbx), %rcx
    add %r15, %rcx
    mov %rdx, (%rax, %rcx, 8)
42: inc %r15
    jmp 41b

50: /* ---- RLE (BOOLEAN, INT64, DECIMAL, DATE, TIMESTAMP) */
    cmp $T_STR, %r13d
    je corrupt_chunk
    cmp $T_FLOAT, %r13d
    je corrupt_chunk
    mov %rbx, %rdi
    mov $4, %esi
    call dc_need
    mov (%rax), %eax
    mov %rax, 16(%rsp)              /* R */
    imul $12, %rax, %rsi
    mov %rbx, %rdi
    call dc_need
    mov %rax, 8(%rsp)               /* runs */
    xor %r15d, %r15d                /* row */
    xor %r14d, %r14d                /* run */
51: cmp 16(%rsp), %r14
    jae 55f
    imul $12, %r14, %rax
    add 8(%rsp), %rax
    mov 8(%rax), %ecx               /* run length */
    test %ecx, %ecx
    jz corrupt_chunk
    mov %r12, %rdx
    sub %r15, %rdx
    cmp %rdx, %rcx
    ja corrupt_chunk                /* runs exceed n */
    mov (%rax), %rax
    mov %rax, 24(%rsp)              /* value */
    mov %rcx, 0(%rsp)
52: cmpq $0, 0(%rsp)
    je 54f
    mov %rbx, %rdi
    mov %r15, %rsi
    call dc_isnull
    test %eax, %eax
    jnz 53f
    mov %rbx, %rdi
    mov %r15, %rsi
    mov 24(%rsp), %rdx
    call dc_store
53: inc %r15
    decq 0(%rsp)
    jmp 52b
54: inc %r14
    jmp 51b
55: cmp %r12, %r15
    jne corrupt_chunk

90: mov DC_POS(%rbx), %rax           /* decoded size must equal length */
    cmp DC_L(%rbx), %rax
    jne corrupt_chunk
    LEAVE
ENDF decode_chunk

/* parse_bound(node rdi, type rsi, out rdx) -> eax 1 if the node is a valid
 * min/max statistic of the column type (value stored at out) */
FUNC parse_bound
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    test %rbx, %rbx
    jz 8f
    mov JN_TYPE(%rbx), %rax
    movzbl %r12b, %ecx
    cmp $T_BOOL, %ecx
    jne 1f
    xor %edx, %edx
    cmp $J_TRUE, %rax
    sete %dl
    je 7f
    cmp $J_FALSE, %rax
    je 7f
    jmp 8f
1:  cmp $T_INT, %ecx
    jne 2f
    mov %rbx, %rdi
    call json_is_int
    test %eax, %eax
    jz 8f
    jmp 7f
2:  cmp $T_FLOAT, %ecx
    jne 3f
    cmp $J_NUMBER, %rax
    jne 8f
    mov JN_PTR(%rbx), %rdi
    mov JN_LEN(%rbx), %rsi
    call text_parse_float
    test %eax, %eax
    jnz 8f
    movq %xmm0, %rdx
    jmp 7f
3:  cmp $J_STRING, %rax
    jne 8f
    mov JN_PTR(%rbx), %rdi
    mov JN_LEN(%rbx), %rsi
    cmp $T_DEC, %ecx
    jne 4f
    mov %r12, %rdx
    shr $8, %edx
    and $0xff, %edx
    mov %r12, %rcx
    shr $16, %ecx
    and $0xff, %ecx
    xor %r8d, %r8d                  /* exact */
    call text_parse_decimal
    test %edx, %edx
    jnz 8f
    mov %rax, %rdx
    jmp 7f
4:  cmp $T_DATE, %ecx
    jne 5f
    call text_parse_date
    test %edx, %edx
    jnz 8f
    mov %rax, %rdx
    jmp 7f
5:  cmp $T_TS, %ecx
    jne 6f
    mov $1, %edx
    call text_parse_timestamp
    test %edx, %edx
    jnz 8f
    mov %rax, %rdx
    jmp 7f
6:  mov %rsi, %rdx                  /* STRING: copy to the table arena */
    mov %rdi, %rsi
    mov g_pending_arena(%rip), %rdi
    call pstr_new
    mov %rax, %rdx
7:  mov %rdx, (%r13)
    mov $1, %eax
    LEAVE
8:  xor %eax, %eax
    LEAVE
ENDF parse_bound

/* pqcf_read(path, name, mmap, index specs) -> rax staging Table* */
#define RD_DC     0     /* DC context 0..79 */
#define RD_BASE   80
#define RD_SIZE   88
#define RD_META   96    /* metadata JSON root */
#define RD_NAME   104
#define RD_MMAP   112
#define RD_IX     120
#define RD_COLS   128   /* columns array node */
#define RD_RGS    136   /* row_groups array node */
#define RD_TABLE  144
#define RD_NROWS  152
#define RD_MLEN   160
#define RD_TMP    168   /* 168..183 */
#define RD_STAT   192   /* struct stat 192..335 */
#define RD_FRAME  336
FUNC pqcf_read
    ENTER RD_FRAME
    mov %rsi, RD_NAME(%rsp)
    mov %rdx, RD_MMAP(%rsp)
    mov %rcx, RD_IX(%rsp)
    call data_path
    mov %rax, %rbx
    mov %rbx, %rdi
    mov $02000000, %esi             /* O_RDONLY|O_CLOEXEC */
    xor %eax, %eax
    call open
    test %eax, %eax
    jns 2f
    call __errno_location
    mov (%rax), %eax
    cmp $2, %eax                    /* ENOENT */
    je 1f
    cmp $20, %eax                   /* ENOTDIR */
    je 1f
    cmp $13, %eax                   /* EACCES */
    jne 11f
    RAISE E_ACCESS_DENIED, "permission denied"
11: RAISE E_IO_ERROR, "cannot open file"
1:  RAISE E_NOT_FOUND, "file not found"
2:  mov %eax, %r12d                 /* fd */
    mov %r12d, %edi
    lea RD_STAT(%rsp), %rsi
    call fstat
    test %eax, %eax
    jnz 8f
    mov RD_STAT+24(%rsp), %eax      /* st_mode */
    and $0170000, %eax
    cmp $0100000, %eax              /* regular file */
    jne 8f
    mov RD_STAT+48(%rsp), %r13      /* st_size */
    mov %r13, RD_SIZE(%rsp)
    test %r13, %r13
    jz 7f
    cmpq $0, RD_MMAP(%rsp)
    je 4f
    xor %edi, %edi                  /* mmap(0, size, PROT_READ, MAP_PRIVATE, fd, 0) */
    mov %r13, %rsi
    mov $1, %edx
    mov $2, %ecx
    mov %r12d, %r8d
    xor %r9d, %r9d
    call mmap
    cmp $-1, %rax
    je 4f                           /* fall back to reading */
    mov %rax, RD_BASE(%rsp)
    mov %rax, g_pending_map(%rip)
    mov %r13, g_pending_map_len(%rip)
    jmp 6f
4:  lea 8(%r13), %rdi
    call tmp_alloc
    mov %rax, RD_BASE(%rsp)
    xor %r14d, %r14d
5:  cmp %r13, %r14
    jae 6f
    mov %r12d, %edi
    mov RD_BASE(%rsp), %rsi
    add %r14, %rsi
    mov %r13, %rdx
    sub %r14, %rdx
    call read
    test %rax, %rax
    jg 51f
    jz 8f
    call __errno_location
    cmpl $4, (%rax)
    je 5b
    jmp 8f
51: add %rax, %r14
    jmp 5b
6:  mov %r12d, %edi
    call close
    jmp 10f
7:  mov %r12d, %edi
    call close
    jmp corrupt_frame
8:  mov %r12d, %edi
    call close
    RAISE E_IO_ERROR, "cannot read file"

10: /* ---- header and footer */
    mov RD_BASE(%rsp), %rbx
    mov RD_SIZE(%rsp), %r13
    cmp $8, %r13
    jb corrupt_frame
    cmpl $0x46435150, (%rbx)        /* "PQCF" */
    jne corrupt_frame
    movzwl 4(%rbx), %eax            /* format_version */
    test %eax, %eax
    jz corrupt_frame
    cmp $1, %eax
    jne 12f
    cmpw $0, 6(%rbx)                /* flags */
    jne 12f
    cmp $20, %r13
    jb corrupt_frame
    cmpl $0x46435150, -4(%rbx, %r13)
    jne corrupt_frame
    mov -12(%rbx, %r13), %eax       /* M */
    mov %rax, RD_MLEN(%rsp)
    lea -20(%r13), %rcx
    cmp %rcx, %rax
    ja corrupt_frame
    mov %r13, %rdi
    sub $12, %rdi
    sub %rax, %rdi
    add %rbx, %rdi                  /* metadata */
    mov %rdi, RD_TMP(%rsp)
    mov %rax, %rsi
    call crc32
    cmp -8(%rbx, %r13), %eax
    jne corrupt_frame
    mov RD_TMP(%rsp), %rdi
    mov RD_MLEN(%rsp), %rsi
    mov g_arena(%rip), %rdx
    call json_parse
    test %rax, %rax
    jz corrupt_meta
    cmpq $J_OBJECT, JN_TYPE(%rax)
    jne corrupt_meta
    mov %rax, RD_META(%rsp)
    jmp 13f
12: RAISE E_STORAGE_VERSION, "unsupported PQCF format version or flags"

13: /* ---- metadata */
    mov RD_META(%rsp), %rdi
    CSTR %rsi, "format_version"
    call m_int
    cmp $1, %rax
    jne corrupt_meta
    mov RD_META(%rsp), %rdi
    CSTR %rsi, "table"
    call m_str
    mov RD_META(%rsp), %rdi
    CSTR %rsi, "row_count"
    call m_int
    mov %rax, RD_NROWS(%rsp)
    mov RD_META(%rsp), %rdi
    CSTR %rsi, "columns"
    call m_arr
    mov %rax, RD_COLS(%rsp)
    mov RD_META(%rsp), %rdi
    CSTR %rsi, "row_groups"
    call m_arr
    mov %rax, RD_RGS(%rsp)
    /* row_count must be the sum of the row groups' row counts */
    xor %r12d, %r12d                /* group */
    xor %r14d, %r14d                /* sum */
14: mov RD_RGS(%rsp), %rax
    cmp JN_LEN(%rax), %r12
    jae 15f
    mov JN_PTR(%rax), %rax
    mov (%rax, %r12, 8), %rdi
    cmpq $J_OBJECT, JN_TYPE(%rdi)
    jne corrupt_meta
    CSTR %rsi, "row_count"
    call m_int
    add %rax, %r14
    jc corrupt_meta
    inc %r12
    jmp 14b
15: cmp RD_NROWS(%rsp), %r14
    jne corrupt_meta
    cmp g_max_table_rows(%rip), %r14
    ja 98f
    /* table and columns */
    mov g_pending_arena(%rip), %rdi
    mov RD_NAME(%rsp), %rsi
    mov RD_COLS(%rsp), %rax
    mov JN_LEN(%rax), %rdx
    mov RD_NROWS(%rsp), %rcx
    call table_new
    mov %rax, RD_TABLE(%rsp)
    xor %r12d, %r12d
20: mov RD_COLS(%rsp), %rax
    cmp JN_LEN(%rax), %r12
    jae 25f
    mov JN_PTR(%rax), %rax
    mov (%rax, %r12, 8), %r13       /* column object */
    cmpq $J_OBJECT, JN_TYPE(%r13)
    jne corrupt_meta
    mov %r13, %rdi
    CSTR %rsi, "name"
    call m_str
    mov %rax, %r14                  /* name */
    cmpq $0, (%r14)
    je corrupt_meta
    xor %r15d, %r15d                /* unique (case-insensitive) */
21: cmp %r12, %r15
    jae 22f
    mov %r15, %rax
    shl $COL_SHIFT, %rax
    mov RD_TABLE(%rsp), %rcx
    add TB_COLS(%rcx), %rax
    mov COL_NAME(%rax), %rdi
    mov %r14, %rsi
    call pstr_ieq
    test %eax, %eax
    jnz corrupt_meta
    inc %r15
    jmp 21b
22: mov %r13, %rdi
    CSTR %rsi, "type"
    call m_str
    lea 8(%rax), %rdi
    mov (%rax), %rsi
    call type_parse
    test %edx, %edx
    jnz corrupt_meta
    mov %rax, %rcx
    mov %r12, %rsi
    shl $COL_SHIFT, %rsi
    mov RD_TABLE(%rsp), %rax
    add TB_COLS(%rax), %rsi
    mov g_pending_arena(%rip), %rdi
    mov %r14, %rdx
    mov RD_NROWS(%rsp), %r8
    call col_stage
    inc %r12
    jmp 20b

25: /* ---- indexes */
    mov RD_META(%rsp), %rdi
    CSTR %rsi, "indexes"
    call m_get
    test %rax, %rax
    jz 30f
    cmpq $J_ARRAY, JN_TYPE(%rax)
    jne corrupt_meta
    mov %rax, RD_TMP(%rsp)
    xor %r12d, %r12d
26: mov RD_TMP(%rsp), %rax
    cmp JN_LEN(%rax), %r12
    jae 30f
    mov JN_PTR(%rax), %rax
    mov (%rax, %r12, 8), %r13
    cmpq $J_OBJECT, JN_TYPE(%r13)
    jne corrupt_meta
    mov %r13, %rdi
    CSTR %rsi, "name"
    call m_str
    cmpq $0, (%rax)
    je corrupt_meta
    mov RD_IX(%rsp), %rdi
    mov %rax, %rsi
    call vec_push
    mov %r13, %rdi
    CSTR %rsi, "column"
    call m_str
    mov %rax, %r14
    xor %r15d, %r15d
27: mov RD_TABLE(%rsp), %rax
    cmp TB_NCOLS(%rax), %r15
    jae corrupt_meta                /* unknown column */
    mov %r15, %rcx
    shl $COL_SHIFT, %rcx
    add TB_COLS(%rax), %rcx
    mov COL_NAME(%rcx), %rdi
    mov %r14, %rsi
    call pstr_ieq
    test %eax, %eax
    jnz 28f
    inc %r15
    jmp 27b
28: mov RD_IX(%rsp), %rdi
    mov %r15, %rsi
    call vec_push
    mov %r13, %rdi
    CSTR %rsi, "kind"
    call m_str
    mov %rax, %r14
    lea 8(%r14), %rdi
    mov (%r14), %rsi
    CSTR %rdx, "HASH"
    call cstr_ieq
    mov $IXK_HASH, %esi
    test %eax, %eax
    jnz 29f
    lea 8(%r14), %rdi
    mov (%r14), %rsi
    CSTR %rdx, "BTREE"
    call cstr_ieq
    test %eax, %eax
    jz corrupt_meta
    mov $IXK_BTREE, %esi
29: mov RD_IX(%rsp), %rdi
    call vec_push
    inc %r12
    jmp 26b

30: /* ---- row groups */
    mov RD_TABLE(%rsp), %r15
    mov RD_RGS(%rsp), %rax
    mov JN_LEN(%rax), %rax
    mov %rax, TB_NRG(%r15)
    imul $RG_SIZE, %rax, %rsi
    add $8, %rsi
    mov g_pending_arena(%rip), %rdi
    call arena_zalloc
    mov %rax, TB_RGS(%r15)
    xor %r12d, %r12d                /* row group */
    xor %r14d, %r14d                /* rows so far */
31: mov RD_RGS(%rsp), %rax
    cmp JN_LEN(%rax), %r12
    jae 50f
    mov JN_PTR(%rax), %rax
    mov (%rax, %r12, 8), %r13       /* row group object */
    cmpq $J_OBJECT, JN_TYPE(%r13)
    jne corrupt_meta
    mov %r13, %rdi
    CSTR %rsi, "row_count"
    call m_int
    mov RD_NROWS(%rsp), %rcx
    sub %r14, %rcx
    cmp %rcx, %rax
    ja corrupt_meta                 /* more rows than row_count */
    imul $RG_SIZE, %r12, %rbx
    add TB_RGS(%r15), %rbx          /* RowGroup* */
    mov %r14, RG_START(%rbx)
    mov %rax, RG_N(%rbx)
    mov TB_NCOLS(%r15), %rsi
    imul $RGC_SIZE, %rsi
    add $8, %rsi
    mov g_pending_arena(%rip), %rdi
    call arena_zalloc
    mov %rax, RG_COLS(%rbx)
    mov %r13, %rdi
    CSTR %rsi, "chunks"
    call m_arr
    mov JN_LEN(%rax), %rcx
    cmp TB_NCOLS(%r15), %rcx
    jne corrupt_meta
    mov %rax, RD_TMP(%rsp)          /* chunks array */
    movq $0, RD_TMP+8(%rsp)         /* column */
32: mov RD_TMP+8(%rsp), %rcx
    cmp TB_NCOLS(%r15), %rcx
    jae 39f
    mov RD_TMP(%rsp), %rax
    mov JN_PTR(%rax), %rax
    mov (%rax, %rcx, 8), %r13       /* chunk object */
    cmpq $J_OBJECT, JN_TYPE(%r13)
    jne corrupt_meta
    shl $COL_SHIFT, %rcx
    add TB_COLS(%r15), %rcx
    mov %rcx, RD_DC+DC_COL(%rsp)
    mov COL_TYPE(%rcx), %rax
    mov %rax, RD_DC+DC_TYPE(%rsp)
    mov RG_N(%rbx), %rax
    mov %rax, RD_DC+DC_N(%rsp)
    mov RG_START(%rbx), %rax
    mov %rax, RD_DC+DC_ROW0(%rsp)
    /* encoding (unknown => VERSION_UNSUPPORTED) */
    mov %r13, %rdi
    CSTR %rsi, "encoding"
    call m_str
    lea 8(%rax), %rdi
    mov %rdi, RD_TMP+16(%rsp)
    CSTR %rsi, "PLAIN"
    call strcmp
    mov $EN_PLAIN, %ecx
    test %eax, %eax
    jz 33f
    mov RD_TMP+16(%rsp), %rdi
    CSTR %rsi, "DICT"
    call strcmp
    mov $EN_DICT, %ecx
    test %eax, %eax
    jz 33f
    mov RD_TMP+16(%rsp), %rdi
    CSTR %rsi, "RLE"
    call strcmp
    mov $EN_RLE, %ecx
    test %eax, %eax
    jz 33f
    RAISE E_STORAGE_VERSION, "unknown PQCF chunk encoding"
33: mov %rcx, RD_DC+DC_ENC(%rsp)
    mov %r13, %rdi
    CSTR %rsi, "null_count"
    call m_int
    cmp RG_N(%rbx), %rax
    ja corrupt_meta
    mov %rax, RD_DC+DC_NC(%rsp)
    mov %r13, %rdi
    CSTR %rsi, "offset"
    call m_int
    cmp $8, %rax
    jb corrupt_meta
    mov %rax, RD_DC+DC_P(%rsp)
    mov %r13, %rdi
    CSTR %rsi, "length"
    call m_int
    mov %rax, RD_DC+DC_L(%rsp)
    mov RD_SIZE(%rsp), %rcx         /* offset + length <= S - 12 - M */
    sub $12, %rcx
    sub RD_MLEN(%rsp), %rcx
    sub RD_DC+DC_P(%rsp), %rcx
    jb corrupt_meta
    cmp %rcx, %rax
    ja corrupt_meta
    mov %r13, %rdi
    CSTR %rsi, "crc32"
    call m_int
    mov %rax, RD_TMP+16(%rsp)
    mov RD_DC+DC_P(%rsp), %rdi      /* chunk checksum */
    add RD_BASE(%rsp), %rdi
    mov %rdi, RD_DC+DC_P(%rsp)
    mov RD_DC+DC_L(%rsp), %rsi
    call crc32
    cmp RD_TMP+16(%rsp), %rax
    jne corrupt_crc
    lea RD_DC(%rsp), %rdi
    call decode_chunk
    /* chunk statistics for row-group skipping */
    mov RD_TMP+8(%rsp), %rax
    imul $RGC_SIZE, %rax, %rax
    add RG_COLS(%rbx), %rax
    mov %rax, RD_TMP+16(%rsp)       /* RGC* */
    mov RD_DC+DC_NC(%rsp), %rcx
    mov %rcx, RGC_NULLS(%rax)
    mov %r13, %rdi
    CSTR %rsi, "min"
    call m_get
    mov %rax, %rdi
    mov RD_DC+DC_TYPE(%rsp), %rsi
    mov RD_TMP+16(%rsp), %rdx
    add $RGC_MIN, %rdx
    call parse_bound
    test %eax, %eax
    jz 38f
    mov %r13, %rdi
    CSTR %rsi, "max"
    call m_get
    mov %rax, %rdi
    mov RD_DC+DC_TYPE(%rsp), %rsi
    mov RD_TMP+16(%rsp), %rdx
    add $RGC_MAX, %rdx
    call parse_bound
    test %eax, %eax
    jz 38f
    mov RD_TMP+16(%rsp), %rax
    movq $1, RGC_HAS(%rax)
38: incq RD_TMP+8(%rsp)
    jmp 32b
39: add RG_N(%rbx), %r14
    inc %r12
    jmp 31b
50: cmp RD_NROWS(%rsp), %r14
    jne corrupt_meta
    /* ---- done: release the mapping */
    mov g_pending_map(%rip), %rdi
    test %rdi, %rdi
    jz 51f
    mov g_pending_map_len(%rip), %rsi
    call munmap
    movq $0, g_pending_map(%rip)
51: mov RD_TABLE(%rsp), %rax
    LEAVE
98: RAISE E_RESOURCE_LIMIT, "table exceeds the maximum row count"
ENDF pqcf_read
