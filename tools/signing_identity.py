#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Explicit local signing policy; never provision, unlock or export a Keychain identity."""
import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path
from shipping_pair import (FEATURES, PROFILE, PRODUCER, PRODUCER_TREE, hex_value,
                           owned_bytes, positive, require, unique_object, verify_input)

IDENTIFIERS = {"app": "io.github.dragoshont.xodus",
               "cli": "io.github.dragoshont.xodus.cli",
               "helper": "io.github.dragoshont.xodus.auth-host",
               "broker": "io.github.dragoshont.xodus.credential-broker"}
COMPARISON_RESULT = (
    "Different signed artifacts share the fixed certificate-bound designated requirement. "
    "Independent-build qualification requires two separately approved build receipts/runs; "
    "it is not established by this comparison.")


def command(arguments):
    result = subprocess.run(arguments, capture_output=True, text=True, timeout=30)
    require(result.returncode == 0, "Signing command failed; no ad-hoc fallback or Keychain alteration performed")
    require(len(result.stdout) + len(result.stderr) <= 65536, "Signing metadata exceeds its bound")
    return result.stdout + result.stderr


def preflight(identity=None, local_ad_hoc=False, run=command):
    require(bool(identity) != local_ad_hoc,
            "Supply an OS Keychain code-signing identity, or explicitly select local-ad-hoc; no default fallback")
    if local_ad_hoc:
        return "-"
    require(re.fullmatch(r"[0-9a-fA-F]{40}", identity) is not None,
            "Signing identity must be an exact public certificate SHA1 fingerprint, not a name or private key")
    fingerprint = identity.upper()
    available = run(["/usr/bin/security", "find-identity", "-p", "codesigning"])
    # A local fixed-leaf requirement does not need global certificate trust.
    matching = re.findall(
        r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"[^"\n]*"'
        r'(?:[ \t]+\(CSSMERR_TP_NOT_TRUSTED\))?[ \t]*$', available, re.MULTILINE)
    require(fingerprint in {value.upper() for value in matching},
            "Supplied OS Keychain code-signing identity is unavailable; human-approved provisioning is required")
    return fingerprint


def sign(path, kind, identity=None, local_ad_hoc=False, run=command):
    signer = preflight(identity, local_ad_hoc, run)
    arguments = ["/usr/bin/codesign", "--force", "--sign", signer,
                 "--identifier", IDENTIFIERS[kind], "--timestamp=none"]
    if not local_ad_hoc:
        # Bind the fixed identifier to the supplied certificate, not this build's cdhash.
        arguments += ["--requirements", '=designated => identifier "' + IDENTIFIERS[kind]
                      + '" and certificate leaf = H"' + signer + '"']
    run(arguments + [str(path)])
    run(["/usr/bin/codesign", "--verify", "--strict", str(path)])


def compare(first, second, kind, identity, run=command):
    signer = preflight(identity, run=run)
    first_record, _ = owned_bytes(first)
    second_record, _ = owned_bytes(second)
    require(first_record["sha256"] != second_record["sha256"],
            "Designated-requirement comparison requires two different signed artifacts")
    requirements = [verify_designated_requirement(path, kind, signer, run) for path in (first, second)]
    require(requirements[0] == requirements[1], "Signed artifacts have different designated requirements")
    return COMPARISON_RESULT


def verify_designated_requirement(path, kind, identity, run=command):
    require(isinstance(identity, str) and re.fullmatch(r"[0-9a-fA-F]{40}", identity) is not None,
            "Exact public certificate SHA1 is required for fixed-leaf verification")
    signer = identity.upper()
    run(["/usr/bin/codesign", "--verify", "--strict", str(path)])
    metadata = run(["/usr/bin/codesign", "--display", "--requirements", "-", "--verbose=2", str(path)])
    identifiers = re.findall(r"^Identifier=(.+)$", metadata, re.MULTILINE)
    designated = re.findall(r"^(?:# )?designated => (.+)$", metadata, re.MULTILINE)
    require(identifiers == [IDENTIFIERS[kind]] and len(designated) == 1,
            "Expected one fixed signing identifier and designated requirement")
    requirement = designated[0]
    require(re.fullmatch(r'identifier "' + re.escape(IDENTIFIERS[kind])
                         + r'" and certificate leaf = H"' + signer + r'"',
                         requirement, re.IGNORECASE) is not None,
            "Requirement must bind only the fixed identifier and supplied certificate")
    return requirement


def validate_reuse_cli(source, digest, size, receipt, receipt_hash, receipt_size, approved_input):
    _, data = owned_bytes(receipt, receipt_hash, receipt_size, 65536)
    record = json.loads(data, object_pairs_hook=unique_object)
    require(type(record) is dict and type(approved_input) is dict, "Expected prior package and sealed-input approval")
    signed = {"sha256": hex_value(digest, 64), "bytes": positive(size)}
    expected = {"schemaVersion": 1, "producerCommit": PRODUCER, "producerTree": PRODUCER_TREE,
                "profile": PROFILE, "features": FEATURES}
    for key in ("externalUnsignedCLI", "externalProvenance"):
        identity = approved_input.get(key)
        require(type(identity) is dict and set(identity) == {"sha256", "bytes"},
                "Missing verified sealed-input identity")
        expected[key] = {"sha256": hex_value(identity["sha256"], 64), "bytes": positive(identity["bytes"])}
    for key, value in expected.items():
        # Canonical JSON equality also separates booleans/floats from exact integer fields.
        require(json.dumps(approved_input.get(key), sort_keys=True) == json.dumps(value, sort_keys=True)
                and json.dumps(record.get(key), sort_keys=True) == json.dumps(value, sort_keys=True),
                "Prior package differs from the required producer or approved sealed inputs: " + key)
    inventory = record.get("finalPackageFiles")
    require(type(inventory) is dict
            and record.get("signedBundledCLI") == signed
            and inventory.get("Contents/Resources/XodusEngine/xodus-cli") == signed
            and type(record["signedBundledCLI"].get("bytes")) is int
            and type(inventory["Contents/Resources/XodusEngine/xodus-cli"].get("bytes")) is int,
            "Prior final package does not approve this exact signed CLI")
    owned_bytes(source, digest, size)


def reuse_cli(source, destination, digest, size, receipt, receipt_hash, receipt_size, approved_input,
              run=command, identity=None):
    validate_reuse_cli(source, digest, size, receipt, receipt_hash, receipt_size, approved_input)
    require(not Path(destination).exists() and not Path(destination).is_symlink(), "CLI reuse destination must be new")
    if identity is not None:
        verify_designated_requirement(source, "cli", identity, run)
    else:
        run(["/usr/bin/codesign", "--verify", "--strict", str(source)])
    shutil.copyfile(source, destination)
    Path(destination).chmod(0o755)
    validate_reuse_cli(source, digest, size, receipt, receipt_hash, receipt_size, approved_input)
    owned_bytes(destination, digest, size)
    if identity is not None:
        verify_designated_requirement(destination, "cli", identity, run)
    else:
        run(["/usr/bin/codesign", "--verify", "--strict", str(destination)])
    owned_bytes(destination, digest, size)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    operations = parser.add_subparsers(dest="operation", required=True)
    for name in ("preflight", "sign", "compare", "verify"):
        operation = operations.add_parser(name)
        operation.add_argument("--identity")
        if name in ("preflight", "sign"):
            operation.add_argument("--local-ad-hoc", action="store_true")
        if name != "preflight":
            operation.add_argument("--kind", choices=IDENTIFIERS, required=True)
        if name in ("sign", "verify"):
            operation.add_argument("--path", required=True)
        if name == "compare":
            operation.add_argument("--first", required=True)
            operation.add_argument("--second", required=True)
    reuse = operations.add_parser("reuse-cli")
    reuse.add_argument("--identity")
    reuse.add_argument("--local-ad-hoc", action="store_true")
    for name in ("source", "destination", "hash", "prior-receipt", "receipt-hash",
                 "engine", "engine-hash", "proof-hash"):
        reuse.add_argument("--" + name, required=True)
    for name in ("bytes", "receipt-bytes", "engine-bytes", "proof-bytes"):
        reuse.add_argument("--" + name, type=int, required=True)
    args = parser.parse_args()
    require(sys.platform == "darwin", "Actual signing and reuse require an approved macOS stage")
    if args.operation == "preflight":
        preflight(args.identity, args.local_ad_hoc)
    elif args.operation == "sign":
        sign(args.path, args.kind, args.identity, args.local_ad_hoc)
    elif args.operation == "compare":
        print(compare(args.first, args.second, args.kind, args.identity))
    elif args.operation == "verify":
        verify_designated_requirement(args.path, args.kind, args.identity)
    else:
        require(not (args.identity and args.local_ad_hoc), "CLI reuse cannot select both signing modes")
        approval = verify_input(args.engine, args.engine_hash, args.engine_bytes, args.proof_hash, args.proof_bytes)
        reuse_cli(args.source, args.destination, args.hash, args.bytes,
                  args.prior_receipt, args.receipt_hash, args.receipt_bytes, approval, identity=args.identity)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit("Signing policy rejected: " + str(error))
