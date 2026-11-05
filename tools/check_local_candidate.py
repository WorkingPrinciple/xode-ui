#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Local-candidate checks with neutral git fixtures and mocked platform metadata."""
from pathlib import Path
import copy
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import build_local_candidate
from build_local_candidate import build_evidence, source_identity, validate_host
from shipping_pair import FEATURES, PROFILE, PRODUCER, PRODUCER_TREE, owned_bytes, swift_pins


class LocalCandidateChecks(unittest.TestCase):
    def actual_candidate_stage(self, root):
        executable = os.environ.get("XODUS_RECIPE_TEST_CLI")
        expected = os.environ.get("XODUS_RECIPE_TEST_CLI_SHA256")
        if executable is None and expected is None:
            self.skipTest("An exact locally built CLI is required for the source-bound binding control")
        self.assertIsNotNone(executable)
        self.assertIsNotNone(expected)
        cli, _ = owned_bytes(executable, expected)
        project = Path(__file__).resolve().parent.parent
        paths = (
            "Sources/XodusPreview/NativeGameLifecycle.swift",
            "Sources/XodusPreview/NativeLaunchConfiguration.swift",
            "Sources/XodusManagement/Resources/LaunchRecipes/title-runtime-v1.json",
        )
        for relative in paths:
            destination = root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(project / relative, destination)
        return cli, paths

    def test_candidate_binding_preserves_real_title_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            cli, paths = self.actual_candidate_stage(root)
            before = {path: (root / path).read_bytes() for path in paths}
            old_catalogue = json.loads(before[paths[2]])
            self.assertNotEqual(cli["sha256"], old_catalogue["cliSha256"])
            receipt = build_local_candidate.bind_candidate_cli(root, cli["sha256"])
            after = {path: (root / path).read_bytes() for path in paths}
            new_catalogue = json.loads(after[paths[2]])
            self.assertEqual(new_catalogue, {**old_catalogue, "cliSha256": cli["sha256"]})
            self.assertEqual(old_catalogue["evidenceCliSha256"], new_catalogue["evidenceCliSha256"])
            self.assertEqual(old_catalogue["items"], new_catalogue["items"])
            self.assertIn(f'static let cliSHA256 = "{cli["sha256"]}"'.encode(), after[paths[0]])
            catalogue_hash = hashlib.sha256(after[paths[2]]).hexdigest()
            self.assertIn(catalogue_hash.encode(), after[paths[1]])
            self.assertEqual(receipt["targetCliSHA256"], cli["sha256"])
            for path in paths:
                self.assertEqual(receipt["sourceFiles"][path], hashlib.sha256(before[path]).hexdigest())
                self.assertEqual(receipt["generatedFiles"][path], hashlib.sha256(after[path]).hexdigest())

    def test_candidate_binding_rejects_inconsistent_real_source_before_writing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            cli, paths = self.actual_candidate_stage(root)
            config = root / paths[1]
            catalogue = root / paths[2]
            original_hash = hashlib.sha256(catalogue.read_bytes()).hexdigest().encode()
            config.write_bytes(config.read_bytes().replace(original_hash, b"0" * 64))
            before = {path: (root / path).read_bytes() for path in paths}
            with self.assertRaises(ValueError):
                build_local_candidate.bind_candidate_cli(root, cli["sha256"])
            self.assertEqual(before, {path: (root / path).read_bytes() for path in paths})

    def test_candidate_binding_rejects_bad_source_data_before_writing(self):
        for case in ("lifecycle-mismatch", "catalogue-mismatch", "malformed-json",
                     "duplicate-key", "invalid-evidence"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                cli, paths = self.actual_candidate_stage(root)
                lifecycle = root / paths[0]
                catalogue = root / paths[2]
                data = catalogue.read_bytes()
                values = json.loads(data)
                old_cli = values["cliSha256"].encode()
                if case == "lifecycle-mismatch":
                    lifecycle.write_bytes(lifecycle.read_bytes().replace(old_cli, b"0" * 64))
                elif case == "catalogue-mismatch":
                    catalogue.write_bytes(data.replace(old_cli, b"0" * 64))
                elif case == "malformed-json":
                    catalogue.write_bytes(b"{")
                elif case == "duplicate-key":
                    catalogue.write_bytes(b'{"cliSha256": "' + old_cli + b'",' + data[1:])
                else:
                    old_evidence = values["evidenceCliSha256"].encode()
                    catalogue.write_bytes(data.replace(old_evidence, b"invalid"))
                before = {path: (root / path).read_bytes() for path in paths}
                with self.assertRaises(ValueError):
                    build_local_candidate.bind_candidate_cli(root, cli["sha256"])
                self.assertEqual(before, {path: (root / path).read_bytes() for path in paths})

    def test_candidate_binding_rejects_bad_target_hash_before_writing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            _, paths = self.actual_candidate_stage(root)
            before = {path: (root / path).read_bytes() for path in paths}
            for value in ("", "A" * 64, "0" * 63, None):
                with self.subTest(value=value), self.assertRaises(ValueError):
                    build_local_candidate.bind_candidate_cli(root, value)
                self.assertEqual(before, {path: (root / path).read_bytes() for path in paths})

    def test_candidate_binding_rejects_linked_or_nonregular_source_before_writing(self):
        for index in range(3):
            for kind in ("symlink", "hardlink", "fifo"):
                with self.subTest(index=index, kind=kind), tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary).resolve()
                    cli, paths = self.actual_candidate_stage(root)
                    original = {path: (root / path).read_bytes() for path in paths}
                    selected = root / paths[index]
                    target = root / "linked-source"
                    if kind == "hardlink":
                        os.link(selected, target)
                    else:
                        selected.unlink()
                        if kind == "symlink":
                            target.write_bytes(original[paths[index]])
                            selected.symlink_to(target)
                        else:
                            os.mkfifo(selected)
                    with self.assertRaises(ValueError):
                        build_local_candidate.bind_candidate_cli(root, cli["sha256"])
                    for path in paths:
                        if path != paths[index] or kind != "fifo":
                            self.assertEqual((root / path).read_bytes(), original[path])
                    if kind != "fifo":
                        self.assertEqual(target.read_bytes(), original[paths[index]])

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
