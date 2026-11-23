#import <Foundation/Foundation.h>
#include "VNCDisplayStream.h"
#include <CoreGraphics/CGDisplayStream.h>
#include <CoreVideo/CVPixelBuffer.h>
#include <dlfcn.h>
#include <errno.h>
#include <mach/mach_time.h>

// These are public macOS 13 APIs, deprecated in 14 and unavailable in newer
// SDK declarations. Resolve them optionally; production selects this backend
// only on Ventura, never substitutes private capture APIs on a newer OS.
typedef CGDisplayStreamRef (*CreateStream)(CGDirectDisplayID, size_t, size_t, int32_t,
    CFDictionaryRef, dispatch_queue_t, CGDisplayStreamFrameAvailableHandler);
typedef CGError (*ControlStream)(CGDisplayStreamRef);

@interface VNCDisplayStreamState : NSObject {
@public
    CGDisplayStreamRef stream;
    dispatch_queue_t queue;
    dispatch_semaphore_t finished;
    ControlStream stopStream;
    VNCDisplayFrameCallback callback;
    VNCDisplayContextRelease releaseContext;
    void *context;
    mach_timebase_info_data_t timebase;
    BOOL stopping;
}
- (void)receive:(CGDisplayStreamFrameStatus)status time:(uint64_t)time surface:(IOSurfaceRef)surface;
- (void)releaseCallback;
@end

@implementation VNCDisplayStreamState
- (void)receive:(CGDisplayStreamFrameStatus)status time:(uint64_t)time surface:(IOSurfaceRef)surface {
    // Releasing the stopped stream can release the block that retains self.
    VNCDisplayStreamState *keepAlive __attribute__((objc_precise_lifetime)) = self;
    (void)keepAlive;
    @autoreleasepool {
        @synchronized(self) {
            // Serialize the consumer with context release, including create /
            // start failure and a concurrent stop. Never use a freed context.
            if (!stopping) callback(context, status, (double)time * timebase.numer / timebase.denom / 1e9, surface);
        }
        if (status == kCGDisplayStreamFrameStatusStopped) {
            CGDisplayStreamRef retired;
            @synchronized(self) { retired = stream; stream = NULL; }
            if (retired) CFRelease(retired);
            // CoreGraphics may retain its handler beyond stop. Release the
            // consumer (and its frame storage) once no further delivery can
            // occur, independently of the native block's remaining lifetime.
            [self releaseCallback];
            dispatch_semaphore_signal(finished);
        }
    }
}
- (void)releaseCallback {
    VNCDisplayContextRelease release;
    void *retired;
    @synchronized(self) {
        stopping = YES;
        release = releaseContext; releaseContext = NULL;
        retired = context; context = NULL;
    }
    if (release) release(retired);
}
- (void)dealloc {
    if (releaseContext) releaseContext(context);
    if (stream) CFRelease(stream);
}
@end

VNCDisplayStreamRef VNCDisplayStreamCreate(CGDirectDisplayID display, uint32_t width, uint32_t height,
    int32_t fps, int32_t shows_cursor, VNCDisplayFrameCallback callback, void *context, VNCDisplayContextRelease release_context,
    int32_t *error) {
    @autoreleasepool {
        VNCDisplayStreamState *state = [[VNCDisplayStreamState alloc] init];
        if (!state) {
            if (release_context) release_context(context);
            if (error) *error = ENOMEM;
            return NULL;
        }
        state->context = context; state->callback = callback; state->releaseContext = release_context;
        int result = EINVAL;
        if (callback && width && height && (uint64_t)width * height <= 64 * 1024 * 1024 && fps > 0 && fps <= 120) {
            CreateStream create = dlsym(RTLD_DEFAULT, "CGDisplayStreamCreateWithDispatchQueue");
            ControlStream start = dlsym(RTLD_DEFAULT, "CGDisplayStreamStart");
            state->stopStream = dlsym(RTLD_DEFAULT, "CGDisplayStreamStop");
            const CFStringRef *cursor = dlsym(RTLD_DEFAULT, "kCGDisplayStreamShowCursor");
            const CFStringRef *interval = dlsym(RTLD_DEFAULT, "kCGDisplayStreamMinimumFrameTime");
            const CFStringRef *depth = dlsym(RTLD_DEFAULT, "kCGDisplayStreamQueueDepth");
            result = ENOTSUP;
            if (create && start && state->stopStream && cursor && interval && depth) {
                state->queue = dispatch_queue_create("mac-vnc.console-display", DISPATCH_QUEUE_SERIAL);
                state->finished = dispatch_semaphore_create(0);
                mach_timebase_info(&state->timebase);
                NSDictionary *properties = @{(__bridge NSString *)*cursor: @(shows_cursor != 0),
                    (__bridge NSString *)*interval: @(1.0 / fps), (__bridge NSString *)*depth: @3};
                state->stream = create(display, width, height, kCVPixelFormatType_32BGRA,
                    (__bridge CFDictionaryRef)properties, state->queue,
                    ^(CGDisplayStreamFrameStatus status, uint64_t time, IOSurfaceRef surface, CGDisplayStreamUpdateRef update) {
                        [state receive:status time:time surface:surface];
                    });
                result = state->stream ? start(state->stream) : VNCDisplayStreamCreateReturnedNull;
            }
        }
        if (error) *error = result;
        if (!result) return (VNCDisplayStreamRef)CFBridgingRetain(state);
        // No successful Start: no stream delivery is pending. Break the block's
        // reference to state before releasing the caller's ownership.
        CGDisplayStreamRef retired;
        @synchronized(state) { retired = state->stream; state->stream = NULL; }
        if (retired) CFRelease(retired);
        [state releaseCallback];
        return NULL;
    }
}

int32_t VNCDisplayStreamDestroy(VNCDisplayStreamRef handle) {
    if (!handle) return 0;
    VNCDisplayStreamState *state = CFBridgingRelease(handle);
    CGDisplayStreamRef stream;
    @synchronized(state) {
        state->stopping = YES;
        stream = state->stream;
        if (stream) CFRetain(stream);
    }
    // All prior deliveries have finished under the same lock. Future native
    // callbacks observe stopping, so consumer storage can be released even
    // if CoreGraphics delays (or never emits) its stopped callback.
    [state releaseCallback];
    int32_t result = 0;
    if (stream) {
        result = state->stopStream(stream);
        CFRelease(stream);
        if (!result && dispatch_semaphore_wait(state->finished, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)))
            result = ETIMEDOUT;
    }
    return result;
}
