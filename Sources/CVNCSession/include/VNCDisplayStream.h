#pragma once
#include <CoreGraphics/CGDirectDisplay.h>
#include <IOSurface/IOSurfaceRef.h>
#include <stdint.h>

typedef struct VNCDisplayStream *VNCDisplayStreamRef;
enum { VNCDisplayFrameComplete = 0, VNCDisplayFrameIdle = 1,
       VNCDisplayFrameBlank = 2, VNCDisplayFrameStopped = 3 };
enum { VNCDisplayStreamCreateReturnedNull = -1 };
// Surface is borrowed only for the duration of the callback. Copy pixels before
// returning; retaining a CVPixelBuffer wrapper alone does not reserve its pixels.
typedef void (*VNCDisplayFrameCallback)(void *context, int32_t status, double seconds, IOSurfaceRef surface);
typedef void (*VNCDisplayContextRelease)(void *context);
// Takes ownership of context on both success and failure via release_context.
VNCDisplayStreamRef VNCDisplayStreamCreate(CGDirectDisplayID display, uint32_t width, uint32_t height,
    int32_t fps, int32_t shows_cursor, VNCDisplayFrameCallback callback, void *context, VNCDisplayContextRelease release_context,
    int32_t *error);
// Consumes the handle. Stops callbacks and waits up to two seconds for the native
// stopped notification. Callback delivery is disabled before its context is
// released; native state survives a timeout until its stopped notification.
int32_t VNCDisplayStreamDestroy(VNCDisplayStreamRef stream);
