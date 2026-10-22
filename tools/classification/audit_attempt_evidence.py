#!/usr/bin/env python3
"""Index retained launch evidence, never execute games or copy raw evidence."""

import datetime as dt
import hashlib
import json
from pathlib import Path
import re

RUN = re.compile(r"\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b")
HASH = re.compile(r"^[0-9a-f]{64}$")
FORMATS = {".json", ".jsonl", ".log", ".txt", ".png", ".jpg", ".jpeg"}
PRIVATE = re.compile(r"account|credential|token|auth-status|license", re.I)


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(2**20), b""):
            value.update(chunk)
    return value.hexdigest()


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key, item in value.items():
            yield from strings(key)
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)


def referenced_runs(value):
    if isinstance(value, dict):
        for key, item in value.items():
            if key.lower().endswith("runid") and not any(
                    word in key.lower() for word in ("install", "status")) and isinstance(item, str):
                yield item
            elif isinstance(item, (dict, list)):
                yield from referenced_runs(item)
    elif isinstance(value, list):
        for item in value:
            yield from referenced_runs(item)


def audit(inputs, previous=None, home=None):
    home = home or Path.home()
    base = home / "Library/Application Support/XodusCLI"
    roots = [base / "proofs", base / "runs"]
    previous = previous or {}
    artifacts = {}
    gaps = []
    records = {}
    documents = {}
    scanned = 0

    def artifact(path, expected=None):
        path = Path(path)
        key = str(path)
        if key not in artifacts:
            if path.is_symlink():
                artifacts[key] = {"status": "SYMLINK_NOT_FOLLOWED", "sha256": None}
            elif path.is_file():
                before = path.stat()
                sha = digest(path)
                after = path.stat()
                stable = (before.st_size, before.st_mtime_ns) == (
                    after.st_size, after.st_mtime_ns)
                artifacts[key] = {"status": "PRESENT" if stable else "CHANGING_DURING_AUDIT",
                                  "bytes": after.st_size, "sha256": sha}
            else:
                artifacts[key] = {"status": "MISSING", "sha256": None}
        if expected and HASH.fullmatch(str(expected)):
            expectations = artifacts[key].setdefault("recordedHashes", [])
            if expected not in expectations:
                expectations.append(expected)
            artifacts[key]["recordedSha256"] = expected
            artifacts[key]["matchesRecordedHash"] = all(
                artifacts[key]["sha256"] == value for value in expectations)
        return key

    for root in roots:
        if not root.is_dir():
            gaps.append("Evidence root unavailable: " + str(root))
            continue
        for path in sorted(root.rglob("*.json")):
            if path.is_symlink() or PRIVATE.search(path.name):
                continue
            scanned += 1
            if path.stat().st_size > 16 * 2**20:
                gaps.append("JSON not parsed (>16 MiB); raw retained: " + str(path))
                continue
            try:
                value = json.loads(path.read_text())
            except (ValueError, UnicodeError) as error:
                gaps.append("Unparsed JSON " + str(path) + ": " + type(error).__name__)
                continue
            if isinstance(value, dict):
                documents[path] = value
                candidates = [value, value.get("result", {})]
                for result in candidates:
                    if not isinstance(result, dict) or result.get("operation") != "launch":
                        continue
                    sid, rid = result.get("product"), result.get("run_id")
                    if sid == "minecraft-java":
                        sid = "9PJ8266BHFWN"
                    if not isinstance(sid, str) or not isinstance(rid, str):
                        gaps.append("Launch record lacks exact product/run identity: " + str(path))
                        continue
                    if not RUN.fullmatch(rid):
                        gaps.append("Noncanonical launch run ID: " + str(path))
                        continue
                    record = records.setdefault((sid, rid), {"results": [], "receiptPaths": []})
                    record["results"].append((path, result))
                    record["receiptPaths"].append(path)

    title_rows = {row["storeId"]: row for row in inputs["candidates"]}
    matrix = {row["productId"]: row for row in inputs["matrix"]["snapshot"]["games"]}
    reports = {row["storeId"]: row for row in inputs["ownerVerdicts"]["snapshot"]["items"]}
    titles = {}
    for (sid, rid), record in sorted(records.items()):
        result_path, result = next(((p, r) for p, r in record["results"]
                                    if p.name == "result.json"), record["results"][0])
        context_roots = set()
        run_dirs = set()
        for path in record["receiptPaths"]:
            parts = path.relative_to(base).parts
            if parts[0] == "proofs" and len(parts) > 2:
                context_roots.add(base / "proofs" / parts[1])
            if path.name == "result.json":
                run_dirs.add(path.parent)
        own = set(record["receiptPaths"])
        for directory in run_dirs:
            own.update(p for p in directory.iterdir() if p.is_file() and p.suffix in FORMATS
                       and not PRIVATE.search(p.name))
        shared = set()
        for root in context_roots:
            shared.update(p for p in root.rglob("*") if p.is_file() and not p.is_symlink()
                          and p.suffix in FORMATS and not PRIVATE.search(p.name))
        associated_docs = {}
        for path, doc in documents.items():
            if path in own:
                associated_docs[path] = doc
            elif path in shared and rid in set(RUN.findall(" ".join(strings(doc)))):
                associated_docs[path] = doc
        invocations = []
        for path, doc in documents.items():
            if path not in shared:
                continue
            argv = doc.get("argv") or doc.get("command")
            if not isinstance(argv, list) or "launch" not in argv:
                continue
            position = argv.index("launch")
            if position + 1 >= len(argv) or argv[position + 1] != sid:
                continue
            if "--state-dir" in argv:
                state = Path(argv[argv.index("--state-dir") + 1])
                if any(directory.is_relative_to(state) for directory in run_dirs):
                    invocations.append((path, argv))
                    associated_docs[path] = doc
        identities = {}
        for path, argv in invocations:
            for sibling in path.parent.iterdir():
                if sibling.is_file() and sibling.suffix in FORMATS and not PRIVATE.search(sibling.name):
                    own.add(sibling)
                    if sibling in documents:
                        associated_docs[sibling] = documents[sibling]
            identities.setdefault("cli", []).append(
                {"path": argv[0], "basis": str(path), "historicalHash": (
                    Path(argv[0]).parent.name if HASH.fullmatch(Path(argv[0]).parent.name) else None),
                 "hashBasis": "Candidate path label, not independent execution-time hash"})
            for flag, name in (("--runtime-dll", "runtime"), ("--engine", "engine"),
                               ("--prefix", "prefix"), ("--registry", "registry"),
                               ("--exe", "gameExecutable")):
                if flag in argv and argv.index(flag) + 1 < len(argv):
                    value = argv[argv.index(flag) + 1]
                    identities.setdefault(name, []).append({"value": value, "basis": str(path)})
        for name, key in (("engine", "engine"), ("prefix", "prefix")):
            if result.get(key):
                identities.setdefault(name, []).append({"value": result[key], "basis": str(result_path)})
        for path, doc in associated_docs.items():
            for name in ("cliSha256", "runtimeSha256", "runtimeDllSha256", "packetSha256",
                         "packet_sha256", "executable_sha256", "runner_sha256",
                         "registry_sha256", "source_registry_sha256"):
                if HASH.fullmatch(str(doc.get(name, ""))):
                    identities.setdefault("recordedHashes", []).append(
                        {"field": name, "sha256": doc[name], "basis": str(path)})
        links = {"runArtifacts": sorted(artifact(p) for p in own),
                 "sharedProofContext": sorted(artifact(p) for p in shared - own)}
        for path, doc in associated_docs.items():
            if path.name == "integrity.json":
                for linked, expected in doc.items():
                    if isinstance(linked, str) and linked.startswith(str(home) + "/") \
                            and HASH.fullmatch(str(expected)):
                        key = artifact(linked, expected)
                        if key not in links["runArtifacts"]:
                            links["runArtifacts"].append(key)
            for text in strings(doc):
                if text.startswith(str(home) + "/") and Path(text).suffix in FORMATS \
                        and "\n" not in text and not PRIVATE.search(Path(text).name):
                    key = artifact(text)
                    if key not in links["runArtifacts"] and key not in links["sharedProofContext"]:
                        links["runArtifacts"].append(key)
        linked = links["runArtifacts"] + links["sharedProofContext"]
        categories = {
            "packet": [p for p in linked if "packet" in Path(p).name],
            "receipt": [p for p in linked if Path(p).name in {
                "receipt.json", "result.json", "retention-result.json", "qualification.json"}],
            "log": [p for p in linked if Path(p).suffix in {".log", ".jsonl"}],
            "screenshot": [p for p in linked if Path(p).suffix.lower() in {".png", ".jpg", ".jpeg"}],
            "saveDelta": [p for p in linked if any(s in Path(p).name.lower() for s in (
                "before-launch", "after-process", "baseline", "retention", "save", "payload"))],
        }
        missing = []
        for name in ("app", "cli", "runtime", "engine", "prefix"):
            if name not in identities:
                missing.append("Historical " + name + " identity not bound to this run")
        missing.append("Path-labeled identities are not independent execution-time binary hashes")
        missing.append("Historical app version and engine/runtime binary hashes may be absent; "
                       "do not substitute currently installed binaries or infer prefix contents")
        for category, paths in categories.items():
            if not any(artifacts[p]["status"] == "PRESENT" for p in paths):
                missing.append("No retained " + category + " artifact found in bounded search")
        if links["sharedProofContext"]:
            missing.append("Shared proof-root files are context only; per-run attribution incomplete")
        row = titles.setdefault(sid, {
            "title": matrix.get(sid, title_rows.get(sid, {})).get("title", sid),
            "attempts": [], "sourceRefs": [],
            "hypothesesStatus": "See existing title scope/blocker and raw diagnostic links; "
            "no per-attempt hypothesis verdict invented.",
            "nextDiscriminatingTest": "Not explicitly frozen by this audit; owner must recover "
            "the existing test card/diagnosis before any separately authorized retry.",
        })
        row["attempts"].append({
            "runId": rid, "recordedProduct": result.get("product"),
            "startedAt": result.get("started_at"), "finishedAt": result.get("finished_at"),
            "observedProcessResult": {k: result[k] for k in (
                "exit_code", "wine_exit_code", "wine_termination_signal", "error_code", "success")
                if k in result},
            "resultPolicy": "Raw process success/exit is not title, gameplay, quit or retention PASS.",
            "identities": identities, "artifacts": links, "categories": categories,
            "observationRefs": [
                {"path": str(path), "field": key, "scope": "Recorded observation; raw stays local"}
                for path, doc in associated_docs.items() for key in doc
                if re.search(r"observ|retention|ordinary|visual|verdict|payload|status", key, re.I)],
            "hypothesisAndNextTestRefs": [
                {"path": str(path), "field": key, "scope": "Recorded diagnosis, not a new conclusion"}
                for path, doc in associated_docs.items() for key in doc
                if re.search(r"hypothes|next|caus|diagnos|gap|inferred|limitation", key, re.I)],
            "gaps": missing,
        })

    for sid, observed in {**matrix, **reports}.items():
        if observed.get("verdict") not in {"NOT_TESTED", "UNTESTED", "CANCELLED"}:
            titles.setdefault(sid, {
                "title": observed.get("title", sid), "attempts": [], "sourceRefs": [],
                "hypothesesStatus": "Per-attempt failed hypotheses not normalized; recover from "
                "existing title scope and referenced diagnosis before retry.",
                "nextDiscriminatingTest": "Not frozen in this index; requires owner source card.",
            })
    for sid, row in titles.items():
        for source_name, source_rows in (("matrix", matrix), ("ownerVerdicts", reports)):
            if sid in source_rows:
                row["sourceRefs"].append({"source": source_name, "productId": sid})
        observed = reports.get(sid, matrix.get(sid, {}))
        row["recordedTitleScope"] = observed.get("scope")
        row["recordedBlocker"] = observed.get("blocker")
        row["gaps"] = [
            "Historical attempts mentioned only in free-form prose/short IDs may remain unenumerated",
            "Per-attempt failed hypotheses and next discriminating test require source-owner annotation",
        ]
        if sid == "9NLRT31Z4RWM":
            row["gaps"].append("S3/coordinator: earlier3a/9b save versions were hashed but not "
                               "archived before legitimate writes; only current1b116832 payload "
                               "archived. Partial historical recoverability, not complete save "
                               "archive; observed retained stick/hash continuity remains valid")
        if sid == "9PNG83MDD6SH":
            row["nextDiscriminatingTest"] = "S1 source index section13: holder/waiter stacks plus "
            row["nextDiscriminatingTest"] += "DLL-init order only if separately assigned. No-game "
            row["nextDiscriminatingTest"] += "container replay PASS does not exclude loader-lock inversion."
        if sid == "9NGH1FK0RJGL":
            row["nextDiscriminatingTest"] = "S1 section9: establish staged MicrosoftGame.config "
            row["nextDiscriminatingTest"] += "byte parity; missing MSAAppId fails parser before socket. "
            row["nextDiscriminatingTest"] += "Retries parked; no runtime socket diagnosis inferred."
        if observed.get("nextGate"):
            row["nextGate"] = observed["nextGate"]
        for value in referenced_runs([matrix.get(sid, {}), reports.get(sid, {})]):
            if not any(a["runId"].startswith(value) for a in row["attempts"]):
                row["attempts"].append({
                    "runId": value, "observedProcessResult": None, "identities": {},
                    "artifacts": {}, "categories": {},
                    "gaps": ["Referenced attempt only; full run ID/result not located"],
                })
    specialist = []
    s1 = home / "src/copilot-worktrees/xode-wine/dragoshont-fantastic-broccoli/engines"
    for name in ("s3-retention-cards.md", "fallout-mouse-evidence.md", "fallout-save-hypotheses.md"):
        specialist.append(artifact(s1 / name))
    for sid, old in previous.get("titles", {}).items():
        row = titles.setdefault(sid, old)
        known = {attempt["runId"] for attempt in row["attempts"]}
        for attempt in old["attempts"]:
            if attempt["runId"] not in known:
                row["attempts"].append({**attempt, "gaps": attempt["gaps"] + [
                    "Previously indexed attempt absent from current bounded scan; retained, not erased"]})
            elif attempt.get("observedProcessResult") is not None:
                current = next(item for item in row["attempts"] if item["runId"] == attempt["runId"])
                if current.get("observedProcessResult") is None:
                    row["attempts"].remove(current)
                    row["attempts"].append({**attempt, "gaps": attempt["gaps"] + [
                        "Current scan lacks original result; prior indexed metadata retained"]})
    for path, old in previous.get("artifacts", {}).items():
        if path not in artifacts:
            artifact(path, old.get("sha256"))
    attempts = [attempt for title in titles.values() for attempt in title["attempts"]]
    return {
        "schemaVersion": 1, "auditedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "scope": "Existing per-title tracker evidence audit. Local XodusCLI proofs/runs JSON "
        "launch records plus referenced integrity paths. Not all past hosts, removed worktrees "
        "or app-only/native attempts are discoverable; no exhaustive-history claim.",
        "retentionPolicy": "Do not delete proofs, logs, screenshots or save payloads for reclaim. "
        "Protected raw evidence remains local. Only path/hash metadata and allowlisted process "
        "identity fields are indexed; no argv, environments, account tokens or save contents copied. "
        "For future separately authorized attempts, owners must archive authorized title save bytes "
        "locally before launch and after quit, before another write. Do not rerun to reconstruct history.",
        "roots": [str(root) for root in roots], "jsonDocumentsInspected": scanned,
        "gaps": gaps, "artifacts": dict(sorted(artifacts.items())), "titles": titles,
        "coverage": {
            "titleCount": len(titles),
            "launchResultAttempts": sum(a.get("observedProcessResult") is not None for a in attempts),
            "unresolvedReferenceCount": sum(a.get("observedProcessResult") is None for a in attempts),
            "artifactCount": len(artifacts),
            "presentArtifacts": sum(a["status"] == "PRESENT" for a in artifacts.values()),
            "missingArtifacts": sum(a["status"] == "MISSING" for a in artifacts.values()),
            "recordedHashDiscrepancies": sum(a.get("matchesRecordedHash") is False
                                           for a in artifacts.values()),
            "attemptsWithIdentityGaps": sum(bool(a["gaps"]) for a in attempts),
            "unresolvedReferencesPolicy": "May include non-launch/support references or short-ID "
            "duplicates; not additional proven game attempts.",
        },
        "specialistIndexes": specialist,
        "identityPolicy": "Direct CLI-only attempts have no observed app identity; do not attach "
        "the current installed app retroactively. Candidate hash paths are labels, not independent "
        "execution-time attestation. Exact prefix path identifies a mutable directory, not its "
        "historical contents. Save-delta JSON hashes do not imply retained original payload bytes.",
    }
