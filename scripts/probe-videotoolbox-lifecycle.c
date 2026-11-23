// macOS VM diagnostic. Default: inspect attached driver client IDs only.
// --open-close: open and close exactly one connection, without submitting media,
// driver methods, screen capture, or input. Useful before/after a VM restart.
// Build: xcrun clang -O2 -Wall -Wextra -framework IOKit -framework CoreFoundation \
//   scripts/probe-videotoolbox-lifecycle.c -o /tmp/probe-videotoolbox-lifecycle
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

typedef struct {
    uint64_t ids[4096];
    size_t count;
} Snapshot;

static bool snapshot(io_service_t driver, Snapshot *result) {
    *result = (Snapshot){0};
    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t kr = IORegistryEntryGetChildIterator(driver, kIOServicePlane, &iterator);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "Cannot enumerate driver children: %s\n", mach_error_string(kr));
        return false;
    }
    io_registry_entry_t child;
    bool valid = true;
    while ((child = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        uint64_t id = 0;
        if (IORegistryEntryGetRegistryEntryID(child, &id) != KERN_SUCCESS ||
            result->count == sizeof(result->ids) / sizeof(result->ids[0])) {
            valid = false;
            IOObjectRelease(child);
            break;
        }
        result->ids[result->count++] = id;
        IOObjectRelease(child);
    }
    IOObjectRelease(iterator);
    return valid;
}

static bool contains(const Snapshot *values, uint64_t id) {
    for (size_t i = 0; i < values->count; ++i) if (values->ids[i] == id) return true;
    return false;
}

static double monotonic_seconds(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return value.tv_sec + value.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    bool open_close = argc == 2 && strcmp(argv[1], "--open-close") == 0;
    if (argc != 1 && !open_close) {
        fprintf(stderr, "Usage: %s [--open-close]\n", argv[0]);
        return 2;
    }
    setvbuf(stdout, NULL, _IOLBF, 0);
    io_service_t driver = IOServiceGetMatchingService(kIOMainPortDefault,
        IOServiceMatching("AppleVideoToolboxParavirtualizationDriver"));
    if (driver == IO_OBJECT_NULL) {
        fprintf(stderr, "The Apple VM VideoToolbox driver is not present.\n");
        return 3;
    }
    Snapshot before, opened, closed;
    if (!snapshot(driver, &before)) { IOObjectRelease(driver); return 4; }
    printf("pid=%d uid=%d attached_before=%zu\n", getpid(), getuid(), before.count);
    if (!open_close) { IOObjectRelease(driver); return 0; }
    io_connect_t connection = IO_OBJECT_NULL;
    double start = monotonic_seconds();
    kern_return_t open_result = IOServiceOpen(driver, mach_task_self(), 0, &connection);
    printf("open_result=0x%08x description=%s elapsed_s=%.3f\n",
        open_result, mach_error_string(open_result), monotonic_seconds() - start);
    bool opened_valid = snapshot(driver, &opened);
    if (opened_valid) {
        printf("attached_after_open=%zu\n", opened.count);
        for (size_t i = 0; i < opened.count; ++i) {
            if (!contains(&before, opened.ids[i]))
                printf("new_id=0x%llx (concurrent processes can also create IDs)\n",
                    (unsigned long long)opened.ids[i]);
        }
    }
    if (open_result == KERN_SUCCESS) {
        start = monotonic_seconds();
        kern_return_t close_result = IOServiceClose(connection);
        printf("close_result=0x%08x description=%s elapsed_s=%.3f\n",
            close_result, mach_error_string(close_result), monotonic_seconds() - start);
        // Allow normal asynchronous termination to complete before counting.
        struct timespec pause = {.tv_sec = 2, .tv_nsec = 0};
        nanosleep(&pause, NULL);
    }
    if (snapshot(driver, &closed)) {
        printf("attached_after_close=%zu delta=%lld\n", closed.count,
            (long long)closed.count - (long long)before.count);
        if (opened_valid) for (size_t i = 0; i < opened.count; ++i) {
            if (!contains(&before, opened.ids[i]) && contains(&closed, opened.ids[i]))
                printf("new_id_still_attached=0x%llx\n", (unsigned long long)opened.ids[i]);
        }
    }
    IOObjectRelease(driver);
    return open_result == KERN_SUCCESS ? 0 : 5;
}
