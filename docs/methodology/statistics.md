# Statistical Methodology

* **Attempts:** each (language, task) cell supports k independent attempts
  (fresh session, fresh workspace). Budget permitting k ≥ 3; otherwise reports
  state n explicitly and avoid inferential claims.
* **Outcomes** are categorical (success, tests_failed, build_failed, timeout,
  budget_exhausted, resource_exhausted, agent_failure, isolation_violation);
  failed attempts are always retained and reported.
* **Time/cost to success** is treated as a time-to-event outcome; unsuccessful
  attempts are right-censored at their observed value. With small n we report
  per-attempt values and medians, not means.
* **Distributions over averages:** box/strip plots of per-attempt values;
  latency distributions (p50/p95/p99) for performance.
* **Benchmark uncertainty:** bootstrap CI of medians; differences are reported as
  ratios with CIs; overlapping CIs are not called differences.
* **Order effects:** languages are started in a seeded random order per wave,
  in parallel with equal limits; host load is recorded.
* **Language vs. model effects:** one model and harness are used throughout; the
  study therefore estimates language effects *for this model/harness* only.
* **Code-quality scores** are produced only with explicit rubrics
  (`docs/methodology/code-quality-rubric.md`); automated metrics (LOC, files,
  test LOC, cyclomatic proxies) are labelled as such; human ratings, if any,
  record inter-rater agreement (Cohen's κ / Krippendorff's α).
* **Weighted overall scores** are gated: an implementation that fails required
  correctness tests cannot be ranked above one that passes, whatever the weights.
