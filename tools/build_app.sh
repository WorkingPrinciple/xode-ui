#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Execute only after independent operator approval of source and sealed CLI inputs.
set -eu
cd "$(dirname "$0")/.."
if [ "$#" -lt 9 ]; then
    printf '%s\n' 'Usage: build_app.sh engine unsignedSHA bytes provenanceSHA bytes approvedAppCommit approvedAppTree newOutputRoot (--signing-identity CERT_SHA1 | --local-ad-hoc) [--preserve-signed-cli path SHA256 bytes priorPackageReceipt receiptSHA256 receiptBytes] [--credential-broker path SHA256 bytes]' >&2
    exit 2
fi
engine=$1
engine_hash=$2
engine_bytes=$3
proof_hash=$4
proof_bytes=$5
source=$6
tree=$7
output_root=$8
shift 8
signer=
local_ad_hoc=false
signed_cli=
credential_broker=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --signing-identity)
            test "$#" -ge 2
            test -z "$signer"
            signer=$2
            shift 2 ;;
        --local-ad-hoc)
            test "$local_ad_hoc" = false
            local_ad_hoc=true
            shift ;;
        --preserve-signed-cli)
            test "$#" -ge 7
            test -z "$signed_cli"
            signed_cli=$2
            signed_cli_hash=$3
            signed_cli_bytes=$4
            prior_receipt=$5
            prior_receipt_hash=$6
            prior_receipt_bytes=$7
            shift 7 ;;
        --credential-broker)
            test "$#" -ge 4
            test -z "$credential_broker"
            credential_broker=$2
            credential_broker_hash=$3
            credential_broker_bytes=$4
            shift 4 ;;
        *) printf '%s\n' 'Unknown signing option; no fallback.' >&2; exit 2 ;;
    esac
done
if [ "$local_ad_hoc" = true ]; then
    test -z "$signer"
    set -- --local-ad-hoc
else
    if [ -z "$signer" ]; then
        printf '%s\n' 'Supplied OS Keychain signing identity is required; provisioning requires human approval.' >&2
        exit 2
    fi
    set -- --identity "$signer"
fi
python3 tools/signing_identity.py preflight "$@"
test "$(git rev-parse HEAD)" = "$source"
test "$(git rev-parse 'HEAD^{tree}')" = "$tree"
if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then
    printf '%s\n' 'Packaging requires an independently approved frozen clean source commit.' >&2
    exit 1
fi
python3 - "$output_root" <<'PY'
import os, pathlib, stat, sys
p = pathlib.Path(sys.argv[1])
s = p.lstat()
assert p.is_absolute() and p.resolve(strict=True) == p and stat.S_ISDIR(s.st_mode)
assert s.st_uid == os.getuid() and s.st_mode & 0o022 == 0
PY
stage=$(mktemp -d "$output_root/Xodus-controlled-pair.XXXXXX")
python3 tools/shipping_pair.py verify --engine "$engine" --engine-hash "$engine_hash" \
    --engine-bytes "$engine_bytes" --proof-hash "$proof_hash" --proof-bytes "$proof_bytes" \
    --output "$stage/unsigned-approval.json"
git archive --format=tar "$source" > "$stage/source.tar"
mkdir "$stage/source"
tar -xf "$stage/source.tar" -C "$stage/source"
cd "$stage/source"
python3 tools/sync_runtime_provider_contract.py --check
XODUS_SHIPPING=1 swift build --jobs 1 -c release --product XodusAuthHost
bin=$(XODUS_SHIPPING=1 swift build -c release --show-bin-path)
app="$stage/Xodus.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/XodusEngine"
cp "$bin/XodusAuthHost" "$app/Contents/MacOS/XodusAuthHost"
if [ -n "$signed_cli" ]; then
    python3 tools/signing_identity.py reuse-cli --source "$signed_cli" \
        --destination "$app/Contents/Resources/XodusEngine/xodus-cli" \
        --hash "$signed_cli_hash" --bytes "$signed_cli_bytes" \
        --prior-receipt "$prior_receipt" --receipt-hash "$prior_receipt_hash" --receipt-bytes "$prior_receipt_bytes" \
        --engine "$engine" --engine-hash "$engine_hash" --engine-bytes "$engine_bytes" \
        --proof-hash "$proof_hash" --proof-bytes "$proof_bytes" "$@"
else
    cp "$engine" "$app/Contents/Resources/XodusEngine/xodus-cli"
python3 - "$app/Contents/Resources/XodusEngine/xodus-cli" "$engine_hash" "$engine_bytes" <<'PY'
import sys
from tools.shipping_pair import owned_bytes
owned_bytes(sys.argv[1], sys.argv[2], int(sys.argv[3]))
PY
fi
chmod 755 "$app/Contents/MacOS/XodusAuthHost" "$app/Contents/Resources/XodusEngine/xodus-cli"
python3 tools/signing_identity.py sign --kind helper --path "$app/Contents/MacOS/XodusAuthHost" "$@"
if [ -z "$signed_cli" ]; then
    python3 tools/signing_identity.py sign --kind cli --path "$app/Contents/Resources/XodusEngine/xodus-cli" "$@"
fi
python3 tools/shipping_pair.py generate --source "$source" --tree "$tree" \
    --engine "$app/Contents/Resources/XodusEngine/xodus-cli" --helper "$app/Contents/MacOS/XodusAuthHost" \
    --approval "$stage/unsigned-approval.json" --output Sources/XodusPreview/ShippingPairPins.swift \
    --receipt "$stage/paired-inputs.json"
if [ -n "$credential_broker" ]; then
    test -n "$signer"
    python3 tools/signing_identity.py verify --kind broker --path "$credential_broker" --identity "$signer"
    python3 - "$credential_broker" "$credential_broker_hash" "$credential_broker_bytes" "$stage" <<'PY'
import json, pathlib, shutil, sys
from tools.shipping_pair import owned_bytes
source, digest, size, stage = sys.argv[1], sys.argv[2], int(sys.argv[3]), pathlib.Path(sys.argv[4])
identity, _ = owned_bytes(source, digest, size)
directory = stage / "CredentialBroker"
directory.mkdir(mode=0o700)
destination = directory / "XodusCredentialBroker"
shutil.copyfile(source, destination)
destination.chmod(0o500)
owned_bytes(destination, digest, size)
owned_bytes(source, digest, size)
manifest = {"version": 1, **identity}
(stage / "Xodus.app/Contents/Resources/XodusCredentialBroker.json").write_text(
    json.dumps(manifest, sort_keys=True) + "\n", encoding="utf-8")
paired = stage / "paired-inputs.json"
record = json.loads(paired.read_bytes())
record["frozenCredentialBroker"] = manifest
record["credentialBrokerInstallation"] = (
    "Separate owner gate: install once at ~/Library/Application Support/Xodus/CredentialBroker/"
    "XodusCredentialBroker; preserve exact bytes on launcher updates. Never silently replace.")
paired.write_text(json.dumps(record, sort_keys=True) + "\n", encoding="utf-8")
PY
    python3 tools/signing_identity.py verify --kind broker \
        --path "$stage/CredentialBroker/XodusCredentialBroker" --identity "$signer"
fi
XODUS_SHIPPING=1 swift build --jobs 1 -c release --product XodusPreview
cp "$bin/XodusPreview" "$app/Contents/MacOS/Xodus"
cp tools/Info.plist "$app/Contents/Info.plist"
cp LICENSE "$app/Contents/Resources/LICENSE.txt"
ditto "$bin/XodusAppFoundation_XodusManagement.bundle" \
    "$app/Contents/Resources/XodusAppFoundation_XodusManagement.bundle"
python3 - "$stage/paired-inputs.json" "$app/Contents/Resources/XodusAuthHost.json" <<'PY'
import json, pathlib, sys
record = json.loads(pathlib.Path(sys.argv[1]).read_bytes())
pathlib.Path(sys.argv[2]).write_text(json.dumps({
    "version": 1, "sha256": record["signedHelper"]["sha256"],
    "sourceCommit": record["approvedAppSourceCommit"]}, sort_keys=True) + "\n", encoding="utf-8")
PY
swift tools/RenderAppIcon.swift "$app/Contents/Resources/Xodus.iconset"
iconutil -c icns "$app/Contents/Resources/Xodus.iconset" -o "$app/Contents/Resources/Xodus.icns"
python3 tools/signing_identity.py sign --kind app --path "$app" "$@"
codesign --verify --deep --strict "$app"
plutil -lint "$app/Contents/Info.plist"
python3 tools/verify_shipping_package.py "$stage"
# Re-pin original unsigned inputs after all copying/building/signing.
python3 tools/shipping_pair.py verify --engine "$engine" --engine-hash "$engine_hash" \
    --engine-bytes "$engine_bytes" --proof-hash "$proof_hash" --proof-bytes "$proof_bytes" \
    --output "$stage/unsigned-approval-after.json"
cmp "$stage/unsigned-approval.json" "$stage/unsigned-approval-after.json"
if [ -n "$signed_cli" ]; then
    python3 - "$signed_cli" "$app/Contents/Resources/XodusEngine/xodus-cli" "$signed_cli_hash" "$signed_cli_bytes" \
        "$prior_receipt" "$prior_receipt_hash" "$prior_receipt_bytes" <<'PY'
import sys
from tools.shipping_pair import owned_bytes
for path in sys.argv[1:3]:
    owned_bytes(path, sys.argv[3], int(sys.argv[4]))
owned_bytes(sys.argv[5], sys.argv[6], int(sys.argv[7]), 65536)
PY
    if [ "$local_ad_hoc" != true ]; then
        python3 tools/signing_identity.py verify --kind cli \
            --path "$app/Contents/Resources/XodusEngine/xodus-cli" --identity "$signer"
    fi
fi
printf '%s\n' "$app" "$stage/package-receipt.json"
printf '%s\n' 'Controlled local pair only. No launch, account operation, previous app replacement, notarization or gameplay qualification.'
if [ "$local_ad_hoc" = true ]; then
    printf '%s\n' 'Explicit local ad-hoc mode is not a durable Keychain signing-identity fix.'
fi
