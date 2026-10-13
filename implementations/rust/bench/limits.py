#!/usr/bin/env python3
"""Stress test of the CR-6 expression size limits (spec/changes/expression-limits.md).

Runs statements at and beyond the minimums (text 1 MiB, nesting depth 1,000,
25,000 operands) built from many constructs, in every execution mode, on a
100-row table n(x) = 0..99, and reports result, value and time per case.

* "min" cases must succeed with the expected first cell.
* "beyond" cases must give the expected value, RESOURCE_LIMIT or TIMEOUT
  within timeout + 1 s.
* "timeout" cases run large statements with a short timeout and check that
  the answer (result or TIMEOUT) arrives within timeout + 1 s.

Usage: limits.py --engine bin/polyquery [--filter SUBSTR] [--modes row,vectorized,parallel,auto]
"""
from __future__ import annotations

import argparse
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tests" / "regression"))
from robustness_probe import Session, code  # noqa: E402

MODES = {"row": {"mode": "row", "threads": 1}, "vectorized": {"mode": "vectorized", "threads": 1},
         "parallel": {"mode": "vectorized", "threads": 8}, "auto": {}}


def where(pred: str) -> str:
    return f"SELECT count(*) FROM n WHERE {pred}"


def minimum_cases() -> list:
    d = 990
    lit = "a" * 524_000
    return [
        ("parens_998", where("(" * 998 + "x >= 0" + ")" * 998), 100),
        ("abs_998", where("ABS(" * 998 + "x" + ")" * 998 + " >= 0"), 100),
        ("unary_minus_998", where("- " * 998 + "x >= 0"), 100),
        ("unary_plus_998", where("+ " * 998 + "x >= 0"), 100),
        ("not_998", where("NOT " * 998 + "x >= 0"), 100),
        ("cast_998", where("CAST(" * 998 + "x" + " AS INT64)" * 998 + " >= 0"), 100),
        ("coalesce_998", where("COALESCE(" * 998 + "x" + ")" * 998 + " >= 0"), 100),
        ("upper_998", where("UPPER(" * 998 + "'a'" + ")" * 998 + " = 'A'"), 100),
        ("case_nested_998", where("CASE WHEN TRUE THEN " * 998 + "x" + " END" * 998 + " >= 0"), 100),
        ("case_cond_nested", where("CASE WHEN " * 499 + "x >= 0" + " THEN TRUE END" * 499), 100),
        ("cmp_nested_499", where("(" * 499 + "x >= 0" + ") = TRUE" * 499), 100),
        ("paren_sum_499", "SELECT max(" + "(" * 499 + "x" + " + 1)" * 499 + ") FROM n", 99 + 499),
        ("right_sum_499", "SELECT max(x" + " + (1" * 499 + ")" * 499 + ") FROM n", 99 + 499),
        ("scalar_subq_nested", where("x >= " + "(SELECT " * d + "0" + ")" * d), 100),
        ("derived_nested", "SELECT count(*) FROM " + "(SELECT * FROM " * d + "n" + ") t" * d, 100),
        ("from_parens_nested", "SELECT count(*) FROM " + "(" * d + "n" + ")" * d, 100),
        ("exists_nested", where("EXISTS (SELECT 1 WHERE " * d + "TRUE" + ")" * d), 100),
        ("in_subq_nested", where("x IN (SELECT x FROM n WHERE " * 300 + "TRUE" + ")" * 300), 100),
        ("cte_nested", "SELECT count(*) FROM (" + "WITH c AS (" * 400 + "SELECT * FROM n"
         + ") SELECT * FROM c" * 400 + ") t", 100),
        ("cte_chain_990", "WITH c0 AS (SELECT x FROM n), " + ", ".join(
            f"c{i} AS (SELECT x FROM c{i - 1})" for i in range(1, d)) + f" SELECT count(*) FROM c{d - 1}", 100),
        ("between_nested", where("(" * 400 + "x BETWEEN 0 AND 99) = TRUE" + ") = TRUE" * 399), 100),
        ("like_nested", where("(" * 400 + "'a' LIKE 'a') = TRUE" + ") = TRUE" * 399), 100),
        ("in_nested", where("(" * 400 + "x IN (1, x)) = TRUE" + ") = TRUE" * 399), 100),
        ("or_10000", where(" OR ".join(f"x = {i}" for i in range(10_000))), 100),
        ("and_10000", where(" AND ".join(f"x <> {-i - 1}" for i in range(10_000))), 100),
        ("or_12500", where(" OR ".join(f"x = {i}" for i in range(12_500))), 100),
        ("sum_10000", "SELECT max(x" + " + 1" * 9_999 + ") FROM n", 99 + 9_999),
        ("sum_25000", "SELECT max(x" + " + 0" * 24_999 + ") FROM n", 99),
        ("sub_10000", "SELECT max(x" + " - 1" * 9_999 + ") FROM n", 99 - 9_999),
        ("mixed_10000", "SELECT max(x" + " + 1 - 1" * 5_000 + ") FROM n", 99),
        ("mul_10000", "SELECT max(x" + " * 1" * 9_999 + ") FROM n", 99),
        ("div_10000", "SELECT max(x" + " / 1" * 9_999 + ") FROM n", 99),
        ("concat_10000", where("length(" + " || ".join("'a'" for _ in range(10_000)) + ") = 10000"), 100),
        ("concat_col_10000", "SELECT max(length(" + " || ".join("CAST(x AS STRING)" for _ in range(10_000))
         + ")) FROM n", 20_000),
        ("sum_where_10000", where("x" + " + 1" * 9_999 + " >= 9999"), 100),
        ("sum_select_10000", "SELECT x" + " + 1" * 9_999 + " FROM n ORDER BY 1 LIMIT 1", 9_999),
        ("sum_float_10000", "SELECT max(x" + " + 1.5e0" * 9_999 + ") FROM n", 99 + 1.5 * 9_999),
        ("sum_decimal_10000", "SELECT max(x" + " + 0.5" * 9_998 + ") > 0 FROM n", True),
        ("in_10000", where("x IN (" + ", ".join(str(i) for i in range(10_000)) + ")"), 100),
        ("in_25000", where("x IN (" + ", ".join(str(i) for i in range(24_999)) + ")"), 100),
        ("not_in_10000", where("x NOT IN (" + ", ".join(str(-i - 1) for i in range(10_000)) + ")"), 100),
        ("in_str_10000", where("CAST(x AS STRING) IN (" + ", ".join(f"'{i}'" for i in range(10_000)) + ")"), 100),
        ("case_5000", "SELECT sum(CASE " + " ".join(f"WHEN x = {i} THEN {i}" for i in range(5_000))
         + " ELSE 0 END) FROM n", 4950),
        ("case_12000", "SELECT sum(CASE " + " ".join(f"WHEN x = {i} THEN {i}" for i in range(12_000))
         + " ELSE 0 END) FROM n", 4950),
        ("case_simple_10000", "SELECT sum(CASE x " + " ".join(f"WHEN {i} THEN {i}" for i in range(10_000))
         + " END) FROM n", 4950),
        ("coalesce_25000", "SELECT max(COALESCE(" + "NULL, " * 24_998 + "x)) FROM n", 99),
        ("concat_fn_10000", "SELECT max(length(CONCAT(" + ", ".join("'a'" for _ in range(10_000)) + "))) FROM n",
         10_000),
        ("select_list_10000", "SELECT " + ", ".join("x" for _ in range(10_000)) + " FROM n ORDER BY 1 LIMIT 1", 0),
        ("aggs_5000", "SELECT " + ", ".join(f"sum(x + {i})" for i in range(5_000)) + " FROM n", 4950),
        ("group_by_1000", "SELECT count(*) FROM (SELECT x FROM n GROUP BY " + ", ".join("x" for _ in range(1000))
         + ") t", 100),
        ("group_by_expr_10000", "SELECT count(*) FROM (SELECT x" + " + 0" * 5_000 + " AS y, count(*) FROM n GROUP BY x"
         + " + 0" * 5_000 + ") t", 100),
        ("order_by_10000", "SELECT x FROM n ORDER BY " + ", ".join("x" for _ in range(10_000)) + " LIMIT 1", 0),
        ("having_or_10000", "SELECT count(*) FROM (SELECT x FROM n GROUP BY x HAVING "
         + " OR ".join(f"x = {i}" for i in range(10_000)) + ") t", 100),
        ("join_on_and_5000", "SELECT count(*) FROM n a JOIN n b ON a.x = b.x AND "
         + " AND ".join(f"a.x <> {-i - 1}" for i in range(5_000)), 100),
        ("left_join_on_or_5000", "SELECT count(*) FROM n a LEFT JOIN n b ON "
         + " OR ".join(f"a.x = b.x + {i}" for i in range(5_000)), 5050),
        ("subq_or_5000", where("x IN (SELECT x FROM n WHERE " + " OR ".join(f"x = {i}" for i in range(5_000)) + ")"),
         100),
        ("corr_subq_or_2000", "SELECT count(*) FROM n a WHERE EXISTS (SELECT 1 FROM n b WHERE b.x = a.x AND ("
         + " OR ".join(f"b.x = {i}" for i in range(2_000)) + "))", 100),
        ("parens_or_mix", where("(" * 990 + " OR ".join(f"x = {i}" for i in range(10_000)) + ")" * 990), 100),
        ("not_or_mix", where("NOT " * 990 + "(" + " OR ".join(f"x = {-i - 1}" for i in range(10_000)) + ")"), 0),
        ("or_and_mix", where(" OR ".join(f"(x = {i} AND x <> -1)" for i in range(6_000))), 100),
        ("union_all_500", "SELECT count(*) FROM (" + " UNION ALL ".join("SELECT x FROM n" for _ in range(500))
         + ") t", 50_000),
        ("join_chain_60", "SELECT count(*) FROM n t0 " + " ".join(f"JOIN n t{i} ON t{i - 1}.x = t{i}.x"
                                                                 for i in range(1, 60)), 100),
        ("text_1mib", where(f"'{lit}' = '{lit}'"), 100),
        ("comment_1mib", "SELECT count(*) /* " + "c" * 1_040_000 + " */ FROM n", 100),
        ("ws_1mib", "SELECT count(*)" + " " * 1_040_000 + "FROM n", 100),
        ("explain_or_10000", "EXPLAIN SELECT count(*) FROM n WHERE " + " OR ".join(f"x = {i}" for i in range(10_000)),
         None),
        ("explain_parens_998", "EXPLAIN SELECT count(*) FROM n WHERE " + "(" * 998 + "x >= 0" + ")" * 998, None),
    ]


def beyond_cases() -> list:
    big = "a" * 5_000_000
    return [
        ("parens_100000", where("(" * 100_000 + "x >= 0" + ")" * 100_000), 100),
        ("or_100000", where(" OR ".join(f"x = {i}" for i in range(100_000))), 100),
        ("in_100000", where("x IN (" + ", ".join(str(i) for i in range(100_000)) + ")"), 100),
        ("not_100000", where("NOT " * 100_000 + "x >= 0"), 100),
        ("minus_100000", where("- " * 100_000 + "x >= 0"), 100),
        ("abs_100000", where("ABS(" * 100_000 + "x" + ")" * 100_000 + " >= 0"), 100),
        ("sum_100000", "SELECT max(x" + " + 1" * 99_999 + ") FROM n", 99 + 99_999),
        ("sum_40000", "SELECT max(x" + " + 1" * 39_999 + ") FROM n", 99 + 39_999),
        ("or_40000", where(" OR ".join(f"x = {i}" for i in range(40_000))), 100),
        ("case_50000", "SELECT sum(CASE " + " ".join(f"WHEN x = {i} THEN {i}" for i in range(50_000))
         + " ELSE 0 END) FROM n", 4950),
        ("subq_5000", where("x >= " + "(SELECT " * 5_000 + "0" + ")" * 5_000), 100),
        ("derived_5000", "SELECT count(*) FROM " + "(SELECT * FROM " * 5_000 + "n" + ") t" * 5_000, 100),
        ("cte_chain_5000", "WITH c0 AS (SELECT x FROM n), " + ", ".join(
            f"c{i} AS (SELECT x FROM c{i - 1})" for i in range(1, 5000)) + " SELECT count(*) FROM c4999", 100),
        ("union_all_5000", "SELECT count(*) FROM (" + " UNION ALL ".join("SELECT x FROM n" for _ in range(5000))
         + ") t", 500_000),
        ("join_chain_300", "SELECT count(*) FROM n t0 " + " ".join(f"JOIN n t{i} ON t{i - 1}.x = t{i}.x"
                                                                  for i in range(1, 300)), 100),
        ("text_10mib", where(f"'{big}' = '{big}'"), 100),
        ("left_join_chain_12000", "SELECT count(*) FROM n t0 " + " ".join(
            f"LEFT JOIN n t{i} ON t{i - 1}.x = t{i}.x" for i in range(1, 12000)), 100),
        ("cte_doubling_30", "WITH c0 AS (SELECT x FROM n), " + ", ".join(
            f"c{i} AS (SELECT a.x FROM c{i - 1} a, c{i - 1} b WHERE a.x = b.x)" for i in range(1, 30))
         + " SELECT count(*) FROM c29", 100),
        ("comma_100000", "SELECT count(*) FROM " + ", ".join(f"n t{i}" for i in range(100_000)), None),
        ("select_list_100000", "SELECT " + ", ".join("x" for _ in range(100_000)) + " FROM n LIMIT 1", 0),
    ]


def edge_cases() -> list:
    """At the engine's own limits (nesting depth 4096, 100,000 operands): the
    result, or RESOURCE_LIMIT (never a crash)."""
    d = 4000
    return [
        ("parens_4000", where("(" * d + "x >= 0" + ")" * d), 100),
        ("abs_4000", where("ABS(" * d + "x" + ")" * d + " >= 0"), 100),
        ("minus_4000", where("- " * d + "x <= 0"), 1),
        ("not_4000", where("NOT " * d + "x >= 0"), 100),
        ("cast_4000", where("CAST(" * d + "x" + " AS INT64)" * d + " >= 0"), 100),
        ("case_nested_4000", where("CASE WHEN TRUE THEN " * d + "x" + " END" * d + " >= 0"), 100),
        ("paren_sum_2000", "SELECT max(" + "(" * 2000 + "x" + " + 1)" * 2000 + ") FROM n", 99 + 2000),
        ("right_sum_2000", "SELECT max(x" + " + (1" * 2000 + ")" * 2000 + ") FROM n", 99 + 2000),
        ("right_or_2000", where("x = -1" + " OR (x = -1" * 1999 + " OR x >= 0" + ")" * 1999), 100),
        ("scalar_subq_4000", where("x >= " + "(SELECT " * d + "0" + ")" * d), 100),
        ("derived_4000", "SELECT count(*) FROM " + "(SELECT * FROM " * d + "n" + ") t" * d, 100),
        ("exists_4000", where("EXISTS (SELECT 1 WHERE " * d + "TRUE" + ")" * d), 100),
        ("in_subq_1300", where("x IN (SELECT x FROM n WHERE " * 1300 + "TRUE" + ")" * 1300), 100),
        ("cte_nested_4000", "SELECT count(*) FROM (" + "WITH c AS (" * 3990 + "SELECT * FROM n"
         + ") SELECT * FROM c" * 3990 + ") t", 100),
        ("corr_subq_2000", "SELECT count(*) FROM n a WHERE " + "EXISTS (SELECT 1 FROM n b WHERE b.x = a.x AND " * 30
         + "x >= " + "(SELECT " * 1900 + "a.x" + ")" * 1900 + ")" * 30, 100),
        ("sum_99999", "SELECT max(x" + " + 1" * 99_998 + ") FROM n", 99 + 99_998),
        ("colsum_99999", "SELECT max(x" + " + x" * 99_998 + ") FROM n", 99 * 99_999),
        ("or_49999", where(" OR ".join(f"x = {i}" for i in range(49_999))), 100),
        ("in_99999", where("x IN (" + ", ".join(str(i) for i in range(99_998)) + ")"), 100),
        ("case_49999", "SELECT sum(CASE " + " ".join(f"WHEN x = {i} THEN {i}" for i in range(49_999))
         + " ELSE 0 END) FROM n", 4950),
        ("concat_99999", "SELECT max(length(" + " || ".join("CAST(x AS STRING)" for _ in range(99_999)) + ")) FROM n",
         199_998),
        ("union_all_50000", "SELECT count(*) FROM (" + " UNION ALL ".join("SELECT x FROM n" for _ in range(50_000))
         + ") t", 5_000_000),
        ("join_chain_2000", "SELECT count(*) FROM n t0 " + " ".join(f"JOIN n t{i} ON t{i - 1}.x = t{i}.x"
                                                                   for i in range(1, 2000)), 100),
        ("cte_chain_20000", "WITH c0 AS (SELECT x FROM n), " + ", ".join(
            f"c{i} AS (SELECT x FROM c{i - 1})" for i in range(1, 20000)) + " SELECT count(*) FROM c19999", 100),
        ("select_list_99999", "SELECT " + ", ".join("x" for _ in range(99_998)) + " FROM n LIMIT 1", 0),
        ("text_16mib", where("'" + "a" * 8_300_000 + "' = '" + "a" * 8_300_000 + "'"), 100),
        ("join_chain_12000", "SELECT count(*) FROM n t0 " + " ".join(f"JOIN n t{i} ON t{i - 1}.x = t{i}.x"
                                                                    for i in range(1, 12000)), 100),
        ("cross_chain_20000", "SELECT count(*) FROM (SELECT * FROM n LIMIT 1) t0, "
         + ", ".join(f"(SELECT 1 AS y) t{i}" for i in range(1, 20000)), 1),
        ("comma_where_5000", "SELECT count(*) FROM " + ", ".join(f"n t{i}" for i in range(5000)) + " WHERE "
         + " AND ".join(f"t{i - 1}.x = t{i}.x" for i in range(1, 5000)), 100),
        ("left_join_chain_3000", "SELECT count(*) FROM n t0 " + " ".join(
            f"LEFT JOIN n t{i} ON t{i - 1}.x = t{i}.x" for i in range(1, 3000)), 100),
        ("mixed_join_chain_6000", "SELECT count(*) FROM n t0 " + " ".join(
            (f"LEFT JOIN n t{i} ON t{i - 1}.x = t{i}.x" if i % 100 == 0 else f"JOIN n t{i} ON t{i - 1}.x = t{i}.x")
            for i in range(1, 6000)), 100),
        ("cte_star_chain_20000", "WITH c0 AS (SELECT * FROM n), " + ", ".join(
            f"c{i} AS (SELECT * FROM c{i - 1})" for i in range(1, 20000)) + " SELECT count(*) FROM c19999", 100),
        ("union_star_20000", "SELECT count(*) FROM (" + " UNION ALL ".join("SELECT * FROM n" for _ in range(20_000))
         + ") t", 2_000_000),
        ("aggs_25000", "SELECT " + ", ".join(f"sum(x + {i})" for i in range(25_000)) + " FROM n", 4950),
        ("aggs_same_25000", "SELECT " + ", ".join("sum(x)" for _ in range(25_000)) + " FROM n", 4950),
        ("group_by_20000", "SELECT count(*) FROM (SELECT x FROM n GROUP BY x, "
         + ", ".join(f"x + {i}" for i in range(20_000)) + ") t", 100),
        ("order_select_20000", "SELECT " + ", ".join(f"x + {i}" for i in range(20_000)) + " FROM n ORDER BY "
         + ", ".join(f"x + {i}" for i in range(20_000)) + " LIMIT 1", 0),
        ("select_exprs_49999", "SELECT " + ", ".join(f"x + {i}" for i in range(49_999)) + " FROM n LIMIT 1", 0),
        ("distinct_20000", "SELECT count(*) FROM (SELECT DISTINCT " + ", ".join(f"x + {i}" for i in range(20_000))
         + " FROM n) t", 100),
        ("coalesce_99999", "SELECT max(COALESCE(" + "NULL, " * 99_998 + "x)) FROM n", 99),
        ("where_and_cols_49999", where(" AND ".join("x >= 0" for _ in range(49_999))), 100),
        ("scalar_subqs_10000", "SELECT " + ", ".join(f"(SELECT max(x) + {i} FROM n)" for i in range(10_000))
         + " FROM n LIMIT 1", 99),
        ("having_aggs_10000", "SELECT count(*) FROM (SELECT x FROM n GROUP BY x HAVING "
         + " AND ".join(f"sum(x) >= {-i}" for i in range(10_000)) + ") t", 100),
    ]


def timeout_cases() -> list:
    """Large statements with a short timeout: the answer must arrive within timeout + 1 s."""
    picked = ("or_12500", "sum_25000", "in_25000", "case_12000", "join_chain_60", "cte_chain_990",
              "derived_nested", "aggs_5000", "or_100000", "in_100000", "subq_5000", "union_all_5000")
    return [c for c in minimum_cases() + beyond_cases() if c[0] in picked] + edge_cases()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True)
    ap.add_argument("--filter", default="")
    ap.add_argument("--modes", default="row,vectorized,parallel,auto")
    ap.add_argument("--groups", default="min,beyond,timeout")
    ap.add_argument("--timeout-ms", type=int, default=200)
    ap.add_argument("--rows", type=int, default=100,
                    help="rows of n (results are only checked with the default 100)")
    a = ap.parse_args()
    engine = str(Path(a.engine).resolve())
    modes = [m for m in a.modes.split(",") if m]
    failures = 0
    with tempfile.TemporaryDirectory() as d:
        data = Path(d)
        (data / "n.csv").write_text("x\n" + "\n".join(str(i % 100) for i in range(a.rows)) + "\n")
        env = {"PQ_PAR_MIN": "1", "PQ_PARALLEL_MIN_ROWS": "1"}
        state: dict = {"s": None}

        def session() -> Session:
            s = state["s"]
            if s is not None and s.alive():
                return s
            if s is not None:
                print("   engine died:", s.close())
            s = state["s"] = Session(engine, data, ["--enable-test-functions"], env)
            s.req({"op": "load", "table": "n", "format": "csv", "path": "n.csv"})
            return s

        groups = {"min": (minimum_cases, 120_000), "beyond": (beyond_cases, 30_000),
                  "edge": (edge_cases, 60_000), "timeout": (timeout_cases, a.timeout_ms)}
        for g in a.groups.split(","):
            make, tmo = groups[g]
            for name, sql, want in make():
                if a.filter and a.filter not in name:
                    continue
                for m in modes:
                    s = session()
                    t0 = time.monotonic()
                    r = s.req({"op": "query", "sql": sql, "options": {**MODES[m], "timeout_ms": tmo}},
                              timeout=tmo / 1000 + 60)
                    dt = time.monotonic() - t0
                    c = code(r) if s.alive() else "CRASH"
                    val = (r.get("rows") or [[None]])[0][0] if c == "ok" else None
                    if a.rows != 100:
                        want = val
                    if g == "min":
                        ok = c == "ok" and (want is None or val == want or
                                            (isinstance(want, float) and abs(float(val) - want) < 1e-6))
                    else:
                        ok = (c == "ok" and val == want) or c in ("RESOURCE_LIMIT", "TIMEOUT")
                        ok = ok and dt <= tmo / 1000 + 1.0 if c in ("TIMEOUT",) or g == "timeout" else ok
                    msg = "" if c == "ok" or r is None else (r.get("error") or {}).get("message", "")[:80]
                    print(f"{'PASS' if ok else 'FAIL'} {g:7} {name:22} {m:10} {c:15} {str(val)[:12]:12} "
                          f"{dt:7.2f}s {msg}", flush=True)
                    failures += not ok
        if state["s"] is not None:
            info = state["s"].close()
            if info["exit_code"] not in (0, None):
                print("engine exit:", info)
                failures += 1
    print(f"{failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
