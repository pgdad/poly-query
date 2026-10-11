// =============================================================================
// datetime.S — calendar arithmetic, parsing and formatting of DATE/TIMESTAMP.
//
// DATE payload      : i64 days since 1970-01-01 (proleptic Gregorian)
// TIMESTAMP payload : i64 microseconds since 1970-01-01 00:00:00 (no zone)
//
// The day <-> civil conversions use Howard Hinnant's era-based algorithms
// (http://howardhinnant.github.io/date_algorithms.html); they are exact for
// any day number, including negative ones (dates before 1970).
//
// Functions:
//   days_from_civil(x0 y, x1 m, x2 d)          -> x0 days
//   civil_from_days(x0 days)                    -> x0 y, x1 m, x2 d
//   parse_date(x0 ptr, x1 len)                  -> x0 days, w1 status
//   parse_timestamp(x0 ptr, x1 len, w2 allow_date) -> x0 micros, w1 status
//   fmt_date(x0 Buf*, x1 days)
//   fmt_timestamp(x0 Buf*, x1 micros)
// =============================================================================
#include "pq.inc"

#define US_PER_SEC   1000000
#define US_PER_DAY   86400000000
#define DAYS_0000_03_01_TO_EPOCH 719468     // days from 0000-03-01 to 1970-01-01
#define DAYS_PER_ERA 146097                 // days in 400 Gregorian years

// The helper macros take *register numbers* for their scratch registers
// (e.g. `3` means w3/x3) so they can use both the w and x views.

// DIGIT n, base, off, fail: x<n> = numeric value of the ASCII digit at
// [base+off]; branch to `fail` if it is not '0'..'9'.
.macro DIGIT n, base, off, fail
    ldrb w\n, [\base, #\off]
    sub  w\n, w\n, #'0'
    cmp  w\n, #9
    b.hi \fail
.endm

// NUM2 d, base, off, t, ten, fail: two ASCII digits at [base+off] -> x<d>.
// x<t> is clobbered; `ten` is an x register holding the constant 10.
.macro NUM2 d, base, off, t, ten, fail
    DIGIT \d, \base, \off, \fail
    DIGIT \t, \base, (\off+1), \fail
    madd x\d, x\d, \ten, x\t
.endm

// PUT2 p, off, v, t1, t2, ten: store v (x register, 0..99) as two ASCII
// digits at [p+off]; x<t1>, x<t2> are clobbered, `ten` holds 10.
.macro PUT2 p, off, v, t1, t2, ten
    udiv x\t2, \v, \ten
    msub x\t1, x\t2, \ten, \v
    add  w\t2, w\t2, #'0'
    add  w\t1, w\t1, #'0'
    strb w\t2, [\p, #\off]
    strb w\t1, [\p, #(\off+1)]
.endm

    .section .rodata
// days per month for a non-leap year, index 1..12 (index 0 unused)
month_days:
    .byte 0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31
    .text

// -----------------------------------------------------------------------------
// days_from_civil(x0 y, x1 m, x2 d) -> x0 days since 1970-01-01      (leaf)
// The year is shifted so that it starts on March 1st (leap day at its end).
// Registers: x9 (m<=2), x10 constants, x11 era, x12 yoe, x13 doy, x14 doe.
// -----------------------------------------------------------------------------
FUNC days_from_civil
    cmp  x1, #2
    cset x9, le
    sub  x0, x0, x9                 // y -= (m <= 2)
    // era = (y >= 0 ? y : y - 399) / 400   (floor division)
    sub  x11, x0, #399
    cmp  x0, #0
    csel x11, x0, x11, ge
    mov  x10, #400
    sdiv x11, x11, x10
    msub x12, x11, x10, x0          // yoe = y - era*400        [0, 399]
    // doy = (153*(m > 2 ? m-3 : m+9) + 2)/5 + d - 1          [0, 365]
    sub  x13, x1, #3
    add  x14, x1, #9
    cmp  x1, #2
    csel x13, x13, x14, gt
    mov  x10, #153
    mul  x13, x13, x10
    add  x13, x13, #2
    mov  x10, #5
    udiv x13, x13, x10
    add  x13, x13, x2
    sub  x13, x13, #1
    // doe = yoe*365 + yoe/4 - yoe/100 + doy                  [0, 146096]
    mov  x10, #365
    mul  x14, x12, x10
    add  x14, x14, x12, lsr #2
    mov  x10, #100
    udiv x15, x12, x10
    sub  x14, x14, x15
    add  x14, x14, x13
    // days = era*146097 + doe - 719468
    ldr  x10, =DAYS_PER_ERA
    madd x0, x11, x10, x14
    ldr  x10, =DAYS_0000_03_01_TO_EPOCH
    sub  x0, x0, x10
    ret
ENDF days_from_civil

// -----------------------------------------------------------------------------
// civil_from_days(x0 days) -> x0 y, x1 m, x2 d                         (leaf)
// Registers: x11 era, x12 doe, x13 doy, x14 yoe, x15 y, x9 mp, x10 consts.
// -----------------------------------------------------------------------------
FUNC civil_from_days
    ldr  x10, =DAYS_0000_03_01_TO_EPOCH
    add  x0, x0, x10                // z = days + 719468
    // era = (z >= 0 ? z : z - 146096) / 146097
    ldr  x10, =(DAYS_PER_ERA - 1)
    sub  x11, x0, x10
    cmp  x0, #0
    csel x11, x0, x11, ge
    ldr  x10, =DAYS_PER_ERA
    sdiv x11, x11, x10
    msub x12, x11, x10, x0          // doe = z - era*146097     [0, 146096]
    // yoe = (doe - doe/1460 + doe/36524 - doe/146096) / 365
    mov  x10, #1460
    udiv x13, x12, x10
    sub  x14, x12, x13
    mov  x10, #36524
    udiv x13, x12, x10
    add  x14, x14, x13
    ldr  x10, =(DAYS_PER_ERA - 1)
    udiv x13, x12, x10
    sub  x14, x14, x13
    mov  x10, #365
    udiv x14, x14, x10              // yoe                      [0, 399]
    mov  x10, #400
    madd x15, x11, x10, x14         // y = era*400 + yoe (March-based year)
    // doy = doe - (365*yoe + yoe/4 - yoe/100)
    mov  x10, #365
    mul  x13, x14, x10
    add  x13, x13, x14, lsr #2
    mov  x10, #100
    udiv x9, x14, x10
    sub  x13, x13, x9
    sub  x13, x12, x13              // doy                      [0, 365]
    // mp = (5*doy + 2)/153                                     [0, 11]
    add  x9, x13, x13, lsl #2
    add  x9, x9, #2
    mov  x10, #153
    udiv x9, x9, x10
    // d = doy - (153*mp + 2)/5 + 1
    mul  x16, x9, x10
    add  x16, x16, #2
    mov  x10, #5
    udiv x16, x16, x10
    sub  x2, x13, x16
    add  x2, x2, #1
    // m = mp < 10 ? mp+3 : mp-9
    add  x1, x9, #3
    sub  x16, x9, #9
    cmp  x9, #10
    csel x1, x1, x16, lo
    // y += (m <= 2)
    cmp  x1, #2
    cinc x0, x15, ls
    ret
ENDF civil_from_days

// -----------------------------------------------------------------------------
// dt_parse_ymd(x0 ptr) -> x0 days, w1 status (0 ok / 1 invalid)
// Parses exactly 10 bytes "YYYY-MM-DD" at ptr (the caller checked the length)
// and validates the calendar date (years 0001..9999).
// Registers: x3 y, x4 m, x5 d, x6 10, x7 tmp, x8 base pointer.
// -----------------------------------------------------------------------------
LFUNC dt_parse_ymd
    mov  x8, x0
    mov  x6, #10
    ldrb w7, [x8, #4]
    cmp  w7, #'-'
    b.ne 9f
    ldrb w7, [x8, #7]
    cmp  w7, #'-'
    b.ne 9f
    NUM2 3, x8, 0, 7, x6, 9f      // year = hi2*100 + lo2
    NUM2 4, x8, 2, 7, x6, 9f
    mov  x7, #100
    madd x3, x3, x7, x4
    cbz  x3, 9f                     // year 0000 is out of range
    NUM2 4, x8, 5, 7, x6, 9f      // month
    sub  x7, x4, #1
    cmp  x7, #11
    b.hi 9f
    NUM2 5, x8, 8, 7, x6, 9f      // day
    cbz  x5, 9f
    // days in month (February of a leap year has 29)
    ADR_L x7, month_days
    ldrb w7, [x7, x4]
    cmp  x4, #2
    b.ne 2f
    tst  x3, #3                     // leap: y%4==0 && (y%100!=0 || y%400==0)
    b.ne 2f
    mov  x9, #100
    udiv x10, x3, x9
    msub x10, x10, x9, x3
    cbnz x10, 1f
    mov  x9, #400
    udiv x10, x3, x9
    msub x10, x10, x9, x3
    cbnz x10, 2f
1:  mov  w7, #29
2:  cmp  x5, x7
    b.hi 9f
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    mov  x0, x3
    mov  x1, x4
    mov  x2, x5
    bl   days_from_civil
    mov  w1, #0
    ldp  x29, x30, [sp], #16
    ret
9:  mov  x0, #0
    mov  w1, #1
    ret
ENDF dt_parse_ymd

// -----------------------------------------------------------------------------
// parse_date(x0 ptr, x1 len) -> x0 days, w1 status (1 = invalid)
// Strict `YYYY-MM-DD`, no surrounding whitespace.
// -----------------------------------------------------------------------------
FUNC parse_date
    cmp  x1, #10
    b.eq dt_parse_ymd               // tail call
    mov  x0, #0
    mov  w1, #1
    ret
ENDF parse_date

// -----------------------------------------------------------------------------
// parse_timestamp(x0 ptr, x1 len, w2 allow_date) -> x0 micros, w1 status
// `YYYY-MM-DD[ T]HH:MM:SS(.f{1,6})?`; with allow_date != 0 a bare
// `YYYY-MM-DD` is accepted as midnight.
// Registers: x19 ptr, x20 len, x21 days; time fields in x3..x7 (leaf part).
// -----------------------------------------------------------------------------
FUNC parse_timestamp
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    mov  x19, x0
    mov  x20, x1
    cmp  x1, #10
    b.ne 1f
    cbz  w2, 9f                     // bare date not allowed here
    bl   dt_parse_ymd
    cbnz w1, 9f
    ldr  x9, =US_PER_DAY
    mul  x0, x0, x9
    b    8f
1:  cmp  x1, #19                    // shortest full form
    b.lo 9f
    cmp  x1, #26                    // longest: 6 fractional digits
    b.hi 9f
    bl   dt_parse_ymd
    cbnz w1, 9f
    ldr  x9, =US_PER_DAY
    mul  x15, x0, x9                // micros of midnight
    ldrb w7, [x19, #10]             // separator: ' ' or 'T'
    cmp  w7, #' '
    b.eq 2f
    cmp  w7, #'T'
    b.ne 9f
2:  ldrb w7, [x19, #13]
    cmp  w7, #':'
    b.ne 9f
    ldrb w7, [x19, #16]
    cmp  w7, #':'
    b.ne 9f
    mov  x6, #10
    NUM2 3, x19, 11, 7, x6, 9f    // hour
    cmp  x3, #23
    b.hi 9f
    NUM2 4, x19, 14, 7, x6, 9f    // minute
    cmp  x4, #59
    b.hi 9f
    NUM2 5, x19, 17, 7, x6, 9f    // second
    cmp  x5, #59
    b.hi 9f
    mov  x7, #60
    madd x3, x3, x7, x4             // h*60 + m
    madd x3, x3, x7, x5             // (h*60 + m)*60 + s
    ldr  x9, =US_PER_SEC
    madd x15, x3, x9, x15
    // optional fraction: '.' followed by 1..6 digits (padded to 6)
    cmp  x20, #19
    b.eq 7f
    ldrb w7, [x19, #19]
    cmp  w7, #'.'
    b.ne 9f
    cmp  x20, #21                   // need at least one digit
    b.lo 9f
    add  x8, x19, #20               // digit cursor
    add  x10, x19, x20              // end
    mov  x11, #0                    // fraction value
    mov  x12, #6                    // digits still to produce
3:  cmp  x8, x10
    b.hs 4f
    ldrb w7, [x8], #1
    sub  w7, w7, #'0'
    cmp  w7, #9
    b.hi 9f
    madd x11, x11, x6, x7
    sub  x12, x12, #1
    b    3b
4:  cbz  x12, 5f                    // pad to microseconds
    mul  x11, x11, x6
    sub  x12, x12, #1
    b    4b
5:  add  x15, x15, x11
7:  mov  x0, x15
8:  mov  w1, #0
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
9:  mov  x0, #0
    mov  w1, #1
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF parse_timestamp

// -----------------------------------------------------------------------------
// fmt_date(x0 Buf*, x1 days): append `YYYY-MM-DD` (no quotes).
// Years outside 0..9999 (never produced by valid data) are written with
// buf_put_i64 so that the output is still meaningful.
// Registers: x19 Buf*, x20 y, x21 m, x22 d.
// -----------------------------------------------------------------------------
FUNC fmt_date
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    mov  x19, x0
    mov  x0, x1
    bl   civil_from_days
    mov  x20, x0
    mov  x21, x1
    mov  x22, x2
    mov  x9, #9999
    cmp  x20, x9
    b.hi 2f                         // unsigned: also catches negative years
    mov  x0, x19
    mov  x1, #10
    bl   buf_reserve
    mov  x6, #10
    mov  x7, #100
    udiv x8, x20, x7                // century part
    msub x9, x8, x7, x20            // year within century
    PUT2 x0, 0, x8, 10, 11, x6
    PUT2 x0, 2, x9, 10, 11, x6
    mov  w10, #'-'
    strb w10, [x0, #4]
    strb w10, [x0, #7]
    PUT2 x0, 5, x21, 10, 11, x6
    PUT2 x0, 8, x22, 10, 11, x6
    ldr  x9, [x19, #BUF_LEN]
    add  x9, x9, #10
    str  x9, [x19, #BUF_LEN]
    b    9f
2:  mov  x0, x19                    // out-of-range year (defensive)
    mov  x1, x20
    bl   buf_put_i64
    mov  x0, x19
    mov  x1, #6
    bl   buf_reserve
    mov  x6, #10
    mov  w10, #'-'
    strb w10, [x0, #0]
    strb w10, [x0, #3]
    PUT2 x0, 1, x21, 10, 11, x6
    PUT2 x0, 4, x22, 10, 11, x6
    ldr  x9, [x19, #BUF_LEN]
    add  x9, x9, #6
    str  x9, [x19, #BUF_LEN]
9:  ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
ENDF fmt_date

// -----------------------------------------------------------------------------
// fmt_timestamp(x0 Buf*, x1 micros): append `YYYY-MM-DD HH:MM:SS[.ffffff]`
// (fraction only when the microsecond part is non-zero). Negative values
// (before 1970) use floor division so the time of day is always positive.
// Registers: x19 Buf*, x20 micros within the day [0, 86400e6).
// -----------------------------------------------------------------------------
FUNC fmt_timestamp
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    mov  x19, x0
    ldr  x9, =US_PER_DAY
    sdiv x10, x1, x9                // truncated quotient
    msub x20, x10, x9, x1           // remainder (sign of dividend)
    cmp  x20, #0
    b.ge 1f
    sub  x10, x10, #1               // floor
    add  x20, x20, x9
1:  mov  x1, x10
    bl   fmt_date
    mov  x0, x19
    mov  x1, #16                    // " HH:MM:SS.ffffff"
    bl   buf_reserve
    ldr  x9, =US_PER_SEC
    udiv x12, x20, x9               // seconds of day
    msub x13, x12, x9, x20          // microseconds
    mov  x6, #10
    mov  x7, #60
    udiv x14, x12, x7               // minutes of day
    msub x15, x14, x7, x12          // second
    udiv x16, x14, x7               // hour
    msub x14, x16, x7, x14          // minute
    mov  w10, #' '
    strb w10, [x0, #0]
    mov  w10, #':'
    strb w10, [x0, #3]
    strb w10, [x0, #6]
    PUT2 x0, 1, x16, 10, 11, x6
    PUT2 x0, 4, x14, 10, 11, x6
    PUT2 x0, 7, x15, 10, 11, x6
    mov  x8, #9                     // bytes written
    cbz  x13, 3f
    mov  w10, #'.'
    strb w10, [x0, #9]
    add  x2, x0, #16                // write 6 digits backwards
2:  udiv x11, x13, x6
    msub x10, x11, x6, x13
    add  w10, w10, #'0'
    strb w10, [x2, #-1]!
    mov  x13, x11
    sub  x8, x8, #1
    cmp  x8, #3                     // 6 digits done when x8 reaches 3
    b.ne 2b
    mov  x8, #16
3:  ldr  x9, [x19, #BUF_LEN]
    add  x9, x9, x8
    str  x9, [x19, #BUF_LEN]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret
ENDF fmt_timestamp

    NOTE_GNU_STACK
