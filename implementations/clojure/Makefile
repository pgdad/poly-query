# PolyQuery — Clojure engine, its embedding API (library), the pqledger
# application (app/) and the embedding example (examples/embed-demo/).
# Requires the Clojure CLI (tools.deps) and a JDK.
CLOJURE ?= clojure
JAR ?= $(if $(JAVA_HOME),$(JAVA_HOME)/bin/jar,jar)
SRC := $(shell find src -name '*.clj')
APP_SRC := $(shell find app/src -name '*.clj')
DEMO_SRC := $(shell find examples/embed-demo/src -name '*.clj')

# Compiling a library client: its deps.edn depends on the engine through
# :local/root; the built engine jar is added so that the engine's AOT
# classes are used instead of being compiled again.
CLIENT_SDEPS := '{:aliases {:engine-jar {:extra-deps {polyquery/aot {:local/root "$(CURDIR)/target/polyquery.jar"}}}}}'

.PHONY: build test test-engine test-app lint fmt clean

build: target/polyquery.jar target/polyquery.aot target/pqledger.jar target/pqledger.aot target/pq-embed-demo.jar

target/classes/polyquery/main.class: $(SRC) deps.edn script/compile.clj
	@mkdir -p target/classes
	@# runtime classpath: dependencies only (the relative "src" entry would let a
	@# launcher started in this directory load sources instead of the AOT classes)
	$(CLOJURE) -Spath | tr ':' '\n' | grep -v '^src$$' | paste -sd: - > target/classpath
	$(CLOJURE) -M -i script/compile.clj
	@touch $@

# The launcher runs the classes from a jar (the JVM's AOT cache requires
# class path entries to be jars). The jar is also the library in binary
# form (polyquery.api and everything it needs).
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

# pqledger: AOT-compiled from app/ (a client of the library); only its own
# classes go into its jar.
target/pqledger.jar: target/polyquery.jar $(APP_SRC) app/deps.edn script/compile-client.clj
	@rm -rf target/app-classes && mkdir -p target/app-classes
	cd app && $(CLOJURE) -Sdeps $(CLIENT_SDEPS) -M:engine-jar ../script/compile-client.clj pqledger.main ../target/app-classes
	$(JAR) cf $@ -C target/app-classes pqledger

# AOT cache of pqledger, recorded while it imports a statement into a
# training ledger (script/pqledger-training.sh). Optional, like the engine's.
target/pqledger.aot: target/pqledger.jar script/pqledger-training.sh
	@rm -f $@
	script/pqledger-training.sh target/training-app $(CURDIR)/$@ \
	  || { echo "pqledger AOT cache training failed; continuing without it" >&2; rm -f $@; }
	@touch -c $@

target/pq-embed-demo.jar: target/polyquery.jar $(DEMO_SRC) examples/embed-demo/deps.edn script/compile-client.clj
	@rm -rf target/demo-classes && mkdir -p target/demo-classes
	cd examples/embed-demo && $(CLOJURE) -Sdeps $(CLIENT_SDEPS) -M:engine-jar ../../script/compile-client.clj embed-demo.main ../../target/demo-classes
	$(JAR) cf $@ -C target/demo-classes embed_demo

test: test-engine test-app

test-engine:
	$(CLOJURE) -M:test

test-app:
	cd app && $(CLOJURE) -M:test

# Reflection warnings are treated as lint failures.
lint:
	@mkdir -p target/lint-classes
	$(CLOJURE) -M -e "(binding [*compile-path* \"target/lint-classes\" *warn-on-reflection* true] (compile 'polyquery.main) (compile 'polyquery.api))" 2>&1 | tee target/lint.log
	@! grep -q "Reflection warning" target/lint.log

# No third-party formatter is allowed; normalise whitespace only.
fmt:
	@for f in $$(find src test script app examples -name '*.clj'); do sed -i 's/[ \t]*$$//' "$$f"; done

clean:
	rm -rf target .cpcache app/.cpcache examples/embed-demo/.cpcache
