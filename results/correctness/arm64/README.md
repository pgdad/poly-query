# AArch64 end-to-end conformance (spark, NVIDIA GB10)

Produced by `tools/remote/arm_engines.sh` from the commit in `snapshot-commit`
(final engines: Phases 1–5, native kernels, CR-1 UNION ALL, CR-3 refactoring,
CR-2 DECIMAL(38), latency optimizations merged so far). The native kernel library
and every engine were built natively on aarch64 with the host's pinned toolchain
versions (`toolchains.txt`) and run as `pqrunner` in locked-down systemd units;
conformance public + hidden (746 cases), with and without `--native`
(`build/aarch64/libpqkernels.so`). Host details: `arm-host.json`. Result: all six
engines 746/746 in both modes.
