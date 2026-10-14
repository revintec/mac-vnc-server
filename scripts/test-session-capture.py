#!/usr/bin/env python3
"""Opt-in capture/RichCursor check of an attached worker, without input or a VNC listener.

Account authentication is outside this test: a private socketpair supplies a
fixture admission after session attachment. --root requires loginwindow and an
already-running root capture service. No services or existing servers are
restarted, no passwords are used, and no screenshot is saved. The temporary
worker exits when its private parent channel closes.
"""
import argparse
import array
import json
import os
from pathlib import Path
import re
import shlex
import socket
import struct
import subprocess
import tempfile
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--root", action="store_true")
    args = parser.parse_args()
    uid = 0 if args.root else os.getuid()
    with tempfile.TemporaryDirectory(prefix="vnc-session-capture-") as directory, tempfile.TemporaryFile() as log:
        folder = Path(directory)
        source = folder / "locate.c"
        source.write_text(LOCATOR)
        locator = folder / "locate"
        subprocess.run(["xcrun", "clang", str(source), str(ROOT / "Sources/CVNCSession/ConsoleSession.c"),
            "-I", str(ROOT / "Sources/CVNCSession/include"), "-framework", "CoreGraphics",
            "-framework", "CoreFoundation", "-lbsm", "-o", str(locator)], check=True)
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
        worker_peer = viewer = None
        process = subprocess.Popen(command, stdin=child, stdout=log, stderr=log,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"})
        child.close()
        try:
            assert read(parent, 1) == b"R"
            # The RFB engine configures TCP_NODELAY. Form one local TCP
            # pair, then close its reservation listener before admission.
            with socket.socket() as reservation:
                reservation.bind(("127.0.0.1", 0)); reservation.listen(1)
                viewer = socket.create_connection(reservation.getsockname(), timeout=5)
                worker_peer, _ = reservation.accept()
            viewer.settimeout(10)
            admission = dict(identity=identity, version="RFB 003.008\n", wrappingKey=[17] * 16)
            metadata = json.dumps(admission).encode()
            parent.sendmsg([b"F"], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [worker_peer.fileno()]))])
            parent.sendall(struct.pack(">I", len(metadata)) + metadata)
            worker_peer.close(); worker_peer = None
            assert read(viewer, 4) == bytes(4)
            viewer.sendall(b"\1")
            initial = read(viewer, 24)
            width, height = struct.unpack_from(">HH", initial)
            read(viewer, struct.unpack_from(">I", initial, 20)[0])
            viewer.sendall(struct.pack(">BBHii", 2, 0, 2, 6, -239))
            viewer.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, width, height))
            update = read(viewer, 4)
            assert update[0] == 0
            decoder = zlib.decompressobj()
            total = 0; cursor = None; varied = False
            for _ in range(struct.unpack_from(">H", update, 2)[0]):
                x, y, w, h, encoding = struct.unpack(">HHHHi", read(viewer, 12))
                if encoding == -239:
                    assert w > 0 and h > 0 and x < w and y < h
                    payload = read(viewer, w * h * 4 + ((w + 7) // 8) * h)
                    assert any(payload[w * h * 4:])
                    cursor = (w, h)
                elif encoding == 6:
                    length = struct.unpack(">I", read(viewer, 4))[0]
                    assert length <= 256 * 1024 * 1024
                    pixels = decoder.decompress(read(viewer, length))
                    assert len(pixels) == w * h * 4
                    varied |= len(set(pixels)) > 1
                    total += len(pixels)
                else:
                    raise AssertionError(f"unexpected encoding {encoding}")
            assert total == width * height * 4 and varied and cursor
            print(f"PASS uid={uid} account worker: frame={width}x{height} RichCursor={cursor} zlib_bytes_decoded={total} plaintext_frames=yes")
        finally:
            parent.close()
            if viewer: viewer.close()
            if worker_peer: worker_peer.close()
            try:
                process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                # Terminate only this test's verified PID from its private log.
                text = os.pread(log.fileno(), 1024 * 1024, 0).decode(errors="replace")
                match = re.search(r"Session worker attached: uid=\d+ audit=\d+ pid=(\d+)", text)
                if args.root and match:
                    subprocess.run(["sudo", "-n", "/bin/zsh", "-c", "kill -TERM " + match[1]], check=False, timeout=5)
                else:
                    process.terminate()
                process.wait(timeout=8)
            text = os.pread(log.fileno(), 1024 * 1024, 0).decode(errors="replace")
            print(text)
            # Closing the parent channel is an EOF, reported as a socket error
            # by account workers after capture and client cleanup have finished.
            expected_eof = process.returncode == 1 and "ScreenCaptureKit: capture stopped" in text and any(
                message in text for message in ["session channel closed", "client socket closed", "client disconnected"])
            assert process.returncode == 0 or expected_eof, f"worker exited {process.returncode}"


if __name__ == "__main__":
    main()
