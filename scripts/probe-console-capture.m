// Compare capture APIs after the same audit join + exec used by the server.
// Build:
// xcrun clang -O2 -fobjc-arc -fblocks -I Sources/CVNCSession/include \
//   scripts/probe-console-capture.m Sources/CVNCSession/ConsoleSession.c \
//   Sources/CVNCSession/ConsoleCapture.m -framework Foundation \
//   -framework CoreGraphics -framework IOSurface -o /tmp/probe-console-capture
// Run without sudo using --current, or with sudo using --console.
// No input injection, session switching, listener, or saved screenshot data.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include "CVNCSession.h"
#include <bsm/audit.h>
#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <stdatomic.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile sig_atomic_t interrupted;
static void interruptProbe(int signal) { interrupted = signal; }

static void received(void *context, int32_t status, IOSurfaceRef surface) {
    if (status != 0 || !surface) return;
    atomic_bool *gotFrame = context;
    if (!atomic_exchange(gotFrame, true)) {
        printf("STREAM_FRAME width=%zu height=%zu content=unverified\n",
               IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface));
    }
}

static int capture(const char *method, BOOL console, VNCConsoleIdentity identity) {
    int verified = console ? VNCConsoleVerify(identity) : 0;
    printf("IDENTITY pid=%d uid=%u audit=%d setugid=%d console_required=%d verify=%d\n",
           getpid(), getuid(), identity.audit_id, issetugid(), console, verified);
    if (verified) return 3;
    printf("ACCESS capture_preflight=%d input_preflight=%d (not delivery verification)\n",
           CGPreflightScreenCaptureAccess(), CGPreflightPostEventAccess());
    uint32_t count = 0;
    CGDirectDisplayID displays[32];
    CGError query = CGGetActiveDisplayList(32, displays, &count);
    printf("DISPLAYS result=%d count=%u\n", query, count);
    if (query || !count) return 4;
    CGDirectDisplayID display = displays[0];
    CGRect bounds = CGDisplayBounds(display);
    printf("TARGET display=%u bounds=%.0f,%.0f %.0fx%.0f\n", display,
           bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height);
    if (CGRectIsEmpty(bounds) || CGRectIsInfinite(bounds) ||
        bounds.size.width > 16384 || bounds.size.height > 16384) return 4;

    int result = 4;
    if (!strcmp(method, "stream")) {
        atomic_bool gotFrame = false;
        VNCConsoleCaptureError error = {0};
        VNCConsoleCaptureRef stream = VNCConsoleCaptureStart(display,
            (size_t)bounds.size.width, (size_t)bounds.size.height, 5,
            received, &gotFrame, &error);
        printf("STREAM_CREATE success=%d stage=%d code=%d\n", stream != NULL, error.stage, error.code);
        if (error.stage == VNCConsoleCaptureStageCreate)
            puts("STREAM_FACTORY returned NULL; macOS supplied no error code; Start was not called");
        if (stream) {
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
            while (!atomic_load(&gotFrame) && deadline.timeIntervalSinceNow > 0)
                [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
            VNCConsoleCaptureStop(stream);
            result = atomic_load(&gotFrame) ? 0 : 4;
        }
    } else {
        // ScreensharingAgent's OurCGDisplayCreateImageForRect calls this with
        // (0, &rect, 1, 0, 0x501). The local SkyLight implementation also accepts
        // (0, NULL, 0, displayID, flags) to select a display explicitly.
        // Both paths still obey the OS's capture authorization/proxy policy.
        typedef CFArrayRef (*Snapshot)(uint32_t, const CGRect *, int32_t, uint32_t, uint32_t);
        Snapshot snapshot = dlsym(RTLD_DEFAULT, "CGSHWCaptureDesktop");
        if (!snapshot) { puts("SNAPSHOT symbol unavailable"); return 4; }
        BOOL rectangle = !strcmp(method, "snapshot-rect");
        CFArrayRef images = snapshot(0, rectangle ? &bounds : NULL,
                                    rectangle ? 1 : 0, rectangle ? 0 : display, 0x501);
        if (!images) {
            puts("SNAPSHOT returned NULL; macOS supplied no error code");
        } else {
            if (CFGetTypeID(images) != CFArrayGetTypeID()) {
                CFRelease(images); puts("SNAPSHOT unexpected result type"); return 4;
            }
            CFIndex imageCount = CFArrayGetCount(images);
            printf("SNAPSHOT images=%ld\n", imageCount);
            for (CFIndex i = 0; i < imageCount; i++) {
                CFTypeRef value = CFArrayGetValueAtIndex(images, i);
                if (!value || CFGetTypeID(value) != CGImageGetTypeID()) continue;
                CGImageRef image = (CGImageRef)value;
                size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
                printf("SNAPSHOT_FRAME index=%ld width=%zu height=%zu content=unverified\n", i, width, height);
                if (width > 1 && height > 1) result = 0;
            }
            CFRelease(images);
        }
    }
    if (console && VNCConsoleVerify(identity)) {
        puts("IDENTITY changed during capture; result discarded"); return 3;
    }
    return result;
}

static int runAttempt(const char *executable, const char *method, BOOL console, VNCConsoleIdentity identity) {
    printf("METHOD %s\n", method);
    char options[128];
    snprintf(options, sizeof(options), "%u:%d:%s", identity.uid, identity.audit_id, method);
    pid_t child = fork();
    if (child < 0) { perror("fork"); return 2; }
    if (child == 0) {
        // Exec immediately: no Objective-C/dispatch work after fork.
        execl(executable, executable, console ? "--prepare" : "--current-worker", options, NULL);
        _exit(127);
    }
    int status = 0;
    // Parent timeout bounds preparation/exec too. Each method gets a fresh
    // process so a failed framework request cannot affect the next method.
    for (unsigned ticks = 0;; ticks++) {
        pid_t waited = waitpid(child, &status, WNOHANG);
        if (waited == child) break;
        if (waited < 0 && errno != EINTR) { perror("waitpid"); return 2; }
        if (interrupted || ticks >= 300) {
            kill(child, SIGKILL);
            while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
            printf("METHOD_STOP reason=%s\n", interrupted ? "interrupt" : "15-second timeout");
            return interrupted ? 128 + interrupted : 4;
        }
        usleep(50000);
    }
    int result = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    printf("METHOD_RESULT method=%s exit=%d\n", method, result);
    return result;
}

int main(int argc, char **argv) {
    setbuf(stdout, NULL);
    // Credential preparation precedes Foundation/WindowServer initialization.
    if (argc == 3) {
        unsigned uid = 0; int audit = 0; char method[32] = {0}, extra = 0;
        if (sscanf(argv[2], "%u:%d:%31[a-z-]%c", &uid, &audit, method, &extra) != 3 ||
            (strcmp(method, "stream") && strcmp(method, "snapshot-rect") && strcmp(method, "snapshot-display"))) return 2;
        VNCConsoleIdentity identity = {uid, audit};
        if (!strcmp(argv[1], "--prepare")) {
            alarm(12);
            int error = VNCConsolePrepare(identity);
            if (!error) error = VNCConsoleExecWorker(argv[0], argv[2]);
            printf("PREPARE failed code=%d\n", error); return 3;
        }
        BOOL console = !strcmp(argv[1], "--console-worker-attached");
        if (!console && strcmp(argv[1], "--current-worker")) return 2;
        alarm(12);
        @autoreleasepool { return capture(method, console, identity); }
    }
    @autoreleasepool {
        BOOL console = argc == 2 && !strcmp(argv[1], "--console");
        if (!console && !(argc == 2 && !strcmp(argv[1], "--current"))) {
            fprintf(stderr, "Usage: probe-console-capture --current | --console\n"); return 2;
        }
        if (console && geteuid() != 0) {
            fprintf(stderr, "--console requires sudo to join loginwindow's audit session\n"); return 2;
        }
        VNCConsoleIdentity identity = {0};
        if (console) {
            int error = VNCConsoleCurrent(&identity);
            if (error) { printf("CONSOLE_IDENTITY failed code=%d\n", error); return 3; }
        } else {
            auditinfo_addr_t audit = {0};
            if (getaudit_addr(&audit, sizeof(audit))) { perror("getaudit_addr"); return 3; }
            identity = (VNCConsoleIdentity){getuid(), audit.ai_asid};
        }
        printf("PROBE target_uid=%u target_audit=%d scope=%s pixels_saved=no input_sent=no\n",
               identity.uid, identity.audit_id, console ? "console" : "current-user");
        NSString *path = [NSString stringWithUTF8String:argv[0]].stringByStandardizingPath;
        if (!path.isAbsolutePath) path = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:path];
        struct sigaction action = {0}; action.sa_handler = interruptProbe;
        sigemptyset(&action.sa_mask);
        sigaction(SIGINT, &action, NULL); sigaction(SIGTERM, &action, NULL);
        BOOL anyFrame = NO;
        const char *methods[] = {"stream", "snapshot-rect", "snapshot-display"};
        for (unsigned i = 0; i < sizeof(methods) / sizeof(methods[0]); i++) {
            const char *method = methods[i];
            if (console) {
                VNCConsoleIdentity now;
                if (VNCConsoleCurrent(&now) || now.uid != identity.uid || now.audit_id != identity.audit_id) {
                    puts("CONSOLE changed; remaining methods skipped"); return 3;
                }
            }
            int result = runAttempt(path.fileSystemRepresentation, method, console, identity);
            if (interrupted) return 128 + interrupted;
            anyFrame |= result == 0;
        }
        puts("Content and input delivery remain unverified, even if a capture API returned a frame.");
        return anyFrame ? 0 : 4;
    }
}
