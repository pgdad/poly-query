# PolyQuery — AArch64 assembly engine
# gcc is used only as preprocessor/assembler driver and linker.

CC      ?= gcc
ASFLAGS := -Iinclude -g -Wa,--fatal-warnings
LDFLAGS := -g
LIBS    := -lm -lpthread

SRCS    := $(wildcard src/*.S)
OBJS    := $(patsubst src/%.S,build/%.o,$(SRCS))
LIBOBJS := $(filter-out build/main.o,$(OBJS))
TESTSRC := $(wildcard tests/unit/test_*.S)
TESTBIN := $(patsubst tests/unit/%.S,build/tests/%,$(TESTSRC))

.PHONY: all build test lint fmt clean

all: build

build: build/polyquery

build/polyquery: $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $(OBJS) $(LIBS)

build/%.o: src/%.S include/pq.inc | build
	$(CC) $(ASFLAGS) -c -o $@ $<

build/tests/%: tests/unit/%.S $(LIBOBJS) include/pq.inc | build
	@mkdir -p build/tests
	$(CC) $(ASFLAGS) $(LDFLAGS) -o $@ $< $(LIBOBJS) $(LIBS)

build:
	@mkdir -p build

test: build $(TESTBIN)
	@set -e; for t in $(TESTBIN); do echo "== $$t"; $$t; done
	@sh tests/sh/run_cli_tests.sh

# lint: assemble everything with warnings as errors and check every object
# carries a non-executable .note.GNU-stack section.
lint: build
	@set -e; for o in $(OBJS); do \
	  readelf -S $$o | grep -q 'note.GNU-stack' || { echo "missing .note.GNU-stack: $$o"; exit 1; }; \
	done; echo "lint ok"

# fmt: normalise whitespace (strip trailing blanks, tabs to spaces).
fmt:
	@for f in $(SRCS) $(TESTSRC) include/*.inc; do \
	  sed -i -e 's/[ \t]*$$//' -e 's/\t/    /g' $$f; done

clean:
	rm -rf build
