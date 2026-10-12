#!/usr/bin/env python3
"""Black-box probes for suspected robustness defects raised by the code reviewers.

  robustness_probe.py --engine implementations/<lang>/bin/polyquery [--only a,b] [--report out.json]

Each probe starts its own engine process (session or serve mode) and observes only the
protocol, the process's liveness and, from /proc, its descriptor count and resident memory.
The spec requirements tested: an engine MUST NOT crash, hang or exit on any request
(errors.md), a failed request leaves no state behind (errors.md: operations are atomic),
and the memory budget is per query (semantics.md §15). Probes whose trigger condition is
not reached report "not_triggered"; pure measurements report "observation".
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path


def tree_pids(root: int) -> list[int]:
    kids: dict[int, list[int]] = {}
    for d in os.listdir("/proc"):
        if d.isdigit():
            try:
                ppid = int(Path(f"/proc/{d}/stat").read_text().rsplit(")", 1)[1].split()[1])
            except (OSError, IndexError, ValueError):
                continue
            kids.setdefault(ppid, []).append(int(d))
    out, todo = [], [root]
    while todo:
        p = todo.pop()
        out.append(p)
        todo += kids.get(p, [])
    return out


def tree_rss_mib(root: int) -> float:
    total = 0
    for p in tree_pids(root):
        try:
            for line in Path(f"/proc/{p}/status").read_text().splitlines():
                if line.startswith("VmRSS:"):
                    total += int(line.split()[1])
        except OSError:
            pass
    return total / 1024


def tree_fds(root: int) -> int:
    n = 0
    for p in tree_pids(root):
        try:
            n += len(os.listdir(f"/proc/{p}/fd"))
        except OSError:
            pass
    return n


class RssSampler:
    def __init__(self, pid: int):
        self.pid, self.peak, self._stop = pid, 0.0, threading.Event()
        self._t = threading.Thread(target=self._run, daemon=True)
        self._t.start()

    def _run(self) -> None:
        while not self._stop.is_set():
            self.peak = max(self.peak, tree_rss_mib(self.pid))
            time.sleep(0.02)

    def stop(self) -> float:
        self._stop.set()
        self._t.join()
        return self.peak


class Session:
    def __init__(self, engine: str, data: Path, args: list[str], env: dict | None = None):
        self.err = tempfile.TemporaryFile()
        self.proc = subprocess.Popen([engine, "session", "--data-dir", str(data), *args], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=self.err, start_new_session=True,
                                     env={**os.environ, **(env or {})})
        self.n = 0

    def send_raw(self, line: bytes, timeout: float = 300) -> dict | None:
        """Sends one line; returns the parsed response, or None if the engine died or hung."""
        box: list = []
        try:
            self.proc.stdin.write(line + b"\n")
            self.proc.stdin.flush()
        except (BrokenPipeError, OSError):
            return None
        t = threading.Thread(target=lambda: box.append(self.proc.stdout.readline()), daemon=True)
        t.start()
        t.join(timeout)
        if not box or not box[0]:
            return None
        try:
            return json.loads(box[0])
        except json.JSONDecodeError:
            return {"_unparsable": box[0][:200].decode("utf-8", "replace")}

    def req(self, r: dict, timeout: float = 300) -> dict | None:
        self.n += 1
        return self.send_raw(json.dumps({"id": self.n, **r}).encode(), timeout)

    def alive(self) -> bool:
        return self.proc.poll() is None

    def close(self) -> dict:
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=30)
        except (OSError, subprocess.TimeoutExpired):
            os.killpg(self.proc.pid, 9)
            self.proc.wait()
        self.err.seek(0)
        tail = self.err.read()[-400:].decode("utf-8", "replace")
        return {"exit_code": self.proc.returncode, "stderr_tail": tail}


def code(resp: dict | None) -> str:
    if resp is None:
        return "NO_RESPONSE"
    if resp.get("ok"):
        return "ok"
    return (resp.get("error") or {}).get("code") or "?"


# Needs far more than 16 MiB (14.4 M join rows, sorted on strings): fails with RESOURCE_LIMIT.
FAILING_QUERY = "SELECT a.s, b.s FROM m a JOIN m b ON a.id % 1000 = b.id % 1000 ORDER BY 1, 2 LIMIT 5"


def write_csv(path: Path, rows: int, width: int) -> None:
    pad = "x" * width
    with open(path, "w") as f:
        f.write("id,k,s\n")
        for i in range(rows):
            f.write(f"{i},k{i},{pad}{i}\n")


# ---------------------------------------------------------------------------- probes

def probe_fd_after_failed_loads(engine: str, data: Path) -> dict:
    """Reviewer suspicion: an allocation that raises while a data file is open leaks the fd."""
    write_csv(data / "big.csv", 200_000, 40)            # ~11 MB
    (data / "small.csv").write_text("id\n1\n2\n")
    variants = {}
    write_csv(data / "mid.csv", 120_000, 40)
    for name, args, pre_fail in (("query_budget_4mb", ["--max-query-memory-mb", "4"], False),
                                 ("ingest_limit_1mb", ["--max-ingest-bytes", "1000000"], False),
                                 ("after_failed_query_16mb", ["--max-query-memory-mb", "16"], True)):
        s = Session(engine, data, args)
        ok0 = code(s.req({"op": "load", "table": "s0", "format": "csv", "path": "small.csv"}))
        pre = None
        if pre_fail:   # leaves the engine in the state probe_limit_after_failed_query looks for
            s.req({"op": "load", "table": "m", "format": "csv", "path": "mid.csv"})
            pre = code(s.req({"op": "query", "sql": FAILING_QUERY}))
        fd0 = tree_fds(s.proc.pid)
        codes: dict[str, int] = {}
        for _ in range(100):
            c = code(s.req({"op": "load", "table": "big", "format": "csv", "path": "big.csv", "replace": True}))
            codes[c] = codes.get(c, 0) + 1
            if c == "NO_RESPONSE":
                break
        fd1 = tree_fds(s.proc.pid) if s.alive() else None
        after = code(s.req({"op": "load", "table": "s1", "format": "csv", "path": "small.csv"}))
        alive = s.alive()
        info = s.close()
        failed = sum(v for k, v in codes.items() if k != "ok")
        if not alive or "NO_RESPONSE" in codes:
            verdict = "fail"
        elif failed == 0:
            verdict = "not_triggered"
        elif fd1 is not None and fd1 - fd0 >= failed // 2:
            verdict = "fail"
        else:
            verdict = "pass"
        variants[name] = {"verdict": verdict, "initial_small_load": ok0, "failed_query_first": pre, "big_load_codes": codes,
                          "fds_before": fd0, "fds_after": fd1, "small_load_after": after, **info}
    return variants


def probe_limit_after_failed_query(engine: str, data: Path) -> dict:
    """Reviewer suspicion: a failed query leaves the query memory budget set for later requests."""
    write_csv(data / "mid.csv", 120_000, 40)            # ~6.5 MB
    s = Session(engine, data, ["--max-query-memory-mb", "16"])
    first = code(s.req({"op": "load", "table": "m", "format": "csv", "path": "mid.csv", "replace": True}))
    q = code(s.req({"op": "query", "sql": FAILING_QUERY}))
    second = code(s.req({"op": "load", "table": "m", "format": "csv", "path": "mid.csv", "replace": True}))
    alive = s.alive()
    info = s.close()
    if not alive or "NO_RESPONSE" in (first, q, second):
        verdict = "fail"
    elif first != "ok" or q != "RESOURCE_LIMIT":
        verdict = "not_triggered"
    else:
        verdict = "pass" if second == "ok" else "fail"
    return {"verdict": verdict, "load_before": first, "query": q, "load_after": second, **info}


def probe_long_or_chain(engine: str, data: Path) -> dict:
    """Reviewer suspicion: left-deep AND/OR chains are not depth-limited, and recursion over them
    overflows a (worker) stack. Any response (result or error) passes; a crash or hang fails.
    The engines' documented minimum-rows settings for parallel execution are lowered so that the
    small table is split into parallel tasks (variables unknown to an engine are ignored)."""
    nrows = 20_000
    rows = "\n".join(str(i) for i in range(nrows))
    (data / "n.csv").write_text("x\n" + rows + "\n")
    out, deaths, hung = {}, [], False
    env = {"PQ_PAR_MIN": "1", "PQ_PARALLEL_MIN_ROWS": "1"}
    s = Session(engine, data, [], env)
    out["load"] = code(s.req({"op": "load", "table": "n", "format": "csv", "path": "n.csv"}))
    for op in ("OR", "AND"):
        for terms in (10_000, 100_000):
            if op == "OR":
                pred = " OR ".join(f"x = {i}" for i in range(terms))
            else:
                pred = " AND ".join(f"x <> {-i - 1}" for i in range(terms))
            for label, opts in (("row", {"mode": "row", "threads": 1}),
                                ("vectorized", {"mode": "vectorized", "threads": 1}),
                                ("parallel", {"mode": "vectorized", "threads": 8}),
                                ("auto", {})):
                if not s.alive() or hung:
                    if hung:   # a late response would otherwise be read as the next case's answer
                        os.killpg(s.proc.pid, 9)
                    end = s.close()
                    if not hung:
                        deaths.append(end)
                    s = Session(engine, data, [], env)
                    s.req({"op": "load", "table": "n", "format": "csv", "path": "n.csv"})
                r = s.req({"op": "query", "sql": f"SELECT count(*) FROM n WHERE {pred}",
                           "options": {**opts, "timeout_ms": 120_000}}, timeout=180)
                c = code(r)
                hung = c == "NO_RESPONSE" and s.alive()
                rc = None
                if c == "ok":
                    rc = (r.get("rows") or [[None]])[0][0]
                out[f"{op}_{terms}_{label}"] = {"result": "HANG" if hung else c, "count": rc, "alive": s.alive()}
    info = s.close()
    if info["exit_code"] not in (0, None):
        deaths.append(info)
    crashed = [k for k, v in out.items() if isinstance(v, dict) and not v["alive"]]
    hangs = [k for k, v in out.items() if isinstance(v, dict) and v["result"] == "HANG"]
    wrong = [k for k, v in out.items() if isinstance(v, dict) and v["result"] == "ok"
             and v["count"] != (min(int(k.split("_")[1]), nrows) if k.startswith("OR") else nrows)]
    return {"verdict": "fail" if crashed or hangs or wrong else "pass", "crashed": crashed,
            "hung": hangs, "hang_rule": "no response within 180 s although options.timeout_ms = 120000",
            "wrong_result": wrong,
            "cases": out, "engine_exits": deaths}


def probe_session_huge_line(engine: str, data: Path) -> dict:
    """Observation: session mode has no request-size limit in the spec; a huge malformed line must
    still produce an error response and leave the engine usable."""
    s = Session(engine, data, [])
    base = tree_rss_mib(s.proc.pid)
    sampler = RssSampler(s.proc.pid)
    r = s.send_raw(b"{" + b"x" * (256 << 20), timeout=300)
    peak = sampler.stop()
    after = code(s.req({"op": "query", "sql": "SELECT 1"}))
    alive = s.alive()
    info = s.close()
    verdict = "fail" if r is None or not alive or after != "ok" else "observation"
    return {"verdict": verdict, "response": code(r) if r and "_unparsable" not in r else r,
            "next_request": after, "rss_base_mib": round(base), "rss_peak_mib": round(peak), **info}


def probe_http_crlf_flood(engine: str, data: Path) -> dict:
    """Reviewer suspicion: CR/LF bytes before a request line are skipped without being consumed,
    so a client sending only CRLFs grows the connection buffer without bound. Resident memory is
    sampled after 128 MiB, 512 MiB and 1 GiB: a retained buffer keeps growing with the bytes sent,
    while uncollected garbage in a managed runtime levels off."""
    err = tempfile.TemporaryFile()
    p = subprocess.Popen([engine, "serve", "--port", "0", "--data-dir", str(data)], stdout=subprocess.PIPE,
                         stderr=err, start_new_session=True)
    try:
        ev = json.loads(p.stdout.readline())
        host, port = ev.get("host", "127.0.0.1"), ev["port"]
        base = tree_rss_mib(p.pid)
        sampler = RssSampler(p.pid)
        sent, closed, stages = 0, False, {}
        sock = socket.create_connection((host, port), timeout=10)
        chunk = b"\r\n" * (512 << 10)
        try:
            for mib in (128, 512, 1024):
                while sent < (mib << 20):
                    sock.sendall(chunk)
                    sent += len(chunk)
                time.sleep(1)
                stages[mib] = round(tree_rss_mib(p.pid) - base)
        except OSError:
            closed = True
        time.sleep(1)
        peak = sampler.stop()
        sock.close()
        alive = p.poll() is None
        healthy = False
        if alive:
            body = json.dumps({"sql": "SELECT 1"}).encode()
            with socket.create_connection((host, port), timeout=30) as c:
                c.sendall(b"POST /v1/query HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n"
                          b"Content-Length: " + str(len(body)).encode() + b"\r\nConnection: close\r\n\r\n" + body)
                resp = b""
                while chunk_ := c.recv(65536):
                    resp += chunk_
                healthy = resp.startswith(b"HTTP/1.1 200")
        # The header block of one request is a few KiB (a 64 KiB cap is common): memory that keeps
        # growing with the bytes sent (doubling from 512 MiB to 1 GiB) means they are buffered without bound.
        grew = peak - base
        unbounded = len(stages) == 3 and stages[1024] > 256 and stages[1024] >= 1.6 * max(stages[512], 1)
        verdict = "fail" if not alive or not healthy or unbounded else "pass"
        return {"verdict": verdict, "bytes_sent": sent, "rss_growth_mib": round(grew), "rss_growth_by_mib_sent": stages, "server_closed_connection": closed,
                "rss_base_mib": round(base), "rss_peak_mib": round(peak), "server_alive": alive,
                "server_healthy_after": healthy}
    finally:
        if p.poll() is None:
            os.killpg(p.pid, 15)
            try:
                p.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, 9)
                p.wait()


def probe_parallel_memory_budget(engine: str, data: Path) -> dict:
    """Reviewer suspicion: each parallel task gets the whole per-query budget. Measurement: outcome
    and peak resident memory of a high-cardinality GROUP BY under a 64 MiB budget, 1 vs 8 threads."""
    write_csv(data / "g.csv", 1_000_000, 8)
    out = {}
    s = Session(engine, data, ["--max-query-memory-mb", "64"])
    out["load"] = code(s.req({"op": "load", "table": "g", "format": "csv", "path": "g.csv"}))
    for threads in (1, 8):
        base = tree_rss_mib(s.proc.pid)
        sampler = RssSampler(s.proc.pid)
        r = s.req({"op": "query", "sql": "SELECT k, s, count(*) FROM g GROUP BY k, s",
                   "options": {"result": "count", "threads": threads, "mode": "vectorized"}})
        peak = sampler.stop()
        out[f"threads_{threads}"] = {"result": code(r), "rss_before_mib": round(base), "rss_peak_mib": round(peak),
                                     "growth_mib": round(peak - base)}
    alive = s.alive()
    info = s.close()
    t1, t8 = out["threads_1"], out["threads_8"]
    if not alive:
        verdict = "fail"
    elif t1["result"] == "RESOURCE_LIMIT" and t8["result"] == "ok":
        verdict = "fail"     # the same query passes the budget only because it ran in parallel
    else:
        verdict = "observation"
    return {"verdict": verdict, **out, **info}


def limit_cases() -> tuple[list, list]:
    """CR-6 (spec/changes/expression-limits.md §5) on n(x) = 0..99: (name, sql, expected first cell)."""
    def where(pred: str) -> str:
        return f"SELECT count(*) FROM n WHERE {pred}"
    lit = "a" * 524_000
    minimum = [
        ("parens_998", where("(" * 998 + "x >= 0" + ")" * 998), 100),
        ("abs_998", where("ABS(" * 998 + "x" + ")" * 998 + " >= 0"), 100),
        ("unary_minus_998", where("- " * 998 + "x >= 0"), 100),
        ("not_998", where("NOT " * 998 + "x >= 0"), 100),
        ("or_10000", where(" OR ".join(f"x = {i}" for i in range(10_000))), 100),
        ("and_10000", where(" AND ".join(f"x <> {-i - 1}" for i in range(10_000))), 100),
        ("sum_10000", "SELECT max(x" + " + 1" * 9_999 + ") FROM n", 99 + 9_999),
        ("in_10000", where("x IN (" + ", ".join(str(i) for i in range(10_000)) + ")"), 100),
        ("case_5000", "SELECT sum(CASE " + " ".join(f"WHEN x = {i} THEN {i}" for i in range(5_000))
         + " ELSE 0 END) FROM n", 4950),
        ("text_1mib", where(f"'{lit}' = '{lit}'"), 100),
    ]
    beyond = [
        ("parens_100000", where("(" * 100_000 + "x >= 0" + ")" * 100_000), 100),
        ("or_100000", where(" OR ".join(f"x = {i}" for i in range(100_000))), 100),
        ("in_100000", where("x IN (" + ", ".join(str(i) for i in range(100_000)) + ")"), 100),
    ]
    return minimum, beyond


def probe_expression_limits(engine: str, data: Path) -> dict:
    """CR-6 (resolves SPEC-Q-002): minimum statement sizes must work in every execution mode;
    beyond them the answer is the result, RESOURCE_LIMIT or TIMEOUT within timeout + 1 s
    (+ 4 s scheduling slack), never a crash, a hang or a size-caused PARSE_ERROR."""
    (data / "n.csv").write_text("x\n" + "\n".join(str(i) for i in range(100)) + "\n")
    env = {"PQ_PAR_MIN": "1", "PQ_PARALLEL_MIN_ROWS": "1"}
    modes = (("row", {"mode": "row", "threads": 1}), ("vectorized", {"mode": "vectorized", "threads": 1}),
             ("parallel", {"mode": "vectorized", "threads": 8}), ("auto", {}))
    minimum, beyond = limit_cases()
    state: dict = {"s": None, "deaths": []}

    def session() -> Session:
        s = state["s"]
        if s is not None and s.alive():
            return s
        if s is not None:
            state["deaths"].append(s.close())
        s = state["s"] = Session(engine, data, [], env)
        s.req({"op": "load", "table": "n", "format": "csv", "path": "n.csv"})
        return s

    def run(sql: str, opts: dict, timeout_ms: int, wait: float) -> tuple[str, object, float, bool]:
        s = session()
        t0 = time.monotonic()
        r = s.req({"op": "query", "sql": sql, "options": {**opts, "timeout_ms": timeout_ms}}, timeout=wait)
        dt = time.monotonic() - t0
        c, alive = code(r), s.alive()
        if c == "NO_RESPONSE" and alive:   # hung: a late reply must not answer the next case
            os.killpg(s.proc.pid, 9)
            s.close()
            state["s"] = None
            return "HANG", None, dt, True
        val = (r.get("rows") or [[None]])[0][0] if c == "ok" else None
        return c, val, dt, alive

    caps = (session().req({"op": "capabilities"}) or {}).get("capabilities") or []
    out: dict = {"claims_capability": "change.expression_limits" in caps, "minimum": {}, "beyond": {}}
    min_fail, beyond_fail = [], []
    for name, sql, want in minimum:
        for label, opts in modes:
            c, val, dt, alive = run(sql, opts, 120_000, 180)
            ok = c == "ok" and val == want
            out["minimum"][f"{name}_{label}"] = {"result": c if alive else "CRASH", "value": val,
                                                 "seconds": round(dt, 2), "pass": ok}
            if not ok:
                min_fail.append(f"{name}_{label}")
    for name, sql, want in beyond:
        for label, opts in modes:
            c, val, dt, alive = run(sql, opts, 30_000, 35)
            ok = alive and ((c == "ok" and val == want) or c in ("RESOURCE_LIMIT", "TIMEOUT"))
            out["beyond"][f"{name}_{label}"] = {
                "result": c if alive else "CRASH", "value": val, "seconds": round(dt, 2),
                "late_by_s": round(dt - 30, 2) if c in ("TIMEOUT", "HANG") else None, "pass": ok}
            if not ok:
                beyond_fail.append(f"{name}_{label}")
    if state["s"] is not None:
        end = state["s"].close()
        if end["exit_code"] not in (0, None):
            state["deaths"].append(end)
    return {"verdict": "fail" if min_fail or beyond_fail else "pass",
            "informational": not out["claims_capability"],
            "minimum_failures": min_fail, "beyond_failures": beyond_fail, **out,
            "engine_exits": state["deaths"]}


PROBES = {
    "fd_after_failed_loads": probe_fd_after_failed_loads,
    "limit_after_failed_query": probe_limit_after_failed_query,
    "long_or_chain": probe_long_or_chain,
    "session_huge_line": probe_session_huge_line,
    "http_crlf_flood": probe_http_crlf_flood,
    "parallel_memory_budget": probe_parallel_memory_budget,
    "expression_limits": probe_expression_limits,
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True)
    ap.add_argument("--only", default="")
    ap.add_argument("--report")
    ap.add_argument("--merge", action="store_true", help="update the probes in an existing --report file")
    a = ap.parse_args()
    engine = str(Path(a.engine).resolve())
    names = [n for n in a.only.split(",") if n] or list(PROBES)
    res = {"engine": a.engine, "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "probes": {}}
    if a.merge and a.report and Path(a.report).exists():
        res = json.loads(Path(a.report).read_text())
        res.setdefault("reruns", []).append({"probes": names, "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
    for n in names:
        with tempfile.TemporaryDirectory(prefix="pqprobe-") as d:
            t0 = time.monotonic()
            try:
                r = PROBES[n](engine, Path(d))
            except Exception as e:  # noqa: BLE001 - a probe error is reported, not raised
                r = {"verdict": "probe_error", "error": repr(e)}
            r["seconds"] = round(time.monotonic() - t0, 1)
        res["probes"][n] = r
        v = r.get("verdict") or {k: x.get("verdict") for k, x in r.items() if isinstance(x, dict)}
        print(f"{n}: {v}", flush=True)
    if a.report:
        Path(a.report).write_text(json.dumps(res, indent=1) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
