#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Exercise the contract gate and check.sh's mismatch path without a full build."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

project = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="ode-contract-sync-") as temporary:
    root = Path(temporary)
    tools = root / "tools"
    tools.mkdir()
    for name in ("sync_contract.py", "check.sh"):
        shutil.copyfile(project / "tools" / name, tools / name)
    source = root / "docs/contracts/management-v1.schema.json"
    target = root / "Sources/OdeManagement/Resources/management-v1.schema.json"
    for path in (source, target):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b'{"accepted":true}\n')

    def snapshot():
        return {path.relative_to(root): (path.read_bytes(), path.stat().st_mtime_ns)
                for path in root.rglob("*") if path.is_file()}

    before = snapshot()
    result = subprocess.run([sys.executable, str(tools / "sync_contract.py")],
                            capture_output=True, text=True, check=False)
    assert result.returncode == 0, result.stderr
    assert before == snapshot(), "Matching contract gate changed files"

    target.write_bytes(b'{"stale":true}\n')
    before = snapshot()
    result = subprocess.run(["sh", str(tools / "check.sh")],
                            capture_output=True, text=True, check=False)
    assert result.returncode != 0 and "Management schema mismatch" in result.stderr, result.stderr
    assert before == snapshot(), "check.sh changed files instead of rejecting the mismatch"

    target.unlink()
    before = snapshot()
    result = subprocess.run([sys.executable, str(tools / "sync_contract.py")],
                            capture_output=True, text=True, check=False)
    assert result.returncode != 0, "Missing bundled schema was silently restored"
    assert before == snapshot(), "Missing-contract failure changed files"

print("Contract sync: matching, mismatched check.sh, and missing-file paths are non-mutating.")
