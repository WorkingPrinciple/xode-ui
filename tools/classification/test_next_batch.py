import copy
import unittest
from unittest.mock import patch

from build_next_batch import CLI, OUTPUT, RC, build, complete
from inspect_queue import DATA, load_json


class NextBatchTests(unittest.TestCase):
    def setUp(self):
        self.packet = load_json(OUTPUT)

    def test_all_untested_identities_are_covered_with_fresh_complete_status(self):
        morning = load_json(DATA / "morning-status-v1.json")
        expected = {row["storeId"] for row in morning["items"] if row["state"] == "UNTESTED"}
        rows = self.packet["allUntestedTitles"]
        self.assertEqual({row["storeId"] for row in rows}, expected)
        self.assertEqual(len(rows), 23)
        for row in rows:
            self.assertTrue(row["installedComplete"])
            self.assertTrue(row["completeInAdf8Terms"])
            self.assertEqual(len(row["installStatusAttempts"]), 1)
            attempt = row["installStatusAttempts"][0]
            self.assertEqual(attempt["cliSha256"], CLI)
            self.assertEqual(attempt["argv"][1], "install-status")
            self.assertTrue(complete(attempt, row["storeId"], row["gameDir"]))
            self.assertIsNone(row["launch"])
            self.assertFalse(row["executionAuthorized"])

    def test_pure_frozen_reproduction_and_no_double_passive_queue(self):
        inputs = copy.deepcopy(self.packet["collectionInputs"])
        with patch("subprocess.run", side_effect=AssertionError("No process")), \
                patch("pathlib.Path.read_bytes", side_effect=AssertionError("No live files")):
            self.assertEqual(build(inputs), self.packet)
        self.assertEqual(inputs, self.packet["collectionInputs"])
        self.assertEqual(self.packet["counts"],
                         {"untested": 23, "installedComplete": 23,
                          "nextBatch": 16, "passiveOverlap": 7})
        self.assertTrue(all(not row["alreadyInPassiveNine"] for row in self.packet["items"]))
        self.assertEqual([row["nextBatchRank"] for row in self.packet["items"]],
                         list(range(1, 17)))
        exact = [row["explicitEngineRowStatus"] for row in self.packet["items"]]
        self.assertEqual(exact, ["present"] * 8 + ["missing"] * 8)
        self.assertEqual(self.packet["missingS1Rows"], [])
        self.assertEqual(len(self.packet["exactBindingRequests"]), 8)

    def test_incomplete_and_wrong_product_never_enter_batch(self):
        inputs = copy.deepcopy(self.packet["collectionInputs"])
        sid = self.packet["items"][0]["storeId"]
        inputs["queries"][sid][0]["result"]["product"] = "wrong"
        result = build(inputs)
        self.assertNotIn(sid, {row["storeId"] for row in result["items"]})
        inputs["queries"][sid][0]["result"]["product"] = sid
        inputs["queries"][sid][0]["result"]["status"] = "incomplete"
        self.assertNotIn(sid, {row["storeId"] for row in build(inputs)["items"]})

    def test_candidate_completion_never_claims_frozen_complete(self):
        inputs = copy.deepcopy(self.packet["collectionInputs"])
        sid = self.packet["items"][0]["storeId"]
        candidate = copy.deepcopy(inputs["queries"][sid][0])
        inputs["queries"][sid][0].update(processExitCode=101, result=None)
        candidate.update(cliSha256=RC, candidateBinary=True)
        inputs["queries"][sid].append(candidate)
        row = next(row for row in build(inputs)["items"] if row["storeId"] == sid)
        self.assertTrue(row["installedComplete"])
        self.assertFalse(row["completeInAdf8Terms"])
        self.assertEqual(row["installStatusAttempts"][0]["processExitCode"], 101)


if __name__ == "__main__":
    unittest.main()
