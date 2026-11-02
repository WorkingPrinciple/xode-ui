#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Verify a pinned, source-bound release app and its admission evidence."""
import hashlib
import json
import os
import plistlib
from pathlib import Path
import posixpath
import re
import stat
import sys


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def app_tree_sha256(app):
    app = Path(app)
    if app.is_symlink() or not app.is_dir():
        raise ValueError("app must be a real directory bundle")
    root = app.resolve(strict=True)
    digest = hashlib.sha256()
    root_mode = stat.S_IMODE(root.lstat().st_mode)
    digest.update(b"D\0.\0" + f"{root_mode:04o}\0".encode("ascii") + b"0\0\0")
    paths = []
    def fail_walk(error):
        raise error

    for directory, names, files in os.walk(root, followlinks=False, onerror=fail_walk):
        names.sort()
        files.sort()
        parent = Path(directory)
        paths.extend(parent / name for name in names + files)
    paths.sort(key=lambda path: path.relative_to(root).as_posix())
    for path in paths:
        relative = path.relative_to(root).as_posix().encode("utf-8")
        metadata = path.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            try:
                path.resolve(strict=True).relative_to(root)
            except (ValueError, OSError, RuntimeError) as error:
                raise ValueError(f"app symlink escapes the bundle or is unresolved: {path}") from error
            entry_type = b"L"
            contents = path.readlink().as_posix().encode("utf-8")
        elif stat.S_ISDIR(metadata.st_mode):
            entry_type = b"D"
            contents = b""
        elif stat.S_ISREG(metadata.st_mode):
            entry_type = b"F"
            contents = None
        else:
            raise ValueError(f"unsupported special file in app bundle: {relative.decode('utf-8')}")
        digest.update(entry_type + b"\0" + relative + b"\0")
        digest.update(f"{stat.S_IMODE(metadata.st_mode):04o}\0".encode("ascii"))
        if contents is not None:
            digest.update(str(len(contents)).encode("ascii") + b"\0" + contents)
        else:
            digest.update(str(metadata.st_size).encode("ascii") + b"\0")
            with path.open("rb") as source:
                for block in iter(lambda: source.read(1024 * 1024), b""):
                    digest.update(block)
        digest.update(b"\0")
    return digest.hexdigest()


def _read_pinned_file(root, relative, expected_sha256, label, maximum=16 * 1024 * 1024):
    if not isinstance(relative, str) or not relative or "\\" in relative:
        raise ValueError(f"{label} path must be a non-empty relative POSIX path")
    normalized = posixpath.normpath(relative)
    if normalized != relative or normalized == "." or normalized.startswith("../") or relative.startswith("/"):
        raise ValueError(f"{label} path must remain inside the admission evidence directory")
    path = root.joinpath(*relative.split("/"))
    current = root
    for component in relative.split("/"):
        current = current / component
        if current.is_symlink():
            raise ValueError(f"{label} must not use symlinks")
    if not path.is_file() or path.stat().st_size == 0 or path.stat().st_size > maximum:
        raise ValueError(f"{label} is missing, not a regular file, or exceeds its size limit")
    content = path.read_bytes()
    if hashlib.sha256(content).hexdigest() != expected_sha256:
        raise ValueError(f"{label} SHA-256 does not match the admission receipt")
    return content


def _verify_evidence(root, record, *, kind, source, app):
    if not isinstance(record, dict) or set(record) != {"receipt", "sha256"}:
        raise ValueError(f"{kind} must pin an evidence receipt path and SHA-256")
    receipt_bytes = _read_pinned_file(root, record["receipt"], record["sha256"], f"{kind} receipt")
    try:
        evidence_receipt = json.loads(receipt_bytes.decode("utf-8"), object_pairs_hook=_unique_object)
    except (UnicodeError, json.JSONDecodeError, ValueError) as error:
        raise ValueError(f"{kind} receipt is not valid unique-key UTF-8 JSON: {error}") from error
    if not isinstance(evidence_receipt, dict):
        raise ValueError(f"{kind} receipt root must be a JSON object")
    if (type(evidence_receipt.get("schemaVersion")) is not int or evidence_receipt["schemaVersion"] != 1
            or evidence_receipt.get("kind") != kind or evidence_receipt.get("status") != "accepted"
            or evidence_receipt.get("source") != source
            or evidence_receipt.get("app") != app):
        raise ValueError(f"{kind} evidence receipt is not accepted for this source and app")
    evidence = evidence_receipt.get("evidence")
    if not isinstance(evidence, list) or not evidence:
        raise ValueError(f"{kind} receipt must reference at least one evidence file")
    for item in evidence:
        if not isinstance(item, dict) or set(item) != {"path", "sha256"}:
            raise ValueError(f"{kind} evidence entries require only a path and SHA-256")
        if not isinstance(item["sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", item["sha256"]):
            raise ValueError(f"{kind} evidence file digest is invalid")
        _read_pinned_file(root, item["path"], item["sha256"], f"{kind} evidence file")


def verify_release_admission(app, receipt_path, *, expected_app_sha256,
                             expected_receipt_sha256, version, commit, tree,
                             repository="WorkingPrinciple/xode-ui"):
    app = Path(app)
    receipt_path = Path(os.path.abspath(receipt_path))
    for label, value in (("app", expected_app_sha256),
                         ("admission receipt", expected_receipt_sha256)):
        if not re.fullmatch(r"[0-9a-f]{64}", value):
            raise ValueError(f"expected {label} SHA-256 must be 64 lowercase hex characters")
    if not re.fullmatch(r"[0-9a-f]{40}", commit) or not re.fullmatch(r"[0-9a-f]{40}", tree):
        raise ValueError("expected source commit and tree must be 40 lowercase hex characters")
    if receipt_path.is_symlink() or not receipt_path.is_file():
        raise ValueError("admission receipt must be a regular, non-symlink file")
    receipt_path = receipt_path.parent.resolve(strict=True) / receipt_path.name
    if receipt_path.stat().st_size > 4 * 1024 * 1024:
        raise ValueError("admission receipt exceeds the 4 MiB limit")
    actual_app_sha256 = app_tree_sha256(app)
    if actual_app_sha256 != expected_app_sha256:
        raise ValueError("app bundle tree does not match the pinned SHA-256")
    receipt_bytes = receipt_path.read_bytes()
    if hashlib.sha256(receipt_bytes).hexdigest() != expected_receipt_sha256:
        raise ValueError("admission receipt does not match the pinned SHA-256")
    try:
        receipt = json.loads(receipt_bytes.decode("utf-8"), object_pairs_hook=_unique_object)
        with (app / "Contents/Info.plist").open("rb") as source:
            info = plistlib.load(source)
    except (OSError, UnicodeError, json.JSONDecodeError, plistlib.InvalidFileException) as error:
        raise ValueError(f"cannot read release input metadata: {error}") from error
    if not isinstance(receipt, dict):
        raise ValueError("admission receipt root must be a JSON object")
    if not isinstance(info, dict):
        raise ValueError("app Info.plist root must be a dictionary")
    if type(receipt.get("schemaVersion")) is not int or receipt["schemaVersion"] != 1:
        raise ValueError("unsupported admission receipt schema")
    if receipt.get("source") != {"repository": repository, "commit": commit, "tree": tree}:
        raise ValueError("admission receipt does not bind this repository, tag commit and source tree")
    if receipt.get("app") != {"sha256": actual_app_sha256, "version": version}:
        raise ValueError("admission receipt does not bind this app tree and version")
    source_identity = {"repository": repository, "commit": commit, "tree": tree}
    app_identity = {"sha256": actual_app_sha256, "version": version}
    _verify_evidence(receipt_path.parent, receipt.get("releaseQualification"),
                     kind="releaseQualification", source=source_identity, app=app_identity)
    _verify_evidence(receipt_path.parent, receipt.get("provenanceRedistributionReview"),
                     kind="provenanceRedistributionReview", source=source_identity, app=app_identity)
    if info.get("CFBundleShortVersionString") != version:
        raise ValueError("app bundle version does not match the release tag")
    return actual_app_sha256


def main(argv):
    if len(argv) == 3 and argv[1] == "--tree-hash":
        try:
            print(app_tree_sha256(argv[2]))
        except (OSError, ValueError) as error:
            raise SystemExit("Release admission rejected: " + str(error))
        return
    if len(argv) != 8:
        raise SystemExit(
            "Usage: release_admission.py --tree-hash <app> | "
            "<app> <receipt> <app-tree-sha256> <receipt-sha256> <version> <source-commit> <source-tree>")
    _, app, receipt, app_sha256, receipt_sha256, version, commit, tree = argv
    try:
        actual = verify_release_admission(
            app, receipt, expected_app_sha256=app_sha256, expected_receipt_sha256=receipt_sha256,
            version=version, commit=commit, tree=tree)
    except (OSError, ValueError, KeyError) as error:
        raise SystemExit("Release admission rejected: " + str(error))
    print(f"PASS: source-bound release admission verified for app tree {actual}")


if __name__ == "__main__":
    main(sys.argv)
