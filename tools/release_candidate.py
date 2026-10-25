#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Build a pinned local candidate; explicitly submit app/DMG only outside --dry-run.

Never installs, opens, activates, or edits an existing app. The single external
receipt records all observed commands, including failures and unexecuted gates.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

from build_local_candidate import source_identity
from refresh_local_candidate import refresh
from shipping_pair import (CLI_SHA256, WINDOWS_HELPER_SHA256 as HELPER_SHA256,
                           PRODUCER as PRODUCER_COMMIT, PRODUCER_TREE, PRODUCER_MANIFEST_SHA256,
                           hex_value, owned_bytes, require, unique_object)
from signing_identity import verify_designated_requirement
from distribution_manifest import require_distribution_ready, distribution_blockers
from package_beta import (INSTALL_NOTE, PRODUCER_NOTICES_SHA256, RELEASE_NOTES,
                          create_installer_dmg, validate_dmg_background)


def read_json(path):
    _, data = owned_bytes(path, bounded=4 * 1024 * 1024)
    return json.loads(data, object_pairs_hook=unique_object)


def validate_engine_notice(path):
    identity, data = owned_bytes(path, bounded=2 * 1024 * 1024)
    text = data.decode("utf-8")
    require(bool(text.strip()) and "\x00" not in text,
            "Calimocho NOTICE must be non-empty UTF-8 text")
    return identity


def frozen_payloads(candidate, approved_unnotarized_cli=None):
    manifest_identity, _ = owned_bytes(candidate / "build-manifest.json", PRODUCER_MANIFEST_SHA256)
    manifest = read_json(candidate / "build-manifest.json")
    require(manifest["source_commit"] == PRODUCER_COMMIT and manifest["source_tree"] == PRODUCER_TREE,
            "Unexpected frozen producer source")
    require(manifest["binary_sha256"] == CLI_SHA256
            and manifest["helper_sha256"] == HELPER_SHA256
            and manifest["helper_embedded_bytes_verified"] is True,
            "Frozen payload receipts do not agree")
    cli, helper = candidate / "xodus-cli", candidate / "xodus-window-monitor.exe"
    cli_identity, cli_bytes = owned_bytes(cli, CLI_SHA256, bounded=512 * 1024 * 1024)
    helper_identity, helper_bytes = owned_bytes(helper, HELPER_SHA256, bounded=16 * 1024 * 1024)
    require(helper_bytes in cli_bytes, "Adjacent Windows helper differs from actual embedded CLI bytes")
    if not (candidate / "notarization/receipt.json").exists():
        require(manifest.get("notarization", {}).get("status") == "NOT_SUBMITTED",
                "Missing accepted standalone notarization receipt")
        require(approved_unnotarized_cli == CLI_SHA256,
                "Standalone notarization is pending: owner approval of this exact CLI/helper/manifest tuple "
                "requires --approve-unnotarized-cli " + CLI_SHA256)
        require(manifest["notarization"].get("submission_id") is None
                and manifest["notarization"].get("accepted_receipt") is None,
                "Unnotarized producer must not claim an Apple acceptance")
        return cli, helper, {
            "cli": cli_identity, "windowsHelper": helper_identity,
            "producerCommit": PRODUCER_COMMIT, "producerTree": PRODUCER_TREE,
            "buildManifest": manifest_identity, "standaloneNotarized": False,
            "combinedAppleSubmission": None, "outerAppNotarizationRequired": True,
            "explicitUnnotarizedCLIApproval": approved_unnotarized_cli,
        }
    notarization = read_json(candidate / "notarization/receipt.json")
    require(notarization["source_commit"] == PRODUCER_COMMIT
            and notarization["cli_sha256"] == CLI_SHA256
            and notarization["helper_sha256"] == HELPER_SHA256
            and notarization["immutable_payloads_unchanged"] is True,
            "Frozen notarization receipt does not agree")
    submission = notarization["combined_payload_submission"]
    require(submission["status"] == "Accepted", "CLI/helper combined notarization was not accepted")
    require(isinstance(submission["receipt"], str)
            and Path(submission["receipt"]).name == submission["receipt"],
            "Apple submission receipt must be adjacent to the notarization receipt")
    apple = read_json(candidate / "notarization" / submission["receipt"])
    require(apple["id"] == submission["id"] and apple["status"] == "Accepted",
            "Apple combined-payload submission does not match the producer receipt")
    return cli, helper, {"cli": cli_identity, "windowsHelper": helper_identity,
                         "producerCommit": PRODUCER_COMMIT, "producerTree": PRODUCER_TREE,
                         "buildManifest": manifest_identity,
                         "standaloneNotarized": True, "outerAppNotarizationRequired": True,
                         "notarizationReceipt": owned_bytes(candidate / "notarization/receipt.json")[0],
                         "combinedAppleSubmission": apple["id"]}


def write_receipt(path, receipt):
    temporary = path.with_suffix(".tmp")
    with temporary.open("w", encoding="utf-8") as output:
        json.dump(receipt, output, indent=2, sort_keys=True)
        output.write("\n")
    temporary.chmod(0o600)
    temporary.replace(path)


def release_branch(project):
    return subprocess.check_output(["git", "-C", str(project), "branch", "--show-current"],
                                   text=True).strip()


def execute(arguments, stage, receipt, receipt_path, label, timeout=1800):
    log = stage / (label + ".log")
    record = {"command": list(map(str, arguments)), "log": str(log), "exitCode": None}
    receipt["commands"].append(record)
    write_receipt(receipt_path, receipt)
    with log.open("xb") as output:
        result = subprocess.run(arguments, stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
    record["exitCode"] = result.returncode
    write_receipt(receipt_path, receipt)
    require(result.returncode == 0, "Release command failed: " + label + "; inspect " + str(log))
    return log


def notarize(path, stage, receipt, receipt_path, label, profile):
    # Keep Apple's JSON stdout separate from diagnostics so parsing cannot
    # accidentally treat a warning or progress line as an acceptance receipt.
    output = stage / (label + "-submission.json")
    command = ["/usr/bin/xcrun", "notarytool", "submit", str(path), "--keychain-profile", profile,
               "--wait", "--output-format", "json"]
    record = {"command": command, "log": str(stage / (label + "-stderr.log")),
              "submission": str(output), "exitCode": None}
    receipt["commands"].append(record)
    write_receipt(receipt_path, receipt)
    with output.open("xb") as stdout, Path(record["log"]).open("xb") as stderr:
        result = subprocess.run(command, stdout=stdout, stderr=stderr, timeout=3600)
    record["exitCode"] = result.returncode
    write_receipt(receipt_path, receipt)
    require(result.returncode == 0, "Notary submission failed; inspect " + str(output))
    submission = read_json(output)
    require(isinstance(submission.get("id"), str), "Missing Apple submission ID")
    record["submissionID"], record["status"] = submission["id"], submission.get("status")
    write_receipt(receipt_path, receipt)
    if submission.get("status") != "Accepted":
        execute(["/usr/bin/xcrun", "notarytool", "log", submission["id"],
                 "--keychain-profile", profile], stage, receipt, receipt_path, label + "-apple-log")
        raise ValueError("Apple did not accept " + label + "; inspect its submission and Apple log")
    return submission


def distribute(app, stage, receipt, receipt_path, identity, profile, producer_notices_sha256=None,
               dmg_background=None):
    require(isinstance(PRODUCER_NOTICES_SHA256, str)
            and re.fullmatch(r"[0-9a-f]{64}", PRODUCER_NOTICES_SHA256) is not None
            and producer_notices_sha256 == PRODUCER_NOTICES_SHA256,
            "No current producer-notice inventory is pinned; await the -02 admission rebuild")
    require_distribution_ready(app, producer_notices_sha256)
    engine_notice = validate_engine_notice(app / "Contents/Resources/EngineNotices/NOTICE.txt")
    require(engine_notice == receipt.get("engineNotice"),
            "Calimocho NOTICE differs from the signed dry-run candidate")
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    version, channel = info.get("CFBundleShortVersionString"), info.get("XodeReleaseChannel")
    require(isinstance(version, str) and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version)
            and isinstance(channel, str) and re.fullmatch(r"[A-Za-z]+", channel),
            "App release version or channel is invalid")
    channel_slug = channel.lower()
    product_name = info.get("CFBundleDisplayName")
    require(product_name == "X Ode" and info.get("CFBundleName") == product_name,
            "App display name differs from the product identity")
    build_number = info.get("CFBundleVersion")
    require(isinstance(build_number, str) and build_number.isdecimal(),
            "App build number is invalid")
    background_identity = validate_dmg_background(dmg_background)
    require(background_identity == receipt.get("dmgBackground"),
            "DMG background differs from the reviewed dry-run asset")
    receipt.update({"appVersion": version, "buildNumber": int(build_number),
                    "releaseChannel": channel,
                    "releaseTag": f"v{version}-{channel_slug}.1"})
    write_receipt(receipt_path, receipt)
    archive = stage / f"X-Ode-{version}-{channel_slug}-submission.zip"
    execute(["/usr/bin/ditto", "-c", "-k", "--keepParent", str(app), str(archive)],
            stage, receipt, receipt_path, "app-archive")
    receipt["artifacts"]["appSubmissionArchive"] = {"path": str(archive), **owned_bytes(archive)[0]}
    write_receipt(receipt_path, receipt)
    receipt["appSubmission"] = notarize(archive, stage, receipt, receipt_path, "app", profile)
    for verb in ("staple", "validate"):
        execute(["/usr/bin/xcrun", "stapler", verb, str(app)],
                stage, receipt, receipt_path, "app-stapler-" + verb)
    execute(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
            stage, receipt, receipt_path, "stapled-app-signature")
    execute(["/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=4", str(app)],
            stage, receipt, receipt_path, "app-gatekeeper")
    distribution = stage / "distribution"
    distribution.mkdir(mode=0o700)
    distribution_app = distribution / app.name
    execute(["/usr/bin/ditto", str(app), str(distribution_app)],
            stage, receipt, receipt_path, "distribution-app-copy")
    execute(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(distribution_app)],
            stage, receipt, receipt_path, "distribution-app-signature")
    (distribution / "INSTALL.txt").write_text(INSTALL_NOTE, encoding="utf-8")
    (distribution / "RELEASE-NOTES.txt").write_text(RELEASE_NOTES, encoding="utf-8")
    dmg = stage / f"X-Ode-{version}-{channel_slug}.dmg"
    def run_dmg_command(arguments):
        if arguments[0] == "dmgbuild":
            label = "dmg-create"
        elif arguments[0] == "/usr/bin/codesign" and "--force" in arguments:
            label = "dmg-sign"
        elif arguments[0] == "/usr/bin/codesign":
            label = "dmg-signature"
        else:
            label = "dmg-component-signature"
        execute(arguments, stage, receipt, receipt_path, label)
    dmg_design = create_installer_dmg(distribution, dmg, product_name, identity,
                                      dmg_background, app, run_dmg_command)
    receipt["artifacts"]["dmgSubmittedBytes"] = {"path": str(dmg), **owned_bytes(dmg)[0]}
    receipt["artifacts"]["dmgBackground"] = dmg_design["background"]
    receipt["artifacts"]["dmgVolumeIcon"] = dmg_design["volumeIcon"]
    write_receipt(receipt_path, receipt)
    receipt["dmgSubmission"] = notarize(dmg, stage, receipt, receipt_path, "dmg", profile)
    for verb in ("staple", "validate"):
        execute(["/usr/bin/xcrun", "stapler", verb, str(dmg)],
                stage, receipt, receipt_path, "dmg-stapler-" + verb)
    execute(["/usr/bin/codesign", "--verify", "--strict", str(dmg)],
            stage, receipt, receipt_path, "stapled-dmg-signature")
    execute(["/usr/sbin/spctl", "--assess", "--type", "open", "--context",
             "context:primary-signature", "--verbose=4", str(dmg)],
            stage, receipt, receipt_path, "dmg-gatekeeper")
    receipt["artifacts"]["dmg"] = {"path": str(dmg), **owned_bytes(dmg)[0]}
    receipt["notarized"], receipt["state"] = True, "notarized_candidate"
    receipt["unexecutedGates"] = ["install/activation", "app_e2e"]
    write_receipt(receipt_path, receipt)


def resume(receipt_path, profile, approved_unnotarized_cli=None, producer_notices_sha256=None,
           dmg_background=None):
    require(isinstance(PRODUCER_NOTICES_SHA256, str)
            and re.fullmatch(r"[0-9a-f]{64}", PRODUCER_NOTICES_SHA256) is not None
            and producer_notices_sha256 == PRODUCER_NOTICES_SHA256,
            "No current producer-notice inventory is pinned; await the -02 admission rebuild")
    receipt = read_json(receipt_path)
    stage = receipt_path.parent
    require(receipt["version"] == 1 and receipt["state"] == "signed_dry_run_complete"
            and receipt["dryRun"] is True and receipt["notarized"] is False
            and receipt["installed"] is False and receipt["activated"] is False,
            "Only an untouched successful signed dry-run can be submitted; reconcile partial submissions explicitly")
    require(profile == receipt["notaryProfile"], "Use the dry-run's admitted notary profile")
    app = Path(receipt["artifacts"]["app"]["path"])
    require(app.resolve(strict=True) == app and app.is_relative_to(stage), "App must remain in its owned dry-run stage")
    require(validate_engine_notice(app / "Contents/Resources/EngineNotices/NOTICE.txt")
            == receipt.get("engineNotice"),
            "Calimocho NOTICE differs from the signed dry-run candidate")
    require(dmg_background is not None, "Supply the reviewed X Ode DMG background PNG")
    background_identity = validate_dmg_background(dmg_background)
    require(background_identity == receipt.get("dmgBackground"),
            "DMG background differs from the reviewed dry-run asset")
    for name, relative in (("launcher", "Contents/MacOS/Xodus"),
                           ("authenticationHelper", "Contents/MacOS/XodusAuthHost"),
                           ("resourceSeal", "Contents/_CodeSignature/CodeResources"),
                           ("bundledCLI", "Contents/Resources/XodusEngine/xodus-cli"),
                           ("bundledWindowsHelper", "Contents/Resources/XodusEngine/xodus-window-monitor.exe")):
        expected = receipt["artifacts"][name]
        owned_bytes(app / relative, expected["sha256"], expected["bytes"])
    expected = receipt["sealedAppResourceReceipt"]
    owned_bytes(app / "Contents/Resources/local-candidate-receipt.json", expected["sha256"], expected["bytes"])
    embedded = read_json(app / "Contents/Resources/local-candidate-receipt.json")
    require(embedded["appSource"] == receipt["appSource"]
            and embedded["preservedCLI"]["sha256"] == CLI_SHA256
            and embedded["preservedWindowsHelper"]["sha256"] == HELPER_SHA256,
            "Sealed app receipt does not bind this exact source and frozen payload pair")
    inputs = receipt["buildInvocation"]["inputs"]
    candidate = Path(inputs["cli"]).parent
    _, _, producer = frozen_payloads(candidate, approved_unnotarized_cli)
    require(producer == receipt["producer"], "Frozen producer receipt changed since dry-run")
    verify_designated_requirement(app, "app", receipt["certificateSHA1"])
    receipt["initialDryRunReceipt"] = owned_bytes(receipt_path)[0]
    receipt["state"], receipt["dryRun"] = "notarizing", False
    write_receipt(receipt_path, receipt)
    try:
        execute(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
                stage, receipt, receipt_path, "resume-app-signature")
        distribute(app, stage, receipt, receipt_path, receipt["certificateSHA1"], profile,
                   producer_notices_sha256, dmg_background)
        frozen_payloads(candidate, approved_unnotarized_cli)
        write_receipt(receipt_path, receipt)
        print(receipt_path, flush=True)
        return receipt_path
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        receipt["state"], receipt["error"] = "failed", str(error)
        write_receipt(receipt_path, receipt)
        raise


def build(args):
    project = Path(__file__).resolve().parent.parent
    source = source_identity(project)
    require(source["commit"] == hex_value(args.app_commit, 40), "Current clean HEAD must equal --app-commit")
    branch = release_branch(project)
    require(branch == "main" or branch.startswith("release/"),
            "Package releases only from main or a release/* branch")
    require(args.producer_notices is not None
            and isinstance(PRODUCER_NOTICES_SHA256, str)
            and re.fullmatch(r"[0-9a-f]{64}", PRODUCER_NOTICES_SHA256) is not None
            and args.producer_notices_sha256 == PRODUCER_NOTICES_SHA256,
            "No current producer-notice inventory is pinned; await the -02 admission rebuild")
    root = args.output_root.resolve(strict=True)
    info = root.stat()
    require(root == args.output_root and info.st_uid == os.getuid() and info.st_mode & 0o022 == 0,
            "Use a canonical, owned, non-writable-by-others output root")
    cli, helper, producer = frozen_payloads(args.candidate.resolve(strict=True), args.approve_unnotarized_cli)
    require(args.dmg_background is not None, "Supply the reviewed X Ode DMG background PNG")
    background_identity = validate_dmg_background(args.dmg_background)
    require(args.engine_notice is not None, "Supply the admitted Calimocho -02 NOTICE text")
    engine_notice_identity = validate_engine_notice(args.engine_notice)
    stage = Path(tempfile.mkdtemp(prefix="Ode-release-", dir=root))
    stage.chmod(0o700)
    receipt_path = stage / "release-receipt.json"
    receipt = {"version": 1, "state": "building", "dryRun": args.dry_run,
               "appSource": source, "producer": producer, "commands": [], "artifacts": {},
               "dmgBackground": background_identity,
               "engineNotice": engine_notice_identity,
               "certificateSHA1": args.identity.upper(), "notaryProfile": args.notary_profile,
               "notarized": False, "installed": False, "activated": False,
               "appE2E": "unobserved", "productionQualified": False}
    write_receipt(receipt_path, receipt)
    print(receipt_path, flush=True)
    try:
        notices = getattr(args, "producer_notices", None)
        notices_sha = getattr(args, "producer_notices_sha256", None)
        receipt["buildInvocation"] = {"function": "refresh_local_candidate.refresh", "completed": False,
            "inputs": {"appCommit": source["commit"], "cli": str(cli), "windowsHelper": str(helper),
                       "producerSource": str(args.producer_source), "producerCommit": PRODUCER_COMMIT,
                       "installedAppReadOnly": str(args.installed_app), "certificateSHA1": args.identity.upper(),
                       "dmgBackground": str(args.dmg_background),
                       "dmgBackgroundSHA256": background_identity["sha256"],
                       "engineNotice": str(args.engine_notice),
                       "engineNoticeSHA256": engine_notice_identity["sha256"]}}
        write_receipt(receipt_path, receipt)
        app, build_receipt = refresh(args.installed_app, stage, args.identity, cli,
                                     args.producer_source, PRODUCER_COMMIT, helper, notices, notices_sha,
                                     args.engine_notice)
        with (app / "Contents/Info.plist").open("rb") as bundle:
            app_info = plistlib.load(bundle)
        app_version = app_info.get("CFBundleShortVersionString")
        release_channel = app_info.get("XodeReleaseChannel")
        app_build = app_info.get("CFBundleVersion")
        require(isinstance(app_version, str) and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", app_version)
                and isinstance(release_channel, str) and re.fullmatch(r"[A-Za-z]+", release_channel)
                and isinstance(app_build, str) and app_build.isdecimal(),
                "Built app release metadata is invalid")
        receipt.update({"appVersion": app_version, "buildNumber": int(app_build),
                        "releaseChannel": release_channel,
                        "releaseTag": f"v{app_version}-{release_channel.lower()}.1"})
        receipt["producerNoticesSHA256"] = notices_sha
        receipt["buildInvocation"]["completed"] = True
        receipt["candidateBuildReceipt"] = {"path": str(build_receipt), **owned_bytes(build_receipt)[0]}
        receipt["candidateBuild"] = read_json(build_receipt)
        require(validate_engine_notice(app / "Contents/Resources/EngineNotices/NOTICE.txt")
                == engine_notice_identity,
                "Built app does not contain the admitted Calimocho NOTICE text")
        receipt["artifacts"]["app"] = {"path": str(app)}
        log = app.parent / "build.log"
        receipt["buildInvocation"]["log"] = str(log)
        execute(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
                stage, receipt, receipt_path, "app-signature")
        owned_bytes(app / "Contents/Resources/XodusEngine/xodus-cli", CLI_SHA256)
        owned_bytes(app / "Contents/Resources/XodusEngine/xodus-window-monitor.exe", HELPER_SHA256)
        if args.dry_run:
            receipt["distributionBlockers"] = distribution_blockers(app, notices_sha)
            receipt["state"] = "signed_dry_run_complete"
            receipt["unexecutedGates"] = ["app notarization", "app stapling and Gatekeeper",
                                          "DMG creation/signing/notarization/stapling/Gatekeeper",
                                          "install/activation", "app_e2e"]
        else:
            distribute(app, stage, receipt, receipt_path, args.identity, args.notary_profile,
                       notices_sha, args.dmg_background)
        require(source_identity(project) == source, "Source changed during release build")
        frozen_payloads(args.candidate.resolve(strict=True), args.approve_unnotarized_cli)
        receipt["artifacts"]["bundledCLI"] = owned_bytes(app / "Contents/Resources/XodusEngine/xodus-cli")[0]
        receipt["artifacts"]["bundledWindowsHelper"] = owned_bytes(
            app / "Contents/Resources/XodusEngine/xodus-window-monitor.exe")[0]
        for name, relative in (("launcher", "Contents/MacOS/Xodus"),
                               ("authenticationHelper", "Contents/MacOS/XodusAuthHost"),
                               ("resourceSeal", "Contents/_CodeSignature/CodeResources")):
            receipt["artifacts"][name] = owned_bytes(app / relative)[0]
        receipt["sealedAppResourceReceipt"] = owned_bytes(app / "Contents/Resources/local-candidate-receipt.json")[0]
        write_receipt(receipt_path, receipt)
        return receipt_path
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        receipt["state"], receipt["error"] = "failed", str(error)
        receipt["buildLogs"] = [str(path) for path in sorted(stage.glob("Ode-refresh-*/build.log"))]
        write_receipt(receipt_path, receipt)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-commit")
    parser.add_argument("--installed-app", type=Path, help="Read-only icon and prior receipt source")
    parser.add_argument("--output-root", type=Path)
    parser.add_argument("--identity")
    parser.add_argument("--candidate", type=Path, help="Frozen payload directory with approved producer receipts")
    parser.add_argument("--producer-source", type=Path)
    parser.add_argument("--producer-notices", type=Path)
    parser.add_argument("--producer-notices-sha256",
                        help="Independently reviewed exact inventory digest; required for distribution")
    parser.add_argument("--dmg-background", type=Path,
                        help="Reviewed X Ode installer PNG; required for distribution")
    parser.add_argument("--engine-notice", type=Path,
                        help="Plain-text Calimocho -02 NOTICE included in the candidate")
    parser.add_argument("--resume-receipt", type=Path, help="Submit the exact already-signed successful dry-run app")
    parser.add_argument("--notary-profile", default="notary")
    parser.add_argument("--approve-unnotarized-cli",
                        help="Only after owner approval: exact prepared CLI SHA; otherwise standalone Accepted is required")
    parser.add_argument("--dry-run", action="store_true", help="Build/sign only; no Apple submission, install or activation")
    args = parser.parse_args()
    if args.resume_receipt:
        require(not args.dry_run and not any((args.app_commit, args.installed_app, args.output_root,
                                             args.identity, args.candidate, args.producer_source,
                                             args.producer_notices, args.dmg_background, args.engine_notice)),
                "Resume takes only its exact dry-run receipt and notary profile")
        resume(args.resume_receipt, args.notary_profile, args.approve_unnotarized_cli,
               args.producer_notices_sha256, args.dmg_background)
    else:
        require(all((args.app_commit, args.installed_app, args.output_root,
                     args.identity, args.candidate, args.producer_source)), "Supply all pinned build inputs")
        build(args)


if __name__ == "__main__":
    main()
