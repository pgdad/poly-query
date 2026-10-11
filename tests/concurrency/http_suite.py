#!/usr/bin/env python3
"""PolyQuery Phase 4 HTTP & concurrency conformance suite (protocol.md §7, concurrency.md).

  http_suite.py --engine implementations/go/bin/polyquery [--report out.json] [-v]

Every check starts its own server process with the options it needs. Checks
are black-box: only the HTTP API, stdout/stderr and process signals are used.
"""
from __future__ import annotations

import argparse
import http.client
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import traceback
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIXTURES = HERE.parent / "conformance" / "fixtures"
PEOPLE_CSV = (FIXTURES / "people.csv").read_bytes()


class CheckFailed(Exception):
    pass


def expect(cond: bool, msg: str) -> None:
    if not cond:
        raise CheckFailed(msg)


class Server:
    def __init__(self, launcher: str, args: list[str], logdir: Path, name: str):
        self.data = Path(tempfile.mkdtemp(prefix="pqhttp-"))
        (self.data / "fixtures").symlink_to(FIXTURES)
        self.stderr_path = logdir / f"{name}.stderr"
        self.stderr = open(self.stderr_path, "wb")
        t0 = time.monotonic()
        self.proc = subprocess.Popen([launcher, "serve", "--port", "0", "--data-dir", str(self.data), *args],
                                     stdout=subprocess.PIPE, stderr=self.stderr, start_new_session=True)
        line = self._readline(timeout=60)
        self.startup_seconds = time.monotonic() - t0
        try:
            ev = json.loads(line)
        except (json.JSONDecodeError, TypeError) as e:
            self.kill()
            raise CheckFailed(f"bad listening line: {line!r}") from e
        expect(ev.get("event") == "listening" and isinstance(ev.get("port"), int), f"bad listening event {ev}")
        self.host, self.port = ev.get("host", "127.0.0.1"), ev["port"]
        threading.Thread(target=self._drain, daemon=True).start()

    def _readline(self, timeout: float):
        box: list = []
        t = threading.Thread(target=lambda: box.append(self.proc.stdout.readline()), daemon=True)
        t.start()
        t.join(timeout)
        if not box:
            self.kill()
            raise CheckFailed("server did not print listening line in time")
        return box[0].decode("utf-8", "replace")

    def _drain(self) -> None:
        for _ in self.proc.stdout:
            pass

    def conn(self, timeout: float = 30) -> http.client.HTTPConnection:
        return http.client.HTTPConnection(self.host, self.port, timeout=timeout)

    def req(self, method: str, path: str, body=None, headers=None, timeout: float = 30) -> tuple[int, dict, bytes]:
        c = self.conn(timeout)
        try:
            if isinstance(body, (dict, list)):
                body = json.dumps(body).encode()
                headers = {"Content-Type": "application/json", **(headers or {})}
            c.request(method, path, body=body, headers=headers or {})
            r = c.getresponse()
            return r.status, {k.lower(): v for k, v in r.getheaders()}, r.read()
        finally:
            c.close()

    def json(self, method: str, path: str, body=None, timeout: float = 30) -> tuple[int, dict, dict]:
        st, h, b = self.req(method, path, body, timeout=timeout)
        try:
            return st, h, json.loads(b)
        except json.JSONDecodeError as e:
            raise CheckFailed(f"{method} {path}: non-JSON body (status {st}): {b[:200]!r}") from e

    def query(self, sql: str, options: dict | None = None, timeout: float = 30) -> tuple[int, dict, dict]:
        body = {"sql": sql}
        if options:
            body["options"] = options
        return self.json("POST", "/v1/query", body, timeout=timeout)

    def load_people(self, name: str = "people") -> None:
        st, _, b = self.json("PUT", f"/v1/tables/{name}?format=csv", PEOPLE_CSV)
        expect(st == 201 and b.get("ok") is True, f"PUT table: {st} {b}")

    def metrics(self) -> dict[str, float]:
        st, h, b = self.req("GET", "/metrics")
        expect(st == 200, f"/metrics status {st}")
        out: dict[str, float] = {}
        for line in b.decode().splitlines():
            if not line or line.startswith("#"):
                continue
            try:
                k, v = line.rsplit(" ", 1)
                out[k.strip()] = float(v)
            except ValueError:
                continue
        return out

    def kill(self) -> None:
        try:
            os.killpg(self.proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass

    def stop(self) -> None:
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(timeout=20)
            except subprocess.TimeoutExpired:
                self.kill()
        self.stderr.close()


def metric(m: dict[str, float], name: str, **labels) -> float:
    total, found = 0.0, False
    for k, v in m.items():
        base = k.split("{", 1)[0]
        if base != name:
            continue
        if labels:
            lab = k[k.find("{"):] if "{" in k else ""
            if not all(f'{lk}="{lv}"' in lab for lk, lv in labels.items()):
                continue
        total += v
        found = True
    if not found:
        raise CheckFailed(f"metric {name}{labels or ''} missing")
    return total


def bg(fn, *a, **kw):
    box: dict = {}

    def run():
        try:
            box["result"] = fn(*a, **kw)
        except BaseException as e:  # noqa: BLE001
            box["error"] = e
    t = threading.Thread(target=run, daemon=True)
    t.start()
    return t, box


# ---------------------------------------------------------------- checks

CHECKS = []


def check(name: str, args: list[str] | None = None):
    def deco(fn):
        CHECKS.append((name, args or [], fn))
        return fn
    return deco


@check("health_version_capabilities")
def _(s: Server):
    st, _, b = s.json("GET", "/health")
    expect(st == 200 and b.get("status") == "ok", f"/health {st} {b}")
    st, _, b = s.json("GET", "/v1/version")
    expect(st == 200 and b.get("protocol_version") == 1, f"/v1/version {st} {b}")
    st, _, b = s.json("GET", "/v1/capabilities")
    caps = b.get("capabilities") or []
    expect(st == 200 and "phase4" in caps, f"/v1/capabilities lacks phase4: {caps}")


@check("table_lifecycle")
def _(s: Server):
    s.load_people()
    st, _, b = s.json("GET", "/v1/tables")
    expect(st == 200 and [t["name"] for t in b.get("tables", [])] == ["people"], f"tables {b}")
    st, _, b = s.json("GET", "/v1/tables/people/schema")
    expect(st == 200 and b.get("row_count") == 8 and len(b.get("columns", [])) == 7, f"schema {b}")
    st, _, b = s.json("GET", "/v1/tables/people/stats")
    expect(st == 200 and b.get("row_count") == 8, f"stats {b}")
    st, _, b = s.json("PUT", "/v1/tables/people?format=csv", PEOPLE_CSV)
    expect(st == 409 and (b.get("error") or {}).get("code") == "ALREADY_EXISTS", f"duplicate PUT {st} {b}")
    st, _, b = s.json("PUT", "/v1/tables/people?format=csv&replace=true", b"a,b\n1,2\n")
    expect(st == 201 and b.get("row_count") == 1, f"replace PUT {st} {b}")
    st, _, b = s.json("PUT", "/v1/tables/j?format=jsonl", b'{"x":1}\n{"x":2}\n')
    expect(st == 201 and b.get("row_count") == 2, f"jsonl PUT {st} {b}")
    st, _, b = s.json("PUT", "/v1/tables/bad?format=csv", b"a,b\n1\n")
    expect(st == 400 and (b.get("error") or {}).get("code") == "INGEST_ERROR", f"bad csv {st} {b}")
    st, _, b = s.json("DELETE", "/v1/tables/people")
    expect(st == 200 and b.get("ok") is True, f"DELETE {st} {b}")
    st, _, b = s.json("GET", "/v1/tables/people/schema")
    expect(st == 404 and (b.get("error") or {}).get("code") == "NOT_FOUND", f"schema after delete {st} {b}")


@check("query_and_error_mapping")
def _(s: Server):
    s.load_people()
    st, h, b = s.query("SELECT id, name FROM people WHERE id <= 2 ORDER BY id")
    expect(st == 200 and b.get("rows") == [[1, "Alice"], [2, "Bob"]], f"query {st} {b}")
    expect("x-polyquery-query-id" in h, "missing X-PolyQuery-Query-Id header")
    st, h, b = s.query("SELECT 1", {"query_id": "my-id-1"})
    expect(st == 200 and h.get("x-polyquery-query-id") == "my-id-1", f"query_id header {h}")
    cases = [("SELEC 1", 400, "PARSE_ERROR"), ("SELECT nope FROM people", 400, "SEMANTIC_ERROR"),
             ("SELECT 1/0", 400, "DIVISION_BY_ZERO"), ("SELECT 1 = 'a'", 400, "TYPE_ERROR")]
    for sql, code, err in cases:
        st, _, b = s.query(sql)
        expect(st == code and (b.get("error") or {}).get("code") == err, f"{sql!r}: {st} {b}")
    st, _, b = s.json("POST", "/v1/query", b"{not json")
    expect(st == 400 and (b.get("error") or {}).get("code") == "INVALID_REQUEST", f"malformed json {st} {b}")
    st, _, b = s.json("GET", "/v1/nope")
    expect(st == 404 and (b.get("error") or {}).get("code") == "NOT_FOUND", f"unknown path {st} {b}")
    st, _, b = s.json("GET", "/v1/query")
    expect(st == 405, f"wrong method {st} {b}")
    st, _, b = s.json("POST", "/v1/request", {"op": "schema", "table": "people"})
    expect(st == 200 and b.get("ok") is True, f"/v1/request {st} {b}")
    st, _, b = s.json("POST", "/v1/request", {"op": "load", "table": "x", "format": "csv", "path": "/etc/passwd"})
    expect(st == 403 and (b.get("error") or {}).get("code") == "ACCESS_DENIED", f"access denied {st} {b}")
    st, _, b = s.json("POST", "/v1/explain", {"sql": "SELECT id FROM people"})
    expect(st == 200 and isinstance(b.get("plan"), dict), f"/v1/explain {st} {b}")


@check("keep_alive")
def _(s: Server):
    c = s.conn()
    try:
        for _ in range(5):
            c.request("GET", "/health")
            r = c.getresponse()
            r.read()
            expect(r.status == 200, "keep-alive request failed")
    finally:
        c.close()


@check("streaming")
def _(s: Server):
    rows = "\n".join(f"{i},{i % 7}" for i in range(1, 30001))
    st, _, b = s.json("PUT", "/v1/tables/big?format=csv", ("n,m\n" + rows + "\n").encode())
    expect(st == 201, f"load big {st} {b}")
    c = s.conn(60)
    try:
        c.request("POST", "/v1/query/stream", json.dumps({"sql": "SELECT n, m FROM big ORDER BY n"}),
                  {"Content-Type": "application/json"})
        r = c.getresponse()
        expect(r.status == 200, f"stream status {r.status}")
        expect("ndjson" in (r.getheader("Content-Type") or ""), f"content-type {r.getheader('Content-Type')}")
        expect((r.getheader("Transfer-Encoding") or "").lower() == "chunked", "stream must be chunked")
        lines = [json.loads(l) for l in r.read().decode().splitlines() if l.strip()]
    finally:
        c.close()
    expect(lines and lines[0].get("type") == "header", f"first line {lines[:1]}")
    expect(lines[0].get("columns") == [{"name": "n", "type": "INT64"}, {"name": "m", "type": "INT64"}], "header columns")
    expect(lines[-1].get("type") == "end" and lines[-1].get("row_count") == 30000, f"end line {lines[-1]}")
    data = [row for l in lines if l.get("type") == "rows" for row in l["rows"]]
    expect(all(len(l["rows"]) <= 10000 for l in lines if l.get("type") == "rows"), "batch larger than 10000 rows")
    expect(len(data) == 30000 and data[0] == [1, 1] and data[-1] == [30000, 30000 % 7], "streamed rows mismatch")
    # errors before the header: normal error response
    st, _, b = s.json("POST", "/v1/query/stream", {"sql": "SELECT nope FROM big"})
    expect(st == 400 and (b.get("error") or {}).get("code") == "SEMANTIC_ERROR", f"stream early error {st} {b}")
    # runtime error: either an error response, or 200 with a final error line and no end line
    st, _, raw = s.req("POST", "/v1/query/stream", {"sql": "SELECT n, 10 / (n - 20000) AS x FROM big ORDER BY n"})
    if st == 200:
        ls = [json.loads(l) for l in raw.decode().splitlines() if l.strip()]
        expect(ls[-1].get("type") == "error" and ls[-1]["error"]["code"] == "DIVISION_BY_ZERO",
               f"mid-stream error must end with an error line: {ls[-1]}")
        expect(not any(l.get("type") == "end" for l in ls), "stream with error must not have an end line")
    else:
        b = json.loads(raw)
        expect(st == 400 and b["error"]["code"] == "DIVISION_BY_ZERO", f"stream runtime error {st} {b}")


@check("metrics")
def _(s: Server):
    s.load_people()
    m0 = s.metrics()
    for name in ["polyquery_queries_total", "polyquery_queries_in_flight", "polyquery_queries_queued",
                 "polyquery_queries_rejected_total", "polyquery_queries_cancelled_total",
                 "polyquery_queries_timeout_total", "polyquery_query_duration_seconds_count",
                 "polyquery_query_duration_seconds_sum", "polyquery_tables", "polyquery_uptime_seconds"]:
        metric(m0, name)
    ok0, err0 = metric(m0, "polyquery_queries_total", status="ok"), metric(m0, "polyquery_queries_total", status="error")
    for _ in range(3):
        s.query("SELECT COUNT(*) FROM people")
    s.query("SELECT nope FROM people")
    m1 = s.metrics()
    expect(metric(m1, "polyquery_queries_total", status="ok") - ok0 == 3, "ok counter did not increase by 3")
    expect(metric(m1, "polyquery_queries_total", status="error") - err0 == 1, "error counter did not increase by 1")
    expect(metric(m1, "polyquery_tables") == 1, "polyquery_tables != 1")


@check("timeout", ["--enable-test-functions"])
def _(s: Server):
    t0 = time.monotonic()
    st, _, b = s.query("SELECT PQ_SLEEP(5000)", {"timeout_ms": 200})
    dt_ = time.monotonic() - t0
    expect(st == 504 and (b.get("error") or {}).get("code") == "TIMEOUT", f"timeout {st} {b}")
    expect(dt_ < 1.5, f"timeout took {dt_:.2f}s")
    expect(metric(s.metrics(), "polyquery_queries_timeout_total") >= 1, "timeout counter")


@check("server_default_timeout", ["--enable-test-functions", "--query-timeout-ms", "300"])
def _(s: Server):
    st, _, b = s.query("SELECT PQ_SLEEP(5000)")
    expect(st == 504 and (b.get("error") or {}).get("code") == "TIMEOUT", f"server timeout {st} {b}")
    st, _, b = s.query("SELECT PQ_SLEEP(10)")
    expect(st == 200, f"short query under server timeout {st} {b}")


@check("cancellation", ["--enable-test-functions"])
def _(s: Server):
    t, box = bg(s.query, "SELECT PQ_SLEEP(10000)", {"query_id": "q-cancel"}, 30)
    deadline = time.monotonic() + 5
    listed = False
    while time.monotonic() < deadline:
        st, _, b = s.json("GET", "/v1/queries")
        if any(q.get("query_id") == "q-cancel" for q in b.get("queries", [])):
            listed = True
            break
        time.sleep(0.05)
    expect(listed, "running query not listed in /v1/queries")
    st, _, b = s.json("POST", "/v1/query", {"sql": "SELECT 1", "options": {"query_id": "q-cancel"}})
    expect(st == 409 and (b.get("error") or {}).get("code") == "ALREADY_EXISTS", f"duplicate query_id {st} {b}")
    t0 = time.monotonic()
    st, _, b = s.json("DELETE", "/v1/queries/q-cancel")
    expect(st == 200 and b.get("cancelled") is True, f"cancel {st} {b}")
    t.join(5)
    expect(not t.is_alive(), "cancelled query did not return")
    expect(time.monotonic() - t0 < 1.5, "cancellation too slow")
    st, _, b = box["result"]
    expect(st == 409 and (b.get("error") or {}).get("code") == "CANCELLED", f"cancelled query response {st} {b}")
    st, _, b = s.json("DELETE", "/v1/queries/q-cancel")
    expect(st == 404, f"cancel finished query {st} {b}")
    expect(metric(s.metrics(), "polyquery_queries_cancelled_total") >= 1, "cancelled counter")


@check("backpressure_overloaded", ["--enable-test-functions", "--workers", "2", "--queue-depth", "1"])
def _(s: Server):
    threads = [bg(s.query, "SELECT PQ_SLEEP(2000)", None, 30) for _ in range(3)]
    time.sleep(0.6)
    t0 = time.monotonic()
    st, _, b = s.query("SELECT PQ_SLEEP(2000)")
    expect(st == 503 and (b.get("error") or {}).get("code") == "OVERLOADED", f"4th query should be rejected: {st} {b}")
    expect(time.monotonic() - t0 < 0.5, "rejection was not immediate")
    t0 = time.monotonic()
    st, _, _b = s.json("GET", "/health")
    expect(st == 200 and time.monotonic() - t0 < 0.5, "/health not responsive while workers busy")
    m = s.metrics()
    expect(metric(m, "polyquery_queries_rejected_total") >= 1, "rejected counter")
    expect(metric(m, "polyquery_queries_in_flight") == 2, f"in_flight should be 2, got {metric(m, 'polyquery_queries_in_flight')}")
    expect(metric(m, "polyquery_queries_queued") == 1, "queued should be 1")
    for t, box in threads:
        t.join(15)
        expect("result" in box and box["result"][0] == 200, f"admitted query failed: {box}")


@check("queued_time_counts_toward_timeout", ["--enable-test-functions", "--workers", "1", "--queue-depth", "4"])
def _(s: Server):
    t, box = bg(s.query, "SELECT PQ_SLEEP(1500)", None, 30)
    time.sleep(0.3)
    st, _, b = s.query("SELECT 1", {"timeout_ms": 400})
    expect(st == 504 and (b.get("error") or {}).get("code") == "TIMEOUT", f"queued query should time out: {st} {b}")
    t.join(10)


@check("snapshot_isolation", ["--enable-test-functions"])
def _(s: Server):
    rows = "\n".join(str(i) for i in range(1, 501))
    st, _, _b = s.json("PUT", "/v1/tables/t?format=csv", ("v\n" + rows + "\n").encode())
    expect(st == 201, "load t")
    t, box = bg(s.query, "SELECT COUNT(*) AS n, SUM(PQ_SLEEP(2)) AS z, SUM(v) AS s FROM t", None, 60)
    time.sleep(0.3)
    st, _, b = s.json("PUT", "/v1/tables/t?format=csv&replace=true", b"v\n1\n2\n")
    expect(st == 201, f"replace during query {st} {b}")
    st, _, b = s.query("SELECT COUNT(*) FROM t")
    expect(st == 200 and b["rows"] == [[2]], f"new snapshot visible to new queries: {b}")
    t.join(30)
    st, _, b = box["result"]
    expect(st == 200 and b["rows"][0][0] == 500 and b["rows"][0][2] == 125250, f"long query must see its snapshot: {b}")
    # dropping a table while a query reads it
    t, box = bg(s.query, "SELECT COUNT(*), SUM(PQ_SLEEP(200)) FROM t", None, 30)
    time.sleep(0.1)
    st, _, _b = s.json("DELETE", "/v1/tables/t")
    expect(st == 200, "drop during query")
    t.join(10)
    expect(box["result"][0] == 200 and box["result"][2]["rows"][0][0] == 2, f"query on dropped table {box}")


@check("concurrent_readers", ["--workers", "8", "--queue-depth", "64"])
def _(s: Server):
    s.load_people()
    expected = s.query("SELECT city, COUNT(*) AS n FROM people GROUP BY city ORDER BY city")[2]["rows"]
    results = []
    lock = threading.Lock()

    def worker():
        for _ in range(10):
            st, _, b = s.query("SELECT city, COUNT(*) AS n FROM people GROUP BY city ORDER BY city")
            with lock:
                results.append((st, b.get("rows")))
    ts = [threading.Thread(target=worker) for _ in range(16)]
    for t in ts:
        t.start()
    for t in ts:
        t.join(60)
    expect(len(results) == 160 and all(st == 200 and r == expected for st, r in results),
           f"concurrent results differ: {[r for r in results if r[0] != 200][:3]}")


@check("client_disconnect_cancels", ["--enable-test-functions"])
def _(s: Server):
    sock = socket.create_connection((s.host, s.port))
    body = json.dumps({"sql": "SELECT PQ_SLEEP(10000)", "options": {"query_id": "q-disc"}}).encode()
    sock.sendall(b"POST /v1/query HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: "
                 + str(len(body)).encode() + b"\r\n\r\n" + body)
    time.sleep(0.4)
    sock.close()
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        st, _, b = s.json("GET", "/v1/queries")
        if not any(q.get("query_id") == "q-disc" for q in b.get("queries", [])):
            return
        time.sleep(0.1)
    raise CheckFailed("query still running 3s after client disconnect")


@check("request_size_limit", ["--max-request-bytes", "1000"])
def _(s: Server):
    st, _, b = s.json("PUT", "/v1/tables/x?format=csv", b"a\n" + b"1\n" * 2000)
    expect(st == 413 and (b.get("error") or {}).get("code") == "RESOURCE_LIMIT", f"oversized body {st} {b}")


@check("malformed_chunked_body", ["--max-request-bytes", "1000"])
def _(s: Server):
    # chunk-size is 1*HEXDIG (RFC 9112 §7.1). A negative size is malformed framing: the server
    # must reject it when it reads the size line, not keep reading the body (which would let it
    # bypass --max-request-bytes). The client keeps the connection open, so a server that reads
    # on to end-of-stream never answers.
    sock = socket.create_connection((s.host, s.port))
    sock.settimeout(5)
    sock.sendall(b"PUT /v1/tables/neg?format=csv HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
                 b"-5\r\n" + b"a\n" + b"1\n" * 2000)
    try:
        head = sock.recv(64).decode("latin-1", "replace")
    except OSError:
        head = ""
    finally:
        sock.close()
    status = int(head.split()[1]) if head.startswith("HTTP/1.") and len(head.split()) > 1 else None
    expect(status is not None and 400 <= status < 500,
           f"negative chunk size: expected a 4xx answer within 5 s, got {head[:40]!r}")
    st, _, b = s.json("GET", "/v1/tables")
    expect(st == 200, f"server unresponsive after malformed chunked body: {st}")
    names = [t.get("name") for t in b.get("tables", [])] if isinstance(b, dict) else []
    expect("neg" not in names, "table created from a malformed chunked body")


@check("structured_logs")
def _(s: Server):
    s.load_people()
    s.query("SELECT COUNT(*) FROM people", {"query_id": "log-me"})
    time.sleep(0.3)
    lines = [l for l in s.stderr_path.read_text(errors="replace").splitlines() if l.strip()]
    parsed = []
    for l in lines:
        try:
            parsed.append(json.loads(l))
        except json.JSONDecodeError:
            raise CheckFailed(f"non-JSON log line: {l[:200]}")
    expect(parsed and all({"ts", "level", "msg"} <= set(p) for p in parsed), "log lines need ts, level, msg")
    expect(any(p.get("query_id") == "log-me" for p in parsed), "no log event with query_id")


def graceful_shutdown(launcher: str, logdir: Path) -> None:
    s = Server(launcher, ["--enable-test-functions", "--shutdown-grace-ms", "5000"], logdir, "graceful_shutdown")
    try:
        t, box = bg(s.query, "SELECT PQ_SLEEP(1500)", None, 30)
        time.sleep(0.3)
        s.proc.send_signal(signal.SIGTERM)
        time.sleep(0.3)
        # New work is refused: connection refused/reset, or 503 SHUTTING_DOWN.
        try:
            st, _, b = s.json("POST", "/v1/query", {"sql": "SELECT 1"}, timeout=3)
            expect(st == 503, f"query during shutdown should be refused, got {st} {b}")
        except (ConnectionError, OSError, http.client.HTTPException):
            pass
        t.join(10)
        expect("result" in box and box["result"][0] == 200, f"in-flight query must complete: {box}")
        rc = s.proc.wait(timeout=10)
        expect(rc == 0, f"exit code {rc}")
    finally:
        s.kill()
        s.stderr.close()


def grace_expiry(launcher: str, logdir: Path) -> None:
    s = Server(launcher, ["--enable-test-functions", "--shutdown-grace-ms", "300"], logdir, "grace_expiry")
    try:
        t, box = bg(s.query, "SELECT PQ_SLEEP(20000)", None, 30)
        time.sleep(0.3)
        t0 = time.monotonic()
        s.proc.send_signal(signal.SIGTERM)
        rc = s.proc.wait(timeout=10)
        expect(time.monotonic() - t0 < 5, "shutdown did not respect grace period")
        expect(rc == 0, f"exit code {rc}")
        t.join(5)
        if "result" in box:
            st, _, b = box["result"]
            expect(st == 409 and b["error"]["code"] == "CANCELLED", f"over-grace query should be CANCELLED: {st} {b}")
    finally:
        s.kill()
        s.stderr.close()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True)
    ap.add_argument("--report")
    ap.add_argument("--only")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()
    launcher = str(Path(a.engine).resolve())
    logdir = Path(tempfile.mkdtemp(prefix="pqhttp-logs-"))
    results = []
    startup = []
    allchecks = [(n, args, fn) for n, args, fn in CHECKS] + [("graceful_shutdown", None, None), ("grace_expiry", None, None)]
    for name, args, fn in allchecks:
        if a.only and a.only not in name:
            continue
        t0 = time.monotonic()
        entry = {"check": name}
        try:
            if fn is None:
                (graceful_shutdown if name == "graceful_shutdown" else grace_expiry)(launcher, logdir)
            else:
                s = Server(launcher, args, logdir, name)
                startup.append(s.startup_seconds)
                try:
                    fn(s)
                finally:
                    s.stop()
            entry["status"] = "pass"
        except CheckFailed as e:
            entry.update(status="fail", message=str(e))
        except Exception as e:  # noqa: BLE001
            entry.update(status="error", message=f"{type(e).__name__}: {e}")
            if a.verbose:
                traceback.print_exc()
        entry["seconds"] = round(time.monotonic() - t0, 2)
        results.append(entry)
        print(f"  {entry['status']:5} {name} {entry.get('message', '')}", flush=True)
    passed = sum(1 for r in results if r["status"] == "pass")
    summary = {"total": len(results), "passed": passed, "failed": len(results) - passed}
    report = {"schema": "polyquery-http-suite/1", "engine": launcher, "summary": summary, "checks": results,
              "startup_seconds": startup, "logs": str(logdir)}
    if a.report:
        Path(a.report).write_text(json.dumps(report, indent=1) + "\n")
    print(f"http suite: {passed}/{len(results)} passed")
    return 0 if summary["failed"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
