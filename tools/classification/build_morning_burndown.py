#!/usr/bin/env python3
"""Read existing receipts and model conditional serial qualification capacity."""

import datetime as dt
import hashlib
import json
import math
from pathlib import Path
import statistics

from inspect_queue import DATA, load_json

PROOFS = Path.home() / "Library/Application Support/XodusCLI/proofs"
OUTPUT = DATA / "morning-burndown-v1.json"
DEADLINE = "2026-10-23T13:26:00+03:00"


def read_result(directory, run):
    path = PROOFS / directory / "runs" / run / "result.json"
    raw = path.read_bytes()
    data = json.loads(raw)
    return {"path": str(path), "sha256": hashlib.sha256(raw).hexdigest(),
            "startedAt": data["started_at"], "finishedAt": data["finished_at"],
            "runId": data["run_id"]}


def calculate(inputs):
    minutes = (dt.datetime.fromisoformat(inputs["deadline"]) -
               dt.datetime.fromisoformat(inputs["asOf"])).total_seconds() / 60
    cycles = []
    for sample in inputs["samples"]:
        elapsed = (dt.datetime.fromisoformat(sample["finish"]["finishedAt"]) -
                   dt.datetime.fromisoformat(sample["start"]["startedAt"])).total_seconds() / 60
        if elapsed <= 0:
            raise ValueError("Cycle must have positive measured duration")
        cycles.append({**sample, "minutes": elapsed})
    timings = [row["minutes"] for row in cycles]
    scenarios = []
    needed = max(0, 20 - inputs["strictWorkingCount"])
    for label, cycle in [("slow observed", max(timings)), ("sample midpoint", statistics.median(timings)),
                         ("fast observed", min(timings))]:
        slots = math.floor(max(0, minutes) / cycle)
        additions = min(slots, len(inputs["queued"]))
        total = inputs["strictWorkingCount"] + additions
        scenarios.append({"label": label, "minutesPerTitle": cycle,
                          "serialCycleSlots": slots, "queueCappedAdditions": additions,
                          "conditionalTotalWorking": total, "gapTo20": max(0, 20 - total),
                          "minimumPassRateRawSlots": needed / slots if slots else None,
                          "minimumPassRateCurrentQueue": needed / additions if additions else None,
                          "targetPossibleCurrentQueue": additions >= needed})
    attempted = inputs["attemptedMatrixRows"]
    matrix_passed = sum(row["verdict"] == "WORKING" for row in attempted)
    passed = inputs["strictWorkingCount"]
    reached_menu = sum(row["verdict"] in {"WORKING", "WORKING_CANDIDATE",
                                         "GAMEPLAY_PASS", "TITLE_SCREEN_ONLY", "TITLE_SCREEN_PASS"} for row in attempted)
    intervals = {}
    for sample in inputs["phaseRuns"]:
        runs = sample["runs"]
        active = sum((dt.datetime.fromisoformat(row["finishedAt"]) -
                      dt.datetime.fromisoformat(row["startedAt"])).total_seconds() / 60
                     for row in runs)
        span = (dt.datetime.fromisoformat(runs[-1]["finishedAt"]) -
                dt.datetime.fromisoformat(runs[0]["startedAt"])).total_seconds() / 60
        intervals[sample["title"]] = {"betweenRecordedRunsMinutes": span - active,
                                       "recordedRunMinutes": active}
    between = sum(row["betweenRecordedRunsMinutes"] for row in intervals.values())
    phase_totals = {"between recorded runs": between}
    for sample in inputs["phaseRuns"]:
        for run in sample["runs"]:
            phase_totals[run["phase"]] = phase_totals.get(run["phase"], 0) + (
                dt.datetime.fromisoformat(run["finishedAt"]) -
                dt.datetime.fromisoformat(run["startedAt"])).total_seconds() / 60
    return {"schemaVersion": 1, "inputs": inputs, "observedCycles": cycles,
            "remainingWallMinutes": minutes, "scenarios": scenarios,
            "observedAdmissionRatio": {"working": passed, "matrixWorking": matrix_passed,
                                       "attemptedMatrix": len(attempted),
                                       "ratio": matrix_passed / len(attempted) if attempted else None,
                                       "receiptAugmentedAttempted": len(inputs["attemptedTrackerRows"]),
                                       "receiptAugmentedRatio": passed / len(inputs["attemptedTrackerRows"]),
                                       "titleScreenOrBeyond": reached_menu,
                                       "postTitleScreenAdmissionRatio": matrix_passed / reached_menu if reached_menu else None,
                                       "meaning": "Snapshot WORKING/attempted, not a probability or final failure "
                                       "rate. Incomplete and CLI-held attempts remain denominator; "
                                       "native Minecraft included as admitted matrix row."},
            "timeSink": {"byTitle": intervals, "phaseTotalsMinutes": phase_totals,
                         "largestCategory": max(phase_totals, key=phase_totals.get),
                         "minutesPerAddition": max(phase_totals.values()) / len(intervals),
                         "limitation": "Between-run gaps are unallocated wall time, NOT proven "
                         "screen/operator waiting. Run spans mix startup/play/input/save; no "
                         "reliable finer split. Largest aggregate category across two cycles, "
                         "not a universal per-title bottleneck."},
            "requiredAverageMinutesPerAddition": minutes / max(1, 20 - inputs["strictWorkingCount"]),
            "interpretation": "Estimate of capacity, NOT expected successful verdicts or a "
            "confidence interval. One exact passive-to-strict cycle (Halls), one broader "
            "title-probe-to-strict proxy (Hogwarts; passive unavailable). These overlap "
            "in wall time; their durations include handoffs, cache/retry and waits, not exclusive "
            "operator effort. Assume one serial qualification lane, continuous focus availability "
            "until deadline, unchanged disk/recipes and every counted queue attempt succeeds. "
            "No measured success probability or working-hours budget exists. "
            "Guaranteed/admitted total remains current strict count. Failures, sleep and holds "
            "reduce totals; dry packets are queued, NOT launch-admitted or WORKING-ready.",
            "blockerClasses": inputs["blockerClasses"]}


def refresh(tracker):
    exclusions = {"9P9VNSQK1W3K": "CLI promotion; candidate not strict",
                  "9P8NSTDMZ11P": "NO_TITLE_SCREEN; startup diagnosis",
                  "9PLH7R84GJWP": "actual gameplay reached; TIMEOUT, no save marker; parked",
                  "9NH0MSG29X6L": "S3-only CRT/STA diagnostic route; excluded passive"}
    queued, withheld, sources = {}, {}, []
    for batch in ("passive-small-eight-v1", "passive-batch2-eight-v1", "passive-batch3-eight-v1"):
        path = PROOFS / batch / "packets.json"
        raw = path.read_bytes()
        sources.append({"path": str(path), "sha256": hashlib.sha256(raw).hexdigest()})
        for row in json.loads(raw)["items"]:
            sid = row["storeId"]
            item = {"storeId": sid, "title": row["title"], "batch": batch}
            if sid in exclusions and not any(
                    item["storeId"] == sid and item["strictWorking"] for item in tracker["items"]):
                withheld[sid] = {**item, "blocker": exclusions[sid]}
            else:
                queued[sid] = item
    working = {row["storeId"] for row in tracker["items"] if row["strictWorking"]}
    additions = tracker["collectionInputs"].get("ownerVerdicts", {}).get(
        "snapshot", {}).get("queueAdditions")
    if additions:
        for row in additions["items"]:
            queued.setdefault(row["storeId"], row)
    queued = {sid: row for sid, row in queued.items() if sid not in working}
    inputs = {"asOf": tracker["updatedAt"], "deadline": DEADLINE,
              "timezoneInterpretation": "User extended deadline by 12 hours to "
              "23 October 13:26 EEST (UTC+03), not UTC; coordinator reported "
              "2026-10-22T06:02:34.865Z.",
              "strictWorkingCount": tracker["strictWorkingCount"],
              "trackerMatrixSha256": tracker["collectionInputs"]["matrix"]["sha256"],
              "packetSources": sources, "queued": list(queued.values()),
              "pendingPacketQueueEvidence": additions,
              "queueReconciliation": {
                  "reportedCap": additions["reportedQueueCap"] if additions else None,
                  "uniqueCount": len(queued),
                  "basis": additions["basis"] if additions else
                  "Deduplicate product IDs across packets."},
              "withheld": list(withheld.values()),
              "samples": [
                  {"title": "Halls of Torment", "startKind": "actual no-input passive",
                   "start": read_result("passive-sta-9NMNMS626R59-small-noargs",
                                        "3f10098a-1cfe-4312-9877-d2c6a032b8a3"),
                   "finish": read_result("s3-halls-retention-02",
                                         "5b39beb9-62b4-4241-9330-33422bbccafd")},
                  {"title": "Hogwarts Legacy", "startKind": "earliest bound STA title probe; "
                   "not independently asserted no-input passive; broader proxy cycle",
                   "start": read_result("hogwarts-apple4-sta",
                                        "5b4e4975-2a36-4b14-8da4-72ba52e4fc7c"),
                   "finish": read_result("s3-hogwarts-sta-quit-04",
                                         "f2471368-2523-4578-8eb8-75c8d4db7040")}],
              "endpointPolicy": "End = final qualifying process exit for an admitted WORKING "
              "matrix row, not time of coordinator message or file mtime. Minecraft lacks "
              "a passive cycle; HK/NMS lack a paired comparable passive start here. "
              "Brotato is not strict; Inscryption is an observed failure, not a completed cycle.",
              "blockerClasses": {
                  "catalogue": {"count": 8, "gate": "entitlement + disk + batch approval; "
                                "membership alone insufficient; closed, not baseline capacity"},
                  "CLI promotion": {"count": 1, "title": "Brotato", "gate": "user promotion/admission; "
                                    "new matrix proves all title gates, no fresh full cycle assumed"},
                  "engine/recipe": {"count": 2, "titles": ["Inscryption", "Well Dweller"],
                                    "gate": "Inscryption end-queue retry hold; Well gameplay "
                                    "TIMEOUT/no save marker parked. Mixtape now WORKING. "
                                    "Not confirmed common engine root cause or retry grants."}}}
    inputs["candidateComparisonExcludedFromStrictSamples"] = {
        "title": "Brotato", "status": "WORKING_CANDIDATE; CLI promotion only",
        "start": read_result("passive-small-eight-v1/9P9VNSQK1W3K",
                             "c2e01ff4-e716-402e-b144-7a7aafdc1ca2"),
        "finish": read_result("s3-brotato-retention-02",
                              "430e9c33-7b7e-47d8-838f-d154a8fb1f48")}
    not_attempted = {"UNTESTED", "NOT_TESTED", "BLOCKED"}
    inputs["attemptedMatrixRows"] = [
        {"storeId": row["productId"], "title": row["title"], "verdict": row["verdict"]}
        for row in tracker["collectionInputs"]["matrix"]["snapshot"]["games"]
        if row["verdict"] not in not_attempted]
    inputs["attemptedTrackerRows"] = [
        {"storeId": row["storeId"], "title": row["title"], "verdict": row["verdict"]}
        for row in tracker["items"] if row["verdict"] not in not_attempted]
    inputs["attemptDefinition"] = "Unique title with an actual matrix attempt, including startup "
    inputs["attemptDefinition"] += "FAIL, title-screen, gameplay, candidate and WORKING; exclude "
    inputs["attemptDefinition"] += "NOT_TESTED/UNTESTED and inventory BLOCKED without execution. "
    inputs["attemptDefinition"] += "Also show tracker augmentation for passive receipts or owner-reported verdicts not yet in matrix."
    def phase(directory, run, label):
        return {**read_result(directory, run), "phase": label}
    inputs["phaseRuns"] = [
        {"title": "Halls of Torment", "runs": [
            {**inputs["samples"][0]["start"], "phase": "initial title probe"},
            phase("s3-halls-world-01", "8d7ea6ba-ec75-4cb1-8b96-7300bd467159", "world/progress run"),
            {**inputs["samples"][0]["finish"], "phase": "retention/relaunch run"}]},
        {"title": "Hogwarts Legacy", "runs": [
            {**inputs["samples"][1]["start"], "phase": "initial title probe"},
            phase("s3-hogwarts-sta-world-02", "891d061f-4820-4cd3-9b61-efefa5700be9", "world/progress run"),
            phase("s3-hogwarts-sta-retention-03", "86e8da68-f4b0-48f8-bf7a-46e577ff3488", "retention/relaunch run"),
            {**inputs["samples"][1]["finish"], "phase": "quit-only run"}]}]
    rc = Path("/Users/dragoshont/src/copilot-worktrees/xodus-macos-app/dragoshont-super-spork/.build/local-candidates/Ode-switchover-rewcsnje/switch-over-receipt.json")
    inputs["installedRcReceipt"] = {"path": str(rc), "sha256": hashlib.sha256(rc.read_bytes()).hexdigest(),
                                    "revision": "42f793d", "installed": True}
    packet = calculate(inputs)
    OUTPUT.write_text(json.dumps(packet, indent=2) + "\n")
    return packet


def render_summary(packet):
    path = DATA / "morning-summary-draft-v2.md"
    text = path.read_text().split("\n<!-- burndown:start -->")[0].rstrip()
    slow, mid, fast = packet["scenarios"]
    samples = packet["observedCycles"]
    text += ("\n<!-- burndown:start -->\n## Burn-down estimate (not promised passes)\n\n"
             f"Deadline **23 Oct 13:26 EEST** (user +12h extension); {packet['remainingWallMinutes'] / 60:.2f}h "
             f"from {packet['inputs']['asOf']}. Halls passive-to-qualified: "
             f"**{samples[0]['minutes']:.1f}min**; Hogwarts title-probe-to-qualified proxy: "
             f"**{samples[1]['minutes']:.1f}min** (no bound passive start). "
             f"One serial, continuously available lane yields **{slow['serialCycleSlots']}"
             f"/{mid['serialCycleSlots']}/{fast['serialCycleSlots']}** slow/mid/fast cycles, "
             f"capped by **{len(packet['inputs']['queued'])} pipeline titles** "
             "(historical deduplicated packet baseline, not an executable queue): "
             f"conditional totals **{slow['conditionalTotalWorking']}/"
             f"{mid['conditionalTotalWorking']}/{fast['conditionalTotalWorking']}**. "
             "These all-pass capacity ceilings assume uninterrupted focus; not predicted successes.\n\n"
             f"Need **{20 - packet['inputs']['strictWorkingCount']}** additions; slow scenario "
             f"leaves **{slow['gapTo20']}**. Required mean: "
             f"**{packet['requiredAverageMinutesPerAddition']:.1f}min/addition**. "
             "Brotato CLI promotion can add one without another full cycle. "
             "Qualification/recipe holds (Inscryption/Well) and eight catalogue titles "
             "(entitlement/disk/approval) are excluded alternatives, not extra time. "
             "Historical packet count is not proof of executable capacity; parked/failed "
             "routes still need their gates resolved. "
             "Inputs/hashes: `morning-burndown-v1.json`; "
             "S1 spec `dfe6ad5`, `retention-passive-batches.md`.\n"
             f"\nObserved admission ratio: **{packet['observedAdmissionRatio']['matrixWorking']}/"
             f"{packet['observedAdmissionRatio']['attemptedMatrix']} matrix attempts "
             f"({packet['observedAdmissionRatio']['ratio']:.1%})**; including receipt/owner-reported "
             f"attempts: **{packet['observedAdmissionRatio']['working']}/"
             f"{packet['observedAdmissionRatio']['receiptAugmentedAttempted']} "
             f"({packet['observedAdmissionRatio']['receiptAugmentedRatio']:.1%})**. "
             f"Matrix post-title-screen subset: **{packet['observedAdmissionRatio']['matrixWorking']}/"
             f"{packet['observedAdmissionRatio']['titleScreenOrBeyond']}**. "
             "Unfinished tests included; no probabilities. Minimum "
             "pass rates slow/mid/fast: **" + "/".join(
                 f"{row['minimumPassRateCurrentQueue']:.1%}" if row["minimumPassRateCurrentQueue"] is not None
                 else "impossible" for row in packet["scenarios"]) +
             "** of queue-capped attempts (>100% would be impossible). Fast raw-slot threshold "
             f"{fast['minimumPassRateRawSlots']:.1%} requires more eligible titles than current queue.\n\n"
             f"Biggest measured time sink: **between-run gaps, "
             f"{packet['timeSink']['phaseTotalsMinutes']['between recorded runs']:.1f}min total / "
             f"{packet['timeSink']['minutesPerAddition']:.1f}min per addition** across Halls/Hogwarts. "
             "Unallocated, not proven screen waiting; operator/other waits and "
             "within-run startup/play/save splits unavailable.\n"
             "<!-- burndown:end -->\n")
    path.write_text(text)


if __name__ == "__main__":
    import sys
    packet = refresh(load_json(DATA / "path-to-20-v1.json")) if "--refresh" in sys.argv else load_json(OUTPUT)
    if packet != calculate(packet["inputs"]):
        raise ValueError("Burn-down does not reproduce")
    print([(row["label"], row["conditionalTotalWorking"], row["gapTo20"])
           for row in packet["scenarios"]])
