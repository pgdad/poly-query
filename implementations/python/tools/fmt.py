"""Minimal standard-library formatter: strips trailing whitespace and ensures a
single final newline (no third-party formatter is available)."""

from __future__ import annotations

import sys
from pathlib import Path


def main(argv: list[str]) -> int:
    for root in argv:
        p = Path(root)
        for path in sorted(p.rglob("*.py")) if p.is_dir() else [p]:
            text = path.read_text(encoding="utf-8")
            formatted = "\n".join(line.rstrip() for line in text.splitlines()).rstrip("\n") + "\n"
            if formatted != text:
                path.write_text(formatted, encoding="utf-8")
                print(f"formatted {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
