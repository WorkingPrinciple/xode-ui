#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Neutral component inventory and no-submit production gate regressions."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from distribution_manifest import (COMPONENT_PATHS, distribution_blockers,
                                   require_distribution_ready, write_manifest)
from package_resources import RUNTIME_RESOURCES
import release_candidate as release


class DistributionChecks(unittest.TestCase):
    def fixture(self, root):
        app = root / "Neutral.app"
        for relative in COMPONENT_PATHS.values():
            path = app / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"Never executed neutral component")
        management = app / "Contents/Resources/XodusAppFoundation_XodusManagement.bundle"
        for relative in RUNTIME_RESOURCES:
            path = management / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("{}" if path.suffix == ".json" else "Neutral notice")
        archive = root / "source.tar"
        archive.write_bytes(b"Neutral source archive identity")
        source = {"commit": "a" * 40, "tree": "b" * 40}
        write_manifest(app, source, source, archive)
        return app, management

    def resolve_fixture_obligations(self, app):
        path = app / "Contents/Resources/distribution-components.json"
        data = json.loads(path.read_text())
        data["unresolved"] = []
        for component in data["components"].values():
            component["rightsReview"] = "resolved"
            component["correspondingSource"] = "neutral-source-delivery-fixture"
        path.write_text(json.dumps(data))

    def test_inventory_binds_components_and_leaves_unknowns_explicit(self):
        with tempfile.TemporaryDirectory() as tmp:
            app, _ = self.fixture(Path(tmp).resolve())
            path = app / "Contents/Resources/distribution-components.json"
            data = json.loads(path.read_text())
            self.assertEqual(set(data["components"]), set(COMPONENT_PATHS))
            self.assertEqual(data["components"]["cli"]["license"], "unresolved")
            self.assertTrue(data["unresolved"])
            with self.assertRaisesRegex(ValueError, "source/rights"):
                require_distribution_ready(app)

    def test_development_runtime_paths_block_production_without_disclosing_values(self):
        for private in ("/Users/neutral/runtime", "${HOME}/src/copilot-worktrees/engine", ".copilot/session-state/private"):
            with self.subTest(private=private), tempfile.TemporaryDirectory() as tmp:
                app, management = self.fixture(Path(tmp).resolve())
                self.resolve_fixture_obligations(app)
                resource = management / "LaunchRecipes/engine-defaults-v1.json"
                resource.write_text(json.dumps({"bindings": [{"registryPath": private}]}))
                blockers = distribution_blockers(app)
                self.assertEqual(len(blockers), 1)
                self.assertIn("engine-defaults-v1.json", blockers[0])
                self.assertNotIn(private, blockers[0])
                with self.assertRaisesRegex(ValueError, "Development-machine"):
                    require_distribution_ready(app)

    def test_changed_binary_and_removed_notice_are_not_admitted(self):
        for target in ("Contents/MacOS/Xodus", "Contents/Resources/XodusAppFoundation_XodusManagement.bundle/CompatibilityData/AWACY-LICENSE.txt"):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as tmp:
                app, _ = self.fixture(Path(tmp).resolve())
                (app / target).write_bytes(b"Altered")
                with self.assertRaises(ValueError):
                    distribution_blockers(app)

    def test_unresolved_package_cannot_start_archive_or_external_submission(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            app, _ = self.fixture(root)
            with patch.object(release, "execute") as execute, patch.object(release, "notarize") as notarize:
                with self.assertRaises(ValueError):
                    release.distribute(app, root, {}, root / "receipt.json", "c" * 40, "notary")
                execute.assert_not_called()
                notarize.assert_not_called()

    def test_neutral_resolved_inventory_and_portable_policy_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            app, _ = self.fixture(Path(tmp).resolve())
            self.resolve_fixture_obligations(app)
            self.assertEqual(distribution_blockers(app), [])


if __name__ == "__main__":
    unittest.main()
