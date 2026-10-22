import unittest

from rank_remaining import ORDER, build


class RemainingRankingTests(unittest.TestCase):
    def test_complete_unique_pool_and_no_download_admission(self):
        packet = build()
        self.assertEqual([row["storeId"] for row in packet["items"]], ORDER)
        self.assertEqual(len(ORDER), len(set(ORDER)))
        self.assertEqual(packet["disk"]["grossMarginGiB"], 23)
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
        self.assertTrue(valor["needsDownload"])
        self.assertIn("handoff pending", valor["installState"])


if __name__ == "__main__":
    unittest.main()
