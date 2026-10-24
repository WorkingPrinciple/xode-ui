#!/usr/bin/env python3
"""REQ-39: reconcile pinned historical evidence; never read live save roots."""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat

DATA = Path(__file__).resolve().parents[2] / "Sources/XodusManagement/Resources/CompatibilityData"
HASH = re.compile(r"[0-9a-f]{64}")
LIMIT = 4096
MAX_FILE_BYTES = 128 * 1024 * 1024


def canonical(value):
    return (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode()


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def is_verified(record):
    return record["status"] in {"VERIFIED", "VERIFIED_FROM_PROTECTED_ARCHIVE"}


def check_file(path, root, expected=None, expected_size=None):
    """Hash a single referenced file without following links or walking directories."""
    path, root = Path(path), Path(root)
    if ".." in path.parts or not path.is_absolute() or not path.is_relative_to(root):
        return {"status": "OUTSIDE_PROOF_SCOPE"}
    for parent in [path, *path.parents]:
        if parent.is_symlink():
            return {"status": "SYMLINK_NOT_FOLLOWED"}
        if parent == root:
            break
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return {"status": "MISSING"}
    with os.fdopen(fd, "rb") as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode):
            return {"status": "NOT_REGULAR_FILE"}
        if before.st_size > MAX_FILE_BYTES:
            return {"status": "FILE_BOUND_EXCEEDED", "bytes": before.st_size}
        value = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
        after = os.fstat(stream.fileno())
    fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
    stable = all(getattr(before, k) == getattr(after, k) for k in fields)
    result = {"status": ("VERIFIED" if expected is not None else "HASHED_WITHOUT_HISTORICAL_PIN")
              if stable else "CHANGED_DURING_READ",
              "sha256": value.hexdigest(), "bytes": after.st_size}
    if stable and expected is not None and result["sha256"] != expected:
        result["status"] = "HASH_MISMATCH"
    if stable and expected_size is not None and after.st_size != expected_size:
        result["status"] = "HASH_AND_SIZE_MISMATCH" if result["status"] == "HASH_MISMATCH" else "SIZE_MISMATCH"
    return result


def pointer(*parts):
    return "/" + "/".join(str(p).replace("~", "~0").replace("/", "~1") for p in parts)


def proof_relative(value, proofs):
    path = Path(value)
    if ".." in path.parts or not path.is_absolute() or not path.is_relative_to(proofs):
        return None
    return path.relative_to(proofs).as_posix()


def archived_path(value, home, proofs):
    relative = PurePosixPath(value)
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError("Unsafe archived save reference")
    path = home / relative
    if not path.is_relative_to(proofs):
        raise ValueError("Archive reference is not under protected proofs")
    return path


def reconcile(tracker, gap, inventory, archive, sources, home, verify):
    proofs = home / "Library/Application Support/XodusCLI/proofs"
    audit = tracker["collectionInputs"]["attemptEvidence"]
    if gap["parseErrors"]:
        raise ValueError("Historical save-gap audit has unresolved parse errors")
    if gap["inventorySha256"] != sources["inventory"]["sha256"]:
        raise ValueError("Save-gap inventory pin does not match source")
    if archive["sourceInventorySha256"] != sources["inventory"]["sha256"]:
        raise ValueError("Historical archive inventory pin does not match source")
    by_root = {}
    for sid, title in audit["titles"].items():
        for attempt in title["attempts"]:
            for paths in attempt.get("artifacts", {}).values():
                for value in paths:
                    relative = proof_relative(value, proofs)
                    if relative:
                        by_root.setdefault(relative.split("/")[0], set()).add((sid, attempt["runId"]))
    archive_hashes = {}
    archive_sources = {}
    for record in archive["references"]:
        archive_hashes.setdefault(record["sha256"], []).append(record)
        key = record["sourceRelativeToHome"]
        if key in archive_sources and archive_sources[key] != record:
            raise ValueError("Conflicting source-to-archive mappings")
        archive_sources[key] = record
    inventory_hashes = {}
    for name, record in inventory["files"].items():
        inventory_hashes.setdefault(record["sha256"], []).append(name)
    verified = {}
    resolved = {}
    archive_reads = 0

    def evidence(path, expected=None, size=None, locator=None):
        nonlocal archive_reads
        name = str(path) if locator is None else "protected-archive:" + sha(str(path).encode())
        if name not in verified:
            if len(verified) + archive_reads >= LIMIT:
                raise ValueError("Explicit evidence file limit exceeded")
            verified[name] = verify(path, proofs, expected, size)
            verified[name]["expectedSha256"] = expected
            verified[name]["expectedBytes"] = size
            resolved[name] = Path(path)
            if expected is not None and verified[name]["status"] in {"MISSING", "OUTSIDE_PROOF_SCOPE"}:
                try:
                    source = Path(path).relative_to(home).as_posix()
                except ValueError:
                    source = None
                archived = archive_sources.get(source)
                if archived is not None and archived["sha256"] == expected:
                    if archived["archivedAs"] != "payloads/" + expected:
                        raise ValueError("Archive payload is not content-addressed by its expected hash")
                    if size is not None and archived["bytes"] != size:
                        raise ValueError("Archive and original evidence byte counts conflict")
                    if len(verified) + archive_reads >= LIMIT:
                        raise ValueError("Explicit evidence file limit exceeded")
                    copy_path = proofs / "s3-historical-session-archive-01" / archived["archivedAs"]
                    copy = verify(copy_path, proofs, expected, archived["bytes"])
                    archive_reads += 1
                    verified[name]["originalStatus"] = verified[name]["status"]
                    verified[name]["archivedCopy"] = {"path": str(copy_path), **copy}
                    if copy["status"] == "VERIFIED":
                        verified[name]["status"] = "VERIFIED_FROM_PROTECTED_ARCHIVE"
                        verified[name]["sha256"] = copy["sha256"]
                        verified[name]["bytes"] = copy["bytes"]
                        resolved[name] = copy_path
            if locator is not None:
                verified[name]["protectedLocator"] = locator
        elif expected is not None and verified[name].get("expectedSha256") not in (None, expected):
            raise ValueError("Conflicting historical evidence hashes")
        return name

    snapshots = []
    hashes = {}
    for index, row in enumerate(gap["snapshots"]):
        relative = PurePosixPath(row["snapshot"])
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("Unsafe historical snapshot reference")
        path = proofs / relative
        key = path.relative_to(home).as_posix()
        pinned = inventory["files"].get(key)
        if pinned is None:
            raise ValueError("Snapshot lacks a pinned inventory record")
        ref = evidence(path, pinned["sha256"], pinned["bytes"])
        bindings = sorted(by_root.get(relative.parts[0], set()))
        ids = sorted({sid for sid, _ in bindings})
        snapshots.append({
            "snapshot": row["snapshot"], "verifiedEvidenceRef": ref,
            "historicalGapPointer": pointer("snapshots", index),
            "productIds": ids, "candidateRunIds": sorted({run for _, run in bindings}),
            "attribution": "proof-root-context-not-execution-attestation",
            "attributionGap": None if len(ids) == 1 else "No unambiguous indexed title identity",
        })
        for save_index, item in enumerate(row["saveReferences"].values()):
            digest = item["sha256"]
            if (not HASH.fullmatch(digest)
                    or (item["bytes"] is not None and (type(item["bytes"]) is not int or item["bytes"] < 0))):
                raise ValueError("Invalid historical save identity")
            record = hashes.setdefault(digest, {
                "sha256": digest, "bytes": item["bytes"], "productIds": [],
                "snapshotRefs": [], "archiveEvidenceRefs": [],
                "historicalInventoryMatch": False,
                "payloadRole": "historical-save-reference-not-independently-classified-as-gameplay-or-settings",
            })
            if record["bytes"] is not None and item["bytes"] is not None and record["bytes"] != item["bytes"]:
                raise ValueError("Conflicting save byte counts for the same hash")
            if item["bytes"] is not None:
                record["bytes"] = item["bytes"]
            record["productIds"] = sorted(set(record["productIds"]) | set(ids))
            record["snapshotRefs"].append({"snapshotIndex": index, "saveOrdinal": save_index})
            for match_index, candidate in enumerate(item["archivedHashMatches"]):
                raw = archived_path(candidate, home, proofs)
                inventory_key = raw.relative_to(home).as_posix()
                raw_pin = inventory["files"].get(inventory_key, {})
                if raw_pin.get("sha256") != digest or raw_pin.get("bytes") != item["bytes"]:
                    raise ValueError("Recorded raw save match is not inventory-bound")
                record["historicalInventoryMatch"] = True
                locator = {"source": "gapAudit", "snapshotIndex": index, "saveOrdinal": save_index,
                           "archiveMatchOrdinal": match_index}
                record["archiveEvidenceRefs"].append(evidence(raw, digest, item["bytes"], locator))
            # Exact hash lookup only: never search live saves or additional proof roots.
            for match_index, candidate in enumerate(inventory_hashes.get(digest, [])):
                raw = archived_path(candidate, home, proofs)
                locator = {"source": "inventory", "sha256": digest, "matchOrdinal": match_index}
                record["archiveEvidenceRefs"].append(evidence(raw, digest, item["bytes"], locator))
            for match_index, candidate in enumerate(archive_hashes.get(digest, [])):
                relative_archive = PurePosixPath(candidate["archivedAs"])
                if relative_archive.is_absolute() or ".." in relative_archive.parts:
                    raise ValueError("Unsafe protected archive payload path")
                raw = proofs / "s3-historical-session-archive-01" / relative_archive
                locator = {"source": "sessionArchive", "sha256": digest, "matchOrdinal": match_index}
                record["archiveEvidenceRefs"].append(evidence(raw, digest, item["bytes"], locator))
    historical_matches = sum(v["historicalInventoryMatch"] for v in hashes.values())
    if (historical_matches != gap["uniqueSaveHashesWithArchivedMatch"]
            or len(hashes) - historical_matches != gap["uniqueSaveHashesWithoutArchivedMatch"]):
        raise ValueError("Historical save-hash denominator mismatch")
    for row in hashes.values():
        row["archiveEvidenceRefs"] = sorted(set(row["archiveEvidenceRefs"]))
        matches = [r for r in row["archiveEvidenceRefs"]
                   if is_verified(verified[r]) and verified[r]["sha256"] == row["sha256"]]
        row["availability"] = "VERIFIED_ARCHIVED_BYTES" if matches else "HASH_ONLY_NO_VERIFIED_ARCHIVED_BYTES"
        row["recoverability"] = "bytes-verified-not-restore-tested" if matches else "not-established-do-not-reconstruct"

    titles = {}
    counts = Counter()
    for sid, title in sorted(audit["titles"].items()):
        attempts = []
        for index, attempt in enumerate(title["attempts"]):
            counts["attemptReferences"] += 1
            if attempt.get("observedProcessResult") is not None:
                counts["launchResultAttempts"] += 1
            run_paths = set(attempt.get("artifacts", {}).get("runArtifacts", []))
            context_paths = set(attempt.get("artifacts", {}).get("sharedProofContext", []))
            categories = {}
            for role in ("packet", "receipt", "log", "screenshot", "saveDelta"):
                refs = []
                for name in attempt.get("categories", {}).get(role, []):
                    if name not in run_paths:
                        continue
                    pin = audit["artifacts"].get(name, {})
                    refs.append(evidence(Path(name), pin.get("sha256"), pin.get("bytes")))
                categories[role] = sorted(set(refs))
            # Filename is an index hint, not evidence that input reached the game.
            categories["inputWindow"] = sorted({
                evidence(Path(name), audit["artifacts"].get(name, {}).get("sha256"),
                         audit["artifacts"].get(name, {}).get("bytes"))
                for name in run_paths
                if re.search(r"input|foreground|window|key.?event|mouse|click", Path(name).name, re.I)
            })
            notes = []
            for item in attempt.get("hypothesisAndNextTestRefs", []):
                name = item["path"]
                pin = audit["artifacts"].get(name, {})
                ref = evidence(Path(name), pin.get("sha256"), pin.get("bytes"))
                note = {"verifiedEvidenceRef": ref, "field": item["field"],
                        "fieldStatus": "SOURCE_NOT_HISTORICALLY_HASH_VERIFIED"}
                if is_verified(verified[ref]) and pin.get("sha256"):
                    raw = resolved[ref].read_bytes()
                    if sha(raw) != pin["sha256"]:
                        raise ValueError("Annotation document changed before field verification")
                    document = json.loads(raw)
                    if isinstance(document, dict) and item["field"] in document:
                        note["fieldStatus"] = "VERIFIED_PRESENT"
                        note["fieldSha256"] = sha(canonical(document[item["field"]]))
                    else:
                        note["fieldStatus"] = "MISSING_RECORDED_FIELD"
                notes.append(note)
            bound_notes = any(x["fieldStatus"] == "VERIFIED_PRESENT" for x in notes)
            next_notes = [x for x in notes if x["fieldStatus"] == "VERIFIED_PRESENT"
                          and x["field"] in {"nextAction", "nextHypothesis", "nextDiscriminator", "nextTest"}]
            counts["attemptsWithVerifiedDiagnosisRefs"] += bound_notes
            counts["attemptsWithVerifiedNextActionRefs"] += bool(next_notes)
            gaps = list(attempt.get("gaps", []))
            for role, refs in categories.items():
                if not any(is_verified(verified[r]) for r in refs):
                    gaps.append(f"No currently hash-verified run-associated {role}; shared files are context only")
            if not bound_notes:
                gaps.append("Per-attempt failed-hypothesis/next-discriminator annotation not retained or not bound")
            else:
                gaps.append("Source diagnosis/limitations are not a normalized per-attempt failed-hypothesis outcome")
            if not next_notes:
                gaps.append("No historically hash-verified per-attempt next-action/hypothesis field")
            attempts.append({
                "runId": attempt["runId"],
                "auditPointer": pointer("collectionInputs", "attemptEvidence", "titles", sid, "attempts", index),
                "identityPointer": pointer("collectionInputs", "attemptEvidence", "titles", sid, "attempts", index, "identities"),
                "identitiesStatus": "historical-index-only-no-retrospective-binding",
                "evidenceByRole": categories, "sharedContextFileCount": len(context_paths),
                "failedHypothesisAndNextDiscriminator": {
                    "status": "verified-document-field-references" if bound_notes else "missing-per-attempt-source-note",
                    "references": notes,
                    "nextDiscriminatorReferences": next_notes,
                    "failedHypothesesStatus": "not-normalized-no-failed-outcome-inferred",
                    "scope": "Verified source fields only; no inferred causal or failed-hypothesis verdict",
                },
                "missingEvidence": list(dict.fromkeys(gaps)),
            })
        hash_ids = sorted(key for key, row in hashes.items() if sid in row["productIds"])
        titles[sid] = {
            "title": title["title"], "attempts": attempts,
            "historicalSaveHashes": hash_ids,
            "saveCoverage": {
                "uniqueHashes": len(hash_ids),
                "verifiedArchivedHashes": sum(hashes[k]["availability"] == "VERIFIED_ARCHIVED_BYTES" for k in hash_ids),
                "scope": "Only the pinned 48-snapshot audit, not all title saves or all later runs",
            },
            "titleLevelDiagnosisPointer": pointer("collectionInputs", "attemptEvidence", "titles", sid),
            "nextFileOnlyDiscriminator": (
                "Recover the exact stopped-run owner note and any original pre-write archive named in existing references; "
                "a missing historical payload cannot be regenerated from a digest. Do not infer title-level notes for earlier attempts."
            ),
        }
    counts["titles"] = len(titles)
    counts["attemptsMissingPerAttemptDiagnosisRefs"] = counts["attemptReferences"] - counts["attemptsWithVerifiedDiagnosisRefs"]
    counts["historicalSnapshotDocuments"] = len(snapshots)
    counts["historicalInventoryFiles"] = len(inventory["files"])
    counts["historicalMatchedSaveHashes"] = historical_matches
    counts["historicalUnmatchedSaveHashes"] = len(hashes) - historical_matches
    counts["saveHashesVerifiedAsRawBytes"] = sum(v["availability"] == "VERIFIED_ARCHIVED_BYTES" for v in hashes.values())
    counts["saveHashesWithoutVerifiedRawBytes"] = len(hashes) - counts["saveHashesVerifiedAsRawBytes"]
    counts["explicitFilesChecked"] = len(verified)
    counts["protectedArchiveCopiesChecked"] = archive_reads
    counts["totalFileChecks"] = len(verified) + archive_reads
    counts["verifiedFiles"] = sum(is_verified(v) for v in verified.values())
    return {
        "schemaVersion": 1, "requirement": "REQ-39",
        "scope": "Pinned historical index reconciliation only. No new directory scan, game, GUI, live-save read, copy or restore.",
        "sources": sources, "coverage": dict(counts),
        "fileVerificationStatuses": dict(sorted(Counter(v["status"] for v in verified.values()).items())),
        "snapshots": snapshots, "saveHashes": dict(sorted(hashes.items())),
        "titles": titles, "verifiedEvidence": dict(sorted(verified.items())),
        "gaps": [
            "Historical archive completeness is not established; hashes without raw bytes are not recoverable snapshots.",
            "No global absence claim: no new roots were searched and live saves were not inspected.",
            "This frozen audit omits newer attempts unless already indexed; it is not exhaustive programme coverage.",
            "Historical identities remain as originally recorded, including missing app/runtime/input bindings.",
            "Source field links do not replace missing per-attempt diagnoses or authorize a retry.",
            "DREDGE original raw save bytes remain unverified; historical reload observations do not reconstruct them.",
        ],
        "admission": "No game verdict, policy clearance, REQ-27 classification or whole-REQ acceptance change",
    }


def updated_owner_bytes(original, result):
    owner = json.loads(original)
    if owner.get("req39EvidenceReconciliation") == result:
        return original
    if "req39EvidenceReconciliation" in owner:
        if list(owner)[-1] != "req39EvidenceReconciliation":
            raise ValueError("Reconciliation is not the final field; preserve concurrent owner changes")
        head, separator, _ = original.partition(b',\n  "req39EvidenceReconciliation": ')
        if not separator:
            raise ValueError("Existing reconciliation boundary is not recognized")
        tail = head.decode()
    else:
        tail = original.rstrip()[:-1].decode().rstrip()
    addition = json.dumps(result, indent=2, sort_keys=True, ensure_ascii=False).replace("\n", "\n  ")
    return (tail + ',\n  "req39EvidenceReconciliation": ' + addition + "\n}\n").encode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="Add reconciliation to existing owner index")
    args = parser.parse_args()
    home = Path.home()
    proofs = home / "Library/Application Support/XodusCLI/proofs"
    tracker_path = DATA / "path-to-20-v1.json"
    owner_path = DATA / "path-to-20-owner-verdicts-v1.json"
    original = owner_path.read_bytes()
    owner = json.loads(original)
    tracker = json.loads(tracker_path.read_text())
    protected = owner["protectedSaveArchiveGapAudit"]
    historical = owner["protectedHistoricalEvidenceIndex"]
    archived = owner["protectedSessionArchive"]
    sources = {
        "tracker": {"path": str(tracker_path), "sha256": sha(tracker_path.read_bytes())},
        "reconciler": {"path": "tools/classification/reconcile_save_evidence.py",
                       "sha256": sha(Path(__file__).read_bytes())},
    }
    docs = {}
    for key, binding in (("gapAudit", protected["index"]), ("inventory", historical["index"]),
                         ("sessionArchive", archived["index"])):
        checked = check_file(binding["path"], proofs, binding["sha256"])
        if checked["status"] != "VERIFIED":
            raise ValueError(f"Protected {key} source changed or unavailable: {checked['status']}")
        raw = Path(binding["path"]).read_bytes()
        if sha(raw) != binding["sha256"]:
            raise ValueError(f"Protected {key} source changed before parsing")
        docs[key] = json.loads(raw)
        sources[key] = {**binding, "bytes": len(raw)}
    result = reconcile(tracker, docs["gapAudit"], docs["inventory"], docs["sessionArchive"],
                       sources, home, check_file)
    if args.write:
        if owner_path.read_bytes() != original:
            raise ValueError("Owner index changed during reconciliation")
        owner_path.write_bytes(updated_owner_bytes(original, result))
    print(json.dumps(result["coverage"], sort_keys=True))
    print(json.dumps(result["fileVerificationStatuses"], sort_keys=True))
    print("REQ-39 remains partial where original bytes, identity bindings or owner diagnoses are missing.")


if __name__ == "__main__":
    main()
