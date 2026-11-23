#!/usr/bin/env python3
"""Opt-in loginwindow capture-service check using the real console identity.

Requires loginwindow to own the physical display and already-authorized sudo.
Rejects an intentionally misattached replayd, then exercises production audit
attachment, readiness, cleanup and immediate retry. --capture decodes frames
through disposable workers. No input, physical session switches, saved images,
public listener, or changes to existing servers/services are involved.
"""
import argparse
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = r'''
#include "CVNCSession.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (getuid() || geteuid()) return 2;
    if (argc == 4 && !strcmp(argv[1], "--console-capture-service")) {
        // Negative fixture: deliberately reproduce 1.7.3's background-audit
        // daemon. The production readiness check must reject this exact job.
        execl("/usr/libexec/replayd", "/usr/libexec/replayd", NULL);
        return 3;
    }
    if (argc == 5 && !strcmp(argv[1], "--console-capture-service-check"))
        return VNCConsoleCheckCaptureService((VNCConsoleIdentity){0, atoi(argv[2])}, atoi(argv[3]), argv[4]);
    if (argc != 3) return 2;
    VNCConsoleIdentity target = {0};
    if (VNCConsoleCurrent(&target) || target.uid != 0) {
        fprintf(stderr, "Loginwindow must own the console; this probe never switches sessions.\n");
        return 4;
    }
    int negative = !strcmp(argv[1], "bad-audit");
    int32_t error = 0;
    VNCConsoleCaptureServiceRef service = VNCConsoleCaptureServiceCreate(target, negative ? argv[0] : argv[2], &error);
    if (negative) {
        if (service) VNCConsoleCaptureServiceDestroy(service);
        if (service || error != ESTALE) {
            fprintf(stderr, "FAIL wrong-audit rejection: error=%d expected=%d\n", error, ESTALE);
            return 5;
        }
        puts("PASS wrong-audit replayd rejected and owned job cleaned up");
        return 0;
    }
    if (!service) { fprintf(stderr, "FAIL startup: %s (%d)\n", strerror(error), error); return 6; }
    printf("READY audit=%d\n", target.audit_id);
    fflush(stdout);
    // A private lifeline bounds ownership to the Python parent, including
    // exceptional paths. Closing stdin never affects the user's server.
    (void)getchar();
    VNCConsoleCaptureServiceDestroy(service);
    puts("PASS attached replayd startup and owned cleanup");
    return 0;
}
'''


def assert_no_jobs():
    assert not list(Path("/private/var/run").glob("mac-vnc-console.*")), "console service metadata remains"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--capture", action="store_true", help="verify real frames using private root workers")
    parser.add_argument("--startup-failure", action="store_true", help="verify forwarded capture errors and fresh worker retry")
    args = parser.parse_args()
    executable = args.binary.resolve(strict=True)
    subprocess.run(["sudo", "-n", "/usr/bin/true"], check=True)
    if list(Path("/private/var/run").glob("mac-vnc-console.*")):
        raise SystemExit("SKIP: existing console capture metadata; leave the owning service alone")
    with tempfile.TemporaryDirectory(prefix="vnc-capture-service-") as directory:
        folder = Path(directory)
        source, controller = folder / "probe.c", folder / "probe"
        source.write_text(SOURCE)
        subprocess.run(["xcrun", "clang", str(source), str(ROOT / "Sources/CVNCSession/ConsoleCaptureService.m"),
                        str(ROOT / "Sources/CVNCSession/ConsoleSession.c"),
                        "-I", str(ROOT / "Sources/CVNCSession/include"), "-framework", "Foundation",
                        "-framework", "ServiceManagement", "-framework", "CoreGraphics",
                        "-framework", "IOKit", "-framework", "SystemConfiguration", "-lbsm",
                        "-o", str(controller)], check=True)
        # Negative case runs production lifecycle + readiness against a fixture
        # that intentionally omits audit attachment. Never replace another job.
        subprocess.run(["sudo", "-n", str(controller), "bad-audit", str(executable)],
                       check=True, timeout=45, env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"})
        assert_no_jobs()
        for attempt in range(1, 3):
            process = subprocess.Popen(["sudo", "-n", str(controller), "attached", str(executable)],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"})
            try:
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdout, selectors.EVENT_READ)
                    assert selector.select(30), "service controller did not become ready"
                ready = process.stdout.readline().decode().strip()
                assert ready.startswith("READY audit="), ready
                print(ready, flush=True)
                if args.startup_failure:
                    subprocess.run([sys.executable, str(ROOT / "scripts/test-console-startup.py"),
                                    str(executable), "--root"], check=True, timeout=90)
                if args.capture:
                    subprocess.run([sys.executable, str(ROOT / "scripts/test-session-capture.py"),
                                    str(executable), "--root"], check=True, timeout=90)
            finally:
                process.stdin.close()
                process.wait(timeout=25)
                print(process.stdout.read().decode(), end="", flush=True)
                process.stdout.close()
            assert process.returncode == 0, f"service controller exited {process.returncode}"
            assert_no_jobs()
            print(f"PASS attempt={attempt}: actual loginwindow audit, readiness, immediate retry and cleanup", flush=True)


if __name__ == "__main__":
    main()
