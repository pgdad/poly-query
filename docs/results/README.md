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

## Runtime performance (1m rows, Phase 5 + native engines)

Source: [`results/performance/20261011T051646Z-1m-m9-native`](../../results/performance/20261011T051646Z-1m-m9-native/summary.json)
(and the pre-native run `20261011T030826Z-1m-final-p5-all`).

| engine | startup | load 9 tables | peak RSS | query latency, geomean of 20 medians | HTTP q/s (16 clients) |
|---|---:|---:|---:|---:|---:|
| Rust | 1.3 ms | 2.6 s | 0.95 GiB | 2.8–3.0 ms | 451 |
| Java | 24 ms | 5.6 s | 6.7 GiB | 5.1–5.2 ms | 1,137 |
| Go | 1.4 ms | 2.6 s | 2.3 GiB | 5.3–5.4 ms | 295 |
| Clojure | 355 ms | 9.6 s | 9.1 GiB | 8.0 ms | 569 |
| Common Lisp | 3.3 ms | 6.1 s | 1.4 GiB | 21.4–21.5 ms | 206 |
| Python | 208 ms | 24.4 s | 16 GiB | 122–124 ms | 10 |

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
* Python: a negative HTTP chunk size makes the server read the request body to
  end-of-stream, bypassing `--max-request-bytes` (found in code review, confirmed by
  the `malformed_chunked_body` HTTP check).
* Clojure: on a failing vectorized/parallel execution the engine re-runs the
  query row-at-a-time (documented; results verified identical).
* Valid but very large expressions (20,001-term sum, 2,000-deep parentheses):
  some engines compute them, others return PARSE_ERROR or RESOURCE_LIMIT
  (spec question SPEC-Q-002).

## Later experiment families (report 7, architectural adaptability)

Per-attempt data (outcome, cost, turns, time, diff size) is in the report-7 table of
[`report.html`](report.html); records in `experiments/runs/a-{change,refactor,debug,optimize}-*`.

| task | outcome | cost range (USD) | notes |
|---|---|---|---|
| CR-1 `UNION ALL` (change) | 6/6 success, first attempt | 3.48–4.92 | 14–21 files, 312–595 lines added |
| CR-3 plan separation (refactoring) | 6/6 success | 3.67–6.37 | behaviour and capabilities unchanged; named optimizer rules with unit tests |
| CR-2 `DECIMAL(38)` + PQCF v2 (change) | 6/6 success | 6.25–16.50 | the most expensive change; Go (16.50) and Java (13.92) needed a new wide-decimal value representation |
| debugging (one injected defect each) | 6/6 success | 0.21–0.39 | one-line fixes in 36–87 s: too easy, because the defect report names the failing cases |
| latency optimization | 5/6 success; Go timed out twice | 10.22–18.61 (successes) | see below |

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
| Python | 123.5 → 43.3 ms | 2.85× | peak RSS 15.4 → 21.2 GiB |
| Common Lisp | 21.9 → 8.9 ms | 2.48× | |
| Go | 5.3 → 3.0 ms | 1.74× | attempt 2 **timed out** (120 min); committed work passes all checks but is not merged |
| Java | 5.3 → 3.9 ms | 1.38× | |
| Clojure | 8.0 → 7.1 ms | 1.13× | |
| Rust | 3.1 → 2.9 ms | 1.07× | `q15_sort_multi_key` significantly slower (0.66×) |

Result digests were identical before and after for every engine and query.

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
`--max-request-bytes` (HTTP suite 18/19; all others 19/19).

## Harness incidents

Six harness defects were found during the runs and fixed; each is logged with
its impact in [`experiments/telemetry/harness-incidents.jsonl`](../../experiments/telemetry/harness-incidents.jsonl).
HI-002 (the runner overwrote explicit request ids) was visible to the Phase 1
agents as two spurious failures. HI-005 (a CR-1 case expected DECIMAL from an
untyped load) was visible to every UNION ALL agent. HI-006: run time limits
depended on the login token's remaining lifetime, and killed agents were counted
as successes; three optimization runs were re-classified as timeouts and the
family was re-run with a uniform 120-minute limit. Affected runs were re-validated; earlier
verdicts are kept in each run's `validation-history/`.

## Reproducibility

A clean clone (`git clone`, then the README quick-start: doctor, spec-validate,
harness-selftest, `test-language go`, `test-kernels`, `datasets 1m`,
`benchmark-language go 1m`, `report`) completed every step; the regenerated 1m
datasets matched the committed checksums and the Go benchmark produced
bit-identical result digests for all 20 queries, with latency within 3 % of the
original run.
