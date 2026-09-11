import copy
import importlib.util
from pathlib import Path
import json
import unittest
from types import SimpleNamespace
from unittest.mock import patch

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

    def test_command_copies_payload_then_marker_and_matches_ack(self):
        args = SimpleNamespace(device="test-device", bundle_id="test.app", no_launch=True, command="status")
        calls = []
        request = {}

        def transport(args, work, command):
            calls.append(command[:2])
            if command[:2] == ["info", "files"]:
                return True
            if command[:2] == ["copy", "to"]:
                source = command[command.index("--source") + 1]
                if source.endswith("request.json"):
                    request.update(json.loads(Path(source).read_text()))
                else:
                    self.assertEqual(Path(source).read_text(), request["id"])
            else:
                response = {"version": 1, "at": 1000, "bundleID": args.bundle_id, "source": "app",
                            "event": "command", "requestID": request["id"], "result": "ok"}
                (work / "response.json").write_text(json.dumps(response))
            return True

        with patch.object(debug, "device_call", side_effect=transport), patch("builtins.print"):
            self.assertEqual(debug.send_command(args), 0)
        self.assertEqual(calls, [["info", "files"], ["copy", "to"], ["copy", "to"], ["copy", "from"]])
        self.assertEqual(request["action"], "status")

    def test_failed_copy_never_sends_commit_marker_or_retries(self):
        args = SimpleNamespace(device="test-device", bundle_id="test.app", no_launch=True, command="reset")
        with patch.object(debug, "device_call", side_effect=[True, False]) as transport:
            with self.assertRaises(RuntimeError):
                debug.send_command(args)
            self.assertEqual(transport.call_count, 2)

    def test_unready_mailbox_does_not_submit_any_action(self):
        args = SimpleNamespace(device="test-device", bundle_id="test.app", no_launch=True, command="reset")
        with patch.object(debug, "device_call", return_value=False) as transport, \
                patch.object(debug.time, "monotonic", side_effect=[0, 9]):
            with self.assertRaisesRegex(RuntimeError, "not ready"):
                debug.send_command(args)
            self.assertEqual(transport.call_count, 1)
            self.assertEqual(transport.call_args.args[2][:2], ["info", "files"])


if __name__ == "__main__":
    unittest.main()
