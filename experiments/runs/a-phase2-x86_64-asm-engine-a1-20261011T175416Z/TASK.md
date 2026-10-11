# PolyQuery implementation task — Phase 2 — SQL Parser and Query Engine

You are an autonomous software engineer implementing **PolyQuery**, an analytical
database engine, in **x86-64 assembly**. You work alone, unattended, in this
workspace. Nobody will answer questions; make reasonable decisions yourself and
document them in `implementations/x86_64-asm-engine/README.md`.

## Your goal

The workspace contains your accepted Phase 1 engine in `implementations/x86_64-asm-engine/`. Extend it to **Phase 2** (`spec/phases/phase-2.md`): the complete SQL grammar and semantics (GROUP BY/HAVING, DISTINCT, INNER/LEFT/CROSS joins, all scalar functions, CASE/LIKE/BETWEEN/IN, uncorrelated subqueries, derived tables, CTEs, EXPLAIN) with distinct lexer, parser/AST, semantic validation, logical plan, physical plan and execution stages, and structured errors. Correlated subqueries (`sql.correlated_subquery`) are optional: implement them if you can; otherwise answer UNSUPPORTED and do not claim the capability. Phase 1 must keep passing.

**Sessions.** This task is larger than one working session. Each session lasts at most 120 minutes; if the task is not done when a session ends, a new session (up to 3 in total) continues from your committed work, with this same task text. Commit often, and keep `implementations/x86_64-asm-engine/NOTES.md` current: what works, what is missing, what to do next.

The task is complete only when the conformance runner reports **100% pass**
for the required phases (see "Definition of done"). Keep working — building,
testing, debugging — until that is true or you are certain it cannot be
achieved. Do not stop at a partial implementation, and never weaken, skip or
special-case tests.

## The specification is the only authority

* `spec/` defines all behaviour: start with `spec/README.md`, then
  `spec/phases/phase-2.md` and the documents it references.
* `tests/conformance/` contains the public conformance suite and its runner.
  `tests/conformance/FORMAT.md` explains the `.pqt` test format. Expected
  results in the tests were derived independently from the spec; if a test
  seems to contradict the spec, re-read the spec — the test is almost certainly right.
* Additional **hidden** acceptance tests (same format and spirit, different
  queries/data) will be run after you finish. Implement the spec, not the tests.

## Rules (experimental controls — mandatory)

1. Write all code under `implementations/x86_64-asm-engine/`. Do not modify anything
   else in the workspace (spec, tests, fixtures, tools).
2. Language & toolchain: GNU assembler (binutils 2.42) with gcc 13.3 used only as the preprocessor/assembler and linker driver (`.S` files; AT&T syntax or `.intel_syntax noprefix`; NASM 2.16 is also installed). x86-64 Linux (AMD Zen 5; AVX2 and AVX-512 are available but SIMD is optional). gdb, strace and objdump are available for debugging.
3. **Standard library only.** Use only the language's standard library, its
   standard build tool and its standard test facility. No third-party packages
   or downloaded code of any kind. For assembly the standard library is glibc, dynamically linked: libc, libm and libpthread (malloc, threads, sockets, file I/O, strtod/snprintf/strtoll for number text, qsort, memcpy and so on). No other libraries. No C, C++ or other high-level source files anywhere in the build, not even small helpers or test drivers, and no compiler-generated assembly (never write C and compile it with -S or similar): every instruction is written by you. Makefiles, shell scripts and test data are fine.
4. Implement everything yourself from the spec. Do not copy code from elsewhere.
5. The engine must satisfy the layout contract in `spec/protocol/protocol.md` §1:
   a `Makefile` with targets `build`, `test`, `lint`, `fmt`, `clean`; an
   executable launcher `bin/polyquery` that works from any directory; `README.md`;
   and `ENGINE.json` (`{"language": "x86_64-asm-engine", "track": "A", "libraries": []}`).
   `make build` must work from a clean checkout with no network access.
6. Write idiomatic, well-structured, maintainable x86-64 assembly. Keep the
   architecture clean (separate lexer, parser/AST, semantic analysis, planning,
   execution, storage, protocol layers). Add unit tests for core components
   (`make test`).
7. Commit your work to git regularly with meaningful messages (small, working
   increments). Your commits are the deliverable; uncommitted work is lost.
8. Performance matters but correctness comes first. Avoid pathological
   algorithms (e.g. quadratic scans where hashing is natural).
9. **Assembly specifics.** Follow the System V AMD64 ABI at every call into glibc (16-byte stack alignment at each call, callee-saved registers preserved, `%al` set for variadic calls) and in your own functions; mark every object with a `.note.GNU-stack` section (no executable stack). `bin/polyquery` may be a small shell script that execs the assembled binary. Unit tests (`make test`) are assembly test programs or shell scripts that drive the binary. Structure the code into modules (separate `.S` files and include files with macros) so it stays maintainable.

## How to test

```bash
make -C implementations/x86_64-asm-engine build
python3 tests/conformance/runner.py --engine implementations/x86_64-asm-engine/bin/polyquery --phase 1 --phase 2 -v
# focus on one file while iterating:
python3 tests/conformance/runner.py --engine implementations/x86_64-asm-engine/bin/polyquery --filter phase1/expressions -v
```

The runner starts `bin/polyquery session --data-dir <tmp>` per test file and
speaks the JSON-lines protocol. Engine logs (stderr) can be captured with
`--logs DIR`. Generated larger datasets are available via
`python3 datasets/generators/pqgen.py generate --scale 100k` if you want to
check performance.

## Definition of done

`python3 tests/conformance/runner.py --engine implementations/x86_64-asm-engine/bin/polyquery --phase 1 --phase 2` reports 0 failures, 0 errors and 0 not-implemented cases except, optionally, the `sql.correlated_subquery` file; `make build test` succeed; all work is committed.

When done, make sure everything is committed, then finish with a short summary:
what you implemented, test results (the runner's summary lines), known
limitations, and the main design decisions.
