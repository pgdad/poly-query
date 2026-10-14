# PolyQuery Java engine — plain javac/jar build (no third-party dependencies).
JAVA     ?= java
JAVAC    ?= javac
JAR      ?= jar
RELEASE  := 27
BUILD    := build
CLASSES  := $(BUILD)/classes
TCLASSES := $(BUILD)/test-classes
ENGINE_JAR := $(BUILD)/polyquery.jar
AOT_CACHE := $(BUILD)/polyquery.aot
SRC      := $(shell find src/main/java -name '*.java')
TEST_SRC := $(shell find src/test/java -name '*.java')
# pqledger (app/) and the embedding example are compiled against the engine jar as a module,
# so they can only use its exported package polyquery.api.
APP_SRC      := $(shell find app/src/main/java -name '*.java')
APP_TEST_SRC := $(shell find app/src/test/java -name '*.java')
APP_CLASSES  := $(BUILD)/app-classes
APP_TCLASSES := $(BUILD)/app-test-classes
APP_JAR      := $(BUILD)/pqledger.jar
DEMO_SRC     := $(shell find examples/embed-demo/src/main/java -name '*.java')
DEMO_CLASSES := $(BUILD)/demo-classes
DEMO_JAR     := $(BUILD)/pq-embed-demo.jar

.PHONY: build test lint fmt clean bench-kernels

# Native kernel library used by the unit tests and bench-kernels (tests are skipped without it).
NATIVE_LIB ?= ../../native-kernels/build/$(shell uname -m)/libpqkernels.so

build: $(ENGINE_JAR) $(AOT_CACHE) $(APP_JAR) $(DEMO_JAR)

$(ENGINE_JAR): $(SRC) src/main/resources/MANIFEST.MF
	rm -rf $(CLASSES)
	mkdir -p $(CLASSES)
	$(JAVAC) --release $(RELEASE) -encoding UTF-8 -Xlint:all,-serial -d $(CLASSES) $(SRC)
	$(JAR) --create --file $(ENGINE_JAR) --main-class polyquery.Main --manifest src/main/resources/MANIFEST.MF -C $(CLASSES) .

$(APP_JAR): $(ENGINE_JAR) $(APP_SRC)
	rm -rf $(APP_CLASSES)
	mkdir -p $(APP_CLASSES)
	$(JAVAC) --release $(RELEASE) -encoding UTF-8 -Xlint:all,-serial --module-path $(ENGINE_JAR) -d $(APP_CLASSES) $(APP_SRC)
	$(JAR) --create --file $(APP_JAR) --main-class pqledger.Main -C $(APP_CLASSES) .

$(DEMO_JAR): $(ENGINE_JAR) $(DEMO_SRC)
	rm -rf $(DEMO_CLASSES)
	mkdir -p $(DEMO_CLASSES)
	$(JAVAC) --release $(RELEASE) -encoding UTF-8 -Xlint:all,-serial --module-path $(ENGINE_JAR) --add-modules polyquery -d $(DEMO_CLASSES) $(DEMO_SRC)
	$(JAR) --create --file $(DEMO_JAR) --main-class demo.EmbedDemo -C $(DEMO_CLASSES) .

# JIT training run creating the JVM's AOT cache (README "JIT warm-up"). Optional: if it fails,
# the engine runs without the cache.
$(AOT_CACHE): $(ENGINE_JAR) bin/aot-train bin/jvm-options
	@if sh bin/aot-train > $(BUILD)/aot-training.log 2>&1; then echo "AOT cache: $@"; \
	else echo "note: AOT training failed, the engine runs without the cache (see $(BUILD)/aot-training.log)"; fi

test: build
	rm -rf $(TCLASSES)
	mkdir -p $(TCLASSES)
	$(JAVAC) --release $(RELEASE) -encoding UTF-8 -cp $(CLASSES) -d $(TCLASSES) $(TEST_SRC)
	$(JAVA) -ea --enable-native-access=ALL-UNNAMED -Dpolyquery.nativeKernels=$(NATIVE_LIB) -cp $(CLASSES):$(TCLASSES) polyquery.TestMain
	rm -rf $(APP_TCLASSES)
	mkdir -p $(APP_TCLASSES)
	$(JAVAC) --release $(RELEASE) -encoding UTF-8 --module-path $(ENGINE_JAR) --add-modules polyquery -cp $(APP_CLASSES) -d $(APP_TCLASSES) $(APP_TEST_SRC)
	$(JAVA) -ea --module-path $(ENGINE_JAR) --add-modules polyquery -cp $(APP_CLASSES):$(APP_TCLASSES) pqledger.AppTestMain

# FFM kernel calls vs the engine's Java loops (needs the library: make -C ../../native-kernels).
bench-kernels: test
	$(JAVA) --enable-native-access=ALL-UNNAMED -cp $(CLASSES):$(TCLASSES) polyquery.KernelBench $(NATIVE_LIB)

lint:
	rm -rf $(BUILD)/lint
	mkdir -p $(BUILD)/lint
	$(JAVAC) --release $(RELEASE) -encoding UTF-8 -Xlint:all,-serial -Werror -d $(BUILD)/lint $(SRC)

# The JDK ships no source formatter; formatting follows the conventions in README.md.
fmt:
	@echo "fmt: no formatter in the JDK toolchain; nothing to do"

clean:
	rm -rf $(BUILD)
