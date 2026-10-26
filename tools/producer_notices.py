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
import urllib.parse

from shipping_pair import owned_bytes, require, unique_object


def digest(data):
    return hashlib.sha256(data).hexdigest()


def git_blob_sha1(data):
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


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
            name = path.name.upper()
            if not member.isfile() or path.suffix.lower() in (
                    ".rs", ".c", ".h", ".py", ".sh", ".swift", ".js", ".ts") \
                    or not any(name == stem or name.startswith((stem + ".", stem + "-"))
                               for stem in ("LICENSE", "LICENCE", "COPYING", "NOTICE", "COPYRIGHT")):
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


def _notice_record(output, text, original_path, provenance):
    sha = digest(text)
    relative = "texts/" + sha + ".txt"
    target = output / relative
    target.parent.mkdir(exist_ok=True)
    if target.exists():
        require(target.read_bytes() == text, "Content-addressed notice collision")
    else:
        target.write_bytes(text)
    return {"originalPath": original_path, "path": relative, "sha256": sha,
            "bytes": len(text), **provenance}


def _attach_notice(output, notices, text, original_path, provenance):
    record = _notice_record(output, text, original_path, provenance)
    existing = next((notice for notice in notices if notice["sha256"] == record["sha256"]), None)
    if existing is None:
        notices.append(record)
    else:
        existing.setdefault("additionalProvenance", []).append(provenance)
    return record


def _crate_vcs(cargo_home, lock, name, version, origin):
    package = lock[(name, version, origin)]
    candidates = list((cargo_home / "registry/cache").glob(
        "*/" + name + "-" + version + ".crate"))
    require(len(candidates) == 1, "Exact locked crate archive is unavailable or ambiguous")
    _, archive = owned_bytes(candidates[0], package["checksum"], bounded=128 * 1024 * 1024)
    with tarfile.open(fileobj=io.BytesIO(archive)) as stream:
        members = [member for member in stream
                   if member.isfile() and member.name.endswith("/.cargo_vcs_info.json")]
        require(len(members) == 1, "Crate source revision unavailable")
        vcs = json.load(stream.extractfile(members[0]), object_pairs_hook=unique_object)
    return package, vcs


def _crate_manifest(archive):
    with tarfile.open(fileobj=io.BytesIO(archive)) as stream:
        vcs_members = [member for member in stream
                       if member.isfile() and member.name.endswith("/.cargo_vcs_info.json")]
        require(len(vcs_members) == 1, "Exact crate VCS metadata is unavailable")
        archive_root = vcs_members[0].name.removesuffix("/.cargo_vcs_info.json")
        manifest_path = archive_root + "/Cargo.toml"
        manifests = [member for member in stream
                     if member.isfile() and member.name == manifest_path]
        require(len(manifests) == 1, "Exact crate Cargo.toml is unavailable")
        return tomllib.loads(stream.extractfile(manifests[0]).read().decode())["package"]


def _merge_upstream_notices(output, inventory, source, cargo_home, report_directory,
                            expected_report_sha256):
    report = read_json(report_directory / "inventory.json", expected_report_sha256)
    require(report.get("version") == 1 and isinstance(report.get("groups"), list),
            "Unsupported supplemental upstream notice report")
    lock_bytes = git_bytes(source, "show", inventory["producer"]["commit"] + ":Cargo.lock")
    lock = {(p["name"], p["version"], p.get("source")): p
            for p in tomllib.loads(lock_bytes.decode())["package"]}
    packages = {p["name"] + "@" + p["version"]: p for p in inventory["packages"]}
    applied_packages = set()
    for group in report["groups"]:
        repository = group.get("repository", "")
        parsed_repository = urllib.parse.urlparse(repository)
        require(parsed_repository.scheme == "https" and parsed_repository.netloc == "github.com"
                and len(parsed_repository.path.strip("/").split("/")) == 2,
                "Supplemental upstream repository is not a pinned public GitHub repository")
        owner, repo = parsed_repository.path.strip("/").split("/")
        revision = group.get("revision")
        require(isinstance(revision, str) and len(revision) == 40
                and all(c in "0123456789abcdef" for c in revision),
                "Supplemental upstream revision is not an exact commit")
        for identity in group.get("packages", []):
            require(identity in packages, "Supplemental package is absent from current metadata")
            package = packages[identity]
            origin = package["source"]
            require(isinstance(origin, str) and origin.startswith("registry+"),
                    "Supplemental VCS notice may only cover locked registry packages")
            locked_package, vcs = _crate_vcs(
                cargo_home, lock, package["name"], package["version"], origin)
            require(vcs["git"]["sha1"] == revision,
                    "Supplemental VCS revision differs from the current locked crate")
            require(identity not in applied_packages,
                    "Supplemental package appears in multiple upstream groups")
        prefix = f"https://raw.githubusercontent.com/{owner}/{repo}/{revision}/"
        for notice in group.get("notices", []):
            text_path = report_directory / notice["path"]
            _, text = owned_bytes(text_path, notice["sha256"], notice["bytes"],
                                  bounded=4 * 1024 * 1024)
            source_url = notice["sourceURL"]
            require(source_url.startswith(prefix), "Supplemental notice URL is not revision-bound")
            require(git_blob_sha1(text) == notice.get("gitBlob"),
                    "Supplemental notice Git blob identity mismatch")
            original_path = urllib.parse.unquote(source_url[len(prefix):])
            require(original_path and not original_path.startswith("/")
                    and ".." not in PurePosixPath(original_path).parts,
                    "Unsafe supplemental upstream notice path")
            record = _notice_record(output, text, original_path, {
                "sourceURL": source_url,
                "sourceRepository": repository,
                "sourceRevision": revision,
                "gitBlobSHA1": notice["gitBlob"],
                "supplementalReportSHA256": expected_report_sha256,
            })
            for identity in group["packages"]:
                package = packages[identity]
                require(not any(item["sha256"] == record["sha256"]
                                for item in package["notices"]),
                        "Supplemental notice duplicates a package notice")
                package["notices"].append(dict(record))
                applied_packages.add(identity)
                unresolved = identity + ": exact source notice texts unavailable"
                if unresolved in inventory["unresolved"]:
                    inventory["unresolved"].remove(unresolved)
    inventory["supplementalProvenance"] = {
        "scope": "Reused upstream texts only after checking current Cargo.lock checksums and .cargo_vcs_info.json revisions",
        "reportSHA256": expected_report_sha256,
        "reportProducer": report.get("producer"),
        "unavailable": [group for group in report["groups"] if not group["notices"]],
    }


def _validate_evidence_document(document, text, producer, producer_source):
    origin = document.get("source", {})
    require(git_blob_sha1(text) == origin.get("gitBlobSHA1"),
            "Supplemental source Git blob identity mismatch")
    if origin.get("kind") == "producer-git":
        require(origin.get("revision") == producer["commit"],
                "Producer source document revision mismatch")
        raw = git_bytes(producer_source, "show",
                        origin["revision"] + ":" + origin["sourcePath"])
        require(raw == text, "Producer source document differs from its pinned Git blob")
    elif origin.get("kind") == "producer-excerpt":
        require(origin.get("revision") == producer["commit"],
                "Producer excerpt revision mismatch")
        raw = git_bytes(producer_source, "show",
                        origin["revision"] + ":" + origin["sourcePath"])
        require(git_blob_sha1(raw) == origin.get("sourceFileGitBlobSHA1"),
                "Producer excerpt source-file blob mismatch")
        lines = raw.splitlines(keepends=True)
        excerpt = b"".join(lines[origin["lineStart"] - 1:origin["lineEnd"]])
        require(excerpt == text, "Producer excerpt differs from its pinned source lines")
    elif origin.get("kind") == "upstream-excerpt":
        parsed = urllib.parse.urlparse(origin.get("sourceURL", ""))
        require(parsed.scheme == "https" and parsed.netloc == "raw.githubusercontent.com"
                and origin.get("revision") in parsed.path,
                "Upstream excerpt URL is not commit-bound")
        _, raw = owned_bytes(Path(document["evidenceRoot"]) / origin["sourcePayloadPath"],
                             origin["sourcePayloadSHA256"], origin["sourcePayloadBytes"],
                             bounded=16 * 1024 * 1024)
        require(git_blob_sha1(raw) == origin.get("sourceFileGitBlobSHA1"),
                "Upstream excerpt source-file blob mismatch")
        lines = raw.splitlines(keepends=True)
        excerpt = b"".join(lines[origin["lineStart"] - 1:origin["lineEnd"]])
        require(excerpt == text, "Upstream excerpt differs from its pinned source lines")
    elif origin.get("kind") in ("upstream-git", "spdx-standard"):
        parsed = urllib.parse.urlparse(origin.get("sourceURL", ""))
        require(parsed.scheme == "https" and parsed.netloc == "raw.githubusercontent.com"
                and origin.get("revision") in parsed.path,
                "Supplemental upstream text URL is not commit-bound")
    else:
        require(False, "Unknown supplemental evidence source kind")


def add_supplement(output, report_directory, report_sha256, evidence_directory,
                   evidence_sha256, source, cargo_home):
    inventory = read_json(output / "inventory.json")
    require(not output.is_symlink(), "Linked dependency notice directory")
    require(source.is_dir() and not source.is_symlink(), "Producer source checkout is invalid")
    require(git_bytes(source, "rev-parse", inventory["producer"]["commit"] + "^{tree}")
            .decode().strip() == inventory["producer"]["tree"],
            "Supplemental evidence producer tree mismatch")
    _merge_upstream_notices(output, inventory, source, cargo_home,
                            report_directory, report_sha256)
    evidence = read_json(evidence_directory / "evidence.json", evidence_sha256)
    require(evidence.get("producer") == inventory["producer"],
            "Supplemental evidence producer mismatch")
    documents = {}
    for document in evidence.get("documents", []):
        identifier = document.get("id")
        require(isinstance(identifier, str) and identifier not in documents,
                "Duplicate or invalid supplemental evidence document id")
        _, text = owned_bytes(evidence_directory / document["path"],
                              document["sha256"], document["bytes"],
                              bounded=16 * 1024 * 1024)
        document["evidenceRoot"] = str(evidence_directory)
        _validate_evidence_document(document, text, inventory["producer"], source)
        document.pop("evidenceRoot")
        documents[identifier] = dict(document)

    producer_files = []
    for item in evidence.get("producerFiles", []):
        raw = git_bytes(source, "show",
                        inventory["producer"]["commit"] + ":" + item["path"])
        require(git_blob_sha1(raw) == item["gitBlobSHA1"]
                and digest(raw) == item["sha256"] and len(raw) == item["bytes"],
                "Producer source-file evidence differs from its pinned Git blob")
        producer_files.append(dict(item))
    root_manifest = next((item for item in producer_files if item["path"] == "Cargo.toml"), None)
    if root_manifest is not None:
        raw = git_bytes(source, "show", inventory["producer"]["commit"] + ":Cargo.toml")
        workspace = tomllib.loads(raw.decode()).get("workspace", {})
        require("crates/*" in workspace.get("members", []),
                "Producer root manifest does not establish crates/* workspace membership")

    package_map = {p["name"] + "@" + p["version"]: p for p in inventory["packages"]}
    lock_bytes = git_bytes(source, "show", inventory["producer"]["commit"] + ":Cargo.lock")
    lock = {(p["name"], p["version"], p.get("source")): p
            for p in tomllib.loads(lock_bytes.decode())["package"]}
    resolved = set()
    used_documents = set()
    workspace_packages = set()
    for item in evidence.get("packages", []):
        identity = item["package"]
        require(identity in package_map, "Supplemental evidence package is absent from producer")
        package = package_map[identity]
        require("licenseEvidence" not in package,
                "Supplemental license evidence already exists for package")
        license_evidence = item["licenseEvidence"]
        package["licenseEvidence"] = license_evidence
        package["licenseEvidence"]["documentIDs"] = list(item.get("documents", []))
        if license_evidence.get("classification") == "exact-upstream-mit":
            revision = license_evidence["sourceRevision"]
            require(package["source"].endswith("#" + revision)
                    and license_evidence["license"] == "MIT"
                    and package["declaredLicense"] is None
                    and {"eappx-license", "eappx-readme-credits"} <= set(item.get("documents", [])),
                    "eappx licence or attribution is not bound to its exact git dependency")
        if license_evidence.get("classification") == "release-tag-mismatch":
            mismatch = license_evidence["vcsMismatch"]
            texts = license_evidence["resolvedTextsFrom"]
            require(mismatch["vcsRevision"] == "592a485494be9d63a60e54944dd2fcc4f077ec58"
                    and mismatch["statusCode"] == 422
                    and mismatch["crateChecksum"] == license_evidence["registryVcs"]["crateChecksum"]
                    and texts["tag"] == "v0.5.0"
                    and texts["revision"] == "1bc323a12552359f5e26b56d52aa29b3449c09ec"
                    and texts["label"] == "from upstream release tag v0.5.0",
                    "system-configuration-sys release-tag mismatch disclosure is incomplete")
        if license_evidence.get("classification") == "spdx-fallback-no-upstream-text":
            require("SPDX standard text plus copyright attribution from crate authors"
                    in license_evidence.get("fallbackDescription", ""),
                    "Missing exact SPDX fallback and crate-author attribution label")
        manifest_path = item.get("manifestPath")
        if manifest_path is not None:
            require(manifest_path.startswith("crates/") and manifest_path.endswith("/Cargo.toml"),
                    "Workspace package manifest path is outside crates/*")
            manifest = git_bytes(source, "show",
                                 inventory["producer"]["commit"] + ":" + manifest_path)
            require(git_blob_sha1(manifest) == item["manifestGitBlobSHA1"],
                    "Workspace package manifest blob mismatch")
            package_metadata = tomllib.loads(manifest.decode()).get("package", {})
            require(package_metadata.get("name") == package["name"]
                    and package_metadata.get("license") == package["declaredLicense"],
                    "Workspace package manifest identity or declared license mismatch")
            require(any(file["path"] == manifest_path
                        and file["gitBlobSHA1"] == item["manifestGitBlobSHA1"]
                        for file in producer_files),
                    "Workspace package manifest is not in producer source-file evidence")
            if license_evidence.get("classification") == "producer-root-license":
                require(package["declaredLicense"] is None
                        and license_evidence.get("grant")
                        == "GNU General Public License version 3, as provided in the producer repository's root LICENSE"
                        and license_evidence.get("versionGrantStatement")
                        == "No version-grant statement found in producer root LICENSE or README.md.",
                        "Producer root-license wording or version-grant evidence is inaccurate")
                workspace_packages.add(package["name"])
        vcs_identity = license_evidence.get("registryVcs")
        if vcs_identity is not None:
            origin = package["source"]
            locked_package, vcs = _crate_vcs(
                cargo_home, lock, package["name"], package["version"], origin)
            require(locked_package.get("checksum") == vcs_identity["crateChecksum"]
                    and vcs["git"]["sha1"] == vcs_identity["revision"]
                    and vcs.get("path_in_vcs", "") == vcs_identity.get("pathInVcs", ""),
                    "Supplemental crate identity differs from lockfile or .cargo_vcs_info.json")
            candidates = list((cargo_home / "registry/cache").glob(
                "*/" + package["name"] + "-" + package["version"] + ".crate"))
            crate_archive = owned_bytes(candidates[0], locked_package["checksum"],
                                        bounded=128 * 1024 * 1024)[1]
            crate_manifest = _crate_manifest(crate_archive)
            require(crate_manifest.get("license") == license_evidence["declaredSPDX"]
                    and package["declaredLicense"] == license_evidence["declaredSPDX"]
                    and license_evidence.get("authors")
                    == [author.split("<", 1)[0].strip()
                        for author in crate_manifest.get("authors", [])],
                    "Crate SPDX declaration or author attribution differs from its exact archive")
        classification = license_evidence.get("classification")
        referenced_documents = [documents[identifier]
                                for identifier in item.get("documents", [])]
        if classification == "exact-upstream-repository-license":
            vcs_identity = license_evidence["registryVcs"]
            require(referenced_documents
                    and all(document["source"].get("kind") == "upstream-git"
                            and document["source"].get("revision") == vcs_identity["revision"]
                            and document["source"].get("repository")
                            == license_evidence["upstreamRepository"]
                            for document in referenced_documents),
                    "Exact upstream crate licence is not bound to its locked VCS revision")
        if classification == "release-tag-mismatch":
            resolved_texts = license_evidence["resolvedTextsFrom"]
            require(referenced_documents
                    and all(document["source"].get("kind") == "upstream-git"
                            and document["source"].get("revision") == resolved_texts["revision"]
                            and document["source"].get("repository")
                            == license_evidence["upstreamRepository"]
                            and document["source"].get("label") == resolved_texts["label"]
                            for document in referenced_documents),
                    "Release-tag fallback documents do not carry the required provenance label")
        if classification == "spdx-fallback-no-upstream-text":
            require(referenced_documents
                    and all(document["source"].get("kind") == "spdx-standard"
                            and document["source"].get("label", "").startswith(
                                "SPDX standard text, license-list-data ")
                            for document in referenced_documents),
                    "SPDX fallback documents are not labelled as standard texts")
        for identifier in item.get("documents", []):
            require(identifier in documents, "Package references unknown evidence document")
            document = documents[identifier]
            text = (evidence_directory / document["path"]).read_bytes()
            _attach_notice(
                output, package["notices"], text,
                document.get("originalPath", document["source"]["sourcePath"]),
                {"evidenceDocumentID": identifier, "source": document["source"]})
            used_documents.add(identifier)
        resolved.update(item.get("resolvesObligations", []))
    if workspace_packages:
        require(workspace_packages == {
            "msixvc", "msixvc-common", "xodus", "xodus-cli",
            "xodus-management", "xodus-service",
        }, "Producer root-license evidence does not cover exactly the six local workspace crates")
        require(any(item["path"] == "LICENSE" for item in producer_files)
                and any(item["path"] == "README.md" for item in producer_files),
                "Producer root LICENSE and README source files are not hash-bound")

    components = []
    for component in evidence.get("components", []):
        record = dict(component)
        record["notices"] = []
        for identifier in component.get("documents", []):
            require(identifier in documents, "Component references unknown evidence document")
            document = documents[identifier]
            text = (evidence_directory / document["path"]).read_bytes()
            _attach_notice(
                output, record["notices"], text,
                document.get("originalPath", document["source"]["sourcePath"]),
                {"evidenceDocumentID": identifier, "source": document["source"]})
            used_documents.add(identifier)
        record.pop("documents", None)
        components.append(record)
        resolved.update(component.get("resolvesObligations", []))
    require(used_documents == set(documents),
            "Supplemental evidence contains unused or unreferenced documents")
    require(resolved <= set(inventory["unresolved"]),
            "Supplemental evidence attempted to resolve an unknown obligation")
    source_delivery = evidence["sourceDelivery"]
    require(source_delivery["sourceArchive"]["sha256"]
            == "d67b903137c96479298a139374d5bdf988db4f64ee971588183584bf520e4fdd"
            and source_delivery["sourceArchive"]["bytes"] == 9_574_400
            and source_delivery["sourceArchive"]["producer"] == inventory["producer"],
            "Corresponding-source archive differs from the approved producer source")
    channel_status = {channel["id"]: channel["status"]
                      for channel in source_delivery["channels"]}
    require(set(channel_status) == {"private-tester-zip", "release-dmg", "github-draft-release"}
            and channel_status["private-tester-zip"] == "workflow-bound"
            and channel_status["release-dmg"] == "workflow-bound"
            and channel_status["github-draft-release"] == "pending-target",
            "Corresponding-source channel status is incomplete or overclaimed")
    inventory["unresolved"] = [item for item in inventory["unresolved"] if item not in resolved]
    inventory["components"] = components
    inventory["evidenceDocuments"] = list(documents.values())
    inventory["producerSourceFiles"] = producer_files
    inventory["sourceDelivery"] = source_delivery
    inventory["provenanceObservations"] = evidence.get("provenanceObservations", [])
    inventory["rightsReview"] = "Provenance and notice-text evidence only; no legal clearance is claimed."
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
    notice_groups = [package["notices"] for package in inventory["packages"]]
    notice_groups.extend(component["notices"] for component in inventory.get("components", []))
    for group in notice_groups:
        for notice in group:
            relative = notice["path"]
            require(relative == "texts/" + notice["sha256"] + ".txt", "Invalid dependency notice path")
            owned_bytes(directory / relative, notice["sha256"], notice["bytes"])
            expected.add(relative)
    for document in inventory.get("evidenceDocuments", []):
        relative = document["path"]
        require(relative == "texts/" + document["sha256"] + ".txt",
                "Invalid supplemental evidence document path")
        owned_bytes(directory / relative, document["sha256"], document["bytes"])
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
    parser.add_argument("--upstream-notices", type=Path)
    parser.add_argument("--upstream-notices-sha256")
    parser.add_argument("--supplemental-evidence", type=Path)
    parser.add_argument("--supplemental-evidence-sha256")
    args = parser.parse_args()
    result = prepare(args.manifest, args.manifest_sha256, args.metadata, args.artifacts,
                     args.producer_source, args.cargo_home, args.output)
    if args.upstream_notices or args.supplemental_evidence:
        require(args.upstream_notices is not None and args.upstream_notices_sha256 is not None
                and args.supplemental_evidence is not None
                and args.supplemental_evidence_sha256 is not None,
                "Both pinned upstream notices and supplemental evidence are required")
        result = add_supplement(
            args.output, args.upstream_notices, args.upstream_notices_sha256,
            args.supplemental_evidence, args.supplemental_evidence_sha256,
            args.producer_source, args.cargo_home)
    print(json.dumps({"packages": len(result["packages"]),
                      "compiled": sum(p["compiled"] for p in result["packages"]),
                      "unresolved": result["unresolved"]}, sort_keys=True))
