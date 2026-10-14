# PolyQuery x86-64 assembly engine
# Toolchain: GNU as 2.42 driven by gcc 13.3 (preprocessor + assembler + linker only).
#
# make build  -> out/polyquery (engine CLI), lib/libpolyquery.a (embedding
#                library), out/pqledger (application, app/), and
#                out/pq-embed-demo (examples/embed-demo, built by its own
#                Makefile exactly as a separate project would)

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
LIB       := lib/libpolyquery.a

# the application: a client of the library, built like an external program
APP_SRCS  := $(wildcard app/*.S)
APP_OBJS  := $(patsubst app/%.S,$(BUILD)/app/%.o,$(APP_SRCS))
APP_TEST_SRCS := $(wildcard app/tests/*.S)
APP_TEST_BINS := $(patsubst app/tests/%.S,$(BUILD)/app/tests/%,$(APP_TEST_SRCS))
PQLEDGER  := $(BUILD)/pqledger
DEMO      := $(BUILD)/pq-embed-demo
APP_ASFLAGS := -c -Iinclude -Iapp -Wa,--noexecstack -g
# the public functions of the library (include/polyquery.h)
API_SYMS  := pq_create pq_close pq_load_file pq_load_text pq_query \
             pq_result_free pq_create_table pq_value_text pq_save pq_open \
             pq_drop pq_tables pq_table_list_free pq_schema pq_schema_free \
             pq_errcode pq_errmsg pq_error_name pq_version

.PHONY: all build test lint fmt clean

all: build

build: $(ENGINE) $(LIB) $(PQLEDGER) $(DEMO)

$(ENGINE): $(OBJS)
	$(AS_DRIVER) $(LDFLAGS) -o $@ $(OBJS) $(LDLIBS)

$(BUILD)/%.o: src/%.S $(wildcard include/*.inc) | $(BUILD)
	$(AS_DRIVER) $(ASFLAGS) -o $@ $<

# The library is one pre-linked object in which only the public pq_*
# functions stay global: the engine's internal symbols (xmalloc, g_out, ...)
# can never clash with the client program's.
$(BUILD)/libpolyquery.o: $(LIBOBJS)
	ld -r -o $@.tmp $(LIBOBJS)
	objcopy $(addprefix --keep-global-symbol=,$(API_SYMS)) $@.tmp $@
	rm -f $@.tmp

$(LIB): $(BUILD)/libpolyquery.o
	@mkdir -p lib
	rm -f $@
	ar rcs $@ $(BUILD)/libpolyquery.o

$(BUILD)/app/%.o: app/%.S $(wildcard app/*.inc) include/polyquery.inc | $(BUILD)/app
	$(AS_DRIVER) $(APP_ASFLAGS) -o $@ $<

$(PQLEDGER): $(APP_OBJS) $(LIB)
	$(AS_DRIVER) $(LDFLAGS) -o $@ $(APP_OBJS) -Llib -lpolyquery $(LDLIBS)

$(BUILD)/app/tests/%: app/tests/%.S $(filter-out $(BUILD)/app/main.o,$(APP_OBJS)) $(LIB) | $(BUILD)/app/tests
	$(AS_DRIVER) $(APP_ASFLAGS) -o $@.o $<
	$(AS_DRIVER) $(LDFLAGS) -o $@ $@.o $(filter-out $(BUILD)/app/main.o,$(APP_OBJS)) -Llib -lpolyquery $(LDLIBS)

$(DEMO): examples/embed-demo/demo.S $(LIB) include/polyquery.inc
	$(MAKE) -s -C examples/embed-demo POLYQUERY=$(CURDIR) OUT=$(CURDIR)/$(DEMO)

$(BUILD)/tests/%: tests/%.S $(LIBOBJS) $(wildcard include/*.inc tests/*.inc) | $(BUILD)/tests
	$(AS_DRIVER) $(ASFLAGS) -o $@.o $<
	$(AS_DRIVER) $(LDFLAGS) -o $@ $@.o $(LIBOBJS) $(LDLIBS)

$(BUILD) $(BUILD)/tests $(BUILD)/app $(BUILD)/app/tests:
	mkdir -p $@

test: build $(TEST_BINS) $(APP_TEST_BINS)
	@set -e; for t in $(TEST_BINS) $(APP_TEST_BINS); do echo "== $$t"; $$t; done
	@sh tests/session_test.sh
	@sh tests/server_test.sh
	@sh tests/modes_test.sh
	@sh tests/pqledger_test.sh

# lint: assemble everything with warnings as errors and check every object
# carries a non-executable .note.GNU-stack section.
lint: build
	@set -e; for o in $(OBJS) $(APP_OBJS); do \
	  readelf -S $$o | grep -q 'note.GNU-stack' || { echo "$$o: missing .note.GNU-stack"; exit 1; }; \
	done; echo "lint ok"

# fmt: normalise whitespace (strip trailing blanks, tabs to spaces).
fmt:
	@for f in src/*.S include/*.inc tests/*.S tests/*.inc app/*.S app/*.inc examples/embed-demo/*.S; do \
	  [ -f "$$f" ] && sed -i -e 's/[ \t]*$$//' -e 's/\t/    /g' "$$f"; \
	done; echo "fmt ok"

clean:
	rm -rf $(BUILD) lib
