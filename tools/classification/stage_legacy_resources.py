#!/usr/bin/env python3
"""Stage a private, release-held legacy reader resource set; never publish it."""

from __future__ import annotations

import argparse
from collections import Counter
import copy
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import parse_qs, urlsplit

from classify_catalogue import CATALOGUE, DATA_DIR, load_json
from game_metadata import canonical_bytes, digest, timestamp

OUTPUT = Path(__file__).parent / "staged-legacy-v1"
CONSUMER = "36994efed478939a85e80df1f143c0e96bae465a"
READER = "Sources/XodusPreview/OfflineGameCompatibility.swift"
ENTRY = ("title", "packageFormat", "pcPackageIdentified", "antiCheat",
         "technologyReferences", "referencePlatforms")
HEADER = ("version", "checkedAt", "market", "packageSource", "antiCheatReference")
SOURCE = ("source", "checkedAt", "method")
SCAN = ("complete", "fileCount", "result", "fileListSha256", "matches",
        "symlinkCount", "signatureSet", "signatureVersion")
CHECK = ("sourceType", "source", "checkedAt", "result")
PUBLISHER = ("title", "technologies", "scope", "source", "checkedAt")
HOSTS = {
    "displaycatalog.mp.microsoft.com", "raw.githubusercontent.com",
    "www.pcgamingwiki.com", "www.xbox.com", "store.steampowered.com",
    "www.nomanssky.com", "support.riotgames.com", "support.halowaypoint.com",
}


def pick(value, fields):
    return {key: copy.deepcopy(value[key]) for key in fields if key in value}


def supported(row):
    return ((row.get("packageFormat") or "").strip().upper() == "MSIXVC"
            and (row.get("antiCheat") or "unknown").strip().lower() == "none")


def source_valid(value):
    url = urlsplit(value.get("source", ""))
    return (url.scheme == "https" and bool(url.hostname) and not url.username
            and not url.password and re.fullmatch(
                r"\d{4}-\d{2}-\d{2}(T.*Z)?", value.get("checkedAt", "")) is not None)


def clearance(product_id, row):
    """Mirror the pinned S5 raw-JSON predicate, not a new clearance policy."""
    if not (row.get("packageFormat") == "MSIXVC"
            and (row.get("antiCheat") or "").strip().lower() == "none"
            and row.get("supported01") is True
            and row.get("pcPackageIdentified") is True):
        return False
    package, ac = row.get("packageFormatEvidence", {}), row.get("antiCheatEvidence", {})
    checks = ac.get("publicChecks", [])
    if not (source_valid(package) and package.get("method") and package.get("observedFormats")
            and source_valid(ac) and ac.get("method") and len(checks) == 3
            and {c.get("sourceType") for c in checks} == {"awacy", "pcgamingwiki", "publisher"}
            and all(source_valid(c) and c.get("result") for c in checks)):
        return False
    if ac.get("type") == "public-source":
        return (ac.get("mode") == "user-directed-correction"
                and ac["method"].startswith("User-directed classification: ")
                and "packageScan" not in ac)
    scan = ac.get("packageScan", {})
    return (ac.get("type") == "package-scan" and scan.get("complete") is True
            and type(scan.get("fileCount")) is int and scan["fileCount"] > 0
            and scan.get("result") == "no-known-signature"
            and re.fullmatch(r"[a-f0-9]{64}", scan.get("fileListSha256", "")) is not None
            and scan.get("matches") == {} and scan.get("symlinkCount") == 0
            and bool(scan.get("signatureSet")) and scan.get("signatureVersion", 0) > 0
            and scan.get("packageIdentity", {}).get("storeId") == product_id)


def audit_text(value, key=""):
    if isinstance(value, dict):
        for name, item in value.items():
            audit_text(item, name)
    elif isinstance(value, list):
        for item in value:
            audit_text(item, key)
    elif isinstance(value, str):
        if re.search(r"/Users/|/Volumes/|~/|file://|proofs[/\\]|Bearer\s|"
                     r"access_token|refresh_token|password|keychain", value, re.I):
            raise ValueError(f"Private or account value in {key}")
        if key in {"source", "packageSource", "antiCheatReference"}:
            url = urlsplit(value)
            if (url.scheme != "https" or url.hostname not in HOSTS or url.username
                    or url.password or url.port or url.fragment):
                raise ValueError(f"Unsafe source in {key}")
            allowed = {"bigIds", "market", "languages"} if url.hostname == "displaycatalog.mp.microsoft.com" else set()
            query = parse_qs(url.query, keep_blank_values=True)
            if set(query) - allowed:
                raise ValueError(f"Unexpected source query in {key}")
            patterns = {"bigIds": r"[A-Z0-9]{12}(,[A-Z0-9]{12})*",
                        "market": r"[A-Z]{2}", "languages": r"[a-z]{2}-[A-Z]{2}"}
            if any(len(values) != 1 or not re.fullmatch(patterns[name], values[0])
                   for name, values in query.items()):
                raise ValueError(f"Invalid source query value in {key}")
        elif key != "signatureSet" and re.search(r"\.(exe|dll|manifest|dat)\b", value, re.I):
            raise ValueError(f"Raw filename in {key}")


def project(database, publisher):
    if (database["version"] != 1 or publisher["version"] != 1
            or timestamp(database["checkedAt"]) is None):
        raise ValueError("Unsupported legacy version or observation date")
    result = pick(database, HEADER)
    result["products"] = {}
    for product_id, original in sorted(database["products"].items()):
        row = pick(original, ENTRY)
        # Match the reader's decodeIfPresent default; never manufacture clearance.
        if row.get("antiCheat") is None:
            row["antiCheat"] = "unknown"
        if (not isinstance(row["antiCheat"], str) or not row["antiCheat"].strip()
                or len(row["antiCheat"].encode()) > 512
                or any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in row["antiCheat"])):
            raise ValueError(f"Invalid legacy anti-cheat value: {product_id}")
        if supported(original):
            if not clearance(product_id, original):
                raise ValueError(f"Existing supported entry lacks reader clearance: {product_id}")
            row["supported01"] = original["supported01"]
            package = pick(original["packageFormatEvidence"], (*SOURCE, "observedFormats"))
            package["method"] = "Legacy catalogue observation; exact observed formats retained."
            row["packageFormatEvidence"] = package
            old_ac = original["antiCheatEvidence"]
            ac = pick(old_ac, (*SOURCE, "type", "mode"))
            ac["publicChecks"] = [pick(check, CHECK) for check in old_ac["publicChecks"]]
            if ac["type"] == "package-scan":
                ac["method"] = "Complete path-signature inventory: not detected; not independently verified absence."
                scan = pick(old_ac["packageScan"], SCAN)
                scan["packageIdentity"] = pick(old_ac["packageScan"]["packageIdentity"], ("storeId",))
                ac["packageScan"] = scan
            else:
                ac["method"] = "User-directed classification: legacy eligibility override; not independently verified absence or runtime qualification."
            row["antiCheatEvidence"] = ac
            if not clearance(product_id, row):
                raise ValueError(f"Projection changed clearance: {product_id}")
        if supported(original) != supported(row):
            raise ValueError(f"Projection changed policy: {product_id}")
        result["products"][product_id] = row
    published = {"version": publisher["version"], "products": {
        product_id: pick(row, PUBLISHER)
        for product_id, row in sorted(publisher["products"].items())
    }}
    for product_id, row in published["products"].items():
        if (result["products"].get(product_id, {}).get("title") != row["title"]
                or not row["technologies"] or len(row["technologies"]) > 16
                or any(not t or len(t.encode()) > 128 for t in row["technologies"])
                or not row["scope"] or len(row["scope"].encode()) > 4096
                or urlsplit(row["source"]).hostname not in {"support.riotgames.com", "support.halowaypoint.com"}
                or timestamp(row["checkedAt"]) is None):
            raise ValueError(f"Publisher reader mismatch: {product_id}")
    audit_text(result)
    audit_text(published)
    validate(result, schema())
    validate(published, schema(publisher=True))
    return result, published


def schema(publisher=False):
    def obj(fields, required=None):
        return {"type": "object", "properties": fields, "additionalProperties": False,
                "required": list(fields) if required is None else list(required)}
    text = {"type": "string"}
    strings = {"type": "array", "items": text, "maxItems": 16}
    nullable = {"type": ["string", "null"]}
    source = {key: text for key in SOURCE}
    scan = obj({
        "complete": {"const": True}, "fileCount": {"type": "integer", "minimum": 1},
        "result": {"const": "no-known-signature"},
        "fileListSha256": {"type": "string", "pattern": "^[a-f0-9]{64}$"},
        "matches": obj({}), "symlinkCount": {"const": 0},
        "signatureSet": {"const": "anti-cheat-signatures-v1.json"},
        "signatureVersion": {"type": "integer", "minimum": 1},
        "packageIdentity": obj({"storeId": {"type": "string", "pattern": "^[A-Z0-9]{12}$"}}),
    })
    ac = obj({**source, "type": {"enum": ["package-scan", "public-source"]}, "mode": text,
              "publicChecks": {"type": "array", "maxItems": 3,
                               "items": obj({key: text for key in CHECK})},
              "packageScan": scan}, (*SOURCE, "type", "mode", "publicChecks"))
    entry = obj({
        "title": nullable, "packageFormat": nullable,
        "pcPackageIdentified": {"type": "boolean"}, "antiCheat": text,
        "technologyReferences": strings, "referencePlatforms": strings,
        "supported01": {"const": True},
        "packageFormatEvidence": obj({**source, "observedFormats": strings}),
        "antiCheatEvidence": ac,
    }, ("pcPackageIdentified", "antiCheat", "technologyReferences", "referencePlatforms"))
    publisher_entry = obj({"title": text, "technologies": strings, "scope": text,
                           "source": text, "checkedAt": text})
    products = {"type": "object", "maxProperties": 4096,
                "propertyNames": {"pattern": "^[A-Z0-9]{12}$"},
                "additionalProperties": publisher_entry if publisher else entry}
    fields = ({"version": {"const": 1}, "products": products} if publisher else {
        **{key: text for key in HEADER if key != "version"},
        "version": {"const": 1}, "products": products})
    return {"$schema": "https://json-schema.org/draft/2020-12/schema",
            "$id": "urn:xodus:private-legacy-resource:publisher:1" if publisher
            else "urn:xodus:private-legacy-resource:catalogue:1", **obj(fields)}


def validate(value, rule):
    """Validate only the JSON Schema keywords emitted above."""
    types = {"object": dict, "array": list, "string": str, "integer": int,
             "boolean": bool, "null": type(None)}
    kind = rule.get("type")
    if kind and not any(type(value) is types[t] for t in ([kind] if isinstance(kind, str) else kind)):
        raise ValueError("Schema type mismatch")
    if "const" in rule and (type(value) is not type(rule["const"]) or value != rule["const"]):
        raise ValueError("Schema constant mismatch")
    if "enum" in rule and value not in rule["enum"]:
        raise ValueError("Schema enum mismatch")
    if isinstance(value, dict):
        properties = rule.get("properties", {})
        if not set(rule.get("required", [])) <= value.keys():
            raise ValueError("Missing schema field")
        if len(value) > rule.get("maxProperties", len(value)):
            raise ValueError("Too many records")
        for key, item in value.items():
            if key not in properties and rule.get("additionalProperties") is False:
                raise ValueError("Unexpected schema field")
            if "propertyNames" in rule:
                validate(key, rule["propertyNames"])
            validate(item, properties.get(key, rule.get("additionalProperties", {})))
    elif isinstance(value, list):
        if len(value) > rule.get("maxItems", len(value)):
            raise ValueError("Too many array entries")
        for item in value:
            validate(item, rule["items"])
    elif isinstance(value, str) and "pattern" in rule and not re.fullmatch(rule["pattern"], value):
        raise ValueError("Schema pattern mismatch")
    elif type(value) is int and value < rule.get("minimum", value):
        raise ValueError("Schema minimum mismatch")


NOTICE = """PRIVATE RELEASE-HELD LEGACY RESOURCE CANDIDATE
Not authorized for public redistribution or app bundling.
Source redistribution terms (including Microsoft and PCGamingWiki) remain
unresolved. Publisher factual summaries/URLs and three public checks are retained
only for the existing reader's private policy predicate, not as rights clearance.
AWACY-derived references retain the accompanying MIT notice.
The seven legacy path-signature inventories mean NOT DETECTED, never independently
verified absence. Two user-directed overrides remain overrides. The legacy
antiCheat="none" string is retained solely to preserve existing policy; it is not
a new descriptive absence claim. No runtime qualification is granted.
Only minimum scan summaries and non-secret inventory SHA256 provenance are
retained under the explicit private-candidate allowance. No raw inventory,
local roots, private package versions, manifest names, filenames or proofs.
No updater. The containing authoring directory must never be copied wholesale.
"""


def export(database, publisher, output=OUTPUT):
    catalogue, published = project(database, publisher)
    reader = subprocess.check_output(["git", "show", f"{CONSUMER}:{READER}"])
    files = {
        "CompatibilityData/game-compatibility-v1.json": canonical_bytes(catalogue),
        "CompatibilityData/publisher-anti-cheat-v1.json": canonical_bytes(published),
        "CompatibilityData/AWACY-LICENSE.txt": (DATA_DIR / "AWACY-LICENSE.txt").read_bytes(),
        "CompatibilityData/NOTICES.txt": NOTICE.encode(),
        "legacy-resource-v1.schema.json": canonical_bytes(schema()),
        "publisher-resource-v1.schema.json": canonical_bytes(schema(publisher=True)),
    }
    if len(files["CompatibilityData/game-compatibility-v1.json"]) > 4 * 1024 * 1024:
        raise ValueError("Legacy reader byte bound exceeded")
    if len(files["CompatibilityData/publisher-anti-cheat-v1.json"]) > 256 * 1024:
        raise ValueError("Publisher reader byte bound exceeded")
    claims = Counter(
        "not-detected" if r["antiCheatEvidence"]["type"] == "package-scan" else "manual-override"
        for r in catalogue["products"].values() if supported(r))
    audit = {
        "releaseStatus": "hold", "privateCandidateOnly": True,
        "consumerCommit": CONSUMER, "consumerPath": READER, "consumerSha256": digest(reader),
        "sourceDatabaseSha256": digest(canonical_bytes(database)),
        "sourcePublisherSha256": digest(canonical_bytes(publisher)),
        "sanitizerSha256": digest(Path(__file__).read_bytes()),
        "products": len(catalogue["products"]), "publisherProducts": len(published["products"]),
        "legacyPolicyCleared": sum(supported(r) for r in catalogue["products"].values()),
        "descriptiveClearanceMeaning": dict(claims), "verifiedAbsence": 0,
        "fieldAudit": {
            "removedTopLevelFields": sorted(set(database) - set(catalogue)),
            "removedProductFieldCounts": dict(sorted(Counter(
                key for product_id, row in database["products"].items()
                for key in set(row) - set(catalogue["products"][product_id])
            ).items())),
            "retainedInventoryDigests": claims["not-detected"],
            "retainedPrivateRoots": 0, "retainedRawInventories": 0,
            "retainedManifestNames": 0, "retainedPrivatePackageVersions": 0,
        },
        "fieldAllowlist": {
            "header": list(HEADER), "entry": list(ENTRY),
            "clearedEntryOnly": ["supported01", "packageFormatEvidence", "antiCheatEvidence"],
            "packageFormatEvidence": [*SOURCE, "observedFormats"],
            "antiCheatEvidence": [*SOURCE, "type", "mode", "publicChecks", "packageScan"],
            "publicCheck": list(CHECK), "scan": [*SCAN, "packageIdentity"],
            "packageIdentity": ["storeId"], "publisherEntry": list(PUBLISHER),
        },
        "files": {name: {"bytes": len(raw), "sha256": digest(raw)}
                  for name, raw in sorted(files.items())},
    }
    files["private-stage-manifest-v1.json"] = canonical_bytes(audit)
    files["SHA256SUMS"] = "".join(
        f"{digest(raw)}  {name}\n" for name, raw in sorted(files.items())).encode()
    output = Path(output)
    if output.exists() and any(
        p.relative_to(output).as_posix() not in files
        for p in output.rglob("*") if p.is_file() or p.is_symlink()
    ):
        raise ValueError("Unexpected existing stage file; refusing mixed resource set")
    if output.is_symlink() or any(p.is_symlink() for p in output.parents):
        raise ValueError("Stage output must not redirect through symlinks")
    for name in files:
        path = output / name
        if path.is_symlink() or any(p.is_symlink() for p in path.parents):
            raise ValueError("Stage file must not redirect through symlinks")
    for name, raw in files.items():
        path = output / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)
    return audit


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=OUTPUT)
    args = parser.parse_args()
    audit = export(load_json(CATALOGUE), load_json(DATA_DIR / "publisher-anti-cheat-v1.json"), args.output)
    print(json.dumps({k: audit[k] for k in ("products", "publisherProducts",
                                          "legacyPolicyCleared", "descriptiveClearanceMeaning")}))
    print("PRIVATE RELEASE HOLD. Staged under tools only; no app resources changed.")
