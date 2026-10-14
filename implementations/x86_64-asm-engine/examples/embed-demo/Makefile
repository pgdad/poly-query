# pq-embed-demo: builds like a separate project that depends on the
# PolyQuery library.  POLYQUERY is the engine's directory (it provides
# include/polyquery.inc and lib/libpolyquery.a, built by its `make build`).
#
#   make POLYQUERY=/path/to/implementations/x86_64-asm-engine
POLYQUERY ?= ../..
OUT       ?= pq-embed-demo

$(OUT): demo.S $(POLYQUERY)/include/polyquery.inc $(POLYQUERY)/lib/libpolyquery.a
	gcc -c -I$(POLYQUERY)/include -Wa,--noexecstack -g -o $(OUT).o demo.S
	gcc -no-pie -Wl,-z,noexecstack -o $(OUT) $(OUT).o -L$(POLYQUERY)/lib -lpolyquery -lm -lpthread
	rm -f $(OUT).o

clean:
	rm -f $(OUT) $(OUT).o

.PHONY: clean
