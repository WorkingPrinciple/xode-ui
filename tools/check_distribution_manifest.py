#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Neutral component inventory and no-submit production gate regressions."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from distribution_manifest import (COMPONENT_PATHS, NMS_DEVELOPER_LOCAL_REGISTRY,
                                   distribution_blockers,
                                   require_distribution_ready, write_manifest)
from package_resources import RUNTIME_RESOURCES
from resource_inventory import (inspect_resources, inventory as resource_inventory)
from resource_inventory import developer_path_findings
import release_candidate as release

TEST_SIGNING_IDENTITY = "C" * 40


class DistributionChecks(unittest.TestCase):
    def setUp(self):
        self.approved_inventory_sha = None

    def fake_signature_inventory(self, app, identity, team_id):
        self.assertEqual(identity, TEST_SIGNING_IDENTITY)
        self.assertEqual(team_id, "M62Z4M5EUY")
        if (app / COMPONENT_PATHS["app"]).read_bytes() != b"Never executed neutral component":
            raise ValueError("Signed app verification failed")
        return {"app": {
            "identifier": "io.github.dragoshont.xodus",
            "teamIdentifier": team_id,
            "certificateSha1": identity,
            "cdhash": "d" * 40,
        }}

    def blockers(self, app):
        with patch("distribution_manifest.verify_developer_id_bundle",
                   side_effect=self.fake_signature_inventory):
            return distribution_blockers(app, self.approved_inventory_sha,
                                         expected_signing_identity=TEST_SIGNING_IDENTITY)

    def require_ready(self, app, approved_inventory_sha=None):
        with patch("distribution_manifest.verify_developer_id_bundle",
                   side_effect=self.fake_signature_inventory):
            return require_distribution_ready(
                app, approved_inventory_sha,
                expected_signing_identity=TEST_SIGNING_IDENTITY)

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
                self.require_ready(app)

    def test_signed_main_executable_is_not_bound_to_a_presign_hash(self):
        with tempfile.TemporaryDirectory() as tmp:
            app, _ = self.fixture(Path(tmp).resolve())
            metadata = json.loads(
                (app / "Contents/Resources/distribution-components.json").read_text())
            component = metadata["components"]["app"]
            self.assertNotIn("sha256", component)
            self.assertNotIn("bytes", component)
            self.assertEqual(component["signatureVerification"], {
                "identifier": "io.github.dragoshont.xodus",
                "teamIdentifier": "M62Z4M5EUY",
            })

    def test_signed_main_executable_is_verified_after_its_signature_changes_the_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            app, _ = self.fixture(Path(tmp).resolve())
            self.resolve_fixture_obligations(app)
            executable = app / COMPONENT_PATHS["app"]
            executable.write_bytes(b"Executable after code signing")
            with patch("distribution_manifest.verify_developer_id_bundle",
                       return_value={"app": {
                           "identifier": "io.github.dragoshont.xodus",
                           "teamIdentifier": "M62Z4M5EUY",
                           "certificateSha1": TEST_SIGNING_IDENTITY,
                           "cdhash": "d" * 40,
                       }}) as verify:
                blockers = distribution_blockers(
                    app, self.approved_inventory_sha,
                    expected_signing_identity=TEST_SIGNING_IDENTITY)
            self.assertEqual(blockers, [])
            verify.assert_called_once_with(
                app, TEST_SIGNING_IDENTITY, "M62Z4M5EUY")

    def test_old_presign_hash_schema_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            app, _ = self.fixture(Path(tmp).resolve())
            path = app / "Contents/Resources/distribution-components.json"
            metadata = json.loads(path.read_text())
            executable = app / COMPONENT_PATHS["app"]
            from shipping_pair import owned_bytes
            metadata["components"]["app"].update(owned_bytes(executable)[0])
            path.write_text(json.dumps(metadata))
            with self.assertRaisesRegex(ValueError, "not a pre-sign hash"):
                self.blockers(app)

    def test_distribution_preflight_requires_an_expected_signing_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            app, _ = self.fixture(Path(tmp).resolve())
            self.resolve_fixture_obligations(app)
            blockers = distribution_blockers(app, self.approved_inventory_sha)
            self.assertIn(
                "Expected Developer ID identity for app signature verification not supplied",
                blockers)

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
                with self.assertRaisesRegex(ValueError, "Development-machine reference|Developer source-tree") as error:
                    self.blockers(app)
                self.assertIn("engine-defaults-v1.json", str(error.exception))
                self.assertNotIn(private, str(error.exception))
                with self.assertRaisesRegex(ValueError, "Development-machine|Developer source-tree"):
                    self.require_ready(app)

    def test_the_former_nms_developer_local_binding_never_ships(self):
        # REQ-52 (review 2bca9f39): source-tree/worktree registry paths are stripped at staging and
        # refused in any staged resource, including the formerly approved NMS developer binding.
        with tempfile.TemporaryDirectory() as tmp:
            app, management = self.fixture(Path(tmp).resolve())
            self.resolve_fixture_obligations(app)
            resource = management / "LaunchRecipes/engine-defaults-v1.json"
            resource.write_text(json.dumps({"bindings": [{
                "registryPath": NMS_DEVELOPER_LOCAL_REGISTRY,
                "engineName": "calimocho-wine11.20-gptk4b3-tls-vulkan-private",
                "developerLocal": True,
            }]}))
            with self.assertRaisesRegex(ValueError, "Developer source-tree or worktree path") as error:
                self.blockers(app)
            self.assertNotIn(NMS_DEVELOPER_LOCAL_REGISTRY, str(error.exception))

    def test_resource_inventory_hashes_every_resource_and_rejects_qa_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            app, management = self.fixture(Path(tmp).resolve())
            (app / "Contents/Resources/distribution-components.json").unlink()
            value = resource_inventory(app)
            paths = {item["path"] for item in value["resources"]}
            self.assertIn("XodusAppFoundation_XodusManagement.bundle/LaunchRecipes/title-profiles-v1.json",
                          paths)
            self.assertTrue(all(item["classification"] == "runtime-needed"
                                and len(item["sha256"]) == 64 and item["bytes"] > 0
                                for item in value["resources"]))
            qa = management / "CompatibilityData/queue-inspection-v1.json"
            qa.write_text("{}")
            with self.assertRaisesRegex(ValueError, "QA/inspection JSON"):
                resource_inventory(app)

    def test_resource_audit_flags_paths_without_reclassifying_runtime_policy(self):
        with tempfile.TemporaryDirectory() as tmp:
            app, management = self.fixture(Path(tmp).resolve())
            (app / "Contents/Resources/distribution-components.json").unlink()
            resource = management / "LaunchRecipes/title-profiles-v1.json"
            resource.write_text(json.dumps({"receipt": "/Users/neutral"}))
            report = inspect_resources(app)
            item = next(entry for entry in report["resources"]
                        if entry["path"].endswith("title-profiles-v1.json"))
            self.assertEqual(item["classification"], "runtime-needed")
            self.assertEqual(item["issues"], ["developer-local path reference"])
            with self.assertRaisesRegex(ValueError, "Developer-local path"):
                resource_inventory(app)

    def test_resource_inventory_scans_non_json_resources_for_developer_paths(self):
        for name in ("NOTICE.txt", "Xodus.icns"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                app, _ = self.fixture(Path(tmp).resolve())
                (app / "Contents/Resources/distribution-components.json").unlink()
                path = app / "Contents/Resources" / name
                path.write_bytes(b"x" * 65_530 + b"/Users/neutral/private suffix")
                with self.assertRaisesRegex(ValueError, "Developer-local path"):
                    resource_inventory(app)

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
                self.require_ready(app, approved_inventory_sha=self.approved_inventory_sha)
            with self.assertRaises(ValueError), patch.object(release, "execute") as execute, \
                    patch.object(release, "notarize") as notarize, \
                    patch("distribution_manifest.verify_developer_id_bundle",
                          side_effect=self.fake_signature_inventory):
                release.distribute(app, root, {}, root / "receipt.json", TEST_SIGNING_IDENTITY, "notary",
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
                self.require_ready(app, approved_inventory_sha=None)


if __name__ == "__main__":
    unittest.main()
