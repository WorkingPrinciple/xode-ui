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

from build_local_candidate import build_evidence, source_identity, validate_host
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
