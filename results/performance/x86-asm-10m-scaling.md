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

Done only through an orchestrated agent run (AGENTS.md §3), task `optimize-scaling`; results
below.
