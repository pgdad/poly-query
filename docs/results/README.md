# PolyQuery results — Track A (2026-10-10/11)

This page summarizes the first complete Track A (controlled) pass: six engines
through Phases 1–5, native kernels in two assembly languages, and native
integration (M9). Every figure links to the raw, machine-readable data; the
generated comparison report is [`report.html`](report.html) and
[`results/comparisons/`](../../results/comparisons/).

## Read this first — limits of the evidence

* **One attempt per language and task (n = 1).** Differences in cost or time
  between languages are observations, not statistically significant effects.
  The design calls for repeated attempts (`docs/methodology/statistics.md`);
  only Java/native has two attempts so far.
* **Development telemetry was measured with up to 8 agents running
  concurrently** on one host, sharing a subscription rate limit. Wall-clock
  times include that contention; token counts and turns do not depend on it.
* **Performance numbers come from one host** (AMD Ryzen 9 9950X3D, 16 cores
  pinned of 32 threads, Ubuntu 24.04), measured with no agents running.
  ARM numbers exist only for the kernels (spark, NVIDIA GB10).
* Costs are the platform-reported **list-price equivalent** of the tokens used
  (`total_cost_usd`), not what was billed under the subscription.
* Track B (ecosystem-optimized) has not run yet. The later experiment families
  (architectural change, refactoring, debugging, optimization) ran as one chained
  lineage per language: CR-1 UNION ALL → CR-3 refactoring → CR-2 DECIMAL(38) →
  latency optimization; debugging ran on the CR-1 baseline and is never merged.

## Correctness

All six engines pass every phase on the first attempt, including the hidden
acceptance tests that the agents never saw:

| check | result (each engine) | data |
|---|---|---|
| conformance, phases 1–3 + hidden | 623/623 | `experiments/runs/a-phase5-*/validation.json` |
| conformance over HTTP | 623/623 | same, `conformance-http.json` |
| option matrix (row/vectorized × joins × threads × optimizer) | 3,738/3,738 | `conformance-modes.json` |
| same with native kernels | 623/623 and 3,738/3,738 | `experiments/runs/a-native-*/` |
| HTTP/concurrency suite | 18/18 | `http-suite.json` |
| PQCF storage interop, 6 × 6 + reference | every reader 28/28 from every writer | [`interop.json`](../../results/correctness/interop.json) |
| crash consistency (25 SIGKILLs during save) | 0 violations | `results/correctness/*-crash.json` |
| fuzzing, 120 s | 3.3–8.3 M inputs, 0 crashes/hangs/INTERNAL_ERROR | `results/correctness/*-fuzz.json` |
| randomized differential vs SQLite | 300/300 | — |
| cross-engine result digests, 20 benchmark queries | identical for all engines | benchmark `result_agreement` |

All six engines implemented the optional correlated subqueries.

## Development effort (all Track A runs, list-price USD)

| language | runs | cost | turns | agent hours | output tokens | repair iterations | non-success attempts |
|---|---:|---:|---:|---:|---:|---:|---|
| Clojure | 6 | $66.60 | 659 | 3.4 | 1.07 M | 41 | — |
| Go | 6 | $68.77 | 681 | 3.8 | 1.08 M | 44 | — |
| Python | 6 | $72.99 | 672 | 4.5 | 1.02 M | 36 | — |
| Rust | 6 | $87.55 | 787 | 5.1 | 1.19 M | 46 | — |
| Java | 7 | $106.02 | 951 | 5.3 | 1.46 M | 69 | native a1: isolation_violation (stray files) |
| Common Lisp | 6 | $112.99 | 897 | 7.3 | 1.26 M | 68 | — |
| x86-64 asm (kernels) | 1 | $11.98 | 83 | 0.7 | 0.27 M | 0 | — |
| AArch64 asm (kernels) | 1 | $4.80 | 26 | 0.5 | 0.14 M | 0 | — |

Per run: [`results/comparisons/development.csv`](../../results/comparisons/development.csv).
Phase 5 (optimization) was the most expensive phase for every language
($16–$47), Phase 4 (HTTP/concurrency) the cheapest ($4–$6.50).

## Runtime performance (1m rows, main line)

Source: [`20261014T115525Z-1m-rebench-main-and-asm-x86`](../../results/performance/20261014T115525Z-1m-rebench-main-and-asm-x86/summary.json) (2026-10-14), a full re-benchmark of main after CR-6, the Common Lisp
large-data fix and the x86 assembly scaling fix: 7 measured repetitions after 3 warm-ups, CPUs
0-15, HTTP with 1/4/16 clients, every engine in the same run. All engines return identical
results for all 20 queries.

| engine | startup | load 9 tables | peak RSS | query latency, geomean of 20 medians | HTTP q/s (1 / 4 / 16 clients) |
|---|---:|---:|---:|---:|---:|
| Go | 2.0 ms | 2.8 s | 2.4 GiB | 1.90 ms | 988 / 2,275 / 3,688 |
| Rust | 1.0 ms | 2.6 s | 1.3 GiB | 1.91 ms | 1,179 / 1,824 / 2,189 |
| Java | 24 ms | 4.6 s | 3.1 GiB | 3.36 ms | 632 / 951 / 1,094 |
| Clojure | 125 ms | 10.4 s | 7.5 GiB | 5.14 ms | 299 / 832 / 1,067 |
| Common Lisp | 14 ms | 2.7 s | 2.1 GiB | 6.59 ms | 146 / 145 / 105 |
| Python | 229 ms | 23.9 s | 16.4 GiB | 26.50 ms | 47 / 17 / 11 |

Go and Rust are tied. Compared with the previous round
([`20261012T115848Z-1m-main-and-asm-x86`](../../results/performance/20261012T115848Z-1m-main-and-asm-x86/summary.json),
before CR-6) every engine is within the ~20 % between-session spread, except Common Lisp's load
(6.2 → 2.7 s, the streaming CSV ingest of its large-data fix) and its startup (4 → 14 ms, a 64 GiB
heap reservation instead of 8 GiB). Earlier 1m runs:
[`20261011T172247Z-1m-main-after-reruns`](../../results/performance/20261011T172247Z-1m-main-after-reruns/summary.json)
(after the optimization re-runs, no HTTP).

The same engine code measured in three separate sessions on the quiet host varied
by up to ~20 % in geomean latency (Go 1.65–2.03 ms; others 5–10 %), so differences
smaller than that between engines are not meaningful.

The figures below come from the Phase 5 / native run (before the optimization tasks).

Optimization effectiveness (each engine's own row-at-a-time baseline vs its
best vectorized mode, geomean over 4 queries): Rust 121×, Java 24×,
Clojure 17.5×, Go 14.8×, Common Lisp 2.5×, Python 2.4×. Python gets slower with
more threads (0.7× at 16 threads), consistent with the GIL.

Native kernels (vectorized vs vectorized + `native: true`, same 4 queries):
Python 12.5× faster, Common Lisp 1.23×, Rust 1.17×, Go 1.15×; Java and Clojure
**0.67×** (slower) — the JVM's own JIT-compiled loops beat the FFM call and
copy overhead at these batch sizes.

### Native kernels alone

| kernel family | x86-64 AVX-512 vs C reference | AArch64 NEON vs C reference (spark, X925) |
|---|---:|---:|
| bitmap popcount | 132× | 40× |
| bitmap filter | 43× | 12× |
| min/max | 11× | 1.9× |
| gather | 1.0× (memory-bound) | 1.0× |

On spark (SVE2, 128-bit vectors) NEON beats SVE for 12/13 kernels (all but `hash_i64`), although
the dispatcher currently prefers SVE. Sources:
[`kernels-x86-quiet`](../../results/performance/kernels-x86-quiet/bench.jsonl),
`experiments/runs/a-kernels-arm64-asm-a1-*/native-arm/bench.jsonl`.

## Runtime performance at 10m rows

Same workload and harness settings at ten times the data: the main tables have 10 million rows
and the dataset is 1.9 GB of CSV. The memory cap is 180 GiB so that Python fits. Source:
[`20261014T120827Z-10m-rebench-main-and-asm-x86`](../../results/performance/20261014T120827Z-10m-rebench-main-and-asm-x86/summary.json) (six engines and the x86-64 assembly engine) and, on spark,
[`20261014T115833Z-10m-rebench-asm-arm`](../../results/performance/20261014T115833Z-10m-rebench-asm-arm/summary.json) (AArch64 assembly engine), 2026-10-14, the same code as the 1m table above. Every
engine returns identical results for all 20 queries, on both machines.

| engine | queries ok | geomean latency 1m → 10m | growth | peak RSS 1m → 10m | load 9 tables at 10m | HTTP q/s, 16 clients, 1m → 10m |
|---|---:|---:|---:|---:|---:|---:|
| Go | 20/20 | 1.90 → 12.35 ms | 6.5× | 2.4 → 18.6 GiB | 29 s | 3,688 → 383 |
| Rust | 20/20 | 1.91 → 14.20 ms | 7.4× | 1.3 → 9.8 GiB | 29 s | 2,189 → 95 |
| Java | 20/20 | 3.36 → 19.52 ms | 5.8× | 3.1 → 31.2 GiB | 40 s | 1,094 → 34 |
| Clojure | 20/20 | 5.14 → 41.02 ms | 8.0× | 7.5 → 29.9 GiB | 93 s | 1,067 → 58 |
| Common Lisp | 20/20 | 6.59 → 68.79 ms | 10.4× | 2.1 → 7.7 GiB | 27 s | 105 → 9 |
| Python | 20/20 | 26.50 → 239.66 ms | 9.0× | 16.4 → 178.5 GiB | 319 s | 11 → 1.3 |
| *x86-64 assembly (cohort)* | 20/20 | 2.48 → 27.39 ms | 11.0× | 1.3 → 12.2 GiB | 14 s | 442 → 26 |
| *AArch64 assembly (cohort, ARM host)* | 20/20 | 2.76 → 23.46 ms | 8.5× | 0.8 → 8.2 GiB | 24 s | 913 → 56 |

The assembly engines are a separate cohort and are not ranked with the six engines; the AArch64
row is a different machine. The first 10m round (2026-10-13,
[`20261013T111035Z-10m-main-and-asm-x86`](../../results/performance/20261013T111035Z-10m-main-and-asm-x86/summary.json),
[`20261013T111147Z-10m-asm-arm`](../../results/performance/20261013T111147Z-10m-asm-arm/summary.json))
gave the same numbers for the engines that did not change (within 6 %), and found the two
defects fixed since:

* **Common Lisp crashed at 10m, and an agent task fixed it.** Its build fixed the SBCL heap at 8 GiB, and
  SBCL died with "Heap exhausted, game over" while parsing the first 10m-row CSV instead of returning
  `RESOURCE_LIMIT`
  ([stderr](../../results/performance/20261013T111035Z-10m-main-and-asm-x86/common-lisp-10m-stderr.txt)).
  The `fix-large-data` run (`a-fix-large-data-common-lisp-a1-20261013T234442Z`, $8.37, 47 min, first
  attempt) streams CSV into typed column builders, raises the heap to 64 GiB and adds a heap guard that
  answers `RESOURCE_LIMIT` (`--max-memory-mb`). It passes the new large-data probe
  (`tests/regression/large_data_probe.py`: 10m workload, a 64 MiB query budget, an ingest limit, six
  10m tables in one process) and conformance 731/731. At 10m it is the slowest engine after Python
  (sorts and joins 250-540 ms) and its HTTP throughput falls to 9 q/s at 16 clients.
* **The x86-64 assembly engine grew 25× (70.7 ms at 10m), and an agent task fixed most of it.** Its 1 GiB
  pool of reusable query memory was too small at 10m, so each request unmapped the excess and the next
  query faulted it back in (2.1 M page faults per round of 20 queries, much of it outside the engine's
  own timer), and the HTTP server recomputed column statistics in every forked query process. The
  `optimize-scaling` run (`a-optimize-scaling-x86_64-asm-engine-a1-20261013T235906Z`, $17.53, 91 min,
  first attempt) sized the pool by peak use: 70.7 → 27.4 ms in the full benchmark, growth 25× → 11×,
  1m unchanged, identical results
  ([`x86-asm-10m-scaling.md`](../../results/performance/x86-asm-10m-scaling.md)). Sorts, million-group
  aggregations and the large join probe still grow faster than the data.

Findings:

* **The 1m ranking holds at 10m**: Go, Rust, Java, Clojure, Common Lisp, then Python. Most engines grow
  6-8× for 10× the data, because many queries are top-N, filtered or grouped down to small results.
  Common Lisp and Python grow about linearly; Python needs 179 GiB.
* **Memory**: Java and Clojure use 30 GiB, Go 19 GiB, Rust and the assembly engines 8-12 GiB, Common
  Lisp 7.7 GiB (the least of the six).
* **HTTP throughput drops 10-40×.** The HTTP benchmark sends workload queries, and at 10m they are
  heavier.

### Storage: save and open (`transactions`, PQCF)

First valid measurement (the harness's open step always failed before, HI-012). Same runs; `open`
includes recreating the table's two indexes; cold = page cache dropped first.

| engine | save 1m / 10m | open cold 1m / 10m | open cold with mmap 1m / 10m |
|---|---:|---:|---:|
| Go | 0.30 / 3.1 s | 0.31 / 3.5 s | 0.19 / 2.4 s |
| Rust | 0.24 / 2.3 s | 0.24 / 3.3 s | 0.20 / 2.7 s |
| Java | 0.23 / 1.8 s | 0.22 / 3.3 s | 0.20 / 3.1 s |
| Clojure | 0.70 / 5.0 s | 0.85 / 15.5 s | 0.79 / 15.1 s |
| Common Lisp | 0.42 / 4.1 s | 0.54 / 7.6 s | 0.37 / 6.2 s |
| Python | 0.79 / 7.9 s | 0.68 / 9.8 s | 0.66 / 8.8 s |
| *x86-64 assembly* | 0.26 / 2.6 s | 0.33 / 3.9 s | 0.21 / 3.0 s |
| *AArch64 assembly (spark)* | 0.12 / 1.0 s | 0.31 / 4.6 s | 0.30 / 4.5 s |

All eight engines write files of the same size (65 MiB at 1m, 650 MiB at 10m, from 87 / 875 MB of
CSV). Opening is not always faster than loading the CSV, because `open` also rebuilds the two
indexes and the CSV load does not: at 10m, compared with loading `transactions` from CSV, open is
7.6× faster for Python, 2-3× for Java, Rust, Go and Clojure, about equal for AArch64, and slower
for the x86-64 engine (3.9 s vs 2.7 s) and Common Lisp (7.6 s vs 5.8 s). Memory-mapping saves
most in Go (33 %) and the x86-64 engine (25 %).

## Code size (automated count, `report.py`)

| language | source LOC | test LOC | files | largest file |
|---|---:|---:|---:|---:|
| Clojure | 11.2 k | 1.4 k | 60 | 798 |
| Python | 12.2 k | 1.4 k | 70 | 979 |
| Common Lisp | 12.7 k | 1.0 k | 55 | 763 |
| Go | 21.2 k | 2.9 k | 77 | 1,068 |
| Java | 21.3 k | 2.2 k | 154 | 1,102 |
| Rust | 22.2 k | 3.2 k | 78 | 1,051 |

The rubric-based review is summarized under "Code-quality review" below.

## Engine quality findings

* Go: single-client HTTP latency is bimodal (p50 1.2 ms, p95 ~40 ms), consistent
  with a Nagle/delayed-ACK interaction.
* Python: a negative HTTP chunk size made the server read the request body to
  end-of-stream, bypassing `--max-request-bytes` (found in code review, confirmed by
  the `malformed_chunked_body` HTTP check). Fixed by the Python CR-6 run, whose
  acceptance required a clean HTTP suite: 19/19 since 2026-10-13.
* Clojure: on a failing vectorized/parallel execution the engine re-runs the
  query row-at-a-time (documented; results verified identical).
* Valid but very large expressions (20,001-term sum, 2,000-deep parentheses):
  some engines compute them, others return PARSE_ERROR or RESOURCE_LIMIT.
  Spec question SPEC-Q-002 is now settled by CR-6; see below.

### Robustness probes (suspected review defects)

`tests/regression/robustness_probe.py` checks, black-box, the defects the code
reviewers suspected. It runs on all eight engines; records are in
[`results/correctness/robustness/`](../../results/correctness/robustness/).
"Hang" means no reply within 180 s although `options.timeout_ms` was 120,000 and
the process was alive. Error responses to huge expressions pass, because the size
limits are an open spec question (SPEC-Q-002).

| probe | failures | passes / notes |
|---|---|---|
| `long_or_chain`: `AND`/`OR` chains of 10,000 and 100,000 terms, in row, vectorized, parallel and auto mode | **x86-64 asm**: SIGSEGV at 100k (parallel, auto). **AArch64 asm**: SIGSEGV at 100k (vectorized, parallel, auto). **Go**: hang at 100k (all modes). **Java**: hang at 100k (vectorized, auto; OR also parallel); the other 100k cases return `TIMEOUT`. **Clojure**: hang at 10k already (all modes) | Rust `PARSE_ERROR`, Python `RESOURCE_LIMIT`, Common Lisp results or `TIMEOUT` |
| `limit_after_failed_query`: does a load succeed after a query failed on its memory budget? | **x86-64 asm**: the load fails with `RESOURCE_LIMIT` (the budget stays set) | the other engines pass or are not triggered |
| `http_crlf_flood`: a header section that never ends, at 128 MiB, 512 MiB and 1 GiB | **x86-64 asm**: RSS grows 1:1 with the bytes sent, up to 1 GiB | AArch64 asm flat; Clojure and Common Lisp level off at about 610 MB and 520 MB (the first, single-stage probe flagged them wrongly); Go closes the connection |
| `fd_after_failed_loads`: descriptor leak after 50 failed loads | none | suspected for both assembly engines, not reproduced |
| `session_huge_line`: a 256 MB malformed session line (observation) | none | all eight answer `INVALID_REQUEST` and stay usable; peak RSS 258 MB (x86 asm) to 3.1 GB (Common Lisp) |
| `parallel_memory_budget`: 1M-row `GROUP BY` with a 64 MB budget, 1 versus 8 threads (observation) | none (all return `RESOURCE_LIMIT`) | RSS growth with 8 threads: AArch64 asm 153 MB (1 thread: 0), which fits the reviewers' per-task-budget finding. Python 3,050 MB: process-tree RSS, which also counts the worker pool's start-up |

**After the CR-6 task (2026-10-13): every probe passes on all eight engines.**
The table above is the state before it. The re-run used the same probe on the
merged engines (records: the same files, `reruns`):

* `long_or_chain`: no crash and no hang on any engine.
* `limit_after_failed_query` and `http_crlf_flood`: both pass on the x86-64
  asm engine. Its CR-6 agent fixed both on its own: it now clears the request
  memory budget at the start of each request, and drops CR/LF bytes before a
  request line.
* `expression_limits`: passes on all eight.

### CR-6 expression size limits (resolves SPEC-Q-002)

[`spec/changes/expression-limits.md`](../../spec/changes/expression-limits.md)
([ADR-0017](../decisions/ADR-0017.md)) defines what an engine must do with very
large statements:

* It must execute 1 MiB of text, nesting depth 1,000 and 25,000 operands in
  every mode. An operator chain counts as one level of nesting.
* Beyond its own limits it must answer `RESOURCE_LIMIT`.
* `TIMEOUT` must arrive within 1 s of expiry in every query stage.

**Result: all eight engines implement CR-6** (change task
`change-expression-limits`, 2026-10-13). Each succeeded on the first attempt,
for \$119.43 in total (\$9.02–21.52 per engine). Each claims
`change.expression_limits`, and validation passed for each:

* the full conformance suite (public and hidden) in every mode and over HTTP;
* the HTTP suite;
* the CR-6 probe with its withheld cases (19 minimum cases × 4 modes and
  7 larger cases × 4 modes).

The independent re-run of the public probe gives 40/40 minimum and 12/12
larger cases on every engine.

| engine | cost (USD) | agent time | commits | approach (from the engine's README and commits) |
|---|---|---|---|---|
| Clojure | 9.02 | 58 min | 3 | statement limits and a deadline in every stage |
| x86-64 asm engine | 10.74 | 58 min | 5 | linear lexing of literals, statement limits; also fixed its stale memory budget and CR/LF handling |
| AArch64 asm engine | 10.89 | 35 min | 9 | statement limits, large worker-thread stacks with a fallback when refused |
| Java | 12.96 | 69 min | 4 | size limits in the parser, timeout in every stage and inside deep expressions |
| Common Lisp | 14.97 | 89 min | 5 | statement limits, deadlines, stack-exhaustion handling with unit tests |
| Go | 18.36 | 71 min | 12 | statement limits, linear handling of long statements in grouping, concatenation and CTE checks |
| Python | 20.99 | 106 min | 10 | large-stack query threads, linear `LIKE`, hashed lookups, deadline checks in planning; also fixed the malformed chunked-body defect, so its HTTP suite now passes 19/19 |
| Rust | 21.52 | 95 min | 8 | statement limits, stack-guarded threads, interruptible evaluation of long chains |

**Before the CR-6 task** (informational, engines built against spec 1.0.0):
probe `expression_limits`, 10 minimum cases × 4 modes and 3 larger cases × 4
modes, with `timeout_ms` 30,000.

| engine | minimums | larger statements (100k nesting / 100k-term `OR` / 100k `IN`) |
|---|---|---|
| Java | 40/40 | `PARSE_ERROR` / no answer within 35 s / ok |
| Clojure | 28/40: no answer to 10,000-term `OR`, `AND` and sum | ok / no answer / ok |
| Rust | 28/40: `PARSE_ERROR` on 10,000-term `OR`, `AND` and sum | `PARSE_ERROR` / `PARSE_ERROR` / ok |
| Python | 28/40: `RESOURCE_LIMIT` on 10,000-term `OR`, `AND` and sum | `PARSE_ERROR` / ok / no answer |
| Go | 40/40 | ok / no answer / ok |
| Common Lisp | 24/40: `PARSE_ERROR` at nesting depth 999 | `PARSE_ERROR` / no answer (the result after 100 s) / ok |
| x86-64 asm engine | 40/40 | `PARSE_ERROR` / no answer (`TIMEOUT` after 37 s) / ok |
| AArch64 asm engine | 24/40: `RESOURCE_LIMIT` at nesting depth 999 | `RESOURCE_LIMIT` / row ok, vectorized no answer, parallel and auto crash / ok |

* **No engine met CR-6 in full before the task.**
* **Two common gaps:**
  * Valid SQL rejected with `PARSE_ERROR` or a depth limit below 1,000.
  * The timeout not enforced while a large statement is parsed or planned.
    * The 100,000-term `OR` chain gets no answer within 35 s from Java, Clojure,
      Go, Common Lisp and the x86-64 asm engine; the 100,000-item `IN` list gets
      none from Python. The timeout was 30 s.
    * Measured with a longer wait, the x86-64 asm engine answers `TIMEOUT` after
      37 s, and Common Lisp returns the result after 100 s.
* **One engine already behaves the way CR-6 requires beyond its limits:** the
  AArch64 assembly engine answers `RESOURCE_LIMIT` to 100,000 nested parentheses.

## Later experiment families (report 7, architectural adaptability)

Per-attempt data (outcome, cost, turns, time, diff size) is in the report-7 table of
[`report.html`](report.html); records in `experiments/runs/a-{change,refactor,debug,optimize}-*`.

| task | outcome | cost range (USD) | notes |
|---|---|---|---|
| CR-1 `UNION ALL` (change) | 6/6 success, first attempt | 3.48–4.92 | 14–21 files, 312–595 lines added |
| CR-3 plan separation (refactoring) | 6/6 success | 3.67–6.37 | behaviour and capabilities unchanged; named optimizer rules with unit tests |
| CR-2 `DECIMAL(38)` + PQCF v2 (change) | 6/6 success | 6.25–16.50 | the most expensive change; Go (16.50) and Java (13.92) needed a new wide-decimal value representation |
| CR-6 expression size limits (change; all eight engines) | 8/8 success, first attempt | 9.02–21.52 | 3–12 commits; see the CR-6 section above |
| debugging (one injected defect each) | 6/6 success | 0.21–0.39 | one-line fixes in 36–87 s: too easy, because the defect report names the failing cases |
| latency optimization | 5/6 success; Go timed out twice | 10.22–18.61 (successes) | agents optimized self-written stand-in workloads (HI-007); see below |
| latency optimization, re-run on the real workload (record-only) | 5/6 success; Python tests_failed (HTTP `malformed_chunked_body`, pre-existing) | 10.48–31.19 | merged, replacing the first round (INT-001); Go succeeded on attempt 3; see below |

All merged engines pass 660/660 public cases (746 with hidden) after the chain,
and the 6 × 6 PQCF interop matrix — now including v2 files with 128-bit decimals —
is clean ([`interop.json`](../../results/correctness/interop.json)).

### Optimization effectiveness, measured independently

The agents' own before/after tables are not used. Each engine was benchmarked at
the commit its optimization run started from and at the run's result, back to back
on a quiet host (1m rows, same harness and data):
[`optimize-latency-before-after.json`](../../results/performance/optimize-latency-before-after.json).

| engine | geomean latency before → after | speedup | caveat |
|---|---|---:|---|
| Python | 129.0 → 42.5 ms | 3.04× | peak RSS 15.4 → 21.3 GiB |
| Common Lisp | 22.1 → 8.6 ms | 2.56× | |
| Go | 5.4 → 3.1 ms | 1.76× | attempt 2 **timed out** (120 min); committed work passes all checks |
| Java | 5.5 → 3.9 ms | 1.41× | `q14_sort_full_string` significantly slower |
| Clojure | 7.8 → 6.9 ms | 1.13× | |
| Rust | 3.1 → 2.7 ms | 1.13× | `q15_sort_multi_key` significantly slower |

Result digests were identical before and after for every engine and query.

**These runs did not optimize the official workload.** The task named
`benchmarks/workloads/analytics.json`, but that file was never exported into
workspaces (HI-007), so every agent wrote its own stand-in queries. The table
above measures how well each agent's optimization transferred to the real
workload. The family was therefore re-run with the workload available (attempt
2 or 3, from the same base commits, 120 minutes, record-only):
[`optimize-latency-before-after-a2.json`](../../results/performance/optimize-latency-before-after-a2.json).

| engine | geomean latency before → after | speedup | queries ≥ 2× faster | peak RSS | caveat |
|---|---|---:|---:|---|---|
| Python | 122.1 → 25.3 ms | 4.83× | 18/20 | 15.4 → 15.8 GiB | run `tests_failed`: HTTP suite 18/19 (the known `malformed_chunked_body` defect, present before the run) |
| Common Lisp | 21.8 → 6.8 ms | 3.21× | 13/20 | 1.4 → 1.7 GiB | `q14_sort_full` ~52× |
| Go | 5.3 → 2.0 ms | 2.63× | 10/20 | 2.4 → 2.4 GiB | |
| Rust | 3.0 → 1.7 ms | 1.75× | 5/20 | 1.0 → 1.2 GiB | |
| Java | 5.1 → 3.1 ms | 1.64× | 7/20 | 8.1 → 2.9 GiB | |
| Clojure | 8.2 → 5.2 ms | 1.58× | 4/20 | 5.4 → 8.6 GiB | |

Both tables are clean re-measurements (HI-009: the first measurements kept stray files
from HEAD in the measured trees; the figures moved by less than the between-session
spread, e.g. Go round 2 3.24× → 2.63×, Python round 1 2.85× → 3.04×).

With the real workload in hand, every agent achieved more (1.4–5.0× vs. 1.1–2.9×),
and the gains are broad, not one-query tricks (Python and Go improved at least
2× on 15+ of 20 queries). The agents could see the benchmark queries, so the
gains may partly be fitted to these 20 queries; correctness is unaffected
(public + hidden conformance, the full mode matrix and native kernels pass,
digests identical). By owner decision the re-runs **replace** the first round on
main (INT-001 in `experiments/telemetry/interventions.jsonl`; all six pass 660/660
afterwards). Python's re-run is merged although its outcome is `tests_failed`,
because its only failure is the defect the first-round engine already had.

### Track B: JVM tuning (Java and Clojure)

A separate Track B task let the Java and Clojure agents tune their JVM build and
start-up: AOT compilation, a JDK AOT cache trained on synthetic data and generic
queries, JIT and GC flags, and boxing in hot loops. Both started from the
first-round engines. Measured independently on the quiet host:
[`jvm-tuning-before-after.json`](../../results/performance/jvm-tuning-before-after.json).
These figures belong to Track B only and are never combined with Track A.

| engine | outcome | start-up | first run of each query (geomean) | warm latency (geomean) | peak RSS |
|---|---|---|---|---|---|
| Clojure | success, $17.45 | 360 → 133 ms (2.7×) | 108 → 19 ms (5.8×) | 6.9 → 5.0 ms (1.39×) | 5.7 → 8.8 GiB |
| Java | timeout (120 min) | 22 → 16 ms (1.4×) | 37 → 28 ms (1.3×) | 3.8 → 3.8 ms (1.00×; `q18_nulls` slower) | 9.0 → 8.8 GiB |

For Clojure the cache and earlier JIT compilation mainly remove start-up and
first-query cost; Java was already fast to start (its first optimization run had
added an AOT cache).

## Assembly kernel family (ADR-0016)

The two assembly languages received their own versions of the later experiment
families, each with hidden acceptance tests (`tests/kernels-hidden/`) validated
natively on x86-64 and on spark. Throughput is measured independently before and
after each run (x86-64: quiet host, pinned; AArch64: spark). The two architectures run
on different machines and are never ranked against each other or against the engines.

| task | x86-64: outcome, cost, time | AArch64: outcome, cost, time | measured effect (SIMD variant: x86 AVX2 / ARM NEON) |
|---|---|---|---|
| CR-4: four 128-bit kernels, ABI revision 1 | success, $7.37, 26 min | success, $3.24, 12 min | new kernels vs. the C fallback: x86 1.7–6.1× (all variants), ARM NEON 1.07–4.5×; existing kernels unchanged |
| CR-5: behaviour-preserving restructuring | success, $14.36, 40 min | success, $8.86, 25 min | x86 machine code byte-identical; ARM geomean 0.99×, no kernel > 5 % slower, NEON `.text` 4.9 → 7.6 KB |
| debugging (one injected defect, symptom-only report, failures only in hidden tests) | success, $0.41, 1 min | success, $0.48, 1 min | one-line fixes; still too easy |
| throughput optimization | success, $27.74, 88 min | success, $10.77, 35 min | x86 AVX2 1.34× (agent's own figure 1.31×), AVX-512 1.03×; ARM NEON 1.02× (`minmax_i128` 1.41×), NEON `.text` 7.6 → 13.3 KB |

The AArch64 agent could not measure (no ARM hardware in its sandbox): it reasoned
from the Cortex-X925 and predicted that most kernels are memory-bound, which the
spark measurement confirmed. Sources: `results/performance/kernels-{x86,arm}-{before,after}-{change,refactor,optimize}/`.

## Assembly engine cohort (option B, ADR-0016)

The owner approved a pilot for complete engines in assembly: $300 cap, glibc
allowed (no C and no compiler-generated assembly), AArch64 agents running
natively on spark. A phase may take up to three 120-minute sessions, each
recorded as its own run. The cohort is never ranked with the six engines.

| engine | phase | sessions | outcome | cost | time | conformance | code |
|---|---|---:|---|---:|---:|---|---|
| x86-64 assembly | 1 | 1 | success | $20.99 | 37 min | 225/225 public, 249/249 with hidden | ~9.9 k LOC in 12 `.S` modules |
| AArch64 assembly | 1 | 1 | success | $23.82 | 28 min | 249/249 with hidden, natively on spark | ~11.0 k LOC in 15 `.S` modules |
| x86-64 assembly | 2 | 1 | success | $16.04 | 25 min | 411/411 public, 451/451 with hidden | ~19.9 k lines in `.S`/`.inc` |
| AArch64 assembly | 2 | 1 | success | $23.19 | 36 min | 451/451 with hidden, natively on spark | ~24.3 k lines in `.S`/`.inc` |
| x86-64 assembly | 3 | 1 | success | $14.80 | 36 min | 554/554 public, 623/623 with hidden | ~25.4 k lines |
| AArch64 assembly | 3 | 1 | success | $19.65 | 30 min | 623/623 with hidden, natively on spark | ~31.4 k lines |
| x86-64 assembly | 4 | 1 | success | $12.70 | 37 min | 623/623 with hidden, also over HTTP; HTTP suite 19/19 | ~30.4 k lines |
| AArch64 assembly | 4 | 1 | success | $10.18 | 29 min | 623/623 with hidden, also over HTTP; HTTP suite 19/19 (spark) | ~36.0 k lines |
| x86-64 assembly | 5 | 1 | success | $20.20 | 51 min | 623/623 with hidden, over HTTP, and 3738/3738 across the six execution modes; HTTP suite 19/19 | ~36.1 k lines |
| AArch64 assembly | 5 | 1 | success | $27.42 | 66 min | 623/623 with hidden, over HTTP, and 3738/3738 across the six execution modes; HTTP suite 19/19 (spark) | ~42.8 k lines |

Both were checked for compliance: no C or other high-level sources, no
compiler-generated assembly, and a launcher that only execs the assembled
binary. The transcripts show no C was ever compiled; Python served only as a
calculator and test-data generator. The AArch64 agent split the work across
sub-agents (an available tool; its cost is included). Phase 1 cost more than for the
high-level languages ($21–24 vs. $8–17) but took no longer (28–37 min vs.
24–106 min), far below the plan's estimate. Both implemented the optional correlated subqueries in Phase 2. The x86-64 agent developed part of Phase 2 on a side branch and merged it; the import was extended to keep such histories (grafted commits with the agent's authorship and dates). After Phase 3 the x86-64 assembly engine joined the PQCF interoperability matrix with the six engines: every file written by any engine is read correctly by every other, in both directions ([`interop-asm-engine.json`](../../results/correctness/interop-asm-engine.json); the assembly engine does not implement CR-2, so the four PQCF v2 files are excluded for it). After Phase 3 the owner raised the cap to $600; spend after Phase 5: $188.99. Both engines completed all five phases in one session per phase (no continuation session was needed) and claim row, vectorized and parallel execution and hash, merge and nested-loop joins. The native-kernel conformance mode does not apply to them (they do not load the kernel library); the ARM validation script now skips it for engines that do not claim `native.kernels`, as engine validation already did.

### Later task families (assembly engines)

Both engines then ran the same later families as the six engines, in the same
order, each starting from the previous merge
(`tools/orchestration/asm_family_pipeline.sh`; debug-mutant is record-only and
starts from the Phase 5 engine). Every merged run passed the hidden tests and the
assembly-policy check (`tools/validation/asm_engine_compliance.py`, stored as
`compliance.json` in each run). The task texts were the six engines' texts with
the native-kernel option removed (`task_overrides` in `experiments/prompts/languages.json`);
the debugging defects were injected with the same mutation tool and seed
(`experiments/controlled/defects/<engine>/`).

| family | x86-64 cost | x86-64 time | AArch64 cost | AArch64 time |
|---|---|---|---|---|
| debug-mutant (injected defect, record-only) | $0.37 | 1 min | $0.27 | 1 min |
| change-union-all (CR-1) | $3.26 | 8 min | $4.52 | 9 min |
| refactor-plan-separation (CR-3) | $8.96 | 25 min | $9.43 | 26 min |
| change-decimal38 (CR-2) | $16.39 | 30 min | $20.75 | 53 min¹ |
| optimize-latency | $18.98 | 51 min | $38.56 | 114 min |
| **total** | **$47.96** | | **$73.53** | |

¹ The recorded wall time is 73 min; the agent's CLI hung for about 20 min after its
final result event and was terminated (intervention INT-002 in
`experiments/telemetry/interventions.jsonl`).

Both debugging agents restored the injected instruction exactly (x86-64: `ja` back
to `jae` in the CASE binder; AArch64: `b.hi` back to `b.hs` in `like_match`).
Every family succeeded in one session. Engine size after the optimization: about
44.1 k lines (x86-64) and 49.9 k lines (AArch64) of assembly. Total assembly-engine
spend: $310.48 of the $600 cap.

### Benchmarks (assembly engines)

Same workload, repetitions and HTTP clients as the six engines, in the same full re-benchmark
(2026-10-14). x86-64 ran together with the six engines on the x86 host ([`20261014T115525Z-1m-rebench-main-and-asm-x86`](../../results/performance/20261014T115525Z-1m-rebench-main-and-asm-x86/summary.json), [`20261014T120827Z-10m-rebench-main-and-asm-x86`](../../results/performance/20261014T120827Z-10m-rebench-main-and-asm-x86/summary.json));
AArch64 ran on spark's Cortex-X925 cores (`tools/remote/arm_bench.sh`, [`20261014T115549Z-1m-rebench-asm-arm`](../../results/performance/20261014T115549Z-1m-rebench-asm-arm/summary.json), [`20261014T115833Z-10m-rebench-asm-arm`](../../results/performance/20261014T115833Z-10m-rebench-asm-arm/summary.json)).
Different machines: the two are not compared with each other, and neither is ranked with the six
engines.

| engine | scale | queries ok | geomean of query medians | startup | peak RSS | HTTP qps (1 / 4 / 16 clients) |
|---|---|---|---|---|---|---|
| x86-64 assembly | 1m | 20 / 20 | 2.48 ms | 1.1 ms | 1,321 MiB | 207 / 391 / 442 |
| x86-64 assembly | 10m | 20 / 20 | 27.39 ms | 0.8 ms | 12.2 GiB | 28 / 36 / 26 |
| AArch64 assembly | 1m | 20 / 20 | 2.76 ms | 1.6 ms | 803 MiB | 589 / 811 / 913 |
| AArch64 assembly | 10m | 20 / 20 | 23.46 ms | 1.3 ms | 8.2 GiB | 40 / 67 / 56 |

For context only (same x86 runs, not a ranking): the six engines' geomeans were 1.90 ms (Go) to
26.50 ms (Python) at 1m and 12.35 to 239.66 ms at 10m. The x86-64 engine forks a snapshot process
per HTTP query; the AArch64 engine serves each connection from a thread. The AArch64
`q01_filter_selective` regression from its optimization run is still there (0.55 ms, against
0.05 ms on x86 and 0.13 ms for Go). Previous round (before CR-6 and the scaling fix):
[`20261012T115848Z-1m-main-and-asm-x86`](../../results/performance/20261012T115848Z-1m-main-and-asm-x86/),
[`20261012T124929Z-1m-asm-arm`](../../results/performance/20261012T124929Z-1m-asm-arm/): x86 2.85 ms,
AArch64 2.68 ms.

Optimization before/after (independent back-to-back benchmark of the engine
before and after the optimize-latency run, identical result digests on both sides):

| engine | before | after | speedup | queries significantly slower |
|---|---|---|---|---|
| x86-64 assembly | 15.84 ms | 2.89 ms | 5.49× (best query 29×) | none |
| AArch64 assembly | 4.85 ms | 2.67 ms | 1.82× (best query 31×) | 3: `q01_filter_selective` (8× slower), `q16_timeseries_hourly`, `q17_wide_projection` |

Raw data: [`optimize-latency-before-after-x86_64-asm-engine.json`](../../results/performance/optimize-latency-before-after-x86_64-asm-engine.json),
[`optimize-latency-before-after-arm64-asm-engine.json`](../../results/performance/optimize-latency-before-after-arm64-asm-engine.json).

10m scaling (x86-64 only). The x86-64 engine grew 24.8× from 1m to 10m; the cause was
an arena chunk pool capped at 1 GiB, which at 10m made almost every query unmap and
re-fault gigabytes of scratch memory (2.1 M minor faults per round, part of it before
the engine's own timer). CR-6 did not contribute (current engine at 1m: 2.86 ms, same as
before CR-6). Fixed by the orchestrated run `a-optimize-scaling-x86_64-asm-engine-a1-20261013T235906Z`
(success, $17.53, 91 min; size-classed pool bounded by peak use, THP chunks, parallel
column statistics and tuple-set merges, join-probe and sort changes). Independent
back-to-back benchmark (`before_after.sh`), identical result digests at both scales:

| scale | before | after | speedup | notes |
|---|---|---|---|---|
| 10m | 63.67 ms | 27.37 ms | 2.33× | q01 31×, q16 6.8×, q17 5.4×, q05 3.2×; peak RSS 11.1 → 12.4 GiB |
| 1m | 2.78 ms | 2.73 ms | 1.02× | 3 pairs: 2.78/2.78/3.02 → 2.73/2.78/2.53 ms; no consistent regression |
| HTTP 10m qps (1 / 4 / 16 clients) | 6.0 / 14.6 / 17.7 | 24.9 / 36.2 / 28.7 | | 1-client p50 140 → 19 ms |

10m/1m growth after the fix: 10.0× (was 22.9× in this pair). Details:
[`x86-asm-10m-scaling.md`](../../results/performance/x86-asm-10m-scaling.md).

## AArch64 end to end

All six engines and the native kernel library were built natively on spark
(NVIDIA GB10) with the host's toolchain versions and pass 746/746 (public + hidden)
with and without native kernels ([`results/correctness/arm64/`](../../results/correctness/arm64/)).

## Code-quality review

Two independent AI reviewers per language scored rubric items 1–4
([`results/development/code-review/`](../../results/development/code-review/)).
Agreement is high (92 % exact, κ = 0.84) but the scale is compressed (almost all
4–5), so the scores barely separate the engines. The useful output is the list of
concrete findings; one was verified by a new black-box check: the Python HTTP
server accepts a negative chunk size and then reads the body past
`--max-request-bytes` (HTTP suite 18/19 until the Python CR-6 run fixed it; 19/19 for all engines since 2026-10-13).

The assembly kernel libraries were reviewed the same way after the optimize merge
(a separate cohort, not comparable with the engine scores): x86-64 5/5, 4/4, 5/5,
5/4 and AArch64 5/4, 5/4, 4/5, 3/3 for architecture, readability, robustness and
testability. Both AArch64 reviewers marked testability down because the agent kept
its guard-page and mutation harnesses out of the repository; no reviewer found a
functional defect.

The two assembly engines were reviewed with the six engines' prompts after their
optimize-latency merge (a separate cohort, never ranked with the six): x86-64
5/5, 4/4, 4/4, 4/4 and AArch64 4/5, 4/4, 4/4, 4/4 for architecture, readability,
robustness and testability (88 % exact agreement). Reviewers of both engines
independently suspected a descriptor leak when an allocation fails during a load,
no session-mode line-length cap and stack-depth risks in parallel workers; none of
these is verified yet. No ABI violation was found
([details](../../results/development/code-review/README.md#assembly-engine-cohort-complete-engines-in-assembly)).

## Application family: pqledger (ADR-0018)

Each engine was turned into an in-process library and used by a personal-finance CLI,
`pqledger` (`spec/apps/pqledger.md`: bank-CSV import in three formats with duplicate detection,
category rules and overrides, monthly/category/merchant reports, budgets, ad-hoc SQL, three
output formats), plus a minimal example program and two guides, `APP.md` (using and configuring
the application) and `EMBEDDING.md` (using the engine as a library in a new program in that
language; for the assembly engines from assembly and from C through a C-ABI library). Every
engine passes all 30 application cases (24 public, 6 hidden incl. a 99,629-transaction ledger)
and all 7 example-program cases, each command traced with `strace` (no engine process, no
socket), and still passes its full conformance suite.

| engine | sessions | cost (USD) | agent time | outcome |
|---|---|---|---|---|
| Python | 1 | 8.87 | 32 min | success |
| Go | 1 | 11.85 | 46 min | success |
| Rust | 1 | 8.55 | 24 min | success |
| Common Lisp | 1 | null¹ | 24 min | success |
| Java | 2 | null¹ + 6.68 | 23 + 14 min | success (docs in session 2) |
| Clojure | 2 | null¹ + 2.74 | 23 + 11 min | success (docs in session 2) |
| x86-64 assembly | 2² | null¹ + 6.27 | 24 + 16 min | success (docs in session 2) |
| AArch64 assembly | 2² | null¹ + 2.91 | 24 + 8 min | success (docs in session 2) |

¹ The usage guard stopped all six agents of the second wave after ~23 minutes when the
seven-day window reached 75 % (HI-013); a stopped agent reports no cost (token counts are
kept in each run's telemetry as lower bounds). At that point every application already passed
all cases; Java, Clojure and both assembly engines had not yet written their guides and finished
them in a continuation session. ² Plus one aborted session each, stopped within seconds by the
same guard. Assembly engines are a separate cohort and are not ranked with the six.

**Ledger interoperability.** The ledger format is normative, so a ledger written by any
implementation must be readable and writable by every other. All eight produce ledgers
row-identical to the engine-free reference; each implementation reads (accounts, list, export,
all reports, budget) and then writes (an overlapping import, set and clear overrides) every
other implementation's ledger and the reference's, and each producer then reads its own ledger
back after every other implementation wrote to it, next to its own cache files: 8 + 72 + 64
checks, all pass, expected values always from the reference
([`results/apps/interop-20261014/`](../../results/apps/interop-20261014/README.md)).

**Review.** Four read-only reviewers scored every guide 5/5 and found every application
compliant: categories are resolved in SQL (globs translated to LIKE, first match by
`MIN(rule_no)`, then `COALESCE(override, rule, 'uncategorized')`) and every report is one SQL
statement; the hosts only compute the `share` column and duplicate decisions. Code quality 4/5
throughout (AArch64 4.5). Unverified finding: five implementations replace the ledger files one
after the other, so a failure between two writes could leave the ledger half-updated; Common Lisp
stages all files first. Spec gap: `list --category uncategorized` is a usage error in Go and
lists uncategorized rows in Python
([review](../../results/development/code-review/pqledger.md)).

## Harness incidents

Fourteen harness defects were found during the runs and fixed; each is logged with
its impact in [`experiments/telemetry/harness-incidents.jsonl`](../../experiments/telemetry/harness-incidents.jsonl).
HI-002 (the runner overwrote explicit request ids) was visible to the Phase 1
agents as two spurious failures. HI-005 (a CR-1 case expected DECIMAL from an
untyped load) was visible to every UNION ALL agent. HI-006: run time limits
depended on the login token's remaining lifetime, and killed agents were counted
as successes; three optimization runs were re-classified as timeouts and the
family was re-run with a uniform 120-minute limit. Affected runs were re-validated; earlier
verdicts are kept in each run's `validation-history/`. HI-007: the
optimization workload was never exported to workspaces, so the first optimization
round optimized stand-in workloads (re-run above). HI-008: after the CR-4 kernel
change, engine validation built the kernel library from mismatched sources and the
native conformance check passed without native kernels; the six affected
record-only runs were re-validated and all passed native conformance. HI-009: the
before/after benchmark script kept stray files from HEAD in the measured trees;
all before/after sets were re-measured. HI-010: the benchmark's result digest treated a
FLOAT64 printed as `79` and as `79.0` as different results; at 10m it flagged a false
`q16` disagreement for both assembly engines (re-checked; all engines agree). HI-011: the new large-data
probe could not generate its data inside the sandbox (fixed; one run re-validated). HI-012: the storage
benchmark reopened a saved table while its indexes still existed, so every engine correctly refused with
`ALREADY_EXISTS` and every open time recorded before commit `9edc603` is invalid (save times and file sizes
are valid; no document quoted open times). HI-013: the usage guard stopped agents on the
seven-day "allowed_warning" notice (75 %) rather than at a utilization limit; it now stops at
98 % weekly or 95 % five-hourly use, any other non-allowed status, or overage. HI-014: the
assembly compliance check matched compiler commands in written file content (a C linking example
in the AArch64 `EMBEDDING.md`); it now checks executed shell commands and flags any high-level
source file written anywhere.

## Reproducibility

A clean clone (`git clone`, then the README quick-start: doctor, spec-validate,
harness-selftest, `test-language go`, `test-kernels`, `datasets 1m`,
`benchmark-language go 1m`, `report`) completed every step; the regenerated 1m
datasets matched the committed checksums and the Go benchmark produced
bit-identical result digests for all 20 queries, with latency within 3 % of the
original run.
