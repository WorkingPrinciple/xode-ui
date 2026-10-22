"""Deterministic guard tests only; none launches Wine or a game."""

import importlib.util
import copy
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import MagicMock, patch


SPEC = importlib.util.spec_from_file_location(
    "retention", Path(__file__).with_name("retention-run.py")
)
retention = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(retention)


class RetentionTests(unittest.TestCase):
    def bound_fixture(self, base):
        base = base.resolve()
        world, _ = self.fixture(base)
        root = base / "title-save"
        source = base / "original-source"
        source.write_bytes(b"original runner")
        selected = {
            "phase": "reload", "prefix": str(base / "prefix"),
            "stateDir": str(base / "fresh-reload/launch"),
            "argv": ["cli", "--state-dir", str(base / "fresh-reload/launch"),
                     "--timeout-seconds", "600"],
            "environment": {}, "unsetEnvironment": [], "titleEnvironment": {},
        }
        original_reload = copy.deepcopy(selected)
        original_reload["argv"][-1] = "300"
        original = {
            "sourceHashes": {str(source): retention.sha(source)},
            "saveRoots": [str(root)],
            "phases": [
                {"phase": "world", "stateDir": str(world / "launch")},
                original_reload,
            ],
        }
        packet_path = base / "original.json"
        packet_path.write_text(json.dumps(original))
        receipt_path = world / "run-receipt.json"
        receipt = json.loads(receipt_path.read_text())
        receipt["packetSha256"] = retention.sha(packet_path)
        receipt_path.write_text(json.dumps(receipt))
        (world / "integrity.json").write_text(json.dumps({
            str(path.relative_to(world)): retention.sha(path)
            for path in world.rglob("*") if path.is_file()
        }))
        packet = {
            "saveRoots": [str(root)],
            "reloadWorldBinding": {
                "originalPacketPath": str(packet_path),
                "originalPacketSha256": retention.sha(packet_path),
                "worldBase": str(world),
                "receiptSha256": retention.sha(receipt_path),
                "observationSha256": retention.sha(world / "manual-observation.json"),
                "integritySha256": retention.sha(world / "integrity.json"),
            },
        }
        return packet, selected, [root], world, source

    def test_bound_reload_reuses_original_world_without_receipt_rewrite(self):
        with TemporaryDirectory() as temporary:
            packet, selected, roots, world, source = self.bound_fixture(Path(temporary))
            original_receipt = (world / "run-receipt.json").read_bytes()
            snapshot = source.with_name("frozen-source")
            snapshot.write_bytes(source.read_bytes())
            source.write_bytes(b"new runner implementation")
            packet["reloadWorldBinding"]["sourceSnapshots"] = {str(source): str(snapshot)}
            result = retention.authorize_bound_reload(packet, selected, roots)
            self.assertEqual(len(retention.content(result)), 1)
            self.assertEqual((world / "run-receipt.json").read_bytes(), original_receipt)

    def test_bound_reload_rejects_changed_evidence_source_payload_and_recipe(self):
        for mutation in (
            "packet", "receipt", "observation", "integrity", "archive", "before",
            "source", "snapshot", "save", "save-redirect", "recipe", "roots",
            "redirect", "world-mismatch", "forced",
        ):
            with self.subTest(mutation=mutation), TemporaryDirectory() as temporary:
                packet, selected, roots, world, source = self.bound_fixture(Path(temporary))
                if mutation == "packet":
                    Path(packet["reloadWorldBinding"]["originalPacketPath"]).write_text("{}")
                elif mutation == "receipt":
                    (world / "run-receipt.json").write_text("{}")
                elif mutation == "observation":
                    (world / "manual-observation.json").write_text("{}")
                elif mutation == "integrity":
                    (world / "integrity.json").write_text("{}")
                elif mutation == "archive":
                    (world / "saves-after/0/progress.xgs").write_bytes(b"changed")
                elif mutation == "before":
                    (world / "before-launch.json").write_text("[]")
                elif mutation == "source":
                    source.write_bytes(b"changed")
                elif mutation == "snapshot":
                    alias = source.with_name("snapshot-alias")
                    alias.symlink_to(source)
                    packet["reloadWorldBinding"]["sourceSnapshots"] = {str(source): str(alias)}
                elif mutation == "save":
                    (roots[0] / "progress.xgs").write_bytes(b"changed")
                elif mutation == "save-redirect":
                    save = roots[0] / "progress.xgs"
                    target = world.parent / "redirected-save"
                    target.write_bytes(save.read_bytes())
                    save.unlink()
                    save.symlink_to(target)
                elif mutation == "recipe":
                    selected["argv"][0] = "other-cli"
                elif mutation == "roots":
                    packet["saveRoots"] = []
                elif mutation == "redirect":
                    alias = world.parent / "redirected-world"
                    alias.symlink_to(world, target_is_directory=True)
                    packet["reloadWorldBinding"]["worldBase"] = str(alias)
                elif mutation == "world-mismatch":
                    packet["reloadWorldBinding"]["worldBase"] = str(world.parent / "other-world")
                else:
                    (world / "external-stop-reason.json").write_text(json.dumps({
                        "forcedStop": True, "reason": "external stop",
                    }))
                with self.assertRaises(RuntimeError):
                    retention.authorize_bound_reload(packet, selected, roots)

    def test_bound_reload_allows_changed_logs_but_only_returns_gameplay_marker(self):
        with TemporaryDirectory() as temporary:
            packet, selected, roots, world, _ = self.bound_fixture(Path(temporary))
            (roots[0] / "stdout.log").write_bytes(b"later attempt diagnostic log")
            result = retention.authorize_bound_reload(packet, selected, roots)
            self.assertEqual(list(retention.content(result)), [(str(roots[0]), "progress.xgs")])

    def test_bound_reload_rechecks_archived_before_launch_identity(self):
        with TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            packet, selected, roots, _, _ = self.bound_fixture(base)
            packet.update(hold="unit test; no launch", diskFloorBeforeLaunchGiB=0)
            previous = retention.authorize_bound_reload(packet, selected, roots)
            (roots[0] / "progress.xgs").write_bytes(b"changed after authorization")
            with patch("sys.argv", [
                "retention-run.py", "run", str(base / "fresh.json"),
                "frozen", "reload", "--screen-release", "unit test",
            ]), patch.object(retention, "load_packet", return_value=(packet, selected, roots)), \
                patch.object(retention, "authorize_bound_reload", return_value=previous), \
                patch.object(retention.subprocess, "Popen") as launch:
                with self.assertRaisesRegex(RuntimeError, "continuity"):
                    retention.main()
                launch.assert_not_called()

    def test_snapshot_copies_bytes_and_hashes(self):
        with TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "title-save"
            root.mkdir()
            (root / "progress.xgs").write_bytes(b"retained progress")
            result = retention.snapshot([root, base / "absent"], base / "archive")
            entry, = result[0]["files"]
            self.assertEqual(entry["sha256"], retention.sha(root / "progress.xgs"))
            self.assertEqual(
                (base / "archive" / entry["archive"]).read_bytes(),
                b"retained progress",
            )
            self.assertFalse(result[1]["exists"])

    def test_snapshot_does_not_follow_symlink_payload(self):
        with TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "title-save"
            root.mkdir()
            (base / "foreign").write_text("not title-owned")
            (root / "link").symlink_to(base / "foreign")
            result = retention.snapshot([root], base / "archive")
            self.assertEqual(result[0]["files"], [])

    def fixture(self, base):
        root = base / "title-save"
        root.mkdir()
        (root / "progress.xgs").write_bytes(b"retained progress")
        world = base / "run-world"
        world.mkdir()
        screenshot = world / "observed-menu-and-gameplay.png"
        screenshot.write_bytes(b"unit-test archive integrity stand-in, not gameplay")
        after = retention.snapshot([root], world / "saves-after")
        documents = {
            "run-receipt.json": {
                "packetSha256": "frozen", "forcedCleanup": None,
                "prefixStopped": True, "cliExitCode": 0,
                "canonicalResult": {"success": True, "wine_exit_code": 0},
            },
            "manual-observation.json": {
                "gameplayObserved": True, "ordinaryQuitObserved": True,
                "screenshots": [{
                    "path": screenshot.name, "sha256": retention.sha(screenshot),
                }],
                "gameplaySaveFiles": [{"root": str(root), "path": "progress.xgs"}],
            },
            "before-launch.json": [{"root": str(root), "exists": True, "files": []}],
            "after-process-exit.json": after,
        }
        for name, value in documents.items():
            (world / name).write_text(json.dumps(value))
        return world, documents

    def test_reload_requires_raw_world_archive_and_observation(self):
        with TemporaryDirectory() as temporary:
            base = Path(temporary)
            world, _ = self.fixture(base)
            self.assertTrue(retention.authorize_reload(base, "frozen"))
            (world / "saves-after/0/progress.xgs").write_bytes(b"changed")
            with self.assertRaisesRegex(RuntimeError, "archive"):
                retention.authorize_reload(base, "frozen")

    def test_forced_exit_cannot_qualify_reload(self):
        with TemporaryDirectory() as temporary:
            base = Path(temporary)
            world, documents = self.fixture(base)
            receipt = documents["run-receipt.json"]
            receipt["forcedCleanup"] = "cap"
            (world / "run-receipt.json").write_text(json.dumps(receipt))
            with self.assertRaisesRegex(RuntimeError, "ordinary-stop"):
                retention.authorize_reload(base, "frozen")

    def test_unobserved_quit_blocks_reload(self):
        with TemporaryDirectory() as temporary:
            base = Path(temporary)
            world, documents = self.fixture(base)
            observation = documents["manual-observation.json"]
            observation["ordinaryQuitObserved"] = False
            (world / "manual-observation.json").write_text(json.dumps(observation))
            with self.assertRaisesRegex(RuntimeError, "ordinary quit"):
                retention.authorize_reload(base, "frozen")

    def test_historical_null_forced_cleanup_cannot_override_external_stop(self):
        with TemporaryDirectory() as temporary:
            base = Path(temporary)
            world, _ = self.fixture(base)
            original = (world / "run-receipt.json").read_bytes()
            (world / "external-stop-reason.json").write_text(json.dumps({
                "forcedStop": True, "reason": "first failed input step",
            }))
            with self.assertRaisesRegex(RuntimeError, "ordinary-stop"):
                retention.authorize_reload(base, "frozen")
            self.assertEqual((world / "run-receipt.json").read_bytes(), original)

    def test_unchanged_payload_blocks_reload(self):
        with TemporaryDirectory() as temporary:
            base = Path(temporary)
            world, documents = self.fixture(base)
            (world / "before-launch.json").write_text(
                json.dumps(documents["after-process-exit.json"])
            )
            with self.assertRaisesRegex(RuntimeError, "did not change"):
                retention.authorize_reload(base, "frozen")

    def test_changed_screenshot_blocks_reload(self):
        with TemporaryDirectory() as temporary:
            base = Path(temporary)
            world, _ = self.fixture(base)
            (world / "observed-menu-and-gameplay.png").write_bytes(b"changed")
            with self.assertRaisesRegex(RuntimeError, "screenshot"):
                retention.authorize_reload(base, "frozen")

    def packet_fixture(self, base):
        prefix = base / "prefix"
        prefix.mkdir()
        source = base / "source"
        source.write_bytes(b"frozen executable identity stand-in")
        packet = base / "packet.json"
        packet.write_text(json.dumps({
            "sourceHashes": {str(source): retention.sha(source)},
            "saveRoots": [str(prefix / "title-save")],
            "phases": [{
                "phase": "world", "prefix": str(prefix),
                "stateDir": str(base / "run-world" / "launch"),
            }],
        }))
        return packet, source

    def test_source_drift_blocks_before_state_creation(self):
        with TemporaryDirectory() as temporary:
            base = Path(temporary)
            packet, source = self.packet_fixture(base)
            source.write_bytes(b"changed")
            with self.assertRaisesRegex(RuntimeError, "identity changed"):
                retention.load_packet(packet, retention.sha(packet), "world")
            self.assertFalse((base / "run-world").exists())

    def test_consumed_state_parent_blocks_replay(self):
        with TemporaryDirectory() as temporary:
            base = Path(temporary)
            packet, _ = self.packet_fixture(base)
            (base / "run-world").mkdir()
            with self.assertRaisesRegex(RuntimeError, "consumed"):
                retention.load_packet(packet, retention.sha(packet), "world")

    def test_save_root_escape_blocks_preflight(self):
        with TemporaryDirectory() as temporary:
            base = Path(temporary)
            packet, _ = self.packet_fixture(base)
            value = json.loads(packet.read_text())
            value["saveRoots"] = [str(base / "unowned")]
            packet.write_text(json.dumps(value))
            with self.assertRaisesRegex(RuntimeError, "outside"):
                retention.load_packet(packet, retention.sha(packet), "world")

    def test_external_forced_stop_is_not_normal_exit(self):
        with TemporaryDirectory() as temporary:
            base = Path(temporary)
            self.assertIsNone(retention.external_stop_reason(base))
            (base / "external-consent-stop.json").write_text(json.dumps({
                "reason": "HUMAN_CONSENT_HOLD", "forcedCleanup": True,
            }))
            self.assertEqual(
                retention.external_stop_reason(base), "HUMAN_CONSENT_HOLD"
            )

    def test_normal_cli_completion_reconciles_external_stop(self):
        for name, flag in (
            ("external-consent-stop.json", "forcedCleanup"),
            ("external-stop-reason.json", "forcedStop"),
            (None, None),
        ):
            with self.subTest(receipt=name), TemporaryDirectory() as temporary:
                base = Path(temporary)
                evidence = base / "run-world"
                selected = {
                    "stateDir": str(evidence / "launch"),
                    "prefix": str(base / "prefix"),
                    "argv": ["never-executed"],
                    "environment": {"WINESERVER": "never-executed"},
                    "titleEnvironment": {}, "unsetEnvironment": [],
                    "quitBySeconds": 540, "timeoutSeconds": 900,
                }
                packet = {
                    "hold": "unit test; no launch",
                    "diskFloorBeforeLaunchGiB": 0,
                }
                process = MagicMock(returncode=0, pid=123)
                process.poll.return_value = 0
                original_write = retention.write

                def write_with_external_stop(path, value):
                    original_write(path, value)
                    if path.name == "invocation.json" and name:
                        original_write(evidence / name, {
                            flag: True, "reason": "explicit external input-failure stop",
                        })

                with patch("sys.argv", [
                    "retention-run.py", "run", str(base / "packet.json"),
                    "frozen", "world", "--screen-release", "unit test",
                ]), patch.object(retention, "load_packet", return_value=(packet, selected, [])), \
                    patch.object(retention, "snapshot", return_value=[]), \
                    patch.object(retention, "cleanup", return_value=[{"returncode": 0}]), \
                    patch.object(retention, "write", side_effect=write_with_external_stop), \
                    patch.object(retention.subprocess, "Popen", return_value=process):
                    retention.main()
                receipt = json.loads((evidence / "run-receipt.json").read_text())
                self.assertEqual(receipt["cliExitCode"], 0)
                self.assertEqual(
                    receipt["forcedCleanup"],
                    "explicit external input-failure stop" if name else None,
                )
                self.assertTrue(receipt["prefixStopped"])

    def test_external_stop_rejects_missing_attribution(self):
        with TemporaryDirectory() as temporary:
            base = Path(temporary)
            path = base / "external-stop-reason.json"
            for value in (
                {"reason": "unattributed"},
                {"forcedStop": True, "reason": ""},
                {"forcedStop": True, "reason": 123},
            ):
                path.write_text(json.dumps(value))
                with self.assertRaisesRegex(RuntimeError, "attribution"):
                    retention.external_stop_reason(base)

    def external_mapping_fixture(self, base):
        packet, _ = self.packet_fixture(base)
        target = base / "host-documents" / "My Games" / "title"
        target.mkdir(parents=True)
        documents = base / "prefix/drive_c/users/crossover/Documents"
        documents.parent.mkdir(parents=True)
        documents.symlink_to(base / "host-documents", target_is_directory=True)
        value = json.loads(packet.read_text())
        value["saveRoots"] = [str(target)]
        value["externalSaveMappings"] = [{
            "prefixPath": str(documents / "My Games/title"),
            "resolvedPath": str(target),
        }]
        packet.write_text(json.dumps(value))
        return packet, documents

    def test_explicit_title_owned_host_save_mapping_is_archived(self):
        with TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            packet, _ = self.external_mapping_fixture(base)
            _, _, roots = retention.load_packet(packet, retention.sha(packet), "world")
            (roots[0] / "slot").write_bytes(b"host title progress")
            snapshot = retention.snapshot(roots, base / "archive")
            self.assertEqual(snapshot[0]["files"][0]["bytes"], 19)

    def test_host_save_mapping_redirect_is_rejected(self):
        with TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            packet, documents = self.external_mapping_fixture(base)
            documents.unlink()
            documents.symlink_to(base / "other", target_is_directory=True)
            with self.assertRaisesRegex(RuntimeError, "identity changed"):
                retention.load_packet(packet, retention.sha(packet), "world")

    def test_host_documents_parent_is_not_a_title_mapping(self):
        with TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            packet, documents = self.external_mapping_fixture(base)
            value = json.loads(packet.read_text())
            value["saveRoots"] = [str(documents.resolve())]
            value["externalSaveMappings"] = [{
                "prefixPath": str(documents), "resolvedPath": str(documents.resolve()),
            }]
            packet.write_text(json.dumps(value))
            with self.assertRaisesRegex(RuntimeError, "title-owned"):
                retention.load_packet(packet, retention.sha(packet), "world")


if __name__ == "__main__":
    unittest.main()
