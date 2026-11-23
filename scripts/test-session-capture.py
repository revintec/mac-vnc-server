#!/usr/bin/env python3
"""Opt-in capture/RichCursor check of an attached worker, without input or a VNC listener.

Account authentication is outside this test: a private socketpair supplies a
fixture admission after session attachment. --root requires loginwindow and, on
macOS 14+, an already-running root capture service. Ventura captures directly
with CoreGraphics and may request a display wake. No services or existing servers are
restarted, no passwords are used, and no screenshot is saved. The temporary
worker exits when its private parent channel closes.
"""
import argparse
import array
import json
import os
import platform
from pathlib import Path
import re
import shlex
import socket
import struct
import subprocess
import tempfile
import time
import zlib

ROOT = Path(__file__).resolve().parents[1]
LOCATOR = r'''
#include "CVNCSession.h"
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    VNCConsoleIdentity identity = {0};
    if (argc != 2 || VNCSessionForUser((uint32_t)strtoul(argv[1], NULL, 10), &identity)) return 2;
    printf("{\"uid\":%u,\"auditID\":%d}\n", identity.uid, identity.audit_id);
}
'''


def read(peer, count):
    data = bytearray()
    while len(data) < count:
        part = peer.recv(count - len(data))
        if not part:
            raise RuntimeError("worker closed its socket")
        data.extend(part)
    return bytes(data)


def connect_viewer(parent, identity, console_bridge=False):
    # TCP_NODELAY is part of the RFB engine, so use a private local TCP pair.
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0)); reservation.listen(1)
        viewer = socket.create_connection(reservation.getsockname(), timeout=5)
        worker_peer, _ = reservation.accept()
    viewer.settimeout(20)
    try:
        metadata = json.dumps(dict(identity=identity, version="RFB 003.008\n", wrappingKey=[17] * 16,
                                   consoleBridge=console_bridge)).encode()
        parent.sendmsg([b"F"], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [worker_peer.fileno()]))])
        parent.sendall(struct.pack(">I", len(metadata)) + metadata)
        return viewer
    except BaseException:
        viewer.close()
        raise
    finally:
        worker_peer.close()


class Viewer:
    def __init__(self, peer, console_bridge=False):
        self.peer = peer
        self.console_bridge = console_bridge
        self.decoder = zlib.decompressobj()
        self.cursor = None
        self.position = None
        assert read(peer, 4) == bytes(4)
        peer.sendall(b"\1")
        initial = read(peer, 24)
        self.width, self.height = struct.unpack_from(">HH", initial)
        read(peer, struct.unpack_from(">I", initial, 20)[0])
        encodings = [0, -239, -232] if console_bridge else [6, -239]
        peer.sendall(struct.pack(">BBH", 2, 0, len(encodings)) + b"".join(struct.pack(">i", encoding) for encoding in encodings))

    def frame(self):
        peer = self.peer
        peer.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, self.width, self.height))
        update = read(peer, 4)
        assert update[0] == 0
        total = 0; varied = False
        for _ in range(struct.unpack_from(">H", update, 2)[0]):
            x, y, w, h, encoding = struct.unpack(">HHHHi", read(peer, 12))
            if encoding == -239:
                assert w > 0 and h > 0 and x < w and y < h
                payload = read(peer, w * h * 4 + ((w + 7) // 8) * h)
                assert any(payload[w * h * 4:])
                self.cursor = (w, h)
            elif encoding == -232:
                assert self.console_bridge and w == 0 and h == 0 and x < self.width and y < self.height
                self.position = (x, y)
            elif encoding == 0:
                assert self.console_bridge
                pixels = read(peer, w * h * 4)
                varied |= len(set(pixels)) > 1
                total += len(pixels)
            elif encoding == 6:
                length = struct.unpack(">I", read(peer, 4))[0]
                assert length <= 256 * 1024 * 1024
                pixels = self.decoder.decompress(read(peer, length))
                assert len(pixels) == w * h * 4
                varied |= len(set(pixels)) > 1
                total += len(pixels)
            else:
                raise AssertionError(f"unexpected encoding {encoding}")
        assert total == self.width * self.height * 4 and varied and self.cursor
        assert not self.console_bridge or self.position is not None
        print(f"PASS frame={self.width}x{self.height} RichCursor={self.cursor} cursor_position={self.position} pixel_bytes_decoded={total} plaintext_frames=yes")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--root", action="store_true")
    parser.add_argument("--console-bridge", action="store_true",
                        help="exercise the private Raw/RichCursor/PointerPos path; selected account must own the console")
    parser.add_argument("--cycles", type=int, default=1,
                        help="reconnect cycles; each checks two overlapping viewers and idle capture teardown")
    parser.add_argument("--inspect-idle", action="store_true", help="sample this temporary worker's CPU and scan its heap after the cycles")
    args = parser.parse_args()
    assert 1 <= args.cycles <= 20
    uid = 0 if args.root else os.getuid()
    core_graphics = uid == 0 and platform.mac_ver()[0].split(".")[0] == "13"
    capture_start = "CoreGraphics: starting verified loginwindow capture" if core_graphics else "ScreenCaptureKit: enumerating displays"
    capture_stop = "CoreGraphics: capture stopped" if core_graphics else "ScreenCaptureKit: capture stopped"
    with tempfile.TemporaryDirectory(prefix="vnc-session-capture-") as directory, tempfile.TemporaryFile() as log:
        folder = Path(directory)
        source = folder / "locate.c"
        source.write_text(LOCATOR)
        locator = folder / "locate"
        subprocess.run(["xcrun", "clang", str(source), str(ROOT / "Sources/CVNCSession/ConsoleSession.c"),
            "-I", str(ROOT / "Sources/CVNCSession/include"), "-framework", "CoreGraphics",
            "-framework", "CoreFoundation", "-framework", "IOKit", "-framework", "SystemConfiguration",
            "-lbsm", "-o", str(locator)], check=True)
        identity = json.loads(subprocess.check_output([str(locator), str(uid)], text=True, timeout=5))
        config = dict(bindAddress="127.0.0.1", port=0,
            fps=10, scale=1, encodingPreference="zlib", displaySelection={"all": {}}, verbose=True,
            clipboardSync=False, fileTransfer=False, adaptiveStreaming=True, adaptiveFrameRate=True,
            cursorMode="auto", allowEncryption=False, zlibConfiguration={"backend": "zlib-ng"},
            transferOptions={"root": folder.as_uri(), "maximumBytes": 1, "minimumFreeBytes": 0},
            transferDirectoryIsExplicit=False)
        options = dict(identity=identity, config=config)
        command = [str(args.binary.resolve()), "--session-worker", json.dumps(options)]
        if args.root:
            command = ["sudo", "-n", "/bin/zsh", "-c", "exec " + shlex.join(["/bin/launchctl", "asuser", "0"] + command)]
        parent, child = socket.socketpair()
        parent.settimeout(20)
        peers = []
        process = subprocess.Popen(command, stdin=child, stdout=log, stderr=log,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"})
        child.close()
        def text_log():
            return os.pread(log.fileno(), 4 * 1024 * 1024, 0).decode(errors="replace")

        idle_message = "Session worker idle: capture and cursor sampling released"

        def wait_idle(count):
            deadline = time.monotonic() + 15
            while text_log().count(idle_message) < count:
                assert process.poll() is None, text_log()
                assert time.monotonic() < deadline, "capture did not retire after the last viewer disconnected"
                time.sleep(0.05)

        try:
            assert read(parent, 1) == b"R"
            assert capture_start not in text_log(), "capture started without a viewer"
            for cycle in range(args.cycles):
                first = connect_viewer(parent, identity, args.console_bridge); peers.append(first)
                Viewer(first, args.console_bridge).frame()
                second = connect_viewer(parent, identity, args.console_bridge); peers.append(second)
                remaining = Viewer(second, args.console_bridge); remaining.frame()
                first.close(); peers.remove(first)
                time.sleep(0.4)
                assert text_log().count(idle_message) == cycle, "capture stopped with another viewer connected"
                remaining.frame()
                second.close(); peers.remove(second)
                wait_idle(cycle + 1)
                assert text_log().count(capture_start) == cycle + 1
                print(f"PASS uid={uid} cycle={cycle + 1}: shared capture, remaining viewer live, last disconnect releases capture")

            # Disconnect during initialization, before ClientInit. This viewer
            # never registers a capture-rate consumer, but still owns a slot.
            failed = connect_viewer(parent, identity, args.console_bridge); peers.append(failed)
            assert read(failed, 4) == bytes(4)
            failed.close(); peers.remove(failed)
            wait_idle(args.cycles + 1)
            print("PASS failed handshake releases capture")
            if args.inspect_idle:
                match = re.search(r"Session worker attached: uid=\d+ audit=\d+ pid=(\d+)", text_log())
                assert match
                pid = match[1]
                subprocess.run(["top", "-l", "3", "-s", "1", "-pid", pid,
                                "-stats", "pid,command,cpu,mem,threads"], check=True, timeout=10)
                # A positive leak count is evidence to report, not a test failure.
                result = subprocess.run(["leaks", "-quiet", pid], timeout=30)
                assert result.returncode in (0, 1), f"leak scan failed: {result.returncode}"
            # Keep this final viewer alive while the listener channel closes.
            # Shutdown must wake its reader/writer and release capture itself.
            active = connect_viewer(parent, identity, args.console_bridge); peers.append(active)
            Viewer(active, args.console_bridge).frame()
        finally:
            parent.close()
            forced = False
            try:
                process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                forced = True
                # Terminate only this test's verified PID from its private log.
                text = text_log()
                match = re.search(r"Session worker attached: uid=\d+ audit=\d+ pid=(\d+)", text)
                if args.root and match:
                    subprocess.run(["sudo", "-n", "/bin/zsh", "-c", "kill -TERM " + match[1]], check=False, timeout=5)
                else:
                    process.terminate()
                process.wait(timeout=8)
            finally:
                for peer in peers: peer.close()
            text = text_log()
            print(text)
            # Closing the parent channel is an EOF, reported as a socket error
            # by account workers after capture and client cleanup have finished.
            expected_eof = process.returncode == 1 and capture_stop in text and any(
                message in text for message in ["session channel closed", "client socket closed", "client disconnected"])
            assert not forced, "worker failed to shut down with an active viewer"
            assert process.returncode == 0 or expected_eof, f"worker exited {process.returncode}"
            print("PASS parent-channel shutdown with a connected viewer")


if __name__ == "__main__":
    main()
