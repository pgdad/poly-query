# PolyQuery application task — {{TASK_TITLE}}

You are an autonomous software engineer. Your accepted **PolyQuery** analytical database
engine, written in **{{LANGUAGE}}**, is in `implementations/{{LANG_DIR}}/` (it passes the full
conformance suite). You work alone, unattended, in this workspace. Nobody will answer
questions; make reasonable decisions yourself and document them.

## Your goal

{{TASK_GOAL}}{{CONTINUATION_NOTE}}

The task is complete only when every check in "Definition of done" passes. Keep working —
building, testing, debugging — until that is true or you are certain it cannot be achieved.
Do not stop at a partial implementation, and never weaken, skip or special-case tests.

## The specification is the only authority

* `spec/apps/pqledger.md` defines the application, `spec/apps/embedding.md` the library API
  and the example program. The engine's own behaviour stays as defined by the rest of `spec/`.
* `tests/apps/pqledger/` contains the public test cases (`cases/*.json`, `embed/*.json`) and
  their runner; `runner.py`'s docstring explains the case format. Expected outputs were derived
  independently from the spec; if a case seems to contradict the spec, re-read the spec.
* Additional **hidden** cases (same format and spirit, different data and options, including a
  ledger of about 100,000 transactions) will be run after you finish. Implement the spec, not
  the tests.
* `datasets/generators/bankgen.py` generates realistic bank-statement exports in three formats
  for your own testing (`--print-config` shows the matching account settings).

## Rules (experimental controls — mandatory)

1. Write all code under `implementations/{{LANG_DIR}}/`. Do not modify anything else in the
   workspace (spec, tests, generators, tools).
2. Language & toolchain: {{TOOLCHAIN}}
3. **Standard library only.** Use only the language's standard library, its standard build tool
   and its standard test facility. No third-party packages or downloaded code of any kind.
   {{STDLIB_NOTE}}
4. Implement everything yourself from the spec. Do not copy code from elsewhere.
5. `pqledger` uses the engine **in-process through the embedding API**: it must not start
   `bin/polyquery` or any other engine process and must not open network connections (the
   hidden run traces system calls to check this). Reports, lists, budgets and category
   resolution are computed by SQL executed by the embedded engine.
6. The engine keeps everything it does today: `bin/polyquery`, its capabilities and the
   conformance suites (`tests/conformance/runner.py`, also with `--modes` and `--transport http`,
   and `tests/concurrency/http_suite.py`) must still pass. Refactor the engine into a library as
   far as needed, without changing its behaviour.
7. Write idiomatic, well-structured, maintainable {{LANGUAGE}}. Keep the application's source
   in `app/`, separate from the engine. Add unit tests (`make test`).
8. Commit your work to git regularly with meaningful messages (small, working increments).
   Your commits are the deliverable; uncommitted work is lost.{{EXTRA_RULES}}

## How to test

```bash
make -C implementations/{{LANG_DIR}} build
python3 tests/apps/pqledger/runner.py --app implementations/{{LANG_DIR}}/bin/pqledger \
    --embed-demo implementations/{{LANG_DIR}}/bin/pq-embed-demo -v
# one case while iterating; --keep leaves the case's directory for inspection:
python3 tests/apps/pqledger/runner.py --app implementations/{{LANG_DIR}}/bin/pqledger --filter import-overlap -v
# the in-process check the hidden run applies (needs strace):
python3 tests/apps/pqledger/runner.py --app implementations/{{LANG_DIR}}/bin/pqledger --trace
python3 tests/conformance/runner.py --engine implementations/{{LANG_DIR}}/bin/polyquery
```

## Definition of done

{{DONE_CRITERIA}}

When done, make sure everything is committed, then finish with a short summary: the library
API you exposed, how pqledger is structured, test results (the runners' summary lines), known
limitations, and the main design decisions.
