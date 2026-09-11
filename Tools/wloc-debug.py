#!/usr/bin/env python3
"""Bounded, metadata-only WLOC diagnostics over a paired iPhone's USB connection."""
import argparse
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

PREFIX = "STIK_WLOC_DEBUG_V1 "
HOSTS = {"gs-loc.apple.com", "gs-loc-cn.apple.com", "bluedot.is.autonavi.com",
         "bluedot.is.autonavi.com.gds.alibabadns.com"}
ERRORS = {"listener_failed", "connection_limit", "connect_timeout", "idle_timeout",
          "client_failed", "header_read_failed", "connect_rejected", "parse_failed",
          "upstream_interrupted", "reply_failed", "upstream_send_failed", "upstream_failed",
          "relay_interrupted", "relay_send_failed", "proxy_error"}
COUNTERS = {"tcpAccepted", "connectAccepted", "upstreamReady", "relayReady",
            "closed", "errorClosed", "resetClosed", "stopClosed"}


def fields(value, required, optional=()):
    return (isinstance(value, dict) and set(required) <= value.keys()
            and value.keys() <= set(required) | set(optional))


def number(value):
    return type(value) in (int, float) and math.isfinite(value) and value >= 0


def integer(value):
    return type(value) is int and value >= 0


def identifier(value):
    try:
        return isinstance(value, str) and str(uuid.UUID(value)).lower() == value.lower()
    except ValueError:
        return False


def validate_failure(failure):
    if not fields(failure, {"operation", "side"}, {"network", "availableBytes", "endOfStream"}):
        return False
    if (failure["operation"] not in ("clientState", "headerRead", "upstreamConnect", "upstreamWaiting",
                                    "upstreamState", "connectReply", "initialUpload", "relayRead",
                                    "relayWrite", "halfClose")
            or failure["side"] not in ("client", "upstream")):
        return False
    if "network" in failure:
        network = failure["network"]
        if (not fields(network, {"domain"}, {"code"})
                or network["domain"] not in ("posix", "dns", "tls", "other")
                or ("code" in network and type(network["code"]) is not int)):
            return False
    if "availableBytes" in failure and not integer(failure["availableBytes"]):
        return False
    if "endOfStream" in failure and type(failure["endOfStream"]) is not bool:
        return False
    return True


def validate_connection(connection):
    if not fields(connection, {"id", "sessionID", "resetAt", "phase", "elapsedMS", "sent", "received",
                               "clientEOF", "upstreamEOF"}, {"host", "reason", "failure"}):
        return False
    if (not identifier(connection["id"]) or not identifier(connection["sessionID"])
            or not number(connection["resetAt"])
            or connection["phase"] not in ("accepted", "targetValidated", "upstreamReady", "relayReady", "closed")
            or not all(integer(connection[key]) for key in ("elapsedMS", "sent", "received"))
            or any(type(connection[key]) is not bool for key in ("clientEOF", "upstreamEOF"))):
        return False
    if "host" in connection and (not isinstance(connection["host"], str) or connection["host"] not in HOSTS):
        return False
    if (connection["phase"] == "closed") != ("reason" in connection):
        return False
    if "reason" in connection and connection["reason"] not in (
            "completeEOF", "clientEOF", "cancelled", "rejected", "transportError", "handshakeTimeout",
            "idleTimeout", "reset", "stop", "connectionLimit"):
        return False
    return "failure" not in connection or validate_failure(connection["failure"])


def validate_record(record, bundle):
    """Reject unknown fields, not just unknown events, to avoid leaking future payloads."""
    if not fields(record, {"version", "at", "bundleID", "source", "event"},
                  {"snapshot", "selfTest", "vpnState", "experimentEnabled", "requestID", "result",
                   "counters", "connection"}):
        return False
    if (type(record["version"]) is not int or record["version"] != 1 or not number(record["at"])
            or record["source"] not in ("app", "tunnel")
            or record["bundleID"] != bundle + (".networkextension" if record["source"] == "tunnel" else "")
            or record["event"] not in ("ready", "snapshot", "reset", "stopped", "selfTest", "command", "connection")):
        return False
    if (record["event"] == "connection") != ("connection" in record):
        return False
    if "connection" in record and (record["source"] != "tunnel" or not validate_connection(record["connection"])):
        return False
    if "counters" in record:
        counters = record["counters"]
        if not fields(counters, COUNTERS) or not all(integer(value) for value in counters.values()):
            return False
    if "requestID" in record and not identifier(record["requestID"]):
        return False
    if "result" in record and record["result"] not in ("ok", "busy", "unavailable", "failed", "accepted"):
        return False
    if "vpnState" in record and record["vpnState"] not in (
            "loading", "disconnected", "connecting", "connected", "disconnecting", "failed"):
        return False
    if "experimentEnabled" in record and type(record["experimentEnabled"]) is not bool:
        return False
    if "selfTest" in record:
        test = record["selfTest"]
        if not fields(test, {"outcome"}, {"httpStatus", "usedProxy", "urlErrorCode"}):
            return False
        if test["outcome"] not in ("running", "passed", "unconfirmed", "failed"):
            return False
        if "httpStatus" in test and (not integer(test["httpStatus"]) or not 0 <= test["httpStatus"] <= 599):
            return False
        if "usedProxy" in test and type(test["usedProxy"]) is not bool:
            return False
        if "urlErrorCode" in test and type(test["urlErrorCode"]) is not int:
            return False
    if "snapshot" in record:
        snap = record["snapshot"]
        if not fields(snap, {"mode", "sessionID", "resetAt", "listening", "active", "hosts"}, {"port", "error"}):
            return False
        if (snap["mode"] not in ("developerLoopback", "wlocProbe") or not identifier(snap["sessionID"])
                or not number(snap["resetAt"]) or type(snap["listening"]) is not bool
                or not integer(snap["active"]) or not isinstance(snap["hosts"], dict)
                or not snap["hosts"].keys() <= HOSTS):
            return False
        if "port" in snap and (not integer(snap["port"]) or not 1 <= snap["port"] <= 65535):
            return False
        if "error" in snap and snap["error"] not in ERRORS:
            return False
        for activity in snap["hosts"].values():
            if (not fields(activity, {"connections", "sent", "received"}, {"lastActivity"})
                    or not all(integer(activity[key]) for key in ("connections", "sent", "received"))
                    or ("lastActivity" in activity and not number(activity["lastActivity"]))):
                return False
    return True


def parse_line(line, bundle):
    if PREFIX not in line:
        return None
    text = line.split(PREFIX, 1)[1].strip()
    if len(text.encode("utf-8")) > 4096:
        return None
    try:
        record = json.loads(text)
        return record if validate_record(record, bundle) else None
    except (ValueError, TypeError, OverflowError):
        return None


def watch(args):
    executable = shutil.which("idevicesyslog")
    if not executable:
        raise RuntimeError("idevicesyslog is required (libimobiledevice).")
    command = [executable, "-u", args.udid, "-p", "StikDebug|PikminTunnel", "--no-colors", "-m", PREFIX]
    # Never store or print raw system logs. Keep at most one bounded partial line.
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL) as process:
        count, pending, dropping = 0, b"", False
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        deadline = time.monotonic() + args.seconds
        try:
            print("Reading USB WLOC metadata; no raw logs are saved.", file=sys.stderr, flush=True)
            while time.monotonic() < deadline:
                if not selector.select(timeout=min(0.5, max(0, deadline - time.monotonic()))):
                    continue
                chunk = os.read(process.stdout.fileno(), 4096)
                if not chunk:
                    break
                for piece in chunk.splitlines(keepends=True):
                    complete = piece.endswith(b"\n")
                    if not dropping:
                        pending += piece
                        if len(pending) > 8192:
                            dropping, pending = True, b""
                    if complete:
                        if not dropping:
                            record = parse_line(pending.decode("utf-8", errors="replace"), args.bundle_id)
                            if record:
                                print(json.dumps(record, ensure_ascii=False, separators=(",", ":")), flush=True)
                                count += 1
                        pending, dropping = b"", False
        finally:
            selector.close()
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        print(f"USB observation finished: {count} validated records. Zero records does not prove zero traffic.", file=sys.stderr)
        return 0 if count else 2


def device_call(args, work, command):
    """Only devicectl's documented JSON result is consumed, never its log text."""
    result_path = work / "devicectl-result.json"
    result_path.unlink(missing_ok=True)
    # Launch treats arguments after the positional bundle ID as app arguments.
    # Keep every devicectl option before that positional argument.
    result = subprocess.run(["xcrun", "devicectl", "device", *command[:2],
                             "--device", args.device, "--timeout", "10", "--quiet",
                             "--json-output", str(result_path), *command[2:]],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=12)
    if result.returncode != 0 or not result_path.exists():
        return False
    try:
        info = json.loads(result_path.read_text())
        return info.get("info", {}).get("outcome") == "success"
    except (ValueError, OSError):
        return False


def send_command(args):
    # One tool owns this device/bundle mailbox at a time. No retries of actions:
    # a timeout could mean the action ran but its acknowledgement was lost.
    key = hashlib.sha256((args.device + "/" + args.bundle_id).encode()).hexdigest()[:24]
    lock_path = Path(tempfile.gettempdir()) / ("stikdebug-wloc-" + key + ".lock")
    with lock_path.open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Another command owns this device mailbox; wait for it to finish.")
        with tempfile.TemporaryDirectory(prefix="stikdebug-wloc-command-") as temporary:
            work = Path(temporary)
            if not args.no_launch:
                if not device_call(args, work, ["process", "launch", args.bundle_id]):
                    raise RuntimeError("Cannot open Debug app. Check pairing, unlock iPhone, and retry.")
            domain = ["--domain-type", "appDataContainer", "--domain-identifier", args.bundle_id]
            # Launch acknowledgement precedes the app's asynchronous setup. Only
            # retry this read-only readiness check, never a submitted action.
            ready_deadline = time.monotonic() + 8
            while not device_call(args, work, ["info", "files", "--subdirectory", "Documents/WLOCDebug", *domain]):
                if time.monotonic() >= ready_deadline:
                    raise RuntimeError("Debug mailbox is not ready. Keep the updated Debug app foregrounded.")
                time.sleep(0.5)
            request = {"version": 1, "id": str(uuid.uuid4()), "issuedAt": time.time(),
                       "action": "selfTest" if args.command == "self-test" else args.command}
            payload = work / "request.json"
            payload.write_text(json.dumps(request))
            marker = work / "ready.txt"
            marker.write_text(request["id"])
            for file in (payload, marker):
                if not device_call(args, work, ["copy", "to", "--source", str(file),
                                                "--destination", "Documents/WLOCDebug/" + file.name, *domain]):
                    raise RuntimeError("USB mailbox copy failed. Check Debug version, app foreground, and device trust.")
            deadline = time.monotonic() + 40
            reply_path = work / "response.json"
            while time.monotonic() < deadline:
                if device_call(args, work, ["copy", "from", "--source", "Documents/WLOCDebug/response.json",
                                            "--destination", str(reply_path), *domain]):
                    if reply_path.stat().st_size <= 4096:
                        try:
                            reply = json.loads(reply_path.read_text())
                            if (validate_record(reply, args.bundle_id)
                                    and reply.get("requestID", "").lower() == request["id"]
                                    and reply.get("result") != "accepted"):
                                print(json.dumps(reply, ensure_ascii=False, separators=(",", ":")), flush=True)
                                return 0 if reply.get("result") == "ok" else 2
                        except (ValueError, TypeError):
                            pass
                time.sleep(0.5)
            raise RuntimeError("No final acknowledgement. Do not blindly resend; check status first. "
                               "Commands require app foreground and Mac/iPhone clocks within 5 seconds.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle-id", required=True, help="Exact installed Debug app ID, not the extension ID")
    commands = parser.add_subparsers(dest="command", required=True)
    stream = commands.add_parser("watch", help="Read metadata, including while the app is backgrounded")
    stream.add_argument("--udid", required=True)
    stream.add_argument("--seconds", type=int, choices=range(1, 56), default=45, metavar="1..55")
    for action in ("status", "reset", "self-test", "stop"):
        command = commands.add_parser(action, help="Send restricted USB command (opens app by default)")
        command.add_argument("--device", required=True, help="CoreDevice identifier or UDID")
        command.add_argument("--no-launch", action="store_true", help="App must already be foregrounded")
    args = parser.parse_args()
    try:
        return watch(args) if args.command == "watch" else send_command(args)
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"Diagnostic tool failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
