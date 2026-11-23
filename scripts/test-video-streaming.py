#!/usr/bin/env python3
"""Opt-in live capture stress check with a disposable animated AppKit window.

Uses an attached worker and private RFB admission, not an existing server or
account password. Checks incremental Zlib delivery, resizing, optional continuous
updates/fences, and freshness while a slow reader applies backpressure. Saves no
screenshots. This is a protocol/capture check, not a RealVNC application test.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import runpy
import socket
import struct
import subprocess
import tempfile
import time
import zlib

ROOT = Path(__file__).resolve().parents[1]
helpers = runpy.run_path(str(ROOT / "scripts/test-session-capture.py"))
read, connect_viewer = helpers["read"], helpers["connect_viewer"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--seconds", type=int, default=30)
    parser.add_argument("--continuous", action="store_true")
    parser.add_argument("--read-delay", type=float, default=0.08)
    args = parser.parse_args()
    assert 5 <= args.seconds <= 120 and 0 <= args.read_delay <= 1
    with tempfile.TemporaryDirectory(prefix="vnc-video-check-") as temp, tempfile.TemporaryFile() as log:
        folder = Path(temp)
        locator = folder / "locate"
        source = folder / "locate.c"
        source.write_text(helpers["LOCATOR"])
        subprocess.run(["xcrun", "clang", str(source), str(ROOT / "Sources/CVNCSession/ConsoleSession.c"),
                        "-I", str(ROOT / "Sources/CVNCSession/include"), "-framework", "CoreGraphics",
                        "-framework", "CoreFoundation", "-framework", "IOKit", "-framework", "SystemConfiguration",
                        "-lbsm", "-o", str(locator)], check=True)
        identity = json.loads(subprocess.check_output([str(locator), str(os.getuid())], text=True))
        workload = folder / "workload"
        subprocess.run(["xcrun", "clang", "-O2", "-fobjc-arc", "-framework", "AppKit",
                        str(ROOT / "scripts/pipeline-profile/workload.m"), "-o", str(workload)], check=True)
        (folder / "workload-mode").write_text("scroll\n")
        config = dict(bindAddress="127.0.0.1", port=0, fps=60, scale=1, encodingPreference="zlib",
                      displaySelection={"all": {}}, verbose=True, clipboardSync=False, fileTransfer=False,
                      adaptiveStreaming=True, adaptiveFrameRate=True, cursorMode="auto", allowEncryption=False,
                      zlibConfiguration={"backend": "zlib-ng"},
                      transferOptions={"root": folder.as_uri(), "maximumBytes": 1, "minimumFreeBytes": 0},
                      transferDirectoryIsExplicit=False)
        parent, child = socket.socketpair()
        parent.settimeout(30)
        worker = animation = peer = None
        try:
            animation = subprocess.Popen([str(workload), str(folder)], stdout=log, stderr=log)
            worker = subprocess.Popen([str(args.binary.resolve()), "--session-worker",
                                       json.dumps(dict(identity=identity, config=config))],
                                      stdin=child, stdout=log, stderr=log,
                                      env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"})
            child.close()
            assert read(parent, 1) == b"R"
            peer = connect_viewer(parent, identity)
            peer.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 32 * 1024)
            peer.settimeout(5)
            assert read(peer, 4) == bytes(4)
            peer.sendall(b"\1")
            initial = read(peer, 24)
            width, height = struct.unpack_from(">HH", initial)
            read(peer, struct.unpack_from(">I", initial, 20)[0])
            # Exact RealVNC iPad capabilities and pixel format from the reported
            # video-freeze trace. Continuous mode adds its optional extensions.
            encodings = [6,24,22,21,16,15,5,2,0,1,-314,-239,-223] + ([-313, -312] if args.continuous else [])
            peer.sendall(struct.pack(">BBH", 2, 0, len(encodings)) + b"".join(struct.pack(">i", e) for e in encodings))
            peer.sendall(bytes(4) + struct.pack(">BBBBHHHBBBxxx", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0))

            def request(incremental):
                peer.sendall(struct.pack(">BBHHHH", 3, int(incremental), 0, 0, width, height))

            def continuous():
                peer.sendall(struct.pack(">BBHHHH", 150, 1, 0, 0, width, height))

            decoder = zlib.decompressobj()
            framebuffer = bytearray(width * height * 4)
            frames = resizes = fences = 0
            started = last_fresh = time.monotonic()
            previous = None
            request(False)
            while time.monotonic() - started < args.seconds:
                kind = read(peer, 1)[0]
                if kind == 150:
                    continue
                if kind == 248:
                    head = read(peer, 8)
                    flags, size = struct.unpack(">IB", head[3:])
                    payload = read(peer, size)
                    if flags & 0x80000000:
                        peer.sendall(b"\xf8\0\0\0" + struct.pack(">IB", flags & 3, size) + payload)
                        fences += 1
                    continue
                assert kind == 0, f"unexpected server message {kind}"
                count = struct.unpack(">H", read(peer, 3)[1:])[0]
                time.sleep(args.read_delay)
                pixels_received = resized = False
                for _ in range(count):
                    x, y, w, h, encoding = struct.unpack(">HHHHi", read(peer, 12))
                    if encoding == -223:
                        width, height = w, h
                        framebuffer = bytearray(width * height * 4)
                        resized = True
                        resizes += 1
                    elif encoding == -239:
                        read(peer, w * h * 4 + ((w + 7) // 8) * h)
                    elif encoding in (1, 6):
                        assert 0 < w and 0 < h and x + w <= width and y + h <= height
                        if encoding == 6:
                            length = struct.unpack(">I", read(peer, 4))[0]
                            assert length < 256 * 1024 * 1024
                            pixels = decoder.decompress(read(peer, length))
                        else:
                            sx, sy = struct.unpack(">HH", read(peer, 4))
                            assert sx + w <= width and sy + h <= height
                            pixels = b"".join(framebuffer[((sy + row) * width + sx) * 4:
                                ((sy + row) * width + sx + w) * 4] for row in range(h))
                        assert len(pixels) == w * h * 4
                        for row in range(h):
                            start = ((y + row) * width + x) * 4
                            framebuffer[start:start + w * 4] = pixels[row * w * 4:(row + 1) * w * 4]
                        pixels_received = True
                    else:
                        raise AssertionError(f"unexpected encoding {encoding}")
                if pixels_received:
                    frames += 1
                    current = hashlib.sha256(framebuffer).digest()
                    if current != previous:
                        last_fresh = time.monotonic()
                        previous = current
                    if args.continuous and frames == 1:
                        continuous()
                assert time.monotonic() - last_fresh < 5, "video delivery stopped producing fresh pixels"
                if resized:
                    if args.continuous:
                        continuous()
                    request(False)
                elif not args.continuous:
                    request(True)
            assert frames >= args.seconds, f"only {frames} frames in {args.seconds} seconds"
            assert resizes == 0, "video load changed the viewer resolution"
            print(f"PASS live animated capture: seconds={args.seconds} frames={frames} resizes={resizes} "
                  f"fences={fences} continuous={args.continuous} read_delay={args.read_delay}")
        finally:
            if peer:
                peer.close()
            parent.close()
            child.close()
            forced = False
            if worker:
                try:
                    worker.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    forced = True
                    worker.terminate()
                    try:
                        worker.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        worker.kill()
                        worker.wait(timeout=5)
            if animation:
                animation.terminate()
                try:
                    animation.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    animation.kill()
                    animation.wait(timeout=5)
            text = os.pread(log.fileno(), 16 * 1024 * 1024, 0).decode(errors="replace")
            print(text)
            assert not forced, "temporary capture worker did not stop"
            if worker:
                assert worker.returncode == 0, f"temporary worker exited {worker.returncode}"


if __name__ == "__main__":
    main()
