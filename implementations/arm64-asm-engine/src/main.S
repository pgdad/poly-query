// =============================================================================
// main.S — command line interface (protocol.md §2).
//
//   polyquery version | capabilities | session [opts] | exec [opts] --request F
//
// Options are parsed into globals; `session` runs the JSON-lines loop,
// `exec` runs one request or an array of requests from a file / stdin.
// =============================================================================
#include "pq.inc"

    .bss
    .p2align 3
g_request_file: .skip 8        // cstr or 0
g_mode:         .skip 8        // 1 version, 2 capabilities, 3 session, 4 exec, 5 serve

    .section .rodata
s_dot:          .asciz "."
s_version:      .asciz "version"
s_caps:         .asciz "capabilities"
s_session:      .asciz "session"
s_exec:         .asciz "exec"
s_serve:        .asciz "serve"
o_data_dir:     .asciz "--data-dir"
o_test_fn:      .asciz "--enable-test-functions"
o_qmem:         .asciz "--max-query-memory-mb"
o_ingest:       .asciz "--max-ingest-bytes"
o_trows:        .asciz "--max-table-rows"
o_jrows:        .asciz "--max-join-rows"
o_threads:      .asciz "--threads"
o_loglevel:     .asciz "--log-level"
o_native:       .asciz "--native-kernels"
o_request:      .asciz "--request"
o_host:         .asciz "--host"
o_port:         .asciz "--port"
o_workers:      .asciz "--workers"
o_queue:        .asciz "--queue-depth"
o_qtimeout:     .asciz "--query-timeout-ms"
o_grace:        .asciz "--shutdown-grace-ms"
o_maxreq:       .asciz "--max-request-bytes"
s_dash:         .asciz "-"
s_rb:           .asciz "rb"
m_usage:        .asciz "usage: polyquery (version|capabilities|session|exec|serve) [options]\n"
m_unknown:      .asciz "polyquery: unknown option: %s\n"
m_missing:      .asciz "polyquery: option %s requires a value\n"
m_badnum:       .asciz "polyquery: invalid number for %s: %s\n"
m_noreq:        .asciz "polyquery: exec requires --request FILE\n"
m_readfail:     .asciz "polyquery: cannot read request file %s\n"
m_serve:        .asciz "polyquery: serve mode is not implemented in this phase\n"

// Option table: name, kind (0 flag-test-functions, 1 string->dest, 2 number->dest,
// 3 number*1MiB->dest, 4 ignored-with-value), destination address.
    .data
    .p2align 3
opt_table:
    .quad o_data_dir, 1, g_data_dir
    .quad o_test_fn,  0, g_test_functions
    .quad o_qmem,     3, g_max_query_mem
    .quad o_ingest,   2, g_max_ingest_bytes
    .quad o_trows,    2, g_max_table_rows
    .quad o_jrows,    2, g_max_join_rows
    .quad o_threads,  5, 0
    .quad o_loglevel, 4, 0
    .quad o_native,   4, 0
    .quad o_request,  1, g_request_file
    .quad o_host,     4, 0
    .quad o_port,     5, 0
    .quad o_workers,  5, 0
    .quad o_queue,    5, 0
    .quad o_qtimeout, 5, 0
    .quad o_grace,    5, 0
    .quad o_maxreq,   5, 0
    .quad 0, 0, 0
    .text

// usage_exit(x0 fmt, x1 arg1, x2 arg2): print to stderr and exit(2)
LFUNC usage_exit
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    mov  x3, x2
    mov  x2, x1
    mov  x1, x0
    GOT_LOAD x0, stderr
    bl   fprintf
    mov  w0, #2
    bl   exit
ENDF usage_exit

// parse_number(x0 cstr, x1 option name) -> x0 value (exits 2 on error)
LFUNC parse_number
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    mov  x19, x0
    mov  x20, x1
    ldrb w2, [x0]
    sub  w2, w2, #'0'
    cmp  w2, #9
    b.hi 9f                         // must start with a digit
    add  x1, sp, #32                // endptr
    mov  w2, #10
    bl   strtoull
    ldr  x1, [sp, #32]
    ldrb w1, [x1]
    cbnz w1, 9f
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #48
    ret
9:  ADR_L x0, m_badnum
    mov  x1, x20
    mov  x2, x19
    bl   usage_exit
ENDF parse_number

// main(w0 argc, x1 argv)
FUNC main
    stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    mov  w19, w0                    // argc
    mov  x20, x1                    // argv
    ADR_L x0, s_dot
    ADR_L x1, g_data_dir
    str  x0, [x1]
    cmp  w19, #2
    b.lt .Lusage
    // ---- mode
    ldr  x21, [x20, #8]
    mov  x22, #0
    mov  x0, x21
    ADR_L x1, s_version
    bl   strcmp
    mov  x22, #1
    cbz  w0, .Lmode_ok
    mov  x0, x21
    ADR_L x1, s_caps
    bl   strcmp
    mov  x22, #2
    cbz  w0, .Lmode_ok
    mov  x0, x21
    ADR_L x1, s_session
    bl   strcmp
    mov  x22, #3
    cbz  w0, .Lmode_ok
    mov  x0, x21
    ADR_L x1, s_exec
    bl   strcmp
    mov  x22, #4
    cbz  w0, .Lmode_ok
    mov  x0, x21
    ADR_L x1, s_serve
    bl   strcmp
    mov  x22, #5
    cbz  w0, .Lmode_ok
    b    .Lusage
.Lmode_ok:
    ADR_L x0, g_mode
    str  x22, [x0]
    // ---- options
    mov  w23, #2                    // argv index
.Lopt_loop:
    cmp  w23, w19
    b.ge .Lopts_done
    ldr  x21, [x20, w23, sxtw #3]   // current option text
    ADR_L x24, opt_table
.Lopt_find:
    ldr  x1, [x24]
    cbz  x1, .Lopt_unknown
    mov  x0, x21
    bl   strcmp
    cbz  w0, .Lopt_found
    add  x24, x24, #24
    b    .Lopt_find
.Lopt_unknown:
    ADR_L x0, m_unknown
    mov  x1, x21
    bl   usage_exit
.Lopt_found:
    ldr  x2, [x24, #8]              // kind
    ldr  x3, [x24, #16]             // destination
    cbnz x2, 1f
    mov  w4, #1                     // kind 0: flag
    str  w4, [x3]
    add  w23, w23, #1
    b    .Lopt_loop
1:  add  w23, w23, #1               // options with a value
    cmp  w23, w19
    b.lt 2f
    ADR_L x0, m_missing
    mov  x1, x21
    bl   usage_exit
2:  ldr  x0, [x20, w23, sxtw #3]    // value text
    add  w23, w23, #1
    cmp  x2, #1
    b.ne 3f
    str  x0, [x3]                   // kind 1: string
    b    .Lopt_loop
3:  cmp  x2, #4
    b.eq .Lopt_loop                 // kind 4: ignored string value
    stp  x2, x3, [sp, #-16]!
    mov  x1, x21
    bl   parse_number
    ldp  x2, x3, [sp], #16
    cmp  x2, #5
    b.eq .Lopt_loop                 // kind 5: validated number, ignored
    cmp  x2, #3
    b.ne 4f
    lsl  x0, x0, #20                // MiB -> bytes
4:  str  x0, [x3]
    b    .Lopt_loop
.Lopts_done:
    LDR_G x22, g_mode
    cmp  x22, #1
    b.ne 1f
    bl   cli_version
    b    .Lexit0
1:  cmp  x22, #2
    b.ne 2f
    bl   cli_capabilities
    b    .Lexit0
2:  cmp  x22, #3
    b.ne 3f
    bl   session_loop
    b    .Lexit0
3:  cmp  x22, #4
    b.ne 4f
    bl   exec_mode
    b    .Lexit0
4:  GOT_LOAD x1, stderr            // serve: Phase 4
    ADR_L x0, m_serve
    bl   fputs
    mov  w0, #1
    b    .Lret
.Lexit0:
    mov  w0, #0
.Lret:
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x23, x24, [sp, #48]
    ldp  x29, x30, [sp], #64
    ret
.Lusage:
    ADR_L x0, m_usage
    mov  x1, #0
    mov  x2, #0
    bl   usage_exit
ENDF main

// session_loop(): read JSON lines from stdin until EOF.
LFUNC session_loop
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  xzr, xzr, [sp, #32]        // char *line = 0; size_t cap = 0
1:  add  x0, sp, #32
    add  x1, sp, #40
    GOT_LOAD x2, stdin
    bl   getline
    cmp  x0, #0
    b.lt 9f
    mov  x19, x0                    // length
    ldr  x20, [sp, #32]
    // strip trailing LF / CR
2:  cbz  x19, 3f
    sub  x2, x19, #1
    ldrb w3, [x20, x2]
    cmp  w3, #'\n'
    b.eq 21f
    cmp  w3, #'\r'
    b.ne 3f
21: mov  x19, x2
    b    2b
3:  // blank line?  (only spaces / tabs)
    mov  x2, #0
4:  cmp  x2, x19
    b.hs 1b
    ldrb w3, [x20, x2]
    add  x2, x2, #1
    cmp  w3, #' '
    b.eq 4b
    cmp  w3, #'\t'
    b.eq 4b
    mov  x0, x20
    mov  x1, x19
    bl   handle_request_line
    b    1b
9:  ldr  x0, [sp, #32]
    bl   free
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #48
    ret
ENDF session_loop

// exec_mode(): run the request(s) in --request FILE ('-' = stdin).
LFUNC exec_mode
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    LDR_G x19, g_request_file
    cbnz x19, 1f
    ADR_L x0, m_noreq
    mov  x1, #0
    mov  x2, #0
    bl   usage_exit
1:  mov  x0, x19
    ADR_L x1, s_dash
    bl   strcmp
    cbnz w0, 2f
    GOT_LOAD x20, stdin
    b    3f
2:  mov  x0, x19
    ADR_L x1, s_rb
    bl   fopen
    mov  x20, x0
    cbnz x0, 3f
    GOT_LOAD x0, stderr
    ADR_L x1, m_readfail
    mov  x2, x19
    bl   fprintf
    mov  w0, #1
    bl   exit
3:  // slurp the stream into a malloc'ed buffer (x21 ptr, x22 len)
    sub  sp, sp, #32
    stp  xzr, xzr, [sp]             // Buf {ptr,len,cap,_}
    stp  xzr, xzr, [sp, #16]
4:  mov  x0, sp
    mov  x1, #65536
    bl   buf_reserve
    mov  x1, #1
    mov  x2, #65536
    mov  x3, x20
    bl   fread
    cbz  x0, 5f
    ldr  x1, [sp, #BUF_LEN]
    add  x1, x1, x0
    str  x1, [sp, #BUF_LEN]
    b    4b
5:  ldr  x21, [sp, #BUF_PTR]
    ldr  x22, [sp, #BUF_LEN]
    add  sp, sp, #32
    mov  x0, x21
    mov  x1, x22
    bl   handle_request_batch
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x29, x30, [sp], #48
    ret
ENDF exec_mode

    NOTE_GNU_STACK
