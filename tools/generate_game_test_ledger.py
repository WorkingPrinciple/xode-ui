#!/usr/bin/env python3
"""Render the public MSI-family queue without inferring access or gameplay."""

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CATALOG = Path("Sources/XodusManagement/Resources/CompatibilityData/game-compatibility-v1.json")
STATE = Path("docs/game-test-ledger-state.json")
OUTPUT = Path("docs/GAME-TEST-LEDGER.md")
FORMATS = frozenset({"MSIXVC", "MSIX"})
FIELDS = (
    "historical", "installedObservation", "session1", "session2", "next", "evidence",
)


def cell(value):
    return str(value).replace("\\", "\\\\").replace("|", "\\|").replace("\r", " ").replace("\n", " ")


def eligible_products(catalog):
    products = catalog["products"]
    return {
        product_id: row for product_id, row in products.items()
        if row.get("pcPackageIdentified") is True and row.get("packageFormat") in FORMATS
    }


def render(catalog, state, digest):
    if state["schemaVersion"] != 1 or state["session"] != 2:
        raise ValueError("Expected the reviewed Session 2 ledger state")
    products = catalog["products"]
    eligible = eligible_products(catalog)
    for product_id, result in state["products"].items():
        if product_id not in eligible:
            raise ValueError(f"Reviewed result outside the MSI-family queue: {product_id}")
        if set(result) != set(FIELDS) or any(not isinstance(result[k], str) or not result[k] for k in FIELDS):
            raise ValueError(f"Incomplete reviewed result: {product_id}")
    formats = Counter(row.get("packageFormat", "Unspecified") for row in products.values())
    selected_formats = Counter(row["packageFormat"] for row in eligible.values())
    counts = ", ".join(f"{name}: {count}" for name, count in sorted(formats.items()))
    selected_counts = ", ".join(f"{name}: {count}" for name, count in sorted(selected_formats.items()))
    lines = [
        "# Joint-product game test ledger",
        "",
        "Generated from the checked public catalogue and explicitly reviewed test state.",
        "Do not edit this generated file; update `docs/game-test-ledger-state.json` and run",
        "`python3 tools/generate_game_test_ledger.py`.",
        "",
        "## Scope and current position",
        "",
        f"- **Session {state['session']}**, state dated {state['asOf']}; deadline **{state['deadline']}**.",
        f"- Catalogue: **{len(products)} product IDs**; checked **{catalog['checkedAt']}**, market **{catalog['market']}**.",
        f"- Exact source: `{CATALOG.as_posix()}`; SHA-256 `{digest}`.",
        f"- Package-format totals: {counts}.",
        f"- **MSI-family queue: {len(eligible)} IDs** ({selected_counts}); **{len(products) - len(eligible)} excluded**.",
        "- Filter: `pcPackageIdentified == true` AND `packageFormat in {MSIXVC, MSIX}`.",
        "- These are product/edition IDs, not a deduplicated franchise count, owned library,",
        "  supported-game list, or a promise that every title can be tested in 24 hours.",
        "- Public package identification does not establish entitlement, download access,",
        "  installability, engine support, or gameplay. No MSI installer claim is made.",
        "",
        "See [the constitution, session register, audit and fix ledger](GAME-ENGINE-TESTS.md).",
        "",
    ]
    lines.extend(f"- {note}" for note in state["notes"])
    lines.extend([
        "",
        "## Next tests",
        "",
        "1. Recover the historically working No Man's Sky and Hogwarts joint configurations.",
        "2. Preserve source/artifact/engine/shim identities and rollback; identify the exact",
        "   remaining integration or permission gap without repeating old hash-based assumptions.",
        "3. Exercise the admitted joint route with resident content, free Wine first and",
        "   CrossOver fallback; then expand through legitimate access to other queued packages.",
        "",
        "## Reviewed priority titles",
        "",
        "| Product ID | Title | Historical baseline | Installed observation | Session 1 | Session 2 | Next action | Evidence |",
        "|---|---|---|---|---|---|---|---|",
    ])
    for product_id, result in sorted(state["products"].items(), key=lambda pair: products[pair[0]]["title"].casefold()):
        values = [product_id, products[product_id]["title"], *(result[key] for key in FIELDS)]
        lines.append("| " + " | ".join(cell(value) for value in values) + " |")
    lines.extend([
        "",
        "## Complete MSI-family queue",
        "",
        "Unreviewed local state and account access stay **unknown**. `Not attempted` means",
        "no launch evidence in these test sessions, not an engine failure. Priority rows",
        "above retain dated local observations and historical results separately.",
        "",
        "| # | Product ID | Title | Package | Local observation | Session 1 | Session 2 | Current account access | Next action |",
        "|---|---|---|---|---|---|---|---|---|",
    ])
    defaults = {
        "installedObservation": "Unknown",
        "session1": "Not attempted",
        "session2": "Not attempted",
        "next": "Resolve legitimate access and package before launch",
    }
    for index, (product_id, row) in enumerate(sorted(eligible.items(), key=lambda pair: (pair[1]["title"].casefold(), pair[0])), 1):
        result = state["products"].get(product_id, defaults)
        values = [
            index, product_id, row["title"], row["packageFormat"],
            result["installedObservation"], result["session1"], result["session2"],
            "Unknown", result["next"],
        ]
        lines.append("| " + " | ".join(cell(value) for value in values) + " |")
    lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail if the committed ledger is stale")
    args = parser.parse_args()
    raw = (ROOT / CATALOG).read_bytes()
    catalog = json.loads(raw)
    state = json.loads((ROOT / STATE).read_text())
    content = render(catalog, state, hashlib.sha256(raw).hexdigest())
    output = ROOT / OUTPUT
    if args.check:
        if not output.exists() or output.read_text() != content:
            parser.exit(1, "Game test ledger is missing or stale; regenerate it.\n")
    else:
        output.write_text(content)
    print(f"{len(eligible_products(catalog))} MSI-family product IDs; ledger {'checked' if args.check else 'generated'}.")


if __name__ == "__main__":
    main()
