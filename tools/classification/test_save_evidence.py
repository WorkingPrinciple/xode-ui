import copy
import json
from pathlib import Path
import tempfile
import unittest

from reconcile_save_evidence import canonical, check_file, reconcile, sha, updated_owner_bytes


class SaveEvidenceTests(unittest.TestCase):
    def fixture(self, directory):
        home = Path(directory)
        proofs = home / "Library/Application Support/XodusCLI/proofs"
        root = proofs / "game"
        root.mkdir(parents=True)
        payload = root / "private-account" / "private-save-filename.xgs"
        payload.parent.mkdir()
        payload.write_bytes(b"raw-private-save-content")
        snapshot = root / "after.json"
        snapshot.write_text('{"sha256": "' + sha(payload.read_bytes()) + '"}')
        result = root / "runs" / "run" / "result.json"
        result.parent.mkdir(parents=True)
        result.write_text('{"secret": "never-export-me"}')
        note = root / "notes.json"
        note.write_text('{"diagnosis": "private note raw text"}')
        artifact = lambda p: {"sha256": sha(p.read_bytes()), "bytes": p.stat().st_size}
        audit = {
            "artifacts": {str(p): artifact(p) for p in (result, note)},
            "titles": {"PRODUCT": {
                "title": "Example", "attempts": [{
                    "runId": "run", "observedProcessResult": {"exit_code": 5}, "gaps": ["identity missing"],
                    "artifacts": {"runArtifacts": [str(result)], "sharedProofContext": [str(note)]},
                    "categories": {"receipt": [str(result)], "screenshot": [str(note)]},
                    "hypothesisAndNextTestRefs": [{"path": str(note), "field": "diagnosis"}],
                }, {"runId": "unresolved", "observedProcessResult": None, "gaps": ["no result"]}],
            }},
        }
        tracker = {"collectionInputs": {"attemptEvidence": audit}, "verdict": "INCONCLUSIVE"}
        digest = sha(payload.read_bytes())
        gap = {
            "parseErrors": [], "inventorySha256": "inventory-pin",
            "uniqueSaveHashesWithArchivedMatch": 1, "uniqueSaveHashesWithoutArchivedMatch": 1,
            "snapshots": [{"snapshot": "game/after.json", "saveReferences": {
                "live-private-account/save": {
                    "sha256": digest, "bytes": payload.stat().st_size,
                    "archivedHashMatches": [payload.relative_to(home).as_posix()],
                },
                "live-private-account/unknown-size": {
                    "sha256": "f" * 64, "bytes": None, "archivedHashMatches": [],
                },
            }}],
        }
        inventory = {"files": {p.relative_to(home).as_posix(): artifact(p) for p in (payload, snapshot)}}
        archive = {"sourceInventorySha256": "inventory-pin", "references": []}
        sources = {"inventory": {"sha256": "inventory-pin"}}
        return home, tracker, gap, inventory, archive, sources, payload

    def run_fixture(self, fixture):
        home, tracker, gap, inventory, archive, sources, _ = fixture
        return reconcile(tracker, gap, inventory, archive, sources, home, check_file)

    def test_deterministic_dedup_privacy_and_no_verdict_promotion(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(directory)
            before = copy.deepcopy(fixture[1:6])
            first = self.run_fixture(fixture)
            self.assertEqual(canonical(first), canonical(self.run_fixture(fixture)))
            self.assertEqual(before, fixture[1:6])
            self.assertEqual(first["coverage"]["saveHashesVerifiedAsRawBytes"], 1)
            self.assertEqual(first["coverage"]["saveHashesWithoutVerifiedRawBytes"], 1)
            self.assertEqual(first["coverage"]["attemptReferences"], 2)
            self.assertEqual(first["coverage"]["launchResultAttempts"], 1)
            attempt = first["titles"]["PRODUCT"]["attempts"][0]
            self.assertEqual(attempt["evidenceByRole"]["screenshot"], [])
            self.assertIn("identity missing", attempt["missingEvidence"])
            text = json.dumps(first)
            for private in ("raw-private-save-content", "never-export-me", "private note raw text",
                            "live-private-account", "private-save-filename", "private-account"):
                self.assertNotIn(private, text)

    def test_unknown_historical_size_is_preserved_not_zero(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_fixture(self.fixture(directory))
            self.assertIsNone(result["saveHashes"]["f" * 64]["bytes"])
            self.assertEqual(result["saveHashes"]["f" * 64]["availability"],
                             "HASH_ONLY_NO_VERIFIED_ARCHIVED_BYTES")

    def test_hash_only_records_are_not_recoverable_after_archive_removal(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(directory)
            fixture[-1].unlink()
            result = self.run_fixture(fixture)
            self.assertEqual(result["coverage"]["saveHashesVerifiedAsRawBytes"], 0)
            self.assertEqual(result["coverage"]["historicalMatchedSaveHashes"], 1)
            self.assertTrue(all(x["recoverability"] == "not-established-do-not-reconstruct"
                                for x in result["saveHashes"].values()))

    def test_corrupt_archive_does_not_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(directory)
            fixture[-1].write_bytes(b"x" * fixture[-1].stat().st_size)
            result = self.run_fixture(fixture)
            self.assertEqual(result["coverage"]["saveHashesVerifiedAsRawBytes"], 0)
            self.assertIn("HASH_MISMATCH", result["fileVerificationStatuses"])

    def test_symlink_and_traversal_are_not_followed(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(directory)
            home, *_, payload = fixture
            target = home / "outside"
            target.write_bytes(b"secret")
            payload.unlink()
            payload.symlink_to(target)
            result = self.run_fixture(fixture)
            self.assertEqual(result["coverage"]["saveHashesVerifiedAsRawBytes"], 0)
            self.assertIn("SYMLINK_NOT_FOLLOWED", result["fileVerificationStatuses"])
            self.assertEqual(check_file(payload.parent / ".." / "outside", payload.parent)["status"],
                             "OUTSIDE_PROOF_SCOPE")

    def test_wrong_source_pin_or_denominator_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(directory)
            fixture[2]["inventorySha256"] = "wrong"
            with self.assertRaisesRegex(ValueError, "pin"):
                self.run_fixture(fixture)
            fixture[2]["inventorySha256"] = "inventory-pin"
            fixture[2]["uniqueSaveHashesWithoutArchivedMatch"] = 8
            with self.assertRaisesRegex(ValueError, "denominator"):
                self.run_fixture(fixture)

    def test_multiple_runs_under_same_root_are_context_not_attestation(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(directory)
            attempts = fixture[1]["collectionInputs"]["attemptEvidence"]["titles"]["PRODUCT"]["attempts"]
            attempts[1]["artifacts"] = copy.deepcopy(attempts[0]["artifacts"])
            result = self.run_fixture(fixture)
            self.assertEqual(result["snapshots"][0]["candidateRunIds"], ["run", "unresolved"])
            self.assertEqual(result["snapshots"][0]["attribution"],
                             "proof-root-context-not-execution-attestation")

    def test_unpinned_snapshot_and_malicious_archive_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(directory)
            snapshot = next(k for k in fixture[3]["files"] if k.endswith("after.json"))
            fixture[3]["files"].pop(snapshot)
            with self.assertRaisesRegex(ValueError, "pinned"):
                self.run_fixture(fixture)
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(directory)
            record = next(iter(fixture[2]["snapshots"][0]["saveReferences"].values()))
            record["archivedHashMatches"] = ["../../live-save"]
            with self.assertRaisesRegex(ValueError, "Unsafe"):
                self.run_fixture(fixture)

    def test_update_preserves_existing_bytes_fields_and_is_idempotent(self):
        original = b'{\n  "historical": [1, 2],\n  "admission": "unchanged"\n}\n'
        result = {"coverage": {"hashes": 57}}
        updated = updated_owner_bytes(original, result)
        self.assertEqual(updated_owner_bytes(updated, result), updated)
        self.assertTrue(updated.startswith(original.rstrip()[:-1].rstrip()))
        parsed = json.loads(updated)
        parsed.pop("req39EvidenceReconciliation")
        self.assertEqual(parsed, json.loads(original))
        next_result = {"coverage": {"hashes": 58}}
        self.assertEqual(json.loads(updated_owner_bytes(updated, next_result))[
            "req39EvidenceReconciliation"], next_result)

    def test_missing_note_field_is_not_a_diagnosis(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(directory)
            attempt = fixture[1]["collectionInputs"]["attemptEvidence"]["titles"]["PRODUCT"]["attempts"][0]
            attempt["hypothesisAndNextTestRefs"][0]["field"] = "notPresent"
            result = self.run_fixture(fixture)
            self.assertEqual(result["coverage"]["attemptsWithVerifiedDiagnosisRefs"], 0)
            note = result["titles"]["PRODUCT"]["attempts"][0]["failedHypothesisAndNextDiscriminator"]["references"][0]
            self.assertEqual(note["fieldStatus"], "MISSING_RECORDED_FIELD")

    def test_unpinned_file_does_not_get_historical_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(directory)
            payload = fixture[-1]
            self.assertEqual(check_file(payload, payload.parent)["status"], "HASHED_WITHOUT_HISTORICAL_PIN")

    def test_duplicate_snapshots_and_multiple_archive_copies_do_not_inflate_hash_count(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.fixture(directory)
            home, _, gap, inventory, _, _, payload = fixture
            extra = payload.parent / "another-copy.xgs"
            extra.write_bytes(payload.read_bytes())
            digest = sha(extra.read_bytes())
            inventory["files"][extra.relative_to(home).as_posix()] = {
                "sha256": digest, "bytes": extra.stat().st_size}
            gap["snapshots"].append(copy.deepcopy(gap["snapshots"][0]))
            result = self.run_fixture(fixture)
            self.assertEqual(result["coverage"]["historicalSnapshotDocuments"], 2)
            self.assertEqual(result["coverage"]["saveHashesVerifiedAsRawBytes"], 1)
            refs = result["saveHashes"][digest]["archiveEvidenceRefs"]
            self.assertEqual(len(refs), 2)


if __name__ == "__main__":
    unittest.main()
