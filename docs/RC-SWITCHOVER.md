# c22029c release-candidate switch-over

## Hold and exact artifacts

**Do not execute the switch-over until S3 confirms the HK normal Quit-to-Menu save, clean
quit, actual tile relaunch and retained save, and the coordinator explicitly
releases the install/activation hold.** A missing process alone is not that
handoff. Do not launch a second app copy: it shares the bundle ID, account
and service state. Do not terminate a game, wineserver or service to force
this procedure through.

This runbook installs the already signed/stapled app, not a rebuild of newer
source. Its identity is:

| Artifact | Identity |
|---|---|
| App source | `c22029c76fe76e68703f63490ba01cf184848b0f` |
| App tree | `4ed1bb9dad781a0b5f528f37df2a6d02fd8c720c` |
| Bundled CLI | `adf8aed7203c33da9b884d3f0b6d2b9f67b10b760931ee89a35df5255d3aa604` |
| Windows monitor | `d5968170c91535385935319a33cb5f680237778cfc85b5e74c5e1be66bdf5535` |
| Apple app acceptance | `ed3af0d4-5536-4137-912c-725b496777fe` |
| Apple DMG acceptance | `dd8ddf27-e239-4973-b8e8-cfaea96adf54` |
| Stapled DMG SHA256 | `8e0034fa675574a5b4f47f6951fa6c13117127e3947f5ee7ad74be9f0404783a` |
| Rollback app source | `c1190ccbd61e4b2f3b241db5eefb4d1aafed3600` |
| Rollback CLI | `ffc4aa3040394dd5ae679f665e522f5ead12c92da20376942e9508dc0d4f060d` |

The external release receipt and all signature/stapler/Gatekeeper/Apple logs
are in `.build/local-candidates/Ode-release-fd3zvkex/`.

Run the following sections from the S5 worktree in one shell, stopping on
every failure. Variables do not persist between separate tool executions.

```sh
set -eu
umask 077
ROOT=/Users/dragoshont/src/copilot-worktrees/ode-macos-app/dragoshont-super-spork
RELEASE="$ROOT/.build/local-candidates/Ode-release-fd3zvkex"
RC="$RELEASE/Ode-refresh-5bl7geeo/Ode to X Local Candidate.app"
LIVE="$HOME/Applications/Ode to X Local Candidate.app"
BACKUP="$ROOT/.build/local-candidates/Ode-rollback-c1190cc.app"
REJECTED="$ROOT/.build/local-candidates/Ode-retired-c22029c.app"
STAGED="$HOME/Applications/Ode to X Incoming c22029c.app"
EVIDENCE=$(mktemp -d "$ROOT/.build/local-candidates/Ode-switchover-XXXXXXXX")
export RC LIVE BACKUP REJECTED STAGED EVIDENCE RELEASE
```

## Safe copy-only dry-run

This section needs no handoff and **must not contain `open`, an executable
invocation from the bundle, or any quit operation**.

```sh
COPY_ROOT=$(mktemp -d "$ROOT/.build/local-candidates/Ode-switch-check-XXXXXXXX")
ditto "$RC" "$COPY_ROOT/Ode to X Local Candidate.app"
codesign --verify --deep --strict "$COPY_ROOT/Ode to X Local Candidate.app" \
  > "$COPY_ROOT/codesign.log" 2>&1
xcrun stapler validate "$COPY_ROOT/Ode to X Local Candidate.app" \
  > "$COPY_ROOT/stapler.log" 2>&1
spctl --assess --type execute --verbose=4 "$COPY_ROOT/Ode to X Local Candidate.app" \
  > "$COPY_ROOT/gatekeeper.log" 2>&1
shasum -a 256 "$COPY_ROOT/Ode to X Local Candidate.app/Contents/Resources/OdeEngine/ode-cli"
```

Executed copy-only evidence:
`.build/local-candidates/Ode-switch-check-WTCoFSi7/copy-check-receipt.json`.
All three checks exited 0; Gatekeeper reported `Notarized Developer ID`.
No copy was launched and nothing was installed. These are not first-launch
or gameplay observations.

## Authorized switch-over only

First record S3's handoff and the coordinator's explicit release in the
session. Confirm all games are normally closed, including the final retained
HK relaunch. The following check only verifies the known HK processes are
gone; it does not replace S3's handoff or prove every game on the host stopped.

```sh
python3 - <<'PY'
import subprocess
for pid in (21156, 21463, 88227, 88315):
    result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "pid=,lstart=,comm="],
                            capture_output=True, text=True)
    assert result.returncode != 0, "Known HK process still present; stop and reconcile its identity, do not kill it"
print("Known HK CLI/game absent; explicit saved-relaunch handoff is still required")
PY
```

Verify the old/new sources, then request a normal quit of **only the exact
installed app**. AppKit `terminate()` is a quit request, not a signal; if it
is refused or the app remains alive, stop rather than escalating to a kill.

```sh
python3 - <<'PY'
import json, os, pathlib
live = pathlib.Path(os.environ["LIVE"])
rc = pathlib.Path(os.environ["RC"])
for app, expected in ((live, "c1190ccbd61e4b2f3b241db5eefb4d1aafed3600"),
                      (rc, "c22029c76fe76e68703f63490ba01cf184848b0f")):
    r = json.loads((app/"Contents/Resources/local-candidate-receipt.json").read_text())
    assert r["appSource"]["commit"] == expected
for name in ("BACKUP", "REJECTED", "STAGED"):
    assert not pathlib.Path(os.environ[name]).exists(), "Preserved/staged destination already exists; reconcile it"
PY
swift -e '
import AppKit
import Foundation
let path = ProcessInfo.processInfo.environment["LIVE"]!
let matches = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == path }
guard matches.count == 1, let app = matches.first else { fatalError("Expected exactly one installed app") }
guard app.terminate() else { fatalError("Normal quit refused; no kill allowed") }
let deadline = Date().addingTimeInterval(30)
while !app.isTerminated && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
guard app.isTerminated else { fatalError("App did not quit; stop and inspect without killing") }
'
python3 - <<'PY'
import os, subprocess
root = os.environ["LIVE"] + "/Contents/"
listing = subprocess.check_output(["/bin/ps", "-ww", "-axo", "pid=,comm="], text=True)
assert not any(root in row for row in listing.splitlines()), "Old app child remains; stop, do not kill it"
PY
```

Stage and verify before moving the previous app. Preserve c1190cc by moving
its exact bundle, including signatures, extended attributes and old receipt.
No game, prefix, account, saves or defaults directory is moved or deleted.

```sh
ditto "$RC" "$STAGED"
codesign --verify --deep --strict "$STAGED" > "$EVIDENCE/staged-signature.log" 2>&1
xcrun stapler validate "$STAGED" > "$EVIDENCE/staged-ticket.log" 2>&1
spctl --assess --type execute --verbose=4 "$STAGED" > "$EVIDENCE/staged-gatekeeper.log" 2>&1
mv "$LIVE" "$BACKUP"
mv "$STAGED" "$LIVE"
codesign --verify --deep --strict "$LIVE" > "$EVIDENCE/installed-signature.log" 2>&1
xcrun stapler validate "$LIVE" > "$EVIDENCE/installed-ticket.log" 2>&1
spctl --assess --type execute --verbose=4 "$LIVE" > "$EVIDENCE/first-launch-gatekeeper.log" 2>&1
open "$LIVE"
```

If either move fails, stop and inspect the exact paths. Do not overwrite or
delete either bundle to retry. Do not strip quarantine, modify its signed
receipt or change system Gatekeeper policy.

## Actual first-window, CLI-in-use and tile checks

After `open`, observe the actual first window and any macOS Gatekeeper or
Keychain UI. Let the user complete native prompts. A prelaunch `spctl` pass
is not proof that the first window appeared or account access succeeded.

After normal service readiness, run:

```sh
python3 - <<'PY' > "$EVIDENCE/cli-in-use.json"
import hashlib, json, os, pathlib, subprocess
app = pathlib.Path(os.environ["LIVE"])
expected = app/"Contents/Resources/OdeEngine/ode-cli"
digest = hashlib.sha256(expected.read_bytes()).hexdigest()
assert digest == "adf8aed7203c33da9b884d3f0b6d2b9f67b10b760931ee89a35df5255d3aa604"
listing = subprocess.check_output(["/bin/ps", "-ww", "-axo", "pid=,comm="], text=True)
pids = [int(row.split(maxsplit=1)[0]) for row in listing.splitlines()
        if len(row.split(maxsplit=1)) == 2 and row.split(maxsplit=1)[1] == str(expected)]
assert pids, "Exact installed adf8 CLI is not running; do not infer success from file hash alone"
births = subprocess.check_output(["/bin/ps", "-p", ",".join(map(str,pids)), "-o", "pid=,lstart=,comm="], text=True)
print(json.dumps({"cli":str(expected),"sha256":digest,"runningPIDs":pids,"identities":births.splitlines()}, indent=2))
PY
screencapture -x -D 1 "$EVIDENCE/first-library-display-1.png"
```

Inspect the actual library, without pressing Play just to inspect a button:

| Tile | Required observation on this exact candidate |
|---|---|
| HK | Authoritative `complete` snapshot gives Play; no View in Xbox Store. Preserve S3's verified prefix/save. |
| NMS | `complete` gives Play. Default recipe is `nms-free-gptk3-d3dshared` with original `de6f1c...` legacy; explicit CrossOver fallback remains distinct. Do not spawn without a lane/input grant. |
| Minecraft | **This candidate shows Open for the installed official native launcher, not Play.** Its native provider has no MSIXVC completeness claim. Record this mismatch against the requested complete/Play acceptance; do not call Open game-running proof. Structured native-provider integration remains unfinished. |

Incomplete status must show Install/Resume/Repair as applicable, never Play
just because a directory, config or previous installation record exists.
Record actual errors instead of forcing the expected state. Retain the
full-display screenshot, app PID/source, CLI birth/hash and status evidence.
No screenshot or readiness state counts as app_e2e save/relaunch proof.

## Rollback to preserved c1190cc

Rollback requires all newly launched games to have quit normally and explicit
input ownership. If a game is running, stop this runbook and coordinate its
normal quit; **do not terminate the app to stop the game**.

Use the same normal-quit Swift command above while `LIVE` points to the
installed RC. Then run the old-app-child absence check above. Preserve the
RC too; never delete game data or restore account/defaults snapshots.

```sh
test -d "$BACKUP"
test ! -e "$REJECTED"
python3 - <<'PY'
import hashlib, json, os, pathlib
app = pathlib.Path(os.environ["BACKUP"])
receipt = json.loads((app/"Contents/Resources/local-candidate-receipt.json").read_text())
assert receipt["appSource"]["commit"] == "c1190ccbd61e4b2f3b241db5eefb4d1aafed3600"
assert hashlib.sha256((app/"Contents/Resources/OdeEngine/ode-cli").read_bytes()).hexdigest() == \
    "ffc4aa3040394dd5ae679f665e522f5ead12c92da20376942e9508dc0d4f060d"
PY
codesign --verify --deep --strict "$BACKUP" > "$EVIDENCE/rollback-signature.log" 2>&1
mv "$LIVE" "$REJECTED"
mv "$BACKUP" "$LIVE"
open "$LIVE"
```

The historical c1190cc bundle was Developer-ID signed but not notarized.
Rollback restores its exact historical status; it does not gain the RC's
ticket. If macOS refuses to open it, record the refusal and stop. Do not
remove quarantine or disable Gatekeeper. Record successful first window,
account/library recovery and actual ffc4 CLI identity separately; rollback
has not been exercised merely because the backup exists.
