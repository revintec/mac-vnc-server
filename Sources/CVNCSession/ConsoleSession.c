#include "CVNCSession.h"
#include <CoreGraphics/CoreGraphics.h>
#include <bsm/audit.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <mach/mach.h>
#include <pwd.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

extern int audit_session_port(au_asid_t, mach_port_name_t *);
extern au_asid_t audit_session_join(mach_port_name_t);

static int number(CFDictionaryRef dict, CFStringRef key, int64_t *out) {
    CFTypeRef value = CFDictionaryGetValue(dict, key);
    return value && CFGetTypeID(value) == CFNumberGetTypeID() &&
        CFNumberGetValue(value, kCFNumberSInt64Type, out);
}

static int decode(CFDictionaryRef dict, VNCConsoleIdentity *out) {
    int64_t uid = -1, asid = 0;
    CFTypeRef on = CFDictionaryGetValue(dict, CFSTR("kCGSSessionOnConsoleKey"));
    int64_t onNumber = 0;
    int onConsole = on && ((CFGetTypeID(on) == CFBooleanGetTypeID() && CFBooleanGetValue(on)) ||
        (number(dict, CFSTR("kCGSSessionOnConsoleKey"), &onNumber) && onNumber == 1));
    if (!onConsole || !number(dict, CFSTR("kCGSSessionUserIDKey"), &uid) ||
        !number(dict, CFSTR("kCGSSessionAuditIDKey"), &asid) || uid < 0 || uid > UINT32_MAX ||
        asid <= 0 || asid > INT32_MAX) return EINVAL;
    *out = (VNCConsoleIdentity){(uint32_t)uid, (int32_t)asid};
    return 0;
}

static int consoleOwner(uint32_t uid) {
    struct stat info;
    if (stat("/dev/console", &info)) return errno;
    return info.st_uid == uid ? 0 : ESTALE;
}

int VNCConsoleCurrent(VNCConsoleIdentity *identity) {
    // Read-only private query, resolved at runtime so unsupported macOS builds
    // fail explicitly. It neither creates nor switches a graphics session.
    CFArrayRef (*copySessions)(void) = dlsym(RTLD_DEFAULT, "CGSCopySessionList");
    if (!copySessions) return ENOTSUP;
    CFArrayRef list = copySessions();
    if (!list) return ENXIO;
    int found = 0;
    VNCConsoleIdentity candidate = {0};
    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
        CFTypeRef item = CFArrayGetValueAtIndex(list, i);
        if (CFGetTypeID(item) == CFDictionaryGetTypeID() && !decode(item, &candidate)) {
            *identity = candidate;
            found++;
        }
    }
    CFRelease(list);
    if (found != 1) return ENXIO;
    return consoleOwner(identity->uid);
}

int VNCConsoleVerify(VNCConsoleIdentity identity) {
    if (getuid() != identity.uid || geteuid() != identity.uid ||
        getgid() != getegid() || issetugid()) return EPERM;
    int error = consoleOwner(identity.uid);
    if (error) return error;
    auditinfo_addr_t audit = {0};
    if (getaudit_addr(&audit, sizeof(audit))) return errno;
    if (audit.ai_asid != identity.audit_id) return ESTALE;
    CFDictionaryRef session = CGSessionCopyCurrentDictionary();
    if (!session) return ENXIO;
    VNCConsoleIdentity current = {0};
    error = decode(session, &current);
    CFRelease(session);
    if (error) return error;
    return current.uid == identity.uid && current.audit_id == identity.audit_id ? 0 : ESTALE;
}

int VNCConsolePrepare(VNCConsoleIdentity identity) {
    if (getuid() != 0 || geteuid() != 0 || identity.audit_id <= 0) return EPERM;
    int error = consoleOwner(identity.uid);
    if (error) return error;
    mach_port_name_t port = MACH_PORT_NULL;
    if (audit_session_port(identity.audit_id, &port)) return errno;
    au_asid_t joined = audit_session_join(port);
    error = errno;
    mach_port_deallocate(mach_task_self(), port);
    if (joined != identity.audit_id) return error ? error : EPERM;
    struct passwd *account = getpwuid(identity.uid);
    if (!account) return ENOENT;
    // This stage must not create a WindowServer connection. Credential changes
    // taint the process (issetugid), so capture runs only after a fresh exec.
    gid_t group = account->pw_gid;
    if (setenv("HOME", account->pw_dir, 1) || setenv("USER", account->pw_name, 1) ||
        setenv("LOGNAME", account->pw_name, 1) || unsetenv("TMPDIR")) return errno;
    // Match the working loginwindow probe: an already-root worker does not
    // need its group list/IDs rewritten. User workers permanently drop root.
    if (identity.uid != 0 &&
        (initgroups(getenv("USER"), group) || setgid(group) || setuid(identity.uid))) return errno;
    if (getuid() != identity.uid || geteuid() != identity.uid || getgid() != getegid()) return EPERM;
    auditinfo_addr_t audit = {0};
    if (getaudit_addr(&audit, sizeof(audit))) return errno;
    if (audit.ai_asid != identity.audit_id) return ESTALE;
    return consoleOwner(identity.uid);
}

int VNCConsoleExecWorker(const char *executable, const char *options) {
    // The supervisor maps the anonymous socket to stdin. Preserve it through
    // the second exec; all other worker IPC descriptors are close-on-exec.
    int flags = fcntl(STDIN_FILENO, F_GETFD);
    if (flags < 0 || fcntl(STDIN_FILENO, F_SETFD, flags & ~FD_CLOEXEC) < 0) return errno;
    char *const arguments[] = {(char *)executable, "--console-worker-attached", (char *)options, NULL};
    execv(executable, arguments);
    return errno;
}
