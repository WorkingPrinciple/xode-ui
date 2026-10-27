#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Synthetic checks for the WM_CLOSE receipt tool; a fake Wine script, no game or prefix."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from wm_close_run import close


def fixture(root, finished=True, wine_path="engine/bin/wine"):
    root = Path(root)
    wine = root / wine_path
    wine.parent.mkdir(parents=True)
    wine.write_text('#!/bin/sh\necho "args $* prefix-set ${WINEPREFIX:+yes} bottle ${CX_BOTTLE_PATH}/${CX_BOTTLE}"\n')
    wine.chmod(0o755)
    run = root / "run-fixture"
    run.mkdir()
    (run / "launch-command.json").write_text(json.dumps({"child": {
        "argv": ["/x/xodus-cli", "run", "/games/Fixture", str(wine), "--exe", "Fixture.exe"],
        "environment": {"WINEPREFIX": "/private/prefix/fixture"}}}))
    if finished:
        (run / "events.jsonl").write_text(json.dumps({"event": "finished", "exit_code": 0}) + "\n")
    return run, wine


class WMCloseReceiptChecks(unittest.TestCase):
    def test_receipt_hashes_prefix_and_records_exit(self):
        with tempfile.TemporaryDirectory() as tmp:
            run, wine = fixture(tmp)
            receipt = close(run, "Fixture.exe", Path(tmp) / "evidence", 5)
            text = (Path(tmp) / "evidence/quit-receipt.json").read_text()
            self.assertEqual(receipt["winePrefixSha256"], hashlib.sha256(b"/private/prefix/fixture").hexdigest())
            self.assertNotIn("/private/prefix", text)
            self.assertNotIn(str(wine), text)
            self.assertEqual(receipt["command"], ["<wine>", "taskkill", "/im", "Fixture.exe"])
            self.assertEqual(receipt["taskkillOutput"], "args taskkill /im Fixture.exe prefix-set yes bottle /")
            self.assertEqual(receipt["runExitCode"], 0)

    def test_crossover_wine_is_pointed_at_the_run_prefix_as_its_bottle(self):
        with tempfile.TemporaryDirectory() as tmp:
            run, _ = fixture(tmp, wine_path="CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine")
            receipt = close(run, "Fixture.exe", Path(tmp) / "evidence", 5)
            self.assertEqual(receipt["taskkillOutput"],
                             "args taskkill /im Fixture.exe prefix-set yes bottle /private/prefix/fixture")

    def test_force_or_path_arguments_are_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            run, _ = fixture(tmp)
            for exe in ("Fixture.exe /f", "../x.exe", "Fixture"):
                with self.subTest(exe=exe), self.assertRaises(ValueError):
                    close(run, exe, Path(tmp) / "evidence", 1)


if __name__ == "__main__":
    unittest.main()
