// Diagnostic only: public macOS 13 CGDisplayStream capture in the verified
// loginwindow audit session, without creating a replayd job or posting input.
// Build with ConsoleSession.c; see docs/console-session-backend.md.
#include "CVNCSession.h"
#include <CoreGraphics/CoreGraphics.h>
#include <CoreVideo/CoreVideo.h>
#include <IOSurface/IOSurface.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <servers/bootstrap.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static atomic_int received, stopped, invalid, complete, idle, blank, unknown;
static VNCConsoleIdentity identity;

static void timeout(int sig) {
    const char message[] = "FAIL: probe exceeded 35 seconds; no capture-service jobs were created.\n";
    (void)write(STDERR_FILENO, message, sizeof(message) - 1);
    _exit(124);
}

static void pump(double seconds, atomic_int *done) {
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + seconds;
    CFRunLoopTimerRef timer = CFRunLoopTimerCreateWithHandler(NULL, deadline, 0, 0, 0, ^(CFRunLoopTimerRef timer) {});
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopDefaultMode);
    while (!atomic_load(done) && CFAbsoluteTimeGetCurrent() < deadline)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
    CFRunLoopTimerInvalidate(timer);
    CFRelease(timer);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    signal(SIGALRM, timeout);
    alarm(35);
    char unresolved[PATH_MAX], executable[PATH_MAX];
    uint32_t length = sizeof(unresolved);
    if (_NSGetExecutablePath(unresolved, &length) || !realpath(unresolved, executable)) return 2;
    if (argc == 2 && !strcmp(argv[1], "--root")) {
        if (getuid() || geteuid()) { fprintf(stderr, "Run --root with sudo.\n"); return 2; }
        execl("/bin/launchctl", "launchctl", "asuser", "0", executable, "--attach", NULL);
        perror("launchctl"); return 2;
    }
    if (argc == 2 && !strcmp(argv[1], "--attach")) {
        if (getuid() || geteuid() || VNCConsoleCurrent(&identity) || identity.uid != 0) {
            fprintf(stderr, "SKIP: loginwindow must own the physical console; the probe never switches sessions.\n"); return 3;
        }
        int result = VNCConsolePrepare(identity);
        if (result) { fprintf(stderr, "FAIL: audit attachment returned %d\n", result); return 4; }
        char audit[32]; snprintf(audit, sizeof(audit), "%d", identity.audit_id);
        execl(executable, executable, "--attached", audit, NULL);
        perror("exec"); return 4;
    }
    if (argc == 3 && !strcmp(argv[1], "--attached")) {
        char *end = NULL;
        long audit = strtol(argv[2], &end, 10);
        if (!end || *end || audit <= 0 || audit > INT32_MAX) return 2;
        identity = (VNCConsoleIdentity){0, (int32_t)audit};
        int result = VNCConsoleVerify(identity);
        if (result) { fprintf(stderr, "FAIL: attached console verification returned %d\n", result); return 4; }
        mach_port_t port = MACH_PORT_NULL;
        kern_return_t lookup = bootstrap_look_up(bootstrap_port, "com.apple.replayd", &port);
        if (lookup == BOOTSTRAP_SUCCESS) {
            mach_port_deallocate(mach_task_self(), port);
            fprintf(stderr, "SKIP: root replayd is already registered; leave it running. This probe requires no root capture service.\n");
            return 3;
        }
        if (lookup != BOOTSTRAP_UNKNOWN_SERVICE) { fprintf(stderr, "FAIL: root service lookup returned %d\n", lookup); return 4; }
        printf("verified loginwindow uid=0 audit=%d; no root replayd registered\n", identity.audit_id);
    } else if (argc != 2 || strcmp(argv[1], "--user") || getuid() == 0) {
        fprintf(stderr, "Usage: sudo %s --root (loginwindow probe), or %s --user (current user desktop)\n", executable, executable);
        return 2;
    }

    // These public APIs are unavailable in new SDK declarations. Resolve their
    // exported symbols so the same diagnostic runs on Ventura and newer hosts.
    typedef CGDisplayStreamRef (*Create)(CGDirectDisplayID, size_t, size_t, int32_t,
        CFDictionaryRef, dispatch_queue_t, CGDisplayStreamFrameAvailableHandler);
    typedef CGError (*Control)(CGDisplayStreamRef);
    Create create = dlsym(RTLD_DEFAULT, "CGDisplayStreamCreateWithDispatchQueue");
    Control start = dlsym(RTLD_DEFAULT, "CGDisplayStreamStart"), stop = dlsym(RTLD_DEFAULT, "CGDisplayStreamStop");
    if (!create || !start || !stop) { fprintf(stderr, "FAIL: CGDisplayStream API unavailable\n"); return 5; }
    CGDirectDisplayID display = CGMainDisplayID();
    CGRect bounds = CGDisplayBounds(display);
    printf("probe_revision=2 uid=%u display=%u active=%d online=%d asleep=%d size=%.0fx%.0f screen_capture_preflight=%d\n",
        getuid(), display, CGDisplayIsActive(display), CGDisplayIsOnline(display), CGDisplayIsAsleep(display),
        bounds.size.width, bounds.size.height, CGPreflightScreenCaptureAccess());
    puts("Preflight is informational. This probe does not wake the display or request permission.");
    dispatch_queue_t queue = dispatch_queue_create("mac-vnc.console-capture-probe", DISPATCH_QUEUE_SERIAL);
    CGDisplayStreamRef stream = create(display, 160, 100, kCVPixelFormatType_32BGRA, NULL, queue,
        ^(CGDisplayStreamFrameStatus status, uint64_t time, IOSurfaceRef surface, CGDisplayStreamUpdateRef update) {
            if (status == kCGDisplayStreamFrameStatusStopped) { atomic_store(&stopped, 1); return; }
            if (status == kCGDisplayStreamFrameStatusFrameIdle) { atomic_fetch_add(&idle, 1); return; }
            if (status == kCGDisplayStreamFrameStatusFrameBlank) { atomic_fetch_add(&blank, 1); return; }
            if (status != kCGDisplayStreamFrameStatusFrameComplete) { atomic_fetch_add(&unknown, 1); return; }
            atomic_fetch_add(&complete, 1);
            if (!surface || IOSurfaceGetWidth(surface) != 160 || IOSurfaceGetHeight(surface) != 100 ||
                IOSurfaceGetBytesPerRow(surface) < 640 || IOSurfaceGetPixelFormat(surface) != kCVPixelFormatType_32BGRA ||
                (identity.audit_id && VNCConsoleVerify(identity))) {
                atomic_store(&invalid, 1); atomic_store(&received, 1); return;
            }
            if (IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL)) {
                atomic_store(&invalid, 1); atomic_store(&received, 1); return;
            }
            const unsigned char *bytes = IOSurfaceGetBaseAddress(surface);
            size_t stride = IOSurfaceGetBytesPerRow(surface);
            int nonzero = 0;
            for (int y = 0; y < 8; y++) for (int x = 0; x < 8; x++) {
                size_t offset = (y * 99 / 7) * stride + (x * 159 / 7) * 4;
                if (bytes[offset] || bytes[offset + 1] || bytes[offset + 2]) nonzero++;
            }
            IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
            if (!atomic_exchange(&received, 1)) printf("FRAME: 160x100 BGRA; sampled_rgb_nonzero=%d/64; no image saved\n", nonzero);
        });
    if (!stream) { fprintf(stderr, "FAIL: CGDisplayStreamCreate returned NULL; native API supplied no reason\n"); return 6; }
    CGError result = start(stream);
    if (result) { fprintf(stderr, "FAIL: CGDisplayStreamStart returned %d\n", result); CFRelease(stream); return 6; }
    pump(5, &received);
    result = stop(stream);
    if (!result) pump(2, &stopped);
    if (atomic_load(&stopped)) CFRelease(stream);
    printf("RESULT: frame_received=%d frame_valid=%d complete=%d idle=%d blank=%d unknown=%d asleep_now=%d stop_result=%d stopped=%d\n",
        atomic_load(&received), atomic_load(&received) && !atomic_load(&invalid),
        atomic_load(&complete), atomic_load(&idle), atomic_load(&blank), atomic_load(&unknown),
        CGDisplayIsAsleep(display), result, atomic_load(&stopped));
    return !atomic_load(&received) || atomic_load(&invalid) || result || !atomic_load(&stopped) ? 7 : 0;
}
