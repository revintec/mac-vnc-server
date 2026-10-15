#include "CVNCSession.h"
#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/IOKitLib.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <bsm/audit.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <mach/mach.h>
#include <pwd.h>
#include <pthread.h>
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

static int decodeSession(CFDictionaryRef dict, VNCConsoleIdentity *out) {
    int64_t uid = -1, asid = 0;
    if (!number(dict, CFSTR("kCGSSessionUserIDKey"), &uid) ||
        !number(dict, CFSTR("kCGSSessionAuditIDKey"), &asid) || uid < 0 || uid > UINT32_MAX ||
        asid <= 0 || asid > INT32_MAX) return EINVAL;
    *out = (VNCConsoleIdentity){(uint32_t)uid, (int32_t)asid};
    return 0;
}

int VNCSessionForUser(uint32_t uid, VNCConsoleIdentity *identity) {
    if (uid == 0) {
        int error = VNCConsoleCurrent(identity);
        return error ? error : (identity->uid == 0 ? 0 : ENXIO);
    }
    CFArrayRef (*copySessions)(void) = dlsym(RTLD_DEFAULT, "CGSCopySessionList");
    if (!copySessions) return ENOTSUP;
    CFArrayRef list = copySessions();
    if (!list) return ENXIO;
    int found = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
        CFTypeRef item = CFArrayGetValueAtIndex(list, i);
        VNCConsoleIdentity candidate;
        if (CFGetTypeID(item) == CFDictionaryGetTypeID() &&
            !decodeSession(item, &candidate) && candidate.uid == uid) {
            if (found && identity->audit_id == candidate.audit_id) continue;
            *identity = candidate;
            found++;
        }
    }
    CFRelease(list);
    return found == 1 ? 0 : (found ? EEXIST : ENXIO);
}

int VNCSessionVerify(VNCConsoleIdentity identity) {
    if (identity.uid == 0) return VNCConsoleVerify(identity);
    if (getuid() != identity.uid || geteuid() != identity.uid ||
        getgid() != getegid() || issetugid()) return EPERM;
    auditinfo_addr_t audit = {0};
    if (getaudit_addr(&audit, sizeof(audit))) return errno;
    if (audit.ai_asid != identity.audit_id) return ESTALE;
    CFDictionaryRef session = CGSessionCopyCurrentDictionary();
    if (!session) return ENXIO;
    VNCConsoleIdentity actual;
    int error = decodeSession(session, &actual);
    CFRelease(session);
    return error ? error : (actual.uid == identity.uid && actual.audit_id == identity.audit_id ? 0 : ESTALE);
}

static int readConsoleOwner(uint32_t *uid) {
    struct stat info;
    if (stat("/dev/console", &info)) return errno;
    *uid = info.st_uid;
    return 0;
}

int VNCConsoleResolveIdentity(CFDictionaryRef state, uint32_t device_owner, VNCConsoleIdentity *identity) {
    if (!identity || !state || CFGetTypeID(state) != CFDictionaryGetTypeID()) return EINVAL;
    int64_t owner = -1;
    if (!number(state, CFSTR("UID"), &owner) || owner < 0 || owner > UINT32_MAX) return EINVAL;
    if (owner != device_owner) return ESTALE;
    CFTypeRef name = CFDictionaryGetValue(state, CFSTR("Name"));
    if (!name || CFGetTypeID(name) != CFStringGetTypeID() || !CFStringGetLength(name) ||
        (CFEqual(name, CFSTR("loginwindow")) && owner != 0)) return EINVAL;
    CFTypeRef list = CFDictionaryGetValue(state, CFSTR("SessionInfo"));
    if (!list || CFGetTypeID(list) != CFArrayGetTypeID()) return ENXIO;

    // The top-level owner and /dev/console describe device ownership. On Ventura
    // these can report loginwindow while the user's graphics session remains
    // OnConsole. Resolve the owner's candidate identity for status reporting;
    // this alone does NOT verify which graphical desktop is on the monitor.
    // Never choose among two audit sessions for the same owner.
    int found = 0;
    VNCConsoleIdentity candidate = {0};
    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
        CFTypeRef item = CFArrayGetValueAtIndex(list, i);
        int64_t uid = -1;
        if (CFGetTypeID(item) != CFDictionaryGetTypeID() ||
            !number(item, CFSTR("kCGSSessionUserIDKey"), &uid) || uid != owner) continue;
        VNCConsoleIdentity decoded = {0};
        if (decodeSession(item, &decoded)) return EINVAL;
        if (CFDictionaryContainsKey(item, CFSTR("kSCSecuritySessionID"))) {
            int64_t security = 0;
            if (!number(item, CFSTR("kSCSecuritySessionID"), &security) || security != decoded.audit_id) return EINVAL;
        }
        if (found && candidate.audit_id != decoded.audit_id) return EEXIST;
        candidate = decoded;
        found = 1;
    }
    if (!found) return ENXIO;
    *identity = candidate;
    return 0;
}

int VNCConsoleResolveCaptureIdentity(CFDictionaryRef state, CFArrayRef console_users,
                                    uint32_t device_owner, VNCConsoleIdentity *identity) {
    if (!identity) return EINVAL;
    VNCConsoleIdentity candidate = {0};
    int error = VNCConsoleResolveIdentity(state, device_owner, &candidate);
    if (error) return error;
    // configd's SessionInfo OnConsole flags can remain stale after a completed
    // user switch. IOConsoleUsers supplies the current graphics-console flags;
    // its selected UID/audit must still agree with configd and /dev/console.
    if (!console_users || CFGetTypeID(console_users) != CFArrayGetTypeID()) return ENXIO;
    int confirmed = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(console_users); i++) {
        CFTypeRef item = CFArrayGetValueAtIndex(console_users, i);
        if (CFGetTypeID(item) != CFDictionaryGetTypeID()) return EINVAL;
        CFTypeRef value = CFDictionaryGetValue(item, CFSTR("kCGSSessionOnConsoleKey"));
        int64_t flag = -1;
        if (value && CFGetTypeID(value) == CFBooleanGetTypeID()) flag = CFBooleanGetValue(value);
        else if (!number(item, CFSTR("kCGSSessionOnConsoleKey"), &flag)) flag = -1;
        VNCConsoleIdentity row = {0};
        if ((flag != 0 && flag != 1) || decodeSession(item, &row)) return EINVAL;
        if (CFDictionaryContainsKey(item, CFSTR("kSCSecuritySessionID"))) {
            int64_t security = 0;
            if (!number(item, CFSTR("kSCSecuritySessionID"), &security) || security != row.audit_id) return EINVAL;
        }
        if (flag == 1) {
            if (row.uid != candidate.uid || row.audit_id != candidate.audit_id) return ESTALE;
            confirmed = 1;
        } else if (row.uid == candidate.uid && row.audit_id == candidate.audit_id) {
            return ESTALE;
        }
    }
    if (!confirmed) return ESTALE;
    *identity = candidate;
    return 0;
}

static CFDictionaryRef copyConsoleState(void) {
    // Reuse the configd connection, never a cached ownership value. Serialize
    // access because capture, input and the menu can query concurrently.
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    static SCDynamicStoreRef store = NULL;
    pthread_mutex_lock(&lock);
    if (!store) store = SCDynamicStoreCreate(NULL, CFSTR("mac-vnc-server console ownership"), NULL, NULL);
    CFPropertyListRef value = store ? SCDynamicStoreCopyValue(store, CFSTR("State:/Users/ConsoleUser")) : NULL;
    if (!value && store) { CFRelease(store); store = NULL; }
    pthread_mutex_unlock(&lock);
    if (value && CFGetTypeID(value) == CFDictionaryGetTypeID()) return value;
    if (value) CFRelease(value);
    return NULL;
}

static CFArrayRef copyConsoleUsers(void) {
    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    if (!root) return NULL;
    CFTypeRef users = IORegistryEntryCreateCFProperty(root, CFSTR("IOConsoleUsers"), kCFAllocatorDefault, 0);
    IOObjectRelease(root);
    if (users && CFGetTypeID(users) == CFArrayGetTypeID()) return users;
    if (users) CFRelease(users);
    return NULL;
}

static int currentConsoleIdentity(VNCConsoleIdentity *identity, int require_graphics_agreement) {
    if (!identity) return EINVAL;
    uint32_t before = 0, after = 0;
    int error = readConsoleOwner(&before);
    if (error) return error;
    CFDictionaryRef state = copyConsoleState();
    if (!state) return ENXIO;
    VNCConsoleIdentity candidate = {0};
    if (require_graphics_agreement) {
        CFArrayRef users = copyConsoleUsers();
        error = VNCConsoleResolveCaptureIdentity(state, users, before, &candidate);
        if (users) CFRelease(users);
    } else {
        error = VNCConsoleResolveIdentity(state, before, &candidate);
    }
    CFRelease(state);
    if (error) return error;
    error = readConsoleOwner(&after);
    if (error) return error;
    if (before != after) return ESTALE;
    *identity = candidate;
    return 0;
}

int VNCConsoleCurrent(VNCConsoleIdentity *identity) { return currentConsoleIdentity(identity, 1); }
int VNCConsoleOwner(VNCConsoleIdentity *identity) { return currentConsoleIdentity(identity, 0); }

static int verifyConsoleOwner(VNCConsoleIdentity identity) {
    VNCConsoleIdentity current = {0};
    int error = VNCConsoleCurrent(&current);
    return error ? error : (current.uid == identity.uid && current.audit_id == identity.audit_id ? 0 : ESTALE);
}

int VNCConsoleVerify(VNCConsoleIdentity identity) {
    if (getuid() != identity.uid || geteuid() != identity.uid ||
        getgid() != getegid() || issetugid()) return EPERM;
    int error = verifyConsoleOwner(identity);
    if (error) return error;
    auditinfo_addr_t audit = {0};
    if (getaudit_addr(&audit, sizeof(audit))) return errno;
    if (audit.ai_asid != identity.audit_id) return ESTALE;
    CFDictionaryRef session = CGSessionCopyCurrentDictionary();
    if (!session) return ENXIO;
    VNCConsoleIdentity current = {0};
    // Check process session metadata as well as the device/graphics agreement
    // above. Audit membership alone does not verify capture/input destination.
    error = decodeSession(session, &current);
    CFRelease(session);
    if (error) return error;
    return current.uid == identity.uid && current.audit_id == identity.audit_id ? 0 : ESTALE;
}

int VNCConsolePrepare(VNCConsoleIdentity identity) {
    if (getuid() != 0 || geteuid() != 0 || identity.audit_id <= 0) return EPERM;
    // SystemConfiguration inspection does not create a WindowServer connection.
    int error = verifyConsoleOwner(identity);
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
    return verifyConsoleOwner(identity);
}

int VNCSessionPrepare(VNCConsoleIdentity identity) {
    if (identity.uid == 0) return VNCConsolePrepare(identity);
    if (getuid() != 0 || geteuid() != 0) return VNCSessionVerify(identity);
    VNCConsoleIdentity actual;
    int error = VNCSessionForUser(identity.uid, &actual);
    if (error) return error;
    if (actual.audit_id != identity.audit_id) return ESTALE;
    mach_port_name_t port = MACH_PORT_NULL;
    if (audit_session_port(identity.audit_id, &port)) return errno;
    au_asid_t joined = audit_session_join(port);
    error = errno;
    mach_port_deallocate(mach_task_self(), port);
    if (joined != identity.audit_id) return error ? error : EPERM;
    struct passwd *account = getpwuid(identity.uid);
    if (!account) return ENOENT;
    gid_t group = account->pw_gid;
    if (setenv("HOME", account->pw_dir, 1) || setenv("USER", account->pw_name, 1) ||
        setenv("LOGNAME", account->pw_name, 1) || unsetenv("TMPDIR") ||
        initgroups(getenv("USER"), group) || setgid(group) || setuid(identity.uid)) return errno;
    return getuid() == identity.uid && geteuid() == identity.uid ? 0 : EPERM;
}

int VNCSessionExecWorker(const char *executable, const char *options) {
    int flags = fcntl(STDIN_FILENO, F_GETFD);
    if (flags < 0 || fcntl(STDIN_FILENO, F_SETFD, flags & ~FD_CLOEXEC) < 0) return errno;
    char *const arguments[] = {(char *)executable, "--session-worker-attached", (char *)options, NULL};
    execv(executable, arguments);
    return errno;
}
