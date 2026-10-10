# Benchmarking Methodology

Harness: `benchmarks/harness/bench.py` (language-neutral; drives engines only
through the protocol). Workload: `benchmarks/workloads/analytics.json`.

* **Process isolation:** each engine runs in its own process tree, started fresh
  for startup measurements and for the main benchmark session; engines run one
  at a time in a randomized (seeded) order.
* **Resource limits:** `taskset` CPU pinning (default CPUs 0–15) and a cgroup v2
  memory limit via `systemd-run --user --scope -p MemoryMax=… -p MemorySwapMax=0`.
* **Warmup:** `--warmup` rounds (default 3) are recorded separately as the warmup
  curve; `--reps` rounds (default 7) are measured. Query order is reshuffled every
  round.
* **Startup** (spawn → first protocol response) is measured separately in fresh
  processes and never mixed into query latency. JVM engines therefore show their
  JIT warmup in the warmup curve and their startup cost in `startup_seconds`.
* **Latency:** client-observed wall time per request over the session pipe
  (engine-reported `stats.elapsed_us` is recorded too when available).
  Statistics: median, mean, stdev, p50/p95/p99, bootstrap 95% CI of the median
  (1000 resamples), Tukey outlier count. Raw measurements are kept in
  `results/performance/<id>/raw.jsonl.gz`.
* **Memory:** peak of the summed RSS of the engine process tree (sampled every
  50 ms) and maximum per-process `VmHWM`.
* **CPU:** user+system CPU seconds of the process tree during ingestion and during
  the query phase (→ CPU utilization = CPU s / wall s).
* **Ingestion throughput:** CSV MB/s per table; **storage:** PQCF size vs CSV,
  save time, open time with cold page cache (`drop_caches`) and warm cache,
  with and without mmap; **index build time**.
* **Scaling:** `threads` ∈ {1,2,4,8,16} for engines with `exec.parallel`;
  execution modes (`row` baseline with `optimize:false`, `row`, `vectorized`,
  `vectorized + native`) and join algorithms for Phase 5 engines.
* **HTTP throughput:** closed-loop clients (1, 4, 16) for 20 s against `serve`.
* **Correctness during benchmarks:** result digests per query are compared across
  engines for information only (never as an authority); conformance results are
  the correctness authority.
* **Identification:** every result directory stores `environment.json`
  (toolchains, CPU model, SIMD flags, memory, OS), the dataset manifest with
  checksums, the git commit and the exact harness arguments.
* **No cross-machine comparisons** are presented as language comparisons; results
  from different hosts are reported in separate tables.
* Performance reports are produced only from runs that were actually executed;
  missing measurements are shown as missing.
