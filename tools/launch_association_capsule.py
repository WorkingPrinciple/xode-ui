#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Explicit private capsule staging; never installs, signs, or executes assets."""
import json
import os
from pathlib import Path
import stat
import sys
from shipping_pair import owned_bytes, require, unique_object

BROKER_SHA256 = "f9c4ed146c7d6dfc94334255907d4e0658218585085ca2107a5181b4deb474fc"
NAMES = {"manifest.json", "adapter.py", "peer.dylib"}


def verify_capsule(directory):
    directory = Path(directory)
    info = directory.lstat()
    require(directory.is_absolute() and directory.resolve(strict=True) == directory
            and stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid()
            and info.st_mode & 0o022 == 0, "Unsafe private capsule directory")
    require({p.name for p in directory.iterdir()} == NAMES, "Unexpected private capsule files")
    manifest_identity, data = owned_bytes(directory / "manifest.json", bounded=4096)
    manifest = json.loads(data, object_pairs_hook=unique_object)
    require(type(manifest) is dict and set(manifest) == {
        "version", "enabled", "adapterSHA256", "peerSHA256", "brokerSHA256"},
        "Invalid private capsule manifest")
    require(type(manifest["version"]) is int and manifest["version"] == 1
            and type(manifest["enabled"]) is bool
            and manifest["brokerSHA256"] == BROKER_SHA256, "Unqualified private capsule contract")
    files = {"manifest.json": manifest_identity}
    for name, key in [("adapter.py", "adapterSHA256"), ("peer.dylib", "peerSHA256")]:
        files[name], _ = owned_bytes(directory / name, manifest[key], bounded=16 * 1024 * 1024)
    return files


def stage_capsule(source, destination, receipt):
    source, destination, receipt = Path(source), Path(destination), Path(receipt)
    approved = verify_capsule(source)
    destination.mkdir(mode=0o700)
    for name, identity in approved.items():
        _, data = owned_bytes(source / name, identity["sha256"], identity["bytes"], 16 * 1024 * 1024)
        with (destination / name).open("xb") as stream:
            stream.write(data)
        (destination / name).chmod(0o600)
    require(verify_capsule(destination) == approved and verify_capsule(source) == approved,
            "Private capsule changed during staging")
    record = json.loads(receipt.read_bytes(), object_pairs_hook=unique_object)
    require("privateLaunchAssociation" not in record, "Private capsule already staged")
    record["privateLaunchAssociation"] = approved
    receipt.write_text(json.dumps(record, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    try:
        stage_capsule(*sys.argv[1:])
    except (ValueError, OSError, KeyError, TypeError) as error:
        raise SystemExit("Private capsule staging failed: " + str(error))
