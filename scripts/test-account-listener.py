#!/usr/bin/env python3
"""Smoke-test a built listener without submitting credentials or starting capture."""
import argparse
import os
from pathlib import Path
import re
import shlex
import signal
import socket
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--root", action="store_true")
    args = parser.parse_args()
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    command = [str(args.binary.resolve()), "--bind", "127.0.0.1", "--port", str(port),
               "--no-file-transfer", "--no-clipboard-sync"]
    if args.root:
        command = ["sudo", "-n", "/bin/zsh", "-c", "exec " + shlex.join(command)]
    environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
    # The normal-user check supplies a dummy value; root uses sudo's filtered
    # environment. Both must request account authentication, never classic VNC.
    if not args.root:
        environment["VNC_PASSWORD"] = "must-not-select-shared-password-auth"
    with tempfile.TemporaryFile() as output:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=output,
                                   stderr=output, env=environment)
        listener_pid = None
        peer = None
        try:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                assert process.poll() is None, "listener exited before accepting"
                try:
                    peer = socket.create_connection(("127.0.0.1", port), timeout=1)
                    break
                except OSError:
                    time.sleep(0.05)
            assert peer is not None, "listener did not start"
            peer.settimeout(3)

            def read(count):
                data = b""
                while len(data) < count:
                    part = peer.recv(count - len(data))
                    assert part, "unexpected EOF"
                    data += part
                return data

            assert read(12) == b"RFB 003.889\n"
            peer.sendall(b"RFB 003.889\n")
            assert read(2) == b"\x01\x1e", "listener did not request username/password"
            peer.sendall(b"\x1e")
            assert read(516)[:4] == b"\x00\x02\x01\x00", "invalid ARD challenge"
            output.seek(0)
            log = output.read().decode()
            match = re.search(r"account listener pid=(\d+) uid=(\d+)", log)
            assert match, log
            listener_pid, uid = map(int, match.groups())
            assert uid == (0 if args.root else os.getuid())
            if uid == 0:
                assert "Account listener privileges: root" in log, log
                assert "running without root" not in log, log
            else:
                assert f"running without root (uid={uid})" in log, log
                assert "only its own existing user session" in log, log
                assert "require starting the listener with sudo" in log, log
            assert "Session worker ready" not in log and "ScreenCaptureKit" not in log
            started = time.monotonic()
            if args.root:
                subprocess.run(["sudo", "-n", "/bin/zsh", "-c", f"kill -INT {listener_pid}"], check=True)
            else:
                process.send_signal(signal.SIGINT)
            process.wait(timeout=5)
            assert process.returncode == 0, process.returncode
            assert peer.recv(1) == b"", "pending authentication socket survived shutdown"
            print(f"PASS uid={uid}: startup privilege report, type-30 challenge, no worker/capture before authentication, Ctrl-C in {time.monotonic()-started:.2f}s")
        finally:
            if peer:
                peer.close()
            if process.poll() is None:
                if args.root and listener_pid:
                    subprocess.run(["sudo", "-n", "/bin/zsh", "-c", f"kill -KILL {listener_pid}"], check=False)
                process.kill()
                process.wait()


if __name__ == "__main__":
    main()
