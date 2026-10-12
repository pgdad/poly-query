# Change request CR-6: expression size limits (resolves SPEC-Q-002)

Status: adopted 2026-10-12 (capability `change.expression_limits`, ADR-0017).
Applies identically to every language. Spec version for engines claiming this
change: 1.3.0-cr6 (it composes with CR-1 and CR-2).

Spec 1.0.0 sets no limit on the size of a statement. Where the spec is silent,
behaviour is implementation-defined (`spec/README.md`), and the engines diverged
on very large but valid statements. Some compute them. Some answer `PARSE_ERROR`
or `RESOURCE_LIMIT`. Some never answer although a timeout was set, and some
crash on stack exhaustion. This change sets minimum sizes every engine must
support, one error code beyond them, and makes the timeout cover the whole life
of a query. **Every existing conformance case keeps its expected result.**

## 1. Measures

For one statement (one `query` request, including `EXPLAIN`):

* **Text length**: the SQL text in bytes (UTF-8).
* **Nesting depth**: the largest number of enclosing constructs around any
  expression. Each of these adds one level: a parenthesized expression `( e )`,
  a unary `+`/`-`, `NOT`, a function call, `CAST`, `CASE`, `IN (…)`, `BETWEEN`,
  `LIKE`, a comparison, and a subquery (scalar, `EXISTS`, `IN`, derived table, CTE).
  **A chain of binary operators of one precedence level** (`a OR b OR c`,
  `a AND b`, `a + b - c`, `a * b`, `a || b`) **adds one level, whatever its length.**
* **Operand count**: the number of literals, column references and `*` arguments
  in the statement.

## 2. Minimums

An engine MUST execute every statement within all of these limits exactly as it
would execute a small one, with the same result, errors and timeout behaviour:

| measure | minimum |
|---|---|
| text length | 1,048,576 bytes (1 MiB) |
| nesting depth | 1,000 |
| operand count | 25,000 |

So a 10,000-term `OR` chain of comparisons (20,000 operands), a 10,000-item
`IN` list, a 10,000-term sum and 1,000 nested parentheses must all work. An engine MAY support more, and its
README MUST state its limits (or that it has none besides memory and time).

The minimums cover the parser, binder, planner and every execution mode
(`row`, `vectorized`, parallel, `auto`). Parallel worker threads MUST be able to
evaluate any expression the engine accepts.

## 3. Beyond an engine's limits

A statement that exceeds a limit of the engine MUST fail with
`RESOURCE_LIMIT`. The message names the measure, e.g. `expression nesting depth
exceeds 4096`. The check MAY stop parsing early, so for a statement beyond a
limit `RESOURCE_LIMIT` MAY be reported in preference to `PARSE_ERROR`,
`SEMANTIC_ERROR` or a type error (an exception to the precedence in
`errors/errors.md`). Valid SQL within the engine's limits MUST NOT fail with
`PARSE_ERROR` because of its size.

A statement larger than `--max-request-bytes` still fails as the protocol
specifies (`RESOURCE_LIMIT`; HTTP 413).

Running out of stack, in any thread, MUST NOT terminate the process. It is
reported as `RESOURCE_LIMIT`, or the engine avoids it by its limits or by
non-recursive processing. `errors/errors.md` already requires that an engine
never crash, hang or exit on a request. This section names the error code.

## 4. The timeout covers every stage of a query

The effective timeout (`concurrency/concurrency.md` §3) counts from receipt of
the request through parsing, binding, planning and execution. When it expires,
the response MUST be `TIMEOUT` and MUST be sent within **1 second** in every
stage. Operators keep the stricter 100 ms rule, and `PQ_SLEEP` keeps 20 ms. A
stage whose work grows faster than linearly with the size of the statement
(for example quadratic planning of a long chain) checks the deadline inside
that work.

## 5. Tests

* `tests/regression/robustness_probe.py --only expression_limits` (black-box,
  session mode, on a 100-row table) checks two things.
  * **Minimums.** The statement must succeed with the correct result, in row,
    vectorized, parallel and auto mode:
    * nesting depth 999 (998 levels plus the comparison) reached with parentheses,
      with `ABS` calls, with unary minus signs, and with `NOT`s;
    * 10,000-term `OR` and `AND` chains;
    * a 10,000-term sum;
    * a 10,000-item `IN` list;
    * a `CASE` with 5,000 `WHEN` branches;
    * just under 1 MiB of SQL text (two 524,000-character string literals).
  * **Beyond the minimums.** The statements are:
    * 100,000 nested parentheses;
    * a 100,000-term `OR` chain;
    * a 100,000-item `IN` list.

    Each runs with `timeout_ms` 30,000. The answer must be the correct result,
    `RESOURCE_LIMIT` or `TIMEOUT`, and it must arrive no more than 1 s after the
    timeout expires. The probe tolerates 4 s extra for scheduling, and reports
    the measured delay.
* The probe runs on every engine. Engines that do not claim the capability
  get the same report, marked informational. They were built against spec
  1.0.0, where these limits were implementation-defined.
