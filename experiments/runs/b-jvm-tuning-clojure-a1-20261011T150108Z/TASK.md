# PolyQuery Track B (ecosystem-optimized) task — JVM build and start-up tuning (Track B)

You are an autonomous software engineer implementing **PolyQuery**, an analytical
database engine, in **Clojure**. You work alone, unattended, in this
workspace. Nobody will answer questions; make reasonable decisions yourself and
document them in `implementations/clojure/README.md`.

## Your goal

Track B tuning task (identical for both JVM languages): your accepted engine is in `implementations/clojure/`. Tune its build and runtime for (1) start-up time (process spawn to first protocol response), (2) first-query (cold) latency and (3) warm query latency on the benchmark workload `benchmarks/workloads/analytics.json` at scale 1m (generate with `python3 datasets/generators/pqgen.py generate --scale 1m`), without changing results. Work through these areas and keep only changes whose effect you measured beyond run-to-run noise:

* **Compilation:** verify that the engine is fully ahead-of-time compiled (no namespace compiled or loaded from source at run time; check with class-loading logs) and that direct linking is in effect on hot call sites (inspect bytecode with `javap -c`); consider compiler options such as `:elide-meta`; enable `*unchecked-math* :warn-on-boxed` in the lint build and make lint fail on boxed math in hot namespaces; keep `*warn-on-reflection*` everywhere.
* **Boxing and dispatch in hot loops:** find and remove boxed arithmetic and boxed collections, reflective calls and avoidable dynamic dispatch in the execution, storage and value code. SQL overflow semantics stay exact: wherever `NUMERIC_OVERFLOW` must be raised, use checked operations (e.g. `Math.addExact`), never silently wrapping arithmetic.
* **JVM start-up:** a JDK AOT cache (JDK 27: `-XX:AOTCacheOutput` during `make build`, `-XX:AOTCache` in the launcher) or CDS. Any training run must use synthetic data and generic queries, never the benchmark queries. A stale or unusable cache must be ignored silently (stdout carries the protocol), and `make build` must still succeed if training fails.
* **JVM flags:** evaluate candidates one at a time (GC choice, heap sizing, `-XX:-UsePerfData`, code cache, pre-touch). Do not use `-XX:TieredStopAtLevel=1` (it trades steady-state speed for start-up). Report the memory (RSS) cost of each kept flag.

Measure before/after yourself through `bin/polyquery session` (start-up, first run and warm median per workload query) and report the results in README.md.

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

1. Write all code under `implementations/clojure/`. Do not modify anything
   else in the workspace (spec, tests, fixtures, tools).
2. Language & toolchain: Clojure 1.12.3 via the `clojure`/`clj` CLI and tools.deps (deps.edn), running on OpenJDK 27 ($JAVA_HOME=/usr/lib/jvm/jdk-27). The only allowed dependency coordinate is org.clojure/clojure itself (already in the local Maven cache; there is no network).
3. **Track B: tuning is allowed.** Unlike the controlled track, you may change
   compiler options, build steps, launcher/runtime flags and code structure for
   performance. The workspace has no network access, so no new third-party
   dependencies are available; use only what the toolchain ships. Record every
   tuning decision (flag, option, build step) in `ENGINE.json` under `"tuning"`.
4. Implement everything yourself from the spec. Do not copy code from elsewhere.
5. The engine must satisfy the layout contract in `spec/protocol/protocol.md` §1:
   a `Makefile` with targets `build`, `test`, `lint`, `fmt`, `clean`; an
   executable launcher `bin/polyquery` that works from any directory; `README.md`;
   and `ENGINE.json` (set `"track": "B"` and keep `"libraries": []`).
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
python3 tests/conformance/runner.py --engine implementations/clojure/bin/polyquery  -v
# focus on one file while iterating:
python3 tests/conformance/runner.py --engine implementations/clojure/bin/polyquery --filter phase1/expressions -v
```

The runner starts `bin/polyquery session --data-dir <tmp>` per test file and
speaks the JSON-lines protocol. Engine logs (stderr) can be captured with
`--logs DIR`. Generated larger datasets are available via
`python3 datasets/generators/pqgen.py generate --scale 100k` if you want to
check performance.

## Definition of done

Conformance is unchanged: `python3 tests/conformance/runner.py --engine implementations/clojure/bin/polyquery` passes everything it passed before, as do `--modes`, `--transport http`, `--native native-kernels/build/x86_64/libpqkernels.so` (build the library with `make -C native-kernels`) and `python3 tests/concurrency/http_suite.py --engine implementations/clojure/bin/polyquery`; the capability set is unchanged; `make build test lint` succeed; README.md has a tuning section listing every technique tried as kept or dropped with its measured effect (start-up, cold, warm, RSS); `ENGINE.json` records the kept tuning; all work is committed.

When done, make sure everything is committed, then finish with a short summary:
what you implemented, test results (the runner's summary lines), known
limitations, and the main design decisions.
