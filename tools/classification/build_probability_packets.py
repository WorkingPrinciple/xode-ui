#!/usr/bin/env python3
"""Build an ordinal, source-bound test priority packet offline; no launches."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json

from inspect_queue import DATA, load_json


# Ordinal judgment, not a measured probability or a game acceptance result.
ASSESSMENTS = [
    (18, "higher-proxy-confidence", "CrossOver perfect plus Proton Platinum; DX9 and a documented Store save path. Legacy UE3 primary-runtime consumption remains unproved."),
    (14, "higher-proxy-confidence", "CrossOver/Wine perfect plus a large Proton Gold sample; established DX11 route. Store save directory and Xbox behavior still unproved."),
    (7, "higher-proxy-confidence", "Large Proton Platinum sample and OpenGL route. Native Mac perfect is contextual only: CrossOver is unknown, and native success is not the Windows Store route."),
    (6, "higher-proxy-confidence", "CrossOver playable plus Proton Platinum; DX9 route. AppleGamingWiki explicitly reports low FPS, so a smoke launch alone cannot qualify it."),
    (13, "higher-proxy-confidence", "CrossOver/Wine playable, GPTK 2 and Whisky device reports, Proton Gold. Some report notes mention crashes; saving has Schnapps/bed/exit constraints."),
    (15, "higher-proxy-confidence", "CrossOver perfect, Wine playable and large Proton Gold sample; DX11. Existing local state is launcher-only/input-unexercised, not WORKING."),
    (5, "higher-proxy-confidence", "CrossOver perfect and large Proton Platinum sample with OpenGL. Native Mac perfect is not evidence for the Xbox package; anti-cheat classification remains unknown."),
    (1, "required-with-blocker-risk", "REQUIRED Hogwarts: CrossOver/Wine perfect and Proton Gold support a bounded test. Steam explicitly lists Denuvo; Microsoft Store entitlement/runtime path is separate and unqualified."),
    (25, "moderate-proxy-confidence", "CrossOver perfect with an explicit CrossOver 25 Early Access PC report (report store unspecified) and Proton Platinum, albeit a small Proton sample. Best uninstalled Mac-specific proxy; DX12/Store runtime and sign-in remain unproved."),
    (3, "moderate-proxy-confidence", "Proton Platinum with strong confidence; DX12. No verified AppleGamingWiki rating at attempted page, so Linux success is a weaker Mac proxy."),
    (16, "moderate-proxy-confidence", "Pixel Remaster Steam ID 1173800 is Proton Platinum; simpler GL candidate profile, but public DX10 requirement makes active renderer uncertain. Not the 3D remake."),
    (8, "moderate-proxy-confidence", "Proton Platinum with strong confidence and DX11 target; no Mac-specific rating found at attempted title page. Store WGS save path is documented."),
    (29, "moderate-proxy-confidence", "Large, strong Proton Platinum sample, but no verified Mac-specific rating; DX12. Sequel evidence is not substituted for the first game."),
    (17, "moderate-proxy-confidence", "Proton Gold with moderate confidence and a small sample; DX11 candidate. Unity OpenGL imports do not establish the active renderer or Store saves."),
    (10, "moderate-proxy-confidence", "Large Proton Platinum sample, but Unreal DX12 Early Access and no title-specific Mac rating. Title-only COM-STA candidate already in v2; runtime/gameplay still unproved."),
    (21, "moderate-proxy-confidence", "Proton Platinum with strong confidence, but no Mac-specific rating; Unreal DX12/primary-runtime COM risk. Known Store WGS path; candidate COM environment unchanged."),
    (22, "moderate-proxy-confidence", "Proton Platinum with good confidence and a small sample; no Mac-specific rating. Unreal DX12 COM candidate and known WGS path, not tested gameplay."),
    (27, "moderate-proxy-confidence", "Proton Platinum with strong confidence; no verified Mac-specific rating. DX12 and unknown Store anti-cheat/runtime behavior remain."),
    (28, "moderate-proxy-confidence", "Proton Platinum with good confidence and a small sample; no verified Mac-specific rating. DX12/Store behavior and anti-cheat remain unknown."),
    (9, "lower-or-conflicting-proxy-confidence", "Proton Gold but no verified Mac-specific rating. Unreal DX12/primary-runtime COM candidate and known WGS path; no observed renderer or save."),
    (4, "lower-or-conflicting-proxy-confidence", "Only eight Proton reports despite Platinum; no verified Mac-specific rating. Existing diagnosed-profile retest remains separate from never-launched sixteen."),
    (24, "lower-or-conflicting-proxy-confidence", "Proton Gold with moderate confidence and a small sample; no verified Mac rating. Deferred for disk, not dropped; do not reserve installer space from rating alone."),
    (20, "lower-or-conflicting-proxy-confidence", "Newer CrossOver perfect report conflicts with older Wine unplayable/graphics feature-tier failure; Proton Silver and Steam Denuvo. Keep below clean proxies, not declared impossible."),
    (11, "lower-or-conflicting-proxy-confidence", "Proton Gold, but AppleGamingWiki CrossOver playable headline conflicts with launcher failure; GPTK report has low FPS/freezing. Original 2009 edition, not Remastered."),
    (19, "unmeasured-proxy", "No Proton summary or verified Mac rating from attempted sources; DX12. Store path known, but package readiness cannot substitute for compatibility evidence."),
    (23, "unmeasured-proxy", "No Proton summary or verified Mac rating from attempted sources; new Unreal DX11 title. COM candidate is prophylactic, not evidence it works."),
    (30, "unmeasured-proxy", "No Proton summary or verified Mac rating from attempted 2026 title page. Do not use original Fable/Fable Anniversary compatibility as evidence."),
    (26, "mac-negative-proxy", "AppleGamingWiki CrossOver and Wine unplayable, with AVX/startup reports despite Proton Gold. Linux x86 success does not resolve Apple Silicon CPU/translation requirements; no bypass recommended."),
    (2, "separate-native-route", "AppleGamingWiki native perfect but CrossOver unplayable; native Mac result is not Xbox MSIXVC qualification. Existing S1/S3 NMS lane must not be changed by this research."),
    (12, "separate-native-route", "Java Edition has native/Rosetta perfect and CrossOver unplayable; no matching Steam Proton tier. Preserve the separately approved native launcher exception, not a new MSIXVC Wine success."),
]
HOGWARTS = "9MT5NJ5W7B8Z"


def digest(name):
    return hashlib.sha256((DATA / name).read_bytes()).hexdigest()


def build():
    queue = load_json(DATA / "next-30-queue.json")["items"]
    by_rank = {row["rank"]: row for row in queue}
    proxies = load_json(DATA / "wine-proxy-evidence-v1.json")["items"]
    by_id = {row["storeId"]: row for row in proxies}
    base = load_json(DATA / "s3-ready-packets-v2.json")
    ready = {row["storeId"]: row for row in base["items"]}
    catalogue = load_json(DATA / "game-compatibility-v1.json")["products"]
    if {rank for rank, _, _ in ASSESSMENTS} != set(by_rank) or len(ASSESSMENTS) != 30:
        raise ValueError("Assessments must cover the exact thirty-title queue once")
    items = []
    for order, (rank, tier, reason) in enumerate(ASSESSMENTS, 1):
        queue_row = by_rank[rank]
        store_id = queue_row["storeId"]
        proxy = by_id[store_id]
        if proxy["originalRank"] != rank or proxy["title"] != queue_row["title"]:
            raise ValueError(f"{store_id}: proxy/queue identity mismatch")
        row = copy.deepcopy(ready.get(store_id, {}))
        row.update({
            "storeId": store_id, "title": queue_row["title"],
            "originalQueueRank": rank, "likelihoodOrder": order,
            "likelihoodTier": tier, "likelihoodBasis": reason,
            "numericProbability": None,
            "requiredAcceptance": store_id == HOGWARTS,
            "inFrozenSixteen": store_id in ready,
            "compatibilityEvidence": copy.deepcopy(proxy),
            "antiCheat": queue_row["antiCheat"],
            "antiCheatEvidence": copy.deepcopy(
                catalogue[store_id].get("antiCheatEvidence")
            ),
            "antiCheatScope": "Existing classification, not reclassified by this "
            "packet. Unknown is not none; absence of an AWACY/path match is not "
            "affirmative absence. Test priority does not set supported01.",
            "graphicsAPI": queue_row["api"],
            "apiEvidenceSource": queue_row["apiEvidenceSource"],
            "downloadSizeBytes": queue_row["downloadSizeBytes"],
            "downloadSizeEvidence": queue_row["downloadSizeEvidence"],
            "alreadyInstalled": queue_row["alreadyInstalled"],
            "reportedGameRoot": queue_row.get("installRoot"),
            "stagingStatus": queue_row.get("stagingStatus"),
            "blockers": [],
        })
        apple = proxy["appleGamingWiki"]
        ratings = apple["ratings"]
        refs = apple["methodReferences"]
        row["macOSMethodSummary"] = {
            "crossOverRating": ratings.get("crossover"),
            "gptkRating": ratings.get("game porting toolkit", ratings.get("gptk")),
            "whiskyRating": ratings.get("whisky"),
            "gptkReportPresent": any(
                "gptk" in (ref.get("version") or "").lower()
                or "game porting toolkit" in (ref.get("method") or "").lower()
                for ref in refs
            ) or any(signal["mentionsGPTK"] for signal in apple["noteSignals"].values()),
            "whiskyReportPresent": any(
                "whisky" in (ref.get("method") or "").lower() for ref in refs
            ) or any(signal["mentionsWhisky"] for signal in apple["noteSignals"].values()),
            "source": apple["url"], "checkedAt": apple["checkedAt"],
            "scope": "AppleGamingWiki Windows PC methods, not CodeWeavers DB. "
            "A report-present flag is not a separate GPTK/Whisky rating. "
            "Null means not established, including missing/challenged pages.",
        }
        steam = proxy["steamDRM"]
        row["drm"] = {
            "knownSteamNotice": steam.get("drmNotice") if steam else None,
            "knownExternalAccountNotice": steam.get("externalAccountNotice") if steam else None,
            "source": steam["url"] if steam else "https://www.minecraft.net/",
            "checkedAt": steam["checkedAt"] if steam else apple["checkedAt"],
            "scope": "Steam PC proxy only; a missing notice does not establish "
            "DRM-free status or Microsoft Store entitlement/sign-in behavior.",
            "xboxDRMQualified": False,
        }
        if steam and steam.get("drmNotice"):
            row["blockers"].append({
                "kind": "drm-risk-not-proven-hard-block",
                "detail": steam["drmNotice"] + "; explicitly Steam proxy. "
                "Do not bypass DRM or infer Xbox package outcome.",
                "url": steam["url"], "checkedAt": steam["checkedAt"],
            })
        if rank == 26:
            row["blockers"].append({
                "kind": "public-mac-cpu-startup-failure",
                "detail": "AppleGamingWiki reports AVX requirement and startup "
                "failures. Reports include internally inconsistent dates/hardware; "
                "retain as dated negative proxy, not a current-engine verdict. "
                "No binary, DRM or AVX bypass is authorized.",
                "url": apple["url"], "checkedAt": apple["checkedAt"],
            })
        if rank == 20:
            row["blockers"].append({
                "kind": "conflicting-version-dependent-graphics-reports",
                "detail": "2023 Wine report fails tiled-resources feature tier; "
                "2026 report says CrossOver Preview December 2025 works. Neither "
                "is the exact adf8/Apple4/7106 Xbox recipe.",
                "url": apple["url"], "checkedAt": apple["checkedAt"],
            })
            row["blockers"].append({
                "kind": "public-account-requirement",
                "detail": "PCGamingWiki states all PC versions require a "
                "Bethesda.net account and Denuvo, with the Microsoft Store "
                "edition explicitly listed. This is a public claim, not an "
                "observed Store entitlement/runtime test or an anti-cheat name.",
                "url": "https://www.pcgamingwiki.com/wiki/Deathloop?action=raw",
                "checkedAt": "2026-10-22",
            })
        if rank == 11:
            row["blockers"].append({
                "kind": "headline-versus-report-conflict",
                "detail": "CrossOver playable headline versus 2021 launcher crash; "
                "2023 GPTK 10-15 FPS/freeze report. Do not rank as clean playable "
                "from the headline alone or apply its legacy prefix instructions.",
                "url": apple["url"], "checkedAt": apple["checkedAt"],
            })
        if rank == 6:
            row["blockers"].append({
                "kind": "public-performance-risk",
                "detail": "2023 CrossOver 21/M1 report describes low particle-effect "
                "FPS; Proton Platinum does not override the Mac performance risk.",
                "url": apple["url"], "checkedAt": apple["checkedAt"],
            })
        if rank == 30:
            row["blockers"].append({
                "kind": "unverified-full-game-download-size",
                "detail": "Queue catalogue size is about 60 MiB, not evidence "
                "that the full Fable payload fits. Require real current package "
                "size/release/entitlement evidence before install admission.",
                "url": queue_row["downloadSizeEvidence"]["source"],
                "checkedAt": queue_row["downloadSizeEvidence"]["checkedAt"],
            })
        if store_id in ready:
            row["blockers"].append({
                "kind": "xbox-runtime-unqualified",
                "detail": "Complete physical receipt, candidate profile and "
                "title-scoped COM environment remain v2 plans only. S3 owns "
                "input, gameplay, save and relaunch evidence.",
                "url": queue_row["signInEvidence"]["source"],
                "checkedAt": queue_row["signInEvidence"]["checkedAt"],
            })
        items.append(row)

    waiting = [row["storeId"] for row in items if row["inFrozenSixteen"]]
    if set(waiting) != set(ready) or len(waiting) != 16:
        raise ValueError("S3 order must be a permutation of all sixteen frozen packets")
    # Add, rather than displace, the explicitly required installed Hogwarts trial.
    combined = [waiting[0], HOGWARTS, *waiting[1:]]
    uninstalled = [
        row["storeId"] for row in items
        if not row["alreadyInstalled"] and row["likelihoodTier"] != "separate-native-route"
    ]
    return {
        "schemaVersion": 3, "checkedAt": "2026-10-22",
        "readOnlyCollection": True, "gameLaunches": 0,
        "sourceArtifacts": {
            name: digest(name) for name in (
                "s3-ready-packets-v2.json", "wine-proxy-evidence-v1.json",
                "next-30-queue.json", "game-compatibility-v1.json",
            )
        },
        "rankingPolicy": {
            "kind": "ordinal-expert-judgment-not-calibrated-probability",
            "basis": "Positive Windows-on-macOS reports first, then Linux Proton "
            "proxy strength/sample, API/profile complexity, explicit DRM and "
            "conflicting report risks. Within broad tiers prefer lower integration "
            "risk. Native macOS is not a Windows/MSIXVC result.",
            "limits": "Ratings come from different versions/hardware/stores. "
            "No known evidence certifies the exact adf8 + 7106 Store recipe. "
            "No numeric success probability can be justified.",
            "codeWeavers": "All attempted DB pages returned HTTP 403; RSS "
            "alternatives also failed. Rating is null, not copied from search "
            "summaries and not replaced by AppleGamingWiki's CrossOver rating. "
            "Title-derived candidate URLs do not prove database entries exist.",
            "appleGamingWiki": "Missing candidate pages mean no verified rating "
            "at that URL, not proof the wiki has no page anywhere. GPTK/Whisky "
            "report-present flags are separate from explicit rating values.",
            "protonDB": "Exact Steam app ID API tier is a Linux Wine proxy, "
            "not a macOS/Microsoft Store test. Missing tier remains null.",
            "blockerAbsence": "Unknown anti-cheat/DRM is not cleared by Proton "
            "or public Mac reports. No bypasses, registry/global COM changes "
            "or profile mutations are authorized.",
        },
        "s3TestOrder": waiting,
        "requiredHogwarts": {
            "storeId": HOGWARTS,
            "reason": "User-required acceptance trial, additional to the frozen sixteen.",
            "installStatus": None,
            "readinessGate": "Known root is not a current complete receipt. "
            "S3/S2 must gate launch on immutable adf8 install-status == complete.",
        },
        "s3OrderIncludingRequiredHogwarts": combined,
        "s3Waves": [combined[index:index + 2] for index in range(0, len(combined), 2)],
        "testExecutionPolicy": {
            "maximumConcurrentTitles": 2,
            "launchesAuthorizedByThisPacket": False,
            "preserveExistingSlot": "Do not interrupt HK/NMS/current gameplay "
            "or change their prefixes; apply order at the next available S3 slots.",
            "workingTarget": 20,
            "verifiedWorkingCount": None,
            "verifiedWorkingCountBasis": "No authoritative current acceptance "
            "count was supplied to S4. Sixteen ready roots are not sixteen WORKING.",
            "qualifiedOutcome": "Only coordinator/S3 gameplay + save/relaunch "
            "acceptance can increment WORKING; ratings, installation and launcher "
            "success never increment it. Native exception tracked separately.",
        },
        "installPriorityAfterDiskRelease": uninstalled,
        "installResumePolicy": {
            "status": "requires-current-disk-fit-and-test-capacity",
            "maximumConcurrentInstallers": 1,
            "minimumFreeGiB": 150,
            "maximumUntestedInstalledBacklog": 6,
            "resumeAutomaticallyNow": False,
            "admission": "Re-measure actual free space after S1 confirms release; "
            "reserve full next catalogue download plus staging margin above floor. "
            "Skip a non-fitting title without dropping it. Resume only when S3 "
            "backlog falls under the agreed cap; no deletions by S4.",
            "profileGate": "Prefer confirmed S1 API class; do not invent new "
            "per-title binding or edit S1 files. Coordinate missing bindings.",
            "smallPayloadGuard": "Fable's approximately 60 MiB catalogue "
            "placeholder-sized payload is not a demonstrated full game. It "
            "must not be admitted merely because that number fits.",
            "readinessGate": "After an approved install, immutable adf8 status "
            "must equal complete before S3 handoff.",
        },
        "items": items,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    packet = build()
    output = DATA / "s3-ready-packets-v3.json"
    content = json.dumps(packet, indent=2, ensure_ascii=True) + "\n"
    if args.check:
        if output.read_text() != content:
            raise SystemExit("Published packet v3 differs from its source-bound generator")
    else:
        output.write_text(content)
    by_id = {row["storeId"]: row for row in packet["items"]}
    for order, store_id in enumerate(packet["s3TestOrder"], 1):
        print(order, by_id[store_id]["title"], store_id)
    print("Required Hogwarts additional slot:", packet["requiredHogwarts"]["storeId"])
    print("Uninstalled priorities:", packet["installPriorityAfterDiskRelease"])


if __name__ == "__main__":
    main()
