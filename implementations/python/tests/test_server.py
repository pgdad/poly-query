import http.client
import json
import socket
import threading
import time
import unittest

from polyquery import errors
from polyquery.server.app import Server, ServerConfig
from polyquery.server.http import match_route
from polyquery.server.metrics import Metrics
from polyquery.server.queries import QueryManager
from tests.helpers import make_handler


class RoutingTests(unittest.TestCase):
    def test_routes(self):
        methods, params = match_route("/v1/tables/my%20t/schema")
        self.assertEqual(methods, {"GET": "schema"})
        self.assertEqual(params, ["my t"])
        self.assertEqual(match_route("/v1/queries/q-1")[1], ["q-1"])
        self.assertIn("PUT", match_route("/v1/tables/t")[0])
        for path in ("/", "/v1", "/v1/tables/", "/v1/nope", "health"):
            self.assertIsNone(match_route(path), path)


class QueryManagerTests(unittest.TestCase):
    def test_ids_and_duplicates(self):
        manager = QueryManager(workers=1, queue_depth=0)
        a = manager.register(None)
        manager.register("mine")
        with self.assertRaises(errors.PolyQueryError) as cm:
            manager.register("mine")
        self.assertEqual(cm.exception.code, errors.ALREADY_EXISTS)
        manager.unregister(a)
        self.assertEqual([q["query_id"] for q in manager.list()], ["mine"])

    def test_overload_and_fifo_admission(self):
        manager = QueryManager(workers=1, queue_depth=1)
        first = manager.register("a")
        manager.admit(first, None)
        second = manager.register("b")
        admitted = threading.Event()

        def wait_for_worker():
            manager.admit(second, None)
            admitted.set()

        thread = threading.Thread(target=wait_for_worker)
        thread.start()
        time.sleep(0.05)
        self.assertEqual(manager.counts(), (1, 1))
        self.assertEqual({q["query_id"]: q["state"] for q in manager.list()}, {"a": "running", "b": "queued"})
        third = manager.register("c")
        with self.assertRaises(errors.PolyQueryError) as cm:
            manager.admit(third, None)
        self.assertEqual(cm.exception.code, errors.OVERLOADED)
        manager.release(first)
        thread.join(2)
        self.assertTrue(admitted.is_set())
        self.assertEqual(manager.counts(), (1, 0))

    def test_queued_query_times_out_or_is_cancelled(self):
        manager = QueryManager(workers=1, queue_depth=4)
        manager.admit(manager.register("busy"), None)
        waiting = manager.register("w")
        with self.assertRaises(errors.PolyQueryError) as cm:
            manager.admit(waiting, time.monotonic() + 0.05)
        self.assertEqual(cm.exception.code, errors.TIMEOUT)
        self.assertEqual(manager.counts(), (1, 0))
        threading.Timer(0.05, manager.cancel, args=("w",)).start()
        with self.assertRaises(errors.PolyQueryError) as cm:
            manager.admit(waiting, None)
        self.assertEqual(cm.exception.code, errors.CANCELLED)

    def test_closed_manager_rejects(self):
        manager = QueryManager(workers=1, queue_depth=1)
        manager.close()
        with self.assertRaises(errors.PolyQueryError) as cm:
            manager.register(None)
        self.assertEqual(cm.exception.code, errors.SHUTTING_DOWN)


class MetricsTests(unittest.TestCase):
    def test_render(self):
        metrics = Metrics()
        metrics.query_finished(None, 0.5)
        metrics.query_finished(errors.TIMEOUT, 1.0)
        text = metrics.render(in_flight=2, queued=1, tables=3)
        samples = dict(line.rsplit(" ", 1) for line in text.splitlines() if not line.startswith("#"))
        self.assertEqual(samples['polyquery_queries_total{status="ok"}'], "1")
        self.assertEqual(samples['polyquery_queries_total{status="error"}'], "1")
        self.assertEqual(samples["polyquery_queries_timeout_total"], "1")
        self.assertEqual(samples["polyquery_queries_in_flight"], "2")
        self.assertEqual(float(samples["polyquery_query_duration_seconds_sum"]), 1.5)
        self.assertEqual(samples["polyquery_query_duration_seconds_count"], "2")


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.server = Server(make_handler(test_functions=True), ServerConfig(port=0, workers=2, queue_depth=2))
        self.server.start()

    def tearDown(self):
        self.server.config.shutdown_grace_ms = 0
        self.server.shutdown()

    def request(self, method, path, body=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.server.port, timeout=10)
        try:
            if isinstance(body, dict):
                body = json.dumps(body)
            conn.request(method, path, body=body)
            response = conn.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            conn.close()

    def test_load_query_and_errors(self):
        status, _, body = self.request("PUT", "/v1/tables/t?format=csv", "a,b\n1,x\n2,y\n")
        self.assertEqual(status, 201, body)
        status, headers, body = self.request("POST", "/v1/query", {"sql": "SELECT a FROM t ORDER BY a"})
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["rows"], [[1], [2]])
        self.assertIn("X-PolyQuery-Query-Id", headers)
        status, _, body = self.request("POST", "/v1/request", {"op": "query", "sql": "SELECT 1/0", "id": 7})
        self.assertEqual(status, 400)
        self.assertEqual(json.loads(body)["id"], 7)
        status, _, _ = self.request("DELETE", "/v1/queries/nope")
        self.assertEqual(status, 404)
        status, _, body = self.request("PATCH", "/v1/tables")
        self.assertEqual((status, json.loads(body)["error"]["code"]), (405, "INVALID_REQUEST"))

    def test_streaming(self):
        rows = "".join(f"{i}\n" for i in range(5000))
        self.request("PUT", "/v1/tables/n?format=csv", "v\n" + rows)
        status, headers, body = self.request("POST", "/v1/query/stream", {"sql": "SELECT v FROM n ORDER BY v"})
        self.assertEqual(status, 200)
        self.assertEqual(headers.get("Transfer-Encoding"), "chunked")
        lines = [json.loads(line) for line in body.decode().splitlines()]
        self.assertEqual(lines[0]["type"], "header")
        self.assertEqual(lines[-1], {"type": "end", "row_count": 5000})
        values = [r[0] for line in lines if line["type"] == "rows" for r in line["rows"]]
        self.assertEqual(values, list(range(5000)))

    def test_malformed_chunk_size_is_rejected(self):
        # chunk-size is 1*HEXDIG: a sign must not be accepted (a negative
        # size made the server read until the client closed the connection)
        for size in (b"-5", b"+5", b"0x5", b"1_0", b""):
            with socket.create_connection(("127.0.0.1", self.server.port), timeout=5) as sock:
                sock.sendall(
                    b"PUT /v1/tables/neg?format=csv HTTP/1.1\r\nHost: x\r\n"
                    b"Transfer-Encoding: chunked\r\n\r\n" + size + b"\r\na\n1\n"
                )
                head = sock.recv(64).decode("latin-1")
            self.assertTrue(head.startswith("HTTP/1.1 400"), (size, head))
        status, _, body = self.request("GET", "/v1/tables")
        self.assertEqual((status, json.loads(body)["tables"]), (200, []))

    def test_timeout_and_metrics(self):
        status, _, body = self.request(
            "POST", "/v1/query", {"sql": "SELECT PQ_SLEEP(2000)", "options": {"timeout_ms": 50}}
        )
        self.assertEqual((status, json.loads(body)["error"]["code"]), (504, "TIMEOUT"))
        status, _, body = self.request("GET", "/metrics")
        self.assertIn("polyquery_queries_timeout_total 1", body.decode())


if __name__ == "__main__":
    unittest.main()
