import hashlib
import json
from pathlib import Path
import unittest

from inspect_queue import DATA


class PipelineStatusTests(unittest.TestCase):
    def test_real_status_receipts_match_exact_products_and_roots(self):
        packet = json.loads((DATA / "pipeline-install-entitlement-v1.json").read_text())
        self.assertTrue(packet["accountReadComplete"])
        self.assertEqual(len(packet["items"]), 9)
        self.assertEqual([row["storeId"] for row in packet["items"][:2]],
                         ["9NQVHHW88XW9", "9PJPCB188SVG"])
        for row in packet["items"]:
            status = row["installStatus"]
            self.assertEqual(row["processExitCode"], 0)
            self.assertEqual(status["product"], row["storeId"])
            self.assertEqual(status["game_dir"], row["root"])
            self.assertEqual(status["operation"], "install-status")
            self.assertEqual(status["status"], "complete")
            self.assertTrue(status["success"])
            self.assertFalse(row["launchAuthorized"])
            self.assertFalse(row["acquisitionAttempted"])
            receipt = row["installStatusReceipt"]
            path = Path(receipt["path"])
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), receipt["sha256"])
            self.assertEqual(json.loads(path.read_text()), status)
            if packet["accountProductCount"] == 0:
                self.assertEqual(row["entitlement"], "unknown")
