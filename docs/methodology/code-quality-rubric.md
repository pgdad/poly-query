# Code Quality and Maintainability Rubric

Automated (objective, reported as measured):

| Metric | Definition |
|---|---|
| Source LOC | non-blank, non-comment lines in the language's source files (excl. tests, build output) |
| Test LOC | same for unit-test sources |
| Files / modules | count of source files |
| Comment density | comment lines / source LOC |
| Largest file / longest function (proxy) | lines |
| Build time | clean `make build` wall time |
| Lint findings | count from the language's standard linter where one exists in the stdlib toolchain (`go vet`, `cargo clippy`, `javac -Xlint`, SBCL compiler warnings) |

Rubric (subjective, 1–5, only if reviewers are available; never presented as fact):

1. **Architecture** — clear separation of lexer/parser/semantic analysis/planning/execution/storage/protocol.
2. **Readability** — idiomatic use of the language, naming, function size.
3. **Robustness** — error handling, resource limits, absence of panics/crashes in fuzzing.
4. **Testability** — unit tests of core components, ease of adding tests.
5. **Extensibility** — evidenced by the cost of the Phase 2–5 and architectural-change tasks (measured).

Reviewer identities (roles), scores and agreement statistics are stored in
`results/development/code-review/` when collected.
