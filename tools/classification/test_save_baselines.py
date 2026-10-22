import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from snapshot_save_baselines import OUTPUT, hash_file, inventory, redact
from inspect_queue import load_json


class SaveBaselineTests(unittest.TestCase):
    def test_absent_empty_full_hash_and_no_nested_link_following(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            self.assertEqual(inventory(base / "missing", [base])["status"], "absent")
            self.assertEqual(inventory(base, [base])["status"], "empty")
            (base / "payload").write_bytes(b"payload-for-hash")
            (base / "zero").touch()
            (base / "link").symlink_to(base / "payload")
            result = inventory(base, [base])
            self.assertEqual(result["status"], "present")
            self.assertEqual(len(result["files"]), 2)
            self.assertEqual(len(result["symlinks"]), 1)
            self.assertFalse(result["symlinks"][0]["followed"])
            row = next(row for row in result["files"] if row["path"].endswith("payload"))
            self.assertEqual(row["sha256"], hashlib.sha256(b"payload-for-hash").hexdigest())
            self.assertEqual(row["sizeBytes"], 16)
            self.assertGreater(row["mtimeNs"], 0)

    def test_out_of_scope_link_is_not_read(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = base / "scoped"
            root.mkdir()
            (root / "escape").symlink_to(base)
            self.assertEqual(inventory(root / "escape", [root])["status"],
                             "out-of-scope-target")

    def test_concurrent_change_discards_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "file"
            path.write_bytes(b"first")
            real = hashlib.file_digest

            def changing(stream, algorithm):
                result = real(stream, algorithm)
                path.write_bytes(b"changed-longer")
                return result

            with patch("snapshot_save_baselines.hashlib.file_digest", side_effect=changing):
                row = hash_file(path)
            self.assertEqual(row["status"], "changed-during-hash")
            self.assertIsNone(row["sha256"])

    def test_published_receipt_is_bound_redacted_and_covers_twelve(self):
        public = load_json(OUTPUT)
        local = load_json(Path(public["localReceipt"]["path"]))
        self.assertEqual(redact(local), {key: value for key, value in public.items()
                                         if key != "localReceipt"})
        self.assertEqual(hashlib.sha256(Path(public["localReceipt"]["path"]).read_bytes()).hexdigest(),
                         public["localReceipt"]["sha256"])
        self.assertEqual(len(public["items"]), 12)
        self.assertEqual(len({item["storeId"] for item in public["items"]}), 12)
        self.assertFalse(public["retentionPass"])
        self.assertFalse(public["saveContentsParsed"])
        self.assertEqual(public["gameLaunches"], 0)
        for item in public["items"]:
            for root in item["roots"]:
                for file in root["files"]:
                    self.assertIsInstance(file["mtimeNs"], int)
                    self.assertGreaterEqual(file["sizeBytes"], 0)
                    if file["status"] == "stable-during-read":
                        self.assertEqual(len(file["sha256"]), 64)
                    else:
                        self.assertIsNone(file["sha256"])


if __name__ == "__main__":
    unittest.main()
