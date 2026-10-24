"""Fail-closed, single-use preconditions immediately before a title spawn."""

import hashlib
import json
from pathlib import Path
import subprocess


class LaunchAdmission:
    def __init__(self, capture_binary, capture_sha256, receipt):
        self.capture_binary = Path(capture_binary)
        self.capture_sha256 = capture_sha256
        self.receipt = Path(receipt)
        self.consumed = False

    def spawn(self, argv, **kwargs):
        if self.consumed or self.receipt.exists():
            raise RuntimeError("launch_admission_already_consumed")
        self.consumed = True
        checks = []
        try:
            result = subprocess.run(
                ["ps", "-axo", "pid=,comm="], check=True,
                capture_output=True, text=True, timeout=5,
            )
            wine_pids = []
            for line in result.stdout.splitlines():
                fields = line.strip().split(None, 1)
                if len(fields) != 2 or not fields[0].isdigit():
                    raise ValueError("malformed process observation")
                if "wine" in Path(fields[1]).name.lower():
                    wine_pids.append(int(fields[0]))
            checks.append({"check": "no_wine_processes", "pass": not wine_pids,
                           "winePids": wine_pids})
        except (OSError, subprocess.SubprocessError, ValueError) as error:
            checks.append({"check": "no_wine_processes", "pass": False,
                           "error": str(error)})
        try:
            binary = self.capture_binary
            if not binary.is_absolute() or binary.is_symlink() or not binary.is_file():
                raise ValueError("capture binary must be an absolute regular non-symlink file")
            actual = hashlib.sha256(binary.read_bytes()).hexdigest()
            checks.append({"check": "capture_pin", "pass": actual == self.capture_sha256,
                           "expectedSha256": self.capture_sha256, "actualSha256": actual})
        except (OSError, ValueError) as error:
            checks.append({"check": "capture_pin", "pass": False, "error": str(error)})
        failures = [item["check"] for item in checks if not item["pass"]]
        with self.receipt.open("x") as stream:
            json.dump({"checks": checks, "spawnPermitted": not failures}, stream, indent=2)
        self.receipt.chmod(0o600)
        if failures:
            raise RuntimeError("launch_admission_failed:" + ",".join(failures))
        return subprocess.Popen(argv, **kwargs)
