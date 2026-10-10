#!/usr/bin/env python3
"""Deliberately tiny fake engine for harness self-tests. Behaviour is selected
with the MOCK_MODE environment variable: ok | wrong | crash | hang | garbage."""
import json
import os
import sys
import time

MODE = os.environ.get("MOCK_MODE", "ok")
if sys.argv[1:2] == ["version"]:
    print(json.dumps({"ok": True, "engine": "mock", "protocol_version": 1}))
    sys.exit(0)
if sys.argv[1:2] == ["capabilities"]:
    print(json.dumps({"ok": True, "protocol_version": 1, "capabilities": ["phase1", "mock"]}))
    sys.exit(0)
for line in sys.stdin:
    req = json.loads(line)
    sql = req.get("sql", "")
    if MODE == "crash" and "boom" in sql:
        sys.exit(3)
    if MODE == "hang" and "boom" in sql:
        time.sleep(3600)
    if MODE == "garbage" and "boom" in sql:
        print("this is not json", flush=True)
        continue
    if req["op"] == "query" and sql.startswith("SELECT 1"):
        val = 2 if MODE == "wrong" else 1
        resp = {"ok": True, "columns": [{"name": "x", "type": "INT64"}], "rows": [[val]], "row_count": 1}
    elif req["op"] == "query" and sql.startswith("SELECT f"):
        resp = {"ok": True, "columns": [{"name": "f", "type": "FLOAT64"}], "rows": [[0.30000000000000004], [1]], "row_count": 2}
    elif req["op"] == "query" and "nope" in sql:
        resp = {"ok": False, "error": {"code": "SEMANTIC_ERROR", "message": "nope"}}
    else:
        resp = {"ok": True, "columns": [], "rows": [], "row_count": 0}
    resp["id"] = req.get("id")
    print(json.dumps(resp), flush=True)
