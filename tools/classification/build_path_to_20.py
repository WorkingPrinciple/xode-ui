#!/usr/bin/env python3
"""Refresh source-bound candidate gates; never execute games or inspect save contents."""

import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import re

from inspect_queue import DATA, load_json

HOME = Path.home()
MATRIX = HOME / ".copilot/session-state/24963110-1b48-4e35-bae1-a54927543f42/files/s3-tried-games.json"
OUTPUT = DATA / "path-to-20-v1.json"
SUMMARY = DATA / "morning-summary-draft-v2.md"
GATES = ("menu", "gameplay", "quit", "relaunch", "save")
S1 = HOME / "src/copilot-worktrees/xode-wine/dragoshont-fantastic-broccoli/engines"


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def source(path):
    raw = path.read_bytes()
    return {"path": str(path), "sha256": hashlib.sha256(raw).hexdigest(),
            "snapshot": json.loads(raw)}


def build(inputs, previous):
    timestamp = inputs["collectedAt"]
    old = {row["storeId"]: row for row in previous.get("items", [])}
    matrix = {row["productId"]: row for row in inputs["matrix"]["snapshot"]["games"]}
    candidates = {row["storeId"]: row for row in inputs["candidates"]}
    for sid, row in matrix.items():
        candidates.setdefault(sid, {"storeId": sid, "title": row["title"]})
    rows = []
    for sid, candidate in candidates.items():
        observed = matrix.get(sid, {})
        verdict = observed.get("verdict", candidate.get("state", "UNTESTED"))
        scope = observed.get("scope")
        gates = {name: {"status": "unknown", "basis": "Not explicitly admitted"} for name in GATES}
        next_gate = "menu"
        owner = "S2/S3"
        blocker = observed.get("blocker") or candidate.get("blocker") or "Execution admission pending"
        evidence = [{"path": inputs["matrix"]["path"], "sha256": inputs["matrix"]["sha256"],
                     "productId": sid}] if observed else []
        packets = [row for row in inputs["packetRows"] if row["storeId"] == sid]
        evidence.extend({"path": row["path"], "sha256": row["sha256"]} for row in packets)
        if verdict == "WORKING":
            for gate in gates.values():
                gate.update(status="passed", basis="Admitted strict WORKING matrix verdict; "
                            "native/roguelite-specific acceptance retained in matrix scope")
            next_gate, owner, blocker = "complete", observed.get("owner", "S3"), None
        elif verdict in {"TITLE_SCREEN_ONLY", "TITLE_SCREEN_PASS", "GAMEPLAY_PASS", "WORKING_CANDIDATE"}:
            gates["menu"].update(status="passed", basis="Admitted matrix " + verdict)
            next_gate, owner = "gameplay", "S3"
            if verdict == "GAMEPLAY_PASS" or (
                    verdict == "WORKING_CANDIDATE" and observed.get("saveObservation", {}).get("retentionVerified")):
                gates["gameplay"].update(status="passed", basis="Admitted matrix gameplay")
                next_gate = "save"
        save = observed.get("saveObservation") or {}
        if save.get("retentionVerified") is True:
            for name in ("save", "relaunch"):
                gates[name].update(status="passed", basis="Explicit matrix retentionVerified; "
                                   "see retained checkpoint/marker limitations")
            next_gate = "quit" if verdict != "WORKING" else "complete"
        if save.get("normalMenuQuitObserved") is True:
            gates["quit"].update(status="passed", basis="Explicit matrix normalMenuQuitObserved")
        if save.get("normalExitQualified") is False:
            gates["quit"].update(status="not-passed", basis="Explicit matrix normalExitQualified=false; "
                                 "menu Quit interaction alone is not a clean process exit")
            next_gate, owner = "ordinary quit", observed.get("owner", "S3")
        if sid == "9P9VNSQK1W3K" and verdict != "WORKING":
            qualified = save.get("retentionVerified") and save.get("normalMenuQuitObserved")
            verdict, next_gate, owner = "WORKING_CANDIDATE", (
                "CLI promotion" if qualified else "gameplay / CLI promotion hold"), "S2/user" if qualified else "S3/S2/user"
            blocker = "Coordinator reports WORKING_CANDIDATE; CLI ebd56e promotion "
            blocker += "pending. Does not count strict WORKING. Individual gates require owner receipt."
            evidence.append({"kind": "coordinator-verdict", "observedAt": timestamp,
                             "sourceSession": "24963110-1b48-4e35-bae1-a54927543f42"})
            receipt = inputs.get("brotatoReceipt")
            if receipt and not qualified:
                gates["menu"].update(status="passed", basis="S2 explicit TITLE_SCREEN_PASS; "
                                    "direct ebd56e only, no input")
                gates["quit"].update(status="not-passed", basis="S2 reports forced exact-prefix "
                                    "wineserver termination; CLI0/Wine0 not ordinary quit")
                evidence.append({"path": receipt["path"], "sha256": receipt["sha256"]})
                blocker += " S2 confirms only menu; gameplay/relaunch/save untested, "
                blocker += "ordinary quit not passed. Candidate label is not full qualification."
            elif qualified:
                blocker = observed["blocker"]
        passive = inputs.get("passiveVerdicts", {}).get(sid)
        if passive and not observed:
            verdict = passive["verdict"]
            if verdict == "NO_TITLE_SCREEN":
                gates["menu"].update(status="not-passed", basis="Owned passive NO_TITLE_SCREEN")
                next_gate, owner = "startup diagnosis", "S1/S2"
                blocker = "No title screen in admitted passive; CLI0 does not establish rendering."
            evidence.append({"path": passive["path"], "sha256": passive["sha256"],
                             "runId": passive["runId"]})
        reports = inputs.get("ownerVerdicts")
        owner_report_applied = False
        if reports:
            report = next((row for row in reports["snapshot"]["items"]
                           if row["storeId"] == sid), None)
            matrix_time = inputs["matrix"]["snapshot"].get("updatedAt")
            newer = report and matrix_time and dt.datetime.fromisoformat(
                report["reportedAt"]) > dt.datetime.fromisoformat(matrix_time)
            if report and (not observed or verdict in {"UNTESTED", "NOT_TESTED"} or newer
                           or (verdict == report["verdict"] == "INCONCLUSIVE"
                               and any(str(observed.get(key, "")).startswith(report["runId"] or "unmatched")
                                       for key in ("runId", "retentionRunId")))):
                verdict = report["verdict"]
                owner_report_applied = True
                scope = report["scope"]
                next_gate, owner, blocker = (
                    report["nextGate"], report["ownerStream"], report["blocker"])
                for name, status in report["gates"].items():
                    gates[name].update(status=status, basis=report["scope"])
                evidence.append({"path": reports["path"], "sha256": reports["sha256"],
                                 "runId": report["runId"],
                                 "sourceSession": report["sourceSession"]})
                if report.get("receiptPath"):
                    receipt = reports.get("receipts", {}).get(sid)
                    if receipt:
                        evidence.append(receipt)
        if candidate.get("catalogueOnly"):
            next_gate, owner = "catalogue hold / entitlement / disk", "user/coordinator"
            blocker = "Catalogue closed tonight; membership is not entitlement; no install grant"
        elif candidate.get("blockerClass") == "disk/ownership" and not observed and not owner_report_applied:
            next_gate, owner = "install hold / entitlement / disk", "user/coordinator"
        if sid == "9PLH7R84GJWP" and verdict == "FAIL":
            next_gate, owner = "actual-title candidate retest", "S3"
        if sid == "C3KLDKZBHNCZ" and verdict != "WORKING":
            next_gate, owner = "save-provider diagnosis", "S2/S3"
        if sid in {"9NGLST31DG26", "9PK087LNGJC5"} and verdict == "FAIL":
            next_gate, owner = "startup diagnosis", "S1/S2"
        s1rows = [row for source_row in inputs["s1"] for row in source_row["snapshot"].get(
            "profiles", source_row["snapshot"].get("items", [])) if row.get("store_id") == sid]
        first = old.get(sid, {}).get("gateFirstObservedAt", timestamp) \
            if old.get(sid, {}).get("nextGate") == next_gate else timestamp
        age = max(0, (dt.datetime.fromisoformat(timestamp) -
                      dt.datetime.fromisoformat(first)).total_seconds() / 3600)
        rows.append({"storeId": sid, "title": observed.get("title", candidate["title"]),
                     "verdict": verdict, "strictWorking": verdict == "WORKING",
                     "gates": gates, "nextGate": next_gate, "ownerStream": owner,
                     "blocker": blocker, "evidence": evidence,
                     "packetReferences": candidate.get("evidence", []) + packets,
                     "s1RowPresent": bool(s1rows),
                     "gateFirstObservedAt": first, "sameGateObservedHours": age,
                     "stuckOver2Hours": age > 2 and next_gate != "complete",
                     "historicalGateAge": "unknown before tracker first observation",
                     "scope": scope})
        history = inputs.get("attemptEvidence", {}).get("titles", {}).get(sid)
        if history is not None:
            rows[-1]["attemptHistory"] = [attempt["runId"] for attempt in history["attempts"]]
            rows[-1]["evidenceAuditRef"] = "collectionInputs.attemptEvidence.titles." + sid
    rows.sort(key=lambda row: (not row["strictWorking"],
                              {"quit": 0, "gameplay / CLI promotion hold": 1, "save": 2,
                               "gameplay": 3}.get(row["nextGate"], 4), row["title"]))
    working = sum(row["strictWorking"] for row in rows)
    return {"schemaVersion": 1, "updatedAt": timestamp, "matrixUpdatedAt":
            inputs["matrix"]["snapshot"]["updatedAt"], "collectionInputs": inputs,
            "target": 20, "strictWorkingCount": working, "remainingTo20": max(0, 20 - working),
            "gameLaunches": 0, "policy": "Unknown gates never inferred passed from "
            "install status, source row, screenshots or cache files. Strict matrix "
            "WORKING or newer explicit coordinator admission admits title-specific gate semantics. WORKING_CANDIDATE excluded. "
            "Stall clock is observed same next gate, not source mtime/global matrix "
            "updatedAt; historical age unavailable until measured. >2h alerts include "
            "held/queued lanes but do not override holds or authorize runs.",
            "refreshPolicy": "Every 30 minutes via attached session automation and "
            "when a session reports a verdict. Same-session refresh only; no background games.",
            "items": rows}


def refresh(audit_evidence=False):
    base = source(DATA / "morning-status-v1.json")
    catalogue = load_json(DATA / "s3-preflight-catalogue-v1.json")
    closed = {row["storeId"] for row in catalogue["blockedItems"]}
    packets = []
    for name in ("s3-preflight-small-v1.json", "s3-preflight-next-v1.json"):
        packet = source(DATA / name)
        for row in packet["snapshot"].get("items", []) + packet["snapshot"].get("blockedItems", []):
            packets.append({"storeId": row["storeId"], "path": packet["path"], "sha256": packet["sha256"]})
    inputs = {"collectedAt": now(), "matrix": source(MATRIX),
              "ownerVerdicts": source(DATA / "path-to-20-owner-verdicts-v1.json"),
              "candidates": [{"storeId": row["storeId"], "title": row["title"],
                              "catalogueOnly": row["storeId"] in closed,
                              "blocker": row.get("blocker"), "state": row["state"],
                              "blockerClass": row.get("blockerClass"),
                              "evidence": row.get("evidence", [])}
                             for row in base["snapshot"]["items"]],
              "packetRows": packets, "s1": [source(path) for path in sorted(S1.glob("*candidates.json"))],
              "candidateSource": {"path": base["path"], "sha256": base["sha256"]}}
    previous = load_json(OUTPUT) if OUTPUT.exists() else {}
    if audit_evidence:
        from audit_attempt_evidence import audit
        inputs["attemptEvidence"] = audit(inputs, previous.get("collectionInputs", {}).get("attemptEvidence"))
    elif previous.get("collectionInputs", {}).get("attemptEvidence"):
        inputs["attemptEvidence"] = previous["collectionInputs"]["attemptEvidence"]
    inputs["ownerVerdicts"]["receipts"] = {}
    for report in inputs["ownerVerdicts"]["snapshot"]["items"]:
        if report.get("receiptPath"):
            receipt = source(Path(report["receiptPath"]))
            result = receipt["snapshot"]
            if (result["run_id"] != report["runId"] or result["product"] != report["storeId"]
                    or result["exit_code"] != 0 or result["wine_exit_code"] != 0):
                raise ValueError("Owner WORKING report has inconsistent exit receipt")
            inputs["ownerVerdicts"]["receipts"][report["storeId"]] = receipt
    brotato = HOME / "Library/Application Support/XodusCLI/proofs/passive-small-eight-v1/9P9VNSQK1W3K/receipt.json"
    if brotato.exists():
        raw = brotato.read_bytes()
        inputs["brotatoReceipt"] = {"path": str(brotato),
                                    "sha256": hashlib.sha256(raw).hexdigest(),
                                    "ownerReport": "S2 direct report 2026-10-22: TITLE_SCREEN_PASS "
                                    "only, forced exact-prefix shutdown; no gameplay/save/relaunch"}
    inputs["passiveVerdicts"] = {}
    for receipt in sorted((HOME / "Library/Application Support/XodusCLI/proofs/passive-small-eight-v1").glob("*/receipt.json")):
        record = source(receipt)
        data = record["snapshot"]
        verdict = data.get("visual_classification")
        if verdict == "NO_TITLE_SCREEN":
            inputs["passiveVerdicts"][receipt.parent.name] = {
                "verdict": verdict, "path": record["path"], "sha256": record["sha256"],
                "runId": data["result"]["run_id"]}
    spec = S1 / "retention-passive-batches.md"
    inputs["retentionSpec"] = {"path": str(spec), "sha256": hashlib.sha256(spec.read_bytes()).hexdigest(),
                               "reportedCommit": "dfe6ad5"}
    return build(inputs, previous)


def render(packet):
    lines = ["# Path to 20", "",
             f"Updated {packet['updatedAt']}; **{packet['strictWorkingCount']}/20 strict WORKING**. "
             "Title qualification is separate from production app UI acceptance. `?` means unverified, not failed.", "",
             "| Title | Verdict | Menu | Gameplay | Quit | Relaunch | Save | Next gate / owner | Blocker / packet | Stuck |",
             "|---|---|---|---|---|---|---|---|---|---|"]
    for row in packet["items"]:
        marks = [{"passed": "passed", "not-passed": "not passed"}.get(
            row["gates"][gate]["status"], "?") for gate in GATES]
        lines.append("| " + " | ".join([row["title"], row["verdict"], *marks,
                     row["nextGate"] + " / " + row["ownerStream"],
                     (str(row["blocker"]) if row["blocker"] else "Admitted matrix").replace(
                         "|", "/").replace("\n", " "),
                     ">2h" if row["stuckOver2Hours"] else "-"]) + " |")
    lines.extend(["", packet["policy"], "", "Full blockers, source hashes and packet "
                  "references are in `path-to-20-v1.json`. Stall time starts at the "
                  "first tracker observation; earlier unknown age is not reported as zero."])
    audit = packet["collectionInputs"].get("attemptEvidence")
    if audit:
        coverage = audit.get("coverage", {})
        lines.extend(["", "## Retained attempt evidence", "",
                      "Audit " + audit["auditedAt"] + ". " + audit["scope"], "",
                      f"Coverage: {coverage.get('titleCount', '?')} titles, "
                      f"{coverage.get('launchResultAttempts', '?')} launch-result attempts, "
                      f"{coverage.get('unresolvedReferenceCount', '?')} unresolved references; "
                      f"{coverage.get('presentArtifacts', '?')} present / "
                      f"{coverage.get('missingArtifacts', '?')} missing artifact links. "
                      "This is bounded discovery, not a complete historical archive.", "",
                      audit["retentionPolicy"], "",
                      "Exact run identities, artifact paths/hashes, failed-hypothesis context and "
                      "explicit gaps: `collectionInputs.attemptEvidence` in the same JSON index. "
                      "Shared proof-root artifacts are context, not automatically attributed to a run.", "",
                      "| Title / product | Indexed attempts | Identity/link gaps |",
                      "|---|---|---|"])
        for sid, title in sorted(audit["titles"].items()):
            count = sum(bool(attempt["gaps"]) for attempt in title["attempts"])
            lines.append(f"| {title['title']} / `{sid}` | {len(title['attempts'])} | "
                         f"{count} attempts incomplete; title hypothesis/test annotations incomplete |")
    (DATA / "path-to-20-v1.md").write_text("\n".join(lines) + "\n")
    text = SUMMARY.read_text()
    text = re.sub(r"\*\*Goal: 20 genuinely WORKING titles; current count: \d+\.\*\*",
                  f"**Goal: 20 genuinely WORKING titles; current count: {packet['strictWorkingCount']}.**", text)
    text = re.sub(r"Frozen snapshot: \d+ WORKING, \d+ TITLE_SCREEN,\n\d+ BLOCKED, \d+ UNTESTED\.",
                  "Current living counts and per-title gates: `path-to-20-v1.json`.", text)
    text = text.replace("**Halls / Abiotic:** title screens only; gameplay/retention remain.",
                        "**Halls:** now WORKING. **Abiotic:** title screen only; gameplay/retention remain.")
    marker = "\n<!-- living-tracker:start -->"
    text = text.split(marker)[0].rstrip()
    working = ", ".join(row["title"] for row in packet["items"] if row["strictWorking"])
    stuck = ", ".join(row["title"] for row in packet["items"] if row["stuckOver2Hours"]) or (
        "none observed yet; pre-tracker gate ages unknown")
    text += (marker + f"\nLiving tracker {packet['updatedAt']}: "
             f"**{packet['strictWorkingCount']}/20** strict: {working}. "
             "Installed-route-equivalent title qualification is not GUI Play-click proof "
             "or production UI acceptance; see per-title scope. "
             f"Same-gate >2h: {stuck}. Refresh every30min and owner verdict.\n"
             "<!-- living-tracker:end -->\n")
    SUMMARY.write_text(text)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--refresh", action="store_true")
    parser.add_argument("--audit-evidence", action="store_true",
                        help="Hash retained local launch evidence into the existing tracker; no execution")
    args = parser.parse_args()
    if args.refresh:
        packet = refresh(audit_evidence=args.audit_evidence)
        OUTPUT.write_text(json.dumps(packet, indent=2, ensure_ascii=True) + "\n")
        render(packet)
        from build_morning_burndown import refresh as refresh_burndown, render_summary
        render_summary(refresh_burndown(packet))
    else:
        packet = load_json(OUTPUT)
        previous = {"items": packet["items"]}
        if packet != build(packet["collectionInputs"], previous):
            raise ValueError("Living tracker does not reproduce")
    print("Strict", packet["strictWorkingCount"], "Stuck",
          [row["title"] for row in packet["items"] if row["stuckOver2Hours"]])


if __name__ == "__main__":
    main()
