# PolyQuery application task — Embedding API and the pqledger application

You are an autonomous software engineer. Your accepted **PolyQuery** analytical database
engine, written in **Rust**, is in `implementations/rust/` (it passes the full
conformance suite). You work alone, unattended, in this workspace. Nobody will answer
questions; make reasonable decisions yourself and document them.

## Your goal

Application and library task (identical for every language): your accepted engine (Phases 1–5 and all later changes) is in `implementations/rust/`. (1) Make the engine usable as a library from Rust programs: expose the embedding API specified in `spec/apps/embedding.md` (create an instance, load, query with typed result values, save/open, drop/list/schema, close; errors carrying the specification's error codes) and package it in the language's usual form (§2). (2) Build `pqledger`, the personal-finance command-line application specified in `spec/apps/pqledger.md`, on that API: importing bank-statement CSV exports in configurable formats, duplicate detection, rule-based categories, reports, budgets, ad-hoc SQL and three output formats, with the ledger stored as PQCF files that any other implementation can read. (3) Write the minimal embedding example `examples/embed-demo` (embedding.md §5). (4) Document both for their readers: `APP.md` for users — how to build, install, configure and use the application (a complete configuration reference with examples, the rules and budget files, every command with example output, exit codes, troubleshooting); `EMBEDDING.md` for developers — how to use the library from any Rust program (dependency set-up step by step with the standard build tool, API reference, value-type mapping, errors, resource management, thread safety, a complete minimal program). Link both from README.md.

The task is complete only when every check in "Definition of done" passes. Keep working —
building, testing, debugging — until that is true or you are certain it cannot be achieved.
Do not stop at a partial implementation, and never weaken, skip or special-case tests.

## The specification is the only authority

* `spec/apps/pqledger.md` defines the application, `spec/apps/embedding.md` the library API
  and the example program. The engine's own behaviour stays as defined by the rest of `spec/`.
* `tests/apps/pqledger/` contains the public test cases (`cases/*.json`, `embed/*.json`) and
  their runner; `runner.py`'s docstring explains the case format. Expected outputs were derived
  independently from the spec; if a case seems to contradict the spec, re-read the spec.
* Additional **hidden** cases (same format and spirit, different data and options, including a
  ledger of about 100,000 transactions) will be run after you finish. Implement the spec, not
  the tests.
* `datasets/generators/bankgen.py` generates realistic bank-statement exports in three formats
  for your own testing (`--print-config` shows the matching account settings).

## Rules (experimental controls — mandatory)

1. Write all code under `implementations/rust/`. Do not modify anything else in the
   workspace (spec, tests, generators, tools).
2. Language & toolchain: Rust 1.96.0 stable with Cargo (offline; `CARGO_NET_OFFLINE=true`). Use edition 2024. Release builds for the launcher.
3. **Standard library only.** Use only the language's standard library, its standard build tool
   and its standard test facility. No third-party packages or downloaded code of any kind.
   Only `std` (and `core`/`alloc`). No crates.io dependencies at all (no serde, no libc crate, no regex). If you need OS functionality std lacks (e.g. mmap, signals), declare the needed C functions yourself with `extern "C"` against the system libc.
4. Implement everything yourself from the spec. Do not copy code from elsewhere.
5. `pqledger` uses the engine **in-process through the embedding API**: it must not start
   `bin/polyquery` or any other engine process and must not open network connections (the
   hidden run traces system calls to check this). Reports, lists, budgets and category
   resolution are computed by SQL executed by the embedded engine.
6. The engine keeps everything it does today: `bin/polyquery`, its capabilities and the
   conformance suites (`tests/conformance/runner.py`, also with `--modes` and `--transport http`,
   and `tests/concurrency/http_suite.py`) must still pass. Refactor the engine into a library as
   far as needed, without changing its behaviour.
7. Write idiomatic, well-structured, maintainable Rust. Keep the application's source
   in `app/`, separate from the engine. Add unit tests (`make test`).
8. Commit your work to git regularly with meaningful messages (small, working increments).
   Your commits are the deliverable; uncommitted work is lost.

## How to test

```bash
make -C implementations/rust build
python3 tests/apps/pqledger/runner.py --app implementations/rust/bin/pqledger \
    --embed-demo implementations/rust/bin/pq-embed-demo -v
# one case while iterating; --keep leaves the case's directory for inspection:
python3 tests/apps/pqledger/runner.py --app implementations/rust/bin/pqledger --filter import-overlap -v
# the in-process check the hidden run applies (needs strace):
python3 tests/apps/pqledger/runner.py --app implementations/rust/bin/pqledger --trace
python3 tests/conformance/runner.py --engine implementations/rust/bin/polyquery
```

## Definition of done

`make build test` succeed; `python3 tests/apps/pqledger/runner.py --app implementations/rust/bin/pqledger --embed-demo implementations/rust/bin/pq-embed-demo --trace` passes every case; `python3 tests/conformance/runner.py --engine implementations/rust/bin/polyquery`, the same with `--modes` and with `--transport http`, `python3 tests/concurrency/http_suite.py --engine implementations/rust/bin/polyquery` and, if the engine claims `change.expression_limits`, `python3 tests/regression/robustness_probe.py --engine implementations/rust/bin/polyquery --only expression_limits --require-pass` all pass (0 failures, 0 errors, 0 not-implemented except optionally correlated subqueries); the engine claims exactly the capabilities it claimed before; `app/`, `examples/embed-demo/`, `APP.md` and `EMBEDDING.md` exist as specified; all work is committed.

When done, make sure everything is committed, then finish with a short summary: the library
API you exposed, how pqledger is structured, test results (the runners' summary lines), known
limitations, and the main design decisions.
