#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Neutral release-pipeline checks; never contacts Apple or activates an app."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import release_candidate as release
import refresh_local_candidate as refresh_tool
import shipping_pair as pins


class ReleaseCandidateChecks(unittest.TestCase):
    def fixture(self, root):
        helper = b"Neutral Windows helper. Never executed."
        cli = b"Neutral CLI containing " + helper
        (root / "xodus-cli").write_bytes(cli)
        (root / "xodus-window-monitor.exe").write_bytes(helper)
        notarization = root / "notarization"
        notarization.mkdir()
        cli_hash, helper_hash = hashlib.sha256(cli).hexdigest(), hashlib.sha256(helper).hexdigest()
        manifest = {"source_commit": release.PRODUCER_COMMIT, "source_tree": release.PRODUCER_TREE,
                    "binary_sha256": cli_hash, "helper_sha256": helper_hash,
                    "helper_embedded_bytes_verified": True}
        receipt = {"source_commit": release.PRODUCER_COMMIT, "cli_sha256": cli_hash,
                   "helper_sha256": helper_hash, "immutable_payloads_unchanged": True,
                   "combined_payload_submission": {"id": "neutral-submission", "status": "Accepted",
                                                   "receipt": "payload-submission.json"}}
        for path, value in ((root / "build-manifest.json", manifest),
                            (notarization / "receipt.json", receipt),
                            (notarization / "payload-submission.json", {"id": "neutral-submission", "status": "Accepted"})):
            path.write_text(json.dumps(value))
        return cli_hash, helper_hash

    def unnotarized_fixture(self, root):
        cli_hash, helper_hash = self.fixture(root)
        (root / "notarization/receipt.json").unlink()
        (root / "notarization/payload-submission.json").unlink()
        (root / "notarization").rmdir()
        path = root / "build-manifest.json"
        manifest = json.loads(path.read_text())
        manifest["notarization"] = {"status": "NOT_SUBMITTED", "submission_id": None, "accepted_receipt": None}
        path.write_text(json.dumps(manifest))
        return cli_hash, helper_hash, hashlib.sha256(path.read_bytes()).hexdigest()

    def test_only_exact_unnotarized_pair_and_manifest_are_admitted(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            cli_hash, helper_hash, manifest_hash = self.unnotarized_fixture(root)
            with patch.object(release, "CLI_SHA256", cli_hash), \
                    patch.object(release, "HELPER_SHA256", helper_hash), \
                    patch.object(release, "UNNOTARIZED_PAIR", (cli_hash, helper_hash)), \
                    patch.object(release, "PRODUCER_MANIFEST_SHA256", manifest_hash):
                _, _, receipt = release.frozen_payloads(root)
                self.assertFalse(receipt["standaloneNotarized"])
                self.assertIsNone(receipt["combinedAppleSubmission"])
                self.assertTrue(receipt["outerAppNotarizationRequired"])
                (root / "xodus-cli").write_bytes(b"Unknown or altered binary")
                with self.assertRaises(ValueError):
                    release.frozen_payloads(root)

    def test_changing_general_pins_cannot_extend_unnotarized_exception(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            cli_hash, helper_hash, manifest_hash = self.unnotarized_fixture(root)
            with patch.object(release, "CLI_SHA256", cli_hash), \
                    patch.object(release, "HELPER_SHA256", helper_hash), \
                    patch.object(release, "PRODUCER_MANIFEST_SHA256", manifest_hash):
                with self.assertRaisesRegex(ValueError, "exception is limited"):
                    release.frozen_payloads(root)

    def test_altered_producer_receipt_or_helper_is_rejected(self):
        for target in ("build-manifest.json", "xodus-window-monitor.exe"):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                cli_hash, helper_hash, manifest_hash = self.unnotarized_fixture(root)
                with patch.object(release, "CLI_SHA256", cli_hash), \
                        patch.object(release, "HELPER_SHA256", helper_hash), \
                        patch.object(release, "UNNOTARIZED_PAIR", (cli_hash, helper_hash)), \
                        patch.object(release, "PRODUCER_MANIFEST_SHA256", manifest_hash):
                    with (root / target).open("ab") as output:
                        output.write(b" ")
                    with self.assertRaises(ValueError):
                        release.frozen_payloads(root)

    def test_wrong_producer_commit_or_tree_is_rejected(self):
        for field in ("source_commit", "source_tree"):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                cli_hash, helper_hash = self.fixture(root)
                path = root / "build-manifest.json"
                manifest = json.loads(path.read_text())
                manifest[field] = "0" * 40
                path.write_text(json.dumps(manifest))
                with patch.object(release, "CLI_SHA256", cli_hash), patch.object(release, "HELPER_SHA256", helper_hash):
                    with self.assertRaisesRegex(ValueError, "producer source"):
                        release.frozen_payloads(root)

    def test_swift_resource_refresh_and_release_pins_agree(self):
        project = Path(__file__).resolve().parent.parent
        lifecycle = (project / "Sources/XodusPreview/NativeGameLifecycle.swift").read_text()
        producer = (project / "Sources/XodusPreview/ShippingProducerPins.swift").read_text()
        configuration = (project / "Sources/XodusPreview/NativeLaunchConfiguration.swift").read_text()
        recipe_bytes = (project / "Sources/XodusManagement/Resources/LaunchRecipes/title-runtime-v1.json").read_bytes()
        recipe = json.loads(recipe_bytes)
        self.assertIn(f'static let cliSHA256 = "{pins.CLI_SHA256}"', lifecycle)
        self.assertIn(f'static let commit = "{pins.PRODUCER}"', producer)
        self.assertIn(f'static let tree = "{pins.PRODUCER_TREE}"', producer)
        self.assertIn(hashlib.sha256(recipe_bytes).hexdigest(), configuration)
        self.assertEqual(recipe["cliSha256"], pins.CLI_SHA256)
        self.assertEqual(recipe["evidenceCliSha256"],
                         "adf8aed7203c33da9b884d3f0b6d2b9f67b10b760931ee89a35df5255d3aa604")
        self.assertEqual(release.CLI_SHA256, refresh_tool.CLI_SHA256)
        self.assertEqual(release.HELPER_SHA256, refresh_tool.WINDOWS_HELPER_SHA256)
        self.assertEqual(release.PRODUCER_COMMIT, refresh_tool.PRODUCER)
        self.assertEqual(release.PRODUCER_TREE, refresh_tool.PRODUCER_TREE)
        self.assertEqual(release.PRODUCER_MANIFEST_SHA256, refresh_tool.PRODUCER_MANIFEST_SHA256)
        self.assertEqual(release.UNNOTARIZED_PAIR, (pins.CLI_SHA256, pins.WINDOWS_HELPER_SHA256))

    def test_refresh_rejects_mismatched_payload_or_producer(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            cli_hash, helper_hash = self.fixture(root)
            cli, helper = root / "xodus-cli", root / "xodus-window-monitor.exe"
            with patch.object(refresh_tool, "CLI_SHA256", cli_hash), \
                    patch.object(refresh_tool, "WINDOWS_HELPER_SHA256", helper_hash):
                refresh_tool.validate_payload_pair(cli, helper, pins.PRODUCER, pins.PRODUCER_TREE)
                for commit, tree in (("0" * 40, pins.PRODUCER_TREE), (pins.PRODUCER, "0" * 40)):
                    with self.assertRaises(ValueError):
                        refresh_tool.validate_payload_pair(cli, helper, commit, tree)
                helper.write_bytes(b"Altered helper")
                with self.assertRaises(ValueError):
                    refresh_tool.validate_payload_pair(cli, helper, pins.PRODUCER, pins.PRODUCER_TREE)

    def test_outer_notarization_signature_stapler_and_gatekeeper_remain_mandatory(self):
        labels = ("app-stapler-staple", "app-stapler-validate", "stapled-app-signature",
                  "app-gatekeeper", "distribution-app-signature", "dmg-sign",
                  "dmg-stapler-staple", "dmg-stapler-validate", "dmg-signature", "dmg-gatekeeper")
        for failure in (None, "app", "dmg", *labels):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                receipt = {"commands": [], "artifacts": {}, "notarized": False}
                def execute(arguments, stage, receipt, path, label):
                    if label == failure:
                        raise ValueError("Required check failed")
                    receipt["commands"].append({"command": arguments, "label": label})
                def notarize(path, stage, receipt, receipt_path, label, profile):
                    if label == failure:
                        raise ValueError("Notary rejection")
                    return {"id": "neutral-" + label, "status": "Accepted"}
                with patch.object(release, "execute", side_effect=execute), \
                        patch.object(release, "notarize", side_effect=notarize) as notary, \
                        patch.object(release, "owned_bytes", return_value=({"sha256": "a" * 64}, b"")):
                    if failure:
                        with self.assertRaises(ValueError):
                            release.distribute(root / "Neutral.app", root, receipt, root / "receipt.json", "c" * 40, "notary")
                        self.assertFalse(receipt["notarized"])
                    else:
                        release.distribute(root / "Neutral.app", root, receipt, root / "receipt.json", "c" * 40, "notary")
                        self.assertTrue(receipt["notarized"])
                        self.assertEqual([call.args[4] for call in notary.call_args_list], ["app", "dmg"])
                        self.assertTrue(set(labels).issubset({record["label"] for record in receipt["commands"]}))

    def test_exact_payloads_and_accepted_receipt_required(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            cli_hash, helper_hash = self.fixture(root)
            with patch.object(release, "CLI_SHA256", cli_hash), patch.object(release, "HELPER_SHA256", helper_hash):
                release.frozen_payloads(root)
                helper = root / "xodus-window-monitor.exe"
                original = helper.read_bytes()
                helper.write_bytes(b"Changed helper")
                with self.assertRaises(ValueError):
                    release.frozen_payloads(root)
                helper.write_bytes(original)
                apple = root / "notarization/payload-submission.json"
                apple.write_text(json.dumps({"id": "neutral-submission", "status": "Invalid"}))
                with self.assertRaises(ValueError):
                    release.frozen_payloads(root)

    def test_dry_run_never_submits_installs_or_activates(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = {"commit": "a" * 40, "tree": "b" * 40}
            args = argparse.Namespace(app_commit=source["commit"], output_root=root,
                candidate=root, installed_app=root / "ReadOnly.app", identity="c" * 40,
                producer_source=root, notary_profile="notary", dry_run=True)

            def refresh(installed, output, *unused):
                app = output / "candidate/Neutral.app"
                resources = app / "Contents/Resources"
                resources.mkdir(parents=True)
                (resources / "local-candidate-receipt.json").write_text("{}")
                receipt = app.parent / "candidate-receipt.json"
                receipt.write_text("{}")
                return app, receipt

            with patch.object(release, "source_identity", return_value=source), \
                    patch.object(release, "frozen_payloads", return_value=(root / "cli", root / "helper", {})), \
                    patch.object(release, "refresh", side_effect=refresh), \
                    patch.object(release, "owned_bytes", return_value=({"sha256": "d" * 64, "bytes": 2}, b"{}")), \
                    patch.object(release, "execute") as execute, \
                    patch.object(release, "notarize") as notarize:
                path = release.build(args)
                receipt = json.loads(path.read_text())
                self.assertEqual(receipt["state"], "signed_dry_run_complete")
                self.assertFalse(receipt["installed"] or receipt["activated"] or receipt["notarized"])
                notarize.assert_not_called()
                self.assertEqual(execute.call_count, 1)
                self.assertEqual(execute.call_args.args[0][:2], ["/usr/bin/codesign", "--verify"])

    def test_wrong_pinned_source_stops_before_build_or_submission(self):
        args = argparse.Namespace(app_commit="a" * 40)
        with patch.object(release, "source_identity", return_value={"commit": "b" * 40}), \
                patch.object(release, "refresh") as refresh, patch.object(release, "notarize") as notarize:
            with self.assertRaises(ValueError):
                release.build(args)
            refresh.assert_not_called()
            notarize.assert_not_called()

    def test_apple_rejection_is_recorded_and_never_promoted(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            receipt, path = {"commands": [], "notarized": False}, root / "release-receipt.json"

            def submit(arguments, stdout, stderr, timeout):
                stdout.write(json.dumps({"id": "neutral-rejection", "status": "Invalid"}).encode())
                return subprocess.CompletedProcess(arguments, 0)

            with patch.object(release.subprocess, "run", side_effect=submit), \
                    patch.object(release, "execute") as execute:
                with self.assertRaises(ValueError):
                    release.notarize(root / "neutral.zip", root, receipt, path, "app", "notary")
                execute.assert_called_once()
                recorded = json.loads(path.read_text())
                self.assertEqual(recorded["commands"][0]["status"], "Invalid")
                self.assertFalse(recorded["notarized"])

    def test_command_failure_preserves_actual_exit(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            receipt, path = {"commands": []}, root / "release-receipt.json"
            with patch.object(release.subprocess, "run", return_value=subprocess.CompletedProcess(["neutral"], 7)):
                with self.assertRaises(ValueError):
                    release.execute(["neutral"], root, receipt, path, "neutral-failure")
                self.assertEqual(json.loads(path.read_text())["commands"][0]["exitCode"], 7)

    def test_resume_preserves_exact_candidate_and_never_rebuilds(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            app = root / "Neutral.app"
            app.mkdir()
            identity = {"sha256": "d" * 64, "bytes": 2}
            receipt = {"version": 1, "state": "signed_dry_run_complete", "dryRun": True,
                "notarized": False, "installed": False, "activated": False, "notaryProfile": "notary",
                "commands": [], "certificateSHA1": "c" * 40, "producer": {},
                "appSource": {"commit": "a" * 40, "tree": "b" * 40},
                "sealedAppResourceReceipt": identity,
                "buildInvocation": {"inputs": {"cli": str(root / "cli")}},
                "artifacts": {"app": {"path": str(app)}, **{name: identity for name in
                    ("launcher", "authenticationHelper", "resourceSeal", "bundledCLI", "bundledWindowsHelper")}}}
            embedded = {"appSource": receipt["appSource"], "preservedCLI": {"sha256": release.CLI_SHA256},
                        "preservedWindowsHelper": {"sha256": release.HELPER_SHA256}}
            with patch.object(release, "read_json", side_effect=lambda path:
                    embedded if path.name == "local-candidate-receipt.json" else receipt), \
                    patch.object(release, "owned_bytes", return_value=(identity, b"{}")), \
                    patch.object(release, "frozen_payloads", return_value=(root / "cli", root / "helper", {})), \
                    patch.object(release, "verify_designated_requirement"), \
                    patch.object(release, "execute"), patch.object(release, "distribute") as distribute, \
                    patch.object(release, "refresh") as refresh:
                release.resume(root / "release-receipt.json", "notary")
                self.assertEqual(distribute.call_args.args[0], app)
                refresh.assert_not_called()
                receipt["state"] = "failed"
                with self.assertRaises(ValueError):
                    release.resume(root / "release-receipt.json", "notary")
                self.assertEqual(distribute.call_count, 1)


if __name__ == "__main__":
    unittest.main()
