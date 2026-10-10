#!/usr/bin/env python3
"""Prints missing toolchains and the commands to install them (does not install anything itself)."""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HINTS = {
    "java": "download OpenJDK 27 from https://jdk.java.net/27/ and unpack to /usr/lib/jvm/jdk-27",
    "javac": "see java",
    "clojure": "curl -L -O https://github.com/clojure/brew-install/releases/latest/download/linux-install.sh && sudo bash linux-install.sh",
    "rustc": "curl https://sh.rustup.rs -sSf | sh -s -- -y --default-toolchain 1.96.0",
    "cargo": "see rustc",
    "go": "install Go 1.27.x from https://go.dev/dl/",
    "python": "uv python install 3.14   (uv: https://docs.astral.sh/uv/)",
    "sbcl": "download sbcl-2.6.9-x86-64-linux-binary.tar.bz2 from sbcl.org; sudo INSTALL_ROOT=/opt/sbcl-2.6.9 sh install.sh; sudo ln -s /opt/sbcl-2.6.9 /opt/sbcl",
    "gcc": "sudo apt install build-essential", "as": "sudo apt install binutils",
    "nasm": "sudo apt install nasm",
    "aarch64-gcc": "sudo apt install gcc-aarch64-linux-gnu libc6-dev-arm64-cross",
    "qemu-aarch64": "sudo apt install qemu-user-static",
    "just": "cargo install just", "bwrap": "sudo apt install bubblewrap",
    "claude": "npm install -g @anthropic-ai/claude-code (agent runs only)",
}
r = subprocess.run([sys.executable, str(ROOT / "tools/environment/doctor.py"), "--quiet"])
v = json.loads((ROOT / "tools/environment/versions.json").read_text())
missing = [k for k, t in v["tools"].items() if not t.get("version")]
if not missing:
    print("all tools present")
for k in missing:
    print(f"missing {k:14} -> {HINTS.get(k, 'see docs/development/setup.md')}")
sys.exit(1 if v["missing_required"] else 0)
