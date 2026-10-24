"""Account-free capture completion, publication and owned-process timeout fixtures."""

import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest
import zlib

SPEC = importlib.util.spec_from_file_location("capture_window", Path(__file__).with_name("capture-window.py"))
capture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(capture)


def png():
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"\0\x12\x34\x56\xff")) + chunk(b"IEND", b""))


class CaptureTests(unittest.TestCase):
    def test_identity_guard_stays_fail_closed_and_diagnostics_are_failure_only(self):
        source = Path(__file__).with_name("capture-window.swift").read_text()
        guard = source.index("guard matches.count == 1, let window = matches.first else {")
        diagnostic = source.index("let sckWindows =", guard)
        refusal = source.index("throw CaptureError.identityMismatch", diagnostic)
        screenshot = source.index("SCScreenshotManager.captureImage")
        self.assertLess(guard, diagnostic)
        self.assertLess(diagnostic, refusal)
        self.assertLess(refusal, screenshot)
        self.assertIn("false, onScreenWindowsOnly: true", source)
        self.assertIn("$0.windowID == windowID && $0.owningApplication?.processID == pid", source)
        self.assertIn("&& $0.title == args[3] && $0.isOnScreen", source)
        self.assertEqual(source.count("SCShareableContent.excludingDesktopWindows("), 1)
        self.assertNotIn(".windowLayer == 0", source)

    def test_swift_diagnostic_shapes_nulls_and_excludes_unrelated_windows(self):
        source = Path(__file__).with_name("capture-window.swift")
        with TemporaryDirectory() as temporary:
            base = Path(temporary)
            fixture = base / "fixture.swift"
            fixture.write_text("""
import Foundation
@main struct Fixture {
    static func main() throws {
        let windows = [
            CaptureIdentityDiagnostic.Window(window: 456, pid: nil, title: nil, onScreen: nil, layer: nil),
            CaptureIdentityDiagnostic.Window(window: 789, pid: 123, title: "Changed", onScreen: false, layer: 27),
            CaptureIdentityDiagnostic.Window(window: 999, pid: 888, title: "UNRELATED-PRIVATE", onScreen: true, layer: 0)
        ]
        let values = [
            CaptureIdentityDiagnostic(expectedPID: 123, expectedWindow: 456,
                expectedTitle: "Expected", matchCount: 0, frontmostPID: nil,
                sckWindows: windows, cgWindows: windows),
            CaptureIdentityDiagnostic(expectedPID: 123, expectedWindow: 456,
                expectedTitle: "Expected", matchCount: 2, frontmostPID: 123,
                sckWindows: [], cgWindows: nil)
        ]
        FileHandle.standardOutput.write(try JSONEncoder().encode(values))
    }
}
""")
            binary = base / "fixture"
            compiled = subprocess.run(
                ["xcrun", "swiftc", "-parse-as-library", "-D", "CAPTURE_DIAGNOSTIC_TEST",
                 str(source), str(fixture), "-o", str(binary)],
                capture_output=True, text=True, timeout=120,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(binary)], check=True, capture_output=True,
                                    text=True, timeout=10)
            diagnostic, absent = json.loads(result.stdout)
            self.assertNotIn("UNRELATED-PRIVATE", result.stdout)
            self.assertEqual(diagnostic["error"], "identityMismatch")
            self.assertEqual(diagnostic["matchCount"], 0)
            self.assertIsNone(diagnostic["frontmostPID"])
            self.assertEqual(diagnostic["expectedPID"], 123)
            self.assertEqual(diagnostic["expectedWindow"], 456)
            self.assertEqual(diagnostic["expectedTitle"], "Expected")
            for key in ("sckCandidates", "cgCandidates"):
                self.assertEqual(len(diagnostic[key]), 2)
                self.assertEqual(diagnostic[key][0], {
                    "window": 456, "pid": None, "title": None, "onScreen": None, "layer": None,
                })
                self.assertEqual(diagnostic[key][1], {
                    "window": 789, "pid": 123, "title": "Changed", "onScreen": False, "layer": 27,
                })
            self.assertEqual(absent["sckCandidates"], [])
            self.assertIsNone(absent["cgCandidates"])
            self.assertEqual(absent["frontmostPID"], 123)
            self.assertEqual(absent["matchCount"], 2)

    def fixture(self, base, mode="success"):
        binary = base / "fixture"
        binary.write_text(
            "#!" + sys.executable + "\nimport json,pathlib,sys,time\n"
            f"data={png()!r}\nmode={mode!r}\n"
            "pathlib.Path(sys.argv[4]).write_bytes(data if mode!='bad-png' else data[:-2])\n"
            "print('raw capture diagnostic',file=sys.stderr,flush=True)\n"
            "if mode=='hang': time.sleep(60)\n"
            "if mode=='failure': sys.exit(7)\n"
            "print(json.dumps({'pid':int(sys.argv[1]),'window':int(sys.argv[2]),"
            "'width':2 if mode=='mismatch' else 1,'height':1,'completed':True}),flush=True)\n"
        )
        binary.chmod(0o700)
        return binary, hashlib.sha256(binary.read_bytes()).hexdigest(), base / "image.png"

    def test_completed_capture_is_validated_and_published_once(self):
        with TemporaryDirectory() as temporary:
            binary, digest, output = self.fixture(Path(temporary))
            result = capture.capture(binary, digest, 123, 456, "Owned", output, 2)
            self.assertTrue(result["completed"])
            self.assertEqual(result["returncode"], 0)
            self.assertFalse(result["timedOut"])
            self.assertEqual(capture.validate_png(output), (1, 1))
            self.assertFalse(Path(result["artifacts"]).exists())
            with self.assertRaisesRegex(ValueError, "existing output"):
                capture.capture(binary, digest, 123, 456, "Owned", output, 2)
            self.assertEqual(output.read_bytes(), png())

    def test_timeout_reaps_only_owned_capture_and_never_publishes_partial_image(self):
        with TemporaryDirectory() as temporary:
            binary, digest, output = self.fixture(Path(temporary), "hang")
            with self.assertRaisesRegex(TimeoutError, "killed/reaped"):
                capture.capture(binary, digest, 123, 456, "Owned", output, 2)
            receipt = json.loads(output.with_suffix(".png.capture.json").read_text())
            self.assertTrue(receipt["timedOut"])
            self.assertLess(receipt["returncode"], 0)
            self.assertIn("raw capture diagnostic", receipt["stderr"])
            self.assertFalse(output.exists())
            self.assertTrue((Path(receipt["artifacts"]) / "image.png").exists())
            self.assertFalse(receipt["completed"])

    def test_failure_invalid_image_and_completion_mismatch_preserve_raw_error(self):
        for mode in ("failure", "bad-png", "mismatch"):
            with self.subTest(mode=mode), TemporaryDirectory() as temporary:
                binary, digest, output = self.fixture(Path(temporary), mode)
                with self.assertRaises((ValueError, RuntimeError)):
                    capture.capture(binary, digest, 123, 456, "Owned", output, 2)
                receipt = json.loads(output.with_suffix(".png.capture.json").read_text())
                self.assertFalse(receipt["completed"])
                self.assertIn("raw capture diagnostic", receipt["stderr"])
                self.assertIn("error", receipt)
                self.assertFalse(output.exists())

    def test_wrong_binary_or_owned_identity_refused_before_child_creation(self):
        with TemporaryDirectory() as temporary:
            binary, digest, output = self.fixture(Path(temporary))
            for expected, pid, window, title in (
                ("wrong", 123, 456, "Owned"), (digest, 0, 456, "Owned"),
                (digest, 123, 0, "Owned"), (digest, 123, 456, ""),
            ):
                with self.assertRaises(ValueError):
                    capture.capture(binary, expected, pid, window, title, output, 2)
            self.assertEqual(list(Path(temporary).iterdir()), [binary])

    def test_png_rejects_truncation_checksum_trailing_data_and_missing_pixels(self):
        valid = png()
        for data in (valid[:-1], valid + b"trailing", valid[:40] + b"x" + valid[41:],
                     valid[:33] + valid[-12:]):
            with self.subTest(data=data), TemporaryDirectory() as temporary:
                path = Path(temporary) / "invalid.png"
                path.write_bytes(data)
                with self.assertRaises(ValueError):
                    capture.validate_png(path)


if __name__ == "__main__":
    unittest.main()
