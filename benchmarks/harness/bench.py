#!/usr/bin/env python3
"""PolyQuery language-neutral benchmark harness.

Drives any engine through its public protocol (session mode, and HTTP for
throughput) and records raw measurements plus summary statistics.

  bench.py --engines all|go,rust --scale 1m [--reps 7] [--warmup 3] [--cpus 0-15]
           [--mem-limit-gb 64] [--cold-cache] [--http] [--seed 1] [--queries q05,q10]

Measured: startup time, warmup curve (first iterations), steady-state query
latency (p50/p95/p99, bootstrap CI), ingestion throughput, index build time,
storage size and save/open time (cold and warm cache), peak RSS and CPU time of
the engine process tree, thread scaling, execution-mode and join-algorithm
comparisons, HTTP throughput. Only engine capabilities the engine claims are
exercised; everything else is reported as not_applicable.

JVM-based engines' startup is reported separately from steady-state latency and
never mixed into query statistics.
"""
from __future__ import annotations

import argparse
import datetime as dt
import gzip
import hashlib
import json
import os
import random
import shutil
import statistics
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "tests/conformance"))
from engine import EngineError, HttpEngine, SessionEngine, engine_info  # noqa: E402

LANGS = ["java", "clojure", "rust", "python", "go", "common-lisp"]
CLK = os.sysconf("SC_CLK_TCK")
PAGE = os.sysconf("SC_PAGE_SIZE")


# ------------------------------------------------------------------ process tree metrics

def tree_pids(root: int) -> list[int]:
    out, stack = [], [root]
    while stack:
        p = stack.pop()
        out.append(p)
        try:
            for t in os.listdir(f"/proc/{p}/task"):
                with open(f"/proc/{p}/task/{t}/children") as fh:
                    stack.extend(int(c) for c in fh.read().split())
        except OSError:
            pass
    return out


# Launcher/sandbox plumbing processes in an engine's tree; excluded from engine RSS/CPU.
WRAPPER_COMMS = {"sudo", "bwrap", "setpriv", "env", "taskset", "systemd-run"}
SANDBOX = ROOT / "tools/orchestration/sandboxed.sh"


def proc_comm(pid: int) -> str:
    try:
        with open(f"/proc/{pid}/comm") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def engine_pids(root: int) -> list[int]:
    return [p for p in tree_pids(root) if proc_comm(p) not in WRAPPER_COMMS]


def proc_cpu(pid: int) -> float:
    try:
        with open(f"/proc/{pid}/stat") as fh:
            f = fh.read().rsplit(")", 1)[1].split()
        return (int(f[11]) + int(f[12]) + int(f[13]) + int(f[14])) / CLK
    except (OSError, IndexError, ValueError):
        return 0.0


def proc_rss(pid: int) -> tuple[int, int]:
    """(current RSS bytes, peak RSS bytes) from /proc/<pid>/status."""
    rss = hwm = 0
    try:
        with open(f"/proc/{pid}/status") as fh:
            for line in fh:
                if line.startswith("VmRSS:"):
                    rss = int(line.split()[1]) * 1024
                elif line.startswith("VmHWM:"):
                    hwm = int(line.split()[1]) * 1024
    except OSError:
        pass
    return rss, hwm


class Sampler:
    """Samples tree RSS every 50 ms; tracks peak (sum of tree RSS) and max per-process HWM."""

    def __init__(self, pid: int):
        self.pid = pid
        self.peak_tree_rss = 0
        self.max_hwm = 0
        self._stop = threading.Event()
        self._t = threading.Thread(target=self._run, daemon=True)
        self._t.start()

    def _run(self) -> None:
        while not self._stop.is_set():
            total = 0
            for p in engine_pids(self.pid):
                rss, hwm = proc_rss(p)
                total += rss
                self.max_hwm = max(self.max_hwm, hwm)
            self.peak_tree_rss = max(self.peak_tree_rss, total)
            self._stop.wait(0.05)

    def cpu(self) -> float:
        return sum(proc_cpu(p) for p in engine_pids(self.pid))

    def stop(self) -> dict:
        self._stop.set()
        self._t.join(1)
        return {"peak_tree_rss_bytes": self.peak_tree_rss, "max_process_hwm_bytes": self.max_hwm}


# ------------------------------------------------------------------ statistics

def pct(xs: list[float], q: float) -> float:
    s = sorted(xs)
    if not s:
        return float("nan")
    k = (len(s) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)


def summarize(xs: list[float], rng: random.Random) -> dict:
    if not xs:
        return {"n": 0}
    boots = []
    for _ in range(1000):
        sample = [xs[rng.randrange(len(xs))] for _ in xs]
        boots.append(statistics.median(sample))
    q1, q3 = pct(xs, 0.25), pct(xs, 0.75)
    iqr = q3 - q1
    outliers = [x for x in xs if x < q1 - 1.5 * iqr or x > q3 + 1.5 * iqr]
    return {"n": len(xs), "median": statistics.median(xs), "mean": statistics.fmean(xs),
            "stdev": statistics.stdev(xs) if len(xs) > 1 else 0.0, "min": min(xs), "max": max(xs),
            "p50": pct(xs, 0.5), "p95": pct(xs, 0.95), "p99": pct(xs, 0.99),
            "ci95_median": [pct(boots, 0.025), pct(boots, 0.975)], "outliers": len(outliers)}


def digest(resp: dict) -> str | None:
    if "rows" not in resp:
        return None
    def norm(v):
        return round(v, 6) if isinstance(v, float) else v
    return hashlib.sha256(json.dumps([[norm(v) for v in r] for r in resp["rows"]]).encode()).hexdigest()[:16]


# ------------------------------------------------------------------ helpers

def drop_caches() -> bool:
    r = subprocess.run(["sudo", "-n", "sh", "-c", "sync; echo 3 > /proc/sys/vm/drop_caches"], capture_output=True)
    return r.returncode == 0


def sandbox_launch_seconds(prefix: list[str], n: int = 5) -> float | None:
    """Median wall time to start and exit `true` through the same wrapper chain as an engine."""
    xs = []
    for _ in range(n):
        t0 = time.monotonic()
        if subprocess.run([*prefix, "true"], capture_output=True).returncode != 0:
            return None
        xs.append(time.monotonic() - t0)
    return sorted(xs)[len(xs) // 2]


def wrap_cmd(cpus: str | None, mem_gb: float | None, sandbox: bool = True) -> list[str]:
    pre = []
    if mem_gb and shutil.which("systemd-run"):
        test = subprocess.run(["systemd-run", "--user", "--scope", "--quiet", "-p", "MemoryMax=1G", "true"],
                              capture_output=True)
        if test.returncode == 0:
            pre += ["systemd-run", "--user", "--scope", "--quiet", "-p", f"MemoryMax={int(mem_gb * 1024)}M",
                    "-p", "MemorySwapMax=0"]
    if cpus and shutil.which("taskset"):
        pre += ["taskset", "-c", cpus]
    if sandbox:
        pre.append(str(SANDBOX))
    return pre


class WrappedLauncher:
    """Creates a tiny wrapper script so the conformance engine drivers can be reused under taskset/cgroups."""

    def __init__(self, launcher: str, prefix: list[str], workdir: Path, name: str):
        self.path = workdir / f"launch-{name}.sh"
        q = " ".join(f"'{a}'" for a in prefix)
        self.path.write_text(f"#!/bin/sh\nexec {q} '{launcher}' \"$@\"\n")
        self.path.chmod(0o755)


def load_tables(eng, workload: dict, scale_dir: Path, raw: list, ctx: dict, caps: set) -> dict:
    out = {}
    for tname, file_stem in workload["tables"].items():
        csv = scale_dir / f"{file_stem}.csv"
        schema = json.loads((scale_dir / f"{file_stem}.schema.json").read_text())
        t0 = time.monotonic()
        resp = eng.request({"op": "load", "table": tname, "format": "csv", "path": csv.name, "schema": schema},
                           timeout=3600)
        el = time.monotonic() - t0
        size = csv.stat().st_size
        rec = {**ctx, "kind": "ingest", "table": tname, "seconds": el, "bytes": size,
               "mb_per_s": size / 1e6 / el if el > 0 else None, "ok": resp.get("ok"), "rows": resp.get("row_count"),
               "error": resp.get("error")}
        raw.append(rec)
        out[tname] = rec
    return out


def run_query(eng, sql: str, options: dict, timeout: float) -> tuple[float, dict]:
    t0 = time.monotonic()
    resp = eng.request({"op": "query", "sql": sql, "options": options}, timeout=timeout)
    return time.monotonic() - t0, resp


# ------------------------------------------------------------------ main benchmark per engine

def bench_engine(lang: str, launcher: str, info: dict, workload: dict, scale: str, scale_dir: Path, args, raw: list,
                 rng: random.Random, workdir: Path) -> dict:
    caps = set(info["capability_set"])
    ctx = {"engine": lang, "scale": scale}
    res: dict = {"engine": lang, "capabilities": sorted(caps), "version": info.get("version")}
    prefix = wrap_cmd(args.cpus, args.mem_limit_gb, args.sandbox)
    wl = WrappedLauncher(launcher, prefix, workdir, lang)

    # 1. startup (process spawn -> first protocol response), measured inside the wrapper chain
    #    so sandbox launch time is excluded (see startup_probe.py)
    startups: list[float] = []
    probe = subprocess.run([*prefix, "python3", str(HERE / "startup_probe.py"), launcher, str(scale_dir),
                            str(args.startup_reps)], capture_output=True, text=True, timeout=1800)
    try:
        startups = [x for x in json.loads(probe.stdout.strip().splitlines()[-1]) if x is not None]
    except (json.JSONDecodeError, IndexError):
        res["startup_error"] = (probe.stderr or probe.stdout)[-500:]
    raw.extend({**ctx, "kind": "startup", "seconds": s, "rep": k} for k, s in enumerate(startups))
    res["startup_seconds"] = summarize(startups, rng) if startups else None

    # 2. main session: ingestion, indexes, queries
    extra = ["--enable-test-functions"] if "test.functions" in caps else []
    eng = SessionEngine(str(wl.path), scale_dir, extra, timeout=args.query_timeout)
    sampler = Sampler(eng.proc.pid)
    try:
        cpu0 = sampler.cpu()
        res["ingest"] = load_tables(eng, workload, scale_dir, raw, ctx, caps)
        res["ingest_cpu_seconds"] = sampler.cpu() - cpu0
        if any(not r["ok"] for r in res["ingest"].values()):
            res["status"] = "ingest_failed"
            res["memory"] = sampler.stop()
            return res
        res["index_build"] = {}
        if args.indexes:
            for ix in workload.get("indexes", []):
                if set(ix["requires"]) <= caps:
                    el, resp = run_query(eng, ix["sql"], {}, args.query_timeout)
                    raw.append({**ctx, "kind": "index_build", "sql": ix["sql"], "seconds": el, "ok": resp.get("ok")})
                    res["index_build"][ix["sql"].split()[2]] = {"seconds": el, "ok": resp.get("ok")}
        queries = [q for q in workload["queries"] if not args.queries or any(q["name"].startswith(x) for x in args.queries)]
        runnable = [q for q in queries if set(q["requires"]) <= caps]
        res["queries"] = {q["name"]: {"status": "not_applicable", "missing": sorted(set(q["requires"]) - caps)}
                          for q in queries if q not in runnable}
        lat: dict[str, list[float]] = {q["name"]: [] for q in runnable}
        first: dict[str, list[float]] = {q["name"]: [] for q in runnable}
        digests: dict[str, set] = {q["name"]: set() for q in runnable}
        failed: dict[str, str] = {}
        cpu_q0 = sampler.cpu()
        t_q0 = time.monotonic()
        rounds = args.warmup + args.reps
        for rnd in range(rounds):
            order = list(runnable)
            rng.shuffle(order)
            for q in order:
                if q["name"] in failed:
                    continue
                opts = {"result": q.get("result", "rows")}
                try:
                    el, resp = run_query(eng, q["sql"], opts, args.query_timeout)
                except EngineError as e:
                    failed[q["name"]] = f"engine failure: {e}"
                    eng = SessionEngine(str(wl.path), scale_dir, extra, timeout=args.query_timeout)
                    sampler.stop()
                    sampler = Sampler(eng.proc.pid)
                    load_tables(eng, workload, scale_dir, [], ctx, caps)
                    continue
                if not resp.get("ok"):
                    failed[q["name"]] = str(resp.get("error"))
                    continue
                d = digest(resp)
                if d:
                    digests[q["name"]].add(d)
                warm = rnd >= args.warmup
                raw.append({**ctx, "kind": "query", "query": q["name"], "round": rnd, "warm": warm, "seconds": el,
                            "engine_elapsed_us": (resp.get("stats") or {}).get("elapsed_us"),
                            "row_count": resp.get("row_count"), "digest": d})
                (lat if warm else first)[q["name"]].append(el)
        res["query_phase_cpu_seconds"] = sampler.cpu() - cpu_q0
        res["query_phase_wall_seconds"] = time.monotonic() - t_q0
        for q in runnable:
            n = q["name"]
            if n in failed:
                res["queries"][n] = {"status": "failed", "error": failed[n][:300]}
            else:
                res["queries"][n] = {"status": "ok", "latency_seconds": summarize(lat[n], rng),
                                     "warmup_seconds": first[n], "digests": sorted(digests[n])}

        # 3. thread scaling / modes / joins (Phase 5 capabilities)
        for section in ("thread_scaling", "modes", "joins"):
            spec = workload.get(section)
            if not spec or not set(spec["requires"]) <= caps:
                res[section] = {"status": "not_applicable"}
                continue
            out: dict = {}
            variants = [{"threads": t} for t in spec["threads"]] if section == "thread_scaling" else spec["options"]
            for qname in spec["queries"]:
                q = next(x for x in workload["queries"] if x["name"] == qname)
                if not set(q["requires"]) <= caps or qname in failed:
                    continue
                for v in variants:
                    key = json.dumps(v, sort_keys=True)
                    xs = []
                    for rnd in range(args.warmup + args.reps):
                        try:
                            el, resp = run_query(eng, q["sql"], {**v, "result": q.get("result", "rows")}, args.query_timeout)
                        except EngineError as e:
                            xs = None
                            out.setdefault(qname, {})[key] = {"status": "failed", "error": str(e)}
                            eng = SessionEngine(str(wl.path), scale_dir, extra, timeout=args.query_timeout)
                            load_tables(eng, workload, scale_dir, [], ctx, caps)
                            break
                        if not resp.get("ok"):
                            out.setdefault(qname, {})[key] = {"status": "failed", "error": str(resp.get("error"))[:200]}
                            xs = None
                            break
                        raw.append({**ctx, "kind": section, "query": qname, "variant": v, "round": rnd,
                                    "warm": rnd >= args.warmup, "seconds": el, "digest": digest(resp)})
                        if rnd >= args.warmup:
                            xs.append(el)
                    if xs:
                        out.setdefault(qname, {})[key] = {"status": "ok", "latency_seconds": summarize(xs, rng)}
            res[section] = out

        # 4. storage: save size/time, cold & warm open
        if "storage.pqcf" in caps:
            st: dict = {}
            outdir = scale_dir / "bench-out"
            outdir.mkdir(exist_ok=True)
            rel = f"bench-out/{lang}-transactions.pqcf"
            t0 = time.monotonic()
            resp = eng.request({"op": "save", "table": "transactions", "path": rel}, timeout=3600)
            st["save_seconds"] = time.monotonic() - t0
            st["save_ok"] = resp.get("ok")
            if resp.get("ok"):
                st["file_bytes"] = (scale_dir / rel).stat().st_size
                st["csv_bytes"] = (scale_dir / "transactions.csv").stat().st_size
                for label, cold in (("cold", True), ("warm", False)):
                    if cold:
                        st["cold_cache_dropped"] = drop_caches()
                    for mm in ([False, True] if "storage.mmap" in caps else [False]):
                        tab = f"tx_{label}_{int(mm)}"
                        t0 = time.monotonic()
                        r1 = eng.request({"op": "open", "table": tab, "path": rel, "options": {"mmap": mm}}, timeout=3600)
                        t_open = time.monotonic() - t0
                        t0 = time.monotonic()
                        r2 = eng.request({"op": "query", "sql": f"SELECT COUNT(*), SUM(amount) FROM {tab}"}, timeout=3600)
                        t_q = time.monotonic() - t0
                        st[f"open_{label}_mmap{int(mm)}"] = {"open_seconds": t_open, "first_query_seconds": t_q,
                                                             "ok": bool(r1.get("ok") and r2.get("ok"))}
                        eng.request({"op": "drop", "table": tab})
                        if cold:
                            drop_caches()
                (scale_dir / rel).unlink(missing_ok=True)
            res["storage"] = st
            raw.append({**ctx, "kind": "storage", **{k: v for k, v in st.items() if not isinstance(v, dict)}})
    finally:
        res["memory"] = sampler.stop()
        eng.close()

    # 5. HTTP throughput (Phase 4)
    if args.http and "phase4" in caps:
        res["http"] = http_throughput(lang, str(wl.path), workload, scale_dir, caps, args, rng, raw, ctx)
    else:
        res["http"] = {"status": "not_applicable" if "phase4" not in caps else "skipped"}
    res["status"] = "ok"
    return res


def http_throughput(lang, launcher, workload, scale_dir, caps, args, rng, raw, ctx) -> dict:
    out: dict = {}
    for clients in args.http_clients:
        srv = HttpEngine(launcher, scale_dir, ["--workers", str(clients), "--queue-depth", str(clients * 4)], timeout=600)
        try:
            for tname, stem in workload["tables"].items():
                if tname not in ("transactions", "customers"):
                    continue
                schema = json.loads((scale_dir / f"{stem}.schema.json").read_text())
                srv.request({"op": "load", "table": tname, "format": "csv", "path": f"{stem}.csv", "schema": schema},
                            timeout=3600)
            light = [q for q in workload["queries"] if set(q["requires"]) <= caps and
                     q["name"] in ("q01_filter_selective", "q03_range_filter_time", "q05_groupby_low_card", "q09_distinct_count")]
            lats: list[float] = []
            errors = 0
            lock = threading.Lock()
            stop_at = time.monotonic() + args.http_seconds

            def worker(seed: int) -> None:
                nonlocal errors
                r = random.Random(seed)
                while time.monotonic() < stop_at:
                    q = r.choice(light)
                    t0 = time.monotonic()
                    st, _, body = srv.http("POST", "/v1/query", json.dumps({"sql": q["sql"]}).encode(),
                                           {"Content-Type": "application/json"}, 600)
                    el = time.monotonic() - t0
                    with lock:
                        if st == 200:
                            lats.append(el)
                        else:
                            errors += 1
            ts = [threading.Thread(target=worker, args=(rng.randrange(1 << 30),)) for _ in range(clients)]
            t0 = time.monotonic()
            for t in ts:
                t.start()
            for t in ts:
                t.join()
            wall = time.monotonic() - t0
            out[str(clients)] = {"qps": len(lats) / wall, "errors": errors, "latency_seconds": summarize(lats, rng)}
            raw.append({**ctx, "kind": "http", "clients": clients, "requests": len(lats), "errors": errors, "wall": wall})
        finally:
            srv.close()
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--engines", default="all")
    ap.add_argument("--scale", default="1m")
    ap.add_argument("--workload", default=str(ROOT / "benchmarks/workloads/analytics.json"))
    ap.add_argument("--reps", type=int, default=7)
    ap.add_argument("--warmup", type=int, default=3)
    ap.add_argument("--startup-reps", type=int, default=5)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--cpus", default="0-15", help="taskset CPU list for engine processes ('' = no pinning)")
    ap.add_argument("--mem-limit-gb", type=float, default=96)
    ap.add_argument("--query-timeout", type=float, default=600)
    ap.add_argument("--queries", help="comma-separated query name prefixes")
    ap.add_argument("--no-indexes", dest="indexes", action="store_false")
    ap.add_argument("--http", action="store_true")
    ap.add_argument("--http-clients", type=lambda s: [int(x) for x in s.split(",")], default=[1, 4, 16])
    ap.add_argument("--http-seconds", type=float, default=20)
    ap.add_argument("--no-sandbox", dest="sandbox", action="store_false",
                    help="run engines unsandboxed (only for trusted engines; recorded in the results)")
    ap.add_argument("--label", default="")
    ap.add_argument("--track", default="A")
    args = ap.parse_args()
    if args.queries:
        args.queries = args.queries.split(",")

    langs = LANGS if args.engines == "all" else args.engines.split(",")
    scale_dir = ROOT / "datasets/generated" / args.scale
    if not (scale_dir / "manifest.json").exists():
        print(f"generating datasets for scale {args.scale} ...", flush=True)
        subprocess.run([sys.executable, str(ROOT / "datasets/generators/pqgen.py"), "generate", "--scale", args.scale], check=True)
    workload = json.loads(Path(args.workload).read_text())
    rng = random.Random(args.seed)
    order = list(langs)
    rng.shuffle(order)
    bench_id = f"{dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')}-{args.scale}{('-' + args.label) if args.label else ''}"
    out_dir = ROOT / "results/performance" / bench_id
    out_dir.mkdir(parents=True, exist_ok=True)
    workdir = Path(os.environ.get("TMPDIR", "/tmp")) / f"pqbench-{bench_id}"
    workdir.mkdir(parents=True, exist_ok=True)
    doctor = subprocess.run([sys.executable, str(ROOT / "tools/environment/doctor.py"), "--quiet",
                             "--out", str(out_dir / "environment.json")], capture_output=True)
    meta = {"schema": "polyquery-benchmark/1", "bench_id": bench_id, "track": args.track, "scale": args.scale,
            "workload": workload["name"], "workload_version": workload["version"], "args": vars(args),
            "engine_order": order, "started": dt.datetime.now(dt.timezone.utc).isoformat(),
            "isolation": {"taskset": args.cpus or None, "memory_limit_gb": args.mem_limit_gb,
                          "cgroup_wrapper": wrap_cmd(None, args.mem_limit_gb, False)[:3],
                          "sandboxed": args.sandbox,
                          # included in every startup sample; identical for all engines
                          "sandbox_launch_seconds": sandbox_launch_seconds(wrap_cmd(args.cpus, args.mem_limit_gb,
                                                                                     args.sandbox)),
                          "cold_cache_supported": drop_caches()},
            "dataset_manifest": json.loads((scale_dir / "manifest.json").read_text()),
            "git_commit": subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip(),
            "environment_file": "environment.json", "doctor_exit": doctor.returncode}
    raw: list[dict] = []
    results = {}
    for lang in order:
        launcher = ROOT / "implementations" / lang / "bin/polyquery"
        if not launcher.exists():
            results[lang] = {"engine": lang, "status": "not_built"}
            print(f"[{lang}] not built", flush=True)
            continue
        info = engine_info(str(WrappedLauncher(str(launcher), wrap_cmd(args.cpus, args.mem_limit_gb, args.sandbox),
                                               workdir, f"{lang}-info").path), timeout=120)
        engine_json = ROOT / "implementations" / lang / "ENGINE.json"
        print(f"[{lang}] benchmarking ({len(info['capability_set'])} capabilities)", flush=True)
        try:
            r = bench_engine(lang, str(launcher), info, workload, args.scale, scale_dir, args, raw, rng, workdir)
        except Exception as e:  # noqa: BLE001
            r = {"engine": lang, "status": "harness_error", "error": repr(e)}
        r["engine_json"] = json.loads(engine_json.read_text()) if engine_json.exists() else None
        results[lang] = r
        ok = sum(1 for q in (r.get("queries") or {}).values() if q.get("status") == "ok")
        print(f"[{lang}] done: status={r.get('status')} queries_ok={ok} peak_rss={((r.get('memory') or {}).get('peak_tree_rss_bytes') or 0) / 2**20:.0f}MiB", flush=True)
    meta["finished"] = dt.datetime.now(dt.timezone.utc).isoformat()
    # cross-engine digest agreement (informational; not an authority on correctness)
    agree = {}
    qnames = {q["name"] for q in workload["queries"]}
    for qn in sorted(qnames):
        ds = {l: tuple(r["queries"][qn]["digests"]) for l, r in results.items()
              if (r.get("queries") or {}).get(qn, {}).get("status") == "ok" and r["queries"][qn]["digests"]}
        if ds:
            agree[qn] = {"distinct_results": len(set(ds.values())), "by_engine": {l: list(v) for l, v in ds.items()}}
    summary = {"meta": meta, "results": results, "result_agreement": agree}
    (out_dir / "summary.json").write_text(json.dumps(summary, indent=1, default=str) + "\n")
    with gzip.open(out_dir / "raw.jsonl.gz", "wt") as fh:
        for r in raw:
            fh.write(json.dumps(r, default=str) + "\n")
    print(f"results: {out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
