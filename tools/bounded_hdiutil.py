#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Run one owned hdiutil child with bounded execution and termination waits."""
import signal
import subprocess
import sys


class InterruptedOperation(Exception):
    pass


def run(arguments):
    if not arguments or arguments[0] not in ("create", "verify", "attach", "detach"):
        raise ValueError("unsupported hdiutil operation")
    timeout = 5 if arguments[0] == "detach" else 120
    child = None

    def interrupted(signum, frame):
        raise InterruptedOperation(f"signal {signum}")

    for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, interrupted)
    try:
        child = subprocess.Popen(["hdiutil", *arguments])
        return child.wait(timeout=timeout)
    except (subprocess.TimeoutExpired, InterruptedOperation) as error:
        reason = "timed out" if isinstance(error, subprocess.TimeoutExpired) else "interrupted"
        print(f"package_release: hdiutil {arguments[0]} {reason}; mount state is uncertain",
              file=sys.stderr)
        return 124
    finally:
        # Keep the direct child unreaped until this sole owner finishes signaling.
        for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            signal.signal(signum, signal.SIG_IGN)
        if child is not None and child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=1)
            except subprocess.TimeoutExpired:
                child.kill()
                try:
                    child.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    print(f"package_release: owned hdiutil PID {child.pid} did not exit; "
                          "manual reconciliation required", file=sys.stderr)


if __name__ == "__main__":
    try:
        sys.exit(run(sys.argv[1:]))
    except (OSError, ValueError) as error:
        sys.exit(f"package_release: cannot run bounded hdiutil: {error}")
