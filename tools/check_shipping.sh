#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
set -eu
cd "$(dirname "$0")/.."
swift build --product OdeManagementChecks
neutral="$(swift build --show-bin-path)/OdeManagementChecks"
ODE_SHIPPING=1 swift build --scratch-path .build/shipping -c release --product OdePreview
ODE_SHIPPING=1 swift build --scratch-path .build/shipping -c release --product OdeAuthHost
bin=$(ODE_SHIPPING=1 swift build --scratch-path .build/shipping -c release --show-bin-path)
ODE_NEUTRAL_ENGINE="$neutral" ODE_NEUTRAL_FIXTURE="$PWD/Tests/ManagementChecks/Fixtures/positive.json" \
    ODE_BACKEND_PATH=/invalid/override ODE_SHIPPING=1 \
    swift test --scratch-path .build/shipping -c release -Xswiftc -enable-testing --filter ShippingChecks
python3 - "$bin" <<'PY'
import pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
for flag in ("--fixture", "--export-preview", "--export-live", "--export-live-data", "--live-check", "--self-check"):
    result = subprocess.run([str(root / "OdePreview"), flag], timeout=10,
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert result.returncode == 64, (flag, result.returncode)
    assert b"does not accept preview, test or development arguments" in result.stderr
    print("PASS actual shipping binary rejects", flag)
for flag in ("--self-check", "--self-check-peer"):
    result = subprocess.run([str(root / "OdeAuthHost"), flag], timeout=10,
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert result.returncode == 64
    print("PASS actual shipping helper rejects", flag)
assert not (root / "OdeApp_OdePreview.bundle").exists()
assert not (root / "OdeApp_OdeAuthHost.bundle").exists()
print("PASS shipping build has no illustration or private fixture resource bundles")
PY
