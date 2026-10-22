#!/usr/bin/env python3
"""Build six S3 bundles; --refresh only hashes files and queries install-status."""

from __future__ import annotations

import argparse
import copy
import datetime as dt
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import uuid

from build_ready_packets import CLI_SHA, PRIMARY_RUNTIME_SHA
from inspect_queue import DATA, load_json


ORDER = (
    "9P1N07XDL1D4", "9P03JGQ4S1GC", "9MWR1NC6VQ6L",
    "9PNG83MDD6SH", "9P3T7HVKM6D0", "9N8C07SS8C9D",
)
S2 = Path("/Users/dragoshont/src/copilot-worktrees/xodus-macos/dragoshont-fluffy-guide")
RUNTIME_RECIPES = S2 / "docs/recipes/title-runtime-v1.json"
HELPER = S2 / "scripts/macos/game-evidence-cycle.py"
CLOSE_HELPER = S2 / "target/diagnostics/close-exact-window-discovery.exe"
OUTPUT = DATA / "s3-preflight-v1.json"
COM_KEYS = ("XODUS_PRIVATE_RUNTIME_COM_STA", "XODUS_PRIVATE_CALLER_OWNS_COM")


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def option(argv, key):
    if argv.count(key) != 1:
        raise ValueError(f"Exactly one {key} required")
    return argv[argv.index(key) + 1]


def shell_command(argv, environment, unset):
    return shlex.join([
        "env", *(part for key in unset for part in ("-u", key)),
        *(f"{key}={value}" for key, value in sorted(environment.items())), *argv,
    ])


def launch_recipe(row, runtime_recipes, *, diagnostic_opt_in=False):
    result = copy.deepcopy(row["launch"])
    argv = result["argv"]
    matches = [item for item in runtime_recipes["items"]
               if item["storeId"] == row["storeId"]
               and item["launch"]["engine"] == option(argv, "--engine")]
    if len(matches) > 1:
        raise ValueError("Ambiguous title-runtime selection")
    selected = matches[0] if matches else None
    environment = dict(result["environment"])
    unset = list(COM_KEYS)
    applied = selected and (not selected.get("pendingTest") or diagnostic_opt_in)
    if applied:
        recipe = selected["launch"]
        if recipe["executable"] != option(argv, "--exe"):
            raise ValueError(f"{row['storeId']}: title-runtime executable differs")
        environment.update(recipe.get("environment", {}))
        unset = list(dict.fromkeys([*unset, *recipe.get("unsetEnvironment", [])]))
    if all(environment.get(key) not in (None, "", "0") for key in COM_KEYS):
        raise ValueError("Conflicting COM settings")
    result["environment"] = environment
    result["unsetEnvironment"] = unset
    result["shellCommand"] = shell_command(argv, environment, unset)
    return result, selected


def status_command(row):
    argv = row["launch"]["argv"]
    return [
        argv[0], "install-status", row["storeId"],
        "--game-dir", row["gameDir"], "--state-dir", option(argv, "--state-dir"),
    ]


def validate_status(row, receipt):
    if (receipt.get("status") != "complete" or receipt.get("success") is not True
            or receipt.get("exit_code") != 0
            or receipt.get("operation") != "install-status"
            or receipt.get("product") != row["storeId"]
            or receipt.get("game_dir") != row["gameDir"]):
        raise ValueError(f"{row['storeId']}: fresh complete install-status required")


def build(base, inputs):
    rows = {row["storeId"]: row for row in base["items"]}
    paths = {row["storeId"]: row for row in base["fastPaths"]}
    registry = {engine["name"]: engine for engine in inputs["registry"]["engines"]}
    items = []
    for index, store_id in enumerate(ORDER, 1):
        row = copy.deepcopy(rows[store_id])
        launch, selected = launch_recipe(row, inputs["titleRuntime"]["snapshot"])
        row["launch"] = launch
        receipt = inputs["receipts"][store_id]
        validate_status(row, receipt["result"])
        row["installStatus"] = copy.deepcopy(receipt["result"])
        engine = registry[option(launch["argv"], "--engine")]
        for key in launch["unsetEnvironment"]:
            if engine.get("environment", {}).get(key) not in (None, "", "0"):
                if engine["environment"][key] != launch["environment"].get(key):
                    raise ValueError("Registry would reintroduce conflicting COM policy")
        row["s1Profile"]["environment"] = copy.deepcopy(engine.get("environment", {}))
        row["fastPath"] = copy.deepcopy(paths[store_id])
        discovery_argv = [
            "python3", inputs["helper"]["path"], str(OUTPUT.resolve()),
            "--store-id", store_id, "--discover",
            "--close-helper", inputs["closeHelper"]["path"],
            "--output", inputs["discoveryOutputs"][store_id],
            "--play-seconds", "300", "--grace-seconds", "30",
        ]
        row["preflight"] = {
            "order": index,
            "installStatus": receipt,
            "statusCommand": {"argv": status_command(row),
                              "shellCommand": shlex.join(status_command(row))},
            "titleRuntimeSelection": selected,
            "titleRuntimePolicy": (
                "Diagnostic candidate recorded, NOT applied without explicit "
                "S3 selection; original default retained." if selected and selected.get("pendingTest")
                else "Matching non-pending S2 selection applied." if selected else
                "No matching title/engine override; COM default, not inferred STA."
            ),
            "engineEnvironment": copy.deepcopy(engine.get("environment", {})),
            "discovery": {
                "argv": discovery_argv,
                "environment": copy.deepcopy(launch["environment"]),
                "unsetEnvironment": copy.deepcopy(launch["unsetEnvironment"]),
                "shellCommand": shell_command(
                    discovery_argv, launch["environment"], launch["unsetEnvironment"]),
                "executed": False,
                "outputMustNotExist": True,
                "qualification": "One bounded discovery run, NOT save retention. "
                "Changed files may be settings/logs/caches. S3 owns gameplay input.",
            },
        }
        row["preflight"]["diagnosticCandidate"] = None
        if selected and selected.get("pendingTest"):
            diagnostic, _ = launch_recipe(
                row, inputs["titleRuntime"]["snapshot"], diagnostic_opt_in=True)
            for key in diagnostic["unsetEnvironment"]:
                declared = engine.get("environment", {}).get(key)
                if declared not in (None, "", "0", diagnostic["environment"].get(key)):
                    raise ValueError("Registry conflicts with explicit diagnostic candidate")
            row["preflight"]["diagnosticCandidate"] = {
                "requiresExplicitS3Selection": True,
                "appliedToDefault": False,
                "launch": diagnostic,
                "limitation": "Helper clears inherited COM controls before "
                "loading launch.environment from items[]. The default packet "
                "does not apply this pending candidate: diagnostic launch is "
                "copy-pasteable only after explicit S3 selection; discovery "
                "requires a separately selected packet with that environment. "
                "Default discovery does not apply STA.",
            }
        items.append(row)
    return {
        "schemaVersion": 1,
        "collectedAt": inputs["finishedAt"],
        "readOnlyCollection": True, "gameLaunches": 0,
        "cliSha256": CLI_SHA, "primaryRuntimeSha256": PRIMARY_RUNTIME_SHA,
        "s1RegistrySha256": inputs["registry"]["sha256"],
        "baseV4": {"path": "s3-ready-packets-v4.json", "sha256": inputs["baseSha256"]},
        "collectionInputs": inputs,
        "order": list(ORDER),
        "operatorContract": {
            "lane": "After Fallout and Hogwarts; at most two S3 titles. "
            "S4 has not launched anything or claimed a slot.",
            "commands": "Launch and discovery are ALTERNATIVES, never run both "
            "concurrently. Re-query status immediately before execution and "
            "require complete. Use a stopped exclusive per-title prefix. "
            "Discovery reuses the exact launch recipe but uses per-phase state "
            "directories and a bounded timeout per S2 helper's contract.",
            "environment": "Unset inherited COM controls before applying explicit "
            "title settings. Registry engine environment is separately recorded; "
            "CLI/helper applies it. No global environment/default changes.",
            "singleUse": "Discovery output paths are fresh single-use absolute "
            "paths; choose a NEW absent directory for any rerun.",
            "retention": "Discovery only identifies candidate paths/windows. "
            "It cannot establish gameplay or save-retention PASS.",
            "installs": "Paused; no payload/prefix/save deletion or modification.",
        },
        "items": items,
    }


def refresh(base):
    rows = {row["storeId"]: row for row in base["items"]}
    registry_path = Path(option(rows[ORDER[0]]["launch"]["argv"], "--registry"))
    engine_names = {option(rows[store_id]["launch"]["argv"], "--engine") for store_id in ORDER}
    inputs = {
        "baseSha256": sha(DATA / "s3-ready-packets-v4.json"),
        "titleRuntime": {"path": str(RUNTIME_RECIPES), "sha256": sha(RUNTIME_RECIPES),
                         "snapshot": load_json(RUNTIME_RECIPES)},
        "registry": {"path": str(registry_path), "sha256": sha(registry_path),
                     "engines": [engine for engine in load_json(registry_path)["engines"]
                                 if engine["name"] in engine_names]},
        "helper": {"path": str(HELPER), "sha256": sha(HELPER)},
        "closeHelper": {"path": str(CLOSE_HELPER), "sha256": sha(CLOSE_HELPER)},
        "receipts": {}, "discoveryOutputs": {},
    }
    if (inputs["titleRuntime"]["snapshot"]["cliSha256"] != CLI_SHA
            or inputs["titleRuntime"]["snapshot"]["primaryRuntimeSha256"] != PRIMARY_RUNTIME_SHA):
        raise ValueError("S2 runtime recipe does not bind immutable adf8/7106")
    for store_id in ORDER:
        row = rows[store_id]
        launch_recipe(row, inputs["titleRuntime"]["snapshot"])
        if sha(Path(row["launch"]["argv"][0])) != CLI_SHA:
            raise ValueError("Frozen adf8 CLI hash mismatch")
        if sha(Path(row["manifest"]["path"])) != row["manifest"]["sha256"]:
            raise ValueError(f"{store_id}: manifest changed")
        if not (Path(row["gameDir"]) / option(row["launch"]["argv"], "--exe")).is_file():
            raise ValueError(f"{store_id}: executable missing")
        for asset in row["s1Profile"]["runtimeAssets"]:
            if sha(Path(asset["path"])) != asset["sha256"]:
                raise ValueError(f"{store_id}: runtime asset mismatch")
        started = dt.datetime.now(dt.timezone.utc).isoformat()
        result = subprocess.run(status_command(row), capture_output=True,
                                text=True, timeout=120, check=True)
        receipt = json.loads(result.stdout)
        validate_status(row, receipt)
        inputs["receipts"][store_id] = {
            "queriedAt": started, "finishedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
            "processExitCode": result.returncode, "stderr": result.stderr,
            "result": receipt,
        }
        output = Path.home() / "Library/Application Support/XodusCLI/proofs" / (
            f"s3-preflight-{store_id}-{uuid.uuid4().hex}")
        if output.exists():
            raise ValueError("Discovery output already exists")
        inputs["discoveryOutputs"][store_id] = str(output)
    for name in ("titleRuntime", "registry", "helper", "closeHelper"):
        binding = inputs[name]
        if sha(Path(binding["path"])) != binding["sha256"]:
            raise ValueError(f"{name} changed during capture; refresh after owner freezes")
    inputs["finishedAt"] = dt.datetime.now(dt.timezone.utc).isoformat()
    return inputs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--refresh", action="store_true")
    mode.add_argument("--check", action="store_true", help="Offline frozen-input check")
    args = parser.parse_args()
    base = load_json(DATA / "s3-ready-packets-v4.json")
    if args.refresh:
        packet = build(base, refresh(base))
        OUTPUT.write_text(json.dumps(packet, indent=2, ensure_ascii=True) + "\n")
    else:
        packet = load_json(OUTPUT)
        if sha(DATA / "s3-ready-packets-v4.json") != packet["baseV4"]["sha256"]:
            raise ValueError("V4 source changed")
        if packet != build(base, packet["collectionInputs"]):
            raise ValueError("Published preflight differs from frozen inputs")
    print(f"{len(packet['items'])} complete preflight bundles; no launches")


if __name__ == "__main__":
    main()
