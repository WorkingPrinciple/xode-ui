"""Explicit, hash-bound keyboard seam; capture separately with the existing observer."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def bound_file(path, expected):
    path = Path(path)
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        raise ValueError(f"Expected absolute regular non-symlink file: {path}")
    if sha256(path) != expected:
        raise ValueError(f"Source/binary hash mismatch: {path}")
    return path


def prepare(binding_path, mac_pid, key, hold):
    binding = json.loads(binding_path.read_text())
    if binding.get("schema") != "s3-key-v1":
        raise ValueError("Expected s3-key-v1 binding")
    for name in ("helper", "wine", "observer"):
        bound_file(binding[name]["path"], binding[name]["sha256"])
    if Path(binding["observer"]["path"]).resolve() != Path(__file__).resolve():
        raise ValueError("Binding must pin this observer")
    for name in ("title", "class"):
        value = binding[name]
        if not isinstance(value, str) or not value or any(c in value for c in "\r\n\t"):
            raise ValueError(f"Invalid {name}")
    windows_pid = binding["windowsPid"]
    if type(windows_pid) is not int or not 1 <= windows_pid <= 2147483647:
        raise ValueError("Expected observed Windows PID")
    if not 1 <= mac_pid <= 2147483647 or not 8 <= key <= 254 or not 1 <= hold <= 1000:
        raise ValueError("PID/key/hold outside finite bounds")
    prefix = Path(binding["prefix"])
    if not prefix.is_absolute() or not prefix.is_dir() or prefix.is_symlink():
        raise ValueError("Expected existing absolute prefix")
    env = os.environ.copy()
    env.update(binding["environment"])
    env["WINEPREFIX"] = str(prefix)
    argv = [
        binding["wine"]["path"], binding["helper"]["path"], str(windows_pid),
        binding["title"], binding["class"], str(key), str(hold),
    ]
    return binding, argv, env


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binding", type=Path, required=True)
    parser.add_argument("--binding-sha256", required=True)
    parser.add_argument("--mac-pid", type=int, required=True)
    parser.add_argument("--key", type=int, required=True)
    parser.add_argument("--hold-ms", type=int, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    binding_path = bound_file(args.binding, args.binding_sha256)
    binding, argv, env = prepare(binding_path, args.mac_pid, args.key, args.hold_ms)
    # The Windows helper independently witnesses HWND/PID/class/title immediately before input.
    swift = """
import CoreGraphics
import Foundation
let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String:Any]]
let owned = all.filter { ($0[kCGWindowOwnerPID as String] as? Int) == MAC_PID && ($0[kCGWindowName as String] as? String) == EXACT_TITLE }
print(String(data: try JSONSerialization.data(withJSONObject: owned), encoding: .utf8)!)
""".replace("MAC_PID", str(args.mac_pid)).replace("EXACT_TITLE", json.dumps(binding["title"]))
    with args.evidence.open("x") as stream:
        record = {
            "bindingSha256": args.binding_sha256, "argv": argv,
            "observerArgv": sys.argv, "startedUnix": time.time(),
            "macPid": args.mac_pid, "windowsPid": binding["windowsPid"],
        }
        stream.write(json.dumps(record) + "\n")
        stream.flush()
        windows = json.loads(subprocess.check_output(["swift", "-e", swift], text=True, timeout=30))
        if len(windows) != 1:
            raise ValueError(f"Expected one exact macPID/title CG window; found {len(windows)}")
        stream.write(json.dumps({"cgWindow": windows[0]}) + "\n")
        stream.flush()
        # Recheck all executable bindings after the potentially slow CG observation.
        prepare(binding_path, args.mac_pid, args.key, args.hold_ms)
        if sha256(binding_path) != args.binding_sha256:
            raise ValueError("Binding changed during observation")
        result = subprocess.run(argv, env=env, text=True, capture_output=True, timeout=20)
        stream.write(json.dumps({
            "finishedUnix": time.time(), "returncode": result.returncode,
            "stdout": result.stdout, "stderr": result.stderr,
        }) + "\n")
        stream.flush()
        print(result.stdout, end="")
        print(result.stderr, end="", file=sys.stderr)
        result.check_returncode()


if __name__ == "__main__":
    main()
