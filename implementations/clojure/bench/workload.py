#!/usr/bin/env python3
"""PolyQuery Clojure engine — workload latency benchmark.

Loads the tables of a workload file (bench/workloads/analytics.json) from a
pqgen dataset directory into one `bin/polyquery session`, then times every
workload query with default options and full results (the latency a client
sees: planning, execution, JSON serialization and the protocol round trip).

usage: workload.py DATA_DIR [--workload FILE] [--runs N] [--warmup N] [--only A1,A2]
                            [--engine LAUNCHER] [--json OUT]
       workload.py DATA_DIR --digest OUT    # write result digests (for before/after checks)
       workload.py DATA_DIR --check FILE    # compare result digests with a previous --digest run
       workload.py DATA_DIR --baseline LAUNCHER   # before/after table: the runs of both
                                            # engines alternate, so they share machine noise

Results are digested as the sorted list of rows (in order if the query has an
ORDER BY), FLOAT64 values rounded to 9 significant digits, so a before/after
comparison tolerates only differences in floating-point summation order.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import statistics
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAUNCHER = HERE.parent / "bin" / "polyquery"
DEFAULT_WORKLOAD = HERE / "workloads" / "analytics.json"


class Session:
    def __init__(self, data_dir: str, java_opts: str, launcher: str):
        env = dict(os.environ, POLYQUERY_JAVA_OPTS=java_opts)
        self.proc = subprocess.Popen([launcher, "session", "--data-dir", data_dir],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)
        self.n = 0

    def request(self, req: dict) -> dict:
        self.n += 1
        self.proc.stdin.write(json.dumps(dict(req, id=self.n)) + "\n")
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        if not line:
            raise RuntimeError("engine exited")
        return json.loads(line)

    def close(self) -> None:
        self.proc.stdin.close()
        self.proc.wait(timeout=30)


def digest(sql: str, resp: dict) -> str:
    norm = lambda v: f"{v:.9g}" if isinstance(v, float) else json.dumps(v)
    rows = ["|".join(norm(v) for v in row) for row in resp["rows"]]
    if "ORDER BY" not in sql.upper():
        rows.sort()
    cols = ",".join(f"{c['name']}:{c['type']}" for c in resp["columns"])
    h = hashlib.sha256((cols + "\n" + "\n".join(rows)).encode()).hexdigest()[:16]
    return f"{h} ({len(rows)} rows)"


def open_session(wl: dict, args, launcher: str) -> Session | None:
    s = Session(args.data_dir, args.java_opts, launcher)
    for t, f in wl["tables"].items():
        schema = json.loads((Path(args.data_dir) / f"{f}.schema.json").read_text())
        t0 = time.monotonic()
        r = s.request({"op": "load", "table": t, "path": f"{f}.csv", "format": "csv", "schema": schema})
        if not r.get("ok"):
            print(f"load {t} failed: {r}", file=sys.stderr)
            return None
        print(f"loaded {t}: {r['row_count']} rows in {time.monotonic() - t0:.1f}s", file=sys.stderr)
    return s


def timed(s: Session, sql: str) -> tuple[float, dict]:
    t0 = time.monotonic()
    r = s.request({"op": "query", "sql": sql})
    return time.monotonic() - t0, r


def compare(queries: list, base: Session, s: Session, args) -> int:
    """Median latencies of both engines, runs interleaved (base, new, base, …)."""
    out = {}
    print("| id | query | rows | before | after | speed-up |")
    print("|---|---|---:|---:|---:|---:|")
    for q in queries:
        tb, tn = [], []
        rows = None
        for i in range(args.warmup + args.runs):
            db, rb = timed(base, q["sql"])
            dn, rn = timed(s, q["sql"])
            if not (rb.get("ok") and rn.get("ok")):
                print(f"{q['id']} failed: {rb if not rb.get('ok') else rn}", file=sys.stderr)
                return 1
            if rb["row_count"] != rn["row_count"]:
                print(f"{q['id']}: row counts differ", file=sys.stderr)
                return 1
            rows = rn["row_count"]
            if i >= args.warmup:
                tb.append(db)
                tn.append(dn)
        mb, mn = statistics.median(tb) * 1000, statistics.median(tn) * 1000
        out[q["id"]] = {"before": mb, "after": mn}
        print(f"| {q['id']} | {q['name']} | {rows} | {mb:.1f} ms | {mn:.1f} ms | {mb / mn:.1f}x |", flush=True)
    base.close()
    s.close()
    tot_b = sum(v["before"] for v in out.values())
    tot_n = sum(v["after"] for v in out.values())
    print(f"| | **total** | | **{tot_b:.0f} ms** | **{tot_n:.0f} ms** | **{tot_b / tot_n:.1f}x** |")
    if args.json:
        Path(args.json).write_text(json.dumps(out, indent=1) + "\n")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("data_dir")
    ap.add_argument("--workload", default=str(DEFAULT_WORKLOAD))
    ap.add_argument("--runs", type=int, default=9)
    ap.add_argument("--warmup", type=int, default=3)
    ap.add_argument("--only")
    ap.add_argument("--java-opts", default="-Xmx24g")
    ap.add_argument("--engine", default=str(LAUNCHER))
    ap.add_argument("--json", metavar="OUT", help="also write the medians as JSON")
    ap.add_argument("--digest", metavar="OUT", help="write result digests instead of timing")
    ap.add_argument("--check", metavar="FILE", help="compare result digests with FILE instead of timing")
    ap.add_argument("--baseline", metavar="LAUNCHER", help="before/after comparison with this engine")
    args = ap.parse_args()

    wl = json.loads(Path(args.workload).read_text())
    only = set(args.only.split(",")) if args.only else None
    queries = [q for q in wl["queries"] if not only or q["id"] in only]

    s = open_session(wl, args, args.engine)
    if s is None:
        return 1
    if args.baseline:
        base = open_session(wl, args, args.baseline)
        return compare(queries, base, s, args) if base else 1

    if args.digest or args.check:
        digests = {}
        for q in queries:
            r = s.request({"op": "query", "sql": q["sql"]})
            digests[q["id"]] = digest(q["sql"], r) if r.get("ok") else "error " + r["error"]["code"]
            print(f"{q['id']}: {digests[q['id']]}", flush=True)
        s.close()
        if args.digest:
            Path(args.digest).write_text(json.dumps(digests, indent=1) + "\n")
            return 0
        ref = json.loads(Path(args.check).read_text())
        bad = [i for i in digests if ref.get(i) != digests[i]]
        for i in bad:
            print(f"DIFF {i}: expected {ref.get(i)}, got {digests[i]}")
        print("all results match" if not bad else f"{len(bad)} result(s) differ")
        return 1 if bad else 0

    medians = {}
    print("| id | query | rows | median |")
    print("|---|---|---:|---:|")
    for q in queries:
        times = []
        rows = None
        for i in range(args.warmup + args.runs):
            t0 = time.monotonic()
            r = s.request({"op": "query", "sql": q["sql"]})
            dt = time.monotonic() - t0
            if not r.get("ok"):
                print(f"{q['id']} failed: {r}", file=sys.stderr)
                break
            rows = r["row_count"]
            if i >= args.warmup:
                times.append(dt)
        med = statistics.median(times) * 1000 if times else None
        medians[q["id"]] = med
        cell = f"{med:.1f} ms" if med is not None else "error"
        print(f"| {q['id']} | {q['name']} | {rows} | {cell} |", flush=True)
    s.close()
    if args.json:
        Path(args.json).write_text(json.dumps(medians, indent=1) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
