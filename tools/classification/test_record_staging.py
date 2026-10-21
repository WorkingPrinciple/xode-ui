"""Check real staged-install evidence without running installers or status commands."""

import unittest
from pathlib import Path

from inspect_queue import DATA, load_json


class StagingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.products = load_json(DATA / "install-staging-v1.json")["products"]
        cls.queue = {
            row["storeId"]: row for row in load_json(DATA / "next-30-queue.json")["items"]
        }
        cls.inspection = load_json(DATA / "queue-inspection-v1.json")["products"]

    def test_readiness_requires_complete_matching_receipt(self):
        self.assertTrue(self.products)
        for product_id, record in self.products.items():
            with self.subTest(product=product_id):
                status = record["completeness"]
                self.assertEqual(status["operation"], "install-status")
                self.assertEqual(status["product"], product_id)
                self.assertEqual(status["status"], "complete")
                self.assertIs(status["success"], True)
                self.assertEqual(status["exit_code"], 0)
                self.assertEqual(
                    Path(status["game_dir"]), Path(record["root"]).expanduser()
                )
                self.assertEqual(record["install"]["product"], product_id)
                self.assertIs(record["install"]["success"], True)
                self.assertEqual(record["install"]["exit_code"], 0)
                digest = record["statusExecutableSha256"]
                self.assertRegex(digest, r"^[0-9a-f]{64}$")
                self.assertEqual(Path(record["statusExecutable"]).parent.name, digest)

    def test_queue_and_inspection_match_staged_package(self):
        for product_id, record in self.products.items():
            with self.subTest(product=product_id):
                row = self.queue[product_id]
                self.assertIs(row["alreadyInstalled"], True)
                self.assertEqual(row["installStatus"], "complete")
                self.assertEqual(row["installRoot"], record["root"])
                self.assertEqual(
                    row["stagingEvidence"], f"install-staging-v1.json#/products/{product_id}"
                )
                self.assertEqual(
                    self.inspection[product_id]["package"], record["package"]
                )

    def test_proposals_are_not_approved_bindings(self):
        profiles = {
            "DX11": "creation-dx11-d3dmetal",
            "DX12": "apple-gptk-4.0b3",
            "DX9": "queue-winecx-nativejson",
            "OpenGL": "queue-winecx-nativejson",
        }
        for product_id, record in self.products.items():
            with self.subTest(product=product_id):
                proposal = record.get("engineProfileProposal")
                if proposal is None:
                    continue
                self.assertIsNone(record["engineProfile"])
                self.assertEqual(record["engineProfileStatus"], "pending-S1-binding")
                self.assertEqual(proposal["status"], "proposal-awaiting-S1-confirmation")
                expected = profiles.get(self.queue[product_id]["api"])
                if expected is None:
                    self.assertIn("OpenGL", record["package"]["graphicsAPIs"])
                    expected = "queue-winecx-nativejson"
                self.assertEqual(proposal["profile"], expected)


if __name__ == "__main__":
    unittest.main()
