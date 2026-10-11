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
engine returns exactly what a saved baseline returned.
"""

from __future__ import annotations

import argparse
import hashlib
import json
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


def digest(sql: str, rows: list) -> str:
    encoded = [json.dumps(r, separators=(",", ":")) for r in rows]
    if "ORDER BY" not in sql.upper().split(")")[-1]:
        encoded.sort()
    h = hashlib.sha256()
    for e in encoded:
        h.update(e.encode())
        h.update(b"\n")
    return h.hexdigest()[:16]


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
    ap.add_argument("--compare", help="fail if a digest differs from this saved result file")
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
        flag = ""
        if q["id"] in baseline and baseline[q["id"]]["digest"] != dig:
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
