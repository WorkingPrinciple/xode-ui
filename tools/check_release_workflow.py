#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Nonpublishing workflow checks; gh and all release artifacts are synthetic."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest
from unittest.mock import patch

from release_workflow import preflight

ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = (ROOT / ".github/workflows/release.yml").read_text()


class ReleaseWorkflowChecks(unittest.TestCase):
    def test_missing_input_and_bad_tag_reject_before_git(self):
        with patch("release_workflow.subprocess.check_output") as git:
            with self.assertRaisesRegex(ValueError, "Missing release prerequisites"):
                preflight({})
            env = {key: "synthetic" for key in (
                "TAG", "EXPECTED_COMMIT", "RELEASE_APP", "RELEASE_ADMISSION", "RELEASE_ADMISSION_SHA256",
                "RELEASE_APP_SHA256", "RELEASE_DMG_SIGNING_IDENTITY", "RELEASE_NOTARY_PROFILE",
                "RELEASE_DMG_RECOVERY_ROOT")}
            with self.assertRaisesRegex(ValueError, "Invalid version tag"):
                preflight(env)
            git.assert_not_called()

    def test_workflow_build_admission_and_token_separation(self):
        self.assertIn("tags: ['v*']", WORKFLOW)
        package, publish = WORKFLOW.split("\n  publish:", 1)
        self.assertNotIn("sh tools/build_app.sh", package)
        self.assertNotIn("--signing-identity", package)
        self.assertLess(package.index("tools/release_workflow.py qualified-app"),
                        package.index("sh tools/package_release.sh"))
        self.assertIn("codesign --verify --deep --strict", package)
        self.assertIn("RELEASE_DMG_SIGNING_IDENTITY: ${{ vars.RELEASE_SIGNING_IDENTITY_SHA1 }}", package)
        self.assertIn("RELEASE_NOTARY_PROFILE: ${{ vars.RELEASE_NOTARY_PROFILE }}", package)
        self.assertIn("RELEASE_DMG_RECOVERY_ROOT: ${{ vars.RELEASE_DMG_RECOVERY_ROOT }}", package)
        self.assertIn("if: always() && env.DMG_TRUST_EVIDENCE != ''", package)
        self.assertIn('assets/dmg-trust-evidence/receipt.json" >> "$GITHUB_ENV"', package)
        self.assertIn("path: ${{ env.DMG_TRUST_EVIDENCE }}", package)
        self.assertNotIn("submitted.dmg", package)
        self.assertNotIn("path: ${{ env.RELEASE_DMG_RECOVERY_ROOT }}", package)
        self.assertLess(package.index("sh tools/package_release.sh"),
                        package.index("actions/upload-artifact"))
        self.assertNotIn("contents: write", package)
        self.assertNotIn("actions/checkout", publish)
        self.assertIn("contents: write", publish)
        self.assertIn("environment: release-publication", publish)
        self.assertIn("commit: ${{ steps.package.outputs.commit }}", package)
        self.assertIn("printf 'commit=%s\\n' \"$EXPECTED_COMMIT\" >> \"$GITHUB_OUTPUT\"", package)
        self.assertIn("EXPECTED_COMMIT: ${{ needs.package.outputs.commit }}", publish)

    def test_publication_prerequisite_with_installed_cli_and_missing_cli(self):
        block = WORKFLOW.split("      - name: Verify and attach exact assets\n", 1)[1]
        script = textwrap.dedent(block.split("        run: |\n", 1)[1])
        prerequisite, publication = script.split('cd "$DIST"\n', 1)
        self.assertIn("gh --version", prerequisite)
        self.assertNotIn("gh api", prerequisite)
        self.assertNotIn("gh release", prerequisite)
        self.assertIn("gh api", publication)
        actual = subprocess.run(["gh", "--version"], capture_output=True, text=True, timeout=10)
        self.assertEqual(actual.returncode, 0, actual.stderr)
        self.assertRegex(actual.stdout.splitlines()[0], r"^gh version 2\.102\.1 \(")
        result = subprocess.run(["/bin/bash", "-c", prerequisite],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        missing_environment = {**os.environ, "PATH": "/usr/bin:/bin"}
        tools = subprocess.run(
            ["/bin/bash", "-c", "command -v awk && ! command -v gh"],
            env=missing_environment, capture_output=True, text=True, timeout=10)
        self.assertEqual(tools.returncode, 0, tools.stdout + tools.stderr)
        self.assertIn("/usr/bin/awk", tools.stdout)
        missing = subprocess.run(["/bin/bash", "-c", prerequisite],
                                 env=missing_environment, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("GitHub CLI 2.102.1 must be provisioned", missing.stderr)

    def test_publish_exact_manifest_and_release_failure_paths(self):
        block = WORKFLOW.split("      - name: Verify and attach exact assets\n", 1)[1]
        script = textwrap.dedent(block.split("        run: |\n", 1)[1])
        script = 'set -euo pipefail\ncd "$DIST"\n' + script.split('cd "$DIST"\n', 1)[1]
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
