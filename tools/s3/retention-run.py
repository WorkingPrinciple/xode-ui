"""Run a frozen S3 retention packet only after an explicit screen handback."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write(path, data):
    with path.open("x") as stream:
        stream.write(json.dumps(data, indent=2) + "\n")
    path.chmod(0o600)


def snapshot(roots, destination):
    destination.mkdir(mode=0o700)
    records = []
    for index, root in enumerate(roots):
        record = {"root": str(root), "exists": root.exists(), "files": []}
        if root.is_symlink():
            raise RuntimeError(f"Save root is a symlink: {root}")
        for source in sorted(root.rglob("*")) if root.is_dir() else []:
            if not source.is_file() or source.is_symlink():
                continue
            relative = source.relative_to(root)
            if not source.resolve().is_relative_to(root.resolve()):
                raise RuntimeError(f"Save escaped its title-owned root: {source}")
            target = destination / str(index) / relative
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            before = source.stat()
            digest = sha(source)
            shutil.copyfile(source, target)
            target.chmod(0o600)
            after = source.stat()
            if (before.st_size, before.st_mtime_ns) != (
                after.st_size, after.st_mtime_ns
            ) or sha(target) != digest:
                raise RuntimeError(f"Save changed during stopped snapshot: {source}")
            record["files"].append({
                "path": str(relative), "bytes": after.st_size, "sha256": digest,
                "archive": str(target.relative_to(destination)),
            })
        records.append(record)
    return records


def content(snapshot_records):
    return {
        (record["root"], item["path"]): (item["bytes"], item["sha256"])
        for record in snapshot_records for item in record["files"]
    }


def load_packet(path, expected, phase):
    if sha(path) != expected:
        raise RuntimeError("Frozen packet hash mismatch.")
    packet = json.loads(path.read_text())
    selected, = [item for item in packet["phases"] if item["phase"] == phase]
    prefix = Path(selected["prefix"])
    if not prefix.is_dir():
        raise RuntimeError("Required retained passive prefix absent.")
    state = Path(selected["stateDir"])
    if state.exists() or state.parent.exists():
        raise RuntimeError("Phase state already consumed; no replay.")
    for filename, expected_sha in packet["sourceHashes"].items():
        if sha(Path(filename)) != expected_sha:
            raise RuntimeError(f"Bound source identity changed: {filename}")
    roots = [Path(root) for root in packet["saveRoots"]]
    external = set()
    for mapping in packet.get("externalSaveMappings", []):
        alias, target = Path(mapping["prefixPath"]), Path(mapping["resolvedPath"])
        if not alias.is_relative_to(prefix) or len(alias.relative_to(prefix).parts) < 6:
            raise RuntimeError("External save mapping must name a title-owned prefix path.")
        if not target.is_absolute() or target != target.resolve() or alias.resolve() != target:
            raise RuntimeError("External save mapping identity changed.")
        if target not in roots:
            raise RuntimeError("External save mapping does not name an archived root.")
        external.add(target)
    for root in roots:
        if not root.resolve().is_relative_to(prefix.resolve()) and root not in external:
            raise RuntimeError("Save root outside the admitted prefix.")
    return packet, selected, roots


def phase_environment(selected):
    env = os.environ.copy()
    for name in selected["unsetEnvironment"]:
        env.pop(name, None)
    env.update(selected["environment"])
    env.update(selected["titleEnvironment"])
    env["WINEPREFIX"] = selected["prefix"]
    return env


def external_stop_reason(evidence):
    path = evidence / "external-consent-stop.json"
    if not path.is_file():
        return None
    receipt = json.loads(path.read_text())
    if receipt.get("forcedCleanup") is not True or not receipt.get("reason"):
        raise RuntimeError("External stop receipt is missing forced-cleanup attribution.")
    return receipt["reason"]


def cleanup(server, env, evidence):
    outcomes = []
    for flag in ("-k", "-w"):
        try:
            with (evidence / f"cleanup-{flag[1:]}.log").open("x") as log:
                result = subprocess.run(
                    [server, flag], env=env, stdout=log,
                    stderr=subprocess.STDOUT, timeout=5, check=False,
                )
            outcomes.append({"flag": flag, "returncode": result.returncode})
        except subprocess.TimeoutExpired:
            outcomes.append({"flag": flag, "error": "five-second timeout"})
    return outcomes


def authorize_reload(base, expected_packet):
    world = base / "run-world"
    summary = json.loads((world / "run-receipt.json").read_text())
    observed = json.loads((world / "manual-observation.json").read_text())
    if summary["packetSha256"] != expected_packet or summary["forcedCleanup"] or (
        not summary.get("prefixStopped")
    ):
        raise RuntimeError("World identity/ordinary-stop gate failed.")
    canonical = summary.get("canonicalResult", {})
    if summary["cliExitCode"] != 0 or not canonical.get("success") or (
        canonical.get("wine_exit_code") != 0
    ):
        raise RuntimeError("World did not finish with actual CLI0/Wine0.")
    if not observed.get("gameplayObserved") or not observed.get(
        "ordinaryQuitObserved"
    ):
        raise RuntimeError("Actual world gameplay and ordinary quit need evidence.")
    if not observed.get("screenshots") or not observed.get("gameplaySaveFiles"):
        raise RuntimeError("Missing observed screenshots or gameplay save markers.")
    for screenshot in observed["screenshots"]:
        path = world / screenshot["path"]
        if not path.resolve().is_relative_to(world.resolve()) or (
            sha(path) != screenshot["sha256"]
        ):
            raise RuntimeError("Observed screenshot archive is missing or changed.")
    after = json.loads((world / "after-process-exit.json").read_text())
    before = content(json.loads((world / "before-launch.json").read_text()))
    for record in after:
        for item in record["files"]:
            archived = world / "saves-after" / item["archive"]
            if not archived.resolve().is_relative_to((world / "saves-after").resolve()):
                raise RuntimeError("World archive reference escaped its proof root.")
            if sha(archived) != item["sha256"]:
                raise RuntimeError("World raw save archive is missing or changed.")
    values = content(after)
    for marker in observed["gameplaySaveFiles"]:
        identity = (marker["root"], marker["path"])
        if identity not in values or values[identity][0] <= 0:
            raise RuntimeError("Claimed gameplay payload is absent/empty.")
        if before.get(identity) == values[identity]:
            raise RuntimeError("Gameplay payload did not change during world.")
    return after


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("dry", "run"))
    parser.add_argument("packet", type=Path)
    parser.add_argument("sha256")
    parser.add_argument("phase", choices=("world", "reload"))
    parser.add_argument("--screen-release", help="Explicit handback reference, not a substitute for authorization")
    args = parser.parse_args()
    packet, selected, roots = load_packet(args.packet, args.sha256, args.phase)
    base = args.packet.parent
    previous = authorize_reload(base, args.sha256) if args.phase == "reload" else None
    if args.action == "dry":
        print(json.dumps({
            "sourceAndStateChecks": "PASS", "phase": args.phase,
            "hold": packet["hold"], "launchAttempted": False,
        }))
        return 0
    if not args.screen_release:
        raise RuntimeError("Explicit current screen handback is required.")
    if shutil.disk_usage(base).free < packet["diskFloorBeforeLaunchGiB"] * 2**30:
        raise RuntimeError("Below 110GiB launch floor; preserve all evidence/saves.")
    state = Path(selected["stateDir"])
    evidence = state.parent
    evidence.mkdir(mode=0o700)
    env = phase_environment(selected)
    before = snapshot(roots, evidence / "saves-before")
    write(evidence / "before-launch.json", before)
    if previous is not None and content(before) != content(previous):
        raise RuntimeError("Stopped T2/T3 save continuity differs; no launch.")
    if shutil.disk_usage(base).free < packet["diskFloorBeforeLaunchGiB"] * 2**30:
        raise RuntimeError("Save archiving left less than 110GiB; no launch.")
    write(evidence / "invocation.json", {
        "packetSha256": args.sha256, "runnerSha256": sha(Path(__file__)),
        "phase": args.phase, "argv": selected["argv"],
        "environment": selected["environment"],
        "titleEnvironment": selected["titleEnvironment"],
        "unsetEnvironment": selected["unsetEnvironment"],
        "screenRelease": args.screen_release,
        "startedAt": datetime.now(timezone.utc).isoformat(),
        "quitBySeconds": selected["quitBySeconds"],
        "capSeconds": selected["timeoutSeconds"],
        "hold": packet["hold"],
    })
    server = env["WINESERVER"]
    forced = None
    cleanup_result = None
    started = time.monotonic()
    quit_notice = False
    with (evidence / "cli.stdout.log").open("x") as out, (
        evidence / "cli.stderr.log"
    ).open("x") as err:
        process = subprocess.Popen(selected["argv"], env=env, stdout=out, stderr=err)
        print(json.dumps({"cliPid": process.pid, "evidence": str(evidence)}), flush=True)
        try:
            while process.poll() is None:
                elapsed = time.monotonic() - started
                if not quit_notice and elapsed >= selected["quitBySeconds"]:
                    notice = {"beginOrdinaryQuit": True, "elapsedSeconds": elapsed}
                    write(evidence / "quit-reminder.json", notice)
                    print(json.dumps(notice), flush=True)
                    quit_notice = True
                if shutil.disk_usage(base).free < packet["diskAbortGiB"] * 2**30:
                    forced = "105GiB running disk floor"
                elif elapsed >= selected["timeoutSeconds"]:
                    forced = "Admitted gameplay cap"
                else:
                    for log in state.glob("runs/*/*.log"):
                        if log.name not in ("stdout.log", "stderr.log"):
                            continue
                        with log.open("rb") as stream:
                            stream.seek(max(0, log.stat().st_size - 65536))
                            tail = stream.read().decode("utf-8", errors="replace")
                        if "Private runtime MSA exchange failed" in tail or (
                            "rps_ticket_bridge" in tail and "0x80072746" in tail
                        ):
                            forced = "Infrastructure sign-in failure"
                            break
                if forced:
                    cleanup_result = cleanup(server, env, evidence)
                    break
                time.sleep(0.5)
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                if not forced:
                    forced = "CLI finalization exceeded bounded wait"
                    cleanup_result = cleanup(server, env, evidence)
                process.terminate()
                process.wait(timeout=5)
        except BaseException:
            if cleanup_result is None:
                cleanup_result = cleanup(server, env, evidence)
            forced = forced or external_stop_reason(evidence)
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
            raise
    if cleanup_result is None:
        cleanup_result = cleanup(server, env, evidence)
    stopped = cleanup_result[-1].get("returncode") == 0
    result_paths = list(state.glob("runs/*/result.json"))
    canonical = json.loads(result_paths[0].read_text()) if len(result_paths) == 1 else None
    receipt = {
        "packetSha256": args.sha256, "phase": args.phase,
        "cliExitCode": process.returncode, "elapsedSeconds": time.monotonic() - started,
        "forcedCleanup": forced, "cleanup": cleanup_result,
        "prefixStopped": stopped, "canonicalResult": canonical,
        "canonicalResultPath": str(result_paths[0]) if len(result_paths) == 1 else None,
        "qualification": "Observed gameplay/save/quit evidence still required; exit0 alone is not a pass.",
    }
    write(evidence / "run-receipt.json", receipt)
    if stopped:
        after = snapshot(roots, evidence / "saves-after")
        write(evidence / "after-process-exit.json", after)
    manifest = {
        str(path.relative_to(evidence)): sha(path)
        for path in sorted(evidence.rglob("*"))
        if path.is_file() and not path.is_symlink()
    }
    write(evidence / "integrity.json", manifest)
    print(json.dumps({
        "cliExitCode": process.returncode, "forcedCleanup": forced,
        "prefixStopped": stopped, "integritySha256": sha(evidence / "integrity.json"),
    }), flush=True)
    return 0 if process.returncode == 0 and not forced and stopped else 1


if __name__ == "__main__":
    raise SystemExit(main())
