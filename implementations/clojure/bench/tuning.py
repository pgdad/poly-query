#!/usr/bin/env python3
"""PolyQuery Clojure engine — build/start-up tuning benchmark (Track B).

Measures, through `bin/polyquery session`, for one or more engine variants
(a launcher plus optional POLYQUERY_JAVA_OPTS):

* start-up: process spawn → first protocol response (`{"op":"version"}`),
  and the process RSS at that moment;
* the benchmark workload (benchmarks/workloads/analytics.json): per query
  the first run in a fresh session (cold) and the median of the warm runs,
  plus the session's peak RSS.

Variants are interleaved to cancel out machine-load drift: start-up spawns
alternate between variants, and in the workload every variant has its own
live session, the runs of one query alternating between them.

usage: tuning.py startup [--runs 20] VARIANT...
       tuning.py workload DATA_DIR [--sessions 3] [--runs 9] [--warmup 3] VARIANT...
       tuning.py cold DATA_DIR --tables T1,T2 --sql "Q1;;Q2" [--runs 7] VARIANT...
                                              # first run of each query, fresh session per run
       tuning.py verify DATA_DIR VARIANT...   # full-result digests must match
VARIANT is NAME=LAUNCHER or NAME=LAUNCHER@JAVA_OPTS, e.g.
  base=/tmp/base/bin/polyquery  new=bin/polyquery  g1=bin/polyquery@-XX:+UseG1GC
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent
DEFAULT_WORKLOAD = ROOT / "benchmarks" / "workloads" / "analytics.json"


class Variant:
    def __init__(self, spec: str):
        name, _, rest = spec.partition("=")
        launcher, _, opts = rest.partition("@")
        self.name, self.launcher, self.opts = name, str(Path(launcher).resolve()), opts


def rss_kb(pid: int, field: str = "VmRSS") -> int:
    try:
        for line in Path(f"/proc/{pid}/status").read_text().splitlines():
            if line.startswith(field + ":"):
                return int(line.split()[1])
    except OSError:
        pass
    return 0


class Session:
    def __init__(self, v: Variant, data_dir: str):
        env = dict(os.environ, POLYQUERY_JAVA_OPTS=v.opts)
        self.t0 = time.monotonic()
        self.proc = subprocess.Popen([v.launcher, "session", "--data-dir", data_dir],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)
        self.n = 0

    def request(self, req: dict) -> dict:
        self.n += 1
        self.proc.stdin.write((json.dumps(dict(req, id=self.n)) + "\n").encode())
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        if not line:
            raise RuntimeError("engine exited")
        return json.loads(line)

    def close(self) -> None:
        self.proc.stdin.close()
        self.proc.wait(timeout=60)


def startup(variants: list[Variant], runs: int) -> None:
    times = {v.name: [] for v in variants}
    rss = {v.name: [] for v in variants}
    with tempfile.TemporaryDirectory() as d:
        for v in variants:  # one untimed spawn each (file-system cache)
            s = Session(v, d)
            s.request({"op": "version"})
            s.close()
        for _ in range(runs):
            for v in variants:
                s = Session(v, d)
                r = s.request({"op": "version"})
                times[v.name].append(time.monotonic() - s.t0)
                assert r.get("ok"), r
                rss[v.name].append(rss_kb(s.proc.pid))
                s.close()
    print("| variant | start-up median | min | max | RSS at first response |")
    print("|---|---:|---:|---:|---:|")
    for v in variants:
        t = times[v.name]
        print(f"| {v.name} | {statistics.median(t) * 1000:.0f} ms | {min(t) * 1000:.0f} ms | "
              f"{max(t) * 1000:.0f} ms | {statistics.median(rss[v.name]) / 1024:.0f} MB |")


def open_session(v: Variant, wl: dict, data_dir: str) -> tuple[Session, float]:
    s = Session(v, data_dir)
    t0 = time.monotonic()
    for alias, f in wl["tables"].items():
        schema = json.loads((Path(data_dir) / f"{f}.schema.json").read_text())
        r = s.request({"op": "load", "table": alias, "path": f"{f}.csv", "format": "csv", "schema": schema})
        if not r.get("ok"):
            raise RuntimeError(f"{v.name}: load {alias} failed: {r}")
    for ix in wl.get("indexes", []):
        r = s.request({"op": "query", "sql": ix["sql"]})
        if not r.get("ok"):
            raise RuntimeError(f"{v.name}: {ix['sql']} failed: {r}")
    return s, time.monotonic() - t0


def query_req(q: dict, full: bool = False) -> dict:
    opts = {} if full or q.get("result", "rows") == "rows" else {"result": q["result"]}
    return {"op": "query", "sql": q["sql"], "options": opts}


def timed(s: Session, q: dict) -> float:
    t0 = time.monotonic()
    r = s.request(query_req(q))
    dt = time.monotonic() - t0
    if not r.get("ok"):
        raise RuntimeError(f"{q['name']} failed: {r}")
    return dt


def workload(variants: list[Variant], wl: dict, args) -> None:
    queries = wl["queries"]
    cold = {v.name: {q["name"]: [] for q in queries} for v in variants}
    warm = {v.name: {q["name"]: [] for q in queries} for v in variants}
    loads = {v.name: [] for v in variants}
    peak = {v.name: [] for v in variants}
    for k in range(args.sessions):
        order = variants if k % 2 == 0 else variants[::-1]
        sessions = {}
        for v in order:
            s, dt = open_session(v, wl, args.data_dir)
            sessions[v.name] = s
            loads[v.name].append(dt)
        for q in queries:
            for v in order:
                cold[v.name][q["name"]].append(timed(sessions[v.name], q))
            per = {v.name: [] for v in variants}
            for i in range(args.warmup + args.runs):
                for v in order:
                    dt = timed(sessions[v.name], q)
                    if i >= args.warmup:
                        per[v.name].append(dt)
            for v in variants:
                warm[v.name][q["name"]].append(statistics.median(per[v.name]))
        for v in variants:
            peak[v.name].append(rss_kb(sessions[v.name].proc.pid, "VmHWM"))
            sessions[v.name].close()
        print(f"session {k + 1}/{args.sessions} done", file=sys.stderr)

    names = [v.name for v in variants]
    ms = lambda x: f"{x * 1000:.1f}"
    print("| query | " + " | ".join(f"{n} cold" for n in names) + " | "
          + " | ".join(f"{n} warm" for n in names) + " |")
    print("|---|" + "---:|" * (2 * len(names)))
    tot_c = {n: 0.0 for n in names}
    tot_w = {n: 0.0 for n in names}
    for q in queries:
        c = {n: statistics.median(cold[n][q["name"]]) for n in names}
        w = {n: statistics.median(warm[n][q["name"]]) for n in names}
        for n in names:
            tot_c[n] += c[n]
            tot_w[n] += w[n]
        print(f"| {q['name']} | " + " | ".join(ms(c[n]) for n in names) + " | "
              + " | ".join(ms(w[n]) for n in names) + " |")
    print("| **total** | " + " | ".join(f"**{ms(tot_c[n])}**" for n in names) + " | "
          + " | ".join(f"**{ms(tot_w[n])}**" for n in names) + " |")
    print()
    print("| variant | load (s) | cold total (ms) | warm total (ms) | peak RSS (MB) |")
    print("|---|---:|---:|---:|---:|")
    for n in names:
        print(f"| {n} | {statistics.median(loads[n]):.1f} | {tot_c[n] * 1000:.0f} | "
              f"{tot_w[n] * 1000:.0f} | {statistics.median(peak[n]) / 1024:.0f} |")
    if args.json:
        Path(args.json).write_text(json.dumps({"cold": cold, "warm": warm, "loads": loads, "peak_kb": peak}) + "\n")


def cold(variants: list[Variant], args) -> None:
    """Focused cold probe: per run and variant a fresh session loads only the
    given tables, then runs each query once."""
    sqls = args.sql.split(";;")
    tables = {t: t for t in args.tables.split(",")}
    res = {v.name: [[] for _ in sqls] for v in variants}
    for k in range(args.runs):
        for v in (variants if k % 2 == 0 else variants[::-1]):
            s, _ = open_session(v, {"tables": tables}, args.data_dir)
            for i, sql in enumerate(sqls):
                res[v.name][i].append(timed(s, {"name": f"query {i + 1}", "sql": sql}))
            s.close()
    print("| variant | " + " | ".join(f"query {i + 1}" for i in range(len(sqls))) + " | sum |")
    print("|---|" + "---:|" * (len(sqls) + 1))
    for v in variants:
        meds = [statistics.median(x) * 1000 for x in res[v.name]]
        print(f"| {v.name} | " + " | ".join(f"{m:.1f}" for m in meds) + f" | {sum(meds):.1f} |")


def norm(v):
    return f"{v:.9g}" if isinstance(v, float) else json.dumps(v)


def digest(r: dict, ordered: bool) -> str:
    rows = ["|".join(norm(x) for x in row) for row in r["rows"]]
    if not ordered:
        rows.sort()
    cols = ",".join(f"{c['name']}:{c['type']}" for c in r["columns"])
    return hashlib.sha256((cols + "\n" + "\n".join(rows)).encode()).hexdigest()[:16] + f" ({len(rows)} rows)"


def verify(variants: list[Variant], wl: dict, args) -> int:
    results = {}
    for v in variants:
        s, _ = open_session(v, wl, args.data_dir)
        for q in wl["queries"]:
            r = s.request(query_req(q, full=True))
            if not r.get("ok"):
                raise RuntimeError(f"{v.name} {q['name']} failed: {r}")
            results.setdefault(q["name"], {})[v.name] = digest(r, "ORDER BY" in q["sql"].upper())
        s.close()
    bad = 0
    for name, d in results.items():
        same = len(set(d.values())) == 1
        bad += not same
        print(f"{'ok  ' if same else 'DIFF'} {name}: " + ", ".join(f"{k}={x}" for k, x in d.items()))
    print("all results identical" if not bad else f"{bad} queries differ")
    return 1 if bad else 0


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("startup")
    a.add_argument("--runs", type=int, default=20)
    a.add_argument("variants", nargs="+")
    c = sub.add_parser("cold")
    c.add_argument("data_dir")
    c.add_argument("--tables", required=True, help="comma-separated pqgen table names")
    c.add_argument("--sql", required=True, help="queries separated by ';;'")
    c.add_argument("--runs", type=int, default=7)
    c.add_argument("variants", nargs="+")
    for name in ("workload", "verify"):
        b = sub.add_parser(name)
        b.add_argument("data_dir")
        b.add_argument("--workload", default=str(DEFAULT_WORKLOAD))
        b.add_argument("--sessions", type=int, default=3)
        b.add_argument("--runs", type=int, default=9)
        b.add_argument("--warmup", type=int, default=3)
        b.add_argument("--json", metavar="OUT")
        b.add_argument("variants", nargs="+")
    args = ap.parse_args()
    variants = [Variant(s) for s in args.variants]
    if args.cmd == "startup":
        startup(variants, args.runs)
        return 0
    if args.cmd == "cold":
        cold(variants, args)
        return 0
    wl = json.loads(Path(args.workload).read_text())
    if args.cmd == "workload":
        workload(variants, wl, args)
        return 0
    return verify(variants, wl, args)


if __name__ == "__main__":
    sys.exit(main())
