# Read-only Windows exit observer v1

Candidate only: no game, Wine, prefix creation, screen input, debugger, injection
or qualification is authorized by building this helper. This tool does not
normalize an exit code or change CLI/runtime behavior.

## Build and offline checks

Use the existing `x86_64-w64-mingw32-gcc`, without installing dependencies:

```text
x86_64-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -Werror \
  -Wl,--no-insert-timestamp tools/s3/exit-observe-v1.c \
  -o <NEW_PRIVATE_PROOF>/exit-observe-v1.exe
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools/s3 -p 'test_*.py'
```

Build twice into unused proof paths and compare bytes. Preserve a private
provenance JSON with exact argv, resolved compiler path/version/SHA-256, source
and fixture hashes, both binary hashes and actual test result. Do not overwrite
historical binaries. Hashes belong to the actual build, not example constants.
Native clang fixtures execute the real control flow against mocked Win32 APIs;
neither those fixtures nor a PE build establish real Wine behavior.

## Required future launch binding

Before a separately admitted run, bind the canonical game run ID, exact existing
prefix, engine/registry/runtime/CLI hashes and environment, observer source,
compiler and binary hashes, raw helper stdout/stderr and helper OS return code.
Do not infer a Windows PID from a macOS PID, reuse historical PID 224, or select
the first process named DREDGE. The existing run's monitor must identify the
owned `DREDGE` / `UnityWndClass` Windows PID and exact launched image path.
The staged image may have a different path on each run.

After that ownership witness, read the creation identity without input:

```text
exit-observe-v1.exe identity OBSERVED_WINDOWS_PID EXACT_WINDOWS_IMAGE_PATH
exit-observe-v1.exe wait OBSERVED_WINDOWS_PID EXACT_WINDOWS_IMAGE_PATH \
  CREATION_HEX_FROM_IDENTITY WAIT_MS
```

These are helper arguments, not authorization to run Wine. Invocation must use
the admitted engine and **same existing prefix**; no engine fallback. Paths must
be absolute drive-letter Windows paths with printable ASCII, exactly matching
`QueryFullProcessImageNameA` (case included). Other encodings/UNC paths are
explicitly refused, not guessed or lossy-converted. Identity mode requires a
currently unsignaled process. Wait mode rechecks the executable and creation
FILETIME (16 hexadecimal digits), protecting against PID reuse between calls.
It then retains that one process handle through the wait; it never reopens by PID.
The external launch witness must also pin the staged executable's bytes; a path
and creation time alone do not authenticate file contents or ownership.

Both modes request exactly `SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION`,
non-inheritable. Identity is flushed before a single bounded wait, and `armed`
is flushed after binding. Wait is 1-600000 ms, never INFINITE. The operator must
see `armed` before separately authorized ordinary Quit input. No polling loop,
termination, focus/window manipulation, input, debugger or process injection
exists. A platform API can fail; that is explicit observer failure, not fallback.

`process_exit` is emitted only after `WAIT_OBJECT_0` and a successful
`GetExitCodeProcess`. It preserves the full unsigned DWORD and eight-digit hex:
255 and 4294967295 (`0xffffffff`) remain different. A signaled process can
legitimately return 259 (`0x00000103`); an unsignaled wait timeout is **not** an
exit, and never queries/interprets `STILL_ACTIVE` as one. The game DWORD does not
become the helper's own exit code.

| Helper status | Meaning |
|---|---|
| 0 | Identity ready, or signaled process exit successfully observed |
| 2 | Invalid arguments |
| 3 | OpenProcess failed, including access denied |
| 4 | Identity query failed/mismatched, or discovery found an exited process |
| 5 | Wait timed out; no game exit claim |
| 6 | Wait failed or returned an unexpected value |
| 7 | GetExitCodeProcess failed |
| 8 | CloseHandle failed; earlier emitted data remains raw, helper failed |

Preserve every record and the helper return status, not just `process_exit`.
There is no catch-all success or nonzero normalization. Correlate with S2's
existing canonical `wine-exit.json` and `result.json` for the **same run**:
Windows game DWORD, observer status and direct Wine-host child status are three
distinct observations. Do not duplicate or rewrite that host receipt.

## Bounded title-log capture plan (not executed)

Only after separate admission and prefix/save availability are resolved, use
the known exact prefix:

```text
~/Library/Application Support/XodusCLI/prefixes/s2-small-9MSVVM5NS9L6-creation-dx11-d3dmetal-passive-v1
```

The only planned log paths are its
`drive_c/users/crossover/AppData/LocalLow/Black Salt Games/DREDGE/Player.log`
and sibling `Player-prev.log`. Record before-run existence, regular-file versus
symlink, size, mtime and hash, then copy each existing stopped before/after log
to a new run-owned protected proof directory. Refuse symlinks and files over
16 MiB; record missing/oversize/unreadable explicitly without crawling other
users, prefixes or payloads. Capture after ordinary quit and before any cleanup
or another launch can overwrite it. Do not create the absent historical prefix,
restore/edit a save or assume a log belongs to the run from its filename alone.
Compare timestamps/content to the new run's identity/timeline. If absent, retain
that absence; a separately approved Unity `-logFile` option would be a recipe
change, not an automatic fallback.

The observer does not capture SEH exceptions/stacks and cannot alone establish
whether a DWORD was deliberate, exceptional or a shutdown defect. Any such
remaining ambiguity must stay explicit; this candidate supplies exit provenance,
not a DREDGE compatibility verdict.
