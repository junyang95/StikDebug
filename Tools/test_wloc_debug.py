import copy
import importlib.util
from pathlib import Path
import json
import unittest

spec = importlib.util.spec_from_file_location("wloc_debug", Path(__file__).with_name("wloc-debug.py"))
debug = importlib.util.module_from_spec(spec)
spec.loader.exec_module(debug)


class DebugReaderTests(unittest.TestCase):
    def setUp(self):
        self.record = {"version": 1, "at": 1000, "bundleID": "test.app.networkextension",
                       "source": "tunnel", "event": "snapshot", "snapshot": {
                           "mode": "wlocProbe", "sessionID": "B1000000-0000-0000-0000-000000000001",
                           "resetAt": 990, "listening": True, "active": 0, "port": 1234,
                           "hosts": {"gs-loc.apple.com": {"connections": 1, "sent": 100, "received": 200}}}}

    def test_accepts_only_expected_app(self):
        line = "system prefix " + debug.PREFIX + json.dumps(self.record)
        self.assertEqual(debug.parse_line(line, "test.app"), self.record)
        self.assertIsNone(debug.parse_line(line, "other.app"))

    def test_rejects_private_or_unexpected_fields(self):
        for path in ((), ("snapshot",), ("snapshot", "hosts", "gs-loc.apple.com")):
            record = copy.deepcopy(self.record)
            target = record
            for key in path:
                target = target[key]
            target["payload"] = "private"
            self.assertFalse(debug.validate_record(record, "test.app"))
        self.record["snapshot"]["error"] = "https://private.example/"
        self.assertFalse(debug.validate_record(self.record, "test.app"))

    def test_rejects_malformed_oversized_or_nonfinite_records(self):
        for text in ("not JSON", "{}", "x" * 4097, "[]", "null"):
            self.assertIsNone(debug.parse_line(debug.PREFIX + text, "test.app"))
        self.record["at"] = float("nan")
        self.assertFalse(debug.validate_record(self.record, "test.app"))

    def test_rejects_unknown_hosts_and_wrong_types(self):
        self.record["snapshot"]["hosts"]["unknown.example"] = {"connections": 0, "sent": 0, "received": 0}
        self.assertFalse(debug.validate_record(self.record, "test.app"))
        self.record["snapshot"]["hosts"].pop("unknown.example")
        self.record["snapshot"]["active"] = True
        self.assertFalse(debug.validate_record(self.record, "test.app"))


if __name__ == "__main__":
    unittest.main()
