"""Profiles workload queries in-process (cProfile), through the same request
handler the session uses.

    python3 tools/profile_workload.py --data /tmp/pqdata/1m q10 q19 [--top 25] [--options '{}']

Only the tables a selected query references are loaded.
"""

from __future__ import annotations

import argparse
import cProfile
import json
import pstats
import re
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

from polyquery.protocol.handlers import RequestHandler  # noqa: E402
from polyquery.service import Engine, EngineConfig  # noqa: E402

WORKLOAD = HERE.parents[2] / "benchmarks" / "workloads" / "analytics.json"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True)
    ap.add_argument("--workload", default=str(WORKLOAD))
    ap.add_argument("--top", type=int, default=25)
    ap.add_argument("--options", default="{}")
    ap.add_argument("--sort", default="tottime")
    ap.add_argument("queries", nargs="+", help="query name prefixes")
    args = ap.parse_args()

    workload = json.loads(Path(args.workload).read_text())
    queries = [q for q in workload["queries"] if any(q["name"].startswith(p) for p in args.queries)]
    handler = RequestHandler(Engine(EngineConfig(data_dir=args.data)))
    data = Path(args.data)
    for name, base in workload["tables"].items():
        if not any(re.search(rf"\b{name}\b", q["sql"]) for q in queries):
            continue
        schema = json.loads((data / f"{base}.schema.json").read_text())
        resp = handler.handle({"op": "load", "table": name, "format": "csv", "path": f"{base}.csv", "schema": schema})
        assert resp["ok"], resp
    for index in workload.get("indexes", []):
        handler.handle({"op": "query", "sql": index["sql"]})
    options = json.loads(args.options)
    for query in queries:
        req = {"op": "query", "sql": query["sql"], "options": {**options, "result": query.get("result", "rows")}}
        handler.handle(req)  # warm-up
        t0 = time.perf_counter()
        handler.handle(req)
        print(f"== {query['name']}: {(time.perf_counter() - t0) * 1000:.0f} ms")
        profiler = cProfile.Profile()
        profiler.enable()
        resp = handler.handle(req)
        profiler.disable()
        assert resp["ok"], resp
        pstats.Stats(profiler).sort_stats(args.sort).print_stats(args.top)
    return 0


if __name__ == "__main__":
    sys.exit(main())
