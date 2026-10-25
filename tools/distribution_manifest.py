#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Seal exact component identities and unresolved source/rights obligations."""
import json
from pathlib import Path

from package_resources import resource_layout, verify_resources
from shipping_pair import owned_bytes, require, unique_object

COMPONENT_PATHS = {
    "app": "Contents/MacOS/Xodus",
    "authHost": "Contents/MacOS/XodusAuthHost",
    "cli": "Contents/Resources/XodusEngine/xodus-cli",
    "windowsHelper": "Contents/Resources/XodusEngine/xodus-window-monitor.exe",
}


def write_manifest(app, source, producer, archive):
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
    metadata = {
        "version": 1, "components": records,
        "appSourceArchive": owned_bytes(archive)[0],
        "compatibilityDataNotice": {"license": "MIT", **notice,
            "path": str((layout / "CompatibilityData/AWACY-LICENSE.txt").relative_to(app))},
        "userInstalledNotBundled": ["Wine/Calimocho", "CrossOver", "GPTK", "graphics shims", "games"],
        "unresolved": [
            "CLI/helper transitive dependency versions, licenses, notices and source obligations",
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
