#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Build an explicitly local, source-bound Developer ID candidate without replacing an installed app."""
import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import tarfile
import tempfile

from shipping_pair import (CARGO_LOCK_SHA256, FEATURES, PRODUCER, PRODUCER_TREE, PROFILE,
                           hex_value, owned_bytes, require, swift_pins, swift_producer_pins)
from signing_identity import preflight, sign, verify_designated_requirement
from legacy_compatibility import CRATE_CLI, PRODUCER_CLI
from shipping_pair import require_renamed_producer



def path_remap(source):
    """REQ-52: build-machine paths never reach shipped binaries (debug, file and Clang prefix maps)."""
    root = str(source)
    return ["-Xswiftc", "-file-prefix-map", "-Xswiftc", root + "=/xode",
            "-Xswiftc", "-debug-prefix-map", "-Xswiftc", root + "=/xode",
            "-Xcc", "-ffile-prefix-map=" + root + "=/xode"]


def strip_debug(path):
    """REQ-52: remove debug symbol entries (object-file paths) before signing."""
    subprocess.run(["/usr/bin/strip", "-S", str(path)], check=True)

def validate_host():
    require(platform.system() == "Darwin" and platform.machine() == "arm64",
            "This local candidate packager requires an Apple Silicon Mac")


def run(arguments, cwd, log, environment=None):
    result = subprocess.run(arguments, cwd=cwd, env=environment, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=1800)
    with log.open("ab") as output:
        output.write(("$ " + " ".join(map(str, arguments)) + "\n").encode())
        output.write(result.stdout)
    require(result.returncode == 0, "Local build failed; inspect " + str(log))
    return result.stdout


def source_identity(root):
    def git(*arguments):
        return subprocess.check_output(["git", *arguments], cwd=root, text=True).strip()
    require(not git("status", "--porcelain", "--untracked-files=normal"),
            "Commit the selected source changes before building a reproducible candidate")
    return {"commit": hex_value(git("rev-parse", "HEAD"), 40),
            "tree": hex_value(git("rev-parse", "HEAD^{tree}"), 40)}


def source_build_number(root):
    build = int(subprocess.check_output(
        ["git", "-C", str(root), "rev-list", "--count", "HEAD"], text=True).strip())
    require(build > 2, "CFBundleVersion must exceed the installed candidate's build 2")
    return build


def copy_release_notices(source, resources):
    for source_name, bundle_name in (("LICENSE", "LICENSE.txt"),
                                     ("NOTICE", "NOTICE.txt"),
                                     ("TRADEMARKS.md", "TRADEMARKS.md")):
        path = source / source_name
        require(path.is_file() and not path.is_symlink(),
                "Missing required release notice: " + source_name)
        shutil.copyfile(path, resources / bundle_name)


def copy_engine_notice(notice_path, resources):
    identity, data = owned_bytes(notice_path, bounded=2 * 1024 * 1024)
    text = data.decode("utf-8")
    require(bool(text.strip()) and "\x00" not in text,
            "Engine NOTICE must be non-empty UTF-8 text")
    destination = resources / "EngineNotices/NOTICE.txt"
    destination.parent.mkdir(parents=True)
    destination.write_bytes(data)
    return identity


def build_evidence(messages):
    artifacts, native_features = [], {}
    for line in messages.splitlines():
        try:
            frame = json.loads(line)
        except ValueError:
            continue
        if frame.get("reason") != "compiler-artifact":
            continue
        name = frame.get("target", {}).get("name", "").replace("_", "-")
        if name in FEATURES:
            require(frame.get("profile") == PROFILE, "Unexpected native release build profile: " + name)
            require(name not in native_features, "Duplicate native build artifact: " + name)
            native_features[name] = frame.get("features")
        if name == CRATE_CLI and frame.get("executable"):
            artifacts.append(frame)
    require(len(artifacts) == 1, "Expected one actual CLI build artifact")
    require(native_features == FEATURES, "Missing or incompatible native release features")
    return artifacts[0], native_features


def build(engine_root, output_root, identity, engine_notice=None):
    require_renamed_producer()
    validate_host()
    project = Path(__file__).resolve().parent.parent
    engine_root = engine_root.resolve(strict=True)
    require(output_root.is_absolute() and output_root.resolve(strict=True) == output_root,
            "Use a canonical existing owned output directory")
    metadata = output_root.stat()
    require(metadata.st_uid == os.getuid() and metadata.st_mode & 0o022 == 0,
            "Output directory must be owned and not group/world writable")
    preflight(identity)
    app_source, engine_source = source_identity(project), source_identity(engine_root)
    require(engine_source == {"commit": PRODUCER, "tree": PRODUCER_TREE},
            "Engine source differs from the approved shipping producer")
    cargo_lock = owned_bytes(engine_root / "Cargo.lock", CARGO_LOCK_SHA256)[0]
    contract = engine_root / "docs/contracts/management-v1.schema.json"
    consumer = project / "Sources/OdeManagement/Resources/management-v1.schema.json"
    require_renamed_producer(contract.read_bytes())
    require(contract.read_bytes() == consumer.read_bytes(),
            "Engine and app management contracts differ; update the actual contract before packaging")
    stage = Path(tempfile.mkdtemp(prefix="Ode-local-", dir=output_root))
    stage.chmod(0o700)
    log = stage / "build.log"
    archive = stage / "source.tar"
    with archive.open("xb") as output:
        subprocess.run(["git", "archive", "--format=tar", app_source["commit"]],
                       cwd=project, stdout=output, check=True)
    source = stage / "source"
    source.mkdir()
    with tarfile.open(archive) as archived:
        archived.extractall(source, filter="data")
    environment = os.environ.copy()
    environment.update(CARGO_TARGET_DIR=str(stage / "engine-target"), CARGO_INCREMENTAL="0",
                       CARGO_BUILD_JOBS="1")
    command = ["cargo", "build", "--release", "--offline", "--locked", "-p", CRATE_CLI,
               "--bin", PRODUCER_CLI, "--target", "aarch64-apple-darwin",
               "--no-default-features", "--message-format=json"]
    messages = run(command, engine_root, log, environment)
    artifact, native_features = build_evidence(messages)
    require(source_identity(engine_root) == engine_source, "Engine source changed during build")
    executable = Path(artifact["executable"]).resolve(strict=True)
    require(executable.is_relative_to(stage / "engine-target"), "CLI artifact is outside this build target")
    unsigned, _ = owned_bytes(executable)
    app = stage / "X Ode.app"
    macos, resources = app / "Contents/MacOS", app / "Contents/Resources"
    macos.mkdir(parents=True)
    (resources / "OdeEngine").mkdir(parents=True)
    engine = resources / "OdeEngine/ode-cli"
    shutil.copyfile(artifact["executable"], engine)
    engine.chmod(0o755)
    owned_bytes(engine, unsigned["sha256"], unsigned["bytes"])
    sign(engine, "cli", identity, developer_id=True)
    signed_engine, _ = owned_bytes(engine)
    environment = os.environ.copy()
    environment["ODE_SHIPPING"] = "1"
    run(["swift", "build", "--jobs", "1", "-c", "release", "--product", "OdeAuthHost"] + path_remap(source),
        source, log, environment)
    binary_dir = Path(run(["swift", "build", "-c", "release", "--show-bin-path"] + path_remap(source),
                         source, log, environment).decode().strip())
    helper = macos / "OdeAuthHost"
    shutil.copyfile(binary_dir / "OdeAuthHost", helper)
    helper.chmod(0o755)
    strip_debug(helper)
    sign(helper, "helper", identity, developer_id=True)
    signed_helper, _ = owned_bytes(helper)
    pins = source / "Sources/OdePreview/ShippingPairPins.swift"
    pins.write_text(swift_pins(app_source["commit"], app_source["tree"],
                              signed_engine, signed_helper, engine_source["commit"], engine_source["tree"]))
    producer_pins = source / "Sources/OdePreview/ShippingProducerPins.swift"
    producer_pins.write_text(swift_producer_pins())
    run(["swift", "build", "--jobs", "1", "-c", "release", "--product", "OdePreview"] + path_remap(source),
        source, log, environment)
    shutil.copyfile(binary_dir / "OdePreview", macos / "Ode")
    (macos / "Ode").chmod(0o755)
    strip_debug(macos / "Ode")
    info = plistlib.loads((source / "tools/Info.plist").read_bytes())
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+",
                         info.get("CFBundleShortVersionString", "")) is not None,
            "App version must use exactly x.y.z")
    info["CFBundleName"] = info["CFBundleDisplayName"] = "X Ode"
    info["CFBundleVersion"] = str(source_build_number(project))
    info["XodeReleaseChannel"] = "Beta"
    with (app / "Contents/Info.plist").open("wb") as output:
        plistlib.dump(info, output)
    copy_release_notices(source, resources)
    engine_notice_record = copy_engine_notice(engine_notice, resources) if engine_notice else None
    run(["swiftc", "Sources/OdeCore/XOdeMark.swift", "tools/RenderAppIcon.swift",
         "-o", str(stage / "RenderAppIcon")], source, log)
    run([str(stage / "RenderAppIcon"), str(resources / "Ode.iconset")], source, log)
    run(["iconutil", "-c", "icns", str(resources / "Ode.iconset"),
         "-o", str(resources / "Ode.icns")], source, log)
    shutil.copytree(binary_dir / "OdeApp_OdeManagement.bundle",
                    resources / "OdeApp_OdeManagement.bundle")
    (resources / "OdeAuthHost.json").write_text(json.dumps({
        "version": 1, "sha256": signed_helper["sha256"],
        "sourceCommit": app_source["commit"]}, sort_keys=True) + "\n")
    sign(app, "app", identity, developer_id=True)
    run(["codesign", "--verify", "--deep", "--strict", str(app)], source, log)
    for path, kind in ((engine, "cli"), (helper, "helper"), (app, "app")):
        verify_designated_requirement(path, kind, identity)
    for executable in (engine, helper, macos / "Ode"):
        require(run(["lipo", "-archs", str(executable)], source, log).decode().strip() == "arm64",
                "Candidate executables must all be arm64")
    owned_bytes(engine, signed_engine["sha256"], signed_engine["bytes"])
    owned_bytes(helper, signed_helper["sha256"], signed_helper["bytes"])
    require(source_identity(project) == app_source and source_identity(engine_root) == engine_source,
            "Source changed during candidate packaging")
    inventory = {str(path.relative_to(app)): owned_bytes(path)[0]
                 for path in sorted(app.rglob("*")) if path.is_file()}
    receipt = {
        "kind": "local-development-candidate", "productionQualified": False, "notarized": False,
        "appSource": app_source, "engineSource": engine_source, "engineCargoLock": cargo_lock,
        "engineBuildCommand": command,
        "actualCargoProfile": artifact["profile"], "unsignedEngine": unsigned,
        "actualNativeResolvedFeatures": native_features,
        "signedEngine": signed_engine, "signedHelper": signed_helper,
        "certificateSHA1": identity.upper(), "generatedPins": owned_bytes(pins)[0],
        "architecture": "arm64",
        "generatedProducerPins": owned_bytes(producer_pins)[0], "packageFiles": inventory,
    }
    if engine_notice_record:
        receipt["engineNotice"] = engine_notice_record
    (stage / "candidate-receipt.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    print(app)
    print(stage / "candidate-receipt.json")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine-source", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--identity", required=True)
    parser.add_argument("--engine-notice", type=Path,
                        help="Plain-text Calimocho NOTICE from the admitted release")
    args = parser.parse_args()
    build(args.engine_source, args.output_root, args.identity, args.engine_notice)
