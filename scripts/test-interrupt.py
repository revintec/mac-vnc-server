#!/usr/bin/env python3
"""Send real signals to the production shutdown controller in disposable processes.

The fixture installs from MainActor, reproducing the original handler-isolation
bug. It also owns a sleep child to check forced exits leave no worker behind.
No capture, input injection, credentials or existing server is involved.
"""
import os
from pathlib import Path
import select
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = r'''
import Darwin
import Foundation
@main struct Fixture {
    @MainActor static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let shutdown = ProcessShutdown.shared
        shutdown.installSignalHandlers()
        let mode = CommandLine.arguments[1]
        if mode.hasSuffix("stalled") {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sleep")
            child.arguments = ["60"]
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try! child.run()
            _ = shutdown.register(child)
            print("CHILD \(child.processIdentifier)")
        }
        if mode != "startup" {
            let runner = Task.detached {
                if mode == "stalled" { while true { Darwin.sleep(60) } }
                if mode == "handler-stalled" {
                    await withTaskCancellationHandler {
                        try? await Task.sleep(for: .seconds(60))
                        while true { Darwin.sleep(60) }
                    } onCancel: { Darwin.sleep(60) }
                }
                do { try await Task.sleep(for: .seconds(60)) }
                catch { Darwin.exit(0) }
                Darwin.exit(2)
            }
            shutdown.attach(runner)
        }
        print("READY")
        dispatchMain()
    }
}
'''


def check(binary, mode, signals, expected, maximum):
    process = subprocess.Popen([str(binary), mode], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    child = None
    try:
        # Read bytewise so Python's buffering cannot hide the READY line from select.
        pending = b""
        deadline = time.monotonic() + 5
        while True:
            assert time.monotonic() < deadline, "fixture startup timed out"
            if not select.select([process.stdout], [], [], 0.1)[0]:
                continue
            data = os.read(process.stdout.fileno(), 1)
            assert data, process.stderr.read().decode()
            pending += data
            if not pending.endswith(b"\n"):
                continue
            if pending.startswith(b"CHILD "):
                child = int(pending.split()[1])
            if pending == b"READY\n":
                break
            pending = b""
        started = time.monotonic()
        for index, number in enumerate(signals):
            if index:
                time.sleep(0.15)
                assert process.poll() is None, "exited before repeated interrupt"
            process.send_signal(number)
        _, errors = process.communicate(timeout=maximum)
        elapsed = time.monotonic() - started
        assert process.returncode == expected, (process.returncode, errors.decode())
        assert b"data race detected" not in errors and b"MainActor" not in errors, errors.decode()
        if mode == "stalled" and len(signals) == 1:
            assert elapsed >= 4.5, "did not allow graceful cleanup deadline"
        assert elapsed < maximum, elapsed
        if child:
            reap_deadline = time.monotonic() + 2
            while time.monotonic() < reap_deadline:
                try:
                    os.kill(child, 0)
                except ProcessLookupError:
                    child = None
                    break
                time.sleep(0.02)
            assert child is None, "owned child survived forced exit"
        print(f"PASS {mode} {[signal.Signals(n).name for n in signals]}: exit={expected} elapsed={elapsed:.2f}s")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        if child:
            try:
                os.kill(child, signal.SIGKILL)
            except ProcessLookupError:
                pass


def main():
    with tempfile.TemporaryDirectory(prefix="mac-vnc-interrupt-") as folder:
        fixture = Path(folder) / "Fixture.swift"
        binary = Path(folder) / "fixture"
        fixture.write_text(FIXTURE)
        subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                        str(ROOT / "Sources/mac-vnc-server/ProcessShutdown.swift"),
                        str(fixture), "-o", str(binary)], check=True)
        check(binary, "graceful", [signal.SIGINT], 0, 2)
        check(binary, "graceful", [signal.SIGTERM], 0, 2)
        check(binary, "startup", [signal.SIGINT], 130, 2)
        check(binary, "stalled", [signal.SIGINT], 130, 7)
        check(binary, "stalled", [signal.SIGINT, signal.SIGINT], 130, 2)
        check(binary, "stalled", [signal.SIGTERM, signal.SIGINT, signal.SIGINT], 130, 2)
        check(binary, "handler-stalled", [signal.SIGINT, signal.SIGINT], 130, 2)


if __name__ == "__main__":
    main()
