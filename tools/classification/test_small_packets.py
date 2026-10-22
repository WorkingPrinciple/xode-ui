"""Expansion facts and candidate preflights; no network/install/launch in tests."""

import copy
import shlex
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from build_fast_path_packets import FIELDS
from build_small_packets import ORDER, build
from build_small_preflights import build as build_preflight
from inspect_queue import DATA, load_json
import stage_small_game


class SmallPacketTests(unittest.TestCase):
    def test_nine_new_bounded_candidates_reproduce_with_positive_proxy(self):
        packet = load_json(DATA / "s3-ready-packets-v5.json")
        inputs = copy.deepcopy(packet["collectionInputs"])
        self.assertEqual(build(inputs), packet)
        self.assertEqual(inputs, packet["collectionInputs"])
        self.assertEqual(len(packet["items"]), 9)
        self.assertEqual([row["storeId"] for row in packet["items"]], list(ORDER))
        original = load_json(DATA / "s3-ready-packets-v4.json")
        original_ids = {row["storeId"] for row in original["items"]}
        for row in packet["items"]:
            self.assertNotIn(row["storeId"], original_ids)
            self.assertNotIn(row["storeId"], inputs["excludedMatrixIds"])
            self.assertGreater(row["downloadSizeBytes"], 0)
            self.assertLessEqual(row["downloadSizeBytes"], 8 * 2**30)
            self.assertIn(row["public"]["protonDB"]["summary"]["tier"], {"platinum", "gold"})
            self.assertIsNone(row["numericProbability"])
            self.assertEqual(row["packageFormat"], "MSIXVC")
            self.assertEqual(set(row["fastPath"]["phases"]), set(FIELDS))
            self.assertIsNone(row["fastPath"]["phases"]["expected_minutes_to_save"]["value"])
            self.assertIsNone(row["windowTitle"])
            self.assertIsNone(row["saveLocation"])
            for phase in row["fastPath"]["phases"].values():
                self.assertEqual(phase["status"], "unknown" if phase["value"] is None else "public-expectation")
                self.assertTrue(phase["sources"])
                self.assertTrue(all(source["url"].startswith("https://")
                                    and source["checkedAt"] for source in phase["sources"]))

    def test_edition_cloud_and_retention_caveats_are_not_erased(self):
        packet = load_json(DATA / "s3-ready-packets-v5.json")
        rows = {row["storeId"]: row for row in packet["items"]}
        self.assertIn("unplayable", packet["rankCaveats"]["Vampire Survivors"])
        self.assertIn("Vulkan", packet["rankCaveats"]["Quake"])
        self.assertIsNone(rows["9P1Z43KRNQD4"]["profileProposal"]["name"])
        self.assertIsNone(rows["9MSVVM5NS9L6"]["save_path"])
        self.assertIsNone(rows["9PBWWQGXVMKC"]["save_path"])
        self.assertIn("Packages", rows["9P8NSTDMZ11P"]["save_path"])
        self.assertIn("NOT retention", " ".join(rows["9P8NSTDMZ11P"]["fastPath"]["warnings"]))
        self.assertFalse(packet["installPolicy"]["deletions"])
        self.assertEqual(packet["installPolicy"]["maximumSerialInstallers"], 1)

    def test_complete_preflight_is_literal_default_and_reproducible(self):
        packet = load_json(DATA / "s3-preflight-small-v1.json")
        with patch("subprocess.run", side_effect=AssertionError("No process")):
            self.assertEqual(build_preflight(packet["collectionInputs"]), packet)
        for row in packet["items"]:
            self.assertEqual(row["installStatus"]["status"], "complete")
            self.assertTrue(row["installStatus"]["success"])
            self.assertFalse(row["launch"]["executed"])
            self.assertEqual(row["launch"]["environment"], {})
            argv = row["launch"]["argv"]
            self.assertEqual(argv[1:3], ["launch", row["storeId"]])
            self.assertEqual(argv[argv.index("--exe") + 1],
                             row["package"]["executables"][0])
            self.assertEqual(shlex.split(row["launch"]["shellCommand"])[-len(argv):], argv)
            discovery = row["preflight"]["discovery"]
            self.assertIn("--discover", discovery["argv"])
            self.assertNotIn("--window-title", discovery["argv"])
            self.assertNotIn("--save-dir", discovery["argv"])
            self.assertFalse(discovery["saveRetentionPass"])
            self.assertEqual(row["s1Profile"]["binding"]["profile"], row["s1Profile"]["name"])
            self.assertEqual(row["s1Profile"]["status"], "persisted-S1-candidate-not-game-qualified")
        for row in packet["blockedItems"]:
            self.assertIsNone(row["launch"])
            self.assertFalse(row["readyForLaunch"])
        brotato = next((row for row in packet["blockedItems"]
                        if row["storeId"] == "9P9VNSQK1W3K"), None)
        if brotato:
            self.assertFalse(brotato["completeInAdf8Terms"])
            self.assertEqual(brotato["frozenStatusFailure"]["exitCode"], 101)

    def test_preflight_rejects_false_complete_and_registry_sta(self):
        packet = load_json(DATA / "s3-preflight-small-v1.json")
        inputs = copy.deepcopy(packet["collectionInputs"])
        sid = inputs["staged"][0]["storeId"]
        inputs["statuses"][sid]["exit_code"] = 1
        with self.assertRaisesRegex(ValueError, "complete"):
            build_preflight(inputs)
        inputs = copy.deepcopy(packet["collectionInputs"])
        for engine in inputs["registry"]["engines"]:
            if engine["name"] == packet["items"][0]["s1Profile"]["name"]:
                engine.setdefault("environment", {})["XODUS_PRIVATE_RUNTIME_COM_STA"] = "1"
        with self.assertRaisesRegex(ValueError, "COM policy"):
            build_preflight(inputs)

    def test_resume_exception_cannot_change_another_title(self):
        with patch("sys.argv", ["stage_small_game.py", "9P8NSTDMZ11P", "--resume-brotato"]):
            with self.assertRaisesRegex(ValueError, "Brotato only"):
                stage_small_game.main()

    def test_low_disk_never_spawns_or_writes_an_install(self):
        sid = "9MXND4PQLK3W"
        state = {"budgetBytes": 20 * 2**30, "minimumFreeBytes": 150 * 2**30,
                 "items": [{"storeId": "9P9VNSQK1W3K", "reservedBytes": 449249280}]}

        def fixture(path):
            if path.name == "s3-tried-games.json":
                return {"games": []}
            if path.name == "small-game-evidence-v1.json":
                return {"items": [{"storeId": sid, "title": "Unit fixture",
                                   "downloadSizeBytes": 2**30}]}
            return copy.deepcopy(state)

        with tempfile.TemporaryDirectory() as home:
            with (patch("sys.argv", ["stage_small_game.py", sid]),
                  patch("stage_small_game.Path.home", return_value=Path(home)),
                  patch("stage_small_game.sha", side_effect=lambda path: path.parent.name),
                  patch("stage_small_game.load_json", side_effect=fixture),
                  patch("stage_small_game.free_bytes", return_value=156 * 2**30),
                  patch("stage_small_game.write") as write,
                  patch("stage_small_game.subprocess.run") as process):
                with self.assertRaisesRegex(ValueError, "155 GiB"):
                    stage_small_game.main()
                write.assert_not_called()
                process.assert_not_called()

    def test_recorded_installs_preserve_floor_budget_and_brotato_exception(self):
        data = load_json(DATA / "small-game-staging-v1.json")
        self.assertLessEqual(sum(row["reservedBytes"] for row in data["items"]),
                             data["budgetBytes"])
        successful = [row for row in data["items"] if row.get("processExitCode") == 0]
        self.assertEqual({row["storeId"] for row in successful}, set(ORDER))
        for row in successful:
            self.assertGreaterEqual(row["freeAfterBytes"], 155 * 2**30)
            self.assertTrue(row["install"]["success"])
            if row.get("resumesPreservedPartial"):
                self.assertEqual(row["storeId"], "9P9VNSQK1W3K")
                self.assertEqual(row["installerSha256"], stage_small_game.BROTATO_INSTALLER_SHA)
                self.assertFalse(row["statusCandidate"]["completeInAdf8Terms"])
                self.assertTrue(row["launchBlocked"])
            else:
                self.assertEqual(row["installStatus"]["status"], "complete")
                self.assertEqual(row["installStatus"]["exit_code"], 0)


if __name__ == "__main__":
    unittest.main()
