"""PolyQuery: an analytical database engine (Python implementation).

The embedding API (spec/apps/embedding.md, EMBEDDING.md) is available as
``polyquery.Database``, ``polyquery.Result``, ``polyquery.Error`` etc.; it is
defined in :mod:`polyquery.api` and imported on first use."""

ENGINE_NAME = "polyquery-python"
ENGINE_VERSION = "0.4.0"
PROTOCOL_VERSION = 1
SPEC_VERSION = "1.0.0"

_API_NAMES = ("ColumnInfo", "Database", "Error", "Result", "TableInfo", "VALUE_TYPES", "configure_interpreter")

__all__ = ["ENGINE_NAME", "ENGINE_VERSION", "PROTOCOL_VERSION", "SPEC_VERSION", *_API_NAMES]


def __getattr__(name: str):
    # imported lazily: the engine's own modules import this package first
    if name in _API_NAMES:
        from . import api

        return getattr(api, name)
    raise AttributeError(f"module 'polyquery' has no attribute {name!r}")


def __dir__() -> list[str]:
    return sorted(__all__)
