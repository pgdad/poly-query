# PolyQuery — Clojure engine. Requires the Clojure CLI (tools.deps) and a JDK.
CLOJURE ?= clojure
SRC := $(shell find src -name '*.clj')

.PHONY: build test lint fmt clean

build: target/classes/polyquery/main.class

target/classes/polyquery/main.class: $(SRC) deps.edn script/compile.clj
	@mkdir -p target/classes
	$(CLOJURE) -Spath > target/classpath
	$(CLOJURE) -M -i script/compile.clj
	@touch $@

test:
	$(CLOJURE) -M:test

# Reflection warnings are treated as lint failures.
lint:
	@mkdir -p target/lint-classes
	$(CLOJURE) -M -e "(binding [*compile-path* \"target/lint-classes\" *warn-on-reflection* true] (compile 'polyquery.main))" 2>&1 | tee target/lint.log
	@! grep -q "Reflection warning" target/lint.log

# No third-party formatter is allowed; normalise whitespace only.
fmt:
	@for f in $$(find src test script -name '*.clj'); do sed -i 's/[ \t]*$$//' "$$f"; done

clean:
	rm -rf target .cpcache
