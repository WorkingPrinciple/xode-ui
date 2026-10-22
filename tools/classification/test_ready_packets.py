"""Validate the published real-title packets without launching games or checking accounts."""

import shlex
import unittest
from pathlib import Path

from build_ready_packets import CLI_SHA, COM_STA_RECIPES, WAITING_RANKS
from inspect_queue import DATA, load_json


class ReadyPacketTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.packet = load_json(DATA / "s3-ready-packets-v1.json")
        cls.queue = {
            row["storeId"]: row for row in load_json(DATA / "next-30-queue.json")["items"]
        }

    def test_fifteen_waiting_plus_complete_keeper_in_rank_order(self):
        rows = self.packet["items"]
        ranks = [row["rank"] for row in rows]
        self.assertEqual(ranks, sorted(WAITING_RANKS | {22}))
        self.assertEqual(len({row["storeId"] for row in rows}), 16)
        self.assertIs(self.packet["readOnlyCollection"], True)
        self.assertEqual(self.packet["gameLaunches"], 0)
        self.assertEqual(self.packet["cliSha256"], CLI_SHA)

    def test_ready_receipts_and_manifest_arguments(self):
        for row in self.packet["items"]:
            with self.subTest(product=row["storeId"]):
                status = row["installStatus"]
                self.assertEqual(status["operation"], "install-status")
                self.assertEqual(status["product"], row["storeId"])
                self.assertEqual(status["game_dir"], row["gameDir"])
                self.assertEqual(status["status"], "complete")
                self.assertIs(status["success"], True)
                self.assertEqual(status["exit_code"], 0)
                self.assertEqual(row["manifest"]["arguments"], [])
                self.assertEqual(len(row["manifest"]["executables"]), 1)
                self.assertEqual(row["graphicsAPI"], self.queue[row["storeId"]]["api"])

    def test_commands_are_literal_and_isolated_per_title(self):
        prefixes = []
        for row in self.packet["items"]:
            with self.subTest(product=row["storeId"]):
                launch = row["launch"]
                argv = launch["argv"]
                self.assertEqual(argv[:3], [self.packet["cli"], "launch", row["storeId"]])
                self.assertEqual(argv[argv.index("--game-dir") + 1], row["gameDir"])
                self.assertEqual(argv[argv.index("--engine") + 1], row["s1Profile"]["name"])
                self.assertEqual(argv[argv.index("--prefix") + 1], launch["prefix"])
                relative = argv[argv.index("--exe") + 1]
                self.assertFalse(Path(relative).is_absolute())
                self.assertNotIn("..", Path(relative).parts)
                self.assertEqual(relative, row["manifest"]["executables"][0]["name"])
                self.assertIs(launch["executed"], False)
                expected = argv
                if launch["environment"]:
                    expected = ["env", "XODUS_PRIVATE_RUNTIME_COM_STA=1", *argv]
                self.assertEqual(shlex.split(launch["shellCommand"]), expected)
                self.assertNotEqual(launch["prefix"], row["s1Profile"]["preparedTemplatePrefix"])
                prefixes.append(launch["prefix"])
        self.assertEqual(len(prefixes), len(set(prefixes)))

    def test_com_prophylaxis_is_title_scoped_and_unknowns_stay_unknown(self):
        for row in self.packet["items"]:
            with self.subTest(product=row["storeId"]):
                self.assertNotIn("XODUS_PRIVATE_RUNTIME_COM_STA", row["s1Profile"]["environment"])
                expected = (
                    {"XODUS_PRIVATE_RUNTIME_COM_STA": "1"}
                    if row["storeId"] in COM_STA_RECIPES else {}
                )
                self.assertEqual(row["launch"]["environment"], expected)
                self.assertIsNone(row["encryptedMSIXVC"])
                self.assertIsNone(row["saveLocation"])
                self.assertIsNone(row["windowTitle"])
                self.assertIsNone(row["signIn"]["shimDirNeededForSignIn"])


if __name__ == "__main__":
    unittest.main()
