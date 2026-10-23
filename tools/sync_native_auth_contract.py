# SPDX-License-Identifier: GPL-3.0-only
"""Import only the two immutable, public private-host contract artifacts."""
import argparse
import hashlib
import pathlib
import subprocess

PIN = "bb6397033fc38497a73684a9ecdb2929caba1f63"
SCHEMA_SHA256 = "c7ca7de8ee8a610b71e9e458f13469554467dd2632f88d35317a1ce2646af430"
FIXTURE_SHA256 = "d864e96079dc5292f6c078fb2be37c870f1cf4be114edc6e68e0984a555d0d24"
ROOT = pathlib.Path(__file__).resolve().parent.parent
FILES = (
    ("docs/contracts/native-auth-host-v1.schema.json", "Resources/native-auth-host-v1.schema.json"),
    ("docs/fixtures/native-auth-host-v1.json", "Resources/native-auth-host-v1.json"),
)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-repository", required=True)
    args = parser.parse_args()
    destination = ROOT / "Sources" / "XodusAuthHost"
    for source, resource in FILES:
        content = subprocess.run(
            ["git", "-C", args.source_repository, "show", f"{PIN}:{source}"],
            check=True, capture_output=True,
        ).stdout
        if b"\r" in content:
            raise ValueError("The canonical public contract must have exact LF bytes")
        digest = hashlib.sha256(content).hexdigest()
        expected = SCHEMA_SHA256 if source.endswith(".schema.json") else FIXTURE_SHA256
        if digest != expected:
            raise ValueError("The immutable native-host artifact pin does not match")
        target = destination / resource
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
        print(f"{target.name}: {digest}")


if __name__ == "__main__":
    main()
