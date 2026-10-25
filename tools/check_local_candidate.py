#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Local-candidate checks with neutral git fixtures and mocked platform metadata."""
from pathlib import Path
import copy
import json
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from build_local_candidate import (build_evidence, copy_engine_notice, copy_release_notices, source_build_number,
                                   source_identity, validate_host)
from shipping_pair import FEATURES, PROFILE, PRODUCER, PRODUCER_TREE, swift_pins


class LocalCandidateChecks(unittest.TestCase):
    def test_actual_build_features_and_profile(self):
        frames = [{"reason": "compiler-artifact", "target": {"name": name},
                   "profile": PROFILE, "features": features,
                   **({"executable": "/neutral/target/xodus-cli"} if name == "xodus-cli" else {})}
                  for name, features in FEATURES.items()]
        def encode(items):
            return b"neutral Cargo diagnostic\n" + b"\n".join(json.dumps(item).encode() for item in items)
        artifact, features = build_evidence(encode(frames))
        self.assertEqual(artifact["executable"], "/neutral/target/xodus-cli")
        self.assertEqual(features, FEATURES)
        changed = copy.deepcopy(frames)
        changed[0]["features"].append("plaintext")
        debug = copy.deepcopy(frames)
        debug[0]["profile"]["debug_assertions"] = True
        for bad in (frames[:-1], frames + [frames[0]], changed, debug):
            with self.assertRaises(ValueError):
                build_evidence(encode(bad))

    def test_requires_apple_silicon_host(self):
        for system, machine in (("Darwin", "x86_64"), ("Linux", "arm64")):
            with self.subTest(system=system, machine=machine), \
                    patch("platform.system", return_value=system), \
                    patch("platform.machine", return_value=machine):
                with self.assertRaises(ValueError):
                    validate_host()
        with patch("platform.system", return_value="Darwin"), \
                patch("platform.machine", return_value="arm64"):
            validate_host()

    def test_source_must_be_committed_and_clean(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            artifact = root / "source"
            artifact.write_text("Neutral fixture")
            subprocess.run(["git", "add", "source"], cwd=root, check=True)
            subprocess.run(["git", "-c", "user.name=Fixture",
                            "-c", "user.email=fixture@example.invalid",
                            "commit", "-qm", "fixture"], cwd=root, check=True)
            identity = source_identity(root)
            self.assertEqual(len(identity["commit"]), 40)
            self.assertEqual(len(identity["tree"]), 40)
            artifact.write_text("Changed fixture")
            with self.assertRaises(ValueError):
                source_identity(root)
            artifact.write_text("Neutral fixture")
            (root / "untracked").write_text("Untracked fixture")
            with self.assertRaises(ValueError):
                source_identity(root)

    def test_build_number_uses_clean_source_commit_count_and_exceeds_installed_build(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(["git", "-c", "user.name=Fixture",
                            "-c", "user.email=fixture@example.invalid",
                            "commit", "--allow-empty", "-qm", "first"], cwd=root, check=True)
            with self.assertRaisesRegex(ValueError, "build 2"):
                source_build_number(root)
            for index in range(2):
                subprocess.run(["git", "-c", "user.name=Fixture",
                                "-c", "user.email=fixture@example.invalid",
                                "commit", "--allow-empty", "-qm", f"follow-up {index}"],
                               cwd=root, check=True)
            self.assertEqual(source_build_number(root), 3)

    def test_release_notices_are_copied_from_source_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, resources = root / "source", root / "Resources"
            source.mkdir()
            resources.mkdir()
            for name, content in (("LICENSE", "GPL fixture"), ("NOTICE", "Notice fixture"),
                                  ("TRADEMARKS.md", "Trademark fixture")):
                (source / name).write_text(content, encoding="utf-8")
            copy_release_notices(source, resources)
            self.assertEqual((resources / "LICENSE.txt").read_text(), "GPL fixture")
            self.assertEqual((resources / "NOTICE.txt").read_text(), "Notice fixture")
            self.assertEqual((resources / "TRADEMARKS.md").read_text(), "Trademark fixture")

    def test_engine_notice_is_bundled_as_plain_text(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source, resources = root / "NOTICE", root / "Resources"
            resources.mkdir()
            source.write_text("Calimocho notice fixture\n", encoding="utf-8")
            record = copy_engine_notice(source, resources)
            self.assertEqual((resources / "EngineNotices/NOTICE.txt").read_text(),
                             "Calimocho notice fixture\n")
            self.assertEqual(record["bytes"], source.stat().st_size)
            source.write_bytes(b"\x00\xffbinary")
            with self.assertRaises(UnicodeDecodeError):
                copy_engine_notice(source, resources)

    def test_candidate_pins_do_not_change_release_defaults(self):
        arguments = ("a" * 40, "b" * 40, {"sha256": "c" * 64, "bytes": 20},
                     {"sha256": "d" * 64, "bytes": 30})
        release = swift_pins(*arguments)
        self.assertIn(f'producerCommit: "{PRODUCER}"', release)
        self.assertIn(f'producerTree: "{PRODUCER_TREE}"', release)
        candidate = swift_pins(*arguments, "e" * 40, "f" * 40)
        self.assertIn(f'producerCommit: "{"e" * 40}"', candidate)
        self.assertIn(f'producerTree: "{"f" * 40}"', candidate)
        self.assertEqual(swift_pins(*arguments), release)
        for commit, tree in (("bad", "f" * 40), ("e" * 40, "bad")):
            with self.subTest(commit=commit, tree=tree), self.assertRaises(ValueError):
                swift_pins(*arguments, commit, tree)


if __name__ == "__main__":
    unittest.main()
