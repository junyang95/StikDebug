#!/usr/bin/env python3
"""Compare the versioned, standalone core in the two app checkouts."""
import argparse
import hashlib
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("peer", type=Path, help="Path to the other app checkout")
args = parser.parse_args()

def source(root):
    choices = [root / "StikDebug/Core/DeviceAuthorizationCore.swift", root / "App/Models/DeviceAuthorizationCore.swift"]
    existing = [path for path in choices if path.is_file()]
    if len(existing) != 1:
        raise SystemExit("Expected exactly one shared authorization source in " + str(root))
    return existing[0]

local = source(Path(__file__).resolve().parent.parent)
peer = source(args.peer.resolve())
a, b = local.read_bytes(), peer.read_bytes()
if a != b:
    raise SystemExit("Authorization cores differ: " + str(local) + " / " + str(peer))
print("Authorization core parity OK: " + hashlib.sha256(a).hexdigest())
