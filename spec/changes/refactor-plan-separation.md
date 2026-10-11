# Change request CR-3: logical/physical plan separation (refactoring)

Status: adopted for the *refactoring* experiment family. Applies identically to
every language. **No externally visible behaviour may change**: same responses,
same errors, same EXPLAIN output, same capabilities.

## 1. Required internal structure

After the refactoring the engine MUST have:

1. **An explicit logical plan representation** — a data structure (not code
   paths) describing relational operators independent of execution strategy:
   at least `Scan`, `Filter`, `Project`, `Join` (with join type and condition),
   `Aggregate` (keys + aggregate calls), `Sort`, `Limit`, `Distinct`, and the
   subquery / CTE constructs the engine supports. It must be possible to print
   it for debugging (internal API or test helper; not a protocol change).
2. **A rule-based logical optimizer** that operates *only* on the logical plan
   and is composed of separately named rules, at least:
   * predicate pushdown (below projections and into join inputs where valid),
   * projection / column pruning,
   * constant folding of literal-only expressions.
   Each rule must be individually testable and the optimizer must honour the
   `optimize: false` query option by applying no rules.
3. **A separate physical planning step** that maps the (optimized) logical plan
   to physical operators: access path (table scan vs index scan), join
   algorithm (hash / merge / nested loop, honouring the `join` option),
   execution mode (`row` / `vectorized`, `threads`) and native kernels.
   Physical decisions MUST NOT be taken inside the logical layer.
4. `EXPLAIN` output continues to be produced from the physical plan exactly as
   before.

Engines that already have this structure must demonstrate it (README module
map) and may limit themselves to closing the gaps.

## 2. Acceptance

* Every conformance case that passed before still passes (session, HTTP,
  `--modes`, native), the HTTP suite still passes.
* The capability set is unchanged.
* Unit tests exist for each optimizer rule.
* `README.md` contains a *before / after* module map naming the files/modules of
  the logical plan, each optimizer rule, and the physical planner.

Assessment beyond pass/fail uses the code-quality rubric
(`docs/methodology/code-quality-rubric.md`) and the size of the diff.
