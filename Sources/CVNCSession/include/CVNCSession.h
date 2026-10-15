#pragma once
#include <stdint.h>
#include <stddef.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CGEvent.h>
#include <IOKit/hidsystem/IOLLEvent.h>

typedef struct {
    uint32_t uid;
    int32_t audit_id;
} VNCConsoleIdentity;

// Return zero on success. No function changes which session owns the monitor.
int VNCConsoleCurrent(VNCConsoleIdentity *identity);
// Device-owner candidate for status only, even when graphics flags disagree.
// Do not use this to authorize capture/input or select a console worker.
int VNCConsoleOwner(VNCConsoleIdentity *identity);
// Resolve a copied State:/Users/ConsoleUser snapshot against /dev/console.
// Graphics OnConsole flags can disagree during Fast User Switching on Ventura.
// Ambiguous/missing audit identities or owner disagreement fail explicitly.
int VNCConsoleResolveIdentity(CFDictionaryRef state, uint32_t device_owner, VNCConsoleIdentity *identity);
// Additionally require consistent OnConsole flags before routing capture/input.
int VNCConsoleResolveCaptureIdentity(CFDictionaryRef state, uint32_t device_owner, VNCConsoleIdentity *identity);
// Prepare audit membership and credentials, without opening a graphics connection.
// Follow with exec before calling Verify or any AppKit/ScreenCaptureKit API.
int VNCConsolePrepare(VNCConsoleIdentity identity);
int VNCConsoleVerify(VNCConsoleIdentity identity);
// Account-routed workers may remain attached while another session owns console.
int VNCSessionForUser(uint32_t uid, VNCConsoleIdentity *identity);
int VNCSessionVerify(VNCConsoleIdentity identity);
int VNCSessionPrepare(VNCConsoleIdentity identity);
int VNCSessionExecWorker(const char *executable, const char *options);
// One marker byte and exactly one SCM_RIGHTS descriptor. Returns errno.
int VNCSessionSendDescriptor(int transport, int descriptor);
int VNCSessionReceiveDescriptor(int transport, int *descriptor);
// Root listener owns the temporary launchd job and lock in process. Destroy
// attempts bounded cleanup; interrupted/failed cleanup is retried on startup.
typedef struct VNCConsoleCaptureService *VNCConsoleCaptureServiceRef;
// Retry abandoned capture-service cleanup when the listener starts.
int VNCConsoleCaptureServiceRecover(void);
VNCConsoleCaptureServiceRef VNCConsoleCaptureServiceCreate(VNCConsoleIdentity identity, const char *executable, int32_t *error);
void VNCConsoleCaptureServiceDestroy(VNCConsoleCaptureServiceRef service);
int VNCConsoleExecCaptureService(VNCConsoleIdentity identity, int32_t owner_pid);

// Only the root loginwindow worker uses physical-console HID input. User
// workers continue to post CGEvents to their own graphics session.
typedef struct VNCConsoleInput *VNCConsoleInputRef;
typedef struct {
    uint32_t type;
    IOGPoint location;
    NXEventData data;
    uint32_t flags;
    uint32_t options;
} VNCConsoleInputEvent;
// Converts using the session's keyboard layout when Unicode is absent. Does
// not open devices, check permissions or send input.
int VNCConsoleEncodeInput(CGEventRef event, VNCConsoleInputEvent *output);
VNCConsoleInputRef VNCConsoleInputCreate(VNCConsoleIdentity identity, int32_t *error);
// Revalidates the console identity immediately before each physical event.
int32_t VNCConsoleInputPost(VNCConsoleInputRef input, CGEventRef event);
void VNCConsoleInputDestroy(VNCConsoleInputRef input);
