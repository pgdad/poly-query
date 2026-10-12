# Code-quality review (rubric, AI reviewers)

Two independent AI reviewer agents per language read the final engine
(`summary.json` → `code_commit`) read-only, without building or running it, and
scored rubric items 1–4 of [`code-quality-rubric.md`](../../../docs/methodology/code-quality-rubric.md).
Reviewer A started from the README module map; reviewer B started from the entry
point and followed the request path. Per-reviewer scores and file:line evidence
are in `<language>-A.json` / `<language>-B.json`.

**These are subjective judgements by AI reviewers, not facts.** Item 5
(extensibility) is measured, not scored: see report 7 (change, refactoring and
debugging task costs).

| language | architecture | readability | robustness | testability |
|---|---|---|---|---|
| Go | 5 / 5 | 4 / 4 | 4 / 4 | 4 / 4 |
| Rust | 5 / 5 | 4 / 4 | 4 / 4 | 4 / 4 |
| Java | 5 / 5 | 4 / 4 | 4 / 4 | 3 / 3 |
| Clojure | 5 / 5 | 4 / 4 | 4 / 4 | 4 / 4 |
| Python | 5 / 5 | 4 / 4 | 5 / 4 | 4 / 4 |
| Common Lisp | 4 / 4 | 4 / 4 | 4 / 4 | 3 / 4 |

Agreement over 24 score pairs: exact 92 %, within one point 100 %, mean absolute
difference 0.08, quadratic-weighted κ 0.84.

## How to read the scores

* **Compressed scale.** Almost every score is 4 or 5. The rubric separates the
  engines very little; the high agreement partly reflects that.
* **High scores can miss defects.** Python reviewer A gave robustness 5;
  reviewer B found a body-limit bypass that the harness then confirmed (below).
* **No blinding.** Reviewers necessarily knew the language.

## Findings raised by reviewers

| finding | engines | raised by | status |
|---|---|---|---|
| A negative HTTP chunk size (`int("-5", 16)`) makes the server read the request body to end-of-stream, bypassing `--max-request-bytes` | Python (`polyquery/server/http.py` `_read_chunked`) | Python B | **verified**: new harness check `malformed_chunked_body` (HTTP suite) fails for Python and passes for the other five engines |
| Panics in parallel worker goroutines are not recovered, so a panic would crash the process instead of returning `INTERNAL_ERROR` | Go | Go A and B | not verified (needs an internal fault) |
| No explicit SQL nesting-depth limit (relies on stack overflow or a large stack being caught) | Go, Clojure, Python; Rust allows 10,000 levels on a 256 MiB stack | several | partly covered by the fuzz stress inputs (`results/correctness/*-fuzz.json`: no crashes). Robustness probe `long_or_chain` (10,000- and 100,000-term `AND`/`OR` chains, `timeout_ms` 120,000): no crash, but **Go (100,000 terms, all modes), Java (100,000 terms: vectorized and auto, OR also parallel; the other 100,000-term cases return `TIMEOUT`) and Clojure (10,000 terms already, all modes) give no response within 180 s**. Rust returns `PARSE_ERROR`, Python `RESOURCE_LIMIT`, Common Lisp results or `TIMEOUT` |
| Session-mode stdin lines have no length cap | Rust, Java, Go, Common Lisp | several | **verified as an observation** (probe `session_huge_line`): a 256 MB malformed line is buffered whole (peak RSS 259 MB Rust to 3.1 GB Common Lisp; Clojure and Python, not flagged, behave alike), then answered with `INVALID_REQUEST`; every engine stays usable. The spec sets no session-line limit |
| Data-path checks are lexical: a symlink inside the data directory is followed | Rust, Clojure, Python, Common Lisp | several | not verified (needs a pre-existing symlink in the data directory) |
| Very large vectorized / parallel execution files and functions; thin unit tests for them (covered end to end by conformance and the mode matrix) | all | most | observation |
| Row-mode re-execution after unexpected vectorized/parallel errors can hide defects | Clojure (default on), Rust/Common Lisp (data errors only) | Clojure A and B | documented engine behaviour |

Robustness probes: `tests/regression/robustness_probe.py`, black-box through the protocol only (process
liveness, `/proc` descriptor counts and RSS), records in `results/correctness/robustness/<engine>.json`
(AArch64 run natively on the ARM host by `tools/remote/arm_probe.sh`, logs in `arm-logs/`). "No response" means
no reply within 180 s although `options.timeout_ms` was 120,000. The engine was still alive, so this is a timeout
that is not enforced (spec `errors.md`: an engine MUST NOT hang; `concurrency.md` §3). Expression size limits
themselves are open (SPEC-Q-002), so an error response such as `PARSE_ERROR` or `RESOURCE_LIMIT` passes.

## Kernel cohort: assembly kernel libraries (ADR-0016)

The same two reviewer slots read `native-kernels/x86_64/` and `native-kernels/arm64/`
after the kernel-optimize merge (commit `572663e`), read-only, each without seeing the
other architecture. Reviewer B started from the ABI header and the dispatcher and
followed kernel call paths. The rubric items were interpreted for a kernel library:
ABI conformance, bounds and tail handling and exact overflow semantics count as
robustness, and the library's own verification aids count as testability.
**These scores are not comparable with the engine scores above and are never ranked
against them**: a 20-kernel library is a different artefact from a complete engine.

| library | architecture | readability | robustness | testability |
|---|---|---|---|---|
| x86-64 assembly | 5 / 5 | 4 / 4 | 5 / 5 | 5 / 4 |
| AArch64 assembly | 5 / 4 | 5 / 4 | 4 / 5 | 3 / 3 |

Agreement over 8 score pairs: exact 50 %, within one point 100 %, mean absolute
difference 0.5.

| finding | library | raised by | status |
|---|---|---|---|
| Verification tools (guard-page harness, mutation checks, clobber audit, SVE vector-length matrix) were used during the run but not committed; the boundary cases of the new heuristics (e.g. `minmax_i128` skip windows) have no regression tests in the repository | AArch64 | A and B | observation. Both optimize tasks had identical text apart from the hardware notes; the x86-64 agent committed the same kind of tools under `verify/` |
| `group_sum_i64` returns `EINVAL` with outputs unchanged by subtracting the earlier chunks again: outputs are modified during the call and the result is wrong if outputs alias inputs | AArch64 NEON | A, B (as design) | not verified; the ABI header is silent on aliasing |
| No BTI landing pads or GNU property note | AArch64 | B | hardening gap, not functional |
| Block-size test constants are plain `#define`s and cannot be overridden from the build | AArch64 | B | observation |
| Kernels write scratch entries past the returned count in `out_idx` (within the documented capacity `n`) | both | A | allowed by the ABI |
| `DRV_ENTER` reads a seventh-argument stack slot in the 6-argument count kernels (never dereferenced) | x86-64 | B | not verified, harmless as described |
| README module-map line counts predate the optimization; an SVE file header still says "validated under emulation only" | x86-64; AArch64 | A; B | documentation drift |
| Heavy GAS macro metaprogramming and 2,000–2,500-line SIMD files after the optimization | both | all | observation |

No reviewer found a functional defect in the traced kernels.

## Assembly engine cohort: complete engines in assembly

The same two reviewer slots and prompts as for the six engines read
`implementations/x86_64-asm-engine/` (commit `fed2bd7`) and
`implementations/arm64-asm-engine/` (commit `b270646`) after the optimize-latency
merge, read-only, each reviewer seeing only its own architecture. Robustness
includes ABI correctness (SysV for x86-64, AAPCS64 for AArch64). These engines are
reported next to the six engines and **never ranked with them**; the two
architectures are not ranked against each other either.

| engine | architecture | readability | robustness | testability |
|---|---|---|---|---|
| x86-64 assembly engine | 5 / 5 | 4 / 4 | 4 / 4 | 4 / 4 |
| AArch64 assembly engine | 4 / 5 | 4 / 4 | 4 / 4 | 4 / 4 |

Agreement over 8 score pairs: exact 88 %, within one point 100 %, mean absolute
difference 0.13.

| finding | engines | raised by | status |
|---|---|---|---|
| A data file's descriptor leaks when an allocation raises while it is open (`read_data_file`; ARM also `pqcf_load`) | both | x86 A and B; ARM B | **not reproduced** (probe `fd_after_failed_loads`: no descriptor growth after 50 loads failing on the ingest limit or a query budget) |
| Session-mode stdin lines have no length cap | both | x86 B; ARM B | **verified as an observation**: a 256 MB line peaks at 258 / 290 MB RSS, then `INVALID_REQUEST`, engine stays usable (as the six engines) |
| Recursion depth safety relies on the large main-thread stack: parallel pool workers run on default stacks (x86, also without an alternate signal stack), and left-deep AND/OR chains are not depth-limited | both | x86 A and B; ARM B | **verified**: a 100,000-term `AND`/`OR` chain kills the x86-64 engine with SIGSEGV in parallel and auto mode (row mode answers correctly) and the AArch64 engine with SIGSEGV in vectorized, parallel and auto mode. 10,000 terms: correct results or `RESOURCE_LIMIT` |
| Each parallel task gets the full per-query memory budget, so a query can use about tasks × `--max-query-memory-mb` | AArch64 | ARM A and B | **consistent** (probe `parallel_memory_budget`, 1M-row `GROUP BY`, 64 MB budget): 8 threads grow RSS by 153 MB before `RESOURCE_LIMIT`, 1 thread by 0 MB. RSS is an indirect measure, so recorded as an observation |
| Error recovery can `longjmp` through the process-global `jmp_buf` into another thread's handler; recovery from SIGSEGV inside glibc is not async-signal-safe | x86-64 | x86 A and B | not verified (needs an internal fault) |
| A failed query leaves the query memory limit set for later non-query requests | x86-64 | x86 B | **verified** (probe `limit_after_failed_query`): after a query fails with `RESOURCE_LIMIT`, a load that succeeded before fails with `RESOURCE_LIMIT`. AArch64 and the six engines pass |
| (found by the probes, not by the reviewers) HTTP: a request whose header section never ends (`\r\n` flood) is buffered without limit | x86-64 | probe | **verified** (probe `http_crlf_flood`): RSS grows 1:1 with the bytes sent (128 → 512 → 1,024 MiB), and the server stays healthy. AArch64 stays flat and the six engines level off (Clojure ≈ 610 MB, Common Lisp ≈ 520 MB, the others close the connection or stay small) |
| `abort()` on out-of-memory in catalog cloning, query registration and HTTP buffers | AArch64 | ARM A and B | design (one case commented as intentional) |
| Very long routines (`veval` about 750–800 lines in both engines; binder, evaluator and lexer routines of 400–600 lines) | both | all | observation |

No reviewer found an ABI violation in the sampled routines (ARM reviewer A
statically checked all 1,410 function bodies against their `ENTER` depth). Both
engines have table-driven unit tests written in assembly. The AArch64 parser test
also checks that callee-saved registers survive a parse.
