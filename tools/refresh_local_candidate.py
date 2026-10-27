#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Refresh local UI source while preserving an explicitly selected signed CLI.

This is not producer-source or release qualification. A missing prior receipt is
recorded, not reconstructed. The preserved CLI never gains lifecycle admission
unless its digest independently matches the app's lifecycle pin.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tarfile
import tempfile

from build_local_candidate import (copy_engine_notice, copy_release_notices, run, source_build_number,
                                   source_identity, validate_host)
from shipping_pair import (CARGO_LOCK_SHA256, CLI_BYTES, CLI_SHA256, WINDOWS_HELPER_BYTES,
                           WINDOWS_HELPER_SHA256, PRODUCER, PRODUCER_TREE,
                           PRODUCER_MANIFEST_SHA256, owned_bytes, require, swift_pins,
                           swift_producer_pins, validate_producer_inventory)
from signing_identity import (command, preflight, sign, verify_developer_id_bundle,
                              verify_designated_requirement)
from package_resources import copy_resources
from distribution_manifest import distribution_blockers, write_manifest



def path_remap(source):
    """REQ-52: build-machine paths never reach shipped binaries (debug, file and Clang prefix maps)."""
    root = str(source)
    return ["-Xswiftc", "-file-prefix-map", "-Xswiftc", root + "=/xode",
            "-Xswiftc", "-debug-prefix-map", "-Xswiftc", root + "=/xode",
            "-Xcc", "-ffile-prefix-map=" + root + "=/xode"]


def strip_debug(path):
    """REQ-52: remove debug symbol entries (object-file paths) before signing."""
    subprocess.run(["/usr/bin/strip", "-S", str(path)], check=True)

def validate_payload_pair(cli, helper, producer, tree):
    require(producer == PRODUCER and tree == PRODUCER_TREE, "Selected producer differs from the approved pin")
    cli_record, cli_bytes = owned_bytes(cli, CLI_SHA256, CLI_BYTES, bounded=512 * 1024 * 1024)
    helper_record, helper_bytes = owned_bytes(helper, WINDOWS_HELPER_SHA256,
                                               WINDOWS_HELPER_BYTES, bounded=16 * 1024 * 1024)
    require(helper_bytes in cli_bytes, "Selected Windows helper differs from actual embedded CLI bytes")
    return cli_record, helper_record


def refresh(installed, output_root, identity, selected_cli=None, producer_source=None, producer_commit=None,
            selected_helper=None, producer_notices=None, producer_notices_sha256=None,
            engine_notice=None):
    validate_host()
    preflight(identity)
    project = Path(__file__).resolve().parent.parent
    source_identity_before = source_identity(project)
    installed = installed.resolve(strict=True)
    require(installed.suffix == ".app", "Select the existing local candidate app")
    require(output_root.is_absolute() and output_root.resolve(strict=True) == output_root,
            "Use a canonical existing output directory")
    info = output_root.stat()
    require(info.st_uid == os.getuid() and info.st_mode & 0o022 == 0, "Unsafe output directory")
    verify_designated_requirement(installed, "app", identity)
    supplied = (selected_cli is not None, producer_source is not None, producer_commit is not None)
    require(all(supplied) or not any(supplied),
            "An explicit CLI needs both its producer source repository and frozen commit")
    require((selected_helper is not None) == (selected_cli is not None),
            "An explicit frozen CLI requires its exact paired Windows helper")
    producer, producer_tree = PRODUCER, PRODUCER_TREE
    if selected_cli is not None:
        producer = subprocess.check_output(
            ["git", "rev-parse", "--verify", producer_commit + "^{commit}"],
            cwd=producer_source, text=True).strip()
        require(producer == producer_commit == PRODUCER, "Select the full approved frozen producer commit")
        producer_tree = subprocess.check_output(
            ["git", "rev-parse", producer + "^{tree}"], cwd=producer_source, text=True).strip()
        require(producer_tree == PRODUCER_TREE, "Selected producer tree differs from the approved pin")
        cargo_lock = subprocess.check_output(
            ["git", "show", producer + ":Cargo.lock"], cwd=producer_source)
        require(hashlib.sha256(cargo_lock).hexdigest() == CARGO_LOCK_SHA256,
                "Selected producer Cargo.lock differs from the approved pin")
        contract = subprocess.check_output(
            ["git", "show", producer + ":docs/contracts/management-v1.schema.json"], cwd=producer_source)
        require(contract == (project / "Sources/XodusManagement/Resources/management-v1.schema.json").read_bytes(),
                "Selected CLI producer and app management contracts differ")
    if producer_notices is not None:
        validate_producer_inventory(Path(producer_notices) / "inventory.json", producer_notices_sha256)
    old_cli = selected_cli.resolve(strict=True) if selected_cli else installed / "Contents/Resources/XodusEngine/xodus-cli"
    old_helper = selected_helper.resolve(strict=True) if selected_helper else old_cli.parent / "xodus-window-monitor.exe"
    cli_record, windows_helper_record = validate_payload_pair(old_cli, old_helper, producer, producer_tree)
    producer_manifest = owned_bytes(old_cli.parent / "build-manifest.json", PRODUCER_MANIFEST_SHA256)[0] \
        if selected_cli is not None else None
    def verify_cli(path):
        command(["/usr/bin/codesign", "--verify", "--strict", "-R",
                 '=certificate leaf = H"' + identity.upper() + '"', str(path)])
    verify_cli(old_cli)
    if selected_cli is not None:
        lifecycle_source = (project / "Sources/XodusPreview/NativeGameLifecycle.swift").read_text()
        require('static let cliSHA256 = "' + cli_record["sha256"] + '"' in lifecycle_source,
                "Selected lifecycle CLI differs from the source's explicit frozen digest")
    stage = Path(tempfile.mkdtemp(prefix="Ode-refresh-", dir=output_root))
    stage.chmod(0o700)
    log = stage / "build.log"
    archive = stage / "source.tar"
    with archive.open("xb") as output:
        subprocess.run(["git", "archive", "--format=tar", source_identity_before["commit"]],
                       cwd=project, stdout=output, check=True)
    source = stage / "source"
    source.mkdir()
    with tarfile.open(archive) as archived:
        archived.extractall(source, filter="data")
    environment = os.environ.copy()
    environment["XODUS_SHIPPING"] = "1"
    run(["swift", "build", "--jobs", "1", "-c", "release", "--product", "XodusAuthHost"] + path_remap(source),
        source, log, environment)
    binary_dir = Path(run(["swift", "build", "-c", "release", "--show-bin-path"] + path_remap(source),
                         source, log, environment).decode().strip())
    app = stage / "X Ode.app"
    macos, resources = app / "Contents/MacOS", app / "Contents/Resources"
    macos.mkdir(parents=True)
    (resources / "XodusEngine").mkdir(parents=True)
    cli = resources / "XodusEngine/xodus-cli"
    shutil.copyfile(old_cli, cli)
    cli.chmod(0o755)
    owned_bytes(cli, cli_record["sha256"], cli_record["bytes"])
    destination = cli.parent / "xodus-window-monitor.exe"
    shutil.copyfile(old_helper, destination)
    destination.chmod(0o644)
    owned_bytes(destination, windows_helper_record["sha256"], windows_helper_record["bytes"])
    helper = macos / "XodusAuthHost"
    shutil.copyfile(binary_dir / "XodusAuthHost", helper)
    helper.chmod(0o755)
    strip_debug(helper)
    sign(helper, "helper", identity, developer_id=True)
    helper_record, _ = owned_bytes(helper)
    (source / "Sources/XodusPreview/ShippingPairPins.swift").write_text(swift_pins(
        source_identity_before["commit"], source_identity_before["tree"], cli_record, helper_record,
        producer, producer_tree))
    require(producer == PRODUCER and producer_tree == PRODUCER_TREE,
            "Selected producer differs from the approved shipping tuple")
    (source / "Sources/XodusPreview/ShippingProducerPins.swift").write_text(swift_producer_pins())
    run(["swift", "build", "--jobs", "1", "-c", "release", "--product", "XodusPreview"] + path_remap(source),
        source, log, environment)
    shutil.copyfile(binary_dir / "XodusPreview", macos / "Xodus")
    (macos / "Xodus").chmod(0o755)
    strip_debug(macos / "Xodus")
    bundle_info = plistlib.loads((source / "tools/Info.plist").read_bytes())
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+",
                         bundle_info.get("CFBundleShortVersionString", "")) is not None,
            "App version must use exactly x.y.z")
    bundle_info["CFBundleName"] = bundle_info["CFBundleDisplayName"] = "X Ode"
    bundle_info["CFBundleVersion"] = str(source_build_number(project))
    bundle_info["XodeReleaseChannel"] = "Beta"
    if environment.get("XODUS_QUALIFICATION") == "1":
        # Installed side by side; never replaces the ordinary candidate.
        bundle_info["CFBundleName"] = bundle_info["CFBundleDisplayName"] = "X Ode Qualification"
        bundle_info["XodeReleaseChannel"] = "Qualification"
        bundle_info["XodeQualificationBuild"] = bundle_info["CFBundleVersion"] + "-qual"
    with (app / "Contents/Info.plist").open("wb") as output:
        plistlib.dump(bundle_info, output)
    copy_release_notices(source, resources)
    engine_notice_record = copy_engine_notice(engine_notice, resources) if engine_notice else None
    shutil.copyfile(installed / "Contents/Resources/Xodus.icns", resources / "Xodus.icns")
    copy_resources(binary_dir / "XodusAppFoundation_XodusManagement.bundle",
                   resources / "XodusAppFoundation_XodusManagement.bundle")
    (resources / "XodusAuthHost.json").write_text(json.dumps({
        "version": 1, "sha256": helper_record["sha256"],
        "sourceCommit": source_identity_before["commit"]}, sort_keys=True) + "\n")
    receipt = {
        "kind": "local-ui-refresh", "productionQualified": False,
        "qualificationVariant": environment.get("XODUS_QUALIFICATION") == "1", "notarized": False,
        "appSource": source_identity_before, "certificateSHA1": identity.upper(),
        "preservedCLI": cli_record,
        "producerBuildPerformed": False, "priorReceiptAvailable": False,
        "producerSourceIndependentlyVerified": False,
        "preservedProducerDeclaration": {"commit": producer, "tree": producer_tree},
        "preservedProducerManifest": producer_manifest,
        "producerCargoLockSHA256": CARGO_LOCK_SHA256,
        "explicitFrozenCLISelected": selected_cli is not None,
        "signedHelper": helper_record,
        "preservedWindowsHelper": windows_helper_record,
    }
    if engine_notice_record:
        receipt["engineNotice"] = engine_notice_record
    previous_receipt = installed / "Contents/Resources/local-candidate-receipt.json"
    if previous_receipt.exists():
        receipt["priorReceiptAvailable"] = True
        receipt["priorReceipt"], _ = owned_bytes(previous_receipt)
    encoded = json.dumps(receipt, indent=2, sort_keys=True) + "\n"
    (resources / "local-candidate-receipt.json").write_text(encoded)
    (stage / "candidate-receipt.json").write_text(encoded)
    write_manifest(app, source_identity_before,
                   {"commit": producer, "tree": producer_tree}, archive, producer_notices,
                   producer_notices_sha256)
    sign(app, "app", identity, developer_id=True)
    run(["codesign", "--verify", "--deep", "--strict", str(app)], source, log)
    verify_cli(cli)
    for path, kind in ((helper, "helper"), (app, "app")):
        verify_designated_requirement(path, kind, identity)
    blockers = distribution_blockers(
        app, producer_notices_sha256, expected_signing_identity=identity)
    signature = verify_developer_id_bundle(app, identity)["app"]
    owned_bytes(old_cli, cli_record["sha256"], cli_record["bytes"])
    require(source_identity(project) == source_identity_before, "App source changed during refresh")
    print("Distribution manifest integrity: PASS")
    print("Signed app CDHash: " + signature["cdhash"])
    print("Signed app team: " + signature["teamIdentifier"])
    if blockers:
        print("Remaining distribution blockers: " + json.dumps(blockers, sort_keys=True))
    print(app)
    print(stage / "candidate-receipt.json")
    return app, stage / "candidate-receipt.json"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--installed-app", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--identity", required=True)
    parser.add_argument("--cli", type=Path)
    parser.add_argument("--producer-source", type=Path)
    parser.add_argument("--producer-commit")
    parser.add_argument("--windows-helper", type=Path)
    parser.add_argument("--producer-notices", type=Path)
    parser.add_argument("--producer-notices-sha256")
    parser.add_argument("--engine-notice", type=Path,
                        help="Plain-text Calimocho NOTICE from the admitted release")
    args = parser.parse_args()
    refresh(args.installed_app, args.output_root, args.identity, args.cli,
            args.producer_source, args.producer_commit, args.windows_helper, args.producer_notices,
            args.producer_notices_sha256, args.engine_notice)
