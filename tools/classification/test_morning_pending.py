import copy
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from build_morning_pending import OUTPUT, build, measure
from inspect_queue import load_json


class MorningPendingTests(unittest.TestCase):
    def setUp(self):
        self.packet = load_json(OUTPUT)

    def test_frozen_feed_membership_does_not_grant_entitlement(self):
        with patch("urllib.request.urlopen", side_effect=AssertionError("No network")):
            self.assertEqual(build(self.packet["collectionInputs"]), self.packet)
        self.assertEqual(len(self.packet["gamePassMembership"]), 8)
        for row in self.packet["gamePassMembership"]:
            self.assertEqual(row["gamePassPcMembership"], "present")
            self.assertEqual(row["ownership"], "unknown")
            self.assertFalse(row["installAuthorized"])
        inputs = copy.deepcopy(self.packet["collectionInputs"])
        inputs["gamePass"]["complete"] = False
        self.assertTrue(all(row["gamePassPcMembership"] == "unknown"
                            for row in build(inputs)["gamePassMembership"]))

    def test_reclaim_proposes_only_two_and_preserves_live_test_lanes(self):
        proposal = self.packet["reclaimProposal"]
        self.assertEqual(proposal["deletedPaths"], [])
        self.assertEqual({row["storeId"] for row in proposal["candidates"]},
                         {"9NGLST31DG26", "9PK087LNGJC5"})
        for row in proposal["allBlockedInstalledDispositions"]:
            self.assertFalse(row["deletionAuthorized"])
            self.assertFalse(row["contentsRead"])
            self.assertTrue(row["path"].startswith(str(Path.home() / "Games/Xodus") + "/"))
            self.assertEqual(row["warnings"], [])
            if row["storeId"] in {"9MT5NJ5W7B8Z", "9PCR3Z2MSM4T", "9PLH7R84GJWP"}:
                self.assertEqual(row["disposition"], "retain-near-term")
        self.assertEqual(proposal["combinedProposal"]["diskFitOnlyCandidates"], [])

    def test_measure_is_metadata_only_and_never_follows_link(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "payload").write_bytes(b"test")
            (root / "alias").symlink_to(root / "payload")
            with patch("pathlib.Path.read_bytes", side_effect=AssertionError("No payload reads")):
                result = measure(root)
            self.assertEqual(result["logicalBytes"], 4)
            self.assertEqual(result["regularFiles"], 1)
            self.assertFalse(result["contentsRead"])


if __name__ == "__main__":
    unittest.main()
