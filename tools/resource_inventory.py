#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Create the release inventory for the resources in an X Ode app bundle."""
import json
from pathlib import Path
import re

from shipping_pair import owned_bytes, require, unique_object

QA_JSON_NAMES = frozenset({
    "mac-game-evidence-v1.json",
    "next-30-queue.json",
    "preflight-game-candidates.json",
    "queue-inspection-v1.json",
    "small-game-candidates.json",
})
INSPECTION_JSON_NAMES = QA_JSON_NAMES | frozenset({
    "distribution-components.json",
    "local-candidate-receipt.json",
})
NMS_DEVELOPER_LOCAL_REGISTRY = (
    "${HOME}/src/copilot-worktrees/calimocho/dragoshont-cautious-potato/build/winehq-11.20/"
    "metal-port-11b-private-binding-01/"
    "calimocho-wine11.20-gptk4b3-tls-vulkan-private.registry.local.PERF-FROZEN-170ca4ad.json"
)
DEVELOPER_PATH = re.compile(
    r"/Users/[^/\\\s\"']+|/home/[^/\\\s\"']+|"
    r"\$\{HOME\}/(?:src/|\.copilot/|Library/Application Support/XodusCLI/proofs/)|"
    r"\$HOME/(?:src/|\.copilot/)|~/(?:src/|\.copilot/)|"
    r"\.copilot/session-state/"
)
DEVELOPER_PATH_BYTES = re.compile(
    rb"/Users/[^/\\\s\"']+|/home/[^/\\\s\"']+|"
    rb"\$\{HOME\}/(?:src/|\.copilot/|Library/Application Support/XodusCLI/proofs/)|"
    rb"\$HOME/(?:src/|\.copilot/)|~/(?:src/|\.copilot/)|"
    rb"\.copilot/session-state/"
)


def developer_path_findings(relative, data):
    text = data.decode("utf-8")
    exceptions = []
    if NMS_DEVELOPER_LOCAL_REGISTRY in text:
        relative = Path(relative).as_posix()
        require(relative.endswith(
            "XodusAppFoundation_XodusManagement.bundle/Contents/Resources/"
            "LaunchRecipes/engine-defaults-v1.json")
            or relative.endswith(
                "XodusAppFoundation_XodusManagement.bundle/Contents/Resources/"
                "engine-defaults-v1.json")
            or relative.endswith(
                "XodusAppFoundation_XodusManagement.bundle/LaunchRecipes/engine-defaults-v1.json"),
            "NMS developer-local path appears outside engine-defaults-v1.json")
        value = json.loads(data, object_pairs_hook=unique_object)
        bindings = value.get("bindings", [])
        matches = [
            binding for binding in bindings
            if binding.get("registryPath") == NMS_DEVELOPER_LOCAL_REGISTRY
            and binding.get("engineName") == "calimocho-wine11.20-gptk4b3-tls-vulkan-private"
            and binding.get("developerLocal") is True
        ]
        require(len(matches) == 1 and text.count(NMS_DEVELOPER_LOCAL_REGISTRY) == 1,
                "NMS developer-local exception is not the recorded engine binding")
        exceptions.append({
            "type": "approved-developer-local-engine-binding",
            "resource": relative,
            "path": NMS_DEVELOPER_LOCAL_REGISTRY,
            "engine": "calimocho-wine11.20-gptk4b3-tls-vulkan-private",
        })
        text = text.replace(NMS_DEVELOPER_LOCAL_REGISTRY, "", 1)
    return {"hasDeveloperPath": DEVELOPER_PATH.search(text) is not None,
            "exceptions": exceptions}


def developer_path_present(relative, data):
    return developer_path_findings(relative, data)["hasDeveloperPath"]


def developer_path_in_file(path):
    tail = b""
    with Path(path).open("rb") as source:
        while chunk := source.read(65_536):
            data = tail + chunk
            if DEVELOPER_PATH_BYTES.search(data):
                return True
            tail = data[-512:]
    return False


def inspect_resources(app):
    resources = Path(app) / "Contents/Resources"
    require(resources.is_dir() and not resources.is_symlink(),
            "App resource directory is missing or linked")
    entries = []
    exceptions = []
    for path in sorted(resources.rglob("*")):
        require(not path.is_symlink(), "Linked app resource: " + str(path))
        if not path.is_file():
            continue
        relative = path.relative_to(resources).as_posix()
        identity, data = owned_bytes(
            path, bounded=16 * 1024 * 1024 if path.suffix.lower() == ".json" else None)
        path_findings = developer_path_findings(relative, data) if path.suffix.lower() == ".json" \
            else {"hasDeveloperPath": developer_path_in_file(path), "exceptions": []}
        exceptions.extend(path_findings["exceptions"])
        classification = "QA/inspection" if path.suffix.lower() == ".json" \
            and path.name in INSPECTION_JSON_NAMES else "runtime-needed"
        issues = []
        if path_findings["hasDeveloperPath"]:
            issues.append("developer-local path reference")
        entries.append({"path": relative, **identity, "classification": classification,
                        **({"issues": issues} if issues else {})})
    require(entries, "App resource inventory is empty")
    return {"schemaVersion": 1, "exceptions": exceptions, "resources": entries}


def inventory(app):
    value = inspect_resources(app)
    entries = value["resources"]
    require(not any(entry["classification"] == "QA/inspection" for entry in entries),
            "QA/inspection JSON cannot ship: " + ", ".join(
                entry["path"] for entry in entries if entry["classification"] == "QA/inspection"))
    require(not any(entry.get("issues") for entry in entries),
            "Developer-local path cannot ship: " + ", ".join(
                entry["path"] for entry in entries if entry.get("issues")))
    return value


def write_inventory(app, destination):
    destination = Path(destination)
    require(not destination.exists() and not destination.is_symlink(),
            "Resource inventory destination already exists")
    value = inventory(app)
    destination.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    return owned_bytes(destination)[0]
