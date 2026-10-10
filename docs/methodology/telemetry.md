# AI Development Telemetry

Every agent attempt produces `experiments/runs/<run_id>/` containing:

| File | Content |
|---|---|
| `manifest.json` | reproducible run manifest: run id, wave, language, task, track, attempt, repo commit of the baseline, spec tree hash, prompt template id + SHA-256 of the rendered prompt, model id, effort level, agent harness name/version, limits (timeout, budget, turns), host tool versions and hardware, timestamps, exit code, outcome |
| `telemetry.json` | metrics below (schema `experiments/telemetry/schema.json`) |
| `transcript.jsonl.gz` | complete stream-json event log of the agent session; every event wrapped as `{"_t": seconds_since_start, "event": …}` |
| `TASK.md` | the exact rendered prompt |
| `validation.json`, `conformance*.json`, `http-suite.json`, `kernel-bench.json` | sandboxed post-run validation (clean clone build, public + hidden suites) |

## Metric definitions and sources

| Metric | Source | Notes |
|---|---|---|
| model, harness version, session id | `system/init` event | |
| input / output / cache-read / cache-creation tokens | final `result` event `usage` | if the run was killed (timeout) there is no `result` event: per-message usage is summed (deduplicated by message id); output tokens are then a **lower bound** (flagged in `tokens.source`) |
| thinking tokens (estimated) | `system/thinking_tokens` events | platform estimate |
| cost (USD) | `result.total_cost_usd` | platform-reported list-price equivalent; the runs used a subscription, so this is not an invoice amount; null when no `result` event |
| agent turns | `result.num_turns` | |
| tool calls (per tool), tool failures | `tool_use` / `tool_result.is_error` | |
| build invocations / failures | Bash commands matching build tools; failure = output matches compiler-error patterns | heuristic, documented |
| conformance runs, progress | Bash commands invoking `runner.py … --engine`; parsed `TOTAL: x/y pass` | |
| repair iterations | conformance runs after the first run that reported failures | |
| wall time | orchestrator clock | |
| model API time | `result.duration_api_ms` | |
| tool time | sum of (tool_result receive time − tool_use receive time) | includes model streaming latency of the tool_use block's tail; approximate |
| waiting time | — | not exposed: `null` |
| human time / interventions | 0 by construction (unattended) | any maintainer intervention is logged in `experiments/telemetry/interventions.jsonl` and reported |
| git commits, lines added/removed, files | `git` in the workspace (baseline..HEAD, language dir) | |
| rate-limit utilization | `rate_limit_event` | subscription window utilization observed during the run |
| outcome | sandboxed validation, see experiment-design.md §5 | |

Credentials and environment variables are never written to telemetry; the
transcript contains only what the agent saw (its sandbox has no host secrets).

The orchestrating session's own token usage (spec, harness, reports) is not
machine-readable from within that session and is reported as unavailable (ADR-0014).
