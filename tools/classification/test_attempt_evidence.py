import json
from pathlib import Path
import tempfile
import unittest

from audit_attempt_evidence import audit, digest


class AttemptEvidenceTests(unittest.TestCase):
    def test_all_launch_outcomes_retained_without_raw_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            root = home / "Library/Application Support/XodusCLI/proofs/example"
            run = "11111111-1111-1111-1111-111111111111"
            run_dir = root / "runs" / run
            run_dir.mkdir(parents=True)
            result = {"operation": "launch", "product": "EXAMPLE", "run_id": run,
                      "engine": "example-engine", "prefix": str(home / "prefix"),
                      "exit_code": 5, "success": False}
            (run_dir / "result.json").write_text(json.dumps(result))
            (run_dir / "stderr.log").write_text("secret raw bearer token never copied")
            (root / "invocation.json").write_text(json.dumps({
                "argv": [str(home / "cli"), "launch", "EXAMPLE", "--state-dir", str(root),
                         "--prefix", str(home / "prefix"), "--runtime-dll", str(home / "runtime.dll")],
                "environment": {"TOKEN": "secret-account-value"},
            }))
            image = root / "world.png"
            image.write_bytes(b"image")
            (root / "integrity.json").write_text(json.dumps({
                str(image): digest(image),
                str(run_dir / "result.json"): digest(run_dir / "result.json")}))
            (root / "account.json").write_text('{"token":"private-account"}')
            inputs = {
                "candidates": [{"storeId": "EXAMPLE", "title": "Example"}],
                "matrix": {"snapshot": {"games": [{
                    "productId": "EXAMPLE", "title": "Example", "verdict": "INCONCLUSIVE",
                    "runId": run, "installStatusRunId": "not-a-launch",
                }]}},
                "ownerVerdicts": {"snapshot": {"items": []}},
            }
            packet = audit(inputs, home=home)
            attempts = packet["titles"]["EXAMPLE"]["attempts"]
            self.assertEqual(len(attempts), 1)
            self.assertEqual(attempts[0]["observedProcessResult"]["exit_code"], 5)
            self.assertEqual(attempts[0]["identities"]["prefix"][0]["value"], str(home / "prefix"))
            self.assertTrue(packet["artifacts"][str(image)]["matchesRecordedHash"])
            serialized = json.dumps(packet)
            self.assertNotIn("secret-account-value", serialized)
            self.assertNotIn("secret raw bearer", serialized)
            self.assertNotIn("private-account", serialized)
            image.unlink()
            followup = audit(inputs, packet, home)
            self.assertEqual(followup["artifacts"][str(image)]["status"], "MISSING")
            self.assertEqual(followup["artifacts"][str(image)]["recordedSha256"],
                             packet["artifacts"][str(image)]["sha256"])
            (run_dir / "result.json").unlink()
            retained = audit(inputs, packet, home)
            self.assertEqual(retained["titles"]["EXAMPLE"]["attempts"][0][
                "observedProcessResult"]["exit_code"], 5)
            self.assertTrue(any("prior indexed" in gap for gap in
                                retained["titles"]["EXAMPLE"]["attempts"][0]["gaps"]))

    def test_unresolved_attempt_is_explicit_not_fabricated(self):
        with tempfile.TemporaryDirectory() as directory:
            inputs = {"candidates": [], "matrix": {"snapshot": {"games": []}},
                      "ownerVerdicts": {"snapshot": {"items": [{
                          "storeId": "EXAMPLE", "title": "Example",
                          "verdict": "INCONCLUSIVE", "runId": "12345678",
                          "scope": "Known failed attempt",
                      }]}}}
            packet = audit(inputs, home=Path(directory))
            attempt = packet["titles"]["EXAMPLE"]["attempts"][0]
            self.assertEqual(attempt["runId"], "12345678")
            self.assertIsNone(attempt["observedProcessResult"])
            self.assertTrue(attempt["gaps"])
