#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Portable negative/positive checks of the externally pinned packaging gate."""
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import sys
import tarfile
import tempfile
from shipping_pair import COMMAND, FEATURES, PROFILE, PRODUCER, PRODUCER_TREE, main as generate_pair, swift_pins, verify_input
from verify_shipping_package import main as verify_package

count = 0
with tempfile.TemporaryDirectory(prefix="xodus-pair-portable-") as temporary:
    root = Path(temporary).resolve()
    engine = root / "neutral-engine"
    proof = Path(str(engine) + ".provenance.json")
    data = b"Neutral packaging bytes. Never executed or represented as a real CLI."
    engine.write_bytes(data)
    engine.chmod(0o500)
    engine_hash = hashlib.sha256(data).hexdigest()
    base = {"version": 1, "sourceCommit": PRODUCER, "sourceTree": PRODUCER_TREE,
            "sealedArtifact": str(engine), "sealedSHA256": engine_hash, "sealedBytes": len(data),
            "sealedMode": "0500", "sealedUID": os.getuid() if os.name == "posix" else 0,
            "nativeResolvedFeatures": FEATURES, "postBuildNativeResolvedFeatures": FEATURES,
            "buildProfile": PROFILE, "command": COMMAND, "architecture": "arm64", "host": "arm64",
            "target": "aarch64-apple-darwin", "metadataPlatformFilter": "aarch64-apple-darwin",
            "appSigningPerformed": False, "signingState": "Rust/linker ad-hoc only; no separate app signing/DeveloperID identity",
            "cargoIncremental": 0, "cargoBuildJobs": 1}

    def admission(payload, expected_engine=engine_hash, expected_size=len(data), expected_proof=None):
        encoded = json.dumps(payload, sort_keys=True).encode() if isinstance(payload, dict) else payload
        proof.chmod(0o600) if proof.exists() else None
        proof.write_bytes(encoded)
        proof.chmod(0o400)
        return verify_input(str(engine), expected_engine, expected_size,
                            expected_proof or hashlib.sha256(encoded).hexdigest(), len(encoded))

    record = admission(base)
    assert record["externalUnsignedCLI"]["sha256"] == engine_hash
    count += 1
    bad = []
    for key, value in [("sourceCommit", "0" * 40), ("sourceTree", "0" * 40),
                       ("buildProfile", "release"), ("appSigningPerformed", True),
                       ("cargoIncremental", True), ("cargoBuildJobs", 2), ("command", ["cargo", "build"])]:
        item = copy.deepcopy(base)
        item[key] = value
        bad.append(item)
    for key in ("nativeResolvedFeatures", "postBuildNativeResolvedFeatures"):
        item = copy.deepcopy(base)
        item[key]["xodus"].append("plaintext")
        bad.append(item)
    item = copy.deepcopy(base)
    item["buildProfile"]["opt_level"] = "0"
    bad.append(item)
    item = copy.deepcopy(base)
    item["buildProfile"]["debug_assertions"] = 0
    bad.append(item)
    for item in bad:
        try:
            admission(item)
            raise AssertionError("Unreviewed provenance accepted")
        except ValueError:
            count += 1
    for kwargs in ({"expected_engine": "0" * 64}, {"expected_size": len(data) + 1},
                   {"expected_proof": "0" * 64}):
        try:
            admission(base, **kwargs)
            raise AssertionError("Wrong external pin accepted")
        except ValueError:
            count += 1
    try:
        admission(b'{"version":1,"version":1}')
        raise AssertionError("Duplicate provenance accepted")
    except ValueError:
        count += 1
    pins = swift_pins("a" * 40, "b" * 40, {"sha256": "c" * 64, "bytes": 20},
                      {"sha256": "d" * 64, "bytes": 30})
    assert 'engineSHA256: "' + "c" * 64 in pins and 'helperSHA256: "' + "d" * 64 in pins
    assert engine_hash not in pins and str(engine) not in pins
    count += 1
    stage = root / "neutral-stage"
    source = stage / "source"
    app = stage / "Xodus.app"
    resources = app / "Contents/Resources"
    macos = app / "Contents/MacOS"
    pair = resources / "XodusEngine/xodus-cli"
    helper = macos / "XodusAuthHost"
    for directory in (source / "Sources/XodusPreview", source / "tools", pair.parent, macos):
        directory.mkdir(parents=True, exist_ok=True)
    project = Path(__file__).resolve().parent.parent
    shutil.copyfile(project / "tools/Info.plist", source / "tools/Info.plist")
    shutil.copyfile(project / "LICENSE", source / "LICENSE")
    shutil.copyfile(source / "tools/Info.plist", app / "Contents/Info.plist")
    shutil.copyfile(source / "LICENSE", resources / "LICENSE.txt")
    neutral = struct.pack("<II", 0xFEEDFACF, 0x0100000C) + b"Never executed neutral package bytes."
    for target in (pair, helper, macos / "Xodus"):
        target.write_bytes(neutral)
        target.chmod(0o755)
    signed = {"sha256": hashlib.sha256(neutral).hexdigest(), "bytes": len(neutral)}
    generated = swift_pins("a" * 40, "b" * 40, signed, signed).encode()
    pin_source = source / "Sources/XodusPreview/ShippingPairPins.swift"
    pin_source.write_bytes(b"Archived nil approval; not generated yet.")
    (source / "Package.swift").write_bytes(b"Neutral archived source marker")
    with tarfile.open(stage / "source.tar", "w") as archive:
        archive.add(source / "Package.swift", arcname="Package.swift")
        archive.add(pin_source, arcname="Sources/XodusPreview/ShippingPairPins.swift")
    approval = stage / "neutral-approval.json"
    approval.write_text(json.dumps(record), encoding="utf-8")
    original_arguments, original_platform = sys.argv, sys.platform
    try:
        # Exercise the CLI generator with owned neutral bytes; never execute an engine.
        sys.platform = "darwin"
        sys.argv = ["neutral-generate", "generate", "--source", "a" * 40, "--tree", "b" * 40,
                    "--engine", str(pair), "--helper", str(helper), "--approval", str(approval),
                    "--output", str(pin_source), "--receipt", str(stage / "paired-inputs.json")]
        generate_pair()
    finally:
        sys.argv, sys.platform = original_arguments, original_platform
    assert pin_source.read_bytes() == generated and b"\r" not in pin_source.read_bytes()
    paired = json.loads((stage / "paired-inputs.json").read_bytes())
    assert paired["signedBundledCLI"] == signed and paired["signedHelper"] == signed
    assert paired["generatedPinsSHA256"] == hashlib.sha256(generated).hexdigest()
    count += 1
    receipt = resources / "XodusAuthHost.json"
    receipt.write_bytes((json.dumps({"version": 1, "sha256": signed["sha256"], "sourceCommit": "a" * 40},
                                   sort_keys=True) + "\n").encode())
    management = resources / "XodusAppFoundation_XodusManagement.bundle"
    management.mkdir()
    for name in ("management-v1.schema.json", "runtime-providers-v1.schema.json"):
        shutil.copyfile(project / "Sources/XodusManagement/Resources" / name, management / name)
    def package_check():
        original = sys.argv
        try:
            sys.argv = ["neutral-package-check", str(stage)]
            verify_package()
        finally:
            sys.argv = original

    package_check()
    final = json.loads((stage / "package-receipt.json").read_bytes())
    assert final["finalPackageFiles"][str(Path("Contents") / "MacOS" / "Xodus")] == signed
    assert "Sources/XodusPreview/ShippingPairPins.swift" in final["archivedSourceFilesIncludingGeneratedPins"]
    count += 1
    (stage / "package-receipt.json").unlink()
    for target, bad_data in [
        (source / "Package.swift", b"Changed compiler source after archive"),
        (macos / "Xodus", b"Wrong architecture"),
        (receipt, b'{"version":1}'),
        (app / "Contents/Info.plist", b"Changed deployment baseline"),
    ]:
        original = target.read_bytes()
        target.write_bytes(bad_data)
        try:
            package_check()
            raise AssertionError("Changed final package input accepted")
        except (ValueError, struct.error):
            count += 1
        finally:
            target.write_bytes(original)
    nested = management / "Contents/Resources"
    nested.mkdir(parents=True)
    for name in ("management-v1.schema.json", "runtime-providers-v1.schema.json"):
        (management / name).rename(nested / name)
    package_check()
    final = json.loads((stage / "package-receipt.json").read_bytes())
    assert str(Path("Contents/Resources") / management.name / "Contents/Resources/management-v1.schema.json") in final["finalPackageFiles"]
    count += 1
    (stage / "package-receipt.json").unlink()
    duplicate = management / "management-v1.schema.json"
    shutil.copyfile(nested / duplicate.name, duplicate)
    try:
        package_check()
        raise AssertionError("Duplicate resource layouts accepted")
    except ValueError:
        count += 1
    duplicate.unlink()
    runtime_schema = nested / "runtime-providers-v1.schema.json"
    runtime_schema.rename(management / runtime_schema.name)
    try:
        package_check()
        raise AssertionError("Mixed resource layouts accepted")
    except ValueError:
        count += 1
    (management / runtime_schema.name).rename(runtime_schema)
    native_schema = nested / "management-v1.schema.json"
    original = native_schema.read_bytes()
    native_schema.write_bytes(b"Wrong hash in native layout")
    try:
        package_check()
        raise AssertionError("Wrong native-layout resource hash accepted")
    except ValueError:
        count += 1
    finally:
        native_schema.write_bytes(original)
    runtime_bytes = runtime_schema.read_bytes()
    runtime_schema.unlink()
    try:
        package_check()
        raise AssertionError("Incomplete native resource layout accepted")
    except ValueError:
        count += 1
    finally:
        runtime_schema.write_bytes(runtime_bytes)
    if os.name == "posix":
        linked_source = root / "linked-neutral-schema.json"
        linked_source.write_bytes(original)
        native_schema.unlink()
        native_schema.symlink_to(linked_source)
        try:
            package_check()
            raise AssertionError("Linked native resource with a matching hash accepted")
        except ValueError:
            count += 1
        finally:
            native_schema.unlink()
            native_schema.write_bytes(original)
print(f"{count} portable packaging admission checks, 0 failures. Neutral bytes only.")
