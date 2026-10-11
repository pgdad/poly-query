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
| No explicit SQL nesting-depth limit (relies on stack overflow or a large stack being caught) | Go, Clojure, Python; Rust allows 10,000 levels on a 256 MiB stack | several | partly covered by the fuzz stress inputs (`results/correctness/*-fuzz.json`: no crashes) |
| Session-mode stdin lines have no length cap | Rust, Java, Go, Common Lisp | several | not verified |
| Data-path checks are lexical: a symlink inside the data directory is followed | Rust, Clojure, Python, Common Lisp | several | not verified (needs a pre-existing symlink in the data directory) |
| Very large vectorized / parallel execution files and functions; thin unit tests for them (covered end to end by conformance and the mode matrix) | all | most | observation |
| Row-mode re-execution after unexpected vectorized/parallel errors can hide defects | Clojure (default on), Rust/Common Lisp (data errors only) | Clojure A and B | documented engine behaviour |

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
