#!/usr/bin/env python3
"""Environment verification: toolchains, hardware, OS.

Writes tools/environment/versions.json (or --out) and prints a summary.
Exit status 1 if a required tool is missing.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

JAVA_HOME = os.environ.get("PQ_JAVA_HOME", "/usr/lib/jvm/jdk-27")


def run(cmd: list[str], timeout: int = 60) -> str | None:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None
    out = (p.stdout + p.stderr).strip()
    return out if p.returncode == 0 or out else None


def first_line(s: str | None) -> str | None:
    return s.splitlines()[0].strip() if s else None


def python314() -> str | None:
    found = run(["uv", "python", "find", "3.14"])
    return found.strip() if found and Path(found.strip()).exists() else None


TOOLS = {
    # name: (required, command)
    "java": (True, [f"{JAVA_HOME}/bin/java", "-version"]),
    "javac": (True, [f"{JAVA_HOME}/bin/javac", "-version"]),
    "clojure": (True, ["clojure", "-M", "-e", "(println (clojure-version))"]),
    "rustc": (True, ["rustc", "--version"]),
    "cargo": (True, ["cargo", "--version"]),
    "go": (True, ["go", "version"]),
    "python": (True, None),  # resolved dynamically
    "sbcl": (True, ["/opt/sbcl/bin/sbcl", "--version"]),
    "gcc": (True, ["gcc", "--version"]),
    "clang": (False, ["clang", "--version"]),
    "nasm": (False, ["nasm", "-v"]),
    "as": (True, ["as", "--version"]),
    "aarch64-gcc": (False, ["aarch64-linux-gnu-gcc", "--version"]),
    "qemu-aarch64": (False, ["qemu-aarch64-static", "--version"]),
    "sqlite3-python": (True, [sys.executable, "-c", "import sqlite3;print(sqlite3.sqlite_version)"]),
    "just": (False, ["just", "--version"]),
    "make": (True, ["make", "--version"]),
    "git": (True, ["git", "--version"]),
    "bwrap": (False, ["bwrap", "--version"]),
    "claude": (False, ["claude", "--version"]),
    "docker": (False, ["docker", "--version"]),
}


def cpu_info() -> dict:
    info: dict = {"arch": platform.machine(), "logical_cpus": os.cpu_count()}
    try:
        txt = Path("/proc/cpuinfo").read_text()
        m = re.search(r"model name\s*:\s*(.+)", txt)
        info["model"] = m.group(1).strip() if m else None
        flags = set(re.search(r"flags\s*:\s*(.+)", txt).group(1).split()) if "flags" in txt else set()
        info["simd"] = sorted(f for f in flags if f in {"sse4_2", "avx", "avx2", "fma", "bmi2", "avx512f", "avx512bw", "avx512vl", "avx512dq", "popcnt"})
        feats = re.search(r"Features\s*:\s*(.+)", txt)
        if feats:  # aarch64
            info["simd"] = sorted(f for f in feats.group(1).split() if f in {"asimd", "sve", "sve2"})
    except OSError:
        pass
    try:
        mem = Path("/proc/meminfo").read_text()
        kb = int(re.search(r"MemTotal:\s*(\d+)", mem).group(1))
        info["memory_gib"] = round(kb / 1024 / 1024, 1)
    except (OSError, AttributeError):
        info["memory_gib"] = None
    return info


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(ROOT / "tools/environment/versions.json"))
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    result: dict = {"tools": {}, "missing_required": []}
    for name, (required, cmd) in TOOLS.items():
        if name == "python":
            exe = python314()
            cmd = [exe, "--version"] if exe else None
            result["tools"]["python"] = {"path": exe, "version": first_line(run(cmd)) if cmd else None}
            if not exe:
                result["missing_required"].append(name)
            continue
        out = run(cmd) if cmd and (Path(cmd[0]).exists() or shutil.which(cmd[0])) else None
        version = None
        if out:
            lines = [l for l in out.splitlines() if l.strip() and "WARNING" not in l]
            version = lines[0].strip() if lines else None
            if name == "clojure":
                version = lines[-1].strip() if lines else None
        result["tools"][name] = {"version": version, "required": required}
        if required and not version:
            result["missing_required"].append(name)

    result["hardware"] = cpu_info()
    result["os"] = {"system": platform.system(), "release": platform.release(),
                    "pretty": first_line(run(["sh", "-c", ". /etc/os-release && echo $PRETTY_NAME"]))}
    Path(args.out).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")

    if not args.quiet:
        for k, v in result["tools"].items():
            flag = "OK " if v.get("version") else ("MISSING" if v.get("required", True) else "absent")
            print(f"  {flag:7} {k:15} {v.get('version') or ''}")
        hw = result["hardware"]
        print(f"  CPU: {hw.get('model')} ({hw.get('arch')}, {hw.get('logical_cpus')} threads, {hw.get('memory_gib')} GiB)")
        print(f"  SIMD: {', '.join(hw.get('simd') or [])}")
        print(f"  OS: {result['os']['pretty']} / kernel {result['os']['release']}")
        print(f"  written: {args.out}")
    if result["missing_required"]:
        print("missing required tools: " + ", ".join(result["missing_required"]), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
