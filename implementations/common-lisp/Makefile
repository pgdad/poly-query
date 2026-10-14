# PolyQuery — Common Lisp implementation (SBCL + ASDF, standard library only).

SBCL       ?= sbcl
# The control stack size applies to every thread (saved in the executable):
# expression trees are processed recursively, and a statement at the
# operand limit (src/sql/limits.lisp) needs about 256 MB in the worst case.
# The heap (dynamic space, 64 GiB) is address space reserved up front and
# only backed by memory as it is used; the engine's heap guard
# (src/util/memory.lisp) keeps its use below a soft limit inside it.
SBCL_FLAGS  = --dynamic-space-size 65536 --control-stack-size 1024 \
              --non-interactive --no-sysinit --no-userinit
ENGINE_SOURCES := polyquery.asd build.lisp $(shell find src -name '*.lisp')
APP_SOURCES    := $(shell find app -name '*.asd' -o -name '*.lisp' -path 'app/src/*')
DEMO_SOURCES   := $(wildcard examples/embed-demo/*.asd examples/embed-demo/*.lisp)

.PHONY: all build test lint fmt clean

all: build

# The engine (bin/polyquery), the application (bin/pqledger) and the
# embedding example (bin/pq-embed-demo); each is a saved SBCL executable
# containing the "polyquery" ASDF system (the engine and its embedding API).
build: build/polyquery build/pqledger build/pq-embed-demo

build/polyquery: $(ENGINE_SOURCES)
	@mkdir -p build
	$(SBCL) $(SBCL_FLAGS) --load build.lisp

build/pqledger: $(ENGINE_SOURCES) $(APP_SOURCES)
	@mkdir -p build
	BUILD_SYSTEM=pqledger BUILD_TOPLEVEL=pqledger:main BUILD_OUTPUT=build/pqledger \
	  $(SBCL) $(SBCL_FLAGS) --load build.lisp

build/pq-embed-demo: $(ENGINE_SOURCES) $(DEMO_SOURCES)
	@mkdir -p build
	BUILD_SYSTEM=pq-embed-demo BUILD_TOPLEVEL=pq-embed-demo:main BUILD_OUTPUT=build/pq-embed-demo \
	  $(SBCL) $(SBCL_FLAGS) --load build.lisp

# Unit tests of the engine and of the application.
test:
	$(SBCL) $(SBCL_FLAGS) --load tests/run.lisp
	$(SBCL) $(SBCL_FLAGS) --load app/tests/run.lisp

# Lint: compile everything from scratch and fail on any full WARNING.
lint:
	rm -rf build/fasl
	POLYQUERY_STRICT=1 $(SBCL) $(SBCL_FLAGS) --load build.lisp
	POLYQUERY_STRICT=1 BUILD_SYSTEM=pqledger BUILD_TOPLEVEL=pqledger:main BUILD_OUTPUT=build/pqledger \
	  $(SBCL) $(SBCL_FLAGS) --load build.lisp
	POLYQUERY_STRICT=1 BUILD_SYSTEM=pq-embed-demo BUILD_TOPLEVEL=pq-embed-demo:main \
	  BUILD_OUTPUT=build/pq-embed-demo $(SBCL) $(SBCL_FLAGS) --load build.lisp

# There is no standard Common Lisp formatter; normalise whitespace only.
fmt:
	find src tests app examples -name '*.lisp' -exec sed -i -e 's/[ \t]*$$//' {} +

clean:
	rm -rf build
