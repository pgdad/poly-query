"""Data-directory path safety (protocol.md §6) and reading input files;
shared by the protocol handlers and the embedding API."""

from __future__ import annotations

import os

from . import errors


def resolve_data_path(data_dir: str, path: str) -> str:
    """Resolves a request path inside the data directory (protocol.md §6)."""
    if path == "" or "\x00" in path or os.path.isabs(path):
        raise errors.access_denied("path must be a non-empty relative path")
    parts = path.replace("\\", "/").split("/")
    if ".." in parts:
        raise errors.access_denied("path must not contain '..' components")
    return os.path.join(data_dir, path)


def read_input_file(full_path: str, max_bytes: int) -> bytes:
    """The contents of an input file, at most ``max_bytes`` long."""
    try:
        with open(full_path, "rb") as f:
            size = os.fstat(f.fileno()).st_size
            if size > max_bytes:
                raise errors.resource_limit(f"input file exceeds the ingestion limit of {max_bytes} bytes")
            return f.read()
    except FileNotFoundError:
        raise errors.not_found("file does not exist") from None
    except PermissionError:
        raise errors.access_denied("permission denied") from None
    except IsADirectoryError:
        raise errors.io_error("path is a directory") from None
    except OSError as e:
        raise errors.io_error(f"cannot read file: {e.strerror}") from None


def decode_utf8(raw: bytes) -> str:
    """Input text of a load; invalid UTF-8 is an INGEST_ERROR."""
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        raise errors.ingest_error("input is not valid UTF-8") from None
