# pq-embed-demo — builds like a separate project that depends on PolyQuery.
#
#   make -C examples/embed-demo POLYQUERY=/path/to/arm64-asm-engine
#
# POLYQUERY is the engine directory (it provides include/polyquery.inc and,
# after `make build` there, lib/libpolyquery.a).

POLYQUERY ?= ../..
CC        ?= gcc

PQ_CFLAGS := -I$(POLYQUERY)/include
PQ_LIBS   := -L$(POLYQUERY)/lib -lpolyquery -lm -lpthread

.PHONY: all clean
all: build/pq-embed-demo

build/pq-embed-demo: demo.S $(POLYQUERY)/include/polyquery.inc $(POLYQUERY)/lib/libpolyquery.a
	@mkdir -p build
	$(CC) $(PQ_CFLAGS) -g -Wa,--fatal-warnings -o $@ demo.S $(PQ_LIBS)

clean:
	rm -rf build
