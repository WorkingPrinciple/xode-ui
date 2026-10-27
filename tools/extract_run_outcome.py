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
    # L12 0fec3d7: XStore product queries report counts only.
    "storeProducts": re.compile(r"gdkc:.*xodus outcome: XStore (entitled|by-id|associated) products "),
}
REQUIRED = ("signIn", "userAddResult", "gameLicence", "storeLicenseResult")
SIGN_IN_ONLY = ("signIn", "userAddResult")
# Titles that query their licence at startup must show the licence lines; others pass on sign-in alone.
EXPECTED = {
    "9NR1R1XWLCNB": REQUIRED,      # Forza Horizon 6
    "9PDC8J1BSV8B": REQUIRED,      # Easy Delivery Co.
    "9P8DL6W0JBB8": SIGN_IN_ONLY,  # Hades: no licence query observed (run c6f0ac9f)
}


def expected(product, override=None):
    if override:
        return tuple(override)
    return EXPECTED.get(product, REQUIRED)
# A kept line only passes when it carries the explicit success form; FAILED or non-zero status fails.
SUCCESS = {
    "signIn": re.compile(r"xodus outcome: sign-in OK status 0\.?$"),
    "userAddResult": re.compile(r"xodus outcome: XUserAddResult status 0\.?$"),
    "gameLicence": re.compile(r"xodus outcome: game licence validated status 0\.?$"),
    "storeLicenseResult": re.compile(r"xodus outcome: XStoreQueryGameLicenseResult status 0 isActive 1\.?$"),
}


def verdict(name, lines):
    if not lines:
        return "missing"
    outcome_lines = [line for line in lines if "xodus outcome:" in line]
    if not outcome_lines:
        return "missing"
    return "pass" if all(SUCCESS[name].search(line) for line in outcome_lines) else "fail"
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


def extract(run_dir, expect=None):
    run_dir = Path(run_dir)
    result = json.loads((run_dir / "result.json").read_text())
    required = expected(result.get("product"), expect)
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
        "product": result.get("product"),
        "expected": list(required),
        "missing": sorted(name for name in required if not outcomes[name]),
        "verdicts": {name: verdict(name, outcomes[name]) for name in REQUIRED},
        # A logged outcome must be a success even when not required; an absent optional one is fine.
        "pass": all(verdict(name, outcomes[name]) == "pass" for name in required)
                and all(verdict(name, outcomes[name]) != "fail" for name in REQUIRED)
                and not outcomes["signInFailure"] and result.get("exit_code") == 0,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_dir", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--expect", choices=REQUIRED, action="append",
                        help="Override the per-title expected outcomes (repeatable)")
    args = parser.parse_args()
    try:
        outcome = extract(args.run_dir, args.expect)
    except OutcomeError as error:
        print(error, file=sys.stderr)
        return 2
    text = json.dumps(outcome, indent=2, sort_keys=True) + "\n"
    require_token_free_document(text)
    args.output.write_text(text)
    print(json.dumps({"pass": outcome["pass"], "verdicts": outcome["verdicts"], "exitCode": outcome["exitCode"]}))
    return 0 if outcome["pass"] else 1


def require_token_free_document(text):
    for line in text.splitlines():
        if "\"run\"" in line or "\"wineDebug\"" in line or "\"product\"" in line:
            continue
        require_token_free(line)


if __name__ == "__main__":
    sys.exit(main())
