#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Copy only runtime-consumed management resources, never private QA queues."""
import json
from pathlib import Path
import re
import shutil
import sys

from shipping_pair import owned_bytes, require

RUNTIME_RESOURCES = frozenset({
    "management-v1.schema.json",
    "runtime-providers-v1.schema.json",
    "mac-game-status-v1.json",
    "LaunchRecipes/engine-defaults-v1.json",
    "LaunchRecipes/hollow-knight-local-saves-candidate-v1.json",
    "LaunchRecipes/launch-candidates-v1.json",
    "LaunchRecipes/save-locations-v1.json",
    "LaunchRecipes/title-profiles-v1.json",
    "LaunchRecipes/title-runtime-v1.json",
    "CompatibilityData/AWACY-LICENSE.txt",
    "CompatibilityData/game-compatibility-v1.json",
    "CompatibilityData/publisher-anti-cheat-v1.json",
})
PRIVATE_QA_RESOURCES = frozenset({
    "CompatibilityData/next-30-queue.json",
    "CompatibilityData/queue-inspection-v1.json",
    "LaunchRecipes/preflight-game-candidates.json",
    "LaunchRecipes/small-game-candidates.json",
    "mac-game-evidence-v1.json",
})


# REQ-52: developer source trees, worktrees and branch names never ship, templated or not.
DEVELOPER_SOURCE_PATH = re.compile(
    r"(\$\{HOME\}|\$HOME|~)/(src|\.copilot)/|copilot-worktrees|/Users/[^/\s\"']+/src/")
ENGINE_DEFAULTS = "LaunchRecipes/engine-defaults-v1.json"
TITLE_PROFILES = "LaunchRecipes/title-profiles-v1.json"


def is_source_tree_binding(binding):
    return (binding.get("developerLocal") is True
            and DEVELOPER_SOURCE_PATH.search(binding.get("registryPath") or "") is not None)


def stripped_engine_names(data):
    return {binding.get("engineName") for binding in json.loads(data).get("bindings", [])
            if is_source_tree_binding(binding)}


def staged_engine_defaults(data):
    """Drops developer-local bindings whose registry lives in a source tree or worktree."""
    value = json.loads(data)
    bindings = value.get("bindings", [])
    kept = [binding for binding in bindings if not is_source_tree_binding(binding)]
    require(all(binding.get("engineName") != value.get("defaultEngine") for binding in bindings
                if binding not in kept), "The default engine cannot be a developer source-tree binding")
    if len(kept) == len(bindings):
        return data
    value["bindings"] = kept
    return (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode()


def staged_title_profiles(data, stripped_engines):
    """Drops title profiles bound to an engine whose developer-local binding isn't packaged."""
    if not stripped_engines:
        return data
    value = json.loads(data)
    profiles = value.get("profiles", [])
    kept = [profile for profile in profiles if profile.get("engine") not in stripped_engines]
    if len(kept) == len(profiles):
        return data
    value["profiles"] = kept
    return (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode()


def require_no_developer_paths(root):
    for name in sorted(RUNTIME_RESOURCES):
        text = (root / name).read_bytes().decode("utf-8", errors="replace")
        require(DEVELOPER_SOURCE_PATH.search(text) is None,
                "Developer source-tree or worktree path in staged resource: " + name)


def resource_layout(bundle):
    require(not bundle.is_symlink(), "Linked management resource bundle")
    layouts = [bundle, bundle / "Contents/Resources"]
    matches = [p for p in layouts if (p / "management-v1.schema.json").is_file()]
    require(len(matches) == 1, "Expected one management resource layout")
    return matches[0]


def inventory(root):
    files = set()
    for path in root.rglob("*"):
        require(not path.is_symlink(), "Linked management resource: " + str(path))
        if path.is_file():
            files.add(path.relative_to(root).as_posix())
    return files


def reject_outside_layout(bundle, root):
    if root != bundle:
        prefix = root.relative_to(bundle).as_posix() + "/"
        require(all(name == "Contents/Info.plist" or name.startswith(prefix)
                    for name in inventory(bundle)), "Resource outside management layout")


def verify_resources(bundle):
    root = resource_layout(bundle)
    reject_outside_layout(bundle, root)
    files = inventory(root)
    if root == bundle:
        files.discard("Info.plist")
    require(files == RUNTIME_RESOURCES, "Management resources differ from runtime allowlist: "
            + ", ".join(sorted(files ^ RUNTIME_RESOURCES)))
    for name in RUNTIME_RESOURCES:
        owned_bytes(root / name)
    require_no_developer_paths(root)


def copy_resources(source, destination):
    require(not destination.exists() and not destination.is_symlink(),
            "Management resource destination already exists")
    root = resource_layout(source)
    require(root.resolve(strict=True) == root, "Linked management resource layout")
    reject_outside_layout(source, root)
    files = inventory(root)
    if root == source:
        files.discard("Info.plist")
    require(RUNTIME_RESOURCES <= files
            and files <= RUNTIME_RESOURCES | PRIVATE_QA_RESOURCES,
            "Unreviewed or missing management resources: "
            + ", ".join(sorted((RUNTIME_RESOURCES - files)
                               | (files - RUNTIME_RESOURCES - PRIVATE_QA_RESOURCES))))
    # Validate the complete input before creating any output.
    for name in RUNTIME_RESOURCES:
        owned_bytes(root / name)
    stripped = stripped_engine_names((root / ENGINE_DEFAULTS).read_bytes())
    for name in sorted(RUNTIME_RESOURCES):
        target = destination / (root.relative_to(source)) / name
        target.parent.mkdir(parents=True, exist_ok=True)
        if name == ENGINE_DEFAULTS:
            target.write_bytes(staged_engine_defaults((root / name).read_bytes()))
        elif name == TITLE_PROFILES:
            target.write_bytes(staged_title_profiles((root / name).read_bytes(), stripped))
        else:
            shutil.copyfile(root / name, target)
    info = source / "Contents/Info.plist"
    if root != source and info.is_file():
        owned_bytes(info)
        shutil.copyfile(info, destination / "Contents/Info.plist")
    verify_resources(destination)


if __name__ == "__main__":
    copy_resources(Path(sys.argv[1]), Path(sys.argv[2]))
