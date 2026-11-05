#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Fail-closed source/tag/build input checks; never create approval receipts."""
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

from release_admission import verify_release_admission
from release_dmg_trust import persistent_root


def preflight(environment=os.environ):
    required = ("TAG", "EXPECTED_COMMIT", "RELEASE_APP", "RELEASE_ADMISSION",
                "RELEASE_ADMISSION_SHA256", "RELEASE_APP_SHA256",
                "RELEASE_DMG_SIGNING_IDENTITY", "RELEASE_NOTARY_PROFILE", "RELEASE_DMG_RECOVERY_ROOT")
    missing = [key for key in required if not environment.get(key)]
    if missing:
        raise ValueError("Missing release prerequisites: " + ", ".join(missing))
    tag = environment["TAG"]
    if not re.fullmatch(r"v[0-9][0-9A-Za-z.+-]*", tag):
        raise ValueError("Invalid version tag")
    if not re.fullmatch(r"[0-9a-fA-F]{40}", environment["RELEASE_DMG_SIGNING_IDENTITY"]):
        raise ValueError("Invalid DMG signing certificate SHA1")
    profile = environment["RELEASE_NOTARY_PROFILE"]
    if profile.startswith("-") or any(ord(c) < 32 for c in profile):
        raise ValueError("Invalid notary Keychain profile")
    persistent_root(environment)
    with Path("tools/Info.plist").open("rb") as source:
        version = plistlib.load(source)["CFBundleShortVersionString"]
    if tag != "v" + version:
        raise ValueError("Tag does not match app version")
    def git(*args):
        return subprocess.check_output(["git", *args], text=True).strip()
    if git("rev-parse", "HEAD") != environment["EXPECTED_COMMIT"]:
        raise ValueError("Tag checkout source mismatch")
    if git("status", "--porcelain", "--untracked-files=normal"):
        raise ValueError("Release source is not clean")
    for key in ("RELEASE_ADMISSION_SHA256", "RELEASE_APP_SHA256"):
        if not re.fullmatch(r"[0-9a-f]{64}", environment[key]):
            raise ValueError("Invalid SHA256: " + key)
    for key in ("RELEASE_APP", "RELEASE_ADMISSION"):
        path = Path(environment[key])
        if not path.is_absolute() or path.resolve(strict=True) != path:
            raise ValueError("Noncanonical absolute input: " + key)
        if not (path.is_dir() if key == "RELEASE_APP" else path.is_file()):
            raise ValueError("Missing release input: " + key)


def qualified_app(environment=os.environ):
    preflight(environment)
    app = Path(environment["RELEASE_APP"])
    tree = subprocess.check_output(["git", "rev-parse", "HEAD^{tree}"], text=True).strip()
    verify_release_admission(
        app, environment["RELEASE_ADMISSION"],
        expected_app_sha256=environment["RELEASE_APP_SHA256"],
        expected_receipt_sha256=environment["RELEASE_ADMISSION_SHA256"],
        version=environment["TAG"][1:], commit=environment["EXPECTED_COMMIT"], tree=tree)
    return app


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["preflight"]:
            preflight()
        elif sys.argv[1:] == ["qualified-app"]:
            print(qualified_app())
        else:
            raise ValueError("Usage: release_workflow.py preflight | qualified-app")
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit("Release workflow rejected: " + str(error))
