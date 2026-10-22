#!/usr/bin/env python3
"""Collect read-only launch planning packets; never launch or prepare a prefix."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import shlex
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

from inspect_queue import DATA, load_json
from record_staging import sha256


CLI_SHA = "adf8aed7203c33da9b884d3f0b6d2b9f67b10b760931ee89a35df5255d3aa604"
PRIMARY_RUNTIME_SHA = "6c9d97d3b1690c6c314d303be5d6da82f630808fc33a57395c8e102216a802a8"
WAITING_RANKS = {6, 7, 8, 9, 10, 11, 13, 14, 16, 17, 18, 19, 20, 21, 23}
COM_STA_RECIPES = {
    "9NH0MSG29X6L", "9PJPCB188SVG", "9NXWSWBM4H6T", "9NQVHHW88XW9", "9NCJWHHMVHR0",
}
ARGUMENT_NAMES = {"argument", "arguments", "commandline", "commandlinearguments"}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profiles", type=Path, required=True)
    parser.add_argument("--registry", type=Path, required=True)
    args = parser.parse_args()
    support = Path.home() / "Library/Application Support"
    cli = support / f"Ode to X/Service/candidates/{CLI_SHA}/xodus-cli"
    state = support / "XodusCLI"
    if sha256(cli) != CLI_SHA:
        raise RuntimeError("Frozen status/launch CLI hash mismatch")
    profiles_hash = sha256(args.profiles)
    registry_hash = sha256(args.registry)
    profiles = load_json(args.profiles)["items"]
    by_id = {row["store_id"]: row for row in profiles}
    registry = {row["name"]: row for row in load_json(args.registry)["engines"]}
    queue = load_json(DATA / "next-30-queue.json")["items"]
    catalogue = load_json(DATA / "game-compatibility-v1.json")["products"]
    inspection = load_json(DATA / "queue-inspection-v1.json")["products"]
    staged = load_json(DATA / "install-staging-v1.json")["products"]
    items = []
    for row in sorted(queue, key=lambda row: row["rank"]):
        if row["rank"] not in WAITING_RANKS and not (
            row["rank"] == 22 and row.get("installStatus") == "complete"
        ):
            continue
        product_id = row["storeId"]
        root = Path(row["installRoot"]).expanduser().resolve(strict=True)
        package = inspection[product_id]["package"]
        manifest = root / package["identity"]["manifest"]
        if sha256(manifest) != package["manifestSha256"]:
            raise RuntimeError(f"{product_id}: manifest changed since package inspection")
        executables = [
            {
                "name": element.attrib["Name"].replace("\\", "/"),
                "attributes": element.attrib,
                "argumentElements": [
                    {"tag": child.tag, "attributes": child.attrib, "text": child.text}
                    for child in element
                    if child.tag.rsplit("}", 1)[-1].lower() in ARGUMENT_NAMES
                ],
            }
            for element in ET.parse(manifest).getroot().iter()
            if element.tag.rsplit("}", 1)[-1] == "Executable"
        ]
        if len(executables) != 1:
            raise RuntimeError(f"{product_id}: executable selection needs manual review")
        executable = executables[0]
        if any(key.lower() in ARGUMENT_NAMES for key in executable["attributes"]) or executable["argumentElements"]:
            raise RuntimeError(f"{product_id}: manifest arguments need literal Windows parsing")
        image = (root / executable["name"]).resolve(strict=True)
        if not image.is_relative_to(root):
            raise RuntimeError(f"{product_id}: executable escapes package root")
        if product_id in staged:
            status = staged[product_id]["completeness"]
            if staged[product_id]["statusExecutableSha256"] != CLI_SHA:
                raise RuntimeError(f"{product_id}: staged status used a different executable")
        else:
            command = [
                str(cli), "install-status", product_id, "--game-dir", str(root),
                "--state-dir", str(state),
            ]
            process = subprocess.run(command, capture_output=True, text=True, check=False)
            if process.returncode:
                raise RuntimeError(
                    f"{product_id}: status failed ({process.returncode}): "
                    f"{process.stdout} {process.stderr}"
                )
            status = json.loads(process.stdout)
        if (
            status.get("status") != "complete"
            or status.get("product") != product_id
            or status.get("operation") != "install-status"
            or status.get("success") is not True
            or status.get("exit_code") != 0
            or Path(status["game_dir"]).resolve() != root
        ):
            raise RuntimeError(f"{product_id}: readiness not established")
        template = by_id[product_id]
        profile_name = template["profile"]
        engine = registry[profile_name]
        runtime = Path(template["runtime"])
        if sha256(runtime) != PRIMARY_RUNTIME_SHA:
            raise RuntimeError(f"{product_id}: recipe requires S2's frozen 7106 primary runtime")
        for asset in template["runtime_assets"]:
            if sha256(Path(asset["path"])) != asset["sha256"]:
                raise RuntimeError(f"{product_id}: runtime asset hash mismatch")
        prefix = state / "prefixes" / f"s3-{product_id}-{profile_name}-adf8"
        argv = [
            str(cli), "launch", product_id, "--account-profile",
            "--game-dir", str(root), "--state-dir", str(state), "--market", "GB",
            "--engine", profile_name, "--registry", str(args.registry.resolve()),
            "--prefix", str(prefix), "--runtime-dll", str(runtime),
            "--shim-dir", template["shim_dir"], "--exe", executable["name"],
            "--no-auto-dismiss",
        ]
        launch_environment = (
            {"XODUS_PRIVATE_RUNTIME_COM_STA": "1"} if product_id in COM_STA_RECIPES else {}
        )
        shell_argv = (
            ["env", "XODUS_PRIVATE_RUNTIME_COM_STA=1", *argv] if launch_environment else argv
        )
        runtime_paths = sorted(
            path.relative_to(root).as_posix() for path in root.rglob("*")
            if path.is_file() and not path.is_symlink()
            and path.name.lower() in {"xgameruntime.dll", "xgameruntime_legacy.dll"}
        )
        imports = [
            binary["path"] for binary in package["binaries"]
            if any(name.lower().startswith("xgameruntime") for name in binary.get("imports", []))
        ]
        unreal_markers = package["engineMarkers"].get("Unreal", [])
        legacy_unreal = (
            (root / "DishonoredGame/CookedPCConsole").is_dir()
            and (root / "Engine/Config").is_dir()
        )
        unreal = bool(unreal_markers) or legacy_unreal
        main_observation = next(
            (binary for binary in package["binaries"] if binary["path"] == executable["name"]), None
        )
        selection_status = "persisted-S1-candidate-not-game-qualified"
        items.append({
            "rank": row["rank"], "title": row["title"], "storeId": product_id,
            "gameDir": str(root), "installStatus": status,
            "manifest": {
                "path": str(manifest), "sha256": package["manifestSha256"],
                "executables": executables, "arguments": [],
                "argumentsBasis": "No argument attributes or argument child elements in the selected executable.",
            },
            "packageFormat": catalogue[product_id]["packageFormat"],
            "encryptedMSIXVC": None,
            "encryptionBasis": (
                "Container format is catalogue evidence; opaque/non-PE main images do not by "
                "themselves prove encryption. No decryption or game launch performed."
            ),
            "mainImageObservation": main_observation,
            "graphicsAPI": row["api"], "graphicsAPIBasis": row["apiBasis"],
            "readableRendererAPIs": package["graphicsAPIs"],
            "engineMarkers": package["engineMarkers"],
            "isUnreal": True if unreal else None,
            "unrealBasis": unreal_markers or (
                ["DishonoredGame/CookedPCConsole", "Engine/Config"] if legacy_unreal else []
            ),
            "xboxRuntime": {
                "importedByReadableImages": imports,
                "shippedRuntimePaths": runtime_paths,
                "manifestXboxIdentity": package["hasXboxIdentity"],
                "actualRuntimeCallsObserved": False,
                "plannedPrimaryRuntime": str(runtime),
            },
            "abioticCOMRisk": {
                "flagged": unreal,
                "basis": (
                    "Unreal layout with planned primary runtime: Abiotic's COM apartment "
                    "initialization failure is a risk, not an observed failure in this title. "
                    "S2 recommends STA only for the five positive WinGDK Shipping titles. "
                    "Dishonored's primary-runtime consumption remains unproven; leave default."
                ) if unreal else "No Unreal layout identified; absence is not proof of another engine.",
                "s2Recommendation": (
                    "Set XODUS_PRIVATE_RUNTIME_COM_STA=1 in this title's recipe only."
                ) if launch_environment else "Leave COM default; no global engine-environment change.",
                "recommendationSource": "S2 session 5fe2f9fe-f6b7-4d63-aaea-bf5dc3a6878d, 2026-10-22",
            },
            "s1Profile": {
                "name": profile_name, "status": selection_status,
                "source": str(args.profiles.resolve()), "registry": str(args.registry.resolve()),
                "wine": engine["wine"], "environment": template["environment"],
                "runtimeAssets": template["runtime_assets"],
                "preparedTemplatePrefix": template["prepared_prefix"],
                "templateIsNotPerTitleQualification": True,
                "confirmationBasis": "Persisted per-title S1 row; source snapshot SHA-256 bound below.",
            },
            "signIn": {
                "needed": row["signInNeeded"],
                "shimDirNeededForSignIn": None,
                "shimDirIncludedForCandidateProfile": template["shim_dir"],
                "basis": (
                    "Profile uses native windows.web/XCurl shims; include its shim directory. "
                    "This does not establish a title's mandatory sign-in or shim requirement."
                ),
            },
            "saveLocation": None,
            "saveLocationBasis": "Not established for this Windows Game Pass build; no saves inspected.",
            "windowTitle": None,
            "windowTitleBasis": "No title window observed; S3 must supply exact observed title, not a guess.",
            "launch": {
                "argv": argv, "environment": launch_environment,
                "shellCommand": shlex.join(shell_argv),
                "executed": False, "prefix": str(prefix),
                "prefixExistsAtCollection": prefix.exists(),
                "prefixPreparationStatus": (
                    "S2 confirms frozen adf8 launch initializes a missing prefix, applies engine "
                    "overlays and checksum-checked registry imports, then runtime pair/shims. "
                    "No template copy or preparation was performed during packet collection."
                ),
                "status": "candidate-command-not-game-qualified",
            },
        })
        print(product_id, "complete;", profile_name, selection_status)
    if sha256(cli) != CLI_SHA:
        raise RuntimeError("Frozen executable changed during collection")
    if sha256(args.profiles) != profiles_hash or sha256(args.registry) != registry_hash:
        raise RuntimeError("S1 profile or registry source changed during collection")
    result = {
        "schemaVersion": 1,
        "checkedAt": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "scope": "S3's fifteen reported never-launched titles, plus Keeper if complete; rank order preserved.",
        "readOnlyCollection": True, "gameLaunches": 0,
        "cli": str(cli), "cliSha256": CLI_SHA,
        "primaryRuntimeSha256": PRIMARY_RUNTIME_SHA,
        "s1ProfilesSha256": profiles_hash,
        "s1RegistrySha256": registry_hash,
        "stagingPaused": {
            "reason": "S3 test backlog exceeds coordinator's approximate six-title staging cap.",
            "reportedNeverLaunchedBeforeKeeper": 15,
            "packetCount": len(items),
            "furtherInstallsStarted": False,
            "valorMortis": "deferred-disk-not-dropped",
        },
        "limitations": [
            "Physical completeness is not license, sign-in, renderer or gameplay qualification.",
            "Unknown encryption and save paths remain null, not inferred.",
            "Commands are plans, not executions; new per-title prefixes were not created.",
            "Do not delete S1 prepared template prefixes referenced by these packets.",
        ],
        "items": items,
    }
    (DATA / "s3-ready-packets-v1.json").write_text(
        json.dumps(result, indent=2, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8"
    )


if __name__ == "__main__":
    main()
