"""Offline preflight invariants; synthetic rows exercise mechanics, not evidence."""

import copy
import hashlib
from pathlib import Path
import shlex
import unittest
from unittest.mock import patch

from build_preflight_packets import (
    CLI_SHA, COM_KEYS, DATA, ORDER, OUTPUT, build, launch_recipe, status_command,
    validate_status,
)
from inspect_queue import load_json


class PreflightRecipeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base = load_json(DATA / "s3-ready-packets-v4.json")
        cls.row = next(row for row in cls.base["items"] if row["storeId"] == ORDER[0])

    def candidate(self, pending):
        argv = self.row["launch"]["argv"]
        return {"items": [{
            "storeId": self.row["storeId"], "pendingTest": pending,
            "launch": {
                "engine": argv[argv.index("--engine") + 1],
                "executable": argv[argv.index("--exe") + 1],
                "environment": {"XODUS_PRIVATE_RUNTIME_COM_STA": "1"},
                "unsetEnvironment": ["CX_APPLEGPTK_LIBD3DSHARED_PATH"],
            },
        }]}

    def test_default_does_not_infer_sta(self):
        row = copy.deepcopy(self.row)
        launch, selected = launch_recipe(row, {"items": []})
        self.assertIsNone(selected)
        self.assertEqual(launch["environment"], {})
        self.assertEqual(launch["unsetEnvironment"], list(COM_KEYS))
        self.assertEqual(launch["argv"], row["launch"]["argv"])
        self.assertEqual(shlex.split(launch["shellCommand"]),
                         ["env", "-u", COM_KEYS[0], "-u", COM_KEYS[1], *launch["argv"]])
        self.assertEqual(row, self.row)

    def test_pending_candidate_is_recorded_not_automatically_applied(self):
        launch, selected = launch_recipe(self.row, self.candidate(True))
        self.assertTrue(selected["pendingTest"])
        self.assertEqual(launch["environment"], {})
        self.assertNotIn("CX_APPLEGPTK_LIBD3DSHARED_PATH", launch["unsetEnvironment"])
        diagnostic, _ = launch_recipe(self.row, self.candidate(True), diagnostic_opt_in=True)
        self.assertEqual(diagnostic["environment"], {"XODUS_PRIVATE_RUNTIME_COM_STA": "1"})

    def test_explicit_nonpending_selection_applies_env_and_unsets(self):
        launch, selected = launch_recipe(self.row, self.candidate(False))
        self.assertFalse(selected["pendingTest"])
        self.assertEqual(launch["environment"], {"XODUS_PRIVATE_RUNTIME_COM_STA": "1"})
        self.assertIn("CX_APPLEGPTK_LIBD3DSHARED_PATH", launch["unsetEnvironment"])
        self.assertIn("XODUS_PRIVATE_RUNTIME_COM_STA=1", shlex.split(launch["shellCommand"]))

    def test_conflict_and_changed_executable_are_rejected(self):
        candidate = self.candidate(False)
        candidate["items"][0]["launch"]["environment"]["XODUS_PRIVATE_CALLER_OWNS_COM"] = "1"
        with self.assertRaisesRegex(ValueError, "Conflicting"):
            launch_recipe(self.row, candidate)
        candidate = self.candidate(False)
        candidate["items"][0]["launch"]["executable"] = "other.exe"
        with self.assertRaisesRegex(ValueError, "executable differs"):
            launch_recipe(self.row, candidate)

    def test_status_is_account_free_and_every_readiness_dimension_is_checked(self):
        command = status_command(self.row)
        self.assertEqual(command[1:3], ["install-status", ORDER[0]])
        self.assertNotIn("--account-profile", command)
        receipt = self.row["installStatus"]
        validate_status(self.row, receipt)
        for key, value in (
            ("status", "partial"), ("success", False), ("exit_code", 1),
            ("operation", "launch"), ("product", "OTHER"), ("game_dir", "/other"),
        ):
            changed = {**receipt, key: value}
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "complete"):
                validate_status(self.row, changed)


class PublishedPreflightTests(unittest.TestCase):
    def test_frozen_packet_is_reproducible_without_live_io(self):
        packet = load_json(OUTPUT)
        base = load_json(DATA / "s3-ready-packets-v4.json")
        original = copy.deepcopy(base)
        with patch("subprocess.run", side_effect=AssertionError("No process")):
            self.assertEqual(build(base, packet["collectionInputs"]), packet)
        self.assertEqual(base, original)
        self.assertEqual(packet["baseV4"]["sha256"], hashlib.sha256(
            (DATA / "s3-ready-packets-v4.json").read_bytes()).hexdigest())
        self.assertEqual(packet["cliSha256"], CLI_SHA)
        self.assertEqual(packet["gameLaunches"], 0)
        self.assertEqual([row["storeId"] for row in packet["items"]], list(ORDER))
        self.assertEqual(len(packet["items"]), 6)
        fast_paths = {row["storeId"]: row for row in base["fastPaths"]}
        original_rows = {row["storeId"]: row for row in base["items"]}
        selected_engines = set()
        for row in packet["items"]:
            self.assertEqual(row["launch"]["argv"], original_rows[row["storeId"]]["launch"]["argv"])
            self.assertEqual(row["manifest"], original_rows[row["storeId"]]["manifest"])
            self.assertEqual(row["s1Profile"]["runtimeAssets"],
                             original_rows[row["storeId"]]["s1Profile"]["runtimeAssets"])
            selected_engines.add(row["s1Profile"]["name"])
            self.assertEqual(row["fastPath"], fast_paths[row["storeId"]])
            validate_status(row, row["installStatus"])
            preflight = row["preflight"]
            self.assertEqual(preflight["installStatus"]["processExitCode"], 0)
            command = preflight["discovery"]["argv"]
            self.assertIn("--discover", command)
            self.assertNotIn("--save-dir", command)
            self.assertNotIn("--window-title", command)
            self.assertEqual(command[2], str(OUTPUT.resolve()))
            output = Path(command[command.index("--output") + 1])
            self.assertTrue(output.is_absolute())
            self.assertFalse(preflight["discovery"]["executed"])
            self.assertEqual(command[command.index("--play-seconds") + 1], "300")
            shell = shlex.split(preflight["discovery"]["shellCommand"])
            self.assertEqual(shell[-len(command):], command)
            self.assertEqual(shell[0], "env")
            self.assertNotIn("--probe-exe", command)
            candidate = preflight["diagnosticCandidate"]
            if candidate:
                self.assertTrue(candidate["requiresExplicitS3Selection"])
                self.assertFalse(candidate["appliedToDefault"])
                self.assertEqual(row["launch"]["environment"], {})
                self.assertEqual(candidate["launch"]["environment"],
                                 preflight["titleRuntimeSelection"]["launch"]["environment"])
        self.assertEqual(
            {engine["name"] for engine in packet["collectionInputs"]["registry"]["engines"]},
            selected_engines,
        )


if __name__ == "__main__":
    unittest.main()
