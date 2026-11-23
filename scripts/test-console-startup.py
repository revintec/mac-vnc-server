#!/usr/bin/env python3
"""Verify private console startup failures using a disposable account worker.

Run while the current account owns the physical console, or use --root with
loginwindow and an already-running owned capture service. An invalid display
selection forces an error after ScreenCaptureKit enumeration, before capture
starts. No input, passwords, session switches or existing servers are involved.
"""
import argparse
import array
import json
import os
from pathlib import Path
import runpy
import re
import shlex
import socket
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
helpers = runpy.run_path(str(ROOT / "scripts/test-session-capture.py"))
read = helpers["read"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--root", action="store_true")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="vnc-startup-error-") as temporary:
        folder = Path(temporary)
        source, locator = folder / "locate.c", folder / "locate"
        source.write_text(helpers["LOCATOR"])
        subprocess.run(["xcrun", "clang", str(source), str(ROOT / "Sources/CVNCSession/ConsoleSession.c"),
                        "-I", str(ROOT / "Sources/CVNCSession/include"), "-framework", "CoreGraphics",
                        "-framework", "CoreFoundation", "-framework", "IOKit", "-framework", "SystemConfiguration",
                        "-lbsm", "-o", str(locator)], check=True)
        identity = json.loads(subprocess.check_output([str(locator), str(0 if args.root else os.getuid())], text=True, timeout=5))
        config = dict(bindAddress="127.0.0.1", port=0, fps=30, scale=1, encodingPreference="zlib",
                      displaySelection={"display": {"_0": 65535}}, verbose=True,
                      clipboardSync=False, fileTransfer=False, adaptiveStreaming=True, adaptiveFrameRate=True,
                      cursorMode="auto", allowEncryption=False, zlibConfiguration={"backend": "zlib-ng"},
                      transferOptions={"root": folder.as_uri(), "maximumBytes": 1, "minimumFreeBytes": 0},
                      transferDirectoryIsExplicit=False)
        # A retry launches a fresh worker after retiring the failed target.
        for attempt in range(2):
            with tempfile.TemporaryFile() as log:
                parent, child = socket.socketpair()
                parent.settimeout(15)
                viewer, target = socket.socketpair()
                viewer.settimeout(20)
                command = [str(args.binary.resolve()), "--session-worker", json.dumps(dict(identity=identity, config=config))]
                if args.root:
                    command = ["sudo", "-n", "/bin/zsh", "-c", "exec " + shlex.join(["/bin/launchctl", "asuser", "0"] + command)]
                worker = subprocess.Popen(command, stdin=child, stdout=log, stderr=log,
                    env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"})
                child.close()
                try:
                    assert read(parent, 1) == b"R"
                    metadata = json.dumps(dict(identity=identity, version="RFB 003.008\n",
                        wrappingKey=[0] * 16, consoleBridge=True)).encode()
                    parent.sendmsg([b"F"], [(socket.SOL_SOCKET, socket.SCM_RIGHTS,
                        array.array("i", [target.fileno()]))])
                    target.close()
                    parent.sendall(struct.pack(">I", len(metadata)) + metadata)
                    assert read(viewer, 4) == struct.pack(">I", 1), "missing startup failure status"
                    length = struct.unpack(">I", read(viewer, 4))[0]
                    assert 0 < length <= 4096
                    reason = read(viewer, length).decode()
                    assert "display 65535 is not available" in reason, reason
                    assert viewer.recv(1) == b"", "failed private connection remained open"
                    worker.wait(timeout=8)
                    assert worker.returncode == 1
                    text = os.pread(log.fileno(), 1024 * 1024, 0).decode(errors="replace")
                    assert "Console desktop startup failed:" in text, text
                    assert "ScreenCaptureKit: starting display" not in text, text
                    print(f"PASS uid={identity['uid']} attempt={attempt + 1}: precise startup error before EOF; target retired; no capture started")
                finally:
                    viewer.close(); target.close(); parent.close()
                    if worker.poll() is None:
                        try:
                            worker.wait(timeout=8)
                        except subprocess.TimeoutExpired:
                            if args.root:
                                text = os.pread(log.fileno(), 1024 * 1024, 0).decode(errors="replace")
                                match = re.search(r"Session worker attached: uid=0 audit=\d+ pid=(\d+)", text)
                                if not match: raise
                                subprocess.run(["sudo", "-n", "/bin/kill", "-TERM", match[1]], check=True, timeout=5)
                            else:
                                worker.terminate()
                            worker.wait(timeout=8)


if __name__ == "__main__":
    main()
