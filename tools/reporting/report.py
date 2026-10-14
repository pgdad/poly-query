#!/usr/bin/env python3
"""PolyQuery report generator.

Builds the eight independent reports (correctness, development effort, runtime
performance, resource efficiency, code quality, optimization effectiveness,
architectural adaptability, overall outcomes) plus a capability matrix and
Pareto analysis from raw records only:

  experiments/runs/*/{manifest,telemetry,validation}.json   (agent runs)
  results/correctness/*.json                                 (conformance reports)
  results/performance/*/summary.json                         (benchmarks)
  results/correctness/{x86_64,arm64}-asm.json, results/performance/kernels-*/  (kernel cohort)
  results/development/code-review/*.json                     (rubric reviews)

The assembly languages form a separate *kernel cohort* (ADR-0016): their results
appear in every report next to, never ranked with, the engines.

Outputs: results/comparisons/{report.json, *.csv}, docs/results/report.html,
docs/results/capability-matrix.md.

  report.py all [--weights weights.json]
  report.py capability-matrix
"""
from __future__ import annotations

import csv
import datetime as dt
import html
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RUNS = ROOT / "experiments/runs"
OUT = ROOT / "results/comparisons"
DOCS = ROOT / "docs/results"
LANGS = ["java", "clojure", "rust", "python", "go", "common-lisp"]
ASM = ["x86_64-asm", "arm64-asm"]
# Complete engines in assembly (ADR-0016, option B): their own cohort, never ranked with the six engines.
ASM_ENGINES = ["x86_64-asm-engine", "arm64-asm-engine"]
# Fixed categorical slots (reference palette order); identity is also always in axis labels.
COLORS = {"java": "#2a78d6", "clojure": "#eb6834", "rust": "#1baf7a", "python": "#eda100", "go": "#e87ba4",
          "common-lisp": "#008300", "x86_64-asm": "#6250d6", "arm64-asm": "#e34948",
          "x86_64-asm-engine": "#6250d6", "arm64-asm-engine": "#e34948"}
COLORS_DARK = {"java": "#3987e5", "clojure": "#d95926", "rust": "#199e70", "python": "#c98500", "go": "#d55181",
               "common-lisp": "#008300", "x86_64-asm": "#9085e9", "arm64-asm": "#e66767",
               "x86_64-asm-engine": "#9085e9", "arm64-asm-engine": "#e66767"}
SRC_EXT = {"java": [".java"], "clojure": [".clj", ".cljc", ".edn"], "rust": [".rs"], "python": [".py"],
           "go": [".go"], "common-lisp": [".lisp", ".asd", ".cl"], "x86_64-asm": [".S", ".s", ".h", ".inc"], "arm64-asm": [".S", ".s", ".h", ".inc"],
           "x86_64-asm-engine": [".S", ".s", ".inc"], "arm64-asm-engine": [".S", ".s", ".inc"]}
COMMENT = {"java": "//", "clojure": ";", "rust": "//", "python": "#", "go": "//", "common-lisp": ";",
           "x86_64-asm": "#", "arm64-asm": "//", "x86_64-asm-engine": "//", "arm64-asm-engine": "//"}
DEFAULT_WEIGHTS = {"correctness": 0.35, "development_effort": 0.2, "performance": 0.2, "resources": 0.1,
                   "maintainability": 0.15}
CAPS_ORDER = ["phase1", "ingest.csv", "ingest.json", "ingest.jsonl", "sql.basic", "test.functions", "phase2",
              "sql.groupby", "sql.join", "sql.functions", "sql.subquery", "sql.cte", "sql.correlated_subquery",
              "phase3", "storage.pqcf", "storage.mmap", "index.hash", "index.btree", "phase4", "http.streaming",
              "phase5", "exec.row", "exec.vectorized", "exec.parallel", "join.hash", "join.merge",
              "join.nested_loop", "native.kernels"]


def load_json(p: Path):
    try:
        return json.loads(p.read_text())
    except (OSError, json.JSONDecodeError):
        return None


# ------------------------------------------------------------------ collection

def collect_runs() -> list[dict]:
    runs = []
    for m in sorted(RUNS.glob("*/manifest.json")):
        man = load_json(m) or {}
        tel = load_json(m.parent / "telemetry.json") or {}
        val = load_json(m.parent / "validation.json") or {}
        runs.append({"run_id": man.get("run_id"), "language": man.get("language"), "task": man.get("task"),
                     "track": man.get("track"), "attempt": man.get("attempt"), "outcome": man.get("outcome") or "unvalidated",
                     "manifest": f"experiments/runs/{m.parent.name}/manifest.json", "telemetry": tel, "validation": val})
    return runs


def code_metrics(lang: str) -> dict | None:
    base = ROOT / ("native-kernels/" + ("x86_64" if lang == "x86_64-asm" else "arm64") if lang in ASM
                   else f"implementations/{lang}")
    if not base.exists():
        return None
    src = tests = files = comments = 0
    largest = 0
    for p in base.rglob("*"):
        if not p.is_file() or p.suffix not in SRC_EXT[lang]:
            continue
        if any(part in ("target", "build", "out", ".cpcache", "__pycache__") for part in p.parts):
            continue
        lines = p.read_text(errors="replace").splitlines()
        code = [l for l in lines if l.strip()]
        cm = [l for l in code if l.strip().startswith(COMMENT[lang]) or l.strip().startswith(("/*", "*", '"""'))]
        n = len(code) - len(cm)
        is_test = bool(re.search(r"(^|/)(tests?|spec)(/|$)|_test\.|test_|Test\.java$|_tests?\.", str(p.relative_to(base))))
        if not is_test and lang == "rust":
            # Rust unit tests live in inline `#[cfg(test)]` modules (conventionally at the end of a file).
            cut = next((i for i, l in enumerate(lines) if l.strip().startswith("#[cfg(test)]")), None)
            if cut is not None:
                tcode = [l for l in lines[cut:] if l.strip() and not l.strip().startswith(COMMENT[lang])]
                tests += len(tcode)
                n -= len(tcode)
        if is_test:
            tests += n
        else:
            src += n
            files += 1
            largest = max(largest, n)
        comments += len(cm)
    return {"source_loc": src, "test_loc": tests, "files": files, "comment_lines": comments,
            "comment_density": round(comments / src, 3) if src else None, "largest_file_loc": largest}


def collect_correctness() -> dict:
    out = {}
    for lang in LANGS + ASM_ENGINES:
        rep = load_json(ROOT / "results/correctness" / f"{lang}.json")
        if rep:
            out[lang] = {"summary": rep.get("summary"), "phase_passed": rep.get("phase_passed"),
                         "capabilities": (rep.get("engine") or {}).get("capability_set"),
                         "started": rep.get("started"), "source": f"results/correctness/{lang}.json"}
    return out


def collect_performance() -> list[dict]:
    out = []
    for s in sorted((ROOT / "results/performance").glob("*/summary.json")):
        d = load_json(s)
        # Harness-validation runs (taken under concurrent agent load to prove the harness works)
        # are functional evidence only, never results.
        if d and "harness-validation" not in (d.get("meta") or {}).get("bench_id", s.parent.name):
            d["_path"] = str(s.relative_to(ROOT))
            out.append(d)
    return out


# Independent before/after benchmarks of the optimize-latency family; each file lists its runs.
TASK_BEFORE_AFTER = {
    "optimize-latency-before-after.json": "attempts 1-2: agents optimized self-written stand-in workloads "
                                          "(HI-007); measured on the real workload",
    "optimize-latency-before-after-a2.json": "re-runs (attempt 2/3, record-only, not merged) with the real "
                                             "workload available to the agents",
}


# Assembly-engine cohort: x86-64 on the quiet x86 host, AArch64 on the ARM host (separate tables).
ASM_TASK_BEFORE_AFTER = {
    "optimize-latency-before-after-x86_64-asm-engine.json": "x86-64 assembly engine, quiet x86 host",
    "optimize-latency-before-after-arm64-asm-engine.json": "AArch64 assembly engine, ARM host (spark)",
}


def collect_task_before_after(files: dict | None = None) -> list[dict]:
    out = []
    for name, note in (files or TASK_BEFORE_AFTER).items():
        d = load_json(ROOT / "results/performance" / name)
        if d:
            out.append({"source": f"results/performance/{name}", "note": note,
                        "digests_identical": d.get("digests_identical"),
                        "engines": {l: {k: e.get(k) for k in ("speedup", "geomean_before_s", "geomean_after_s",
                                                               "worst_ratio", "significantly_slower",
                                                               "peak_rss_before", "peak_rss_after")}
                                    for l, e in d["engines"].items()}})
    return out


KARCH = {"x86": "x86_64-asm", "arm": "arm64-asm"}
SIMD_VARIANT = {"x86_64-asm": "x86_avx2", "arm64-asm": "a64_neon"}


def geomean(xs: list[float]) -> float | None:
    xs = [x for x in xs if x and x > 0]
    if not xs:
        return None
    g = 1.0
    for x in xs:
        g *= x
    return g ** (1 / len(xs))


def collect_kernel_benches() -> dict[str, list[dict]]:
    """results/performance/kernels-<arch>-<label>/ -> {lang: [bench sets, oldest first]}."""
    out: dict[str, list[dict]] = {l: [] for l in ASM}
    for d in sorted((ROOT / "results/performance").glob("kernels-*")):
        bf = d / "bench.jsonl"
        if not bf.exists():
            continue
        arch, _, label = d.name[len("kernels-"):].partition("-")
        meta = load_json(d / "meta.json") or {"label": label, "measured": ""}
        rows = [json.loads(l) for l in bf.read_text().splitlines() if l.strip().startswith("{")]
        host = (load_json(d / "environment.json") or {}).get("hardware", {}).get("model") or \
            (load_json(d / "arm-host.json") or {}).get("hostname")
        out[KARCH[arch]].append({"label": meta["label"], "measured": meta.get("measured", ""), "ref": meta.get("ref"),
                                 "source": str(d.relative_to(ROOT)), "host": host,
                                 "ns_per_elem": {(r["variant"], r["kernel"]): r["ns_per_elem"] for r in rows},
                                 "codesize": load_json(d / "codesize.json")})
    for l in out:
        out[l].sort(key=lambda b: b["measured"])
    return out


def bench_speedup(before: dict, after: dict, variant: str) -> dict:
    """Per-kernel speedup before/after for one variant (>1 = faster) and the geomean."""
    ks = sorted({k for v, k in after["ns_per_elem"] if v == variant and (variant, k) in before["ns_per_elem"]})
    per = {k: before["ns_per_elem"][(variant, k)] / after["ns_per_elem"][(variant, k)] for k in ks
           if after["ns_per_elem"][(variant, k)] > 0}
    return {"variant": variant, "before": before["source"], "after": after["source"],
            "per_kernel": {k: round(v, 3) for k, v in per.items()}, "geomean": geomean(list(per.values())),
            "slower_kernels": sorted(k for k, v in per.items() if v < 0.95)}


def collect_kernels() -> dict:
    benches = collect_kernel_benches()
    out = {}
    for l in ASM:
        corr = load_json(ROOT / "results/correctness" / f"{l}.json")
        bs = benches[l]
        latest = bs[-1] if bs else None
        perf = None
        if latest:
            variants = sorted({v for v, _ in latest["ns_per_elem"]})
            perf = {"source": latest["source"], "label": latest["label"], "host": latest["host"],
                    "ns_per_elem": {v: {k: x for (vv, k), x in latest["ns_per_elem"].items() if vv == v} for v in variants},
                    # speedup of each variant over the C reference (same binary, same run)
                    "speedup_vs_reference": {v: geomean([latest["ns_per_elem"][("reference", k)] / x
                                                         for (vv, k), x in latest["ns_per_elem"].items()
                                                         if vv == v and ("reference", k) in latest["ns_per_elem"] and x > 0])
                                             for v in variants if v != "reference"}}
        by_label = {b["label"]: b for b in bs}
        pairs = {}
        for name, (a, b) in {"kernel-optimize": ("before-optimize", "after-optimize"),
                             "kernel-refactor": ("before-refactor", "after-refactor"),
                             "kernel-change-i128": ("before-change", "after-change")}.items():
            if a in by_label and b in by_label:
                pairs[name] = bench_speedup(by_label[a], by_label[b], SIMD_VARIANT[l])
        out[l] = {"correctness": {"summary": (corr or {}).get("summary"), "variants": (corr or {}).get("variants"),
                                  "variants_emulated": (corr or {}).get("variants_emulated"),
                                  "suites": (corr or {}).get("suites"), "commit": (corr or {}).get("commit"),
                                  "source": f"results/correctness/{l}.json" if corr else None},
                  "performance": perf, "codesize": latest["codesize"] if latest else None,
                  "before_after": pairs}
    return out


def collect_reviews() -> dict:
    out: dict[str, dict] = {}
    for f in sorted((ROOT / "results/development/code-review").glob("*-[AB].json")):
        d = load_json(f) or {}
        if d.get("language") and d.get("scores"):
            out.setdefault(d["language"], {})[d.get("reviewer", f.stem[-1])] = d["scores"]
    return {l: {"reviewers": r, "mean": {c: sum(x[c] for x in r.values()) / len(r) for c in next(iter(r.values()))}}
            for l, r in out.items()}


def latest_merged_run(lang: str) -> Path | None:
    """Run directory of the engine's latest successful Track A run (its validation records)."""
    best = None
    for m in RUNS.glob(f"a-*-{lang}-a*/manifest.json"):
        man = load_json(m) or {}
        if man.get("language") == lang and man.get("outcome") == "success" and not man.get("task", "").startswith("debug"):
            key = (load_json(m.parent / "validation.json") or {}).get("validated_at") or ""
            if best is None or key > best[0]:
                best = (key, m.parent)
    return best[1] if best else None


def collect_suites() -> dict:
    """Additional suites per engine; a missing entry carries the reason instead of a value."""
    out = {}
    interop = load_json(ROOT / "results/correctness/interop-asm-engine.json") or load_json(ROOT / "results/correctness/interop.json") or {}
    interop_engines = (interop.get("summary") or {}).get("engines") or []
    for l in LANGS + ASM_ENGINES:
        rc = ROOT / "results/correctness"
        run = latest_merged_run(l) if l in ASM_ENGINES else None
        http = load_json(rc / f"{l}-http.json") or (load_json(run / "http-suite.json") if run else None)
        modes = load_json(rc / f"{l}-modes.json") or (load_json(run / "conformance-modes.json") if run else None)
        crash = load_json(rc / f"{l}-crash.json")
        fuzz = load_json(rc / f"{l}-fuzz.json")
        native = load_json(rc / f"{l}-native.json")
        probe = load_json(rc / "robustness" / f"{l}.json")
        e: dict = {}
        hs = (http or {}).get("summary") or {}
        e["http_suite"] = {"value": f"{hs['passed']}/{hs['total']}", "ok": hs["passed"] == hs["total"]} if hs else \
            {"missing": "not run"}
        mt = ((modes or {}).get("summary") or {}).get("total") or {}
        e["execution_modes"] = {"value": f"{mt['pass']}/{mt['total']}", "ok": mt["pass"] == mt["total"]} if mt else \
            {"missing": "not run"}
        cs = (crash or {}).get("summary")
        e["crash_safety"] = ({"value": f"{cs['violations']} violations / {cs['iterations']} kills", "ok": cs["violations"] == 0}
                             if cs else {"missing": "not run yet for the assembly engines (the six engines ran it after Phase 3)"
                                         if l in ASM_ENGINES else "not run"})
        e["fuzz"] = ({"value": f"{len(fuzz['problems'])} problems / {fuzz['inputs']:,} inputs", "ok": not fuzz["problems"]}
                     if fuzz else {"missing": "not run yet for the assembly engines" if l in ASM_ENGINES else "not run"})
        e["pqcf_interop"] = ({"value": "all files read by all engines" if interop.get("summary", {}).get("passed") else "failures",
                              "ok": bool(interop.get("summary", {}).get("passed"))} if l in interop_engines else
                             {"missing": "runs only on the ARM host; the interop matrix is built on the x86 host"
                              if l == "arm64-asm-engine" else "not run"})
        e["native_kernels"] = ({"value": "pass" if all((native.get("phase_passed") or {}).values()) else "fail",
                                "ok": all((native.get("phase_passed") or {}).values())} if native else
                               {"missing": "not applicable: the assembly engines do not load the kernel library"
                                if l in ASM_ENGINES else "not run"})
        if probe:
            pr = probe["probes"]

            def verdicts(v: dict) -> list[str]:
                return [v["verdict"]] if "verdict" in v else [x.get("verdict") for x in v.values() if isinstance(x, dict)]
            lim = pr.get("expression_limits")
            pr = {n: v for n, v in pr.items() if n != "expression_limits"}
            fails = sorted(n for n, v in pr.items() if "fail" in verdicts(v))
            e["robustness_probes"] = {"value": ("fail: " + ", ".join(fails)) if fails else f"no failures ({len(pr)} probes)",
                                      "ok": not fails}
            if lim and "minimum" in lim:
                mn, by = lim["minimum"], lim["beyond"]
                tag = "" if lim.get("claims_capability") else " (informational)"
                e["expression_limits"] = {
                    "value": f"minimums {sum(x['pass'] for x in mn.values())}/{len(mn)}, "
                             f"beyond {sum(x['pass'] for x in by.values())}/{len(by)}{tag}",
                    "ok": lim["verdict"] == "pass"}
            else:
                e["expression_limits"] = {"missing": "probe not run"}
        else:
            e["robustness_probes"] = {"missing": "probe run in progress"}
            e["expression_limits"] = {"missing": "probe not run"}
        out[l] = e
    return out


# ------------------------------------------------------------------ analysis

def latest_by(runs: list[dict], lang: str, task: str) -> list[dict]:
    return [r for r in runs if r["language"] == lang and r["task"] == task]


def pareto(points: dict[str, tuple[float, float, float]]) -> list[str]:
    """Points: name -> (dev_cost, -correctness, latency). Lower is better in every dimension."""
    front = []
    for a, pa in points.items():
        dominated = any(all(pb[i] <= pa[i] for i in range(3)) and any(pb[i] < pa[i] for i in range(3))
                        for b, pb in points.items() if b != a)
        if not dominated:
            front.append(a)
    return front


def build(weights: dict) -> dict:
    runs = collect_runs()
    corr = collect_correctness()
    perf = collect_performance()
    tasks = sorted({r["task"] for r in runs})
    langs_all = LANGS + ASM + ASM_ENGINES
    kern = collect_kernels()
    reviews = collect_reviews()

    # 1. correctness
    correctness = {l: corr.get(l, {"summary": None}) for l in LANGS}
    # 2. development effort (per task, all attempts incl. failures)
    dev = {}
    for l in langs_all:
        for t in tasks:
            rs = latest_by(runs, l, t)
            if not rs:
                continue
            dev.setdefault(l, {})[t] = [{
                "run_id": r["run_id"], "attempt": r["attempt"], "outcome": r["outcome"], "manifest": r["manifest"],
                "cost_usd": r["telemetry"].get("cost_usd"),
                "tokens_output": (r["telemetry"].get("tokens") or {}).get("output"),
                "tokens_input_total": sum(v or 0 for k, v in (r["telemetry"].get("tokens") or {}).items()
                                          if k in ("input", "cache_read", "cache_creation")),
                "turns": r["telemetry"].get("agent_turns"),
                "wall_seconds": (r["telemetry"].get("time") or {}).get("wall_seconds"),
                "tool_calls": r["telemetry"].get("tool_calls_total"),
                "tool_failures": r["telemetry"].get("tool_failures"),
                "build_failures": r["telemetry"].get("build_failures_heuristic"),
                "repair_iterations": r["telemetry"].get("repair_iterations"),
                "commits": (r["telemetry"].get("git") or {}).get("commits"),
                "lines_added": (r["telemetry"].get("git") or {}).get("lines_added"),
                "lines_removed": (r["telemetry"].get("git") or {}).get("lines_removed"),
                "files_changed": (r["telemetry"].get("git") or {}).get("files_changed"),
                "conformance": (r["validation"].get("summary") or {}).get("total"),
            } for r in rs]
    # 3/4/6. performance, resources, optimization (latest benchmark per scale)
    perf_rep, asm_perf, asm_perf_by_scale = [], {}, {}
    for p in perf:
        meta = p["meta"]
        # Before/after benchmarks measure task branches (some never merged): they belong to report 6
        # only. Track B benchmarks never enter the Track A reports 3, 4 and 8.
        # Labels are "[arm-]before-<task>" / "[arm-]after-<task>" directly after the scale; a label that only
        # contains the word (e.g. "main-after-reruns") is a regular benchmark.
        if re.search(r"-\d+[km]-(arm-)?(before|after)-[a-z-]+$", meta["bench_id"]) or meta.get("track", "A") != "A":
            continue
        entry = {"bench_id": meta["bench_id"], "scale": meta["scale"], "track": meta.get("track"), "source": p["_path"],
                 "host_cpu": None, "engines": {}}
        env = load_json(ROOT / Path(p["_path"]).parent / "environment.json") or {}
        entry["host_cpu"] = (env.get("hardware") or {}).get("model")
        entry["host_arch"] = (env.get("hardware") or {}).get("arch")
        arm = load_json(ROOT / Path(p["_path"]).parent / "arm-host.json")
        if arm and not entry["host_cpu"]:  # /proc/cpuinfo on AArch64 has no model name
            models = sorted({ln.split()[1] for ln in arm.get("cpus", "").splitlines()[1:] if len(ln.split()) > 1})
            entry["host_cpu"] = f"{arm.get('hostname')} ({'/'.join(models)})"
        for l, r in p["results"].items():
            q = {n: v["latency_seconds"]["median"] for n, v in (r.get("queries") or {}).items()
                 if v.get("status") == "ok" and v["latency_seconds"].get("n")}
            entry["engines"][l] = {
                "status": r.get("status"), "error": r.get("error"), "median_latency_by_query": q,
                "queries_ok": len(q), "startup_median_s": (r.get("startup_seconds") or {}).get("median"),
                "peak_rss_mib": ((r.get("memory") or {}).get("peak_tree_rss_bytes") or 0) / 2**20 or None,
                "ingest_mb_s": {t: v.get("mb_per_s") for t, v in (r.get("ingest") or {}).items()},
                "query_cpu_s": r.get("query_phase_cpu_seconds"), "query_wall_s": r.get("query_phase_wall_seconds"),
                "storage": r.get("storage"), "thread_scaling": r.get("thread_scaling"), "modes": r.get("modes"),
                "joins": r.get("joins"), "http": r.get("http")}
        # Assembly engines are a separate cohort: their figures never enter the six-engine tables,
        # rankings or Pareto front (the latest benchmark per engine is kept for the cohort section).
        for l in ASM_ENGINES:
            if l in entry["engines"]:
                e = {**entry["engines"][l], "bench_id": entry["bench_id"], "scale": entry["scale"],
                     "source": entry["source"], "host_cpu": entry["host_cpu"], "host_arch": entry["host_arch"]}
                asm_perf_by_scale.setdefault(entry["scale"], {})[l] = e
                if entry["scale"] == PRIMARY_SCALE:
                    asm_perf[l] = e
        entry["engines"] = {l: e for l, e in entry["engines"].items() if l in LANGS}
        if entry["engines"]:
            perf_rep.append(entry)
    # 5. code quality: automated metrics + rubric review scores (AI reviewers, labelled as such)
    quality = {l: {**(code_metrics(l) or {}), "rubric_review": reviews.get(l)} for l in langs_all}
    # 7. architectural adaptability: change-task runs (engines and kernel cohort)
    adapt = {l: {t: v for t, v in d.items()
                 if t.startswith(("change", "refactor", "debug", "regress", "optimize", "kernel-"))}
             for l, d in dev.items()}

    # capability matrix (the assembly engines get columns; the kernel libraries claim no engine capabilities)
    matrix = {l: (corr.get(l) or {}).get("capabilities") or [] for l in LANGS + ASM_ENGINES}

    # 8. overall: correctness-gated weighted score per language (only where data exist)
    overall = {}
    cost = {l: sum((a["cost_usd"] or 0) for t in dev.get(l, {}).values() for a in t) for l in LANGS}
    for l in LANGS:
        s = (corr.get(l) or {}).get("summary") or {}
        tot = (s.get("total") or {})
        pass_rate = tot.get("pass", 0) / tot["total"] if tot.get("total") else None
        overall[l] = {"pass_rate": pass_rate, "dev_cost_usd": cost.get(l) or None,
                      "correctness_gate": bool(pass_rate == 1.0)}
    pts = {}
    if perf_rep:
        last = perf_rep[-1]
        for l, e in last["engines"].items():
            med = e["median_latency_by_query"]
            if med and overall.get(l, {}).get("pass_rate") is not None and overall[l]["dev_cost_usd"]:
                geo = 1.0
                for v in med.values():
                    geo *= max(v, 1e-6)
                geo **= 1 / len(med)
                overall[l]["geomean_latency_s"] = geo
                pts[l] = (overall[l]["dev_cost_usd"], -overall[l]["pass_rate"], geo)
    front = pareto(pts) if pts else []
    # Kernel cohort (8): correctness gate, development cost, SIMD throughput on its own hardware.
    # x86 and ARM kernels run on different machines: reported side by side, never ranked.
    kernel_overall = {}
    for l in ASM:
        k = kern[l]
        simd = SIMD_VARIANT[l]
        kernel_overall[l] = {
            "correctness_gate": bool(((k["correctness"] or {}).get("summary") or {}).get("all_pass")),
            "dev_cost_usd": sum((a["cost_usd"] or 0) for t in dev.get(l, {}).values() for a in t) or None,
            "simd_variant": simd,
            "simd_geomean_ns_per_elem": geomean(list(((k["performance"] or {}).get("ns_per_elem") or {}).get(simd, {}).values())),
            "simd_speedup_vs_reference": ((k["performance"] or {}).get("speedup_vs_reference") or {}).get(simd),
            "host": (k["performance"] or {}).get("host")}
    asm_overall = {}
    for l in ASM_ENGINES:
        tot = ((corr.get(l) or {}).get("summary") or {}).get("total") or {}
        e = asm_perf.get(l) or {}
        asm_overall[l] = {
            "correctness_gate": bool(tot.get("total") and tot.get("pass") == tot.get("total")),
            "dev_cost_usd": sum((a["cost_usd"] or 0) for t in dev.get(l, {}).values() for a in t) or None,
            "geomean_latency_s": geomean(list((e.get("median_latency_by_query") or {}).values())),
            "bench_id": e.get("bench_id"), "host_cpu": e.get("host_cpu"), "host_arch": e.get("host_arch")}
    return {"generated": dt.datetime.now(dt.timezone.utc).isoformat(), "weights": weights,
            "git_commit": subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip(),
            "runs": [{k: v for k, v in r.items() if k not in ("telemetry", "validation")} for r in runs],
            "capability_matrix": matrix, "reports": {
                "1_functional_correctness": {**correctness, "kernel_cohort": {l: kern[l]["correctness"] for l in ASM},
                                             "asm_engine_cohort": {l: corr.get(l) for l in ASM_ENGINES}},
                "2_development_effort": dev,
                "3_runtime_performance": perf_rep,
                "3_runtime_performance_kernel_cohort": {l: kern[l]["performance"] for l in ASM},
                "3_runtime_performance_asm_engine_cohort": asm_perf,
                "3_runtime_performance_asm_engine_cohort_by_scale": asm_perf_by_scale,
                "4_resource_efficiency": [
                    {"bench_id": p["bench_id"], "engines": {l: {k: e[k] for k in ("peak_rss_mib", "query_cpu_s", "query_wall_s", "startup_median_s", "ingest_mb_s")}
                                                          for l, e in p["engines"].items()}} for p in perf_rep],
                "4_resource_efficiency_kernel_cohort": {
                    l: {"text_bytes_per_source": kern[l]["codesize"],
                        "note": "Kernels never allocate (ABI rule); resource figures are machine-code size and time per element."}
                    for l in ASM},
                "1b_additional_suites": collect_suites(),
                "5_code_quality": quality, "6_optimization_effectiveness": [
                    {"bench_id": p["bench_id"], "engines": {l: {k: e[k] for k in ("modes", "joins", "thread_scaling")}
                                                          for l, e in p["engines"].items()}} for p in perf_rep],
                "6_optimization_task_before_after": collect_task_before_after(),
                "6_optimization_task_before_after_asm_engine_cohort": collect_task_before_after(ASM_TASK_BEFORE_AFTER),
                "6_optimization_effectiveness_kernel_cohort": {
                    l: {"simd_and_scalar_speedup_vs_reference": (kern[l]["performance"] or {}).get("speedup_vs_reference"),
                        "independent_before_after": kern[l]["before_after"]} for l in ASM},
                "7_architectural_adaptability": adapt, "8_overall": {"per_language": overall, "pareto_front": front,
                                                                      "note": "Correctness-gated: a language without a 100% pass rate is never ranked above one with 100%. Track A and Track B are never combined.",
                                                                      "kernel_cohort": kernel_overall,
                                                                      "asm_engine_cohort": asm_overall,
                                                                      "asm_engine_cohort_note": "Complete engines in assembly (ADR-0016 option B): a separate cohort, never ranked with the six engines; x86-64 and AArch64 are benchmarked on different machines and are not ranked against each other.",
                                                                      "kernel_cohort_note": "Assembly kernels are a separate cohort (ADR-0016), never ranked with the engines; x86-64 and AArch64 are measured on different machines and are not ranked against each other."}}}


# ------------------------------------------------------------------ rendering

PRIMARY_SCALE = "1m"   # headline charts: the scale every engine has been benchmarked at


def scale_rows(scale: str) -> int:
    n, unit = int(scale[:-1]), scale[-1]
    return n * {"k": 10**3, "m": 10**6}[unit]


def scale_charts(R: dict, lbl: dict) -> list[str]:
    """Latency and memory at each larger scale (latest benchmark per scale), with the reason an engine has no data."""
    out = []
    # Benchmarks of one scale are merged, latest per engine (e.g. a single-engine re-run fills a gap).
    by_scale: dict[str, dict] = {}
    for p in R["3_runtime_performance"]:
        m = by_scale.setdefault(p["scale"], {"bench_id": p["bench_id"], "engines": {}})
        m["engines"].update(p["engines"])
        m["bench_id"] = ", ".join(dict.fromkeys([*m["bench_id"].split(", "), p["bench_id"]]))
    asm_by = R.get("3_runtime_performance_asm_engine_cohort_by_scale") or {}
    for s in sorted((s for s in by_scale if scale_rows(s) > scale_rows(PRIMARY_SCALE)), key=scale_rows):
        p = by_scale[s]
        eng = {**p["engines"], **asm_by.get(s, {})}
        miss = {l: f"{e.get('status')}: {e.get('error') or 'no successful query'}" for l, e in eng.items()
                if not e.get("median_latency_by_query")}
        note = (f"{s} rows ({p['bench_id']}). Same workload and settings as the {PRIMARY_SCALE} charts. The AArch64 engine "
                "runs on the ARM host: not comparable with the x86 bars.")
        out.append(bar_chart(f"Query latency at {s} rows, geometric mean of medians", "ms",
                             {l: 1000 * geomean(list(e["median_latency_by_query"].values()))
                              if e.get("median_latency_by_query") else None for l, e in eng.items()},
                             lambda v: f"{v:,.2f}", missing=miss, note=note, labels=lbl))
        out.append(bar_chart(f"Peak resident memory at {s} rows (engine process tree)", "MiB",
                             {l: e["peak_rss_mib"] for l, e in eng.items()}, lambda v: f"{v:,.0f}",
                             missing=miss, labels=lbl))
    return out


def bar_chart(title: str, unit: str, data: dict[str, float | None], fmt=lambda v: f"{v:,.1f}",
              missing: dict[str, str] | None = None, note: str = "", labels: dict[str, str] | None = None) -> str:
    """Horizontal bars; `missing` lists entries without data and why (shown as rows, never as zero bars)."""
    items = [(k, v) for k, v in data.items() if v is not None]
    gaps = [(k, r) for k, r in (missing or {}).items() if data.get(k) is None]
    gaps += [(k, "not recorded yet") for k, v in data.items() if v is None and k not in (missing or {})]
    lab = labels or {}
    note_html = f'<p class="muted note">{html.escape(note)}</p>' if note else ""
    if not items and not gaps:
        return f'<figure class="chart"><figcaption>{html.escape(title)}</figcaption><p class="muted">No data recorded yet.</p></figure>'
    w, bh, gap, left = 640, 22, 8, 150
    h = (len(items) + len(gaps)) * (bh + gap) + 10
    mx = max((v for _, v in items), default=1) or 1
    rows = []
    for i, (k, v) in enumerate(items):
        y = i * (bh + gap) + 4
        bw = max(2, (w - left - 90) * v / mx)
        rows.append(
            f'<g class="bar"><title>{html.escape(lab.get(k, k))}: {fmt(v)} {html.escape(unit)}</title>'
            f'<text x="{left - 8}" y="{y + bh * 0.7}" text-anchor="end" class="lbl">{html.escape(lab.get(k, k))}</text>'
            f'<rect x="{left}" y="{y}" width="{bw:.1f}" height="{bh}" rx="4" style="fill:var(--c-{k})"/>'
            f'<text x="{left + bw + 6}" y="{y + bh * 0.7}" class="val">{fmt(v)}</text></g>')
    for j, (k, r) in enumerate(gaps):
        y = (len(items) + j) * (bh + gap) + 4
        rows.append(f'<g><title>{html.escape(k)}: {html.escape(r)}</title>'
                    f'<text x="{left - 8}" y="{y + bh * 0.7}" text-anchor="end" class="lbl">{html.escape(lab.get(k, k))}</text>'
                    f'<text x="{left + 6}" y="{y + bh * 0.7}" class="val">n/a — {html.escape(r[:62] + ("… (see table)" if len(r) > 62 else ""))}</text></g>')
    table = "".join(f"<tr><td>{html.escape(lab.get(k, k))}</td><td>{fmt(v)}</td></tr>" for k, v in items)
    table += "".join(f"<tr><td>{html.escape(lab.get(k, k))}</td><td class='muted'>n/a — {html.escape(r)}</td></tr>" for k, r in gaps)
    return (f'<figure class="chart"><figcaption>{html.escape(title)} <span class="muted">({html.escape(unit)})</span></figcaption>{note_html}'
            f'<svg viewBox="0 0 {w} {h}" role="img" aria-label="{html.escape(title)}">'
            f'<line x1="{left}" y1="0" x2="{left}" y2="{h}" class="axis"/>{"".join(rows)}</svg>'
            f'<details><summary>Table</summary><table><tr><th>Language</th><th>{html.escape(unit)}</th></tr>{table}</table></details></figure>')


def render_asm_engine_cohort(R: dict) -> str:
    """Option-B cohort: complete engines in assembly, reported next to (never ranked with) the six engines."""
    corr = R["1_functional_correctness"].get("asm_engine_cohort") or {}
    dev, q = R["2_development_effort"], R["5_code_quality"]
    rows = []
    for l in ASM_ENGINES:
        c = corr.get(l) or {}
        tot = (c.get("summary") or {}).get("total") or {}
        for t in sorted(t for t in (dev.get(l) or {}) if t.startswith("phase")):
            atts = dev[l][t]
            cost = sum(a["cost_usd"] or 0 for a in atts)
            wall = sum(a["wall_seconds"] or 0 for a in atts) / 60
            rows.append(f"<tr><td>{html.escape(l)}</td><td>{t}</td><td>{len(atts)}</td>"
                        f"<td class='o-{atts[-1]['outcome']}'>{atts[-1]['outcome']}</td><td>{cost:.2f}</td><td>{wall:.0f}</td>"
                        f"<td>{sum(a['turns'] or 0 for a in atts)}</td></tr>")
        m = q.get(l) or {}
        rows.append(f"<tr><td colspan='7' class='muted'>{html.escape(l)}: conformance (claimed capabilities, with hidden on "
                    f"AArch64) {tot.get('pass', '—')}/{tot.get('total', '—')}; source LOC {m.get('source_loc', '—')}, "
                    f"test LOC {m.get('test_loc', '—')}, files {m.get('files', '—')}</td></tr>")
    return ("<h2>Assembly engine cohort (option B, ADR-0016)</h2><p class='muted'>Complete engines written in x86-64 and "
            "AArch64 assembly (glibc only, no C) through the same black-box spec and suites. A separate cohort: never "
            "ranked with the six engines, and the two architectures are developed and validated on different machines. "
            "A phase may take several sessions of at most 120 minutes; each session is one attempt row.</p>"
            "<table><tr><th>engine</th><th>phase</th><th>sessions</th><th>outcome</th><th>cost USD</th><th>wall min</th>"
            f"<th>turns</th></tr>{''.join(rows)}</table>" + render_asm_engine_reports(R))


def render_asm_engine_reports(R: dict) -> str:
    """Reports 2-8 for the assembly-engine cohort (later families, rubric, benchmarks, overall)."""
    def f(v, fmt="{:,.2f}"):
        return "—" if v is None else fmt.format(v)
    dev, parts = R["2_development_effort"], []
    rows = [f"<tr><td>{html.escape(l)}</td><td>{html.escape(t)}</td><td>{len(atts)}</td>"
            f"<td class='o-{atts[-1]['outcome']}'>{atts[-1]['outcome']}</td><td>{sum(a['cost_usd'] or 0 for a in atts):.2f}</td>"
            f"<td>{sum(a['wall_seconds'] or 0 for a in atts) / 60:.0f}</td>"
            f"<td>{f(sum(a['lines_added'] or 0 for a in atts), '{:,}')} / {f(sum(a['lines_removed'] or 0 for a in atts), '{:,}')}</td></tr>"
            for l in ASM_ENGINES for t, atts in sorted((dev.get(l) or {}).items()) if not t.startswith("phase")]
    if rows:
        parts.append("<h3>2/7. Later families (change, refactoring, debugging, optimization)</h3><p class='muted'>Same tasks "
                     "and order as the six engines; the native-kernel option is left out of the task text because the "
                     "assembly engines do not load the kernel library. Each family is one chain of at most two sessions.</p>"
                     "<table><tr><th>engine</th><th>task</th><th>sessions</th><th>outcome</th><th>cost USD</th><th>wall min</th>"
                     "<th>lines +/−</th></tr>" + "".join(rows) + "</table>")
    perf = {f"{l} ({s})": e for s, d in sorted((R.get("3_runtime_performance_asm_engine_cohort_by_scale") or {}).items(),
                                               key=lambda x: scale_rows(x[0])) for l, e in d.items()}
    if perf:
        body = "".join(
            f"<tr><td>{html.escape(l)}</td><td>{html.escape(str(e.get('host_cpu')))}</td>"
            f"<td>{f(geomean(list(e['median_latency_by_query'].values())), '{:.4f}') if e['median_latency_by_query'] else '—'}</td>"
            f"<td>{e['queries_ok']}</td><td>{f((e['startup_median_s'] or 0) * 1000 or None, '{:,.1f}')}</td>"
            f"<td>{f(e['peak_rss_mib'], '{:,.0f}')}</td>"
            f"<td>{' / '.join(f(((e.get('http') or {}).get(c) or {}).get('qps'), '{:,.0f}') for c in ('1', '4', '16'))}</td>"
            f"<td><a href='../../{html.escape(e['source'])}'>{html.escape(e['bench_id'])}</a></td></tr>"
            for l, e in perf.items())
        parts.append("<h3>3/4. Runtime performance and resources</h3><p class='muted'>Same harness, workload, scales "
                     "(1m and 10m rows), repetitions and CPU pinning as the six engines. x86-64 on the quiet x86 host, AArch64 natively on the "
                     "ARM host: the two rows are not comparable with each other.</p><table><tr><th>engine</th><th>host</th>"
                     "<th>geomean latency s</th><th>queries ok</th><th>startup ms</th><th>peak RSS MiB</th>"
                     "<th>HTTP q/s (1/4/16 clients)</th><th>benchmark</th></tr>" + body + "</table>")
    if R.get("6_optimization_task_before_after_asm_engine_cohort"):
        parts.append("<h3>6. Optimization task, measured independently</h3><p class='muted'>Shown with the six engines "
                     "in the report-6 section above.</p>")
    ov = R["8_overall"].get("asm_engine_cohort") or {}
    parts.append("<h3>8. Overall (assembly-engine cohort, not ranked)</h3><p class='muted'>"
                 + html.escape(R["8_overall"].get("asm_engine_cohort_note", "")) + "</p><table><tr><th>engine</th>"
                 "<th>correctness gate</th><th>agent cost USD (all tasks)</th><th>geomean latency s</th><th>host</th></tr>" + "".join(
                     f"<tr><td>{html.escape(l)}</td><td>{'pass' if o['correctness_gate'] else 'fail'}</td>"
                     f"<td>{f(o['dev_cost_usd'])}</td><td>{f(o['geomean_latency_s'], '{:.4f}')}</td>"
                     f"<td>{html.escape(str(o['host_cpu'] or '—'))}</td></tr>" for l, o in ov.items()) + "</table>")
    return "".join(parts)


def render_kernel_cohort(R: dict) -> str:
    """Kernel cohort (assembly languages) across reports 1-8; never ranked with the engines."""
    def f(v, fmt="{:.3f}"):
        return "—" if v is None else fmt.format(v)
    parts = ['<h2>Kernel cohort: x86-64 and AArch64 assembly (reports 1–8)</h2>',
             '<p class="muted">The assembly languages implement the native kernels, not complete engines (ADR-0016). '
             'Their results are shown next to the engines in every report but never ranked with them, and x86-64 and '
             'AArch64 are measured on different machines (x86-64: the quiet Zen 5 host; AArch64: the GB10 ARM host), '
             'so they are not ranked against each other either. Development effort and the change, refactoring, '
             'debugging and optimization runs appear in the charts and the adaptability table above.</p>']
    rows = []
    for l, c in R["1_functional_correctness"]["kernel_cohort"].items():
        for v, x in sorted(((c or {}).get("variants") or {}).items()):
            rows.append(f"<tr><td>{html.escape(l)}</td><td>{html.escape(v)}</td><td>{x['provided']}/{x['total']}</td>"
                        f"<td>{x.get('public', '—')}</td><td>{x.get('asan', '—')}</td><td>{x.get('hidden', '—')}</td>"
                        f"<td><a href='../../{html.escape(c.get('source') or '')}'>record</a></td></tr>")
    parts.append("<h3>1. Correctness</h3><p class='muted'>Differential tests against the C reference, the ASan/UBSan "
                 "build and the hidden acceptance tests; AArch64 natively on the ARM host.</p><table><tr><th>language</th>"
                 "<th>variant</th><th>kernels</th><th>public</th><th>ASan/UBSan</th><th>hidden</th><th></th></tr>"
                 + "".join(rows) + "</table>")
    for l, p in R["3_runtime_performance_kernel_cohort"].items():
        if not p:
            continue
        vs = list(p["ns_per_elem"])
        ks = sorted({k for v in vs for k in p["ns_per_elem"][v]})
        body = "".join(f"<tr><td>{html.escape(k)}</td>" + "".join(f"<td>{f(p['ns_per_elem'][v].get(k))}</td>" for v in vs)
                       + "</tr>" for k in ks)
        parts.append(f"<h3>3. Throughput — {html.escape(l)} on {html.escape(str(p['host']))}</h3>"
                     f"<p class='muted'>Median ns per element, 4M elements, 15 repetitions, one pinned core "
                     f"(<a href='../../{html.escape(p['source'])}'>{html.escape(p['source'])}</a>). Lower is better.</p>"
                     f"<table><tr><th>kernel</th>{''.join(f'<th>{html.escape(v)}</th>' for v in vs)}</tr>{body}</table>")
    cs = R["4_resource_efficiency_kernel_cohort"]
    parts.append("<h3>4. Resources</h3><p class='muted'>" + html.escape(next(iter(cs.values()))["note"]) + "</p><table>"
                 "<tr><th>language</th><th>source</th><th>.text bytes</th></tr>" + "".join(
                     f"<tr><td>{html.escape(l)}</td><td>{html.escape(src)}</td><td>{n:,}</td></tr>"
                     for l, c in cs.items() for src, n in sorted((c["text_bytes_per_source"] or {}).items())) + "</table>")
    q = R["5_code_quality"]
    parts.append("<h3>5. Code quality</h3><table><tr><th>language</th><th>source LOC</th><th>files</th><th>comment density</th>"
                 "<th>largest file LOC</th></tr>" + "".join(
                     f"<tr><td>{html.escape(l)}</td><td>{f((q.get(l) or {}).get('source_loc'), '{:,}')}</td>"
                     f"<td>{f((q.get(l) or {}).get('files'), '{}')}</td><td>{f((q.get(l) or {}).get('comment_density'), '{:.2f}')}</td>"
                     f"<td>{f((q.get(l) or {}).get('largest_file_loc'), '{:,}')}</td></tr>" for l in ASM) +
                 "</table><p class='muted'>Rubric scores for the assembly kernels are in the rubric table above.</p>")
    o = R["6_optimization_effectiveness_kernel_cohort"]
    rows = []
    for l, x in o.items():
        for v, g in sorted((x["simd_and_scalar_speedup_vs_reference"] or {}).items()):
            rows.append(f"<tr><td>{html.escape(l)}</td><td>{html.escape(v)} vs C reference</td><td>{f(g, '{:.2f}')}×</td><td>—</td></tr>")
        for task, ba in x["independent_before_after"].items():
            rows.append(f"<tr><td>{html.escape(l)}</td><td>{html.escape(task)}: {html.escape(ba['variant'])} before → after</td>"
                        f"<td>{f(ba['geomean'], '{:.2f}')}×</td><td>{html.escape(', '.join(ba['slower_kernels']) or 'none')}</td></tr>")
    parts.append("<h3>6. Optimization effectiveness</h3><p class='muted'>Geometric-mean speedup over the benchmarked kernels "
                 "(>1 = faster). Before/after pairs are measured independently after the agent run; slower = kernels more "
                 "than 5% slower.</p><table><tr><th>language</th><th>comparison</th><th>geomean</th><th>slower kernels</th></tr>"
                 + "".join(rows) + "</table>")
    ko = R["8_overall"]["kernel_cohort"]
    parts.append("<h3>8. Overall (kernel cohort, not ranked)</h3><p class='muted'>" + html.escape(R["8_overall"]["kernel_cohort_note"])
                 + "</p><table><tr><th>language</th><th>correctness gate</th><th>agent cost USD (all kernel tasks)</th>"
                 "<th>SIMD variant</th><th>geomean ns/elem</th><th>speedup vs C reference</th><th>host</th></tr>" + "".join(
                     f"<tr><td>{html.escape(l)}</td><td>{'pass' if k['correctness_gate'] else 'fail'}</td><td>{f(k['dev_cost_usd'], '{:,.2f}')}</td>"
                     f"<td>{html.escape(k['simd_variant'])}</td><td>{f(k['simd_geomean_ns_per_elem'])}</td>"
                     f"<td>{f(k['simd_speedup_vs_reference'], '{:.2f}')}×</td><td>{html.escape(str(k['host']))}</td></tr>"
                     for l, k in ko.items()) + "</table>")
    return "\n".join(parts)


def render_task_before_after(R: dict) -> str:
    parts = ["<h2>Optimization effectiveness, measured independently (report 6)</h2>",
             "<p class='muted'>Each engine benchmarked at the commit its optimization run started from and at the run's "
             "result, back to back on a quiet host (1m rows, real workload). Speedup = ratio of the geometric means of "
             "the 20 query medians.</p>"]
    asm = R.get("6_optimization_task_before_after_asm_engine_cohort") or []
    for ba in (R.get("6_optimization_task_before_after") or []) + asm:
        rows = "".join(
            f"<tr><td>{html.escape(l)}</td><td>{e['geomean_before_s'] * 1e3:.1f} → {e['geomean_after_s'] * 1e3:.1f} ms</td>"
            f"<td>{e['speedup']:.2f}×</td><td>{html.escape(', '.join(e.get('significantly_slower') or []) or '—')}</td>"
            f"<td>{(e.get('peak_rss_before') or 0) / 2**30:.2f} → {(e.get('peak_rss_after') or 0) / 2**30:.2f} GiB</td></tr>"
            for l, e in sorted(ba["engines"].items(), key=lambda kv: -kv[1]["speedup"]))
        cohort = " (assembly-engine cohort, not ranked with the six engines)" if ba in asm else ""
        parts.append(f"<p><b>{html.escape(ba['note'])}{cohort}</b> — <code>{html.escape(ba['source'])}</code>; result digests "
                     f"identical: {ba['digests_identical']}</p><table><tr><th>engine</th><th>geomean latency</th>"
                     f"<th>speedup</th><th>significantly slower queries</th><th>peak RSS</th></tr>{rows}</table>")
    return "".join(parts)


def render_html(rep: dict) -> str:
    R = rep["reports"]
    dev = R["2_development_effort"]

    def cell(v, f="{:,.2f}") -> str:
        return "—" if v is None else f.format(v)

    adapt_rows = "".join(
        f"<tr><td>{html.escape(t)}</td><td>{html.escape(l)}</td><td>{a['attempt']}</td>"
        f"<td class='o-{html.escape(a['outcome'])}'><a href='../../{html.escape(a['manifest'])}'>{html.escape(a['outcome'])}</a></td>"
        f"<td>{cell(a['cost_usd'])}</td><td>{cell(a['turns'], '{:d}')}</td>"
        f"<td>{cell(None if a['wall_seconds'] is None else a['wall_seconds'] / 60, '{:.1f}')}</td>"
        f"<td>{cell(a['lines_added'], '{:d}')} / {cell(a['lines_removed'], '{:d}')}</td><td>{cell(a['files_changed'], '{:d}')}</td></tr>"
        for t in sorted({t for d in R["7_architectural_adaptability"].values() for t in d})
        for l, d in R["7_architectural_adaptability"].items() for a in d.get(t, []))

    def agg(lang: str, key: str) -> float | None:
        vals = [a[key] for t in dev.get(lang, {}).values() for a in t if a.get(key) is not None]
        return sum(vals) if vals else None

    ALL = LANGS + ASM + ASM_ENGINES
    lbl = {"x86_64-asm": "x86-64 asm kernels", "arm64-asm": "AArch64 asm kernels",
           "x86_64-asm-engine": "x86-64 asm engine", "arm64-asm-engine": "AArch64 asm engine"}
    dev_note = ("Assembly: the kernel libraries (ADR-0016) and the complete assembly engines (option B) are separate "
                "cohorts, shown next to the six engines but never ranked with them.")
    charts = []
    charts.append(bar_chart("Development time (all attempts, all tasks)", "hours",
                            {l: (agg(l, "wall_seconds") or 0) / 3600 or None for l in ALL}, lambda v: f"{v:.2f}",
                            note=dev_note, labels=lbl))
    charts.append(bar_chart("Output tokens (all attempts)", "k tokens",
                            {l: (agg(l, "tokens_output") or 0) / 1000 or None for l in ALL}, lambda v: f"{v:,.0f}", labels=lbl))
    charts.append(bar_chart("Model cost, list-price equivalent", "USD", {l: agg(l, "cost_usd") for l in ALL},
                            lambda v: f"{v:,.2f}", labels=lbl))
    charts.append(bar_chart("Repair iterations", "runs", {l: agg(l, "repair_iterations") for l in ALL},
                            lambda v: f"{v:.0f}", labels=lbl,
                            missing={l: "no repair iterations recorded" for l in ALL if not agg(l, "repair_iterations")}))
    corr = R["1_functional_correctness"]
    asm_corr = corr.get("asm_engine_cohort") or {}

    def pass_rate(c: dict | None) -> float | None:
        t = ((c or {}).get("summary") or {}).get("total") or {}
        return 100 * t.get("pass", 0) / t["total"] if t.get("total") else None
    kc = corr.get("kernel_cohort") or {}
    charts.append(bar_chart(
        "Conformance pass rate (latest report, claimed capabilities)", "%",
        {**{l: pass_rate(corr.get(l)) for l in LANGS}, **{l: pass_rate(asm_corr.get(l)) for l in ASM_ENGINES},
         **{l: None for l in ASM}}, lambda v: f"{v:.1f}", labels=lbl,
        missing={l: "SQL conformance does not apply to a kernel library; kernel suites: "
                    + ("all variants pass" if ((kc.get(l) or {}).get("summary") or {}).get("all_pass") else "see report 1")
                 for l in ASM},
        note="The AArch64 engine's report runs natively on the ARM host and includes the hidden tests (746 cases); "
             "the others are the public suite."))
    asm_perf = R.get("3_runtime_performance_asm_engine_cohort") or {}
    no_sql = "a kernel library runs no SQL workload; kernel throughput (ns/element) is in the kernel cohort, report 3"
    arm_note = ("x86-64 bars: same run on the quiet x86 host. The AArch64 engine is measured on the ARM host "
                "(spark, Cortex-X925): different hardware, shown for completeness, not comparable with the x86 bars. "
                "The six engines have not been benchmarked on the ARM host.")
    if R["3_runtime_performance"]:
        last = ([p for p in R["3_runtime_performance"] if p["scale"] == PRIMARY_SCALE] or R["3_runtime_performance"])[-1]
        eng = {l: e for l in LANGS + ASM_ENGINES if (e := {**last["engines"], **asm_perf}.get(l))}
        geo = {l: (1000 * geomean(list(e["median_latency_by_query"].values()))
                   if e.get("median_latency_by_query") else None) for l, e in eng.items()}
        miss = {l: no_sql for l in ASM}
        miss.update({l: "not benchmarked yet" for l in ASM_ENGINES if l not in asm_perf})
        charts.append(bar_chart(f"Query latency, geometric mean of medians ({last['scale']}, {last['bench_id']})",
                                "ms", {**geo, **{l: None for l in ASM}}, lambda v: f"{v:,.2f}", missing=miss,
                                note=arm_note, labels=lbl))
        charts.append(bar_chart("Peak resident memory (engine process tree)", "MiB",
                                {**{l: e["peak_rss_mib"] for l, e in eng.items()}, **{l: None for l in ASM}},
                                lambda v: f"{v:,.0f}", missing={l: "kernels never allocate (ABI rule); machine-code size "
                                                                   "is in the kernel cohort, report 4" for l in ASM},
                                labels=lbl))
        charts.append(bar_chart("Startup time (spawn → first response)", "ms",
                                {**{l: (e["startup_median_s"] or 0) * 1000 or None for l, e in eng.items()},
                                 **{l: None for l in ASM}}, lambda v: f"{v:,.1f}",
                                missing={l: "a library has no process startup" for l in ASM}, labels=lbl))

        def qps16(e: dict) -> float | None:
            return (((e.get("http") or {}).get("16") or {}).get("qps")) or None
        charts.append(bar_chart("HTTP throughput, 16 concurrent clients", "queries/s",
                                {**{l: qps16(e) for l, e in eng.items()}, **{l: None for l in ASM}},
                                lambda v: f"{v:,.0f}", missing={**{l: "no HTTP server in a kernel library" for l in ASM},
                                                               **{l: "HTTP not measured in the latest benchmark"
                                                                  for l, e in eng.items() if qps16(e) is None}},
                                note="The x86-64 assembly engine forks a snapshot process per query; the AArch64 engine "
                                     "serves each connection from a thread.", labels=lbl))
    charts.append(bar_chart("Source lines of code (automated count)", "LOC",
                            {l: (R["5_code_quality"].get(l) or {}).get("source_loc") for l in ALL},
                            lambda v: f"{v:,.0f}", labels=lbl))
    charts.extend(scale_charts(R, lbl))

    css_vars = "".join(f"--c-{k}:{v};" for k, v in COLORS.items())
    css_dark = "".join(f"--c-{k}:{v};" for k, v in COLORS_DARK.items())
    runs_rows = "".join(
        f"<tr><td>{html.escape(r['language'] or '')}</td><td>{html.escape(r['task'] or '')}</td><td>{r['attempt']}</td>"
        f"<td class='o-{html.escape(r['outcome'])}'>{html.escape(r['outcome'])}</td><td><code>{html.escape(r['manifest'])}</code></td></tr>"
        for r in rep["runs"])
    caps = rep["capability_matrix"]
    cap_langs = LANGS + ASM_ENGINES
    cap_rows = "".join("<tr><td><code>" + c + "</code></td>" + "".join(
        f"<td>{'✔' if c in (caps.get(l) or []) else '·'}</td>" for l in cap_langs) + "</tr>" for c in CAPS_ORDER)
    suites = R.get("1b_additional_suites") or {}
    scols = [("http_suite", "HTTP suite"), ("execution_modes", "execution modes"), ("crash_safety", "crash safety"),
             ("fuzz", "fuzz"), ("pqcf_interop", "PQCF interop"), ("native_kernels", "native kernels"),
             ("robustness_probes", "robustness probes"), ("expression_limits", "CR-6 expression limits")]

    def scell(x: dict) -> str:
        if "missing" in x:
            return f"<td class='muted'>n/a — {html.escape(x['missing'])}</td>"
        return f"<td class='{'o-success' if x['ok'] else 'o-tests_failed'}'>{html.escape(x['value'])}</td>"
    suite_rows = "".join(f"<tr><td>{html.escape(l)}</td>" + "".join(scell(e[k]) for k, _ in scols) + "</tr>"
                         for l, e in suites.items())
    suite_rows += "".join(f"<tr><td>{html.escape(l)}</td><td colspan='{len(scols)}' class='muted'>n/a — a kernel library "
                          "has no protocol, storage or HTTP; its differential, ASan/UBSan and hidden suites are in the "
                          "kernel cohort, report 1</td></tr>" for l in ASM)
    ov = R["8_overall"]
    kernel_html = render_kernel_cohort(R) + render_asm_engine_cohort(R)
    rubric_rows = "".join(
        f"<tr><td>{html.escape(l)}</td>" + "".join(
            f"<td>{' / '.join(str(r[c]) for r in q['rubric_review']['reviewers'].values())}</td>"
            for c in ("architecture", "readability", "robustness", "testability")) + "</tr>"
        for l, q in R["5_code_quality"].items() if (q or {}).get("rubric_review"))
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>PolyQuery Results</title><style>
:root{{color-scheme:light;--bg:#fcfcfb;--fg:#0b0b0b;--muted:#52514e;--grid:#d9d8d4;{css_vars}}}
@media (prefers-color-scheme:dark){{:root:not([data-theme="light"]){{color-scheme:dark;--bg:#1a1a19;--fg:#f0efec;--muted:#c3c2b7;--grid:#3a3a37;{css_dark}}}}}
:root[data-theme="dark"]{{color-scheme:dark;--bg:#1a1a19;--fg:#f0efec;--muted:#c3c2b7;--grid:#3a3a37;{css_dark}}}
body{{background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,sans-serif;margin:0 auto;max-width:980px;padding:24px 16px}}
.muted{{color:var(--muted)}} .chart{{margin:24px 0}} svg{{width:100%;height:auto}} .lbl,.val{{fill:var(--fg);font-size:12px}}
.val{{fill:var(--muted)}} .axis{{stroke:var(--grid)}} table{{border-collapse:collapse;font-size:13px;overflow-x:auto;display:block}}
td,th{{border-bottom:1px solid var(--grid);padding:4px 8px;text-align:left}} figcaption{{font-weight:600}}
.o-success{{color:#008300}} .o-tests_failed,.o-build_failed,.o-timeout,.o-agent_failure{{color:#e34948}}
</style></head><body>
<h1>PolyQuery — comparative results</h1>
<p class="muted">Generated {html.escape(rep['generated'])} from commit <code>{html.escape(rep['git_commit'][:12])}</code>.
Every figure is computed from raw records; each run links to its manifest. Track A (controlled) only unless labelled.
Missing bars mean the measurement has not been run — nothing is estimated.</p>
<h2>Overall (correctness-gated)</h2><p>{html.escape(ov['note'])} Pareto front (dev cost × correctness × latency):
<b>{html.escape(', '.join(ov['pareto_front']) or 'not yet computable')}</b></p>
<p class="muted">The Pareto front covers the six engines only: the assembly kernels and the assembly engines are separate
cohorts (ADR-0016) and appear in every chart below with their values or the reason a value is missing; their overall
tables are in the cohort sections further down.</p>
{''.join(charts)}
<h2>Architectural adaptability (change, refactoring, debugging, optimization tasks)</h2>
<p class="muted">One row per attempt; failed and timed-out attempts are kept. Cost is null when the agent was killed
before reporting it (timeouts). Lines and files count the agent's diff inside its language directory.</p>
<table><tr><th>task</th><th>language</th><th>attempt</th><th>outcome</th><th>cost USD</th><th>turns</th><th>wall min</th>
<th>lines +/−</th><th>files</th></tr>{adapt_rows}</table>
{render_task_before_after(R)}
<h2>Code-quality rubric (AI reviewers A / B)</h2>
<p class="muted">Two independent read-only AI reviewers per language score rubric items 1–4 (1–5 scale). Subjective
judgements, not measurements; evidence per score in <code>results/development/code-review/</code>.</p>
<table><tr><th>language</th><th>architecture</th><th>readability</th><th>robustness</th><th>testability</th></tr>{rubric_rows}</table>
{kernel_html}
<h2>Additional suites (all engines)</h2><p class="muted">Black-box suites beyond conformance. Six engines: records in
<code>results/correctness/</code>; assembly engines: the validation records of their latest merged run (HTTP suite,
execution modes). Robustness probes (<code>tests/regression/robustness_probe.py</code>) check the defects suspected
by the code reviewers; "fail" means a probe reproduced one. CR-6 expression limits (<code>spec/changes/expression-limits.md</code>,
resolves SPEC-Q-002) counts the passing cases: minimum statement sizes in four execution modes, and larger statements, which
must give the result, <code>RESOURCE_LIMIT</code> or a timely <code>TIMEOUT</code>. No engine claims the capability yet,
so the column is informational.</p>
<table><tr><th>engine</th>{''.join(f'<th>{h}</th>' for _, h in scols)}</tr>{suite_rows}</table>
<h2>Capability matrix (claimed and tested)</h2><p class="muted">The kernel libraries claim no engine capabilities
(they are called through the C ABI, not the protocol).</p><table><tr><th>capability</th>{''.join(f'<th>{l}</th>' for l in cap_langs)}</tr>{cap_rows}</table>
<h2>All agent attempts (failures included)</h2><table><tr><th>language</th><th>task</th><th>attempt</th><th>outcome</th><th>manifest</th></tr>{runs_rows}</table>
</body></html>"""


def write_capability_matrix(rep: dict) -> None:
    caps = rep["capability_matrix"]
    corr = rep["reports"]["1_functional_correctness"]
    lines = ["# Capability Matrix", "", "Generated by `tools/reporting/report.py` from `results/correctness/*.json`.",
             "A capability is listed only if the engine claims it **and** its conformance report exists; per-phase pass status below.", "",
             "| capability | " + " | ".join(LANGS) + " |", "|---|" + "---|" * len(LANGS)]
    for c in CAPS_ORDER:
        lines.append(f"| `{c}` | " + " | ".join("✔" if c in (caps.get(l) or []) else "·" for l in LANGS) + " |")
    lines += ["", "| phase passed (public suite) | " + " | ".join(LANGS) + " |", "|---|" + "---|" * len(LANGS)]
    for ph in "12345":
        lines.append(f"| phase {ph} | " + " | ".join(
            ("✔" if ((corr.get(l) or {}).get("phase_passed") or {}).get(ph) else "✘" if ph in ((corr.get(l) or {}).get("phase_passed") or {}) else "–")
            for l in LANGS) + " |")
    DOCS.mkdir(parents=True, exist_ok=True)
    (DOCS / "capability-matrix.md").write_text("\n".join(lines) + "\n")


def main() -> int:
    cmd = sys.argv[1] if len(sys.argv) > 1 else "all"
    weights = DEFAULT_WEIGHTS
    if "--weights" in sys.argv:
        weights = json.loads(Path(sys.argv[sys.argv.index("--weights") + 1]).read_text())
    rep = build(weights)
    write_capability_matrix(rep)
    if cmd == "capability-matrix":
        print((DOCS / "capability-matrix.md").read_text())
        return 0
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "report.json").write_text(json.dumps(rep, indent=1, default=str) + "\n")
    with open(OUT / "development.csv", "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["language", "task", "attempt", "outcome", "cost_usd", "tokens_output", "tokens_input_total", "turns",
                    "wall_seconds", "tool_calls", "tool_failures", "build_failures", "repair_iterations", "commits",
                    "lines_added", "manifest"])
        for l, ts in rep["reports"]["2_development_effort"].items():
            for t, atts in ts.items():
                for a in atts:
                    w.writerow([l, t, a["attempt"], a["outcome"], a["cost_usd"], a["tokens_output"], a["tokens_input_total"],
                                a["turns"], a["wall_seconds"], a["tool_calls"], a["tool_failures"], a["build_failures"],
                                a["repair_iterations"], a["commits"], a["lines_added"], a["manifest"]])
    with open(OUT / "performance.csv", "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["bench_id", "scale", "engine", "query", "median_latency_s", "source"])
        for p in rep["reports"]["3_runtime_performance"]:
            for l, e in p["engines"].items():
                for q, v in e["median_latency_by_query"].items():
                    w.writerow([p["bench_id"], p["scale"], l, q, v, p["source"]])
    DOCS.mkdir(parents=True, exist_ok=True)
    (DOCS / "report.html").write_text(render_html(rep))
    print(f"wrote {OUT / 'report.json'}, development.csv, performance.csv, {DOCS / 'report.html'}, capability-matrix.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
