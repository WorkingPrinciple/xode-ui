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
        self.assertEqual(self.packet["strictWorkingCount"], admitted)
        self.assertEqual(self.packet["remainingTo20"], max(0, 20 - admitted))
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


if __name__ == "__main__":
    unittest.main()
