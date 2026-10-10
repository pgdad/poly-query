# PolyQuery Java engine — plain javac/jar build (no third-party dependencies).
JAVA     ?= java
JAVAC    ?= javac
JAR      ?= jar
RELEASE  := 27
BUILD    := build
CLASSES  := $(BUILD)/classes
TCLASSES := $(BUILD)/test-classes
ENGINE_JAR := $(BUILD)/polyquery.jar
SRC      := $(shell find src/main/java -name '*.java')
TEST_SRC := $(shell find src/test/java -name '*.java')

.PHONY: build test lint fmt clean

build: $(ENGINE_JAR)

$(ENGINE_JAR): $(SRC)
	rm -rf $(CLASSES)
	mkdir -p $(CLASSES)
	$(JAVAC) --release $(RELEASE) -encoding UTF-8 -Xlint:all,-serial -d $(CLASSES) $(SRC)
	$(JAR) --create --file $(ENGINE_JAR) --main-class polyquery.Main -C $(CLASSES) .

test: build
	rm -rf $(TCLASSES)
	mkdir -p $(TCLASSES)
	$(JAVAC) --release $(RELEASE) -encoding UTF-8 -cp $(CLASSES) -d $(TCLASSES) $(TEST_SRC)
	$(JAVA) -ea -cp $(CLASSES):$(TCLASSES) polyquery.TestMain

lint:
	rm -rf $(BUILD)/lint
	mkdir -p $(BUILD)/lint
	$(JAVAC) --release $(RELEASE) -encoding UTF-8 -Xlint:all,-serial -Werror -d $(BUILD)/lint $(SRC)

# The JDK ships no source formatter; formatting follows the conventions in README.md.
fmt:
	@echo "fmt: no formatter in the JDK toolchain; nothing to do"

clean:
	rm -rf $(BUILD)
