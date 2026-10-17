#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Neutral policy checks; no certificate, private key, Keychain or actual signing operation."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
from shipping_pair import FEATURES, PROFILE, PRODUCER, PRODUCER_TREE
from signing_identity import (COMPARISON_RESULT, IDENTIFIERS, compare, preflight, reuse_cli, sign,
                              verify_designated_requirement)

fingerprint = "A" * 40
calls = []


def neutral(arguments):
    calls.append(arguments)
    if arguments[0] == "/usr/bin/security":
        return '  1) ' + fingerprint + ' "Neutral test identity"\n     1 valid identities found\n'
    return ""


def rejected(operation):
    try:
        operation()
    except (ValueError, OSError):
        return
    raise AssertionError("Unsafe signing policy was accepted")


for identity in (None, "", "-", "Certificate name", "A" * 39, "A" * 41):
    calls.clear()
    rejected(lambda: preflight(identity, run=neutral))
    assert not calls
rejected(lambda: preflight(fingerprint, True, neutral))
assert preflight(local_ad_hoc=True, run=neutral) == "-"
rejected(lambda: preflight(fingerprint, run=lambda _: "0 valid identities found\n"))
assert preflight(fingerprint.lower(), run=neutral) == fingerprint
untrusted_matching = (
    'Matching identities\n  1) ' + fingerprint + ' "Neutral local identity" (CSSMERR_TP_NOT_TRUSTED)\n'
    '     1 identities found\n\nValid identities only\n     0 valid identities found\n')
assert preflight(fingerprint, run=lambda arguments: (
    untrusted_matching if arguments == ["/usr/bin/security", "find-identity", "-p", "codesigning"] else ""
)) == fingerprint
for wrong in ("B" * 40,):
    rejected(lambda: preflight(wrong, run=lambda _: untrusted_matching))
for failure in ("CSSMERR_TP_CERT_EXPIRED", "CSSMERR_TP_INVALID_EXTENDED_KEY_USAGE"):
    rejected(lambda failure=failure: preflight(fingerprint, run=lambda _:
             untrusted_matching.replace("CSSMERR_TP_NOT_TRUSTED", failure)))
for kind, identifier in IDENTIFIERS.items():
    calls.clear()
    sign("/neutral/new-build", kind, fingerprint, run=neutral)
    signing = calls[1]
    assert signing[signing.index("--sign") + 1] == fingerprint
    assert signing[signing.index("--identifier") + 1] == identifier
    assert signing[signing.index("--requirements") + 1] == (
        '=designated => identifier "' + identifier + '" and certificate leaf = H"' + fingerprint + '"')
    assert calls[-1][1:4] == ["--verify", "--strict", "/neutral/new-build"]
calls.clear()
sign("/neutral/local-only", "app", local_ad_hoc=True, run=neutral)
assert all(call[0] != "/usr/bin/security" for call in calls)
assert calls[0][calls[0].index("--sign") + 1] == "-"

with tempfile.TemporaryDirectory(prefix="xodus-signing-neutral-") as temporary:
    first, second = Path(temporary).resolve() / "first", Path(temporary).resolve() / "second"
    first.write_bytes(b"Same neutral payload; simulated signature A. Never executed.")
    second.write_bytes(b"Same neutral payload; simulated signature B. Never executed.")
    identifier = IDENTIFIERS["cli"]
    requirement = 'identifier "' + identifier + '" and certificate leaf = H"' + fingerprint + '"'
    def metadata(arguments):
        if arguments[0] == "/usr/bin/security":
            return neutral(arguments)
        if "--display" in arguments:
            return "Identifier=" + identifier + "\ndesignated => " + requirement + "\n"
        return ""
    assert compare(first, second, "cli", fingerprint, metadata) == COMPARISON_RESULT
    assert verify_designated_requirement(first, "cli", fingerprint, metadata) == requirement
    assert "Independent-build qualification" in COMPARISON_RESULT
    assert "not established by this comparison" in COMPARISON_RESULT
    assert compare(first, second, "cli", fingerprint, lambda arguments:
                   metadata(arguments).replace("\ndesignated =>", "\n# designated =>")) == COMPARISON_RESULT
    for bad in ('identifier "wrong" and certificate leaf = H"' + fingerprint + '"',
                requirement + ' and cdhash H"' + "B" * 40 + '"',
                requirement.replace(fingerprint, "B" * 40)):
        def altered(arguments, bad=bad):
            return ("Identifier=" + identifier + "\ndesignated => " + bad + "\n"
                    if "--display" in arguments else metadata(arguments))
        rejected(lambda: compare(first, second, "cli", fingerprint, altered))
        rejected(lambda: verify_designated_requirement(first, "cli", fingerprint, altered))
    rejected(lambda: verify_designated_requirement(first, "cli", fingerprint, lambda arguments:
             metadata(arguments).replace("Identifier=" + identifier, "Identifier=wrong")))
    second.write_bytes(first.read_bytes())
    rejected(lambda: compare(first, second, "cli", fingerprint, metadata))

    signed_data = first.read_bytes()
    signed = {"sha256": hashlib.sha256(signed_data).hexdigest(), "bytes": len(signed_data)}
    approval = {"schemaVersion": 1, "producerCommit": PRODUCER, "producerTree": PRODUCER_TREE,
                "externalUnsignedCLI": {"sha256": "b" * 64, "bytes": 100},
                "externalProvenance": {"sha256": "c" * 64, "bytes": 200},
                "profile": PROFILE, "features": FEATURES}
    base_receipt = {**approval, "signedBundledCLI": signed,
                    "finalPackageFiles": {"Contents/Resources/XodusEngine/xodus-cli": signed}}
    receipt = Path(temporary).resolve() / "prior-package-receipt.json"
    destination = Path(temporary).resolve() / "new-copy"

    def attempt(payload, digest=None, size=None, source_hash=signed["sha256"], source_size=signed["bytes"],
                approved=approval, receipt_path=receipt, identity=None, command_run=neutral):
        encoded = json.dumps(payload, sort_keys=True).encode() if isinstance(payload, dict) else payload
        receipt.write_bytes(encoded)
        receipt.chmod(0o600)
        calls.clear()
        reuse_cli(first, destination, source_hash, source_size, receipt_path,
                  digest or hashlib.sha256(encoded).hexdigest(), size or len(encoded), approved,
                  run=command_run, identity=identity)

    negatives = []
    for key, value in [
        ("schemaVersion", True), ("schemaVersion", 1.0), ("producerCommit", "0" * 40),
        ("producerTree", "0" * 40), ("externalUnsignedCLI", {"sha256": "d" * 64, "bytes": 100}),
        ("externalProvenance", {"sha256": "e" * 64, "bytes": 200}),
        ("externalUnsignedCLI", {"sha256": "b" * 64, "bytes": 100.0}),
        ("profile", {**PROFILE, "debug_assertions": 0}),
        ("features", {**FEATURES, "xodus-cli": ["plaintext"]}),
        ("signedBundledCLI", {"sha256": "f" * 64, "bytes": signed["bytes"]}),
        ("signedBundledCLI", {**signed, "bytes": float(signed["bytes"])}),
        ("signedBundledCLI", {**signed, "bytes": signed["bytes"] + 1}),
        ("finalPackageFiles", {}),
        ("finalPackageFiles", {"Contents/Resources/XodusEngine/xodus-cli":
                              {"sha256": "f" * 64, "bytes": signed["bytes"]}}),
        ("finalPackageFiles", {"Contents/Resources/XodusEngine/xodus-cli":
                              {**signed, "bytes": float(signed["bytes"])}}),
    ]:
        payload = copy.deepcopy(base_receipt)
        payload[key] = value
        negatives.append(payload)
    missing = copy.deepcopy(base_receipt)
    del missing["externalProvenance"]
    negatives += [missing, b'{"schemaVersion":1,"schemaVersion":1}', b'{"unfinished"', b"[]", b"x" * 65537]
    for payload in negatives:
        rejected(lambda payload=payload: attempt(payload))
        assert not destination.exists() and not calls
    for options in [
        {"digest": "0" * 64}, {"size": 1}, {"size": True}, {"source_hash": "0" * 64},
        {"source_size": signed["bytes"] + 1},
        {"approved": {**approval, "producerCommit": "0" * 40}},
        {"approved": {**approval, "producerTree": "0" * 40}},
        {"approved": {**approval, "externalUnsignedCLI": {"sha256": "f" * 64, "bytes": 100}}},
        {"approved": {**approval, "externalProvenance": {"sha256": "f" * 64, "bytes": 200}}},
        {"approved": {**approval, "externalProvenance": None}},
        {"receipt_path": Path(temporary).resolve() / "missing-receipt"},
    ]:
        rejected(lambda options=options: attempt(base_receipt, **options))
        assert not destination.exists() and not calls
    attempt(base_receipt)
    assert destination.read_bytes() == signed_data and first.read_bytes() == signed_data
    assert len(calls) == 2 and all(call[:3] == ["/usr/bin/codesign", "--verify", "--strict"] for call in calls)
    rejected(lambda: attempt(base_receipt))
    assert not calls
    destination.unlink()
    for bad in (requirement.replace(fingerprint, "B" * 40),
                requirement.replace(identifier, "wrong"),
                requirement + ' and cdhash H"' + "B" * 40 + '"'):
        def cross_identity(arguments, bad=bad):
            return ("Identifier=" + identifier + "\ndesignated => " + bad + "\n"
                    if "--display" in arguments else metadata(arguments))
        rejected(lambda: attempt(base_receipt, identity=fingerprint, command_run=cross_identity))
        assert not destination.exists()
    attempt(base_receipt, identity=fingerprint, command_run=metadata)
    assert destination.read_bytes() == signed_data and first.read_bytes() == signed_data
    destination.unlink()

    def changed_receipt(arguments):
        calls.append(arguments)
        receipt.write_bytes(b"Changed after initial admission")
        return ""

    encoded = json.dumps(base_receipt, sort_keys=True).encode()
    receipt.write_bytes(encoded)
    calls.clear()
    rejected(lambda: reuse_cli(first, destination, signed["sha256"], signed["bytes"], receipt,
                              hashlib.sha256(encoded).hexdigest(), len(encoded), approval, run=changed_receipt))
    assert len(calls) == 1

assert all(call == ["/usr/bin/security", "find-identity", "-p", "codesigning"]
           for call in calls if call[0] == "/usr/bin/security")
print("PASS simulated matching/untrusted identity, fixed requirement and receipt-bound CLI reuse policy, "
      "including cross-producer/seal rejection. "
      "Neutral bytes and mocked OS commands only; no real signing, independent builds or persistence qualification.")
