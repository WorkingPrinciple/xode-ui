#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""REQ-150 grep gate: no pre-Ode codename in this repository outside the listed exceptions.

Case-insensitive over every tracked or new file path and every text line. Exceptions are exact
files and exact line patterns, never whole folders of product code.
"""
from pathlib import Path
import hashlib
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
# The tested-games ledger and its state: historical evidence whose run IDs, paths and names must match
# hash-locked receipts; never rewritten (REQ-150 review b2530f59 m2). The ledger grows, so it is exempt by name.
FILES |= {"docs/GAME-TEST-LEDGER.md", "docs/game-test-ledger-state.json",
          # The compatibility catalogue; the app hash-locks it (install roots as observed).
          "Sources/OdeManagement/Resources/CompatibilityData/game-compatibility-v1.json"}
# Frozen QA evidence the catalogue was built from: exempt only while its bytes are the frozen ones
# (Git blob SHA-1, identical to 692/694). Any edit must drop the old name or re-justify the pin.
FROZEN = {
    "Sources/OdeManagement/QA/CompatibilityData/next-30-queue.json": "3296db2d8d60864f1d79e7c61ed133ca5829f372",
    "Sources/OdeManagement/QA/CompatibilityData/queue-inspection-v1.json": "7ac4cb610fac247018075a636fcbd190926ab765",
    "Sources/OdeManagement/QA/LaunchRecipes/preflight-game-candidates.json": "e21ab0ce5cf1ca75ecc1106d5586c540b814dd1f",
    "Sources/OdeManagement/QA/LaunchRecipes/small-game-candidates.json": "56f881be2c11e7a15e9acab56021ae21e5728ae5",
}
# Spans allowed anywhere; only the span is removed, the rest of the line is still checked:
# the upstream project's repository (xodus-gaming/xodus), the inherited public fork and links into it
# (its paths are upstream's), and links to a file at a pinned commit in our own repositories (which keep
# that commit's paths).
LINK_END = r"[^\s)\]>\"'`]*"
# A span starts at a token boundary (not inside a host, path or word) and ends at one: no trailing word
# character, hyphen or dotted continuation, so look-alike hosts, owners and repositories don't match.
START = r"(?<![\w./:@-])"
END = r"(?![\w-]|\.\w)"
GITHUB = r"(?:(?:https?://)?github\.com/)?"
ATTRIBUTION = re.compile(START + GITHUB + r"xodus-gaming(?:/xodus" + END + r")?" + END
                         + r"|" + START + GITHUB + r"WorkingPrinciple/xodus-macos" + END + r"(?:/" + LINK_END + r")?"
                         + r"|" + START + r"https?://github\.com/(?:WorkingPrinciple|dragoshont)/[\w.-]+/blob/[0-9a-f]{40}/"
                         + LINK_END)
# On a line that credits the upstream project or links the fork, the upstream project's own name.
UPSTREAM_NAME = re.compile(r"\bXodus\b(?![\w-]|\.\w)")
# Tokens allowed anywhere: the pinned producer source archive name, until producer #7 is replaced.
# Also the upstream Wine environment name XODUS_XBL_ONLINE (inherited; never renamed).
LINES = re.compile(r"xodus-cli-(?:beta-)?[0-9a-f]{7,40}-source\.tar|\bXODUS_XBL_ONLINE\b")


def blob_sha1(data):
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def files(root):
    listed = subprocess.run(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                            cwd=root, capture_output=True, check=True).stdout
    return sorted({name for name in listed.decode().split("\0") if name and (root / name).is_file()})


# Launch recipes pass the runtime's pre-rename debug channels beside the new ones for one release
# (COR-337), so either runtime version traces. REMOVE AFTER NEXT RELEASE.
RECIPES = "Sources/OdeManagement/Resources/LaunchRecipes/"
# They also keep the runtime-pin-pending environment names while the pinned runtime pair predates f8092bb.
RECIPE_TOKENS = re.compile(r"\+xodus_(?:user|package)\b"
                           r"|\bXODUS_PRIVATE_(?:RUNTIME_COM_STA|CALLER_OWNS_COM|LOCAL_SAVES)\b")


def line_violates(name, line):
    kept = RECIPE_TOKENS.sub("", line) if name.startswith(RECIPES) else line
    stripped = ATTRIBUTION.sub("", kept)
    if stripped != kept:
        stripped = UPSTREAM_NAME.sub("", stripped)
    return bool(NAME.search(LINES.sub("", stripped)))


def violations(root):
    found = []
    for name in files(root):
        if name in FILES or name.startswith(PREFIXES):
            continue
        data = (root / name).read_bytes()
        if name in FROZEN:
            if blob_sha1(data) != FROZEN[name]:
                found.append(f"{name}: frozen evidence changed (blob {blob_sha1(data)}, expected {FROZEN[name]})")
            continue
        if NAME.search(name):
            found.append(f"{name}: path")
        if b"\0" in data[:8192]:
            continue
        for number, line in enumerate(data.decode("utf-8", "replace").splitlines(), 1):
            if line_violates(name, line):
                found.append(f"{name}:{number}: {line.strip()[:160]}")
    return found


# Lines that must fail, and must pass, whatever the tree holds (708fb8ae n1).
SELF_TEST = (
    ("README.md", "[x](https://github.com/WorkingPrinciple/xode-ui/blob/" + "0" * 40 + "/a.md) then Xodus.app", True),
    ("README.md", "https://github.com/evil/xodus/blob/" + "0" * 40 + "/a.md", True),
    ("README.md", "https://github.com/WorkingPrinciple/x/blob/" + "0" * 40 + "/xodus.md xodus", True),
    ("README.md", "Credit: xodus-gaming, also XodusPreview", True),
    ("README.md", "[Fork](https://github.com/WorkingPrinciple/xodus-macos) and WorkingPrinciple/xodus-macos-private-ai", True),
    ("Sources/OdeManagement/Resources/LaunchRecipes/a.json", "XODUS_PRIVATE_OTHER", True),
    ("README.md", "Built on [Xodus](https://github.com/xodus-gaming/xodus); see Xodus.app", True),
    ("README.md", "Xodus alone, with no credit on the line", True),
    # Look-alike hosts, owners and repositories (REQ-150 review after da9cc503, finding 1).
    ("README.md", "https://github.com/evil/xodus-gaming", True),
    ("README.md", "https://evil.example/xodus-gaming", True),
    ("README.md", "https://github.com/xodus-gaming-evil/xodus-gaming", True),
    ("README.md", "https://github.com/WorkingPrinciple/xodus-macos.evil", True),
    ("README.md", "https://github.com/WorkingPrinciple/xodus-macos-evil", True),
    ("README.md", "https://evil.example/WorkingPrinciple/xodus-macos", True),
    ("README.md", "https://xodus-gaming.evil.example/x", True),
    ("README.md", "evilxodus-gaming/xodus", True),
    ("README.md", "https://github.com/xodus-gaming/xodusevil", True),
    ("README.md", "https://github.com/xodus-gaming/xodus.evil", True),
    ("README.md", "https://evil.example/https://github.com/WorkingPrinciple/x/blob/" + "0" * 40 + "/xodus", True),
    ("README.md", "XODUS_XBL_ONLINE=1 xodus-cli-beta-285696f9-source.tar", False),
    ("README.md", "[a](https://github.com/WorkingPrinciple/xode-ui/blob/" + "0" * 40 + "/Sources/XodusPreview/A.swift#L1)", False),
    ("README.md", "Built on [xodus-gaming](https://github.com/WorkingPrinciple/xodus-macos).", False),
    ("README.md", "[notes](https://github.com/WorkingPrinciple/xodus-macos/blob/main/docs/xodus/a.md) of Xodus.", False),
    ("README.md", "Upstream game-management project (xodus-gaming/xodus)", False),
    ("README.md", 'linkText: "github.com/xodus-gaming/xodus",', False),
    ("README.md", "a fork of the Xodus game-management project (xodus-gaming, GPL-3.0).", False),
    ("README.md", "is the [macOS backend fork](https://github.com/WorkingPrinciple/xodus-macos) of Xodus.", False),
    ("Sources/OdeManagement/Resources/LaunchRecipes/a.json", "+xodus_user,+ode_user XODUS_PRIVATE_LOCAL_SAVES", False),
)


def self_test():
    return [f"self-test: {line!r} should {'fail' if bad else 'pass'}"
            for name, line, bad in SELF_TEST if line_violates(name, line) != bad]


def main():
    root = Path(__file__).resolve().parent.parent
    found = self_test() + violations(root)
    for item in found:
        print(item)
    print(f"{len(found)} legacy-name match(es) outside the REQ-150 exceptions", file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
