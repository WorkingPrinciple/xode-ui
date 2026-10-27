#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail

if [[ $# != 1 || ! -x "$1/generate_keys" ]]; then
    echo "Usage: $0 /absolute/path/to/Sparkle-2.10.1/bin" >&2
    exit 2
fi

# COR-300: the owner already generated the key. Lookup only; never generate, import or export.
exec "$1/generate_keys" -p
