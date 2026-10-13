#!/usr/bin/env python3
"""Opt-in root loginwindow capture/cleanup test. Never injects input.

Run through an administrator shell while the physical console is at loginwindow.
Starts loopback-only VNC instances using a fixed test credential in VNC_PASSWORD,
decodes full frames, then checks graceful shutdown, SIGKILL cleanup and dead
manager recovery. Malformed metadata and unrelated services must survive. The
existing user endpoint is untouched. No screenshot data is saved.
"""
import argparse
from contextlib import contextmanager
import ctypes
import os
from pathlib import Path
import plistlib
import re
import signal
import socket
import struct
import subprocess
import tempfile
import time
import zlib
import uuid


def read(sock, size):
    data = bytearray()
    while len(data) < size:
        block = sock.recv(size - len(data))
        if not block:
            raise RuntimeError("VNC connection closed")
        data.extend(block)
    return bytes(data)


def receive_frame(port):
    with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
        sock.settimeout(5)
        assert read(sock, 12) == b"RFB 003.003\n"
        sock.sendall(b"RFB 003.003\n")
        assert read(sock, 4) == struct.pack(">I", 2)
        challenge = read(sock, 16)
        key = bytes(int(f"{v:08b}"[::-1], 2) for v in b"console-probe-fixture"[:8])
        crypto = ctypes.CDLL("/usr/lib/system/libcommonCrypto.dylib")
        crypto.CCCrypt.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32,
            ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_void_p,
            ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
        encrypted = ctypes.create_string_buffer(16)
        written = ctypes.c_size_t()
        assert crypto.CCCrypt(0, 1, 2, key, 8, None, challenge, 16,
                              encrypted, 16, ctypes.byref(written)) == 0
        sock.sendall(encrypted.raw)
        assert read(sock, 4) == b"\0" * 4
        sock.sendall(b"\1")
        initial = read(sock, 24)
        width, height = struct.unpack_from(">HH", initial)
        name = read(sock, struct.unpack_from(">I", initial, 20)[0]).decode()
        sock.sendall(b"\0" * 4 + struct.pack(">BBBBHHHBBB3x", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0))
        sock.sendall(struct.pack(">BBHi", 2, 0, 1, 6))
        sock.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, width, height))
        header = read(sock, 4)
        assert header[0] == 0
        decoder = zlib.decompressobj()
        decoded, varied = 0, False
        for _ in range(struct.unpack_from(">H", header, 2)[0]):
            x, y, w, h, encoding = struct.unpack(">HHHHi", read(sock, 12))
            assert encoding == 6 and x + w <= width and y + h <= height
            length = struct.unpack(">I", read(sock, 4))[0]
            assert length <= 256 * 1024 * 1024
            pixels = decoder.decompress(read(sock, length))
            assert len(pixels) == w * h * 4
            decoded += len(pixels)
            varied |= len(set(pixels)) > 1
        assert decoded == width * height * 4 and varied
        return {"desktop": name, "frame": [width, height], "decoded_bytes": decoded}


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def check_broker_conflict(binary, audit, expected="root capture service is already owned"):
    """A second root broker must not replace the first broker's Mach services."""
    parent, child = socket.socketpair()
    with tempfile.TemporaryFile(mode="w+b") as log:
        duplicate = subprocess.Popen(["/bin/launchctl", "asuser", "0", str(binary), "--console-capture-broker", audit],
            stdin=child, stdout=log, stderr=log, env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"})
        child.close()
        try:
            parent.settimeout(6)
            ready = parent.recv(1)
            assert ready == b"", "duplicate broker claimed root capture services"
            assert duplicate.wait(timeout=10) != 0
            text = os.pread(log.fileno(), 1024 * 1024, 0).decode(errors="replace")
            assert expected in text, text
            print("Existing root capture broker preserved; duplicate rejected", flush=True)
        finally:
            parent.close()
            if duplicate.poll() is None:
                duplicate.wait(timeout=12)


def check(binary, stop_signal, manager_signal=None):
    with socket.socket() as reserve:
        reserve.bind(("127.0.0.1", 0))
        port = reserve.getsockname()[1]
    baseline = set(Path("/private/var/run").glob("mac-vnc-console.*"))
    with tempfile.TemporaryFile(mode="w+b") as log:
        env = dict(os.environ, VNC_PASSWORD="console-probe-fixture")
        server = subprocess.Popen([str(binary), "--session", "console", "--bind", "127.0.0.1",
            "--port", str(port), "--display", "all", "--verbose"], env=env, stdout=log, stderr=log)
        owned_dirs, owned_pids = set(), set()
        text = ""
        result = None

        def collect():
            nonlocal text
            text = os.pread(log.fileno(), 16 * 1024 * 1024, 0).decode(errors="replace")
            owned_dirs.update(set(Path("/private/var/run").glob("mac-vnc-console.*")) - baseline)
            owned_pids.update(map(int, re.findall(r"Console capture broker ready: .*?manager=(\d+)", text)))
            owned_pids.update(map(int, re.findall(r"Console worker started: .*?pid=(\d+)", text)))

        try:
            deadline = time.monotonic() + 25
            while time.monotonic() < deadline:
                text = os.pread(log.fileno(), 16 * 1024 * 1024, 0).decode(errors="replace")
                if server.poll() is not None:
                    raise RuntimeError(f"server exited {server.returncode}\n{text}")
                if "mac-vnc-server listening on" in text:
                    break
                time.sleep(.05)
            else:
                raise RuntimeError(f"console startup timed out\n{text}")
            assert "Console worker ready: uid=0" in text, text
            owned_dirs = set(Path("/private/var/run").glob("mac-vnc-console.*")) - baseline
            assert len(owned_dirs) == 1
            collect()
            if stop_signal == signal.SIGINT:
                audit = re.search(r"Console capture broker ready: uid=0 audit=(\d+)", text).group(1)
                check_broker_conflict(binary, audit)
                assert set(Path("/private/var/run").glob("mac-vnc-console.*")) - baseline == owned_dirs
            result = receive_frame(port)
            if manager_signal is not None:
                manager = int(re.search(r"Console capture broker ready: .*?manager=(\d+)", text).group(1))
                old_dirs, old_pids = set(owned_dirs), set(owned_pids)
                os.kill(manager, manager_signal)
                deadline = time.monotonic() + 25
                while time.monotonic() < deadline:
                    collect()
                    assert server.poll() is None, text
                    if text.count("Console worker ready: uid=0") >= 2:
                        break
                    time.sleep(.05)
                else:
                    raise RuntimeError(f"manager exit did not recover\n{text}")
                assert not any(p.exists() for p in old_dirs), text
                assert not any(alive(p) for p in old_pids), text
                if manager_signal == signal.SIGKILL:
                    assert "console capture broker exited; restarting capture worker" in text, text
                    assert "Console capture broker recovered orphan:" in text, text
                else:
                    assert "Console capture broker stopped:" in text, text
                result = receive_frame(port)
        finally:
            collect()
            if server.poll() is None:
                server.send_signal(stop_signal)
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait(timeout=5)
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if not any(p.exists() for p in owned_dirs) and not any(alive(p) for p in owned_pids):
                    break
                time.sleep(.1)
            text = os.pread(log.fileno(), 16 * 1024 * 1024, 0).decode(errors="replace")
            print(text, flush=True)
            assert not any(p.exists() for p in owned_dirs), "broker temporary directory survived"
            assert not any(alive(p) for p in owned_pids), "owned helper survived"
            for directory in owned_dirs:
                target = "user/0/com.mac-vnc-server.console-capture." + directory.name
                checked = subprocess.run(["/bin/launchctl", "print", target], capture_output=True)
                assert checked.returncode != 0, "owned launchd job survived"
        assert server.returncode == (0 if stop_signal == signal.SIGINT else -signal.SIGKILL), server.returncode
        print({"signal": signal.Signals(stop_signal).name, "uri": f"vnc://127.0.0.1:{port}/",
               "capture": result, "broker_cleanup": "passed",
               "manager_recovery": signal.Signals(manager_signal).name if manager_signal else "not requested"}, flush=True)
        return re.search(r"Console capture broker ready: uid=0 audit=(\d+)", text).group(1)


@contextmanager
def protected_metadata(binary):
    """Recovery must leave live owners and unverified/symlinked records alone."""
    with tempfile.TemporaryDirectory(prefix="mac-vnc-metadata-test-", dir="/private/var/run") as folder:
        external = Path(folder) / "external.plist"
        external.write_bytes(b"unrelated data")
        fixtures = []
        try:
            for kind in ["live", "label", "mode", "symlink", "directory-symlink"]:
                root = Path("/private/var/run/mac-vnc-console." + uuid.uuid4().hex[:6])
                fixtures.append(root)
                if kind == "directory-symlink":
                    root.symlink_to(folder, target_is_directory=True)
                    continue
                root.mkdir(mode=0o700)
                path = root / "capture.plist"
                job = {"Label": "com.mac-vnc-server.console-capture." + root.name,
                    "ProgramArguments": [str(binary), "--console-capture-service", "100795",
                        str(os.getpid()) if kind == "live" else "2147483647"],
                    "RunAtLoad": True, "LimitLoadToSessionType": ["Background"], "ProcessType": "Interactive",
                    "MachServices": {"com.apple.replayd": True, "com.apple.replayd-cache-delete": True,
                        "com.apple.replaykit.sharingsession": True}}
                if kind == "label":
                    job["Label"] = "com.apple.unrelated-fixture"
                if kind == "symlink":
                    path.symlink_to(external)
                else:
                    path.write_bytes(plistlib.dumps(job))
                    path.chmod(0o644 if kind == "mode" else 0o600)
            yield
            assert all(p.exists() for p in fixtures), "unverified/live metadata was removed"
            assert all((p / "capture.plist").exists() for p in fixtures if not p.is_symlink())
            assert external.read_bytes() == b"unrelated data", "symlink target was modified"
            print("Live-manager, mismatched-label, wrong-mode and symlink metadata preserved", flush=True)
        finally:
            for root in fixtures:
                if root.is_symlink():
                    root.unlink()
                elif root.exists():
                    (root / "capture.plist").unlink(missing_ok=True)
                    root.rmdir()


def check_foreign_service(binary, audit):
    """An already registered root replayd service must also be preserved."""
    label = "com.mac-vnc-server.root-service-fixture." + uuid.uuid4().hex
    target = "user/0/" + label
    with tempfile.TemporaryDirectory(prefix="mac-vnc-service-test-", dir="/private/var/run") as folder:
        path = Path(folder) / "service.plist"
        path.write_bytes(plistlib.dumps({"Label": label, "ProgramArguments": ["/bin/sleep", "30"],
            "LimitLoadToSessionType": ["Background"], "MachServices": {"com.apple.replayd": True}}))
        try:
            subprocess.run(["/bin/launchctl", "bootstrap", "user/0", str(path)], check=True, timeout=5)
            check_broker_conflict(binary, audit, "an existing root capture service is not replaced")
            subprocess.run(["/bin/launchctl", "print", target], check=True, capture_output=True, timeout=5)
        finally:
            subprocess.run(["/bin/launchctl", "bootout", target], check=True, capture_output=True, timeout=5)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    options = parser.parse_args()
    if os.geteuid() != 0:
        parser.error("requires root; tests need the physical console to be at loginwindow")
    binary = options.binary.resolve()
    with protected_metadata(binary):
        audit = check(binary, signal.SIGINT)
    check(binary, signal.SIGKILL)
    check(binary, signal.SIGINT, manager_signal=signal.SIGKILL)
    check(binary, signal.SIGINT, manager_signal=signal.SIGHUP)
    check_foreign_service(binary, audit)
