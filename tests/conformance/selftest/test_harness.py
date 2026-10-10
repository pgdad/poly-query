"""Self-tests for the conformance harness (pqt parsing, comparison rules, runner failure detection)."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

from pqt import parse_file, rows_match, subset_match, value_eq  # noqa: E402


def run_runner(mode: str) -> dict:
    with tempfile.TemporaryDirectory() as td:
        rep = Path(td) / "r.json"
        env = {**os.environ, "MOCK_MODE": mode}
        cmd = [sys.executable, str(HERE.parent / "runner.py"), "--engine", str(HERE / "mock_engine.py"),
               "--report", str(rep), "--timeout", "2", "-q", "--jobs", "1"]
        # Run the real runner with its public-cases directory pointed at the selftest cases.
        subprocess.run([sys.executable, "-c",
                            "import sys,runpy; sys.path.insert(0, sys.argv[1]); import runner; "
                            "runner.PUBLIC_CASES = __import__('pathlib').Path(sys.argv[2]); "
                            "sys.argv = ['runner.py'] + sys.argv[3:]; sys.exit(runner.main())",
                            str(HERE.parent), str(HERE / "cases")] + cmd[2:], env=env, capture_output=True, text=True)
        return json.loads(rep.read_text())


def statuses(rep: dict) -> list[str]:
    return [c["status"] for f in rep["files"] for c in f["cases"]]


class ComparisonTests(unittest.TestCase):
    def test_value_types(self):
        self.assertTrue(value_eq(1, 1, "INT64"))
        self.assertFalse(value_eq(1, 1.0, "INT64"))
        self.assertFalse(value_eq(1, True, "INT64"))
        self.assertTrue(value_eq(0.3, 0.30000000000000004, "FLOAT64"))
        self.assertTrue(value_eq(3.0, 3, "FLOAT64"))
        self.assertFalse(value_eq(3.0, 3.001, "FLOAT64"))
        self.assertTrue(value_eq("1.50", "1.50", "DECIMAL(18,2)"))
        self.assertFalse(value_eq("1.50", "1.5", "DECIMAL(18,2)"))
        self.assertFalse(value_eq(None, 0, "INT64"))
        self.assertTrue(value_eq(None, None, "STRING"))

    def test_rows_unordered_with_floats(self):
        ok, _ = rows_match([[1, 0.1], [2, 0.2]], [[2, 0.2000000000000001], [1, 0.1]], ["INT64", "FLOAT64"], False)
        self.assertTrue(ok)
        ok, _ = rows_match([[1, 0.1], [2, 0.2]], [[2, 0.2], [1, 0.1]], ["INT64", "FLOAT64"], True)
        self.assertFalse(ok)
        ok, _ = rows_match([[1], [1]], [[1], [2]], ["INT64"], False)
        self.assertFalse(ok)

    def test_subset_match(self):
        self.assertTrue(subset_match({"a": [1, {"b": 2}]}, {"a": [1, {"b": 2, "c": 3}], "z": 0})[0])
        self.assertFalse(subset_match({"a": [1]}, {"a": [1, 2]})[0])
        self.assertFalse(subset_match({"a": 1}, {"a": True})[0])

    def test_all_suites_parse(self):
        for p in sorted((HERE.parent / "cases").rglob("*.pqt")):
            parse_file(p)


class RunnerTests(unittest.TestCase):
    def test_ok_engine(self):
        rep = run_runner("ok")
        self.assertEqual(statuses(rep), ["pass", "pass", "pass", "pass", "not_implemented"])
        self.assertTrue(rep["phase_passed"]["1"])
        self.assertFalse(rep["phase_passed"]["2"])

    def test_wrong_result_detected(self):
        self.assertEqual(statuses(run_runner("wrong"))[0], "fail")

    def test_crash_detected(self):
        self.assertEqual(statuses(run_runner("crash"))[3], "error")

    def test_hang_detected(self):
        self.assertEqual(statuses(run_runner("hang"))[3], "error")

    def test_garbage_detected(self):
        self.assertEqual(statuses(run_runner("garbage"))[3], "error")


if __name__ == "__main__":
    unittest.main()
