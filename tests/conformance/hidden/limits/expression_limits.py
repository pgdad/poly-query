# Withheld CR-6 acceptance cases (spec/changes/expression-limits.md), loaded by
# tests/regression/robustness_probe.py --extra-cases during validation only.
# Same table as the public cases: n(x) = 0..99. Different constructs than the public
# cases, at the same measures (nesting depth <= 1,000, operands <= 25,000, text <= 1 MiB).


def cases() -> tuple[list, list]:
    def where(pred: str) -> str:
        return f"SELECT count(*) FROM n WHERE {pred}"

    def nested_case(levels: int) -> str:
        e = "1"
        for _ in range(levels):
            e = f"CASE WHEN x >= 0 THEN {e} ELSE 0 END"
        return f"SELECT sum({e}) FROM n"

    sub = "SELECT x FROM n"
    for _ in range(50):
        sub = f"SELECT x FROM n WHERE x IN ({sub})"
    minimum = [
        ("h_concat_10000", where(" || ".join(["'a'"] * 10_000) + f" = '{'a' * 10_000}'"), 100),
        ("h_mul_10000", "SELECT max(x" + " * 1" * 9_999 + ") FROM n", 99),
        ("h_minus_plus_9998", "SELECT max(x" + " - 1 + 1" * 4_999 + ") FROM n", 99),
        ("h_case_nest_900", nested_case(900), 100),
        ("h_cast_nest_900", where("CAST(" * 900 + "x" + " AS INT64)" * 900 + " >= 0"), 100),
        ("h_in_string_10000", where("CAST(x AS STRING) IN (" + ", ".join(f"'{i}'" for i in range(10_000)) + ")"), 100),
        ("h_subquery_nest_50", where(f"x IN ({sub})"), 100),
        ("h_or_of_and_5000", where(" OR ".join(f"(x = {i} AND x >= 0)" for i in range(5_000))), 100),
        ("h_comment_1mib", "SELECT count(*) FROM n /* " + "c" * 1_040_000 + " */", 100),
    ]
    beyond = [
        ("h_not_100000", where("NOT " * 100_000 + "x >= 0"), 100),
        ("h_sum_200000", "SELECT max(x" + " + 1" * 199_999 + ") FROM n", 99 + 199_999),
        ("h_and_150000", where(" AND ".join(f"x <> {-i - 1}" for i in range(150_000))), 100),
        ("h_case_nest_50000", nested_case(50_000), 100),
    ]
    return minimum, beyond
