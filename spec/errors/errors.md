# Error Model

All failures are reported with the error object

```json
{"code": "SEMANTIC_ERROR", "message": "unknown column 'nmae'", "details": {"line": 1, "column": 8}}
```

* `code` — one of the stable codes in [error-codes.json](error-codes.json). Codes are
  the **only** part of an error that conformance tests check.
* `message` — human-readable English; free-form; MUST NOT contain stack traces
  (put debugging detail in logs).
* `details` — optional object. Recommended keys: `line`, `column` (1-based, SQL
  position), `record` (1-based input record), `column_name`, `table`.

Precedence when several errors are possible in one statement: the engine MAY
report any of them, **except** that errors detectable before execution (parse,
semantic, type) MUST be reported in preference to runtime errors, and a request
that fails MUST NOT have partially modified the catalog (operations are atomic).

An engine MUST NOT crash, hang, or exit on any request; internal failures are
`INTERNAL_ERROR` responses. Out-of-memory conditions SHOULD be reported as
`RESOURCE_LIMIT` via the query memory budget before the process runs out of memory.

The HTTP status mapping is defined in protocol.md §7.1 and repeated in error-codes.json.
