"""Detects clients that disconnect while their query executes (concurrency.md §4).

One background thread polls the sockets of connections whose request is
being processed; when a peer closes its end, the registered callback (which
cancels the query) is invoked.
"""

from __future__ import annotations

import select
import socket
import threading
from collections.abc import Callable, Iterator
from contextlib import contextmanager

_POLL_MS = 20
_HANGUP = select.POLLHUP | select.POLLERR | select.POLLNVAL | getattr(select, "POLLRDHUP", 0)


class _Watch:
    __slots__ = ("sock", "on_disconnect")

    def __init__(self, sock: socket.socket, on_disconnect: Callable[[], None]):
        self.sock = sock
        self.on_disconnect = on_disconnect


class DisconnectWatcher:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._watches: set[_Watch] = set()
        self._wakeup = threading.Event()
        self._thread: threading.Thread | None = None

    @contextmanager
    def watch(self, sock: socket.socket, on_disconnect: Callable[[], None]) -> Iterator[None]:
        entry = _Watch(sock, on_disconnect)
        with self._lock:
            self._watches.add(entry)
            if self._thread is None:
                self._thread = threading.Thread(target=self._run, name="disconnect-watcher", daemon=True)
                self._thread.start()
        self._wakeup.set()
        try:
            yield
        finally:
            with self._lock:
                self._watches.discard(entry)

    def _run(self) -> None:
        while True:
            with self._lock:
                watches = list(self._watches)
                if not watches:
                    self._wakeup.clear()
            if not watches:
                self._wakeup.wait()
                continue
            poller = select.poll()
            by_fd: dict[int, _Watch] = {}
            for entry in watches:
                try:
                    fd = entry.sock.fileno()
                except OSError:
                    continue
                if fd < 0:
                    continue
                by_fd[fd] = entry
                poller.register(fd, select.POLLIN | _HANGUP)
            try:
                events = poller.poll(_POLL_MS)
            except OSError:
                events = []
            for fd, mask in events:
                entry = by_fd[fd]
                if self._disconnected(entry.sock, mask):
                    self._fire(entry)
                elif mask & select.POLLIN:
                    # the client sent more data (a pipelined request): the
                    # connection is alive; stop polling it to avoid spinning
                    with self._lock:
                        self._watches.discard(entry)

    @staticmethod
    def _disconnected(sock: socket.socket, mask: int) -> bool:
        if mask & _HANGUP:
            return True
        try:
            return sock.recv(1, socket.MSG_PEEK | socket.MSG_DONTWAIT) == b""
        except (BlockingIOError, InterruptedError):
            return False
        except OSError:
            return True

    def _fire(self, entry: _Watch) -> None:
        with self._lock:
            if entry not in self._watches:
                return
            self._watches.discard(entry)
        entry.on_disconnect()
