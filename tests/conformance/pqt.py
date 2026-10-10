"""Parser and result comparison for the .pqt conformance test format (see FORMAT.md)."""
from __future__ import annotations

import json
import math
import re
import shlex
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

FLOAT_REL_TOL = 1e-9


class PqtSyntaxError(Exception):
    pass


@dataclass
class Step:
    kind: str                      # load | data | query | error | statement | request | explain
    line: int
    sql: str = ""
    request: dict | None = None    # for load/data/request
    ordered: bool = False
    oracle: bool = False
    options: dict | None = None
    columns: list[tuple[str, str]] | None = None
    rows: list[list[Any]] | None = None
    rowcount: int | None = None
    expect_error: str | None = None
    expectations: list[tuple[str, Any]] = field(default_factory=list)  # request/explain checks
    setup: bool = False            # load/data without expectation: setup, still reported
    result_span: tuple[int, int] | None = None  # 0-based [header_line, end_line) of a query result

    @property
    def is_case(self) -> bool:
        return not self.setup


@dataclass
class PqtFile:
    path: Path
    phase: int
    requires: list[str]
    engine_args: list[str]
    steps: list[Step]


_HEADER_SPLIT = re.compile(r"\s*\|\s*")


def parse_header(line: str, lineno: int) -> list[tuple[str, str]]:
    if line.strip() == "-":
        return []
    cols = []
    for part in _HEADER_SPLIT.split(line.strip()):
        part = part.strip()
        if part.startswith('"'):
            name, end = json.JSONDecoder().raw_decode(part)
            typ = part[end:].strip()
        else:
            name, _, typ = part.partition(" ")
        if not name or not typ:
            raise PqtSyntaxError(f"line {lineno}: bad column header part {part!r}")
        cols.append((name, typ.strip().replace(" ", "")))
    return cols


def _parse_opts(tokens: list[str], lineno: int) -> tuple[dict, list[str]]:
    opts, rest = {}, []
    for t in tokens:
        if "=" in t and not t.startswith("{"):
            k, v = t.split("=", 1)
            opts[k] = v
        else:
            rest.append(t)
    return opts, rest


def _options_json(line: str, lineno: int) -> tuple[str, dict | None]:
    idx = line.find("options=")
    if idx < 0:
        return line, None
    try:
        return line[:idx].strip(), json.loads(line[idx + len("options="):])
    except json.JSONDecodeError as e:
        raise PqtSyntaxError(f"line {lineno}: bad options json: {e}") from e


def _schema(spec: str) -> list[dict]:
    out = []
    for item in spec.split(";"):
        name, _, typ = item.partition(":")
        out.append({"name": name, "type": typ})
    return out


def _load_request(table: str, opts: dict, *, path: str | None = None, data: str | None = None,
                  fmt: str | None = None) -> tuple[dict, str | None]:
    req: dict = {"op": "load", "table": table}
    if path is not None:
        req["path"] = path
        fmt = opts.pop("format", None) or fmt or Path(path).suffix.lstrip(".")
    else:
        req["data"] = data
    req["format"] = fmt
    if "schema" in opts:
        req["schema"] = _schema(opts.pop("schema"))
    if "schemafile" in opts:  # path relative to tests/conformance (e.g. fixtures/gen/x.schema.json)
        req["schema"] = json.loads((Path(__file__).resolve().parent / opts.pop("schemafile")).read_text())
    o = {}
    if "header" in opts:
        o["header"] = opts.pop("header").lower() == "true"
    if "delimiter" in opts:
        o["delimiter"] = opts.pop("delimiter")
    if "layout" in opts:
        o["layout"] = opts.pop("layout")
    if o:
        req["options"] = o
    if "replace" in opts:
        req["replace"] = opts.pop("replace").lower() == "true"
    expect = opts.pop("expect", None)
    if opts:
        raise PqtSyntaxError(f"unknown load options {sorted(opts)}")
    return req, expect


def parse_file(path: Path) -> PqtFile:
    lines = path.read_text(encoding="utf-8").split("\n")
    phase, requires, engine_args, steps = 0, [], [], []
    i, n = 0, len(lines)

    def take_until_sep(start: int) -> tuple[list[str], int, bool]:
        """Collect lines until '----' or blank line. Returns (lines, next_index, saw_separator)."""
        out, j = [], start
        while j < n:
            l = lines[j]
            if l.strip() == "----":
                return out, j + 1, True
            if l.strip() == "":
                return out, j, False
            out.append(l)
            j += 1
        return out, j, False

    def take_block(start: int) -> tuple[list[str], int]:
        out, j = [], start
        while j < n and lines[j].strip() != "":
            out.append(lines[j])
            j += 1
        return out, j

    while i < n:
        raw = lines[i]
        line = raw.strip()
        lineno = i + 1
        if not line or line.startswith("#"):
            i += 1
            continue
        if line.startswith("@phase"):
            phase = int(line.split()[1]); i += 1; continue
        if line.startswith("@requires"):
            requires += line.split()[1:]; i += 1; continue
        if line.startswith("@engine-args"):
            engine_args += shlex.split(line[len("@engine-args"):]); i += 1; continue

        word = line.split()[0]
        if word == "load":
            toks = shlex.split(line)
            if len(toks) < 3:
                raise PqtSyntaxError(f"{path}:{lineno}: load needs table and path")
            opts, rest = _parse_opts(toks[3:], lineno)
            req, expect = _load_request(toks[1], opts, path=toks[2])
            steps.append(Step("load", lineno, request=req, expect_error=expect, setup=expect is None))
            i += 1
        elif word in ("open", "save"):
            toks = shlex.split(line)
            if len(toks) < 3:
                raise PqtSyntaxError(f"{path}:{lineno}: {word} needs table and path")
            opts, _ = _parse_opts(toks[3:], lineno)
            req: dict = {"op": word, "table": toks[1], "path": toks[2]}
            o: dict = {}
            if "mmap" in opts:
                o["mmap"] = opts.pop("mmap").lower() == "true"
            if "encoding" in opts:
                o["encoding"] = opts.pop("encoding")
            if "row_group_size" in opts:
                o["row_group_size"] = int(opts.pop("row_group_size"))
            if "layout" in opts:
                o["layout"] = opts.pop("layout")
            if o:
                req["options"] = o
            if "replace" in opts:
                req["replace"] = opts.pop("replace").lower() == "true"
            expect = opts.pop("expect", None)
            if opts:
                raise PqtSyntaxError(f"{path}:{lineno}: unknown {word} options {sorted(opts)}")
            steps.append(Step(word, lineno, request=req, expect_error=expect))
            i += 1
        elif word == "corrupt":
            toks = shlex.split(line)
            if len(toks) != 4:
                raise PqtSyntaxError(f"{path}:{lineno}: corrupt <table> <path> <CODE>")
            steps.append(Step("corrupt", lineno, request={"op": "open", "table": toks[1], "path": toks[2]},
                              expect_error=toks[3]))
            i += 1
        elif word == "data":
            toks = shlex.split(line)
            opts, _ = _parse_opts(toks[3:], lineno)
            body, j = [], i + 1
            while j < n and lines[j] != ".":
                body.append(lines[j]); j += 1
            if j >= n:
                raise PqtSyntaxError(f"{path}:{lineno}: data block not terminated by '.'")
            content = "\n".join(body) + ("\n" if body else "")
            req, expect = _load_request(toks[1], opts, data=content, fmt=toks[2])
            steps.append(Step("data", lineno, request=req, expect_error=expect, setup=expect is None))
            i = j + 1
        elif word in ("query", "error", "statement", "explain"):
            head, options = _options_json(line, lineno)
            toks = head.split()
            body, j, sep = take_until_sep(i + 1)
            if not body:
                raise PqtSyntaxError(f"{path}:{lineno}: missing SQL")
            sql = "\n".join(body)
            if word == "query":
                if not sep:
                    raise PqtSyntaxError(f"{path}:{lineno}: query without ----")
                st = Step("query", lineno, sql=sql, options=options,
                          ordered="ordered" in toks[1:], oracle="oracle" in toks[1:])
                res_start = j
                res, j = take_block(j)
                st.result_span = (res_start, j)
                if not res:
                    raise PqtSyntaxError(f"{path}:{lineno}: missing result header")
                if res[0].startswith("rowcount "):
                    st.rowcount = int(res[0].split()[1])
                else:
                    st.columns = parse_header(res[0], lineno)
                    st.rows = []
                    for k, r in enumerate(res[1:]):
                        if r.strip() == "?":           # placeholder: rows filled by the oracle tool
                            st.rows = None
                            break
                        try:
                            v = json.loads(r)
                        except json.JSONDecodeError as e:
                            raise PqtSyntaxError(f"{path}:{lineno + k + 2}: bad row json: {e}") from e
                        if not isinstance(v, list) or len(v) != len(st.columns):
                            raise PqtSyntaxError(f"{path}:{lineno + k + 2}: row arity mismatch")
                        st.rows.append(v)
                steps.append(st)
            elif word == "error":
                if len(toks) < 2:
                    raise PqtSyntaxError(f"{path}:{lineno}: error needs a code")
                steps.append(Step("error", lineno, sql=sql, options=options, expect_error=toks[1]))
            elif word == "statement":
                st = Step("statement", lineno, sql=sql, options=options)
                if toks[1:2] == ["error"]:
                    st.expect_error = toks[2]
                steps.append(st)
            else:  # explain
                if not sep:
                    raise PqtSyntaxError(f"{path}:{lineno}: explain without ----")
                res, j = take_block(j)
                st = Step("explain", lineno, sql=sql, options=options)
                for r in res:
                    parts = r.split()
                    st.expectations.append((parts[0], parts[1:]))
                steps.append(st)
            i = j
        elif word == "request":
            body, j, sep = take_until_sep(i + 1)
            try:
                req = json.loads("\n".join(body))
            except json.JSONDecodeError as e:
                raise PqtSyntaxError(f"{path}:{lineno}: bad request json: {e}") from e
            st = Step("request", lineno, request=req)
            if sep:
                res, j = take_block(j)
                for r in res:
                    r = r.strip()
                    if r == "ok":
                        st.expectations.append(("ok", None))
                    elif r.startswith("error "):
                        st.expectations.append(("error", r.split()[1]))
                    elif r.startswith("match "):
                        st.expectations.append(("match", json.loads(r[6:])))
                    else:
                        raise PqtSyntaxError(f"{path}:{lineno}: bad expectation {r!r}")
            else:
                st.expectations.append(("ok", None))
            steps.append(st)
            i = j
        else:
            raise PqtSyntaxError(f"{path}:{lineno}: unknown directive {word!r}")
    if phase == 0:
        raise PqtSyntaxError(f"{path}: missing @phase")
    return PqtFile(path, phase, requires, engine_args, steps)


# ---------------------------------------------------------------- comparison

def float_eq(a: float, b: float) -> bool:
    return abs(a - b) <= FLOAT_REL_TOL * max(1.0, abs(a), abs(b))


def value_eq(expected: Any, actual: Any, typ: str) -> bool:
    if expected is None or actual is None:
        return expected is None and actual is None
    if typ == "FLOAT64":
        if isinstance(actual, bool) or not isinstance(actual, (int, float)):
            return False
        if isinstance(expected, str):
            return False
        return math.isfinite(actual) and float_eq(float(expected), float(actual))
    if typ == "INT64":
        return isinstance(actual, int) and not isinstance(actual, bool) and actual == expected
    if typ == "BOOLEAN":
        return isinstance(actual, bool) and actual == expected
    # STRING, DECIMAL(p,s), DATE, TIMESTAMP: exact string match
    return isinstance(actual, str) and actual == expected


def row_eq(exp: list, act: list, types: list[str]) -> bool:
    return len(exp) == len(act) and all(value_eq(e, a, t) for e, a, t in zip(exp, act, types))


def _sort_key(row: list, types: list[str]) -> tuple:
    key = []
    for v, t in zip(row, types):
        if v is None:
            key.append((0, 0))
        elif t == "FLOAT64" or t == "INT64":
            key.append((1, float(v)))
        elif t.startswith("DECIMAL"):
            key.append((1, float(v)))
        elif t == "BOOLEAN":
            key.append((1, int(v)))
        else:
            key.append((2, str(v)))
    return tuple(key)


def rows_match(exp: list[list], act: list[list], types: list[str], ordered: bool) -> tuple[bool, str]:
    if len(exp) != len(act):
        return False, f"row count: expected {len(exp)}, got {len(act)}"
    if ordered:
        for k, (e, a) in enumerate(zip(exp, act)):
            if not row_eq(e, a, types):
                return False, f"row {k}: expected {json.dumps(e)}, got {json.dumps(a)}"
        return True, ""
    # Multiset comparison with float tolerance: sort both, then greedy match per
    # neighbourhood (tolerant values sort adjacently).
    try:
        es = sorted(exp, key=lambda r: _sort_key(r, types))
        as_ = sorted(act, key=lambda r: _sort_key(r, types))
    except (TypeError, ValueError):
        return False, "result contains values of unexpected JSON types"
    if all(row_eq(e, a, types) for e, a in zip(es, as_)):
        return True, ""
    remaining = list(as_)
    for e in es:
        for idx, a in enumerate(remaining):
            if row_eq(e, a, types):
                del remaining[idx]
                break
        else:
            return False, f"expected row {json.dumps(e)} not found in result"
    return True, ""


def subset_match(expected: Any, actual: Any, path: str = "$") -> tuple[bool, str]:
    if isinstance(expected, dict):
        if not isinstance(actual, dict):
            return False, f"{path}: expected object"
        for k, v in expected.items():
            if k not in actual:
                return False, f"{path}.{k}: missing"
            ok, msg = subset_match(v, actual[k], f"{path}.{k}")
            if not ok:
                return False, msg
        return True, ""
    if isinstance(expected, list):
        if not isinstance(actual, list) or len(actual) != len(expected):
            return False, f"{path}: expected array of length {len(expected)}"
        for k, (e, a) in enumerate(zip(expected, actual)):
            ok, msg = subset_match(e, a, f"{path}[{k}]")
            if not ok:
                return False, msg
        return True, ""
    if isinstance(expected, float) and isinstance(actual, (int, float)) and not isinstance(actual, bool):
        return (float_eq(expected, float(actual)), f"{path}: expected {expected}, got {actual}")
    if type(expected) is not type(actual) or expected != actual:
        return False, f"{path}: expected {json.dumps(expected)}, got {json.dumps(actual)}"
    return True, ""


def walk_plan(node: Any):
    if isinstance(node, dict):
        yield node
        for c in node.get("children", []) or []:
            yield from walk_plan(c)
