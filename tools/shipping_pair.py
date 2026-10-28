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
from legacy_compatibility import CRATE_CLI, CRATE_CORE, CRATE_MANAGEMENT, LEGACY_SCHEMA_ID_PREFIX, PRODUCER_CLI

PRODUCER = "dcc7dbda6e2215069907d9f8240823d3284a79b6"
PRODUCER_TREE = "e265702e2fe43939c6dc87a519499b5121e8c38d"
CLI_SHA256 = "3da6b7a42acaf33fa0ab36c44ddc5f4574f7f644bd4434ad6de70e2c85632db6"
CLI_BYTES = 30_992_384
WINDOWS_HELPER_SHA256 = "c205a45fcfa703296593034498a35c177ad7e9c80fdd1a4ddeec2fdb721bface"
WINDOWS_HELPER_BYTES = 22_016
PRODUCER_MANIFEST_SHA256 = "bbd2626b9a7be86827bb9606d1154238a0323e4e29f5f65b877e5ff4dcb84506"
CARGO_LOCK_SHA256 = "e0123c68f37c7c0a272829fea83670d70c473a165643a70b6a474e8b97dddb93"
SOURCE_ARCHIVE_NAME = "xodus-cli-dcc7dbda-source.tar"
SOURCE_ARCHIVE_SHA256 = "f47e44f24bc89e190d8ea7527f3366b56133edf5a8eb900f287169897b5a92cd"
SOURCE_ARCHIVE_BYTES = 10_639_360
FEATURES = {CRATE_CORE: [], CRATE_CLI: [], CRATE_MANAGEMENT: ["live"],
            "apple-native-keyring-store": ["keychain", "security-framework"]}
PROFILE = {"opt_level": "3", "debuginfo": 0, "debug_assertions": False,
           "overflow_checks": False, "test": False}
COMMAND = ["cargo", "build", "--release", "--offline", "--locked", "-q", "-p",
           CRATE_CLI, "--bin", PRODUCER_CLI, "--target", "aarch64-apple-darwin",
           "--no-default-features", "--message-format=json"]


def require(condition, message):
    if not condition:
        raise ValueError(message)


# REQ-150: this app uses Ode identities, so it pairs only with a reviewed producer built after the rename.
# Set True only when the pins above name such a producer; until then every packaging path refuses.
PRODUCER_RENAMED = True
RENAMED_SCHEMA_ID = b'"urn:ode:management:1.0"'
# Producers known to predate the rename. Setting the flag without moving the pins off these still refuses.
PRE_RENAME_PRODUCERS = frozenset({"bcc11c98621cf9f90679e383f02ec4516df57ad5",
                                  "399957962f35eee6189b8fbcef9697f47e951581"})


def require_renamed_producer(contract=None):
    require(PRODUCER_RENAMED and PRODUCER not in PRE_RENAME_PRODUCERS,
            "The pinned producer predates the Ode rename; pin a reviewed renamed producer "
            "before packaging this app (REQ-150)")
    if contract is not None:
        require(LEGACY_SCHEMA_ID_PREFIX.encode() not in contract and RENAMED_SCHEMA_ID in contract,
                "The producer contract still carries pre-rename schema IDs; this app pairs only with a "
                "renamed producer (REQ-150)")


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


def validate_producer_inventory(path, expected_digest):
    require(isinstance(expected_digest, str) and re.fullmatch("[0-9a-f]{64}", expected_digest) is not None,
            "Producer-notice inventory requires an exact external digest")
    identity, data = owned_bytes(path, expected_digest, bounded=32 * 1024 * 1024)
    inventory = json.loads(data, object_pairs_hook=unique_object)
    expected_producer = {"commit": PRODUCER, "tree": PRODUCER_TREE}
    require(type(inventory) is dict and inventory.get("producer") == expected_producer,
            "Producer-notice inventory does not identify the approved source")
    for key, expected in {
        "cliSHA256": CLI_SHA256,
        "helperSHA256": WINDOWS_HELPER_SHA256,
        "producerManifestSHA256": PRODUCER_MANIFEST_SHA256,
        "cargoLockSHA256": CARGO_LOCK_SHA256,
    }.items():
        require(inventory.get(key) == expected,
                "Producer-notice inventory differs from the approved tuple: " + key)
    source_delivery = inventory.get("sourceDelivery")
    require(type(source_delivery) is dict,
            "Producer-notice inventory has no corresponding-source delivery record")
    source_archive = source_delivery.get("sourceArchive")
    require(type(source_archive) is dict
            and source_archive.get("file") == SOURCE_ARCHIVE_NAME
            and source_archive.get("sha256") == SOURCE_ARCHIVE_SHA256
            and source_archive.get("bytes") == SOURCE_ARCHIVE_BYTES
            and source_archive.get("producer") == expected_producer,
            "Producer-notice inventory does not bind the approved corresponding-source archive")
    return identity


def swift_producer_pins():
    return f'''// Generated for this approved producer source.
enum ShippingProducerPins {{
    static let commit = "{PRODUCER}"
    static let tree = "{PRODUCER_TREE}"
}}
'''


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


def swift_pins(app_source, app_tree, engine, helper, producer=PRODUCER, producer_tree=PRODUCER_TREE):
    source, tree = hex_value(app_source, 40), hex_value(app_tree, 40)
    producer, producer_tree = hex_value(producer, 40), hex_value(producer_tree, 40)
    for record in (engine, helper):
        hex_value(record["sha256"], 64)
        positive(record["bytes"])
    return f'''// Generated ONLY for an externally approved controlled local package.
enum ShippingPairPins {{
    static let approved: ShippingPairIdentity? = ShippingPairIdentity(
        schemaVersion: 1,
        appSourceCommit: "{source}", appSourceTree: "{tree}",
        producerCommit: "{producer}", producerTree: "{producer_tree}",
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
