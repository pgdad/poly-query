# Embedding API (application spec 1.0.0)

Status: adopted 2026-10-14 (ADR-0018). Every engine becomes usable as a **library**: a program
written in the engine's own language uses the engine in-process through a documented public
API. This document fixes what the API must offer; its shape (names, idioms, packaging) is
the implementation's choice and MUST be idiomatic for the language.

## 1. Required operations

The API MUST let a program, without starting a process or opening a network connection:

1. **create** an engine instance with a configuration: the data directory (as `--data-dir`,
   including path safety, `spec/protocol/protocol.md` §6) and the limits and defaults the CLI
   accepts (at least the per-query memory limit and the default thread count);
2. **load** CSV into a table, from a file path or from in-memory text, with optional explicit
   schema and CSV options (`header`, `delimiter`) and `replace`, as the `load` operation;
3. **query**: execute one SQL statement with options (at least `threads`, `timeout_ms`,
   `max_rows`) and return a **result object** giving the column names, the column types (the
   canonical type names of `spec/data-types/types.md`), the row count and the values;
4. **save** a table to a PQCF file and **open** a PQCF file as a table (with `replace`);
5. **drop** a table, **list** tables, read a table's **schema**;
6. **close** the instance and release its resources (an explicit call, or the language's
   standard resource-management idiom).

Values in a result are exposed as **typed native values**, not as JSON text: `INT64` as a
64-bit integer, `DECIMAL(p,s)` exactly (e.g. an arbitrary-precision decimal type, or the
unscaled integer and the scale), `FLOAT64` as a binary64, `STRING` as the language's string
type, `BOOLEAN` as a boolean, `DATE` and `TIMESTAMP` as a documented representation (a date
type, or days / microseconds since 1970-01-01), and NULL distinguishably from every value.
The mapping MUST be documented.

**Errors** are reported in the language's idiom (exception, condition, `Result`/error
value, or a status return) and MUST carry the specification's error code (e.g.
`PARSE_ERROR`, `NOT_FOUND`) and the message. An error MUST leave the instance usable.

Several instances MAY exist in one process. Whether one instance may be used from several
threads at once MUST be documented.

## 2. Packaging

`make build` produces the library in the language's usual form, so that a separate project
can use it without copying source files:

| language | expected form |
|---|---|
| Java | a jar (the API in an exported package) |
| Clojure | a library usable via `deps.edn` (`:local/root`) and/or a jar |
| Rust | a library crate usable as a Cargo path dependency |
| Go | a package in a module usable via `require` + `replace` |
| Python | an importable package (via `PYTHONPATH` or a path entry) |
| Common Lisp | an ASDF system |
| x86-64 / AArch64 assembly | a C-ABI library (`lib/libpolyquery.a` and/or `.so`) with a header `include/polyquery.h`, following the platform's standard calling convention, so it can be called from assembly and from C |

## 3. Unchanged engine

`bin/polyquery` keeps its behaviour, and the engine keeps passing its conformance suites. The
CLI and the API SHOULD share one implementation (the CLI becoming a client of the library).

## 4. `EMBEDDING.md`

The developer guide in the implementation directory MUST cover: how to build the library and
how a separate project depends on it (step by step, for the language's standard build tool);
the API reference (every public type and operation, its parameters, results and errors); the
value-type mapping; errors; resource management; thread safety; a complete, minimal program;
and pointers to `examples/embed-demo` and to `app/` as the larger example.

## 5. `examples/embed-demo`

A standalone program that uses **only the public API** (it would compile/run unchanged as a
separate project), built by `make build`, launcher `bin/pq-embed-demo`:

```
pq-embed-demo DATA_DIR CSV_FILE SQL
```

It creates an instance with data directory `DATA_DIR`, loads `CSV_FILE` (relative to
`DATA_DIR`, header row, inferred schema) as table `t`, runs `SQL` and prints the result to
stdout in the `csv` format of [pqledger.md](pqledger.md) §7. On an engine error it prints
`error: CODE: MESSAGE` to stderr and exits with status 1; otherwise status 0.
