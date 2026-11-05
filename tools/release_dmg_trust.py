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


class TrustFailure(Exception):
    def __init__(self, stage, reason, exit_code=None, timed_out=False, attempt=None):
        self.stage = stage
        self.reason = reason
        self.exit_code = exit_code
        self.timed_out = timed_out
        self.attempt = attempt

    def receipt(self):
        return {
            "stage": self.stage,
            "reason": self.reason,
            "exitCode": self.exit_code,
            "timedOut": self.timed_out,
        }

    def exit_status(self):
        if self.timed_out:
            return 124
        if self.reason == "operation_interrupted":
            return 130 if self.exit_code is None else self.exit_code
        return 1

    def diagnostic(self):
        parts = [f"DMG trust failed at {self.stage}: {self.reason}"]
        if self.exit_code is not None:
            parts.append(f"command exit {self.exit_code}")
        if self.timed_out:
            parts.append("timed out")
        if self.attempt:
            parts.append(f"reconcile attempt {self.attempt}")
        return "; ".join(parts)


def fail(stage, reason, exit_code=None, timed_out=False):
    raise TrustFailure(stage, reason, exit_code, timed_out)


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
            raise TrustFailure("recovery-lock", "operation_already_active") from error
        yield
    finally:
        os.close(descriptor)


def trust(image, evidence, environment=os.environ):
    try:
        root = persistent_root(environment)
    except (OSError, ValueError, KeyError):
        fail("recovery-preflight", "persistent_recovery_configuration_invalid")
    try:
        with submission_lock(root):
            trust_locked(image, evidence, root, environment)
    except TrustFailure:
        raise
    except (OSError, ValueError, KeyError):
        fail("recovery-state", "persistent_recovery_state_invalid")


def read_json(path, stage):
    try:
        return json.loads(path.read_text(), object_pairs_hook=unique)
    except (OSError, UnicodeDecodeError, ValueError):
        fail(stage, "invalid_response")


def trust_locked(image, evidence, root, environment):
    for previous in root.glob("dmg-*"):
        record = previous / "receipt.json"
        if previous.is_symlink() or not record.is_file():
            fail("recovery-check", "prior_attempt_requires_reconciliation")
        if read_json(record, "recovery-check").get("state") != "trusted":
            fail("recovery-check", "prior_attempt_requires_reconciliation")
    attempt = Path(tempfile.mkdtemp(prefix="dmg-", dir=root))
    attempt.chmod(0o700)
    sync_directory(root)
    evidence.mkdir(mode=0o700, parents=True, exist_ok=True)
    receipt = {"version": 1, "attempt": attempt.name, "state": "preparing",
               "submissionID": None, "notaryStatus": None, "automaticRetry": False}
    current_stage = "prepare"

    def save():
        # This allowlisted receipt is suitable for public Actions artifacts:
        # no command arguments, runner paths, Keychain profile or raw diagnostics.
        write_json(attempt / "receipt.json", receipt)
        write_json(evidence / "receipt.json", receipt)

    def execute(command, label, timeout=1800):
        try:
            with (attempt / (label + ".json")).open("xb") as stdout, (
                    attempt / (label + "-stderr.log")).open("xb") as stderr:
                result = subprocess.run(command, stdout=stdout, stderr=stderr, timeout=timeout)
        except subprocess.TimeoutExpired:
            fail(label, "command_timeout", 124, True)
        except FileNotFoundError:
            fail(label, "command_not_found")
        except PermissionError:
            fail(label, "command_permission_denied")
        except OSError:
            fail(label, "command_unavailable_or_local_io_failed")
        if result.returncode:
            fail(label, "command_failed", result.returncode)
        return attempt / (label + ".json")

    def interrupted(signum, frame):
        raise TrustFailure(current_stage, "operation_interrupted", 130)

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
            fail("capture", "submitted_image_identity_mismatch")
        receipt["state"] = "submission-may-have-started"
        save()
        current_stage = "submit"
        profile = environment["RELEASE_NOTARY_PROFILE"]
        response = execute(["xcrun", "notarytool", "submit", str(submitted),
                            "--keychain-profile", profile, "--output-format", "json"], "submit")
        submission = read_json(response, "submit-response")
        if not isinstance(submission, dict):
            fail("submit-response", "invalid_response")
        submission_id = submission.get("id")
        try:
            valid_submission_id = isinstance(submission_id, str) and (
                str(uuid.UUID(submission_id)) == submission_id.lower())
        except ValueError:
            valid_submission_id = False
        if not valid_submission_id:
            fail("submit-response", "submission_id_invalid")
        receipt["submissionID"] = submission_id
        receipt["state"] = "waiting"
        save()
        current_stage = "wait"
        response = execute(["xcrun", "notarytool", "wait", submission_id,
                            "--keychain-profile", profile, "--timeout", "1h",
                            "--output-format", "json"], "wait", timeout=3660)
        current_stage = "wait-response"
        result = read_json(response, "wait-response")
        if not isinstance(result, dict):
            fail("wait-response", "invalid_response")
        if result.get("id") != submission_id:
            fail("wait-response", "submission_id_mismatch")
        status = result.get("status")
        receipt["notaryStatus"] = status if status in ("Accepted", "Invalid", "In Progress", "Rejected") else None
        current_stage = "notary-result"
        save()
        if status != "Accepted":
            fail("notary-result", "submission_not_accepted")
        current_stage = "submitted-image-check"
        if identity(submitted) != receipt["submittedImage"]:
            fail("submitted-image-check", "submitted_image_identity_mismatch")
        current_stage = "finalize"
        final = attempt / "distribution.dmg"
        shutil.copyfile(submitted, final)
        final.chmod(0o600)
        for verb in ("staple", "validate"):
            execute(["xcrun", "stapler", verb, str(final)], verb)
        execute(["codesign", "--verify", "--strict", str(final)], "final-signature")
        execute(["spctl", "--assess", "--type", "open", "--context",
                 "context:primary-signature", "--verbose=4", str(final)], "gatekeeper")
        receipt["distributionImage"] = identity(final)
        current_stage = "copy-back"
        shutil.copyfile(final, image)
        if identity(image) != receipt["distributionImage"]:
            fail("copy-back", "distribution_image_identity_mismatch")
        receipt["state"] = "trusted"
        save()
    except TrustFailure as error:
        receipt["state"] = "reconciliation-required"
        receipt["failure"] = error.receipt()
        save()
        error.attempt = attempt.name
        raise
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        receipt["state"] = "reconciliation-required"
        receipt["failure"] = TrustFailure(current_stage, "local_operation_failed").receipt()
        save()
        raise TrustFailure(current_stage, "local_operation_failed",
                           attempt=attempt.name) from None
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
            fail("invocation", "invalid_arguments")
    except TrustFailure as error:
        print(error.diagnostic(), file=sys.stderr)
        sys.exit(error.exit_status())
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        print("DMG trust failed at recovery-preflight: persistent_recovery_configuration_invalid",
              file=sys.stderr)
        sys.exit(1)
