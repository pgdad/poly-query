# PolyQuery Rust engine — standard targets (protocol.md §1).
CARGO ?= cargo
export CARGO_NET_OFFLINE := true

.PHONY: build test lint fmt clean

build:
	$(CARGO) build --release --offline --workspace

test:
	$(CARGO) test --release --offline --workspace

lint:
	$(CARGO) clippy --release --offline --workspace --all-targets -- -D warnings

fmt:
	$(CARGO) fmt

clean:
	$(CARGO) clean
