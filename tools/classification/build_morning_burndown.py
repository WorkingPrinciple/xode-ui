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
DEADLINE = "2026-10-23T01:26:00+03:00"


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
    for label, cycle in [("slow observed", max(timings)), ("sample midpoint", statistics.median(timings)),
                         ("fast observed", min(timings))]:
        slots = math.floor(max(0, minutes) / cycle)
        additions = min(slots, len(inputs["queued"]))
        total = inputs["strictWorkingCount"] + additions
        scenarios.append({"label": label, "minutesPerTitle": cycle,
                          "serialCycleSlots": slots, "queueCappedAdditions": additions,
                          "conditionalTotalWorking": total, "gapTo20": max(0, 20 - total)})
    return {"schemaVersion": 1, "inputs": inputs, "observedCycles": cycles,
            "remainingWallMinutes": minutes, "scenarios": scenarios,
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
                  "9PLH7R84GJWP": "engine host probes only; actual-title retest",
                  "9NH0MSG29X6L": "S3-only CRT/STA diagnostic route; excluded passive"}
    queued, withheld, sources = {}, {}, []
    for batch in ("passive-small-eight-v1", "passive-batch2-eight-v1", "passive-batch3-eight-v1"):
        path = PROOFS / batch / "packets.json"
        raw = path.read_bytes()
        sources.append({"path": str(path), "sha256": hashlib.sha256(raw).hexdigest()})
        for row in json.loads(raw)["items"]:
            sid = row["storeId"]
            item = {"storeId": sid, "title": row["title"], "batch": batch}
            if sid in exclusions:
                withheld[sid] = {**item, "blocker": exclusions[sid]}
            else:
                queued[sid] = item
    working = {row["storeId"] for row in tracker["items"] if row["strictWorking"]}
    queued = {sid: row for sid, row in queued.items() if sid not in working}
    inputs = {"asOf": tracker["updatedAt"], "deadline": DEADLINE,
              "timezoneInterpretation": "01:26 tomorrow = 23 October EEST (UTC+03), "
              "not 01:26 UTC; measured from current 22 October morning snapshot",
              "strictWorkingCount": tracker["strictWorkingCount"],
              "trackerMatrixSha256": tracker["collectionInputs"]["matrix"]["sha256"],
              "packetSources": sources, "queued": list(queued.values()),
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
                  "engine/recipe": {"count": 3, "titles": ["Inscryption", "Well Dweller", "Mixtape"],
                                    "gate": "diagnosis/retest or S3-only diagnostic recipe; "
                                    "not confirmed common engine root cause"}}}
    inputs["candidateComparisonExcludedFromStrictSamples"] = {
        "title": "Brotato", "status": "WORKING_CANDIDATE; CLI promotion only",
        "start": read_result("passive-small-eight-v1/9P9VNSQK1W3K",
                             "c2e01ff4-e716-402e-b144-7a7aafdc1ca2"),
        "finish": read_result("s3-brotato-retention-02",
                              "430e9c33-7b7e-47d8-838f-d154a8fb1f48")}
    packet = calculate(inputs)
    OUTPUT.write_text(json.dumps(packet, indent=2) + "\n")
    return packet


def render_summary(packet):
    path = DATA / "morning-summary-draft-v2.md"
    text = path.read_text().split("\n<!-- burndown:start -->")[0].rstrip()
    slow, mid, fast = packet["scenarios"]
    samples = packet["observedCycles"]
    text += ("\n<!-- burndown:start -->\n## Burn-down estimate (not promised passes)\n\n"
             f"Deadline **23 Oct 01:26 EEST**; {packet['remainingWallMinutes'] / 60:.2f}h "
             f"from {packet['inputs']['asOf']}. Halls passive-to-qualified: "
             f"**{samples[0]['minutes']:.1f}min**; Hogwarts title-probe-to-qualified proxy: "
             f"**{samples[1]['minutes']:.1f}min** (no bound passive start). "
             f"One serial, continuously available lane yields **{slow['serialCycleSlots']}"
             f"/{mid['serialCycleSlots']}/{fast['serialCycleSlots']}** slow/mid/fast cycles, "
             f"capped by **{len(packet['inputs']['queued'])} queued dry packets**: "
             f"conditional totals **{slow['conditionalTotalWorking']}/"
             f"{mid['conditionalTotalWorking']}/{fast['conditionalTotalWorking']}**. "
             "Every attempted title must pass; sleep, focus, disk and failures reduce this. "
             "No probability assumed; only current admitted count is assured.\n\n"
             f"Need **{20 - packet['inputs']['strictWorkingCount']}** additions; slow scenario "
             f"leaves **{slow['gapTo20']}**. Required mean: "
             f"**{packet['requiredAverageMinutesPerAddition']:.1f}min/addition**. "
             "Brotato CLI promotion can add one without another full cycle. "
             "Engine/recipe fixes (Inscryption/Well/Mixtape) and eight catalogue "
             "titles (entitlement/disk/install approval) add alternatives, not time. "
             "Existing queue already covers 15; catalogue expansion alone cannot cure "
             "the slow-rate gap. All these blocked lanes are excluded. "
             "Inputs/hashes: `morning-burndown-v1.json`; "
             "S1 retention spec `dfe6ad5`, `retention-passive-batches.md`.\n"
             "<!-- burndown:end -->\n")
    path.write_text(text)


if __name__ == "__main__":
    import sys
    packet = refresh(load_json(DATA / "path-to-20-v1.json")) if "--refresh" in sys.argv else load_json(OUTPUT)
    if packet != calculate(packet["inputs"]):
        raise ValueError("Burn-down does not reproduce")
    print([(row["label"], row["conditionalTotalWorking"], row["gapTo20"])
           for row in packet["scenarios"]])
