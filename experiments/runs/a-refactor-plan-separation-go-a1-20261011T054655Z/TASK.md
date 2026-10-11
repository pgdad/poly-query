# PolyQuery implementation task — Refactoring — logical/physical plan separation

You are an autonomous software engineer implementing **PolyQuery**, an analytical
database engine, in **Go**. You work alone, unattended, in this
workspace. Nobody will answer questions; make reasonable decisions yourself and
document them in `implementations/go/README.md`.

## Your goal

Behaviour-preserving refactoring (identical for every language): your accepted engine (Phases 1–5 and native kernels) is in `implementations/go/`. Restructure it as specified in `spec/changes/refactor-plan-separation.md`: an explicit logical plan representation, a rule-based optimizer made of separately named and unit-tested rules that operates only on the logical plan (honouring `optimize: false`), and a separate physical planning step that alone decides access paths, join algorithms, execution mode and native kernels. No externally visible behaviour may change.

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

1. Write all code under `implementations/go/`. Do not modify anything
   else in the workspace (spec, tests, fixtures, tools).
2. Language & toolchain: Go 1.27.1 (`go` on PATH; GOTOOLCHAIN=local, GOPROXY=off — no module downloads). Use a go.mod with no requirements.
3. **Standard library only.** Use only the language's standard library, its
   standard build tool and its standard test facility. No third-party packages
   or downloaded code of any kind. Only the Go standard library (net/http, encoding/json, encoding/csv, sync, context, hash/crc32, syscall, testing, …). No external modules, including golang.org/x/*.
4. Implement everything yourself from the spec. Do not copy code from elsewhere.
5. The engine must satisfy the layout contract in `spec/protocol/protocol.md` §1:
   a `Makefile` with targets `build`, `test`, `lint`, `fmt`, `clean`; an
   executable launcher `bin/polyquery` that works from any directory; `README.md`;
   and `ENGINE.json` (`{"language": "go", "track": "A", "libraries": []}`).
   `make build` must work from a clean checkout with no network access.
6. Write idiomatic, well-structured, maintainable Go. Keep the
   architecture clean (separate lexer, parser/AST, semantic analysis, planning,
   execution, storage, protocol layers). Add unit tests for core components
   (`make test`).
7. Commit your work to git regularly with meaningful messages (small, working
   increments). Your commits are the deliverable; uncommitted work is lost.
8. Performance matters but correctness comes first. Avoid pathological
   algorithms (e.g. quadratic scans where hashing is natural).

## How to test

```bash
make -C implementations/go build
python3 tests/conformance/runner.py --engine implementations/go/bin/polyquery  -v
# focus on one file while iterating:
python3 tests/conformance/runner.py --engine implementations/go/bin/polyquery --filter phase1/expressions -v
```

The runner starts `bin/polyquery session --data-dir <tmp>` per test file and
speaks the JSON-lines protocol. Engine logs (stderr) can be captured with
`--logs DIR`. Generated larger datasets are available via
`python3 datasets/generators/pqgen.py generate --scale 100k` if you want to
check performance.

## Definition of done

Every conformance suite that passed before still passes: `python3 tests/conformance/runner.py --engine implementations/go/bin/polyquery`, the same with `--modes`, with `--transport http`, with `--native native-kernels/build/x86_64/libpqkernels.so` (build the library with `make -C native-kernels`), and `python3 tests/concurrency/http_suite.py --engine implementations/go/bin/polyquery`; the capability set is unchanged; each optimizer rule has unit tests; `make build test` succeed; README.md contains a before/after module map; all work is committed.

When done, make sure everything is committed, then finish with a short summary:
what you implemented, test results (the runner's summary lines), known
limitations, and the main design decisions.
