import io
import json
import unittest

from polyquery.protocol.session import run_exec, run_session
from tests.helpers import make_handler


class SessionTests(unittest.TestCase):
    def run_lines(self, *lines: str) -> list[dict]:
        out = io.BytesIO()
        run_session(make_handler(), io.BytesIO("\n".join(lines).encode() + b"\n"), out)
        return [json.loads(line) for line in out.getvalue().decode().splitlines()]

    def test_one_response_per_request(self):
        responses = self.run_lines('{"op":"version","id":1}', "", "not json", "[1]", '{"op":"query","sql":"SELECT \'a\\nb\'"}')
        self.assertEqual(len(responses), 4)
        self.assertEqual(responses[0]["id"], 1)
        self.assertEqual(responses[1]["error"]["code"], "INVALID_REQUEST")
        self.assertIsNone(responses[2]["id"])
        self.assertEqual(responses[3]["rows"], [["a\nb"]])

    def test_exec_array(self):
        out = io.BytesIO()
        run_exec(make_handler(), b'[{"op":"tables"},{"op":"bogus"}]', out)
        lines = out.getvalue().decode().splitlines()
        self.assertEqual(len(lines), 2)
        self.assertFalse(json.loads(lines[1])["ok"])


if __name__ == "__main__":
    unittest.main()
