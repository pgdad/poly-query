# PolyQuery Go engine. Requires only the Go toolchain (standard library only).
GO      ?= go
BIN     := build/polyquery
GOFLAGS := -trimpath
export GOTOOLCHAIN := local
export GOPROXY := off

.PHONY: build test lint fmt clean

build:
	$(GO) build $(GOFLAGS) -o $(BIN) ./cmd/polyquery

test:
	$(GO) test ./...

lint:
	$(GO) vet ./...
	@out=$$(gofmt -l .); if [ -n "$$out" ]; then echo "gofmt needed:"; echo "$$out"; exit 1; fi

fmt:
	gofmt -w .

clean:
	rm -rf build
