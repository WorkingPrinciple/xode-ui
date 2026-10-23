"""One hash-bound ScreenCaptureKit capture, with owned-child timeout and atomic PNG publication."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import time
import zlib


def validate_png(path):
    data = path.read_bytes()
    if len(data) > 64 * 2**20 or data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("Expected bounded PNG")
    position, chunks, compressed, dimensions = 8, [], bytearray(), None
    while position < len(data):
        if len(data) - position < 12:
            raise ValueError("Truncated PNG chunk")
        size, = struct.unpack(">I", data[position:position + 4])
        end = position + 12 + size
        if end > len(data):
            raise ValueError("Truncated PNG payload")
        kind = data[position + 4:position + 8]
        payload = data[position + 8:end - 4]
        crc, = struct.unpack(">I", data[end - 4:end])
        if zlib.crc32(kind + payload) != crc:
            raise ValueError("PNG checksum mismatch")
        if not chunks and kind != b"IHDR":
            raise ValueError("Missing PNG header")
        if kind == b"IHDR":
            if dimensions or size != 13:
                raise ValueError("Invalid PNG header")
            width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", payload)
            channels = {0: 1, 2: 3, 4: 2, 6: 4}.get(color)
            if not channels or depth not in (8, 16) or compression or filtering or interlace:
                raise ValueError("Unsupported PNG encoding")
            if not 1 <= width <= 16384 or not 1 <= height <= 16384:
                raise ValueError("PNG dimensions outside capture bounds")
            dimensions = (width, height)
            expected = height * (1 + width * channels * depth // 8)
            if expected > 128 * 2**20:
                raise ValueError("Decoded PNG too large")
        elif kind == b"IDAT":
            compressed.extend(payload)
        elif kind == b"IEND":
            if size or end != len(data) or not compressed:
                raise ValueError("Incomplete PNG or trailing data")
            decoder = zlib.decompressobj()
            pixels = decoder.decompress(compressed, expected + 1)
            if len(pixels) != expected or not decoder.eof or decoder.unused_data:
                raise ValueError("Incomplete PNG pixels")
            return dimensions
        chunks.append(kind)
        position = end
    raise ValueError("Missing PNG end")


def capture(binary, expected_sha, pid, window, title, output, timeout):
    if (not binary.is_absolute() or binary.is_symlink() or not binary.is_file()
            or hashlib.sha256(binary.read_bytes()).hexdigest() != expected_sha):
        raise ValueError("Capture binary identity mismatch")
    if not 1 <= pid <= 2147483647 or not 1 <= window <= 4294967295 or not title:
        raise ValueError("Expected exact owned PID/window/title")
    if not 0 < timeout <= 30 or output.exists() or output.is_symlink():
        raise ValueError("Invalid timeout or existing output")
    receipt_path = output.with_suffix(output.suffix + ".capture.json")
    if receipt_path.exists():
        raise ValueError("Capture evidence already exists")
    staging = Path(tempfile.mkdtemp(prefix=".capture-", dir=output.parent))
    image = staging / "image.png"
    argv = [str(binary), str(pid), str(window), title, str(image)]
    receipt = {"argv": argv, "binarySha256": expected_sha, "startedUnix": time.time(),
               "completed": False, "artifacts": str(staging)}
    try:
        child = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        receipt["capturePid"] = child.pid
        try:
            stdout, stderr = child.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            child.kill()
            stdout, stderr = child.communicate()
            receipt.update(stdout=stdout, stderr=stderr, returncode=child.returncode, timedOut=True)
            raise TimeoutError(f"Owned capture PID {child.pid} exceeded {timeout}s and was killed/reaped")
        receipt.update(stdout=stdout, stderr=stderr, returncode=child.returncode, timedOut=False)
        if child.returncode:
            raise RuntimeError(f"Capture PID {child.pid} failed: {stderr.strip()}")
        result = json.loads(stdout)
        dimensions = validate_png(image)
        if (result.get("completed") is not True or result.get("pid") != pid
                or result.get("window") != window
                or dimensions != (result.get("width"), result.get("height"))):
            raise ValueError("Capture completion identity/dimensions mismatch")
        image.chmod(0o600)
        os.link(image, output)
        image.unlink()
        staging.rmdir()
        receipt.update(completed=True, output=str(output),
                       sha256=hashlib.sha256(output.read_bytes()).hexdigest(),
                       width=dimensions[0], height=dimensions[1])
        return receipt
    except (OSError, ValueError, RuntimeError, zlib.error) as error:
        receipt.update(errorType=type(error).__name__, error=str(error))
        raise
    finally:
        receipt["finishedUnix"] = time.time()
        with receipt_path.open("x") as stream:
            json.dump(receipt, stream, indent=2)
            stream.write("\n")
        receipt_path.chmod(0o600)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--binary-sha256", required=True)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--window", type=int, required=True)
    parser.add_argument("--title", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout-seconds", type=float, default=10)
    args = parser.parse_args()
    print(json.dumps(capture(args.binary, args.binary_sha256, args.pid, args.window,
                             args.title, args.output, args.timeout_seconds)))


if __name__ == "__main__":
    main()
