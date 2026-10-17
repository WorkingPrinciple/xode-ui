#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
set -eu
cd "$(dirname "$0")/.."
python3 tools/sync_contract.py
python3 tools/sync_runtime_provider_contract.py --check
sh -n tools/build_app.sh
python3 tools/check_signing_identity.py
swift build
python3 tools/check_shipping_pair.py
sh tools/check_shipping.sh
swift run XodusFixtureChecks
swift run XodusManagementChecks
swift run XodusPreview --self-check
swift run XodusPreview --live-check
swift run XodusAuthHost --self-check
swift run XodusCredentialChecks --self-check
