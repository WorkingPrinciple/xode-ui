import copy
import io
import unittest
from unittest.mock import patch

from build_free_morning import OUTPUT, build, free_pc_offer
import datetime as dt
from classify_catalogue import request_json
from inspect_queue import load_json


class FreeMorningTests(unittest.TestCase):
    def test_reproduces_no_acquisition_or_false_install_fit(self):
        packet = load_json(OUTPUT)
        self.assertEqual(packet, build(packet["collectionInputs"]))
        for key in ("acquisitions", "installs", "gameLaunches", "deletions"):
            self.assertEqual(packet[key], 0)
        for row in packet["candidates"]:
            self.assertTrue(row["zeroPricePurchaseOffers"])
            self.assertTrue(any(p["PackageFormat"] == "MSIXVC" for p in row["packages"]))
            self.assertEqual(row["antiCheat"], "unknown")
            self.assertIsNone(row["supported01"])
            self.assertIsNone(row["actualInstalledBytes"])
            self.assertFalse(row["acquisitionAuthorized"])
            self.assertFalse(row["installAuthorized"])
            self.assertGreaterEqual(row["planningBudgetBytes"], row["catalogPayloadBytes"])
            self.assertEqual(row["minimumFreeBeforeBudgetBytes"],
                             157 * 2**30 + row["planningBudgetBytes"])
            self.assertEqual(row["fitsCurrent155Plus2Floor"],
                             row["minimumFreeBeforeBudgetBytes"] <= packet["collectionInputs"]["freeBytes"])
        total = sum(row["allocatedBytes"] or 0 for row in packet["collectionInputs"]["parkedSpace"]
                    if row["kind"] == "whole parked prefix")
        self.assertEqual(total, packet["parkedPrefixAllocatedTotalBytes"])

    def test_missing_free_purchase_offer_fails_explicitly(self):
        inputs = copy.deepcopy(load_json(OUTPUT)["collectionInputs"])
        next(row for row in inputs["products"]
             if row["storeId"] == "9NBL0XKVCN5L")["zeroPricePurchaseOffers"] = []
        with self.assertRaisesRegex(ValueError, "No explicit free"):
            build(inputs)

    def test_chunked_json_without_content_length(self):
        class Response(io.BytesIO):
            status = 200
            headers = {}
        with patch("classify_catalogue.urllib.request.urlopen",
                   return_value=Response(b'{"Products": []}')):
            self.assertEqual(request_json("https://example.invalid"), {"Products": []})

    def test_console_only_and_expired_offer_are_not_free_pc_evidence(self):
        packet = load_json(OUTPUT)
        row = copy.deepcopy(packet["candidates"][0]["zeroPricePurchaseOffers"][0])
        offer = {"Actions": row["actions"], "Conditions": row["conditions"],
                 "OrderManagementData": {"Price": row["price"]}}
        instant = dt.datetime.fromisoformat(packet["collectedAt"])
        self.assertTrue(free_pc_offer(offer, instant))
        offer["Conditions"]["ClientConditions"]["AllowedPlatforms"] = [
            {"PlatformName": "Windows.Xbox"}]
        self.assertFalse(free_pc_offer(offer, instant))
        offer["Conditions"]["ClientConditions"]["AllowedPlatforms"] = [
            {"PlatformName": "Windows.Desktop"}]
        offer["Conditions"]["EndDate"] = "2020-01-01T00:00:00Z"
        self.assertFalse(free_pc_offer(offer, instant))

    def test_existing_matrix_title_is_not_a_new_candidate(self):
        packet = load_json(OUTPUT)
        inputs = copy.deepcopy(packet["collectionInputs"])
        inputs["matrix"]["productIds"].append(packet["candidates"][0]["storeId"])
        with self.assertRaisesRegex(ValueError, "already in tried-games matrix"):
            build(inputs)


if __name__ == "__main__":
    unittest.main()
