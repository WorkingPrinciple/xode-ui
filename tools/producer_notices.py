#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Prepare local producer notices from hash-bound Cargo metadata and archives."""
import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import subprocess
import tarfile
import tomllib

from shipping_pair import owned_bytes, require, unique_object


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_json(path, expected=None):
    _, data = owned_bytes(path, expected, bounded=32 * 1024 * 1024)
    return json.loads(data, object_pairs_hook=unique_object)


def git_bytes(source, *arguments):
    return subprocess.check_output(["git", "-C", str(source), *arguments])


def notice_members(archive):
    notices = {}
    with tarfile.open(fileobj=io.BytesIO(archive)) as stream:
        for member in stream:
            path = PurePosixPath(member.name)
            require(not path.is_absolute() and ".." not in path.parts,
                    "Unsafe dependency archive path")
            if not member.isfile() or not path.name.upper().startswith(
                    ("LICENSE", "LICENCE", "COPYING", "NOTICE", "COPYRIGHT")):
                continue
            require(member.size <= 4 * 1024 * 1024, "Oversized dependency notice")
            data = stream.extractfile(member).read()
            notices[path.as_posix()] = data
    return notices


def prepare(manifest_path, manifest_sha, metadata_path, artifacts_path, source, cargo_home, output):
    manifest = read_json(manifest_path, manifest_sha)
    commit = manifest["source_commit"]
    require(git_bytes(source, "rev-parse", commit + "^{tree}").decode().strip()
            == manifest["source_tree"], "Producer source tree mismatch")
    evidence = manifest["evidence"]
    metadata = read_json(metadata_path, evidence["post-build-native-metadata.json"]["sha256"])
    _, events = owned_bytes(artifacts_path, evidence["release-artifacts.jsonl"]["sha256"],
                            bounded=32 * 1024 * 1024)
    compiled = {event["package_id"] for line in events.splitlines()
                if (event := json.loads(line, object_pairs_hook=unique_object))["reason"]
                == "compiler-artifact"}
    packages = metadata["packages"]
    require(compiled <= {package["id"] for package in packages},
            "Compiler artifacts absent from producer metadata")
    lock_bytes = git_bytes(source, "show", commit + ":Cargo.lock")
    locked = {(p["name"], p["version"], p.get("source")): p
              for p in tomllib.loads(lock_bytes.decode())["package"]}
    require(not output.exists() and not output.is_symlink(), "Notice output already exists")
    output.mkdir(mode=0o700, parents=True)
    records, unresolved = [], []
    for package in sorted(packages, key=lambda p: (p["name"], p["version"], p["id"])):
        name, version, origin = package["name"], package["version"], package["source"]
        require((name, version, origin) in locked, "Metadata dependency absent from exact lockfile")
        record = {"name": name, "version": version, "source": origin or {"commit": commit},
                  "declaredLicense": package["license"], "compiled": package["id"] in compiled,
                  "notices": []}
        archive = None
        if origin and origin.startswith("registry+"):
            candidates = list((cargo_home / "registry/cache").glob("*/" + name + "-" + version + ".crate"))
            require(len(candidates) <= 1, "Ambiguous cached dependency archive")
            if candidates:
                _, archive = owned_bytes(candidates[0], locked[(name, version, origin)]["checksum"],
                                         bounded=128 * 1024 * 1024)
        elif origin and origin.startswith("git+"):
            revision = origin.rsplit("#", 1)[-1]
            checkout = Path(package["manifest_path"]).parent
            require(git_bytes(checkout, "rev-parse", revision + "^{commit}").decode().strip()
                    == revision, "Git dependency source revision mismatch")
            archive = git_bytes(checkout, "archive", "--format=tar", revision)
        else:
            # Repository-root licence applies to original workspace material;
            # missing package-level declarations remain explicit, not inferred.
            text = git_bytes(source, "show", commit + ":LICENSE")
            archive_buffer = io.BytesIO()
            with tarfile.open(fileobj=archive_buffer, mode="w") as stream:
                member = tarfile.TarInfo("LICENSE")
                member.size = len(text)
                stream.addfile(member, io.BytesIO(text))
            archive = archive_buffer.getvalue()
        for original, text in sorted(notice_members(archive).items() if archive is not None else []):
            sha = digest(text)
            relative = "texts/" + sha + ".txt"
            target = output / relative
            target.parent.mkdir(exist_ok=True)
            if not target.exists():
                target.write_bytes(text)
            record["notices"].append({"originalPath": original, "path": relative,
                                      "sha256": sha, "bytes": len(text)})
        if record["compiled"] and not record["declaredLicense"]:
            unresolved.append(name + "@" + version + ": no package-level licence declaration")
        if record["compiled"] and not record["notices"]:
            unresolved.append(name + "@" + version + ": exact source notice texts unavailable")
        records.append(record)
    inventory = {
        "version": 1, "producer": {"commit": commit, "tree": manifest["source_tree"]},
        "cliSHA256": manifest["binary_sha256"], "helperSHA256": manifest["helper_sha256"],
        "producerManifestSHA256": manifest_sha,
        "cargoLockSHA256": digest(lock_bytes),
        "metadataSHA256": evidence["post-build-native-metadata.json"]["sha256"],
        "artifactsSHA256": evidence["release-artifacts.jsonl"]["sha256"],
        "scope": "Cargo metadata superset; compiled includes host/build/proc-macro dependencies, not a binary-link assertion",
        "packages": records,
        "unresolved": unresolved + [
            "Rust standard-library/compiler-runtime exact version, notices and source-delivery obligations",
            "Windows helper: exact MinGW-w64 CRT/compiler support-library versions, notices and applicable exceptions",
            "Exact corresponding-source delivery and applicable licence/notice review for distributed components",
        ],
    }
    (output / "inventory.json").write_text(json.dumps(inventory, sort_keys=True, indent=2) + "\n")
    return inventory


def verify(directory, producer, cli_sha, helper_sha, expected_inventory_sha256):
    require(isinstance(expected_inventory_sha256, str) and len(expected_inventory_sha256) == 64
            and all(c in "0123456789abcdef" for c in expected_inventory_sha256),
            "Independently approved producer inventory SHA-256 is required")
    inventory = read_json(directory / "inventory.json", expected_inventory_sha256)
    require(inventory["version"] == 1 and inventory["producer"] == producer,
            "Dependency inventory producer mismatch")
    require(inventory["cliSHA256"] == cli_sha and inventory["helperSHA256"] == helper_sha,
            "Dependency inventory payload mismatch")
    expected = {"inventory.json"}
    for package in inventory["packages"]:
        for notice in package["notices"]:
            relative = notice["path"]
            require(relative == "texts/" + notice["sha256"] + ".txt", "Invalid dependency notice path")
            owned_bytes(directory / relative, notice["sha256"], notice["bytes"])
            expected.add(relative)
    actual = set()
    require(not directory.is_symlink(), "Linked dependency notice directory")
    for path in directory.rglob("*"):
        require(not path.is_symlink(), "Linked dependency notice")
        if path.is_file():
            actual.add(path.relative_to(directory).as_posix())
    require(actual == expected, "Unexpected or missing dependency notice files")
    return inventory


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--manifest-sha256", required=True)
    parser.add_argument("--metadata", type=Path, required=True)
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--producer-source", type=Path, required=True)
    parser.add_argument("--cargo-home", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = prepare(args.manifest, args.manifest_sha256, args.metadata, args.artifacts,
                     args.producer_source, args.cargo_home, args.output)
    print(json.dumps({"packages": len(result["packages"]),
                      "compiled": sum(p["compiled"] for p in result["packages"]),
                      "unresolved": result["unresolved"]}, sort_keys=True))
