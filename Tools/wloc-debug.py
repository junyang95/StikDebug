#!/usr/bin/env python3
"""Bounded, metadata-only WLOC diagnostics over a paired iPhone's USB connection."""
import argparse
import json
import math
import os
import selectors
import shutil
import subprocess
import sys
import time
import uuid

PREFIX = "STIK_WLOC_DEBUG_V1 "
HOSTS = {"gs-loc.apple.com", "gs-loc-cn.apple.com", "bluedot.is.autonavi.com",
         "bluedot.is.autonavi.com.gds.alibabadns.com"}
ERRORS = {"listener_failed", "connection_limit", "connect_timeout", "idle_timeout",
          "client_failed", "header_read_failed", "connect_rejected", "parse_failed",
          "upstream_interrupted", "reply_failed", "upstream_send_failed", "upstream_failed",
          "relay_interrupted", "relay_send_failed", "proxy_error"}


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


def validate_record(record, bundle):
    """Reject unknown fields, not just unknown events, to avoid leaking future payloads."""
    if not fields(record, {"version", "at", "bundleID", "source", "event"},
                  {"snapshot", "selfTest", "vpnState", "experimentEnabled", "requestID", "result"}):
        return False
    if (type(record["version"]) is not int or record["version"] != 1 or not number(record["at"])
            or record["source"] not in ("app", "tunnel")
            or record["bundleID"] != bundle + (".networkextension" if record["source"] == "tunnel" else "")
            or record["event"] not in ("ready", "snapshot", "reset", "stopped", "selfTest", "command")):
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle-id", required=True, help="Exact installed Debug app ID, not the extension ID")
    commands = parser.add_subparsers(dest="command", required=True)
    stream = commands.add_parser("watch", help="Read metadata, including while the app is backgrounded")
    stream.add_argument("--udid", required=True)
    stream.add_argument("--seconds", type=int, choices=range(1, 56), default=45, metavar="1..55")
    args = parser.parse_args()
    try:
        return watch(args)
    except (OSError, RuntimeError) as error:
        print(f"Diagnostic tool failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
