#!/usr/bin/env python3
"""Correctness record for one assembly language's kernels (report 1 for the kernel cohort).

Runs the public differential tests, the ASan/UBSan build and the hidden acceptance
tests of the merged kernels in the repository, inside the sandbox (x86-64 natively;
AArch64 under qemu for functional evidence and natively on the ARM host), and writes
results/correctness/<lang>.json.

Usage: kernel_correctness.py x86_64-asm|arm64-asm [--no-arm-host]
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SANDBOXED = ROOT / "tools/orchestration/sandboxed.sh"
HIDDEN = "../tests/kernels-hidden/kernel_hidden_test.c"
LINE = re.compile(r"^\s+(\w+)\s+(\d+)/(\d+) kernels\s+(hidden )?(PASS|FAIL)", re.M)


def run(cmd: list[str], timeout: int = 3600) -> tuple[int, str]:
    p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout + p.stderr


def parse(log: str, prefix: str, key: str, into: dict) -> None:
    for m in LINE.finditer(log):
        if m.group(1).startswith(prefix):
            into.setdefault(m.group(1), {"provided": int(m.group(2)), "total": int(m.group(3))})[key] = m.group(5)


def make(target: str, extra: list[str] | None = None) -> tuple[int, str]:
    return run([str(SANDBOXED), "make", "-C", "native-kernels", target, *(extra or [])])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("lang", choices=["x86_64-asm", "arm64-asm"])
    ap.add_argument("--no-arm-host", action="store_true")
    a = ap.parse_args()
    run([str(SANDBOXED), "make", "-C", "native-kernels", "clean"])
    out: dict = {"language": a.lang, "generated": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
                 "commit": run(["git", "rev-parse", "HEAD"])[1].strip(), "suites": {}}
    v: dict[str, dict] = {}
    if a.lang == "x86_64-asm":
        for target, key in (("test-native", "public"), ("test-asan", "asan")):
            rc, log = make(target)
            parse(log, "x86_", key, v)
            out["suites"][key] = {"exit": rc, "environment": "native x86-64 (sandbox)"}
        rc, log = make("test-hidden", [f"HIDDEN_SRC={HIDDEN}"])
        parse(log, "x86_", "hidden", v)
        out["suites"]["hidden"] = {"exit": rc, "environment": "native x86-64 (sandbox), ASan/UBSan"}
        out["variants"] = v
    else:
        rc, log = make("test-cross")
        parse(log, "a64_", "public", v)
        out["suites"]["public_emulated"] = {"exit": rc, "environment": "qemu-aarch64 (functional only)"}
        rc, log = make("test-hidden-cross", [f"HIDDEN_SRC={HIDDEN}"])
        parse(log, "a64_", "hidden", v)
        out["suites"]["hidden_emulated"] = {"exit": rc, "environment": "qemu-aarch64 (functional only)"}
        out["variants_emulated"] = v
        if not a.no_arm_host:
            with tempfile.TemporaryDirectory(dir="/srv/polyquery") as td:
                kd = Path(td) / "native-kernels"
                shutil.copytree(ROOT / "native-kernels", kd, ignore=shutil.ignore_patterns("build"))
                (kd / "hidden").mkdir()
                shutil.copy(ROOT / "tests/kernels-hidden/kernel_hidden_test.c", kd / "hidden")
                od = Path(td) / "out"
                rc, _ = run([str(ROOT / "tools/remote/arm_native.sh"), str(kd), str(od), "--asan", "--hidden"], 3 * 3600)
                nv: dict[str, dict] = {}
                for log, key in (("arm-test.log", "public"), ("arm-asan.log", "asan"), ("arm-hidden.log", "hidden")):
                    if (od / log).exists():
                        parse((od / log).read_text(errors="replace"), "a64_", key, nv)
                host = json.loads((od / "arm-host.json").read_text()) if (od / "arm-host.json").exists() else {}
                out["suites"]["native_arm"] = {"exit": rc, "environment": f"native AArch64 on {host.get('hostname')}"
                                               f" ({host.get('os')}), pqrunner systemd unit"}
                out["variants"] = nv
        else:
            out["variants"] = None
    variants = out.get("variants") or out.get("variants_emulated") or {}
    out["summary"] = {
        "variants": len(variants),
        "all_pass": bool(variants) and all(all(x.get(k) == "PASS" for k in ("public", "hidden") if k in x) and
                                           x.get("public") == "PASS" for x in variants.values()),
        "complete_variants": sorted(k for k, x in variants.items() if x["provided"] == x["total"]),
        "suites_exit_ok": all(s["exit"] == 0 for s in out["suites"].values()),
    }
    dst = ROOT / "results/correctness" / f"{a.lang}.json"
    dst.write_text(json.dumps(out, indent=1) + "\n")
    print(f"{a.lang}: {len(variants)} variants, all_pass={out['summary']['all_pass']}, "
          f"suites_ok={out['summary']['suites_exit_ok']} -> {dst.relative_to(ROOT)}")
    return 0 if out["summary"]["all_pass"] and out["summary"]["suites_exit_ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
