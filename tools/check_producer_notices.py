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

from producer_notices import digest, notice_members, prepare, verify


class NoticeChecks(unittest.TestCase):
    def fixture(self, root):
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode="w:gz") as stream:
            for name, data in {"neutral-1.0.0/LICENSE": b"Neutral licence fixture",
                               "neutral-1.0.0/src/copying.rs": b"#![cfg(test)]",
                               "neutral-1.0.0/src/license.rs": b"not a notice",
                               "neutral-1.0.0/src/lib.rs": b"not a notice"}.items():
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


if __name__ == "__main__":
    unittest.main()
