#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Local admission/archive checks with stub Apple tools, never native release proof."""
import hashlib
import json
import multiprocessing
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from release_admission import app_tree_sha256, verify_release_admission
from release_dmg_trust import persistent_root, trust

ROOT = Path(__file__).resolve().parent.parent


def concurrent_trust_attempt(root, number, phase, ready, release, results):
    recovery = root / "persistent"
    original_glob = Path.glob

    def admission_glob(path, pattern):
        entries = list(original_glob(path, pattern))
        if path == recovery and pattern == "dmg-*" and phase == "admission":
            ready.set()
            if not release.wait(10):
                raise ValueError("Synthetic admission barrier timed out")
        return iter(entries)

    def stub_run(command, stdout, stderr, timeout):
        if command[1:3] == ["notarytool", "submit"]:
            with (root / "submissions").open("a") as calls:
                calls.write(str(number) + "\n")
            stdout.write(b'{"id":"12345678-1234-1234-1234-123456789abc"}')
            return SimpleNamespace(returncode=0)
        if command[1:3] == ["notarytool", "wait"]:
            if phase == "wait":
                ready.set()
                if not release.wait(10):
                    raise ValueError("Synthetic wait barrier timed out")
            return SimpleNamespace(returncode=124)
        raise AssertionError("Unexpected trust command in concurrency check")

    environment = {"RELEASE_DMG_RECOVERY_ROOT": str(recovery),
                   "RELEASE_NOTARY_PROFILE": "synthetic-notary"}
    with patch.object(Path, "glob", admission_glob), patch("release_dmg_trust.subprocess.run", stub_run):
        try:
            trust(root / "image.dmg", root / ("evidence-" + str(number)), environment)
        except ValueError as error:
            results.put(str(error))
        else:
            raise AssertionError("Synthetic timeout must not succeed")


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
[ "$CASE" != signature ] || exit 1
case "$*" in
*--sign*) [ "$CASE" != dmg-sign ] || exit 1 ;;
*--verify*' --strict '*.dmg)
    if [ "$CASE" = final-signature ] && grep -q 'stapler validate' "$CONTROL/trust-calls" 2>/dev/null; then exit 1; fi ;;
esac''',
            "xcrun": '''echo "$*" >> "$CONTROL/trust-calls"
case "$1 $2" in
"notarytool submit")
    [ "$CASE" != notary-error ] || exit 1
    case "$CASE" in
      notary-malformed) echo 'not JSON' ;;
      notary-missing-id) echo '{"message":"Uploaded"}' ;;
      *) echo '{"id":"12345678-1234-1234-1234-123456789abc","message":"Uploaded","path":"/private/runner/secret-path"}' ;;
    esac ;;
"notarytool wait")
    [ "$CASE" != wait-timeout ] || exit 124
    [ "$CASE" != wait-interrupt ] || { kill -TERM "$PPID"; /bin/sleep 1; exit 124; }
    case "$CASE" in
      notary-invalid) echo '{"id":"12345678-1234-1234-1234-123456789abc","status":"Invalid"}' ;;
      notary-id-mismatch) echo '{"id":"87654321-4321-4321-4321-cba987654321","status":"Accepted"}' ;;
      notary-duplicate) echo '{"id":"12345678-1234-1234-1234-123456789abc","status":"Invalid","status":"Accepted"}' ;;
      *) echo '{"id":"12345678-1234-1234-1234-123456789abc","status":"Accepted"}' ;;
    esac ;;
"stapler staple")
    [ "$CASE" != staple-error ] || exit 1
    printf stapled >> "$3" ;;
"stapler validate") [ "$CASE" != validate-error ] ;;
*) exit 99 ;; esac''',
            "spctl": '''echo "$*" >> "$CONTROL/trust-calls"
[ "$CASE" != assessment-error ]''',
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

    def package(self, root, inputs, case="valid", output=None, overrides=None):
        app, receipt, app_hash, receipt_hash = inputs
        environment = dict(os.environ, CASE=case, CONTROL=str(root), FIXTURE_APP=str(app),
                           RELEASE_DMG_SIGNING_IDENTITY="a" * 40,
                           RELEASE_NOTARY_PROFILE="synthetic-notary",
                           PATH=str(self.stub_tools(root)) + os.pathsep + os.environ["PATH"])
        # A synthetic policy tests validation, not real persistent storage.
        with tempfile.TemporaryDirectory(prefix=".release-recovery-check-", dir=ROOT) as directory:
            recovery = Path(directory).resolve()
            policy = recovery / ".ode-dmg-recovery.json"
            policy.write_text('{"version":1,"retention":"owner-managed-persistent"}')
            policy.chmod(0o600)
            environment["RELEASE_DMG_RECOVERY_ROOT"] = str(recovery)
            environment.pop("GITHUB_WORKSPACE", None)
            environment.update(overrides or {})
            result = subprocess.run(
                ["sh", str(ROOT / "tools/package_release.sh"), str(app), "0.2.0",
                 str(output or root / "output"), str(receipt), app_hash, receipt_hash,
                 "a" * 40, "b" * 40, "WorkingPrinciple/xode-ui"],
                env=environment, capture_output=True, text=True, timeout=20)
            result.recovery = [{
                "receipt": json.loads((attempt / "receipt.json").read_text()),
                "submitted": (attempt / "submitted.dmg").read_bytes(),
                "imageMode": (attempt / "submitted.dmg").stat().st_mode & 0o777,
                "directoryMode": attempt.stat().st_mode & 0o777,
                "waitResponse": ((attempt / "wait.json").read_text()
                                 if (attempt / "wait.json").exists() else None),
            } for attempt in recovery.glob("dmg-*")]
            return result

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
            calls = (root / "codesign-calls").read_text()
            sign_calls = [line for line in calls.splitlines() if "--sign" in line]
            self.assertEqual(len(sign_calls), 1)
            self.assertTrue(sign_calls[0].endswith(".dmg"))
            self.assertIn("--timestamp", sign_calls[0])
            self.assertEqual(app_tree_sha256(root / "Ode to X.app"),
                             json.loads((root / "admission.json").read_text())["app"]["sha256"])
            trust = (root / "trust-calls").read_text()
            self.assertLess(trust.index("notarytool submit"), trust.index("stapler staple"))
            self.assertLess(trust.index("notarytool wait"), trust.index("stapler staple"))
            self.assertNotIn("--wait", trust)
            self.assertLess(trust.index("stapler validate"), trust.index("--assess --type open"))
            self.assertEqual((output / "Ode-to-X-v0.2.0-macos-arm64.dmg").read_bytes(),
                             b"dmgstapled")
            self.assertIn("verify", (root / "hdiutil-calls").read_text())

    def test_packaging_failures_never_publish_success_manifest(self):
        for case in ("origin", "origin-lookalike", "source-commit", "source-tree", "dirty", "signature", "architecture", "dmg-invalid", "dmg-corrupt",
                     "zip-corrupt", "detach-fail", "partial-attach", "dmg-sign", "notary-error",
                     "notary-invalid", "notary-malformed", "notary-missing-id", "staple-error",
                     "validate-error", "assessment-error", "notary-duplicate", "final-signature"):
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

    def test_wait_timeout_retains_private_exact_submission_and_sanitized_receipt(self):
        for case in ("wait-timeout", "wait-interrupt", "notary-error", "notary-id-mismatch"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                result = self.package(root, self.fixture(root), case)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((root / "output/SHA256SUMS.txt").exists())
                self.assertEqual(len(result.recovery), 1)
                retained = result.recovery[0]
                self.assertEqual(retained["submitted"], b"dmg")
                self.assertEqual(retained["imageMode"], 0o400)
                self.assertEqual(retained["directoryMode"], 0o700)
                record = retained["receipt"]
                self.assertEqual(record["submittedImage"]["sha256"], hashlib.sha256(b"dmg").hexdigest())
                self.assertEqual(record["submittedImage"]["bytes"], 3)
                self.assertEqual(record["state"], "reconciliation-required")
                self.assertEqual(record["submissionID"],
                    "12345678-1234-1234-1234-123456789abc" if case != "notary-error" else None)
                self.assertIsNone(record["notaryStatus"])
                if case == "notary-id-mismatch":
                    self.assertEqual(json.loads(retained["waitResponse"]),
                        {"id": "87654321-4321-4321-4321-cba987654321", "status": "Accepted"})
                    self.assertNotIn("stapler", (root / "trust-calls").read_text())
                calls = (root / "trust-calls").read_text()
                self.assertEqual(calls.count("notarytool submit"), 1)
                public = (root / "output/dmg-trust-evidence/receipt.json").read_text()
                self.assertEqual(json.loads(public), record)
                self.assertNotIn(str(root), public)
                self.assertNotIn("/private/runner", public)
                self.assertNotIn("synthetic-notary", public)

    def test_recovery_requires_owner_managed_nonvolatile_private_storage(self):
        with tempfile.TemporaryDirectory(prefix=".release-recovery-check-", dir=ROOT) as directory:
            recovery = Path(directory).resolve()
            env = {"RELEASE_DMG_RECOVERY_ROOT": str(recovery)}
            with self.assertRaises(OSError):
                persistent_root(env)
            policy = recovery / ".ode-dmg-recovery.json"
            policy.write_text('{"version":1,"retention":"owner-managed-persistent"}')
            policy.chmod(0o600)
            self.assertEqual(persistent_root(env), recovery)
            for variable in ("RUNNER_TEMP", "TMPDIR", "GITHUB_WORKSPACE"):
                with self.assertRaisesRegex(ValueError, "temporary"):
                    persistent_root({**env, variable: str(recovery.parent)})
            recovery.chmod(0o755)
            with self.assertRaisesRegex(ValueError, "0700"):
                persistent_root(env)
            recovery.chmod(0o700)
            policy.chmod(0o644)
            with self.assertRaisesRegex(ValueError, "0600"):
                persistent_root(env)

    def test_unreconciled_attempt_blocks_a_second_submission(self):
        with tempfile.TemporaryDirectory(prefix=".release-recovery-check-", dir=ROOT) as directory:
            root = Path(directory).resolve()
            recovery = root / "persistent"
            recovery.mkdir(mode=0o700)
            policy = recovery / ".ode-dmg-recovery.json"
            policy.write_text('{"version":1,"retention":"owner-managed-persistent"}')
            policy.chmod(0o600)
            result = self.package(root, self.fixture(root), "wait-timeout",
                                  overrides={"RELEASE_DMG_RECOVERY_ROOT": str(recovery)})
            self.assertNotEqual(result.returncode, 0)
            image = root / "new-image.dmg"
            image.write_bytes(b"must not submit")
            environment = {**os.environ, "RELEASE_DMG_RECOVERY_ROOT": str(recovery),
                           "RELEASE_NOTARY_PROFILE": "synthetic-notary",
                           "PATH": str(root / "bin") + os.pathsep + os.environ["PATH"],
                           "CONTROL": str(root), "CASE": "valid"}
            environment.pop("GITHUB_WORKSPACE", None)
            second = subprocess.run(["python3", str(ROOT / "tools/release_dmg_trust.py"),
                                     str(image), str(root / "second-evidence")],
                                    env=environment, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(second.returncode, 0)
            self.assertIn("requires owner reconciliation", second.stderr)
            self.assertEqual((root / "trust-calls").read_text().count("notarytool submit"), 1)
            attempts = list(recovery.glob("dmg-*"))
            self.assertEqual(len(attempts), 1)
            self.assertEqual((attempts[0] / "submitted.dmg").read_bytes(), b"dmg")

    def test_concurrent_admission_and_process_death_never_resubmit(self):
        context = multiprocessing.get_context("fork")
        for phase in ("admission", "wait"):
            with self.subTest(phase=phase), tempfile.TemporaryDirectory(
                    prefix=".release-recovery-check-", dir=ROOT) as directory:
                root = Path(directory).resolve()
                recovery = root / "persistent"
                recovery.mkdir(mode=0o700)
                policy = recovery / ".ode-dmg-recovery.json"
                policy.write_text('{"version":1,"retention":"owner-managed-persistent"}')
                policy.chmod(0o600)
                image = root / "image.dmg"
                image.write_bytes(b"exact signed submission fixture")
                ready, release, results = context.Event(), context.Event(), context.Queue()
                owner = context.Process(target=concurrent_trust_attempt,
                    args=(root, 1, phase, ready, release, results))
                contenders = []
                owner.start()
                try:
                    self.assertTrue(ready.wait(5), "Owner did not reach deterministic barrier")
                    contender = context.Process(target=concurrent_trust_attempt,
                        args=(root, 2, None, ready, release, results))
                    contenders.append(contender)
                    contender.start()
                    contender.join(5)
                    self.assertEqual(contender.exitcode, 0)
                    self.assertIn("already active", results.get(timeout=2))
                    calls = root / "submissions"
                    self.assertEqual(calls.read_text().splitlines() if calls.exists() else [],
                                     [] if phase == "admission" else ["1"])
                    if phase == "wait":
                        lock = recovery / ".submission.lock"
                        lock_inode = lock.stat().st_ino
                        self.assertEqual(lock.stat().st_mode & 0o777, 0o600)
                        owner.kill()
                        owner.join(5)
                        self.assertEqual(owner.exitcode, -9)
                        attempt, = recovery.glob("dmg-*")
                        record = json.loads((attempt / "receipt.json").read_text())
                        self.assertEqual(record["state"], "waiting")
                        self.assertEqual(record["submissionID"],
                                         "12345678-1234-1234-1234-123456789abc")
                        self.assertEqual(record["submittedImage"]["sha256"], self.hash(image))
                        self.assertEqual(record["submittedImage"]["bytes"], image.stat().st_size)
                        self.assertEqual((attempt / "submitted.dmg").read_bytes(), image.read_bytes())
                        self.assertEqual((attempt / "submitted.dmg").stat().st_mode & 0o777, 0o400)
                        self.assertEqual(json.loads((root / "evidence-1/receipt.json").read_text()), record)
                        retry = context.Process(target=concurrent_trust_attempt,
                            args=(root, 3, None, ready, release, results))
                        contenders.append(retry)
                        retry.start()
                        retry.join(5)
                        self.assertEqual(retry.exitcode, 0)
                        self.assertIn("requires owner reconciliation", results.get(timeout=2))
                        self.assertEqual(lock.stat().st_ino, lock_inode)
                    else:
                        release.set()
                        owner.join(5)
                        self.assertEqual(owner.exitcode, 0)
                        self.assertIn("trust incomplete", results.get(timeout=2))
                    self.assertEqual(calls.read_text().splitlines(), ["1"])
                    self.assertEqual(len(list(recovery.glob("dmg-*"))), 1)
                finally:
                    if owner.is_alive():
                        release.set()
                    for process in [owner, *contenders]:
                        process.join(2)
                        if process.is_alive():
                            process.kill()
                            process.join(2)
                    results.close()
                    results.join_thread()

    def test_missing_trust_configuration_rejects_before_image_creation(self):
        for overrides in ({"RELEASE_DMG_SIGNING_IDENTITY": ""},
                          {"RELEASE_DMG_SIGNING_IDENTITY": "-"},
                          {"RELEASE_NOTARY_PROFILE": ""},
                          {"RELEASE_NOTARY_PROFILE": "--other-option"},
                          {"RELEASE_DMG_RECOVERY_ROOT": ""}):
            with self.subTest(overrides=overrides), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                result = self.package(root, self.fixture(root), overrides=overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((root / "output").exists())
                self.assertFalse((root / "hdiutil-calls").exists())

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
