#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Synthetic checks for the REQ-32 run outcome extractor; no game or account data."""
import json
from pathlib import Path
import tempfile
import unittest

from extract_run_outcome import OutcomeError, extract


def run_fixture(root, lines):
    run = Path(root) / "run-fixture"
    run.mkdir()
    (run / "result.json").write_text(json.dumps({
        "exit_code": 0, "engine": "calimocho-fixture",
        "diagnostic": {"wine_debug": "warn+gdkc", "log": {"truncated": False}}}))
    (run / "stderr.log").write_text("\n".join(lines) + "\n")
    return run


class RunOutcomeChecks(unittest.TestCase):
    def test_outcome_lines_are_kept_and_redacted(self):
        with tempfile.TemporaryDirectory() as tmp:
            outcome = extract(run_fixture(tmp, [
                "1.0:01:warn:gdkc:user_Initialize xodus outcome: sign-in OK status 0",
                "1.1:01:warn:gdkc:x_user_XUserAddResult xodus outcome: XUserAddResult status 0 xuid(2533274800000000)",
                "1.2:01:warn:gdkc:x_store_game_license_provider Microsoft-issued matching full-game licence validated; no identity or token logged.",
                "1.3:01:warn:gdkc:x_store xodus outcome: XStoreQueryGameLicenseResult status 0 isActive 1",
                "1.4:01:fixme:other:unrelated line"]))
            self.assertEqual(outcome["missing"], [])
            self.assertIn("xuid(N)", outcome["outcomes"]["userAddResult"][0])
            self.assertNotIn("2533274800000000", json.dumps(outcome))

    def test_missing_outcomes_are_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            outcome = extract(run_fixture(tmp, ["1.0:01:warn:gdkc:f xodus outcome: sign-in FAILED status 0x89245115",
                                                "1.1:01:warn:gdkc:f user initialization failed at rps with status 0x89245115"]))
            self.assertEqual(outcome["missing"], ["gameLicence", "storeLicenseResult", "userAddResult"])
            self.assertEqual(len(outcome["outcomes"]["signInFailure"]), 1)

    def test_token_like_content_fails_closed(self):
        pre = "1.0:01:warn:gdkc:f xodus outcome: sign-in OK "
        for secret in (pre + "Authorization: XBL3.0 x=1;abc", pre + "token=abc", pre + "eyJhbGciOiJSUzI1NiJ9",
                       pre + "A" * 48, pre + "ab" * 20, pre + "ticket=t"):
            with self.subTest(secret=secret[:20]), tempfile.TemporaryDirectory() as tmp:
                with self.assertRaises(OutcomeError):
                    extract(run_fixture(tmp, [secret]))


if __name__ == "__main__":
    unittest.main()
