import copy
import unittest

from build_morning_burndown import DEADLINE, OUTPUT, calculate
from inspect_queue import load_json


class BurnDownTests(unittest.TestCase):
    def test_reproduces_and_caps_by_queue(self):
        packet = load_json(OUTPUT)
        self.assertEqual(packet, calculate(packet["inputs"]))
        for scenario in packet["scenarios"]:
            self.assertLessEqual(scenario["queueCappedAdditions"], len(packet["inputs"]["queued"]))
            self.assertEqual(scenario["conditionalTotalWorking"],
                             packet["inputs"]["strictWorkingCount"] + scenario["queueCappedAdditions"])
        self.assertTrue(all(row["minutes"] > 0 for row in packet["observedCycles"]))
        self.assertEqual(len({row["storeId"] for row in packet["inputs"]["queued"]}),
                         len(packet["inputs"]["queued"]))
        ratio = packet["observedAdmissionRatio"]
        self.assertEqual(ratio["working"], packet["inputs"]["strictWorkingCount"])
        self.assertEqual(ratio["ratio"], ratio["matrixWorking"] / ratio["attemptedMatrix"])
        self.assertEqual(ratio["receiptAugmentedRatio"],
                         ratio["working"] / ratio["receiptAugmentedAttempted"])
        needed = 20 - packet["inputs"]["strictWorkingCount"]
        for scenario in packet["scenarios"]:
            self.assertEqual(scenario["minimumPassRateCurrentQueue"],
                             needed / scenario["queueCappedAdditions"])
        self.assertEqual(packet["timeSink"]["largestCategory"], "between recorded runs")

    def test_expired_deadline_has_no_additions(self):
        inputs = copy.deepcopy(load_json(OUTPUT)["inputs"])
        inputs["asOf"] = inputs["deadline"]
        self.assertTrue(all(row["queueCappedAdditions"] == 0
                            for row in calculate(inputs)["scenarios"]))

    def test_user_extended_deadline_is_preserved(self):
        self.assertEqual(DEADLINE, "2026-10-23T13:26:00+03:00")
        self.assertEqual(load_json(OUTPUT)["inputs"]["deadline"], DEADLINE)

    def test_reported_queue_additions_are_not_claimed_completed_packets(self):
        inputs = load_json(OUTPUT)["inputs"]
        evidence = inputs["pendingPacketQueueEvidence"]
        self.assertEqual(evidence["reportedQueueCap"], 23)
        for row in evidence["items"]:
            queued = next(item for item in inputs["queued"]
                          if item["storeId"] == row["storeId"])
            self.assertIn(queued["batch"], ("packet preparation pending",
                                          "passive-batch2-eight-v1", "passive-batch3-eight-v1"))
        self.assertEqual(inputs["queueReconciliation"]["uniqueCount"], len(inputs["queued"]))


if __name__ == "__main__":
    unittest.main()
