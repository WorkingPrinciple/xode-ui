import unittest

from rank_remaining import ORDER, build


class RemainingRankingTests(unittest.TestCase):
    def test_complete_unique_pool_and_no_download_admission(self):
        packet = build()
        self.assertEqual([row["storeId"] for row in packet["items"]],
                         [sid for sid in ORDER if sid != "9PBWWQGXVMKC"])
        self.assertEqual(len(ORDER), len(set(ORDER)))
        self.assertEqual(packet["disk"]["grossMarginGiB"], 17)
        self.assertEqual(packet["disk"]["abortBelowGiB"], 105)
        self.assertIsNone(packet["disk"]["valorMortisRemainingBytes"])
        for row in packet["items"]:
            self.assertIn("NOT ADMITTED", row["diskAdmission"])
            if row["needsUserClaim"]:
                self.assertTrue(row["needsLicenseCheck"])
                self.assertTrue(row["needsDownload"])
            if not row["needsDownload"]:
                self.assertEqual(row["incrementalDownloadBudgetBytes"], 0)
        valor = next(row for row in packet["items"] if row["storeId"] == "9P861V1542BL")
        self.assertIn("passive attempted", valor["installState"])
        self.assertIn("VC++", valor["blocker"])
        extensions = [row for row in packet["items"] if row["pipelineExtensionCandidate"]]
        self.assertEqual(packet["pipelineExtension"]["storeIds"],
                         [row["storeId"] for row in extensions])
        self.assertEqual(len(extensions), 9)
        for row in extensions:
            self.assertGreater(row["rank"], 10)
            self.assertIsNotNone(row["inventoryEvidence"])
            self.assertFalse(row["needsUserClaim"])
            self.assertFalse(row["needsDownload"])
            self.assertTrue(row["fitsGrossMargin"])
            self.assertIn(row["verdict"], {"UNTESTED", "NOT_TESTED"})


if __name__ == "__main__":
    unittest.main()
