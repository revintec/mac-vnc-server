#include "CVNCSession.h"
#import <Foundation/Foundation.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <servers/bootstrap.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
static volatile sig_atomic_t brokerInterrupted;
static void interruptBroker(int number) { brokerInterrupted = number; }
static void closeDescriptor(int *fd) { if (*fd >= 0) close(*fd); }

static int launchctl(NSArray<NSString *> *arguments) {
    char **argv = calloc(arguments.count + 2, sizeof(char *));
    if (!argv) return ENOMEM;
    argv[0] = "/bin/launchctl";
    for (NSUInteger i = 0; i < arguments.count; i++) argv[i + 1] = (char *)arguments[i].UTF8String;
    pid_t child = 0;
    int result = posix_spawn(&child, argv[0], NULL, NULL, argv, environ);
    free(argv);
    if (result) return result;
    // Bound launchctl itself as well as native service startup/teardown.
    for (unsigned tick = 0; tick < 80; tick++) {
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

static int anonymousSocket(void) {
    struct stat st;
    struct sockaddr_un address = {0};
    socklen_t size = sizeof(address);
    if (fstat(STDIN_FILENO, &st) || !S_ISSOCK(st.st_mode) ||
        getsockname(STDIN_FILENO, (struct sockaddr *)&address, &size) ||
        address.sun_family != AF_UNIX || address.sun_path[0]) return EINVAL;
    int flags = fcntl(STDIN_FILENO, F_GETFD);
    // Only the manager owns this lifeline. launchctl must not inherit it.
    if (flags < 0 || fcntl(STDIN_FILENO, F_SETFD, flags | FD_CLOEXEC) < 0) return errno;
    int yes = 1;
    return setsockopt(STDIN_FILENO, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes)) ? errno : 0;
}

static NSDictionary *captureJob(NSString *label, NSString *executable, int32_t audit, pid_t manager) {
    return @{
        @"Label": label,
        @"ProgramArguments": @[executable, @"--console-capture-service",
            [NSString stringWithFormat:@"%d", audit], [NSString stringWithFormat:@"%d", manager]],
        @"RunAtLoad": @YES,
        @"LimitLoadToSessionType": @[@"Background"],
        @"ProcessType": @"Interactive",
        @"MachServices": @{@"com.apple.replayd": @YES, @"com.apple.replayd-cache-delete": @YES,
            @"com.apple.replaykit.sharingsession": @YES}
    };
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

// Called only while holding the exclusive broker lock. A dead manager cannot
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
        if (brokerInterrupted) return EINTR;
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
        id arguments = job[@"ProgramArguments"];
        if (![arguments isKindOfClass:NSArray.class] || [arguments count] != 4 ||
            ![arguments[0] isKindOfClass:NSString.class] || ![arguments[0] isAbsolutePath]) continue;
        int32_t audit = positiveInteger(arguments[2]);
        pid_t manager = positiveInteger(arguments[3]);
        NSString *label = [@"com.mac-vnc-server.console-capture." stringByAppendingString:name];
        if (!audit || manager <= 1 || ![job isEqual:captureJob(label, arguments[0], audit, manager)]) continue;
        // Existing/reused PIDs and permission failures are not proof of death.
        if (kill(manager, 0) == 0 || errno != ESRCH) continue;
        NSString *target = [@"user/0/" stringByAppendingString:label];
        fprintf(stderr, "Console capture broker recovering orphan: manager=%d job=%s\n", manager, target.UTF8String);
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
        fprintf(stderr, "Console capture broker recovered orphan: %s\n", target.UTF8String);
    }
    return 0;
}

int VNCConsoleExecCaptureService(VNCConsoleIdentity identity, int32_t manager_pid) {
    if (identity.uid != 0 || manager_pid <= 1 || kill(manager_pid, 0)) return EPERM;
    int result = VNCConsolePrepare(identity);
    if (result) return result;
    // Execute Apple's original signed service, with its own normal entitlement
    // validation. No private entitlements are added to our executable.
    execl("/usr/libexec/replayd", "/usr/libexec/replayd", NULL);
    return errno;
}

int VNCConsoleRunCaptureBroker(VNCConsoleIdentity identity, const char *executable) {
    if (getuid() != 0 || geteuid() != 0 || identity.uid != 0 || identity.audit_id <= 0 ||
        !executable || executable[0] != '/') return EPERM;
    int result = anonymousSocket();
    if (result) return result;
    struct sigaction action = {0};
    action.sa_handler = interruptBroker;
    sigemptyset(&action.sa_mask);
    sigaction(SIGINT, &action, NULL); sigaction(SIGTERM, &action, NULL); sigaction(SIGHUP, &action, NULL);
    signal(SIGPIPE, SIG_IGN);
    @autoreleasepool {
        VNCConsoleIdentity current = {0};
        if (VNCConsoleCurrent(&current) || current.uid != 0 || current.audit_id != identity.audit_id) return ESTALE;
        // launchd accepts different job labels that claim the same Mach service
        // names. Serialize our managers before looking up the existing service.
        // Keep this empty lock inode across runs: unlinking it on unlock would
        // let concurrent opens lock different inodes. /var/run resets on reboot.
        int owner __attribute__((cleanup(closeDescriptor))) = open(
            "/private/var/run/mac-vnc-console-capture.lock",
            O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_EXLOCK | O_NONBLOCK, 0600);
        if (owner < 0) {
            int lockError = errno;
            fprintf(stderr, "Console capture broker refused: root capture service is already owned or its lock is unavailable\n");
            return lockError;
        }
        struct stat lockInfo;
        if (fstat(owner, &lockInfo) || !S_ISREG(lockInfo.st_mode) || lockInfo.st_uid != 0 ||
            lockInfo.st_nlink != 1 || (lockInfo.st_mode & 0777) != 0600) return EPERM;
        result = recoverOrphanedJobs();
        if (result) return result;
        if (brokerInterrupted) return EINTR;
        // This manager is launched through `launchctl asuser 0`, so lookup uses
        // the same root namespace as the job below, not the invoking user's.
        mach_port_t existing = MACH_PORT_NULL;
        kern_return_t lookup = bootstrap_look_up(bootstrap_port, "com.apple.replayd", &existing);
        if (lookup == BOOTSTRAP_SUCCESS) {
            mach_port_deallocate(mach_task_self(), existing);
            fprintf(stderr, "Console capture broker refused: an existing root capture service is not replaced\n");
            return EADDRINUSE;
        }
        if (lookup != BOOTSTRAP_UNKNOWN_SERVICE) {
            fprintf(stderr, "Console capture broker service lookup failed (%d)\n", lookup);
            return ENXIO;
        }
        // launchctl needs a plist, but it contains no credentials or pixels.
        // mkdtemp makes a root-only directory outside the user's home. The
        // manager removes this directory and its uniquely named job on exit.
        char directory[] = "/private/var/run/mac-vnc-console.XXXXXX";
        if (!mkdtemp(directory)) return errno;
        NSString *root = [NSString stringWithUTF8String:directory];
        NSString *label = [@"com.mac-vnc-server.console-capture." stringByAppendingString:root.lastPathComponent];
        NSString *target = [@"user/0/" stringByAppendingString:label];
        NSString *path = [root stringByAppendingPathComponent:@"capture.plist"];
        NSDictionary *job = captureJob(label, [NSString stringWithUTF8String:executable], identity.audit_id, getpid());
        NSError *error = nil;
        NSData *plist = [NSPropertyListSerialization dataWithPropertyList:job
            format:NSPropertyListXMLFormat_v1_0 options:0 error:&error];
        if (!plist || ![plist writeToFile:path options:NSDataWritingAtomic error:&error]) {
            fprintf(stderr, "Console capture broker plist failed: %s\n", error.localizedDescription.UTF8String);
            [NSFileManager.defaultManager removeItemAtPath:root error:nil];
            return EIO;
        }
        chmod(path.fileSystemRepresentation, 0600);
        result = launchctl(@[@"bootstrap", @"user/0", path]);
        if (result) {
            fprintf(stderr, "Console capture broker bootstrap failed (%d); an existing root capture service is not replaced\n", result);
        } else {
            fprintf(stderr, "Console capture broker ready: uid=0 audit=%d manager=%d\n", identity.audit_id, getpid());
            const uint8_t ready = 1;
            if (write(STDIN_FILENO, &ready, 1) != 1) result = EPIPE;
            while (!result && !brokerInterrupted) {
                if (VNCConsoleCurrent(&current) || current.uid != 0 || current.audit_id != identity.audit_id) break;
                struct pollfd fd = {STDIN_FILENO, POLLIN | POLLHUP, 0};
                int polled = poll(&fd, 1, 250);
                if (polled < 0) { if (errno == EINTR) continue; result = errno; break; }
                if (polled > 0) {
                    uint8_t byte;
                    ssize_t length = read(STDIN_FILENO, &byte, 1);
                    if (length <= 0) break; // Supervisor exited or closed the lifeline.
                }
            }
        }
        // Also try bootout after a failed bootstrap: launchd may have accepted
        // the job before its reply failed. The random label is owned only here.
        int cleanup = bootout(target);
        if (cleanup) {
            fprintf(stderr, "warning: console capture broker cleanup failed (%d): %s; retained %s for administrator cleanup\n",
                cleanup, target.UTF8String, path.fileSystemRepresentation);
            if (!result) result = cleanup;
        } else {
            [NSFileManager.defaultManager removeItemAtPath:root error:nil];
        }
        fprintf(stderr, "Console capture broker stopped: audit=%d manager=%d\n", identity.audit_id, getpid());
        return result;
    }
}
