#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Neutral resource packaging checks; no application or network execution."""
import json
from pathlib import Path
import tempfile
import unittest

from package_resources import (ENGINE_DEFAULTS, PRIVATE_QA_RESOURCES, RUNTIME_RESOURCES, TITLE_PROFILES,
                               copy_resources, inventory, resource_layout, verify_resources)

SOURCE_TREE = "${HOME}/src/copilot-worktrees/example/branch/build/engine.registry.json"
APP_SUPPORT = "${HOME}/Library/Application Support/XodusCLI/renderers/engine.registry.json"
ENGINE_DEFAULTS_FIXTURE = json.dumps({"version": 1, "defaultEngine": "release", "bindings": [
    {"engineName": "release", "wineSha256": "a" * 64, "wineserverSha256": "b" * 64},
    {"engineName": "source-tree", "registryPath": SOURCE_TREE, "developerLocal": True},
    {"engineName": "app-support", "registryPath": APP_SUPPORT, "developerLocal": True}]}).encode()
TITLE_PROFILES_FIXTURE = json.dumps({"version": 1, "profiles": [
    {"productID": "A", "engine": "release"},
    {"productID": "B", "engine": "source-tree", "preservedPrefixPath": "${HOME}/prefixes/internal-qa-name"},
    {"productID": "C", "engine": "app-support"}]}).encode()


class PackageResourceChecks(unittest.TestCase):
    def fixture(self, root, nested):
        source = root / "source.bundle"
        layout = source / "Contents/Resources" if nested else source
        for name in RUNTIME_RESOURCES | PRIVATE_QA_RESOURCES:
            path = layout / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(ENGINE_DEFAULTS_FIXTURE if name == ENGINE_DEFAULTS
                             else TITLE_PROFILES_FIXTURE if name == TITLE_PROFILES
                             else b"Neutral resource fixture")
        if nested:
            (source / "Contents/Info.plist").write_bytes(b"Neutral bundle metadata")
        return source, layout

    def test_both_layouts_keep_runtime_and_notice_but_exclude_qa(self):
        for nested in (False, True):
            with self.subTest(nested=nested), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp).resolve()
                source, _ = self.fixture(root, nested)
                destination = root / "output.bundle"
                copy_resources(source, destination)
                self.assertEqual(inventory(resource_layout(destination)), RUNTIME_RESOURCES)

    def test_missing_unknown_and_linked_inputs_fail_before_copy(self):
        for mutation in ("missing", "unknown", "symlink"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp).resolve()
                source, layout = self.fixture(root, True)
                if mutation == "missing":
                    (layout / "management-v1.schema.json").unlink()
                elif mutation == "unknown":
                    (layout / "private-proof.json").write_bytes(b"Not shippable")
                else:
                    path = layout / "CompatibilityData/next-30-queue.json"
                    path.unlink()
                    path.symlink_to(layout / "management-v1.schema.json")
                with self.assertRaises(ValueError):
                    copy_resources(source, root / "output.bundle")
                self.assertFalse((root / "output.bundle").exists())

    def test_verifier_rejects_qa_reintroduced_after_copy(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            source, _ = self.fixture(root, True)
            destination = root / "output.bundle"
            copy_resources(source, destination)
            (resource_layout(destination) / "CompatibilityData/queue-inspection-v1.json").write_bytes(b"QA")
            with self.assertRaises(ValueError):
                verify_resources(destination)

    def test_source_tree_engine_bindings_are_stripped_and_app_support_kept(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            source, _ = self.fixture(root, True)
            destination = root / "output.bundle"
            copy_resources(source, destination)
            staged = (resource_layout(destination) / ENGINE_DEFAULTS).read_text()
            names = [binding["engineName"] for binding in json.loads(staged)["bindings"]]
            self.assertEqual(names, ["release", "app-support"])
            self.assertNotIn("copilot-worktrees", staged)
            self.assertNotIn("${HOME}/src/", staged)

    def test_title_profiles_for_stripped_engines_are_not_packaged(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            source, _ = self.fixture(root, True)
            destination = root / "output.bundle"
            copy_resources(source, destination)
            staged = (resource_layout(destination) / TITLE_PROFILES).read_text()
            self.assertEqual([p["productID"] for p in json.loads(staged)["profiles"]], ["A", "C"])
            self.assertNotIn("internal-qa-name", staged)

    def test_verifier_rejects_developer_paths_in_any_staged_resource(self):
        for text in ("${HOME}/src/repo/file", "~/src/repo", "/x/copilot-worktrees/y", "/Users/name/src/repo"):
            with self.subTest(text=text), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp).resolve()
                source, _ = self.fixture(root, True)
                destination = root / "output.bundle"
                copy_resources(source, destination)
                (resource_layout(destination) / "mac-game-status-v1.json").write_text(text)
                with self.assertRaises(ValueError):
                    verify_resources(destination)

    def test_existing_destination_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            source, _ = self.fixture(root, True)
            destination = root / "output.bundle"
            destination.mkdir()
            with self.assertRaises(ValueError):
                copy_resources(source, destination)


if __name__ == "__main__":
    unittest.main()
