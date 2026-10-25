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
    def setUp(self):
        self.approved_inventory_sha = None

    def blockers(self, app):
        return distribution_blockers(app, self.approved_inventory_sha)

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
        if data["producerNotices"] is None:
            notices = app / "Contents/Resources/ProducerNotices"
            notices.mkdir()
            inventory = {
                "version": 1, "producer": data["components"]["cli"]["source"],
                "cliSHA256": data["components"]["cli"]["sha256"],
                "helperSHA256": data["components"]["windowsHelper"]["sha256"],
                "packages": [], "unresolved": [],
            }
            inventory_path = notices / "inventory.json"
            inventory_path.write_text(json.dumps(inventory))
            from shipping_pair import owned_bytes
            data["producerNotices"] = owned_bytes(inventory_path)[0]
        self.approved_inventory_sha = data["producerNotices"]["sha256"]
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

    def test_engine_notice_is_optional_but_bound_when_present(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            app, _ = self.fixture(root)
            resources = app / "Contents/Resources"
            receipt = resources / "distribution-components.json"
            receipt.unlink()
            notice = resources / "EngineNotices/NOTICE.txt"
            notice.parent.mkdir()
            notice.write_text("Calimocho release notice\n", encoding="utf-8")
            source = {"commit": "a" * 40, "tree": "b" * 40}
            write_manifest(app, source, source, root / "source.tar")
            metadata = json.loads(receipt.read_text())
            self.assertEqual(metadata["engineNotice"]["path"],
                             "Contents/Resources/EngineNotices/NOTICE.txt")
            self.assertEqual(metadata["engineNotice"]["bytes"], notice.stat().st_size)
            notice.write_text("Calimocho release Notice\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "hash|digest"):
                self.blockers(app)

    def test_unrecorded_engine_notice_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            app, _ = self.fixture(Path(tmp).resolve())
            notice = app / "Contents/Resources/EngineNotices/NOTICE.txt"
            notice.parent.mkdir()
            notice.write_text("Unrecorded notice\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "Unrecorded Calimocho NOTICE"):
                self.blockers(app)

    def test_development_runtime_paths_block_production_without_disclosing_values(self):
        for private in ("/Users/neutral/runtime", "${HOME}/src/copilot-worktrees/engine", ".copilot/session-state/private"):
            with self.subTest(private=private), tempfile.TemporaryDirectory() as tmp:
                app, management = self.fixture(Path(tmp).resolve())
                self.resolve_fixture_obligations(app)
                resource = management / "LaunchRecipes/engine-defaults-v1.json"
                resource.write_text(json.dumps({"bindings": [{"registryPath": private}]}))
                blockers = self.blockers(app)
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
                    self.blockers(app)

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
            self.assertEqual(self.blockers(app), [])

    def test_unmapped_executables_and_runtime_data_fail_closed(self):
        for relative in ("Contents/MacOS/Unmapped", "Contents/Frameworks/Extra.dylib",
                         "Contents/_CodeSignature/Unmapped",
                         "Contents/Resources/UnknownRuntime/data.json"):
            with self.subTest(relative=relative), tempfile.TemporaryDirectory() as tmp:
                app, _ = self.fixture(Path(tmp).resolve())
                self.resolve_fixture_obligations(app)
                extra = app / relative
                extra.parent.mkdir(parents=True, exist_ok=True)
                extra.write_bytes(b"unmapped payload")
                with self.assertRaisesRegex(ValueError, "Unmapped distribution payload"):
                    self.blockers(app)
                (app / "Contents/Resources/distribution-components.json").unlink()
                source = {"commit": "a" * 40, "tree": "b" * 40}
                with self.assertRaisesRegex(ValueError, "Unmapped distribution payload"):
                    write_manifest(app, source, source, Path(tmp).resolve() / "source.tar")

    def test_code_cannot_hide_in_allowlisted_noncode_resource(self):
        with tempfile.TemporaryDirectory() as tmp:
            app, _ = self.fixture(Path(tmp).resolve())
            (app / "Contents/Resources/LICENSE.txt").write_bytes(b"MZdisguised executable")
            with self.assertRaisesRegex(ValueError, "Executable content in non-code"):
                self.blockers(app)

    def test_missing_inventory_cannot_be_cleared_via_summary_obligations(self):
        with tempfile.TemporaryDirectory() as tmp:
            app, _ = self.fixture(Path(tmp).resolve())
            path = app / "Contents/Resources/distribution-components.json"
            data = json.loads(path.read_text())
            data["unresolved"] = []
            for component in data["components"].values():
                component["rightsReview"] = "resolved"
                component["correspondingSource"] = "neutral-fixture"
            path.write_text(json.dumps(data))
            self.assertEqual(self.blockers(app),
                             ["Exact producer dependency inventory/notices not supplied"])

    def test_optional_broker_reference_cannot_inherit_base_clearance(self):
        with tempfile.TemporaryDirectory() as tmp:
            app, _ = self.fixture(Path(tmp).resolve())
            manifest = app / "Contents/Resources/distribution-components.json"
            manifest.unlink()
            broker = app / "Contents/Resources/XodusCredentialBroker.json"
            broker.write_text(json.dumps({"version": 1, "sha256": "c" * 64, "bytes": 123}))
            source = {"commit": "a" * 40, "tree": "b" * 40}
            write_manifest(app, source, source, Path(tmp).resolve() / "source.tar")
            self.resolve_fixture_obligations(app)
            blockers = self.blockers(app)
            self.assertEqual(len(blockers), 1)
            self.assertIn("credentialBroker", blockers[0])
            broker.write_text(json.dumps({"version": 1, "sha256": "d" * 64, "bytes": 123}))
            with self.assertRaisesRegex(ValueError, "Optional distribution payload changed"):
                self.blockers(app)

    def test_python_inventory_is_verified_and_keeps_independent_obligations(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            app, _ = self.fixture(root)
            (app / "Contents/Resources/distribution-components.json").unlink()
            interpreter = app / "Contents/Resources/XodusPython/bin/python3"
            interpreter.parent.mkdir(parents=True)
            interpreter.write_bytes(b"neutral interpreter")
            from shipping_pair import owned_bytes
            metadata = {"files": {"bin/python3": owned_bytes(interpreter)[0]}}
            (app / "Contents/Resources/XodusPython.json").write_text(json.dumps(metadata))
            source = {"commit": "a" * 40, "tree": "b" * 40}
            with patch("python_runtime.verify_runtime") as verify:
                write_manifest(app, source, source, root / "source.tar")
                self.resolve_fixture_obligations(app)
                blockers = self.blockers(app)
                self.assertEqual(len(blockers), 1)
                self.assertIn("pythonRuntime", blockers[0])
                self.assertEqual(verify.call_count, 2)

    def test_new_optional_component_after_inventory_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            app, _ = self.fixture(Path(tmp).resolve())
            self.resolve_fixture_obligations(app)
            (app / "Contents/Resources/XodusCredentialBroker.json").write_text(
                json.dumps({"version": 1, "sha256": "c" * 64, "bytes": 123}))
            with self.assertRaisesRegex(ValueError, "Optional distribution inventory"):
                self.blockers(app)

    def test_producer_notices_are_copied_bound_and_keep_precise_obligations(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            app, _ = self.fixture(root)
            (app / "Contents/Resources/distribution-components.json").unlink()
            source = {"commit": "a" * 40, "tree": "b" * 40}
            from shipping_pair import owned_bytes
            identity = owned_bytes(app / COMPONENT_PATHS["cli"])[0]
            notices = root / "producer-notices"
            notices.mkdir()
            inventory = {
                "version": 1, "producer": source, "cliSHA256": identity["sha256"],
                "helperSHA256": identity["sha256"], "packages": [],
                "unresolved": ["Neutral exact component obligation"],
            }
            (notices / "inventory.json").write_text(json.dumps(inventory))
            approved = owned_bytes(notices / "inventory.json")[0]["sha256"]
            write_manifest(app, source, source, root / "source.tar", notices, approved)
            self.resolve_fixture_obligations(app)
            self.assertEqual(self.blockers(app), ["Neutral exact component obligation"])
            packaged = app / "Contents/Resources/ProducerNotices/inventory.json"
            packaged.write_text("{}")
            with self.assertRaises(ValueError):
                self.blockers(app)

    def test_resealed_inventory_deletion_does_not_override_external_approval(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            app, _ = self.fixture(root)
            self.resolve_fixture_obligations(app)
            inventory_path = app / "Contents/Resources/ProducerNotices/inventory.json"
            manifest_path = app / "Contents/Resources/distribution-components.json"
            inventory = json.loads(inventory_path.read_text())
            inventory["packages"] = [{"name": "tampered"}]
            inventory["unresolved"] = []
            inventory_path.write_text(json.dumps(inventory))
            manifest = json.loads(manifest_path.read_text())
            from shipping_pair import owned_bytes
            manifest["producerNotices"] = owned_bytes(inventory_path)[0]
            manifest["unresolved"] = []
            manifest_path.write_text(json.dumps(manifest))
            with self.assertRaises(ValueError):
                require_distribution_ready(app, self.approved_inventory_sha)
            with self.assertRaises(ValueError), patch.object(release, "execute") as execute, \
                    patch.object(release, "notarize") as notarize:
                release.distribute(app, root, {}, root / "receipt.json", "c" * 40, "notary",
                                   self.approved_inventory_sha)
            execute.assert_not_called()
            notarize.assert_not_called()

    def test_inventory_self_seal_is_not_distribution_approval(self):
        with tempfile.TemporaryDirectory() as tmp:
            app, _ = self.fixture(Path(tmp).resolve())
            self.resolve_fixture_obligations(app)
            self.assertIn("Independently approved producer inventory SHA-256 not supplied",
                          distribution_blockers(app))
            with self.assertRaises(ValueError):
                require_distribution_ready(app)


if __name__ == "__main__":
    unittest.main()
