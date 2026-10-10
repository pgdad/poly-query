# Experiment Design

## 1. Research questions

* **RQ1 (development):** For a fixed model and agent harness, how do effort
  (tokens, cost, turns, wall time, repair iterations), reliability (success rate,
  failure modes) and maintainability-related outcomes differ across
  implementation languages when building the same system from the same spec?
* **RQ2 (quality):** How do the resulting implementations differ in
  correctness, performance, resource use, robustness and code size/structure?
* **RQ3 (evolution):** How costly and how safe are identical requirement
  changes, debugging tasks, refactorings and optimizations per language?

## 2. Experimental unit and factors

Unit: one **attempt** = one fresh agent session working on one
(language, task) pair in an isolated workspace until it stops or hits a limit.

| Factor | Levels |
|---|---|
| Language | Java, Clojure, Rust, Python, Go, Common Lisp (+ C/asm for kernels) |
| Task | phase1 … phase5 (initial implementation); debug-*, refactor-*, optimize-*, change-*, regress-* (§4) |
| Track | A (controlled), B (ecosystem-optimized) |
| Attempt | 1..k independent repetitions |

Held constant within a track: model id, agent harness version, effort setting,
prompt template (only language/toolchain placeholders differ), spec snapshot,
public tests, sandbox limits, wall-clock and budget limits, completion criteria.

## 3. Tracks

* **Track A — controlled:** standard-library-only policy (ADR-0003), identical
  prompts, identical visibility of tests (public suite visible, hidden suite
  withheld), same limits.
* **Track B — ecosystem-optimized:** starts from the accepted Track A Phase 4
  code of the same language (or from scratch where stated), permits any
  third-party libraries, compiler flags, runtime tuning and native interop;
  every deviation is recorded in `ENGINE.json` and the run manifest.

Track A and B results are reported separately and never combined in one ranking.

## 4. Task families

| Family | Procedure |
|---|---|
| Initial implementation | phase-k task from the spec; workspace contains the language's accepted phase-(k−1) code |
| Debugging | orchestrator injects a documented defect (from `experiments/controlled/defects/`) into accepted code, gives the failing test names; measure time/tokens to green and collateral regressions |
| Refactoring | behaviour-preserving design change (e.g. separate logical and physical planning); success = all tests still pass + rubric |
| Optimization | improve a benchmark target while keeping conformance; measure speedup achieved per token |
| Architectural change | identical requirement change for all languages (e.g. `UNION ALL`, storage format v2, decimal precision 38) |
| Regression recovery | controlled defects introduced silently; agent must find via tests |

## 5. Outcomes and classification

Every attempt ends in exactly one terminal status:

* `success` — all required acceptance tests (public + hidden) pass;
* `tests_failed` — builds, but some required tests fail;
* `build_failed` — `make build` fails;
* `timeout` — wall-clock limit reached;
* `budget_exhausted` — token/cost limit reached;
* `resource_exhausted` — sandbox OOM/disk;
* `agent_failure` — harness/API error, agent crash, refusal or stop without completion claim;
* `isolation_violation` — patch touched disallowed paths (attempt invalid but retained).

Failed attempts are kept. Time-to-success analyses treat unsuccessful attempts as
right-censored observations (Kaplan–Meier style), never silently dropped.

## 6. Order effects and randomization

Languages within a wave are started in a randomized order (seeded; seed in the
wave manifest). Runs in a wave execute in parallel with equal resource limits;
host contention is recorded (load average samples) in the manifest.

## 7. Threats to validity (tracked)

* Single model/harness ⇒ results do not generalize across models (stated).
* Model non-determinism ⇒ multiple attempts per cell where budget allows; with a
  single attempt the report states n=1 and shows no confidence intervals.
* Spec bias: the spec was written by the same model family that implements it.
* Infrastructure language (Python) ≠ an engine language; the Python engine agent
  sees no harness internals beyond the CLI contract (isolation).
* Parallel runs share a host ⇒ wall-clock is noisier; token counts are not affected.
* Track A stdlib policy disadvantages languages with small stdlibs on effort — this
  is an intended, reported effect.
