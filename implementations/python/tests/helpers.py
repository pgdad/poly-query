"""Shared helpers for unit tests."""

from __future__ import annotations

import tempfile
from typing import Any

from polyquery.protocol.handlers import RequestHandler
from polyquery.service import Engine, EngineConfig


def make_handler(**config: Any) -> RequestHandler:
    config.setdefault("data_dir", tempfile.gettempdir())
    return RequestHandler(Engine(EngineConfig(**config)))


class EngineTestMixin:
    """Gives a test case a fresh engine plus ``load``/``query`` shortcuts."""

    handler: RequestHandler

    def setUp(self) -> None:  # noqa: D401
        self.handler = make_handler(test_functions=True)

    def request(self, **req: Any) -> dict[str, Any]:
        return self.handler.handle(req)

    def load_csv(self, table: str, data: str, **extra: Any) -> dict[str, Any]:
        resp = self.request(op="load", table=table, format="csv", data=data, **extra)
        assert resp["ok"], resp
        return resp

    def query(self, sql: str, **options: Any) -> dict[str, Any]:
        req: dict[str, Any] = {"op": "query", "sql": sql}
        if options:
            req["options"] = options
        return self.handler.handle(req)

    def rows(self, sql: str) -> list[list[Any]]:
        resp = self.query(sql)
        assert resp["ok"], resp
        return [list(r) for r in resp["rows"]]

    def error_code(self, sql: str, **options: Any) -> str:
        resp = self.query(sql, **options)
        assert not resp["ok"], resp
        return resp["error"]["code"]
