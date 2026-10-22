import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).parent
SPEC = importlib.util.spec_from_file_location("key_observe", ROOT / "key-observe-v1.py")
OBSERVER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(OBSERVER)


class KeyTests(unittest.TestCase):
    def test_native_win32_mock_guards(self):
        cases = {
            "ok": (0, 2), "extended": (0, 2),
            "bad-pid": (2, 0), "bad-key": (2, 0), "mouse": (2, 0),
            "bad-hold": (2, 0), "bad-title": (2, 0), "no-scan": (2, 0),
            "duplicate": (3, 0), "hidden": (3, 0), "enum-error": (3, 0),
            "wrong-pid": (3, 0), "wrong-class": (3, 0), "wrong-title": (3, 0),
            "foreground-denied": (4, 0), "changed-title": (4, 0),
            "late-duplicate": (4, 0), "down-failed": (5, 1),
            "lost-before-up": (6, 1), "up-failed": (7, 2), "lost-after-up": (8, 2),
        }
        with tempfile.TemporaryDirectory() as directory:
            binary = str(Path(directory) / "key-test")
            subprocess.run([
                "clang", "-std=c11", "-Wall", "-Wextra", "-Werror",
                str(ROOT / "key-test.c"), "-o", binary,
            ], check=True, capture_output=True, text=True)
            for scenario, (code, sends) in cases.items():
                with self.subTest(scenario=scenario):
                    result = subprocess.run(
                        [binary, scenario, str(code), str(sends)],
                        capture_output=True, text=True,
                    )
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    if sends:
                        self.assertIn("event=pre-down", result.stdout)
                        self.assertIn("event=post-down", result.stdout)
                    if code == 0:
                        self.assertIn("event=pre-up", result.stdout)
                        self.assertIn("event=post-up", result.stdout)
                        self.assertIn("tick=250", result.stdout)

    def test_observer_binding_and_no_legacy_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            helper, wine = root / "key-v1.exe", root / "wine"
            helper.write_bytes(b"mock helper")
            wine.write_bytes(b"mock wine")
            binding = {
                "schema": "s3-key-v1",
                "helper": {"path": str(helper), "sha256": OBSERVER.sha256(helper)},
                "wine": {"path": str(wine), "sha256": OBSERVER.sha256(wine)},
                "observer": {"path": str(ROOT / "key-observe-v1.py"),
                             "sha256": OBSERVER.sha256(ROOT / "key-observe-v1.py")},
                "windowsPid": 220, "title": "Dishonored",
                "class": "LaunchUnrealUWindowsClient", "prefix": str(root),
                "environment": {"WINEDEBUG": "-all"},
            }
            path = root / "binding.json"
            path.write_text(json.dumps(binding))
            _, argv, env = OBSERVER.prepare(path, 123, 87, 100)
            self.assertEqual(argv, [
                str(wine), str(helper), "220", "Dishonored",
                "LaunchUnrealUWindowsClient", "87", "100",
            ])
            self.assertEqual(env["WINEPREFIX"], str(root))
            for field, value in (("windowsPid", 0), ("title", "bad\n"), ("schema", "legacy")):
                with self.subTest(field=field):
                    changed = dict(binding, **{field: value})
                    path.write_text(json.dumps(changed))
                    with self.assertRaises(ValueError):
                        OBSERVER.prepare(path, 123, 87, 100)
            path.write_text(json.dumps(binding))
            for values in ((0, 87, 100), (123, 1, 100), (123, 87, 1001)):
                with self.assertRaises(ValueError):
                    OBSERVER.prepare(path, *values)
            helper.write_bytes(b"tampered")
            with self.assertRaisesRegex(ValueError, "hash mismatch"):
                OBSERVER.prepare(path, 123, 87, 100)
            helper.unlink()
            helper.symlink_to(wine)
            with self.assertRaisesRegex(ValueError, "non-symlink"):
                OBSERVER.prepare(path, 123, 87, 100)


if __name__ == "__main__":
    unittest.main()
