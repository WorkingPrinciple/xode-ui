#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# REQ-134 automated pass against the installed X Ode build (default: build 624, "Ode to X Local Candidate.app").
# Reads AX trees and captures windows; changes app state only through the allow-listed AX actions in
# req134_observe.swift. No synthetic keystrokes or clicks, no game, account, install or permission action.
# Every action waits until the owner has been idle for XODE_IDLE_SECONDS (COR-272).
#
#   tools/qa/req134_run.sh OUT_DIR
#
# Before running: the screen is unlocked, X Ode build 624 is already open from Finder (signed in for the
# signed-in steps), and this terminal has Accessibility and Screen Recording access. Evidence stays local in
# OUT_DIR; it can contain account and library data, so never commit it to this public repository.
set -u
OUT="${1:?usage: tools/qa/req134_run.sh OUT_DIR}"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$OUT"
BIN="$OUT/req134_observe"
xcrun swiftc -O "$HERE/req134_observe.swift" -o "$BIN" || exit 2
DETAIL_TITLE="${XODE_DETAIL_TITLE:-Valor Mortis}"
SEARCH_QUERY="${XODE_SEARCH_QUERY:-mortis}"
STEPS="$OUT/steps.tsv"
printf 'step\treq\tcommand\texit\n' > "$STEPS"

run() { # run STEP REQS ARGS... ; retries while the owner is active (exit 3 from the idle guard)
    local step="$1" reqs="$2"; shift 2
    local attempt=0 status
    while :; do
        "$BIN" "$@" 2> "$OUT/.stderr"; status=$?
        if [ $status -eq 3 ] && grep -q "owner active" "$OUT/.stderr" && [ $attempt -lt 40 ]; then
            attempt=$((attempt + 1)); sleep 15; continue
        fi
        break
    done
    cat "$OUT/.stderr" >&2
    printf '%s\t%s\t%s\t%s\n' "$step" "$reqs" "$*" "$status" >> "$STEPS"
    return $status
}

run 00-preflight "all" preflight "$OUT" || { echo "Not ready; see $OUT/preflight.json"; exit 3; }
run 01-launch "REQ-75 REQ-119 REQ-4" snapshot "$OUT" 01-launch
run 02-library "REQ-5 REQ-60 REQ-61 REQ-62 REQ-63 REQ-64 REQ-85" press "$OUT" xodus.navigation.library
run 03-library-mid "REQ-64 REQ-76 REQ-21" scroll "$OUT" 0.5
run 04-library-end "REQ-64 REQ-21" scroll "$OUT" 1
run 05-library-top "REQ-15 REQ-66" scroll "$OUT" 0
for size in "1619 897" "1500 897" "1619 897" "1280 800" "1100 700"; do
    run "06-size-${size// /x}" "REQ-4 REQ-11" resize "$OUT" $size
done
run 07-library-filter-position "REQ-8" scroll "$OUT" 0.5
run 08-discover "REQ-5 REQ-65 REQ-91 REQ-60 REQ-61" press "$OUT" xodus.navigation.discover
run 09-discover-mid "REQ-91 REQ-21" scroll "$OUT" 0.5
run 10-back-to-library "REQ-8 REQ-9" press "$OUT" xodus.navigation.library
run 11-back-to-discover "REQ-8 REQ-9" press "$OUT" xodus.navigation.discover
run 12-search "REQ-10 REQ-59 REQ-60 REQ-61 REQ-62 REQ-9" set-search "$OUT" "$SEARCH_QUERY"
run 13-detail "REQ-11 REQ-23 REQ-62 REQ-63 REQ-77 REQ-61" press "$OUT" "label:View $DETAIL_TITLE"
run 14-detail-close "REQ-11" press "$OUT" "label:Close"
run 15-downloads "REQ-51 REQ-23" press "$OUT" xodus.navigation.downloads
run 16-account "REQ-93 REQ-49" press "$OUT" xodus.account
run 17-account-close "REQ-93" press "$OUT" "label:Done"
run 18-acknowledgments "REQ-117 REQ-122 REQ-19" press "$OUT" "menu:Acknowledgments…"
run 19-settings "REQ-118 REQ-20" press "$OUT" "menu:Settings…"
run 20-settings-general "REQ-118" press "$OUT" xodus.settings.general
run 21-library-final "REQ-21 REQ-8" press "$OUT" xodus.navigation.library

for png in "$OUT"/*.png; do
    [ -e "$png" ] && run "30-contrast-$(basename "$png" .png)" "REQ-19 REQ-20" contrast "$OUT" "$png"
done
run 40-signposts "REQ-21 REQ-75 REQ-119 REQ-9" signposts "$OUT" 30

python3 - "$OUT" <<'PY'
import glob, hashlib, json, os, sys
out = sys.argv[1]
findings, contrast = [], []
for path in sorted(glob.glob(os.path.join(out, "*-snapshot.json"))):
    data = json.load(open(path))
    for f in data.get("contentFindings", []):
        findings.append({"snapshot": data["label"], **f})
for path in sorted(glob.glob(os.path.join(out, "*-contrast.json"))):
    data = json.load(open(path))
    contrast.append({"png": data["png"], "lines": len(data["lines"]), "below": data["below"],
                     "lowest": min((l["ratio"] for l in data["lines"]), default=None)})
steps = [line.rstrip("\n").split("\t") for line in open(os.path.join(out, "steps.tsv"))][1:]
manifest = {}
for path in sorted(glob.glob(os.path.join(out, "*"))):
    if os.path.isfile(path) and not path.endswith(("manifest.json", "req134_observe", ".stderr")):
        manifest[os.path.basename(path)] = hashlib.sha256(open(path, "rb").read()).hexdigest()
summary = {"steps": [{"step": s[0], "reqs": s[1], "command": s[2], "exit": int(s[3])} for s in steps],
           "contentFindings": findings, "contrast": contrast}
json.dump(summary, open(os.path.join(out, "summary.json"), "w"), indent=2)
json.dump(manifest, open(os.path.join(out, "manifest.json"), "w"), indent=2, sort_keys=True)
failed = [s for s in summary["steps"] if s["exit"] != 0]
print(f"{len(steps)} steps, {len(failed)} not completed, {len(findings)} content findings, "
      f"{sum(c['below'] for c in contrast)} text lines below WCAG across {len(contrast)} captures")
for s in failed: print("  not completed:", s["step"], s["command"], "exit", s["exit"])
PY
