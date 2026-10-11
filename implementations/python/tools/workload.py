"""Latency driver for a benchmark workload file (``benchmarks/analytics.json``).

    python3 tools/workload.py --data /tmp/pqdata/1m [--workload benchmarks/analytics.json]
        [--repeat 5] [--only A02,A04] [--options '{"threads":4}'] [--engine bin/polyquery]
        [--save results.json] [--compare baseline.json]

The tables of the workload are loaded (CSV with the generated schemas) into one
``bin/polyquery session``; every query is then run once as a warm-up and
``--repeat`` times, end to end: the wall time from writing the request to
reading the complete response line, rows included (``result: rows``). The
median is reported in ms.

Every result is reduced to a digest of its rows (in result order when the query
has ORDER BY, else as a multiset), so ``--compare`` checks that an optimized
engine returns exactly what a saved baseline returned. With ``--save-rows``
the rows themselves are saved too; a result whose digest differs from such a
baseline is then compared value by value, FLOAT64 values with a relative
tolerance of 1e-9 (types.md §9: consumers compare floats with tolerance), and
reported as ``~`` if it matches within that tolerance.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import statistics
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAUNCHER = HERE.parent / "bin" / "polyquery"
WORKLOAD = HERE.parent / "benchmarks" / "analytics.json"


class Session:
    def __init__(self, data_dir: str, launcher: str, extra_args: list[str]):
        self.proc = subprocess.Popen(
            [launcher, "session", "--data-dir", data_dir, *extra_args],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
        )
        self.next_id = 0

    def request(self, req: dict) -> tuple[dict, float]:
        """Sends one request; returns the response and the wall time in ms."""
        self.next_id += 1
        line = json.dumps({**req, "id": self.next_id}) + "\n"
        assert self.proc.stdin is not None and self.proc.stdout is not None
        t0 = time.perf_counter()
        self.proc.stdin.write(line)
        self.proc.stdin.flush()
        raw = self.proc.stdout.readline()
        elapsed = (time.perf_counter() - t0) * 1000
        resp = json.loads(raw)
        if not resp.get("ok"):
            raise RuntimeError(f"{req}: {resp.get('error')}")
        return resp, elapsed

    def close(self) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.close()
        self.proc.wait()


def ordered(sql: str) -> bool:
    return "ORDER BY" in sql.upper().split(")")[-1]


def digest(sql: str, rows: list) -> str:
    encoded = [json.dumps(r, separators=(",", ":")) for r in rows]
    if not ordered(sql):
        encoded.sort()
    h = hashlib.sha256()
    for e in encoded:
        h.update(e.encode())
        h.update(b"\n")
    return h.hexdigest()[:16]


def same_value(a: object, b: object) -> bool:
    if isinstance(a, float) or isinstance(b, float):
        if not isinstance(a, (int, float)) or not isinstance(b, (int, float)):
            return False
        return math.isclose(a, b, rel_tol=1e-9, abs_tol=1e-12)
    return a == b


def same_rows(sql: str, got: list, expected: list) -> bool:
    """Equal up to FLOAT64 tolerance (as multisets when the order is unspecified)."""
    if len(got) != len(expected):
        return False
    if not ordered(sql):
        # order by the non-float values (floats may differ in the last bits)
        def key(row: list) -> str:
            return json.dumps([v for v in row if not isinstance(v, float)])

        got, expected = sorted(got, key=key), sorted(expected, key=key)
    return all(
        len(g) == len(e) and all(same_value(x, y) for x, y in zip(g, e)) for g, e in zip(got, expected)
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True, help="directory of the generated scale (e.g. .../1m)")
    ap.add_argument("--workload", default=str(WORKLOAD))
    ap.add_argument("--repeat", type=int, default=5)
    ap.add_argument("--only")
    ap.add_argument("--options", default="{}", help="query options (JSON) added to every query")
    ap.add_argument("--engine", default=str(LAUNCHER))
    ap.add_argument("--engine-arg", action="append", default=[], help="extra launcher argument")
    ap.add_argument("--save", help="write per-query medians and digests to this JSON file")
    ap.add_argument("--save-rows", action="store_true", help="also save the result rows")
    ap.add_argument("--compare", help="fail if a result differs from this saved result file")
    args = ap.parse_args()

    workload = json.loads(Path(args.workload).read_text())
    options = json.loads(args.options)
    data = Path(args.data).resolve()
    session = Session(str(data), args.engine, args.engine_arg)
    for name, base in workload["tables"].items():
        schema = json.loads((data / f"{base}.schema.json").read_text())
        _, ms = session.request({"op": "load", "table": name, "format": "csv", "path": f"{base}.csv", "schema": schema})
        print(f"load {name}: {ms / 1000:.1f}s", file=sys.stderr)

    baseline = json.loads(Path(args.compare).read_text())["queries"] if args.compare else {}
    only = set(args.only.split(",")) if args.only else None
    results: dict[str, dict] = {}
    mismatches = []
    print("query | median ms | min ms | rows | digest")
    for q in workload["queries"]:
        if only and q["id"] not in only:
            continue
        resp, _ = session.request({"op": "query", "sql": q["sql"], "options": options})
        rows = resp["rows"]
        dig = digest(q["sql"], rows)
        times = [session.request({"op": "query", "sql": q["sql"], "options": options})[1] for _ in range(args.repeat)]
        med = statistics.median(times)
        results[q["id"]] = {"median_ms": round(med, 1), "min_ms": round(min(times), 1), "rows": len(rows), "digest": dig}
        if args.save_rows:
            results[q["id"]]["result"] = rows
        flag = ""
        base = baseline.get(q["id"])
        if base is not None and base["digest"] != dig:
            if "result" in base and same_rows(q["sql"], rows, base["result"]):
                flag = "  ~"
            else:
                flag = "  MISMATCH"
                mismatches.append(q["id"])
        print(f"{q['id']} | {med:.0f} | {min(times):.0f} | {len(rows)} | {dig}{flag}", flush=True)
    session.close()
    total = sum(r["median_ms"] for r in results.values())
    print(f"total | {total:.0f}")
    if args.save:
        Path(args.save).write_text(json.dumps({"options": options, "queries": results}, indent=1) + "\n")
    if mismatches:
        print(f"result mismatch: {', '.join(mismatches)}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
