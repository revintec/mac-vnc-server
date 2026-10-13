#!/usr/bin/env python3
"""Exercise the production exec bridge in a disposable process (no capture/input).

No root is needed. Checks PID/audit/UID/GID and anonymous stdin IPC survive exec,
including a path with spaces and FD_CLOEXEC initially set on stdin. Root credential
changes and console capture still require the real administrator-run endpoint test.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = r'''#include "CVNCSession.h"
#include <bsm/audit.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 3) return 1;
    auditinfo_addr_t audit = {0};
    if (getaudit_addr(&audit, sizeof(audit))) return 2;
    if (!strcmp(argv[1], "--launch")) {
        dprintf(STDIN_FILENO, "{\"pid\":%d,\"uid\":%u,\"gid\":%u,\"audit\":%d}\n",
                getpid(), getuid(), getgid(), audit.ai_asid);
        if (fcntl(STDIN_FILENO, F_SETFD, FD_CLOEXEC)) return 3;
        int error = VNCConsoleExecWorker(argv[0], argv[2]);
        fprintf(stderr, "exec failed: %s\n", strerror(error));
        return 4;
    }
    if (strcmp(argv[1], "--console-worker-attached") || issetugid()) return 5;
    // Read a parent challenge and echo it after exec on the inherited socket.
    char challenge[4];
    if (read(STDIN_FILENO, challenge, 4) != 4 || memcmp(challenge, "test", 4)) return 6;
    dprintf(STDIN_FILENO, "{\"pid\":%d,\"uid\":%u,\"gid\":%u,\"audit\":%d,"
            "\"setugid\":%d,\"options\":%s}\n",
            getpid(), getuid(), getgid(), audit.ai_asid, issetugid(), argv[2]);
    return 0;
}
'''


def main():
    with tempfile.TemporaryDirectory(prefix="console exec test ") as folder:
        source = Path(folder) / "worker.c"
        binary = Path(folder) / "test worker"
        source.write_text(SOURCE)
        subprocess.run(["xcrun", "clang", str(source),
                        str(ROOT / "Sources/CVNCSession/ConsoleSession.c"),
                        "-I", str(ROOT / "Sources/CVNCSession/include"),
                        "-framework", "CoreGraphics", "-framework", "CoreFoundation",
                        "-o", str(binary)], check=True)
        options = {"identity": {"uid": 501, "auditID": 123}, "label": "spaces and \"quotes\""}
        parent, child = socket.socketpair()
        with parent, child:
            process = subprocess.Popen([str(binary), "--launch", json.dumps(options)],
                                       stdin=child, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"})
            child.close()
            try:
                parent.settimeout(5)
                parent.sendall(b"test")
                data = bytearray()
                while data.count(b"\n") < 2:
                    part = parent.recv(4096)
                    if not part:
                        raise RuntimeError("worker exited without reply")
                    data.extend(part)
                output, error = process.communicate(timeout=5)
                assert process.returncode == 0, error.decode()
                before, result = map(json.loads, data.splitlines())
                assert all(before[field] == result[field] for field in ("pid", "uid", "gid", "audit"))
                assert result["pid"] == process.pid
                assert result["uid"] == os.getuid() and result["gid"] == os.getgid()
                assert result["setugid"] == 0 and result["options"] == options
                print("PASS: production exec preserves PID, UID/GID, audit, options and bidirectional stdin socket")
                print(f"Attached process: audit={result['audit']} setugid={result['setugid']}")
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()


if __name__ == "__main__":
    main()
