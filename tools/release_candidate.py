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
import subprocess
import tempfile

from build_local_candidate import source_identity
from refresh_local_candidate import refresh
from shipping_pair import hex_value, owned_bytes, require, unique_object

CLI_SHA256 = "adf8aed7203c33da9b884d3f0b6d2b9f67b10b760931ee89a35df5255d3aa604"
HELPER_SHA256 = "d5968170c91535385935319a33cb5f680237778cfc85b5e74c5e1be66bdf5535"
PRODUCER_COMMIT = "a86d2f654b29dd33203022013fd63b34826d47cd"


def read_json(path):
    _, data = owned_bytes(path, bounded=4 * 1024 * 1024)
    return json.loads(data, object_pairs_hook=unique_object)


def frozen_payloads(candidate):
    manifest = read_json(candidate / "build-manifest.json")
    notarization = read_json(candidate / "notarization/receipt.json")
    require(manifest["source_commit"] == notarization["source_commit"] == PRODUCER_COMMIT,
            "Unexpected frozen producer source")
    require(manifest["binary_sha256"] == notarization["cli_sha256"] == CLI_SHA256
            and manifest["helper_sha256"] == notarization["helper_sha256"] == HELPER_SHA256
            and manifest["helper_embedded_bytes_verified"] is True
            and notarization["immutable_payloads_unchanged"] is True,
            "Frozen payload receipts do not agree")
    submission = notarization["combined_payload_submission"]
    require(submission["status"] == "Accepted", "CLI/helper combined notarization was not accepted")
    require(isinstance(submission["receipt"], str)
            and Path(submission["receipt"]).name == submission["receipt"],
            "Apple submission receipt must be adjacent to the notarization receipt")
    apple = read_json(candidate / "notarization" / submission["receipt"])
    require(apple["id"] == submission["id"] and apple["status"] == "Accepted",
            "Apple combined-payload submission does not match the producer receipt")
    cli, helper = candidate / "xodus-cli", candidate / "xodus-window-monitor.exe"
    cli_identity, cli_bytes = owned_bytes(cli, CLI_SHA256, bounded=512 * 1024 * 1024)
    helper_identity, helper_bytes = owned_bytes(helper, HELPER_SHA256, bounded=16 * 1024 * 1024)
    require(helper_bytes in cli_bytes, "Adjacent Windows helper differs from actual embedded CLI bytes")
    return cli, helper, {"cli": cli_identity, "windowsHelper": helper_identity,
                         "producerCommit": PRODUCER_COMMIT, "producerTree": manifest["source_tree"],
                         "notarizationReceipt": owned_bytes(candidate / "notarization/receipt.json")[0],
                         "combinedAppleSubmission": apple["id"]}


def write_receipt(path, receipt):
    temporary = path.with_suffix(".tmp")
    with temporary.open("w", encoding="utf-8") as output:
        json.dump(receipt, output, indent=2, sort_keys=True)
        output.write("\n")
    temporary.chmod(0o600)
    temporary.replace(path)


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


def build(args):
    project = Path(__file__).resolve().parent.parent
    source = source_identity(project)
    require(source["commit"] == hex_value(args.app_commit, 40), "Current clean HEAD must equal --app-commit")
    root = args.output_root.resolve(strict=True)
    info = root.stat()
    require(root == args.output_root and info.st_uid == os.getuid() and info.st_mode & 0o022 == 0,
            "Use a canonical, owned, non-writable-by-others output root")
    cli, helper, producer = frozen_payloads(args.candidate.resolve(strict=True))
    stage = Path(tempfile.mkdtemp(prefix="Ode-release-", dir=root))
    stage.chmod(0o700)
    receipt_path = stage / "release-receipt.json"
    receipt = {"version": 1, "state": "building", "dryRun": args.dry_run,
               "appSource": source, "producer": producer, "commands": [], "artifacts": {},
               "certificateSHA1": args.identity.upper(), "notaryProfile": args.notary_profile,
               "notarized": False, "installed": False, "activated": False,
               "appE2E": "unobserved", "productionQualified": False}
    write_receipt(receipt_path, receipt)
    print(receipt_path, flush=True)
    try:
        receipt["buildInvocation"] = {"function": "refresh_local_candidate.refresh", "completed": False,
            "inputs": {"appCommit": source["commit"], "cli": str(cli), "windowsHelper": str(helper),
                       "producerSource": str(args.producer_source), "producerCommit": PRODUCER_COMMIT,
                       "installedAppReadOnly": str(args.installed_app), "certificateSHA1": args.identity.upper()}}
        write_receipt(receipt_path, receipt)
        app, build_receipt = refresh(args.installed_app, stage, args.identity, cli,
                                     args.producer_source, PRODUCER_COMMIT, helper)
        receipt["buildInvocation"]["completed"] = True
        receipt["candidateBuildReceipt"] = {"path": str(build_receipt), **owned_bytes(build_receipt)[0]}
        receipt["candidateBuild"] = read_json(build_receipt)
        receipt["artifacts"]["app"] = {"path": str(app)}
        log = app.parent / "build.log"
        receipt["buildInvocation"]["log"] = str(log)
        execute(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
                stage, receipt, receipt_path, "app-signature")
        owned_bytes(app / "Contents/Resources/XodusEngine/xodus-cli", CLI_SHA256)
        owned_bytes(app / "Contents/Resources/XodusEngine/xodus-window-monitor.exe", HELPER_SHA256)
        if args.dry_run:
            receipt["state"] = "signed_dry_run_complete"
            receipt["unexecutedGates"] = ["app notarization", "app stapling and Gatekeeper",
                                          "DMG creation/signing/notarization/stapling/Gatekeeper",
                                          "install/activation", "app_e2e"]
        else:
            archive = stage / "Ode-to-X-submission.zip"
            execute(["/usr/bin/ditto", "-c", "-k", "--keepParent", str(app), str(archive)],
                    stage, receipt, receipt_path, "app-archive")
            receipt["artifacts"]["appSubmissionArchive"] = {"path": str(archive), **owned_bytes(archive)[0]}
            write_receipt(receipt_path, receipt)
            receipt["appSubmission"] = notarize(archive, stage, receipt, receipt_path, "app", args.notary_profile)
            for verb in ("staple", "validate"):
                execute(["/usr/bin/xcrun", "stapler", verb, str(app)],
                        stage, receipt, receipt_path, "app-stapler-" + verb)
            execute(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
                    stage, receipt, receipt_path, "stapled-app-signature")
            execute(["/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=4", str(app)],
                    stage, receipt, receipt_path, "app-gatekeeper")
            distribution = stage / "distribution"
            distribution.mkdir(mode=0o700)
            execute(["/usr/bin/ditto", str(app), str(distribution / app.name)],
                    stage, receipt, receipt_path, "distribution-app-copy")
            execute(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(distribution / app.name)],
                    stage, receipt, receipt_path, "distribution-app-signature")
            dmg = stage / "Ode-to-X.dmg"
            execute(["/usr/bin/hdiutil", "create", "-volname", "Ode to X", "-srcfolder", str(distribution),
                     "-format", "UDZO", str(dmg)], stage, receipt, receipt_path, "dmg-create")
            execute(["/usr/bin/codesign", "--sign", args.identity, "--timestamp", str(dmg)],
                    stage, receipt, receipt_path, "dmg-sign")
            receipt["artifacts"]["dmgSubmittedBytes"] = {"path": str(dmg), **owned_bytes(dmg)[0]}
            write_receipt(receipt_path, receipt)
            receipt["dmgSubmission"] = notarize(dmg, stage, receipt, receipt_path, "dmg", args.notary_profile)
            for verb in ("staple", "validate"):
                execute(["/usr/bin/xcrun", "stapler", verb, str(dmg)],
                        stage, receipt, receipt_path, "dmg-stapler-" + verb)
            execute(["/usr/bin/codesign", "--verify", "--strict", str(dmg)],
                    stage, receipt, receipt_path, "dmg-signature")
            execute(["/usr/sbin/spctl", "--assess", "--type", "open", "--context",
                     "context:primary-signature", "--verbose=4", str(dmg)],
                    stage, receipt, receipt_path, "dmg-gatekeeper")
            receipt["artifacts"]["dmg"] = {"path": str(dmg), **owned_bytes(dmg)[0]}
            receipt["notarized"], receipt["state"] = True, "notarized_candidate"
        require(source_identity(project) == source, "Source changed during release build")
        frozen_payloads(args.candidate.resolve(strict=True))
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
    parser.add_argument("--app-commit", required=True)
    parser.add_argument("--installed-app", type=Path, required=True, help="Read-only icon and prior receipt source")
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--identity", required=True)
    parser.add_argument("--candidate", type=Path, required=True, help="Frozen adf8 directory with S2 notarization receipts")
    parser.add_argument("--producer-source", type=Path, required=True)
    parser.add_argument("--notary-profile", default="notary")
    parser.add_argument("--dry-run", action="store_true", help="Build/sign only; no Apple submission, install or activation")
    build(parser.parse_args())


if __name__ == "__main__":
    main()
