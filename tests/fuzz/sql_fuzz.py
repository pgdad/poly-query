#!/usr/bin/env python3
"""Robustness fuzzing: the engine must survive arbitrary input.

Sends (a) random token soups, (b) mutated valid queries, (c) malformed protocol
requests and (d) malformed ingestion data. Every request must yield exactly one
valid protocol response within the timeout, never INTERNAL_ERROR, and the
process must not crash or hang.

  sql_fuzz.py --engine implementations/go/bin/polyquery [--seconds 120] [--seed 1]
"""
from __future__ import annotations

import argparse
import json
import random
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests/conformance"))
from engine import EngineError, SessionEngine  # noqa: E402

FIX = ROOT / "tests/conformance/fixtures"
TOKENS = ("SELECT FROM WHERE GROUP BY ORDER HAVING LIMIT OFFSET JOIN LEFT ON AND OR NOT NULL IS IN LIKE BETWEEN "
          "CASE WHEN THEN ELSE END CAST AS DISTINCT WITH EXISTS COUNT SUM AVG MIN MAX ( ) , . * + - / % = <> < > "
          "<= >= || ; people id name age city score active joined t1 'x' '' 'it''s' 0 1 -1 9223372036854775807 "
          "1.5 1e308 .5 DATE TIMESTAMP '2024-02-30' TRUE FALSE INT64 DECIMAL(18,2) \" \"\" -- /* */ \\ \x00 é 🚀").split(" ")
SEEDS = [
    "SELECT id, name FROM people WHERE age > 30 ORDER BY id",
    "SELECT city, COUNT(*) FROM people GROUP BY city HAVING COUNT(*) > 1",
    "SELECT CAST(score AS DECIMAL(5,1)) FROM people",
    "SELECT a.id FROM people a JOIN people b ON a.id = b.id",
    "WITH x AS (SELECT * FROM people) SELECT COUNT(*) FROM x",
    "SELECT (SELECT MAX(age) FROM people), id FROM people WHERE id IN (SELECT id FROM people)",
    "SELECT CASE WHEN age < 30 THEN 'a' ELSE 'b' END FROM people ORDER BY 1 LIMIT 3",
]
BAD_REQUESTS = [
    "", "{", "[]", "null", "42", '"str"', '{"op":null}', '{"op":"query","sql":null}', '{"op":"query","sql":["x"]}',
    '{"op":"load","table":"","format":"csv","data":"a\\n1\\n"}', '{"op":"load","table":"t","format":"csv","data":1}',
    '{"op":"load","table":"t","format":"csv","path":"fixtures/people.csv","schema":"nope"}',
    '{"op":"load","table":"t","format":"csv","path":"fixtures/people.csv","schema":[{"name":"x"}]}',
    '{"op":"query","sql":"SELECT 1","options":{"max_rows":-1}}', '{"op":"query","sql":"SELECT 1","options":"x"}',
    '{"op":"save","table":"people","path":"\\u0000"}', '{"op":"schema"}', '{"op":"drop","table":5}',
    '{"op":"query","sql":"' + "(" * 5000 + '"}', '{"op":"query","sql":"SELECT ' + "1+" * 20000 + '1"}',
]


def mutate(rng: random.Random, s: str) -> str:
    chars = list(s)
    for _ in range(rng.randint(1, 4)):
        k = rng.random()
        pos = rng.randrange(len(chars) + 1)
        if k < 0.3 and chars:
            del chars[min(pos, len(chars) - 1)]
        elif k < 0.6:
            chars.insert(pos, rng.choice(" ()',.;*-+=<>\"x0é"))
        else:
            tok = rng.choice(TOKENS)
            chars[pos:pos] = list(" " + tok + " ")
    return "".join(chars)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True)
    ap.add_argument("--seconds", type=float, default=120)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--report")
    a = ap.parse_args()
    rng = random.Random(a.seed)
    launcher = str(Path(a.engine).resolve())
    data = Path(tempfile.mkdtemp(prefix="pqfuzz-"))
    (data / "fixtures").symlink_to(FIX)

    def start():
        e = SessionEngine(launcher, data, timeout=20)
        e.request({"op": "load", "table": "people", "format": "csv", "path": "fixtures/people.csv"})
        return e
    eng = start()
    problems, sent = [], 0
    deadline = time.monotonic() + a.seconds
    # protocol-level garbage first
    for raw in BAD_REQUESTS:
        sent += 1
        try:
            assert eng.proc.stdin
            eng.proc.stdin.write(raw.encode() + b"\n")
            eng.proc.stdin.flush()
            if raw.strip() == "":
                continue  # blank lines are ignored by the protocol
            line = eng._lines.get(timeout=20)
            if line is None:
                raise EngineError("engine exited")
            resp = json.loads(line)
            if not isinstance(resp, dict) or resp.get("ok") is not False:
                problems.append({"input": raw[:200], "problem": f"expected an error response, got {str(resp)[:200]}"})
            elif (resp.get("error") or {}).get("code") == "INTERNAL_ERROR":
                problems.append({"input": raw[:200], "problem": "INTERNAL_ERROR"})
        except Exception as e:  # noqa: BLE001
            problems.append({"input": raw[:200], "problem": f"{type(e).__name__}: {e}"})
            eng.kill()
            eng = start()
    while time.monotonic() < deadline:
        k = rng.random()
        if k < 0.45:
            sql = mutate(rng, rng.choice(SEEDS))
            req = {"op": "query", "sql": sql}
        elif k < 0.8:
            sql = " ".join(rng.choice(TOKENS) for _ in range(rng.randint(1, 25)))
            req = {"op": "query", "sql": sql}
        else:
            junk = "".join(rng.choice("a,b\n1\"2\r\n,,\"x\"\"y\"é{}[]:") for _ in range(rng.randint(0, 200)))
            req = {"op": "load", "table": f"f{sent}", "format": rng.choice(["csv", "json", "jsonl"]), "data": junk}
        sent += 1
        try:
            resp = eng.request(req)
            if (resp.get("error") or {}).get("code") == "INTERNAL_ERROR":
                problems.append({"input": json.dumps(req)[:300], "problem": "INTERNAL_ERROR: " + str(resp["error"].get("message"))[:200]})
        except EngineError as e:
            problems.append({"input": json.dumps(req)[:300], "problem": str(e)})
            eng = start()
    eng.close()
    print(f"fuzz: {sent} inputs, {len(problems)} problems")
    for p in problems[:20]:
        print(f"  {p['problem'][:120]}  <- {p['input'][:160]!r}")
    if a.report:
        Path(a.report).write_text(json.dumps({"inputs": sent, "problems": problems, "seed": a.seed}, indent=1) + "\n")
    return 0 if not problems else 1


if __name__ == "__main__":
    sys.exit(main())
