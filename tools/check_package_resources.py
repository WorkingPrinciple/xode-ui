#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Neutral resource packaging checks; no application or network execution."""
from pathlib import Path
import tempfile
import unittest

from package_resources import (PRIVATE_QA_RESOURCES, RUNTIME_RESOURCES,
                               copy_resources, inventory, resource_layout, verify_resources)


class PackageResourceChecks(unittest.TestCase):
    def fixture(self, root, nested):
        source = root / "source.bundle"
        layout = source / "Contents/Resources" if nested else source
        for name in RUNTIME_RESOURCES | PRIVATE_QA_RESOURCES:
            path = layout / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"Neutral resource fixture")
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
