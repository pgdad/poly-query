#!/usr/bin/env python3
"""Latency of the benchmark workload (benchmarks/workloads/analytics.json).

Usage:
  python3 datasets/generators/pqgen.py generate --scale 1m --jobs 1
  python3 implementations/go/scripts/workload.py --data datasets/generated/1m [--repeat 7] \
      [--engine PATH [--engine PATH2 ...]] [--options '{"threads": 1}'] [--json out.json] [--check base.json]

Starts `<engine> session --data-dir DATA`, loads the workload's tables (CSV with
the generated schemas, default layout), creates the workload's indexes and
runs every workload query through the session protocol with the default query
options (plus `result: "count"` where the workload asks for it, and any
`--options`). One warm-up run per query is followed by `--repeat` timed runs;
the client-side wall time (request written → response line read) is reported
as the median in ms. With several --engine options the engines run side by
side and their runs are interleaved. A digest of every result is recorded so that two
engines can be compared for identical answers (`--check`).
"""
import argparse
import hashlib
import json
import statistics
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ENGINE = HERE.parent / "bin" / "polyquery"
WORKLOAD = HERE.parents[2] / "benchmarks" / "workloads" / "analytics.json"


class Session:
    def __init__(self, engine, data, extra):
        self.p = subprocess.Popen([str(engine), "session", "--data-dir", str(data)] + extra,
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.n = 0

    def req(self, obj):
        self.n += 1
        obj["id"] = self.n
        self.p.stdin.write(json.dumps(obj) + "\n")
        self.p.stdin.flush()
        return json.loads(self.p.stdout.readline())

    def close(self):
        self.p.stdin.close()
        self.p.wait()


def digest(resp):
    """Digest of a query answer; FLOAT64 values are rounded so that
    summation-order differences of parallel FLOAT64 sums do not count."""
    def norm(v):
        if isinstance(v, float):
            return float(f"{v:.9g}")
        return v
    body = {"columns": resp.get("columns"), "row_count": resp.get("row_count"),
            "rows": [[norm(v) for v in r] for r in resp.get("rows", [])]}
    return hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()[:16]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True)
    ap.add_argument("--engine", action="append",
                    help="engine executable; repeat to compare engines (runs are interleaved)")
    ap.add_argument("--workload", default=str(WORKLOAD))
    ap.add_argument("--repeat", type=int, default=7)
    ap.add_argument("--options", default="{}", help="extra query options (JSON object)")
    ap.add_argument("--engine-args", default="", help="extra engine arguments (space separated)")
    ap.add_argument("--queries", default="", help="comma-separated subset of query names")
    ap.add_argument("--json", help="write the results of the first engine to this file")
    ap.add_argument("--check", help="compare result digests with this earlier --json file")
    args = ap.parse_args()
    engines = args.engine or [str(ENGINE)]

    wl = json.loads(Path(args.workload).read_text())
    sessions = [Session(e, args.data, args.engine_args.split()) for e in engines]
    for name, base in wl["tables"].items():
        schema = json.loads((Path(args.data) / f"{base}.schema.json").read_text())
        for e, s in zip(engines, sessions):
            t0 = time.monotonic()
            r = s.req({"op": "load", "table": name, "path": f"{base}.csv", "format": "csv", "schema": schema})
            if not r.get("ok"):
                sys.exit(f"{e}: load {name}: {r}")
            print(f"# {e}: loaded {name}: {r['row_count']} rows in {time.monotonic() - t0:.2f}s", file=sys.stderr)
    for ix in wl.get("indexes", []):
        for e, s in zip(engines, sessions):
            r = s.req({"op": "query", "sql": ix["sql"]})
            print(f"# {e}: {ix['sql']}: {'ok' if r.get('ok') else r['error']['code']}", file=sys.stderr)

    extra = json.loads(args.options)
    only = set(filter(None, args.queries.split(",")))
    results = [{} for _ in engines]
    head = " | ".join(f"median ms ({i})" if len(engines) > 1 else "median ms" for i in range(len(engines)))
    print(f"| query | {head} | rows |")
    print("|---|" + "---:|" * (len(engines) + 1))
    for q in wl["queries"]:
        if only and q["name"] not in only:
            continue
        opts = dict(extra)
        if q.get("result") == "count":
            opts["result"] = "count"
        req = {"op": "query", "sql": q["sql"]}
        if opts:
            req["options"] = opts
        digests, times, failed = [], [[] for _ in engines], {}
        for i, s in enumerate(sessions):
            r = s.req(dict(req))  # warm-up
            if not r.get("ok"):
                failed[i] = r["error"]["code"]
            digests.append(digest(r) if r.get("ok") else None)
            rows = r.get("row_count")
        # Runs are interleaved across engines so that load drift on the
        # machine affects all of them alike.
        for _ in range(args.repeat):
            for i, s in enumerate(sessions):
                if i in failed:
                    continue
                t0 = time.monotonic()
                r = s.req(dict(req))
                times[i].append((time.monotonic() - t0) * 1000)
                if digest(r) != digests[i]:
                    sys.exit(f"{engines[i]}: {q['name']}: result changed between runs")
        cells = []
        for i in range(len(engines)):
            if i in failed:
                results[i][q["name"]] = {"error": failed[i]}
                cells.append(failed[i])
                continue
            results[i][q["name"]] = {"median_ms": statistics.median(times[i]), "min_ms": min(times[i]),
                                     "row_count": rows, "digest": digests[i]}
            cells.append(f"{statistics.median(times[i]):.2f}")
        if len(set(digests)) > 1:
            cells.append("**results differ**")
        print(f"| {q['name']} | " + " | ".join(cells) + f" | {rows} |", flush=True)
    for s in sessions:
        s.close()
    totals = [sum(v.get("median_ms", 0) for v in res.values()) for res in results]
    print("| total | " + " | ".join(f"{t:.1f}" for t in totals) + " | |")
    if args.json:
        Path(args.json).write_text(json.dumps(results[0], indent=1))
    if args.check:
        base = json.loads(Path(args.check).read_text())
        for e, res in zip(engines, results):
            bad = [k for k, v in res.items() if k in base and base[k].get("digest") != v.get("digest")]
            if bad:
                sys.exit(f"{e}: result digests differ from {args.check}: {', '.join(bad)}")
        print(f"# all result digests match {args.check}", file=sys.stderr)


if __name__ == "__main__":
    main()
