#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Trust one new DMG, retaining exact submission bytes privately for reconciliation."""
import hashlib
import fcntl
from contextlib import contextmanager
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import uuid


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate Apple response key")
        result[key] = value
    return result


def persistent_root(environment=os.environ):
    value = environment.get("RELEASE_DMG_RECOVERY_ROOT", "")
    if not value:
        raise ValueError("RELEASE_DMG_RECOVERY_ROOT must name provisioned persistent owner-only storage")
    root = Path(value)
    if not root.is_absolute() or root.resolve(strict=True) != root or not root.is_dir():
        raise ValueError("Recovery root must be an existing canonical absolute directory")
    metadata = root.stat()
    if metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != 0o700:
        raise ValueError("Recovery root must be owned by the runner user with mode 0700")
    volatile = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]
    volatile += [environment[key] for key in ("RUNNER_TEMP", "TMPDIR", "GITHUB_WORKSPACE")
                 if environment.get(key)]
    if any(root.is_relative_to(Path(path).resolve()) for path in volatile):
        raise ValueError("Recovery root cannot be temporary storage or the Actions workspace")
    policy = root / ".ode-dmg-recovery.json"
    metadata = policy.lstat()
    if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid()
            or stat.S_IMODE(metadata.st_mode) != 0o600):
        raise ValueError("Recovery persistence policy must be an owner-only regular file (0600)")
    if json.loads(policy.read_text(), object_pairs_hook=unique) != {
            "version": 1, "retention": "owner-managed-persistent"}:
        raise ValueError("Recovery storage needs the operator's explicit persistent-retention policy")
    return root


def identity(path):
    digest, size = hashlib.sha256(), 0
    with path.open("rb") as source:
        for data in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(data)
            size += len(data)
    return {"sha256": digest.hexdigest(), "bytes": size}


def write_json(path, value):
    temporary = path.with_suffix(".tmp")
    with temporary.open("w") as output:
        output.write(json.dumps(value, indent=2, sort_keys=True) + "\n")
        output.flush()
        os.fsync(output.fileno())
    temporary.chmod(0o600)
    temporary.replace(path)
    sync_directory(path.parent)


def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


@contextmanager
def submission_lock(root):
    # Keep one inode permanently: unlinking a released lock lets contenders
    # lock different files. The kernel releases flock even after SIGKILL.
    descriptor = os.open(root / ".submission.lock",
                         os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        metadata = os.fstat(descriptor)
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid()
                or stat.S_IMODE(metadata.st_mode) != 0o600 or metadata.st_nlink != 1):
            raise ValueError("Submission lock must be an owner-only regular file (0600)")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError("A DMG trust operation is already active for this recovery root") from error
        yield
    finally:
        os.close(descriptor)


def trust(image, evidence, environment=os.environ):
    root = persistent_root(environment)
    with submission_lock(root):
        trust_locked(image, evidence, root, environment)


def trust_locked(image, evidence, root, environment):
    for previous in root.glob("dmg-*"):
        record = previous / "receipt.json"
        if (previous.is_symlink() or not record.is_file()
                or json.loads(record.read_text(), object_pairs_hook=unique).get("state") != "trusted"):
            raise ValueError("An earlier DMG attempt requires owner reconciliation before a new submission")
    attempt = Path(tempfile.mkdtemp(prefix="dmg-", dir=root))
    attempt.chmod(0o700)
    sync_directory(root)
    evidence.mkdir(mode=0o700, parents=True, exist_ok=True)
    receipt = {"version": 1, "attempt": attempt.name, "state": "preparing",
               "submissionID": None, "notaryStatus": None, "automaticRetry": False}

    def save():
        # This allowlisted receipt is suitable for public Actions artifacts:
        # no command arguments, runner paths, Keychain profile or raw diagnostics.
        write_json(attempt / "receipt.json", receipt)
        write_json(evidence / "receipt.json", receipt)

    def execute(command, label, timeout=1800):
        with (attempt / (label + ".json")).open("xb") as stdout, (
                attempt / (label + "-stderr.log")).open("xb") as stderr:
            result = subprocess.run(command, stdout=stdout, stderr=stderr, timeout=timeout)
        if result.returncode:
            raise ValueError(label + " failed; reconcile the private recovery attempt before retry")
        return attempt / (label + ".json")

    def interrupted(signum, frame):
        raise InterruptedError("Interrupted; reconcile the private recovery attempt before retry")

    old_handlers = {sig: signal.signal(sig, interrupted)
                    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    try:
        save()
        submitted = attempt / "submitted.dmg"
        shutil.copyfile(image, submitted)
        submitted.chmod(0o400)
        with submitted.open("rb") as source:
            os.fsync(source.fileno())
        receipt["submittedImage"] = identity(submitted)
        if identity(image) != receipt["submittedImage"]:
            raise ValueError("Signed image changed during recovery capture")
        receipt["state"] = "submission-may-have-started"
        save()
        profile = environment["RELEASE_NOTARY_PROFILE"]
        response = execute(["xcrun", "notarytool", "submit", str(submitted),
                            "--keychain-profile", profile, "--output-format", "json"], "submit")
        submission = json.loads(response.read_text(), object_pairs_hook=unique)
        if not isinstance(submission, dict):
            raise ValueError("Apple submission response is not an object")
        submission_id = submission.get("id")
        if not isinstance(submission_id, str) or str(uuid.UUID(submission_id)) != submission_id.lower():
            raise ValueError("Apple submission did not return a valid ID; reconcile before retry")
        receipt["submissionID"] = submission_id
        receipt["state"] = "waiting"
        save()
        response = execute(["xcrun", "notarytool", "wait", submission_id,
                            "--keychain-profile", profile, "--timeout", "1h",
                            "--output-format", "json"], "wait", timeout=3660)
        result = json.loads(response.read_text(), object_pairs_hook=unique)
        if not isinstance(result, dict):
            raise ValueError("Apple wait response is not an object")
        if result.get("id") != submission_id:
            raise ValueError("Apple wait response does not identify the selected submission")
        status = result.get("status")
        receipt["notaryStatus"] = status if status in ("Accepted", "Invalid", "In Progress", "Rejected") else None
        save()
        if status != "Accepted":
            raise ValueError("Apple did not accept the selected submission")
        if identity(submitted) != receipt["submittedImage"]:
            raise ValueError("Submission image changed while waiting for Apple")
        final = attempt / "distribution.dmg"
        shutil.copyfile(submitted, final)
        final.chmod(0o600)
        for verb in ("staple", "validate"):
            execute(["xcrun", "stapler", verb, str(final)], verb)
        execute(["codesign", "--verify", "--strict", str(final)], "final-signature")
        execute(["spctl", "--assess", "--type", "open", "--context",
                 "context:primary-signature", "--verbose=4", str(final)], "gatekeeper")
        receipt["distributionImage"] = identity(final)
        shutil.copyfile(final, image)
        if identity(image) != receipt["distributionImage"]:
            raise ValueError("Final distribution image copy changed")
        receipt["state"] = "trusted"
        save()
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        receipt["state"] = "reconciliation-required"
        save()
        raise ValueError("DMG trust incomplete; reconcile owner-only attempt " + attempt.name
                         + " before any new submission") from error
    finally:
        for sig, handler in old_handlers.items():
            signal.signal(sig, handler)


if __name__ == "__main__":
    os.umask(0o077)
    try:
        if sys.argv[1:] == ["preflight"]:
            persistent_root()
        elif len(sys.argv) == 3:
            trust(Path(sys.argv[1]), Path(sys.argv[2]))
        else:
            raise ValueError("Usage: release_dmg_trust.py preflight | image evidenceDirectory")
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        sys.exit("DMG trust rejected: " + str(error))
