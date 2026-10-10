# PolyQuery developer commands. Run `just --list`.
set shell := ["bash", "-euo", "pipefail", "-c"]

langs := "java clojure rust python go common-lisp"
py := "python3"

default:
    @just --list

# Install/verify toolchains (prints what is missing; see docs/development/setup.md)
setup:
    {{py}} tools/environment/setup.py

# Verify the environment and record tool/hardware versions
doctor:
    {{py}} tools/environment/doctor.py

# Validate the specification and the conformance suites (syntax, oracle cross-check, PQCF fixtures)
spec-validate:
    {{py}} tools/validation/spec_validate.py
    {{py}} tools/validation/oracle_check.py

# Harness self-tests (runner, pqt parser, comparison rules)
harness-selftest:
    {{py}} -m unittest discover -s tests/conformance/selftest -v

# SQLite oracle cross-check of all oracle-eligible expectations
oracle-check:
    {{py}} tools/validation/oracle_check.py

# Build one engine
build lang:
    make -C implementations/{{lang}} build

# Build all engines that exist
build-all:
    for l in {{langs}}; do if [ -f implementations/$l/Makefile ]; then make -C implementations/$l build; fi; done

# Conformance for one language (public suite, all phases the engine claims)
test-language lang *args:
    make -C implementations/{{lang}} build
    {{py}} tests/conformance/runner.py --engine implementations/{{lang}}/bin/polyquery --report results/correctness/{{lang}}.json {{args}}

# Conformance for all languages; writes results/correctness/*.json
test-all:
    for l in {{langs}}; do if [ -x implementations/$l/bin/polyquery ]; then just test-language $l || true; fi; done
    {{py}} tools/reporting/report.py capability-matrix

# Phase 4 HTTP suite for one language
test-http lang:
    {{py}} tests/concurrency/http_suite.py --engine implementations/{{lang}}/bin/polyquery --report results/correctness/{{lang}}-http.json

# Cross-engine PQCF interoperability matrix (+ reference validator)
test-interop:
    {{py}} tests/integration/storage_interop.py --report results/correctness/interop.json

# Crash-consistency suite for one language
test-crash lang:
    {{py}} tests/integration/storage_crash.py --engine implementations/{{lang}}/bin/polyquery

# Robustness fuzzing / randomized differential testing for one language
fuzz lang seconds="120":
    {{py}} tests/fuzz/sql_fuzz.py --engine implementations/{{lang}}/bin/polyquery --seconds {{seconds}}
    {{py}} tests/property-based/differential.py --engine implementations/{{lang}}/bin/polyquery --cases 300

# Native kernels: build + differential tests (x86-64 natively, AArch64 under qemu = functional only)
test-kernels:
    make -C native-kernels test

benchmark-kernels:
    make -C native-kernels bench

# Generate datasets for a scale factor (10k, 100k, 1m, 10m, 100m)
datasets scale="100k":
    {{py}} datasets/generators/pqgen.py generate --scale {{scale}}

datasets-verify scale="10k":
    {{py}} datasets/generators/pqgen.py verify --scale {{scale}}

# Benchmarks
benchmark-language lang scale="1m" *args:
    {{py}} benchmarks/harness/bench.py --engines {{lang}} --scale {{scale}} {{args}}

benchmark-all scale="1m" *args:
    {{py}} benchmarks/harness/bench.py --engines all --scale {{scale}} {{args}}

# Reports (JSON/CSV/HTML) from raw results and experiment telemetry
report:
    {{py}} tools/reporting/report.py all

# Experiment status: runs, outcomes, telemetry
experiment-status:
    {{py}} tools/orchestration/pq_orchestrate.py status
    {{py}} -c "import json;s=json.load(open('project-state.json'));print('milestone:',s['current_milestone']);print('next:',s['next_recommended_action'])"

# Launch a wave of sandboxed implementation agents (Track A)
wave task *args:
    {{py}} tools/orchestration/pq_orchestrate.py wave --task {{task}} {{args}}
