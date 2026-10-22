"""Expansion facts and candidate preflights; no network/install/launch in tests."""

import copy
import shlex
import unittest
from unittest.mock import patch

from build_fast_path_packets import FIELDS
from build_small_packets import ORDER, build
from build_small_preflights import build as build_preflight
from inspect_queue import DATA, load_json


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


if __name__ == "__main__":
    unittest.main()
