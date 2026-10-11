/*
 * pqk_x86_consts.h — every constant value and constant table of the x86-64
 * kernels, defined once.
 *
 *  - Scalar constants are cpp #defines (used as immediates, e.g.
 *    movabs $C_FMIX1, %r8, or as .quad values of the tables below).
 *  - Each rodata table is an emit-macro TAB_<name>; a variant invokes the
 *    macros of the tables it uses (in its "constant tables" section), which
 *    emits a file-local @object symbol of the same name. Including this
 *    header emits nothing. The README lists which kernels use which table.
 * Included by pqk_x86_common.h (before any macro that uses a constant); the
 * TAB_* macros use OBJ / ENDOBJ from there.
 */
#ifndef PQK_X86_CONSTS_H
#define PQK_X86_CONSTS_H

/* ------------------------------------------------------------------------
 * Scalar constants
 * ---------------------------------------------------------------------- */
#define C_I64MAX        0x7fffffffffffffff      /* INT64_MAX */
#define C_SIGN64        0x8000000000000000      /* INT64_MIN = 2^63 = qword sign bit */
#define C_SIGN32        0x80000000              /* dword sign bit */
#define C_F64_PINF      0x7ff0000000000000      /* +inf */
#define C_F64_NINF      0xfff0000000000000      /* -inf */
#define C_FMIX1         0xff51afd7ed558ccd      /* MurmurHash3 fmix64 multipliers */
#define C_FMIX2         0xc4ceb9fe1a85ec53
#define C_BITS_EVEN     0x5555555555555555      /* every even bit */
#define C_BITS_2OF4     0x3333333333333333      /* low 2 bits of every nibble */
#define C_NIBBLE_LO     0x0f0f0f0f0f0f0f0f      /* low nibble of every byte */
#define C_BYTE_ONES     0x0101010101010101      /* bit 0 of every byte */
#define C_NIB_BIT1      0x2222222222222222      /* bit 1 of every nibble */
#define LO32(x)         ((x) & 0xffffffff)
#define HI32(x)         (((x) >> 32) & 0xffffffff)

/* ------------------------------------------------------------------------
 * AVX2 tables
 * ---------------------------------------------------------------------- */
/* shc: vpsllvq counts for 64-bit rows. Group g (rows 4g..4g+3), lane j ->
 * 63-(4g+j): moves validity bit 4g+j of a broadcast 64-bit validity word into
 * the sign bit of lane j. 64 quads, 32-byte aligned. */
.macro TAB_SHC
        OBJ     shc, 5
        .set r, 0
        .rept 64
        .quad 63 - r
        .set r, r + 1
        .endr
        ENDOBJ  shc
.endm
/* shc128m: vpsllvq counts for de-interleaved 128-bit groups, lane order
 * (0, 2, 1, 3): group g -> 63-4g, 61-4g, 62-4g, 60-4g. 16 x 4 quads. */
.macro TAB_SHC128M
        OBJ     shc128m, 5
        .set g, 0
        .rept 16
        .quad 63 - 4*g, 61 - 4*g, 62 - 4*g, 60 - 4*g
        .set g, g + 1
        .endr
        ENDOBJ  shc128m
.endm
.macro TAB_EIGHT_D                      /* dword 8 (vpbroadcastd) */
        OBJ     c_eight_d, 2
        .long   8
        ENDOBJ  c_eight_d
.endm
.macro TAB_SIGN_D                       /* dword sign bit (vpbroadcastd) */
        OBJ     c_sign_d, 2
        .long   C_SIGN32
        ENDOBJ  c_sign_d
.endm
/* low 32-bit halves of the fmix64 multipliers (vpmuludq multiplies the low
 * dwords of each qword: lo * lo32(C)). */
.macro TAB_FMIX_LO
        OBJ     c_fmix1_lo, 3
        .quad   LO32(C_FMIX1)
        ENDOBJ  c_fmix1_lo
        OBJ     c_fmix2_lo, 3
        .quad   LO32(C_FMIX2)
        ENDOBJ  c_fmix2_lo
.endm
/* fmix64 multipliers as dword pairs (hi32, lo32) per qword, 32 bytes (vpmulld
 * memory operand: lo*hi32 and hi*lo32 in one multiply), and the high-dword
 * mask (vpbroadcastq). */
.macro TAB_FMIX_SWAP
        OBJ     c_fmix1_sw, 5
        .rept 4
        .long   HI32(C_FMIX1), LO32(C_FMIX1)
        .endr
        ENDOBJ  c_fmix1_sw
        OBJ     c_fmix2_sw, 5
        .rept 4
        .long   HI32(C_FMIX2), LO32(C_FMIX2)
        .endr
        ENDOBJ  c_fmix2_sw
        OBJ     c_hi32, 3
        .quad   0xffffffff00000000
        ENDOBJ  c_hi32
.endm
/* idx8: for every byte value m (entry m, 8 bytes): the positions 0..7 of
 * the set bits of m in ascending order, packed from byte 0; unused bytes 0.
 * (filter index emission: vpmovzxbd idx8(, m, 8) gives the row offsets.) */
.macro TAB_IDX8
        OBJ     idx8, 3
        .set m, 0
        .rept 256
        .set c, 0
        .set j, 0
        .rept 8
        .if (m >> j) & 1
        .byte   j
        .set c, c + 1
        .endif
        .set j, j + 1
        .endr
        .rept 8 - c
        .byte   0
        .endr
        .set m, m + 1
        .endr
        ENDOBJ  idx8
.endm
/* pairmask: lane masks of 2 rows of 128 bits, entry k (32 bytes): qwords
 * 0, 1 all-ones iff bit 0 of k is set, qwords 2, 3 iff bit 1 is set. */
.macro TAB_PAIRMASK
        OBJ     pairmask, 5
        .quad    0,  0,  0,  0
        .quad   -1, -1,  0,  0
        .quad    0,  0, -1, -1
        .quad   -1, -1, -1, -1
        ENDOBJ  pairmask
.endm
.macro TAB_SIXTEEN_Q                    /* 4 x qword 16 (32-byte memory operand) */
        OBJ     c_sixteen_q, 5
        .quad   16, 16, 16, 16
        ENDOBJ  c_sixteen_q
.endm
.macro TAB_SIGN4                        /* 4 x 2^63 (32-byte memory operand) */
        OBJ     c_sign4, 5
        .quad   C_SIGN64, C_SIGN64, C_SIGN64, C_SIGN64
        ENDOBJ  c_sign4
.endm
/* nibmask: lane masks of 4 rows, entry k (32 bytes) = 4 qwords, qword j =
 * all-ones iff bit j of the nibble k is set (validity -> lane mask by one
 * table load). */
.macro TAB_NIBMASK
        OBJ     nibmask, 5
        .set k, 0
        .rept 16
        .quad   -((k >> 0) & 1), -((k >> 1) & 1), -((k >> 2) & 1), -((k >> 3) & 1)
        .set k, k + 1
        .endr
        ENDOBJ  nibmask
.endm
/* vop_inv: AVX2 operator -> "invert the kind's result" (EQ NE LT LE GT GE
 * BETWEEN, and index 7 = PQK_OP_RANGE: BETWEEN with a <= b; BETWEEN =
 * !OUT). Used by count_i64 / count_i128 direct counters. */
.macro TAB_VOP_INV
        OBJ     vop_inv, 0
        .byte   0, 1, 0, 1, 0, 1, 1, 1
        ENDOBJ  vop_inv
.endm

/* ------------------------------------------------------------------------
 * AVX-512 tables
 * ---------------------------------------------------------------------- */
.macro TAB_IOTA16                       /* dwords 0..15 (vpcompressd indices) */
        OBJ     iota16, 6
        .set r, 0
        .rept 16
        .long r
        .set r, r + 1
        .endr
        ENDOBJ  iota16
.endm
.macro TAB_SIXTEEN_D                    /* dword 16 (vpbroadcastd) */
        OBJ     c_sixteen_d, 2
        .long   16
        ENDOBJ  c_sixteen_d
.endm
.macro TAB_FMIX                         /* fmix64 multipliers (vpmullq) */
        OBJ     c_fmix1, 3
        .quad   C_FMIX1
        ENDOBJ  c_fmix1
        OBJ     c_fmix2, 3
        .quad   C_FMIX2
        ENDOBJ  c_fmix2
.endm
.macro TAB_I64MAX
        OBJ     c_i64max, 3
        .quad   C_I64MAX
        ENDOBJ  c_i64max
.endm
.macro TAB_NIB_LUT                      /* popcount of a nibble (vpshufb) */
        OBJ     nib_lut, 4
        .byte 0,1,1,2,1,2,2,3,1,2,2,3,2,3,3,4
        ENDOBJ  nib_lut
.endm
.macro TAB_0F                           /* byte 0x0f (vpbroadcastb) */
        OBJ     c_0f, 0
        .byte   0x0f
        ENDOBJ  c_0f
.endm
/* vpermt2q indices de-interleaving two 64-byte loads of 128-bit rows into
 * low words (even qwords) and high words (odd qwords). */
.macro TAB_IDX_EVEN_ODD
        OBJ     c_idx_even, 6
        .quad 0, 2, 4, 6, 8, 10, 12, 14
        ENDOBJ  c_idx_even
        OBJ     c_idx_odd, 6
        .quad 1, 3, 5, 7, 9, 11, 13, 15
        ENDOBJ  c_idx_odd
.endm
/* kinv128: AVX-512 operator -> "invert the kind's result" for count_i128
 * (EQ NE LT LE GT GE BETWEEN; BETWEEN = IN, not inverted). */
.macro TAB_KINV128
        OBJ     kinv128, 0
        .byte   0, 1, 0, 1, 0, 1, 0
        ENDOBJ  kinv128
.endm

/* ------------------------------------------------------------------------
 * Tables used by both SIMD variants
 * ---------------------------------------------------------------------- */
.macro TAB_PINF_NINF                    /* +inf / -inf (vbroadcastsd) */
        OBJ     c_pinf, 3
        .quad   C_F64_PINF
        ENDOBJ  c_pinf
        OBJ     c_ninf, 3
        .quad   C_F64_NINF
        ENDOBJ  c_ninf
.endm
.macro TAB_I64MIN                       /* INT64_MIN = 2^63 (sign bias / min) */
        OBJ     c_i64min, 3
        .quad   C_SIGN64
        ENDOBJ  c_i64min
.endm
/* c_hibias: [0, 2^63] per 128-bit row = the sign bias of each row's high
 * word (sum_i128). 32 bytes: AVX2 loads all of it, AVX-512 broadcasts the
 * first 16 bytes (vbroadcasti32x4). */
.macro TAB_HIBIAS
        OBJ     c_hibias, 5
        .quad   0, C_SIGN64, 0, C_SIGN64
        ENDOBJ  c_hibias
.endm

#endif /* PQK_X86_CONSTS_H */
