#!/usr/bin/env python3
"""Fresh complete receipts and literal discovery commands for installed additions."""

import argparse
import copy
import datetime as dt
import json
from pathlib import Path
import subprocess
import uuid
import xml.etree.ElementTree as ET

from build_preflight_packets import (
    CLI_SHA, PRIMARY_RUNTIME_SHA, HELPER, CLOSE_HELPER, COM_KEYS,
    shell_command, validate_status,
)
from build_small_packets import PROFILES, sha
from inspect_queue import DATA, load_json

OUTPUT = DATA / "s3-preflight-small-v1.json"


def build(inputs):
    base = inputs["base"]
    research = {row["storeId"]: row for row in inputs["v5"]["items"]}
    engines = {row["name"]: row for row in inputs["registry"]["engines"]}
    bindings = {row["store_id"]: row for row in inputs["profiles"]["items"]}
    items = []
    blocked = []
    for staged in inputs["staged"]:
        sid = staged["storeId"]
        row = copy.deepcopy(research[sid])
        name = PROFILES[sid]
        root = Path(staged["root"])
        validate_status({"storeId": sid, "gameDir": str(root)}, inputs["statuses"][sid])
        if name is None:
            row.update(gameDir=str(root), manifest=staged["manifest"],
                       installStatus=inputs["statuses"][sid], package=staged["package"],
                       launch=None, discovery=None, readyForLaunch=False,
                       blocker="Explicit S1 renderer/argument choice required; "
                       "static/public API capability does not select active renderer.")
            blocked.append(row)
            continue
        binding = bindings.get(sid)
        if binding and binding["profile"] != name:
            raise ValueError(f"{sid}: S1 selected a different profile; reconcile")
        engine = engines[name]
        if any(engine.get("environment", {}).get(key) not in (None, "", "0")
               for key in COM_KEYS):
            raise ValueError("Registry would reintroduce non-default COM policy")
        template = next(row for row in base["items"] if row["s1Profile"]["name"] == name)
        prefix = Path.home() / "Library/Application Support/XodusCLI/prefixes" / f"s3-{sid}-{name}-adf8"
        exe, = staged["package"]["executables"]
        runtime = template["xboxRuntime"]["plannedPrimaryRuntime"]
        argv = [
            template["launch"]["argv"][0], "launch", sid, "--account-profile",
            "--game-dir", str(root), "--state-dir", str(Path.home() / "Library/Application Support/XodusCLI"),
            "--market", "GB", "--engine", name, "--registry", inputs["registry"]["path"],
            "--prefix", str(prefix), "--runtime-dll", runtime,
            "--shim-dir", template["signIn"]["shimDirIncludedForCandidateProfile"],
            "--exe", exe, "--no-auto-dismiss",
        ]
        row.update(gameDir=str(root), manifest=staged["manifest"],
                   installStatus=inputs["statuses"][sid], package=staged["package"],
                   launch={"argv": argv, "environment": {}, "unsetEnvironment": list(COM_KEYS),
                           "prefix": str(prefix), "executed": False,
                           "shellCommand": shell_command(argv, {}, COM_KEYS)},
                   s1Profile={
                       "name": name, "registry": inputs["registry"]["path"],
                       "environment": engine.get("environment", {}),
                       "runtimeAssets": template["s1Profile"]["runtimeAssets"],
                       "source": inputs["profiles"]["path"], "binding": binding,
                       "status": "persisted-S1-candidate-not-game-qualified" if binding
                       else "proposal-only-awaiting-S1-binding",
                   })
        helper_argv = [
            "python3", str(HELPER), str(OUTPUT.resolve()), "--store-id", sid, "--discover",
            "--close-helper", str(CLOSE_HELPER), "--output", inputs["outputs"][sid],
            "--play-seconds", "300", "--grace-seconds", "30",
        ]
        row["preflight"] = {
            "discovery": {"argv": helper_argv, "shellCommand": shell_command(helper_argv, {}, COM_KEYS),
                          "executed": False, "saveRetentionPass": False},
            "warning": "Default COM, no STA. S2 passive checks and S3 input runs "
            "must coordinate exclusive title/prefix ownership. "
            "Choose ONE launch/discovery command, not both. "
            "Current complete gate and stopped exclusive prefix required. Discovery changes "
            "may be logs/settings, not saves. S3 owns all input and retention acceptance.",
            "install": staged["install"],
            "freeAfterInstallBytes": staged["freeAfterBytes"],
            "staticRendererCaveat": "Readable Unity/Godot/OpenGL libraries establish capability "
            "only, NOT active renderer. Public API and alternatives remain separate.",
        }
        items.append(row)
    return {
        "schemaVersion": 1, "collectedAt": inputs["collectedAt"],
        "cliSha256": CLI_SHA, "primaryRuntimeSha256": PRIMARY_RUNTIME_SHA,
        "s1RegistrySha256": inputs["registry"]["sha256"],
        "gameLaunches": 0, "collectionInputs": inputs, "items": items,
        "blockedItems": blocked,
        "scope": "Complete installed additions only. Candidate recipes, not gameplay qualification.",
    }


def refresh():
    base = load_json(DATA / "s3-ready-packets-v4.json")
    sample = base["items"][0]
    registry_path = Path(sample["s1Profile"]["registry"])
    profiles_path = Path(sample["s1Profile"]["source"])
    inputs = {
        "base": base, "v5": load_json(DATA / "s3-ready-packets-v5.json"),
        "registry": {"path": str(registry_path), "sha256": sha(registry_path),
                     "engines": load_json(registry_path)["engines"]},
        "profiles": {"path": str(profiles_path), "sha256": sha(profiles_path),
                     "items": load_json(profiles_path)["items"]},
        "helper": {"path": str(HELPER), "sha256": sha(HELPER)},
        "closeHelper": {"path": str(CLOSE_HELPER), "sha256": sha(CLOSE_HELPER)},
        "staged": [], "statuses": {}, "outputs": {},
    }
    for staged in load_json(DATA / "small-game-staging-v1.json")["items"]:
        if staged["state"] != "complete-not-game-qualified":
            continue
        staged = copy.deepcopy(staged)
        root = Path(staged["root"])
        manifest = root / staged["package"]["identity"]["manifest"]
        if sha(manifest) != staged["package"]["manifestSha256"]:
            raise ValueError("Installed manifest changed")
        elements = [e for e in ET.parse(manifest).getroot().iter()
                    if e.tag.rsplit("}", 1)[-1] == "Executable"]
        element, = elements
        if any("argument" in key.lower() for key in element.attrib) or list(element):
            raise ValueError("Manifest arguments need explicit literal parsing")
        staged["manifest"] = {"path": str(manifest), "sha256": sha(manifest),
                              "attributes": element.attrib, "arguments": []}
        command = staged["statusArgv"]
        if sha(Path(command[0])) != CLI_SHA:
            raise ValueError("Status CLI identity mismatch")
        result = subprocess.run(command, capture_output=True, text=True, check=True, timeout=120)
        status = json.loads(result.stdout)
        validate_status({"storeId": staged["storeId"], "gameDir": str(root)}, status)
        if PROFILES[staged["storeId"]] is not None:
            template = next(row for row in base["items"]
                            if row["s1Profile"]["name"] == PROFILES[staged["storeId"]])
            assets = template["s1Profile"]["runtimeAssets"]
            if not any(asset["path"] == template["xboxRuntime"]["plannedPrimaryRuntime"]
                       and asset["sha256"] == PRIMARY_RUNTIME_SHA for asset in assets):
                raise ValueError("Recipe does not bind the immutable primary runtime")
            for asset in assets:
                if sha(Path(asset["path"])) != asset["sha256"]:
                    raise ValueError(f"Runtime asset identity mismatch: {asset['path']}")
        inputs["statuses"][staged["storeId"]] = status
        inputs["staged"].append(staged)
        output = Path.home() / "Library/Application Support/XodusCLI/proofs" / f"s3-small-{staged['storeId']}-{uuid.uuid4().hex}"
        if output.exists():
            raise ValueError("Discovery output already exists")
        inputs["outputs"][staged["storeId"]] = str(output)
    inputs["collectedAt"] = dt.datetime.now(dt.timezone.utc).isoformat()
    for source in ("registry", "profiles", "helper", "closeHelper"):
        if sha(Path(inputs[source]["path"])) != inputs[source]["sha256"]:
            raise ValueError(f"{source} changed during read-only collection")
    return inputs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--refresh", action="store_true")
    args = parser.parse_args()
    if args.refresh:
        packet = build(refresh())
        OUTPUT.write_text(json.dumps(packet, indent=2, ensure_ascii=True) + "\n")
    else:
        packet = load_json(OUTPUT)
        if packet != build(packet["collectionInputs"]):
            raise ValueError("Frozen preflight does not reproduce")
    print(len(packet["items"]), "candidate preflights;",
          len(packet["blockedItems"]), "complete but renderer-blocked; no launches")


if __name__ == "__main__":
    main()
