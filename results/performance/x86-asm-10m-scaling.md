# x86-64 assembly engine: poor 1m -> 10m scaling (diagnosis)

Date: 2026-10-13. Engine: `implementations/x86_64-asm-engine` at `4a84c95` (after CR-6).
Host: AMD Ryzen 9 9950X3D, 16 engine CPUs (taskset 0-15), all engine processes sandboxed
(`tools/orchestration/sandboxed.sh`). Probe scripts were kept outside the repo (scratchpad);
every number below comes from them or from the committed benchmark raw data.

## Symptom

| run | geomean (20 queries) | worst queries |
|---|---|---|
| 1m, pre-CR-6 engine (`20261012T115848Z-1m-main-and-asm-x86`) | 2.85 ms | |
| 1m, current engine (`20261013T234047Z-1m-cr6-1m-x86-scaling`) | 2.86 ms | |
| 10m, current engine (`20261013T111035Z-10m-main-and-asm-x86`) | 70.7 ms (24.8x) | q01 427x, q05 30x, q14 29x, q16 27x |

HTTP throughput (q01/q03/q05/q09, forked query children): 16 clients 232 -> 17 qps; 1 client
median latency 18 ms -> 160 ms.

## CR-6 is not the cause

The current (CR-6) engine at 1m gives the same numbers as the pre-CR-6 engine: geomean
2.86 vs 2.85 ms, every query within +-20 %, identical result digests. The growth is a pure
scale effect.

## Evidence

1. **The time is lost outside the engine's own query timer.** In the 10m raw data,
   `wall - stats.elapsed_us` has a per-query median of 0.1-36 ms (sum over the 20 queries:
   365 ms of 2220 ms). q01 is 27.3 ms wall but 0.05 ms inside the engine. At 1m the gap is
   0.02-0.12 ms.
2. **History, not the query, decides the cost.** In a fresh session that has loaded all 10m
   tables, q01 takes 0.03 ms, q05 12.9 ms, q16 1.7 ms, q17 0.9 ms. In the benchmark's
   interleaved order (random order per round, as `bench.py` runs it) the same queries take
   21 / 22 / 4.6 / 20.8 ms. A bench-like interleaved replay
   reproduces the benchmark exactly (sum of medians 2221 ms vs 2220 ms in the benchmark).
3. **Page faults: zero at 1m, 2.1 million per round at 10m.** Minor faults of the engine
   process per query (from `/proc/<pid>/stat`), interleaved, median of 3 rounds:

   | query | 1m minflt | 10m minflt | 10m sys CPU |
   |---|---|---|---|
   | q14_sort_full_string | 0 | 415,094 | 1,110 ms |
   | q15_sort_multi_key | 0 | 495,858 | 1,340 ms |
   | q10_join_customers | 0 | 187,827 | 160 ms |
   | q07_groupby_skewed | 22 | 151,483 | 290 ms |
   | q02_filter_low_selectivity | 0 | 22,875 | 30 ms |
   | q01_filter_selective | 0 | 0 | 20 ms (all before the timer) |
   | **sum, 20 queries** | **54** | **2,123,065** | **4,580 ms** |

   Even the same query repeated back to back faults every time at 10m (q07: 134k faults,
   q10: 242k faults per execution), while at 1m nothing faults after warm-up.
4. Single-thread scans scale linearly (q02 with `threads:1`: 15.1 ms -> 155 ms, 10.3x), and
   user CPU per query grows about 10x, so the operators themselves are not super-linear.

## Root cause

Per-request scratch memory comes from arenas whose chunks are recycled through a process-wide
chunk pool (`src/util.S`: `chunk_get`, `chunk_put`, `arena_alloc_slow`, `arena_reset`;
`src/par.S`: `par_reset`, worker arenas). The pool is capped at `POOL_MAX` = 1 GiB, chunks are
fresh anonymous `mmap`s (since CR-6; malloc before, which had the same first-touch cost), and
any chunk that would exceed the cap is `munmap`ped.

* At 1m every query's scratch fits in the pool: no syscalls, no faults.
* At 10m a large query (sorts, joins, high-cardinality GROUP BY) needs well over 1 GiB of
  request + worker arena memory. On the **next request**, `proto_handle_line` (`src/protocol.S`)
  calls `par_reset` and `arena_reset` *before* `op_query` starts its timer; the chunks that do
  not fit the pool are `munmap`ped there (the 1-70 ms "gap", visible even for q01 which itself
  needs nothing). The next large query then `mmap`s fresh chunks and first-touches every page
  with 16 worker threads (minor faults, zeroing, `mmap_lock` contention) - the inflated in-engine
  time (e.g. q05 22.6 ms in the benchmark vs 12.9 ms in a fresh session).
* Best-fit reuse of variable-sized chunks (`max(size, total/2 capped at 64 MiB)`) makes the
  pool hold the wrong sizes once the working set exceeds the cap, so even repeating one query
  faults.

Secondary (HTTP only): `serve` runs every query in a `fork()`ed child (`src/server.S`). The
fork copies the page tables of the whole catalog (proportional to loaded data), the child
starts with an empty chunk pool (`chunk_pool_forget`) and no worker pool (`par_after_fork`), so
all of its scratch is freshly faulted. This makes per-request cost grow with data size
(1-client latency 18 ms -> 160 ms).

No index, zone-map or algorithmic regression was found: the hash index is still used for q01
(0.05 ms inside the engine at 10m; 92 matching rows vs 116 at 1m), the B-tree for q03.

## Fix

Done only through an orchestrated agent run (AGENTS.md §3): task `optimize-scaling`
(`experiments/prompts/tasks.json`, symptom report only), run
`a-optimize-scaling-x86_64-asm-engine-a1-20261013T235906Z`: outcome success, $17.53,
195 turns, 91 min, validation (conformance 660/660, `--modes`, HTTP transport, http_suite,
expression-limits probe incl. hidden cases, assembly-policy compliance) passed; merged.
The agent's own account is in the engine README ("Scaling optimization"). Changes: arena
chunk pool with size classes, bounded by max(1 GiB, peak - in use, peak/2) instead of a fixed
1 GiB, per-class free lists, 2 MiB-aligned THP chunks; parallel column statistics, computed
once per table in `serve` before publishing (forked children used to recompute them per
query); parallel concatenation of per-part tuple sets; direct emission in key-only hash-join
probes; MSD radix sort ping-pong buffers and constant-digit skipping; fewer threads per
forked query under concurrent HTTP load.

### Independent before/after (`benchmarks/harness/before_after.sh`, back to back)

Before = engine at `3c07126` (= `4a84c95` content), after = branch
`track-a/x86_64-asm-engine/optimize-scaling/a1`. Medians in ms; 7 reps, 3 warm-up, 16 CPUs.
Raw data: `20261014T015257Z-10m-before-optimize-scaling`, `20261014T015515Z-10m-after-optimize-scaling`,
`20261014T015742Z-1m-before-optimize-scaling`, `20261014T015753Z-1m-after-optimize-scaling`.
Note the "before" 10m value of q01 (1.99 ms) is lower than in the original 10m run (27.3 ms):
the random query order of this run put cheaper queries before it.

| query | 1m before | 1m after | 10m before | 10m after | 10m speedup | 10m/1m after | digests |
|---|---:|---:|---:|---:|---:|---:|---|
| q01_filter_selective | 0.051 | 0.051 | 1.99 | 0.06 | 31.03x | 1.3x | same |
| q02_filter_low_selectivity | 2.113 | 1.558 | 34.69 | 19.97 | 1.74x | 12.8x | same |
| q03_range_filter_time | 1.623 | 1.621 | 33.91 | 16.78 | 2.02x | 10.4x | same |
| q04_arith_aggregate | 1.747 | 1.792 | 43.16 | 17.26 | 2.50x | 9.6x | same |
| q05_groupby_low_card | 1.464 | 1.509 | 45.30 | 14.38 | 3.15x | 9.5x | same |
| q06_groupby_high_card | 5.431 | 5.819 | 85.88 | 66.96 | 1.28x | 11.5x | same |
| q07_groupby_skewed | 7.014 | 7.332 | 148.70 | 112.64 | 1.32x | 15.4x | same |
| q08_groupby_uniform_multi | 3.338 | 3.728 | 57.87 | 27.23 | 2.13x | 7.3x | same |
| q09_distinct_count | 6.030 | 5.785 | 105.99 | 78.90 | 1.34x | 13.6x | same |
| q10_join_customers | 6.807 | 6.148 | 179.21 | 97.20 | 1.84x | 15.8x | same |
| q11_join_star | 5.775 | 5.043 | 123.11 | 59.97 | 2.05x | 11.9x | same |
| q12_left_join_anti | 6.728 | 5.434 | 173.91 | 89.12 | 1.95x | 16.4x | same |
| q13_sort_topn | 2.931 | 3.049 | 62.87 | 34.63 | 1.82x | 11.4x | same |
| q14_sort_full_string | 14.336 | 14.618 | 354.94 | 268.18 | 1.32x | 18.3x | same |
| q15_sort_multi_key | 16.531 | 16.562 | 373.79 | 295.28 | 1.27x | 17.8x | same |
| q16_timeseries_hourly | 0.757 | 0.784 | 21.30 | 3.15 | 6.76x | 4.0x | same |
| q17_wide_projection | 0.272 | 0.238 | 8.87 | 1.63 | 5.43x | 6.9x | same |
| q18_nulls | 2.203 | 2.034 | 57.34 | 20.98 | 2.73x | 10.3x | same |
| q19_cte_subquery | 8.733 | 8.908 | 168.93 | 130.41 | 1.30x | 14.6x | same |
| q20_string_functions | 3.082 | 3.829 | 57.23 | 32.09 | 1.78x | 8.4x | same |
| **geomean** | 2.781 | 2.726 | 63.67 | 27.37 | 2.33x | 10.0x | |

Result digests: identical for all 20 queries at 1m and at 10m (and in all repeat runs).
Peak RSS: 10m 11,334 -> 12,684 MiB (+12 %), 1m 1,406 -> 1,230 MiB. Query-phase wall time at
10m: 22.6 s -> 14.2 s.

1m regression check, three back-to-back pairs (the pair above plus
`*-1m-rep{1,2}-{before,after}-optimize-scaling`): geomean 2.78 / 2.78 / 3.02 ms before,
2.73 / 2.78 / 2.53 ms after. Per-query median-of-three ratios after/before range 0.78 (q12)
to 1.24 (q20; its before values were 3.08 / 3.02 / 4.18, after 3.83 / 3.81 / 3.01 - noise
dominated); q08 (+11 %) and q06 (+7 %) are slightly slower in two of three pairs, within the
host's +-10-20 % noise. No consistent 1m regression.

HTTP at 10m (`--http`, transactions + customers, q01/q03/q05/q09; runs
`20261014T113026Z-10m-http-after-optimize-scaling`, `20261014T113230Z-10m-http-before-optimize-scaling`):

| clients | before qps | after qps | before p50 | after p50 |
|---:|---:|---:|---:|---:|
| 1 | 6.0 | 24.9 | 140 ms | 19 ms |
| 4 | 14.6 | 36.2 | 210 ms | 46 ms |
| 16 | 17.7 | 28.7 | 816 ms | 122 ms |

Outcome: 10m geomean 63.7 -> 27.4 ms (2.33x); 10m/1m growth 22.9x -> 10.0x, in line with the
other engines. What still grows faster than the data (per the agent): radix-sort scatter
(q14/q15), chained hash tables for one million groups (q07/q19) and the one-million-key join
probe (q10) - cache effects of the operators' data structures.
