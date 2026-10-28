#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import migrate_game_root as migration
from legacy_compatibility import LEGACY_GAME_FOLDER_EXPORT, LEGACY_GAME_LIBRARY_FOLDER


class MigrationChecks(unittest.TestCase):
    def fixture(self, root):
        old, new = root / LEGACY_GAME_LIBRARY_FOLDER, root / "Xode"
        old.mkdir()
        game = old / "Witcher"
        game.mkdir()
        partial = game / ".ode-streaming-tmp.msixvc"
        partial.write_bytes(b"neutral partial, not game data")
        (old / ".Witcher.ode-lifecycle.lock").touch()
        registry = root / "installed-games.json"
        registry.write_text(json.dumps([{"id": "stable", "folder": str(game),
                                        "engine": str(old) + "-not-a-descendant",
                                        "storageVolume": {"path": "/"}}]))
        journal = root / "game-operation.json.resumable.json"
        journal.write_text(json.dumps({"neutral": {"destination": str(game), "id": "stable",
                                                 "nativeAccountHash": "neutral-fixture"}}))
        launcher = root / "launcher.sh"
        launcher.write_text("#!/bin/sh\n" + LEGACY_GAME_FOLDER_EXPORT + str(game) + "\nexec /bin/true\n")
        launcher.chmod(0o750)
        files = [(registry, "registry"), (journal, "resumable"), (launcher, "launcher")]
        return old, new, partial, files, root / "evidence"

    def test_success_preserves_partial_children_and_unrelated_fields(self):
        with tempfile.TemporaryDirectory() as temporary:
            old, new, partial, files, stage = self.fixture(Path(temporary).resolve())
            original = partial.stat()
            migration.prepare(old, new, files, partial, stage)
            result = migration.apply(stage, lambda: True)
            self.assertEqual(result["state"], "migrated_quiescent")
            self.assertFalse(old.exists())
            self.assertEqual((new / "Witcher" / partial.name).stat().st_ino, original.st_ino)
            registry = json.loads(files[0][0].read_text())
            self.assertEqual(registry[0]["folder"], str(new / "Witcher"))
            self.assertEqual(registry[0]["engine"], str(old) + "-not-a-descendant")
            self.assertEqual(registry[0]["storageVolume"], {"path": "/"})
            self.assertEqual(files[2][0].stat().st_mode & 0o777, 0o750)

    def test_collision_and_busy_prevent_any_move(self):
        for collision in (True, False):
            with self.subTest(collision=collision), tempfile.TemporaryDirectory() as temporary:
                old, new, partial, files, stage = self.fixture(Path(temporary).resolve())
                migration.prepare(old, new, files, partial, stage)
                if collision:
                    new.mkdir()
                with self.assertRaises(ValueError):
                    migration.apply(stage, lambda: collision)
                self.assertTrue(old.exists())

    def test_exclusive_rename_does_not_replace_empty_destination(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            old, new = root / "old", root / "new"
            old.mkdir()
            new.mkdir()
            with self.assertRaises(OSError):
                migration.exclusive_rename(old, new)
            self.assertTrue(old.exists() and new.exists())

    def test_failure_restores_exact_bytes_modes_and_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            old, new, partial, files, stage = self.fixture(Path(temporary).resolve())
            originals = {path: path.read_bytes() for path, _ in files}
            migration.prepare(old, new, files, partial, stage)
            real_write = migration.atomic_write
            calls = 0

            def fail_once(*args):
                nonlocal calls
                calls += 1
                if calls == 2:
                    raise OSError("neutral injected failure")
                return real_write(*args)

            with patch.object(migration, "atomic_write", side_effect=fail_once), self.assertRaises(OSError):
                migration.apply(stage, lambda: True)
            self.assertTrue(old.exists())
            self.assertFalse(new.exists())
            for path, content in originals.items():
                self.assertEqual(path.read_bytes(), content)
            self.assertEqual(json.loads((stage / "migration.json").read_text())["state"],
                             "rolled_back_quiescent")

    def test_changed_reference_or_partial_aborts_without_overwriting(self):
        for target in ("partial", "reference"):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as temporary:
                old, new, partial, files, stage = self.fixture(Path(temporary).resolve())
                migration.prepare(old, new, files, partial, stage)
                (partial if target == "partial" else files[0][0]).write_bytes(b"external change")
                with self.assertRaises(ValueError):
                    migration.apply(stage, lambda: True)
                self.assertTrue(old.exists())
                self.assertFalse(new.exists())

    def test_exact_path_boundary_and_key_preservation(self):
        value = {"/old/key": ["/old", "/old/game", "/old-other", "prefix /old/game"]}
        self.assertEqual(migration.remap(value, "/old", "/new"),
                         {"/old/key": ["/new", "/new/game", "/old-other", "prefix /old/game"]})

    def test_concurrent_reference_update_at_exchange_is_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            old, new, partial, files, stage = self.fixture(Path(temporary).resolve())
            migration.prepare(old, new, files, partial, stage)
            exchange = migration.exchange
            injected = False
            external = b'[{"external": "must survive"}]'

            def interfere(source, destination):
                nonlocal injected
                if not injected:
                    injected = True
                    destination.write_bytes(external)
                exchange(source, destination)

            with patch.object(migration, "exchange", side_effect=interfere), self.assertRaises(ValueError):
                migration.apply(stage, lambda: True)
            self.assertEqual(files[0][0].read_bytes(), external)
            self.assertNotEqual(json.loads((stage / "migration.json").read_text())["state"],
                                "migrated_quiescent")

    def test_final_callback_cannot_substitute_source_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            old, new, partial, files, stage = self.fixture(root)
            migration.prepare(old, new, files, partial, stage)
            calls = 0

            def quiescent():
                nonlocal calls
                calls += 1
                if calls == 2:
                    old.rename(root / "displaced")
                    old.symlink_to(root / "displaced", target_is_directory=True)
                return True

            with self.assertRaises(ValueError):
                migration.apply(stage, quiescent)
            self.assertTrue(old.is_symlink())
            self.assertFalse(new.exists())
            self.assertEqual(json.loads((stage / "migration.json").read_text())["state"],
                             "rollback_requires_reconciliation")

    def test_rollback_does_not_move_substituted_destination(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            old, new, partial, files, stage = self.fixture(root)
            migration.prepare(old, new, files, partial, stage)

            def substitute(*args):
                new.rename(root / "owned-displaced")
                new.mkdir()
                (new / "external").write_bytes(b"must remain")
                raise OSError("injected root replacement")

            with patch.object(migration, "atomic_write", side_effect=substitute), self.assertRaises(OSError):
                migration.apply(stage, lambda: True)
            self.assertFalse(old.exists())
            self.assertEqual((new / "external").read_bytes(), b"must remain")
            self.assertTrue((root / "owned-displaced").exists())
            self.assertEqual(json.loads((stage / "migration.json").read_text())["state"],
                             "rollback_requires_reconciliation")

    def test_rollback_reference_interference_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            old, new, partial, files, stage = self.fixture(Path(temporary).resolve())
            migration.prepare(old, new, files, partial, stage)
            original_write, original_exchange = migration.atomic_write, migration.exchange
            writes = 0
            external = b"external rollback writer"

            def fail_second(*args):
                nonlocal writes
                writes += 1
                if writes == 2:
                    raise OSError("injected second-file failure")
                return original_write(*args)

            swaps = 0

            def interfere(source, destination):
                nonlocal swaps
                swaps += 1
                if swaps == 2:
                    destination.write_bytes(external)
                original_exchange(source, destination)

            with patch.object(migration, "atomic_write", side_effect=fail_second), \
                    patch.object(migration, "exchange", side_effect=interfere), self.assertRaises(OSError):
                migration.apply(stage, lambda: True)
            self.assertEqual(files[0][0].read_bytes(), external)
            self.assertEqual(json.loads((stage / "migration.json").read_text())["state"],
                             "rollback_requires_reconciliation")


if __name__ == "__main__":
    unittest.main()
