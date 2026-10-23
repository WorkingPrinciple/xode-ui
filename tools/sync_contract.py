#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Copy the pinned wire schema into the Swift resource without rewriting it."""
from pathlib import Path
import hashlib
import shutil

root = Path(__file__).resolve().parent.parent
source = root / "docs" / "contracts" / "management-v1.schema.json"
target = root / "Sources" / "XodusManagement" / "Resources" / source.name
target.parent.mkdir(parents=True, exist_ok=True)
shutil.copyfile(source, target)
print("Management schema SHA256:", hashlib.sha256(target.read_bytes()).hexdigest())
