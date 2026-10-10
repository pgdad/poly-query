# Development Setup

Reference host used for the recorded experiment: Ubuntu 24.04.5, kernel 7.0,
AMD Ryzen 9 9950X3D (16C/32T, AVX2 + AVX-512), 249 GiB RAM.
Exact versions: `tools/environment/versions.json` (written by `just doctor`).

| Tool | Version used | Install |
|---|---|---|
| JDK | OpenJDK 27 (`/usr/lib/jvm/jdk-27`) | jdk.java.net GA tarball |
| Clojure CLI | 1.12.3 | clojure.org install script |
| Rust | 1.96.0 | rustup |
| Go | 1.27.1 | go.dev tarball or snap |
| CPython | 3.14 | `uv python install 3.14` |
| SBCL | 2.6.9 at `/opt/sbcl` | sbcl.org binary: `sh install.sh` with `INSTALL_ROOT=/opt/sbcl-2.6.9`, symlink `/opt/sbcl` |
| C toolchain | gcc 13.3, binutils 2.42, nasm 2.16 | apt `build-essential nasm` |
| AArch64 cross | aarch64-linux-gnu-gcc 13.3, qemu-user-static 8.2 | apt `gcc-aarch64-linux-gnu libc6-dev-arm64-cross qemu-user-static` |
| Harness | Python ≥ 3.12 stdlib only, `sqlite3` module | — |
| just | 1.58 | `cargo install just` |
| Agent runs only | Claude Code CLI ≥ 2.1, bubblewrap ≥ 0.9, passwordless sudo | see docs/methodology/isolation.md |

`just setup` prints what is missing and the commands to install it.

A container image for reproducible builds and conformance runs (not for
benchmarks, see ADR-0015) is defined in `tools/environment/Dockerfile`:

```bash
docker build -t polyquery-env tools/environment
docker run --rm -v "$PWD":/work -w /work polyquery-env just test-language go
```
