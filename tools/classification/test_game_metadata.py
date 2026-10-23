"""Synthetic extractor edge cases plus invariants on the real captured database."""

import copy
from collections import Counter
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.error
from io import BytesIO
from email.message import Message

import game_metadata as metadata
from classify_catalogue import CATALOGUE, catalog_batch_evidence, desktop_packages, fetch_json, load_json, validate


SID = "AAAAAAAAAAAA"
OTHER = "BBBBBBBBBBBB"
SOURCE = {
    "url": "https://displaycatalog.mp.microsoft.com/v7.0/products?bigIds=" + SID + "&market=RO&languages=en-US",
    "checkedAt": "2026-10-23T10:00:00+00:00", "responseSha256": "a" * 64,
    "responseBytes": 100, "httpDate": None,
}


def sample_product(sid=SID):
    return {
        "ProductId": sid, "ProductKind": "Game", "ProductType": "Game",
        "ProductFamily": "Games",
        "LocalizedProperties": [{"Language": "en", "Markets": ["RO"], "ProductTitle": "Test game"}],
        "Properties": {"IsDemo": False, "ProductGroupId": "group"},
        "MarketProperties": [{"Markets": ["RO"], "OriginalReleaseDate": "2025-01-01T00:00:00Z"}],
        "DisplaySkuAvailabilities": [{
            "Sku": {"SkuId": "0010", "SkuType": "full", "Properties": {
                "IsBundle": False, "IsPreOrder": False, "BundledSkus": [],
                "Packages": [{
                    "PackageFormat": "MSIXVC", "ContentId": "content", "PackageId": "package",
                    "Version": "0", "PackageFamilyName": "Example.Game_publisher",
                    "Architectures": ["x64"],
                    "PlatformDependencies": [{"PlatformName": "Windows.Desktop"}],
                    "KeyBlob": "must-not-export", "PackageDownloadUris": [{"Uri": "secret"}],
                }],
            }},
        }],
    }


def sample_database():
    fact = metadata.catalogue_facts(sample_product(), SOURCE, "RO")
    return {
        "products": {SID: {
            "desktopCatalog": fact, "antiCheat": "none",
            "antiCheatEvidence": {"type": "package-scan", "checkedAt": "2026-10-22"},
            "supported01": True, "launchProof": [{"localPath": "/private/proof"}],
        }},
        "desktopCatalogSnapshot": {
            "checkedAt": SOURCE["checkedAt"], "productIds": [SID],
            "scope": {"market": "RO", "language": "en-US", "platform": "Windows.Desktop",
                      "plan": "cfq7ttc0kgq8", "feedId": metadata.FEED_ID, "feedTitle": "All PC Games"},
            "membership": {**SOURCE, "url": metadata.feed_url("RO")},
            "status": "complete", "errors": [], "missingCanonicalProductIds": [],
        },
    }


class MetadataTests(unittest.TestCase):
    def test_desktop_only_not_console_or_undeclared(self):
        product = sample_product()
        packages = product["DisplaySkuAvailabilities"][0]["Sku"]["Properties"]["Packages"]
        console = copy.deepcopy(packages[0])
        console.update(PackageFormat="XVC", PlatformDependencies=[{"PlatformName": "Windows.Xbox"}])
        packages.extend([console, {"PackageFormat": "MSIXVC"}])
        result = desktop_packages(product)
        self.assertEqual([p["rawFormat"] for p in result], ["MSIXVC"])
        self.assertEqual(result[0]["contentId"], "content")
        self.assertEqual(result[0]["skuId"], "0010")
        with patch("classify_catalogue.request_json", return_value={"Products": [product]}):
            evidence = catalog_batch_evidence([SID], "RO")[SID]
        self.assertEqual(evidence["packageFormatEvidence"]["observedFormats"], ["MSIXVC"])
        product["DisplaySkuAvailabilities"][0]["Sku"]["Properties"]["Packages"] = [console]
        with patch("classify_catalogue.request_json", return_value={"Products": [product]}):
            self.assertEqual(catalog_batch_evidence([SID], "RO")[SID]["packageFormat"], "unknown")

    def test_unknown_format_preserved_not_msixvc(self):
        product = sample_product()
        product["DisplaySkuAvailabilities"][0]["Sku"]["Properties"]["Packages"][0]["PackageFormat"] = "FutureFormat"
        observation = desktop_packages(product)[0]
        self.assertEqual(observation["rawFormat"], "FutureFormat")
        self.assertEqual(observation["family"], "unknown")
        facts = metadata.catalogue_facts(product, SOURCE, "RO")
        self.assertIn("no-known-desktop-full-game-format", metadata.eligibility(facts, SOURCE["checkedAt"]))

    def test_en_market_title_and_conflicting_locale_remain_explicit(self):
        product = sample_product()
        self.assertEqual(metadata.catalogue_facts(product, SOURCE, "RO")["title"], "Test game")
        product["LocalizedProperties"].append({
            "Language": "en-US", "Markets": ["RO"], "ProductTitle": "Conflicting title"})
        self.assertIsNone(metadata.catalogue_facts(product, SOURCE, "RO")["title"])

    def test_bundle_unreleased_demo_launcher_missing_flags_excluded(self):
        cases = [
            (lambda p: p["DisplaySkuAvailabilities"][0]["Sku"]["Properties"].update(IsBundle=True), "bundle-preorder"),
            (lambda p: p["DisplaySkuAvailabilities"][0]["Sku"]["Properties"].update(IsPreOrder=True), "bundle-preorder"),
            (lambda p: p["MarketProperties"][0].update(OriginalReleaseDate="2099-01-01T00:00:00Z"), "unreleased"),
            (lambda p: p["Properties"].update(IsDemo=True), "demo"),
            (lambda p: p["LocalizedProperties"][0].update(ProductTitle="Game Launcher"), "ambiguous"),
            (lambda p: p["DisplaySkuAvailabilities"][0]["Sku"]["Properties"].pop("IsBundle"), "bundle-preorder"),
        ]
        for change, reason in cases:
            with self.subTest(reason=reason):
                product = sample_product()
                change(product)
                exclusions = metadata.eligibility(metadata.catalogue_facts(product, SOURCE, "RO"), SOURCE["checkedAt"])
                self.assertTrue(any(reason in item for item in exclusions))

    def test_duplicate_identity_components_all_excluded(self):
        database = sample_database()
        database["products"][OTHER] = copy.deepcopy(database["products"][SID])
        database["products"][OTHER]["desktopCatalog"]["productId"] = OTHER
        database["products"][OTHER]["desktopCatalog"]["source"]["url"] = SOURCE["url"].replace(SID, OTHER)
        database["desktopCatalogSnapshot"]["productIds"].append(OTHER)
        projection, audit = metadata.project(database)
        self.assertEqual(audit["qualifiedDistinctReleasedBaseGames"], 0)
        self.assertTrue(all("duplicate-or-edition-identity-ambiguous" in r["qualificationExclusions"]
                            for r in projection["products"]))

    def test_projection_allowlist_strips_nested_private_fields(self):
        database = sample_database()
        facts = database["products"][SID]["desktopCatalog"]
        facts["packages"][0]["KeyBlob"] = "must-not-export"
        facts["source"]["localPath"] = "/private"
        facts["fullSkus"][0]["account"] = "must-not-export"
        before = copy.deepcopy(database)
        projection, _ = metadata.project(database)
        metadata.validate_schema(projection, metadata.metadata_schema())
        raw = json.dumps(projection)
        for value in ("KeyBlob", "must-not-export", "supported01", "launchProof", "/private", "PackageDownloadUris"):
            self.assertNotIn(value, raw)
        self.assertEqual(database, before)

    def test_stale_or_failed_refresh_not_certified_and_wrong_scope_rejected(self):
        database = sample_database()
        database["products"][SID]["desktopCatalog"]["source"]["checkedAt"] = "2026-10-21T10:00:00Z"
        projection, audit = metadata.project(database)
        self.assertEqual(audit["qualifiedDistinctReleasedBaseGames"], 0)
        self.assertIn("catalogue-evidence-not-current-complete-scope",
                      projection["products"][0]["qualificationExclusions"])
        database["products"][SID]["desktopCatalog"]["source"]["url"] += "&token=secret"
        with self.assertRaises(ValueError):
            metadata.project(database)

    def test_unknown_and_legacy_none_never_verified_absence(self):
        product = sample_database()["products"][SID]
        self.assertEqual(metadata.anti_cheat_metadata(product)["claim"], "not-detected")
        product["antiCheatEvidence"].update(type="public-source", source="https://www.pcgamingwiki.com/wiki/Test")
        self.assertEqual(metadata.anti_cheat_metadata(product)["claim"], "manual-override")
        product["antiCheat"] = "EAC"
        public = metadata.anti_cheat_metadata(product)
        self.assertEqual(public["claim"], "unknown")
        self.assertEqual(public["technologies"], [])
        product["antiCheatEvidence"]["source"] = "https://example.com/?token=secret"
        with self.assertRaises(ValueError):
            metadata.anti_cheat_metadata(product)

    def test_age_of_empires_unknown_retains_primary_source_citations(self):
        database = load_json(CATALOGUE)
        row = database["products"]["9N94NCGM1Q2N"]
        self.assertEqual(row["title"], "Age of Empires IV: Anniversary Edition")
        self.assertEqual(row["packageFormat"], "MSIXVC")
        self.assertEqual(row["antiCheat"], "unknown")
        self.assertEqual(row["antiCheatEvidence"]["type"], "unknown")
        self.assertIsNone(row["supported01"])
        checks = row["antiCheatEvidence"]["publicChecks"]
        self.assertEqual(len(checks), 2)
        self.assertTrue(all(c["sourceType"] == "publisher" for c in checks))
        self.assertTrue(all("not evidence of absence" in c["result"] for c in checks))
        projection, _ = metadata.project(database)
        projected = next(x["antiCheat"] for x in projection["products"]
                         if x["productId"] == "9N94NCGM1Q2N")
        self.assertEqual(projected["claim"], "unknown")
        self.assertEqual(projected["technologies"], [])
        self.assertEqual(projected["sources"], [
            row["antiCheatEvidence"]["source"],
            "https://www.ageofempires.com/news/age-of-empires-iv-patch-16-2-10475/",
            "https://support.ageofempires.com/hc/en-us/articles/4408424670484-Age-of-Empires-IV-Known-Issues-Solutions",
        ])

    def test_schema_rejects_unknown_keys_and_wrong_types(self):
        projection, _ = metadata.project(sample_database())
        projection["products"][0]["proofPath"] = "/private"
        with self.assertRaises(ValueError):
            metadata.validate_schema(projection, metadata.metadata_schema())
        del projection["products"][0]["proofPath"]
        projection["schemaVersion"] = True
        with self.assertRaises(ValueError):
            metadata.validate_schema(projection, metadata.metadata_schema())

    def test_feed_scope_duplicates_unknown_and_missing_authoring_rows(self):
        feed = [{"title": "All PC Games"}, {"id": SID}, {"id": SID}]
        self.assertEqual(metadata.feed_ids(feed), [SID])
        feed[0]["title"] = "Day one releases"
        with self.assertRaises(ValueError):
            metadata.feed_ids(feed)
        database = sample_database()
        database["desktopCatalogSnapshot"]["productIds"].append(OTHER)
        database["desktopCatalogSnapshot"]["missingCanonicalProductIds"] = [OTHER]
        projection, audit = metadata.project(database)
        self.assertEqual(projection["status"], "partial")
        self.assertEqual(audit["exclusions"][-1]["reasons"], ["no-scoped-desktop-catalogue"])

    def test_deterministic_export_checksums_and_manifest(self):
        database = sample_database()
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            (output / "NOTICES.txt").write_text("Rights hold")
            with patch.object(metadata, "OUTPUT", output):
                metadata.export(database, "a" * 40)
                before = {p.name: p.read_bytes() for p in output.iterdir()}
                metadata.export(database, "a" * 40)
                self.assertEqual(before, {p.name: p.read_bytes() for p in output.iterdir()})
            manifest = json.loads(before["manifest-v1.json"])
            for name, expected in manifest["files"].items():
                self.assertEqual(metadata.digest(before[name]), expected["sha256"])
                self.assertEqual(len(before[name]), expected["bytes"])
            self.assertFalse(manifest["updaterSupported"])
            self.assertEqual(manifest["releaseStatus"], "hold")

    def test_capture_is_additive_and_bounded_without_account_or_game_endpoints(self):
        database = {"market": "RO", "products": {SID: {
            "title": "Legacy", "packageFormat": "unknown", "antiCheat": "unknown",
            "supported01": None, "launchProof": [],
        }}}
        legacy = copy.deepcopy(database["products"][SID])
        response = sample_product()
        reads = [
            ([{"title": "All PC Games"}, {"id": SID}], SOURCE),
            ({"Products": [response]}, SOURCE),
        ]
        with patch("game_metadata.fetch_json", side_effect=reads) as fetch:
            metadata.capture(database)
        self.assertEqual(fetch.call_count, 2)
        self.assertIn("catalog.gamepass.com", fetch.call_args_list[0].args[0])
        self.assertIn("displaycatalog.mp.microsoft.com", fetch.call_args_list[1].args[0])
        self.assertEqual(legacy, {k: v for k, v in database["products"][SID].items()
                                  if k != "desktopCatalog"})
        with patch("game_metadata.fetch_json", side_effect=reads), patch.object(metadata, "MAX_BYTES", 1):
            with self.assertRaisesRegex(RuntimeError, "byte budget"):
                metadata.capture(copy.deepcopy(database))

    def test_retry_budget_and_retry_after_are_not_silently_ignored(self):
        headers = Message()
        headers["Retry-After"] = "300"
        rate_limit = urllib.error.HTTPError(SOURCE["url"], 429, "rate limit", headers, BytesIO())
        with patch("urllib.request.urlopen", side_effect=rate_limit) as request:
            with self.assertRaisesRegex(RuntimeError, "Retry-After"):
                fetch_json(SOURCE["url"])
            self.assertEqual(request.call_count, 1)
        transient = urllib.error.URLError("temporary")
        with patch("urllib.request.urlopen", side_effect=transient) as request, patch("time.sleep"):
            with self.assertRaises(urllib.error.URLError):
                fetch_json(SOURCE["url"])
            self.assertEqual(request.call_count, 3)

    def test_real_capture_count_privacy_and_legacy_reader_bounds(self):
        database = load_json(CATALOGUE)
        validate(database)
        projection, audit = metadata.project(database)
        metadata.validate_schema(projection, metadata.metadata_schema())
        self.assertGreaterEqual(audit["qualifiedDistinctReleasedBaseGames"], 300)
        self.assertEqual(audit["qualifiedDistinctReleasedBaseGames"],
                         sum(row["qualifiedBaseGame"] for row in projection["products"]))
        self.assertLess(CATALOGUE.stat().st_size, 4 * 1024 * 1024)
        self.assertLessEqual(len(database["products"]), 4096)
        self.assertEqual(len(database["products"]), 565)
        self.assertEqual(database["version"], 1)
        for product in database["products"].values():
            # Existing Codable Entry fields retain their original shape.
            self.assertIsInstance(product["pcPackageIdentified"], bool)
            self.assertIsInstance(product["antiCheat"], str)
            self.assertIsInstance(product["technologyReferences"], list)
            self.assertLessEqual(len(product["technologyReferences"]), 16)
            self.assertIsInstance(product["referencePlatforms"], list)
        self.assertTrue(all("Windows.Desktop" in p["platforms"]
                            for r in projection["products"] for p in r["packages"]))
        self.assertNotIn('"supported01"', json.dumps(projection))
        self.assertNotIn("/Users/", json.dumps(projection))
        claims = Counter(row["antiCheat"]["claim"] for row in projection["products"])
        self.assertEqual(claims.get("not-detected"), 7)
        self.assertEqual(claims.get("manual-override"), 2)
if __name__ == "__main__":
    unittest.main()
