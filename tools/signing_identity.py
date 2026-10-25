#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Explicit local signing policy; never provision, unlock or export a Keychain identity."""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from shipping_pair import (FEATURES, PROFILE, PRODUCER, PRODUCER_TREE, hex_value,
                           owned_bytes, positive, require, unique_object, verify_input)

IDENTIFIERS = {"app": "io.github.dragoshont.xodus",
               "cli": "io.github.dragoshont.xodus.cli",
               "helper": "io.github.dragoshont.xodus.auth-host",
               "broker": "io.github.dragoshont.xodus.credential-broker"}
COMPARISON_RESULT = (
    "Different signed artifacts share the fixed certificate-bound designated requirement. "
    "Independent-build qualification requires distinct compilations and live access checks; "
    "it is not established by this comparison.")
PACKAGE_RECEIPT_LIMIT = 4 * 1024 * 1024


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


def sign(path, kind, identity=None, local_ad_hoc=False, run=command, developer_id=False):
    require(not developer_id or (identity and not local_ad_hoc),
            "Developer ID signing requires an explicit certificate; ad-hoc is not distribution signing")
    signer = preflight(identity, local_ad_hoc, run)
    if developer_id:
        available = run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"])
        require(re.search(r'^\s*\d+\)\s+' + signer
                          + r'\s+"Developer ID Application: [^"\n]+"\s*$',
                          available, re.MULTILINE) is not None,
                "Distribution signing requires a valid Developer ID Application identity")
    arguments = ["/usr/bin/codesign", "--force", "--sign", signer,
                 "--identifier", IDENTIFIERS[kind]]
    arguments += ["--timestamp", "--options", "runtime"] if developer_id else ["--timestamp=none"]
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


MACH_O_MAGICS = {
    b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}


def _certificate_fingerprints(path, run):
    with tempfile.TemporaryDirectory(prefix="xodus-certs-") as directory:
        prefix = Path(directory).resolve(strict=True) / "certificate"
        run(["/usr/bin/codesign", "--display",
             "--extract-certificates=" + str(prefix), str(path)])
        certificates = sorted(prefix.parent.glob(prefix.name + "[0-9]*"))
        require(certificates and certificates[0].name == prefix.name + "0",
                "Signed component has no extractable leaf certificate")
        result = []
        for certificate in certificates:
            _, data = owned_bytes(certificate, bounded=1_048_576)
            result.append(hashlib.sha1(data, usedforsecurity=False).hexdigest().upper())
        return result


def verify_developer_id_component(path, identity, team_id="M62Z4M5EUY", run=command,
                                  hardened_runtime=True):
    require(re.fullmatch(r"[0-9a-fA-F]{40}", identity or "") is not None,
            "Exact Developer ID certificate SHA1 is required")
    path = Path(path)
    require(not path.is_symlink() and (path.is_file() or path.is_dir()),
            "Expected a regular signed code component")
    run(["/usr/bin/codesign", "--verify", "--strict", "--verbose=2", str(path)])
    metadata = run(["/usr/bin/codesign", "--display", "--verbose=4", str(path)])
    identifiers = re.findall(r"^Identifier=(.+)$", metadata, re.MULTILINE)
    teams = re.findall(r"^TeamIdentifier=(.+)$", metadata, re.MULTILINE)
    authorities = re.findall(r"^Authority=(.+)$", metadata, re.MULTILINE)
    timestamps = re.findall(r"^Timestamp=(.+)$", metadata, re.MULTILINE)
    runtime_flags = re.findall(r"^.*\bflags=.*\bruntime\b.*$", metadata, re.MULTILINE)
    require(len(identifiers) == len(teams) == len(timestamps) == 1 and authorities,
            "Developer ID signature metadata is incomplete")
    require(teams[0] == team_id and authorities[0].startswith("Developer ID Application: "),
            "Component is not signed by the required Developer ID team")
    require(timestamps[0].strip().lower() != "none", "Component has no secure signing timestamp")
    require(not hardened_runtime or bool(runtime_flags),
            "Component is not signed with the hardened runtime")
    fingerprints = _certificate_fingerprints(path, run)
    require(fingerprints[0] == identity.upper(),
            "Component certificate leaf differs from the approved Developer ID identity")
    return {
        "identifier": identifiers[0],
        "teamIdentifier": teams[0],
        "authority": authorities[0],
        "certificateSha1": fingerprints[0],
        "hardenedRuntime": bool(runtime_flags),
        "secureTimestamp": True,
    }


def verify_developer_id_bundle(app, identity, team_id="M62Z4M5EUY", run=command):
    app = Path(app)
    require(app.is_dir() and app.suffix == ".app" and not app.is_symlink(),
            "Expected a regular app bundle")
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    required = {
        "Contents/MacOS/Xodus",
        "Contents/MacOS/XodusAuthHost",
        "Contents/Resources/XodusEngine/xodus-cli",
    }
    mach_o = []
    for path in app.rglob("*"):
        require(not path.is_symlink(), "Linked path in signed app bundle")
        if not path.is_file():
            continue
        with path.open("rb") as source:
            magic = source.read(4)
        if magic in MACH_O_MAGICS:
            mach_o.append(path)
    relative_paths = {path.relative_to(app).as_posix() for path in mach_o}
    require(required <= relative_paths,
            "Signed app is missing a required native code component")
    components = {"app": verify_developer_id_component(
        app, identity, team_id, run, hardened_runtime=True)}
    for path in sorted(mach_o):
        relative = path.relative_to(app).as_posix()
        components[relative] = verify_developer_id_component(path, identity, team_id, run)
    return components


def package_receipt(path, digest, size):
    return owned_bytes(path, digest, size, PACKAGE_RECEIPT_LIMIT)


def validate_reuse_cli(source, digest, size, receipt, receipt_hash, receipt_size, approved_input):
    _, data = package_receipt(receipt, receipt_hash, receipt_size)
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
        if name == "sign":
            operation.add_argument("--developer-id", action="store_true",
                                   help="Require valid Developer ID Application signing, timestamp and hardened runtime")
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
        sign(args.path, args.kind, args.identity, args.local_ad_hoc, developer_id=args.developer_id)
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
