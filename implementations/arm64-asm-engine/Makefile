# PolyQuery — AArch64 assembly engine
# gcc is used only as preprocessor/assembler driver and linker.

CC      ?= gcc
ASFLAGS := -Iinclude -g -Wa,--fatal-warnings
LDFLAGS := -g
LIBS    := -lm -lpthread

SRCS    := $(wildcard src/*.S)
OBJS    := $(patsubst src/%.S,build/%.o,$(SRCS))
LIBOBJS := $(filter-out build/main.o,$(OBJS))

# Embedding library (EMBEDDING.md): every engine module but main.o, linked
# into one relocatable object in which only the pq_* API stays global.
API_SYMS := pq_create pq_close pq_errcode pq_errname pq_errmsg pq_code_name \
            pq_load_file pq_load_text pq_save pq_open pq_drop pq_tables \
            pq_schema pq_query pq_query_into pq_result_free pq_value_at \
            pq_format_value pq_version
LIBA    := lib/libpolyquery.a

# pqledger (app/): uses the engine only through the library
APPSRCS := $(filter-out app/tests/%,$(wildcard app/*.S))
APPOBJS := $(patsubst app/%.S,build/app/%.o,$(APPSRCS))
APPFLAGS := -Iapp -Iinclude -g -Wa,--fatal-warnings
APPTESTSRC := $(wildcard app/tests/test_*.S)
APPTESTBIN := $(patsubst app/tests/%.S,build/apptests/%,$(APPTESTSRC))
TESTSRC := $(wildcard tests/unit/test_*.S)
TESTBIN := $(patsubst tests/unit/%.S,build/tests/%,$(TESTSRC))

.PHONY: all build lib demo test lint fmt clean

all: build

build: build/polyquery $(LIBA) build/pqledger demo

lib: $(LIBA)

$(LIBA): $(LIBOBJS)
	@mkdir -p lib
	ld -r -o build/libpolyquery-all.o $(LIBOBJS)
	objcopy $(addprefix -G ,$(API_SYMS)) build/libpolyquery-all.o build/libpolyquery.o
	rm -f $@
	ar rcs $@ build/libpolyquery.o

build/app/%.o: app/%.S app/ledger.inc include/polyquery.inc | build/.dir
	@mkdir -p build/app
	$(CC) $(APPFLAGS) -c -o $@ $<

build/pqledger: $(APPOBJS) $(LIBA)
	$(CC) $(LDFLAGS) -o $@ $(APPOBJS) -Llib -lpolyquery $(LIBS)

demo: $(LIBA)
	$(MAKE) -C examples/embed-demo POLYQUERY=$(CURDIR)

build/apptests/%: app/tests/%.S $(filter-out build/app/main.o,$(APPOBJS)) $(LIBA)
	@mkdir -p build/apptests
	$(CC) $(APPFLAGS) -o $@ $< $(filter-out build/app/main.o,$(APPOBJS)) -Llib -lpolyquery $(LIBS)

build/polyquery: $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $(OBJS) $(LIBS)

build/%.o: src/%.S $(wildcard include/*.inc) | build/.dir
	$(CC) $(ASFLAGS) -c -o $@ $<

build/tests/%: tests/unit/%.S $(LIBOBJS) include/pq.inc | build/.dir
	@mkdir -p build/tests
	$(CC) $(ASFLAGS) $(LDFLAGS) -o $@ $< $(LIBOBJS) $(LIBS)

build/.dir:
	@mkdir -p build/tests && touch $@

test: build $(TESTBIN) $(APPTESTBIN)
	@set -e; for t in $(TESTBIN) $(APPTESTBIN); do echo "== $$t"; $$t; done
	@set -e; for s in tests/sh/*.sh; do sh $$s; done

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
	rm -rf build lib/libpolyquery.a examples/embed-demo/build
