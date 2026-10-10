# PolyQuery Rust engine — standard targets (protocol.md §1).
CARGO ?= cargo
export CARGO_NET_OFFLINE := true

.PHONY: build test lint fmt clean

build:
	$(CARGO) build --release --offline

test:
	$(CARGO) test --release --offline

lint:
	$(CARGO) clippy --release --offline --all-targets -- -D warnings

fmt:
	$(CARGO) fmt

clean:
	$(CARGO) clean
