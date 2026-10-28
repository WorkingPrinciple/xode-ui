#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Synthetic checks for the REQ-32 run outcome extractor; no game or account data."""
import json
from pathlib import Path
import tempfile
import unittest

from extract_run_outcome import OutcomeError, extract
from legacy_compatibility import LEGACY_OUTCOME_PREFIX


def run_fixture(root, lines, product="9NR1R1XWLCNB"):
    run = Path(root) / "run-fixture"
    run.mkdir()
    (run / "result.json").write_text(json.dumps({
        "exit_code": 0, "engine": "calimocho-fixture", "product": product,
        "diagnostic": {"wine_debug": "warn+gdkc", "log": {"truncated": False}}}))
    (run / "stderr.log").write_text("\n".join(lines) + "\n")
    return run


class RunOutcomeChecks(unittest.TestCase):
    def test_outcome_lines_are_kept_and_redacted(self):
        with tempfile.TemporaryDirectory() as tmp:
            outcome = extract(run_fixture(tmp, [
                "1.0:01:warn:gdkc:user_Initialize ode outcome: sign-in OK status 0.",
                "1.1:01:warn:gdkc:x_user_XUserAddResult ode outcome: XUserAddResult status 0.",
                "1.15:01:warn:gdkc:x_user_url xuid(2533274800000000) ode outcome: XUserAddResult trace",
                "1.2:01:warn:gdkc:x_store_game_license_provider Microsoft-issued matching full-game licence validated; no identity or token logged.",
                "1.25:01:warn:gdkc:x_store_game_license_provider ode outcome: game licence validated status 0.",
                "1.3:01:warn:gdkc:x_store ode outcome: XStoreQueryGameLicenseResult status 0 isActive 1.",
                "1.4:01:fixme:other:unrelated line"]))
            self.assertEqual(outcome["missing"], [])
            self.assertIn("xuid(N)", outcome["outcomes"]["userAddResult"][1])
            self.assertNotIn("2533274800000000", json.dumps(outcome))

    def test_success_verdicts(self):
        good = ["1:01:warn:gdkc:f ode outcome: sign-in OK status 0.",
                "1:01:warn:gdkc:f ode outcome: XUserAddResult status 0.",
                "1:01:warn:gdkc:f ode outcome: game licence validated status 0.",
                "1:01:warn:gdkc:f ode outcome: XStoreQueryGameLicenseResult status 0 isActive 1."]
        with tempfile.TemporaryDirectory() as tmp:
            outcome = extract(run_fixture(tmp, good))
            self.assertTrue(outcome["pass"])
            self.assertEqual(set(outcome["verdicts"].values()), {"pass"})
        for index, bad in ((0, "1:01:warn:gdkc:f ode outcome: sign-in FAILED status 0x89245115."),
                           (2, "1:01:warn:gdkc:f ode outcome: game licence FAILED status 0x80004005."),
                           (3, "1:01:warn:gdkc:f ode outcome: XStoreQueryGameLicenseResult status 0 isActive 0.")):
            lines = list(good)
            lines[index] = bad
            with self.subTest(bad=bad[-40:]), tempfile.TemporaryDirectory() as tmp:
                outcome = extract(run_fixture(tmp, lines))
                self.assertEqual(outcome["missing"], [])
                self.assertFalse(outcome["pass"])
                self.assertIn("fail", outcome["verdicts"].values())

    def test_pre_rename_prefix_is_read_for_one_release(self):
        good = ["1:01:warn:gdkc:f ode outcome: sign-in OK status 0.",
                "1:01:warn:gdkc:f ode outcome: XUserAddResult status 0.",
                "1:01:warn:gdkc:f ode outcome: game licence validated status 0.",
                "1:01:warn:gdkc:f ode outcome: XStoreQueryGameLicenseResult status 0 isActive 1."]
        legacy = [line.replace("ode outcome:", LEGACY_OUTCOME_PREFIX) for line in good]
        with tempfile.TemporaryDirectory() as tmp:
            outcome = extract(run_fixture(tmp, legacy))
            self.assertEqual(outcome["missing"], [])
            self.assertTrue(outcome["pass"])
        failed = list(legacy)
        failed[0] = failed[0].replace("sign-in OK status 0.", "sign-in FAILED status 0x89245115.")
        with tempfile.TemporaryDirectory() as tmp:
            self.assertFalse(extract(run_fixture(tmp, failed))["pass"])

    def test_per_title_expectations(self):
        sign_in = ["1:01:warn:gdkc:f ode outcome: sign-in OK status 0.",
                   "1:01:warn:gdkc:f ode outcome: XUserAddResult status 0."]
        with tempfile.TemporaryDirectory() as tmp:
            hades = extract(run_fixture(tmp, sign_in, product="9P8DL6W0JBB8"))
            self.assertTrue(hades["pass"])
            self.assertEqual(hades["missing"], [])
        with tempfile.TemporaryDirectory() as tmp:
            fh6 = extract(run_fixture(tmp, sign_in, product="9NR1R1XWLCNB"))
            self.assertFalse(fh6["pass"])
            self.assertEqual(fh6["missing"], ["gameLicence", "storeLicenseResult"])
        with tempfile.TemporaryDirectory() as tmp:
            failed = extract(run_fixture(tmp, sign_in + [
                "1:01:warn:gdkc:f ode outcome: game licence FAILED status 0x80004005."], product="9P8DL6W0JBB8"))
            self.assertFalse(failed["pass"])
        with tempfile.TemporaryDirectory() as tmp:
            unknown = extract(run_fixture(tmp, sign_in, product="9ZZZZZZZZZZZ"))
            self.assertFalse(unknown["pass"])
            forced = extract(Path(tmp) / "run-fixture", expect=["signIn", "userAddResult"])
            self.assertTrue(forced["pass"])

    def test_store_product_lines_are_kept(self):
        with tempfile.TemporaryDirectory() as tmp:
            outcome = extract(run_fixture(tmp, ["1:01:warn:gdkc:f ode outcome: XStore entitled products status 0 count 3."]))
            self.assertEqual(len(outcome["outcomes"]["storeProducts"]), 1)

    def test_missing_outcomes_are_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            outcome = extract(run_fixture(tmp, ["1.0:01:warn:gdkc:f ode outcome: sign-in FAILED status 0x89245115",
                                                "1.1:01:warn:gdkc:f user initialization failed at rps with status 0x89245115"]))
            self.assertEqual(outcome["missing"], ["gameLicence", "storeLicenseResult", "userAddResult"])
            self.assertEqual(len(outcome["outcomes"]["signInFailure"]), 1)
            self.assertEqual(outcome["verdicts"]["signIn"], "fail")
            self.assertFalse(outcome["pass"])

    def test_token_like_content_fails_closed(self):
        pre = "1.0:01:warn:gdkc:f ode outcome: sign-in OK "
        for secret in (pre + "Authorization: XBL3.0 x=1;abc", pre + "token=abc", pre + "eyJhbGciOiJSUzI1NiJ9",
                       pre + "A" * 48, pre + "ab" * 20, pre + "ticket=t"):
            with self.subTest(secret=secret[:20]), tempfile.TemporaryDirectory() as tmp:
                with self.assertRaises(OutcomeError):
                    extract(run_fixture(tmp, [secret]))


if __name__ == "__main__":
    unittest.main()
