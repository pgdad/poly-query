# Plan: complete database engines in x86-64 and AArch64 assembly (option B)

Status: **approved 2026-10-11, pilot in preparation.** Decision record: [ADR-0016](../decisions/ADR-0016.md).
Owner decisions (§8): pilot budget **$300** (double the proposed $150) for x86-64 Phase 1;
**glibc allowed**; AArch64 development **on the ARM host (spark)**, with whatever it needs
installed there.
Today the assembly languages take part through the native kernels: the original
kernel task plus the kernel experiment family (CR-4 change, CR-5 refactor,
debugging, optimization, code review). This plan covers going further:
an assembly language implementing the whole engine (Phases 1–5 and the later
experiment families) through the same black-box protocol as the six engines.

## 1. Research question

How far can an AI agent take a complete, concurrent, network-facing analytical
database in assembly, and at what cost relative to high-level languages?
Secondary: does assembly change the *kind* of defects (memory safety, ABI,
concurrency) and the cost of later changes (CR-1…CR-3)?

## 2. Scope and comparability rules

* **Separate cohort ("Track A-asm").** Assembly engines are reported next to,
  never ranked with, the six engines (same rule as Track A vs. Track B and as the
  kernel cohort). Same spec, same conformance suites, same hidden tests, same
  benchmark workload.
* **Same spec, no relaxations.** The pilot must not lower the bar. If a phase
  proves infeasible, that is the result.
* **Runtime library policy (decision needed, §8).** Proposed: dynamic linking
  against glibc (`libc`, `libm`, `libpthread`) is the "standard library": memory
  allocation, threads, sockets, file I/O, `strtod`/`snprintf` for float text.
  No other libraries, no C source, no compiler-generated assembly (the same rule
  as the kernel tasks). Raw-syscall-only would be a different experiment with a
  far larger scope (float parsing/formatting alone is substantial).
* **Native kernels.** An assembly engine *is* native code; the `native` option
  must still be honoured (it may call `libpqkernels` or ignore it, but results
  must be identical with and without it).

## 3. What has to be built (harness side)

| item | work |
|---|---|
| ADR + methodology | ADR-0016, cohort definition, this plan, report labels |
| `languages.json` | entries `x86_64-asm-engine`, `arm64-asm-engine` (toolchain, ABI, library policy, build notes) |
| prompt template | `track-a-implementation.md` works as is; add assembly-specific rules (ABI, `.note.GNU-stack`, no C) |
| orchestrator | engine languages may be assembly (today `ASM_LANGS` are kernel-only, `pq_orchestrate.py`); work dirs `implementations/x86_64-asm/`, `implementations/arm64-asm/` |
| **continuation runs** | a phase will likely not fit one 120-minute run: add a `--continue-from <run>` mode that starts a new session from the previous run's committed work (base = its import branch), recorded as one attempt with several sessions. Needed before the pilot. |
| AArch64 development loop | the agent runs on the x86 host; the ARM engine is built with the cross toolchain and tested with `qemu-aarch64` user mode (functional only; the conformance suite is black-box, so the runner works unchanged with a qemu wrapper `bin/polyquery`). Validation and all performance numbers come from the ARM host (`tools/remote/arm_engines.sh`). Alternative: agents on the ARM host (needs the Claude CLI, sandbox and usage guard there, and an OAuth credential copied to that machine — a security decision for the owner). |
| validation | unchanged (black-box): public + hidden conformance, `--modes`, HTTP transport, HTTP suite, fuzz, storage interop (matrix grows to 7×7 / 8×8), crash recovery |
| benchmarks | x86 engine on the quiet x86 host; ARM engine only on the ARM host, reported separately (no cross-architecture comparison) |
| reports | cohort column in reports 1–8; code-quality rubric reviewers for assembly |

### Implementation status (2026-10-11)

| item | state |
|---|---|
| language entries | `x86_64-asm-engine`, `arm64-asm-engine` (work dirs `implementations/<id>/`; the IDs differ from the kernel cohort's `x86_64-asm`/`arm64-asm`) |
| prompt | the engine template unchanged for the six engines (byte-identical renders); assembly rules via `EXTRA_RULES`, glibc policy via `stdlib_note` |
| continuation runs | `pq_orchestrate.py chain --task phaseN --lang L --max-sessions 3 --total-budget-usd B --timeout-min 120`: each session is its own recorded run (`-sN` suffix, `continues`, `session`), cloned from the previous session's workspace with its git history; the budget is shared across sessions; import covers all sessions |
| AArch64 loop | agents and their validation run natively on spark (`agent_host`), in the same bubblewrap sandbox (`tools/remote/spark_sandbox.sh`, installed by `tools/remote/spark_agent_setup.sh`); the credential copy exists on spark only during a run |
| still to do before Phase 5 | the native-kernel library path in engine validation is x86-only (`native-kernels/build/x86_64`); the AArch64 engine needs the aarch64 build there |
| pilot | started 2026-10-11 16:40 UTC: x86-64 Phase 1, attempt 1, ≤ 3 sessions × 120 min, $300 |

## 4. Phasing and stop rules

1. **Pilot (x86-64 only, Phase 1).** One attempt, continuation allowed up to
   3 sessions × 120 min. Measures cost, time, LOC and defect profile.
   *Stop rule:* if Phase 1 is not reached within the pilot budget, record the
   result and stop (no ARM, no later phases).
2. **x86-64 Phases 2–5**, one phase per wave, same continuation rules.
3. **AArch64 Phases 1–5** (functional development under qemu, native validation).
4. **Later families** (CR-1 UNION ALL, CR-3 refactor, CR-2 decimal38,
   debugging, optimization) for both assembly engines, identical prompts.
5. **Code review** (two rubric reviewers per engine), reports, narrative.

## 5. Cost and time (estimates, not measurements)

Measured so far: Phases 1–5 cost $57–101 per high-level language (15–33 kLOC);
the 16-kernel assembly task cost $5–12 (≈1.1–3.5 kLOC per variant file).
An assembly engine is likely several times the size of the high-level engines.
Rough planning range: **$300–1,500 and 15–60 agent hours per assembly engine
for Phases 1–5**, with wide uncertainty; the pilot replaces this guess with a
measured Phase 1 figure before anything else is committed.

## 6. Risks

* **Run-length limit.** 120-minute sessions vs. a very large phase ⇒ continuation
  runs (§3); without them the result would mostly measure the time limit.
* **Memory-safety defects** in a network server: all engine execution is already
  sandboxed (bubblewrap on x86, locked-down systemd units on the ARM host).
* **Concurrency** (Phase 4/5: threads, snapshot isolation) in assembly is the
  most likely failure point.
* **Emulated ARM development** is slow for the 746-case suite plus the mode
  matrix; the runner's per-case timeouts may need a qemu multiplier.
* **Comparability.** Different time per phase and continuation sessions must be
  reported explicitly (sessions, wall time, cost) so the cohort is interpretable.

## 7. Deliverables

Engines under `implementations/{x86_64,arm64}-asm/`, run records in
`experiments/runs/`, correctness/performance results, cohort sections in reports
1–8, a results narrative section, and an updated `project-state.json`.

## 8. Decisions (taken 2026-10-11)

1. Pilot approved with a **$300** cap for Phase 1, x86-64 (proposed was $150).
   After Phases 1-3 for both engines ($118.49, every phase in one session) the owner
   raised the cap for the assembly engines to **$600** (2026-10-11) for Phases 4-5 and
   continuation sessions.
2. Library policy: **glibc allowed** (dynamic `libc`, `libm`, `libpthread`), as proposed.
3. ARM development loop: **agents run on the ARM host (spark)**. This needs the Claude
   CLI, the sandbox and the usage guard on spark, and the OAuth credential copied
   there (only the credential file, as on the x86 host). Agents run as an unprivileged
   user in a locked-down unit; engine code still never runs outside the sandbox.
