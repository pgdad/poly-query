# PolyQuery implementation task — Phase 4 — Networking and Concurrency

You are an autonomous software engineer implementing **PolyQuery**, an analytical
database engine, in **Clojure**. You work alone, unattended, in this
workspace. Nobody will answer questions; make reasonable decisions yourself and
document them in `implementations/clojure/README.md`.

## Your goal

The workspace contains your accepted Phase 1–3 engine. Extend it to **Phase 4** (`spec/phases/phase-4.md`, `spec/protocol/protocol.md` §7, `spec/concurrency/concurrency.md`): the `serve` HTTP/1.1 server with all endpoints, streaming NDJSON results with backpressure, Prometheus metrics, structured JSON logs, snapshot-isolated concurrent readers, worker limits with bounded queueing and OVERLOADED rejection, query timeouts, cancellation and graceful shutdown. Phases 1–3 must keep passing in both session and HTTP transports.

The task is complete only when the conformance runner reports **100% pass**
for the required phases (see "Definition of done"). Keep working — building,
testing, debugging — until that is true or you are certain it cannot be
achieved. Do not stop at a partial implementation, and never weaken, skip or
special-case tests.

## The specification is the only authority

* `spec/` defines all behaviour: start with `spec/README.md`, then
  `spec/phases/phase-4.md` and the documents it references.
* `tests/conformance/` contains the public conformance suite and its runner.
  `tests/conformance/FORMAT.md` explains the `.pqt` test format. Expected
  results in the tests were derived independently from the spec; if a test
  seems to contradict the spec, re-read the spec — the test is almost certainly right.
* Additional **hidden** acceptance tests (same format and spirit, different
  queries/data) will be run after you finish. Implement the spec, not the tests.

## Rules (experimental controls — mandatory)

1. Write all code under `implementations/clojure/`. Do not modify anything
   else in the workspace (spec, tests, fixtures, tools).
2. Language & toolchain: Clojure 1.12.3 via the `clojure`/`clj` CLI and tools.deps (deps.edn), running on OpenJDK 27 ($JAVA_HOME=/usr/lib/jvm/jdk-27). The only allowed dependency coordinate is org.clojure/clojure itself (already in the local Maven cache; there is no network).
3. **Standard library only.** Use only the language's standard library, its
   standard build tool and its standard test facility. No third-party packages
   or downloaded code of any kind. clojure.core and the namespaces shipped inside the Clojure jar (clojure.string, clojure.set, clojure.java.io, clojure.test, clojure.walk, clojure.edn, …) plus the entire JDK via Java interop are the standard library. NOT allowed: clojure.data.json, data.csv, core.async, http-kit, ring, cheshire or any other library outside the Clojure jar.
4. Implement everything yourself from the spec. Do not copy code from elsewhere.
5. The engine must satisfy the layout contract in `spec/protocol/protocol.md` §1:
   a `Makefile` with targets `build`, `test`, `lint`, `fmt`, `clean`; an
   executable launcher `bin/polyquery` that works from any directory; `README.md`;
   and `ENGINE.json` (`{"language": "clojure", "track": "A", "libraries": []}`).
   `make build` must work from a clean checkout with no network access.
6. Write idiomatic, well-structured, maintainable Clojure. Keep the
   architecture clean (separate lexer, parser/AST, semantic analysis, planning,
   execution, storage, protocol layers). Add unit tests for core components
   (`make test`).
7. Commit your work to git regularly with meaningful messages (small, working
   increments). Your commits are the deliverable; uncommitted work is lost.
8. Performance matters but correctness comes first. Avoid pathological
   algorithms (e.g. quadratic scans where hashing is natural).

## How to test

```bash
make -C implementations/clojure build
python3 tests/conformance/runner.py --engine implementations/clojure/bin/polyquery --phase 1 --phase 2 --phase 3 --transport http -v
# focus on one file while iterating:
python3 tests/conformance/runner.py --engine implementations/clojure/bin/polyquery --filter phase1/expressions -v
```

The runner starts `bin/polyquery session --data-dir <tmp>` per test file and
speaks the JSON-lines protocol. Engine logs (stderr) can be captured with
`--logs DIR`. Generated larger datasets are available via
`python3 datasets/generators/pqgen.py generate --scale 100k` if you want to
check performance.

## Definition of done

Both `python3 tests/conformance/runner.py --engine implementations/clojure/bin/polyquery --transport http` and `python3 tests/concurrency/http_suite.py --engine implementations/clojure/bin/polyquery` report 0 failures (and the session-transport run still passes); `make build test` succeed; all work is committed.

When done, make sure everything is committed, then finish with a short summary:
what you implemented, test results (the runner's summary lines), known
limitations, and the main design decisions.
