"""Deterministic guard tests only; none launches Wine or a game."""

import importlib.util
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest


SPEC = importlib.util.spec_from_file_location(
    "retention", Path(__file__).with_name("retention-run.py")
)
retention = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(retention)


class RetentionTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
