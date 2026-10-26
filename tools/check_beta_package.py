#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Neutral regressions for beta packaging; no OS signing or external submission."""
import hashlib
import json
from pathlib import Path
import plistlib
import runpy
import shutil
import subprocess
import tempfile
from unittest.mock import patch

import package_beta as beta
from package_beta import (IDENTITY, TEAM_ID,
                         package_beta as create_beta_package)

PRODUCER_NOTICES_SHA256 = "a" * 64
PRODUCER_SOURCE_ARCHIVE_BYTES = b"Neutral private tester source archive"
PRODUCER_SOURCE_ARCHIVE_SHA256 = hashlib.sha256(PRODUCER_SOURCE_ARCHIVE_BYTES).hexdigest()
assert beta.PRODUCER_NOTICES_SHA256 == (
    "ec3d8e79fe0472c84356cbc2285fa3ff2fb1ea65c481d58bc6e190cc27b15066")
assert beta.PRODUCER_SOURCE_COMMIT == "99e20addf88932de7796fc966fe09e00b71e4981"
assert beta.PRODUCER_SOURCE_TREE == "7f9e8cc5bd10f696ea508f0ff9f2da3a7eaf2e91"
assert beta.PRODUCER_SOURCE_ARCHIVE_SHA256 == (
    "d67b903137c96479298a139374d5bdf988db4f64ee971588183584bf520e4fdd")
assert beta.PRODUCER_SOURCE_ARCHIVE_BYTES == 9_574_400
beta.PRODUCER_NOTICES_SHA256 = PRODUCER_NOTICES_SHA256
beta.PRODUCER_SOURCE_ARCHIVE_SHA256 = PRODUCER_SOURCE_ARCHIVE_SHA256
beta.PRODUCER_SOURCE_ARCHIVE_BYTES = len(PRODUCER_SOURCE_ARCHIVE_BYTES)

settings = runpy.run_path(str(Path(__file__).with_name("xode_dmg_settings.py")),
                          init_globals={"defines": {
                              "app": "/tmp/X Ode.app", "install_note": "/tmp/INSTALL.txt",
                              "release_notes": "/tmp/RELEASE-NOTES.txt",
                              "volume_icon": "/tmp/X Ode.icns", "background": "/tmp/background.tiff",
                          }})
assert settings["volume_name"] == "X Ode" and settings["filesystem"] == "APFS"
assert settings["format"] == "ULFO" and settings["window_rect"] == ((100, 100), (660, 400))
assert settings["icon_size"] == 128 and settings["symlinks"] == {"Applications": "/Applications"}
assert settings["icon_locations"]["X Ode.app"] == (165, 190)
assert settings["icon_locations"]["Applications"] == (495, 190)
assert settings["background"] == "/tmp/background.tiff"
with (Path(__file__).with_name("Info.plist")).open("rb") as source_info_file:
    source_info = plistlib.load(source_info_file)
assert source_info["CFBundleIdentifier"] == beta.APP_BUNDLE_IDENTIFIER
assert beta.APP_SIGNING_IDENTIFIER == "io.github.dragoshont.xodus"


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
                       "CFBundleIdentifier": beta.APP_BUNDLE_IDENTIFIER}, output)
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
    producer_source_archive = root / "producer-source.tar"
    producer_source_archive.write_bytes(PRODUCER_SOURCE_ARCHIVE_BYTES)
    return app, output, source, producer_source_archive


def signatures():
    return {
        "app": {"identifier": beta.APP_SIGNING_IDENTIFIER, "teamIdentifier": TEAM_ID,
                "certificateSha1": IDENTITY, "hardenedRuntime": True, "secureTimestamp": True},
        "Contents/MacOS/Xodus": {"identifier": beta.APP_SIGNING_IDENTIFIER,
                "teamIdentifier": TEAM_ID, "certificateSha1": IDENTITY,
                "hardenedRuntime": True, "secureTimestamp": True},
    }


def fake_runner(calls):
    def run(arguments):
        arguments = list(map(str, arguments))
        calls.append(arguments)
        if arguments[0] == "/usr/bin/ditto" and len(arguments) == 3:
            shutil.copytree(arguments[1], arguments[2])
            if arguments[1].endswith(".app"):
                with (Path(arguments[2]) / "Contents/Info.plist").open("rb") as info_file:
                    packaged_info = plistlib.load(info_file)
                assert packaged_info["CFBundleIdentifier"] == beta.APP_BUNDLE_IDENTIFIER
        elif arguments[0] == "/usr/bin/ditto" and "-c" in arguments:
            payload = Path(arguments[-2])
            assert (payload / "INSTALL.txt").is_file()
            assert (payload / "RELEASE-NOTES.txt").read_text(encoding="utf-8") == beta.RELEASE_NOTES
            assert (payload / "X Ode.app").is_dir()
            assert (payload / "PRIVATE-TESTER-SOURCE.tar").read_bytes() == (
                PRODUCER_SOURCE_ARCHIVE_BYTES)
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
    app, output, source, producer_source_archive = fixture(root)
    commands = []
    with patch.object(beta, "distribution_blockers", return_value=[]) as blockers, \
            patch.object(beta, "verify_developer_id_bundle", return_value=signatures()):
        receipt_path = create_beta_package(app, output, "zip", source,
                                           producer_notices_sha256=PRODUCER_NOTICES_SHA256,
                                           run_command=fake_runner(commands),
                                           producer_source_archive=producer_source_archive)
        assert blockers.call_args.args == (app, PRODUCER_NOTICES_SHA256)
    receipt = json.loads(receipt_path.read_text())
    artifact_path = output / "X-Ode-0.2.0-beta-private-testers.zip"
    checksum_path = output / (artifact_path.name + ".sha256")
    assert receipt["state"] == "prepared_not_submitted"
    assert receipt["distributionScope"] == "private-testers-only"
    assert receipt["publicUpload"] is False
    assert receipt["appVersion"] == "0.2.0"
    assert receipt["releaseChannel"] == "Beta"
    assert receipt["releaseTag"] == "v0.2.0-beta.1"
    assert receipt["buildNumber"] == 3
    assert receipt["notarization"] == "NOT_SUBMITTED"
    assert receipt["installed"] is False and receipt["launched"] is False
    assert receipt["producerNoticesSHA256"] == PRODUCER_NOTICES_SHA256
    assert receipt["producerSourceArchive"] == {
        "file": "PRIVATE-TESTER-SOURCE.tar",
        "sourceCommit": beta.PRODUCER_SOURCE_COMMIT,
        "sourceTree": beta.PRODUCER_SOURCE_TREE,
        "sha256": PRODUCER_SOURCE_ARCHIVE_SHA256,
        "bytes": len(PRODUCER_SOURCE_ARCHIVE_BYTES),
        "audience": "private-testers-only",
        "checksumFile": "PRIVATE-TESTER-SOURCE.tar.sha256",
    }
    private_source = receipt_path.parent / "PRIVATE-TESTER-SOURCE.tar"
    assert private_source.read_bytes() == PRODUCER_SOURCE_ARCHIVE_BYTES
    assert (receipt_path.parent / "PRIVATE-TESTER-SOURCE.tar.sha256").read_text() == (
        PRODUCER_SOURCE_ARCHIVE_SHA256 + "  PRIVATE-TESTER-SOURCE.tar\n")
    assert private_source.stat().st_mode & 0o777 == 0o600
    assert "developer-local engine binding" in beta.RELEASE_NOTES
    assert "does not substitute another engine" in beta.RELEASE_NOTES
    assert "In-game voice chat and microphone input aren't supported in this beta." in beta.RELEASE_NOTES
    assert receipt["artifacts"]["sha256"] == hashlib.sha256(artifact_path.read_bytes()).hexdigest()
    assert checksum_path.read_text() == receipt["artifacts"]["sha256"] + "  " + artifact_path.name + "\n"
    assert not any(any(name in command[0] for name in ("notarytool", "stapler", "launchctl"))
                   or command[0] == "/usr/bin/open" for command in commands)
    assert (receipt_path.parent / "package-receipt.json").exists()

    wrong_source = root / "wrong-producer-source.tar"
    wrong_source.write_bytes(b"Not the approved source archive")
    rejected(lambda: create_beta_package(app, output, "zip", source,
                                         producer_notices_sha256=PRODUCER_NOTICES_SHA256,
                                         run_command=fake_runner([]),
                                         producer_source_archive=wrong_source))
    rejected(lambda: create_beta_package(app, output, "zip", source,
                                         producer_notices_sha256=PRODUCER_NOTICES_SHA256,
                                         run_command=fake_runner([])))

    inventory_path = app / "Contents/Resources/ProducerNotices/inventory.json"
    inventory_bytes = inventory_path.read_bytes()
    inventory_path.unlink()
    with patch.object(beta, "distribution_blockers", return_value=[]), \
            patch.object(beta, "verify_developer_id_bundle", return_value=signatures()):
        rejected(lambda: create_beta_package(app, output, "zip", source,
                                             producer_notices_sha256=PRODUCER_NOTICES_SHA256,
                                             run_command=fake_runner([]),
                                             producer_source_archive=producer_source_archive))
    inventory_path.write_bytes(inventory_bytes)

    info_path = app / "Contents/Info.plist"
    info_bytes = info_path.read_bytes()
    wrong_info = plistlib.loads(info_bytes)
    wrong_info["CFBundleIdentifier"] = beta.APP_SIGNING_IDENTIFIER
    with info_path.open("wb") as output_file:
        plistlib.dump(wrong_info, output_file)
    with patch.object(beta, "distribution_blockers", return_value=[]), \
            patch.object(beta, "verify_developer_id_bundle", return_value=signatures()):
        rejected(lambda: create_beta_package(app, output, "zip", source,
                                             producer_notices_sha256=PRODUCER_NOTICES_SHA256,
                                             run_command=fake_runner([]),
                                             producer_source_archive=producer_source_archive))
    info_path.write_bytes(info_bytes)

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
                                               dmg_background=background,
                                               producer_source_archive=producer_source_archive)
    dmg_receipt = json.loads(dmg_receipt_path.read_text())
    assert dmg_receipt["format"] == "dmg"
    assert (output / "X-Ode-0.2.0-beta-private-testers.dmg").is_file()
    assert (dmg_receipt_path.parent / "PRIVATE-TESTER-SOURCE.tar").read_bytes() == (
        PRODUCER_SOURCE_ARCHIVE_BYTES)
    assert dmg_receipt["artifacts"]["background"]["sha256"] == hashlib.sha256(
        background.read_bytes()).hexdigest()
    assert dmg_receipt["artifacts"]["volumeIcon"]["sha256"] == hashlib.sha256(
        (app / "Contents/Resources/Xodus.icns").read_bytes()).hexdigest()
    dmg_command = next(command for command in commands if command[0] == "dmgbuild")
    assert any(value.startswith("app=") and value.endswith("/X Ode.app") for value in dmg_command)
    dmg_signing = next(command for command in commands
                       if command[0] == "/usr/bin/codesign" and "--timestamp" in command)
    assert dmg_signing[dmg_signing.index("--identifier") + 1] == (
        beta.APP_SIGNING_IDENTIFIER + ".installer-dmg")
    assert not any(any(name in command[0] for name in ("notarytool", "stapler", "launchctl"))
                   or command[0] == "/usr/bin/open" for command in commands)

    with patch.object(beta, "distribution_blockers", return_value=["Unresolved rights"]), \
            patch.object(beta, "verify_developer_id_bundle", return_value=signatures()):
        rejected(lambda: create_beta_package(app, output, "zip", source,
                                             producer_notices_sha256=PRODUCER_NOTICES_SHA256,
                                             run_command=fake_runner([]),
                                             producer_source_archive=producer_source_archive))

    rejected(lambda: create_beta_package(app, output, "dmg", source,
                                         producer_notices_sha256=PRODUCER_NOTICES_SHA256,
                                         run_command=fake_runner([]),
                                         producer_source_archive=producer_source_archive))

    with patch.object(beta, "PRODUCER_NOTICES_SHA256", None):
        rejected(lambda: create_beta_package(app, output, "zip", source,
                                             producer_notices_sha256=PRODUCER_NOTICES_SHA256,
                                             run_command=fake_runner([]),
                                             producer_source_archive=producer_source_archive))

    with (app / "Contents/Info.plist").open("wb") as output_file:
        plistlib.dump({"CFBundleName": "X Ode", "CFBundleDisplayName": "X Ode",
                       "CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "2",
                       "XodeReleaseChannel": "Beta",
                       "CFBundleIdentifier": beta.APP_BUNDLE_IDENTIFIER}, output_file)
    with patch.object(beta, "distribution_blockers", return_value=[]), \
            patch.object(beta, "verify_developer_id_bundle", return_value=signatures()):
        rejected(lambda: create_beta_package(app, output, "zip", source,
                                             producer_notices_sha256=PRODUCER_NOTICES_SHA256,
                                             run_command=fake_runner([]),
                                             producer_source_archive=producer_source_archive))

print("PASS plist-derived beta archive names, source-bound build number/update gate, optional timestamped DMG, "
      "rights blocker, and no-submit/no-install behavior. "
      "Neutral fixture bytes and mocked platform commands only.")
