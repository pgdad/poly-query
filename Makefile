# Thin wrapper around the justfile for environments without `just`.
.PHONY: help doctor spec-validate test-all report test-kernels
help:
	@echo "Targets: doctor spec-validate test-all report test-kernels (see justfile for more)"
doctor:
	python3 tools/environment/doctor.py
spec-validate:
	python3 tools/validation/spec_validate.py && python3 tools/validation/oracle_check.py
test-all:
	@for l in java clojure rust python go common-lisp; do \
	  if [ -f implementations/$$l/Makefile ]; then make -C implementations/$$l build && \
	  python3 tests/conformance/runner.py --engine implementations/$$l/bin/polyquery --report results/correctness/$$l.json || true; fi; done
report:
	python3 tools/reporting/report.py all
test-kernels:
	$(MAKE) -C native-kernels test
