#!/usr/bin/env python3
"""Opt-in real ScreenCaptureKit startup check; requires Screen Recording access.

Starts isolated loopback servers, including the staged AppKit entry point and
automatic display listeners. Receives real Zlib framebuffer rectangles without
posting input or saving desktop pixels. No client URL parameters are used.
"""
import argparse
import json
import os
from pathlib import Path
import pty
import socket
import struct
import subprocess
import tempfile
import threading
import time
import zlib


def read_exact(sock, length):
    data = bytearray()
    while len(data) < length:
        block = sock.recv(length - len(data))
        if not block:
            raise RuntimeError("Server closed the connection")
        data.extend(block)
    return bytes(data)


def frame(sock):
    assert read_exact(sock, 12).startswith(b"RFB ")
    sock.sendall(b"RFB 003.008\n")
    count = read_exact(sock, 1)[0]
    assert 1 in read_exact(sock, count), "Isolated test must offer None auth"
    sock.sendall(b"\x01")
    assert read_exact(sock, 4) == b"\0" * 4
    sock.sendall(b"\x01")
    init = read_exact(sock, 24)
    width, height = struct.unpack_from(">HH", init)
    read_exact(sock, struct.unpack_from(">I", init, 20)[0])
    # Standard 32-bit little-endian BGRX; Zlib is the only requested encoding.
    pixel_format = struct.pack(">BBBBHHHBBB3x", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
    sock.sendall(b"\0\0\0\0" + pixel_format)
    sock.sendall(struct.pack(">BBHi", 2, 0, 1, 6))
    sock.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, width, height))
    header = read_exact(sock, 4)
    assert header[0] == 0, "Expected FramebufferUpdate"
    count = struct.unpack_from(">H", header, 2)[0]
    assert count > 0
    decoder = zlib.decompressobj()
    byte_count, varied = 0, False
    for _ in range(count):
        x, y, w, h, encoding = struct.unpack(">HHHHi", read_exact(sock, 12))
        assert encoding == 6, f"Expected Zlib, got {encoding}"
        assert x + w <= width and y + h <= height
        length = struct.unpack(">I", read_exact(sock, 4))[0]
        assert length <= 256 * 1024 * 1024
        pixels = decoder.decompress(read_exact(sock, length))
        assert len(pixels) == w * h * 4
        byte_count += len(pixels)
        varied |= len(set(pixels)) > 1
    assert byte_count > 0
    return {"width": width, "height": height, "rectangles": count,
            "decoded_bytes": byte_count, "nonuniform_pixels": varied}


def collect_output(fd, chunks):
    # Drain throughout frame reads: a full PTY can otherwise block the server's
    # logger and make a successful startup look like a handshake timeout.
    while True:
        try:
            block = os.read(fd, 65536)
        except OSError:
            break
        if not block:
            break
        chunks.append(block)


def check(binary, name, extra):
    # Reserve enough consecutive ports for ordinary multi-monitor setups.
    for _ in range(100):
        reserved = []
        try:
            first = socket.socket()
            first.bind(("127.0.0.1", 0))
            reserved.append(first)
            port = first.getsockname()[1]
            for offset in range(1, 9):
                other = socket.socket()
                reserved.append(other)
                other.bind(("127.0.0.1", port + offset))
            break
        except OSError:
            pass
        finally:
            for item in reserved:
                item.close()
    else:
        raise RuntimeError("Cannot find unused consecutive ports")

    with tempfile.TemporaryDirectory(prefix="mac-vnc-capture-smoke-") as root:
        master, slave = pty.openpty()
        args = [str(binary), "--verbose", "--encoding", "zlib", "--clipboard-sync",
                "--bind", "127.0.0.1", "--port", str(port), "--no-password",
                "--no-encryption", "--transfer-directory", root] + extra
        process = subprocess.Popen(args, stdout=slave, stderr=slave)
        os.close(slave)
        chunks = []
        reader = threading.Thread(target=collect_output, args=(master, chunks), daemon=True)
        reader.start()
        start = time.monotonic()
        succeeded = False
        try:
            deadline = start + 80
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError(f"Startup exited {process.returncode}")
                try:
                    sock = socket.create_connection(("127.0.0.1", port), timeout=1)
                    break
                except ConnectionRefusedError:
                    time.sleep(0.05)
            else:
                raise RuntimeError("Startup did not listen within 80 seconds")
            with sock:
                sock.settimeout(10)
                result = frame(sock)
            # Automatic selection must also bring up its per-display server.
            if "--display" not in extra:
                with socket.create_connection(("127.0.0.1", port + 1), timeout=10) as display:
                    frame(display)
            assert b"CONTINUATION MISUSE" not in b"".join(chunks)
            result.update(case=name, uri=f"vnc://127.0.0.1:{port}/",
                          startup_and_frame_ms=round((time.monotonic() - start) * 1000, 1))
            succeeded = True
            return result
        except Exception as error:
            log = b"".join(chunks).decode(errors="replace")
            raise RuntimeError(f"{name}: {error}\n{log}") from error
        finally:
            process.terminate()
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            reader.join(timeout=2)
            os.close(master)
            if succeeded:
                assert process.returncode == 0, "Server did not shut down cleanly"
                assert b"ScreenCaptureKit: capture stopped" in b"".join(chunks)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", nargs="?", default=".build/release/mac-vnc-server-dev")
    options = parser.parse_args()
    for name, extra in [
        ("staged-automatic", ["--file-transfer"]),
        ("native-automatic", ["--file-transfer", "--file-drop-mode", "native"]),
        ("staged-single-display", ["--file-transfer", "--display", "all"]),
        ("capture-only", ["--display", "all"]),
    ]:
        print(json.dumps(check(Path(options.binary).resolve(), name, extra)), flush=True)
