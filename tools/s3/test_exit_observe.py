import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).parent


class ExitObserverTests(unittest.TestCase):
    def test_actual_control_flow_with_mock_win32(self):
        cases = {
            "0": 0, "255": 0, "ffffffff": 0, "259": 0, "identity": 0,
            "bad-pid": 2, "signed-pid": 2, "junk-pid": 2, "zero-pid": 2,
            "bad-path": 2, "unicode-path": 2, "bad-creation": 2,
            "zero-creation": 2, "bad-timeout": 2, "zero-timeout": 2,
            "bad-argc": 2, "access-denied": 3, "wrong-pid": 4,
            "wrong-image": 4, "wrong-creation": 4, "pid-error": 4,
            "times-error": 4, "image-error": 4, "truncated-image": 4,
            "bad-image": 4, "identity-exited": 4,
            "timeout": 5, "still-active": 5, "wait-error": 6,
            "wait-unexpected": 6, "exit-error": 7, "close-error": 8,
        }
        with tempfile.TemporaryDirectory() as directory:
            binary = str(Path(directory) / "exit-test")
            subprocess.run([
                "clang", "-std=c11", "-Wall", "-Wextra", "-Werror",
                str(ROOT / "exit-test.c"), "-o", binary,
            ], check=True, capture_output=True, text=True)
            for scenario, expected in cases.items():
                with self.subTest(scenario=scenario):
                    run = subprocess.run([binary, scenario, str(expected)],
                                         capture_output=True, text=True)
                    self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                    records = [json.loads(line) for line in run.stdout.splitlines()]
                    self.assertEqual(records[-1]["observer_exit"], expected)
                    exits = [r for r in records if r["event"] == "process_exit"]
                    if scenario in ("0", "255", "ffffffff", "259", "close-error"):
                        code = {"0": 0, "255": 255, "ffffffff": 0xFFFFFFFF,
                                "259": 259, "close-error": 0}[scenario]
                        self.assertEqual(len(exits), 1)
                        self.assertEqual(exits[0]["exit_dword"], code)
                        self.assertEqual(exits[0]["exit_hex"], f"0x{code:08x}")
                        self.assertIs(exits[0]["wait_signaled"], True)
                    else:
                        self.assertEqual(exits, [])
                    if scenario == "identity":
                        self.assertEqual(records[0]["image"], r"Z:\stage\DREDGE.exe")
                        self.assertEqual(records[0]["creation_hex"], "1234567800000001")
                        self.assertEqual(records[0]["windows_pid"], 224)
                        self.assertEqual(records[-1]["event"], "identity_ready")
                    if scenario in ("timeout", "still-active"):
                        self.assertEqual(records[-1]["event"], "timeout")
                        self.assertNotIn("exit_dword", records[-1])
                    if scenario == "access-denied":
                        self.assertEqual(records[-1]["stage"], "OpenProcess")
                        self.assertEqual(records[-1]["win32_error"], 5)


if __name__ == "__main__":
    unittest.main()
