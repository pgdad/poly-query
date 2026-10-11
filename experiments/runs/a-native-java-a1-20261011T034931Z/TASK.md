# PolyQuery implementation task — Native kernel integration (M9)

You are an autonomous software engineer implementing **PolyQuery**, an analytical
database engine, in **Java**. You work alone, unattended, in this
workspace. Nobody will answer questions; make reasonable decisions yourself and
document them in `implementations/java/README.md`.

## Your goal

The workspace contains your accepted Phase 1–5 engine in `implementations/java/` and the native kernel library sources in `native-kernels/` (C ABI `native-kernels/include/pq_kernels.h`, C reference, runtime dispatch, x86-64 and AArch64 assembly). Build the library with `make -C native-kernels` (it produces `native-kernels/build/x86_64/libpqkernels.so`; never modify anything under `native-kernels/`). Integrate it into the engine through Java's standard FFI (see `spec/phases/native-kernels.md`): load it when `--native-kernels PATH` is given, use the kernels for filtering, aggregation, bitmap and hashing work when a query runs with the option `native: true` (and in vectorized mode where applicable), fall back to the engine's own code paths when the library is absent or a kernel does not apply, and claim the capability `native.kernels`. Results with and without native kernels MUST be identical (kernel overflow flags must be honoured exactly). Measure end-to-end impact on the generated 1m datasets and document it.

The task is complete only when the conformance runner reports **100% pass**
for the required phases (see "Definition of done"). Keep working — building,
testing, debugging — until that is true or you are certain it cannot be
achieved. Do not stop at a partial implementation, and never weaken, skip or
special-case tests.

## The specification is the only authority

* `spec/` defines all behaviour: start with `spec/README.md`, then
  `spec/phases/native-kernels.md` and the documents it references.
* `tests/conformance/` contains the public conformance suite and its runner.
  `tests/conformance/FORMAT.md` explains the `.pqt` test format. Expected
  results in the tests were derived independently from the spec; if a test
  seems to contradict the spec, re-read the spec — the test is almost certainly right.
* Additional **hidden** acceptance tests (same format and spirit, different
  queries/data) will be run after you finish. Implement the spec, not the tests.

## Rules (experimental controls — mandatory)

1. Write all code under `implementations/java/`. Do not modify anything
   else in the workspace (spec, tests, fixtures, tools).
2. Language & toolchain: Java 27 (OpenJDK 27 at $JAVA_HOME=/usr/lib/jvm/jdk-27; `java`/`javac`/`jar` are on PATH). Build with plain `javac`/`jar` from the Makefile or with Maven (`mvn`, offline; plugins already cached may be used, but no dependencies). Target release 27.
3. **Standard library only.** Use only the language's standard library, its
   standard build tool and its standard test facility. No third-party packages
   or downloaded code of any kind. The JDK (java.*, javax.*, jdk.* modules incl. com.sun.net.httpserver, java.util.concurrent, java.nio, the Foreign Function & Memory API and the incubating Vector API) is the standard library. JUnit is NOT available: write tests with plain Java (e.g. a small test main) or `assert`.
4. Implement everything yourself from the spec. Do not copy code from elsewhere.
5. The engine must satisfy the layout contract in `spec/protocol/protocol.md` §1:
   a `Makefile` with targets `build`, `test`, `lint`, `fmt`, `clean`; an
   executable launcher `bin/polyquery` that works from any directory; `README.md`;
   and `ENGINE.json` (`{"language": "java", "track": "A", "libraries": []}`).
   `make build` must work from a clean checkout with no network access.
6. Write idiomatic, well-structured, maintainable Java. Keep the
   architecture clean (separate lexer, parser/AST, semantic analysis, planning,
   execution, storage, protocol layers). Add unit tests for core components
   (`make test`).
7. Commit your work to git regularly with meaningful messages (small, working
   increments). Your commits are the deliverable; uncommitted work is lost.
8. Performance matters but correctness comes first. Avoid pathological
   algorithms (e.g. quadratic scans where hashing is natural).

## How to test

```bash
make -C implementations/java build
python3 tests/conformance/runner.py --engine implementations/java/bin/polyquery --native native-kernels/build/x86_64/libpqkernels.so -v
# focus on one file while iterating:
python3 tests/conformance/runner.py --engine implementations/java/bin/polyquery --filter phase1/expressions -v
```

The runner starts `bin/polyquery session --data-dir <tmp>` per test file and
speaks the JSON-lines protocol. Engine logs (stderr) can be captured with
`--logs DIR`. Generated larger datasets are available via
`python3 datasets/generators/pqgen.py generate --scale 100k` if you want to
check performance.

## Definition of done

`python3 tests/conformance/runner.py --engine implementations/java/bin/polyquery --native native-kernels/build/x86_64/libpqkernels.so` and the same with `--modes` report 0 failures, 0 errors and 0 not-implemented (except optionally correlated subqueries); all earlier conformance (session, `--transport http`, `--modes`) and the HTTP suite still pass without the library; `make build test` succeed; README.md documents the FFI design, which kernels are used where, and before/after measurements with `native: true`; all work is committed.

When done, make sure everything is committed, then finish with a short summary:
what you implemented, test results (the runner's summary lines), known
limitations, and the main design decisions.
