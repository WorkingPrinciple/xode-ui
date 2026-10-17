#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Keep the separately versioned provider schema identical in docs and Swift resources."""
import argparse
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "docs" / "contracts" / "runtime-providers-v1.schema.json"
RESOURCE = ROOT / "Sources" / "XodusManagement" / "Resources" / SCHEMA.name
EXPECTED = "90c094e4585af059b5ebcfc3201260362e88aa642b50ec0388a03427260d55e9"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    source = SCHEMA.read_bytes().replace(b"\r\n", b"\n")
    if hashlib.sha256(source).hexdigest() != EXPECTED:
        raise SystemExit("Provider schema differs from reviewed public producer 9ef0f298.")
    if args.check:
        if not RESOURCE.exists() or RESOURCE.read_bytes().replace(b"\r\n", b"\n") != source:
            raise SystemExit("Swift provider schema resource is out of sync.")
    else:
        RESOURCE.write_bytes(source)


if __name__ == "__main__":
    main()
