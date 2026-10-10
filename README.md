# PolyQuery

A reproducible experiment comparing **AI-assisted software engineering across
languages**: the same analytical database engine — CSV/JSON ingestion, a SQL
engine with joins/grouping/subqueries/CTEs, a crash-safe columnar file format
with indexes, an HTTP server with concurrency control, and vectorized/parallel
execution — is implemented independently by sandboxed AI agents in **Java,
Clojure, Rust, Python, Go and Common Lisp**, plus native kernels in **x86-64 and
AArch64 assembly**. The experiment measures both how effectively the agent
develops in each language (tokens, cost, time, repair iterations, failures) and
the quality of the result (correctness, performance, resources, maintainability).

| | |
|---|---|
| Specification (normative) | [`spec/`](spec/README.md) |
| Experiment design & methodology | [`docs/methodology/`](docs/methodology/experiment-design.md) |
| Architecture & decisions | [`docs/architecture/overview.md`](docs/architecture/overview.md), [`docs/decisions/`](docs/decisions/README.md) |
| Roadmap & milestone status | [`docs/development/roadmap.md`](docs/development/roadmap.md), [`project-state.json`](project-state.json) |
| Results | [`docs/results/`](docs/results/) (generated), [`results/`](results/) (machine-readable) |
| Agent instructions | [`AGENTS.md`](AGENTS.md) |

## Quick start (fresh clone)

```bash
just doctor                     # verify toolchains, record versions/hardware
just spec-validate              # spec ↔ tests consistency + SQLite oracle cross-check
just harness-selftest           # conformance harness self-tests
just test-language go           # build an engine and run the conformance suite
just test-kernels               # native kernels: differential tests (+ AArch64 under qemu)
just datasets 1m                # deterministic datasets (not committed; manifests are)
just benchmark-all 1m           # benchmarks → results/performance/<id>/
just report                     # reports → results/comparisons/, docs/results/report.html
just experiment-status          # agent runs and their outcomes
```

Without `just`, the `Makefile` offers the main targets, and every command is a
plain script under `tools/`, `tests/`, `benchmarks/`. Setup details:
[`docs/development/setup.md`](docs/development/setup.md).

## How the experiment runs

1. The spec, conformance suite (public + hidden), dataset generators and
   benchmark harness are fixed first (milestones M0–M2).
2. `tools/orchestration/pq_orchestrate.py wave --task phaseN` prepares a fresh,
   isolated repository per language, starts one headless Claude Code agent per
   language inside a bubblewrap sandbox (no access to other implementations,
   hidden tests, host credentials), records the full transcript and telemetry,
   then validates the result in the sandbox (clean-clone build, public + hidden
   tests) and stores the run record in `experiments/runs/`.
3. Accepted work is imported into the main repository on per-run branches.
4. Benchmarks and reports are produced from raw measurements only.

## Status

See [`project-state.json`](project-state.json) for the machine-readable state and
[`docs/development/roadmap.md`](docs/development/roadmap.md) for milestone status.

## License

MIT — see [LICENSE](LICENSE).
