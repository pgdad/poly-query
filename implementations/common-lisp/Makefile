# PolyQuery — Common Lisp implementation (SBCL + ASDF, standard library only).

SBCL       ?= sbcl
SBCL_FLAGS  = --dynamic-space-size 8192 --control-stack-size 64 \
              --non-interactive --no-sysinit --no-userinit
SOURCES    := polyquery.asd build.lisp $(shell find src -name '*.lisp')

.PHONY: all build test lint fmt clean

all: build

build: build/polyquery

build/polyquery: $(SOURCES)
	@mkdir -p build
	$(SBCL) $(SBCL_FLAGS) --load build.lisp

test:
	$(SBCL) $(SBCL_FLAGS) --load tests/run.lisp

# Lint: compile everything from scratch and fail on any full WARNING.
lint:
	rm -rf build/fasl
	POLYQUERY_STRICT=1 $(SBCL) $(SBCL_FLAGS) --load build.lisp

# There is no standard Common Lisp formatter; normalise whitespace only.
fmt:
	find src tests -name '*.lisp' -exec sed -i -e 's/[ \t]*$$//' {} +

clean:
	rm -rf build
