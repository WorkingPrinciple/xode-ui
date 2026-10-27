#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""REQ-32: extracts redacted sign-in and licence outcome lines from one qualification run.

Reads only `<run>/stderr.log` and `<run>/result.json`, keeps the fixed outcome lines,
redacts identifiers, and fails closed if anything token-like survives redaction.
The raw log is never copied.
"""
import argparse
import json
from pathlib import Path
import re
import sys

# Runtime outcome lines (warn+gdkc only): fixed text plus an HRESULT, no identities.
OUTCOMES = {
    "signIn": re.compile(r"gdkc:.*xodus outcome: sign-in "),
    "userAddResult": re.compile(r"gdkc:.*xodus outcome: XUserAddResult "),
    "gameLicence": re.compile(r"gdkc:.*(xodus outcome: game licence |Microsoft-issued matching full-game licen[cs]e validated"
                              r"|Authoritative Microsoft game licen[cs]e validation failed)"),
    "storeLicenseResult": re.compile(r"gdkc:.*xodus outcome: XStoreQueryGameLicenseResult "),
    "signInFailure": re.compile(r"gdkc:.*user initialization failed at "),
}
REQUIRED = ("signIn", "userAddResult", "gameLicence", "storeLicenseResult")
MAX_LINES_PER_OUTCOME = 8
MAX_LINE_BYTES = 400

REDACTIONS = (
    (re.compile(r"xuid\(\s*[0-9]+\s*\)", re.IGNORECASE), "xuid(N)"),
    (re.compile(r"(?i)\b(xuid|gamertag|gtg|userhash|uhs)\s*[=:]\s*\"?[^\s\",;]+"), r"\1=<redacted>"),
    (re.compile(r"\b[0-9]{10,}\b"), "<N>"),
)
# Anything still matching one of these after redaction aborts the extraction.
TOKEN_LIKE = (
    re.compile(r"eyJ[A-Za-z0-9_-]{8,}"),                        # JWT / JWE header
    re.compile(r"XBL[0-9.]*\s*x="),                             # XBL authorization header
    re.compile(r"(?i)\b(bearer|authorization|rpsticket|t=|ticket=|token=|proof=|signature=)"),
    re.compile(r"[A-Za-z0-9+/_=-]{40,}"),                       # long opaque blob
    re.compile(r"[0-9a-fA-F]{32,}"),                            # long hex secret
    re.compile(r"(?i)\bxuid\([0-9]"),                           # unredacted XUID
)


class OutcomeError(ValueError):
    pass


def redact(line):
    for pattern, replacement in REDACTIONS:
        line = pattern.sub(replacement, line)
    return line


def require_token_free(line):
    for pattern in TOKEN_LIKE:
        if pattern.search(line):
            raise OutcomeError("Token-like content survived redaction; nothing was written")


def extract(run_dir):
    run_dir = Path(run_dir)
    result = json.loads((run_dir / "result.json").read_text())
    diagnostic = result.get("diagnostic") or {}
    outcomes = {name: [] for name in OUTCOMES}
    with (run_dir / "stderr.log").open("r", encoding="utf-8", errors="replace") as log:
        for raw in log:
            for name, pattern in OUTCOMES.items():
                if pattern.search(raw) and len(outcomes[name]) < MAX_LINES_PER_OUTCOME:
                    line = redact(raw.rstrip("\n"))[:MAX_LINE_BYTES]
                    require_token_free(line)
                    outcomes[name].append(line)
    return {
        "schema": "xode.run-outcome.v1",
        "run": run_dir.name,
        "exitCode": result.get("exit_code"),
        "engine": result.get("engine"),
        "wineDebug": diagnostic.get("wine_debug"),
        "logTruncated": (diagnostic.get("log") or {}).get("truncated"),
        "outcomes": outcomes,
        "missing": sorted(name for name in REQUIRED if not outcomes[name]),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_dir", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        outcome = extract(args.run_dir)
    except OutcomeError as error:
        print(error, file=sys.stderr)
        return 2
    text = json.dumps(outcome, indent=2, sort_keys=True) + "\n"
    require_token_free_document(text)
    args.output.write_text(text)
    print(json.dumps({"missing": outcome["missing"], "exitCode": outcome["exitCode"]}))
    return 0


def require_token_free_document(text):
    for line in text.splitlines():
        if "\"run\"" in line or "\"wineDebug\"" in line:
            continue
        require_token_free(line)


if __name__ == "__main__":
    sys.exit(main())
