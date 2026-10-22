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


class ReleaseCandidateChecks(unittest.TestCase):
    def fixture(self, root):
        helper = b"Neutral Windows helper. Never executed."
        cli = b"Neutral CLI containing " + helper
        (root / "xodus-cli").write_bytes(cli)
        (root / "xodus-window-monitor.exe").write_bytes(helper)
        notarization = root / "notarization"
        notarization.mkdir()
        cli_hash, helper_hash = hashlib.sha256(cli).hexdigest(), hashlib.sha256(helper).hexdigest()
        manifest = {"source_commit": release.PRODUCER_COMMIT, "source_tree": "b" * 40,
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


if __name__ == "__main__":
    unittest.main()
