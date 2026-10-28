#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Neutral policy checks; no certificate, private key, Keychain or actual signing operation."""
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from shipping_pair import FEATURES, PROFILE, PRODUCER, PRODUCER_TREE
from signing_identity import (COMPARISON_RESULT, IDENTIFIERS, compare, preflight, reuse_cli, sign,
                              PACKAGE_RECEIPT_LIMIT, package_receipt, verify_developer_id_bundle,
                              verify_developer_id_component, verify_designated_requirement)

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

calls.clear()
rejected(lambda: sign("/neutral/distribution", "cli", local_ad_hoc=True,
                      run=neutral, developer_id=True))
assert not calls
rejected(lambda: sign("/neutral/distribution", "cli", fingerprint,
                      run=neutral, developer_id=True))

def developer_identity(arguments):
    calls.append(arguments)
    if arguments[0] == "/usr/bin/security":
        return '  1) ' + fingerprint + ' "Developer ID Application: Neutral (TEAM)"\n'
    return ""

calls.clear()
sign("/neutral/distribution", "cli", fingerprint, run=developer_identity, developer_id=True)
signing = next(call for call in calls if "--sign" in call)
assert "--timestamp" in signing and "--timestamp=none" not in signing
assert signing[signing.index("--options") + 1] == "runtime"
assert calls[-1] == ["/usr/bin/codesign", "--verify", "--strict", "/neutral/distribution"]
rejected(lambda: sign("/neutral/distribution", "cli", fingerprint,
                      run=lambda arguments: developer_identity(arguments).replace(
                          "Developer ID Application:", "Apple Development:"),
                      developer_id=True))

with tempfile.TemporaryDirectory(prefix="ode-signing-neutral-") as temporary:
    signed_metadata = (
        "Identifier=neutral.component\n"
        "Format=Mach-O thin (arm64)\n"
        "CodeDirectory v=20500 size=123 flags=0x10000(runtime) hashes=1+2 location=embedded\n"
        "CDHash=0123456789abcdef0123456789abcdef01234567\n"
        "TeamIdentifier=M62Z4M5EUY\n"
        "Timestamp=Oct 25, 2026 at 12:00:00 PM\n"
        "Authority=Developer ID Application: Neutral (M62Z4M5EUY)\n"
        "Authority=Developer ID Certification Authority\n"
        "Authority=Apple Root CA\n"
    )

    neutral_certificate = b"Neutral public certificate"
    component_identity = hashlib.sha1(neutral_certificate).hexdigest().upper()

    def signed_component_command(metadata=signed_metadata):
        def invoke(arguments):
            extract_option = next((argument for argument in arguments
                                   if argument.startswith("--extract-certificates=")), None)
            if arguments[0] == "/usr/bin/codesign" and extract_option:
                assert "--display" in arguments
                prefix = Path(extract_option.split("=", 1)[1])
                Path(str(prefix) + "0").write_bytes(neutral_certificate)
                return ""
            if arguments[0] == "/usr/bin/codesign" and "--display" in arguments:
                return metadata
            return ""
        return invoke

    neutral_code = Path(temporary).resolve() / "neutral-code"
    neutral_code.write_bytes(b"Neutral signed Mach-O test fixture")
    assert verify_developer_id_component(
        neutral_code, component_identity, run=signed_component_command())["hardenedRuntime"]
    assert verify_developer_id_component(
        neutral_code, component_identity, run=signed_component_command())["cdhash"] == \
        "0123456789abcdef0123456789abcdef01234567"
    no_runtime = signed_metadata.replace("flags=0x10000(runtime)", "flags=0x0")
    assert verify_developer_id_component(
        neutral_code, component_identity, run=signed_component_command(metadata=no_runtime),
        hardened_runtime=False)["secureTimestamp"]
    rejected(lambda: verify_developer_id_component(
        neutral_code, "B" * 40, run=signed_component_command()))
    rejected(lambda: verify_developer_id_component(
        neutral_code, component_identity, run=signed_component_command(metadata=signed_metadata.replace(
            "Timestamp=Oct 25, 2026 at 12:00:00 PM", "Timestamp=none"))))
    rejected(lambda: verify_developer_id_component(
        neutral_code, component_identity, run=signed_component_command(metadata=signed_metadata.replace(
            "flags=0x10000(runtime)", "flags=0x0"))))
    rejected(lambda: verify_developer_id_component(
        neutral_code, component_identity, run=signed_component_command(metadata=signed_metadata.replace(
            "CDHash=0123456789abcdef0123456789abcdef01234567\n", ""))))
    rejected(lambda: verify_developer_id_component(
        neutral_code, component_identity, run=signed_component_command(metadata=signed_metadata.replace(
            "CDHash=0123456789abcdef0123456789abcdef01234567",
            "CDHash=invalid"))))

    app = Path(temporary).resolve() / "Neutral.app"
    for relative in ("Contents/MacOS/Ode", "Contents/MacOS/OdeAuthHost",
                     "Contents/Resources/OdeEngine/ode-cli"):
        target = app / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b"\xcf\xfa\xed\xfe" + b"Neutral signed Mach-O test fixture")
    signature_inventory = verify_developer_id_bundle(
        app, component_identity, run=signed_component_command())
    assert signature_inventory["app"]["cdhash"] == \
        "0123456789abcdef0123456789abcdef01234567"
    assert {"app", "Contents/MacOS/Ode", "Contents/MacOS/OdeAuthHost",
            "Contents/Resources/OdeEngine/ode-cli"} == set(signature_inventory)
    (app / "Contents/Resources/Linked").symlink_to("missing")
    rejected(lambda: verify_developer_id_bundle(app, component_identity, run=signed_component_command()))

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
                    "finalPackageFiles": {"Contents/Resources/OdeEngine/ode-cli": signed}}
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
        ("features", {**FEATURES, "ode-cli": ["plaintext"]}),
        ("signedBundledCLI", {"sha256": "f" * 64, "bytes": signed["bytes"]}),
        ("signedBundledCLI", {**signed, "bytes": float(signed["bytes"])}),
        ("signedBundledCLI", {**signed, "bytes": signed["bytes"] + 1}),
        ("finalPackageFiles", {}),
        ("finalPackageFiles", {"Contents/Resources/OdeEngine/ode-cli":
                              {"sha256": "f" * 64, "bytes": signed["bytes"]}}),
        ("finalPackageFiles", {"Contents/Resources/OdeEngine/ode-cli":
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

    runtime_receipt = copy.deepcopy(base_receipt)
    runtime_receipt["finalPackageFiles"].update({
        f"Contents/Resources/OdePython/lib/neutral-{index}.py":
            {"sha256": "d" * 64, "bytes": 12} for index in range(2000)})
    encoded = json.dumps(runtime_receipt, sort_keys=True).encode()
    assert 65536 < len(encoded) < PACKAGE_RECEIPT_LIMIT
    attempt(runtime_receipt)
    assert destination.read_bytes() == signed_data and all("--sign" not in call for call in calls)
    assert package_receipt(receipt, hashlib.sha256(encoded).hexdigest(), len(encoded))[1] == encoded
    build_script = Path(__file__).with_name("build_app.sh").read_text()
    repin_marker = '        "$prior_receipt" "$prior_receipt_hash" "$prior_receipt_bytes" <<\'PY\'\n'
    assert build_script.count(repin_marker) == 1
    repin_script = build_script.split(repin_marker, 1)[1].split("\nPY\n", 1)[0]
    repin_arguments = [
        sys.executable, "-E", "-B", "-", str(first), str(destination), signed["sha256"],
        str(signed["bytes"]), str(receipt), hashlib.sha256(encoded).hexdigest(), str(len(encoded))]
    repin = subprocess.run(repin_arguments, input=repin_script, text=True, capture_output=True,
                           cwd=Path(__file__).resolve().parent.parent, timeout=10)
    assert repin.returncode == 0, repin.stderr
    receipt.write_bytes(encoded + b"\n")
    rejected(lambda: package_receipt(receipt, hashlib.sha256(encoded).hexdigest(), len(encoded)))
    repin = subprocess.run(repin_arguments, input=repin_script, text=True, capture_output=True,
                           cwd=Path(__file__).resolve().parent.parent, timeout=10)
    assert repin.returncode != 0
    destination.unlink()
    oversized = {**base_receipt, "padding": "x" * PACKAGE_RECEIPT_LIMIT}
    rejected(lambda: attempt(oversized))
    assert not destination.exists() and not calls

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
