#!/usr/bin/env python3
"""Compares two benchmark runs of the same engines (e.g. before/after an optimization task).

Per engine: geometric mean of per-query median latencies, speedup, best/worst per-query
ratio, queries significantly slower (> 10 % and non-overlapping 95 % CIs of the median),
peak RSS, and whether result digests are identical between the runs.

  compare_runs.py BEFORE_DIR AFTER_DIR [--report out.json]
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path


def geomean(xs: list[float]) -> float:
    return math.exp(sum(math.log(max(x, 1e-7)) for x in xs) / len(xs))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("before")
    ap.add_argument("after")
    ap.add_argument("--report")
    a = ap.parse_args()
    b = json.loads((Path(a.before) / "summary.json").read_text())
    f = json.loads((Path(a.after) / "summary.json").read_text())
    out: dict = {"before": a.before, "after": a.after, "engines": {}}
    out["digests_identical"] = all(b["result_agreement"][q]["by_engine"] == f["result_agreement"][q]["by_engine"]
                                   for q in b["result_agreement"])
    for lang in b["results"]:
        if lang not in f["results"]:
            continue
        qb, qa = b["results"][lang]["queries"], f["results"][lang]["queries"]
        common = [q for q in qb if q in qa and qb[q].get("status") == "ok" and qa[q].get("status") == "ok"]
        mb = {q: qb[q]["latency_seconds"]["median"] for q in common}
        ma = {q: qa[q]["latency_seconds"]["median"] for q in common}
        ratios = {q: mb[q] / ma[q] for q in common}
        slower = [q for q in common if ma[q] > 1.10 * mb[q]
                  and qa[q]["latency_seconds"]["ci95_median"][0] > qb[q]["latency_seconds"]["ci95_median"][1]]
        gb, ga = geomean(list(mb.values())), geomean(list(ma.values()))
        rss = lambda r: (r.get("memory") or {}).get("peak_tree_rss_bytes")  # noqa: E731
        out["engines"][lang] = {"queries": len(common), "geomean_before_s": gb, "geomean_after_s": ga,
                                "speedup": gb / ga, "best_ratio": max(ratios.values()),
                                "worst_ratio": min(ratios.values()), "significantly_slower": slower,
                                "peak_rss_before": rss(b["results"][lang]), "peak_rss_after": rss(f["results"][lang]),
                                "per_query_speedup": ratios}
        e = out["engines"][lang]
        print(f"{lang:12} {gb * 1e3:9.2f} ms -> {ga * 1e3:9.2f} ms  x{e['speedup']:.2f}  "
              f"best x{e['best_ratio']:.1f} worst x{e['worst_ratio']:.2f}  slower={slower}")
    print(f"result digests identical: {out['digests_identical']}")
    if a.report:
        Path(a.report).write_text(json.dumps(out, indent=1) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
