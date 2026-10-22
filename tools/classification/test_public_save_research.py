"""Check source requirements and frozen launch/readiness preservation offline."""

import copy
import hashlib
import unittest
from datetime import date
from urllib.parse import urlparse

from inspect_queue import DATA, load_json
from public_save_research import CHECKED_AT, FIELDS, build_packet


class PublicSaveResearchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base = load_json(DATA / "s3-ready-packets-v1.json")
        cls.packet = load_json(DATA / "s3-ready-packets-v2.json")

    def test_published_packet_is_reproducible_without_mutating_base(self):
        original = copy.deepcopy(self.base)
        self.assertEqual(build_packet(self.base), self.packet)
        self.assertEqual(self.base, original)
        self.assertEqual(self.packet["schemaVersion"], 2)
        self.assertFalse(self.packet["basePacket"]["readinessRefreshed"])
        self.assertEqual(
            self.packet["basePacket"]["sha256"],
            hashlib.sha256((DATA / "s3-ready-packets-v1.json").read_bytes()).hexdigest(),
        )

    def test_all_sixteen_original_rows_and_receipts_are_preserved(self):
        self.assertEqual(len(self.packet["items"]), 16)
        for original, row in zip(self.base["items"], self.packet["items"]):
            with self.subTest(product=original["storeId"]):
                for key, value in original.items():
                    self.assertEqual(row[key], value, key)
                self.assertEqual(row["installStatus"]["status"], "complete")
                self.assertIsNone(row["saveLocation"])
                self.assertIsNone(row["windowTitle"])
                self.assertFalse(row["launch"]["executed"])
        self.assertEqual(self.packet["gameLaunches"], 0)
        self.assertTrue(self.packet["readOnlyCollection"])

    def test_every_field_has_dated_scoped_sources_even_when_unknown(self):
        for row in self.packet["items"]:
            for field in FIELDS:
                with self.subTest(product=row["storeId"], field=field):
                    detail = row["researchEvidence"][field]
                    self.assertEqual(
                        detail["status"],
                        "unknown" if row[field] is None else "public-expectation",
                    )
                    self.assertTrue(detail["sources"])
                    for source in detail["sources"]:
                        parsed = urlparse(source["url"])
                        self.assertEqual(parsed.scheme, "https")
                        self.assertTrue(parsed.netloc)
                        self.assertEqual(date.fromisoformat(source["checkedAt"]).isoformat(), CHECKED_AT)
                        self.assertTrue(source["scope"])
                        self.assertTrue(source["finding"])

    def test_store_paths_require_explicit_store_evidence_and_no_host_expansion(self):
        for row in self.packet["items"]:
            with self.subTest(product=row["storeId"]):
                path = row["save_path"]
                if path is None:
                    self.assertIsNone(row["save_path_uses_wgs"])
                    continue
                self.assertTrue(path.startswith(("%LOCALAPPDATA%\\", "%USERPROFILE%\\")))
                self.assertNotIn("Steam", path)
                self.assertNotIn("/Users/", path)
                self.assertIn(
                    "Microsoft Store",
                    row["researchEvidence"]["save_path"]["sources"][0]["scope"],
                )
                self.assertEqual(
                    row["save_path_uses_wgs"], r"\systemappdata\wgs" in path.lower(),
                )
        by_id = {row["storeId"]: row for row in self.packet["items"]}
        for store_id in (
            "9MWR1NC6VQ6L", "9PJPCB188SVG", "9P2J5D12GJL5", "9P3T7HVKM6D0",
            "9P03JGQ4S1GC", "9N8C07SS8C9D", "9NGH1FK0RJGL", "9NQVHHW88XW9",
        ):
            self.assertIsNone(by_id[store_id]["save_path"])
        self.assertIsNone(by_id["9NQVHHW88XW9"]["xbox_cloud"])
        self.assertFalse(by_id["9P1N07XDL1D4"]["save_path_uses_wgs"])
        self.assertTrue(by_id["9P1N07XDL1D4"]["xbox_cloud"])

    def test_expected_window_substring_is_not_an_observed_exact_selector(self):
        for row in self.packet["items"]:
            self.assertIsNone(row["window_class"])
            self.assertIsNone(row["windowTitle"])
            if row["storeId"] == "9P03JGQ4S1GC":
                self.assertEqual(row["window_title"], "Skyrim Special Edition")
                self.assertIn(
                    "substring",
                    row["researchEvidence"]["window_title"]["sources"][0]["finding"],
                )
            else:
                self.assertIsNone(row["window_title"])

    def test_counts_treat_false_cloud_as_known_and_reject_identity_drift(self):
        for field in FIELDS:
            known = sum(row[field] is not None for row in self.packet["items"])
            self.assertEqual(
                self.packet["publicResearchCounts"][field],
                {"populated": known, "unknown": 16 - known},
            )
        changed = copy.deepcopy(self.base)
        changed["items"].reverse()
        with self.assertRaisesRegex(ValueError, "identities/order"):
            build_packet(changed)


if __name__ == "__main__":
    unittest.main()
