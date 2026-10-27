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
from shipping_pair import (CARGO_LOCK_SHA256, CLI_BYTES, CLI_SHA256, COMMAND, FEATURES, PROFILE,
                           PRODUCER, PRODUCER_MANIFEST_SHA256, PRODUCER_TREE, SOURCE_ARCHIVE_BYTES,
                           SOURCE_ARCHIVE_NAME, SOURCE_ARCHIVE_SHA256, WINDOWS_HELPER_BYTES,
                           WINDOWS_HELPER_SHA256, require,
                           main as generate_pair, swift_pins, swift_producer_pins,
                           validate_producer_inventory, verify_input)
from verify_shipping_package import main as verify_package
from launch_association_capsule import BROKER_SHA256, stage_capsule, verify_capsule
from python_runtime import approved_pin, inventory
from package_resources import RUNTIME_RESOURCES
from package_beta import PRODUCER_NOTICES_SHA256

SUPERSEDED_PRODUCERS = (
    "01d4" + "cfd6" + "25764c2a8ec4d60824ef4f277b30b9e9",
    "99e20" + "addf88932de7796fc966fe09e00b71e4981",
)


def require_current_producer_pins(source_root):
    for directory in ("Sources", "tools"):
        for path in (source_root / directory).rglob("*"):
            if path.is_file() and not path.is_symlink() and path.suffix in {
                    ".swift", ".py", ".json", ".plist"}:
                data = path.read_bytes()
                if any(producer.encode() in data or producer[:8].encode() in data
                       for producer in SUPERSEDED_PRODUCERS):
                    raise ValueError("Superseded producer pin found in " + str(path.relative_to(source_root)))


def require_app_shipping_pins(source_root):
    producer_pins = (source_root / "Sources/XodusPreview/ShippingProducerPins.swift").read_text(
        encoding="utf-8")
    require(f'static let commit = "{PRODUCER}"' in producer_pins
            and f'static let tree = "{PRODUCER_TREE}"' in producer_pins,
            "App producer commit/tree differs from the approved shipping pair")

    lifecycle = (source_root / "Sources/XodusPreview/NativeGameLifecycle.swift").read_text(encoding="utf-8")
    require(f'static let cliSHA256 = "{CLI_SHA256}"' in lifecycle,
            "Lifecycle CLI digest differs from the approved shipping pair")

    runtime_path = source_root / "Sources/XodusManagement/Resources/LaunchRecipes/title-runtime-v1.json"
    runtime_bytes = runtime_path.read_bytes()
    runtime = json.loads(runtime_bytes)
    require(runtime.get("cliSha256") == CLI_SHA256,
            "Runtime catalogue CLI digest differs from the approved shipping pair")
    runtime_hash = hashlib.sha256(runtime_bytes).hexdigest()
    launch_configuration = (source_root / "Sources/XodusPreview/NativeLaunchConfiguration.swift").read_text(
        encoding="utf-8")
    require(f'== "{runtime_hash}" else' in launch_configuration,
            "Runtime catalogue file digest is not pinned in the app")

    acknowledgments = (source_root / "Sources/XodusPreview/Acknowledgments.swift").read_text(encoding="utf-8")
    require(f'pinnedProducerInventorySHA256 = "{PRODUCER_NOTICES_SHA256}"' in acknowledgments,
            "App producer-notice inventory digest differs from the packaging pin")


count = 0
project = Path(__file__).resolve().parent.parent
require_current_producer_pins(project)
require_app_shipping_pins(project)
count += 1
with tempfile.TemporaryDirectory(prefix="xodus-pair-portable-") as temporary:
    root = Path(temporary).resolve()
    stale_source = root / "stale-source"
    stale_pin = stale_source / "Sources/XodusPreview/ShippingProducerPins.swift"
    stale_pin.parent.mkdir(parents=True)
    for producer in SUPERSEDED_PRODUCERS:
        stale_pin.write_text("static let commit = \"" + producer + "\"", encoding="utf-8")
        try:
            require_current_producer_pins(stale_source)
            raise AssertionError("Superseded producer source pin accepted")
        except ValueError:
            count += 1
        stale_pin.write_text("static let commit = \"" + producer[:8] + "\"", encoding="utf-8")
        try:
            require_current_producer_pins(stale_source)
            raise AssertionError("Superseded producer prefix accepted")
        except ValueError:
            count += 1
    for relative in (
            "Sources/XodusPreview/ShippingProducerPins.swift",
            "Sources/XodusPreview/NativeGameLifecycle.swift",
            "Sources/XodusPreview/Acknowledgments.swift",
            "Sources/XodusPreview/NativeLaunchConfiguration.swift",
            "Sources/XodusManagement/Resources/LaunchRecipes/title-runtime-v1.json"):
        destination = stale_source / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(project / relative, destination)
    stale_app_pin = stale_source / "Sources/XodusPreview/ShippingProducerPins.swift"
    stale_app_pin.write_text(
        "enum ShippingProducerPins { static let commit = \"" + SUPERSEDED_PRODUCERS[1] + "\" }",
        encoding="utf-8")
    try:
        require_app_shipping_pins(stale_source)
        raise AssertionError("Mismatched app producer source pin accepted")
    except ValueError:
        count += 1
    shutil.copy2(project / "Sources/XodusPreview/ShippingProducerPins.swift", stale_app_pin)
    stale_runtime = stale_source / "Sources/XodusManagement/Resources/LaunchRecipes/title-runtime-v1.json"
    runtime_data = json.loads(stale_runtime.read_text(encoding="utf-8"))
    runtime_data["cliSha256"] = "0" * 64
    stale_runtime.write_text(json.dumps(runtime_data), encoding="utf-8")
    try:
        require_app_shipping_pins(stale_source)
        raise AssertionError("Mismatched runtime catalogue CLI pin accepted")
    except ValueError:
        count += 1
    inventory_path = root / "inventory.json"
    producer_inventory = {
        "producer": {"commit": PRODUCER, "tree": PRODUCER_TREE},
        "cliSHA256": CLI_SHA256, "helperSHA256": WINDOWS_HELPER_SHA256,
        "producerManifestSHA256": PRODUCER_MANIFEST_SHA256,
        "cargoLockSHA256": CARGO_LOCK_SHA256,
        "sourceDelivery": {"sourceArchive": {
            "file": SOURCE_ARCHIVE_NAME,
            "sha256": SOURCE_ARCHIVE_SHA256, "bytes": SOURCE_ARCHIVE_BYTES,
            "producer": {"commit": PRODUCER, "tree": PRODUCER_TREE},
        }},
    }
    def write_inventory(value):
        inventory_path.write_text(json.dumps(value, sort_keys=True), encoding="utf-8")
        inventory_path.chmod(0o600)
        return hashlib.sha256(inventory_path.read_bytes()).hexdigest()

    validate_producer_inventory(inventory_path, write_inventory(producer_inventory))
    assert CLI_BYTES == 30_385_936 and WINDOWS_HELPER_BYTES == 22_016
    producer_pins = swift_producer_pins()
    assert PRODUCER in producer_pins and PRODUCER_TREE in producer_pins
    count += 1
    for field, value in (("cliSHA256", "0" * 64), ("helperSHA256", "0" * 64),
                         ("producerManifestSHA256", "0" * 64), ("cargoLockSHA256", "0" * 64)):
        malformed = copy.deepcopy(producer_inventory)
        malformed[field] = value
        try:
            validate_producer_inventory(inventory_path, write_inventory(malformed))
            raise AssertionError("Mismatched producer inventory pin accepted: " + field)
        except ValueError:
            count += 1
    for field, value in (("file", "wrong-source.tar"), ("sha256", "0" * 64),
                         ("bytes", SOURCE_ARCHIVE_BYTES + 1)):
        malformed = copy.deepcopy(producer_inventory)
        malformed["sourceDelivery"]["sourceArchive"][field] = value
        try:
            validate_producer_inventory(inventory_path, write_inventory(malformed))
            raise AssertionError("Mismatched source archive pin accepted: " + field)
        except ValueError:
            count += 1
    malformed = copy.deepcopy(producer_inventory)
    malformed["producer"]["tree"] = "0" * 40
    try:
        validate_producer_inventory(inventory_path, write_inventory(malformed))
        raise AssertionError("Wrong producer source accepted")
    except ValueError:
        count += 1
    malformed = copy.deepcopy(producer_inventory)
    malformed["sourceDelivery"]["sourceArchive"]["producer"]["commit"] = "0" * 40
    try:
        validate_producer_inventory(inventory_path, write_inventory(malformed))
        raise AssertionError("Wrong source archive producer accepted")
    except ValueError:
        count += 1
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
    local_pins = swift_pins("a" * 40, "b" * 40, {"sha256": "c" * 64, "bytes": 20},
                           {"sha256": "d" * 64, "bytes": 30}, "e" * 40, "f" * 40)
    assert 'producerCommit: "' + "e" * 40 in local_pins
    assert 'producerTree: "' + "f" * 40 in local_pins
    for producer, tree in (("not-a-commit", "f" * 40), ("e" * 40, "invalid-tree")):
        try:
            swift_pins("a" * 40, "b" * 40, {"sha256": "c" * 64, "bytes": 20},
                       {"sha256": "d" * 64, "bytes": 30}, producer, tree)
            raise AssertionError("Malformed local source pin accepted")
        except ValueError:
            count += 1
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
    shutil.copyfile(project / "tools/Info.plist", source / "tools/Info.plist")
    shutil.copyfile(project / "LICENSE", source / "LICENSE")
    (source / "NOTICE").write_text("Neutral notice fixture", encoding="utf-8")
    (source / "TRADEMARKS.md").write_text("Neutral trademark fixture", encoding="utf-8")
    shutil.copyfile(source / "tools/Info.plist", app / "Contents/Info.plist")
    shutil.copyfile(source / "LICENSE", resources / "LICENSE.txt")
    shutil.copyfile(source / "NOTICE", resources / "NOTICE.txt")
    shutil.copyfile(source / "TRADEMARKS.md", resources / "TRADEMARKS.md")
    neutral = struct.pack("<II", 0xFEEDFACF, 0x0100000C) + b"Never executed neutral package bytes."
    for target in (pair, helper, macos / "Xodus"):
        target.write_bytes(neutral)
        target.chmod(0o755)
    signed = {"sha256": hashlib.sha256(neutral).hexdigest(), "bytes": len(neutral)}
    generated = swift_pins("a" * 40, "b" * 40, signed, signed).encode()
    pin_source = source / "Sources/XodusPreview/ShippingPairPins.swift"
    pin_source.write_bytes(b"Archived nil approval; not generated yet.")
    (source / "Package.swift").write_bytes(b"Neutral archived source marker")
    schema_source = source / "Sources/XodusManagement/Resources"
    schema_source.mkdir(parents=True)
    for name in ("management-v1.schema.json", "runtime-providers-v1.schema.json"):
        shutil.copyfile(project / "Sources/XodusManagement/Resources" / name, schema_source / name)
    with tarfile.open(stage / "source.tar", "w") as archive:
        archive.add(source / "Package.swift", arcname="Package.swift")
        archive.add(pin_source, arcname="Sources/XodusPreview/ShippingPairPins.swift")
        for name in ("management-v1.schema.json", "runtime-providers-v1.schema.json"):
            archive.add(schema_source / name, arcname="Sources/XodusManagement/Resources/" + name)
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
    for name in RUNTIME_RESOURCES:
        (management / name).parent.mkdir(parents=True, exist_ok=True)
        if name in ("management-v1.schema.json", "runtime-providers-v1.schema.json"):
            shutil.copyfile(schema_source / name, management / name)
        else:
            (management / name).write_bytes(b"Neutral allowlisted resource fixture")
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
        (management / "management-v1.schema.json", b"Wrong packaged management schema"),
        (management / "runtime-providers-v1.schema.json", b"Wrong packaged runtime schema"),
        (schema_source / "management-v1.schema.json", b"Changed schema source after archive"),
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
    original_schema = (schema_source / "management-v1.schema.json").read_bytes()
    for target in (schema_source / "management-v1.schema.json", management / "management-v1.schema.json"):
        target.write_bytes(b"Matching but not archived schema bytes")
    try:
        package_check()
        raise AssertionError("Matching source/package schema changed after archive accepted")
    except ValueError:
        count += 1
    finally:
        for target in (schema_source / "management-v1.schema.json", management / "management-v1.schema.json"):
            target.write_bytes(original_schema)
    nested = management / "Contents/Resources"
    nested.mkdir(parents=True)
    for name in RUNTIME_RESOURCES:
        (nested / name).parent.mkdir(parents=True, exist_ok=True)
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
    capsule = root / "private-capsule"
    capsule.mkdir(mode=0o700)
    adapter = b"Neutral adapter bytes. Never executed.\n"
    peer = b"Neutral source library bytes. Never loaded.\n"
    manifest = {"version": 1, "enabled": False,
                "adapterSHA256": hashlib.sha256(adapter).hexdigest(),
                "peerSHA256": hashlib.sha256(peer).hexdigest(), "brokerSHA256": BROKER_SHA256}
    for name, data in [("adapter.py", adapter), ("peer.dylib", peer)]:
        (capsule / name).write_bytes(data)
        (capsule / name).chmod(0o600)
    manifest_path = capsule / "manifest.json"
    manifest_path.write_text(json.dumps(manifest))
    manifest_path.chmod(0o600)
    approved_capsule = verify_capsule(capsule)
    count += 1
    for key, value in [("version", 2), ("enabled", 1), ("brokerSHA256", "0" * 64),
                       ("adapterSHA256", "0" * 64), ("peerSHA256", "0" * 64)]:
        bad = {**manifest, key: value}
        manifest_path.write_text(json.dumps(bad))
        try:
            verify_capsule(capsule)
            raise AssertionError("Invalid private capsule accepted")
        except ValueError:
            count += 1
    manifest_path.write_text(json.dumps(manifest))
    extra = capsule / "unreviewed.py"
    extra.write_bytes(b"Never executed.")
    try:
        verify_capsule(capsule)
        raise AssertionError("Unreviewed adapter dependency accepted")
    except ValueError:
        count += 1
    extra.unlink()
    packaged_capsule = app / "Contents/Resources/LaunchAssociation"
    stage_capsule(capsule, packaged_capsule, stage / "paired-inputs.json")
    assert verify_capsule(packaged_capsule) == approved_capsule
    package_check()
    count += 1
    (stage / "package-receipt.json").unlink()
    (packaged_capsule / "adapter.py").write_bytes(b"Changed after staging.")
    try:
        package_check()
        raise AssertionError("Changed packaged private capsule accepted")
    except ValueError:
        count += 1
    (packaged_capsule / "adapter.py").write_bytes(adapter)
    packaged_manifest = packaged_capsule / "manifest.json"
    manifest["enabled"] = True
    packaged_manifest.write_text(json.dumps(manifest))
    paired = json.loads((stage / "paired-inputs.json").read_bytes())
    paired["privateLaunchAssociation"] = verify_capsule(packaged_capsule)
    (stage / "paired-inputs.json").write_text(json.dumps(paired))
    try:
        package_check()
        raise AssertionError("Enabled capsule accepted without a packaged interpreter")
    except ValueError:
        count += 1
    python_root = resources / "XodusPython"
    python_manifest = resources / "XodusPython.json"
    python_manifest.write_text("{}")
    try:
        package_check()
        raise AssertionError("Unstaged interpreter metadata accepted")
    except ValueError:
        count += 1
    (python_root / "bin").mkdir(parents=True)
    (python_root / "lib/python3.14").mkdir(parents=True)
    (python_root / "bin/python3").write_bytes(neutral)
    (python_root / "bin/python3").chmod(0o755)
    (python_root / "lib/python3.14/LICENSE.txt").write_bytes(b"Neutral license fixture; not an actual license.")
    (python_root / "lib/python3.14/empty.py").write_bytes(b"")
    pin = approved_pin()
    python_metadata = {"version": 1, "pythonVersion": pin["pythonVersion"], "archiveSHA256": pin["sha256"],
                       "files": inventory(python_root)}
    python_manifest.write_text(json.dumps(python_metadata))
    paired["privatePythonRuntime"] = python_metadata
    (stage / "paired-inputs.json").write_text(json.dumps(paired))
    package_check()
    count += 1
    (stage / "package-receipt.json").unlink()
    for path, bad_data in [
        (python_root / "bin/python3", b"Changed interpreter"),
        (python_root / "lib/python3.14/empty.py", b"Changed import"),
        (python_manifest, b'{"version":1}'),
    ]:
        original = path.read_bytes()
        path.write_bytes(bad_data)
        try:
            package_check()
            raise AssertionError("Changed interpreter package accepted")
        except (ValueError, KeyError):
            count += 1
        finally:
            path.write_bytes(original)
    del paired["privatePythonRuntime"]
    (stage / "paired-inputs.json").write_text(json.dumps(paired))
    try:
        package_check()
        raise AssertionError("Unstaged interpreter tree accepted")
    except ValueError:
        count += 1
print(f"{count} portable packaging admission checks, 0 failures. Neutral bytes only.")
