# Plan: Clojure AOT compilation, direct linking and JVM start-up tuning

Status: **approved and queued** (2026-10-11): Track B, Java and Clojure, after the optimize-latency re-runs (HI-007) and their quiet-host benchmark. Task `jvm-tuning` in `experiments/prompts/tasks.json`.

## 1. Where the Clojure engine stands today (read from the code, not run)

| item | current state |
|---|---|
| AOT `.class` files | **Already done.** `make build` runs `script/compile.clj`, which compiles `polyquery.main` and everything it requires into `target/classes` (8,665 classes). The launcher's runtime classpath drops `src`, so sources are never loaded at run time. |
| Direct linking | **Already on** for engine code: `*compiler-options* {:direct-linking true}` in `script/compile.clj`. The Clojure jar itself ships precompiled. No `^:redef` or `^:dynamic` vars; no runtime `eval`. |
| Reflection | `*warn-on-reflection*` is set in 57 of 61 namespaces; `make lint` fails on any reflection warning. |
| Boxed arithmetic | `*unchecked-math*` / `:warn-on-boxed` is not used anywhere, so boxed arithmetic in hot loops is not detected. |
| JVM flags (`bin/polyquery`) | `-Xss16m -XX:+UseParallelGC --enable-native-access=ALL-UNNAMED` plus logging switches. No CDS archive and no JDK AOT cache. |
| Start-up (process spawn to first response, quiet host) | Clojure **0.35–0.38 s**; Java **0.023–0.025 s**. Java's optimize-latency agent added a JDK AOT cache (`-XX:AOTCache`) built from a training run during `make build`. |
| Warm query latency, 1m rows | Java faster by 1.84× (geometric mean, `results/performance/20261011T102732Z-1m-after-optimize`). Clojure is faster only on the two high-cardinality/skewed GROUP BY queries. |

**Consequence for expectations.** The benchmark reports start-up separately and measures latency after 3 warm-up runs. AOT compilation and direct linking are already in place. A start-up cache and JVM flags therefore mainly improve start-up and first-query (cold) latency. They will barely touch the 1.84× warm-latency gap.

The levers that can move warm latency are boxing, reflection, protocol dispatch in hot loops and GC/heap behaviour. The plan covers both groups, and measures and reports them separately.

## 2. Integrity: how this may be done

1. **No hand edits.** Engines change only through sandboxed agent runs (AGENTS.md §3, ADR-0007).
2. **Not Track A.** If we tell one language's agent exactly which techniques to apply, Track A is no longer controlled: the other agents received only the generic goal. So the run is a **Track B (ecosystem-optimized)** task, reported only in Track B.
3. **Java gets the same treatment.** The same task text, adapted only in its language-specific notes, also goes to Java. Otherwise the Track B JVM comparison would be lopsided.
4. **Training data.** A start-up cache or training run must use synthetic data and generic queries, never the benchmark queries. This is the rule Java's agent already followed.

## 3. Agent task: `track-b-jvm-tuning`

Base: the current accepted Clojure engine. Limit: 120 min.

### A. AOT completeness and direct linking (verify, then tighten)
* Prove that nothing is compiled at run time: start with `-verbose:class` (or `-Xlog:class+load`) during a conformance session and check that every `polyquery.*` class comes from `target/classes` and that no `clojure.lang.Compiler` activity appears. Fix any namespace loaded dynamically.
* Add `:elide-meta [:doc :file :line :added]` to `*compiler-options*`. Measure class size and start-up; keep it only if it helps.
* Verify direct linking on hot call sites with `javap -c` on a few hot functions: expect `invokestatic`, not `Var.getRawRoot`. Document the result.
* Hot-path calls through protocols or multimethods stay dynamic even with direct linking. List them, and move inner-loop dispatch to `definterface`/`deftype` with type hints or to primitive-hinted functions where profiling shows a cost.

### B. Boxing and reflection (warm latency)
* Turn on `(set! *unchecked-math* :warn-on-boxed)` in the lint build, and make `make lint` fail on new boxed-math warnings in the `exec`, `storage` and `values` namespaces.
* Remove boxing in hot loops with `^long`/`^double` hints, primitive `loop`/`recur` and primitive arrays.
* SQL overflow semantics must stay exact. Wherever `NUMERIC_OVERFLOW` must be raised, use explicit checked operations such as `Math/addExact` and `Math/multiplyExact`, not unchecked arithmetic.
* Add `*warn-on-reflection*` to the remaining 4 namespaces.

### C. JVM start-up (start-up and cold latency)
* **JDK AOT cache** (JDK 27; the same mechanism Java uses):
  * `make build` runs a training session on synthetic data with generic queries, writing `-XX:AOTCacheOutput=target/polyquery.aot`;
  * the launcher passes `-XX:AOTCache=` when the cache is newer than the classes;
  * a stale or unusable cache is ignored silently, so stdout stays protocol-only;
  * the build must still succeed if training fails.
* Evaluate each candidate flag separately, and keep it only if the effect is beyond run-to-run noise (bootstrap 95% CI):

| flag | rationale |
|---|---|
| `-XX:-UsePerfData` | avoids the `hsperfdata` mmap at start-up |
| `-XX:TieredStopAtLevel=1` | **rejected in advance**: faster start-up but worse steady-state code |
| `-Xshare` / CDS when no AOT cache | fallback start-up path |
| heap: `-Xms` sized like `-Xmx` vs default | fewer heap resizes vs higher RSS (report both) |
| GC: ParallelGC (current) vs G1 vs ZGC | throughput vs pause time for 1m-row queries |
| `-XX:ReservedCodeCacheSize`, `-XX:+AlwaysPreTouch` | only if profiling shows JIT code-cache or page-fault cost |

### D. Done criteria
* Conformance unchanged:
  * 660/660 public plus hidden;
  * the full option matrix (`--modes`) 3870/3870;
  * HTTP transport, the HTTP suite and native kernels;
  * the capability set is unchanged.
* `make build test lint` succeed.
* The README has a section listing each technique with "kept" or "dropped" and the measured effect.

## 4. Measurement protocol (done by the maintainer after the run)

1. Before/after on the quiet host with `benchmarks/harness/before_after.sh`, scale 1m, the real workload (HI-007 fix), digests identical.
2. Report three numbers separately, never mixed:
   * start-up (spawn to first response);
   * cold first-query latency;
   * warm latency (geometric mean and per query).
   Also report peak RSS.
3. Same protocol for the Java Track B run. Results go into the Track B part of reports 3, 4 and 6, never into Track A or the Track A ranking.

## 5. Expected effects (estimates, to be replaced by measurements)

* **Start-up:** the AOT cache is the main lever. Java's first query went from 194 ms to 33 ms with it. For Clojure, a drop from about 0.36 s to roughly 0.1–0.2 s is plausible, since loading and initialising Clojure namespaces dominates.
* **Warm latency:** JVM flags are likely within ±10%. Removing boxing and protocol dispatch from hot loops is the only part likely to narrow the 1.84× gap, and its size is unknown.
* **Memory:** heap pre-sizing and the AOT cache raise RSS. Both are reported.

## 6. Cost and steps

1. Write the Track B task text (`tasks.json` → `track-b-jvm-tuning`) and the Track B prompt notes for Clojure and Java.
2. Run Clojure and Java in parallel: two agent runs, each about $10–20 at the cost of earlier optimization runs (an estimate), with a 120-min limit.
3. Validate, record and import, without merging into Track A's `main` lineage. Keep the Track B branches `track-b/<lang>/jvm-tuning/a1`.
4. Run the before/after benchmark (quiet host, about 30 min), then update the reports and the Track B narrative.

## 7. Decisions needed

1. Run this as Track B for both Clojure and Java (recommended), or for Clojure only (then it is an anecdote, not a comparison).
2. Start now, or after the queued optimize-latency re-runs (HI-007), so the Track A baseline is settled first (recommended).
