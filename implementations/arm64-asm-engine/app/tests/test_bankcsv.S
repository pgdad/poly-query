// =============================================================================
// test_bankcsv.S — unit tests for app/bankcsv.S (bank_read, bank_parse_date,
// bank_parse_amount, merchant_normalize).
//
//   gcc -Iinclude -Iapp -g -Wa,--fatal-warnings -o /tmp/test_bankcsv \
//       app/tests/test_bankcsv.S app/bankcsv.S app/util.S && /tmp/test_bankcsv
//
// Writes CSV files into a mkdtemp directory, reads them with bank_read and
// compares the records; error cases run bank_read in a forked child whose
// stderr is captured through a pipe (exit status 4 and the message are
// checked). Prints "test_bankcsv: N passed" and exits 0 when all pass.
//
// Dump mode (manual cross-checks, e.g. against datasets/generators/bankgen.py):
//   test_bankcsv us-checking|us-card|de-giro FILE
// prints "date|cents|description|merchant" per record.
//
// Functions:
//   main(w0 argc, x1 argv) -> w0 exit status
//   t_check(w0 cond, x1 printf format, x2..x5 args): count one check
//   bytes_eq(x0 ptr, x1 len, x2 cstr) -> w0 1 if equal
//   make_file(x0 name, x1 content cstr or 0) -> x0 path (file written)
//   run_ok_case(x0 OKC*), run_err_case(x0 ERC*)
//   expect_exit4(x0 path, x1 IS*, x2 expected stderr substring, x3 label)
//   t_dates, t_amounts, t_merchants, t_large, dump(x0 style, x1 path)
// =============================================================================
#include "ledger.inc"

#define CH_TAB      9
#define CH_SPACE    32
#define CH_APOS     39
#define CH_COMMA    44
#define CH_DOT      46
#define CH_SEMI     59

#define MAX_PATHS   64
#define ERRBUF_SIZE 4096
#define LARGE_N     100000

// ok case: a file that must convert to the expected records
#define OKC_NAME    0
#define OKC_CONTENT 8
#define OKC_IS      16
#define OKC_COUNT   24
#define OKC_EXP     32
#define OKC_SIZE    40
// expected record
#define EXP_DATE    0
#define EXP_CENTS   8
#define EXP_DESC    16
#define EXP_MERCH   24
#define EXP_SIZE    32
// error case: bank_read must exit 4 with a message containing EXPECT
#define ERC_NAME    0
#define ERC_CONTENT 8
#define ERC_IS      16
#define ERC_EXPECT  24
#define ERC_SIZE    32

// ------------------------------------------------------------ data macros ----

// a C string in .rodata; its address as a .quad
.macro QSTR text
    .quad 9001f
    .pushsection .rodata
9001: .asciz "\text"
    .popsection
.endm

// IS settings struct (ledger.inc IS_*)
.macro ISDEF delim, header, skip, datecol, datefmt, desccol, mode, amtcol, debcol, credcol, dec, thou, cur, invert
    .p2align 3
    .byte \delim, 0, 0, 0
    .word \header
    .quad \skip
    QSTR "\datecol"
    .word \datefmt, 0
    QSTR "\desccol"
    .word \mode, 0
    QSTR "\amtcol"
    QSTR "\debcol"
    QSTR "\credcol"
    .byte \dec, 0, 0, 0
    .byte \thou, 0, 0, 0
    QSTR "\cur"
    .word \invert, 0
.endm

.macro EXP date, cents, desc, merch
    .quad \date, \cents
    QSTR "\desc"
    QSTR "\merch"
.endm

.macro OKC name, content, is, count, exp
    QSTR "\name"
    .quad \content, \is, \count, \exp
.endm

.macro ERC name, content, is, expect
    QSTR "\name"
    .quad \content, \is
    QSTR "\expect"
.endm

.macro DATE_T text, fmt, expect
    QSTR "\text"
    .quad \fmt, \expect
.endm

.macro AMT_T text, is, expect, status
    QSTR "\text"
    .quad \is, \expect, \status
.endm

.macro MER_T in, out
    QSTR "\in"
    QSTR "\out"
.endm

// ------------------------------------------------------- import settings ----
    .data
//                delim     hdr skip date                fmt           desc                mode             amount    debit    credit   dec     thou      currency invert
is_chk:   ISDEF CH_COMMA, 1, 0, "Date",              DF_YMD_DASH,  "Description",      AM_SIGNED,       "Amount", "Debit", "Credit", CH_DOT, 0,        "",      0
is_card:  ISDEF CH_COMMA, 1, 0, "transaction date",  DF_MDY_SLASH, "Description",      AM_SIGNED,       "Amount", "Debit", "Credit", CH_DOT, CH_COMMA, "$",     1
is_giro:  ISDEF CH_SEMI,  1, 2, "Buchungstag",       DF_DMY_DOT,   "Verwendungszweck", AM_DEBIT_CREDIT, "Amount", "Soll",  "Haben",  CH_COMMA, CH_DOT, "",      0
is_pos:   ISDEF CH_COMMA, 0, 0, "3",                 DF_YMD,       "1",                AM_SIGNED,       "2",      "",      "",       CH_DOT, 0,        "EUR",   0
is_ci:    ISDEF CH_COMMA, 1, 0, "DATE",              DF_YMD_DASH,  "description",      AM_SIGNED,       "AMOUNT", "",      "",       CH_DOT, 0,        "",      0
is_tab:   ISDEF CH_TAB,   1, 0, "Datum",             DF_DMY_SLASH, "Text",             AM_SIGNED,       "Betrag", "",      "",       CH_COMMA, CH_SPACE, "\342\202\254", 0
is_swiss: ISDEF CH_COMMA, 1, 0, "Date",              DF_YMD_DASH,  "Description",      AM_SIGNED,       "Amount", "",      "",       CH_DOT, CH_APOS,  "CHF",   0
is_dcpos: ISDEF CH_COMMA, 0, 0, "1",                 DF_YMD_DASH,  "2",                AM_DEBIT_CREDIT, "",       "3",     "4",      CH_DOT, 0,        "",      1
is_nocol: ISDEF CH_COMMA, 1, 0, "Date",              DF_YMD_DASH,  "Description",      AM_SIGNED,       "Betrag", "",      "",       CH_DOT, 0,        "",      0
is_pos4:  ISDEF CH_COMMA, 0, 0, "1",                 DF_YMD_DASH,  "2",                AM_SIGNED,       "4",      "",      "",       CH_DOT, 0,        "",      0
is_nohdr: ISDEF CH_COMMA, 0, 0, "Date",              DF_YMD_DASH,  "Description",      AM_SIGNED,       "Amount", "",      "",       CH_DOT, 0,        "",      0

tmpl:       .asciz "/tmp/pqlbankXXXXXX"

    .bss
    .p2align 3
g_pass:     .skip 8
g_fail:     .skip 8
g_npaths:   .skip 8
g_paths:    .skip 8 * MAX_PATHS
g_errbuf:   .skip ERRBUF_SIZE

// ------------------------------------------------------------ CSV inputs -----
    .section .rodata
c_checking:                             // us-checking style, quoted fields
    .ascii "Date,Description,Amount\n"
    .ascii "2026-01-01,\"RENT - OAKWOOD APTS\",-1850.00\n"
    .ascii "2026-01-03,\"Trader Joe's #3614\",-119.75\n"
    .ascii "2026-01-15,\"ACME PAYROLL 2026\",+2500.5\n"
    .ascii "2024-02-29,  Leap Day Cafe  ,0.07\n"
    .ascii "2026-01-20,Zero,-0.00\n"
    .ascii " 2026-01-21 ,Big,  9999999999999999.99\t\n"
    .asciz "2000-02-29,\"SQ *Blue  Bottle 4421\",(3.10)"
c_card:                                 // us-card style
    .ascii "\"Transaction Date\",\"Description\",\"Amount\"\n"
    .ascii "01/02/2026,\"Trader Joe's #9387\",\"$18.52\"\n"
    .ascii "1/4/2026,\"Pacific Gas & Electric\",\"$1,193.43\"\n"
    .ascii "12/31/2025,\"REFUND Home Depot #4085\",\"($67.11)\"\n"
    .ascii "02/29/2028,\"Payment Thank You\",\"-$500.00\"\n"
    .ascii "3/7/2026,Shell Oil 2647,$ 38.5\n"
    .ascii "04/01/2026,\"Suffix Currency\",12.00$\n"
    .asciz "04/02/2026,\"Zero refund\",($0.00)\n"
c_giro:                                 // de-giro style, CRLF
    .ascii "Kontoums\303\244tze Girokonto;;;\r\n"
    .ascii "Zeitraum: 01.01.2026 - 31.01.2026;;;\r\n"
    .ascii "Buchungstag;Verwendungszweck;Soll;Haben\r\n"
    .ascii "01.01.2026;Miete Hausverwaltung;1.120,00;\r\n"
    .ascii "2.1.2026;Aral Tankstelle 2371;42,21;\r\n"
    .ascii "15.01.2026;Gehalt ACME GmbH;;3.456,7\r\n"
    .ascii "\r\n"
    .asciz "29.02.2024;\"Umbuchung; \"\"intern\"\"\";10,00;0,50\r\n"
c_pos:                                  // no header, positional references
    .ascii "Coffee Shop 123,-4.50 EUR,20260301\n"
    .asciz "\"Book, Store\",EUR12,20260302\n"
c_bom:                                  // BOM, names matched trimmed + caseless
    .ascii "\357\273\277 Date ,Description,\tAmount\n"
    .ascii "\n"
    .ascii "2026-01-05,\"Lunch with \"\"Bob\"\", Alice\",-12.00\n"
    .ascii "\"2026-01-06\",\"Multi\nline\",-1.00\n"
    .ascii "\n"
    .ascii "\n"
    .ascii "2026-01-07,\"\",0\n"
    .ascii "2026-01-08,\tTabbed\t Desc\t,1.5\n"
    .asciz "2026-01-09,Quote\"Inside,2"
c_tab:                                  // tab delimiter, D/M/YYYY, euro, CRLF
    .ascii "Datum\tText\tBetrag\r\n"
    .ascii "31/12/2025\tSupermarkt  Nord 0042\t-1 234,56 \342\202\254\r\n"
    .asciz "1/2/2026\tGutschrift\t\342\202\254 5\r\n"
c_dcpos:                                // debit_credit by position, invert
    .ascii "2026-03-01,Fee,2.50,\n"
    .ascii "2026-03-02,Deposit,,100\n"
    .asciz "2026-03-03,Both,1.00,0.25\n"
c_header_only:
    .asciz "Date,Description,Amount\n"
c_empty:
    .asciz ""
c_blank_first:                          // empty lines before the header
    .asciz "\n\r\n\nDate,Description,Amount\r\n\r\n2026-01-05,x,1\r\n\r\n"

e_bad_date:
    .asciz "Date,Description,Amount\n2026-01-05,Lunch,-12.00\n2026-02-30,Dinner,-30.00\n"
e_bad_amount:
    .asciz "Date,Description,Amount\n2026-01-05,Lunch,-12.005\n"
e_fields:
    .ascii "Date,Description,Amount\n2026-01-05,Lunch,-12.00\n\n"
    .asciz "\"2026-01-06\",\"Multi\nline\",-1.00\n2026-01-07,Extra,1.00,x\n"
e_few:
    .asciz "Date,Description,Amount\r\n2026-01-05,Lunch\r\n"
e_both:
    .ascii "pre1;;;\r\npre2\r\nBuchungstag;Verwendungszweck;Soll;Haben\r\n"
    .asciz "01.01.2026;Miete;1.120,00;\r\n03.01.2026;Leer; ;\t\r\n"
e_big:
    .asciz "Date,Description,Amount\n2026-01-05,Big,12345678901234567.00\n"
e_pos_three:
    .asciz "2026-01-05,Lunch,-12.00\n"
e_unterm:
    .asciz "Date,Description,Amount\n2026-01-05,\"Open\n,-1.00\n"
e_afterq:
    .asciz "Date,Description,Amount\n\n2026-01-05,\"Lunch\"x,-1.00\n"
e_giro_date:
    .ascii "a\r\nb\r\nBuchungstag;Verwendungszweck;Soll;Haben\r\n"
    .asciz "31.04.2026;Miete;1,00;\r\n"
e_giro_credit:
    .ascii "a\r\nb\r\nBuchungstag;Verwendungszweck;Soll;Haben\r\n"
    .asciz "30.04.2026;Miete;;abc\r\n"
e_card_bad:
    .asciz "Transaction Date,Description,Amount\n01/02/2026,ok,$1.00\n01/03/2026,bad,$-5\n"
e_bad_first:                            // invalid date in the first record (no header)
    .asciz "2026-1-05,Lunch,-12.00\n"

// ---------------------------------------------------------- case tables ------
    .data
    .p2align 3
x_checking:
    EXP 20260101, -185000, "RENT - OAKWOOD APTS", "RENT - OAKWOOD APTS"
    EXP 20260103, -11975, "Trader Joe's #3614", "TRADER JOE'S"
    EXP 20260115, 250050, "ACME PAYROLL 2026", "ACME PAYROLL"
    EXP 20240229, 7, "Leap Day Cafe", "LEAP DAY CAFE"
    EXP 20260120, 0, "Zero", "ZERO"
    EXP 20260121, 999999999999999999, "Big", "BIG"
    EXP 20000229, -310, "SQ *Blue  Bottle 4421", "SQ *BLUE BOTTLE"
x_card:
    EXP 20260102, -1852, "Trader Joe's #9387", "TRADER JOE'S"
    EXP 20260104, -119343, "Pacific Gas & Electric", "PACIFIC GAS & ELECTRIC"
    EXP 20251231, 6711, "REFUND Home Depot #4085", "REFUND HOME DEPOT"
    EXP 20280229, 50000, "Payment Thank You", "PAYMENT THANK YOU"
    EXP 20260307, -3850, "Shell Oil 2647", "SHELL OIL"
    EXP 20260401, -1200, "Suffix Currency", "SUFFIX CURRENCY"
    EXP 20260402, 0, "Zero refund", "ZERO REFUND"
x_giro:
    EXP 20260101, -112000, "Miete Hausverwaltung", "MIETE HAUSVERWALTUNG"
    EXP 20260102, -4221, "Aral Tankstelle 2371", "ARAL TANKSTELLE"
    EXP 20260115, 345670, "Gehalt ACME GmbH", "GEHALT ACME GMBH"
    EXP 20240229, -950, "Umbuchung; \"intern\"", "UMBUCHUNG; \"INTERN\""
x_pos:
    EXP 20260301, -450, "Coffee Shop 123", "COFFEE SHOP"
    EXP 20260302, 1200, "Book, Store", "BOOK, STORE"
x_bom:
    EXP 20260105, -1200, "Lunch with \"Bob\", Alice", "LUNCH WITH \"BOB\", ALICE"
    EXP 20260106, -100, "Multi\nline", "MULTI\nLINE"
    EXP 20260107, 0, "", ""
    EXP 20260108, 150, "Tabbed\t Desc", "TABBED DESC"
    EXP 20260109, 200, "Quote\"Inside", "QUOTE\"INSIDE"
x_tab:
    EXP 20251231, -123456, "Supermarkt  Nord 0042", "SUPERMARKT NORD"
    EXP 20260201, 500, "Gutschrift", "GUTSCHRIFT"
x_dcpos:
    EXP 20260301, 250, "Fee", "FEE"
    EXP 20260302, -10000, "Deposit", "DEPOSIT"
    EXP 20260303, 75, "Both", "BOTH"
x_blank_first:
    EXP 20260105, 100, "x", "X"

ok_cases:
    OKC "checking.csv",    c_checking,    is_chk,   7, x_checking
    OKC "card.csv",        c_card,        is_card,  7, x_card
    OKC "giro.csv",        c_giro,        is_giro,  4, x_giro
    OKC "positional.csv",  c_pos,         is_pos,   2, x_pos
    OKC "bom.csv",         c_bom,         is_ci,    5, x_bom
    OKC "tab.csv",         c_tab,         is_tab,   2, x_tab
    OKC "dcpos.csv",       c_dcpos,       is_dcpos, 3, x_dcpos
    OKC "header_only.csv", c_header_only, is_chk,   0, 0
    OKC "empty.csv",       c_empty,       is_nocol, 0, 0
    OKC "blank_first.csv", c_blank_first, is_chk,   1, x_blank_first
    .quad 0

err_cases:
    ERC "bad_date.csv",    e_bad_date,    is_chk,   "bad_date.csv:3: invalid date '2026-02-30'"
    ERC "bad_amount.csv",  e_bad_amount,  is_chk,   "bad_amount.csv:2: invalid amount '-12.005'"
    ERC "fields.csv",      e_fields,      is_chk,   "fields.csv:6: expected 3 fields, found 4"
    ERC "few.csv",         e_few,         is_chk,   "few.csv:2: expected 3 fields, found 2"
    ERC "nocol.csv",       e_bad_amount,  is_nocol, "nocol.csv: column 'Betrag' not found in the header"
    ERC "nocol_hdr.csv",   c_header_only, is_nocol, "nocol_hdr.csv: column 'Betrag' not found in the header"
    ERC "nope.csv",        0,             is_chk,   "nope.csv: cannot read file"
    ERC "both.csv",        e_both,        is_giro,  "both.csv:5: debit and credit are both empty"
    ERC "big.csv",         e_big,         is_chk,   "big.csv:2: invalid amount '12345678901234567.00'"
    ERC "pos4.csv",        e_pos_three,   is_pos4,  "pos4.csv: column '4' is out of range"
    ERC "nohdr.csv",       e_pos_three,   is_nohdr, "nohdr.csv: column 'Date' is a name but the file has no header"
    ERC "unterm.csv",      e_unterm,      is_chk,   "unterm.csv:2: unterminated quoted field"
    ERC "afterq.csv",      e_afterq,      is_chk,   "afterq.csv:3: unexpected text after a closing quote"
    ERC "giro_date.csv",   e_giro_date,   is_giro,  "giro_date.csv:4: invalid date '31.04.2026'"
    ERC "giro_credit.csv", e_giro_credit, is_giro,  "giro_credit.csv:4: invalid amount 'abc'"
    ERC "card_bad.csv",    e_card_bad,    is_card,  "card_bad.csv:3: invalid amount '$-5'"
    ERC "bad_first.csv",   e_bad_first,   is_pos4,  "bad_first.csv: column '4' is out of range"
    ERC "bad_first2.csv",  e_bad_first,   is_dcpos, "bad_first2.csv: column '4' is out of range"
    ERC "first_date.csv",  e_bad_first,   is_ci,    "first_date.csv: column 'DATE' not found in the header"
    .quad 0

date_cases:
    DATE_T "2026-01-31", DF_YMD_DASH, 20260131
    DATE_T "2026-02-30", DF_YMD_DASH, 0
    DATE_T "2026-02-29", DF_YMD_DASH, 0
    DATE_T "2024-02-29", DF_YMD_DASH, 20240229
    DATE_T "2000-02-29", DF_YMD_DASH, 20000229
    DATE_T "1900-02-29", DF_YMD_DASH, 0
    DATE_T "0000-01-01", DF_YMD_DASH, 0
    DATE_T "0001-01-01", DF_YMD_DASH, 10101
    DATE_T "9999-12-31", DF_YMD_DASH, 99991231
    DATE_T "2026-13-01", DF_YMD_DASH, 0
    DATE_T "2026-00-10", DF_YMD_DASH, 0
    DATE_T "2026-01-00", DF_YMD_DASH, 0
    DATE_T "2026-04-31", DF_YMD_DASH, 0
    DATE_T "2026-1-05",  DF_YMD_DASH, 0
    DATE_T "2026-01-5",  DF_YMD_DASH, 0
    DATE_T "2026/01/05", DF_YMD_DASH, 0
    DATE_T "2026-01-05x", DF_YMD_DASH, 0
    DATE_T "26-01-05",   DF_YMD_DASH, 0
    DATE_T "",           DF_YMD_DASH, 0
    DATE_T "20260105",   DF_YMD, 20260105
    DATE_T "2026015",    DF_YMD, 0
    DATE_T "202601050",  DF_YMD, 0
    DATE_T "2026-01-05", DF_YMD, 0
    DATE_T "20261231",   DF_YMD, 20261231
    DATE_T "1/2/2026",   DF_MDY_SLASH, 20260102
    DATE_T "01/02/2026", DF_MDY_SLASH, 20260102
    DATE_T "12/31/2025", DF_MDY_SLASH, 20251231
    DATE_T "13/01/2026", DF_MDY_SLASH, 0
    DATE_T "04/31/2026", DF_MDY_SLASH, 0
    DATE_T "1/2/26",     DF_MDY_SLASH, 0
    DATE_T "001/02/2026", DF_MDY_SLASH, 0
    DATE_T "1/2/20260",  DF_MDY_SLASH, 0
    DATE_T "/2/2026",    DF_MDY_SLASH, 0
    DATE_T "1-2-2026",   DF_MDY_SLASH, 0
    DATE_T "1/2/2026",   DF_DMY_SLASH, 20260201
    DATE_T "31/12/2025", DF_DMY_SLASH, 20251231
    DATE_T "29/02/2023", DF_DMY_SLASH, 0
    DATE_T "1.2.2026",   DF_DMY_SLASH, 0
    DATE_T "30.4.2026",  DF_DMY_DOT, 20260430
    DATE_T "31.04.2026", DF_DMY_DOT, 0
    DATE_T "29.02.2024", DF_DMY_DOT, 20240229
    DATE_T "01.01.0001", DF_DMY_DOT, 10101
    DATE_T "1/1/2026",   9, 0
    .quad 0

amount_cases:
    AMT_T "12.34",              is_chk, 1234, 0
    AMT_T "-12.00",             is_chk, -1200, 0
    AMT_T "+5",                 is_chk, 500, 0
    AMT_T "(7.5)",              is_chk, -750, 0
    AMT_T "( 3.10 )",           is_chk, -310, 0
    AMT_T "- 2",                is_chk, -200, 0
    AMT_T "0.07",               is_chk, 7, 0
    AMT_T "-0.00",              is_chk, 0, 0
    AMT_T " \t42\t ",           is_chk, 4200, 0
    AMT_T "007",                is_chk, 700, 0
    AMT_T "9999999999999999.99", is_chk, 999999999999999999, 0
    AMT_T "0000000000000001",   is_chk, 100, 0
    AMT_T "12345678901234567",  is_chk, 0, 1
    AMT_T "12.005",             is_chk, 0, 1
    AMT_T "12.",                is_chk, 0, 1
    AMT_T ".5",                 is_chk, 0, 1
    AMT_T "",                   is_chk, 0, 1
    AMT_T "   ",                is_chk, 0, 1
    AMT_T "-",                  is_chk, 0, 1
    AMT_T "()",                 is_chk, 0, 1
    AMT_T "--5",                is_chk, 0, 1
    AMT_T "+-5",                is_chk, 0, 1
    AMT_T "-(5)",               is_chk, 0, 1
    AMT_T "1e3",                is_chk, 0, 1
    AMT_T "1.2.3",              is_chk, 0, 1
    AMT_T "1,000.00",           is_chk, 0, 1
    AMT_T "$5",                 is_chk, 0, 1
    AMT_T "$1,234.56",          is_card, 123456, 0
    AMT_T "($67.11)",           is_card, -6711, 0
    AMT_T "-$500.00",           is_card, -50000, 0
    AMT_T "12.00$",             is_card, 1200, 0
    AMT_T "$ 1 ",               is_card, 100, 0
    AMT_T "1,2,3",              is_card, 12300, 0
    AMT_T "$$5",                is_card, 0, 1
    AMT_T "$5$",                is_card, 0, 1
    AMT_T "$-5",                is_card, 0, 1
    AMT_T "$",                  is_card, 0, 1
    AMT_T "1.120,00",           is_giro, 112000, 0
    AMT_T "3.456,7",            is_giro, 345670, 0
    AMT_T "12.5",               is_giro, 12500, 0
    AMT_T "0,50",               is_giro, 50, 0
    AMT_T "1,2,3",              is_giro, 0, 1
    AMT_T "1,234",              is_giro, 0, 1
    AMT_T "CHF 1'234.50",       is_swiss, 123450, 0
    AMT_T "-1'000 CHF",         is_swiss, -100000, 0
    AMT_T "CHF",                is_swiss, 0, 1
    AMT_T "-1 234,56 \342\202\254", is_tab, -123456, 0
    AMT_T "4.50",               is_tab, 450, 0
    .quad 0

merchant_cases:
    MER_T "Whole Foods Market #10234", "WHOLE FOODS MARKET"
    MER_T "SQ *Blue  Bottle 4421",     "SQ *BLUE BOTTLE"
    MER_T "Rent 2026",                 "RENT"
    MER_T "7-Eleven 12",               "7-ELEVEN 12"
    MER_T "#123",                      "#123"
    MER_T "Shop 12 345",               "SHOP 12"
    MER_T "REI #",                     "REI #"
    MER_T "Caf\303\251\tM\303\251lange  #9", "CAF\303\251 M\303\251LANGE"
    MER_T "",                          ""
    MER_T "Line\nbreak",               "LINE\nBREAK"
    MER_T "  \t lower   case\t\t",     "LOWER CASE"
    MER_T "   ",                       ""
    MER_T "123",                       "123"
    MER_T "a 123",                     "A"
    MER_T "a 12",                      "A 12"
    MER_T "a #1",                      "A"
    MER_T "a #1x",                     "A #1X"
    MER_T "a 12a3",                    "A 12A3"
    MER_T "Store 1 2 3456",            "STORE 1 2"
    MER_T "zZ[`{@",                    "ZZ[`{@"
    .quad 0

// ----------------------------------------------------------------- strings ---
    .section .rodata
s_fail:         .asciz "FAIL: "
s_wb:           .asciz "wb"
s_pathfmt:      .asciz "%s/%s"
s_err_prefix:   .asciz "pqledger: error: "
s_count:        .asciz "%s: %lu records, expected %lu"
s_date:         .asciz "%s[%lu]: date %lu"
s_amount:       .asciz "%s[%lu]: amount %ld"
s_desc:         .asciz "%s[%lu]: description '%.*s'"
s_merch:        .asciz "%s[%lu]: merchant '%.*s'"
s_status:       .asciz "%s: wait status 0x%x, expected exit 4"
s_stderr:       .asciz "%s: stderr '%s' lacks '%s'"
s_dcase:        .asciz "date '%s' format %lu -> %lu"
s_acase:        .asciz "amount '%s' -> %ld status %u"
s_mcase:        .asciz "merchant '%s' -> '%.*s'"
s_large_hdr:    .asciz "Date,Description,Amount\n"
s_large_fmt:    .asciz "2026-%02lu-%02lu,\"Store %lu #%lu\",-%lu.%02lu\n"
s_large_name:   .asciz "large.csv"
s_large_n:      .asciz "large: %lu records"
s_large_bad:    .asciz "large: %lu records differ"
s_large_rec:    .asciz "large: record 12345 merchant '%.*s'"
s_large_desc:   .asciz "Store 345 #12345"
s_large_merch:  .asciz "STORE 345"
s_large_time:   .asciz "large: %lu records (%lu bytes) read in %ld ms\n"
s_large_slow:   .asciz "large: %ld ms (limit 1000)"
s_mkdtemp:      .asciz "mkdtemp"
s_cantwrite:    .asciz "cannot write %s\n"
s_result_ok:    .asciz "test_bankcsv: %lu passed\n"
s_result_bad:   .asciz "test_bankcsv: %lu passed, %lu FAILED\n"
s_st_chk:       .asciz "us-checking"
s_st_card:      .asciz "us-card"
s_st_giro:      .asciz "de-giro"
s_dump_fmt:     .asciz "%lu|%ld|%.*s|%.*s\n"
s_dump_usage:   .asciz "usage: test_bankcsv [us-checking|us-card|de-giro FILE]\n"

// ------------------------------------------------------------------ main -----

// main(w0 argc, x1 argv) -> w0 0 all passed / 1 failures
//   x19 table cursor, x20 path index
FUNC main
    ENTER 2
    cmp  w0, #3
    b.ne 1f
    ldp  x0, x1, [x1, #8]
    bl   dump
    LEAVE 2
1:  cmp  w0, #1
    b.eq 2f
    GOT_LOAD x1, stderr
    ADR_L x0, s_dump_usage
    bl   fputs
    mov  w0, #1
    LEAVE 2
2:  ADR_L x0, tmpl
    bl   mkdtemp
    cbnz x0, 3f
    ADR_L x0, s_mkdtemp
    bl   perror
    mov  w0, #1
    LEAVE 2

3:  bl   t_dates
    bl   t_amounts
    bl   t_merchants
    ADR_L x19, ok_cases
4:  ldr  x9, [x19]
    cbz  x9, 5f
    mov  x0, x19
    bl   run_ok_case
    add  x19, x19, #OKC_SIZE
    b    4b
5:  ADR_L x19, err_cases
6:  ldr  x9, [x19]
    cbz  x9, 7f
    mov  x0, x19
    bl   run_err_case
    add  x19, x19, #ERC_SIZE
    b    6b
7:  bl   t_large

    mov  x20, #0                        // remove the files and the directory
8:  LDR_G x9, g_npaths
    cmp  x20, x9
    b.hs 9f
    ADR_L x9, g_paths
    ldr  x0, [x9, x20, lsl #3]
    bl   unlink
    add  x20, x20, #1
    b    8b
9:  ADR_L x0, tmpl
    bl   rmdir

    LDR_G x1, g_pass
    LDR_G x2, g_fail
    cbnz x2, 10f
    ADR_L x0, s_result_ok
    bl   printf
    mov  w0, #0
    LEAVE 2
10: ADR_L x0, s_result_bad
    bl   printf
    mov  w0, #1
    LEAVE 2
ENDF main

// ---------------------------------------------------------------- helpers ----

// t_check(w0 cond, x1 fmt, x2..x5 args): count one check; on failure print
// "FAIL: " and the formatted message
//   sp+16..: saved fmt and args
LFUNC t_check
    stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    cbz  w0, 1f
    ADR_L x9, g_pass
    ldr  x10, [x9]
    add  x10, x10, #1
    str  x10, [x9]
    ldp  x29, x30, [sp], #64
    ret
1:  stp  x1, x2, [sp, #16]
    stp  x3, x4, [sp, #32]
    str  x5, [sp, #48]
    ADR_L x9, g_fail
    ldr  x10, [x9]
    add  x10, x10, #1
    str  x10, [x9]
    ADR_L x0, s_fail
    bl   printf
    ldp  x0, x1, [sp, #16]
    ldp  x2, x3, [sp, #32]
    ldr  x4, [sp, #48]
    bl   printf
    mov  w0, #'\n'
    bl   putchar
    ldp  x29, x30, [sp], #64
    ret
ENDF t_check

// bytes_eq(x0 ptr, x1 len, x2 cstr) -> w0 1 if the bytes equal the string
//   x19 ptr, x20 len, x21 cstr
LFUNC bytes_eq
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x0, x2
    bl   strlen
    cmp  x0, x20
    b.ne 8f
    mov  x0, x19
    mov  x1, x21
    mov  x2, x20
    bl   memcmp
    cmp  w0, #0
    cset w0, eq
    LEAVE 2
8:  mov  w0, #0
    LEAVE 2
ENDF bytes_eq

// make_file(x0 name, x1 content or 0) -> x0 "TMPDIR/name" (xmalloc); writes
// the content (no file at all for 0) and remembers the path for cleanup
//   x19 name, x20 content, x21 path, x22 FILE*
LFUNC make_file
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    mov  x0, #512
    bl   xmalloc
    mov  x21, x0
    mov  x1, #512
    ADR_L x2, s_pathfmt
    ADR_L x3, tmpl
    mov  x4, x19
    bl   snprintf
    cbz  x20, 9f
    mov  x0, x21
    ADR_L x1, s_wb
    bl   fopen
    cbz  x0, 8f
    mov  x22, x0
    mov  x0, x20
    bl   strlen
    mov  x2, x0
    mov  x0, x20
    mov  x1, #1
    mov  x3, x22
    bl   fwrite
    mov  x0, x22
    bl   fclose
    ADR_L x9, g_npaths
    ldr  x10, [x9]
    cmp  x10, #MAX_PATHS
    b.hs 9f
    ADR_L x11, g_paths
    str  x21, [x11, x10, lsl #3]
    add  x10, x10, #1
    str  x10, [x9]
9:  mov  x0, x21
    LEAVE 2
8:  GOT_LOAD x0, stderr
    ADR_L x1, s_cantwrite
    mov  x2, x21
    bl   fprintf
    mov  w0, #1
    bl   exit
ENDF make_file

// run_ok_case(x0 OKC*): write, bank_read, compare count and every record
//   x19 case, x20 records, x21 count, x22 index, x23 REC*, x24 expected,
//   x25 case name
LFUNC run_ok_case
    ENTER 5
    mov  x19, x0
    ldr  x25, [x19, #OKC_NAME]
    ldp  x0, x1, [x19, #OKC_NAME]
    bl   make_file
    ldr  x1, [x19, #OKC_IS]
    bl   bank_read
    mov  x20, x0
    mov  x21, x1
    ldr  x4, [x19, #OKC_COUNT]
    cmp  x21, x4
    cset w0, eq
    ADR_L x1, s_count
    mov  x2, x25
    mov  x3, x21
    bl   t_check
    ldr  x9, [x19, #OKC_COUNT]
    cmp  x21, x9
    b.ne 9f
    mov  x22, #0
1:  cmp  x22, x21
    b.hs 9f
    mov  x9, #REC_SIZE
    madd x23, x22, x9, x20
    ldr  x24, [x19, #OKC_EXP]
    add  x24, x24, x22, lsl #5          // EXP_SIZE = 32

    ldr  x4, [x23, #REC_DATE]
    ldr  x10, [x24, #EXP_DATE]
    cmp  x4, x10
    cset w0, eq
    ADR_L x1, s_date
    mov  x2, x25
    mov  x3, x22
    bl   t_check

    ldr  x4, [x23, #REC_AMOUNT]
    ldr  x10, [x24, #EXP_CENTS]
    cmp  x4, x10
    cset w0, eq
    ADR_L x1, s_amount
    mov  x2, x25
    mov  x3, x22
    bl   t_check

    ldp  x0, x1, [x23, #REC_DESC]
    ldr  x2, [x24, #EXP_DESC]
    bl   bytes_eq
    ADR_L x1, s_desc
    mov  x2, x25
    mov  x3, x22
    ldr  x4, [x23, #REC_DESC_LEN]
    ldr  x5, [x23, #REC_DESC]
    bl   t_check

    ldp  x0, x1, [x23, #REC_MERCH]
    ldr  x2, [x24, #EXP_MERCH]
    bl   bytes_eq
    ldp  x9, x10, [x23, #REC_MERCH]     // and NUL-terminated
    ldrb w10, [x9, x10]
    cmp  w10, #0
    csel w0, w0, wzr, eq
    ADR_L x1, s_merch
    mov  x2, x25
    mov  x3, x22
    ldr  x4, [x23, #REC_MERCH_LEN]
    ldr  x5, [x23, #REC_MERCH]
    bl   t_check
    add  x22, x22, #1
    b    1b
9:  LEAVE 5
ENDF run_ok_case

// run_err_case(x0 ERC*): write the file (if any) and expect exit 4
//   x19 case
LFUNC run_err_case
    ENTER 1
    mov  x19, x0
    ldp  x0, x1, [x19, #ERC_NAME]
    bl   make_file
    ldr  x1, [x19, #ERC_IS]
    ldr  x2, [x19, #ERC_EXPECT]
    ldr  x3, [x19, #ERC_NAME]
    bl   expect_exit4
    LEAVE 1
ENDF run_err_case

// expect_exit4(x0 path, x1 IS*, x2 expected substring, x3 label): run
// bank_read in a child with stderr on a pipe; check exit status 4, the
// "pqledger: error: " prefix and the substring
//   x19 path, x20 IS*, x21 substring, x22 label, w23 pid, x24 bytes read
//   sp: int fds[2], int status
LFUNC expect_exit4
    ENTER 3
    sub  sp, sp, #16
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x22, x3
    mov  x0, #0                         // nothing buffered may be duplicated
    bl   fflush
    mov  x0, sp
    bl   pipe
    bl   fork
    mov  w23, w0
    cbnz w0, 1f
    ldr  w0, [sp]                       // child
    bl   close
    ldr  w0, [sp, #4]
    mov  w1, #2
    bl   dup2
    mov  x0, x19
    mov  x1, x20
    bl   bank_read
    mov  w0, #0
    bl   _exit
1:  ldr  w0, [sp, #4]                   // parent: collect stderr
    bl   close
    mov  x24, #0
2:  mov  x2, #(ERRBUF_SIZE - 1)
    sub  x2, x2, x24
    cbz  x2, 3f
    ldr  w0, [sp]
    ADR_L x1, g_errbuf
    add  x1, x1, x24
    bl   read
    cmp  x0, #0
    b.le 3f
    add  x24, x24, x0
    b    2b
3:  ADR_L x9, g_errbuf
    strb wzr, [x9, x24]
    ldr  w0, [sp]
    bl   close
    mov  w0, w23
    add  x1, sp, #8
    mov  w2, #0
    bl   waitpid

    ldr  w3, [sp, #8]                   // exited normally with status 4
    and  w10, w3, #0xffff
    cmp  w10, #0x400
    cset w0, eq
    ADR_L x1, s_status
    mov  x2, x22
    bl   t_check
    ADR_L x0, g_errbuf
    ADR_L x1, s_err_prefix
    mov  x2, #17
    bl   strncmp
    cmp  w0, #0
    cset w0, eq
    ADR_L x1, s_stderr
    mov  x2, x22
    ADR_L x3, g_errbuf
    ADR_L x4, s_err_prefix
    bl   t_check
    ADR_L x0, g_errbuf
    mov  x1, x21
    bl   strstr
    cmp  x0, #0
    cset w0, ne
    ADR_L x1, s_stderr
    mov  x2, x22
    ADR_L x3, g_errbuf
    mov  x4, x21
    bl   t_check
    add  sp, sp, #16
    LEAVE 3
ENDF expect_exit4

// t_dates: bank_parse_date over date_cases (text, DF_*, expected)
//   x19 table cursor
LFUNC t_dates
    ENTER 1
    ADR_L x19, date_cases
1:  ldr  x0, [x19]
    cbz  x0, 9f
    bl   strlen
    mov  x1, x0
    ldr  x0, [x19]
    ldr  x2, [x19, #8]
    bl   bank_parse_date
    mov  x4, x0
    ldr  x9, [x19, #16]
    cmp  x0, x9
    cset w0, eq
    ADR_L x1, s_dcase
    ldp  x2, x3, [x19]
    bl   t_check
    add  x19, x19, #24
    b    1b
9:  LEAVE 1
ENDF t_dates

// t_amounts: bank_parse_amount over amount_cases (text, IS*, cents, status)
//   x19 table cursor
LFUNC t_amounts
    ENTER 1
    ADR_L x19, amount_cases
1:  ldr  x0, [x19]
    cbz  x0, 9f
    bl   strlen
    mov  x1, x0
    ldr  x0, [x19]
    ldr  x2, [x19, #8]
    bl   bank_parse_amount
    mov  x3, x0
    mov  w4, w1
    ldp  x9, x10, [x19, #16]
    cmp  x3, x9
    ccmp x4, x10, #0, eq
    cset w0, eq
    ADR_L x1, s_acase
    ldr  x2, [x19]
    bl   t_check
    add  x19, x19, #32
    b    1b
9:  LEAVE 1
ENDF t_amounts

// t_merchants: merchant_normalize over merchant_cases (in, out)
//   x19 table cursor, x20 result, x21 result length
LFUNC t_merchants
    ENTER 2
    ADR_L x19, merchant_cases
1:  ldr  x0, [x19]
    cbz  x0, 9f
    bl   strlen
    mov  x1, x0
    ldr  x0, [x19]
    bl   merchant_normalize
    mov  x20, x0
    mov  x21, x1
    ldr  x2, [x19, #8]
    bl   bytes_eq
    ldrb w9, [x20, x21]                 // NUL-terminated
    cmp  w9, #0
    csel w0, w0, wzr, eq
    ADR_L x1, s_mcase
    ldr  x2, [x19]
    mov  x3, x21
    mov  x4, x20
    bl   t_check
    mov  x0, x20
    bl   free
    add  x19, x19, #16
    b    1b
9:  LEAVE 2
ENDF t_merchants

// UMOD dst, src, divisor (register), tmp: dst = src % divisor (unsigned)
.macro UMOD dst, src, div, tmp
    udiv \tmp, \src, \div
    msub \dst, \tmp, \div, \src
.endm

// t_large: LARGE_N generated records (~4 MB); checks every date and amount,
// one description / merchant, and that bank_read takes < 1 s
//   x19 index, x20 LARGE_N, x21 path, x22 records, x23 count, x24 ms,
//   x25 mismatches, x26 file size
//   sp: Buf [0,32), line [32,128), timespec t0 [128,144), t1 [144,160)
LFUNC t_large
    ENTER 5
    sub  sp, sp, #160
    stp  xzr, xzr, [sp]
    stp  xzr, xzr, [sp, #16]
    mov  x0, sp
    ADR_L x1, s_large_hdr
    bl   buf_puts
    movz x20, #(LARGE_N & 0xffff)
    movk x20, #(LARGE_N >> 16), lsl #16
    mov  x19, #0
1:  cmp  x19, x20                       // generate
    b.hs 2f
    mov  x9, #12
    UMOD x2, x19, x9, x10
    add  x2, x2, #1                     // month
    mov  x9, #28
    UMOD x3, x19, x9, x10
    add  x3, x3, #1                     // day
    mov  x9, #500
    UMOD x4, x19, x9, x10               // store
    mov  x5, x19
    mov  x9, #1000
    UMOD x6, x19, x9, x10               // whole units
    mov  x9, #100
    UMOD x7, x19, x9, x10               // cents
    add  x0, sp, #32
    ADR_L x1, s_large_fmt
    bl   sprintf
    sxtw x2, w0
    add  x1, sp, #32
    mov  x0, sp
    bl   buf_put
    add  x19, x19, #1
    b    1b
2:  ldr  x26, [sp, #BUF_LEN]
    mov  x0, sp
    bl   buf_cstr
    mov  x1, x0
    ADR_L x0, s_large_name
    bl   make_file
    mov  x21, x0
    mov  x0, sp
    bl   buf_free

    mov  w0, #1                         // CLOCK_MONOTONIC
    add  x1, sp, #128
    bl   clock_gettime
    mov  x0, x21
    ADR_L x1, is_chk
    bl   bank_read
    mov  x22, x0
    mov  x23, x1
    mov  w0, #1
    add  x1, sp, #144
    bl   clock_gettime
    ldp  x9, x10, [sp, #128]
    ldp  x11, x12, [sp, #144]
    sub  x9, x11, x9
    sub  x10, x12, x10
    mov  x11, #1000
    mul  x9, x9, x11
    movz x11, #(1000000 & 0xffff)
    movk x11, #(1000000 >> 16), lsl #16
    sdiv x10, x10, x11
    add  x24, x9, x10

    cmp  x23, x20
    cset w0, eq
    ADR_L x1, s_large_n
    mov  x2, x23
    bl   t_check
    cmp  x23, x20
    b.ne 9f

    mov  x19, #0                        // verify every date and amount
    mov  x25, #0
3:  cmp  x19, x20
    b.hs 4f
    mov  x9, #REC_SIZE
    madd x11, x19, x9, x22
    mov  x9, #12
    UMOD x2, x19, x9, x10
    add  x2, x2, #1
    mov  x9, #28
    UMOD x3, x19, x9, x10
    add  x3, x3, #1
    mov  x9, #2026
    mov  x10, #10000
    mul  x9, x9, x10
    mov  x10, #100
    madd x9, x2, x10, x9
    add  x9, x9, x3                     // expected date
    ldr  x12, [x11, #REC_DATE]
    cmp  x12, x9
    cinc x25, x25, ne
    mov  x9, #1000
    UMOD x2, x19, x9, x10
    mov  x9, #100
    UMOD x3, x19, x9, x10
    madd x9, x2, x9, x3
    neg  x9, x9                         // expected cents
    ldr  x12, [x11, #REC_AMOUNT]
    cmp  x12, x9
    cinc x25, x25, ne
    add  x19, x19, #1
    b    3b
4:  cmp  x25, #0
    cset w0, eq
    ADR_L x1, s_large_bad
    mov  x2, x25
    bl   t_check

    mov  x9, #REC_SIZE                  // record 12345
    mov  x10, #12345
    madd x19, x10, x9, x22
    ldp  x0, x1, [x19, #REC_DESC]
    ADR_L x2, s_large_desc
    bl   bytes_eq
    mov  w25, w0
    ldp  x0, x1, [x19, #REC_MERCH]
    ADR_L x2, s_large_merch
    bl   bytes_eq
    and  w0, w0, w25
    ADR_L x1, s_large_rec
    ldp  x3, x2, [x19, #REC_MERCH]
    bl   t_check

    ADR_L x0, s_large_time
    mov  x1, x23
    mov  x2, x26
    mov  x3, x24
    bl   printf
    cmp  x24, #1000
    cset w0, lt
    ADR_L x1, s_large_slow
    mov  x2, x24
    bl   t_check
9:  add  sp, sp, #160
    LEAVE 5
ENDF t_large

// dump(x0 style, x1 path) -> w0 exit status: print the converted records
//   x19 style, x20 path, x21 IS*, x22 records, x23 count, x24 index
LFUNC dump
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    ADR_L x21, is_chk
    mov  x0, x19
    ADR_L x1, s_st_chk
    bl   strcmp
    cbz  w0, 2f
    ADR_L x21, is_card
    mov  x0, x19
    ADR_L x1, s_st_card
    bl   strcmp
    cbz  w0, 2f
    ADR_L x21, is_giro
    mov  x0, x19
    ADR_L x1, s_st_giro
    bl   strcmp
    cbz  w0, 2f
    GOT_LOAD x1, stderr
    ADR_L x0, s_dump_usage
    bl   fputs
    mov  w0, #1
    LEAVE 3
2:  mov  x0, x20
    mov  x1, x21
    bl   bank_read
    mov  x22, x0
    mov  x23, x1
    mov  x24, #0
3:  cmp  x24, x23
    b.hs 9f
    mov  x9, #REC_SIZE
    madd x9, x24, x9, x22
    ADR_L x0, s_dump_fmt
    ldp  x1, x2, [x9, #REC_DATE]
    ldp  x4, x3, [x9, #REC_DESC]
    ldp  x6, x5, [x9, #REC_MERCH]
    bl   printf
    add  x24, x24, #1
    b    3b
9:  mov  w0, #0
    LEAVE 3
ENDF dump

    NOTE_GNU_STACK
