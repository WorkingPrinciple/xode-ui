#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Verify the pinned wire schema and Swift resource agree without rewriting either."""
from pathlib import Path
import hashlib
import sys

root = Path(__file__).resolve().parent.parent
source = root / "docs" / "contracts" / "management-v1.schema.json"
target = root / "Sources" / "OdeManagement" / "Resources" / source.name
if source.read_bytes() != target.read_bytes():
    sys.exit("Management schema mismatch: update both contract copies from the accepted backend source.")
print("Management schema SHA256:", hashlib.sha256(target.read_bytes()).hexdigest())
