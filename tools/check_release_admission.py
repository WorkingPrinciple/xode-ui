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
[ "$CASE" != signature ]''',
            "ditto": '''case "$1" in
-c) /bin/cp -R "$4" "$CONTROL/zip-app"; printf zip > "$5" ;;
-x) /bin/cp -R "$CONTROL/zip-app" "$4/Ode to X.app"
    [ "$CASE" != zip-corrupt ] || echo changed > "$4/Ode to X.app/Contents/MacOS/Fixture" ;;
*) /bin/cp -R "$1" "$2" ;; esac''',
            "hdiutil": '''echo "$*" >> "$CONTROL/hdiutil-calls"
case "$1" in
create) for arg do destination=$arg; done; printf dmg > "$destination" ;;
verify) [ "$CASE" != dmg-invalid ] ;;
attach) while [ "$1" != -mountpoint ]; do shift; done
    /bin/cp -R "$FIXTURE_APP" "$2/Ode to X.app"
    echo "$2" > "$CONTROL/mountpoint"
    [ "$CASE" != dmg-corrupt ] || echo changed > "$2/Ode to X.app/Contents/MacOS/Fixture"
    [ "$CASE" != partial-attach ] ;;
detach) [ "$CASE" != detach-hang ] || exec /bin/sleep 6
    [ "$CASE" != detach-fail ] && [ "$CASE" != partial-attach ] ;;
*) exit 99 ;; esac''',
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

    def test_stub_round_trip_and_checksums(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            result = self.package(root, self.fixture(root))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            output = root / "output"
            lines = (output / "SHA256SUMS.txt").read_text().splitlines()
            self.assertEqual(len(lines), 2)
            for line in lines:
                digest, filename = line.split()
                self.assertEqual(self.hash(output / filename), digest)
            self.assertEqual(len(list(output.iterdir())), 3)
            calls = (root / "codesign-calls").read_text()
            self.assertNotIn("--sign", calls)
            self.assertIn("verify", (root / "hdiutil-calls").read_text())

    def test_packaging_failures_never_publish_success_manifest(self):
        for case in ("origin", "origin-lookalike", "source-commit", "source-tree", "dirty", "signature", "architecture", "dmg-invalid", "dmg-corrupt",
                     "zip-corrupt", "detach-fail", "partial-attach"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                result = self.package(root, self.fixture(root), case)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse((root / "output/SHA256SUMS.txt").exists())
                if case in ("detach-fail", "partial-attach"):
                    mount = Path((root / "mountpoint").read_text().strip())
                    self.assertTrue((mount / "Ode to X.app").exists())
                    self.assertIn("preserving stage", result.stderr)
                else:
                    self.assertEqual(list((root / "output").glob(".package-stage.*")), [])

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
                self.assertFalse((root / "hdiutil-calls").exists())
                self.assertFalse((output / "SHA256SUMS.txt").exists())

    def test_failed_git_status_with_empty_stdout_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            result = self.package(root, self.fixture(root), "status-error")
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("could not inspect source status", result.stderr)
            self.assertFalse((root / "output").exists())
            self.assertFalse((root / "codesign-calls").exists())
            self.assertFalse((root / "hdiutil-calls").exists())

    def test_hanging_detach_is_bounded_and_preserves_uncertain_mount(self):
        import time
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            start = time.monotonic()
            result = self.package(root, self.fixture(root), "detach-hang")
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertLess(time.monotonic() - start, 12)
            self.assertIn("timed out", result.stderr)
            self.assertIn("preserving stage", result.stderr)
            mount = Path((root / "mountpoint").read_text().strip())
            self.assertTrue((mount / "Ode to X.app").exists())
            self.assertFalse((root / "output/SHA256SUMS.txt").exists())


if __name__ == "__main__":
    unittest.main()
