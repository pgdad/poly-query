"""pq-embed-demo DATA_DIR CSV_FILE SQL — the minimal embedding example
(spec/apps/embedding.md §5).

Creates an engine instance on DATA_DIR, loads CSV_FILE (relative to DATA_DIR,
header row, inferred schema) as table ``t``, runs SQL and prints the result as
CSV (spec/apps/pqledger.md §7). Uses only the public ``polyquery`` API: the
package is found through PYTHONPATH (or any other sys.path entry), exactly
as in a separate project.
"""

from __future__ import annotations

import datetime
import decimal
import sys

import polyquery


def value_text(value: object, type_name: str) -> str:
    """The text of a result value in the pqledger output formats."""
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, decimal.Decimal):
        return f"{value:f}"
    if isinstance(value, float):
        text = f"{value:.6f}"
        return "0.000000" if text == "-0.000000" else text
    if isinstance(value, datetime.datetime):
        return value.isoformat(sep=" ")
    if isinstance(value, datetime.date):
        return value.isoformat()
    return str(value)


def csv_field(value: object, type_name: str) -> str:
    if value is None:
        return ""
    text = value_text(value, type_name)
    if (
        (text == "" and isinstance(value, str))
        or any(c in text for c in ',"\r\n')
        or text.startswith(" ")
        or text.endswith(" ")
    ):
        return '"' + text.replace('"', '""') + '"'
    return text


def write_csv(result: polyquery.Result, out) -> None:
    out.write(",".join(csv_field(name, "STRING") for name in result.columns) + "\n")
    for row in result:
        out.write(",".join(csv_field(v, t) for v, t in zip(row, result.types)) + "\n")


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: pq-embed-demo DATA_DIR CSV_FILE SQL", file=sys.stderr)
        return 2
    data_dir, csv_file, sql = argv
    try:
        with polyquery.Database(data_dir) as db:
            db.load("t", path=csv_file)
            result = db.query(sql)
    except polyquery.Error as e:
        print(f"error: {e.code}: {e.message}", file=sys.stderr)
        return 1
    write_csv(result, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
