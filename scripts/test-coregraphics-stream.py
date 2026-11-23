#!/usr/bin/env python3
"""Opt-in live check of the public CGDisplayStream wrapper in the current desktop.

Captures small frames without saving images or sending input. Verifies native
start/stop and callback-context cleanup. Does not change sessions, start replayd
jobs, or establish loginwindow support on a different macOS release.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = r'''
#include "VNCDisplayStream.h"
#include "CVNCSession.h"
#include <CoreGraphics/CoreGraphics.h>
#include <CoreVideo/CoreVideo.h>
#include <IOSurface/IOSurface.h>
#include <dispatch/dispatch.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static dispatch_semaphore_t frameReady, contextFreed;
static atomic_int frames, releases, invalid;
static atomic_int sampledRGB;
static VNCConsoleIdentity rootIdentity;
static void frame(void *context, int32_t status, double seconds, IOSurfaceRef surface) {
    if (status != VNCDisplayFrameComplete) return;
    if (!surface || IOSurfaceGetWidth(surface) != 160 || IOSurfaceGetHeight(surface) != 100 ||
        IOSurfaceGetPixelFormat(surface) != kCVPixelFormatType_32BGRA) atomic_store(&invalid, 1);
    if (rootIdentity.audit_id && VNCConsoleVerify(rootIdentity)) atomic_store(&invalid, 1);
    if (surface && !IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL)) {
        const unsigned char *bytes = IOSurfaceGetBaseAddress(surface);
        size_t width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface), stride = IOSurfaceGetBytesPerRow(surface);
        int lit = 0;
        for (int y=0; y<8; y++) for (int x=0; x<8; x++) {
            size_t offset = (y*(height-1)/7)*stride+(x*(width-1)/7)*4;
            if (bytes[offset] || bytes[offset+1] || bytes[offset+2]) lit++;
        }
        atomic_store(&sampledRGB,lit);
        IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    }
    if (atomic_fetch_add(&frames, 1) == 0) dispatch_semaphore_signal(frameReady);
}
static void released(void *context) {
    free(context);
    atomic_fetch_add(&releases, 1);
    dispatch_semaphore_signal(contextFreed);
}
int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--root")) {
        if (getuid() || VNCConsoleCurrent(&rootIdentity) || rootIdentity.uid) return 4;
        int error = VNCConsolePrepare(rootIdentity);
        if (error) { fprintf(stderr,"attach error=%d\n",error); return 5; }
        char audit[32]; snprintf(audit,sizeof(audit),"%d",rootIdentity.audit_id);
        execl(argv[0],argv[0],"--root-attached",audit,NULL);
        return 6;
    }
    if (argc == 3 && !strcmp(argv[1], "--root-attached")) {
        rootIdentity = (VNCConsoleIdentity){0,atoi(argv[2])};
        if (VNCConsoleVerify(rootIdentity)) return 7;
        printf("verified loginwindow uid=0 audit=%d\n",rootIdentity.audit_id);
    }
    frameReady = dispatch_semaphore_create(0);
    contextFreed = dispatch_semaphore_create(0);
    for (int attempt = 1; attempt <= 2; attempt++) {
        atomic_store(&frames, 0);
        int32_t error = 0;
        VNCDisplayStreamRef stream = VNCDisplayStreamCreate(CGMainDisplayID(), 160, 100, 10, attempt == 2,
            frame, malloc(1), released, &error);
        if (!stream) { fprintf(stderr, "FAIL create code=%d\n", error); return 2; }
        int timedout = dispatch_semaphore_wait(frameReady, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        int stop = VNCDisplayStreamDestroy(stream);
        int leak = dispatch_semaphore_wait(contextFreed, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
        if (timedout || stop || leak || atomic_load(&invalid) || atomic_load(&releases) != attempt) {
            fprintf(stderr, "FAIL frame_timeout=%d stop=%d release_timeout=%d invalid=%d releases=%d\n",
                timedout, stop, leak, atomic_load(&invalid), atomic_load(&releases));
            return 3;
        }
        printf("PASS cycle=%d native CGDisplayStream frame 160x100, sampled_rgb_nonzero=%d/64, stop, context released once\n", attempt,atomic_load(&sampledRGB));
    }
    return 0;
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", action="store_true", help="attach a fresh root probe to the current loginwindow; never switch sessions")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="vnc-cgstream-") as directory:
        source, binary = Path(directory) / "probe.m", Path(directory) / "probe"
        source.write_text(SOURCE)
        subprocess.run(["xcrun", "clang", "-fobjc-arc", str(source), str(ROOT / "Sources/CVNCSession/DisplayStream.m"),
                        str(ROOT / "Sources/CVNCSession/ConsoleSession.c"),
                        "-I", str(ROOT / "Sources/CVNCSession/include"), "-framework", "Foundation",
                        "-framework", "CoreGraphics", "-framework", "CoreVideo", "-framework", "IOSurface",
                        "-framework", "SystemConfiguration", "-framework", "IOKit", "-lbsm",
                        "-o", str(binary)], check=True)
        command = [str(binary)]
        if args.root: command = ["sudo", "-n", "/bin/launchctl", "asuser", "0", str(binary), "--root"]
        subprocess.run(command, check=True, timeout=25)


if __name__ == "__main__":
    main()
