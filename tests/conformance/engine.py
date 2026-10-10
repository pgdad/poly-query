"""Engine drivers: talk to any PolyQuery engine through its public protocol only."""
from __future__ import annotations

import json
import os
import queue
import signal
import subprocess
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path


class EngineError(Exception):
    """The engine crashed, hung or produced invalid protocol output."""


class SessionEngine:
    """Drives `bin/polyquery session` over stdin/stdout JSON lines."""

    def __init__(self, launcher: str, data_dir: Path, extra_args: list[str] | None = None,
                 timeout: float = 30.0, stderr_path: Path | None = None):
        self.launcher = launcher
        self.timeout = timeout
        args = [launcher, "session", "--data-dir", str(data_dir)] + (extra_args or [])
        self._stderr = open(stderr_path, "wb") if stderr_path else subprocess.DEVNULL
        self.start_time = time.monotonic()
        self.proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=self._stderr, cwd=str(data_dir), start_new_session=True)
        self._lines: queue.Queue = queue.Queue()
        self._reader = threading.Thread(target=self._read, daemon=True)
        self._reader.start()
        self.dead = False

    def _read(self) -> None:
        assert self.proc.stdout
        for line in self.proc.stdout:
            self._lines.put(line)
        self._lines.put(None)

    def request(self, req: dict, timeout: float | None = None) -> dict:
        if self.dead:
            raise EngineError("engine process is no longer running")
        data = (json.dumps(req, ensure_ascii=False) + "\n").encode("utf-8")
        try:
            assert self.proc.stdin
            self.proc.stdin.write(data)
            self.proc.stdin.flush()
        except (BrokenPipeError, OSError) as e:
            self.dead = True
            raise EngineError(f"engine stdin closed: {e}; exit={self.proc.poll()}") from e
        deadline = timeout if timeout is not None else self.timeout
        while True:
            try:
                line = self._lines.get(timeout=deadline)
            except queue.Empty:
                self.kill()
                raise EngineError(f"engine did not respond within {deadline}s (hang)")
            if line is None:
                self.dead = True
                raise EngineError(f"engine exited unexpectedly (exit={self.proc.wait()})")
            if not line.strip():
                continue
            try:
                resp = json.loads(line.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as e:
                self.kill()
                raise EngineError(f"invalid JSON line from engine: {line[:200]!r}") from e
            if not isinstance(resp, dict) or "ok" not in resp:
                self.kill()
                raise EngineError(f"response is not a protocol object: {line[:200]!r}")
            return resp

    def kill(self) -> None:
        self.dead = True
        try:
            os.killpg(self.proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass

    def close(self) -> None:
        if self.proc.poll() is None:
            try:
                assert self.proc.stdin
                self.proc.stdin.close()
                self.proc.wait(timeout=10)
            except (subprocess.TimeoutExpired, OSError):
                self.kill()
        if self._stderr not in (subprocess.DEVNULL, None):
            self._stderr.close()


class HttpEngine:
    """Drives `bin/polyquery serve` through POST /v1/request."""

    def __init__(self, launcher: str, data_dir: Path, extra_args: list[str] | None = None,
                 timeout: float = 30.0, stderr_path: Path | None = None, startup_timeout: float = 60.0):
        self.timeout = timeout
        args = [launcher, "serve", "--port", "0", "--data-dir", str(data_dir)] + (extra_args or [])
        self._stderr = open(stderr_path, "wb") if stderr_path else subprocess.DEVNULL
        self.proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=self._stderr,
                                     cwd=str(data_dir), start_new_session=True)
        self.dead = False
        q: queue.Queue = queue.Queue()

        def first_line() -> None:
            assert self.proc.stdout
            q.put(self.proc.stdout.readline())
            for _ in self.proc.stdout:  # drain
                pass

        threading.Thread(target=first_line, daemon=True).start()
        try:
            line = q.get(timeout=startup_timeout)
            ev = json.loads(line)
            assert ev.get("event") == "listening"
            self.base = f"http://{ev.get('host', '127.0.0.1')}:{int(ev['port'])}"
        except Exception as e:  # noqa: BLE001
            self.kill()
            raise EngineError(f"server did not announce listening port: {e}") from e

    def http(self, method: str, path: str, body: bytes | None = None, headers: dict | None = None,
             timeout: float | None = None) -> tuple[int, dict, bytes]:
        req = urllib.request.Request(self.base + path, data=body, method=method, headers=headers or {})
        try:
            with urllib.request.urlopen(req, timeout=timeout or self.timeout) as r:
                return r.status, dict(r.headers), r.read()
        except urllib.error.HTTPError as e:
            return e.code, dict(e.headers), e.read()
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            raise EngineError(f"HTTP failure: {e}") from e

    def request(self, req: dict, timeout: float | None = None) -> dict:
        status, _, body = self.http("POST", "/v1/request", json.dumps(req).encode(),
                                    {"Content-Type": "application/json"}, timeout)
        try:
            resp = json.loads(body)
        except json.JSONDecodeError as e:
            raise EngineError(f"invalid JSON body (status {status}): {body[:200]!r}") from e
        if "id" not in resp:
            resp["id"] = req.get("id")
        return resp

    def kill(self) -> None:
        self.dead = True
        try:
            os.killpg(self.proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass

    def close(self) -> None:
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.kill()
        if self._stderr not in (subprocess.DEVNULL, None):
            self._stderr.close()


def engine_info(launcher: str, timeout: float = 60.0) -> dict:
    """Runs `version` and `capabilities` CLI commands."""
    info: dict = {"launcher": launcher}
    for cmd in ("version", "capabilities"):
        t0 = time.monotonic()
        try:
            p = subprocess.run([launcher, cmd], capture_output=True, timeout=timeout)
            out = p.stdout.decode("utf-8", "replace").strip().splitlines()
            info[cmd] = json.loads(out[-1]) if out else None
            info[f"{cmd}_exit"] = p.returncode
        except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError, IndexError) as e:
            info[cmd] = None
            info[f"{cmd}_error"] = str(e)
        info[f"{cmd}_seconds"] = round(time.monotonic() - t0, 3)
    caps = (info.get("capabilities") or {}).get("capabilities") or []
    info["capability_set"] = sorted(c for c in caps if isinstance(c, str))
    return info
