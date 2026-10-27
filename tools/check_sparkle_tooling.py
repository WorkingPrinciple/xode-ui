#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""REQ-143: key lookup only and release plan without side effects or Keychain access."""
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SparkleToolingChecks(unittest.TestCase):
    def fake_tools(self, directory):
        tools = directory / "Sparkle tools"
        tools.mkdir()
        for name in ("generate_keys", "sign_update", "generate_appcast"):
            path = tools / name
            path.write_text("#!/bin/bash\nprintf '%s\\n' \"$@\"\n", encoding="utf-8")
            path.chmod(0o755)
        return tools

    def test_key_script_only_looks_up_existing_public_key(self):
        with tempfile.TemporaryDirectory() as tmp:
            tools = self.fake_tools(Path(tmp))
            result = subprocess.run(
                ["bash", str(ROOT / "scripts/sparkle-setup-key.sh"), str(tools)],
                check=True, capture_output=True, text=True)
            self.assertEqual(result.stdout.strip(), "-p")

    def test_missing_key_fails_without_generating(self):
        with tempfile.TemporaryDirectory() as tmp:
            tools = self.fake_tools(Path(tmp))
            (tools / "generate_keys").write_text(
                "#!/bin/bash\n[[ \"$*\" == '-p' ]] || exit 99\nexit 3\n", encoding="utf-8")
            result = subprocess.run(
                ["bash", str(ROOT / "scripts/sparkle-setup-key.sh"), str(tools)],
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 3)

    def test_release_plan_never_invokes_tools_or_creates_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            tools = self.fake_tools(directory)
            marker = directory / "unexpected-tool-invocation"
            for name in ("sign_update", "generate_appcast"):
                (tools / name).write_text(
                    f"#!/bin/bash\ntouch '{marker}'\nexit 99\n", encoding="utf-8")
            app, output = directory / "Test app.app", directory / "release output"
            app.mkdir()
            result = subprocess.run(
                ["bash", str(ROOT / "scripts/sparkle-prepare-release.sh"),
                 str(app), str(tools), str(output), "v0.2.0-beta.1"],
                check=True, capture_output=True, text=True)
            self.assertFalse(output.exists())
            self.assertFalse(marker.exists())
            self.assertIn("DRY RUN ONLY", result.stdout)
            self.assertIn("sign_update", result.stdout)
            self.assertIn("generate_appcast", result.stdout)
            self.assertIn("--maximum-deltas 0", result.stdout)
            self.assertNotIn("--ed-key-file", result.stdout)

    def test_shipped_plist_has_public_key_but_no_feed_and_no_scheduler(self):
        with (ROOT / "tools/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        self.assertNotIn("SUFeedURL", info)
        self.assertTrue(info["SUPublicEDKey"])
        for key in ("SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUEnableSystemProfiling"):
            self.assertIs(info[key], False)


if __name__ == "__main__":
    unittest.main()
