#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
set -eu
cd "$(dirname "$0")/.."
neutral="$(swift build --show-bin-path)/XodusManagementChecks"
XODUS_SHIPPING=1 swift build --scratch-path .build/shipping -c release --product XodusPreview
XODUS_SHIPPING=1 swift build --scratch-path .build/shipping -c release --product XodusAuthHost
bin=$(XODUS_SHIPPING=1 swift build --scratch-path .build/shipping -c release --show-bin-path)
XODUS_NEUTRAL_ENGINE="$neutral" XODUS_NEUTRAL_FIXTURE="$PWD/Tests/ManagementChecks/Fixtures/positive.json" \
    XODUS_BACKEND_PATH=/invalid/override XODUS_SHIPPING=1 \
    swift test --scratch-path .build/shipping -c release -Xswiftc -enable-testing --filter ShippingChecks
python3 - "$bin" <<'PY'
import pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
for flag in ("--fixture", "--export-preview", "--export-live", "--export-live-data", "--live-check", "--self-check"):
    result = subprocess.run([str(root / "XodusPreview"), flag], timeout=10,
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert result.returncode == 64, (flag, result.returncode)
    assert b"does not accept preview, test or development arguments" in result.stderr
    print("PASS actual shipping binary rejects", flag)
for flag in ("--self-check", "--self-check-peer"):
    result = subprocess.run([str(root / "XodusAuthHost"), flag], timeout=10,
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert result.returncode == 64
    print("PASS actual shipping helper rejects", flag)
assert not (root / "XodusAppFoundation_XodusPreview.bundle").exists()
assert not (root / "XodusAppFoundation_XodusAuthHost.bundle").exists()
print("PASS shipping build has no illustration or private fixture resource bundles")
PY
