"""Frozen research invariants; no network, process execution or game evidence mocks."""

import copy
import unittest
from unittest.mock import patch

from build_catalogue_batch import ORDER, build
from inspect_queue import DATA, load_json


class CatalogueBatchTests(unittest.TestCase):
    def test_ranking_reproduces_and_never_emits_executable_recipes(self):
        packet = load_json(DATA / "s3-preflight-catalogue-v1.json")
        with patch("subprocess.run", side_effect=AssertionError("No process")):
            self.assertEqual(packet, build(packet["collectionInputs"]))
        self.assertEqual(packet["items"], [])
        self.assertEqual(len(packet["blockedItems"]), 8)
        self.assertEqual(packet["candidateOrder"], [row[0] for row in ORDER])
        self.assertFalse(packet["installPolicy"]["authorizedNow"])
        for row in packet["blockedItems"]:
            self.assertEqual(row["ownership"], "catalogue, ownership unverified")
            self.assertIsNone(row["launch"])
            self.assertIsNone(row["discovery"])
            self.assertIsNone(row["installStatus"])
            self.assertFalse(row["readyForLaunch"])
            self.assertFalse(row["preflight"]["installAttempted"])
            self.assertTrue(row["evidenceAssessment"]["positiveProtonProxy"])
            self.assertTrue(row["evidenceAssessment"]["singlePlayerSteamCategory"])
            self.assertIsNone(row["evidenceAssessment"]["offlineXboxBuild"])
            self.assertEqual(row["antiCheat"], "unknown")
            self.assertFalse(row["evidenceAssessment"]["noAntiCheatEstablished"])
            self.assertTrue(row["public"]["pcgamingwiki"]["bodyAvailable"])
            self.assertEqual(row["public"]["drmNetworkInspection"]["httpStatus"], 200)
            self.assertGreater(row["downloadSizeBytes"], 0)

    def test_existing_titles_and_service_caveats_are_not_erased(self):
        packet = load_json(DATA / "s3-preflight-catalogue-v1.json")
        inputs = copy.deepcopy(packet["collectionInputs"])
        inputs["installed"][0]["storeIds"].append(ORDER[0][0])
        with self.assertRaisesRegex(ValueError, "not a new uninstalled"):
            build(inputs)
        hades = next(row for row in packet["rejected"] if row["title"] == "Hades")
        self.assertIn("Xbox Live", hades["reason"])
        self.assertTrue(hades["evidence"])
        silksong = next(row for row in packet["blockedItems"]
                        if row["storeId"] == "9N116V0599HB")
        self.assertIn("not signed in",
                      silksong["evidenceAssessment"]["knownStoreServiceCaveat"])

    def test_installed_kex_facts_do_not_invent_renderer_or_engine_version(self):
        packet = load_json(DATA / "doom-quake-installed-facts-v1.json")
        self.assertTrue(packet["readOnly"])
        self.assertEqual(packet["gameLaunches"], 0)
        self.assertEqual(packet["decryptedFiles"], 0)
        exes = {"9MXND4PQLK3W": "DOOM64_x64.exe",
                "9P1Z43KRNQD4": "bastet_WinStore.exe"}
        for row in packet["items"]:
            self.assertEqual(row["package"]["executables"], [exes[row["storeId"]]])
            self.assertIsNone(row["launch"])
            self.assertIsNone(row["activeRenderer"])
            self.assertIsNone(row["installedEngineVersion"])
            self.assertEqual(row["lastCompleteAdf8Status"]["status"], "complete")
            self.assertTrue(row["resources"])
            for resource in row["resources"]:
                self.assertTrue(resource["archiveReadableWithoutDecryption"])
                self.assertTrue(resource["headerHex"].startswith("504b0304"))
                self.assertEqual(len(resource["sha256"]), 64)


if __name__ == "__main__":
    unittest.main()
