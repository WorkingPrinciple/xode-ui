#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Seal exact component identities and unresolved source/rights obligations."""
import json
from pathlib import Path
import shutil

from package_resources import resource_layout, verify_resources
from producer_notices import verify as verify_producer_notices
from shipping_pair import owned_bytes, require, unique_object

COMPONENT_PATHS = {
    "app": "Contents/MacOS/Xodus",
    "authHost": "Contents/MacOS/XodusAuthHost",
    "cli": "Contents/Resources/XodusEngine/xodus-cli",
    "windowsHelper": "Contents/Resources/XodusEngine/xodus-window-monitor.exe",
}


def optional_payloads(app):
    resources = app / "Contents/Resources"
    result = {}
    python_root, python_manifest = resources / "XodusPython", resources / "XodusPython.json"
    if python_root.exists() or python_manifest.exists():
        from python_runtime import approved_pin, verify_runtime
        _, data = owned_bytes(python_manifest, bounded=4 * 1024 * 1024)
        metadata = json.loads(data, object_pairs_hook=unique_object)
        verify_runtime(python_root, metadata)
        result["pythonRuntime"] = {
            "source": approved_pin(), "files": {
                "Contents/Resources/XodusPython/" + name: {
                    "sha256": identity["sha256"], "bytes": identity["bytes"]}
                for name, identity in metadata["files"].items()},
            "metadata": {"path": "Contents/Resources/XodusPython.json",
                         **owned_bytes(python_manifest)[0]},
        }
    broker = resources / "XodusCredentialBroker.json"
    if broker.exists():
        _, data = owned_bytes(broker, bounded=4096)
        pin = json.loads(data, object_pairs_hook=unique_object)
        require(set(pin) == {"version", "sha256", "bytes"} and pin["version"] == 1,
                "Invalid credential broker reference")
        result["credentialBroker"] = {
            "delivery": "separately-installed; executable is not in the app bundle",
            "payloadReference": pin, "files": {},
            "metadata": {"path": "Contents/Resources/XodusCredentialBroker.json",
                         **owned_bytes(broker)[0]},
        }
    capsule = resources / "LaunchAssociation"
    if capsule.exists():
        from launch_association_capsule import verify_capsule
        result["launchAssociation"] = {
            "source": verify_capsule(capsule),
            "files": {path.relative_to(app).as_posix(): owned_bytes(path)[0]
                      for path in capsule.rglob("*") if path.is_file()},
        }
    return result


def verify_payload_coverage(app, optional):
    """Unmapped payloads cannot inherit another component's rights clearance."""
    management = app / "Contents/Resources/XodusAppFoundation_XodusManagement.bundle"
    verify_resources(management)
    allowed = set(COMPONENT_PATHS.values()) | {
        "Contents/Info.plist", "Contents/Resources/LICENSE.txt", "Contents/Resources/Xodus.icns",
        "Contents/Resources/XodusAuthHost.json", "Contents/Resources/local-candidate-receipt.json",
        "Contents/Resources/XodusEngine/build-manifest.json",
        "Contents/Resources/distribution-components.json",
        "Contents/_CodeSignature/CodeResources",
    }
    allowed.update(path.relative_to(app).as_posix() for path in management.rglob("*") if path.is_file())
    for component in optional.values():
        allowed.update(component["files"])
        if "metadata" in component:
            allowed.add(component["metadata"]["path"])
    notices = app / "Contents/Resources/ProducerNotices"
    if notices.exists():
        allowed.update(path.relative_to(app).as_posix() for path in notices.rglob("*") if path.is_file())
    for path in app.rglob("*"):
        require(not path.is_symlink(), "Linked distribution payload")
        if not path.is_file():
            continue
        relative = path.relative_to(app).as_posix()
        if relative.startswith("Contents/Resources/Xodus.iconset/") and path.suffix == ".png":
            _, data = owned_bytes(path, bounded=16 * 1024 * 1024)
            require(data.startswith(b"\x89PNG\r\n\x1a\n"), "Invalid packaged icon")
            continue
        require(relative in allowed, "Unmapped distribution payload: " + relative)
        owned_bytes(path)
        if relative not in COMPONENT_PATHS.values() and not any(
                relative in component["files"] for component in optional.values()):
            require(not path.stat().st_mode & 0o111, "Executable non-code resource: " + relative)
            with path.open("rb") as stream:
                header = stream.read(4)
            require(header not in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe",
                                   b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce",
                                   b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
                                   b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca", b"\x7fELF")
                    and not header.startswith((b"MZ", b"#!")),
                    "Executable content in non-code resource: " + relative)


def write_manifest(app, source, producer, archive, producer_notices=None):
    resources = app / "Contents/Resources"
    records = {}
    for name, relative in COMPONENT_PATHS.items():
        identity, _ = owned_bytes(app / relative)
        records[name] = {
            **identity, "path": relative,
            "source": source if name in ("app", "authHost") else producer,
            "license": "GPL-3.0-only" if name in ("app", "authHost") else "unresolved",
            "notice": "LICENSE.txt" if name in ("app", "authHost") else None,
            "correspondingSource": "delivery-unresolved",
            "rightsReview": "unresolved",
        }
    management = resources / "XodusAppFoundation_XodusManagement.bundle"
    verify_resources(management)
    layout = resource_layout(management)
    notice, _ = owned_bytes(layout / "CompatibilityData/AWACY-LICENSE.txt")
    optional = optional_payloads(app)
    for component in optional.values():
        component.update({"license": "unresolved", "rightsReview": "unresolved",
                          "correspondingSource": "delivery-unresolved"})
    dependency_inventory = None
    if producer_notices is not None:
        verify_producer_notices(producer_notices, producer, records["cli"]["sha256"],
                               records["windowsHelper"]["sha256"])
        shutil.copytree(producer_notices, resources / "ProducerNotices")
        dependency_inventory = owned_bytes(resources / "ProducerNotices/inventory.json")[0]
    verify_payload_coverage(app, optional)
    metadata = {
        "version": 1, "components": records,
        "optionalComponents": optional,
        "producerNotices": dependency_inventory,
        "appSourceArchive": owned_bytes(archive)[0],
        "compatibilityDataNotice": {"license": "MIT", **notice,
            "path": str((layout / "CompatibilityData/AWACY-LICENSE.txt").relative_to(app))},
        "userInstalledNotBundled": ["Wine/Calimocho", "CrossOver", "GPTK", "graphics shims", "games"],
        "unresolved": [
            *([] if dependency_inventory else ["Exact producer dependency inventory/notices not supplied"]),
            "Exact app and producer corresponding-source delivery route",
            "Distribution target and component redistribution-rights review",
        ],
    }
    path = resources / "distribution-components.json"
    with path.open("x", encoding="utf-8") as stream:
        json.dump(metadata, stream, sort_keys=True, indent=2)
        stream.write("\n")


def distribution_blockers(app):
    resources = app / "Contents/Resources"
    _, data = owned_bytes(resources / "distribution-components.json", bounded=4 * 1024 * 1024)
    metadata = json.loads(data, object_pairs_hook=unique_object)
    require(metadata["version"] == 1 and set(metadata["components"]) == set(COMPONENT_PATHS),
            "Incomplete distribution component inventory")
    blockers = list(metadata["unresolved"])
    optional = optional_payloads(app)
    declared_optional = metadata.get("optionalComponents", {})
    require(set(optional) == set(declared_optional), "Optional distribution inventory differs from payloads")
    for name, component in optional.items():
        declared = declared_optional[name]
        require(all(declared.get(key) == value for key, value in component.items()),
                "Optional distribution payload changed: " + name)
        if declared["license"] == "unresolved" or declared["rightsReview"] != "resolved" \
                or declared["correspondingSource"] == "delivery-unresolved":
            blockers.append("Unresolved optional component source/license/rights: " + name)
    verify_payload_coverage(app, optional)
    notices = resources / "ProducerNotices"
    if metadata.get("producerNotices") is not None:
        identity = metadata["producerNotices"]
        owned_bytes(notices / "inventory.json", identity["sha256"], identity["bytes"])
        inventory = verify_producer_notices(
            notices, metadata["components"]["cli"]["source"],
            metadata["components"]["cli"]["sha256"],
            metadata["components"]["windowsHelper"]["sha256"])
        blockers.extend(inventory["unresolved"])
    else:
        require(not notices.exists() and not notices.is_symlink(), "Unmapped producer notices")
        missing = "Exact producer dependency inventory/notices not supplied"
        if missing not in blockers:
            blockers.append(missing)
    for name, relative in COMPONENT_PATHS.items():
        component = metadata["components"][name]
        require(component["path"] == relative, "Unexpected component path")
        owned_bytes(app / relative, component["sha256"], component["bytes"])
        if component["rightsReview"] != "resolved" or component["correspondingSource"] == "delivery-unresolved":
            blockers.append("Unresolved source/rights: " + name)
    notice = metadata["compatibilityDataNotice"]
    notice_path = Path(notice["path"])
    require(not notice_path.is_absolute() and ".." not in notice_path.parts, "Invalid notice path")
    owned_bytes(app / notice_path, notice["sha256"], notice["bytes"])
    management = resources / "XodusAppFoundation_XodusManagement.bundle"
    verify_resources(management)
    for path in sorted(resource_layout(management).rglob("*.json")):
        _, data = owned_bytes(path, bounded=16 * 1024 * 1024)
        # Do not expose private values; report only the affected resource name.
        text = data.decode("utf-8")
        if any(marker in text for marker in ("/Users/", "/src/copilot-worktrees/", ".copilot/session-state/")):
            blockers.append("Development-machine reference: " + path.relative_to(management).as_posix())
    return blockers


def require_distribution_ready(app):
    blockers = distribution_blockers(app)
    require(not blockers, "Distribution preflight blocked: " + "; ".join(blockers))
