"""Minimal standard-library lint: syntax, unused imports and whitespace checks."""

from __future__ import annotations

import ast
import sys
from pathlib import Path


def python_files(roots: list[str]) -> list[Path]:
    files: list[Path] = []
    for root in roots:
        p = Path(root)
        files.extend(sorted(p.rglob("*.py")) if p.is_dir() else [p])
    return files


def check(path: Path) -> list[str]:
    problems = []
    text = path.read_text(encoding="utf-8")
    tree = ast.parse(text, str(path))
    imported: dict[str, int] = {}
    for node in ast.walk(tree):
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            if isinstance(node, ast.ImportFrom) and node.module == "__future__":
                continue
            for alias in node.names:
                name = (alias.asname or alias.name).split(".")[0]
                imported[name] = node.lineno
    used = {n.id for n in ast.walk(tree) if isinstance(n, ast.Name)}
    used |= {n.value.id for n in ast.walk(tree) if isinstance(n, ast.Attribute) and isinstance(n.value, ast.Name)}
    exported = set()
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "__all__" for t in node.targets):
            exported = {e.value for e in node.value.elts}  # type: ignore[attr-defined]
    if path.name != "__init__.py":
        for name, line in imported.items():
            if name not in used and name not in exported:
                problems.append(f"{path}:{line}: unused import '{name}'")
    for n, line in enumerate(text.splitlines(), 1):
        if line != line.rstrip():
            problems.append(f"{path}:{n}: trailing whitespace")
        if len(line) > 120:
            problems.append(f"{path}:{n}: line longer than 120 characters")
    return problems


def main(argv: list[str]) -> int:
    problems = [p for f in python_files(argv) for p in check(f)]
    for p in problems:
        print(p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
