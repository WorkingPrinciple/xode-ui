#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Controlled local packaging pins; external approval is required, never inferred."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys

PRODUCER = "c1073100ce8936a751b962b1401ddb641c8be38a"
PRODUCER_TREE = "7a808c0e6a8a909455d07eb463379ab55bdf138c"
FEATURES = {"xodus": [], "xodus-cli": [], "xodus-management": ["live"],
            "apple-native-keyring-store": ["keychain", "security-framework"]}
PROFILE = {"opt_level": "3", "debuginfo": 0, "debug_assertions": False,
           "overflow_checks": False, "test": False}
COMMAND = ["cargo", "build", "--release", "--offline", "--locked", "-q", "-p",
           "xodus-cli", "--bin", "xodus-cli", "--target", "aarch64-apple-darwin",
           "--no-default-features", "--message-format=json"]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def hex_value(value, length):
    require(isinstance(value, str) and re.fullmatch("[0-9a-f]{" + str(length) + "}", value),
            "Expected canonical reviewed hash/source pin")
    return value


def positive(value):
    require(type(value) is int and value > 0, "Expected positive exact byte count")
    return value


def owned_bytes(path, expected_hash=None, expected_size=None, bounded=None):
    path = Path(path)
    require(path.is_absolute() and path.resolve(strict=True) == path, "Noncanonical or linked artifact path")
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0)
                 | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0))
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1, "Artifact must be regular and single-link")
        if os.name == "posix":
            require(before.st_uid == os.getuid() and before.st_mode & 0o022 == 0, "Unsafe artifact ownership/mode")
        if expected_size is not None:
            require(before.st_size == positive(expected_size), "Artifact size differs from external approval")
        require(bounded is None or 0 < before.st_size <= bounded, "Provenance exceeds bound")
        digest = hashlib.sha256()
        chunks = [] if bounded else None
        with os.fdopen(fd, "rb", closefd=False) as stream:
            while block := stream.read(65536):
                digest.update(block)
                if chunks is not None:
                    chunks.append(block)
        after = os.fstat(fd)
        key = lambda info: (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_nlink,
                            info.st_size, info.st_mtime_ns, info.st_ctime_ns)
        require(key(before) == key(after), "Artifact changed during verification")
        actual = digest.hexdigest()
        if expected_hash is not None:
            require(actual == hex_value(expected_hash, 64), "Artifact digest differs from external approval")
        return {"sha256": actual, "bytes": before.st_size}, b"".join(chunks) if chunks is not None else None
    finally:
        os.close(fd)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "Duplicate provenance key")
        result[key] = value
    return result


def verify_input(engine, engine_hash, engine_bytes, proof_hash, proof_bytes):
    engine_record, _ = owned_bytes(engine, engine_hash, engine_bytes)
    proof_record, data = owned_bytes(str(engine) + ".provenance.json", proof_hash, proof_bytes, 65536)
    proof = json.loads(data, object_pairs_hook=unique_object)
    require(type(proof) is dict and type(proof.get("version")) is int and proof["version"] == 1,
            "Unsupported sealed provenance")
    for key, expected in {
        "sourceCommit": PRODUCER, "sourceTree": PRODUCER_TREE,
        "sealedSHA256": engine_record["sha256"], "sealedBytes": engine_record["bytes"],
        "sealedArtifact": str(engine), "sealedMode": "0500",
        "nativeResolvedFeatures": FEATURES, "postBuildNativeResolvedFeatures": FEATURES,
        "buildProfile": PROFILE, "command": COMMAND,
        "architecture": "arm64", "host": "arm64", "target": "aarch64-apple-darwin",
        "metadataPlatformFilter": "aarch64-apple-darwin", "appSigningPerformed": False,
        "signingState": "Rust/linker ad-hoc only; no separate app signing/DeveloperID identity",
        "cargoIncremental": 0, "cargoBuildJobs": 1,
    }.items():
        require(proof.get(key) == expected and type(proof.get(key)) is type(expected),
                "Sealed provenance does not match reviewed release input: " + key)
    # Python equality treats bool as int, so validate the complete profile types too.
    require(set(proof["buildProfile"]) == set(PROFILE)
            and all(type(proof["buildProfile"][key]) is type(value) for key, value in PROFILE.items()),
            "Wrong-type native release profile")
    if os.name == "posix":
        require(stat.S_IMODE(Path(engine).stat().st_mode) == 0o500
                and stat.S_IMODE(Path(str(engine) + ".provenance.json").stat().st_mode) == 0o400
                and type(proof.get("sealedUID")) is int and proof["sealedUID"] == os.getuid(),
                "Unsigned sealed input ownership/mode differs")
    return {"schemaVersion": 1, "producerCommit": PRODUCER, "producerTree": PRODUCER_TREE,
            "externalUnsignedCLI": engine_record, "externalProvenance": proof_record,
            "profile": PROFILE, "features": FEATURES}


def swift_pins(app_source, app_tree, engine, helper):
    source, tree = hex_value(app_source, 40), hex_value(app_tree, 40)
    for record in (engine, helper):
        hex_value(record["sha256"], 64)
        positive(record["bytes"])
    return f'''// Generated ONLY for an externally approved controlled local package.
enum ShippingPairPins {{
    static let approved: ShippingPairIdentity? = ShippingPairIdentity(
        schemaVersion: 1,
        appSourceCommit: "{source}", appSourceTree: "{tree}",
        producerCommit: "{PRODUCER}", producerTree: "{PRODUCER_TREE}",
        engineSHA256: "{engine["sha256"]}", engineBytes: {engine["bytes"]},
        helperSHA256: "{helper["sha256"]}", helperBytes: {helper["bytes"]},
        helperVersion: 1, helperSourceCommit: "{source}")
}}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="operation", required=True)
    verify = commands.add_parser("verify")
    for name in ("engine", "engine-hash", "proof-hash"):
        verify.add_argument("--" + name, required=True)
    for name in ("engine-bytes", "proof-bytes"):
        verify.add_argument("--" + name, type=int, required=True)
    verify.add_argument("--output", required=True)
    generate = commands.add_parser("generate")
    for name in ("source", "tree", "engine", "helper", "approval", "output", "receipt"):
        generate.add_argument("--" + name, required=True)
    args = parser.parse_args()
    require(sys.platform == "darwin", "Packaging is restricted to an explicitly approved macOS stage")
    if args.operation == "verify":
        record = verify_input(args.engine, args.engine_hash, args.engine_bytes, args.proof_hash, args.proof_bytes)
        with open(args.output, "x", encoding="utf-8") as stream:
            json.dump(record, stream, sort_keys=True)
            stream.write("\n")
    else:
        engine, _ = owned_bytes(args.engine)
        helper, _ = owned_bytes(args.helper)
        approval = json.loads(Path(args.approval).read_bytes(), object_pairs_hook=unique_object)
        require(approval.get("producerCommit") == PRODUCER and approval.get("producerTree") == PRODUCER_TREE,
                "Missing previously verified external approval")
        output = Path(args.output)
        require(output.name == "ShippingPairPins.swift" and output.is_file() and not output.is_symlink(),
                "Only the isolated-stage pin template can be replaced")
        output.write_bytes(swift_pins(args.source, args.tree, engine, helper).encode("utf-8"))
        approval.update({"approvedAppSourceCommit": hex_value(args.source, 40),
                         "approvedAppSourceTree": hex_value(args.tree, 40),
                         "signedBundledCLI": engine, "signedHelper": helper, "helperVersion": 1,
                         "helperSourceCommit": args.source,
                         "generatedPinsSHA256": hashlib.sha256(output.read_bytes()).hexdigest(),
                         "qualification": "Controlled local operator-approved pair; not distribution attestation."})
        with open(args.receipt, "x", encoding="utf-8") as stream:
            json.dump(approval, stream, sort_keys=True)
            stream.write("\n")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, json.JSONDecodeError) as error:
        raise SystemExit("Packaging admission failed: " + str(error))
