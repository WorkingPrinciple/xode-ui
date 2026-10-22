import copy
import datetime as dt
import unittest

from build_path_to_20 import OUTPUT, build
from inspect_queue import load_json


class PathTo20Tests(unittest.TestCase):
    def setUp(self):
        self.packet = load_json(OUTPUT)

    def test_reproduction_and_admitted_count_without_candidate_inflation(self):
        self.assertEqual(build(self.packet["collectionInputs"], self.packet), self.packet)
        admitted = sum(row["verdict"] == "WORKING" for row in
                       self.packet["collectionInputs"]["matrix"]["snapshot"]["games"])
        self.assertGreaterEqual(self.packet["strictWorkingCount"], admitted)
        self.assertEqual(self.packet["strictWorkingCount"],
                         sum(row["strictWorking"] for row in self.packet["items"]))
        self.assertEqual(self.packet["remainingTo20"],
                         max(0, 20 - self.packet["strictWorkingCount"]))
        rows = {row["storeId"]: row for row in self.packet["items"]}
        self.assertEqual(len(rows), len(self.packet["items"]))
        self.assertEqual(rows["9NMNMS626R59"]["verdict"], "WORKING")
        hogwarts = rows["9MT5NJ5W7B8Z"]
        self.assertIn(hogwarts["nextGate"], ("quit", "complete"))
        for gate in ("menu", "gameplay", "save", "relaunch"):
            self.assertEqual(hogwarts["gates"][gate]["status"], "passed")
        brotato = rows["9P9VNSQK1W3K"]
        if brotato["verdict"] == "WORKING":
            self.assertTrue(brotato["strictWorking"])
            return
        self.assertFalse(brotato["strictWorking"])
        self.assertEqual(brotato["verdict"], "WORKING_CANDIDATE")
        self.assertEqual(brotato["gates"]["menu"]["status"], "passed")
        source_row = next((row for row in self.packet["collectionInputs"]["matrix"]["snapshot"]["games"]
                           if row["productId"] == brotato["storeId"]), {})
        if source_row.get("saveObservation", {}).get("retentionVerified"):
            self.assertEqual(brotato["nextGate"], "CLI promotion")
            self.assertTrue(all(gate["status"] == "passed" for gate in brotato["gates"].values()))
        else:
            self.assertEqual(brotato["gates"]["quit"]["status"], "not-passed")
            self.assertEqual(brotato["gates"]["save"]["status"], "unknown")
        for row in rows.values():
            self.assertTrue(row["nextGate"])
            self.assertTrue(row["ownerStream"])
            if not row["strictWorking"]:
                self.assertTrue(row["blocker"])

    def test_stall_clock_carries_only_unchanged_gate_and_threshold_strictly_greater(self):
        inputs = copy.deepcopy(self.packet["collectionInputs"])
        time = dt.datetime.fromisoformat(inputs["collectedAt"])
        previous = copy.deepcopy(self.packet)
        candidate = next(row for row in previous["items"] if row["nextGate"] != "complete")
        candidate["gateFirstObservedAt"] = (time - dt.timedelta(hours=2)).isoformat()
        row = next(row for row in build(inputs, previous)["items"]
                   if row["storeId"] == candidate["storeId"])
        self.assertFalse(row["stuckOver2Hours"])
        inputs["collectedAt"] = (time + dt.timedelta(seconds=1)).isoformat()
        row = next(row for row in build(inputs, previous)["items"]
                   if row["storeId"] == candidate["storeId"])
        self.assertTrue(row["stuckOver2Hours"])
        candidate["nextGate"] = "different-gate"
        row = next(row for row in build(inputs, previous)["items"]
                   if row["storeId"] == candidate["storeId"])
        self.assertFalse(row["stuckOver2Hours"])
        self.assertEqual(row["gateFirstObservedAt"], inputs["collectedAt"])

    def test_unchanged_gate_preserves_clock_despite_blocker_edit(self):
        inputs = copy.deepcopy(self.packet["collectionInputs"])
        previous = copy.deepcopy(self.packet)
        candidate = next(row for row in previous["items"] if row["nextGate"] != "complete")
        candidate["blocker"] = "different prose, not gate progress"
        row = next(row for row in build(inputs, previous)["items"]
                   if row["storeId"] == candidate["storeId"])
        self.assertEqual(row["gateFirstObservedAt"], candidate["gateFirstObservedAt"])

    def test_title_screen_pass_alias_advances_to_gameplay(self):
        inputs = copy.deepcopy(self.packet["collectionInputs"])
        source_row = next(row for row in inputs["matrix"]["snapshot"]["games"]
                          if row["productId"] == "9NMNMS626R59")
        source_row["verdict"] = "TITLE_SCREEN_PASS"
        source_row.pop("saveObservation", None)
        row = next(row for row in build(inputs, {})["items"]
                   if row["storeId"] == source_row["productId"])
        self.assertEqual(row["gates"]["menu"]["status"], "passed")
        self.assertEqual(row["gates"]["gameplay"]["status"], "unknown")
        self.assertEqual(row["nextGate"], "gameplay")

    def test_dredge_retention_is_not_clean_quit_or_working(self):
        inputs = copy.deepcopy(self.packet["collectionInputs"])
        inputs["matrix"]["snapshot"]["games"] = [
            row for row in inputs["matrix"]["snapshot"]["games"]
            if row["productId"] != "9MSVVM5NS9L6"]
        row = next(row for row in build(inputs, {})["items"]
                   if row["storeId"] == "9MSVVM5NS9L6")
        self.assertEqual(row["verdict"], "INCONCLUSIVE")
        self.assertFalse(row["strictWorking"])
        self.assertEqual(row["gates"]["save"]["status"], "passed")
        self.assertEqual(row["gates"]["relaunch"]["status"], "passed")
        self.assertEqual(row["gates"]["quit"]["status"], "not-passed")
        self.assertEqual(row["nextGate"], "ordinary quit")

    def test_newer_hades_admission_overrides_stale_matrix(self):
        inputs = copy.deepcopy(self.packet["collectionInputs"])
        inputs["matrix"]["snapshot"]["updatedAt"] = "2026-10-22T03:24:22+00:00"
        source_row = next(row for row in inputs["matrix"]["snapshot"]["games"]
                          if row["productId"] == "9PCR3Z2MSM4T")
        source_row["verdict"] = "GAMEPLAY_PASS"
        row = next(row for row in build(inputs, {})["items"]
                   if row["storeId"] == "9PCR3Z2MSM4T")
        self.assertTrue(row["strictWorking"])
        self.assertEqual(row["verdict"], "WORKING")
        self.assertTrue(all(gate["status"] == "passed" for gate in row["gates"].values()))
        self.assertIsNone(row["blocker"])
        self.assertIn("Nights 2", row["scope"])

    def test_abiotic_owner_admission_retains_qualification_evidence(self):
        inputs = copy.deepcopy(self.packet["collectionInputs"])
        inputs["matrix"]["snapshot"]["updatedAt"] = "2026-10-22T03:24:22+00:00"
        source_row = next(row for row in inputs["matrix"]["snapshot"]["games"]
                          if row["productId"] == "9P4NV23Q6QC2")
        source_row["verdict"] = "TITLE_SCREEN_ONLY"
        row = next(row for row in build(inputs, {})["items"]
                   if row["storeId"] == "9P4NV23Q6QC2")
        self.assertTrue(row["strictWorking"])
        self.assertEqual(row["nextGate"], "complete")
        self.assertTrue(all(gate["status"] == "passed" for gate in row["gates"].values()))
        self.assertIsNone(row["blocker"])
        self.assertIn("$5 and duct tape", row["scope"])
        self.assertTrue(any(evidence.get("snapshot", {}).get("run_id") ==
                            "18dcee0d-1705-469e-8f67-48924b239258"
                            for evidence in row["evidence"]))

    def test_observed_menu_quit_does_not_override_failed_exit(self):
        inputs = copy.deepcopy(self.packet["collectionInputs"])
        source_row = next(row for row in inputs["matrix"]["snapshot"]["games"]
                          if row["productId"] == "9MSVVM5NS9L6")
        source_row["saveObservation"].update(normalMenuQuitObserved=True,
                                             normalExitQualified=False)
        inputs.pop("ownerVerdicts", None)
        row = next(row for row in build(inputs, {})["items"]
                   if row["storeId"] == source_row["productId"])
        self.assertEqual(row["gates"]["quit"]["status"], "not-passed")
        self.assertEqual(row["nextGate"], "ordinary quit")
        self.assertFalse(row["strictWorking"])

    def test_mixtape_clean_exit_does_not_prove_saved_chapter(self):
        inputs = copy.deepcopy(self.packet["collectionInputs"])
        inputs["matrix"]["snapshot"]["updatedAt"] = "2026-10-22T04:00:00+00:00"
        row = next(row for row in build(inputs, {})["items"]
                   if row["storeId"] == "9NH0MSG29X6L")
        self.assertEqual(row["verdict"], "INCONCLUSIVE")
        self.assertEqual(row["gates"]["quit"]["status"], "passed")
        self.assertNotEqual(row["gates"]["save"]["status"], "passed")
        self.assertFalse(row["strictWorking"])

    def test_well_gameplay_timeout_does_not_qualify_quit_or_save(self):
        row = next(row for row in self.packet["items"] if row["storeId"] == "9PLH7R84GJWP")
        self.assertEqual(row["verdict"], "INCONCLUSIVE")
        self.assertEqual(row["gates"]["gameplay"]["status"], "passed")
        self.assertEqual(row["gates"]["quit"]["status"], "not-passed")
        self.assertNotEqual(row["gates"]["save"]["status"], "passed")
        self.assertEqual(row["nextGate"], "qualification hold")
        self.assertFalse(row["strictWorking"])

    def test_limbo_failed_attempt_does_not_pass_menu(self):
        row = next(row for row in self.packet["items"] if row["storeId"] == "9PNG83MDD6SH")
        self.assertEqual(row["verdict"], "FAIL")
        self.assertEqual(row["gates"]["menu"]["status"], "not-passed")
        self.assertEqual(row["nextGate"], "startup diagnosis")
        self.assertFalse(row["strictWorking"])

    def test_digging_timeout_is_not_working(self):
        inputs = copy.deepcopy(self.packet["collectionInputs"])
        inputs["matrix"]["snapshot"]["updatedAt"] = "2026-10-22T05:00:00+00:00"
        row = next(row for row in build(inputs, {})["items"]
                   if row["storeId"] == "9NGLST31DG26")
        self.assertEqual(row["verdict"], "INCONCLUSIVE")
        self.assertEqual(row["gates"]["gameplay"]["status"], "passed")
        self.assertEqual(row["gates"]["quit"]["status"], "not-passed")
        self.assertNotEqual(row["gates"]["save"]["status"], "passed")
        self.assertFalse(row["strictWorking"])


if __name__ == "__main__":
    unittest.main()
