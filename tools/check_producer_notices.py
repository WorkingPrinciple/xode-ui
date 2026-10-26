#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Neutral, offline producer provenance and notice inventory regressions."""
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

from producer_notices import (
    _crate_manifest,
    add_supplement,
    digest,
    git_blob_sha1,
    notice_members,
    prepare,
    verify,
)


class NoticeChecks(unittest.TestCase):
    def test_crate_manifest_uses_archive_root_not_vcs_workspace_path(self):
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode="w") as stream:
            for name, data in {
                "objc2-foundation-0.3.2/.cargo_vcs_info.json":
                    json.dumps({"git": {"sha1": "f" * 40},
                                "path_in_vcs": "framework-crates/objc2-foundation"}).encode(),
                "objc2-foundation-0.3.2/Cargo.toml":
                    b'[package]\nname = "objc2-foundation"\nversion = "0.3.2"\nlicense = "MIT"\n',
            }.items():
                member = tarfile.TarInfo(name)
                member.size = len(data)
                stream.addfile(member, io.BytesIO(data))
        self.assertEqual(_crate_manifest(archive.getvalue())["name"], "objc2-foundation")

    def fixture(self, root):
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode="w:gz") as stream:
            for name, data in {"neutral-1.0.0/LICENSE": b"Neutral licence fixture",
                               "neutral-1.0.0/src/copying.rs": b"#![cfg(test)]",
                               "neutral-1.0.0/src/license.rs": b"not a notice",
                               "neutral-1.0.0/src/lib.rs": b"not a notice",
                               "neutral-1.0.0/.cargo_vcs_info.json":
                                   json.dumps({"git": {"sha1": "f" * 40},
                                               "path_in_vcs": ""}).encode()}.items():
                member = tarfile.TarInfo(name)
                member.size = len(data)
                stream.addfile(member, io.BytesIO(data))
        content = archive.getvalue()
        cache = root / "registry/cache/neutral"
        cache.mkdir(parents=True)
        (cache / "neutral-1.0.0.crate").write_bytes(content)
        package = {"name": "neutral", "version": "1.0.0", "id": "neutral-id",
                   "source": "registry+https://neutral.invalid", "license": "MIT"}
        metadata = json.dumps({"packages": [package]}).encode()
        events = json.dumps({"reason": "compiler-artifact", "package_id": "neutral-id"}).encode()
        manifest = {
            "source_commit": "a" * 40, "source_tree": "b" * 40,
            "binary_sha256": "c" * 64, "helper_sha256": "d" * 64,
            "evidence": {"post-build-native-metadata.json": {"sha256": digest(metadata)},
                         "release-artifacts.jsonl": {"sha256": digest(events)}},
        }
        for name, data in (("manifest.json", json.dumps(manifest).encode()),
                           ("metadata.json", metadata), ("events.jsonl", events)):
            (root / name).write_bytes(data)
        lock = ('[[package]]\nname = "neutral"\nversion = "1.0.0"\n'
                'source = "registry+https://neutral.invalid"\nchecksum = "' + digest(content) + '"\n')
        arguments = (root / "manifest.json", digest((root / "manifest.json").read_bytes()),
                     root / "metadata.json", root / "events.jsonl", root, root, root / "notices")

        def git(_source, *args):
            return ("b" * 40 + "\n").encode() if args[0] == "rev-parse" else lock.encode()
        return arguments, git, manifest

    def test_exact_archives_produce_notice_texts_and_no_source_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            args, git, manifest = self.fixture(root)
            with patch("producer_notices.git_bytes", side_effect=git):
                result = prepare(*args)
            self.assertEqual(len(result["packages"]), 1)
            self.assertTrue(result["packages"][0]["compiled"])
            self.assertEqual(result["packages"][0]["declaredLicense"], "MIT")
            self.assertEqual(len(result["packages"][0]["notices"]), 1)
            self.assertNotIn(str(root), (root / "notices/inventory.json").read_text())
            verify(root / "notices", result["producer"], manifest["binary_sha256"], manifest["helper_sha256"],
                   digest((root / "notices/inventory.json").read_bytes()))
            self.assertTrue(result["unresolved"])  # No inferred redistribution/source clearance.

    def test_changed_metadata_or_cached_archive_is_rejected(self):
        for target in ("metadata.json", "registry/cache/neutral/neutral-1.0.0.crate"):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp).resolve()
                args, git, _ = self.fixture(root)
                (root / target).write_bytes(b"changed")
                with patch("producer_notices.git_bytes", side_effect=git), self.assertRaises(ValueError):
                    prepare(*args)

    def test_wrong_producer_extra_file_and_changed_notice_fail_verification(self):
        for mutation in ("producer", "extra", "text"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp).resolve()
                args, git, manifest = self.fixture(root)
                with patch("producer_notices.git_bytes", side_effect=git):
                    result = prepare(*args)
                approved = digest((root / "notices/inventory.json").read_bytes())
                producer = result["producer"]
                if mutation == "producer":
                    producer = {"commit": "e" * 40, "tree": "f" * 40}
                elif mutation == "extra":
                    (root / "notices/unmapped").write_bytes(b"extra")
                else:
                    next((root / "notices/texts").glob("*.txt")).write_bytes(b"changed")
                with self.assertRaises(ValueError):
                    verify(root / "notices", producer, manifest["binary_sha256"], manifest["helper_sha256"],
                           approved)

    def test_deleted_packages_or_obligations_cannot_self_admit(self):
        for field in ("packages", "unresolved"):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp).resolve()
                args, git, manifest = self.fixture(root)
                with patch("producer_notices.git_bytes", side_effect=git):
                    result = prepare(*args)
                path = root / "notices/inventory.json"
                approved = digest(path.read_bytes())
                result[field] = []
                path.write_text(json.dumps(result))
                with self.assertRaises(ValueError):
                    verify(root / "notices", result["producer"], manifest["binary_sha256"],
                           manifest["helper_sha256"], approved)

    def test_inventory_needs_independent_expected_digest(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            args, git, manifest = self.fixture(root)
            with patch("producer_notices.git_bytes", side_effect=git):
                result = prepare(*args)
            with self.assertRaisesRegex(ValueError, "Independently approved"):
                verify(root / "notices", result["producer"], manifest["binary_sha256"],
                       manifest["helper_sha256"], None)

    def test_missing_cached_notice_is_named_not_fabricated(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            args, git, _ = self.fixture(root)
            (root / "registry/cache/neutral/neutral-1.0.0.crate").unlink()
            with patch("producer_notices.git_bytes", side_effect=git):
                result = prepare(*args)
            self.assertIn("neutral@1.0.0: exact source notice texts unavailable", result["unresolved"])
            self.assertEqual(result["packages"][0]["notices"], [])

    def test_archive_traversal_is_rejected_without_extracting(self):
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode="w") as stream:
            member = tarfile.TarInfo("../LICENSE")
            member.size = 1
            stream.addfile(member, io.BytesIO(b"x"))
        with self.assertRaisesRegex(ValueError, "Unsafe dependency"):
            notice_members(archive.getvalue())

    def test_upstream_notice_reuse_checks_current_lock_and_vcs_revision(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            args, git, manifest = self.fixture(root)
            with patch("producer_notices.git_bytes", side_effect=git):
                result = prepare(*args)
                upstream = root / "upstream"
                (upstream / "texts").mkdir(parents=True)
                text = b"Neutral exact-revision upstream notice\n"
                sha = digest(text)
                (upstream / "texts" / (sha + ".txt")).write_bytes(text)
                report = {
                    "version": 1,
                    "producer": {"commit": "9" * 40, "tree": "8" * 40},
                    "groups": [{
                        "repository": "https://github.com/neutral/project",
                        "revision": "f" * 40,
                        "packages": ["neutral@1.0.0"],
                        "notices": [{
                            "sourceURL": "https://raw.githubusercontent.com/neutral/project/"
                                         + "f" * 40 + "/LICENSE",
                            "gitBlob": git_blob_sha1(text),
                            "path": "texts/" + sha + ".txt",
                            "sha256": sha,
                            "bytes": len(text),
                        }],
                    }],
                }
                report_path = upstream / "inventory.json"
                report_path.write_text(json.dumps(report))
                report_sha = digest(report_path.read_bytes())
                from producer_notices import _merge_upstream_notices
                _merge_upstream_notices(root / "notices", result, root, root,
                                        upstream, report_sha)
            self.assertFalse(any("neutral@1.0.0: exact source notice" in item
                                for item in result["unresolved"]))
            self.assertEqual(result["packages"][0]["notices"][-1]["sourceRevision"], "f" * 40)
            self.assertEqual(result["supplementalProvenance"]["reportSHA256"], report_sha)

    def test_supplemental_evidence_is_content_addressed_and_verified(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            args, git, manifest = self.fixture(root)
            with patch("producer_notices.git_bytes", side_effect=git):
                result = prepare(*args)
                upstream = root / "upstream"
                upstream.mkdir()
                report = {"version": 1, "producer": result["producer"], "groups": []}
                report_path = upstream / "inventory.json"
                report_path.write_text(json.dumps(report))
                report_sha = digest(report_path.read_bytes())

                evidence_dir = root / "evidence"
                (evidence_dir / "texts").mkdir(parents=True)
                text = b"Neutral supplementary attribution\n"
                sha = digest(text)
                relative = "texts/" + sha + ".txt"
                (evidence_dir / relative).write_bytes(text)
                evidence = {
                    "producer": result["producer"],
                    "documents": [{
                        "id": "neutral-attribution",
                        "path": relative,
                        "sha256": sha,
                        "bytes": len(text),
                        "source": {
                            "kind": "upstream-git",
                            "revision": "f" * 40,
                            "sourcePath": "README.md",
                            "sourceURL": "https://raw.githubusercontent.com/neutral/project/"
                                         + "f" * 40 + "/README.md",
                            "gitBlobSHA1": git_blob_sha1(text),
                        },
                    }],
                    "packages": [],
                    "components": [{
                        "id": "neutral-component",
                        "name": "Neutral component",
                        "licenseEvidence": {"basis": "exact upstream attribution"},
                        "documents": ["neutral-attribution"],
                        "resolvesObligations": [],
                    }],
                    "sourceDelivery": {
                        "sourceArchive": {
                            "file": "xodus-cli-beta-1bcc1c42-source.tar",
                            "sha256": "6d7adbaf0998ab9a2c024f68cd3c2ad88bd173235872e790b462edd469a65f87",
                            "bytes": 8_980_480,
                            "producer": result["producer"],
                        },
                        "channels": [
                            {"id": "private-tester-zip", "status": "workflow-bound"},
                            {"id": "release-dmg", "status": "workflow-bound"},
                            {"id": "github-draft-release", "status": "pending-target"},
                        ],
                    },
                }
                evidence_path = evidence_dir / "evidence.json"
                evidence_path.write_text(json.dumps(evidence))
                evidence_sha = digest(evidence_path.read_bytes())
                result = add_supplement(root / "notices", upstream, report_sha,
                                        evidence_dir, evidence_sha, root, root)
            inventory_path = root / "notices/inventory.json"
            expected = digest(inventory_path.read_bytes())
            verified = verify(root / "notices", result["producer"],
                              manifest["binary_sha256"], manifest["helper_sha256"], expected)
            self.assertEqual(verified["components"][0]["notices"][0]["sha256"], sha)
            self.assertEqual(verified["sourceDelivery"]["channels"][-1]["status"],
                             "pending-target")


if __name__ == "__main__":
    unittest.main()
