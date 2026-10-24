# Completed owned-window capture

Build with the installed Apple SDK, outside the repository:

```text
xcrun swiftc -parse-as-library -O tools/s3/capture-window.swift -o /private/proof/capture-window
```

Invoke `capture-window.py` with `--binary`, `--binary-sha256`, `--pid`,
`--window`, `--title`, `--output` and optional `--timeout-seconds` (default 10,
maximum 30). The observed macOS PID, window ID and exact title must belong to
the admitted app. The helper uses ScreenCaptureKit's one-shot image completion;
it initializes AppKit and refuses absent Screen Recording permission without
requesting it. It neither activates the app nor sends input.

Capture is passive: a different frontmost application is not a reason to
activate the game or refuse an otherwise exact PID/window/title/onscreen SCK
match. Do not put an external foreground/activation gate before this wrapper.
The desktop-independent window filter captures only the selected owned window,
not the whole screen or occluding applications. A successfully validated image
must still be inspected; metadata or renderer logs are not visible-render proof.
Input admission is separate and still requires the input sender's exact
foreground-window binding plus its process/image/creation/title/class guards.
Passive capture does not grant permission to send keys, click or focus a window.

Title controllers must call `LaunchAdmission.spawn` from `launch-admission.py`
instead of directly spawning after a separate shell precheck. The single-use
gate observes all Wine-named processes and checks the exact capture binary pin
in-process immediately before spawn, writes independently labelled private
outcomes, and refuses spawn on either failure or an unreadable observation.
Both checks run even if one fails. A consumed instance or existing receipt
cannot spawn again, including after a failed spawn. This is an admission
observation, not an OS-wide process lock or a substitute for the exclusive
lease and the controller's title/runtime/save/disk guards.

The wrapper owns and reaps only its capture child on timeout. A published image
requires child exit 0, matching completion identity/dimensions, complete PNG
chunks/checksums and decoded pixel data. Publication uses an exclusive atomic
link; existing images are never replaced. `<output>.capture.json` preserves
child PID, raw stdout/stderr, exit/timeout, timing and image hash. Failed staging
bytes remain in the named private directory, unpublished. Successful staging
is removed. The Swift source, compiler, binary and wrapper must be pinned by
the admitting packet; an idle-app capture is not game certification.

On identity mismatch only, stderr includes a JSON diagnostic with the expected
PID/window/title, match count, frontmost PID, and ScreenCaptureKit plus same-time
CoreGraphics candidates restricted to that PID or window ID. Optional metadata
is encoded as JSON null, including an unavailable CoreGraphics list; an empty
list means no matching candidate. Each candidate includes title, onscreen state
and layer. No unrelated window inventory is emitted. The existing wrapper
preserves this diagnostic privately in `<output>.capture.json`; it does not
reselect, retry or relax any identity/onscreen guard. Earlier CG observations
alone cannot establish which predicate failed in the later SCK snapshot.

## External stop ownership

During `retention-run.py run`, the external observer must atomically publish
`run-world/external-stop-reason.json` containing
`{"forcedStop": true, "reason": "specific observed failure"}` (or the equivalent
`external-consent-stop.json` with `forcedCleanup: true`). It must **not** invoke
the runner's cleanup function or write cleanup logs. The runner polls the stop
receipt and owns exact-prefix cleanup and final receipt generation.

Cleanup claims `cleanup-owner/` exclusively, retains stdout/stderr there, then
records its server/prefix and outcomes in `result.json`. A repeated call only
returns a completed identity/log-verified result, including any prior failure;
it never repeats uncertain side effects. Incomplete/concurrent ownership is an
explicit error. Legacy root-level cleanup logs are preserved, not overwritten
or interpreted as successful cleanup. External stop attribution always blocks
ordinary-quit qualification, even when CLI/Wine returned zero.

Run account-free fixtures with:

```text
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools/s3 -p 'test_*.py'
```
