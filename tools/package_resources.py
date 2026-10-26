#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Copy only runtime-consumed management resources, never private QA queues."""
from pathlib import Path
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
    for name in sorted(RUNTIME_RESOURCES):
        target = destination / (root.relative_to(source)) / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / name, target)
    info = source / "Contents/Info.plist"
    if root != source and info.is_file():
        owned_bytes(info)
        shutil.copyfile(info, destination / "Contents/Info.plist")
    verify_resources(destination)


if __name__ == "__main__":
    copy_resources(Path(sys.argv[1]), Path(sys.argv[2]))
