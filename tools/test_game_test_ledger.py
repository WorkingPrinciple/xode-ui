import copy
import unittest

from generate_game_test_ledger import cell, eligible_products, render


class GameTestLedgerTests(unittest.TestCase):
    def setUp(self):
        self.catalog = {
            "checkedAt": "2026-10-19T21:30:33Z",
            "market": "RO",
            "products": {
                "A": {"title": "Alpha", "pcPackageIdentified": True, "packageFormat": "MSIXVC"},
                "B": {"title": "Beta", "pcPackageIdentified": True, "packageFormat": "MSIX"},
                "C": {"title": "Appx", "pcPackageIdentified": True, "packageFormat": "Appx"},
                "D": {"title": "Unknown", "pcPackageIdentified": False, "packageFormat": "MSIXVC"},
                "E": {"title": "Unspecified", "pcPackageIdentified": True},
                "F": {"title": "Legacy", "pcPackageIdentified": True, "packageFormat": "EAppx"},
            },
        }
        self.state = {
            "schemaVersion": 1, "session": 2, "asOf": "2026-10-21",
            "deadline": "2026-10-22T05:28:46Z", "notes": [], "products": {},
        }

    def test_requires_explicit_pc_evidence_and_exact_format(self):
        self.assertEqual(set(eligible_products(self.catalog)), {"A", "B"})
        self.catalog["products"]["D"]["pcPackageIdentified"] = "true"
        self.assertEqual(set(eligible_products(self.catalog)), {"A", "B"})

    def test_unknown_access_is_not_failure_or_ownership(self):
        text = render(self.catalog, self.state, "digest")
        self.assertIn("**MSI-family queue: 2 IDs**", text)
        self.assertIn("**4 excluded**", text)
        self.assertIn("| 1 | A | Alpha | MSIXVC | Unknown | Not attempted | Not attempted | Unknown |", text)
        self.assertNotIn("Unowned", text)

    def test_rejects_results_for_excluded_or_missing_ids(self):
        for product_id in ("C", "MISSING"):
            state = copy.deepcopy(self.state)
            state["products"][product_id] = {}
            with self.assertRaises(ValueError):
                render(self.catalog, state, "digest")

    def test_rejects_incomplete_reviewed_outcomes(self):
        self.state["products"]["A"] = {"session2": "Passed"}
        with self.assertRaises(ValueError):
            render(self.catalog, self.state, "digest")

    def test_retains_history_separate_from_current_sessions(self):
        self.state["products"]["A"] = {
            "historical": "Owner-reported CrossOver launch",
            "installedObservation": "Dated local observation",
            "session1": "Preflight only",
            "session2": "Not launched",
            "next": "Recover baseline",
            "evidence": "Owner clarification",
        }
        text = render(self.catalog, self.state, "digest")
        self.assertIn("Owner-reported CrossOver launch", text)
        self.assertIn("| Preflight only | Not launched |", text)
        self.assertNotIn("Gameplay passed", text)

    def test_markdown_escapes_titles(self):
        self.assertEqual(cell("A|B\nC"), "A\\|B C")


if __name__ == "__main__":
    unittest.main()
