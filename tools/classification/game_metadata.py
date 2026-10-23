#!/usr/bin/env python3
"""Bounded public catalogue capture and deterministic, policy-free metadata export."""

from __future__ import annotations

import argparse
from collections import Counter
import datetime as dt
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse

from classify_catalogue import (
    CATALOGUE, DATA_DIR, FORMATS, desktop_packages, fetch_json, load_json,
    normalized_title, validate,
)

OUTPUT = DATA_DIR / "PublicMetadata"
SCHEMA_ID = "urn:xodus:game-metadata:1"
FEED_ID = "609d944c-d395-4c0a-9ea4-e9f39b52c1ad"
RULES = "desktop-released-base-v1"
ANTI_CHEAT_REFERENCE_HOSTS = {
    "raw.githubusercontent.com", "www.pcgamingwiki.com",
    "support.riotgames.com", "support.halowaypoint.com",
    "www.ageofempires.com", "support.ageofempires.com",
}
MAX_PRODUCTS = 600
MAX_BATCHES = 30
MAX_SECONDS = 600
MAX_BYTES = 64 * 1024 * 1024
PACKAGE_FIELDS = (
    "skuId", "skuType", "isBundle", "isPreOrder", "bundledProductIds", "platforms",
    "rawFormat", "family", "contentId", "packageId", "packageFamilyName", "version",
    "architectures",
)
SKU_FIELDS = ("skuId", "isBundle", "isPreOrder", "bundledProductIds")
SOURCE_FIELDS = ("url", "checkedAt", "responseSha256", "responseBytes", "httpDate")


def canonical_bytes(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode()


def digest(value):
    return hashlib.sha256(value).hexdigest()


def timestamp(value):
    if not isinstance(value, str):
        return None
    try:
        result = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        return result if result.tzinfo else None
    except ValueError:
        return None


def feed_url(market):
    return "https://catalog.gamepass.com/sigls/v3?" + urllib.parse.urlencode({
        "id": FEED_ID, "market": market, "language": "en-US",
        "platformContext": "pc", "subscriptionContext": "cfq7ttc0kgq8",
    })


def feed_ids(payload):
    if not isinstance(payload, list) or not payload or not isinstance(payload[0], dict):
        raise ValueError("Invalid scoped Game Pass feed")
    if payload[0].get("siglId", payload[0].get("id", FEED_ID)) != FEED_ID:
        raise ValueError("Unexpected feed identity")
    if payload[0].get("title") != "All PC Games":
        raise ValueError("Feed is not All PC Games")
    ids = [item.get("id") for item in payload[1:] if isinstance(item, dict)]
    if not ids or len(ids) > MAX_PRODUCTS or any(
        not isinstance(item, str) or not re.fullmatch(r"[A-Z0-9]{12}", item) for item in ids
    ):
        raise ValueError("Invalid product identity or feed size")
    return sorted(set(ids))


def catalogue_facts(product, receipt, market):
    """Never persist descriptions, artwork, URLs to packages, or raw response bodies."""
    props = product.get("Properties") or {}
    localized = [item for item in product.get("LocalizedProperties", [])
                 if item.get("Language", "").lower() in {"en", "en-us"}
                 and market in item.get("Markets", [])]
    titles = {item.get("ProductTitle") for item in localized if item.get("ProductTitle")}
    title = next(iter(titles)) if len(titles) == 1 else None
    market_properties = [item for item in product.get("MarketProperties", [])
                         if market in item.get("Markets", [])]
    dates = sorted({item["OriginalReleaseDate"] for item in market_properties
                    if isinstance(item.get("OriginalReleaseDate"), str)})
    full_skus = []
    for availability in product.get("DisplaySkuAvailabilities", []):
        sku = availability.get("Sku") or {}
        if sku.get("SkuType") != "full":
            continue
        sp = sku.get("Properties") or {}
        full_skus.append({
            "skuId": sku.get("SkuId"),
            "isBundle": sp.get("IsBundle"),
            "isPreOrder": sp.get("IsPreOrder"),
            "bundledProductIds": sorted({
                item["BigId"] for item in sp.get("BundledSkus", [])
                if isinstance(item, dict) and isinstance(item.get("BigId"), str)
            }),
        })
    return {
        "extractorVersion": RULES,
        "source": receipt,
        "productId": product["ProductId"],
        "title": title,
        "titleLanguages": sorted({item["Language"] for item in localized}),
        "productKind": product.get("ProductKind"),
        "productType": product.get("ProductType"),
        "productFamily": product.get("ProductFamily"),
        "isDemo": props.get("IsDemo"),
        "productGroupId": props.get("ProductGroupId"),
        "marketListingReleaseDates": dates,
        "fullSkus": sorted(full_skus, key=lambda item: str(item["skuId"])),
        "packages": desktop_packages(product),
    }


def capture(database):
    market = database["market"]
    started = time.monotonic()
    total_bytes = 0
    requests = 0
    receipts = []

    def read(url):
        nonlocal total_bytes, requests
        if requests >= MAX_BATCHES + 1 or time.monotonic() - started > MAX_SECONDS:
            raise RuntimeError("Metadata capture request/time budget exhausted")
        requests += 1
        payload, receipt = fetch_json(url)
        total_bytes += receipt["responseBytes"]
        if total_bytes > MAX_BYTES:
            raise RuntimeError("Metadata capture byte budget exhausted")
        receipts.append(receipt)
        return payload, receipt

    payload, membership = read(feed_url(market))
    ids = feed_ids(payload)
    batches = [ids[i:i + 20] for i in range(0, len(ids), 20)]
    if len(batches) > MAX_BATCHES:
        raise RuntimeError("Too many metadata batches")
    facts = {}
    errors = []
    for batch in batches:
        url = "https://displaycatalog.mp.microsoft.com/v7.0/products?" + urllib.parse.urlencode({
            "bigIds": ",".join(batch), "market": market, "languages": "en-US",
        })
        response, receipt = read(url)
        if not isinstance(response, dict) or not isinstance(response.get("Products"), list):
            raise ValueError("Malformed public catalogue response")
        seen = set()
        for product in response["Products"]:
            sid = product.get("ProductId")
            if sid not in batch or sid in seen:
                raise ValueError("Duplicate/unrequested product in catalogue response")
            seen.add(sid)
            facts[sid] = catalogue_facts(product, receipt, market)
        for sid in sorted(set(batch) - seen):
            errors.append({"productId": sid, "stage": "catalogue", "reason": "product-not-returned"})
    # Existing legacy fields/action policy are deliberately not rewritten.
    for sid, product in database["products"].items():
        if sid in facts:
            product["desktopCatalog"] = facts[sid]
    database["desktopCatalogSnapshot"] = {
        "scope": {"market": market, "language": "en-US", "platform": "Windows.Desktop",
                  "plan": "cfq7ttc0kgq8", "feedId": FEED_ID, "feedTitle": "All PC Games"},
        "membership": membership,
        "productIds": ids,
        "checkedAt": max(item["checkedAt"] for item in receipts),
        "status": "partial" if errors else "complete",
        "errors": errors,
        "missingCanonicalProductIds": sorted(set(ids) - set(database["products"])),
        "requests": requests,
        "maximumHttpAttempts": requests * 3,
        "responseBytes": total_bytes,
        "budgets": {"maxRequests": MAX_BATCHES + 1, "maxHttpAttempts": (MAX_BATCHES + 1) * 3,
                    "maxSecondsBeforeNextRequest": MAX_SECONDS, "maxResponseBytes": MAX_BYTES},
    }
    return database


def eligibility(facts, checked_at):
    reasons = []
    if not facts:
        return ["no-scoped-desktop-catalogue"]
    if not facts.get("title"):
        reasons.append("missing-exact-localized-title")
    if (facts.get("productKind"), facts.get("productType"), facts.get("productFamily")) != (
        "Game", "Game", "Games"
    ):
        reasons.append("not-explicit-game-product")
    if facts.get("isDemo") is not False:
        reasons.append("demo-or-demo-state-unknown")
    full = [sku for sku in facts.get("fullSkus", [])
            if sku.get("isBundle") is False and sku.get("isPreOrder") is False
            and not sku.get("bundledProductIds")]
    if not full:
        reasons.append("bundle-preorder-or-full-sku-role-unknown")
    if re.search(r"\b(launcher|season pass|upgrade|premium|deluxe|ultimate|collection|bundle|demo|trilogy|preview)\b",
                 facts.get("title") or "", re.I):
        reasons.append("ambiguous-edition-launcher-or-collection")
    dates = facts.get("marketListingReleaseDates", [])
    release = timestamp(dates[0]) if len(dates) == 1 else None
    if not release or release > timestamp(checked_at):
        reasons.append("unreleased-or-market-release-date-ambiguous")
    sku_ids = {sku["skuId"] for sku in full}
    packages = [p for p in facts.get("packages", [])
                if p.get("skuId") in sku_ids and p.get("family") in set(FORMATS.values())]
    if not packages:
        reasons.append("no-known-desktop-full-game-format")
    identities = {p.get("packageFamilyName") or p.get("contentId") for p in packages}
    if not identities or None in identities:
        reasons.append("missing-desktop-content-identity")
    if not facts.get("productGroupId") and not identities:
        reasons.append("base-game-identity-ambiguous")
    return reasons


def anti_cheat_metadata(product):
    ac = product["antiCheat"]
    evidence = product["antiCheatEvidence"]
    if ac.lower() == "none":
        return {
            "claim": "not-detected" if evidence["type"] == "package-scan" else "manual-override",
            "technologies": [],
            "checkedAt": evidence["checkedAt"],
            "buildBinding": "unknown",
            "scope": "Not verified absence; legacy launch policy is separate.",
            "sources": [],
        }
    source = evidence.get("source", "")
    parsed = urllib.parse.urlsplit(source)
    if (parsed.scheme != "https" or parsed.hostname not in ANTI_CHEAT_REFERENCE_HOSTS
            or parsed.query or parsed.fragment or parsed.username or parsed.password):
        raise ValueError("Anti-cheat source is not an allowlisted public factual URL")
    # PCGamingWiki redistribution terms are not established: links only, no imported claim.
    pcgw = "pcgamingwiki.com" in urllib.parse.urlsplit(source).netloc
    references = [source]
    for check in evidence.get("publicChecks", []):
        url = urllib.parse.urlsplit(check.get("source", ""))
        if (url.scheme == "https" and url.hostname in ANTI_CHEAT_REFERENCE_HOSTS
                and not url.query and not url.fragment and not url.username and not url.password):
            references.append(check["source"])
    return {
        "claim": "unknown" if ac.lower() == "unknown" or pcgw else "reported-present",
        "technologies": [] if ac.lower() == "unknown" or pcgw else ac.split("; "),
        "checkedAt": evidence["checkedAt"],
        "buildBinding": "unknown",
        "scope": "Reference only; no current Xbox-PC build absence or compatibility claim.",
        "sources": list(dict.fromkeys(references)),
    }


def project(database):
    snapshot = database.get("desktopCatalogSnapshot")
    if not snapshot:
        raise ValueError("Capture a scoped snapshot first")
    if timestamp(snapshot.get("checkedAt")) is None:
        raise ValueError("Invalid snapshot observation time")
    records = []
    exclusions = []
    candidates = []
    for sid in snapshot["productIds"]:
        product = database["products"].get(sid)
        facts = product.get("desktopCatalog") if product else None
        reasons = eligibility(facts, snapshot["checkedAt"])
        if facts and facts.get("extractorVersion") != RULES:
            raise ValueError("Unrecognized catalogue extractor")
        if facts:
            if facts.get("productId") != sid:
                raise ValueError("Catalogue product identity mismatch")
            source = facts["source"]
            parsed = urllib.parse.urlsplit(source["url"])
            query = urllib.parse.parse_qs(parsed.query)
            if (parsed.scheme != "https" or parsed.hostname != "displaycatalog.mp.microsoft.com"
                    or parsed.path != "/v7.0/products" or parsed.username or parsed.password
                    or set(query) != {"bigIds", "market", "languages"}
                    or query["market"] != [snapshot["scope"]["market"]]
                    or query["languages"] != ["en-US"]
                    or sid not in query["bigIds"][0].split(",")):
                raise ValueError("Catalogue source identity/scope mismatch")
            source_time = timestamp(source["checkedAt"])
            if (not source_time or not timestamp(snapshot["membership"]["checkedAt"])
                    or not timestamp(snapshot["checkedAt"])
                    or not timestamp(snapshot["membership"]["checkedAt"]) <= source_time <= timestamp(snapshot["checkedAt"])
                    or any(error["productId"] == sid for error in snapshot["errors"])):
                reasons.append("catalogue-evidence-not-current-complete-scope")
            # Explicit allowlist, never serialize authoring/QA objects wholesale.
            record = {
                "productId": sid, "title": facts.get("title"),
                "role": {
                    "catalogKind": facts.get("productKind"),
                    "catalogType": facts.get("productType"),
                    "catalogFamily": facts.get("productFamily"),
                    "isDemo": facts.get("isDemo"),
                    "productGroupId": facts.get("productGroupId"),
                    "fullSkus": [{k: sku[k] for k in SKU_FIELDS}
                                 for sku in facts.get("fullSkus", [])],
                },
                "titleLanguages": facts.get("titleLanguages", []),
                "marketListingReleaseDates": facts.get("marketListingReleaseDates", []),
                "packages": [{k: package[k] for k in PACKAGE_FIELDS}
                             for package in facts["packages"]],
                "source": {k: facts["source"][k] for k in SOURCE_FIELDS},
                "antiCheat": anti_cheat_metadata(product),
                "qualifiedBaseGame": False,
                "qualificationExclusions": reasons,
            }
            records.append(record)
            if not reasons:
                candidates.append(record)
        if reasons:
            exclusions.append({"productId": sid, "reasons": reasons})
    # Connected identity components deduplicate editions sharing group, content, PFN or title.
    # Multiple different IDs in a component are all excluded: no invented representative.
    parents = {r["productId"]: r["productId"] for r in candidates}

    def root(sid):
        while parents[sid] != sid:
            sid = parents[sid]
        return sid

    identities = {}
    for row in candidates:
        keys = {"title:" + normalized_title(row["title"])}
        group = row["role"]["productGroupId"]
        if group:
            keys.add("group:" + group)
        for p in row["packages"]:
            for field in ("packageFamilyName", "contentId"):
                if p.get(field):
                    keys.add(field + ":" + p[field])
        for key in keys:
            if key in identities:
                parents[root(row["productId"])] = root(identities[key])
            else:
                identities[key] = row["productId"]
    groups = Counter(root(r["productId"]) for r in candidates)
    duplicate_groups = [
        sorted(row["productId"] for row in candidates if root(row["productId"]) == key)
        for key, size in groups.items() if size > 1
    ]
    for row in candidates:
        if groups[root(row["productId"])] > 1:
            row["qualificationExclusions"] = ["duplicate-or-edition-identity-ambiguous"]
            exclusions.append({"productId": row["productId"], "reasons": row["qualificationExclusions"]})
        else:
            row["qualifiedBaseGame"] = True
    audit = {
        "rulesVersion": RULES,
        "currentFeedProducts": len(snapshot["productIds"]),
        "canonicalOverlap": len(set(snapshot["productIds"]) & set(database["products"])),
        "desktopKnownFormatProducts": sum(any(
            p["family"] != "unknown" for p in r["packages"]) for r in records),
        "qualifiedDistinctReleasedBaseGames": sum(r["qualifiedBaseGame"] for r in records),
        "duplicateIdentityGroups": sorted(duplicate_groups),
        "exclusions": sorted(exclusions, key=lambda r: r["productId"]),
        "definition": "Current scoped feed; explicit full non-bundle non-preorder Game; past Store market listing date; known Windows.Desktop package; exclude ambiguous editions, collections/trilogies, previews, launchers and duplicate group/content/family/title components. Catalogue-only, not installed/tested/entitled.",
    }
    return {
        "schema": SCHEMA_ID, "schemaVersion": 1, "minimumReaderVersion": 1,
        "snapshotId": digest(canonical_bytes(snapshot)),
        "observedAt": snapshot["checkedAt"], "scope": snapshot["scope"],
        "status": "partial" if snapshot["errors"] or snapshot["missingCanonicalProductIds"] else "complete",
        "errors": [*snapshot["errors"], *[
            {"productId": sid, "stage": "authoring", "reason": "product-not-in-canonical-database"}
            for sid in snapshot["missingCanonicalProductIds"]
        ]],
        "membership": {k: snapshot["membership"][k] for k in SOURCE_FIELDS},
        "rights": {"releaseStatus": "hold", "reason": "Microsoft catalogue/feed bulk redistribution permission unverified; PCGamingWiki claims not copied; no public release authorized."},
        "counts": {k: v for k, v in audit.items() if k in (
            "currentFeedProducts", "canonicalOverlap", "desktopKnownFormatProducts",
            "qualifiedDistinctReleasedBaseGames")},
        "products": sorted(records, key=lambda r: r["productId"]),
    }, audit


def metadata_schema():
    """The small closed schema is also used by the dependency-free local validator."""
    def obj(properties):
        return {"type": "object", "properties": properties, "required": list(properties),
                "additionalProperties": False}

    def array(items, maximum=4096):
        return {"type": "array", "items": items, "maxItems": maximum}

    text = {"type": "string", "maxLength": 2048}
    nullable_text = {"type": ["string", "null"], "maxLength": 2048}
    boolean = {"type": "boolean"}
    nullable_bool = {"type": ["boolean", "null"]}
    count = {"type": "integer", "minimum": 0}
    sha = {"type": "string", "pattern": "^[a-f0-9]{64}$"}
    product_id = {"type": "string", "pattern": "^[A-Z0-9]{12}$"}
    source = obj({
        "url": text, "checkedAt": text, "responseSha256": sha,
        "responseBytes": count, "httpDate": nullable_text,
    })
    sku = obj({
        "skuId": nullable_text, "isBundle": nullable_bool, "isPreOrder": nullable_bool,
        "bundledProductIds": array(product_id),
    })
    package = obj({
        "skuId": nullable_text, "skuType": nullable_text,
        "isBundle": nullable_bool, "isPreOrder": nullable_bool,
        "bundledProductIds": array(product_id),
        "platforms": array(text), "rawFormat": text,
        "family": {"enum": ["MSIXVC", "EAppx", "Appx", "MSIX", "unknown"]},
        "contentId": nullable_text, "packageId": nullable_text,
        "packageFamilyName": nullable_text, "version": nullable_text,
        "architectures": array(text),
    })
    result = obj({
        "schema": {"const": SCHEMA_ID}, "schemaVersion": {"const": 1},
        "minimumReaderVersion": {"const": 1}, "snapshotId": sha,
        "observedAt": text,
        "scope": obj({k: text for k in ("market", "language", "platform", "plan", "feedId", "feedTitle")}),
        "status": {"enum": ["complete", "partial"]},
        "errors": array(obj({"productId": product_id, "stage": text, "reason": text})),
        "membership": source,
        "rights": obj({"releaseStatus": {"const": "hold"}, "reason": text}),
        "counts": obj({k: count for k in ("currentFeedProducts", "canonicalOverlap",
                                        "desktopKnownFormatProducts", "qualifiedDistinctReleasedBaseGames")}),
        "products": array(obj({
            "productId": product_id, "title": nullable_text,
            "titleLanguages": array(text),
            "role": obj({
                "catalogKind": nullable_text, "catalogType": nullable_text,
                "catalogFamily": nullable_text, "isDemo": nullable_bool,
                "productGroupId": nullable_text, "fullSkus": array(sku),
            }),
            "marketListingReleaseDates": array(text), "packages": array(package),
            "source": source,
            "antiCheat": obj({
                "claim": {"enum": ["unknown", "reported-present", "not-detected", "manual-override"]},
                "technologies": array(text), "checkedAt": text,
                "buildBinding": {"const": "unknown"}, "scope": text, "sources": array(text),
            }),
            "qualifiedBaseGame": boolean, "qualificationExclusions": array(text),
        }), MAX_PRODUCTS),
    })
    return {"$schema": "https://json-schema.org/draft/2020-12/schema",
            "$id": SCHEMA_ID, **result}


def validate_schema(value, schema, location="$"):
    """Validate exactly the JSON Schema keywords used by metadata_schema, no packages."""
    types = {
        "object": lambda x: isinstance(x, dict),
        "array": lambda x: isinstance(x, list),
        "string": lambda x: isinstance(x, str),
        "integer": lambda x: isinstance(x, int) and not isinstance(x, bool),
        "boolean": lambda x: isinstance(x, bool),
        "null": lambda x: x is None,
    }
    expected = schema.get("type")
    if expected and not any(types[t](value) for t in ([expected] if isinstance(expected, str) else expected)):
        raise ValueError(f"{location}: invalid schema type")
    if "const" in schema and (type(value) is not type(schema["const"]) or value != schema["const"]):
        raise ValueError(f"{location}: schema constant mismatch")
    if "enum" in schema and value not in schema["enum"]:
        raise ValueError(f"{location}: invalid enumeration")
    if isinstance(value, dict) and expected == "object":
        if set(value) != set(schema["properties"]):
            raise ValueError(f"{location}: missing or unexpected metadata fields")
        for key, item in value.items():
            validate_schema(item, schema["properties"][key], location + "." + key)
    elif isinstance(value, list):
        if len(value) > schema.get("maxItems", len(value)):
            raise ValueError(f"{location}: array bound exceeded")
        for i, item in enumerate(value):
            validate_schema(item, schema["items"], f"{location}[{i}]")
    elif isinstance(value, str):
        if len(value) > schema.get("maxLength", len(value)):
            raise ValueError(f"{location}: text bound exceeded")
        if "pattern" in schema and not re.search(schema["pattern"], value):
            raise ValueError(f"{location}: pattern mismatch")
    elif types["integer"](value) and value < schema.get("minimum", value):
        raise ValueError(f"{location}: integer below minimum")


def export(database, source_commit):
    projection, audit = project(database)
    validate_schema(projection, metadata_schema())
    OUTPUT.mkdir(exist_ok=True)
    files = {
        "game-metadata-v1.json": canonical_bytes(projection),
        "count-audit-v1.json": canonical_bytes(audit),
        "game-metadata-v1.schema.json": canonical_bytes(metadata_schema()),
        "AWACY-LICENSE.txt": (DATA_DIR / "AWACY-LICENSE.txt").read_bytes(),
    }
    files["NOTICES.txt"] = (OUTPUT / "NOTICES.txt").read_bytes()
    manifest = {
        "schemaVersion": 1, "metadataSchema": SCHEMA_ID, "minimumReaderVersion": 1,
        "sourceCommit": source_commit,
        "authoringDatabaseSha256": digest(canonical_bytes(database)),
        "sourceCode": {name: digest((Path(__file__).parent / name).read_bytes())
                       for name in ("game_metadata.py", "classify_catalogue.py")},
        "snapshotId": projection["snapshotId"],
        "observedAt": projection["observedAt"],
        "releaseStatus": "hold",
        "signature": None, "updaterSupported": False,
        "files": {name: {"bytes": len(raw), "sha256": digest(raw)}
                  for name, raw in sorted(files.items())},
    }
    files["manifest-v1.json"] = canonical_bytes(manifest)
    for name, raw in files.items():
        (OUTPUT / name).write_bytes(raw)
    (OUTPUT / "SHA256SUMS").write_text("".join(
        f"{digest(raw)}  {name}\n" for name, raw in sorted(files.items())))
    return projection, audit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture", action="store_true", help="Finite public feed/catalogue fetch; no account APIs")
    parser.add_argument("--export", action="store_true", help="Deterministic offline metadata-only candidate")
    args = parser.parse_args()
    database = load_json(CATALOGUE)
    validate(database)
    if args.capture:
        original = json.loads(json.dumps(database))
        database = capture(database)
        validate(database)
        for sid, row in original["products"].items():
            assert {k: v for k, v in database["products"][sid].items() if k != "desktopCatalog"} == {
                k: v for k, v in row.items() if k != "desktopCatalog"
            }, f"Legacy action-policy mutation: {sid}"
        CATALOGUE.write_bytes(canonical_bytes(database))
    if args.export:
        commit = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
        projection, audit = export(database, commit)
        print(json.dumps(projection["counts"], sort_keys=True))
        print("Release HOLD: source redistribution rights unverified; no app action policy changed.")
    if not args.capture and not args.export:
        raise ValueError("Specify --capture and/or --export")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, urllib.error.URLError) as error:
        print(f"metadata error: {error}", file=sys.stderr)
        raise SystemExit(1) from error
