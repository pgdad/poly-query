# Phase 2 — SQL Parser and Query Engine

**Required capabilities:** all of Phase 1 plus `phase2`, `sql.groupby`, `sql.join`,
`sql.functions`, `sql.subquery`, `sql.cte`. Optional: `sql.correlated_subquery`.

Engines MUST have distinct, inspectable stages: lexer, parser producing an AST,
semantic validation (binding & typing), logical plan, physical plan, execution.
(Verified by code review rubric, not by black-box tests, except `EXPLAIN`.)

Full grammar of sql/grammar.md, semantics of sql/semantics.md, all functions of
sql/functions.md, `EXPLAIN` (statement and `explain` op), `CREATE/DROP INDEX`
parsing (an engine without Phase 3 indexes answers `UNSUPPORTED` for them).

Structured errors: `PARSE_ERROR` SHOULD include `details.line`/`details.column`.

Conformance suites: `tests/conformance/cases/phase2/*`.
