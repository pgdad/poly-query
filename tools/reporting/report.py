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
# Fixed categorical slots (reference palette order); identity is also always in axis labels.
COLORS = {"java": "#2a78d6", "clojure": "#eb6834", "rust": "#1baf7a", "python": "#eda100", "go": "#e87ba4",
          "common-lisp": "#008300", "x86_64-asm": "#6250d6", "arm64-asm": "#e34948"}
COLORS_DARK = {"java": "#3987e5", "clojure": "#d95926", "rust": "#199e70", "python": "#c98500", "go": "#d55181",
               "common-lisp": "#008300", "x86_64-asm": "#9085e9", "arm64-asm": "#e66767"}
SRC_EXT = {"java": [".java"], "clojure": [".clj", ".cljc", ".edn"], "rust": [".rs"], "python": [".py"],
           "go": [".go"], "common-lisp": [".lisp", ".asd", ".cl"], "x86_64-asm": [".S", ".s", ".h", ".inc"], "arm64-asm": [".S", ".s", ".h", ".inc"]}
COMMENT = {"java": "//", "clojure": ";", "rust": "//", "python": "#", "go": "//", "common-lisp": ";",
           "x86_64-asm": "#", "arm64-asm": "//"}
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
    for lang in LANGS:
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


def collect_task_before_after() -> list[dict]:
    out = []
    for name, note in TASK_BEFORE_AFTER.items():
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
    langs_all = LANGS + ASM
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
    perf_rep = []
    for p in perf:
        meta = p["meta"]
        # Before/after benchmarks measure task branches (some never merged): they belong to report 6
        # only. Track B benchmarks never enter the Track A reports 3, 4 and 8.
        if re.search(r"-(before|after)-[a-z-]+$", meta["bench_id"]) or meta.get("track", "A") != "A":
            continue
        entry = {"bench_id": meta["bench_id"], "scale": meta["scale"], "track": meta.get("track"), "source": p["_path"],
                 "host_cpu": None, "engines": {}}
        env = load_json(ROOT / Path(p["_path"]).parent / "environment.json") or {}
        entry["host_cpu"] = (env.get("hardware") or {}).get("model")
        for l, r in p["results"].items():
            q = {n: v["latency_seconds"]["median"] for n, v in (r.get("queries") or {}).items()
                 if v.get("status") == "ok" and v["latency_seconds"].get("n")}
            entry["engines"][l] = {
                "status": r.get("status"), "median_latency_by_query": q,
                "queries_ok": len(q), "startup_median_s": (r.get("startup_seconds") or {}).get("median"),
                "peak_rss_mib": ((r.get("memory") or {}).get("peak_tree_rss_bytes") or 0) / 2**20 or None,
                "ingest_mb_s": {t: v.get("mb_per_s") for t, v in (r.get("ingest") or {}).items()},
                "query_cpu_s": r.get("query_phase_cpu_seconds"), "query_wall_s": r.get("query_phase_wall_seconds"),
                "storage": r.get("storage"), "thread_scaling": r.get("thread_scaling"), "modes": r.get("modes"),
                "joins": r.get("joins"), "http": r.get("http")}
        perf_rep.append(entry)
    # 5. code quality: automated metrics + rubric review scores (AI reviewers, labelled as such)
    quality = {l: {**(code_metrics(l) or {}), "rubric_review": reviews.get(l)} for l in langs_all}
    # 7. architectural adaptability: change-task runs (engines and kernel cohort)
    adapt = {l: {t: v for t, v in d.items()
                 if t.startswith(("change", "refactor", "debug", "regress", "optimize", "kernel-"))}
             for l, d in dev.items()}

    # capability matrix
    matrix = {l: (corr.get(l) or {}).get("capabilities") or [] for l in LANGS}

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
    return {"generated": dt.datetime.now(dt.timezone.utc).isoformat(), "weights": weights,
            "git_commit": subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip(),
            "runs": [{k: v for k, v in r.items() if k not in ("telemetry", "validation")} for r in runs],
            "capability_matrix": matrix, "reports": {
                "1_functional_correctness": {**correctness, "kernel_cohort": {l: kern[l]["correctness"] for l in ASM}},
                "2_development_effort": dev,
                "3_runtime_performance": perf_rep,
                "3_runtime_performance_kernel_cohort": {l: kern[l]["performance"] for l in ASM},
                "4_resource_efficiency": [
                    {"bench_id": p["bench_id"], "engines": {l: {k: e[k] for k in ("peak_rss_mib", "query_cpu_s", "query_wall_s", "startup_median_s", "ingest_mb_s")}
                                                          for l, e in p["engines"].items()}} for p in perf_rep],
                "4_resource_efficiency_kernel_cohort": {
                    l: {"text_bytes_per_source": kern[l]["codesize"],
                        "note": "Kernels never allocate (ABI rule); resource figures are machine-code size and time per element."}
                    for l in ASM},
                "5_code_quality": quality, "6_optimization_effectiveness": [
                    {"bench_id": p["bench_id"], "engines": {l: {k: e[k] for k in ("modes", "joins", "thread_scaling")}
                                                          for l, e in p["engines"].items()}} for p in perf_rep],
                "6_optimization_task_before_after": collect_task_before_after(),
                "6_optimization_effectiveness_kernel_cohort": {
                    l: {"simd_and_scalar_speedup_vs_reference": (kern[l]["performance"] or {}).get("speedup_vs_reference"),
                        "independent_before_after": kern[l]["before_after"]} for l in ASM},
                "7_architectural_adaptability": adapt, "8_overall": {"per_language": overall, "pareto_front": front,
                                                                      "note": "Correctness-gated: a language without a 100% pass rate is never ranked above one with 100%. Track A and Track B are never combined.",
                                                                      "kernel_cohort": kernel_overall,
                                                                      "kernel_cohort_note": "Assembly kernels are a separate cohort (ADR-0016), never ranked with the engines; x86-64 and AArch64 are measured on different machines and are not ranked against each other."}}}


# ------------------------------------------------------------------ rendering

def bar_chart(title: str, unit: str, data: dict[str, float | None], fmt=lambda v: f"{v:,.1f}") -> str:
    items = [(k, v) for k, v in data.items() if v is not None]
    if not items:
        return f'<figure class="chart"><figcaption>{html.escape(title)}</figcaption><p class="muted">No data recorded yet.</p></figure>'
    w, bh, gap, left = 640, 22, 8, 120
    h = len(items) * (bh + gap) + 10
    mx = max(v for _, v in items) or 1
    rows = []
    for i, (k, v) in enumerate(items):
        y = i * (bh + gap) + 4
        bw = max(2, (w - left - 90) * v / mx)
        rows.append(
            f'<g class="bar"><title>{html.escape(k)}: {fmt(v)} {html.escape(unit)}</title>'
            f'<text x="{left - 8}" y="{y + bh * 0.7}" text-anchor="end" class="lbl">{html.escape(k)}</text>'
            f'<rect x="{left}" y="{y}" width="{bw:.1f}" height="{bh}" rx="4" style="fill:var(--c-{k})"/>'
            f'<text x="{left + bw + 6}" y="{y + bh * 0.7}" class="val">{fmt(v)}</text></g>')
    table = "".join(f"<tr><td>{html.escape(k)}</td><td>{fmt(v)}</td></tr>" for k, v in items)
    return (f'<figure class="chart"><figcaption>{html.escape(title)} <span class="muted">({html.escape(unit)})</span></figcaption>'
            f'<svg viewBox="0 0 {w} {h}" role="img" aria-label="{html.escape(title)}">'
            f'<line x1="{left}" y1="0" x2="{left}" y2="{h}" class="axis"/>{"".join(rows)}</svg>'
            f'<details><summary>Table</summary><table><tr><th>Language</th><th>{html.escape(unit)}</th></tr>{table}</table></details></figure>')


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
    for ba in R.get("6_optimization_task_before_after") or []:
        rows = "".join(
            f"<tr><td>{html.escape(l)}</td><td>{e['geomean_before_s'] * 1e3:.1f} → {e['geomean_after_s'] * 1e3:.1f} ms</td>"
            f"<td>{e['speedup']:.2f}×</td><td>{html.escape(', '.join(e.get('significantly_slower') or []) or '—')}</td>"
            f"<td>{(e.get('peak_rss_before') or 0) / 2**30:.1f} → {(e.get('peak_rss_after') or 0) / 2**30:.1f} GiB</td></tr>"
            for l, e in sorted(ba["engines"].items(), key=lambda kv: -kv[1]["speedup"]))
        parts.append(f"<p><b>{html.escape(ba['note'])}</b> — <code>{html.escape(ba['source'])}</code>; result digests "
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

    charts = []
    charts.append(bar_chart("Development time (all attempts, all tasks)", "hours",
                            {l: (agg(l, "wall_seconds") or 0) / 3600 or None for l in LANGS + ASM}, lambda v: f"{v:.2f}"))
    charts.append(bar_chart("Output tokens (all attempts)", "k tokens",
                            {l: (agg(l, "tokens_output") or 0) / 1000 or None for l in LANGS + ASM}, lambda v: f"{v:,.0f}"))
    charts.append(bar_chart("Model cost, list-price equivalent", "USD", {l: agg(l, "cost_usd") for l in LANGS + ASM},
                            lambda v: f"{v:,.2f}"))
    charts.append(bar_chart("Repair iterations", "runs", {l: agg(l, "repair_iterations") for l in LANGS + ASM},
                            lambda v: f"{v:.0f}"))
    corr = R["1_functional_correctness"]
    charts.append(bar_chart("Conformance pass rate (public suite, latest report)", "%",
                            {l: (100 * ((c.get("summary") or {}).get("total") or {}).get("pass", 0) /
                                 ((c.get("summary") or {}).get("total") or {}).get("total", 1))
                             if (c.get("summary") or {}).get("total", {}).get("total") else None
                             for l, c in corr.items()}, lambda v: f"{v:.1f}"))
    if R["3_runtime_performance"]:
        last = R["3_runtime_performance"][-1]
        geo = {}
        for l, e in last["engines"].items():
            med = e["median_latency_by_query"]
            if med:
                g = 1.0
                for v in med.values():
                    g *= max(v, 1e-6)
                geo[l] = 1000 * g ** (1 / len(med))
        charts.append(bar_chart(f"Query latency, geometric mean of medians ({last['scale']}, {last['bench_id']})",
                                "ms", geo, lambda v: f"{v:,.1f}"))
        charts.append(bar_chart("Peak resident memory (engine process tree)", "MiB",
                                {l: e["peak_rss_mib"] for l, e in last["engines"].items()}, lambda v: f"{v:,.0f}"))
        charts.append(bar_chart("Startup time (spawn → first response)", "ms",
                                {l: (e["startup_median_s"] or 0) * 1000 or None for l, e in last["engines"].items()},
                                lambda v: f"{v:,.0f}"))
    charts.append(bar_chart("Source lines of code (automated count)", "LOC",
                            {l: (q or {}).get("source_loc") for l, q in R["5_code_quality"].items()}, lambda v: f"{v:,.0f}"))

    css_vars = "".join(f"--c-{k}:{v};" for k, v in COLORS.items())
    css_dark = "".join(f"--c-{k}:{v};" for k, v in COLORS_DARK.items())
    runs_rows = "".join(
        f"<tr><td>{html.escape(r['language'] or '')}</td><td>{html.escape(r['task'] or '')}</td><td>{r['attempt']}</td>"
        f"<td class='o-{html.escape(r['outcome'])}'>{html.escape(r['outcome'])}</td><td><code>{html.escape(r['manifest'])}</code></td></tr>"
        for r in rep["runs"])
    caps = rep["capability_matrix"]
    cap_rows = "".join("<tr><td><code>" + c + "</code></td>" + "".join(
        f"<td>{'✔' if c in (caps.get(l) or []) else '·'}</td>" for l in LANGS) + "</tr>" for c in CAPS_ORDER)
    ov = R["8_overall"]
    kernel_html = render_kernel_cohort(R)
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
<h2>Capability matrix (claimed and tested)</h2><table><tr><th>capability</th>{''.join(f'<th>{l}</th>' for l in LANGS)}</tr>{cap_rows}</table>
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
