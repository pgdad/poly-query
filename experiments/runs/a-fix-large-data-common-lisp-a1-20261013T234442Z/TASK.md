# PolyQuery implementation task — Defect fix — large data (10m rows) and memory exhaustion

You are an autonomous software engineer implementing **PolyQuery**, an analytical
database engine, in **Common Lisp**. You work alone, unattended, in this
workspace. Nobody will answer questions; make reasonable decisions yourself and
document them in `implementations/common-lisp/README.md`.

## Your goal

Defect report (engine-specific): your accepted engine (Phases 1–5 and all later changes) is in `implementations/common-lisp/`. It cannot run the benchmark workload at 10 million rows. When the 9 tables of `benchmarks/workloads/analytics.json` are generated at scale 10m (`python3 datasets/generators/pqgen.py generate --scale 10m --jobs 8`, about 1.9 GB of CSV; the largest file, transactions.csv, is 0.87 GB) and loaded, the engine process dies while loading the first table, before any query runs, instead of answering. This violates the specification: an engine MUST NOT crash, hang or exit on any request, and out-of-memory conditions are reported as `RESOURCE_LIMIT` (`spec/errors/errors.md`); default ingestion limits allow at least 2 GiB of input and 200,000,000 rows (`spec/data-types/ingestion.md` §3); `--max-query-memory-mb` and `--max-ingest-bytes` are enforced with `RESOURCE_LIMIT` (`spec/sql/semantics.md` §15, `spec/protocol/protocol.md`). Fix the engine so that (1) the full 10m workload loads and all 20 queries answer correctly, and (2) when memory really runs out — e.g. many large tables loaded into one process — the request fails with `RESOURCE_LIMIT` and the engine keeps serving instead of dying. The host has ample memory (≈250 GB); a run that exceeds 120 GiB is stopped by the check. Keep all existing behaviour, capabilities and performance at smaller scales. The public check is `tests/regression/large_data_probe.py` (read its docstring: checks workload, query_budget, ingest_limit, exhaustion).

The task is complete only when the conformance runner reports **100% pass**
for the required phases (see "Definition of done"). Keep working — building,
testing, debugging — until that is true or you are certain it cannot be
achieved. Do not stop at a partial implementation, and never weaken, skip or
special-case tests.

## The specification is the only authority

* `spec/` defines all behaviour: start with `spec/README.md`, then
  `spec/phases/phase-5.md` and the documents it references.
* `tests/conformance/` contains the public conformance suite and its runner.
  `tests/conformance/FORMAT.md` explains the `.pqt` test format. Expected
  results in the tests were derived independently from the spec; if a test
  seems to contradict the spec, re-read the spec — the test is almost certainly right.
* Additional **hidden** acceptance tests (same format and spirit, different
  queries/data) will be run after you finish. Implement the spec, not the tests.

## Rules (experimental controls — mandatory)

1. Write all code under `implementations/common-lisp/`. Do not modify anything
   else in the workspace (spec, tests, fixtures, tools).
2. Language & toolchain: SBCL 2.6.9 (`sbcl` on PATH, /opt/sbcl) with ASDF (bundled). Build a standalone executable or a core image via the Makefile (e.g. `sb-ext:save-lisp-and-die`); `bin/polyquery` may also start sbcl with a prebuilt core.
3. **Standard library only.** Use only the language's standard library, its
   standard build tool and its standard test facility. No third-party packages
   or downloaded code of any kind. Only ANSI Common Lisp, SBCL's own extensions (sb-ext, sb-sys, sb-alien, sb-unix, sb-int, sb-impl, sb-thread, sb-kernel) and the contribs bundled with SBCL (asdf, uiop, sb-bsd-sockets, sb-posix, sb-concurrency, sb-rotate-byte, sb-md5, sb-cltl2, sb-introspect, sb-simd, sb-sprof, sb-rt). No Quicklisp, no third-party systems (no alexandria, cl-json, hunchentoot, cl-ppcre, bordeaux-threads).
4. Implement everything yourself from the spec. Do not copy code from elsewhere.
5. The engine must satisfy the layout contract in `spec/protocol/protocol.md` §1:
   a `Makefile` with targets `build`, `test`, `lint`, `fmt`, `clean`; an
   executable launcher `bin/polyquery` that works from any directory; `README.md`;
   and `ENGINE.json` (`{"language": "common-lisp", "track": "A", "libraries": []}`).
   `make build` must work from a clean checkout with no network access.
6. Write idiomatic, well-structured, maintainable Common Lisp. Keep the
   architecture clean (separate lexer, parser/AST, semantic analysis, planning,
   execution, storage, protocol layers). Add unit tests for core components
   (`make test`).
7. Commit your work to git regularly with meaningful messages (small, working
   increments). Your commits are the deliverable; uncommitted work is lost.
8. Performance matters but correctness comes first. Avoid pathological
   algorithms (e.g. quadratic scans where hashing is natural).

## How to test

```bash
make -C implementations/common-lisp build
python3 tests/conformance/runner.py --engine implementations/common-lisp/bin/polyquery  -v
# focus on one file while iterating:
python3 tests/conformance/runner.py --engine implementations/common-lisp/bin/polyquery --filter phase1/expressions -v
```

The runner starts `bin/polyquery session --data-dir <tmp>` per test file and
speaks the JSON-lines protocol. Engine logs (stderr) can be captured with
`--logs DIR`. Generated larger datasets are available via
`python3 datasets/generators/pqgen.py generate --scale 100k` if you want to
check performance.

## Definition of done

`python3 tests/regression/large_data_probe.py --engine implementations/common-lisp/bin/polyquery --require-pass` exits 0; `python3 tests/conformance/runner.py --engine implementations/common-lisp/bin/polyquery`, the same with `--modes` and with `--transport http`, `python3 tests/concurrency/http_suite.py --engine implementations/common-lisp/bin/polyquery` and `python3 tests/regression/robustness_probe.py --engine implementations/common-lisp/bin/polyquery --only expression_limits --require-pass` all pass (0 failures, 0 errors, 0 not-implemented except optionally correlated subqueries); the engine keeps every capability it claimed before; `make build test` succeed; README.md documents the memory model and limits and which modules the fix touched; generated data is not committed; all work is committed.

When done, make sure everything is committed, then finish with a short summary:
what you implemented, test results (the runner's summary lines), known
limitations, and the main design decisions.
