# PolyQuery implementation task — Optimization — scaling to 10m rows

You are an autonomous software engineer implementing **PolyQuery**, an analytical
database engine, in **x86-64 assembly**. You work alone, unattended, in this
workspace. Nobody will answer questions; make reasonable decisions yourself and
document them in `implementations/x86_64-asm-engine/README.md`.

## Your goal

Performance problem report (engine-specific; no requirement change): your accepted engine (Phases 1–5 and all later changes) is in `implementations/x86_64-asm-engine/`. It scales badly from 1 million to 10 million rows on the benchmark workload `benchmarks/workloads/analytics.json`, measured with the project's harness `benchmarks/harness/bench.py` (one session per engine: all nine tables loaded, the workload's two indexes created, then 3 warm-up and 7 measured rounds in which the 20 queries run in a random order per round; 16 CPUs). Geometric mean of the 20 per-query medians: 2.86 ms at 1m, 70.7 ms at 10m (24.8x for 10x the data; the other engines of the project grow 6–10x). Worst queries (1m -> 10m median): q01_filter_selective 0.05 -> 27.3 ms, q05_groupby_low_card 1.6 -> 41.5 ms, q16_timeseries_hourly 0.8 -> 22.0 ms, q14_sort_full_string 15.4 -> 411 ms, q12_left_join_anti 6.7 -> 183 ms, q10_join_customers 7.1 -> 188 ms. HTTP throughput (`serve`, transactions and customers loaded, q01/q03/q05/q09) falls from 190–232 qps at 16 clients (1m) to 17 qps (10m); single-client median latency 18 ms -> 160 ms. Black-box observations of the engine process at 10m, none of which occur at 1m: (1) the latency the client sees is much larger than the engine's own `stats.elapsed_us`: q01 27.3 ms wall vs 0.05 ms reported, and about 365 ms of the 2,220 ms per round lie outside the reported time (at 1m the difference is below 0.15 ms per query); (2) a query's latency depends on what ran before it in the session: in a fresh session with all 10m tables loaded q01 takes 0.03 ms, q05 12.9 ms, q16 1.7 ms, q17 0.9 ms, but 21, 22, 4.6 and 20.8 ms in the interleaved benchmark order; (3) per round of the 20 queries the process takes about 2.1 million minor page faults and 4.6 s of system CPU (q15 496k faults, q14 415k, q10 188k, q07 151k; repeating one query back to back still faults every time), versus 54 minor faults and no measurable system CPU per round at 1m. Single-threaded operator time grows about linearly (q02 with `threads: 1`: 15 ms -> 155 ms). Find and remove the causes of the super-linear growth (session mode first; HTTP mode too if you can) without changing any result. Reproduce: `python3 datasets/generators/pqgen.py generate --scale 10m --jobs 8` and the same with `--scale 1m` (use `--jobs 1` if multiprocessing fails; output goes to the git-ignored `datasets/generated/`, about 2 GB for 10m), then `python3 benchmarks/harness/bench.py --engines x86_64-asm-engine --scale 10m --no-sandbox --cpus '' --mem-limit-gb 0 --label <name>` (you are already inside a sandbox; add `--http` for the throughput part, `--queries q01,q05` for a subset, `--reps`/`--warmup` to shorten). It writes `results/performance/<id>/summary.json` (per-query `latency_seconds` medians and result `digests`) and `raw.jsonl.gz` (per execution incl. `engine_elapsed_us`). A full 10m run of this engine takes several minutes; the host has 32 logical CPUs and over 200 GB of RAM, and the engine's peak RSS at 10m is about 12 GB.

**Sessions.** This task is larger than one working session. Each session lasts at most 180 minutes; if the task is not done when a session ends, a new session (up to 1 in total) continues from your committed work, with this same task text. Commit often, and keep `implementations/x86_64-asm-engine/NOTES.md` current: what works, what is missing, what to do next.

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
python3 tests/conformance/runner.py --engine implementations/x86_64-asm-engine/bin/polyquery  -v
# focus on one file while iterating:
python3 tests/conformance/runner.py --engine implementations/x86_64-asm-engine/bin/polyquery --filter phase1/expressions -v
```

The runner starts `bin/polyquery session --data-dir <tmp>` per test file and
speaks the JSON-lines protocol. Engine logs (stderr) can be captured with
`--logs DIR`. Generated larger datasets are available via
`python3 datasets/generators/pqgen.py generate --scale 100k` if you want to
check performance.

## Definition of done

README.md contains a before/after table (bench.py medians of all 20 queries plus the geometric mean, at 10m and at 1m, same host and settings, measured back to back) and a short explanation of the causes found and the change; the 10m geometric mean improves measurably, no query gets slower at 1m beyond measurement noise, and every query's result digest at 1m and at 10m is identical before and after; peak RSS at 10m does not grow by more than about 25 %. All public checks still pass: `python3 tests/conformance/runner.py --engine implementations/x86_64-asm-engine/bin/polyquery`, the same with `--modes` and with `--transport http`, `python3 tests/concurrency/http_suite.py --engine implementations/x86_64-asm-engine/bin/polyquery` and `python3 tests/regression/robustness_probe.py --engine implementations/x86_64-asm-engine/bin/polyquery --only expression_limits --require-pass` (0 failures, 0 errors, 0 not-implemented except optionally correlated subqueries); the capability set is unchanged; `make build test` succeed; generated data and benchmark results are not committed; all work is committed.

When done, make sure everything is committed, then finish with a short summary:
what you implemented, test results (the runner's summary lines), known
limitations, and the main design decisions.
