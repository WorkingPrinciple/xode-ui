#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
set -eu
cd "$(dirname "$0")/.."
python3 tools/sync_contract.py
python3 tools/check_contract_sync.py
python3 tools/sync_runtime_provider_contract.py --check
sh -n tools/build_app.sh
python3 tools/check_signing_identity.py
python3 tools/check_local_candidate.py
python3 tools/check_release_candidate.py
python3 tools/check_package_resources.py
python3 tools/check_distribution_manifest.py
python3 tools/check_producer_notices.py
python3 tools/check_game_root_migration.py
swift build
python3 tools/check_shipping_pair.py
python3 tools/check_python_runtime.py
sh tools/check_shipping.sh
swift run OdeFixtureChecks
swift run OdeManagementChecks
swift run OdePreview --self-check
swift run OdePreview --live-check
swift run OdeAuthHost --self-check
swift run OdeCredentialChecks --self-check
