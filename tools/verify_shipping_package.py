#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Verify the post-app-sign pair and preserve actual final package identities."""
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import sys
import tarfile
from shipping_pair import hex_value, owned_bytes, require, swift_pins, unique_object


def main():
    stage = Path(sys.argv[1])
    require(stage.is_absolute() and stage.resolve(strict=True) == stage, "Noncanonical package stage")
    app = stage / "Xodus.app"
    record = json.loads((stage / "paired-inputs.json").read_bytes(), object_pairs_hook=unique_object)
    source, tree = record["approvedAppSourceCommit"], record["approvedAppSourceTree"]
    hex_value(source, 40)
    hex_value(tree, 40)
    for key, relative in [
        ("signedBundledCLI", "Contents/Resources/XodusEngine/xodus-cli"),
        ("signedHelper", "Contents/MacOS/XodusAuthHost"),
    ]:
        path = app / relative
        expected = record[key]
        owned_bytes(path, expected["sha256"], expected["bytes"])
        with path.open("rb") as stream:
            require(struct.unpack("<II", stream.read(8)) == (0xFEEDFACF, 0x0100000C), "Expected arm64 Mach-O")
    launcher = app / "Contents/MacOS/Xodus"
    owned_bytes(launcher)
    with launcher.open("rb") as stream:
        require(struct.unpack("<II", stream.read(8)) == (0xFEEDFACF, 0x0100000C), "Expected arm64 launcher")
    expected_pins = swift_pins(source, tree, record["signedBundledCLI"], record["signedHelper"]).encode()
    pin_path = stage / "source/Sources/XodusPreview/ShippingPairPins.swift"
    require(pin_path.read_bytes() == expected_pins
            and hashlib.sha256(expected_pins).hexdigest() == record["generatedPinsSHA256"],
            "Generated compiler pins changed")
    metadata = app / "Contents/Resources/XodusAuthHost.json"
    expected_receipt = (json.dumps({"version": 1, "sha256": record["signedHelper"]["sha256"],
                                  "sourceCommit": source}, sort_keys=True) + "\n").encode()
    owned_bytes(metadata, hashlib.sha256(expected_receipt).hexdigest(), len(expected_receipt))
    if "frozenCredentialBroker" in record:
        broker = record["frozenCredentialBroker"]
        require(type(broker) is dict and set(broker) == {"version", "sha256", "bytes"}
                and type(broker["version"]) is int and broker["version"] == 1, "Invalid frozen broker pin")
        owned_bytes(stage / "CredentialBroker/XodusCredentialBroker", broker["sha256"], broker["bytes"])
        expected = (json.dumps(broker, sort_keys=True) + "\n").encode()
        owned_bytes(app / "Contents/Resources/XodusCredentialBroker.json",
                    hashlib.sha256(expected).hexdigest(), len(expected))
    else:
        require(not (app / "Contents/Resources/XodusCredentialBroker.json").exists(),
                "Unreviewed broker metadata")
    source_root = stage / "source"
    for target, original in [
        (app / "Contents/Info.plist", source_root / "tools/Info.plist"),
        (app / "Contents/Resources/LICENSE.txt", source_root / "LICENSE"),
    ]:
        original_identity, _ = owned_bytes(original)
        owned_bytes(target, original_identity["sha256"], original_identity["bytes"])
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    require(info.get("CFBundleExecutable") == "Xodus" and info.get("CFBundlePackageType") == "APPL"
            and info.get("LSMinimumSystemVersion") == "14.0",
            "Unexpected packaged executable/deployment baseline")
    resources = app / "Contents/Resources"
    require(not (resources / "XodusAppFoundation_XodusPreview.bundle").exists()
            and not (resources / "XodusAppFoundation_XodusAuthHost.bundle").exists(),
            "Shipping package contains preview/private check resources")
    management = resources / "XodusAppFoundation_XodusManagement.bundle"
    layouts = [management, management / "Contents/Resources"]
    schemas = ("management-v1.schema.json", "runtime-providers-v1.schema.json")
    present = [layout for layout in layouts if all((layout / name).is_file() for name in schemas)]
    require(len(present) == 1, "Expected exactly one SwiftPM management resource layout")
    selected = present[0]
    require(all(not (layout / name).exists() and not (layout / name).is_symlink()
                for layout in layouts if layout != selected for name in schemas),
            "Mixed or duplicate SwiftPM management resources")
    for name, expected in [
        ("management-v1.schema.json", "6945db01df88eeaf80f495f6b9d7240e270a879851c2c830fc5548ba20d32192"),
        ("runtime-providers-v1.schema.json", "90c094e4585af059b5ebcfc3201260362e88aa642b50ec0388a03427260d55e9"),
    ]:
        owned_bytes(selected / name, expected)
    archived_inputs = {}
    with tarfile.open(stage / "source.tar") as archive:
        for member in archive.getmembers():
            if member.isfile() and (member.name == "Package.swift" or member.name.startswith("Sources/")):
                require(member.name not in archived_inputs, "Duplicate archived source input")
                data = archive.extractfile(member).read()
                if member.name == "Sources/XodusPreview/ShippingPairPins.swift":
                    data = expected_pins
                identity, _ = owned_bytes(source_root / member.name, hashlib.sha256(data).hexdigest(), len(data))
                archived_inputs[member.name] = identity
    # Limit inventory to the new owned package, never another app/game/root.
    package = {}
    for path in sorted(app.rglob("*")):
        require(not path.is_symlink(), "Linked file in final package")
        if path.is_file():
            identity, _ = owned_bytes(path)
            package[str(path.relative_to(app))] = identity
    record.update({"finalPackageFiles": package, "archivedSourceFilesIncludingGeneratedPins": archived_inputs,
                   "normalLaunch": "Approved bundled pair only; human sign-in still unverified."})
    with (stage / "package-receipt.json").open("x", encoding="utf-8") as stream:
        json.dump(record, stream, sort_keys=True)
        stream.write("\n")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, json.JSONDecodeError, struct.error,
            tarfile.TarError, plistlib.InvalidFileException) as error:
        raise SystemExit("Final package verification failed: " + str(error))
