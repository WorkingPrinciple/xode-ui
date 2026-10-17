#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
set -eu
cd "$(dirname "$0")/.."
mkdir -p design/artwork/embedded
for name in harbor orbit ridge signal moss tide; do
    sips -s format jpeg -s formatOptions 82 \
        "Sources/XodusPreview/Resources/Artwork/$name.png" \
        --out "design/artwork/embedded/$name.jpg" >/dev/null
done
