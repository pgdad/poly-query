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

Source: [`results/performance/20261011T172247Z-1m-main-after-reruns`](../../results/performance/20261011T172247Z-1m-main-after-reruns/summary.json),
the engines on main after the real-workload optimization re-runs were merged
(INT-001). HTTP throughput is from the earlier run
[`20261011T051646Z-1m-m9-native`](../../results/performance/20261011T051646Z-1m-m9-native/summary.json)
(before the optimization tasks); the new run did not include the HTTP benchmark.

| engine | startup | load 9 tables | peak RSS | query latency, geomean of 20 medians | HTTP q/s (16 clients, earlier run) |
|---|---:|---:|---:|---:|---:|
| Rust | 1.2 ms | 2.6 s | 1.3 GiB | 1.6 ms | 451 |
| Go | 1.9 ms | 2.7 s | 2.4 GiB | 1.8 ms | 295 |
| Java | 25 ms | 4.8 s | 3.0 GiB | 3.2 ms | 1,137 |
| Clojure | 127 ms | 10.7 s | 8.7 GiB | 5.5 ms | 569 |
| Common Lisp | 4.2 ms | 6.5 s | 1.7 GiB | 7.0 ms | 206 |
| Python | 222 ms | 25.0 s | 15.8 GiB | 22.9 ms | 10 |

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
| latency optimization | 5/6 success; Go timed out twice | 10.22–18.61 (successes) | agents optimized self-written stand-in workloads (HI-007); see below |
| latency optimization, re-run on the real workload (record-only) | 5/6 success; Python tests_failed (HTTP `malformed_chunked_body`, pre-existing) | 10.48–31.19 | not merged; see below |

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

Both were checked for compliance: no C or other high-level sources, no
compiler-generated assembly, and a launcher that only execs the assembled
binary. The transcripts show no C was ever compiled; Python served only as a
calculator and test-data generator. The AArch64 agent split the work across
sub-agents (an available tool; its cost is included). Phase 1 cost more than for the
high-level languages ($21–24 vs. $8–17) but took no longer (28–37 min vs.
24–106 min), far below the plan's estimate. Both implemented the optional correlated subqueries in Phase 2. The x86-64 agent developed part of Phase 2 on a side branch and merged it; the import was extended to keep such histories (grafted commits with the agent's authorship and dates). After Phase 3 the x86-64 assembly engine joined the PQCF interoperability matrix with the six engines: every file written by any engine is read correctly by every other, in both directions ([`interop-asm-engine.json`](../../results/correctness/interop-asm-engine.json); the assembly engine does not implement CR-2, so the four PQCF v2 files are excluded for it). Option-B spend after three phases: $118.49 of the approved $300.

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

The assembly kernel libraries were reviewed the same way after the optimize merge
(a separate cohort, not comparable with the engine scores): x86-64 5/5, 4/4, 5/5,
5/4 and AArch64 5/4, 5/4, 4/5, 3/3 for architecture, readability, robustness and
testability. Both AArch64 reviewers marked testability down because the agent kept
its guard-page and mutation harnesses out of the repository; no reviewer found a
functional defect.

## Harness incidents

Nine harness defects were found during the runs and fixed; each is logged with
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
all before/after sets were re-measured.

## Reproducibility

A clean clone (`git clone`, then the README quick-start: doctor, spec-validate,
harness-selftest, `test-language go`, `test-kernels`, `datasets 1m`,
`benchmark-language go 1m`, `report`) completed every step; the regenerated 1m
datasets matched the committed checksums and the Go benchmark produced
bit-identical result digests for all 20 queries, with latency within 3 % of the
original run.
