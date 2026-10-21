"""Deterministic checks for static inspection; generated images are parser fixtures only."""

import copy
import json
import struct
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import classify_catalogue
import inspect_queue


def image(normal=b"d3d11.dll", delayed=b"vulkan-1.dll"):
    data = bytearray(1024)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 60, 64)
    data[64:68] = b"PE\0\0"
    struct.pack_into("<H", data, 70, 1)
    struct.pack_into("<H", data, 84, 240)
    optional = 88
    struct.pack_into("<H", data, optional, 0x20B)
    struct.pack_into("<I", data, optional + 60, 512)
    struct.pack_into("<I", data, optional + 108, 16)
    directories = optional + 112
    struct.pack_into("<II", data, directories + 8, 0x1000, 40)
    struct.pack_into("<II", data, directories + 13 * 8, 0x1028, 64)
    struct.pack_into("<IIII", data, optional + 240 + 8, 512, 0x1000, 512, 512)
    struct.pack_into("<IIIII", data, 512, 0, 0, 0, 0x1080, 0)
    struct.pack_into("<IIIIIIII", data, 552, 1, 0x10A0, 0, 0, 0, 0, 0, 0)
    data[640:640 + len(normal) + 1] = normal + b"\0"
    data[672:672 + len(delayed) + 1] = delayed + b"\0"
    return data


class ImportTests(unittest.TestCase):
    def parse(self, data, filename="Game.exe"):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / filename
            path.write_bytes(data)
            return inspect_queue.pe_imports(path)

    def test_normal_and_delayed_imports(self):
        result = self.parse(image())
        self.assertEqual(result["status"], "parsed")
        self.assertEqual(result["graphicsAPIs"], ["DX11", "Vulkan"])
        self.assertEqual(result["imports"], ["d3d11.dll", "vulkan-1.dll"])

    def test_dxgi_does_not_identify_renderer(self):
        result = self.parse(image(b"dxgi.dll", b"user32.dll"))
        self.assertTrue(result["dxgi"])
        self.assertEqual(result["graphicsAPIs"], [])

    def test_opaque_is_not_claimed_to_be_encrypted(self):
        result = self.parse(b"\xa5" * 128)
        self.assertEqual(result["status"], "opaque-or-not-PE")
        self.assertEqual(result["imports"], [])

    def test_invalid_rva_is_explicit_failure(self):
        data = image()
        struct.pack_into("<I", data, 524, 0x90000000)
        result = self.parse(data)
        self.assertEqual(result["status"], "invalid-or-protected-PE")
        self.assertIn("RVA", result["error"])

    def test_managed_backend_marker_is_not_a_native_import(self):
        data = image(b"user32.dll", b"kernel32.dll")
        data[800:816] = b"MonoGame.OpenGL\0\0"
        result = self.parse(data, "MonoGame.Framework.dll")
        self.assertIn("MonoGame.OpenGL", result["backendMarkers"])
        self.assertEqual(result["graphicsAPIs"], [])


class QueueTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.catalogue = inspect_queue.load_json(inspect_queue.DATA / "game-compatibility-v1.json")
        cls.queue = inspect_queue.load_json(inspect_queue.QUEUE)

    def validate(self, queue):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "queue.json"
            path.write_text(json.dumps(queue))
            with patch.object(classify_catalogue, "NEXT_30_QUEUE", path):
                classify_catalogue.validate_next30_queue(self.catalogue)

    def test_actual_queue(self):
        self.validate(self.queue)
        for item in self.queue["items"]:
            self.assertIsInstance(item["sizeBytes"] / 1024**3, float)
            self.assertIsInstance(item["downloadSizeBytes"] / 1024**3, float)

    def test_null_or_negative_size_is_rejected(self):
        for size in (None, -1, True):
            with self.subTest(size=size):
                queue = copy.deepcopy(self.queue)
                queue["items"][0]["sizeBytes"] = size
                with self.assertRaises(RuntimeError):
                    self.validate(queue)

    def test_metadata_alone_cannot_become_a_signin_verdict(self):
        queue = copy.deepcopy(self.queue)
        item = next(
            item for item in queue["items"]
            if item["signInEvidence"].get("basis") == "manifest-insufficient"
        )
        item["signInNeeded"] = False
        with self.assertRaises(RuntimeError):
            self.validate(queue)

    def test_fable_is_not_install_ready(self):
        item = next(item for item in self.queue["items"] if item["storeId"] == "9PMN4DGRT1LN")
        self.assertTrue(item["releaseStatus"]["coming_soon"])
        self.assertEqual(item["testEligibility"], "defer-unreleased")
        self.assertEqual(item["rank"], 30)

    def test_unknown_size_is_not_zero_download_claim(self):
        self.assertEqual(inspect_queue.positive_sizes({"packages": [{
            "PackageFormat": "MSIXVC", "MaxDownloadSizeInBytes": 0,
        }]}), [])

    def test_console_flag_never_clears_windows_signin(self):
        for item in self.queue["items"]:
            evidence = item["signInEvidence"]
            if evidence.get("manifestFields", {}) and evidence["manifestFields"].get(
                "RequiresXboxLive"
            ) == ["false"]:
                self.assertIsNone(item["signInNeeded"])


if __name__ == "__main__":
    unittest.main()
