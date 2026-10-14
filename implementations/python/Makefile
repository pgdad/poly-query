# PolyQuery (Python) — standard library only; no network access required.
# The engine package (polyquery/) is also the embedding library (EMBEDDING.md);
# app/ is the pqledger application (APP.md), examples/embed-demo the minimal
# embedding example.
PYTHON ?= python3

.PHONY: build test lint fmt clean

build:
	$(PYTHON) -m compileall -q polyquery entry.py app examples
	chmod +x bin/polyquery bin/pqledger bin/pq-embed-demo
	@bin/polyquery version >/dev/null && bin/pqledger version >/dev/null && echo "build ok"

test:
	$(PYTHON) -I -m unittest discover -s tests -t . -q
	cd app && $(PYTHON) -I -m unittest discover -s tests -t . -q

lint:
	$(PYTHON) -W error -m compileall -q -f polyquery tests entry.py app examples
	$(PYTHON) tools/lint.py polyquery tests entry.py app examples

fmt:
	$(PYTHON) tools/fmt.py polyquery tests entry.py app examples

clean:
	find . -name __pycache__ -type d -prune -exec rm -rf {} +
	find . -name '*.pyc' -delete
