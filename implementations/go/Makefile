# PolyQuery Go engine, its embedding library (package polyquery, the module
# root), the pqledger application (app/) and the embedding example
# (examples/embed-demo, a separate module). Requires only the Go toolchain
# (standard library only).
GO      ?= go
BUILD   := build
GOFLAGS := -trimpath
export GOTOOLCHAIN := local
export GOPROXY := off
export GOFLAGS
# Explicit SIMD kernels use the standard library's experimental
# simd/archsimd package (amd64 only); elsewhere portable loops are used.
ifeq ($(shell $(GO) env GOARCH),amd64)
export GOEXPERIMENT := simd
endif

.PHONY: build test lint fmt clean

build:
	$(GO) build ./...
	$(GO) build -o $(BUILD)/polyquery ./cmd/polyquery
	$(GO) build -o $(BUILD)/pqledger ./app/cmd/pqledger
	cd examples/embed-demo && $(GO) build -o ../../$(BUILD)/pq-embed-demo .

test:
	$(GO) test ./...
	cd examples/embed-demo && $(GO) vet ./...

lint:
	$(GO) vet ./...
	cd examples/embed-demo && $(GO) vet ./...
	@out=$$(gofmt -l .); if [ -n "$$out" ]; then echo "gofmt needed:"; echo "$$out"; exit 1; fi

fmt:
	gofmt -w .

clean:
	rm -rf $(BUILD)
