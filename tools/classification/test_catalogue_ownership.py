import copy
import hashlib
from pathlib import Path
import unittest
from unittest.mock import patch

from inspect_queue import load_json
from read_catalogue_ownership import OUTPUT, build


class OwnershipTests(unittest.TestCase):
    def setUp(self):
        self.packet = load_json(OUTPUT)

    def test_actual_source_binding_and_frozen_reproduction(self):
        inputs = self.packet["collectionInputs"]
        with patch("subprocess.run", side_effect=AssertionError("No process")):
            self.assertEqual(build(inputs), self.packet)
        receipt = inputs["receipt"]
        self.assertEqual(hashlib.sha256(Path(receipt["path"]).read_bytes()).hexdigest(),
                         receipt["sha256"])
        raw = load_json(Path(receipt["path"]))
        self.assertTrue(raw["complete"])
        self.assertEqual([r["command"] for r in raw["responses"]],
                         ["hello", "auth.status", "ode.account.read.v1", "auth.status"])
        self.assertTrue(inputs["collectionSummary"]["accountBindingVerified"])
        self.assertEqual(len(self.packet["items"]), 8)
        self.assertFalse(self.packet["approvalRequiredInstallQueue"])
        self.assertNotIn("accountHash", str(self.packet))

    def test_incomplete_or_missing_account_never_means_not_owned(self):
        inputs = copy.deepcopy(self.packet["collectionInputs"])
        inputs["collectionSummary"]["complete"] = False
        result = build(inputs)
        self.assertTrue(all(row["ownership"] == "unknown" for row in result["items"]))
        self.assertEqual(result["approvalRequiredInstallQueue"], [])
        inputs["collectionSummary"]["complete"] = True
        inputs["collectionSummary"]["accountBindingVerified"] = False
        self.assertTrue(all(row["ownership"] == "unknown"
                            for row in build(inputs)["items"]))

    def test_exact_owned_filter_predicate_and_disk_margin(self):
        inputs = copy.deepcopy(self.packet["collectionInputs"])
        ids = [row["storeId"] for row in inputs["candidates"]]
        inputs["collectionSummary"]["items"] = [
            {"productID": ids[0], "acquisitionKind": "purchased"},
            {"productID": ids[1], "acquisitionKind": "unknown"},
            {"productID": ids[2], "acquisitionKind": "subscription"},
        ]
        inputs["freeBytes"] = 157 * 2**30 + inputs["candidates"][0]["downloadSizeBytes"]
        rows = build(inputs)["items"]
        self.assertEqual([row["ownership"] for row in rows[:3]],
                         ["owned", "owned", "unknown"])
        self.assertTrue(rows[0]["fits155Plus2GiBNow"])
        inputs["freeBytes"] -= 1
        self.assertFalse(build(inputs)["items"][0]["fits155Plus2GiBNow"])
        self.assertTrue(all(row["installAuthorized"] is False for row in rows))


if __name__ == "__main__":
    unittest.main()
