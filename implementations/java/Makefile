# PolyQuery Java engine — plain javac/jar build (no third-party dependencies).
JAVA     ?= java
JAVAC    ?= javac
JAR      ?= jar
RELEASE  := 27
BUILD    := build
CLASSES  := $(BUILD)/classes
TCLASSES := $(BUILD)/test-classes
ENGINE_JAR := $(BUILD)/polyquery.jar
# AOT cache (classes + method profiles from a training run); used by bin/polyquery when present
AOT_CACHE := $(BUILD)/polyquery.aot
SRC      := $(shell find src/main/java -name '*.java')
TEST_SRC := $(shell find src/test/java -name '*.java')

.PHONY: build test lint fmt clean bench-kernels

# Native kernel library used by the unit tests and bench-kernels (tests are skipped without it).
NATIVE_LIB ?= ../../native-kernels/build/$(shell uname -m)/libpqkernels.so

build: $(ENGINE_JAR) $(AOT_CACHE)

$(ENGINE_JAR): $(SRC) src/main/resources/MANIFEST.MF
	rm -rf $(CLASSES)
	mkdir -p $(CLASSES)
	$(JAVAC) --release $(RELEASE) -encoding UTF-8 -Xlint:all,-serial -d $(CLASSES) $(SRC)
	$(JAR) --create --file $(ENGINE_JAR) --main-class polyquery.Main --manifest src/main/resources/MANIFEST.MF -C $(CLASSES) .

# Training run recording the AOT cache. The class path must be the absolute jar path the launcher
# uses. The cache only speeds up start-up and JIT warm-up; if it cannot be created, the engine
# runs without it.
$(AOT_CACHE): $(ENGINE_JAR)
	rm -f $(AOT_CACHE)
	$(JAVA) -XX:+UseParallelGC -XX:-UsePerfData -Xlog:disable -Xlog:all=off -XX:AOTCacheOutput=$(CURDIR)/$(AOT_CACHE) \
		-cp $(CURDIR)/$(ENGINE_JAR) polyquery.training.AotTraining || rm -f $(AOT_CACHE)

test: build
	rm -rf $(TCLASSES)
	mkdir -p $(TCLASSES)
	$(JAVAC) --release $(RELEASE) -encoding UTF-8 -cp $(CLASSES) -d $(TCLASSES) $(TEST_SRC)
	$(JAVA) -ea --enable-native-access=ALL-UNNAMED -Dpolyquery.nativeKernels=$(NATIVE_LIB) -cp $(CLASSES):$(TCLASSES) polyquery.TestMain

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
