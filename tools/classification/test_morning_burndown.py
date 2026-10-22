import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from build_morning_burndown import (
    DEADLINE, OUTPUT, calculate, read_current_receipt, recheck_historical_receipt,
)
from inspect_queue import load_json


class BurnDownTests(unittest.TestCase):
    def test_current_receipt_checks_identity_scope_and_logs(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "receipt.json"
            log = Path(directory) / "check.log"
            log.write_bytes(b"verified")
            app = {
                "path": str(Path.home() / "Applications/Ode to X Local Candidate.app"),
                "sourceIdentityUnknown": False,
                "sourceIdentity": {"appSource": {
                    "commit": "c7487d8cde0c74c927207c17029a9d5008373a9c"}},
                "checks": [{"exitCode": 0, "log": str(log),
                            "logSHA256": hashlib.sha256(log.read_bytes()).hexdigest()} for _ in range(4)],
            }
            receipt = {"verifiedAt": "2026-10-22T17:22:09+00:00",
                       "originalSwitchOverReceipt": False, "switchOverPerformed": False,
                       "lostArtifactsRecovered": False, "apps": [app]}

            def read():
                path.write_text(json.dumps(receipt))
                return read_current_receipt(path, hashlib.sha256(path.read_bytes()).hexdigest())

            self.assertFalse(read()["originalSwitchOverReceipt"])
            receipt["lostArtifactsRecovered"] = True
            with self.assertRaisesRegex(ValueError, "scope"):
                read()
            receipt["lostArtifactsRecovered"] = False
            app["checks"][0]["exitCode"] = 1
            with self.assertRaisesRegex(ValueError, "verification failed"):
                read()
            app["checks"][0]["exitCode"] = 0
            log.write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "log hash changed"):
                read()

    def test_missing_historical_release_receipt_is_explicit(self):
        with tempfile.TemporaryDirectory() as directory:
            previous = {"path": str(Path(directory) / "receipt.json"),
                        "sha256": hashlib.sha256(b"receipt").hexdigest(),
                        "revision": "42f793d", "installed": True}
            result = recheck_historical_receipt(previous)
            self.assertIn("missing", result["sourceStatus"])
            self.assertEqual(result["sha256"], previous["sha256"])
            self.assertNotIn("sourceStatus", previous)

    def test_historical_release_receipt_requires_same_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "receipt.json"
            path.write_bytes(b"receipt")
            previous = {"path": str(path), "sha256": hashlib.sha256(b"receipt").hexdigest()}
            self.assertIn("hash reverified", recheck_historical_receipt(previous)["sourceStatus"])
            path.write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "hash changed"):
                recheck_historical_receipt(previous)

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

    def test_user_launch_floor_is_110_gib(self):
        policy = load_json(OUTPUT)["inputs"]["launchDiskPolicy"]
        self.assertEqual(policy["minimumFreeGiB"], 110)
        self.assertEqual(policy["minimumFreeBytes"], 110 * 2**30)
        self.assertEqual(policy["stagingMinimumFreeGiB"], 110)
        self.assertEqual(policy["runningAbortBelowGiB"], 105)

    def test_reported_queue_additions_are_not_claimed_completed_packets(self):
        inputs = load_json(OUTPUT)["inputs"]
        evidence = inputs["pendingPacketQueueEvidence"]
        self.assertEqual(evidence["reportedQueueCap"], 23)
        for row in evidence["items"]:
            queued = next(item for item in inputs["queued"] + inputs["withheld"]
                          if item["storeId"] == row["storeId"])
            self.assertIn(queued["batch"], ("packet preparation pending",
                                          "passive-batch2-eight-v1", "passive-batch3-eight-v1"))
        self.assertEqual(inputs["queueReconciliation"]["uniqueCount"], len(inputs["queued"]))

    def test_human_consent_titles_are_not_ready_capacity(self):
        inputs = load_json(OUTPUT)["inputs"]
        queued = {row["storeId"] for row in inputs["queued"]}
        held = {row["storeId"]: row for row in inputs["withheld"]}
        for sid in ("9NQVHHW88XW9", "9PJPCB188SVG"):
            self.assertNotIn(sid, queued)
            self.assertIn("Human legal consent", held[sid]["blocker"])


if __name__ == "__main__":
    unittest.main()
