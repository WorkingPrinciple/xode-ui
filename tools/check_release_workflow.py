#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Nonpublishing workflow checks; gh and all release artifacts are synthetic."""
import hashlib
from contextlib import chdir
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest
from unittest.mock import patch

import check_release_admission as admission_checks
from release_workflow import preflight, qualified_app

ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = (ROOT / ".github/workflows/release.yml").read_text()


class ReleaseWorkflowChecks(unittest.TestCase):
    def test_missing_input_and_bad_tag_reject_before_git(self):
        with patch("release_workflow.subprocess.check_output") as git:
            with self.assertRaisesRegex(ValueError, "Missing release prerequisites"):
                preflight({})
            env = {key: "synthetic" for key in (
                "TAG", "EXPECTED_COMMIT", "RELEASE_APP", "RELEASE_ADMISSION", "RELEASE_ADMISSION_SHA256",
                "RELEASE_APP_SHA256")}
            with self.assertRaisesRegex(ValueError, "Invalid version tag"):
                preflight(env)
            git.assert_not_called()

    def test_same_qualified_bytes_and_stale_evidence_rejection(self):
        for case in ("valid", "changed-app", "stale-source", "changed-evidence", "mismatched-version"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                app, receipt, app_hash, receipt_hash = admission_checks.ReleaseAdmissionChecks().fixture(root)
                (root / "tools").mkdir()
                (root / "tools/Info.plist").write_bytes((app / "Contents/Info.plist").read_bytes())
                environment = {"TAG": "v0.2.0", "EXPECTED_COMMIT": "a" * 40,
                    "RELEASE_APP": str(app), "RELEASE_ADMISSION": str(receipt),
                    "RELEASE_APP_SHA256": app_hash, "RELEASE_ADMISSION_SHA256": receipt_hash}
                if case == "mismatched-version":
                    environment["TAG"] = "v0.2.1"
                if case == "changed-app":
                    (app / "Contents/MacOS/Fixture").write_bytes(b"new signing bytes")
                if case == "changed-evidence":
                    (root / "releaseQualification.txt").write_bytes(b"changed")
                def git(arguments, **kwargs):
                    if "status" in arguments:
                        return ""
                    if arguments[-1] == "HEAD^{tree}":
                        return ("c" if case == "stale-source" else "b") * 40
                    return "a" * 40
                with chdir(root), patch("release_workflow.subprocess.check_output", side_effect=git):
                    if case == "valid":
                        self.assertEqual(qualified_app(environment), app)
                        # The same immutable input is passed to the existing packager;
                        # only Apple tools are stubbed, not its admission verifier.
                        result = admission_checks.ReleaseAdmissionChecks().package(
                            root, (app, receipt, app_hash, receipt_hash), "checkout-origin")
                        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                        self.assertEqual(admission_checks.app_tree_sha256(app), app_hash)
                    else:
                        with self.assertRaises(ValueError):
                            qualified_app(environment)

    def test_workflow_build_admission_and_token_separation(self):
        self.assertIn("tags: ['v*']", WORKFLOW)
        package, publish = WORKFLOW.split("\n  publish:", 1)
        self.assertNotIn("sh tools/build_app.sh", package)
        self.assertIn("--finalize-generated-assets", package)
        self.assertLess(package.index("sh tools/package_release.sh"),
                        package.index("--finalize-generated-assets"))
        self.assertLess(package.index("--finalize-generated-assets"),
                        package.index("actions/upload-artifact"))
        self.assertLess(package.index("tools/release_workflow.py qualified-app"),
                        package.index("sh tools/package_release.sh"))
        self.assertIn("codesign --verify --deep --strict", package)
        self.assertNotIn("contents: write", package)
        self.assertNotIn("actions/checkout", publish)
        self.assertIn("contents: write", publish)
        self.assertIn("environment: release-publication", publish)
        self.assertIn("commit: ${{ steps.package.outputs.commit }}", package)
        self.assertIn("printf 'commit=%s\\n' \"$EXPECTED_COMMIT\" >> \"$GITHUB_OUTPUT\"", package)
        self.assertIn("EXPECTED_COMMIT: ${{ needs.package.outputs.commit }}", publish)

    def test_publish_exact_manifest_and_release_failure_paths(self):
        block = WORKFLOW.split("      - name: Verify and attach exact assets\n", 1)[1]
        script = textwrap.dedent(block.split("        run: |\n", 1)[1])
        for case in ("valid", "annotated", "missing", "duplicate", "tampered", "collision", "auth", "absent",
                     "moved-tag", "missing-tag", "tag-auth", "bad-tag-object", "tag-cycle", "missing-commit",
                     "moved-create", "missing-create"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                base = "Ode-to-X-v0.2.0-macos-arm64"
                lines = []
                for suffix in ("dmg", "zip"):
                    name = base + "." + suffix
                    (root / name).write_bytes(b"synthetic " + suffix.encode())
                    lines.append(hashlib.sha256((root / name).read_bytes()).hexdigest() + "  " + name)
                if case == "missing":
                    lines.pop()
                if case == "duplicate":
                    lines.append(lines[0])
                if case == "tampered":
                    (root / (base + ".zip")).write_bytes(b"changed")
                (root / "SHA256SUMS.txt").write_text("\n".join(lines) + "\n")
                bin_path = root / "bin"
                bin_path.mkdir()
                gh = bin_path / "gh"
                gh.write_text('''#!/bin/sh
set -eu
echo "$*" >> "$CALLS"
case "$1 $2" in
"api repos/synthetic/unused/git/ref/tags/v0.2.0")
  case "$CASE" in
    missing-tag|missing-create) exit 1 ;;
    tag-auth) echo Forbidden >&2; exit 1 ;;
    moved-tag|moved-create) echo "commit cccccccccccccccccccccccccccccccccccccccc" ;;
    annotated|tag-cycle) echo "tag bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ;;
    bad-tag-object) echo "tree aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ;;
    *) echo "commit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ;;
  esac ;;
"api repos/synthetic/unused/git/tags/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
  if [ "$CASE" = tag-cycle ]; then echo "tag bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  else echo "commit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; fi ;;
"api repos/synthetic/unused/git/commits/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
  [ "$CASE" != missing-commit ] || exit 1
  echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
"api --include")
  [ "$CASE" != auth ] || { echo "HTTP/2.0 403 Forbidden"; exit 1; }
  case "$CASE" in absent|moved-create|missing-create) echo "HTTP/2.0 404 Not Found"; exit 1 ;; esac ;;
"release view") [ "$CASE" != collision ] || echo SHA256SUMS.txt ;;
"release upload"|"release create") ;;
*) exit 99 ;;
esac
''')
                gh.chmod(0o755)
                result = subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                    env={**os.environ, "PATH": str(bin_path) + os.pathsep + os.environ["PATH"],
                         "DIST": str(root), "TAG": "v0.2.0", "VERSION": "0.2.0",
                         "EXPECTED_COMMIT": "a" * 40,
                         "GH_REPO": "synthetic/unused", "CALLS": str(root / "calls"), "CASE": case},
                    timeout=10)
                calls = (root / "calls").read_text() if (root / "calls").exists() else ""
                if case in ("valid", "annotated", "absent"):
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn("release " + ("create" if case == "absent" else "upload"), calls)
                    self.assertEqual(calls.splitlines()[-2],
                        "api repos/synthetic/unused/git/commits/" + "a" * 40 + " --jq .sha")
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertNotIn("release upload", calls)
                    self.assertNotIn("release create", calls)


if __name__ == "__main__":
    unittest.main()
