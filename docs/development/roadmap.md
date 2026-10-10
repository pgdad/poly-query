# Roadmap and Milestone Status

Acceptance criteria per milestone: [`spec/acceptance/README.md`](../../spec/acceptance/README.md) §3.
Live status: [`project-state.json`](../../project-state.json).

| Milestone | Content | Mechanism |
|---|---|---|
| M0 | Repository, spec, methodology, infrastructure | maintainer session |
| M1 | Protocol, conformance harness, public + hidden suites, SQLite oracle | maintainer session |
| M2 | Dataset generators, benchmark harness, telemetry, orchestrator, sandbox | maintainer session |
| M3 | Phase 1 engines × 6 | Track A wave `phase1` |
| M4 | Phase 2 engines × 6 | Track A wave `phase2` |
| M5 | Phase 3 engines × 6 + interop matrix + crash suite | Track A wave `phase3` |
| M6 | Phase 4 engines × 6 + HTTP suite | Track A wave `phase4` |
| M7 | Phase 5 engines × 6 + modes suite + benchmarks | Track A wave `phase5` |
| M8 | C reference + x86-64 (scalar, AVX2) + AArch64 (scalar, NEON) kernels | maintainer (C) + Track A wave `kernels` |
| M9 | Native integration (`native: true`) + kernel/e2e benchmarks | Track B / integration task |
| M10 | Reports, reproducibility validation | maintainer session |

## Per-wave procedure

```bash
python3 tools/orchestration/pq_orchestrate.py wave --task phaseN --attempt 1 --seed <recorded>
# after the wave: inspect experiments/runs/*/validation.json, then for each run to accept:
python3 tools/orchestration/pq_orchestrate.py import <run_id> --merge
just test-all && just report
```

A failed attempt is retained; a new attempt (`--attempt 2`) starts from the same
baseline. The next phase of a language starts only from an accepted (successful)
attempt; if no attempt succeeds within the attempt budget, the best attempt is
merged and the gap is recorded as a known defect and carried into the next
phase's task (the engine still has to pass all earlier phases' tests).

## Later experiment families (after M7)

Debugging (injected defects), refactoring, optimization, architectural changes
(`UNION ALL`, PQCF v2, DECIMAL(38)) and regression recovery — see
`docs/methodology/experiment-design.md` §4. Task definitions go to
`experiments/prompts/tasks.json`, defect patches to `experiments/controlled/defects/`.
