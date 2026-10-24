import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "launch_admission", Path(__file__).with_name("launch-admission.py")
)
admission = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(admission)


class LaunchAdmissionTests(unittest.TestCase):
    def fixture(self, root):
        binary = root / "capture"
        binary.write_bytes(b"pinned capture")
        return binary, hashlib.sha256(binary.read_bytes()).hexdigest(), root / "checks.json"

    def test_either_or_both_failed_checks_prevent_spawn_and_label_each_result(self):
        for processes, mutate, expected in (
            ("123 /engine/wineserver\n", False, "no_wine_processes"),
            ("123 /bin/safe\n", True, "capture_pin"),
            ("123 /engine/wine\n", True, "no_wine_processes,capture_pin"),
        ):
            with self.subTest(expected=expected), TemporaryDirectory() as temporary:
                binary, digest, receipt = self.fixture(Path(temporary))
                if mutate:
                    binary.write_bytes(b"changed after binding")
                gate = admission.LaunchAdmission(binary, digest, receipt)
                with patch.object(admission.subprocess, "run", return_value=subprocess.CompletedProcess(
                    [], 0, processes, ""
                )), patch.object(admission.subprocess, "Popen") as spawn:
                    with self.assertRaisesRegex(RuntimeError, "^launch_admission_failed:" + expected + "$"):
                        gate.spawn(["title"])
                    spawn.assert_not_called()
                    with self.assertRaisesRegex(RuntimeError, "already_consumed"):
                        gate.spawn(["title"])
                    spawn.assert_not_called()
                checks = json.loads(receipt.read_text())
                self.assertFalse(checks["spawnPermitted"])
                self.assertEqual([x["check"] for x in checks["checks"]],
                                 ["no_wine_processes", "capture_pin"])

    def test_success_spawns_once_and_receipt_blocks_new_instance_replay(self):
        with TemporaryDirectory() as temporary:
            binary, digest, receipt = self.fixture(Path(temporary))
            gate = admission.LaunchAdmission(binary, digest, receipt)
            with patch.object(admission.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 0, "42 /bin/safe\n", ""
            )), patch.object(admission.subprocess, "Popen") as spawn:
                self.assertIs(gate.spawn(["title"], env={"SAFE": "1"}), spawn.return_value)
                with self.assertRaisesRegex(RuntimeError, "already_consumed"):
                    gate.spawn(["title"])
                with self.assertRaisesRegex(RuntimeError, "already_consumed"):
                    admission.LaunchAdmission(binary, digest, receipt).spawn(["title"])
                spawn.assert_called_once_with(["title"], env={"SAFE": "1"})
            self.assertTrue(json.loads(receipt.read_text())["spawnPermitted"])

    def test_observation_failure_and_missing_capture_fail_closed_without_spawn(self):
        for result in (subprocess.TimeoutExpired("ps", 5), "malformed"):
            with self.subTest(result=result), TemporaryDirectory() as temporary:
                binary, digest, receipt = self.fixture(Path(temporary))
                binary.unlink()
                with patch.object(admission.subprocess, "run") as observe, patch.object(
                    admission.subprocess, "Popen"
                ) as spawn:
                    if isinstance(result, Exception):
                        observe.side_effect = result
                    else:
                        observe.return_value = subprocess.CompletedProcess([], 0, result, "")
                    with self.assertRaisesRegex(
                        RuntimeError, "launch_admission_failed:no_wine_processes,capture_pin"
                    ):
                        admission.LaunchAdmission(binary, digest, receipt).spawn(["title"])
                    spawn.assert_not_called()

    def test_failed_spawn_is_not_replayed(self):
        with TemporaryDirectory() as temporary:
            binary, digest, receipt = self.fixture(Path(temporary))
            gate = admission.LaunchAdmission(binary, digest, receipt)
            with patch.object(admission.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 0, "", ""
            )), patch.object(admission.subprocess, "Popen", side_effect=OSError("spawn failed")) as spawn:
                with self.assertRaisesRegex(OSError, "spawn failed"):
                    gate.spawn(["title"])
                with self.assertRaisesRegex(RuntimeError, "already_consumed"):
                    gate.spawn(["title"])
                self.assertEqual(spawn.call_count, 1)


if __name__ == "__main__":
    unittest.main()
