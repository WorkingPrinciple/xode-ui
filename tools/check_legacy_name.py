#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""REQ-150 grep gate: no pre-Ode codename in this repository outside the listed exceptions.

Case-insensitive over every tracked or new file path and every text line. Exceptions are exact
files and exact line patterns, never whole folders of product code.
"""
from pathlib import Path
import re
import subprocess
import sys

NAME = re.compile("xodus", re.IGNORECASE)

# Files allowed to hold the old name in full.
FILES = {
    # The two single-file compatibility adapters (Swift, Python); removal after the next release.
    "Sources/OdeLegacyCompatibility/LegacyCompatibility.swift",
    "tools/legacy_compatibility.py",
    # This gate, and the rename record that maps old names to new.
    "tools/check_legacy_name.py",
    "docs/ODE-RENAME.md",
    # Secret-scanner fingerprints of historical commits; paths there are immutable.
    ".gitleaksignore",
    # Byte-identical copies of backend contracts; they change only when the backend contract does.
    "Sources/OdeAuthHost/Resources/native-auth-host-v1.schema.json",
    "Sources/OdeManagement/Resources/management-v1.schema.json",
    "Sources/OdeManagement/Resources/runtime-providers-v1.schema.json",
    "docs/contracts/foundation-v1.schema.json",
    "docs/contracts/management-v1.schema.json",
    "docs/contracts/runtime-providers-v1.schema.json",
    "Tests/ManagementChecks/Fixtures/install-plan-development.schema.json",
    "Tests/ManagementChecks/Fixtures/registry-development.schema.json",
}
# Immutable archives.
PREFIXES = ("design/archive/",)
# Whole lines allowed anywhere: credit to the upstream project and links to the inherited public fork.
ATTRIBUTION = re.compile(r"xodus-gaming|WorkingPrinciple/xodus-macos(?![-\w])")
# Tokens allowed anywhere: the pinned producer source archive name, until producer #7 is replaced.
LINES = re.compile(r"xodus-cli-beta-[0-9a-f]{7,40}-source\.tar")


def files(root):
    listed = subprocess.run(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                            cwd=root, capture_output=True, check=True).stdout
    return sorted({name for name in listed.decode().split("\0") if name and (root / name).is_file()})


# Launch recipes pass the runtime's pre-rename debug channels beside the new ones for one release
# (COR-337), so either runtime version traces. REMOVE AFTER NEXT RELEASE.
RECIPES = "Sources/OdeManagement/Resources/LaunchRecipes/"
RECIPE_TOKENS = re.compile(r"\+xodus_(?:user|package)\b")


def violations(root):
    found = []
    for name in files(root):
        if name in FILES or name.startswith(PREFIXES):
            continue
        if NAME.search(name):
            found.append(f"{name}: path")
        data = (root / name).read_bytes()
        if b"\0" in data[:8192]:
            continue
        for number, line in enumerate(data.decode("utf-8", "replace").splitlines(), 1):
            kept = RECIPE_TOKENS.sub("", line) if name.startswith(RECIPES) else line
            if NAME.search(line) and not ATTRIBUTION.search(line) and NAME.search(LINES.sub("", kept)):
                found.append(f"{name}:{number}: {line.strip()[:160]}")
    return found


def main():
    root = Path(__file__).resolve().parent.parent
    found = violations(root)
    for item in found:
        print(item)
    print(f"{len(found)} legacy-name match(es) outside the REQ-150 exceptions", file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
