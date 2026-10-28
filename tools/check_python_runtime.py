#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Neutral archive/inventory tests. No supplied interpreter or signing tool is executed."""
import hashlib
import io
import json
import os
from pathlib import Path
import struct
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import python_runtime as runtime


def archive(entries, group_writable=False):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:gz") as stream:
        for name, data, kind in entries:
            entry = tarfile.TarInfo(name)
            entry.mode = 0o755 if name.endswith("python3.14") else 0o644
            if group_writable:
                entry.mode |= 0o022
            if kind == "link":
                entry.type = tarfile.SYMTYPE
                entry.linkname = data
                stream.addfile(entry)
            elif kind == "hard":
                entry.type = tarfile.LNKTYPE
                entry.linkname = data
                stream.addfile(entry)
            elif kind == "fifo":
                entry.type = tarfile.FIFOTYPE
                stream.addfile(entry)
            else:
                entry.size = len(data)
                stream.addfile(entry, io.BytesIO(data))
    return output.getvalue()


class RuntimeChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ode-runtime-neutral-")
        self.root = Path(self.temporary.name).resolve()
        self.addCleanup(self.cleanup)
        self.destination = self.root / "OdePython"
        self.entries = [
            ("python/bin/python3.14", struct.pack("<II", 0xFEEDFACF, 0x0100000C) + b"Never executed.", "file"),
            ("python/bin/python3", "python3.14", "link"),
            ("python/lib/python3.14/LICENSE.txt", b"Neutral license fixture, not a license grant.", "file"),
            ("python/lib/python3.14/empty.py", b"", "file"),
        ]

    def cleanup(self):
        for path in self.root.rglob("*"):
            if path.is_dir() and not path.is_symlink():
                path.chmod(0o700)
        self.temporary.cleanup()

    def metadata(self):
        pin = runtime.approved_pin()
        return {"version": 1, "pythonVersion": pin["pythonVersion"], "archiveSHA256": pin["sha256"],
                "files": runtime.inventory(self.destination)}

    def test_materialized_aliases_zero_byte_files_and_exact_inventory(self):
        runtime.unpack(archive(self.entries), self.destination)
        self.assertFalse((self.destination / "bin/python3").is_symlink())
        self.assertEqual((self.destination / "bin/python3").stat().st_nlink, 1)
        self.assertEqual((self.destination / "bin/python3").read_bytes(),
                         (self.destination / "bin/python3.14").read_bytes())
        metadata = self.metadata()
        self.assertEqual(metadata["files"]["lib/python3.14/empty.py"]["bytes"], 0)
        self.assertEqual(runtime.verify_runtime(self.destination, metadata), metadata)

    def test_reject_unsafe_archive_paths_and_entry_types_before_materialization(self):
        for name, data, kind in [
            ("/python/escape", b"", "file"), ("python/../escape", b"", "file"),
            ("python//escape", b"", "file"), ("elsewhere/file", b"", "file"),
            ("python/fifo", "", "fifo"), ("python/hard", "python/bin/python3.14", "hard"),
            ("python/link", "/usr/bin/python3", "link"),
            ("python/link", "../../escape", "link"), ("python/link", "missing", "link"),
            ("python/link", "link", "link"), self.entries[0],
        ]:
            with self.subTest(name=name, kind=kind):
                with self.assertRaises(ValueError):
                    runtime.unpack(archive([*self.entries, (name, data, kind)]), self.destination)
                self.assertFalse(self.destination.exists())

    def test_reject_existing_destination(self):
        self.destination.mkdir()
        with self.assertRaises(ValueError):
            runtime.unpack(archive(self.entries), self.destination)

    def test_archive_permissions_are_normalized_not_restored(self):
        runtime.unpack(archive(self.entries, group_writable=True), self.destination)
        for path in self.destination.rglob("*"):
            self.assertEqual(path.stat().st_mode & 0o022, 0)
        self.assertTrue((self.destination / "bin/python3").stat().st_mode & 0o111)

    def test_reject_changed_and_added_file_and_mode(self):
        runtime.unpack(archive(self.entries), self.destination)
        metadata = self.metadata()
        target = self.destination / "lib/python3.14/empty.py"
        target.write_bytes(b"Changed")
        with self.assertRaises(ValueError):
            runtime.verify_runtime(self.destination, metadata)
        target.write_bytes(b"")
        target.chmod(0o755)
        with self.assertRaises(ValueError):
            runtime.verify_runtime(self.destination, metadata)
        target.chmod(0o644)
        extra = self.destination / "unreviewed.py"
        extra.write_bytes(b"")
        with self.assertRaises(ValueError):
            runtime.verify_runtime(self.destination, metadata)
        extra.unlink()
        target.chmod(0o666)
        with self.assertRaises(ValueError):
            runtime.verify_runtime(self.destination, metadata)

    def test_reject_unapproved_metadata(self):
        runtime.unpack(archive(self.entries), self.destination)
        metadata = self.metadata()
        for key, value in [("version", True), ("pythonVersion", "3.99"),
                           ("archiveSHA256", "0" * 64), ("extra", 1)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                runtime.verify_runtime(self.destination, {**metadata, key: value})

    def test_reject_linked_and_hardlinked_runtime_files(self):
        runtime.unpack(archive(self.entries), self.destination)
        target = self.destination / "lib/python3.14/empty.py"
        target.unlink()
        target.symlink_to(self.root / "absent")
        with self.assertRaises(ValueError):
            runtime.inventory(self.destination)
        target.unlink()
        os.link(self.destination / "bin/python3", target)
        with self.assertRaises(ValueError):
            runtime.inventory(self.destination)

    def test_stage_explicit_pinned_archive_and_sign_only_code(self):
        data = archive(self.entries)
        source = self.root / "python.tar.gz"
        source.write_bytes(data)
        pin = {**runtime.approved_pin(), "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
        receipt = self.root / "pair.json"
        receipt.write_text("{}")
        commands = []
        with patch.object(runtime, "approved_pin", return_value=pin):
            runtime.stage_runtime(source, self.destination, receipt, local_ad_hoc=True,
                                  run=lambda args: commands.append(args) or "")
            metadata = json.loads(self.destination.with_suffix(".json").read_bytes())
            self.assertEqual(runtime.verify_runtime(self.destination, metadata), metadata)
        self.assertEqual(len(commands), 4)
        self.assertTrue(all(args[0] == "/usr/bin/codesign" for args in commands))
        self.assertEqual(json.loads(receipt.read_bytes())["privatePythonRuntime"], metadata)
        self.assertTrue(all(not (path.stat().st_mode & 0o222)
                            for path in self.destination.rglob("*")))
        self.assertFalse(self.destination.stat().st_mode & 0o222)

    def test_bad_external_archive_pin_never_signs_or_unpacks(self):
        source = self.root / "wrong.tar.gz"
        source.write_bytes(archive(self.entries))
        with self.assertRaises(ValueError):
            runtime.stage_runtime(source, self.destination, self.root / "absent.json",
                                  local_ad_hoc=True, run=lambda _: self.fail("Unapproved code signed"))
        self.assertFalse(self.destination.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
