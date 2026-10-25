#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Create a signed, no-submit beta archive from an already signed app bundle."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import tempfile

from distribution_manifest import distribution_blockers
from shipping_pair import hex_value, owned_bytes, require, unique_object
from signing_identity import verify_developer_id_bundle, verify_developer_id_component

VERSION = "0.11.4"
IDENTITY = "410914520BCC840C0125D3826CCF0F247F603321"
TEAM_ID = "M62Z4M5EUY"
APP_IDENTIFIER = "io.github.dragoshont.xodus"
ARTIFACT_STEM = "Ode-to-X-beta-" + VERSION
INSTALL_NOTE = """Ode to X beta 0.11.4

Verify the adjacent SHA-256 file before opening this archive. The app is signed
with Developer ID, but this package has not been submitted to Apple for
notarization. Do not distribute it as a public end-user release until the
notarization and Gatekeeper checks are completed.

After notarization is completed, move "Ode to X.app" into Applications and
launch it from there. Keep this archive and its checksum with the beta record.
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


def package_beta(app, output_root, package_format, identity=IDENTITY,
                 producer_notices_sha256=None, run_command=run):
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
    require(isinstance(identity, str) and identity.upper() == IDENTITY,
            "Use the approved Developer ID certificate leaf")

    _, info_bytes = owned_bytes(app / "Contents/Info.plist", bounded=1_048_576)
    info = plistlib.loads(info_bytes)
    require(info.get("CFBundleShortVersionString") == VERSION,
            "App bundle is not version " + VERSION)
    require(info.get("CFBundleIdentifier") == APP_IDENTIFIER,
            "App bundle identifier differs from the product identity")
    source_identity = app_source(app)
    blockers = distribution_blockers(app, producer_notices_sha256)
    require(not blockers, "Distribution preflight blocked: " + "; ".join(blockers))
    signatures = verify_developer_id_bundle(app, identity, TEAM_ID, run_command)

    package_dir = output_root / (ARTIFACT_STEM + "." + package_format)
    package_dir.mkdir(mode=0o700, exist_ok=False)
    package_dir.chmod(0o700)
    receipt_path = package_dir / "package-receipt.json"
    receipt = {
        "schemaVersion": 1,
        "state": "packaging",
        "version": VERSION,
        "appSource": source_identity,
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
            payload = staging / ARTIFACT_STEM
            payload.mkdir(mode=0o700)
            packaged_app = payload / "Ode to X.app"
            run_command(["/usr/bin/ditto", str(app), str(packaged_app)])
            run_command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(packaged_app)])
            signatures = verify_developer_id_bundle(packaged_app, identity, TEAM_ID, run_command)
            (payload / "INSTALL.txt").write_text(INSTALL_NOTE, encoding="utf-8")

            artifact = package_dir / (ARTIFACT_STEM + "." + package_format)
            if package_format == "zip":
                run_command(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc",
                             "--keepParent", str(payload), str(artifact)])
            else:
                run_command(["/usr/bin/hdiutil", "create", "-volname", "Ode to X beta " + VERSION,
                             "-srcfolder", str(payload), "-format", "UDZO", str(artifact)])
                run_command(["/usr/bin/codesign", "--force", "--sign", identity.upper(),
                             "--timestamp", "--identifier", APP_IDENTIFIER + ".beta." + VERSION,
                             str(artifact)])
                run_command(["/usr/bin/codesign", "--verify", "--strict", str(artifact)])
                verify_developer_id_component(artifact, identity, TEAM_ID, run_command,
                                              hardened_runtime=False)

            artifact_identity = identify_file(artifact)
            digest = artifact_identity["sha256"]
            checksum_path = package_dir / (artifact.name + ".sha256")
            checksum_path.write_text(digest + "  " + artifact.name + "\n", encoding="ascii")
            receipt["signatures"] = signatures
            receipt["artifacts"] = {
                "package": {"file": artifact.name, **artifact_identity},
                "sha256": digest,
                "checksumFile": checksum_path.name,
                "installNote": "INSTALL.txt (included in package)",
            }
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
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--format", choices=("zip", "dmg"), required=True)
    parser.add_argument("--identity", default=IDENTITY)
    parser.add_argument("--producer-notices-sha256",
                        help="Independently reviewed exact producer inventory digest")
    arguments = parser.parse_args()
    receipt = package_beta(arguments.app, arguments.output_root, arguments.format, arguments.identity,
                           arguments.producer_notices_sha256)
    print(receipt)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
        raise SystemExit("Beta packaging blocked: " + str(error))
