#include "CVNCSession.h"
#import <Foundation/Foundation.h>
#import <ServiceManagement/ServiceManagement.h>
#include <bsm/audit.h>
#include <errno.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <libproc.h>
#include <signal.h>
#include <spawn.h>
#include <servers/bootstrap.h>
#include <sys/proc.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static void closeDescriptor(int *fd) { if (*fd >= 0) close(*fd); }

struct VNCConsoleCaptureService {
    int lock;
    int32_t audit;
    char *directory;
    mach_port_t endpoint;
};

static int launchctlWithTimeout(NSArray<NSString *> *arguments, unsigned ticks) {
    char **argv = calloc(arguments.count + 2, sizeof(char *));
    if (!argv) return ENOMEM;
    argv[0] = "/bin/launchctl";
    for (NSUInteger i = 0; i < arguments.count; i++) argv[i + 1] = (char *)arguments[i].UTF8String;
    // These short-lived commands run in the supervisor now. Do not inherit its
    // VNC credential, listener/client sockets, or the service ownership lock.
    char *environment[] = {"PATH=/usr/bin:/bin:/usr/sbin:/sbin", NULL};
    posix_spawnattr_t attributes;
    posix_spawn_file_actions_t actions;
    int result = posix_spawnattr_init(&attributes);
    if (result) { free(argv); return result; }
    result = posix_spawn_file_actions_init(&actions);
    if (result) { posix_spawnattr_destroy(&attributes); free(argv); return result; }
    result = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);
    if (!result) result = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    if (!result) result = posix_spawn_file_actions_adddup2(&actions, STDERR_FILENO, STDOUT_FILENO);
    if (!result) result = posix_spawn_file_actions_adddup2(&actions, STDERR_FILENO, STDERR_FILENO);
    pid_t child = 0;
    if (!result) result = posix_spawn(&child, argv[0], &actions, &attributes, argv, environment);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    free(argv);
    if (result) return result;
    // Bound launchctl itself as well as native service startup/teardown.
    for (unsigned tick = 0; tick < ticks; tick++) {
        int status = 0;
        pid_t waited = waitpid(child, &status, WNOHANG);
        if (waited == child) return WIFEXITED(status) ? WEXITSTATUS(status) : EINTR;
        if (waited < 0 && errno != EINTR) return errno;
        usleep(50000);
    }
    kill(child, SIGKILL);
    while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
    return ETIMEDOUT;
}

static int launchctl(NSArray<NSString *> *arguments) {
    return launchctlWithTimeout(arguments, 80);
}

// Retain the exact old schema solely to recognize our abandoned jobs safely.
static NSDictionary *legacyCaptureJob(NSString *label, NSString *executable, int32_t audit, pid_t owner) {
    return @{
        @"Label": label,
        @"ProgramArguments": @[executable, @"--console-capture-service",
            [NSString stringWithFormat:@"%d", audit], [NSString stringWithFormat:@"%d", owner]],
        @"RunAtLoad": @YES,
        @"LimitLoadToSessionType": @[@"Background"],
        @"ProcessType": @"Interactive",
        @"MachServices": @{@"com.apple.replayd": @YES, @"com.apple.replayd-cache-delete": @YES,
            @"com.apple.replaykit.sharingsession": @YES}
    };
}

static NSDictionary *directCaptureJob(NSString *label, NSString *executable, int32_t audit, pid_t owner) {
    return @{
        @"Label": label,
        // Retained only to recognize abandoned 1.7.3 jobs. Starting replayd
        // here leaves it in root's background audit session, not loginwindow.
        @"ProgramArguments": @[@"/usr/libexec/replayd"],
        @"RunAtLoad": @YES,
        @"LimitLoadToSessionType": @[@"Background"],
        @"ProcessType": @"Interactive",
        @"MachServices": @{@"com.apple.replayd": @YES, @"com.apple.replayd-cache-delete": @YES,
            @"com.apple.replaykit.sharingsession": @YES},
        // launchd ignores this application-owned metadata. It replaces the
        // ownership information formerly stored in the helper's arguments.
        @"MacVNCServerOwnership": @{@"Version": @2, @"Executable": executable,
            @"AuditSession": [NSString stringWithFormat:@"%d", audit],
            @"OwnerPID": [NSString stringWithFormat:@"%d", owner]}
    };
}

static NSDictionary *captureJob(NSString *label, NSString *executable, int32_t audit, pid_t owner) {
    NSMutableDictionary *job = [NSMutableDictionary dictionaryWithDictionary:legacyCaptureJob(label, executable, audit, owner)];
    job[@"MacVNCServerOwnership"] = @{@"Version": @3, @"Executable": executable,
        @"AuditSession": [NSString stringWithFormat:@"%d", audit],
        @"OwnerPID": [NSString stringWithFormat:@"%d", owner]};
    return job;
}

CFDictionaryRef VNCConsoleCaptureJobCreate(const char *label, const char *executable, int32_t audit, int32_t owner) {
    if (!label || !executable || executable[0] != '/' || audit <= 0 || owner <= 1) return NULL;
    @autoreleasepool {
        return CFRetain((__bridge CFDictionaryRef)captureJob(@(label), @(executable), audit, owner));
    }
}

static int bootout(NSString *target) {
    int result = launchctl(@[@"bootout", target]);
    // A timed-out request may already have removed the job. ESRCH means absent.
    if (result && result != ESRCH) result = launchctl(@[@"bootout", target]);
    return result == ESRCH ? 0 : result;
}

static int32_t positiveInteger(id value) {
    if (![value isKindOfClass:NSString.class]) return 0;
    const char *text = [value UTF8String];
    if (!text || text[0] < '1' || text[0] > '9') return 0;
    char *end = NULL;
    errno = 0;
    long number = strtol(text, &end, 10);
    return !errno && end && !*end && number <= INT32_MAX ? (int32_t)number : 0;
}

int VNCConsoleCaptureJobReadOwner(CFDictionaryRef value, const char *label, int32_t *audit, int32_t *owner) {
    if (!value || CFGetTypeID(value) != CFDictionaryGetTypeID() || !label || !audit || !owner) return EINVAL;
    @autoreleasepool {
        NSDictionary *job = (__bridge NSDictionary *)value;
        id metadata = job[@"MacVNCServerOwnership"];
        id executable;
        int32_t jobAudit, jobOwner;
        NSDictionary *expected;
        if (metadata) {
            if (![metadata isKindOfClass:NSDictionary.class]) return EINVAL;
            executable = metadata[@"Executable"];
            jobAudit = positiveInteger(metadata[@"AuditSession"]);
            jobOwner = positiveInteger(metadata[@"OwnerPID"]);
            if (![executable isKindOfClass:NSString.class] || ![executable isAbsolutePath] ||
                !jobAudit || jobOwner <= 1) return EINVAL;
            expected = [metadata[@"Version"] isEqual:@2]
                ? directCaptureJob(@(label), executable, jobAudit, jobOwner)
                : captureJob(@(label), executable, jobAudit, jobOwner);
        } else {
            id arguments = job[@"ProgramArguments"];
            if (![arguments isKindOfClass:NSArray.class] || [arguments count] != 4) return EINVAL;
            executable = arguments[0];
            jobAudit = positiveInteger(arguments[2]);
            jobOwner = positiveInteger(arguments[3]);
            if (![executable isKindOfClass:NSString.class] || ![executable isAbsolutePath] ||
                !jobAudit || jobOwner <= 1) return EINVAL;
            expected = legacyCaptureJob(@(label), executable, jobAudit, jobOwner);
        }
        if (![job isEqual:expected]) return EINVAL;
        *audit = jobAudit;
        *owner = jobOwner;
        return 0;
    }
}

// Called only while holding the exclusive service lock. A dead supervisor cannot
// clean up after SIGKILL; its root-only plist is the record of which unique job
// we own. Never infer ownership from a replayd PID or Mach service name alone.
static int recoverOrphanedJobs(void) {
    NSString *runtime = @"/private/var/run";
    NSString *prefix = @"mac-vnc-console.";
    NSCharacterSet *suffixCharacters = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"];
    NSError *error = nil;
    NSArray *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:runtime error:&error];
    if (!names) return EIO;
    for (NSString *name in names) {
        if (![name hasPrefix:prefix] || name.length != prefix.length + 6 ||
            [[name substringFromIndex:prefix.length] rangeOfCharacterFromSet:suffixCharacters.invertedSet].location != NSNotFound) continue;
        NSString *root = [runtime stringByAppendingPathComponent:name];
        int directory __attribute__((cleanup(closeDescriptor))) = open(root.fileSystemRepresentation,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        struct stat info;
        if (directory < 0 || fstat(directory, &info) || !S_ISDIR(info.st_mode) ||
            info.st_uid != 0 || (info.st_mode & 07777) != 0700) continue;
        int file __attribute__((cleanup(closeDescriptor))) = openat(directory, "capture.plist",
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
        if (file < 0 || fstat(file, &info) || !S_ISREG(info.st_mode) || info.st_uid != 0 ||
            info.st_nlink != 1 || (info.st_mode & 07777) != 0600 || info.st_size <= 0 || info.st_size > 16384) continue;
        NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)info.st_size];
        NSUInteger offset = 0;
        while (offset < data.length) {
            ssize_t count = read(file, (uint8_t *)data.mutableBytes + offset, data.length - offset);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) break;
            offset += (NSUInteger)count;
        }
        if (offset != data.length) continue;
        id job = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil];
        if (![job isKindOfClass:NSDictionary.class]) continue;
        int32_t audit = 0, owner = 0;
        NSString *label = [@"com.mac-vnc-server.console-capture." stringByAppendingString:name];
        if (VNCConsoleCaptureJobReadOwner((__bridge CFDictionaryRef)job, label.UTF8String, &audit, &owner)) continue;
        // A previous failed cleanup in this process is also recoverable once
        // we reacquire the exclusive lock. Other live/reused PIDs are preserved.
        // All known schemas also recover older standalone managers.
        if (owner != getpid() && (kill(owner, 0) == 0 || errno != ESRCH)) continue;
        NSString *target = [@"user/0/" stringByAppendingString:label];
        fprintf(stderr, "Console capture service recovering orphan: owner=%d job=%s\n", owner, target.UTF8String);
        int result = bootout(target);
        if (result) {
            fprintf(stderr, "warning: console capture orphan cleanup failed (%d): %s; retained %s/capture.plist\n",
                result, target.UTF8String, root.fileSystemRepresentation);
            return result;
        }
        // Remove just the verified metadata, never recursively traverse a tree.
        if (unlinkat(directory, "capture.plist", 0) || rmdir(root.fileSystemRepresentation)) {
            fprintf(stderr, "warning: console capture orphan metadata cleanup failed: %s (%d)\n",
                root.fileSystemRepresentation, errno);
        }
        fprintf(stderr, "Console capture service recovered orphan: %s\n", target.UTF8String);
    }
    return 0;
}

static int acquireOwnershipLock(int *descriptor) {
    *descriptor = open("/private/var/run/mac-vnc-console-capture.lock",
        O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_EXLOCK | O_NONBLOCK, 0600);
    if (*descriptor < 0) return errno;
    struct stat info;
    if (fstat(*descriptor, &info) || !S_ISREG(info.st_mode) || info.st_uid != 0 ||
        info.st_nlink != 1 || (info.st_mode & 07777) != 0600) return EPERM;
    return 0;
}

int VNCConsoleCaptureServiceRecover(void) {
    if (getuid() != 0 || geteuid() != 0) return EPERM;
    int lock __attribute__((cleanup(closeDescriptor))) = -1;
    int result = acquireOwnershipLock(&lock);
    if (result) return result;
    @autoreleasepool { return recoverOrphanedJobs(); }
}

int VNCRunConsoleCaptureService(VNCConsoleIdentity identity, int32_t owner_pid) {
    if (getuid() != 0 || geteuid() != 0 || identity.uid != 0 || owner_pid <= 1 || kill(owner_pid, 0)) return EPERM;
    // replayd's audit session selects its graphics context too. The worker's
    // own attachment cannot compensate for a daemon in the background session.
    // Join before exec so replayd creates all framework connections afresh.
    int result = VNCConsolePrepare(identity);
    if (result) return result;
    execl("/usr/libexec/replayd", "/usr/libexec/replayd", NULL);
    return errno;
}

int VNCConsoleCheckCaptureService(VNCConsoleIdentity identity, int32_t owner_pid, const char *label) {
    if (getuid() != 0 || geteuid() != 0 || identity.uid != 0 || owner_pid <= 1 || !label) return EPERM;
    // The listener invokes this short-lived check via launchctl asuser 0.
    // Query root's bootstrap without changing the listener's own namespace.
    // A registered send right alone is not readiness: launchd queues messages
    // even when the service repeatedly fails to launch. Check this owned job's
    // PID and executable, never an unrelated replayd found by process name.
    pid_t previousPID = 0;
    for (unsigned tick = 0; tick < 100; tick++) {
        if (kill(owner_pid, 0)) return ESRCH;
        VNCConsoleIdentity current = {0};
        if (VNCConsoleCurrent(&current) || current.uid != 0 || current.audit_id != identity.audit_id) return ESTALE;
        pid_t runningPID = 0;
        @autoreleasepool {
            // This read-only API predates Ventura. The response is advisory:
            // missing/malformed data fails closed and the native PID/path is
            // verified independently. No launchctl text output is parsed.
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            CFDictionaryRef value = SMJobCopyDictionary(kSMDomainUserLaunchd, (__bridge CFStringRef)@(label));
            #pragma clang diagnostic pop
            if (value) {
                NSDictionary *job = (__bridge NSDictionary *)value;
                id pid = job[@"PID"];
                if ([job[@"Label"] isEqual:@(label)] && [pid isKindOfClass:NSNumber.class] &&
                    [pid longLongValue] > 1 && [pid longLongValue] <= INT32_MAX) {
                    pid_t candidate = [pid intValue];
                    struct proc_bsdinfo info = {0};
                    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
                    if (proc_pidinfo(candidate, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info) &&
                        info.pbi_uid == 0 && info.pbi_ppid == 1 && info.pbi_status != SZOMB &&
                        proc_pidpath(candidate, path, sizeof(path)) > 0 && !strcmp(path, "/usr/libexec/replayd")) {
                        auditpinfo_addr_t audit = {.ap_pid = candidate};
                        if (auditon(A_GETPINFO_ADDR, &audit, sizeof(audit)) == 0) {
                            if (audit.ap_asid != identity.audit_id) {
                                fprintf(stderr, "Console capture service audit mismatch: pid=%d actual=%d expected=%d\n",
                                    candidate, audit.ap_asid, identity.audit_id);
                                CFRelease(value);
                                return ESTALE;
                            }
                            runningPID = candidate;
                        }
                    }
                }
                CFRelease(value);
            }
        }
        if (runningPID && runningPID == previousPID) {
            fprintf(stderr, "Console capture service process ready: pid=%d verified_audit=%d\n", runningPID, identity.audit_id);
            return 0;
        }
        previousPID = runningPID;
        usleep(100000);
    }
    fprintf(stderr, "Console capture service did not start replayd within 10 seconds\n");
    return ETIMEDOUT;
}

static int startService(VNCConsoleCaptureServiceRef service, VNCConsoleIdentity identity, const char *executable) {
    if (getuid() != 0 || geteuid() != 0 || identity.uid != 0 || identity.audit_id <= 0 ||
        !executable || executable[0] != '/') return EPERM;
    @autoreleasepool {
        VNCConsoleIdentity current = {0};
        if (VNCConsoleCurrent(&current) || current.uid != 0 || current.audit_id != identity.audit_id) return ESTALE;
        // launchd accepts different job labels that claim the same Mach service
        // names. Serialize owners before looking up the existing service.
        // Keep this empty lock inode across runs: unlinking it on unlock would
        // let concurrent opens lock different inodes. /var/run resets on reboot.
        int result = acquireOwnershipLock(&service->lock);
        if (result) {
            fprintf(stderr, "Console capture service refused: root capture service is already owned or its lock is unavailable\n");
            return result;
        }
        result = recoverOrphanedJobs();
        if (result) return result;
        // Query user/0 explicitly without changing this process's bootstrap or
        // graphics session. Its inherited namespace belongs to the GUI caller.
        typedef kern_return_t (*PerUserLookup)(mach_port_t, const char *, uid_t, mach_port_t *);
        PerUserLookup lookupForUser = dlsym(RTLD_DEFAULT, "bootstrap_look_up_per_user");
        if (!lookupForUser) return ENOTSUP;
        mach_port_t existing = MACH_PORT_NULL;
        kern_return_t lookup = lookupForUser(bootstrap_port, "com.apple.replayd", 0, &existing);
        if (lookup == BOOTSTRAP_SUCCESS) {
            mach_port_deallocate(mach_task_self(), existing);
            fprintf(stderr, "Console capture service refused: an existing root capture service is not replaced\n");
            return EADDRINUSE;
        }
        if (lookup != BOOTSTRAP_UNKNOWN_SERVICE) {
            fprintf(stderr, "Console capture service lookup failed (%d)\n", lookup);
            return ENXIO;
        }
        // launchctl needs a plist, but it contains no credentials or pixels.
        // mkdtemp makes a root-only directory outside the user's home. The
        // supervisor removes this directory and its uniquely named job on exit.
        char directory[] = "/private/var/run/mac-vnc-console.XXXXXX";
        if (!mkdtemp(directory)) return errno;
        service->directory = strdup(directory);
        if (!service->directory) { rmdir(directory); return ENOMEM; }
        NSString *root = [NSString stringWithUTF8String:directory];
        NSString *label = [@"com.mac-vnc-server.console-capture." stringByAppendingString:root.lastPathComponent];
        NSString *path = [root stringByAppendingPathComponent:@"capture.plist"];
        NSDictionary *job = captureJob(label, [NSString stringWithUTF8String:executable], identity.audit_id, getpid());
        NSError *error = nil;
        NSData *plist = [NSPropertyListSerialization dataWithPropertyList:job
            format:NSPropertyListXMLFormat_v1_0 options:0 error:&error];
        if (!plist || ![plist writeToFile:path options:NSDataWritingAtomic error:&error]) {
            fprintf(stderr, "Console capture service plist failed: %s\n", error.localizedDescription.UTF8String);
            return EIO;
        }
        if (chmod(path.fileSystemRepresentation, 0600)) return errno;
        result = launchctl(@[@"bootstrap", @"user/0", path]);
        if (result) {
            fprintf(stderr, "Console capture service bootstrap failed (%d)\n", result);
        } else {
            if (lookupForUser(bootstrap_port, "com.apple.replayd", 0, &service->endpoint) != BOOTSTRAP_SUCCESS) return ENXIO;
            fprintf(stderr, "Console capture service registered: uid=0 target_audit=%d owner=%d; attaching replayd to loginwindow\n",
                identity.audit_id, getpid());
            result = launchctlWithTimeout(@[@"asuser", @"0", @(executable), @"--console-capture-service-check",
                [NSString stringWithFormat:@"%d", identity.audit_id], [NSString stringWithFormat:@"%d", getpid()], label], 240);
            if (result) {
                fprintf(stderr, "Console capture service readiness failed (%d); owned launchd job status follows\n", result);
                (void)launchctl(@[@"print", [@"user/0/" stringByAppendingString:label]]);
            }
        }
        return result;
    }
}

VNCConsoleCaptureServiceRef VNCConsoleCaptureServiceCreate(VNCConsoleIdentity identity, const char *executable, int32_t *error) {
    VNCConsoleCaptureServiceRef service = calloc(1, sizeof(*service));
    if (!service) { if (error) *error = ENOMEM; return NULL; }
    service->lock = -1;
    service->audit = identity.audit_id;
    int result = startService(service, identity, executable);
    if (error) *error = result;
    if (result) { VNCConsoleCaptureServiceDestroy(service); return NULL; }
    return service;
}

void VNCConsoleCaptureServiceDestroy(VNCConsoleCaptureServiceRef service) {
    if (!service) return;
    @autoreleasepool {
        if (service->directory) {
            NSString *root = [NSString stringWithUTF8String:service->directory];
            NSString *target = [@"user/0/com.mac-vnc-server.console-capture." stringByAppendingString:root.lastPathComponent];
            NSString *path = [root stringByAppendingPathComponent:@"capture.plist"];
            // Also try bootout after a failed bootstrap: launchd may have accepted
            // the job before its reply failed. The random label is owned only here.
            int cleanup = bootout(target);
            if (cleanup) {
                fprintf(stderr, "warning: console capture service cleanup failed (%d): %s; retained %s for retry on next startup\n",
                    cleanup, target.UTF8String, path.fileSystemRepresentation);
            } else {
                // bootout can return before the daemon drops its receive
                // right. Keep our ownership lock briefly until this exact
                // endpoint dies, so an immediate retry does not mistake it
                // for an unrelated root service. Never terminate by name.
                for (unsigned tick = 0; service->endpoint && tick < 40; tick++) {
                    mach_port_type_t type = 0;
                    if (mach_port_type(mach_task_self(), service->endpoint, &type) != KERN_SUCCESS ||
                        (type & MACH_PORT_TYPE_DEAD_NAME)) break;
                    usleep(50000);
                }
                if ((unlink(path.fileSystemRepresentation) && errno != ENOENT) || rmdir(root.fileSystemRepresentation)) {
                    fprintf(stderr, "warning: console capture metadata cleanup failed: %s (%d)\n", root.fileSystemRepresentation, errno);
                }
            }
            fprintf(stderr, "Console capture service released: audit=%d owner=%d\n", service->audit, getpid());
        }
    }
    if (service->endpoint) mach_port_deallocate(mach_task_self(), service->endpoint);
    closeDescriptor(&service->lock);
    free(service->directory);
    free(service);
}
