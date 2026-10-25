#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Neutral regressions for beta packaging; no OS signing or external submission."""
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
from unittest.mock import patch

import package_beta as beta
from package_beta import (IDENTITY, TEAM_ID,
                         package_beta as create_beta_package)

PRODUCER_NOTICES_SHA256 = "a" * 64
beta.PRODUCER_NOTICES_SHA256 = PRODUCER_NOTICES_SHA256


def fixture(root):
    app = root / "X Ode Local Candidate.app"
    (app / "Contents/Resources").mkdir(parents=True)
    source = root / "source"
    source.mkdir()
    subprocess.run(["git", "init", "--initial-branch=main", str(source)], check=True,
                   stdout=subprocess.DEVNULL)
    subprocess.run(["git", "-C", str(source), "config", "user.name", "Beta Check"], check=True)
    subprocess.run(["git", "-C", str(source), "config", "user.email",
                    "beta-check@example.invalid"], check=True)
    for index in range(3):
        (source / "source.txt").write_text(str(index), encoding="utf-8")
        subprocess.run(["git", "-C", str(source), "add", "source.txt"], check=True)
        subprocess.run(["git", "-C", str(source), "commit", "-m", f"source {index}"], check=True,
                       stdout=subprocess.DEVNULL)
    commit = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"],
                                     text=True).strip()
    tree = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD^{tree}"],
                                   text=True).strip()
    with (app / "Contents/Info.plist").open("wb") as output:
        plistlib.dump({"CFBundleName": "X Ode", "CFBundleDisplayName": "X Ode",
                       "CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "3",
                       "XodeReleaseChannel": "Beta",
                       "CFBundleIdentifier": beta.APP_IDENTIFIER}, output)
    (app / "Contents/Resources/local-candidate-receipt.json").write_text(json.dumps({
        "appSource": {"commit": commit, "tree": tree},
    }))
    notices = app / "Contents/Resources/ProducerNotices"
    notices.mkdir()
    (notices / "inventory.json").write_text("Neutral fixture inventory")
    engine_notices = app / "Contents/Resources/EngineNotices"
    engine_notices.mkdir()
    (engine_notices / "NOTICE.txt").write_text("Neutral Calimocho notice fixture\n")
    output = root / "output"
    output.mkdir(mode=0o700)
    output.chmod(0o700)
    return app, output, source


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
            assert (payload / "X Ode.app").is_dir()
            Path(arguments[-1]).write_bytes(b"Neutral beta archive")
        elif arguments[0] == "dmgbuild":
            assert "-s" in arguments and "app=" in " ".join(arguments)
            assert any(value.startswith("background=") for value in arguments)
            assert "X Ode" in arguments
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
    app, output, source = fixture(root)
    commands = []
    with patch.object(beta, "distribution_blockers", return_value=[]) as blockers, \
            patch.object(beta, "verify_developer_id_bundle", return_value=signatures()):
        receipt_path = create_beta_package(app, output, "zip", source,
                                           producer_notices_sha256=PRODUCER_NOTICES_SHA256,
                                           run_command=fake_runner(commands))
        assert blockers.call_args.args == (app, PRODUCER_NOTICES_SHA256)
    receipt = json.loads(receipt_path.read_text())
    artifact_path = output / "X-Ode-0.2.0-beta-submission.zip"
    checksum_path = output / (artifact_path.name + ".sha256")
    assert receipt["state"] == "prepared_not_submitted"
    assert receipt["appVersion"] == "0.2.0"
    assert receipt["releaseChannel"] == "Beta"
    assert receipt["releaseTag"] == "v0.2.0-beta.1"
    assert receipt["buildNumber"] == 3
    assert receipt["notarization"] == "NOT_SUBMITTED"
    assert receipt["installed"] is False and receipt["launched"] is False
    assert receipt["producerNoticesSHA256"] == PRODUCER_NOTICES_SHA256
    assert "developer-local engine binding" in beta.RELEASE_NOTES
    assert "does not substitute another engine" in beta.RELEASE_NOTES
    assert "In-game voice chat and microphone input aren't supported in this beta." in beta.RELEASE_NOTES
    assert receipt["artifacts"]["sha256"] == hashlib.sha256(artifact_path.read_bytes()).hexdigest()
    assert checksum_path.read_text() == receipt["artifacts"]["sha256"] + "  " + artifact_path.name + "\n"
    assert not any(any(name in command[0] for name in ("notarytool", "stapler", "launchctl"))
                   or command[0] == "/usr/bin/open" for command in commands)
    assert (receipt_path.parent / "package-receipt.json").exists()

    inventory_path = app / "Contents/Resources/ProducerNotices/inventory.json"
    inventory_bytes = inventory_path.read_bytes()
    inventory_path.unlink()
    with patch.object(beta, "distribution_blockers", return_value=[]), \
            patch.object(beta, "verify_developer_id_bundle", return_value=signatures()):
        rejected(lambda: create_beta_package(app, output, "zip", source,
                                             producer_notices_sha256=PRODUCER_NOTICES_SHA256,
                                             run_command=fake_runner([])))
    inventory_path.write_bytes(inventory_bytes)

    commands.clear()
    background = root / "installer.tiff"
    background.write_bytes(b"II*\x00Neutral background fixture")
    (app / "Contents/Resources/Xodus.icns").write_bytes(b"icnsNeutral icon fixture")
    with patch.object(beta, "distribution_blockers", return_value=[]), \
            patch.object(beta, "verify_developer_id_bundle", return_value=signatures()), \
            patch.object(beta, "verify_developer_id_component",
                         return_value={"certificateSha1": IDENTITY, "secureTimestamp": True}):
        dmg_receipt_path = create_beta_package(app, output, "dmg", source,
                                               producer_notices_sha256=PRODUCER_NOTICES_SHA256,
                                               run_command=fake_runner(commands),
                                               dmg_background=background)
    dmg_receipt = json.loads(dmg_receipt_path.read_text())
    assert dmg_receipt["format"] == "dmg"
    assert (output / "X-Ode-0.2.0-beta.dmg").is_file()
    assert dmg_receipt["artifacts"]["background"]["sha256"] == hashlib.sha256(
        background.read_bytes()).hexdigest()
    assert dmg_receipt["artifacts"]["volumeIcon"]["sha256"] == hashlib.sha256(
        (app / "Contents/Resources/Xodus.icns").read_bytes()).hexdigest()
    dmg_command = next(command for command in commands if command[0] == "dmgbuild")
    assert any(value.startswith("app=") and value.endswith("/X Ode.app") for value in dmg_command)
    assert any(command[0] == "/usr/bin/codesign" and "--timestamp" in command for command in commands)
    assert not any(any(name in command[0] for name in ("notarytool", "stapler", "launchctl"))
                   or command[0] == "/usr/bin/open" for command in commands)

    with patch.object(beta, "distribution_blockers", return_value=["Unresolved rights"]), \
            patch.object(beta, "verify_developer_id_bundle", return_value=signatures()):
        rejected(lambda: create_beta_package(app, output, "zip", source,
                                             producer_notices_sha256=PRODUCER_NOTICES_SHA256,
                                             run_command=fake_runner([])))

    rejected(lambda: create_beta_package(app, output, "dmg", source,
                                         producer_notices_sha256=PRODUCER_NOTICES_SHA256,
                                         run_command=fake_runner([])))

    with patch.object(beta, "PRODUCER_NOTICES_SHA256", None):
        rejected(lambda: create_beta_package(app, output, "zip", source,
                                             producer_notices_sha256=PRODUCER_NOTICES_SHA256,
                                             run_command=fake_runner([])))

    with (app / "Contents/Info.plist").open("wb") as output_file:
        plistlib.dump({"CFBundleName": "X Ode", "CFBundleDisplayName": "X Ode",
                       "CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "2",
                       "XodeReleaseChannel": "Beta",
                       "CFBundleIdentifier": beta.APP_IDENTIFIER}, output_file)
    with patch.object(beta, "distribution_blockers", return_value=[]), \
            patch.object(beta, "verify_developer_id_bundle", return_value=signatures()):
        rejected(lambda: create_beta_package(app, output, "zip", source,
                                             producer_notices_sha256=PRODUCER_NOTICES_SHA256,
                                             run_command=fake_runner([])))

print("PASS plist-derived beta archive names, source-bound build number/update gate, optional timestamped DMG, "
      "rights blocker, and no-submit/no-install behavior. "
      "Neutral fixture bytes and mocked platform commands only.")
