# PolyQuery implementation task — Phase 5 — Optimization

You are an autonomous software engineer implementing **PolyQuery**, an analytical
database engine, in **Python**. You work alone, unattended, in this
workspace. Nobody will answer questions; make reasonable decisions yourself and
document them in `implementations/python/README.md`.

## Your goal

The workspace contains your accepted Phase 1–4 engine. Extend it to **Phase 5** (`spec/phases/phase-5.md`): keep a row-at-a-time baseline (`mode: row`) and add vectorized/batch execution (`mode: vectorized`), parallel scans and aggregations (`threads`), hash, sort-merge and nested-loop joins selectable via the `join` option, a switchable logical optimizer (`optimize`), SIMD-friendly or explicitly SIMD filtering/aggregation where the standard library permits, memory-allocation optimizations and cache-aware layouts. Measure your improvements with the generated datasets (e.g. `pqgen.py generate --scale 1m`). Every option combination must produce identical results.

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

1. Write all code under `implementations/python/`. Do not modify anything
   else in the workspace (spec, tests, fixtures, tools).
2. Language & toolchain: CPython 3.14 (`python3` on PATH is 3.14). No virtualenv or pip installs are possible or needed.
3. **Standard library only.** Use only the language's standard library, its
   standard build tool and its standard test facility. No third-party packages
   or downloaded code of any kind. Only the Python standard library (json, csv, http.server, socketserver, threading, concurrent.futures, mmap, zlib, struct, decimal, datetime, unittest, …). No third-party packages (no numpy, pandas, pyarrow, sqlite-based query execution is NOT allowed: the `sqlite3` module must not be used).
4. Implement everything yourself from the spec. Do not copy code from elsewhere.
5. The engine must satisfy the layout contract in `spec/protocol/protocol.md` §1:
   a `Makefile` with targets `build`, `test`, `lint`, `fmt`, `clean`; an
   executable launcher `bin/polyquery` that works from any directory; `README.md`;
   and `ENGINE.json` (`{"language": "python", "track": "A", "libraries": []}`).
   `make build` must work from a clean checkout with no network access.
6. Write idiomatic, well-structured, maintainable Python. Keep the
   architecture clean (separate lexer, parser/AST, semantic analysis, planning,
   execution, storage, protocol layers). Add unit tests for core components
   (`make test`).
7. Commit your work to git regularly with meaningful messages (small, working
   increments). Your commits are the deliverable; uncommitted work is lost.
8. Performance matters but correctness comes first. Avoid pathological
   algorithms (e.g. quadratic scans where hashing is natural).

## How to test

```bash
make -C implementations/python build
python3 tests/conformance/runner.py --engine implementations/python/bin/polyquery --modes -v
# focus on one file while iterating:
python3 tests/conformance/runner.py --engine implementations/python/bin/polyquery --filter phase1/expressions -v
```

The runner starts `bin/polyquery session --data-dir <tmp>` per test file and
speaks the JSON-lines protocol. Engine logs (stderr) can be captured with
`--logs DIR`. Generated larger datasets are available via
`python3 datasets/generators/pqgen.py generate --scale 100k` if you want to
check performance.

## Definition of done

`python3 tests/conformance/runner.py --engine implementations/python/bin/polyquery` (all phases) and `... --modes` both report 0 failures, 0 errors and 0 not-implemented (except optionally correlated subqueries), the HTTP suite still passes, `make build test` succeed, and README.md documents the optimizations with before/after measurements you took; all work is committed.

When done, make sure everything is committed, then finish with a short summary:
what you implemented, test results (the runner's summary lines), known
limitations, and the main design decisions.
