#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Stage an explicitly pinned, relocatable interpreter; never download or install globally."""
import argparse
import io
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import stat
import struct
import subprocess
import sys
import tarfile
from shipping_pair import owned_bytes, require, unique_object
from signing_identity import command, preflight

PIN = Path(__file__).resolve().with_name("python-runtime.json")
EXECUTABLE = "bin/python3"
MAX_FILES = 10000
MAX_BYTES = 256 * 1024 * 1024


def approved_pin():
    _, data = owned_bytes(PIN, bounded=4096)
    pin = json.loads(data, object_pairs_hook=unique_object)
    require(set(pin) == {"version", "pythonVersion", "target", "release", "url", "sha256", "bytes"}
            and type(pin["version"]) is int and pin["version"] == 1
            and pin["target"] == "aarch64-apple-darwin", "Invalid interpreter approval")
    return pin


def checked_directory(path):
    path = Path(path)
    info = path.lstat()
    require(path.is_absolute() and path.resolve(strict=True) == path and stat.S_ISDIR(info.st_mode)
            and info.st_uid == os.getuid() and info.st_mode & 0o022 == 0,
            "Unsafe interpreter directory")


def unpack(data, destination):
    """Materialize in-archive file aliases as independent regular files, never links."""
    destination = Path(destination)
    checked_directory(destination.parent)
    require(not destination.exists() and not destination.is_symlink(), "Interpreter destination must be new")
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        members = archive.getmembers()
        require(0 < len(members) <= MAX_FILES, "Interpreter archive entry bound exceeded")
        entries = {}
        total = 0
        for member in members:
            path = PurePosixPath(member.name)
            require(bool(path.parts) and member.name.rstrip("/") == path.as_posix() and not path.is_absolute()
                    and path.parts[0] == "python" and ".." not in path.parts
                    and member.name.rstrip("/") not in entries, "Unsafe or duplicate interpreter archive path")
            require(member.isdir() or member.isfile() or member.issym(),
                    "Unsupported interpreter archive entry")
            require(member.size >= 0 and member.size <= 32 * 1024 * 1024,
                    "Interpreter archive member exceeds bound")
            entries[member.name.rstrip("/")] = member

        def regular(member):
            seen = set()
            while member.issym():
                require(member.name not in seen and not PurePosixPath(member.linkname).is_absolute(),
                        "Cyclic or absolute interpreter archive alias")
                seen.add(member.name)
                name = posixpath.normpath(posixpath.join(posixpath.dirname(member.name), member.linkname))
                require(name.startswith("python/") and name in entries, "Escaping interpreter archive alias")
                member = entries[name]
            require(member.isfile(), "Interpreter alias must name a regular file")
            return member

        files = []
        for name, member in entries.items():
            if member.isdir():
                continue
            source = regular(member)
            total += source.size
            require(total <= MAX_BYTES, "Expanded interpreter archive exceeds bound")
            files.append((PurePosixPath(name).relative_to("python"), source))
        require(any(str(name) == EXECUTABLE for name, _ in files), "Interpreter executable absent")
        require(any(str(name) == "lib/python3.14/LICENSE.txt" for name, _ in files),
                "Interpreter license absent")
        destination.mkdir(mode=0o755)
        for relative, member in files:
            target = destination / relative
            target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
            content = archive.extractfile(member).read(member.size + 1)
            require(len(content) == member.size, "Truncated interpreter archive file")
            with target.open("xb") as stream:
                stream.write(content)
            target.chmod(0o755 if member.mode & 0o111 else 0o644)


def inventory(directory):
    directory = Path(directory)
    checked_directory(directory)
    files, total = {}, 0
    for path in sorted(directory.rglob("*")):
        require(not path.is_symlink(), "Linked interpreter input")
        if path.is_dir():
            checked_directory(path)
            continue
        identity, _ = owned_bytes(path)
        total += identity["bytes"]
        require(len(files) < MAX_FILES and total <= MAX_BYTES, "Interpreter inventory bound exceeded")
        files[path.relative_to(directory).as_posix()] = {
            **identity, "executable": bool(path.stat().st_mode & 0o111)}
    require(EXECUTABLE in files and files[EXECUTABLE]["executable"], "Interpreter is not executable")
    require("lib/python3.14/LICENSE.txt" in files, "Interpreter license absent")
    with (directory / EXECUTABLE).open("rb") as stream:
        require(stream.read(8) == struct.pack("<II", 0xFEEDFACF, 0x0100000C),
                "Expected arm64 interpreter")
    return files


def verify_runtime(directory, metadata):
    pin = approved_pin()
    require(type(metadata) is dict and set(metadata) == {
        "version", "pythonVersion", "archiveSHA256", "files"},
        "Invalid packaged interpreter manifest")
    require(type(metadata["version"]) is int and metadata["version"] == 1
            and metadata["pythonVersion"] == pin["pythonVersion"]
            and metadata["archiveSHA256"] == pin["sha256"], "Unapproved packaged interpreter")
    require(inventory(directory) == metadata["files"], "Packaged interpreter changed")
    return metadata


def stage_runtime(archive_path, destination, receipt, identity=None, local_ad_hoc=False, run=command):
    pin = approved_pin()
    archive_identity, data = owned_bytes(archive_path, pin["sha256"], pin["bytes"], 32 * 1024 * 1024)
    signer = preflight(identity, local_ad_hoc, run)
    destination, receipt = Path(destination), Path(receipt)
    unpack(data, destination)
    for relative in inventory(destination):
        path = destination / relative
        with path.open("rb") as stream:
            header = stream.read(8)
        if header[:4] == struct.pack("<I", 0xFEEDFACF):
            require(header == struct.pack("<II", 0xFEEDFACF, 0x0100000C),
                    "Unexpected interpreter code architecture")
            run(["/usr/bin/codesign", "--force", "--sign", signer, "--timestamp=none", str(path)])
            run(["/usr/bin/codesign", "--verify", "--strict", str(path)])
    for path in sorted(destination.rglob("*"), key=lambda path: len(path.parts), reverse=True):
        path.chmod(0o555 if path.is_dir() or path.stat().st_mode & 0o111 else 0o444)
    destination.chmod(0o555)
    metadata = {"version": 1, "pythonVersion": pin["pythonVersion"],
                "archiveSHA256": archive_identity["sha256"], "files": inventory(destination)}
    manifest = destination.with_suffix(".json")
    with manifest.open("x", encoding="utf-8") as stream:
        stream.write(json.dumps(metadata, sort_keys=True) + "\n")
    manifest.chmod(0o644)
    verify_runtime(destination, metadata)
    owned_bytes(archive_path, pin["sha256"], pin["bytes"])
    record = json.loads(receipt.read_bytes(), object_pairs_hook=unique_object)
    require("privatePythonRuntime" not in record, "Interpreter already staged")
    record["privatePythonRuntime"] = metadata
    receipt.write_text(json.dumps(record, sort_keys=True) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive")
    parser.add_argument("destination")
    parser.add_argument("receipt")
    parser.add_argument("--identity")
    parser.add_argument("--local-ad-hoc", action="store_true")
    args = parser.parse_args()
    require(sys.platform == "darwin", "Interpreter signing requires macOS")
    stage_runtime(args.archive, args.destination, args.receipt, args.identity, args.local_ad_hoc)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError, tarfile.TarError, subprocess.SubprocessError) as error:
        raise SystemExit("Interpreter staging failed: " + str(error))
