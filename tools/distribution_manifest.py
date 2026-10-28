#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Seal exact component identities and unresolved source/rights obligations."""
import json
from pathlib import Path
import re
import shutil

from package_resources import resource_layout, verify_resources
from producer_notices import verify as verify_producer_notices
from resource_inventory import (NMS_DEVELOPER_LOCAL_REGISTRY, QA_JSON_NAMES,
                                developer_path_present)
from signing_identity import IDENTIFIERS, TEAM_ID, verify_developer_id_bundle
from shipping_pair import owned_bytes, require, unique_object

COMPONENT_PATHS = {
    "app": "Contents/MacOS/Ode",
    "authHost": "Contents/MacOS/OdeAuthHost",
    "cli": "Contents/Resources/OdeEngine/ode-cli",
    "windowsHelper": "Contents/Resources/OdeEngine/ode-window-monitor.exe",
}
APP_SIGNATURE_BINDING = {
    "identifier": IDENTIFIERS["app"],
    "teamIdentifier": TEAM_ID,
}


def optional_payloads(app):
    resources = app / "Contents/Resources"
    result = {}
    python_root, python_manifest = resources / "OdePython", resources / "OdePython.json"
    if python_root.exists() or python_manifest.exists():
        from python_runtime import approved_pin, verify_runtime
        _, data = owned_bytes(python_manifest, bounded=4 * 1024 * 1024)
        metadata = json.loads(data, object_pairs_hook=unique_object)
        verify_runtime(python_root, metadata)
        result["pythonRuntime"] = {
            "source": approved_pin(), "files": {
                "Contents/Resources/OdePython/" + name: {
                    "sha256": identity["sha256"], "bytes": identity["bytes"]}
                for name, identity in metadata["files"].items()},
            "metadata": {"path": "Contents/Resources/OdePython.json",
                         **owned_bytes(python_manifest)[0]},
        }
    broker = resources / "OdeCredentialBroker.json"
    if broker.exists():
        _, data = owned_bytes(broker, bounded=4096)
        pin = json.loads(data, object_pairs_hook=unique_object)
        require(set(pin) == {"version", "sha256", "bytes"} and pin["version"] == 1,
                "Invalid credential broker reference")
        result["credentialBroker"] = {
            "delivery": "separately-installed; executable is not in the app bundle",
            "payloadReference": pin, "files": {},
            "metadata": {"path": "Contents/Resources/OdeCredentialBroker.json",
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


def verify_resource_json(resources):
    for path in sorted(resources.rglob("*.json")):
        _, data = owned_bytes(path, bounded=16 * 1024 * 1024)
        text = data.decode("utf-8")
        if path.name in QA_JSON_NAMES:
            require(False, "QA/inspection JSON cannot ship: " + path.relative_to(resources).as_posix())
        require(not developer_path_present(path.relative_to(resources).as_posix(), data),
                "Development-machine reference: " + path.relative_to(resources).as_posix())


def verify_payload_coverage(app, optional):
    """Unmapped payloads cannot inherit another component's rights clearance."""
    management = app / "Contents/Resources/OdeApp_OdeManagement.bundle"
    verify_resources(management)
    allowed = set(COMPONENT_PATHS.values()) | {
        "Contents/Info.plist", "Contents/Resources/LICENSE.txt", "Contents/Resources/NOTICE.txt",
        "Contents/Resources/TRADEMARKS.md", "Contents/Resources/Ode.icns",
        "Contents/Resources/OdeAuthHost.json", "Contents/Resources/local-candidate-receipt.json",
        "Contents/Resources/OdeEngine/build-manifest.json",
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
    engine_notice = app / "Contents/Resources/EngineNotices/NOTICE.txt"
    if engine_notice.exists():
        allowed.add(engine_notice.relative_to(app).as_posix())
        _, data = owned_bytes(engine_notice, bounded=2 * 1024 * 1024)
        text = data.decode("utf-8")
        require(bool(text.strip()) and "\x00" not in text,
                "Engine NOTICE must be non-empty UTF-8 text")
    for path in app.rglob("*"):
        require(not path.is_symlink(), "Linked distribution payload")
        if not path.is_file():
            continue
        relative = path.relative_to(app).as_posix()
        if relative.startswith("Contents/Resources/Ode.iconset/") and path.suffix == ".png":
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
    verify_resource_json(app / "Contents/Resources")


def write_manifest(app, source, producer, archive, producer_notices=None,
                   producer_notices_sha256=None):
    resources = app / "Contents/Resources"
    records = {}
    for name, relative in COMPONENT_PATHS.items():
        component = {
            "path": relative,
            "source": source if name in ("app", "authHost") else producer,
            "license": "GPL-3.0-only" if name in ("app", "authHost") else "unresolved",
            "notice": "LICENSE.txt" if name in ("app", "authHost") else None,
            "correspondingSource": "delivery-unresolved",
            "rightsReview": "unresolved",
        }
        if name == "app":
            component["signatureVerification"] = APP_SIGNATURE_BINDING
        else:
            component.update(owned_bytes(app / relative)[0])
        records[name] = component
    management = resources / "OdeApp_OdeManagement.bundle"
    verify_resources(management)
    layout = resource_layout(management)
    notice, _ = owned_bytes(layout / "CompatibilityData/AWACY-LICENSE.txt")
    optional = optional_payloads(app)
    engine_notice = resources / "EngineNotices/NOTICE.txt"
    engine_notice_record = None
    if engine_notice.exists():
        _, notice_data = owned_bytes(engine_notice, bounded=2 * 1024 * 1024)
        notice_text = notice_data.decode("utf-8")
        require(bool(notice_text.strip()) and "\x00" not in notice_text,
                "Engine NOTICE must be non-empty UTF-8 text")
        engine_notice_record = {
            "path": engine_notice.relative_to(app).as_posix(),
            **owned_bytes(engine_notice)[0],
        }
    for component in optional.values():
        component.update({"license": "unresolved", "rightsReview": "unresolved",
                          "correspondingSource": "delivery-unresolved"})
    dependency_inventory = None
    require((producer_notices is None) == (producer_notices_sha256 is None),
            "Producer notices need their independently approved inventory digest")
    if producer_notices is not None:
        verify_producer_notices(producer_notices, producer, records["cli"]["sha256"],
                               records["windowsHelper"]["sha256"], producer_notices_sha256)
        shutil.copytree(producer_notices, resources / "ProducerNotices")
        dependency_inventory = owned_bytes(
            resources / "ProducerNotices/inventory.json", producer_notices_sha256)[0]
    verify_payload_coverage(app, optional)
    metadata = {
        "version": 1, "components": records,
        "optionalComponents": optional,
        "producerNotices": dependency_inventory,
        "engineNotice": engine_notice_record,
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


def distribution_blockers(app, approved_producer_notices_sha256=None,
                          expected_signing_identity=None):
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
        if approved_producer_notices_sha256 is None:
            blockers.append("Independently approved producer inventory SHA-256 not supplied")
        inventory = verify_producer_notices(
            notices, metadata["components"]["cli"]["source"],
            metadata["components"]["cli"]["sha256"],
            metadata["components"]["windowsHelper"]["sha256"],
            approved_producer_notices_sha256 or identity["sha256"])
        blockers.extend(inventory["unresolved"])
    else:
        require(not notices.exists() and not notices.is_symlink(), "Unmapped producer notices")
        missing = "Exact producer dependency inventory/notices not supplied"
        if missing not in blockers:
            blockers.append(missing)
    engine_notice = resources / "EngineNotices/NOTICE.txt"
    engine_notice_record = metadata.get("engineNotice")
    if engine_notice_record is None:
        require(not engine_notice.exists() and not engine_notice.is_symlink(),
                "Unrecorded Calimocho NOTICE resource")
    else:
        require(type(engine_notice_record) is dict
                and set(engine_notice_record) == {"path", "sha256", "bytes"}
                and engine_notice_record["path"] == "Contents/Resources/EngineNotices/NOTICE.txt",
                "Invalid Calimocho NOTICE receipt")
        owned_bytes(engine_notice, engine_notice_record["sha256"], engine_notice_record["bytes"])
    for name, relative in COMPONENT_PATHS.items():
        component = metadata["components"][name]
        require(component["path"] == relative, "Unexpected component path")
        if name == "app":
            require(component.get("signatureVerification") == APP_SIGNATURE_BINDING
                    and "sha256" not in component and "bytes" not in component,
                    "Main executable must be verified by code signature, not a pre-sign hash")
            if expected_signing_identity is None:
                blockers.append("Expected Developer ID identity for app signature verification not supplied")
            else:
                signatures = verify_developer_id_bundle(
                    app, expected_signing_identity, APP_SIGNATURE_BINDING["teamIdentifier"])
                signature = signatures.get("app")
                require(type(signature) is dict
                        and signature.get("identifier") == APP_SIGNATURE_BINDING["identifier"]
                        and signature.get("teamIdentifier") == APP_SIGNATURE_BINDING["teamIdentifier"]
                        and signature.get("certificateSha1") == expected_signing_identity.upper()
                        and isinstance(signature.get("cdhash"), str)
                        and re.fullmatch(r"[0-9a-f]{40}", signature["cdhash"]) is not None,
                        "Signed app identity or cdhash differs from the expected identity")
        else:
            owned_bytes(app / relative, component["sha256"], component["bytes"])
        if component["rightsReview"] != "resolved" or component["correspondingSource"] == "delivery-unresolved":
            blockers.append("Unresolved source/rights: " + name)
    notice = metadata["compatibilityDataNotice"]
    notice_path = Path(notice["path"])
    require(not notice_path.is_absolute() and ".." not in notice_path.parts, "Invalid notice path")
    owned_bytes(app / notice_path, notice["sha256"], notice["bytes"])
    management = resources / "OdeApp_OdeManagement.bundle"
    verify_resources(management)
    return blockers


def require_distribution_ready(app, approved_producer_notices_sha256=None,
                               expected_signing_identity=None):
    blockers = distribution_blockers(app, approved_producer_notices_sha256,
                                     expected_signing_identity)
    require(not blockers, "Distribution preflight blocked: " + "; ".join(blockers))
