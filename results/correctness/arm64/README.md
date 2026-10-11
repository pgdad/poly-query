# AArch64 end-to-end conformance (spark, NVIDIA GB10)

Produced by `tools/remote/arm_engines.sh` from the commit in `snapshot-commit`:
native kernel library and every engine built natively on aarch64 with the host's
pinned toolchain versions (`toolchains.txt`), run as `pqrunner` in locked-down
systemd units, conformance public + hidden, with and without `--native`
(`build/aarch64/libpqkernels.so`). Host details: `arm-host.json`.

The Clojure files come from a re-run (`clojure-*`): the first run failed in the
harness, not the engine (Maven resolved its local repository from the runner
user's passwd home instead of the job's offline cache; fixed in the script).
Java and Common Lisp were measured before their CR-1 (`UNION ALL`) merge, hence
638 instead of 665 cases.
