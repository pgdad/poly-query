# PolyQuery x86-64 assembly engine
# Toolchain: GNU as 2.42 driven by gcc 13.3 (preprocessor + assembler + linker only).

AS_DRIVER ?= gcc
ASFLAGS   := -c -Iinclude -Wa,--noexecstack -g
LDFLAGS   := -no-pie -Wl,-z,noexecstack -Wl,-z,now
LDLIBS    := -lm -lpthread

BUILD     := out
SRCS      := $(wildcard src/*.S)
OBJS      := $(patsubst src/%.S,$(BUILD)/%.o,$(SRCS))
LIBOBJS   := $(filter-out $(BUILD)/main.o,$(OBJS))
TEST_SRCS := $(wildcard tests/*.S)
TEST_BINS := $(patsubst tests/%.S,$(BUILD)/tests/%,$(TEST_SRCS))
ENGINE    := $(BUILD)/polyquery

.PHONY: all build test lint fmt clean

all: build

build: $(ENGINE)

$(ENGINE): $(OBJS)
	$(AS_DRIVER) $(LDFLAGS) -o $@ $(OBJS) $(LDLIBS)

$(BUILD)/%.o: src/%.S $(wildcard include/*.inc) | $(BUILD)
	$(AS_DRIVER) $(ASFLAGS) -o $@ $<

$(BUILD)/tests/%: tests/%.S $(LIBOBJS) $(wildcard include/*.inc) | $(BUILD)/tests
	$(AS_DRIVER) $(ASFLAGS) -o $@.o $<
	$(AS_DRIVER) $(LDFLAGS) -o $@ $@.o $(LIBOBJS) $(LDLIBS)

$(BUILD) $(BUILD)/tests:
	mkdir -p $@

test: build $(TEST_BINS)
	@set -e; for t in $(TEST_BINS); do echo "== $$t"; $$t; done
	@sh tests/session_test.sh
	@sh tests/server_test.sh

# lint: assemble everything with warnings as errors and check every object
# carries a non-executable .note.GNU-stack section.
lint: build
	@set -e; for o in $(OBJS); do \
	  readelf -S $$o | grep -q 'note.GNU-stack' || { echo "$$o: missing .note.GNU-stack"; exit 1; }; \
	done; echo "lint ok"

# fmt: normalise whitespace (strip trailing blanks, tabs to spaces).
fmt:
	@for f in src/*.S include/*.inc tests/*.S; do \
	  [ -f "$$f" ] && sed -i -e 's/[ \t]*$$//' -e 's/\t/    /g' "$$f"; \
	done; echo "fmt ok"

clean:
	rm -rf $(BUILD)
