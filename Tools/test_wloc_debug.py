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

    def lifecycle_record(self):
        return {"version": 1, "at": 1000, "bundleID": "test.app.networkextension", "source": "tunnel",
                "event": "connection", "counters": {key: 0 for key in debug.COUNTERS}, "connection": {
                    "id": "B1000000-0000-0000-0000-000000000002",
                    "sessionID": "B1000000-0000-0000-0000-000000000001", "resetAt": 990,
                    "phase": "closed", "elapsedMS": 100, "sent": 20, "received": 30,
                    "clientEOF": True, "upstreamEOF": False, "host": "gs-loc.apple.com",
                    "reason": "transportError", "failure": {"operation": "relayRead", "side": "upstream",
                        "network": {"domain": "posix", "code": 54}, "availableBytes": 0, "endOfStream": False}}}

    def test_accepts_lifecycle_phases_and_signed_network_codes(self):
        record = self.lifecycle_record()
        self.assertEqual(debug.parse_line(debug.PREFIX + json.dumps(record), "test.app"), record)
        for phase in ("accepted", "targetValidated", "upstreamReady", "relayReady"):
            with self.subTest(phase=phase):
                current = copy.deepcopy(record)
                current["connection"]["phase"] = phase
                for key in ("host", "reason", "failure"):
                    current["connection"].pop(key)
                self.assertTrue(debug.validate_record(current, "test.app"))
        for domain, code in (("posix", -54), ("tls", -9806), ("dns", -65537), ("other", 0)):
            with self.subTest(domain=domain, code=code):
                record["connection"]["failure"]["network"] = {"domain": domain, "code": code}
                self.assertTrue(debug.validate_record(record, "test.app"))
        record["connection"]["failure"]["network"] = {"domain": "other"}
        self.assertTrue(debug.validate_record(record, "test.app"))

    def test_termination_order_records_and_legacy_records_are_accepted(self):
        record = self.lifecycle_record()
        self.assertTrue(debug.validate_record(record, "test.app"))
        record["connection"]["termination"] = {
            "client": {"readEOF": {"order": 1, "elapsedMS": 20}},
            "upstream": {"writeCloseSubmitted": {"order": 2, "elapsedMS": 20},
                         "writeCloseCompleted": {"order": 3, "elapsedMS": 21}}}
        record["connection"]["failure"]["observedAt"] = {"order": 4, "elapsedMS": 22}
        self.assertEqual(debug.parse_line(debug.PREFIX + json.dumps(record), "test.app"), record)

    def test_termination_rejects_unknown_fields_bad_types_and_impossible_orders(self):
        base = self.lifecycle_record()
        base["connection"]["termination"] = {
            "client": {"readEOF": {"order": 1, "elapsedMS": 20}},
            "upstream": {"writeCloseSubmitted": {"order": 2, "elapsedMS": 20},
                         "writeCloseCompleted": {"order": 3, "elapsedMS": 21}}}
        for value in (0, 8, True, "1", -1):
            record = copy.deepcopy(base)
            record["connection"]["termination"]["client"]["readEOF"]["order"] = value
            self.assertFalse(debug.validate_record(record, "test.app"))
        for value in (True, -1, "20", 0.5):
            record = copy.deepcopy(base)
            record["connection"]["termination"]["client"]["readEOF"]["elapsedMS"] = value
            self.assertFalse(debug.validate_record(record, "test.app"))
        for path in ((), ("client",), ("client", "readEOF")):
            record = copy.deepcopy(base)
            target = record["connection"]["termination"]
            for key in path:
                target = target[key]
            target["payload"] = "private"
            self.assertFalse(debug.validate_record(record, "test.app"))
        record = copy.deepcopy(base)
        record["connection"]["failure"]["observedAt"] = {"order": 1, "elapsedMS": 22}
        self.assertFalse(debug.validate_record(record, "test.app"))
        record = copy.deepcopy(base)
        record["connection"]["termination"]["upstream"].pop("writeCloseSubmitted")
        self.assertFalse(debug.validate_record(record, "test.app"))
        record = copy.deepcopy(base)
        record["connection"]["termination"]["upstream"]["writeCloseCompleted"]["order"] = 1
        self.assertFalse(debug.validate_record(record, "test.app"))

    def test_lifecycle_event_source_and_reason_are_constrained(self):
        for change in ("app", "missing_connection", "wrong_event", "missing_reason", "early_reason"):
            with self.subTest(change=change):
                record = self.lifecycle_record()
                if change == "app":
                    record.update(source="app", bundleID="test.app")
                elif change == "missing_connection":
                    record.pop("connection")
                elif change == "wrong_event":
                    record["event"] = "snapshot"
                elif change == "missing_reason":
                    record["connection"].pop("reason")
                else:
                    record["connection"]["phase"] = "accepted"
                self.assertFalse(debug.validate_record(record, "test.app"))

    def test_lifecycle_rejects_unknown_fields_and_private_strings(self):
        for path in ((), ("counters",), ("connection",), ("connection", "failure"),
                     ("connection", "failure", "network")):
            with self.subTest(path=path):
                record = self.lifecycle_record()
                target = record
                for key in path:
                    target = target[key]
                target["payload"] = "https://private.example/?token=secret"
                self.assertFalse(debug.validate_record(record, "test.app"))
        cases = (("host", "unknown.example"), ("host", "https://gs-loc.apple.com/clls/wloc"),
                 ("reason", "https://private.example/"), ("reason", "arbitrary_error"),
                 ("phase", "unknown"), ("id", "not-a-uuid"), ("sessionID", "not-a-uuid"))
        for key, value in cases:
            with self.subTest(key=key, value=value):
                record = self.lifecycle_record()
                record["connection"][key] = value
                self.assertFalse(debug.validate_record(record, "test.app"))
        for key in ("operation", "side"):
            record = self.lifecycle_record()
            record["connection"]["failure"][key] = "https://private.example/"
            self.assertFalse(debug.validate_record(record, "test.app"))
        record = self.lifecycle_record()
        record["connection"]["failure"]["network"]["domain"] = "https://private.example/"
        self.assertFalse(debug.validate_record(record, "test.app"))

    def test_lifecycle_rejects_invalid_counts_timestamps_and_boolean_types(self):
        record = self.lifecycle_record()
        checks = [("counters", key) for key in debug.COUNTERS]
        checks += [("connection", key) for key in ("elapsedMS", "sent", "received")]
        for section, key in checks:
            for value in (-1, True, 1.5, "1"):
                with self.subTest(section=section, key=key, value=value):
                    current = copy.deepcopy(record)
                    current[section][key] = value
                    self.assertFalse(debug.validate_record(current, "test.app"))
        for value in (-1, float("nan"), float("inf"), True, "990"):
            current = copy.deepcopy(record)
            current["connection"]["resetAt"] = value
            self.assertFalse(debug.validate_record(current, "test.app"))
        for key in ("clientEOF", "upstreamEOF"):
            current = copy.deepcopy(record)
            current["connection"][key] = 1
            self.assertFalse(debug.validate_record(current, "test.app"))
        for key, value in (("availableBytes", -1), ("availableBytes", True), ("endOfStream", 0)):
            current = copy.deepcopy(record)
            current["connection"]["failure"][key] = value
            self.assertFalse(debug.validate_record(current, "test.app"))
        for value in (True, 1.5, "-9806"):
            current = copy.deepcopy(record)
            current["connection"]["failure"]["network"]["code"] = value
            self.assertFalse(debug.validate_record(current, "test.app"))

    def test_counters_require_all_fields_and_preserve_old_record_compatibility(self):
        self.assertTrue(debug.validate_record(self.record, "test.app"))
        self.record["counters"] = {key: 0 for key in debug.COUNTERS}
        self.assertTrue(debug.validate_record(self.record, "test.app"))
        self.record["counters"].pop("closed")
        self.assertFalse(debug.validate_record(self.record, "test.app"))

    def test_lifecycle_records_keep_4096_byte_bound(self):
        record = self.lifecycle_record()
        text = json.dumps(record)
        self.assertLessEqual(len(text.encode("utf-8")), 4096)
        self.assertEqual(debug.parse_line(debug.PREFIX + text, "test.app"), record)
        oversized = text[:1] + " " * 4096 + text[1:]
        self.assertIsNone(debug.parse_line(debug.PREFIX + oversized, "test.app"))

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

    def test_launch_options_precede_positional_bundle_identifier(self):
        args = SimpleNamespace(device="test-device", bundle_id="test.app")
        with debug.tempfile.TemporaryDirectory(prefix="stikdebug-wloc-test-") as temporary:
            work = Path(temporary)

            def run(command, **kwargs):
                self.assertEqual(command[:5], ["xcrun", "devicectl", "device", "process", "launch"])
                bundle_index = command.index(args.bundle_id)
                for option in ("--device", "--timeout", "--quiet", "--json-output"):
                    self.assertLess(command.index(option), bundle_index)
                self.assertEqual(command[command.index("--device") + 1], args.device)
                self.assertEqual(command[-1], args.bundle_id)
                output = Path(command[command.index("--json-output") + 1])
                output.write_text(json.dumps({"info": {"outcome": "success"}}))
                return SimpleNamespace(returncode=0)

            with patch.object(debug.subprocess, "run", side_effect=run) as process:
                self.assertTrue(debug.device_call(args, work, ["process", "launch", args.bundle_id]))
                process.assert_called_once()

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
