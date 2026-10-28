# SPDX-License-Identifier: GPL-3.0-only
"""Import only the two immutable, public private-host contract artifacts."""
import argparse
import hashlib
import pathlib
import subprocess

PIN = "a272b1d7f10ccf0aa32936e24551098b9c7cd02e"
SCHEMA_SHA256 = "36d9d8969c941b45283f8ca4aa1fa4e73c8b23ce0afea2e4243f55ce366e889e"
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
    destination = ROOT / "Sources" / "OdeAuthHost"
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
