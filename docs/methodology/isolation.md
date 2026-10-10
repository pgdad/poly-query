# Implementation Isolation

Requirement (prompt §3.2, §14): an implementation agent must not be able to
inspect another language's implementation, the hidden acceptance tests, or
reference tooling; instructions alone are not sufficient.

## Mechanism (ADR-0007)

1. **Fresh workspace repository.** `pq_orchestrate.py prepare` exports, with
   `git archive` from a recorded commit, only: `spec/`, the public conformance
   runner, cases and fixtures, `tests/concurrency/`, dataset generators and
   manifests, the kernel ABI header, and the agent's own language directory
   (accepted code from the previous phase). It is committed as a new repository
   (`baseline` commit) — there is no shared object database, so `git log/show`
   cannot reveal other code. Kernel tasks receive only the kernel ABI,
   reference C, tests and their own architecture directory.
2. **Sandbox** (`tools/orchestration/sandbox.sh`, bubblewrap): the agent process
   sees the host root read-only, but
   * `$HOME` is an empty tmpfs with only toolchain directories bound read-only
     (`~/.cargo`, `~/.rustup`, `~/.local/bin`, `~/.local/share/claude`,
     `~/.clojure`, `~/.local/share/uv`) and per-run caches;
   * `/srv` (all run directories) is a tmpfs; only this run's workspace,
     scratch and agent-config directories are re-bound;
   * `/tmp`, `/var/tmp`, `/run/user`, `/root`, `/mnt`, `/media` are private/empty;
   * the environment is rebuilt from an allowlist (`env -i`), so no host
     credentials (e.g. `AWS_*`) leak;
   * the process runs with the invoking uid but **no supplementary groups**
     (no `docker`/`sudo` group), **no capabilities**, and **no_new_privs** (setuid
     binaries such as `sudo` cannot elevate);
   * PID/IPC/UTS namespaces are private.
3. **Agent configuration isolation.** `CLAUDE_CONFIG_DIR` points to a per-run
   directory containing only a copy of the OAuth credential and a minimal
   settings file: no user `CLAUDE.md`, memories, plugins, MCP servers or session
   history are visible to the agent (`--strict-mcp-config`, `--setting-sources user`).
4. **Post-hoc verification.** Telemetry records every path an agent changed
   outside its language directory (`paths_outside_language_dir`); a non-empty
   list classifies the attempt as `isolation_violation`. `import` applies only
   patches restricted to the language directory and re-checks the resulting diff.
5. **Validation in the sandbox.** Agent-built binaries are executed for
   validation only inside the same sandbox (clean clone + hidden tests copied in
   after the agent has exited).

## Residual risks (documented, not hidden)

* **Network access is not restricted** (the agent needs the model API). An agent
  could in principle download code from the internet. Track A forbids it; build
  offline settings (`GOPROXY=off`, `CARGO_NET_OFFLINE=true`) make accidental
  dependency downloads fail; `ENGINE.json`/build files are reviewed.
* Host system directories (`/usr`, `/etc`, `/opt`) are readable. They contain no
  PolyQuery implementation code.
* bubblewrap is started via passwordless `sudo` because Ubuntu 24.04's AppArmor
  policy blocks unprivileged user namespaces; privileges are dropped before the
  agent starts. This requires sudo rights for the orchestrating user.
* Agents in the same wave run concurrently on one host and can observe host
  load, but not each other's files.

## Host-side execution of merged engines

After merging, engines and assembly kernels still run only sandboxed:
`tools/orchestration/sandboxed.sh` (used by every `just` recipe that executes
engine or kernel code, and by the benchmark harness) binds the repository as the
only writable tree, overlays `.git` read-only, gives an empty agent config dir
(no credentials), clears the environment and drops all privileges.

Validation of a run (`pq_orchestrate.py validate`) takes only the agent's own
work directory from the workspace; `tests/`, `spec/` and the kernel scaffolding
come from the trusted repository, so an agent cannot influence its own verdict
by editing the harness.

## Native AArch64 host (spark)

Native ARM testing and benchmarking runs on `spark` (NVIDIA GB10: 10× Cortex-X925
+ 10× Cortex-A725, SVE2 with a 128-bit vector length, Ubuntu 24.04) through
`tools/remote/arm_native.sh`. The kernel tree is copied to the host and executed
as the unprivileged system user `pqrunner` in a transient systemd unit:
`PrivateNetwork`, `IPAddressDeny=any`, `ProtectHome`, `ProtectSystem=strict`,
`PrivateTmp`, `PrivateDevices`, `NoNewPrivileges`, an empty capability set,
`MemoryMax=16G`, and write access only to the job directory (removed afterwards).
Tests use the X925 cores; benchmarks are pinned to one X925 core (CPU 9) with the
`performance` governor. Host identification is stored with every result
(`native-arm/arm-host.json`). qemu runs remain as an additional functional check
(and for the SVE vector-length sweep); only spark results count as ARM
performance evidence. Set `PQ_ARM_HOST=` (empty) to disable, or another host name.
