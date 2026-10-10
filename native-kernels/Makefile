# libpqkernels: C reference + runtime dispatch + optional assembly variants.
#   make            build native library (build/<arch>/libpqkernels.so) and tests
#   make test       differential tests (native) + AArch64 cross build under qemu (functional only)
#   make test-asan  native tests with AddressSanitizer + UBSan
#   make bench      micro-benchmarks (native only; JSON lines in build/<arch>/bench.jsonl)
ARCH      := $(shell uname -m)
CC        ?= gcc
CFLAGS    ?= -O2 -g
WARN      := -std=c17 -Wall -Wextra -Werror -Wno-unused-parameter
INC       := -Iinclude -Ireference-c
CROSS_CC  ?= aarch64-linux-gnu-gcc
QEMU      ?= qemu-aarch64-static -L /usr/aarch64-linux-gnu

C_SRC     := reference-c/pq_kernels_ref.c reference-c/pq_dispatch.c
X86_ASM   := $(wildcard x86_64/*.S)
A64_ASM   := $(wildcard arm64/*.S)

ifeq ($(ARCH),x86_64)
NATIVE_ASM := $(X86_ASM)
else ifeq ($(ARCH),aarch64)
NATIVE_ASM := $(A64_ASM)
endif

B := build/$(ARCH)
BA := build/aarch64-cross

.PHONY: all test test-native test-cross test-asan bench clean
all: $(B)/libpqkernels.so $(B)/kernel_test $(B)/kernel_bench

$(B):
	mkdir -p $@
$(BA):
	mkdir -p $@

$(B)/libpqkernels.so: $(C_SRC) $(NATIVE_ASM) include/pq_kernels.h reference-c/pq_kernels_internal.h | $(B)
	$(CC) $(CFLAGS) $(WARN) $(INC) -fPIC -shared -o $@ $(C_SRC) $(NATIVE_ASM)

$(B)/kernel_test: tests/kernel_test.c $(C_SRC) $(NATIVE_ASM) | $(B)
	$(CC) $(CFLAGS) $(WARN) $(INC) -o $@ tests/kernel_test.c $(C_SRC) $(NATIVE_ASM) -lm

$(B)/kernel_bench: tests/kernel_bench.c $(C_SRC) $(NATIVE_ASM) | $(B)
	$(CC) -O3 $(WARN) $(INC) -o $@ tests/kernel_bench.c $(C_SRC) $(NATIVE_ASM) -lm

$(B)/kernel_test_asan: tests/kernel_test.c $(C_SRC) $(NATIVE_ASM) | $(B)
	$(CC) -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer $(WARN) $(INC) -o $@ tests/kernel_test.c $(C_SRC) $(NATIVE_ASM) -lm

$(BA)/kernel_test: tests/kernel_test.c $(C_SRC) $(A64_ASM) | $(BA)
	$(CROSS_CC) $(CFLAGS) $(WARN) $(INC) -static -o $@ tests/kernel_test.c $(C_SRC) $(A64_ASM) -lm

test-native: $(B)/kernel_test
	$(B)/kernel_test 3000

test-asan: $(B)/kernel_test_asan
	$(B)/kernel_test_asan 1500

# AArch64 under user-mode emulation: FUNCTIONAL evidence only, never performance.
test-cross: $(BA)/kernel_test
	@echo "== AArch64 (qemu-user emulation; functional only) =="
	$(QEMU) $(BA)/kernel_test 1500

test: test-native test-asan
	@if command -v $(CROSS_CC) >/dev/null && command -v $(firstword $(QEMU)) >/dev/null; then $(MAKE) test-cross; \
	 else echo "SKIPPED AArch64 cross tests: $(CROSS_CC) or qemu not installed"; fi

bench: $(B)/kernel_bench
	$(B)/kernel_bench 4194304 15 | tee $(B)/bench.jsonl

clean:
	rm -rf build
