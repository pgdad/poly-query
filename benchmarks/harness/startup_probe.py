#!/usr/bin/env python3
"""Measures engine startup *inside* the sandbox: process spawn -> first `version`
response over the session protocol, repeated. Run through the same wrapper chain
as the engine (cgroup, taskset, sandbox) so the sandbox launch itself (~tens of
ms, identical for every engine) is not part of the measurement.

  startup_probe.py <launcher> <data-dir> <reps>   -> JSON list of seconds on stdout
"""
import json
import subprocess
import sys
import time


def main() -> int:
    launcher, data_dir, reps = sys.argv[1], sys.argv[2], int(sys.argv[3])
    out = []
    for _ in range(reps):
        t0 = time.monotonic()
        p = subprocess.Popen([launcher, "session", "--data-dir", data_dir], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        assert p.stdin and p.stdout
        p.stdin.write(b'{"op":"version","id":1}\n')
        p.stdin.flush()
        line = p.stdout.readline()
        el = time.monotonic() - t0
        p.stdin.close()
        p.wait(timeout=60)
        resp = json.loads(line) if line.strip() else {}
        out.append(el if resp.get("ok") else None)
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
