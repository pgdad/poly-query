# PolyQuery (Python) — standard library only; no network access required.
PYTHON ?= python3

.PHONY: build test lint fmt clean

build:
	$(PYTHON) -m compileall -q polyquery entry.py
	chmod +x bin/polyquery
	@bin/polyquery version >/dev/null && echo "build ok"

test:
	$(PYTHON) -I -m unittest discover -s tests -t . -q

lint:
	$(PYTHON) -W error -m compileall -q -f polyquery tests entry.py
	$(PYTHON) tools/lint.py polyquery tests entry.py

fmt:
	$(PYTHON) tools/fmt.py polyquery tests entry.py

clean:
	find . -name __pycache__ -type d -prune -exec rm -rf {} +
	find . -name '*.pyc' -delete
