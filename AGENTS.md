# AGENTS.md — Instructions for AI agents working on PolyQuery

> If you are an **implementation agent** inside a sandboxed experiment workspace,
> your instructions are in `TASK.md` at your workspace root; they take precedence
> over this file. This file is for agents maintaining the PolyQuery repository
> itself (spec, harnesses, orchestration, reports).

## 1. Project objectives

PolyQuery is a reproducible experiment comparing AI-assisted software
engineering across Java, Clojure, Rust, Python, Go and Common Lisp (complete
analytical database engines) plus ARM64 and x86-64 assembly (native kernels).
It measures (1) AI development effectiveness and (2) implementation quality.
See `docs/methodology/experiment-design.md`.

## 2. Repository structure

| Path | Contents |
|---|---|
| `spec/` | **Normative** language-neutral specification (types, SQL, protocol, storage, concurrency, errors, phases, acceptance). |
| `implementations/<lang>/` | Independent engines. Never share code between them. |
| `native-kernels/` | C ABI header, C reference, x86-64 and AArch64 assembly, kernel tests. |
| `tests/conformance/` | Language-neutral conformance harness (`runner.py`), `.pqt` cases, fixtures; `hidden/` = acceptance tests withheld from agents. |
| `tests/{integration,property-based,fuzz,concurrency,regression}/` | Additional harness suites (all black-box via the protocol). |
| `datasets/` | Deterministic generators, manifests, small committed fixtures. Large data is generated into `datasets/generated/` (git-ignored). |
| `benchmarks/` | Workloads, harness, profiles, reports. |
| `experiments/` | Prompts, manifests, agent transcripts, telemetry for every agent run. |
| `tools/` | `orchestration/` (workspaces, sandbox, agent adapter), `validation/` (oracle, PQCF reference), `reporting/`, `environment/` (doctor). |
| `results/` | Machine-readable results (correctness, performance, development, comparisons). |
| `docs/` | Architecture, methodology, ADRs, development guide, results narrative. |
| `project-state.json` | Machine-readable project state — **update at the end of every session**. |

## 3. Experimental integrity rules

1. The spec is the only authority. Never "fix" a test to match an engine;
   fix the engine, or change the spec through change control (`spec/README.md`).
2. Never use one engine's output as expected results for another.
3. Never inspect or copy one language's implementation while working on another.
   Implementation work happens only through `tools/orchestration/pq_orchestrate.py`
   in sandboxed workspaces (ADR-0007). If you must touch an engine directly
   (e.g. a harness-integration bug), record it as a human/maintainer intervention
   in `experiments/telemetry/interventions.jsonl`.
4. Never fabricate telemetry or benchmark numbers. Unavailable ⇒ `null` + reason.
5. Keep failed attempts. Never delete runs from `experiments/`.
6. Controlled (Track A) and ecosystem (Track B) results are never merged into a single ranking.
7. Hidden acceptance tests must never be copied into a workspace.
8. Emulated (qemu) runs are functional evidence only, never performance evidence.

## 4. Coding standards (infrastructure code)

* Python tooling: stdlib only, Python ≥ 3.12, type hints, `ruff`-clean style, no network access at runtime.
* Shell: `set -euo pipefail`, shellcheck-clean.
* C: C17, `-Wall -Wextra -Werror`, sanitizer-clean.
* Comments explain *why*; keep them sparse.

## 5. Tests required before committing

* Spec changes: `just spec-validate`.
* Harness changes: `just harness-selftest` and `just oracle-check`.
* Generator changes: `just datasets-verify`.
* Kernel changes: `just test-kernels`.
* Engine merges: `just test-language <lang>` (conformance up to the engine's claimed phase).

## 6. Commit conventions

`<area>: <imperative summary>` where area ∈ `spec, harness, datasets, bench,
telemetry, orchestration, kernels, impl/<lang>, docs, reports, ci, state`.
Milestone completions: `milestone: M<n> complete — <summary>`. Small, validated
commits. Agent-produced engine commits keep their original messages and author
`PolyQuery Agent`, and are merged via branches `track-a/<lang>/p<phase>/a<attempt>`.

## 7. Benchmarking requirements

See `docs/methodology/benchmarking.md`: process isolation, warmups, ≥ 5 measured
repetitions, randomized order, pinned CPUs, raw data retention, hardware/runtime
identification, never compare JVM startup with steady-state native numbers.

## 8. Telemetry requirements

See `docs/methodology/telemetry.md` and `experiments/telemetry/schema.json`.
Every agent run produces `experiments/runs/<run-id>/{manifest.json, telemetry.json, transcript.jsonl.gz, conformance.json}`.

## 9. Documentation requirements

Every decision that resolves an ambiguity gets an ADR. Every engine has a README
with its design, libraries and limitations. Results docs link to raw data.

## 10. Current milestone and how to resume

Read `project-state.json` first (`current_milestone`, `next_recommended_action`,
`outstanding_tasks`). Then run `just doctor` and `just experiment-status`.
Continue with the next recommended action. At the end of the session, update
`project-state.json` and commit.
