# Bound keyboard input v1

This single-key helper does not replace `s3-dialog.exe`, change retained
receipts, or qualify gameplay. It supports neither mouse, routes, dialogue
acceptance, nor automatic retries. A new runtime attempt still needs admission.

Build with the already installed `x86_64-w64-mingw32-gcc`, using
`-std=c11 -O2 -Wall -Wextra -Werror -Wl,--no-insert-timestamp`,
then `key-audited-v1.c -o <private-proof>/key-audited-v1.exe -luser32`.
Do not install a compiler or overwrite historical binaries.

`key-observe-v1.py` is an explicit keyboard-only observer seam. The old observer
can still perform **capture-only** work; never send keys through its legacy
binary. Invoke the new seam with all of:

```text
python3 key-observe-v1.py --binding /absolute/admitted-binding.json \
  --binding-sha256 SHA256 --mac-pid OBSERVED_MAC_PID \
  --key DECIMAL_VK --hold-ms 100 --evidence /absolute/unused-event.jsonl
```

The admitted private binding has this shape (placeholders are not runnable):

```json
{
  "schema": "s3-key-v1",
  "helper": {"path": "ABSOLUTE_NEW_EXE", "sha256": "SHA256"},
  "wine": {"path": "ABSOLUTE_RESOLVED_ENGINE_BINARY", "sha256": "SHA256"},
  "observer": {"path": "ABSOLUTE_KEY_OBSERVER", "sha256": "SHA256"},
  "prefix": "ABSOLUTE_EXISTING_PREFIX",
  "environment": {"WINEDEBUG": "-all"},
  "windowsPid": "REPLACE_WITH_OBSERVED_INTEGER",
  "title": "EXACT_OBSERVED_TITLE",
  "class": "EXACT_OBSERVED_CLASS"
}
```

Preserve the recipe's actual environment, not just the example above. The
wrapper checks executable hashes, a unique exact macOS PID/title CG window,
and checks the hashes again before invoking Wine. There is no default helper
or legacy fallback. Windows PID is a separately observed identity, never
derived from the macOS PID.

The helper rejects ambiguous visible exact titles, wrong PID/class, unsupported
scan codes, and missing/changed foreground identity. It witnesses HWND, actual
foreground HWND/PID/class/title and ticks immediately before down/up, reports
each SendInput count/error/tick, and checks identity after up. Hold is 1–1000ms.
Normal success requires one down and one up; delivery is not game handling.

If focus/identity changes before up, **no up is sent to another target** and
exit 6 explicitly says release was not delivered. Stop the lane and reconcile
the possibly held key with its owner; do not retry, restore focus, or infer
success. Windows focus can race any separate API check and SendInput; these
witnesses reduce ambiguity, not provide an atomic OS guarantee.

Run focused checks without Wine, windows, games, or screen access:

```text
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools/s3 -p 'test_*.py'
```

`key-test.c` runs the actual helper control flow against native mocked Win32
APIs using existing clang. This and cross-compilation do not validate real
Wine foreground behavior, key delivery, or gameplay.
