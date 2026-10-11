// =============================================================================
// test_pqcf.S — unit tests for src/pqcf.S (standalone program).
//
//   * CRC-32 check value ("123456789" = 0xCBF43926) with the CRC32
//     instructions and with the table fallback, and incremental updates;
//   * utf8_valid on valid / invalid sequences;
//   * save -> load round trips of an in-memory table with every column type
//     and NULLs, for every forced encoding (auto/plain/dict/rle), several row
//     group sizes, read and mmap: every cell must survive, and every row
//     group's chunk statistics must be exact (null counts, min/max);
//   * damaged files (chunk byte flip, truncation, empty file, header version
//     2) raise STORAGE_CORRUPT / STORAGE_VERSION_UNSUPPORTED, a missing file
//     NOT_FOUND, saving into a missing directory IO_ERROR — and no temporary
//     file is left behind.
// Files live in a fresh mkdtemp directory under /tmp (g_data_dir), removed
// at the end. Errors are caught with setjmp on g_jmpbuf.
// Prints one line per failure; exit status 0 only if every case passes.
// =============================================================================
#include "pq.inc"
#include "frame.inc"

#define NROWS      23
#define NCOLS      8
#define DATE_MIN   -719162
#define DATE_MAX   2932896
#define TS_MIN     -62135596800000000
#define TS_MAX     253402300799999999

// Static Str object: STRC label, "text"
.macro STRC label, text
    .p2align 3
\label: .quad 9f - 8f
8:  .ascii "\text"
9:  .byte 0
.endm

    .bss
    .p2align 4
tbl:        .skip TBL_SIZE          // the in-memory source table
failures:   .skip 8
passes:     .skip 8
statbuf:    .skip 128

    .data
dirtmpl:    .asciz "/tmp/pqcf_test_XXXXXX"
    .p2align 3
col_names:  .quad n_b, n_i, n_d, n_f, n_s, n_dt, n_ts, n_c
col_types:  .word T_BOOL, T_INT, DEC_TYPE(10,2), T_FLOAT, T_STR, T_DATE, T_TS, T_STR
strtab:     .quad s_alpha, s_empty, s_uni, s_beta, s_punct
strtab2:    .quad s_red, s_green
rg_sizes:   .quad 0, 3, 7, 23, 1000

    .section .rodata
n_b:  .asciz "b"
n_i:  .asciz "i"
n_d:  .asciz "d"
n_f:  .asciz "f"
n_s:  .asciz "s"
n_dt: .asciz "dt"
n_ts: .asciz "ts"
n_c:  .asciz "c"
s_alpha: .asciz "alpha"
s_empty: .asciz ""
s_uni:   .asciz "\xC3\xBCn\xC3\xAF \xE2\x82\xAC \xF0\x9F\x98\x80"
s_beta:  .asciz "beta"
s_punct: .asciz "x,y\n\"z\""
s_red:   .asciz "red"
s_green: .asciz "green"
s_check: .ascii "123456789"
    STRC p_file, "t.pqcf"
    STRC p_missing, "missing.pqcf"
    STRC p_nodir, "nodir/x.pqcf"
    STRC tname, "src"
f_fail:     .asciz "FAIL %s (enc %d, rgs %ld, mmap %d): %s\n"
f_failv:    .asciz "FAIL %s: got %ld expected %ld\n"
f_raised:   .asciz "unexpected error %d: %s"
f_sum:      .asciz "test_pqcf: %ld passed, %ld failed\n"
f_rm:       .asciz "%s/%s"
m_cells:    .asciz "cell mismatch"
m_shape:    .asciz "shape mismatch"
m_nrg:      .asciz "row group count"
m_stats:    .asciz "chunk statistics"
m_none:     .asciz ""
t_crc_hw:   .asciz "crc32 check value (default mode)"
t_crc_tab:  .asciz "crc32 check value (table mode)"
t_crc_inc:  .asciz "crc32_update continuation"
t_crc_empty: .asciz "crc32 of nothing"
t_crc_long: .asciz "crc32 table vs default on 1000 bytes"
t_utf8:     .asciz "utf8_valid case"
t_bitflip:  .asciz "chunk byte flip => STORAGE_CORRUPT"
t_trunc:    .asciz "truncated file => STORAGE_CORRUPT"
t_empty:    .asciz "empty file => STORAGE_CORRUPT"
t_version:  .asciz "header version 3 => STORAGE_VERSION_UNSUPPORTED"
t_missing:  .asciz "missing file => NOT_FOUND"
t_nodir:    .asciz "missing directory => IO_ERROR"
t_notmp:    .asciz "no temporary files left behind"
t_pending:  .asciz "failed load leaves the pending table registered"

// utf8 cases: length byte, expected, bytes
utf8_cases:
    .byte 3, 1, 'a', 'b', 'c'
    .byte 2, 1, 0xC3, 0xBC
    .byte 3, 1, 0xE2, 0x82, 0xAC
    .byte 4, 1, 0xF0, 0x9F, 0x98, 0x80
    .byte 4, 1, 0xF4, 0x8F, 0xBF, 0xBF
    .byte 1, 0, 0x80
    .byte 2, 0, 0xC0, 0xAF
    .byte 2, 0, 0xC3, 0x28
    .byte 3, 0, 0xE0, 0x80, 0x80
    .byte 3, 0, 0xED, 0xA0, 0x80
    .byte 4, 0, 0xF4, 0x90, 0x80, 0x80
    .byte 1, 0, 0xFF
    .byte 2, 0, 0xE2, 0x82
    .byte 11, 1, 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 0xC3, 0xBC
    .byte 10, 0, 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 0xC3
    .byte 0
    .text

// -----------------------------------------------------------------------------
// fail_v(x0 name, x1 got, x2 expected) / pass(): counters
// -----------------------------------------------------------------------------
LFUNC pass
    ADR_L x9, passes
    ldr  x10, [x9]
    add  x10, x10, #1
    str  x10, [x9]
    ret
ENDF pass

LFUNC expect_eq                     // x0 name, x1 got, x2 expected
    cmp  x1, x2
    b.eq pass
    ENTER 0
    mov  x3, x2
    mov  x2, x1
    mov  x1, x0
    ADR_L x0, f_failv
    bl   printf
    ADR_L x9, failures
    ldr  x10, [x9]
    add  x10, x10, #1
    str  x10, [x9]
    LEAVE 0
ENDF expect_eq

// fail_rt(x0 what, w1 enc, x2 rgs, w3 mmap, x4 detail)
LFUNC fail_rt
    ENTER 0
    mov  x5, x4
    mov  w4, w3
    mov  x3, x2
    mov  w2, w1
    mov  x1, x0
    ADR_L x0, f_fail
    bl   printf
    ADR_L x9, failures
    ldr  x10, [x9]
    add  x10, x10, #1
    str  x10, [x9]
    LEAVE 0
ENDF fail_rt

// free_pending(): free g_pending_table (left by a failed load) and the
// request arena
LFUNC free_pending
    ENTER 1
    LDR_G x19, g_pending_table
    cbz  x19, 1f
    add  x0, x19, #TBL_ARENA
    bl   arena_free
    mov  x0, x19
    bl   free
    ADR_L x9, g_pending_table
    str  xzr, [x9]
1:  ADR_L x0, g_arena
    bl   arena_free
    LEAVE 1
ENDF free_pending

// =============================================================================
// gen_value(w0 col, x1 row) -> x0 payload, x1 isnull   (strings: Str* in the
// source table's arena)
// =============================================================================
LFUNC gen_value
    ENTER 2
    mov  w19, w0
    mov  x20, x1
    mov  x1, #0
    cmp  w19, #0
    b.ne 1f
    mov  x9, #5                     // b: BOOLEAN, NULL if i%5 == 4
    udiv x10, x20, x9
    msub x10, x10, x9, x20
    cmp  x10, #4
    cset x1, eq
    mov  x9, #3
    udiv x10, x20, x9
    msub x10, x10, x9, x20
    cmp  x10, #0
    cset x0, eq
    b    9f
1:  cmp  w19, #1                    // i: INT64 i/4 - 2, NULL at 7
    b.ne 2f
    lsr  x0, x20, #2
    sub  x0, x0, #2
    cmp  x20, #7
    cset x1, eq
    b    9f
2:  cmp  w19, #2                    // d: DECIMAL(10,2), NULL if i%6 == 1
    b.ne 3f
    mov  x9, #12345
    ldr  x10, =99999
    mul  x0, x20, x9
    sub  x0, x0, x10
    mov  x9, #6
    udiv x10, x20, x9
    msub x10, x10, x9, x20
    cmp  x10, #1
    cset x1, eq
    b    9f
3:  cmp  w19, #3                    // f: FLOAT64 i * 0.25 - 1, NULL at 0
    b.ne 4f
    scvtf d0, x20
    fmov d1, #0.25
    fmul d0, d0, d1
    fmov d1, #1.0
    fsub d0, d0, d1
    fmov x0, d0
    cmp  x20, #0
    cset x1, eq
    b    9f
4:  cmp  w19, #4                    // s: STRING strtab[i%5], NULL if i%7 == 3
    b.ne 5f
    mov  x9, #5
    udiv x10, x20, x9
    msub x10, x10, x9, x20
    ADR_L x9, strtab
    ldr  x0, [x9, x10, lsl #3]
    bl   mk_str
    mov  x9, #7
    udiv x10, x20, x9
    msub x10, x10, x9, x20
    cmp  x10, #3
    cset x1, eq
    b    9f
5:  cmp  w19, #5                    // dt: DATE min / max / 19000 + i/3, NULL at 10
    b.ne 6f
    mov  x9, #3
    udiv x0, x20, x9
    mov  x9, #19000
    add  x0, x0, x9
    ldr  x9, =DATE_MIN
    cmp  x20, #0
    csel x0, x9, x0, eq
    ldr  x9, =DATE_MAX
    cmp  x20, #1
    csel x0, x9, x0, eq
    cmp  x20, #10
    cset x1, eq
    b    9f
6:  cmp  w19, #6                    // ts: TIMESTAMP min / max / ..., never NULL
    b.ne 7f
    lsr  x0, x20, #1
    ldr  x9, =1000001
    mul  x0, x0, x9
    ldr  x9, =1700000000000000
    add  x0, x0, x9
    ldr  x9, =TS_MIN
    cmp  x20, #0
    csel x0, x9, x0, eq
    ldr  x9, =TS_MAX
    cmp  x20, #1
    csel x0, x9, x0, eq
    mov  x1, #0
    b    9f
7:  mov  x9, #6                     // c: STRING red/green runs, never NULL
    udiv x10, x20, x9
    and  x10, x10, #1
    ADR_L x9, strtab2
    ldr  x0, [x9, x10, lsl #3]
    bl   mk_str
    mov  x1, #0
9:  LEAVE 2
ENDF gen_value

// mk_str(x0 cstr) -> x0 Str* in the source table's arena
LFUNC mk_str
    ENTER 1
    mov  x19, x0
    bl   strlen
    mov  x2, x0
    mov  x1, x19
    ADR_L x0, tbl + TBL_ARENA
    bl   str_new_in
    LEAVE 1
ENDF mk_str

// =============================================================================
// build_table(): the source table (8 columns, NROWS rows, plain columnar)
// Registers: x19 Column*, x20 col, x21 row, x22 arena
// =============================================================================
LFUNC build_table
    ENTER 3
    ADR_L x22, tbl + TBL_ARENA
    ADR_L x9, tbl
    ADR_L x10, tname
    str  x10, [x9, #TBL_NAME]
    mov  x10, #NCOLS
    str  x10, [x9, #TBL_NCOLS]
    mov  x10, #NROWS
    str  x10, [x9, #TBL_NROWS]
    mov  x0, x22
    mov  x1, #(NCOLS * COL_SIZE)
    bl   arena_alloc_in
    ADR_L x9, tbl
    str  x0, [x9, #TBL_COLS]
    mov  x20, #0
1:  cmp  x20, #NCOLS
    b.hs 9f
    ADR_L x9, tbl
    ldr  x19, [x9, #TBL_COLS]
    add  x19, x19, x20, lsl #5
    ADR_L x9, col_names
    ldr  x0, [x9, x20, lsl #3]
    bl   mk_str
    str  x0, [x19, #COL_NAME]
    ADR_L x9, col_types
    ldr  w9, [x9, x20, lsl #2]
    str  w9, [x19, #COL_TYPE]
    str  wzr, [x19, #COL_ENC]
    mov  x0, x22
    mov  x1, #(NROWS * 8)
    bl   arena_alloc_in
    str  x0, [x19, #COL_DATA]
    str  xzr, [x19, #COL_NULLS]
    cmp  x20, #6                    // ts / c: no NULLs, no bitmap
    b.hs 2f
    mov  x0, x22
    mov  x1, #16
    bl   arena_alloc_in
    stp  xzr, xzr, [x0]
    str  x0, [x19, #COL_NULLS]
2:  mov  x21, #0
3:  cmp  x21, #NROWS
    b.hs 5f
    mov  w0, w20
    mov  x1, x21
    bl   gen_value
    cbz  x1, 4f
    mov  x0, #0                     // NULL: payload 0, bit set
    ldr  x9, [x19, #COL_NULLS]
    lsr  x10, x21, #3
    ldrb w11, [x9, x10]
    and  x12, x21, #7
    mov  w13, #1
    lsl  w13, w13, w12
    orr  w11, w11, w13
    strb w11, [x9, x10]
4:  ldr  x9, [x19, #COL_DATA]
    str  x0, [x9, x21, lsl #3]
    add  x21, x21, #1
    b    3b
5:  add  x20, x20, #1
    b    1b
9:  LEAVE 3
ENDF build_table

// =============================================================================
// cmp_tables(x0 Table* a, x1 Table* b) -> w0 1 if every cell is equal
// Registers: x19 a, x20 b, x21 col, x22 row, x23 a payload, x24 a isnull
// =============================================================================
LFUNC cmp_tables
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    mov  x21, #0
1:  ldr  x9, [x19, #TBL_NCOLS]
    cmp  x21, x9
    b.hs 8f
    mov  x22, #0
2:  ldr  x9, [x19, #TBL_NROWS]
    cmp  x22, x9
    b.hs 7f
    mov  x0, x19
    mov  x1, x21
    mov  x2, x22
    bl   tbl_get
    mov  x23, x0
    mov  x24, x1
    mov  x0, x20
    mov  x1, x21
    mov  x2, x22
    bl   tbl_get
    cmp  x1, x24
    b.ne 9f
    cbnz x1, 6f
    ldr  x9, [x19, #TBL_COLS]
    add  x9, x9, x21, lsl #5
    ldr  w9, [x9, #COL_TYPE]
    and  w9, w9, #T_KIND_MASK
    cmp  w9, #T_STR
    b.eq 3f
    cmp  x0, x23
    b.ne 9f
    b    6f
3:  ldr  x3, [x0, #STR_LEN]
    add  x2, x0, #STR_DATA
    ldr  x1, [x23, #STR_LEN]
    add  x0, x23, #STR_DATA
    cmp  x1, x3
    b.ne 9f
    bl   bytes_cmp
    cbnz w0, 9f
6:  add  x22, x22, #1
    b    2b
7:  add  x21, x21, #1
    b    1b
8:  mov  w0, #1
    LEAVE 3
9:  mov  w0, #0
    LEAVE 3
ENDF cmp_tables

// =============================================================================
// check_stats(x0 Table*) -> w0 1 if every ChunkStat is exact: CK_NULLS = the
// NULLs of the group's rows, CK_HASMM iff a non-null value exists, and then
// CK_MIN / CK_MAX are the smallest / largest value (value_cmp).
// Registers: x19 table, x20 group, x21 col, x22 row, x23 ChunkStat*,
//            x24 null count, x25 min seen, x26 max seen, w27 type, x28 RowGroup*
// =============================================================================
LFUNC check_stats
    ENTER 5
    mov  x19, x0
    mov  x20, #0
1:  ldr  x9, [x19, #TBL_NRG]
    cmp  x20, x9
    b.hs 8f
    ldr  x28, [x19, #TBL_RGS]
    add  x28, x28, x20, lsl #5
    mov  x21, #0
2:  ldr  x9, [x19, #TBL_NCOLS]
    cmp  x21, x9
    b.hs 7f
    ldr  x23, [x28, #RG_CHUNKS]
    add  x23, x23, x21, lsl #5
    ldr  x9, [x19, #TBL_COLS]
    add  x9, x9, x21, lsl #5
    ldr  w27, [x9, #COL_TYPE]
    mov  x24, #0
    mov  x25, #0
    mov  x26, #0
    ldr  x22, [x28, #RG_START]
3:  ldr  x9, [x28, #RG_START]
    ldr  x10, [x28, #RG_NROWS]
    add  x9, x9, x10
    cmp  x22, x9
    b.hs 6f
    mov  x0, x19
    mov  x1, x21
    mov  x2, x22
    bl   tbl_get
    cbz  x1, 4f
    add  x24, x24, #1
    b    5f
4:  ldr  w9, [x23, #CK_HASMM]
    cbz  w9, 9f                     // a value but no statistics
    str  x0, [sp, #-16]!
    ldr  x1, [x23, #CK_MIN]
    mov  w2, w27
    bl   value_cmp
    tbnz w0, #31, 91f               // below min
    cmp  w0, #0
    cinc x25, x25, eq
    ldr  x0, [sp]
    ldr  x1, [x23, #CK_MAX]
    mov  w2, w27
    bl   value_cmp
    cmp  w0, #0
    b.gt 91f                        // above max
    cinc x26, x26, eq
    add  sp, sp, #16
5:  add  x22, x22, #1
    b    3b
6:  ldr  x9, [x23, #CK_NULLS]
    cmp  x9, x24
    b.ne 9f
    ldr  w9, [x23, #CK_HASMM]
    cbz  w9, 61f
    cbz  x25, 9f                    // min / max must be attained
    cbz  x26, 9f
61: add  x21, x21, #1
    b    2b
7:  add  x20, x20, #1
    b    1b
8:  mov  w0, #1
    LEAVE 5
91: add  sp, sp, #16
9:  mov  w0, #0
    LEAVE 5
ENDF check_stats

// =============================================================================
// roundtrip(w0 encoding, x1 row group size, w2 mmap): save the source table,
// load it back, compare cells, row group count and statistics.
// Registers: w19 encoding, x20 rgs, w21 mmap, x22 loaded table
// =============================================================================
LFUNC roundtrip
    ENTER 2
    mov  w19, w0
    mov  x20, x1
    mov  w21, w2
    ADR_L x0, g_jmpbuf
    bl   setjmp
    cbnz w0, .Lrt_raised
    ADR_L x0, tbl
    ADR_L x1, p_file
    mov  x2, x20
    mov  w3, w19
    bl   pqcf_save
    ADR_L x0, p_file
    mov  w1, w21
    bl   pqcf_load
    mov  x22, x0
    ADR_L x9, g_pending_table       // the test owns the table now
    str  xzr, [x9]
    ldr  x9, [x22, #TBL_NCOLS]
    ldr  x10, [x22, #TBL_NROWS]
    cmp  x9, #NCOLS
    ccmp x10, #NROWS, #0, eq
    b.ne .Lrt_shape
    ADR_L x0, tbl
    mov  x1, x22
    bl   cmp_tables
    cbz  w0, .Lrt_cells
    // row groups: ceil(NROWS / rgs) (rgs 0 = default => 1 group)
    mov  x9, #1
    cbz  x20, 1f
    add  x9, x20, #(NROWS - 1)
    mov  x10, x20
    udiv x9, x9, x10
1:  ldr  x10, [x22, #TBL_NRG]
    cmp  x9, x10
    b.ne .Lrt_nrg
    mov  x0, x22
    bl   check_stats
    cbz  w0, .Lrt_stats
    bl   pass
    b    .Lrt_free
.Lrt_shape:
    ADR_L x0, m_shape
    b    .Lrt_fail
.Lrt_cells:
    ADR_L x0, m_cells
    b    .Lrt_fail
.Lrt_nrg:
    ADR_L x0, m_nrg
    b    .Lrt_fail
.Lrt_stats:
    ADR_L x0, m_stats
.Lrt_fail:
    mov  w1, w19
    mov  x2, x20
    mov  w3, w21
    ADR_L x4, m_none
    bl   fail_rt
.Lrt_free:
    add  x0, x22, #TBL_ARENA
    bl   arena_free
    mov  x0, x22
    bl   free
    b    9f
.Lrt_raised:
    sub  sp, sp, #256
    mov  x0, sp
    mov  x1, #256
    ADR_L x2, f_raised
    ADR_L x3, g_err_code
    ldr  w3, [x3]
    ADR_L x4, g_err_msg
    bl   snprintf
    ADR_L x0, m_none
    mov  w1, w19
    mov  x2, x20
    mov  w3, w21
    mov  x4, sp
    bl   fail_rt
    add  sp, sp, #256
9:  bl   free_pending
    LEAVE 2
ENDF roundtrip

// =============================================================================
// expect_load_error(x0 name, x1 path Str*, w2 expected code)
// Registers: x19 name, x20 path, w21 code
// =============================================================================
LFUNC expect_load_error
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    mov  w21, w2
    ADR_L x0, g_jmpbuf
    bl   setjmp
    cbnz w0, 1f
    mov  x0, x20
    mov  w1, #1
    bl   pqcf_load
    mov  x0, x19                    // loaded (still pending, freed below):
    mov  x1, #0                     // report "got 0" (success)
    mov  w2, w21
    bl   expect_eq
    b    2f
1:  mov  x0, x19
    ADR_L x1, g_err_code
    ldr  w1, [x1]
    mov  w2, w21
    bl   expect_eq
2:  bl   free_pending
    LEAVE 2
ENDF expect_load_error

// file_path(x0 name cstr) -> x0 "<dir>/<name>" (static buffer)
    .bss
pathbuf: .skip 512
    .text
LFUNC file_path
    ENTER 0
    mov  x4, x0
    LDR_G x3, g_data_dir
    ADR_L x0, pathbuf
    mov  x1, #512
    ADR_L x2, f_rm
    bl   snprintf
    ADR_L x0, pathbuf
    LEAVE 0
ENDF file_path

// patch_byte(x0 name cstr, x1 offset, w2 xor mask): flip bits of one byte
// Registers: x19 offset, w20 mask, w21 fd
LFUNC patch_byte
    ENTER 2
    sub  sp, sp, #16
    mov  x19, x1
    mov  w20, w2
    bl   file_path
    mov  w1, #2                     // O_RDWR
    bl   open
    mov  w21, w0
    mov  w0, w21
    mov  x1, sp
    mov  x2, #1
    mov  x3, x19
    bl   pread
    ldrb w9, [sp]
    eor  w9, w9, w20
    strb w9, [sp]
    mov  w0, w21
    mov  x1, sp
    mov  x2, #1
    mov  x3, x19
    bl   pwrite
    mov  w0, w21
    bl   close
    add  sp, sp, #16
    LEAVE 2
ENDF patch_byte

// count_temp_files() -> x0 number of directory entries starting with '.'
// other than "." and ".."   Registers: x19 DIR*, x20 count
LFUNC count_temp_files
    ENTER 1
    LDR_G x0, g_data_dir
    bl   opendir
    mov  x19, x0
    mov  x20, #0
1:  mov  x0, x19
    bl   readdir
    cbz  x0, 3f
    add  x0, x0, #19                // d_name
    ldrb w9, [x0]
    cmp  w9, #'.'
    b.ne 1b
    ldrb w9, [x0, #1]
    cbz  w9, 1b
    cmp  w9, #'.'
    b.ne 2f
    ldrb w9, [x0, #2]
    cbz  w9, 1b
2:  add  x20, x20, #1
    b    1b
3:  mov  x0, x19
    bl   closedir
    mov  x0, x20
    LEAVE 1
ENDF count_temp_files

// =============================================================================
// main
// Registers: x19 / x20 / x21 loop state, x22 scratch
// =============================================================================
FUNC main
    ENTER 3
    // --- CRC-32
    ADR_L x0, s_check
    mov  x1, #9
    bl   crc32
    mov  w1, w0
    ADR_L x0, t_crc_hw
    ldr  x2, =0xCBF43926
    bl   expect_eq
    ADR_L x0, s_check
    mov  x1, #4
    bl   crc32
    ADR_L x1, s_check + 4
    mov  x2, #5
    bl   crc32_update
    mov  w1, w0
    ADR_L x0, t_crc_inc
    ldr  x2, =0xCBF43926
    bl   expect_eq
    ADR_L x0, s_check
    mov  x1, #0
    bl   crc32
    mov  w1, w0
    ADR_L x0, t_crc_empty
    mov  x2, #0
    bl   expect_eq
    ADR_L x0, main                  // 1000 bytes of code as input
    mov  x1, #1000
    bl   crc32
    mov  w22, w0
    ADR_L x9, g_crc_mode            // force the table implementation
    mov  x10, #2
    str  x10, [x9]
    ADR_L x0, s_check
    mov  x1, #9
    bl   crc32
    mov  w1, w0
    ADR_L x0, t_crc_tab
    ldr  x2, =0xCBF43926
    bl   expect_eq
    ADR_L x0, main
    mov  x1, #1000
    bl   crc32
    mov  w1, w0
    ADR_L x0, t_crc_long
    mov  w2, w22
    bl   expect_eq
    ADR_L x9, g_crc_mode            // back to probing
    str  xzr, [x9]

    // --- UTF-8
    ADR_L x19, utf8_cases
1:  ldrb w20, [x19]
    cbz  w20, 2f
    add  x0, x19, #2
    mov  x1, x20
    bl   utf8_valid
    mov  w1, w0
    ldrb w2, [x19, #1]
    ADR_L x0, t_utf8
    bl   expect_eq
    add  x19, x19, x20
    add  x19, x19, #2
    b    1b

2:  // --- data directory and source table
    ADR_L x0, dirtmpl
    bl   mkdtemp
    ADR_L x9, g_data_dir
    str  x0, [x9]
    bl   build_table

    // --- round trips: 4 encodings x 5 row group sizes x read / mmap
    mov  w19, #PENC_AUTO
3:  cmp  w19, #PENC_RLE
    b.hi 6f
    mov  x20, #0
4:  cmp  x20, #5
    b.hs 51f
    mov  w21, #0
5:  cmp  w21, #1
    b.hi 50f
    mov  w0, w19
    ADR_L x9, rg_sizes
    ldr  x1, [x9, x20, lsl #3]
    mov  w2, w21
    bl   roundtrip
    add  w21, w21, #1
    b    5b
50: add  x20, x20, #1
    b    4b
51: add  w19, w19, #1
    b    3b

6:  // --- damaged files (t.pqcf currently holds the last RLE save)
    bl   save_plain
    adr  x0, fname_t
    mov  x1, #11                    // a byte inside the first chunk
    mov  w2, #0x10
    bl   patch_byte
    ADR_L x0, t_bitflip
    ADR_L x1, p_file
    mov  w2, #ERR_STORAGE_CORRUPT
    bl   expect_load_error
    ADR_L x0, t_pending
    LDR_G x1, g_pending_table
    mov  x2, #0
    bl   expect_eq                  // free_pending released it

    bl   save_plain
    adr  x0, fname_t
    bl   file_path
    mov  x1, #100
    bl   truncate
    ADR_L x0, t_trunc
    ADR_L x1, p_file
    mov  w2, #ERR_STORAGE_CORRUPT
    bl   expect_load_error

    adr  x0, fname_t
    bl   file_path
    mov  x1, #0
    bl   truncate
    ADR_L x0, t_empty
    ADR_L x1, p_file
    mov  w2, #ERR_STORAGE_CORRUPT
    bl   expect_load_error

    bl   save_plain
    adr  x0, fname_t
    mov  x1, #4                     // format_version 1 -> 3
    mov  w2, #2
    bl   patch_byte
    ADR_L x0, t_version
    ADR_L x1, p_file
    mov  w2, #ERR_STORAGE_VERSION
    bl   expect_load_error

    ADR_L x0, t_missing
    ADR_L x1, p_missing
    mov  w2, #ERR_NOT_FOUND
    bl   expect_load_error

    // --- save into a missing directory
    ADR_L x0, g_jmpbuf
    bl   setjmp
    cbnz w0, 7f
    ADR_L x0, tbl
    ADR_L x1, p_nodir
    mov  x2, #0
    mov  w3, #PENC_AUTO
    bl   pqcf_save
    mov  w0, #0
7:  mov  w1, w0
    cbz  w1, 71f
    ADR_L x1, g_err_code
    ldr  w1, [x1]
71: ADR_L x0, t_nodir
    mov  x2, #ERR_IO
    bl   expect_eq
    bl   free_pending
    bl   count_temp_files
    mov  x1, x0
    ADR_L x0, t_notmp
    mov  x2, #0
    bl   expect_eq

    // --- cleanup
    adr  x0, fname_t
    bl   file_path
    bl   unlink
    LDR_G x0, g_data_dir
    bl   rmdir
    ADR_L x0, tbl + TBL_ARENA
    bl   arena_free
    ADR_L x0, f_sum
    LDR_G x1, passes
    LDR_G x2, failures
    bl   printf
    LDR_G x0, failures
    cmp  x0, #0
    cset w0, ne
    LEAVE 3
fname_t: .asciz "t.pqcf"
    .p2align 2
ENDF main

// save_plain(): save the source table as t.pqcf (PLAIN, one row group)
LFUNC save_plain
    ENTER 0
    ADR_L x0, g_jmpbuf
    bl   setjmp
    cbnz w0, 1f
    ADR_L x0, tbl
    ADR_L x1, p_file
    mov  x2, #0
    mov  w3, #PENC_PLAIN
    bl   pqcf_save
1:  bl   free_pending
    LEAVE 0
ENDF save_plain

    NOTE_GNU_STACK
