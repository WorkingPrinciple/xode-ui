#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Create a signed, no-submit beta archive from an already signed app bundle."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import tempfile

from distribution_manifest import distribution_blockers
from shipping_pair import hex_value, owned_bytes, require, unique_object
from signing_identity import verify_developer_id_bundle, verify_developer_id_component

MINIMUM_UPDATE_BUILD = 2
IDENTITY = "410914520BCC840C0125D3826CCF0F247F603321"
TEAM_ID = "M62Z4M5EUY"
APP_IDENTIFIER = "io.github.dragoshont.xodus"
PRODUCER_NOTICES_SHA256 = None
INSTALL_NOTE = """X Ode beta

Verify the adjacent SHA-256 file before opening this archive. The app is signed
with Developer ID, but this package has not been submitted to Apple for
notarization. Do not distribute it as a public end-user release until the
notarization and Gatekeeper checks are completed.

After notarization is completed, move "X Ode.app" into Applications and
launch it from there. Keep this archive and its checksum with the beta record.
"""
RELEASE_NOTES = """X Ode beta release notes

The eappx, msixvc, msixvc-common, xodus, xodus-cli, xodus-management, and
xodus-service workspace crates are licensed under GPL-3.0-only as stated by
the producer repository's root LICENSE. The corresponding source archive
includes that LICENSE.

Known beta limitation: No Man's Sky uses an explicitly configured developer-local engine binding.
On a Mac without that exact tested engine installed, X Ode reports that the engine
is missing and does not substitute another engine.
"""
def run(arguments, timeout=1800):
    result = subprocess.run(arguments, capture_output=True, text=True, timeout=timeout)
    require(result.returncode == 0, "Packaging command failed: " + Path(arguments[0]).name)
    return result.stdout + result.stderr


def read_json(path):
    _, data = owned_bytes(path, bounded=4 * 1024 * 1024)
    return json.loads(data, object_pairs_hook=unique_object)


def app_source(app):
    receipt = read_json(app / "Contents/Resources/local-candidate-receipt.json")
    source = receipt.get("appSource")
    require(type(source) is dict, "App receipt has no source identity")
    commit = hex_value(source.get("commit"), 40)
    tree = hex_value(source.get("tree"), 40)
    return {"commit": commit, "tree": tree}


def release_identity(source, expected_source):
    source = Path(source)
    require(source.is_absolute() and source.resolve(strict=True) == source and source.is_dir(),
            "Source must be a canonical existing Git checkout")

    def git(*arguments):
        return subprocess.check_output(
            ["git", "-C", str(source), *arguments], text=True, stderr=subprocess.PIPE).strip()

    branch = git("branch", "--show-current")
    require(branch == "main" or branch.startswith("release/"),
            "Package releases only from main or a release/* branch")
    require(not git("status", "--porcelain", "--untracked-files=normal"),
            "Package source checkout must be clean")
    commit = hex_value(git("rev-parse", "HEAD"), 40)
    tree = hex_value(git("rev-parse", "HEAD^{tree}"), 40)
    require(commit == expected_source["commit"] and tree == expected_source["tree"],
            "Package source checkout differs from the app receipt")
    build_number = git("rev-list", "--count", "HEAD")
    require(build_number.isdecimal() and int(build_number) > MINIMUM_UPDATE_BUILD,
            "CFBundleVersion must exceed the installed candidate's build 2")
    return {"commit": commit, "tree": tree, "buildNumber": int(build_number)}


def validate_dmg_background(background_image):
    background_record, background_data = owned_bytes(background_image, bounded=20 * 1024 * 1024)
    require(Path(background_image).suffix.lower() in (".tif", ".tiff")
            and background_data[:4] in (b"II*\x00", b"MM\x00*"),
            "DMG background must be a combined HiDPI TIFF image")
    return background_record


def create_installer_dmg(payload, artifact, product_name, identity,
                         background_image, app_bundle, run_command):
    background_record = validate_dmg_background(background_image)
    volume_icon = app_bundle / "Contents/Resources/Xodus.icns"
    icon_record, icon_data = owned_bytes(volume_icon, bounded=8 * 1024 * 1024)
    require(icon_data.startswith(b"icns"), "App volume icon is not a valid ICNS file")
    settings = Path(__file__).with_name("xode_dmg_settings.py").resolve(strict=True)
    app_path = payload / (product_name + ".app")
    run_command([
        "dmgbuild", "-s", str(settings),
        "-D", "app=" + str(app_path),
        "-D", "install_note=" + str(payload / "INSTALL.txt"),
        "-D", "release_notes=" + str(payload / "RELEASE-NOTES.txt"),
        "-D", "background=" + str(background_image),
        "-D", "volume_icon=" + str(volume_icon),
        product_name, str(artifact),
    ])
    run_command(["/usr/bin/codesign", "--force", "--sign", identity.upper(),
                 "--timestamp", "--identifier", APP_IDENTIFIER + ".installer-dmg", str(artifact)])
    run_command(["/usr/bin/codesign", "--verify", "--strict", str(artifact)])
    verify_developer_id_component(artifact, identity, TEAM_ID, run_command,
                                  hardened_runtime=False)
    return {"background": background_record, "volumeIcon": icon_record}


def package_beta(app, output_root, package_format, source, identity=IDENTITY,
                 producer_notices_sha256=None, run_command=run, dmg_background=None):
    app = Path(app)
    output_root = Path(output_root)
    require(app.is_absolute() and app.resolve(strict=True) == app and app.is_dir()
            and app.suffix == ".app" and not app.is_symlink(),
            "App must be a canonical existing .app bundle")
    require(output_root.is_absolute() and output_root.resolve(strict=True) == output_root
            and output_root.is_dir() and not output_root.is_symlink(),
            "Output root must be an existing canonical directory")
    output_stat = output_root.stat()
    require(output_stat.st_uid == os.getuid() and output_stat.st_mode & 0o022 == 0,
            "Output root must be owned by the current user and not writable by others")
    require(package_format in ("zip", "dmg"), "Package format must be zip or dmg")
    require(package_format != "dmg" or dmg_background is not None,
            "A reviewed combined HiDPI TIFF background is required for the installer image")
    if dmg_background is not None:
        validate_dmg_background(dmg_background)
    require(isinstance(identity, str) and identity.upper() == IDENTITY,
            "Use the approved Developer ID certificate leaf")

    _, info_bytes = owned_bytes(app / "Contents/Info.plist", bounded=1_048_576)
    info = plistlib.loads(info_bytes)
    version = info.get("CFBundleShortVersionString")
    require(isinstance(version, str) and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version),
            "App version must use exactly x.y.z")
    channel = info.get("XodeReleaseChannel")
    require(isinstance(channel, str) and re.fullmatch(r"[A-Za-z]+", channel),
            "App release channel is missing or invalid")
    channel_slug = channel.lower()
    product_name = info.get("CFBundleDisplayName")
    require(product_name == "X Ode" and info.get("CFBundleName") == product_name,
            "App bundle display names differ from the product identity")
    require(info.get("CFBundleIdentifier") == APP_IDENTIFIER,
            "App bundle identifier differs from the product identity")
    require(isinstance(PRODUCER_NOTICES_SHA256, str)
            and re.fullmatch(r"[0-9a-f]{64}", PRODUCER_NOTICES_SHA256) is not None
            and producer_notices_sha256 == PRODUCER_NOTICES_SHA256,
            "No current producer-notice inventory is pinned; await the -02 admission rebuild")
    build_number = info.get("CFBundleVersion")
    source_identity = app_source(app)
    release_source = release_identity(source, source_identity)
    require(build_number == str(release_source["buildNumber"]),
            "CFBundleVersion does not match the source commit count")
    notices = app / "Contents/Resources/ProducerNotices"
    require(notices.is_dir() and not notices.is_symlink()
            and (notices / "inventory.json").is_file()
            and not (notices / "inventory.json").is_symlink(),
            "Pinned producer notice inventory is required in the app bundle")
    engine_notice = app / "Contents/Resources/EngineNotices/NOTICE.txt"
    engine_notice_identity, engine_notice_data = owned_bytes(engine_notice, bounded=2 * 1024 * 1024)
    engine_notice_text = engine_notice_data.decode("utf-8")
    require(bool(engine_notice_text.strip()) and "\x00" not in engine_notice_text,
            "Calimocho NOTICE must be non-empty UTF-8 text in the app bundle")
    blockers = distribution_blockers(app, producer_notices_sha256)
    require(not blockers, "Distribution preflight blocked: " + "; ".join(blockers))
    signatures = verify_developer_id_bundle(app, identity, TEAM_ID, run_command)

    artifact_name = (f"{product_name.replace(' ', '-')}-{version}-{channel_slug}"
                     + ("-submission.zip" if package_format == "zip" else ".dmg"))
    artifact_stem = artifact_name.removesuffix("." + package_format)
    package_dir = output_root / (artifact_stem + "-package")
    package_dir.mkdir(mode=0o700, exist_ok=False)
    package_dir.chmod(0o700)
    receipt_path = package_dir / "package-receipt.json"
    receipt = {
        "schemaVersion": 1,
        "state": "packaging",
        "appVersion": version,
        "buildNumber": release_source["buildNumber"],
        "releaseChannel": channel,
        "releaseTag": f"v{version}-{channel_slug}.1",
        "appSource": source_identity,
        "producerNoticesSHA256": producer_notices_sha256,
        "engineNotice": engine_notice_identity,
        "certificateSha1": identity.upper(),
        "teamIdentifier": TEAM_ID,
        "format": package_format,
        "notarization": "NOT_SUBMITTED",
        "installed": False,
        "launched": False,
        "signatures": signatures,
        "artifacts": {},
    }
    write_receipt(receipt_path, receipt)
    try:
        with tempfile.TemporaryDirectory(prefix="xodus-beta-", dir=package_dir) as temporary:
            staging = Path(temporary)
            payload = staging / artifact_stem
            payload.mkdir(mode=0o700)
            packaged_app = payload / (product_name + ".app")
            run_command(["/usr/bin/ditto", str(app), str(packaged_app)])
            run_command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(packaged_app)])
            signatures = verify_developer_id_bundle(packaged_app, identity, TEAM_ID, run_command)
            (payload / "INSTALL.txt").write_text(INSTALL_NOTE, encoding="utf-8")
            (payload / "RELEASE-NOTES.txt").write_text(RELEASE_NOTES, encoding="utf-8")

            artifact = output_root / artifact_name
            if package_format == "zip":
                run_command(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc",
                             "--keepParent", str(payload), str(artifact)])
            else:
                design_records = create_installer_dmg(
                    payload, artifact, product_name, identity, dmg_background, app, run_command)

            artifact_identity = identify_file(artifact)
            digest = artifact_identity["sha256"]
            checksum_path = output_root / (artifact.name + ".sha256")
            checksum_path.write_text(digest + "  " + artifact.name + "\n", encoding="ascii")
            receipt["signatures"] = signatures
            receipt["artifacts"] = {
                "package": {"file": artifact.name, **artifact_identity},
                "sha256": digest,
                "checksumFile": checksum_path.name,
                "installNote": "INSTALL.txt (included in package)",
            }
            if package_format == "dmg":
                receipt["artifacts"].update(design_records)
            receipt["state"] = "prepared_not_submitted"
            write_receipt(receipt_path, receipt)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        receipt["state"] = "failed"
        receipt["error"] = type(error).__name__ + ": " + str(error)
        write_receipt(receipt_path, receipt)
        raise
    return receipt_path


def write_receipt(path, receipt):
    temporary = path.with_suffix(".tmp")
    with temporary.open("w", encoding="utf-8") as output:
        json.dump(receipt, output, indent=2, sort_keys=True)
        output.write("\n")
    temporary.chmod(0o600)
    temporary.replace(path)


def identify_file(path):
    path = Path(path)
    require(path.resolve(strict=True) == path and not path.is_symlink(),
            "Package artifact path is not canonical")
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
                         | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NONBLOCK", 0))
    try:
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1
                and before.st_uid == os.getuid() and before.st_mode & 0o022 == 0,
                "Package artifact ownership or mode is unsafe")
        digest = hashlib.sha256()
        with os.fdopen(descriptor, "rb", closefd=False) as source:
            while chunk := source.read(1024 * 1024):
                digest.update(chunk)
        after = os.fstat(descriptor)
        key = lambda item: (item.st_dev, item.st_ino, item.st_mode, item.st_uid, item.st_nlink,
                            item.st_size, item.st_mtime_ns, item.st_ctime_ns)
        require(key(before) == key(after), "Package artifact changed during hashing")
        return {"sha256": digest.hexdigest(), "bytes": before.st_size}
    finally:
        os.close(descriptor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True,
                        help="Clean main or release/* checkout matching the app receipt")
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--format", choices=("zip", "dmg"), required=True)
    parser.add_argument("--identity", default=IDENTITY)
    parser.add_argument("--producer-notices-sha256", required=True,
                        help="Independently reviewed exact producer inventory digest")
    parser.add_argument("--dmg-background", type=Path,
                        help="Approved PNG background art required when --format dmg")
    arguments = parser.parse_args()
    receipt = package_beta(arguments.app, arguments.output_root, arguments.format, arguments.source,
                           arguments.identity,
                           arguments.producer_notices_sha256, dmg_background=arguments.dmg_background)
    print(receipt)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
        raise SystemExit("Beta packaging blocked: " + str(error))
