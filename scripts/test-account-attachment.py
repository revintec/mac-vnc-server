#!/usr/bin/env python3
"""Verify fresh worker attachment without capture, input, or account passwords.

Run normally for the current user. --root uses the caller-authorized sudo zsh
entry point to check fresh root-to-user and loginwindow attachment. It never
changes the physical session, opens capture services, or touches running servers.
"""
import argparse
import os
from pathlib import Path
import shlex
import socket
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = r'''
#include "CVNCSession.h"
#include <errno.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
int main(int argc, char **argv) {
    VNCConsoleIdentity identity = {0};
    if (argc == 3 && !strcmp(argv[1], "locate")) {
        int result = VNCSessionForUser((uint32_t)strtoul(argv[2], NULL, 10), &identity);
        if (result) { printf("UNAVAILABLE %d\n", result); return 2; }
        printf("%u:%d\n", identity.uid, identity.audit_id); return 0;
    }
    if (argc != 3 || sscanf(argv[2], "%u:%d", &identity.uid, &identity.audit_id) != 2) return 3;
    if (!strcmp(argv[1], "attach")) {
        int error = VNCSessionPrepare(identity);
        if (error) { printf("PREPARE_ERROR %d\n", error); return 4; }
        int result = VNCSessionExecWorker(argv[0], argv[2]);
        printf("EXEC_ERROR %d\n", result); return 5;
    }
    if (strcmp(argv[1], "--session-worker-attached")) return 6;
    int error = VNCSessionVerify(identity);
    struct sockaddr_un address = {0}; socklen_t length = sizeof(address);
    int inherited = !getsockname(0, (struct sockaddr *)&address, &length) && address.sun_family == AF_UNIX;
    printf("VERIFY uid=%u euid=%u audit=%d setugid=%d result=%d inherited=%d\n",
        getuid(), geteuid(), identity.audit_id, issetugid(), error, inherited);
    return error || !inherited ? 7 : 0;
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", action="store_true")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="vnc-account-attachment-") as directory:
        folder = Path(directory)
        source, executable = folder / "probe.c", folder / "probe"
        source.write_text(SOURCE)
        subprocess.run([
            "xcrun", "clang", str(source), str(ROOT / "Sources/CVNCSession/ConsoleSession.c"),
            "-I", str(ROOT / "Sources/CVNCSession/include"), "-framework", "CoreGraphics",
            "-framework", "IOSurface", "-framework", "CoreFoundation", "-lbsm", "-o", str(executable)
        ], check=True)
        identities = []
        for uid in dict.fromkeys([os.getuid()] + ([0] if args.root else [])):
            query = subprocess.run([str(executable), "locate", str(uid)], capture_output=True, text=True, timeout=10)
            if query.returncode:
                print(f"SKIP uid={uid}: no unambiguous current GUI session ({query.stdout.strip()})")
                continue
            identities.append((uid, query.stdout.strip()))
        assert identities, "no session available for attachment test"
        for uid, identity in identities:
            command = [str(executable), "attach", identity]
            if args.root:
                command = ["sudo", "-n", "/bin/zsh", "-c", "exec " + shlex.join(
                    ["/bin/launchctl", "asuser", str(uid)] + command)]
            parent, child = socket.socketpair()
            try:
                result = subprocess.run(command, stdin=child, capture_output=True, text=True, timeout=15)
                print(result.stdout.strip())
                assert result.returncode == 0, (result.returncode, result.stderr)
                assert f"uid={uid} euid={uid}" in result.stdout
                assert "setugid=0 result=0 inherited=1" in result.stdout
            finally:
                parent.close()
                child.close()


if __name__ == "__main__":
    main()
