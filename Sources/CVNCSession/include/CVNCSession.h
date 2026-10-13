#pragma once
#include <stdint.h>
#include <stddef.h>
#include <IOSurface/IOSurface.h>
#include <CoreGraphics/CGEvent.h>
#include <IOKit/hidsystem/IOLLEvent.h>

typedef struct {
    uint32_t uid;
    int32_t audit_id;
} VNCConsoleIdentity;

// Return zero on success. No function changes which session owns the monitor.
int VNCConsoleCurrent(VNCConsoleIdentity *identity);
// Prepare audit membership and credentials, without opening a graphics connection.
// Follow with exec before calling Verify or any AppKit/ScreenCaptureKit API.
int VNCConsolePrepare(VNCConsoleIdentity identity);
// Returns errno only on failure; keeps PID, audit/bootstrap and stdin IPC on success.
int VNCConsoleExecWorker(const char *executable, const char *options);
int VNCConsoleVerify(VNCConsoleIdentity identity);
// Internal root-only helpers. The manager requires an inherited anonymous Unix
// socket on stdin and removes its temporary launchd job when that socket closes.
int VNCConsoleRunCaptureBroker(VNCConsoleIdentity identity, const char *executable);
int VNCConsoleExecCaptureService(VNCConsoleIdentity identity, int32_t manager_pid);

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

typedef struct VNCConsoleCapture *VNCConsoleCaptureRef;
typedef enum {
    VNCConsoleCaptureStageNone = 0,
    VNCConsoleCaptureStageArguments,
    VNCConsoleCaptureStageSymbols,
    VNCConsoleCaptureStageAllocation,
    VNCConsoleCaptureStageCreate,
    VNCConsoleCaptureStageStart
} VNCConsoleCaptureStage;
typedef struct {
    VNCConsoleCaptureStage stage;
    // errno for setup failures, CGError for Start. Create supplies no error code.
    int32_t code;
} VNCConsoleCaptureError;
// The surface is valid only during the callback; copy before returning.
typedef void (*VNCConsoleCaptureHandler)(void *context, int32_t status, IOSurfaceRef surface);
VNCConsoleCaptureRef VNCConsoleCaptureStart(uint32_t display, size_t width, size_t height,
                                          int32_t fps, VNCConsoleCaptureHandler handler,
                                          void *context, VNCConsoleCaptureError *error);
// Drains callbacks before returning. Must not be called from a frame callback.
void VNCConsoleCaptureStop(VNCConsoleCaptureRef capture);
