# PolyQuery — Clojure engine. Requires the Clojure CLI (tools.deps) and a JDK.
CLOJURE ?= clojure
JAR ?= $(if $(JAVA_HOME),$(JAVA_HOME)/bin/jar,jar)
SRC := $(shell find src -name '*.clj')

.PHONY: build test lint fmt clean

build: target/polyquery.jar target/polyquery.aot

target/classes/polyquery/main.class: $(SRC) deps.edn script/compile.clj
	@mkdir -p target/classes
	@# runtime classpath: dependencies only (the relative "src" entry would let a
	@# launcher started in this directory load sources instead of the AOT classes)
	$(CLOJURE) -Spath | tr ':' '\n' | grep -v '^src$$' | paste -sd: - > target/classpath
	$(CLOJURE) -M -i script/compile.clj
	@touch $@

# The launcher runs the classes from a jar (the JVM's AOT cache requires
# class path entries to be jars).
target/polyquery.jar: target/classes/polyquery/main.class
	$(JAR) cf $@ -C target/classes .

# JVM ahead-of-time cache (classes pre-loaded and linked, JIT profiles) from
# a training session over synthetic data (script/training.clj); it shortens
# the first executions of queries. Optional: the engine runs without it.
target/polyquery.aot: target/polyquery.jar script/training.clj
	@rm -rf target/training $@
	$(CLOJURE) -M script/training.clj target/training
	POLYQUERY_JAVA_OPTS="-XX:AOTCacheOutput=$(CURDIR)/$@" bin/polyquery session --data-dir target/training \
	  < target/training/requests.jsonl > target/training/responses.jsonl 2> target/training/stderr.log \
	  || { echo "AOT cache training failed; continuing without it" >&2; rm -f $@; }
	@rm -f target/training/*.csv
	@touch -c $@

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
