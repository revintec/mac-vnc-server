#include "CVNCSession.h"
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <errno.h>

// The SDK marks CGDisplayStream obsolete, but the exported implementation still
// delivers frames on Tahoe. This is not a guarantee of direct WindowServer
// capture: SkyLight can proxy the call through ScreenCaptureKit, depending on
// the caller's TCC authorization and private entitlements. A failed request
// must not substitute an unrelated user's display.
typedef CFTypeRef (*CreateStream)(CGDirectDisplayID, size_t, size_t, int32_t,
                                 CFDictionaryRef, dispatch_queue_t,
                                 void (^)(CGDisplayStreamFrameStatus, uint64_t,
                                          IOSurfaceRef, CGDisplayStreamUpdateRef));
typedef CGError (*StreamOperation)(CFTypeRef);

@interface VNCConsoleFrameTarget : NSObject {
@public
    VNCConsoleCaptureHandler handler;
    void *context;
}
@end
@implementation VNCConsoleFrameTarget
@end

struct VNCConsoleCapture {
    CFTypeRef stream;
    StreamOperation stop;
    dispatch_queue_t queue;
    VNCConsoleFrameTarget *target;
};

VNCConsoleCaptureRef VNCConsoleCaptureStart(uint32_t display, size_t width, size_t height,
                                          int32_t fps, VNCConsoleCaptureHandler handler,
                                          void *context, VNCConsoleCaptureError *error) {
    if (!error) return NULL;
    *error = (VNCConsoleCaptureError){VNCConsoleCaptureStageArguments, EINVAL};
    if (!width || !height || fps < 1 || fps > 120 || !handler) return NULL;
    CreateStream create = dlsym(RTLD_DEFAULT, "CGDisplayStreamCreateWithDispatchQueue");
    StreamOperation start = dlsym(RTLD_DEFAULT, "CGDisplayStreamStart");
    StreamOperation stop = dlsym(RTLD_DEFAULT, "CGDisplayStreamStop");
    CFStringRef *cursor = dlsym(RTLD_DEFAULT, "kCGDisplayStreamShowCursor");
    CFStringRef *interval = dlsym(RTLD_DEFAULT, "kCGDisplayStreamMinimumFrameTime");
    CFStringRef *depth = dlsym(RTLD_DEFAULT, "kCGDisplayStreamQueueDepth");
    *error = (VNCConsoleCaptureError){VNCConsoleCaptureStageSymbols, ENOTSUP};
    if (!create || !start || !stop || !cursor || !interval || !depth) return NULL;
    VNCConsoleCaptureRef capture = calloc(1, sizeof(*capture));
    if (!capture) {
        *error = (VNCConsoleCaptureError){VNCConsoleCaptureStageAllocation, ENOMEM};
        return NULL;
    }
    capture->stop = stop;
    capture->queue = dispatch_queue_create("mac-vnc-server.console-display", DISPATCH_QUEUE_SERIAL);
    VNCConsoleFrameTarget *target = [VNCConsoleFrameTarget new];
    target->handler = handler;
    target->context = context;
    capture->target = target;
    NSDictionary *properties = @{(__bridge id)*cursor: @YES, (__bridge id)*interval: @(1.0 / fps), (__bridge id)*depth: @3};
    capture->stream = create(display, width, height, 'BGRA', (__bridge CFDictionaryRef)properties,
        capture->queue, ^(CGDisplayStreamFrameStatus status, uint64_t time,
                          IOSurfaceRef surface, CGDisplayStreamUpdateRef update) {
            if (target->handler) target->handler(target->context, (int32_t)status, surface);
        });
    if (!capture->stream) {
        // The factory has no error out-parameter. Inventing ENXIO here hid the
        // failing stage and was mistaken for a CoreGraphics status code.
        *error = (VNCConsoleCaptureError){VNCConsoleCaptureStageCreate, 0};
        VNCConsoleCaptureStop(capture);
        return NULL;
    }
    CGError startError = start(capture->stream);
    if (startError) {
        *error = (VNCConsoleCaptureError){VNCConsoleCaptureStageStart, startError};
        VNCConsoleCaptureStop(capture);
        return NULL;
    }
    *error = (VNCConsoleCaptureError){VNCConsoleCaptureStageNone, 0};
    return capture;
}

void VNCConsoleCaptureStop(VNCConsoleCaptureRef capture) {
    if (!capture) return;
    VNCConsoleFrameTarget *target = capture->target;
    // All callbacks use this serial queue. Disable and drain them before the
    // Swift owner can release context. Later callbacks retain the target but
    // can no longer dereference that context.
    dispatch_sync(capture->queue, ^{ target->handler = NULL; target->context = NULL; });
    if (capture->stream) {
        capture->stop(capture->stream);
        CFRelease(capture->stream);
    }
    capture->target = nil;
    capture->queue = nil;
    free(capture);
}
