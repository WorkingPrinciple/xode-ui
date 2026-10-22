"""Offline checks for proxy identity, honest unknowns and non-launching priorities."""

import unittest
from urllib.parse import urlparse

from build_probability_packets import ASSESSMENTS, HOGWARTS, build
from collect_wine_proxies import wiki_fields
from inspect_queue import DATA, load_json


class ProbabilityPacketTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.packet = load_json(DATA / "s3-ready-packets-v3.json")
        cls.base = load_json(DATA / "s3-ready-packets-v2.json")
        cls.proxies = load_json(DATA / "wine-proxy-evidence-v1.json")

    def test_blank_wiki_values_cannot_swallow_the_next_rating(self):
        self.assertEqual(
            wiki_fields(
                "{{Compatibility/macOS\n|native = na\n|native notes = \n"
                "|crossover = perfect\n|crossover notes = \n|wine = unknown\n}}"
            ),
            {"native": "na", "crossover": "perfect", "wine": "unknown"},
        )
        self.assertEqual(wiki_fields("<html>404 not found</html>"), {})

    def test_offline_reproducible_exact_thirty_title_permutation(self):
        self.assertEqual(build(), self.packet)
        queue = load_json(DATA / "next-30-queue.json")["items"]
        items = self.packet["items"]
        self.assertEqual(len(items), 30)
        self.assertEqual(len(ASSESSMENTS), 30)
        self.assertEqual({row["storeId"] for row in items}, {row["storeId"] for row in queue})
        self.assertEqual([row["likelihoodOrder"] for row in items], list(range(1, 31)))
        self.assertTrue(self.packet["readOnlyCollection"])
        self.assertEqual(self.packet["gameLaunches"], 0)
        self.assertTrue(all(row["numericProbability"] is None for row in items))

    def test_sixteen_readiness_packets_are_not_displaced_by_required_hogwarts(self):
        original = {row["storeId"]: row for row in self.base["items"]}
        order = self.packet["s3TestOrder"]
        self.assertEqual(len(order), 16)
        self.assertEqual(set(order), set(original))
        self.assertEqual(order[0], "9P1N07XDL1D4")
        combined = self.packet["s3OrderIncludingRequiredHogwarts"]
        self.assertEqual(len(set(combined)), 17)
        self.assertEqual(combined[1], HOGWARTS)
        self.assertEqual([value for value in combined if value != HOGWARTS], order)
        self.assertEqual(
            [store_id for wave in self.packet["s3Waves"] for store_id in wave], combined,
        )
        self.assertTrue(all(1 <= len(wave) <= 2 for wave in self.packet["s3Waves"]))
        for row in self.packet["items"]:
            if row["storeId"] not in original:
                continue
            for key, value in original[row["storeId"]].items():
                self.assertEqual(row[key], value, (row["storeId"], key))

    def test_proxy_ratings_are_exact_and_unavailable_is_never_positive(self):
        for row in self.packet["items"]:
            evidence = row["compatibilityEvidence"]
            apple = evidence["appleGamingWiki"]
            cw = evidence["codeWeavers"]
            proton = evidence["protonDB"]
            self.assertEqual(cw["httpStatus"], 403)
            self.assertIsNone(cw["rating"])
            self.assertTrue(cw["identityBasis"])
            self.assertEqual(row["macOSMethodSummary"]["crossOverRating"], apple["ratings"].get("crossover"))
            self.assertIn("not CodeWeavers DB", row["macOSMethodSummary"]["scope"])
            for source in (apple, cw, proton):
                self.assertEqual(urlparse(source["url"]).scheme, "https")
                self.assertTrue(source["checkedAt"])
            if apple["httpStatus"] != 200:
                self.assertEqual(apple["ratings"], {})
            if apple["steamAppId"] is not None:
                self.assertEqual(apple["steamAppId"], evidence["steamAppId"])
            if proton["summary"] is not None:
                self.assertIsNotNone(evidence["steamAppId"])
                self.assertIn("/" + evidence["steamAppId"] + ".json", proton["url"])
                self.assertIn("total", proton["summary"])
        by_id = {row["storeId"]: row for row in self.packet["items"]}
        self.assertIsNone(by_id["9PJ8266BHFWN"]["compatibilityEvidence"]["protonDB"]["summary"])
        ffiv = by_id["9N8C07SS8C9D"]["compatibilityEvidence"]
        self.assertEqual(ffiv["steamAppId"], "1173800")
        self.assertTrue(ffiv["codeWeavers"]["url"].endswith("/final-fantasy-iv-1"))
        self.assertTrue(ffiv["codeWeavers"]["urlChangedSinceBlockedAttempt"])
        self.assertTrue(ffiv["codeWeavers"]["blockedAttemptUrl"].endswith("/final-fantasy-iv"))

    def test_drm_negative_reports_and_store_unknowns_survive_positive_proxies(self):
        by_id = {row["storeId"]: row for row in self.packet["items"]}
        for store_id in (HOGWARTS, "9P5Z4530318L"):
            row = by_id[store_id]
            self.assertIn("denuvo", row["drm"]["knownSteamNotice"].lower())
            self.assertFalse(row["drm"]["xboxDRMQualified"])
        self.assertEqual(
            by_id["9P5Z4530318L"]["compatibilityEvidence"]["protonDB"]["summary"]["tier"],
            "silver",
        )
        for store_id, kind in (
            ("9P5Z4530318L", "conflicting-version-dependent-graphics-reports"),
            ("9P2J5D12GJL5", "headline-versus-report-conflict"),
            ("9N94NCGM1Q2N", "public-mac-cpu-startup-failure"),
            ("9PMN4DGRT1LN", "unverified-full-game-download-size"),
        ):
            self.assertIn(kind, {blocker["kind"] for blocker in by_id[store_id]["blockers"]})
        original_queue = {
            row["storeId"]: row for row in load_json(DATA / "next-30-queue.json")["items"]
        }
        for row in self.packet["items"]:
            self.assertEqual(row["antiCheat"], original_queue[row["storeId"]]["antiCheat"])

    def test_capacity_disk_and_working_count_do_not_become_success_claims(self):
        policy = self.packet["testExecutionPolicy"]
        self.assertEqual(policy["maximumConcurrentTitles"], 2)
        self.assertEqual(policy["workingTarget"], 20)
        self.assertIsNone(policy["verifiedWorkingCount"])
        self.assertFalse(policy["launchesAuthorizedByThisPacket"])
        install = self.packet["installResumePolicy"]
        self.assertEqual(install["minimumFreeGiB"], 150)
        self.assertEqual(install["maximumConcurrentInstallers"], 1)
        self.assertEqual(install["maximumUntestedInstalledBacklog"], 6)
        self.assertFalse(install["resumeAutomaticallyNow"])
        rows = {row["storeId"]: row for row in self.packet["items"]}
        priorities = self.packet["installPriorityAfterDiskRelease"]
        self.assertEqual(priorities[0], "9NJCVGS6T30K")
        self.assertTrue(all(not rows[store_id]["alreadyInstalled"] for store_id in priorities))
        self.assertIn("9P861V1542BL", priorities)
        self.assertIn("placeholder", install["smallPayloadGuard"])


if __name__ == "__main__":
    unittest.main()
