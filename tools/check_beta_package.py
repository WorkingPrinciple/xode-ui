#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Neutral regressions for beta packaging; no OS signing or external submission."""
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import tempfile
from unittest.mock import patch

import package_beta as beta
from package_beta import ARTIFACT_STEM, IDENTITY, TEAM_ID, VERSION, package_beta as create_beta_package


def fixture(root):
    app = root / "Ode to X Local Candidate.app"
    (app / "Contents/Resources").mkdir(parents=True)
    with (app / "Contents/Info.plist").open("wb") as output:
        plistlib.dump({"CFBundleShortVersionString": VERSION,
                       "CFBundleIdentifier": beta.APP_IDENTIFIER}, output)
    (app / "Contents/Resources/local-candidate-receipt.json").write_text(json.dumps({
        "appSource": {"commit": "a" * 40, "tree": "b" * 40},
    }))
    output = root / "output"
    output.mkdir(mode=0o700)
    output.chmod(0o700)
    return app, output


def signatures():
    return {
        "app": {"identifier": beta.APP_IDENTIFIER, "teamIdentifier": TEAM_ID,
                "certificateSha1": IDENTITY, "hardenedRuntime": True, "secureTimestamp": True},
        "Contents/MacOS/Xodus": {"identifier": beta.APP_IDENTIFIER,
                "teamIdentifier": TEAM_ID, "certificateSha1": IDENTITY,
                "hardenedRuntime": True, "secureTimestamp": True},
    }


def fake_runner(calls):
    def run(arguments):
        arguments = list(map(str, arguments))
        calls.append(arguments)
        if arguments[0] == "/usr/bin/ditto" and len(arguments) == 3:
            shutil.copytree(arguments[1], arguments[2])
        elif arguments[0] == "/usr/bin/ditto" and "-c" in arguments:
            payload = Path(arguments[-2])
            assert (payload / "INSTALL.txt").is_file()
            assert (payload / "RELEASE-NOTES.txt").read_text(encoding="utf-8") == beta.RELEASE_NOTES
            assert (payload / "Ode to X.app").is_dir()
            Path(arguments[-1]).write_bytes(b"Neutral beta archive")
        elif arguments[0] == "/usr/bin/hdiutil":
            Path(arguments[-1]).write_bytes(b"Neutral signed disk image")
        return ""
    return run


def rejected(operation):
    try:
        operation()
    except (ValueError, OSError):
        return
    raise AssertionError("Unsafe beta package was accepted")


with tempfile.TemporaryDirectory(prefix="xodus-beta-package-") as temporary:
    root = Path(temporary).resolve()
    app, output = fixture(root)
    commands = []
    with patch.object(beta, "distribution_blockers", return_value=[]) as blockers, \
            patch.object(beta, "verify_developer_id_bundle", return_value=signatures()):
        receipt_path = create_beta_package(app, output, "zip", producer_notices_sha256="c" * 64,
                                           run_command=fake_runner(commands))
        assert blockers.call_args.args == (app, "c" * 64)
    receipt = json.loads(receipt_path.read_text())
    artifact_path = receipt_path.parent / (ARTIFACT_STEM + ".zip")
    checksum_path = receipt_path.parent / (artifact_path.name + ".sha256")
    assert receipt["state"] == "prepared_not_submitted"
    assert receipt["notarization"] == "NOT_SUBMITTED"
    assert receipt["installed"] is False and receipt["launched"] is False
    assert receipt["producerNoticesSHA256"] == "c" * 64
    assert receipt["artifacts"]["sha256"] == hashlib.sha256(artifact_path.read_bytes()).hexdigest()
    assert checksum_path.read_text() == receipt["artifacts"]["sha256"] + "  " + artifact_path.name + "\n"
    assert not any(name in " ".join(command) for command in commands
                   for name in ("notarytool", "stapler", "open", "launchctl"))
    assert (receipt_path.parent / "package-receipt.json").exists()

    commands.clear()
    with patch.object(beta, "distribution_blockers", return_value=[]), \
            patch.object(beta, "verify_developer_id_bundle", return_value=signatures()), \
            patch.object(beta, "verify_developer_id_component",
                         return_value={"certificateSha1": IDENTITY, "secureTimestamp": True}):
        dmg_receipt_path = create_beta_package(app, output, "dmg", run_command=fake_runner(commands))
    dmg_receipt = json.loads(dmg_receipt_path.read_text())
    assert dmg_receipt["format"] == "dmg"
    assert any(command[0] == "/usr/bin/codesign" and "--timestamp" in command for command in commands)
    assert not any(name in " ".join(command) for command in commands
                   for name in ("notarytool", "stapler", "open", "launchctl"))

    with patch.object(beta, "distribution_blockers", return_value=["Unresolved rights"]), \
            patch.object(beta, "verify_developer_id_bundle", return_value=signatures()):
        rejected(lambda: create_beta_package(app, output, "zip", run_command=fake_runner([])))

    with (app / "Contents/Info.plist").open("wb") as output_file:
        plistlib.dump({"CFBundleShortVersionString": "0.2.0",
                       "CFBundleIdentifier": beta.APP_IDENTIFIER}, output_file)
    with patch.object(beta, "distribution_blockers", return_value=[]), \
            patch.object(beta, "verify_developer_id_bundle", return_value=signatures()):
        rejected(lambda: create_beta_package(app, output, "zip", run_command=fake_runner([])))

print("PASS 0.11.4 archive/checksum, optional timestamped DMG, rights blocker, and no-submit/no-install behavior. "
      "Neutral fixture bytes and mocked platform commands only.")
