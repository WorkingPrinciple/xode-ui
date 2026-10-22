"""Frozen reconciliation invariants; no product execution or filesystem mutation."""

import copy
import unittest
from unittest.mock import patch

from build_morning_status import OUTPUT, build_status, compare_disk, markdown
from inspect_queue import DATA, load_json


class MorningStatusTests(unittest.TestCase):
    def setUp(self):
        self.packet = load_json(OUTPUT)
        self.rows = {row["storeId"]: row for row in self.packet["items"]}

    def test_frozen_reproduction_needs_no_live_file_or_process(self):
        inputs = copy.deepcopy(self.packet["collectionInputs"])
        with patch("pathlib.Path.read_bytes", side_effect=AssertionError("No live receipt")), \
                patch("subprocess.run", side_effect=AssertionError("No process")):
            self.assertEqual(build_status(inputs), self.packet)
        self.assertEqual(inputs, self.packet["collectionInputs"])

    def test_complete_unique_four_state_union_and_actionable_evidence(self):
        inputs = self.packet["collectionInputs"]
        expected = {item["storeId"] for packet in inputs["packets"]
                    for key in ("items", "blockedItems")
                    for item in packet["snapshot"][key]}
        expected.update(item["productId"] for item in inputs["matrix"]["snapshot"]["games"])
        self.assertEqual(set(self.rows), expected)
        self.assertEqual(len(self.rows), len(self.packet["items"]))
        self.assertEqual(sum(self.packet["counts"].values()), len(self.rows))
        for row in self.rows.values():
            self.assertIn(row["state"], {"WORKING", "TITLE_SCREEN", "BLOCKED", "UNTESTED"})
            self.assertTrue(row["nextAction"])
            self.assertTrue(row["evidence"])
            if row["state"] != "WORKING":
                self.assertTrue(row["blocker"])
            for evidence in row["evidence"]:
                self.assertTrue(evidence["path"].startswith("/"))
                self.assertNotIn("pointer", evidence)

    def test_only_admitted_matrix_can_clear_working_and_gameplay_is_not_retention(self):
        matrix = self.packet["collectionInputs"]["matrix"]["snapshot"]["games"]
        expected = {row["productId"] for row in matrix if row["verdict"] == "WORKING"}
        self.assertEqual({sid for sid, row in self.rows.items()
                          if row["state"] == "WORKING"}, expected)
        self.assertEqual(len(expected), 3)
        for row in self.rows.values():
            if row.get("rawMatrixVerdict") == "GAMEPLAY_PASS":
                self.assertEqual(row["state"], "BLOCKED")
        hogwarts = self.rows["9MT5NJ5W7B8Z"]
        self.assertEqual(hogwarts["latestOwnerReportedVerdict"], "GAMEPLAY_PASS")
        self.assertEqual(hogwarts["state"], "BLOCKED")
        self.assertIn("unverified", hogwarts["blocker"])

    def test_title_receipt_and_kex_candidates_do_not_clear_working(self):
        halls = self.rows["9NMNMS626R59"]
        self.assertEqual(halls["state"], "TITLE_SCREEN")
        inputs = copy.deepcopy(self.packet["collectionInputs"])
        inputs["verifiedReceipts"] = {}
        with self.assertRaisesRegex(ValueError, "receipt identity mismatch"):
            build_status(inputs)
        for sid in ("9MXND4PQLK3W", "9P1Z43KRNQD4"):
            row = self.rows[sid]
            self.assertEqual(row["state"], "UNTESTED")
            self.assertTrue(any(item["path"].endswith("kex-game-candidates.json")
                                for item in row["s1Rows"]))
        self.assertEqual(self.rows["9P9VNSQK1W3K"]["state"], "BLOCKED")

    def test_uninstalled_catalogue_never_becomes_a_test_or_launch_admission(self):
        catalogue = load_json(DATA / "s3-preflight-catalogue-v1.json")
        for item in catalogue["blockedItems"]:
            row = self.rows[item["storeId"]]
            self.assertEqual(row["state"], "BLOCKED")
            self.assertIn("ownership/entitlement", row["blocker"])
            self.assertNotIn("launch", row)
        text = markdown(self.packet, load_json(DATA / "disk-growth-v1.json"))
        self.assertLess(len(text), 18000)
        self.assertIn("No installs, launches or deletions", text)

    def test_all_blockers_have_one_class_without_inventing_engine_causality(self):
        groups = self.packet["blockerPrioritization"]["rankedClasses"]
        expected = {sid for sid, row in self.rows.items() if row["state"] == "BLOCKED"}
        members = [row["storeId"] for group in groups for row in group["titles"]]
        self.assertEqual(set(members), expected)
        self.assertEqual(len(members), len(set(members)))
        self.assertEqual({group["blockerClass"]: group["titleCount"] for group in groups},
                         {"untested recipe": 4, "CLI bug": 1,
                          "missing engine feature": 2, "disk/ownership": 15,
                          "anti-cheat/online": 0})
        self.assertEqual([group["priorityRank"] for group in groups], list(range(1, 6)))
        for sid in ("C3KLDKZBHNCZ", "9NGLST31DG26"):
            self.assertFalse(self.rows[sid]["blockerClassIsConfirmedRootCause"])
        self.assertTrue(self.rows["9P9VNSQK1W3K"]["blockerClassIsConfirmedRootCause"])
        self.assertIn("not established root causes",
                      self.packet["blockerPrioritization"]["scope"])
        for group in groups:
            self.assertTrue(group["relativeEffort"])
            self.assertTrue(group["nextAction"])
            self.assertTrue(group["rankRationale"])

    def test_disk_rate_uses_actual_delta_not_modified_footprint(self):
        first = {
            "at": "2026-10-22T00:00:00+00:00", "freeBytes": 160 * 2**30,
            "buckets": {"/sample": {"allocatedBytes": 2**30,
                                   "recentModifiedAllocatedBytes": 2**30}},
            "trackedFiles": {},
        }
        last = copy.deepcopy(first)
        last.update(at="2026-10-22T01:00:00+00:00", freeBytes=158 * 2**30)
        last["buckets"]["/sample"]["allocatedBytes"] += 2**29
        baseline = {"at": first["at"], "freeBytes": first["freeBytes"]}
        audit = {"collectedAt": first["at"], "items": []}
        with patch("build_morning_status.load_json", return_value=audit):
            result = compare_disk(first, last, baseline)
            self.assertEqual(result["netConsumptionGiBPerHour"], 2)
            self.assertEqual(result["hoursUntil150GiBFloorAtSampleRate"], 4)
            self.assertEqual(result["topPathDeltas"][0]["growthGiBPerHour"], 0.5)
            for free in (first["freeBytes"], first["freeBytes"] + 2**30):
                last["freeBytes"] = free
                result = compare_disk(first, last, baseline)
                self.assertIsNone(result["hoursUntil150GiBFloorAtSampleRate"])


if __name__ == "__main__":
    unittest.main()
