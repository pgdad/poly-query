// =============================================================================
// pqcf.S — PQCF v1 columnar table files (storage/pqcf-v1.md): writer, reader
// and the CRC-32 / UTF-8 helpers they need.
//
//   crc32(x0 ptr, x1 len) -> w0                      ISO-HDLC / zlib CRC-32
//   crc32_update(w0 crc, x1 ptr, x2 len) -> w0       continue a CRC-32
//   utf8_valid(x0 ptr, x1 len) -> w0 1/0             strict UTF-8 check
//   pqcf_save(x0 Table*, x1 path Str*, x2 row_group_size (0 = default),
//             w3 encoding PENC_*) -> x0 file size in bytes
//   pqcf_load(x0 path Str*, w1 use_mmap) -> x0 Table*, x1 XS* index specs,
//             x2 spec count
//
// Writer. The file is produced in one pass: the header, then for every row
// group and column one chunk (8-byte aligned), then the metadata JSON and
// the footer. Chunk bytes are built directly in a persistent output buffer
// (g_pq_out, flushed to the file every PQ_FLUSH_AT bytes); the metadata JSON
// is accumulated alongside in g_pq_meta. Values are read with tbl_get, so any
// layout / encoding of the in-memory table can be saved. Per chunk the
// encoding is chosen from the request (PENC_*) and the chunk statistics:
// AUTO picks RLE when runs < n/4 (BOOLEAN, INT64, DECIMAL, DATE, TIMESTAMP),
// DICT when distinct < n/2 (STRING; hash table), else PLAIN.
// Saving is atomic (§5): the bytes go to ".<base>.tmp-<pid>-<seq>" in the
// target's directory, which is fsync'ed, renamed over the target, and the
// directory is fsync'ed. Errors raised while the temporary file exists are
// intercepted (the caller's g_jmpbuf is saved and replaced by our own), the
// temporary file is closed and removed, and the error is re-raised.
//
// Reader. The file is read into the request arena (or mmap'ed with
// use_mmap, unmapped before returning — also on errors, via the same
// g_jmpbuf interception). Everything is validated before the table is
// returned: header, footer, metadata CRC, JSON structure and consistency,
// chunk bounds and CRCs, exact chunk sizes, the validity bitmap and every
// non-null value (§3.4). Columns are decoded into plain u64 payload vectors
// (CENC_PLAIN) plus null bitmaps; STRING values become Str* in the table
// arena (DICT entries are shared between rows). TBL_NRG / TBL_RGS describe
// the file's row groups with per-chunk null counts and min/max statistics.
// The new table is registered in g_pending_table as soon as it is allocated.
// Invalid files raise STORAGE_CORRUPT; a newer format version, non-zero
// flags or an unknown encoding name raise STORAGE_VERSION_UNSUPPORTED.
// =============================================================================
#include "pq.inc"
#include "frame.inc"

    .arch_extension crc

#define PQ_DEFAULT_RG   65536
#define PQ_MAX_RG       (1 << 30)
#define PQ_FLUSH_AT     (1 << 20)
#define JMPBUF_BYTES    512             // size of g_jmpbuf (rt.S)
#define PQ_MAGIC        0x46435150      // "PQCF" little-endian

// Linux / AArch64 constants
#define O_RDONLY        0
#define O_WRONLY        1
#define O_CREAT         0x40
#define O_EXCL          0x80
#define O_TRUNC         0x200
#define O_DIRECTORY     0x4000
#define O_CLOEXEC       0x80000
#define ENOENT          2
#define EINTR           4
#define ENOTDIR         20
#define AT_HWCAP        16
#define HWCAP_CRC32     (1 << 7)
#define PROT_READ       1
#define MAP_PRIVATE     2
#define STAT_MODE         16              // struct stat offsets (AArch64)
#define STAT_SIZE         48
#define STAT_BYTES      128

// Valid DATE / TIMESTAMP ranges (0001-01-01 .. 9999-12-31 23:59:59.999999)
#define DATE_MIN        -719162
#define DATE_MAX        2932896
#define TS_MIN          -62135596800000000
#define TS_MAX          253402300799999999

// Writer context (g_pw)
#define PW_TBL     0        // Table*
#define PW_FD      8        // i64 file descriptor of the temp file, -1 = none
#define PW_TMP     16       // cstr temp path (0 once renamed)
#define PW_FULL    24       // cstr target path
#define PW_POS     32       // u64 file offset of the next byte (flushed + buffered)
#define PW_ENC     40       // u32 requested PENC_*
#define PW_HASMM   44       // u32 1 = PW_MIN/PW_MAX valid (current chunk)
#define PW_RGS     48       // u64 rows per row group
#define PW_VALS    56       // u64* payloads of the current group (NULL => 0)
#define PW_ISN     64       // u8* 1 = NULL, per row of the current group
#define PW_CODES   72       // u32* DICT codes
#define PW_DICT    80       // Str** DICT entries
#define PW_HSLOT   88       // u32* hash slots (code + 1, 0 = empty)
#define PW_HMASK   96       // u64 slot count - 1
#define PW_NNULL   104      // u64 null count (current chunk)
#define PW_MIN     112      // payload
#define PW_MAX     120      // payload
#define PW_RUNS    128      // u64 runs of equal payloads (RLE run count)
#define PW_SBYTES  136      // u64 bytes of the non-null strings
#define PW_ND      144      // u64 DICT entries
#define PW_DBYTES  152      // u64 bytes of the DICT entries
#define PW_CRC     160      // u32 CRC of the current chunk
#define PW_JMP     176      // saved caller g_jmpbuf
#define PW_SIZE    (PW_JMP + JMPBUF_BYTES)

// Reader context (g_pr)
#define RD_BASE    0        // u8* file bytes
#define RD_SIZE    8        // u64 file size S
#define RD_MSTART  16       // u64 metadata offset (end of the chunk area)
#define RD_MAPPED  24       // u64 1 = RD_BASE is an mmap
#define RD_TBL     32       // Table* being built
#define RD_NCOLS   40       // u64
#define RD_NROWS   48       // u64
#define RD_VBM     56       // u8* validity bitmap of the current chunk or 0
#define RD_TYPES   64       // u32* column types
#define RD_NAMES   72       // Str** column names
#define RD_CKS     80       // chunk descriptors [ng * ncols]
#define RD_GN      88       // u64* rows per row group
#define RD_NG      96       // u64 row groups
#define RD_XS      104      // XS* index specs
#define RD_NXS     112      // u64
#define RD_JMP     128      // saved caller g_jmpbuf
#define RD_SZ      (RD_JMP + JMPBUF_BYTES)

// Chunk descriptor (validated metadata of one chunk; request arena)
#define PCK_OFF    0        // u64 offset
#define PCK_LEN    8        // u64 length
#define PCK_CRC    16       // u32 crc32
#define PCK_ENC    20       // u32 PENC_PLAIN / PENC_DICT / PENC_RLE
#define PCK_NULLS  24       // u64 null_count
#define PCK_MIN    32       // JNode* or 0
#define PCK_MAX    40       // JNode* or 0
#define PCK_SIZE   48

// ISNULL_AT d, vbm, i, t (register numbers): w<d> = 1 if row x<i> is NULL
// per the validity bitmap x<vbm> (0 = no bitmap, nothing is NULL).
// Clobbers x<t>.
.macro ISNULL_AT d, vbm, i, t
    mov  w\d, #0
    cbz  x\vbm, .Lisn\@
    lsr  x\t, x\i, #3
    ldrb w\d, [x\vbm, x\t]
    and  w\t, w\i, #7
    lsr  w\d, w\d, w\t
    and  w\d, w\d, #1
    eor  w\d, w\d, #1
.Lisn\@:
.endm

    .bss
    .p2align 4
g_pw:           .skip PW_SIZE
g_pr:           .skip RD_SZ
g_pq_out:       .skip BUF_SIZE      // persistent: file bytes not yet written
g_pq_meta:      .skip BUF_SIZE      // persistent: metadata JSON / scratch
g_pq_tmpseq:    .skip 8             // counter for temporary file names
    .global g_crc_mode
g_crc_mode:     .skip 8             // 0 = not probed, 1 = CRC32 insns, 2 = table
g_crc_tab:      .skip 1024          // u32[256] (table mode)

    .section .rodata
s_header:   .byte 'P', 'Q', 'C', 'F', 1, 0, 0, 0
f_tmpname:  .asciz "%.*s/.%s.tmp-%d-%lu"
j_head:     .asciz "{\"format_version\":1,\"writer\":\"polyquery-arm64-asm 0.1.0\",\"table\":"
j_rowcount: .asciz ",\"row_count\":"
j_columns:  .asciz ",\"columns\":["
j_name:     .asciz "{\"name\":"
j_type:     .asciz ",\"type\":\""
j_indexes:  .asciz "],\"indexes\":["
j_column:   .asciz ",\"column\":"
j_kind:     .asciz ",\"kind\":\""
j_rgs:      .asciz "],\"row_groups\":["
j_rg:       .asciz "{\"row_count\":"
j_chunks:   .asciz ",\"chunks\":["
j_offset:   .asciz "{\"offset\":"
j_length:   .asciz ",\"length\":"
j_crc:      .asciz ",\"crc32\":"
j_enc:      .asciz ",\"encoding\":\""
j_nulls:    .asciz "\",\"null_count\":"
j_min:      .asciz ",\"min\":"
j_max:      .asciz ",\"max\":"
j_close:    .asciz "]}"
j_empty:    .asciz "\"\""
e_plain:    .asciz "PLAIN"
e_dict:     .asciz "DICT"
e_rle:      .asciz "RLE"
x_hash:     .asciz "HASH"
x_btree:    .asciz "BTREE"
k_fv:       .asciz "format_version"
k_table:    .asciz "table"
k_rowcount: .asciz "row_count"
k_columns:  .asciz "columns"
k_name:     .asciz "name"
k_type:     .asciz "type"
k_indexes:  .asciz "indexes"
k_column:   .asciz "column"
k_kind:     .asciz "kind"
k_rgs:      .asciz "row_groups"
k_chunks:   .asciz "chunks"
k_offset:   .asciz "offset"
k_length:   .asciz "length"
k_crc32:    .asciz "crc32"
k_encoding: .asciz "encoding"
k_nulls:    .asciz "null_count"
k_min:      .asciz "min"
k_max:      .asciz "max"
m_create:   .asciz "cannot create file in the directory of "
m_nofile:   .asciz "file not found "
m_ioread:   .asciz "cannot read file "
m_encver:   .asciz "unsupported PQCF encoding "
    .text

// =============================================================================
//                                   CRC-32
// =============================================================================

// crc32(x0 ptr, x1 len) -> w0 CRC-32 of the bytes
FUNC crc32
    mov  x2, x1
    mov  x1, x0
    mov  w0, #0
    b    crc32_update
ENDF crc32

// -----------------------------------------------------------------------------
// crc32_update(w0 crc, x1 ptr, x2 len) -> w0
// zlib-style continuation: crc32_update(crc32(a), b) = crc32(a ++ b).
// Uses the ARMv8 CRC32 instructions (same reflected polynomial 0xEDB88320)
// when the CPU has them, else a byte-wise table. Leaf except for the first
// call, which probes the CPU (crc_init).
// -----------------------------------------------------------------------------
FUNC crc32_update
    LDR_G x9, g_crc_mode
    cbz  x9, 8f
    mvn  w0, w0
    cmp  x9, #1
    b.ne 5f
1:  cmp  x2, #8                     // hardware: 8 bytes per step
    b.lo 2f
    ldr  x10, [x1], #8
    crc32x w0, w0, x10
    sub  x2, x2, #8
    b    1b
2:  cbz  x2, 3f
    ldrb w10, [x1], #1
    crc32b w0, w0, w10
    sub  x2, x2, #1
    b    2b
3:  mvn  w0, w0
    ret
5:  ADR_L x9, g_crc_tab             // table: one byte per step
6:  cbz  x2, 3b
    ldrb w10, [x1], #1
    eor  w10, w10, w0
    and  w10, w10, #0xff
    ldr  w10, [x9, w10, uxtw #2]
    eor  w0, w10, w0, lsr #8
    sub  x2, x2, #1
    b    6b
8:  stp  x29, x30, [sp, #-48]!      // first call: probe, then retry
    mov  x29, sp
    stp  x0, x1, [sp, #16]
    str  x2, [sp, #32]
    bl   crc_init
    ldp  x0, x1, [sp, #16]
    ldr  x2, [sp, #32]
    ldp  x29, x30, [sp], #48
    b    crc32_update
ENDF crc32_update

// crc_init(): build the table and choose the implementation (g_crc_mode).
LFUNC crc_init
    ENTER 0
    ADR_L x9, g_crc_tab
    ldr  w11, =0xEDB88320
    mov  w10, #0                    // i
1:  mov  w12, w10
    mov  w13, #8
2:  tst  w12, #1
    lsr  w12, w12, #1
    eor  w14, w12, w11
    csel w12, w14, w12, ne
    subs w13, w13, #1
    b.ne 2b
    str  w12, [x9, w10, uxtw #2]
    add  w10, w10, #1
    cmp  w10, #256
    b.lo 1b
    mov  x0, #AT_HWCAP
    bl   getauxval
    tst  x0, #HWCAP_CRC32
    mov  x9, #1
    mov  x10, #2
    csel x9, x9, x10, ne
    ADR_L x10, g_crc_mode
    str  x9, [x10]
    LEAVE 0
ENDF crc_init

// =============================================================================
// utf8_valid(x0 ptr, x1 len) -> w0 1 if valid UTF-8 else 0          (leaf)
// Strict: no overlong forms, no surrogates (U+D800..DFFF), max U+10FFFF.
// Registers: x0 cursor, x1 end, w10 continuation bytes still expected,
// w11/w12 bounds of the first continuation byte.
// =============================================================================
FUNC utf8_valid
    add  x1, x0, x1
1:  sub  x9, x1, x0                 // fast path: 8 ASCII bytes
    cmp  x9, #8
    b.lo 2f
    ldr  x9, [x0]
    tst  x9, #0x8080808080808080
    b.ne 2f
    add  x0, x0, #8
    b    1b
2:  cmp  x0, x1
    b.hs 8f
    ldrb w9, [x0], #1
    cmp  w9, #0x80
    b.lo 1b
    mov  w11, #0x80
    mov  w12, #0xbf
    cmp  w9, #0xc2
    b.lo 9f                         // continuation byte / overlong 2-byte lead
    cmp  w9, #0xdf
    b.hi 3f
    mov  w10, #1
    b    5f
3:  cmp  w9, #0xef
    b.hi 4f
    mov  w10, #2
    cmp  w9, #0xe0
    b.ne 31f
    mov  w11, #0xa0                 // no overlong 3-byte forms
31: cmp  w9, #0xed
    b.ne 5f
    mov  w12, #0x9f                 // no surrogates
    b    5f
4:  cmp  w9, #0xf4
    b.hi 9f
    mov  w10, #3
    cmp  w9, #0xf0
    b.ne 41f
    mov  w11, #0x90                 // no overlong 4-byte forms
41: cmp  w9, #0xf4
    b.ne 5f
    mov  w12, #0x8f                 // <= U+10FFFF
5:  sub  x9, x1, x0
    cmp  x9, x10
    b.lo 9f
    ldrb w9, [x0], #1
    cmp  w9, w11
    b.lo 9f
    cmp  w9, w12
    b.hi 9f
6:  subs w10, w10, #1
    b.eq 1b
    ldrb w9, [x0], #1
    and  w9, w9, #0xc0
    cmp  w9, #0x80
    b.ne 9f
    b    6b
8:  mov  w0, #1
    ret
9:  mov  w0, #0
    ret
ENDF utf8_valid

// =============================================================================
//                                   WRITER
// =============================================================================

// metadata output helpers (g_pq_meta)
LFUNC mp_puts                       // x0 cstr
    mov  x1, x0
    ADR_L x0, g_pq_meta
    b    buf_puts
ENDF mp_puts

LFUNC mp_c                          // w0 byte
    mov  w1, w0
    ADR_L x0, g_pq_meta
    b    buf_putc
ENDF mp_c

LFUNC mp_u64                        // x0 value
    mov  x1, x0
    ADR_L x0, g_pq_meta
    b    buf_put_u64
ENDF mp_u64

LFUNC mp_jstr                       // x0 Str*: JSON string literal
    ldr  x2, [x0, #STR_LEN]
    add  x1, x0, #STR_DATA
    ADR_L x0, g_pq_meta
    b    buf_put_jstr
ENDF mp_jstr

// pw_io_error(): raise IO_ERROR naming the target path (never returns)
LFUNC pw_io_error
    RAISE ERR_IO, "cannot write PQCF file"
ENDF pw_io_error

// =============================================================================
// pqcf_save(x0 Table*, x1 path Str*, x2 row_group_size (0 = default),
//           w3 encoding PENC_*) -> x0 file size in bytes
// The path has been validated by the caller (protocol.md §6). A missing
// parent directory or any I/O failure raises IO_ERROR; the target is then
// unchanged and no temporary file is left behind.
// Registers: x19 ctx, x20 path Str*, x21 nrows, x22 first row of the group,
//            x23 rows in the group, x24 column, x25 ncols
// =============================================================================
FUNC pqcf_save
    ENTER 4
    ADR_L x19, g_pw
    mov  x20, x1
    str  x0, [x19, #PW_TBL]
    str  w3, [x19, #PW_ENC]
    ldr  x21, [x0, #TBL_NROWS]
    // rows per group: 1 <= min(requested or default, nrows, PQ_MAX_RG)
    cbnz x2, 1f
    mov  x2, #PQ_DEFAULT_RG
1:  mov  x9, #PQ_MAX_RG
    cmp  x2, x9
    csel x2, x2, x9, ls
    cmp  x2, x21
    csel x2, x2, x21, ls
    cmp  x2, #1
    csinc x2, x2, xzr, hs
    str  x2, [x19, #PW_RGS]
    mov  x9, #-1
    str  x9, [x19, #PW_FD]
    str  xzr, [x19, #PW_TMP]
    // target and temporary file names
    mov  x0, x20
    bl   data_path
    str  x0, [x19, #PW_FULL]
    bl   pw_tmp_name
    ldr  x0, [x19, #PW_TMP]
    mov  w1, #(O_WRONLY | O_CREAT | O_EXCL | O_TRUNC)
    orr  w1, w1, #O_CLOEXEC
    mov  w2, #420                   // 0644
    bl   open
    tbz  w0, #31, 2f
    str  xzr, [x19, #PW_TMP]        // nothing was created
    mov  w0, #ERR_IO
    ADR_L x1, m_create
    add  x2, x20, #STR_DATA
    ldr  x3, [x20, #STR_LEN]
    bl   pq_raise_s
2:  sxtw x0, w0
    str  x0, [x19, #PW_FD]
    // from here on errors must remove the temporary file: intercept them
    add  x0, x19, #PW_JMP
    ADR_L x1, g_jmpbuf
    mov  x2, #JMPBUF_BYTES
    bl   memcpy
    ADR_L x0, g_jmpbuf
    bl   setjmp
    cbnz w0, .Lsv_fail
    ADR_L x0, g_pq_out
    str  xzr, [x0, #BUF_LEN]
    ADR_L x0, g_pq_meta
    str  xzr, [x0, #BUF_LEN]
    str  xzr, [x19, #PW_POS]
    bl   pw_alloc_scratch
    // header, metadata prefix
    ADR_L x1, s_header
    ADR_L x0, g_pq_out
    mov  x2, #8
    bl   buf_put
    mov  x9, #8
    str  x9, [x19, #PW_POS]
    bl   pw_meta_head
    ldr  x0, [x19, #PW_TBL]
    ldr  x25, [x0, #TBL_NCOLS]
    // row groups
    mov  x22, #0
3:  cmp  x22, x21
    b.hs 7f
    ldr  x23, [x19, #PW_RGS]
    sub  x9, x21, x22
    cmp  x23, x9
    csel x23, x23, x9, ls
    cbz  x22, 4f
    mov  w0, #','
    bl   mp_c
4:  ADR_L x0, j_rg
    bl   mp_puts
    mov  x0, x23
    bl   mp_u64
    ADR_L x0, j_chunks
    bl   mp_puts
    mov  x24, #0
5:  cmp  x24, x25
    b.hs 6f
    cbz  x24, 51f
    mov  w0, #','
    bl   mp_c
51: mov  x0, x24
    mov  x1, x22
    mov  x2, x23
    bl   pw_chunk
    add  x24, x24, #1
    b    5b
6:  ADR_L x0, j_close
    bl   mp_puts
    add  x22, x22, x23
    b    3b
7:  ADR_L x0, j_close
    bl   mp_puts
    bl   pw_finish
    // success: restore the caller's error handler
    ADR_L x0, g_jmpbuf
    add  x1, x19, #PW_JMP
    mov  x2, #JMPBUF_BYTES
    bl   memcpy
    ldr  x0, [x19, #PW_POS]
    LEAVE 4
.Lsv_fail:
    // an error was raised: close and remove the temp file, re-raise
    ADR_L x19, g_pw
    ldr  x0, [x19, #PW_FD]
    tbnz x0, #63, 8f
    bl   close
    mov  x9, #-1
    str  x9, [x19, #PW_FD]
8:  ldr  x0, [x19, #PW_TMP]
    cbz  x0, 9f
    bl   unlink
    str  xzr, [x19, #PW_TMP]
9:  ADR_L x0, g_jmpbuf
    add  x1, x19, #PW_JMP
    mov  x2, #JMPBUF_BYTES
    bl   memcpy
    ADR_L x0, g_jmpbuf
    mov  w1, #1
    bl   longjmp
ENDF pqcf_save

// -----------------------------------------------------------------------------
// pw_tmp_name(): PW_TMP = "<dir of PW_FULL>/.<base>.tmp-<pid>-<seq>"
// Registers: x19 target path, x20 its last '/', x21 buffer, x22 buffer size,
//            w23 pid, x24 sequence number
// -----------------------------------------------------------------------------
LFUNC pw_tmp_name
    ENTER 3
    ADR_L x9, g_pw
    ldr  x19, [x9, #PW_FULL]
    mov  x0, x19
    mov  w1, #'/'
    bl   strrchr                    // never 0: data_path inserts a '/'
    mov  x20, x0
    mov  x0, x19
    bl   strlen
    add  x22, x0, #64
    mov  x0, x22
    bl   arena_alloc
    mov  x21, x0
    bl   getpid
    mov  w23, w0
    ADR_L x9, g_pq_tmpseq
    ldr  x24, [x9]
    add  x10, x24, #1
    str  x10, [x9]
    mov  x0, x21
    mov  x1, x22
    ADR_L x2, f_tmpname
    sub  x3, x20, x19
    mov  x4, x19
    add  x5, x20, #1
    mov  w6, w23
    mov  x7, x24
    bl   snprintf
    ADR_L x9, g_pw
    str  x21, [x9, #PW_TMP]
    LEAVE 3
ENDF pw_tmp_name

// -----------------------------------------------------------------------------
// pw_alloc_scratch(): per-group scratch arrays for PW_RGS rows (request
// arena), reused by every row group.
// Registers: x19 ctx, x20 rows per group, x21 hash slot count
// -----------------------------------------------------------------------------
LFUNC pw_alloc_scratch
    ENTER 2
    ADR_L x19, g_pw
    ldr  x20, [x19, #PW_RGS]
    lsl  x0, x20, #3
    add  x0, x0, #16
    bl   arena_alloc
    str  x0, [x19, #PW_VALS]
    add  x0, x20, #16
    bl   arena_alloc
    str  x0, [x19, #PW_ISN]
    lsl  x0, x20, #2
    add  x0, x0, #16
    bl   arena_alloc
    str  x0, [x19, #PW_CODES]
    lsl  x0, x20, #3
    add  x0, x0, #16
    bl   arena_alloc
    str  x0, [x19, #PW_DICT]
    mov  x21, #16                   // slots: power of two >= 2 * rows
1:  cmp  x21, x20, lsl #1
    b.hs 2f
    lsl  x21, x21, #1
    b    1b
2:  sub  x9, x21, #1
    str  x9, [x19, #PW_HMASK]
    lsl  x0, x21, #2
    bl   arena_alloc
    str  x0, [x19, #PW_HSLOT]
    LEAVE 2
ENDF pw_alloc_scratch

// -----------------------------------------------------------------------------
// pw_meta_head(): metadata up to and including "row_groups":[
// Registers: x19 table, x20 Column* / Index**, x21 count, x22 i, x23 Index*
// -----------------------------------------------------------------------------
LFUNC pw_meta_head
    ENTER 3
    ADR_L x9, g_pw
    ldr  x19, [x9, #PW_TBL]
    ADR_L x0, j_head
    bl   mp_puts
    ldr  x0, [x19, #TBL_NAME]
    cbnz x0, 1f
    ADR_L x0, j_empty
    bl   mp_puts
    b    2f
1:  bl   mp_jstr
2:  ADR_L x0, j_rowcount
    bl   mp_puts
    ldr  x0, [x19, #TBL_NROWS]
    bl   mp_u64
    ADR_L x0, j_columns
    bl   mp_puts
    ldr  x20, [x19, #TBL_COLS]
    ldr  x21, [x19, #TBL_NCOLS]
    mov  x22, #0
3:  cmp  x22, x21
    b.hs 5f
    cbz  x22, 4f
    mov  w0, #','
    bl   mp_c
4:  ADR_L x0, j_name
    bl   mp_puts
    ldr  x0, [x20, #COL_NAME]
    bl   mp_jstr
    ADR_L x0, j_type
    bl   mp_puts
    ADR_L x0, g_pq_meta
    ldr  w1, [x20, #COL_TYPE]
    bl   type_write
    mov  w0, #'"'
    bl   mp_c
    mov  w0, #'}'
    bl   mp_c
    add  x20, x20, #COL_SIZE
    add  x22, x22, #1
    b    3b
5:  ADR_L x0, j_indexes
    bl   mp_puts
    mov  x0, x19
    bl   index_list
    mov  x20, x0
    mov  x21, x1
    mov  x22, #0
6:  cmp  x22, x21
    b.hs 8f
    cbz  x22, 7f
    mov  w0, #','
    bl   mp_c
7:  ldr  x23, [x20, x22, lsl #3]
    ADR_L x0, j_name
    bl   mp_puts
    ldr  x0, [x23, #IX_NAME]
    bl   mp_jstr
    ADR_L x0, j_column
    bl   mp_puts
    ldr  x9, [x23, #IX_COL]
    ldr  x10, [x19, #TBL_COLS]
    add  x10, x10, x9, lsl #5
    ldr  x0, [x10, #COL_NAME]
    bl   mp_jstr
    ADR_L x0, j_kind
    bl   mp_puts
    ldr  w9, [x23, #IX_KIND]
    ADR_L x0, x_hash
    ADR_L x10, x_btree
    cmp  w9, #IXK_HASH
    csel x0, x0, x10, eq
    bl   mp_puts
    mov  w0, #'"'
    bl   mp_c
    mov  w0, #'}'
    bl   mp_c
    add  x22, x22, #1
    b    6b
8:  ADR_L x0, j_rgs
    bl   mp_puts
    LEAVE 3
ENDF pw_meta_head

// -----------------------------------------------------------------------------
// pw_flush(): write g_pq_out to the temp file and empty it.
// Registers: x19 cursor, x20 bytes left
// -----------------------------------------------------------------------------
LFUNC pw_flush
    ENTER 2
    ADR_L x9, g_pq_out
    ldr  x19, [x9, #BUF_PTR]
    ldr  x20, [x9, #BUF_LEN]
1:  cbz  x20, 3f
    ADR_L x9, g_pw
    ldr  x0, [x9, #PW_FD]
    mov  x1, x19
    mov  x2, x20
    bl   write
    cmp  x0, #0
    b.gt 2f
    b.eq pw_io_error
    bl   __errno_location
    ldr  w0, [x0]
    cmp  w0, #EINTR
    b.eq 1b
    b    pw_io_error
2:  add  x19, x19, x0
    sub  x20, x20, x0
    b    1b
3:  ADR_L x9, g_pq_out
    str  xzr, [x9, #BUF_LEN]
    LEAVE 2
ENDF pw_flush

// -----------------------------------------------------------------------------
// pw_finish(): append metadata and footer, flush, fsync, close, rename over
// the target, fsync the directory.
// Registers: x19 ctx, x20 metadata length / dir path, x21 crc / dir length,
//            x22 footer scratch on the stack
// -----------------------------------------------------------------------------
LFUNC pw_finish
    ENTER 2
    sub  sp, sp, #16
    ADR_L x19, g_pw
    bl   pw_flush
    ADR_L x9, g_pq_meta
    ldr  x20, [x9, #BUF_LEN]
    lsr  x10, x20, #32
    cbz  x10, 1f
    RAISE ERR_RESOURCE_LIMIT, "PQCF metadata exceeds 4 GiB"
1:  ldr  x0, [x9, #BUF_PTR]
    mov  x1, x20
    bl   crc32
    mov  w21, w0
    ADR_L x9, g_pq_meta
    ldr  x1, [x9, #BUF_PTR]
    ADR_L x0, g_pq_out
    mov  x2, x20
    bl   buf_put
    str  w20, [sp]                  // footer: u32 M, u32 crc, "PQCF"
    str  w21, [sp, #4]
    ldr  w9, =PQ_MAGIC
    str  w9, [sp, #8]
    ADR_L x0, g_pq_out
    mov  x1, sp
    mov  x2, #12
    bl   buf_put
    ldr  x9, [x19, #PW_POS]
    add  x9, x9, x20
    add  x9, x9, #12
    str  x9, [x19, #PW_POS]
    bl   pw_flush
    ldr  x0, [x19, #PW_FD]
    bl   fsync
    cbnz w0, pw_io_error
    ldr  x0, [x19, #PW_FD]
    mov  x9, #-1
    str  x9, [x19, #PW_FD]
    bl   close
    cbnz w0, pw_io_error
    ldr  x0, [x19, #PW_TMP]
    ldr  x1, [x19, #PW_FULL]
    bl   rename
    cbnz w0, pw_io_error
    str  xzr, [x19, #PW_TMP]        // the temp file is now the target
    // fsync the directory (best effort)
    ldr  x20, [x19, #PW_FULL]
    mov  x0, x20
    mov  w1, #'/'
    bl   strrchr
    sub  x21, x0, x20
    add  x0, x21, #1
    bl   arena_alloc
    mov  x22, x0
    mov  x1, x20
    mov  x2, x21
    bl   memcpy
    strb wzr, [x22, x21]
    mov  x0, x22
    mov  w1, #(O_RDONLY | O_DIRECTORY)
    orr  w1, w1, #O_CLOEXEC
    bl   open
    tbnz w0, #31, 2f
    mov  w20, w0
    bl   fsync
    mov  w0, w20
    bl   close
2:  add  sp, sp, #16
    LEAVE 2
ENDF pw_finish

// -----------------------------------------------------------------------------
// pw_gather(x0 col, x1 first row, x2 n, w3 type): read the group's values
// into PW_VALS / PW_ISN and compute PW_NNULL, PW_HASMM/MIN/MAX, PW_RUNS,
// PW_SBYTES.
// Registers: x19 ctx, x20 col, x21 first row, x22 n, w23 type, x24 i,
//            x25 PW_VALS, x26 PW_ISN, x27 table
// -----------------------------------------------------------------------------
LFUNC pw_gather
    ENTER 5
    ADR_L x19, g_pw
    mov  x20, x0
    mov  x21, x1
    mov  x22, x2
    mov  w23, w3
    ldr  x25, [x19, #PW_VALS]
    ldr  x26, [x19, #PW_ISN]
    ldr  x27, [x19, #PW_TBL]
    str  xzr, [x19, #PW_NNULL]
    str  wzr, [x19, #PW_HASMM]
    str  xzr, [x19, #PW_RUNS]
    str  xzr, [x19, #PW_SBYTES]
    mov  x24, #0
1:  cmp  x24, x22
    b.hs 9f
    mov  x0, x27
    mov  x1, x20
    add  x2, x21, x24
    bl   tbl_get
    cbz  x1, 2f
    strb w1, [x26, x24]             // NULL: payload 0
    str  xzr, [x25, x24, lsl #3]
    ldr  x9, [x19, #PW_NNULL]
    add  x9, x9, #1
    str  x9, [x19, #PW_NNULL]
    b    6f
2:  strb wzr, [x26, x24]
    str  x0, [x25, x24, lsl #3]
    and  w9, w23, #T_KIND_MASK
    cmp  w9, #T_STR
    b.ne 3f
    ldr  x9, [x0, #STR_LEN]
    ldr  x10, [x19, #PW_SBYTES]
    add  x10, x10, x9
    str  x10, [x19, #PW_SBYTES]
3:  ldr  w9, [x19, #PW_HASMM]
    cbnz w9, 4f
    str  x0, [x19, #PW_MIN]
    str  x0, [x19, #PW_MAX]
    mov  w9, #1
    str  w9, [x19, #PW_HASMM]
    b    6f
4:  ldr  x1, [x19, #PW_MIN]
    mov  w2, w23
    bl   value_cmp
    tbz  w0, #31, 5f
    ldr  x0, [x25, x24, lsl #3]
    str  x0, [x19, #PW_MIN]
5:  ldr  x0, [x25, x24, lsl #3]
    ldr  x1, [x19, #PW_MAX]
    mov  w2, w23
    bl   value_cmp
    cmp  w0, #0
    b.le 6f
    ldr  x0, [x25, x24, lsl #3]
    str  x0, [x19, #PW_MAX]
6:  // runs of equal payloads (NULL slots count as payload 0)
    ldr  x0, [x25, x24, lsl #3]
    cbz  x24, 7f
    sub  x9, x24, #1
    ldr  x1, [x25, x9, lsl #3]
    cmp  x0, x1
    b.eq 8f
7:  ldr  x9, [x19, #PW_RUNS]
    add  x9, x9, #1
    str  x9, [x19, #PW_RUNS]
8:  add  x24, x24, #1
    b    1b
9:  LEAVE 5
ENDF pw_gather

// -----------------------------------------------------------------------------
// pw_dict(x0 n): dictionary of the group's non-null strings (first-seen
// order): PW_DICT entries, PW_CODES per row (0 for NULL), PW_ND, PW_DBYTES.
// Open addressing over PW_HSLOT (FNV-1a hash, linear probing; load <= 1/2).
// Registers: x19 ctx, x20 n, x21 i, x22 PW_VALS, x23 PW_ISN, x24 PW_CODES,
//            x25 PW_DICT, x26 PW_HSLOT, x27 mask, x28 entries so far
// -----------------------------------------------------------------------------
LFUNC pw_dict
    ENTER 5
    ADR_L x19, g_pw
    mov  x20, x0
    ldr  x22, [x19, #PW_VALS]
    ldr  x23, [x19, #PW_ISN]
    ldr  x24, [x19, #PW_CODES]
    ldr  x25, [x19, #PW_DICT]
    ldr  x26, [x19, #PW_HSLOT]
    ldr  x27, [x19, #PW_HMASK]
    mov  x0, x26
    mov  w1, #0
    add  x2, x27, #1
    lsl  x2, x2, #2
    bl   memset
    str  xzr, [x19, #PW_DBYTES]
    mov  x28, #0
    mov  x21, #0
1:  cmp  x21, x20
    b.hs 9f
    ldrb w9, [x23, x21]
    cbz  w9, 2f
    str  wzr, [x24, x21, lsl #2]    // NULL: code 0
    b    8f
2:  ldr  x0, [x22, x21, lsl #3]     // Str*
    ldr  x1, [x0, #STR_LEN]
    add  x2, x0, #STR_DATA
    ldr  x9, =0xcbf29ce484222325    // FNV-1a 64
    ldr  x10, =0x100000001b3
    mov  x11, #0
3:  cmp  x11, x1
    b.hs 4f
    ldrb w12, [x2, x11]
    eor  x9, x9, x12
    mul  x9, x9, x10
    add  x11, x11, #1
    b    3b
4:  eor  x9, x9, x9, lsr #29
    and  x9, x9, x27                // slot
5:  ldr  w10, [x26, x9, lsl #2]
    cbz  w10, 7f
    sub  w10, w10, #1               // existing entry: compare
    ldr  x11, [x25, x10, lsl #3]
    ldr  x12, [x11, #STR_LEN]
    cmp  x12, x1
    b.ne 61f
    add  x11, x11, #STR_DATA
    mov  x13, #0
6:  cmp  x13, x1
    b.hs 62f                        // equal
    ldrb w14, [x11, x13]
    ldrb w15, [x2, x13]
    cmp  w14, w15
    b.ne 61f
    add  x13, x13, #1
    b    6b
61: add  x9, x9, #1                 // probe the next slot
    and  x9, x9, x27
    b    5b
62: str  w10, [x24, x21, lsl #2]
    b    8f
7:  add  w10, w28, #1               // new entry
    str  w10, [x26, x9, lsl #2]
    str  x0, [x25, x28, lsl #3]
    str  w28, [x24, x21, lsl #2]
    add  x28, x28, #1
    ldr  x9, [x19, #PW_DBYTES]
    add  x9, x9, x1
    str  x9, [x19, #PW_DBYTES]
8:  add  x21, x21, #1
    b    1b
9:  str  x28, [x19, #PW_ND]
    LEAVE 5
ENDF pw_dict

// -----------------------------------------------------------------------------
// pw_chunk(x0 col, x1 first row, x2 n): encode one column chunk into
// g_pq_out and append its metadata object to g_pq_meta.
// Registers: x19 ctx, x20 col, x21 first row, x22 n, w23 type, w24 kind,
//            w25 chosen encoding, x26 values section bytes, x27 chunk start,
//            x28 validity bitmap bytes (0 = no NULLs)
// -----------------------------------------------------------------------------
LFUNC pw_chunk
    ENTER 5
    ADR_L x19, g_pw
    mov  x20, x0
    mov  x21, x1
    mov  x22, x2
    ldr  x9, [x19, #PW_TBL]
    ldr  x9, [x9, #TBL_COLS]
    add  x9, x9, x20, lsl #5
    ldr  w23, [x9, #COL_TYPE]
    and  w24, w23, #T_KIND_MASK
    mov  x0, x20
    mov  x1, x21
    mov  x2, x22
    mov  w3, w23
    bl   pw_gather
    // --- encoding
    ldr  w9, [x19, #PW_ENC]
    mov  w25, #PENC_PLAIN
    cmp  w24, #T_STR
    b.ne 3f
    cmp  w9, #PENC_DICT
    b.eq 1f
    cmp  w9, #PENC_AUTO
    b.ne 5f
1:  mov  x0, x22
    bl   pw_dict
    ldr  w9, [x19, #PW_ENC]
    cmp  w9, #PENC_DICT
    b.eq 2f
    ldr  x10, [x19, #PW_ND]         // AUTO: DICT if distinct < n/2
    cmp  x22, x10, lsl #1
    b.ls 5f
2:  mov  w25, #PENC_DICT
    b    5f
3:  cmp  w24, #T_FLOAT
    b.eq 5f
    cmp  w9, #PENC_RLE
    b.eq 4f
    cmp  w9, #PENC_AUTO
    b.ne 5f
    ldr  x10, [x19, #PW_RUNS]       // AUTO: RLE if runs < n/4
    cmp  x22, x10, lsl #2
    b.ls 5f
4:  mov  w25, #PENC_RLE
5:  // --- size of the values section
    cmp  w25, #PENC_RLE
    b.ne 51f
    ldr  x9, [x19, #PW_RUNS]
    mov  x10, #12
    mul  x26, x9, x10
    add  x26, x26, #4
    b    6f
51: cmp  w25, #PENC_DICT
    b.ne 52f
    ldr  x9, [x19, #PW_DBYTES]
    lsr  x10, x9, #32
    cbnz x10, .Lpc_big
    ldr  x10, [x19, #PW_ND]
    add  x26, x9, x10, lsl #2       // dict bytes + 4 D
    add  x26, x26, #8               // + u32 D + offsets[D]
    add  x26, x26, x22, lsl #2      // + codes
    b    6f
52: cmp  w24, #T_BOOL
    b.ne 53f
    add  x26, x22, #7
    lsr  x26, x26, #3
    b    6f
53: cmp  w24, #T_DATE
    b.ne 54f
    lsl  x26, x22, #2
    b    6f
54: cmp  w24, #T_STR
    b.ne 55f
    ldr  x9, [x19, #PW_SBYTES]
    lsr  x10, x9, #32
    cbnz x10, .Lpc_big
    add  x26, x9, x22, lsl #2
    add  x26, x26, #4
    b    6f
55: lsl  x26, x22, #3
6:  mov  x28, #0
    ldr  x9, [x19, #PW_NNULL]
    cbz  x9, 7f
    add  x28, x22, #7
    lsr  x28, x28, #3
7:  // --- reserve (plus 8 bytes for the alignment padding) and write
    ADR_L x0, g_pq_out
    add  x1, x26, x28
    add  x1, x1, #8
    bl   buf_reserve
    mov  x27, x0
    cbz  x28, 8f
    mov  w1, #0                     // validity bitmap: 1 = non-null
    mov  x2, x28
    bl   memset
    ldr  x9, [x19, #PW_ISN]
    mov  x10, #0
71: cmp  x10, x22
    b.hs 8f
    ldrb w11, [x9, x10]
    cbnz w11, 72f
    lsr  x12, x10, #3
    ldrb w13, [x27, x12]
    and  x14, x10, #7
    mov  w15, #1
    lsl  w15, w15, w14
    orr  w13, w13, w15
    strb w13, [x27, x12]
72: add  x10, x10, #1
    b    71b
8:  add  x0, x27, x28
    mov  x1, x22
    mov  w2, w24
    cmp  w25, #PENC_RLE
    b.ne 81f
    bl   pw_put_rle
    b    82f
81: cmp  w25, #PENC_DICT
    b.ne 811f
    bl   pw_put_dict
    b    82f
811: bl  pw_put_plain
82: add  x9, x27, x28               // the writer must end exactly at the size
    add  x9, x9, x26
    cmp  x0, x9
    b.eq 83f
    RAISE ERR_INTERNAL, "PQCF chunk size mismatch"
83: mov  x0, x27
    add  x1, x26, x28
    bl   crc32
    str  w0, [x19, #PW_CRC]
    ADR_L x9, g_pq_out
    ldr  x10, [x9, #BUF_LEN]
    add  x10, x10, x26
    add  x10, x10, x28
    str  x10, [x9, #BUF_LEN]
    // --- metadata
    ADR_L x0, j_offset
    bl   mp_puts
    ldr  x0, [x19, #PW_POS]
    bl   mp_u64
    ADR_L x0, j_length
    bl   mp_puts
    add  x0, x26, x28
    bl   mp_u64
    ADR_L x0, j_crc
    bl   mp_puts
    ldr  w0, [x19, #PW_CRC]
    bl   mp_u64
    ADR_L x0, j_enc
    bl   mp_puts
    ADR_L x0, e_plain
    cmp  w25, #PENC_DICT
    b.ne 84f
    ADR_L x0, e_dict
84: cmp  w25, #PENC_RLE
    b.ne 85f
    ADR_L x0, e_rle
85: bl   mp_puts
    ADR_L x0, j_nulls
    bl   mp_puts
    ldr  x0, [x19, #PW_NNULL]
    bl   mp_u64
    ldr  w9, [x19, #PW_HASMM]
    cbz  w9, 86f
    ADR_L x0, j_min
    bl   mp_puts
    ADR_L x0, g_pq_meta
    ldr  x1, [x19, #PW_MIN]
    mov  x2, #0
    mov  w3, w23
    bl   write_value_json
    ADR_L x0, j_max
    bl   mp_puts
    ADR_L x0, g_pq_meta
    ldr  x1, [x19, #PW_MAX]
    mov  x2, #0
    mov  w3, w23
    bl   write_value_json
86: mov  w0, #'}'
    bl   mp_c
    // --- advance, pad to 8 bytes (zeros; space was reserved)
    ldr  x9, [x19, #PW_POS]
    add  x9, x9, x26
    add  x9, x9, x28
    neg  x10, x9
    and  x10, x10, #7
    add  x9, x9, x10
    str  x9, [x19, #PW_POS]
    ADR_L x11, g_pq_out
    ldr  x12, [x11, #BUF_PTR]
    ldr  x13, [x11, #BUF_LEN]
    str  xzr, [x12, x13]
    add  x13, x13, x10
    str  x13, [x11, #BUF_LEN]
    mov  x9, #PQ_FLUSH_AT
    cmp  x13, x9
    b.lo 9f
    bl   pw_flush
9:  LEAVE 5
.Lpc_big:
    RAISE ERR_RESOURCE_LIMIT, "PQCF string chunk exceeds 4 GiB; use a smaller row_group_size"
ENDF pw_chunk

// -----------------------------------------------------------------------------
// pw_put_plain(x0 dst, x1 n, w2 kind) -> x0 end of the written values
// PLAIN values section from PW_VALS / PW_ISN.
// Registers: x19 dst, x20 n, x21 i, x22 PW_VALS, x23 PW_ISN, x24 offsets,
//            x25 string bytes cursor
// -----------------------------------------------------------------------------
LFUNC pw_put_plain
    ENTER 4
    mov  x19, x0
    mov  x20, x1
    ADR_L x9, g_pw
    ldr  x22, [x9, #PW_VALS]
    ldr  x23, [x9, #PW_ISN]
    cmp  w2, #T_BOOL
    b.eq 1f
    cmp  w2, #T_DATE
    b.eq 3f
    cmp  w2, #T_STR
    b.eq 5f
    mov  x1, x22                    // 8-byte values: copy
    lsl  x2, x20, #3
    bl   memcpy
    add  x0, x19, x20, lsl #3
    LEAVE 4
1:  add  x2, x20, #7                // BOOLEAN: bitmap, 1 = true
    lsr  x2, x2, #3
    mov  w1, #0
    bl   memset
    mov  x21, #0
2:  cmp  x21, x20
    b.hs 21f
    ldr  x9, [x22, x21, lsl #3]
    cbz  x9, 22f
    lsr  x10, x21, #3
    ldrb w11, [x19, x10]
    and  x12, x21, #7
    mov  w13, #1
    lsl  w13, w13, w12
    orr  w11, w11, w13
    strb w11, [x19, x10]
22: add  x21, x21, #1
    b    2b
21: add  x0, x20, #7
    lsr  x0, x0, #3
    add  x0, x19, x0
    LEAVE 4
3:  mov  x21, #0                    // DATE: i32 days
4:  cmp  x21, x20
    b.hs 41f
    ldr  x9, [x22, x21, lsl #3]
    str  w9, [x19, x21, lsl #2]
    add  x21, x21, #1
    b    4b
41: add  x0, x19, x20, lsl #2
    LEAVE 4
5:  mov  x24, x19                   // STRING: (n+1) u32 offsets, bytes
    add  x25, x19, x20, lsl #2
    add  x25, x25, #4
    mov  x21, #0
6:  cmp  x21, x20
    b.hs 7f
    add  x9, x24, #4
    sub  x10, x25, x9
    sub  x10, x10, x20, lsl #2      // bytes written so far
    str  w10, [x24, x21, lsl #2]
    ldrb w9, [x23, x21]
    cbnz w9, 61f
    ldr  x9, [x22, x21, lsl #3]
    ldr  x2, [x9, #STR_LEN]
    add  x1, x9, #STR_DATA
    mov  x0, x25
    add  x25, x25, x2
    bl   memcpy
61: add  x21, x21, #1
    b    6b
7:  add  x9, x24, #4
    sub  x10, x25, x9
    sub  x10, x10, x20, lsl #2
    str  w10, [x24, x20, lsl #2]
    mov  x0, x25
    LEAVE 4
ENDF pw_put_plain

// -----------------------------------------------------------------------------
// pw_put_dict(x0 dst, x1 n) -> x0 end: u32 D, (D+1) u32 offsets, bytes,
// n u32 codes (from pw_dict).
// Registers: x19 offsets, x20 n, x21 d, x22 D, x23 bytes start, x24 cursor,
//            x25 PW_DICT
// -----------------------------------------------------------------------------
LFUNC pw_put_dict
    ENTER 4
    mov  x20, x1
    ADR_L x9, g_pw
    ldr  x22, [x9, #PW_ND]
    ldr  x25, [x9, #PW_DICT]
    str  w22, [x0]
    add  x19, x0, #4
    add  x23, x19, x22, lsl #2
    add  x23, x23, #4
    mov  x24, x23
    mov  x21, #0
1:  cmp  x21, x22
    b.hs 2f
    sub  x9, x24, x23
    str  w9, [x19, x21, lsl #2]
    ldr  x9, [x25, x21, lsl #3]
    ldr  x2, [x9, #STR_LEN]
    add  x1, x9, #STR_DATA
    mov  x0, x24
    add  x24, x24, x2
    bl   memcpy
    add  x21, x21, #1
    b    1b
2:  sub  x9, x24, x23
    str  w9, [x19, x22, lsl #2]
    mov  x0, x24
    ADR_L x9, g_pw
    ldr  x1, [x9, #PW_CODES]
    lsl  x2, x20, #2
    bl   memcpy
    add  x0, x24, x20, lsl #2
    LEAVE 4
ENDF pw_put_dict

// -----------------------------------------------------------------------------
// pw_put_rle(x0 dst, x1 n) -> x0 end: u32 R, R x {i64 value, u32 length}
// over PW_VALS (NULL slots hold 0 and are covered by runs).      (leaf)
// Registers: x9 PW_VALS, x10 i, x11 run end, x12 value, x13 cursor, x14 R
// -----------------------------------------------------------------------------
LFUNC pw_put_rle
    ADR_L x9, g_pw
    ldr  x9, [x9, #PW_VALS]
    add  x13, x0, #4
    mov  x14, #0
    mov  x10, #0
1:  cmp  x10, x1
    b.hs 4f
    ldr  x12, [x9, x10, lsl #3]
    add  x11, x10, #1
2:  cmp  x11, x1
    b.hs 3f
    ldr  x15, [x9, x11, lsl #3]
    cmp  x15, x12
    b.ne 3f
    add  x11, x11, #1
    b    2b
3:  str  x12, [x13]
    sub  x15, x11, x10
    str  w15, [x13, #8]
    add  x13, x13, #12
    add  x14, x14, #1
    mov  x10, x11
    b    1b
4:  str  w14, [x0]
    mov  x0, x13
    ret
ENDF pw_put_rle

// =============================================================================
//                                   READER
// =============================================================================

// Failure exits (branch targets; they never return)
LFUNC pr_bad_frame
    RAISE ERR_STORAGE_CORRUPT, "not a valid PQCF file (header/footer)"
ENDF pr_bad_frame
LFUNC pr_bad_version
    RAISE ERR_STORAGE_VERSION, "unsupported PQCF format version or flags"
ENDF pr_bad_version
LFUNC pr_bad_metacrc
    RAISE ERR_STORAGE_CORRUPT, "PQCF metadata checksum mismatch"
ENDF pr_bad_metacrc
LFUNC pr_bad_meta
    RAISE ERR_STORAGE_CORRUPT, "invalid PQCF metadata"
ENDF pr_bad_meta
LFUNC pr_bad_bounds
    RAISE ERR_STORAGE_CORRUPT, "PQCF chunk out of bounds"
ENDF pr_bad_bounds
LFUNC pr_bad_crc
    RAISE ERR_STORAGE_CORRUPT, "PQCF chunk checksum mismatch"
ENDF pr_bad_crc
LFUNC pr_bad_chunk
    RAISE ERR_STORAGE_CORRUPT, "invalid PQCF chunk layout"
ENDF pr_bad_chunk
LFUNC pr_bad_value
    RAISE ERR_STORAGE_CORRUPT, "invalid value in PQCF chunk"
ENDF pr_bad_value

// =============================================================================
// pqcf_load(x0 path Str*, w1 use_mmap) -> x0 Table*, x1 XS* specs, x2 count
// Missing file => NOT_FOUND; unreadable => IO_ERROR; invalid => STORAGE_*.
// Registers: x19 ctx, x20 path Str*, w21 use_mmap, x22 fd, x23 size,
//            x24 bytes read; stack: struct stat, later the results
// =============================================================================
FUNC pqcf_load
    ENTER 3
    sub  sp, sp, #STAT_BYTES
    ADR_L x19, g_pr
    mov  x20, x0
    mov  w21, w1
    str  xzr, [x19, #RD_MAPPED]
    str  xzr, [x19, #RD_TBL]
    bl   data_path
    mov  w1, #O_CLOEXEC             // O_RDONLY
    bl   open
    sxtw x22, w0
    tbz  x22, #63, 2f
    bl   __errno_location
    ldr  w0, [x0]
    cmp  w0, #ENOENT
    b.eq 1f
    cmp  w0, #ENOTDIR
    b.ne .Lld_ioerr
1:  mov  w0, #ERR_NOT_FOUND
    ADR_L x1, m_nofile
    add  x2, x20, #STR_DATA
    ldr  x3, [x20, #STR_LEN]
    bl   pq_raise_s
2:  mov  w0, w22
    mov  x1, sp
    bl   fstat
    cbnz w0, .Lld_ioclose
    ldr  w9, [sp, #STAT_MODE]
    and  w9, w9, #0170000
    cmp  w9, #0100000               // regular file
    b.ne .Lld_ioclose
    ldr  x23, [sp, #STAT_SIZE]
    cbnz x23, 3f
    mov  w0, w22
    bl   close
    b    pr_bad_frame               // empty file
3:  cbz  w21, 4f
    mov  x0, #0                     // mmap(0, size, PROT_READ, MAP_PRIVATE, fd, 0)
    mov  x1, x23
    mov  w2, #PROT_READ
    mov  w3, #MAP_PRIVATE
    mov  w4, w22
    mov  x5, #0
    bl   mmap
    cmn  x0, #1
    b.eq 4f                         // cannot map: read instead
    str  x0, [x19, #RD_BASE]
    mov  x9, #1
    str  x9, [x19, #RD_MAPPED]
    b    6f
4:  add  x0, x23, #8
    bl   arena_alloc
    str  x0, [x19, #RD_BASE]
    mov  x24, #0
5:  cmp  x24, x23
    b.hs 6f
    mov  w0, w22
    ldr  x1, [x19, #RD_BASE]
    add  x1, x1, x24
    sub  x2, x23, x24
    bl   read
    cmp  x0, #0
    b.gt 51f
    b.eq 52f                        // shrank meanwhile: use what was read
    bl   __errno_location
    ldr  w0, [x0]
    cmp  w0, #EINTR
    b.eq 5b
    b    .Lld_ioclose
51: add  x24, x24, x0
    b    5b
52: mov  x23, x24
6:  str  x23, [x19, #RD_SIZE]
    mov  w0, w22
    bl   close
    // intercept errors to unmap the file
    add  x0, x19, #RD_JMP
    ADR_L x1, g_jmpbuf
    mov  x2, #JMPBUF_BYTES
    bl   memcpy
    ADR_L x0, g_jmpbuf
    bl   setjmp
    cbnz w0, .Lld_fail
    bl   pr_parse
    stp  x0, x1, [sp]
    str  x2, [sp, #16]
    bl   pr_unmap
    ADR_L x0, g_jmpbuf
    add  x1, x19, #RD_JMP
    mov  x2, #JMPBUF_BYTES
    bl   memcpy
    ldp  x0, x1, [sp]
    ldr  x2, [sp, #16]
    add  sp, sp, #STAT_BYTES
    LEAVE 3
.Lld_fail:
    ADR_L x19, g_pr
    bl   pr_unmap
    ADR_L x0, g_jmpbuf
    add  x1, x19, #RD_JMP
    mov  x2, #JMPBUF_BYTES
    bl   memcpy
    ADR_L x0, g_jmpbuf
    mov  w1, #1
    bl   longjmp
.Lld_ioclose:
    mov  w0, w22
    bl   close
.Lld_ioerr:
    mov  w0, #ERR_IO
    ADR_L x1, m_ioread
    add  x2, x20, #STR_DATA
    ldr  x3, [x20, #STR_LEN]
    bl   pq_raise_s
ENDF pqcf_load

// pr_unmap(): release an mmap'ed file image
LFUNC pr_unmap
    ENTER 0
    ADR_L x9, g_pr
    ldr  x10, [x9, #RD_MAPPED]
    cbz  x10, 1f
    str  xzr, [x9, #RD_MAPPED]
    ldr  x0, [x9, #RD_BASE]
    ldr  x1, [x9, #RD_SIZE]
    bl   munmap
1:  LEAVE 0
ENDF pr_unmap

// -----------------------------------------------------------------------------
// pr_parse() -> x0 Table*, x1 XS*, x2 count: validate and decode the image
// at RD_BASE / RD_SIZE.
// Registers: x19 ctx, x20 metadata root
// -----------------------------------------------------------------------------
LFUNC pr_parse
    ENTER 1
    ADR_L x19, g_pr
    bl   pr_frame
    mov  x20, x0
    bl   pr_top
    mov  x0, x20
    bl   pr_columns
    mov  x0, x20
    bl   pr_groups
    mov  x0, x20
    bl   pr_indexes
    bl   pr_build
    bl   pr_decode
    ldr  x0, [x19, #RD_TBL]
    ldr  x1, [x19, #RD_XS]
    ldr  x2, [x19, #RD_NXS]
    LEAVE 1
ENDF pr_parse

// -----------------------------------------------------------------------------
// pr_frame() -> x0 metadata root (JSON object): header, footer, metadata
// bounds and CRC (§1). Sets RD_MSTART.
// Registers: x19 ctx, x20 base, x21 size, x22 metadata length
// -----------------------------------------------------------------------------
LFUNC pr_frame
    ENTER 2
    ADR_L x19, g_pr
    ldr  x20, [x19, #RD_BASE]
    ldr  x21, [x19, #RD_SIZE]
    cmp  x21, #8
    b.lo pr_bad_frame
    ldr  w9, [x20]
    ldr  w10, =PQ_MAGIC
    cmp  w9, w10
    b.ne pr_bad_frame
    ldrh w9, [x20, #4]              // format_version
    cbz  w9, pr_bad_frame
    cmp  w9, #1
    b.hi pr_bad_version
    ldrh w9, [x20, #6]              // flags
    cbnz w9, pr_bad_version
    cmp  x21, #20
    b.lo pr_bad_frame
    sub  x9, x21, #4
    ldr  w9, [x20, x9]
    cmp  w9, w10
    b.ne pr_bad_frame
    sub  x9, x21, #12
    ldr  w22, [x20, x9]             // M
    sub  x10, x21, #20
    cmp  x22, x10
    b.hi pr_bad_frame               // metadata would start before offset 8
    sub  x9, x9, x22
    str  x9, [x19, #RD_MSTART]
    add  x0, x20, x9
    mov  x1, x22
    bl   crc32
    sub  x9, x21, #8
    ldr  w9, [x20, x9]
    cmp  w0, w9
    b.ne pr_bad_metacrc
    ldr  x9, [x19, #RD_MSTART]
    add  x0, x20, x9
    mov  x1, x22
    bl   json_parse
    cbz  x0, pr_bad_meta
    ldr  w9, [x0, #JN_TYPE]
    cmp  w9, #J_OBJ
    b.ne pr_bad_meta
    LEAVE 2
ENDF pr_frame

// -----------------------------------------------------------------------------
// pr_req(x0 obj, x1 key cstr, w2 JSON type) -> x0 JNode*  (missing, null or
// of another type => STORAGE_CORRUPT)
// pr_opt(x0 obj, x1 key cstr) -> x0 JNode* or 0 (absent / null)
// pr_uint(x0 JNode*) -> x0 non-negative JSON integer (else STORAGE_CORRUPT)
// -----------------------------------------------------------------------------
LFUNC pr_req
    ENTER 1
    mov  w19, w2
    bl   json_get
    cbz  x0, pr_bad_meta
    ldr  w9, [x0, #JN_TYPE]
    cmp  w9, w19
    b.ne pr_bad_meta
    LEAVE 1
ENDF pr_req

LFUNC pr_opt
    ENTER 0
    bl   json_get
    cbz  x0, 1f
    ldr  w9, [x0, #JN_TYPE]
    cmp  w9, #J_NULL
    b.ne 1f
    mov  x0, #0
1:  LEAVE 0
ENDF pr_opt

LFUNC pr_uint
    ENTER 0
    ldr  w9, [x0, #JN_TYPE]
    cmp  w9, #J_NUM
    b.ne pr_bad_meta
    ldr  x9, [x0, #JN_PTR]
    add  x0, x9, #STR_DATA
    ldr  x1, [x9, #STR_LEN]
    bl   parse_int64
    cbnz w1, pr_bad_meta
    tbnz x0, #63, pr_bad_meta
    LEAVE 0
ENDF pr_uint

// pr_top(x0 root): format_version (= header), table, row_count
LFUNC pr_top
    ENTER 1
    mov  x19, x0
    ADR_L x1, k_fv
    mov  w2, #J_NUM
    bl   pr_req
    bl   pr_uint
    ADR_L x9, g_pr
    ldr  x9, [x9, #RD_BASE]
    ldrh w9, [x9, #4]
    cmp  x0, x9
    b.ne pr_bad_meta
    mov  x0, x19
    ADR_L x1, k_table
    mov  w2, #J_STR
    bl   pr_req
    mov  x0, x19
    ADR_L x1, k_rowcount
    mov  w2, #J_NUM
    bl   pr_req
    bl   pr_uint
    ADR_L x9, g_pr
    str  x0, [x9, #RD_NROWS]
    LEAVE 1
ENDF pr_top

// -----------------------------------------------------------------------------
// pr_columns(x0 root): RD_NCOLS / RD_NAMES / RD_TYPES. Names non-empty and
// unique (case-insensitive); types valid and in canonical form.
// Registers: x19 ctx, x20 elements, x21 n, x22 i, x23 names, x24 types,
//            x25 element / name, x26 j
// -----------------------------------------------------------------------------
LFUNC pr_columns
    ENTER 4
    ADR_L x19, g_pr
    ADR_L x1, k_columns
    mov  w2, #J_ARR
    bl   pr_req
    ldr  w21, [x0, #JN_COUNT]
    ldr  x20, [x0, #JN_PTR]
    cbz  x21, pr_bad_meta
    str  x21, [x19, #RD_NCOLS]
    lsl  x0, x21, #3
    bl   arena_alloc
    mov  x23, x0
    str  x23, [x19, #RD_NAMES]
    lsl  x0, x21, #2
    bl   arena_alloc
    mov  x24, x0
    str  x24, [x19, #RD_TYPES]
    mov  x22, #0
1:  cmp  x22, x21
    b.hs 9f
    ldr  x25, [x20, x22, lsl #3]
    ldr  w9, [x25, #JN_TYPE]
    cmp  w9, #J_OBJ
    b.ne pr_bad_meta
    mov  x0, x25
    ADR_L x1, k_type
    mov  w2, #J_STR
    bl   pr_req
    ldr  x0, [x0, #JN_PTR]
    bl   pr_type
    str  w0, [x24, x22, lsl #2]
    mov  x0, x25
    ADR_L x1, k_name
    mov  w2, #J_STR
    bl   pr_req
    ldr  x25, [x0, #JN_PTR]
    ldr  x9, [x25, #STR_LEN]
    cbz  x9, pr_bad_meta
    mov  x26, #0
2:  cmp  x26, x22
    b.hs 3f
    mov  x0, x25
    ldr  x1, [x23, x26, lsl #3]
    bl   str_ieq
    cbnz w0, pr_bad_meta            // duplicate column name
    add  x26, x26, #1
    b    2b
3:  str  x25, [x23, x22, lsl #3]
    add  x22, x22, #1
    b    1b
9:  LEAVE 4
ENDF pr_columns

// pr_type(x0 Str*) -> w0 type; the text must be a canonical type name
// (types.md §1), checked by re-rendering it into g_pq_meta.
// Registers: x19 Str*, w20 type
LFUNC pr_type
    ENTER 1
    mov  x19, x0
    add  x0, x19, #STR_DATA
    ldr  x1, [x19, #STR_LEN]
    bl   type_parse
    tbnz w0, #31, pr_bad_meta
    and  w9, w0, #T_KIND_MASK
    cbz  w9, pr_bad_meta            // the null type is not a column type
    mov  w20, w0
    ADR_L x0, g_pq_meta
    str  xzr, [x0, #BUF_LEN]
    mov  w1, w20
    bl   type_write
    ADR_L x9, g_pq_meta
    ldr  x2, [x9, #BUF_LEN]
    ldr  x10, [x19, #STR_LEN]
    cmp  x2, x10
    b.ne pr_bad_meta
    ldr  x0, [x9, #BUF_PTR]
    add  x1, x19, #STR_DATA
    bl   memcmp
    cbnz w0, pr_bad_meta
    mov  w0, w20
    LEAVE 1
ENDF pr_type

// -----------------------------------------------------------------------------
// pr_enc(x0 Str*) -> w0 PENC_PLAIN / PENC_DICT / PENC_RLE; any other name
// raises STORAGE_VERSION_UNSUPPORTED (§3.3).
// Registers: x19 Str*
// -----------------------------------------------------------------------------
LFUNC pr_enc
    ENTER 1
    mov  x19, x0
    add  x0, x19, #STR_DATA
    ADR_L x1, e_plain
    bl   strcmp
    mov  w9, #PENC_PLAIN
    mov  x10, #5
    cbz  w0, 1f
    add  x0, x19, #STR_DATA
    ADR_L x1, e_dict
    bl   strcmp
    mov  w9, #PENC_DICT
    mov  x10, #4
    cbz  w0, 1f
    add  x0, x19, #STR_DATA
    ADR_L x1, e_rle
    bl   strcmp
    mov  w9, #PENC_RLE
    mov  x10, #3
    cbnz w0, 2f
1:  ldr  x11, [x19, #STR_LEN]       // no embedded NUL ("PLAIN\u0000x")
    cmp  x11, x10
    b.ne 2f
    mov  w0, w9
    LEAVE 1
2:  mov  w0, #ERR_STORAGE_VERSION
    ADR_L x1, m_encver
    add  x2, x19, #STR_DATA
    ldr  x3, [x19, #STR_LEN]
    bl   pq_raise_s
ENDF pr_enc

// -----------------------------------------------------------------------------
// pr_min_bytes(w0 kind, w1 enc, x2 n, x3 nulls) -> x0 lower bound of the
// chunk length (saturates at 2^63), used to reject absurd row counts before
// anything is allocated.                                            (leaf)
// -----------------------------------------------------------------------------
LFUNC pr_min_bytes
    mov  x9, #0                     // validity bitmap
    cbz  x3, 1f
    add  x9, x2, #7
    lsr  x9, x9, #3
1:  lsr  x10, x2, #56
    cbnz x10, 8f
    cmp  w1, #PENC_RLE
    b.ne 2f
    mov  x10, #4
    cbz  x2, 7f
    mov  x10, #16
    b    7f
2:  cmp  w1, #PENC_DICT
    b.ne 3f
    lsl  x10, x2, #2
    add  x10, x10, #8
    b    7f
3:  cmp  w0, #T_BOOL
    b.ne 4f
    add  x10, x2, #7
    lsr  x10, x10, #3
    b    7f
4:  cmp  w0, #T_DATE
    b.ne 5f
    lsl  x10, x2, #2
    b    7f
5:  cmp  w0, #T_STR
    b.ne 6f
    lsl  x10, x2, #2
    add  x10, x10, #4
    b    7f
6:  lsl  x10, x2, #3
7:  add  x0, x9, x10
    ret
8:  mov  x0, #1
    lsl  x0, x0, #63
    ret
ENDF pr_min_bytes

// -----------------------------------------------------------------------------
// pr_groups(x0 root): validate the row group / chunk metadata into chunk
// descriptors (RD_CKS, RD_GN, RD_NG).
// Registers: x19 ctx, x20 group elements, x21 ng, x22 g, x23 descriptor,
//            x24 rows so far, x25 rows of the group, x26 chunk elements,
//            x27 c, x28 chunk object
// -----------------------------------------------------------------------------
LFUNC pr_groups
    ENTER 5
    ADR_L x19, g_pr
    ADR_L x1, k_rgs
    mov  w2, #J_ARR
    bl   pr_req
    ldr  w21, [x0, #JN_COUNT]
    ldr  x20, [x0, #JN_PTR]
    str  x21, [x19, #RD_NG]
    lsl  x0, x21, #3
    add  x0, x0, #8
    bl   arena_alloc
    str  x0, [x19, #RD_GN]
    ldr  x9, [x19, #RD_NCOLS]       // ng * ncols chunk objects ("{}" at
    umulh x10, x21, x9              // least) must fit in the metadata
    cbnz x10, pr_bad_meta
    mul  x0, x21, x9
    ldr  x10, [x19, #RD_SIZE]
    cmp  x0, x10
    b.hi pr_bad_meta
    mov  x9, #PCK_SIZE
    mul  x0, x0, x9
    add  x0, x0, #16
    bl   arena_alloc
    mov  x23, x0
    str  x23, [x19, #RD_CKS]
    mov  x24, #0
    mov  x22, #0
1:  cmp  x22, x21
    b.hs 8f
    ldr  x28, [x20, x22, lsl #3]
    ldr  w9, [x28, #JN_TYPE]
    cmp  w9, #J_OBJ
    b.ne pr_bad_meta
    mov  x0, x28
    ADR_L x1, k_rowcount
    mov  w2, #J_NUM
    bl   pr_req
    bl   pr_uint
    mov  x25, x0
    ldr  x9, [x19, #RD_GN]
    str  x25, [x9, x22, lsl #3]
    adds x24, x24, x25
    b.cs pr_bad_meta
    ldr  x9, [x19, #RD_NROWS]
    cmp  x24, x9
    b.hi pr_bad_meta
    mov  x0, x28
    ADR_L x1, k_chunks
    mov  w2, #J_ARR
    bl   pr_req
    ldr  w9, [x0, #JN_COUNT]
    ldr  x10, [x19, #RD_NCOLS]
    cmp  x9, x10
    b.ne pr_bad_meta                // exactly one chunk per column
    ldr  x26, [x0, #JN_PTR]
    mov  x27, #0
2:  ldr  x9, [x19, #RD_NCOLS]
    cmp  x27, x9
    b.hs 7f
    ldr  x28, [x26, x27, lsl #3]
    ldr  w9, [x28, #JN_TYPE]
    cmp  w9, #J_OBJ
    b.ne pr_bad_meta
    // encoding first: an unknown name is a version problem
    mov  x0, x28
    ADR_L x1, k_encoding
    mov  w2, #J_STR
    bl   pr_req
    ldr  x0, [x0, #JN_PTR]
    bl   pr_enc
    str  w0, [x23, #PCK_ENC]
    ldr  x9, [x19, #RD_TYPES]
    ldr  w9, [x9, x27, lsl #2]
    and  w9, w9, #T_KIND_MASK
    cmp  w0, #PENC_DICT
    b.ne 3f
    cmp  w9, #T_STR                 // DICT: STRING only
    b.ne pr_bad_meta
3:  cmp  w0, #PENC_RLE
    b.ne 4f
    cmp  w9, #T_STR                 // RLE: not FLOAT64 / STRING
    b.eq pr_bad_meta
    cmp  w9, #T_FLOAT
    b.eq pr_bad_meta
4:  mov  x0, x28
    ADR_L x1, k_offset
    mov  w2, #J_NUM
    bl   pr_req
    bl   pr_uint
    str  x0, [x23, #PCK_OFF]
    mov  x0, x28
    ADR_L x1, k_length
    mov  w2, #J_NUM
    bl   pr_req
    bl   pr_uint
    str  x0, [x23, #PCK_LEN]
    mov  x0, x28
    ADR_L x1, k_crc32
    mov  w2, #J_NUM
    bl   pr_req
    bl   pr_uint
    lsr  x9, x0, #32
    cbnz x9, pr_bad_meta
    str  w0, [x23, #PCK_CRC]
    mov  x0, x28
    ADR_L x1, k_nulls
    mov  w2, #J_NUM
    bl   pr_req
    bl   pr_uint
    cmp  x0, x25
    b.hi pr_bad_meta
    str  x0, [x23, #PCK_NULLS]
    // 8 <= offset, offset + length <= metadata start
    ldr  x9, [x23, #PCK_OFF]
    ldr  x10, [x23, #PCK_LEN]
    ldr  x11, [x19, #RD_MSTART]
    cmp  x9, #8
    b.lo pr_bad_bounds
    cmp  x9, x11
    b.hi pr_bad_bounds
    sub  x11, x11, x9
    cmp  x10, x11
    b.hi pr_bad_bounds
    // the length must at least hold n values
    ldr  x9, [x19, #RD_TYPES]
    ldr  w0, [x9, x27, lsl #2]
    and  w0, w0, #T_KIND_MASK
    ldr  w1, [x23, #PCK_ENC]
    mov  x2, x25
    ldr  x3, [x23, #PCK_NULLS]
    bl   pr_min_bytes
    ldr  x10, [x23, #PCK_LEN]
    cmp  x0, x10
    b.hi pr_bad_chunk
    mov  x0, x28
    ADR_L x1, k_min
    bl   pr_opt
    str  x0, [x23, #PCK_MIN]
    mov  x0, x28
    ADR_L x1, k_max
    bl   pr_opt
    str  x0, [x23, #PCK_MAX]
    add  x23, x23, #PCK_SIZE
    add  x27, x27, #1
    b    2b
7:  add  x22, x22, #1
    b    1b
8:  ldr  x9, [x19, #RD_NROWS]
    cmp  x24, x9
    b.ne pr_bad_meta                // row_count = sum of the groups
    LEAVE 5
ENDF pr_groups

// -----------------------------------------------------------------------------
// pr_indexes(x0 root): optional "indexes" => RD_XS / RD_NXS. Each entry
// names an existing column (case-insensitive) and a kind HASH / BTREE;
// index names are non-empty and unique.
// Registers: x19 ctx, x20 elements, x21 n, x22 i, x23 XS*, x24 entry,
//            x25 j / column, x26 Str*
// -----------------------------------------------------------------------------
LFUNC pr_indexes
    ENTER 4
    ADR_L x19, g_pr
    str  xzr, [x19, #RD_NXS]
    str  xzr, [x19, #RD_XS]
    ADR_L x1, k_indexes
    bl   pr_opt
    cbz  x0, 9f
    ldr  w9, [x0, #JN_TYPE]
    cmp  w9, #J_ARR
    b.ne pr_bad_meta
    ldr  w21, [x0, #JN_COUNT]
    ldr  x20, [x0, #JN_PTR]
    mov  x9, #XS_SIZE
    mul  x0, x21, x9
    add  x0, x0, #8
    bl   arena_alloc
    mov  x23, x0
    str  x23, [x19, #RD_XS]
    str  x21, [x19, #RD_NXS]
    mov  x22, #0
1:  cmp  x22, x21
    b.hs 9f
    ldr  x24, [x20, x22, lsl #3]
    ldr  w9, [x24, #JN_TYPE]
    cmp  w9, #J_OBJ
    b.ne pr_bad_meta
    mov  x9, #XS_SIZE
    madd x23, x22, x9, x23          // x23 = &specs[i] (reset below)
    // name
    mov  x0, x24
    ADR_L x1, k_name
    mov  w2, #J_STR
    bl   pr_req
    ldr  x26, [x0, #JN_PTR]
    ldr  x9, [x26, #STR_LEN]
    cbz  x9, pr_bad_meta
    str  x26, [x23, #XS_NAME]
    ldr  x25, [x19, #RD_XS]         // unique among earlier entries
2:  cmp  x25, x23
    b.hs 3f
    ldr  x1, [x25, #XS_NAME]
    mov  x0, x26
    bl   str_ieq
    cbnz w0, pr_bad_meta
    add  x25, x25, #XS_SIZE
    b    2b
3:  // column
    mov  x0, x24
    ADR_L x1, k_column
    mov  w2, #J_STR
    bl   pr_req
    ldr  x26, [x0, #JN_PTR]
    mov  x25, #0
4:  ldr  x9, [x19, #RD_NCOLS]
    cmp  x25, x9
    b.hs pr_bad_meta                // unknown column
    ldr  x9, [x19, #RD_NAMES]
    ldr  x1, [x9, x25, lsl #3]
    mov  x0, x26
    bl   str_ieq
    cbnz w0, 5f
    add  x25, x25, #1
    b    4b
5:  str  x25, [x23, #XS_COL]
    // kind
    mov  x0, x24
    ADR_L x1, k_kind
    mov  w2, #J_STR
    bl   pr_req
    ldr  x26, [x0, #JN_PTR]
    mov  x0, x26
    ADR_L x1, x_hash
    bl   str_ieq_c
    mov  w9, #IXK_HASH
    cbnz w0, 6f
    mov  x0, x26
    ADR_L x1, x_btree
    bl   str_ieq_c
    mov  w9, #IXK_BTREE
    cbz  w0, pr_bad_meta
6:  str  w9, [x23, #XS_KIND]
    ldr  x23, [x19, #RD_XS]
    add  x22, x22, #1
    b    1b
9:  LEAVE 4
ENDF pr_indexes

// -----------------------------------------------------------------------------
// pr_build(): allocate the table (g_pending_table), its columns and row
// group descriptors.
// Registers: x19 ctx, x20 table, x21 arena, x22 i, x23 Column* / RowGroup*,
//            x24 nrows, x25 first row
// -----------------------------------------------------------------------------
LFUNC pr_build
    ENTER 4
    ADR_L x19, g_pr
    ldr  x24, [x19, #RD_NROWS]
    LDR_G x9, g_max_table_rows
    cmp  x24, x9
    b.ls 1f
    RAISE ERR_RESOURCE_LIMIT, "PQCF table exceeds --max-table-rows"
1:  mov  x0, #1
    mov  x1, #TBL_SIZE
    bl   calloc
    cbnz x0, 2f
    RAISE ERR_RESOURCE_LIMIT, "out of memory"
2:  mov  x20, x0
    ADR_L x9, g_pending_table
    str  x20, [x9]
    str  x20, [x19, #RD_TBL]
    add  x21, x20, #TBL_ARENA
    ldr  x9, [x19, #RD_NCOLS]
    str  x9, [x20, #TBL_NCOLS]
    str  x24, [x20, #TBL_NROWS]
    mov  w9, #LAYOUT_COLUMN
    str  w9, [x20, #TBL_LAYOUT]
    // columns
    mov  x0, x21
    ldr  x1, [x19, #RD_NCOLS]
    lsl  x1, x1, #5
    bl   arena_alloc_in
    str  x0, [x20, #TBL_COLS]
    mov  x22, #0
3:  ldr  x9, [x19, #RD_NCOLS]
    cmp  x22, x9
    b.hs 4f
    ldr  x23, [x20, #TBL_COLS]
    add  x23, x23, x22, lsl #5
    ldr  x9, [x19, #RD_NAMES]
    ldr  x9, [x9, x22, lsl #3]
    mov  x0, x21
    add  x1, x9, #STR_DATA
    ldr  x2, [x9, #STR_LEN]
    bl   str_new_in
    str  x0, [x23, #COL_NAME]
    ldr  x9, [x19, #RD_TYPES]
    ldr  w9, [x9, x22, lsl #2]
    str  w9, [x23, #COL_TYPE]
    mov  w9, #CENC_PLAIN
    str  w9, [x23, #COL_ENC]
    str  xzr, [x23, #COL_NULLS]
    mov  x0, x21
    lsl  x1, x24, #3
    add  x1, x1, #8
    bl   arena_alloc_in
    str  x0, [x23, #COL_DATA]
    add  x22, x22, #1
    b    3b
4:  // row groups
    ldr  x9, [x19, #RD_NG]
    str  x9, [x20, #TBL_NRG]
    str  xzr, [x20, #TBL_RGS]
    cbz  x9, 9f
    mov  x0, x21
    lsl  x1, x9, #5
    bl   arena_alloc_in
    str  x0, [x20, #TBL_RGS]
    mov  x25, #0
    mov  x22, #0
5:  ldr  x9, [x19, #RD_NG]
    cmp  x22, x9
    b.hs 9f
    ldr  x23, [x20, #TBL_RGS]
    add  x23, x23, x22, lsl #5
    str  x25, [x23, #RG_START]
    ldr  x9, [x19, #RD_GN]
    ldr  x9, [x9, x22, lsl #3]
    str  x9, [x23, #RG_NROWS]
    add  x25, x25, x9
    mov  x0, x21
    ldr  x1, [x19, #RD_NCOLS]
    lsl  x1, x1, #5
    bl   arena_alloc_in
    str  x0, [x23, #RG_CHUNKS]
    mov  w1, #0
    ldr  x2, [x19, #RD_NCOLS]
    lsl  x2, x2, #5
    bl   memset
    add  x22, x22, #1
    b    5b
9:  LEAVE 4
ENDF pr_build

// -----------------------------------------------------------------------------
// pr_decode(): decode every chunk and record its statistics.
// Registers: x19 ctx, x20 g, x21 c, x22 first row, x23 descriptor,
//            x24 rows of the group, x25 ChunkStat* of the group
// -----------------------------------------------------------------------------
LFUNC pr_decode
    ENTER 4
    ADR_L x19, g_pr
    ldr  x23, [x19, #RD_CKS]
    mov  x22, #0
    mov  x20, #0
1:  ldr  x9, [x19, #RD_NG]
    cmp  x20, x9
    b.hs 9f
    ldr  x9, [x19, #RD_GN]
    ldr  x24, [x9, x20, lsl #3]
    ldr  x9, [x19, #RD_TBL]
    ldr  x9, [x9, #TBL_RGS]
    add  x9, x9, x20, lsl #5
    ldr  x25, [x9, #RG_CHUNKS]
    mov  x21, #0
2:  ldr  x9, [x19, #RD_NCOLS]
    cmp  x21, x9
    b.hs 3f
    mov  x0, x23
    mov  x1, x21
    mov  x2, x22
    mov  x3, x24
    bl   pr_chunk
    mov  x0, x23
    add  x1, x25, x21, lsl #5
    ldr  x9, [x19, #RD_TYPES]
    ldr  w2, [x9, x21, lsl #2]
    bl   pr_minmax
    add  x23, x23, #PCK_SIZE
    add  x21, x21, #1
    b    2b
3:  add  x22, x22, x24
    add  x20, x20, #1
    b    1b
9:  LEAVE 4
ENDF pr_decode

// -----------------------------------------------------------------------------
// pr_chunk(x0 descriptor, x1 col, x2 first row, x3 n): verify the CRC and
// decode one chunk into the column's payload vector / null bitmap.
// Registers: x19 ctx, x20 descriptor, x21 Column*, x22 first row, x23 n,
//            x24 chunk bytes, x25 chunk length, x26 validity bitmap bytes,
//            w27 type, x28 payload base (COL_DATA + 8 * first row)
// -----------------------------------------------------------------------------
LFUNC pr_chunk
    ENTER 5
    ADR_L x19, g_pr
    mov  x20, x0
    mov  x22, x2
    mov  x23, x3
    ldr  x9, [x19, #RD_TBL]
    ldr  x9, [x9, #TBL_COLS]
    add  x21, x9, x1, lsl #5
    ldr  w27, [x21, #COL_TYPE]
    ldr  x28, [x21, #COL_DATA]
    add  x28, x28, x22, lsl #3
    ldr  x9, [x19, #RD_BASE]
    ldr  x10, [x20, #PCK_OFF]
    add  x24, x9, x10
    ldr  x25, [x20, #PCK_LEN]
    mov  x0, x24
    mov  x1, x25
    bl   crc32
    ldr  w9, [x20, #PCK_CRC]
    cmp  w0, w9
    b.ne pr_bad_crc
    // validity bitmap (present iff null_count > 0)
    str  xzr, [x19, #RD_VBM]
    mov  x26, #0
    ldr  x9, [x20, #PCK_NULLS]
    cbz  x9, 5f
    add  x26, x23, #7
    lsr  x26, x26, #3
    cmp  x26, x25
    b.hi pr_bad_chunk
    str  x24, [x19, #RD_VBM]
    ldr  x0, [x21, #COL_NULLS]
    cbnz x0, 2f
    ldr  x9, [x19, #RD_TBL]         // first NULL of the column: bitmap
    ldr  x1, [x9, #TBL_NROWS]
    add  x1, x1, #7
    lsr  x1, x1, #3
    add  x1, x1, #8
    str  x1, [sp, #-16]!
    add  x0, x9, #TBL_ARENA
    bl   arena_alloc_in
    ldr  x2, [sp], #16
    str  x0, [x21, #COL_NULLS]
    mov  w1, #0
    bl   memset
    ldr  x0, [x21, #COL_NULLS]
2:  mov  x9, #0                     // i
    mov  x10, #0                    // zero bits seen
3:  cmp  x9, x23
    b.hs 4f
    lsr  x11, x9, #3
    ldrb w12, [x24, x11]
    and  x13, x9, #7
    lsr  w12, w12, w13
    tbnz w12, #0, 31f
    add  x10, x10, #1               // NULL: set column bit first + i
    add  x11, x22, x9
    lsr  x12, x11, #3
    ldrb w13, [x0, x12]
    and  x14, x11, #7
    mov  w15, #1
    lsl  w15, w15, w14
    orr  w13, w13, w15
    strb w13, [x0, x12]
31: add  x9, x9, #1
    b    3b
4:  ldr  x9, [x20, #PCK_NULLS]
    cmp  x10, x9
    b.ne pr_bad_chunk
5:  // values section
    add  x0, x24, x26
    sub  x1, x25, x26
    mov  x2, x23
    mov  x3, x28
    mov  w4, w27
    ldr  w9, [x20, #PCK_ENC]
    cmp  w9, #PENC_RLE
    b.ne 6f
    bl   pr_rle
    b    8f
6:  cmp  w9, #PENC_DICT
    b.ne 7f
    bl   pr_dict
    b    8f
7:  bl   pr_plain
8:  mov  x0, x28
    mov  x1, x23
    mov  w2, w27
    bl   pr_check_values
    LEAVE 5
ENDF pr_chunk

// -----------------------------------------------------------------------------
// pr_plain(x0 src, x1 bytes, x2 n, x3 out u64*, w4 type): PLAIN values;
// the section must be exactly as long as n values need.
// Registers: x19 src, x20 bytes, x21 n, x22 out, x23 i, x24 string bytes,
//            x25 previous offset, x26 table arena
// -----------------------------------------------------------------------------
LFUNC pr_plain
    ENTER 4
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x22, x3
    and  w4, w4, #T_KIND_MASK
    cmp  w4, #T_BOOL
    b.eq 1f
    cmp  w4, #T_DATE
    b.eq 3f
    cmp  w4, #T_STR
    b.eq 5f
    lsr  x9, x20, #3                // 8-byte values
    cmp  x21, x9
    b.hi pr_bad_chunk
    cmp  x20, x21, lsl #3
    b.ne pr_bad_chunk
    mov  x0, x22
    mov  x1, x19
    lsl  x2, x21, #3
    bl   memcpy
    LEAVE 4
1:  add  x9, x21, #7                // BOOLEAN bitmap
    lsr  x9, x9, #3
    cmp  x9, x20
    b.ne pr_bad_chunk
    mov  x23, #0
2:  cmp  x23, x21
    b.hs 9f
    lsr  x9, x23, #3
    ldrb w10, [x19, x9]
    and  x11, x23, #7
    lsr  w10, w10, w11
    and  x10, x10, #1
    str  x10, [x22, x23, lsl #3]
    add  x23, x23, #1
    b    2b
3:  lsr  x9, x20, #2                // DATE: i32
    cmp  x21, x9
    b.hi pr_bad_chunk
    cmp  x20, x21, lsl #2
    b.ne pr_bad_chunk
    mov  x23, #0
4:  cmp  x23, x21
    b.hs 9f
    ldrsw x10, [x19, x23, lsl #2]
    str  x10, [x22, x23, lsl #3]
    add  x23, x23, #1
    b    4b
5:  // STRING: (n+1) u32 offsets then the bytes
    lsr  x9, x20, #2
    add  x10, x21, #1
    cmp  x10, x9
    b.hi pr_bad_chunk
    add  x24, x19, x10, lsl #2      // bytes
    sub  x20, x20, x10, lsl #2      // byte count
    ldr  w9, [x19]
    cbnz w9, pr_bad_chunk           // offsets[0] = 0
    ldr  w9, [x19, x21, lsl #2]
    cmp  x9, x20
    b.ne pr_bad_chunk               // offsets[n] = byte count
    ADR_L x9, g_pr
    ldr  x26, [x9, #RD_TBL]
    add  x26, x26, #TBL_ARENA
    mov  x25, #0
    mov  x23, #0
6:  cmp  x23, x21
    b.hs 9f
    add  x9, x23, #1
    ldr  w9, [x19, x9, lsl #2]
    cmp  x9, x25
    b.lo pr_bad_chunk               // decreasing
    cmp  x9, x20
    b.hi pr_bad_chunk               // out of range
    ADR_L x10, g_pr
    ldr  x10, [x10, #RD_VBM]
    ISNULL_AT 11, 10, 23, 12
    cbz  w11, 7f
    str  xzr, [x22, x23, lsl #3]
    mov  x25, x9
    b    8f
7:  str  x9, [sp, #-16]!
    add  x0, x24, x25
    sub  x1, x9, x25
    bl   utf8_valid
    cbz  w0, pr_bad_value
    ldr  x9, [sp]
    mov  x0, x26
    add  x1, x24, x25
    sub  x2, x9, x25
    bl   str_new_in
    str  x0, [x22, x23, lsl #3]
    ldr  x25, [sp], #16
8:  add  x23, x23, #1
    b    6b
9:  LEAVE 4
ENDF pr_plain

// -----------------------------------------------------------------------------
// pr_dict(x0 src, x1 bytes, x2 n, x3 out u64*): DICT STRING values:
// u32 D, (D+1) u32 offsets, dictionary bytes, n u32 codes (exact size).
// Registers: x19 offsets, x20 D, x21 n, x22 out, x23 i, x24 dictionary
//            bytes, x25 byte count, x26 codes, x27 Str** entries,
//            x28 table arena
// -----------------------------------------------------------------------------
LFUNC pr_dict
    ENTER 5
    mov  x21, x2
    mov  x22, x3
    cmp  x1, #4
    b.lo pr_bad_chunk
    ldr  w20, [x0]
    add  x19, x0, #4
    sub  x1, x1, #4
    lsr  x9, x1, #2                 // offsets: (D+1) * 4 bytes
    add  x10, x20, #1
    cmp  x10, x9
    b.hi pr_bad_chunk
    add  x24, x19, x10, lsl #2
    sub  x1, x1, x10, lsl #2
    ldr  w9, [x19]
    cbnz w9, pr_bad_chunk
    ldr  w25, [x19, x20, lsl #2]    // dictionary byte count
    cmp  x25, x1
    b.hi pr_bad_chunk
    add  x26, x24, x25
    sub  x1, x1, x25
    lsr  x9, x1, #2                 // then exactly n codes
    cmp  x21, x9
    b.hi pr_bad_chunk
    cmp  x1, x21, lsl #2
    b.ne pr_bad_chunk
    ADR_L x9, g_pr
    ldr  x28, [x9, #RD_TBL]
    add  x28, x28, #TBL_ARENA
    lsl  x0, x20, #3
    add  x0, x0, #8
    bl   arena_alloc
    mov  x27, x0
    mov  x23, #0                    // entries
1:  cmp  x23, x20
    b.hs 3f
    ldr  w9, [x19, x23, lsl #2]
    add  x10, x23, #1
    ldr  w10, [x19, x10, lsl #2]
    cmp  x10, x9
    b.lo pr_bad_chunk
    cmp  x10, x25
    b.hi pr_bad_chunk
    sub  x10, x10, x9
    stp  x9, x10, [sp, #-16]!
    add  x0, x24, x9
    mov  x1, x10
    bl   utf8_valid
    cbz  w0, pr_bad_value
    ldp  x9, x10, [sp], #16
    mov  x0, x28
    add  x1, x24, x9
    mov  x2, x10
    bl   str_new_in
    str  x0, [x27, x23, lsl #3]
    add  x23, x23, #1
    b    1b
3:  ADR_L x9, g_pr                  // codes
    ldr  x10, [x9, #RD_VBM]
    mov  x23, #0
4:  cmp  x23, x21
    b.hs 9f
    ISNULL_AT 11, 10, 23, 12
    cbz  w11, 5f
    str  xzr, [x22, x23, lsl #3]
    b    6f
5:  ldr  w9, [x26, x23, lsl #2]
    cmp  x9, x20
    b.hs pr_bad_value               // code >= D
    ldr  x9, [x27, x9, lsl #3]
    str  x9, [x22, x23, lsl #3]
6:  add  x23, x23, #1
    b    4b
9:  LEAVE 5
ENDF pr_dict

// -----------------------------------------------------------------------------
// pr_rle(x0 src, x1 bytes, x2 n, x3 out u64*): u32 R, R x {i64, u32} runs
// (exact size, run lengths >= 1 summing to n).                      (leaf)
// Registers: x9 R, x10 cursor, x11 row, x12 value, x13 length, x14 run
// -----------------------------------------------------------------------------
LFUNC pr_rle
    cmp  x1, #4
    b.lo pr_bad_chunk
    ldr  w9, [x0]
    sub  x1, x1, #4
    mov  x10, #12
    mul  x10, x9, x10
    cmp  x10, x1
    b.ne pr_bad_chunk
    add  x10, x0, #4
    mov  x11, #0
1:  cbz  x9, 4f
    ldr  x12, [x10]
    ldr  w13, [x10, #8]
    add  x10, x10, #12
    cbz  w13, pr_bad_chunk
    sub  x14, x2, x11
    cmp  x13, x14
    b.hi pr_bad_chunk               // runs exceed n
2:  str  x12, [x3, x11, lsl #3]
    add  x11, x11, #1
    subs w13, w13, #1
    b.ne 2b
    sub  x9, x9, #1
    b    1b
4:  cmp  x11, x2
    b.ne pr_bad_chunk
    ret
ENDF pr_rle

// -----------------------------------------------------------------------------
// pr_check_values(x0 out u64*, x1 n, w2 type): set NULL payloads to 0 and
// check every non-null value (§3.4): BOOLEAN 0/1, DECIMAL within precision,
// DATE / TIMESTAMP range, finite FLOAT64.                           (leaf)
// Registers: x9 i, x10 validity bitmap, w11 null flag, x12 tmp, x13 value,
//            x14/x15 bounds, w16 kind
// -----------------------------------------------------------------------------
LFUNC pr_check_values
    ADR_L x10, g_pr
    ldr  x10, [x10, #RD_VBM]
    and  w16, w2, #T_KIND_MASK
    mov  x14, #0
    mov  x15, #0
    cmp  w16, #T_BOOL
    b.ne 1f
    mov  x15, #1
1:  cmp  w16, #T_DEC
    b.ne 2f
    ADR_L x12, pq_pow10
    ubfx w13, w2, #T_PREC_SHIFT, #8
    cmp  w13, #18
    b.hi pr_bad_value
    ldr  x15, [x12, x13, lsl #3]    // |v| < 10^p
2:  cmp  w16, #T_DATE
    b.ne 3f
    ldr  x14, =DATE_MIN
    ldr  x15, =DATE_MAX
3:  cmp  w16, #T_TS
    b.ne 4f
    ldr  x14, =TS_MIN
    ldr  x15, =TS_MAX
4:  mov  x9, #0
5:  cmp  x9, x1
    b.hs 9f
    ISNULL_AT 11, 10, 9, 12
    cbz  w11, 6f
    str  xzr, [x0, x9, lsl #3]
    b    8f
6:  ldr  x13, [x0, x9, lsl #3]
    cmp  w16, #T_BOOL
    b.ne 61f
    cmp  x13, x15
    b.hi pr_bad_value
    b    8f
61: cmp  w16, #T_DEC
    b.ne 62f
    cmp  x13, #0
    cneg x13, x13, lt
    cmp  x13, x15
    b.hs pr_bad_value
    b    8f
62: cmp  w16, #T_FLOAT
    b.ne 63f
    ubfx x13, x13, #52, #11
    cmp  x13, #0x7ff
    b.eq pr_bad_value
    b    8f
63: cmp  w16, #T_DATE
    b.eq 64f
    cmp  w16, #T_TS
    b.ne 8f
64: cmp  x13, x14
    b.lt pr_bad_value
    cmp  x13, x15
    b.gt pr_bad_value
8:  add  x9, x9, #1
    b    5b
9:  ret
ENDF pr_check_values

// -----------------------------------------------------------------------------
// pr_minmax(x0 descriptor, x1 ChunkStat*, w2 type): CK_NULLS and, when both
// "min" and "max" are present and decode as values of the column type,
// CK_MIN / CK_MAX with CK_HASMM = 1 (statistics are advisory: undecodable
// ones are ignored).
// Registers: x19 descriptor, x20 ChunkStat*, w21 type, x22 min payload
// -----------------------------------------------------------------------------
LFUNC pr_minmax
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    mov  w21, w2
    ldr  x9, [x19, #PCK_NULLS]
    str  x9, [x20, #CK_NULLS]
    str  wzr, [x20, #CK_HASMM]
    ldr  x0, [x19, #PCK_MIN]
    cbz  x0, 9f
    ldr  x9, [x19, #PCK_MAX]
    cbz  x9, 9f
    mov  w1, w21
    bl   pr_statval
    cbnz w1, 9f
    mov  x22, x0
    ldr  x0, [x19, #PCK_MAX]
    mov  w1, w21
    bl   pr_statval
    cbnz w1, 9f
    str  x22, [x20, #CK_MIN]
    str  x0, [x20, #CK_MAX]
    mov  w9, #1
    str  w9, [x20, #CK_HASMM]
9:  LEAVE 2
ENDF pr_minmax

// -----------------------------------------------------------------------------
// pr_statval(x0 JNode*, w1 type) -> x0 payload, w1 status (0 ok)
// JSON value per types.md §9 => payload (STRING: Str* in the table arena).
// Registers: x19 node, w20 kind / type
// -----------------------------------------------------------------------------
LFUNC pr_statval
    ENTER 2
    mov  x19, x0
    mov  w20, w1
    and  w9, w1, #T_KIND_MASK
    ldr  w10, [x19, #JN_TYPE]
    ldr  x11, [x19, #JN_PTR]
    cmp  w9, #T_BOOL
    b.ne 2f
    mov  x0, #1
    cmp  w10, #J_TRUE
    b.eq 8f
    mov  x0, #0
    cmp  w10, #J_FALSE
    b.eq 8f
    b    7f
2:  cmp  w9, #T_INT
    b.ne 3f
    cmp  w10, #J_NUM
    b.ne 7f
    add  x0, x11, #STR_DATA
    ldr  x1, [x11, #STR_LEN]
    bl   parse_int64
    b    9f
3:  cmp  w9, #T_FLOAT
    b.ne 4f
    cmp  w10, #J_NUM
    b.ne 7f
    add  x0, x11, #STR_DATA
    ldr  x1, [x11, #STR_LEN]
    bl   parse_float
    fmov x0, d0
    b    9f
4:  cmp  w10, #J_STR                // all other kinds are JSON strings
    b.ne 7f
    add  x0, x11, #STR_DATA
    ldr  x1, [x11, #STR_LEN]
    cmp  w9, #T_DEC
    b.ne 5f
    ubfx w2, w20, #T_PREC_SHIFT, #8
    ubfx w3, w20, #T_SCALE_SHIFT, #8
    mov  w4, #0
    bl   parse_decimal
    b    9f
5:  cmp  w9, #T_DATE
    b.ne 6f
    bl   parse_date
    b    9f
6:  cmp  w9, #T_TS
    b.ne 61f
    mov  w2, #0
    bl   parse_timestamp
    b    9f
61: mov  x2, x1                     // STRING
    mov  x1, x0
    ADR_L x9, g_pr
    ldr  x0, [x9, #RD_TBL]
    add  x0, x0, #TBL_ARENA
    bl   str_new_in
8:  mov  w1, #0
    b    9f
7:  mov  w1, #1
9:  LEAVE 2
ENDF pr_statval

    .section .rodata
    .p2align 3
pq_pow10:
    .quad 1, 10, 100, 1000, 10000, 100000, 1000000, 10000000, 100000000
    .quad 1000000000, 10000000000, 100000000000, 1000000000000
    .quad 10000000000000, 100000000000000, 1000000000000000
    .quad 10000000000000000, 100000000000000000, 1000000000000000000
    .text

    NOTE_GNU_STACK
