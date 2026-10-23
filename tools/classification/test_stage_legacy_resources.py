"""Focused offline checks for the private, held legacy resource candidate."""

import copy
import json
from pathlib import Path
import tempfile
import unittest

from classify_catalogue import CATALOGUE, DATA_DIR, load_json
from game_metadata import canonical_bytes, digest
from stage_legacy_resources import (
    CONSUMER, ENTRY, clearance, export, project, schema, supported, validate,
)


class LegacyResourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.database = load_json(CATALOGUE)
        cls.publisher = load_json(DATA_DIR / "publisher-anti-cheat-v1.json")

    def test_exact_legacy_entry_values_and_policy_preserved(self):
        result, publisher = project(self.database, self.publisher)
        self.assertEqual(len(result["products"]), 565)
        self.assertEqual(len(publisher["products"]), 4)
        for product_id, original in self.database["products"].items():
            row = result["products"][product_id]
            for key in ENTRY:
                self.assertEqual(row.get(key), original.get(key))
            self.assertEqual(supported(row), supported(original))
            if supported(row):
                self.assertTrue(clearance(product_id, row))
                self.assertTrue(clearance(product_id, original))
        self.assertEqual(sum(map(supported, result["products"].values())), 9)

    def test_closed_recursive_allowlist_removes_private_payloads(self):
        database = copy.deepcopy(self.database)
        database["testCandidates"] = {"account": "secret"}
        database["private"] = "/Users/private/proofs/raw"
        for row in database["products"].values():
            row["launchProof"] = "/Users/private/proofs/raw"
            row["account"] = {"access_token": "secret"}
            row["desktopCatalog"] = {"raw": "not admitted"}
            if supported(row):
                row["antiCheatEvidence"]["publicChecks"][0]["account"] = "secret"
                if "packageScan" in row["antiCheatEvidence"]:
                    scan = row["antiCheatEvidence"]["packageScan"]
                    scan["root"] = "/Users/private/Game"
                    scan["rawInventory"] = ["private.exe"]
                    scan["packageIdentity"].update(manifest="Private.manifest", version="private-version", name="private-name")
        clean, _ = project(database, self.publisher)
        raw = canonical_bytes(clean).decode()
        for token in ("secret", "/Users/", "launchProof", "testCandidates",
                      "desktopCatalog", "private-version", "Private.manifest", "rawInventory"):
            self.assertNotIn(token, raw)
        for row in clean["products"].values():
            if "packageScan" in row.get("antiCheatEvidence", {}):
                self.assertEqual(set(row["antiCheatEvidence"]["packageScan"]["packageIdentity"]), {"storeId"})

    def test_unknown_missing_and_unspecified_never_clear(self):
        for value in ("unknown", "unspecified", None):
            database = copy.deepcopy(self.database)
            row = database["products"]["9PCR3Z2MSM4T"]
            row["antiCheat"] = value
            result, _ = project(database, self.publisher)
            self.assertFalse(supported(result["products"]["9PCR3Z2MSM4T"]))
            self.assertNotIn("antiCheatEvidence", result["products"]["9PCR3Z2MSM4T"])
            if value is None:
                self.assertEqual(result["products"]["9PCR3Z2MSM4T"]["antiCheat"], "unknown")

    def test_invalid_existing_clearance_fails_not_downgrades(self):
        for field in ("fileListSha256", "packageIdentity", "complete", "matches"):
            database = copy.deepcopy(self.database)
            del database["products"]["9PCR3Z2MSM4T"]["antiCheatEvidence"]["packageScan"][field]
            with self.assertRaises(ValueError):
                project(database, self.publisher)

    def test_mixed_format_unknowns_and_negative_policy_preserved(self):
        database = copy.deepcopy(self.database)
        for value in ("unknown", "EAppx", "MSIXVC / EAppx"):
            row = database["products"]["9PCR3Z2MSM4T"]
            row["packageFormat"] = value
            result, _ = project(database, self.publisher)
            self.assertEqual(result["products"]["9PCR3Z2MSM4T"]["packageFormat"], value)
            self.assertFalse(supported(result["products"]["9PCR3Z2MSM4T"]))
        database["products"]["9PCR3Z2MSM4T"]["antiCheat"] = "Easy Anti-Cheat"
        result, _ = project(database, self.publisher)
        self.assertEqual(result["products"]["9PCR3Z2MSM4T"]["antiCheat"], "Easy Anti-Cheat")

    def test_invalid_anticheat_values_fail(self):
        for value in ("", " ", "unknown\n", "x" * 513):
            database = copy.deepcopy(self.database)
            database["products"]["9PCR3Z2MSM4T"]["antiCheat"] = value
            with self.assertRaises(ValueError):
                project(database, self.publisher)

    def test_manual_methods_remove_raw_filenames_without_claim_change(self):
        result, _ = project(self.database, self.publisher)
        for product_id in ("9P03JGQ4S1GC", "C3KLDKZBHNCZ"):
            ac = result["products"][product_id]["antiCheatEvidence"]
            self.assertTrue(ac["method"].startswith("User-directed classification: "))
            self.assertIn("not independently verified absence", ac["method"])
            self.assertNotIn("packageScan", ac)
            self.assertNotIn(".manifest", ac["method"])
            self.assertNotIn(".dat", ac["method"])

    def test_private_values_in_retained_fields_fail(self):
        for bad in ("/Users/alice/proofs/test", "Bearer secret", "game.exe", "access_token=secret"):
            database = copy.deepcopy(self.database)
            database["products"]["9PCR3Z2MSM4T"]["antiCheatEvidence"]["publicChecks"][0]["result"] = bad
            with self.assertRaises(ValueError):
                project(database, self.publisher)

    def test_credential_and_unexpected_query_sources_fail(self):
        for bad in ("https://user:password@www.xbox.com/a",
                    "https://www.xbox.com/a?token=private",
                    "file:///private/a", "https://unapproved.example/a"):
            database = copy.deepcopy(self.database)
            database["packageSource"] = bad
            with self.assertRaises(ValueError):
                project(database, self.publisher)

    def test_schema_rejects_private_nested_fields_and_types(self):
        clean, publisher = project(self.database, self.publisher)
        validate(publisher, schema(publisher=True))
        clean["products"]["9PCR3Z2MSM4T"]["antiCheatEvidence"]["packageScan"]["root"] = "/private"
        with self.assertRaises(ValueError):
            validate(clean, schema())
        clean, _ = project(self.database, self.publisher)
        clean["products"]["9PCR3Z2MSM4T"]["pcPackageIdentified"] = 1
        with self.assertRaises(ValueError):
            validate(clean, schema())

    def test_publisher_title_binding_preserved_and_private_fields_removed(self):
        publisher = copy.deepcopy(self.publisher)
        for row in publisher["products"].values():
            row["rawAccount"] = "private"
        _, cleaned = project(self.database, publisher)
        self.assertEqual(cleaned, self.publisher)
        next(iter(publisher["products"].values()))["title"] = "wrong title"
        with self.assertRaises(ValueError):
            project(self.database, publisher)

    def test_deterministic_stage_checksums_bounds_and_rights_hold(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary).resolve() / "stage"
            audit = export(self.database, self.publisher, output)
            first = {p.relative_to(output).as_posix(): p.read_bytes()
                     for p in output.rglob("*") if p.is_file()}
            export(self.database, self.publisher, output)
            second = {p.relative_to(output).as_posix(): p.read_bytes()
                      for p in output.rglob("*") if p.is_file()}
            self.assertEqual(first, second)
            self.assertEqual(audit["consumerCommit"], CONSUMER)
            self.assertEqual(audit["releaseStatus"], "hold")
            self.assertEqual(audit["descriptiveClearanceMeaning"], {"not-detected": 7, "manual-override": 2})
            self.assertEqual(audit["verifiedAbsence"], 0)
            self.assertEqual(audit["fieldAudit"]["retainedInventoryDigests"], 7)
            self.assertIn("testCandidates", audit["fieldAudit"]["removedTopLevelFields"])
            self.assertLessEqual(len(first["CompatibilityData/game-compatibility-v1.json"]), 4 * 1024 * 1024)
            self.assertLessEqual(len(first["CompatibilityData/publisher-anti-cheat-v1.json"]), 256 * 1024)
            self.assertEqual(len(first), 8)
            for name, pin in audit["files"].items():
                self.assertEqual(pin, {"bytes": len(first[name]), "sha256": digest(first[name])})
            for line in first["SHA256SUMS"].decode().splitlines():
                sha, name = line.split("  ")
                self.assertEqual(sha, digest(first[name]))
            self.assertFalse(any("PublicMetadata" in name for name in first))

    def test_mixed_stage_and_symlink_output_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary).resolve() / "stage"
            output.mkdir()
            (output / "private-proof.json").write_text("{}")
            with self.assertRaises(ValueError):
                export(self.database, self.publisher, output)
            link = Path(temporary).resolve() / "link"
            link.symlink_to(output, target_is_directory=True)
            with self.assertRaises(ValueError):
                export(self.database, self.publisher, link)

    def test_input_database_unchanged(self):
        before = canonical_bytes(self.database)
        project(self.database, self.publisher)
        self.assertEqual(before, canonical_bytes(self.database))


if __name__ == "__main__":
    unittest.main()
