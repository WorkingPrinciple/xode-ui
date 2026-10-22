"""Frozen-source tests: no networking, launches, input or live triage capture."""

import copy
import hashlib
from pathlib import Path
import unittest
from unittest.mock import patch
from urllib.parse import urlparse

from build_fast_path_packets import FIELDS, build, capture_triage, fast_paths
from inspect_queue import DATA, load_json


class FastPathTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base = load_json(DATA / "s3-ready-packets-v3.json")
        cls.packet = load_json(DATA / "s3-ready-packets-v4.json")
        cls.scripts = {row["storeId"]: row for row in cls.packet["fastPaths"]}

    def test_reproducible_offline_without_any_subprocess(self):
        with patch("subprocess.run", side_effect=AssertionError("No live capture")):
            self.assertEqual(build(), self.packet)
        self.assertEqual(
            self.packet["baseV3"]["sha256"],
            hashlib.sha256((DATA / "s3-ready-packets-v3.json").read_bytes()).hexdigest(),
        )

    def test_all_seventeen_in_order_with_every_requested_phase(self):
        scripts = self.packet["fastPaths"]
        self.assertEqual(len(scripts), 17)
        self.assertEqual([row["order"] for row in scripts], list(range(1, 18)))
        self.assertEqual(
            [row["storeId"] for row in scripts],
            self.base["s3OrderIncludingRequiredHogwarts"],
        )
        self.assertEqual(scripts[1]["storeId"], "9MT5NJ5W7B8Z")
        for row in scripts:
            self.assertEqual(set(row["phases"]), set(FIELDS))
            for key, phase in row["phases"].items():
                self.assertEqual(phase["status"],
                                 "unknown" if phase["value"] is None else "public-expectation")
                self.assertTrue(phase["sources"], (row["storeId"], key))
                for source in phase["sources"]:
                    self.assertEqual(urlparse(source["url"]).scheme, "https")
                    self.assertTrue(source["checkedAt"])
                    self.assertTrue(source["scope"])
                    self.assertTrue(source["finding"])

    def test_every_v3_recipe_ranking_and_save_field_is_preserved(self):
        original = copy.deepcopy(self.base)
        self.assertEqual(fast_paths(self.base), self.packet["fastPaths"])
        self.assertEqual(self.base, original)
        for key, value in self.base.items():
            if key != "schemaVersion":
                self.assertEqual(self.packet[key], value, key)
        self.assertEqual(self.packet["schemaVersion"], 4)
        self.assertTrue(self.packet["fastPathContract"]["readOnlyResearch"])
        self.assertEqual(self.packet["fastPathContract"]["launchesPerformed"], 0)

    def test_times_and_unestablished_keys_do_not_become_guesses(self):
        for row in self.scripts.values():
            self.assertIsNone(row["phases"]["expected_minutes_to_save"]["value"])
            self.assertIsNone(row["phases"]["logo_skip"]["value"])
        for store_id in ("9N8C07SS8C9D", "9NH0MSG29X6L", "9NQVHHW88XW9"):
            self.assertIsNone(self.scripts[store_id]["phases"]["keyboard_controls"]["value"])
        ffiv = self.scripts["9N8C07SS8C9D"]["phases"]["save_trigger"]
        self.assertIsNone(ffiv["value"])
        self.assertTrue(any("SNES" in row["scope"] for row in ffiv["sources"]))
        self.assertTrue(any("Wrong-title" in row["finding"] for row in ffiv["sources"]))
        self.assertTrue(all(
            row["value"] is None for row in self.scripts["9NQVHHW88XW9"]["phases"].values()
        ))

    def test_high_value_shortcuts_have_specific_gates_and_risks(self):
        kcd = self.scripts["9P3T7HVKM6D0"]["phases"]["save_trigger"]["value"]
        self.assertIn("mother conversation", kcd)
        self.assertIn("Standard", kcd)
        self.assertIn("No need to reach Awakening", kcd)
        hogwarts = self.scripts["9MT5NJ5W7B8Z"]
        self.assertIn("right mouse", hogwarts["phases"]["intro_skip"]["value"])
        self.assertIn("cannot be", hogwarts["phases"]["tutorial_skip"]["value"])
        self.assertTrue(any("pre-window FAIL" in warning for warning in hogwarts["warnings"]))
        replaced = self.scripts["9NV3L234VGXD"]
        self.assertIsNone(replaced["phases"]["intro_skip"]["value"])
        self.assertTrue(any("softlocked" in warning for warning in replaced["warnings"]))
        self.assertTrue(any("New Game" in warning
                            for warning in self.scripts["9NFB47H2SDRX"]["warnings"]))
        self.assertIn("Esc", self.scripts["9NGH1FK0RJGL"]["phases"]["save_trigger"]["value"])
        self.assertIsNone(self.scripts["9NCJWHHMVHR0"]["phases"]["save_trigger"]["value"])
        self.assertIn("Do not skip the first cutscene",
                      self.scripts["9P5Z4530318L"]["phases"]["intro_skip"]["value"])

    def test_triage_only_proposes_real_failed_or_blocked_payloads_with_holds(self):
        triage = self.packet["uninstallReview"]
        self.assertFalse(triage["deletionsAuthorized"])
        self.assertEqual(triage["deletionsPerformed"], 0)
        self.assertEqual(triage["permanentUninstallRecommendations"], [])
        self.assertEqual(len(triage["source"]["sha256"]), 64)
        self.assertEqual(len(triage["candidates"]), 5)
        self.assertEqual(triage["sha256"], hashlib.sha256(
            (DATA / triage["path"]).read_bytes()).hexdigest())
        for row in triage["candidates"]:
            self.assertIn(row["s3Evidence"]["verdict"], {"FAIL", "BLOCKED"})
            self.assertFalse(row["eligibleForDeletionNow"])
            self.assertGreater(row["allocatedKiB"], 0)
            self.assertTrue(Path(row["gameRoot"]).is_absolute())
            self.assertTrue(row["hold"])
            self.assertTrue(row["s3Evidence"]["blocker"])
        hogwarts = next(row for row in triage["candidates"]
                        if row["storeId"] == "9MT5NJ5W7B8Z")
        self.assertEqual(hogwarts["disposition"], "hold-required-title")
        comparison = triage["spaceComparison"]
        total = sum(row["allocatedKiB"] * 1024 for row in triage["candidates"]
                    if row["storeId"] != "9MT5NJ5W7B8Z")
        self.assertEqual(comparison["nonRequiredCandidateAllocatedBytes"], total)
        for row in comparison["targets"]:
            deficit = max(0, 150 * 2**30 + row["catalogueDownloadBytes"]
                          - triage["currentFreeBytes"])
            self.assertEqual(row["minimumExtraBytesBeforeMargin"], deficit)
            self.assertEqual(row["nonRequiredCandidatesCouldCoverBeforeMargin"],
                             total >= deficit)

    def test_changed_verdict_stops_triage_before_disk_probes_or_writes(self):
        class ChangedSnapshot:
            def read_bytes(self):
                return b'{"games":[{"productId":"9PLH7R84GJWP","verdict":"WORKING"}]}'

        with patch("subprocess.run", side_effect=AssertionError("No disk probe")), \
             patch("build_fast_path_packets.write_json",
                   side_effect=AssertionError("No writes")), \
             patch.object(Path, "is_dir", return_value=True):
            with self.assertRaisesRegex(ValueError, "verdict changed"):
                capture_triage(ChangedSnapshot())

    def test_missing_or_symlink_payload_stops_before_disk_probe(self):
        class Snapshot:
            def read_bytes(self):
                return b'{"games":[{"productId":"9PLH7R84GJWP","verdict":"FAIL"}]}'

        for is_dir, is_symlink in ((False, False), (True, True)):
            with self.subTest(is_dir=is_dir, is_symlink=is_symlink), \
                 patch.object(Path, "is_dir", side_effect=[True, is_dir]), \
                 patch.object(Path, "is_symlink", return_value=is_symlink), \
                 patch("subprocess.run", side_effect=AssertionError("No disk probe")), \
                 patch("build_fast_path_packets.write_json",
                       side_effect=AssertionError("No writes")):
                with self.assertRaisesRegex(ValueError, "real installed payload directory"):
                    capture_triage(Snapshot())


if __name__ == "__main__":
    unittest.main()
