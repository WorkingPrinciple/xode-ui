#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Local admission/archive checks with stub Apple tools, never native release proof."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

from release_admission import app_tree_sha256, verify_release_admission
from release_dmg_trust import TrustFailure

ROOT = Path(__file__).resolve().parent.parent


class ReleaseAdmissionChecks(unittest.TestCase):
    def fixture(self, root):
        app = root / "Ode to X.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        with (app / "Contents/Info.plist").open("wb") as target:
            plistlib.dump({"CFBundleShortVersionString": "0.2.0",
                          "CFBundleExecutable": "Fixture"}, target)
        executable = app / "Contents/MacOS/Fixture"
        executable.write_bytes(b"synthetic executable")
        executable.chmod(0o755)
        source = {"repository": "WorkingPrinciple/xode-ui", "commit": "a" * 40, "tree": "b" * 40}
        identity = {"sha256": app_tree_sha256(app), "version": "0.2.0"}
        admission = {"schemaVersion": 1, "source": source, "app": identity}
        for kind in ("releaseQualification", "provenanceRedistributionReview"):
            report = root / (kind + ".txt")
            report.write_bytes(b"Synthetic test evidence, not approval")
            record = {"schemaVersion": 1, "kind": kind, "status": "accepted",
                      "source": source, "app": identity,
                      "evidence": [{"path": report.name, "sha256": self.hash(report)}]}
            path = root / (kind + ".json")
            path.write_text(json.dumps(record))
            admission[kind] = {"receipt": path.name, "sha256": self.hash(path)}
        receipt = root / "admission.json"
        receipt.write_text(json.dumps(admission))
        return app, receipt, identity["sha256"], self.hash(receipt)

    @staticmethod
    def hash(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def verify(self, app, receipt, app_hash, receipt_hash):
        return verify_release_admission(app, receipt, expected_app_sha256=app_hash,
                                        expected_receipt_sha256=receipt_hash, version="0.2.0",
                                        commit="a" * 40, tree="b" * 40)

    def test_admission_accepts_exact_input(self):
        with tempfile.TemporaryDirectory() as directory:
            inputs = self.fixture(Path(directory).resolve())
            self.assertEqual(self.verify(*inputs), inputs[2])

    def test_missing_changed_unqualified_and_mismatched_evidence(self):
        for case in ("app", "receipt", "pending", "source", "missing", "tampered", "escape", "duplicate"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                app, receipt, app_hash, receipt_hash = self.fixture(root)
                record = root / "releaseQualification.json"
                evidence = json.loads(record.read_text())
                if case == "app":
                    (app / "Contents/MacOS/Fixture").write_bytes(b"changed")
                elif case == "receipt":
                    receipt.write_text("{}")
                elif case == "missing":
                    (root / "releaseQualification.txt").unlink()
                elif case == "tampered":
                    (root / "releaseQualification.txt").write_bytes(b"changed")
                else:
                    if case == "pending":
                        evidence["status"] = "pending"
                    elif case == "source":
                        evidence["source"]["commit"] = "c" * 40
                    elif case == "escape":
                        evidence["evidence"][0]["path"] = "../outside"
                    record.write_text(json.dumps(evidence))
                    if case == "duplicate":
                        record.write_text(record.read_text().replace(
                            '"status": "accepted"', '"status": "accepted", "status": "accepted"'))
                    admission = json.loads(receipt.read_text())
                    admission["releaseQualification"]["sha256"] = self.hash(record)
                    receipt.write_text(json.dumps(admission))
                    receipt_hash = self.hash(receipt)
                with self.assertRaises((ValueError, OSError)):
                    self.verify(app, receipt, app_hash, receipt_hash)

    def test_bundle_symlinks_are_contained_and_resolved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            app, _, _, _ = self.fixture(root)
            link = app / "Contents/linked"
            link.symlink_to("MacOS/Fixture")
            self.assertEqual(len(app_tree_sha256(app)), 64)
            link.unlink()
            link.symlink_to(root / "outside")
            (root / "outside").write_bytes(b"not admitted")
            with self.assertRaisesRegex(ValueError, "symlink"):
                app_tree_sha256(app)
            link.unlink()
            link.symlink_to("missing")
            with self.assertRaisesRegex(ValueError, "symlink"):
                app_tree_sha256(app)

    def stub_tools(self, root):
        bin_path = root / "bin"
        bin_path.mkdir()
        scripts = {
            "git": '''case "$*" in *'rev-parse HEAD')
    [ "$CASE" != source-commit ] || { printf '%040d\\n' 0 | tr 0 c; exit; }
    printf '%040d\\n' 0 | tr 0 a ;;
*'HEAD^{tree}'*)
    [ "$CASE" != source-tree ] || { printf '%040d\\n' 0 | tr 0 c; exit; }
    printf '%040d\\n' 0 | tr 0 b ;;
*'remote get-url origin')
    [ "$CASE" != origin ] || { echo https://github.com/synthetic/other.git; exit; }
    [ "$CASE" != origin-lookalike ] || { echo https://github.com/WorkingPrinciple/xode-ui.evil; exit; }
    [ "$CASE" != checkout-origin ] || { echo https://github.com/WorkingPrinciple/xode-ui; exit; }
    echo https://github.com/WorkingPrinciple/xode-ui.git ;;
*status*) [ "$CASE" != status-error ] || exit 42
    [ "$CASE" != dirty ] || echo dirty ;;
*) exit 99 ;; esac''',
            "plutil": 'printf "Fixture\\n"',
            "lipo": '[ "$CASE" != architecture ] || { echo x86_64; exit; }; echo arm64',
            "codesign": '''echo "$*" >> "$CONTROL/codesign-calls"
if [ "$CASE" = signature ]; then
    echo "codesign verification failed for admitted app" >&2
    exit 1
fi''',
        }
        for name, body in scripts.items():
            path = bin_path / name
            path.write_text("#!/bin/sh\nset -eu\n" + body + "\n")
            path.chmod(0o755)
        return bin_path

    def package(self, root, inputs, case="valid", output=None):
        app, receipt, app_hash, receipt_hash = inputs
        environment = dict(os.environ, CASE=case, CONTROL=str(root), FIXTURE_APP=str(app),
                           PATH=str(self.stub_tools(root)) + os.pathsep + os.environ["PATH"])
        return subprocess.run(
            ["sh", str(ROOT / "tools/package_release.sh"), str(app), "0.2.0",
             str(output or root / "output"), str(receipt), app_hash, receipt_hash,
             "a" * 40, "b" * 40, "WorkingPrinciple/xode-ui"],
            env=environment, capture_output=True, text=True, timeout=20)

    def test_missing_trust_configuration_rejects_before_output_creation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            result = self.package(root, self.fixture(root))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("RELEASE_DMG_SIGNING_IDENTITY", result.stderr)
            self.assertFalse((root / "output").exists())

    def test_trust_failure_receipt_diagnostic_and_exit_status(self):
        interrupted = TrustFailure("wait", "operation_interrupted", 130)
        self.assertEqual(interrupted.receipt(), {
            "stage": "wait", "reason": "operation_interrupted",
            "exitCode": 130, "timedOut": False,
        })
        self.assertEqual(interrupted.diagnostic(),
                         "DMG trust failed at wait: operation_interrupted; command exit 130")
        self.assertEqual(interrupted.exit_status(), 130)

        timeout = TrustFailure("wait", "command_timeout", 124, timed_out=True, attempt="dmg-safe")
        self.assertEqual(timeout.receipt(), {
            "stage": "wait", "reason": "command_timeout",
            "exitCode": 124, "timedOut": True,
        })
        self.assertEqual(timeout.diagnostic(),
                         "DMG trust failed at wait: command_timeout; command exit 124; timed out; reconcile attempt dmg-safe")
        self.assertEqual(timeout.exit_status(), 124)
        self.assertNotIn("RELEASE_NOTARY_PROFILE", timeout.diagnostic())
        self.assertNotIn("/private/", timeout.diagnostic())

    def test_trust_cli_rejects_bad_arguments_without_path_or_prefix_leak(self):
        result = subprocess.run(
            ["python3", str(ROOT / "tools/release_dmg_trust.py"), "unexpected"],
            capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr.strip(),
                         "DMG trust failed at invocation: invalid_arguments")
        self.assertNotIn("1:", result.stderr)
        self.assertNotIn(str(ROOT), result.stderr)

    def test_trust_cli_reports_sanitized_recovery_preflight_failure(self):
        environment = dict(os.environ)
        environment.pop("RELEASE_DMG_RECOVERY_ROOT", None)
        result = subprocess.run(
            ["python3", str(ROOT / "tools/release_dmg_trust.py"), "preflight"],
            env=environment, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(
            result.stderr.strip(),
            "DMG trust failed at recovery-preflight: persistent_recovery_configuration_invalid")
        self.assertNotIn("1:", result.stderr)
        self.assertNotIn(str(ROOT), result.stderr)

    def test_packaging_failures_never_publish_success_manifest(self):
        expected_errors = {
            "origin": "source origin repository mismatch",
            "origin-lookalike": "source origin repository mismatch",
            "source-commit": "source commit mismatch",
            "source-tree": "source tree mismatch",
            "dirty": "packaging tool source must be frozen and clean",
            "signature": "codesign verification failed for admitted app",
            "architecture": "executable has no arm64 slice",
        }
        for case, message in expected_errors.items():
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                result = self.package(root, self.fixture(root), case)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(message, result.stderr)
                self.assertNotIn("RELEASE_DMG_SIGNING_IDENTITY", result.stderr)
                self.assertFalse((root / "output/SHA256SUMS.txt").exists())
                self.assertFalse((root / "output").exists())

    def test_invalid_destinations_and_changed_admission_fail_before_tools(self):
        for case in ("equal", "nested", "alias", "existing", "changed"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                inputs = self.fixture(root)
                app = inputs[0]
                output = root / "output"
                if case == "equal":
                    output = app
                elif case == "nested":
                    output = app / "output"
                elif case == "alias":
                    (root / "alias").symlink_to(app, target_is_directory=True)
                    output = root / "alias/output"
                elif case == "existing":
                    output.mkdir()
                elif case == "changed":
                    (app / "Contents/MacOS/Fixture").write_bytes(b"changed")
                result = self.package(root, inputs, output=output)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((root / "codesign-calls").exists())
                self.assertFalse((output / "SHA256SUMS.txt").exists())

    def test_failed_git_status_with_empty_stdout_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            result = self.package(root, self.fixture(root), "status-error")
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("could not inspect source status", result.stderr)
            self.assertFalse((root / "output").exists())
            self.assertFalse((root / "codesign-calls").exists())

if __name__ == "__main__":
    unittest.main()
