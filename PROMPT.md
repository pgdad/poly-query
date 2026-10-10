# PolyQuery — Master Implementation Prompt

## Role and Mission

You are the principal architect, research engineer, and autonomous implementation agent for **PolyQuery**, a comprehensive experiment evaluating AI-assisted software engineering across multiple programming languages.

Your mission is to design, implement, test, benchmark, and document a fully functional, multi-language analytical database engine in a single Git repository.

This is both a software engineering project and a reproducible research experiment.

The experiment must measure two independent dimensions:

1. **AI-assisted development effectiveness:** How efficiently and reliably an AI coding agent can implement, debug, optimize, extend, and maintain a substantial system in each language.
2. **Software implementation quality:** The correctness, performance, resource efficiency, robustness, and maintainability of the resulting implementations.

Do not optimize exclusively for development speed or runtime performance. Preserve the ability to measure both.

Do not stop after creating scaffolding, initial examples, or a minimal prototype. The ultimate objective is to implement the complete feature set described below, across all required languages, with reproducible tests and benchmark results.

Work incrementally, committing validated milestones. If the project cannot be completed in one session, preserve sufficient state for another agent session to resume without losing context.

Never report a feature as complete unless its required acceptance tests pass.

---

# 1. Required Languages and Platforms

Implement PolyQuery independently in:

1. Java — target Java 27, subject to installed toolchain availability.
2. Clojure — target the JVM and current stable Clojure.
3. Rust — current stable Rust.
4. Python — current stable CPython.
5. Go — current stable Go.
6. Common Lisp — SBCL as the primary implementation.

Additionally, implement performance-critical native kernels in:

7. ARM64 assembly — AArch64, with NEON and optional SVE variants.
8. x86-64 assembly — System V AMD64 ABI, with AVX2 and optional AVX-512 variants.

Use C17 as the reference language for native kernel correctness and ABI definitions, but not as a seventh complete database implementation.

The complete database engines must remain independently implemented. They must not share a core database engine implemented in another language.

Language-specific standard libraries and carefully selected third-party libraries are permitted in the ecosystem-optimized experiment, but must be documented.

Record compiler versions, runtime versions, optimization flags, library versions, and hardware capabilities.

Support Linux and macOS where feasible. Provide containerized Linux execution for reproducibility.

Architecture-specific tests and benchmarks must be skipped with an explicit reason when compatible hardware is unavailable. Never present emulated performance as native hardware performance.

---

# 2. Repository Organization

Create a single Git repository using this structure:

```text
polyquery/
├── README.md
├── AGENTS.md
├── LICENSE
├── Makefile
├── justfile
├── .github/
│   └── workflows/
├── docs/
│   ├── architecture/
│   ├── methodology/
│   ├── decisions/
│   ├── development/
│   └── results/
├── spec/
│   ├── protocol/
│   ├── sql/
│   ├── data-types/
│   ├── storage/
│   ├── concurrency/
│   ├── errors/
│   ├── phases/
│   └── acceptance/
├── implementations/
│   ├── java/
│   ├── clojure/
│   ├── rust/
│   ├── python/
│   ├── go/
│   └── common-lisp/
├── native-kernels/
│   ├── include/
│   ├── reference-c/
│   ├── arm64/
│   ├── x86_64/
│   └── tests/
├── datasets/
│   ├── generators/
│   ├── fixtures/
│   └── manifests/
├── tests/
│   ├── conformance/
│   ├── integration/
│   ├── property-based/
│   ├── fuzz/
│   ├── concurrency/
│   └── regression/
├── benchmarks/
│   ├── workloads/
│   ├── harness/
│   ├── profiles/
│   └── reports/
├── experiments/
│   ├── manifests/
│   ├── agents/
│   ├── prompts/
│   ├── telemetry/
│   ├── controlled/
│   └── ecosystem/
├── tools/
│   ├── orchestration/
│   ├── validation/
│   ├── reporting/
│   └── environment/
└── results/
    ├── correctness/
    ├── performance/
    ├── development/
    └── comparisons/
```

Use a monorepo architecture without sacrificing implementation independence.

The repository must be usable from a fresh clone with documented setup steps.

---

# 3. Fundamental Experimental Rules

## 3.1 Specification-first development

Before implementing database engines:

- Define a language-neutral specification.
- Define the wire protocol.
- Define the supported SQL grammar.
- Define exact query semantics.
- Define storage format versions.
- Define concurrency guarantees.
- Define error codes.
- Define acceptance criteria.
- Implement the independent conformance test harness.
- Implement deterministic dataset generators.

The shared specification is the sole normative authority for all language implementations.

## 3.2 Implementation isolation

Each language implementation must be developed in an isolated Git worktree or equivalent workspace.

An implementation agent may access:

- The shared specification.
- Shared test interfaces and public fixtures.
- Its own language implementation.
- Language-specific toolchain documentation.
- Install any tools required for the work, including programming language tools
- Approved experiment infrastructure.

It must not inspect source code from another language implementation.

The experiment orchestrator must enforce or verify this isolation.

Use filesystem-level isolation or separate containers for strict controlled runs. Instructions alone are not sufficient isolation.

## 3.3 No cross-language translation

Do not generate the Rust implementation by translating Java, or the Common Lisp implementation by translating Python.

Each implementation should be independently designed using idiomatic language constructs.

The goal is to observe how AI approaches the same problem in different languages.

## 3.4 Two experimental tracks

Maintain two distinct experimental tracks.

**Track A — Controlled comparison**

- Same model and model version.
- Same reasoning or thinking budget.
- Same functional specification.
- Same available context.
- Same agent tooling policy where possible.
- Same test visibility.
- Same resource limits.
- Same completion criteria.
- No access to other implementations.

**Track B — Ecosystem-optimized comparison**

Allow each agent to use the most appropriate language-specific:

- Libraries.
- Compiler optimizations.
- Runtime configurations.
- Concurrency primitives.
- Profilers.
- Data structures.
- Native interoperability features.

Record all deviations from the controlled track.

Never mix controlled and ecosystem-optimized results in a single undifferentiated ranking.

---

# 4. PolyQuery Functional Requirements

Implement a standalone analytical database supporting structured datasets and SQL-like queries.

## Phase 1 — In-Memory Data Engine

Implement:

- CSV ingestion.
- JSON and JSON Lines ingestion.
- Explicit and inferred schemas.
- Typed columns.
- Null values.
- Integer and floating-point values.
- Fixed-precision decimal values.
- Strings and booleans.
- Dates and timestamps.
- Filtering.
- Projection.
- Sorting.
- LIMIT and OFFSET.
- COUNT, SUM, MIN, MAX, AVG.
- Basic memory management.
- Deterministic query results.

All six languages must pass the same conformance tests.

## Phase 2 — SQL Parser and Query Engine

Implement a documented SQL subset supporting:

- SELECT.
- FROM.
- WHERE.
- AND, OR, NOT.
- Comparison operators.
- Arithmetic expressions.
- Aliases.
- ORDER BY.
- GROUP BY.
- HAVING.
- LIMIT and OFFSET.
- INNER JOIN.
- LEFT JOIN.
- DISTINCT.
- Aggregations.
- Scalar functions.
- Nested expressions.
- Subqueries.
- Common table expressions.

Implement:

- Lexer.
- Parser.
- Abstract syntax tree.
- Semantic validation.
- Logical query plan.
- Physical execution plan.
- Query execution.
- Structured error reporting.

Define operator precedence, null semantics, numeric coercion, decimal precision, overflow, string comparison, timestamp handling, and deterministic ordering.

## Phase 3 — Storage and Indexing

Implement:

- Row-oriented in-memory representation.
- Column-oriented in-memory representation.
- Persistent binary columnar storage.
- Versioned file format.
- Checksums.
- Metadata and schema persistence.
- Dictionary encoding.
- Null bitmaps.
- Basic compression.
- Memory-mapped file support where available.
- Hash indexes.
- B-tree or equivalent ordered indexes.
- Table statistics.
- Index selection.
- Predicate pushdown.
- Column pruning.
- Basic cost-based query planning.

Storage must be interoperable across all six implementations.

Every implementation must be able to read a storage file written by any other implementation.

Define crash-consistency guarantees and verify them.

## Phase 4 — Networking and Concurrency

Implement:

- HTTP API.
- Query execution endpoint.
- Dataset ingestion endpoint.
- Schema inspection endpoint.
- Health endpoint.
- Metrics endpoint.
- Streaming query results.
- Concurrent readers.
- Configurable worker limits.
- Query cancellation.
- Query timeouts.
- Backpressure.
- Graceful shutdown.
- Structured logging.

Define a consistent concurrency contract.

Avoid adding distributed consensus or replication in this phase; those are optional future extensions and must not distract from the primary comparison.

## Phase 5 — Optimization

Implement and compare:

- Row-at-a-time execution.
- Vectorized execution.
- Batch processing.
- Parallel scans.
- Parallel aggregations.
- Hash joins.
- Sort-merge joins.
- Query-plan optimization.
- SIMD filtering.
- SIMD aggregation.
- Memory allocation optimization.
- Cache-aware data layouts.

Optimization must preserve correctness.

Retain unoptimized baselines for performance comparison.

---

# 5. Native Assembly Kernels

Create a stable C ABI for native kernels.

Implement at least:

1. Integer filtering.
2. Integer summation.
3. Minimum and maximum.
4. Predicate counting.
5. Bitmap operations.
6. Hashing.
7. Fixed-width value comparison.
8. Selected vectorized aggregation primitives.

For each kernel, implement:

- Portable C reference.
- ARM64 scalar assembly.
- ARM64 NEON implementation where applicable.
- x86-64 scalar assembly.
- x86-64 AVX2 implementation where applicable.

Optional implementations:

- ARM SVE.
- x86 AVX-512.

Requirements:

- Correct calling conventions.
- Alignment handling.
- Unaligned inputs.
- Empty inputs.
- Tail processing.
- Overflow semantics.
- Boundary cases.
- Randomized differential testing.
- Sanitizer testing where supported.
- CPU feature detection.
- Runtime dispatch.

Expose kernels through language-appropriate FFI mechanisms.

Measure both:

- Direct kernel execution performance.
- End-to-end database query performance using the kernels.

Keep native acceleration optional and retain a correct language-native fallback.

Never require native kernels for basic conformance.

---

# 6. Shared Protocol

Every engine must support an identical external protocol.

Provide:

- CLI execution mode.
- Long-running server mode.
- Machine-readable JSON request and response format.
- Consistent error schema.
- Deterministic output serialization.
- Engine capability reporting.
- Engine version reporting.

Define a protocol version.

The benchmark harness must be able to replace one language engine with another without changing workload definitions.

All implementations must produce equivalent results for equivalent requests.

---

# 7. Dataset Generation

Create deterministic datasets using explicit random seeds.

Include:

- Small correctness datasets.
- Medium integration datasets.
- Large analytical datasets.
- Highly selective filters.
- Low-selectivity filters.
- High-cardinality groupings.
- Low-cardinality groupings.
- Skewed distributions.
- Uniform distributions.
- Null-heavy datasets.
- Wide and narrow tables.
- Join-heavy datasets.
- Sorting workloads.
- Time-series data.
- Financial transaction data.
- Synthetic customer data.

Provide scale factors targeting approximately:

- 10,000 rows.
- 100,000 rows.
- 1 million rows.
- 10 million rows.
- 100 million rows, where hardware permits.

Do not commit enormous generated datasets to Git.

Commit generators, seeds, schemas, manifests, and checksums instead.

---

# 8. Conformance Testing

Build the conformance harness independently from the database implementations.

Use a trusted reference implementation, such as SQLite or DuckDB, where semantics match the PolyQuery specification.

Where semantics differ, use explicit independently reviewed expected results.

Do not treat the output of one PolyQuery language implementation as the authoritative expected result.

Test:

- Parsing.
- Type checking.
- Query results.
- Numeric precision.
- Null handling.
- Sorting.
- Aggregations.
- Joins.
- Index correctness.
- Storage interoperability.
- Invalid inputs.
- Resource limits.
- Concurrency.
- Cancellation.
- Persistence.
- Crash recovery.

Add property-based testing, randomized differential testing, and fuzzing.

Maintain public development tests and separate hidden acceptance tests.

Hidden acceptance tests must not be accessible to implementation agents during controlled runs.

Produce machine-readable correctness reports.

---

# 9. Performance Benchmarking

Build a language-neutral benchmark harness.

Measure:

- Query throughput.
- Query latency.
- p50, p95, and p99 latency.
- Startup time.
- Warmup time.
- Peak resident memory.
- Allocations where measurable.
- CPU utilization.
- Ingestion throughput.
- Storage size.
- Index construction time.
- Cold-cache performance.
- Warm-cache performance.
- Single-thread performance.
- Multi-thread scaling.
- Native kernel performance.

Use appropriate benchmark techniques:

- Multiple repetitions.
- Warmup runs.
- Randomized execution order.
- Process isolation.
- Explicit CPU and memory limits.
- Hardware identification.
- Runtime and compiler identification.
- Confidence intervals.
- Outlier reporting.
- Raw measurement retention.

Do not compare JVM startup behavior directly with steady-state native execution without clearly separating those measurements.

Do not report cross-machine comparisons as direct language performance comparisons.

Record architecture, CPU model, memory capacity, operating system, compiler flags, and runtime configuration.

---

# 10. AI Development Telemetry

This is a core part of the experiment, not an optional feature.

Build a telemetry system that records each implementation attempt.

Capture:

- Language.
- Feature or milestone.
- Experiment track.
- Model name and version.
- Agent harness version.
- Prompt identifier.
- Prompt hash.
- Session identifier.
- Attempt identifier.
- Input tokens.
- Output tokens.
- Cached tokens, when available.
- Model/API cost, when available.
- Number of agent turns.
- Tool calls.
- Tool failures.
- Compiler errors.
- Test failures.
- Repair iterations.
- Wall-clock elapsed time.
- Human intervention time.
- Number of human interventions.
- Git commits.
- Source code changes.
- Final acceptance status.

Do not fabricate unavailable telemetry.

Use explicit null values when the underlying agent platform does not expose a metric.

Distinguish model generation time, tool execution time, waiting time, and human time when available.

Capture a reproducible experiment manifest for every run.

Never expose credentials or sensitive environment variables in telemetry logs.

---

# 11. AI Development Experiments

For each language and feature, run experiments measuring:

## Initial implementation

How effectively can the AI implement a feature from a specification?

## Debugging

How effectively can the AI identify and repair defects?

## Refactoring

How effectively can the AI improve an existing design without changing behavior?

## Optimization

How effectively can the AI improve performance while preserving correctness?

## Architectural change

Introduce identical requirements changes to every language implementation.

Examples:

- Convert row-oriented execution to column-oriented execution.
- Introduce streaming results.
- Add decimal precision guarantees.
- Introduce query cancellation.
- Add a new SQL operator.
- Change the storage format version.

Measure the cost and correctness of each change.

## Regression recovery

Introduce controlled defects and measure the AI's ability to detect and repair them.

Preserve all experiments as independently reproducible runs.

---

# 12. Statistical and Experimental Methodology

Do not assume a single AI run is representative.

Support multiple independent attempts per language and feature.

Use fresh agent sessions and isolated workspaces.

Record random seeds and experimental conditions.

Randomize or counterbalance language execution order to reduce systematic bias.

Distinguish:

- Failure to compile.
- Failure to pass tests.
- Timeout.
- Resource exhaustion.
- Agent failure.
- Successful completion.

Avoid survivorship bias by retaining failed attempts in the dataset.

Report distributions rather than only averages.

For time-to-completion analysis, account for unsuccessful or timed-out runs rather than excluding them.

Separate implementation-language effects from agent/model effects.

Avoid presenting subjective code-quality scores as objective facts. Use explicit rubrics and record reviewer agreement when human evaluation is performed.

---

# 13. Scoring and Reporting

Generate independent reports for:

1. Functional correctness.
2. Development effort.
3. Runtime performance.
4. Resource efficiency.
5. Code quality and maintainability.
6. Optimization effectiveness.
7. Architectural adaptability.
8. Overall experimental outcomes.

Preserve raw measurements.

Support configurable scoring weights.

Do not allow a weighted overall score to conceal a correctness failure.

Provide visualizations including:

- Language versus development time.
- Language versus token usage.
- Language versus cost.
- Language versus correctness.
- Language versus throughput.
- Language versus memory consumption.
- Language versus latency.
- Language versus repair iterations.
- Language versus maintenance effort.
- Language versus optimization improvement.

Include Pareto-frontier analysis for development cost, correctness, and runtime performance.

Generate machine-readable JSON/CSV and human-readable HTML reports.

Every reported result must link to the corresponding experiment manifest and raw measurements.

---

# 14. Development Orchestration

Create an experiment orchestrator capable of:

- Creating isolated Git worktrees.
- Preparing isolated agent workspaces.
- Provisioning development environments.
- Assigning language-specific implementation tasks.
- Supplying the appropriate specification.
- Running tests.
- Capturing telemetry.
- Committing validated milestones.
- Running benchmarks.
- Collecting results.
- Generating reports.

Support both sequential and parallel implementation runs.

Controlled experiments must not permit one implementation agent to observe another implementation's source code or results before completing its own run.

If the selected coding-agent platform supports programmatic invocation, integrate it behind an adapter.

Otherwise, provide a documented manual invocation mechanism.

Do not claim automatic token or cost capture unless supported by the actual agent platform.

---

# 15. Toolchain and Developer Experience

Provide convenient commands such as:

```bash
just setup
just doctor
just spec-validate
just test-all
just test-language rust
just benchmark-all
just benchmark-language java
just benchmark-kernels
just report
just experiment-status
```

Also provide:

- CI pipelines.
- Language-specific linting.
- Formatting.
- Dependency pinning.
- Reproducible builds.
- Environment verification.
- Clear error messages.
- Developer documentation.

CI must support partial feature completion without falsely marking unimplemented features as passing.

Provide a capability matrix showing exactly which features are implemented and tested in each language.

---

# 16. Git and Milestone Strategy

Use small, meaningful commits.

Recommended milestone order:

- M0: Repository, specification, methodology, and infrastructure.
- M1: Shared protocol and conformance harness.
- M2: Dataset generators and benchmark harness.
- M3: All six Phase 1 engines.
- M4: All six Phase 2 engines.
- M5: All six Phase 3 engines.
- M6: All six Phase 4 engines.
- M7: All six Phase 5 optimized engines.
- M8: Portable C and architecture-specific assembly kernels.
- M9: Native integration and comparative benchmarks.
- M10: Complete experimental reports and reproducibility validation.

Each milestone must have explicit acceptance criteria.

Do not move a milestone to complete merely because its code exists.

If work remains incomplete, document the exact status and continue with the next required task in subsequent sessions.

---

# 17. Agent Instructions and Persistent Project Memory

Create an AGENTS.md file at the repository root.

It must describe:

- Project objectives.
- Repository structure.
- Experimental integrity rules.
- Implementation isolation.
- Coding standards.
- Test requirements.
- Commit conventions.
- Benchmarking requirements.
- Telemetry requirements.
- Documentation requirements.
- Current milestone.
- How to resume development.

Maintain a machine-readable project state file containing:

- Completed milestones.
- In-progress milestones.
- Outstanding tasks.
- Known defects.
- Blockers.
- Test results.
- Last successful commit.
- Next recommended action.

The state file must be updated at the end of every substantial work session.

Do not rely exclusively on the agent's conversational context for project continuity.

---

# 18. Resource and Security Constraints

Treat SQL input, dataset files, and external dependencies as untrusted.

Implement resource limits, input validation, and bounded execution.

Do not execute arbitrary SQL-provided code.

Do not permit unsafe file access through query inputs.

Run coding agents and generated binaries with least privilege.

Do not expose host credentials to isolated experiment environments.

For assembly and FFI:

- Validate memory bounds.
- Test alignment assumptions.
- Detect supported CPU features.
- Avoid unsupported instructions.
- Test error and edge cases.

Record any remaining security limitations.

---

# 19. Definition of Done

The project is complete only when:

- All six language implementations exist.
- All required functional phases are implemented.
- All implementations pass the shared conformance suite.
- Cross-language storage interoperability works.
- HTTP and CLI protocols are consistent.
- Native C reference kernels pass.
- ARM64 assembly kernels pass on native ARM64 hardware.
- x86-64 assembly kernels pass on native x86-64 hardware.
- Native integration is validated where supported.
- Benchmarks can be reproduced.
- AI development telemetry is collected or explicitly marked unavailable.
- Controlled and ecosystem-optimized experiments are separately reported.
- Reports include failures and incomplete attempts.
- Documentation enables another engineer to reproduce the experiment.
- No required feature is silently omitted.

Where compatible hardware or agent instrumentation is unavailable, report that limitation explicitly rather than claiming full validation.

---

# 20. Execution Instructions

Begin immediately.

First:

1. Inspect the current environment, available tools, operating system, compilers, and runtime versions.
2. Create the repository if it does not exist.
3. Establish the architecture and experiment methodology.
4. Identify ambiguities in the requirements and resolve them through documented architectural decisions.
5. Create the complete implementation roadmap.
6. Implement the shared specification and test infrastructure.
7. Establish the experiment telemetry system.
8. Implement the first functional milestone across all six languages.
9. Validate the milestone.
10. Commit the results.
11. Continue through the remaining milestones.

Do not request approval after every phase.

Make reasonable engineering decisions autonomously and document them.

Do not reduce the scope of the project without explicitly documenting the deviation.

Do not substitute placeholder implementations for completed functionality.

Do not claim benchmarks were executed when only benchmark scripts were generated.

When encountering an error, investigate, repair, and rerun the relevant validation.

If a task requires unavailable hardware or credentials, complete all independent work, mark the blocked validation accurately, and proceed with other work.

At the end of each session, report:

- Current milestone.
- Features completed.
- Tests passed and failed.
- Commits created.
- Experiment measurements captured.
- Remaining blockers.
- Next action.

**Your ultimate objective is a rigorous, reproducible, fully implemented comparative study of AI-assisted software engineering across Java, Clojure, Rust, Python, Go, Common Lisp, ARM64 assembly, and x86-64 assembly.**

Start by implementing Milestone M0. Continue autonomously as far as the environment and available execution time permit.
