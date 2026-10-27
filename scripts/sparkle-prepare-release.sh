#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail

if [[ $# != 4 ]]; then
    echo "Usage: $0 /path/to/signed.app /path/to/Sparkle-2.10.1/bin /new/output/directory release-tag" >&2
    echo "Dry-run only: prints a plan; does not create, sign, notarize or publish anything." >&2
    exit 2
fi

app=$1
tools=$2
output=$3
tag=$4
[[ "$app" == /* && "$tools" == /* && "$output" == /* ]] || {
    echo "All paths must be absolute." >&2; exit 2;
}
[[ -d "$app" && "$app" == *.app && ! -e "$output" ]] || {
    echo "Expected an existing .app and a new output directory." >&2; exit 2;
}
[[ "$tag" =~ ^v[0-9][A-Za-z0-9._-]*$ ]] || {
    echo "Expected a release tag, for example v0.2.0-beta.1." >&2; exit 2;
}
for tool in sign_update generate_appcast; do
    [[ -x "$tools/$tool" ]] || { echo "Missing Sparkle 2.10.1 tool: $tool" >&2; exit 2; }
done

archive="$output/Ode-$tag.zip"
download_prefix="https://github.com/WorkingPrinciple/xode-ui/releases/download/$tag/"
feed="https://github.com/WorkingPrinciple/xode-ui/releases/latest/download/appcast.xml"
identity="Developer ID Application: Dragos Hont (M62Z4M5EUY)"

command_plan() { printf '%q ' "$@"; printf '\n'; }
printf 'DRY RUN ONLY. Required identity: %s\n' "$identity"
printf 'Proposed feed (not written to Info.plist): %s\n' "$feed"
printf '%s\n' 'Before execution: verify hardened runtime, library validation, framework/XPC signing, and owner-approved notarization.'
command_plan /usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
command_plan /usr/bin/spctl --assess --type execute --verbose=2 "$app"
command_plan /bin/mkdir "$output"
command_plan /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
command_plan "$tools/sign_update" "$archive"
command_plan "$tools/generate_appcast" --download-url-prefix "$download_prefix" \
    --maximum-deltas 0 -o "$output/appcast.xml" "$output"
printf '%s\n' 'STOP: review the generated appcast, signatures and source/notices before owner-approved publication.'
