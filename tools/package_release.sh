#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Archive generation only; never signs, notarizes, installs or publishes.
set -eu
fail() { printf 'package_release: %s\n' "$1" >&2; exit 1; }
[ "$#" -eq 9 ] || {
    printf '%s\n' 'Usage: package_release.sh app version newOutputDirectory admissionReceipt appTreeSHA256 receiptSHA256 sourceCommit sourceTree repository' >&2
    exit 64
}
app=${1%/}
version=$2
outdir=$3
receipt=$4
app_hash=$5
receipt_hash=$6
commit=$7
tree=$8
[ "$9" = WorkingPrinciple/xode-ui ] || fail "unexpected source repository"
case "$version" in
    ''|v*|*[!0-9A-Za-z.+-]*) fail "invalid version (no leading v)" ;;
esac
case "$app" in *.app) ;; *) fail "not an .app bundle" ;; esac
[ -d "$app" ] && [ ! -L "$app" ] || fail "app must be a real directory bundle"
app=$(cd "$app" && pwd -P)
script_dir=$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)
repo=$(dirname "$script_dir")
outdir=$(python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$outdir")
python3 - "$app" "$outdir" <<'PY'
from pathlib import Path
import sys
app, output = map(Path, sys.argv[1:])
if output.exists() or output.is_symlink():
    raise SystemExit("package_release: output directory must be new")
if output.resolve().is_relative_to(app):
    raise SystemExit("package_release: output directory must be outside the input app bundle")
parent = output.parent
if not parent.is_dir() or parent.resolve(strict=True) != parent:
    raise SystemExit("package_release: output parent must be an existing canonical directory")
PY
origin=$(git -C "$repo" remote get-url origin) || fail "source origin unavailable"
case "$origin" in
    https://github.com/WorkingPrinciple/xode-ui|https://github.com/WorkingPrinciple/xode-ui.git|git@github.com:WorkingPrinciple/xode-ui.git) ;;
    *) fail "source origin repository mismatch" ;;
esac
[ "$(git -C "$repo" rev-parse HEAD)" = "$commit" ] || fail "source commit mismatch"
[ "$(git -C "$repo" rev-parse 'HEAD^{tree}')" = "$tree" ] || fail "source tree mismatch"
source_status=$(git -C "$repo" status --porcelain --untracked-files=normal) ||
    fail "could not inspect source status"
[ -z "$source_status" ] ||
    fail "packaging tool source must be frozen and clean"
python3 - "$script_dir" "$app" "$receipt" "$app_hash" "$receipt_hash" "$version" "$commit" "$tree" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from release_admission import verify_release_admission
try:
    verify_release_admission(sys.argv[2], sys.argv[3], expected_app_sha256=sys.argv[4],
                             expected_receipt_sha256=sys.argv[5], version=sys.argv[6],
                             commit=sys.argv[7], tree=sys.argv[8])
except (OSError, ValueError, KeyError) as error:
    raise SystemExit("Release admission rejected: " + str(error))
PY
plist="$app/Contents/Info.plist"
executable=$(plutil -extract CFBundleExecutable raw -o - "$plist") || fail "missing executable metadata"
case "$executable" in ''|.|..|*/*) fail "invalid executable name" ;; esac
[ -s "$app/Contents/MacOS/$executable" ] && [ -x "$app/Contents/MacOS/$executable" ] ||
    fail "missing executable"
archs=$(lipo -archs "$app/Contents/MacOS/$executable") || fail "cannot inspect executable architectures"
case " $archs " in *' arm64 '*) ;; *) fail "executable has no arm64 slice" ;; esac
codesign --verify --deep --strict "$app"

# Reserve a new output directory; publish no success manifest on partial failure.
mkdir -m 700 "$outdir"
stage=$(mktemp -d "$outdir/.package-stage.XXXXXX")
mounted=0
hdiutil_uncertain=0
run_hdiutil() {
    if python3 "$script_dir/bounded_hdiutil.py" "$@"; then
        return 0
    else
        operation_status=$?
        if [ "$operation_status" -eq 124 ]; then hdiutil_uncertain=1; fi
        return "$operation_status"
    fi
}
cleanup() {
    status=$?
    trap - EXIT
    cleanup_interrupted=0
    trap 'cleanup_interrupted=1' HUP INT TERM
    if [ "$mounted" -eq 1 ] && ! run_hdiutil detach "$stage/dmg-mounted" -quiet; then
        printf 'package_release: detach failed; preserving stage without recursive removal: %s\n' "$stage" >&2
        exit 1
    fi
    if [ "$cleanup_interrupted" -eq 1 ] || [ "$hdiutil_uncertain" -eq 1 ]; then
        printf 'package_release: operation interrupted or timed out; preserving stage for reconciliation: %s\n' "$stage" >&2
        exit 1
    fi
    rm -rf "$stage" || { printf 'package_release: stage cleanup failed: %s\n' "$stage" >&2; exit 1; }
    exit "$status"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
app_name=$(basename "$app")
snapshot="$stage/$app_name"
verify_tree() {
    actual=$(python3 "$script_dir/release_admission.py" --tree-hash "$1") || fail "could not hash app tree"
    [ "$actual" = "$app_hash" ] || fail "app tree changed or archive does not match admitted input"
    codesign --verify --deep --strict "$1"
}
ditto "$app" "$snapshot"
verify_tree "$snapshot"
mkdir "$stage/dmg"
ditto "$snapshot" "$stage/dmg/$app_name"
verify_tree "$stage/dmg/$app_name"
ln -s /Applications "$stage/dmg/Applications"
base="Ode-to-X-v$version-macos-arm64"
run_hdiutil create -quiet -volname "Ode to X $version" -srcfolder "$stage/dmg" -format UDZO "$stage/$base.dmg"
[ -s "$stage/$base.dmg" ] || fail "missing DMG"
run_hdiutil verify -quiet "$stage/$base.dmg"
mkdir "$stage/dmg-mounted"
mounted=1
run_hdiutil attach -quiet -readonly -nobrowse -mountpoint "$stage/dmg-mounted" "$stage/$base.dmg"
verify_tree "$stage/dmg-mounted/$app_name"
run_hdiutil detach "$stage/dmg-mounted" -quiet || fail "could not detach generated DMG"
mounted=0
ditto -c -k --keepParent "$snapshot" "$stage/$base.zip"
[ -s "$stage/$base.zip" ] || fail "missing ZIP"
mkdir "$stage/zip"
ditto -x -k "$stage/$base.zip" "$stage/zip"
verify_tree "$stage/zip/$app_name"
verify_tree "$app"
(
    cd "$stage"
    shasum -a 256 "$base.dmg" "$base.zip" > SHA256SUMS.txt
    shasum -a 256 -c SHA256SUMS.txt
)
mv "$stage/$base.dmg" "$stage/$base.zip" "$outdir/"
# The manifest is the last output; its presence indicates complete archives.
mv "$stage/SHA256SUMS.txt" "$outdir/"
printf '%s\n' "$outdir/$base.dmg" "$outdir/$base.zip" "$outdir/SHA256SUMS.txt"
