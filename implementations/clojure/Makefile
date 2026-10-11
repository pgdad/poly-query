# PolyQuery — Clojure engine. Requires the Clojure CLI (tools.deps) and a JDK.
CLOJURE ?= clojure
JDK_BIN := $(if $(JAVA_HOME),$(JAVA_HOME)/bin/,)
SRC := $(shell find src -name '*.clj')

.PHONY: build test lint fmt clean

build: target/polyquery.jar target/polyquery.aot

target/classes/polyquery/main.class: $(SRC) deps.edn script/compile.clj
	@rm -rf target/classes
	@mkdir -p target/classes
	@# runtime classpath: dependencies only (the relative "src" entry would let a
	@# launcher started in this directory load sources instead of the AOT classes)
	$(CLOJURE) -Spath | tr ':' '\n' | grep -v '^src$$' | paste -sd: - > target/classpath
	$(CLOJURE) -M -i script/compile.clj
	@touch $@

# The engine runs from a jar: the JDK's AOT cache only covers classes loaded
# from jar files.
target/polyquery.jar: target/classes/polyquery/main.class
	@rm -f $@
	$(JDK_BIN)jar --create --file $@ -C target/classes .

# JDK AOT cache (JEP 483/514/515: pre-parsed, pre-linked classes, the
# initialized Clojure runtime and method profiles), recorded by replaying a
# synthetic training session (script/training.clj: generated tables, generic
# queries) through the launcher with the launcher's own JVM flags. Optional:
# if training fails the build still succeeds and the engine runs without it.
target/polyquery.aot: target/polyquery.jar script/training.clj bin/polyquery
	@rm -f $@
	@rm -rf target/training
	@if $(CLOJURE) -M script/training.clj target/training && \
	    POLYQUERY_AOT_OUTPUT="$(CURDIR)/$@" bin/polyquery session --data-dir target/training \
	      < target/training/requests.jsonl > target/training/responses.jsonl 2> target/training/training.log && \
	    test -s $@; then \
	  echo "AOT cache: $@ ($$(grep -c '"ok":true' target/training/responses.jsonl) training requests ok)"; \
	else \
	  echo "warning: AOT cache training failed (see the output above and target/training/training.log); building without it" >&2; \
	  rm -f $@; \
	fi
	@rm -f target/training/*.csv target/training/*.pqcf target/training/responses.jsonl

test:
	$(CLOJURE) -M:test

# Fails on any reflection or boxed-math warning (script/lint.clj).
lint:
	@rm -rf target/lint-classes
	@mkdir -p target/lint-classes
	$(CLOJURE) -M script/lint.clj

# No third-party formatter is allowed; normalise whitespace only.
fmt:
	@for f in $$(find src test script -name '*.clj'); do sed -i 's/[ \t]*$$//' "$$f"; done

clean:
	rm -rf target .cpcache
