// Opt-in interoperability probe, used by MultiClientTests. No window is shown;
// the test server supplies synthetic pixels and a private test pasteboard.
// Build: xcrun clang -fobjc-arc -framework AppKit scripts/probe-native-screen-sharing.m -o /tmp/mac-vnc-native-drag-probe
// Run tests with MAC_VNC_NATIVE_PROBE=/tmp/mac-vnc-native-drag-probe.
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>

typedef struct { NSInteger width, height; } NativeFramebufferSize;
@interface ProbeFramebuffer : NSObject
- (NativeFramebufferSize)size;
- (void)lock;
- (void)unlock;
- (CGImageRef)newCGImage CF_RETURNS_RETAINED;
@end

@interface NSObject (NativeScreenSharingProbe)
+ (id)defaultOptions;
+ (NSDictionary *)optionsFromURL:(NSURL *)url;
+ (id)vncAuthenticationCredentialsWithPassword:(NSString *)password;
+ (id)diffieHellmanCredentialsWithUsername:(NSString *)username withPassword:(NSString *)password label:(NSString *)label;
- (void)applyURLOptions:(NSDictionary *)options;
- (NSInteger)minimumEncryptionLevel;
- (NSInteger)controlType;
- (void)setControlType:(NSInteger)mode;
- (NSInteger)controlMode;
- (id)connectionOptions;
+ (id)keyboardEventWithKeyCode:(NSUInteger)keyCode withState:(int)state withEvent:(id)event;
- (void)sendEvent:(id)event;
- (void)connectToURL:(NSString *)url withPreferredCredentials:(id)credentials options:(id)options;
- (void)setShouldWarnUserForUnencryptedLegacyVNC:(BOOL)value;
- (void)setAllowsFileTransferToRemote:(BOOL)value;
- (void)setAllowsFileTransferFromRemote:(BOOL)value;
- (BOOL)isConnected;
- (BOOL)isLegacyVNC;
- (BOOL)supportsFileTransfer;
- (BOOL)supportsControlMode;
- (BOOL)sessionAllowsControl;
- (BOOL)isControlling;
- (NSInteger)displayInfo2Version;
- (BOOL)hasReliableVirtualDisplayInfo;
- (BOOL)isOnConsole;
- (BOOL)isUsingVirtualDisplay;
- (void)setShouldScaleScreen:(BOOL)value;
- (void)setControlMode:(NSInteger)mode;
- (id)session;
- (void)setScalingFactor:(double)factor forced:(BOOL)forced;
- (double)scalingFactor;
- (ProbeFramebuffer *)frameBuffer;
- (id)frameBufferView;
- (BOOL)allowsDragAndDropFileCopyToRemote;
- (BOOL)allowsDragAndDropFileCopyFromRemote;
@end

@interface ProbeSessionView : NSView
- (void)setDelegate:(id)delegate;
@end

// Screen Sharing 3.0 saves the view's mode when "finished connecting" resizes
// its window, then reads that file in sessionIsReady. Model only that ordering
// with in-memory state; no persistent preferences or files are changed.
@interface ProbeStartupDelegate : NSObject
@property(nonatomic, weak) id view;
@property(nonatomic) BOOL ready;
@property(nonatomic) BOOL finished;
@property(nonatomic) BOOL finishedBeforeReady;
@property(nonatomic) BOOL restoreSavedMode;
@property(nonatomic) NSInteger savedMode;
@end

@implementation ProbeStartupDelegate
- (void)sessionIsReady {
    if (self.restoreSavedMode) {
        [[[self.view session] connectionOptions] setControlType:self.savedMode];
    }
    self.ready = YES;
}
- (void)sessionDidFinishConnecting {
    self.finishedBeforeReady |= !self.ready;
    self.finished = YES;
    if (self.restoreSavedMode) self.savedMode = [self.view controlMode];
}
@end

static BOOL readTestPixel(id view, int x, int y, uint8_t pixel[4]) {
    ProbeFramebuffer *buffer = [[view session] frameBuffer];
    if (!buffer) return NO;
    [buffer lock];
    CGImageRef image = [buffer newCGImage];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixel, 1, 1, 8, 4, colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGImageRef sample = image ? CGImageCreateWithImageInRect(image, CGRectMake(x, y, 1, 1)) : NULL;
    if (sample && context) CGContextDrawImage(context, CGRectMake(0, 0, 1, 1), sample);
    if (sample) CGImageRelease(sample);
    if (context) CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    if (image) CGImageRelease(image);
    [buffer unlock];
    return YES;
}

static int testPixelPhase(id view) {
    uint8_t pixel[4] = {0};
    // Stay inside the animated 64x64 patch, away from the test cursor at 0,0.
    if (!readTestPixel(view, 32, 32, pixel)) return -1;
    if (abs((int)pixel[0] - 192) >= 8 || abs((int)pixel[1] - 128) >= 8) return -1;
    if (abs((int)pixel[2] - 64) < 8) return 0;
    if (abs((int)pixel[2] - 160) < 8) return 1;
    return -1;
}

static BOOL hasTestPixels(id view) { return testPixelPhase(view) >= 0; }

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 4) return 2;
        BOOL fileTransfer = atoi(argv[2]) != 0;
        NSString *initialMode = [NSString stringWithUTF8String:argv[3]];
        if (!dlopen("/System/Library/PrivateFrameworks/ScreenSharing.framework/Versions/A/ScreenSharing", RTLD_LAZY | RTLD_LOCAL)) return 2;
        Class viewClass = NSClassFromString(@"SSSessionView");
        if (!viewClass) return 2;
        BOOL expectClientCursor = getenv("MAC_VNC_NATIVE_CURSOR") != NULL;
        BOOL restoreObserve = [initialMode isEqualToString:@"restore-observe"];
        BOOL restoreSavedControl = [initialMode isEqualToString:@"restore-saved-control"];
        BOOL restoreSavedObserve = [initialMode isEqualToString:@"restore-saved-observe"];
        __block BOOL restoredObserveBeforePixels = NO;
        __block NSUInteger modeCallbacks = 0;
        __block BOOL restored = NO;
        SEL selector = NSSelectorFromString(@"ssSession:delegateControlModeSet:");
        Method callback = class_getInstanceMethod(viewClass, selector);
        if (!callback) return 2;
        void (*original)(id, SEL, id, NSInteger) = (void *)method_getImplementation(callback);
        method_setImplementation(callback, imp_implementationWithBlock(^(id self, id session, NSInteger mode) {
            ++modeCallbacks;
            original(self, selector, session, mode);
            if (restoreObserve && mode == 1 && !restored) {
                // Model the app restoring Observe during startup, without
                // changing a saved preference or posting any real input.
                restored = YES;
                restoredObserveBeforePixels = !hasTestPixels(self);
                [self setControlMode:0];
            }
        }));
        // Fail instead of opening a modal warning in this hidden probe. This
        // also catches permission notifications delivered in the wrong order.
        Method warning = class_getInstanceMethod(viewClass,
            NSSelectorFromString(@"showWarningWithTitle:andMessage:withStatus:"));
        if (!warning) return 2;
        method_setImplementation(warning, imp_implementationWithBlock(^(id self, id title, id message, NSInteger status) {
            fprintf(stderr, "Screen Sharing warning: %s / %s status=%ld\n",
                [title description].UTF8String, [message description].UTF8String, (long)status);
            fflush(stdout);
            _exit(3);
        }));
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        // Match Screen Sharing 3.0's registerAppDefaults. The bare framework
        // defaults to 0, which would falsely suggest plaintext compatibility.
        // Registration is process-local and does not write client preferences.
        [NSUserDefaults.standardUserDefaults registerDefaults:@{@"encryptionLevel": @2}];
        // Test a saved Observe preference separately from the actual default.
        // This override exists only in the disposable probe process.
        if ([initialMode isEqualToString:@"saved-observe"]) {
            [NSUserDefaults.standardUserDefaults setVolatileDomain:@{@"controlType": @0}
                forName:NSArgumentDomain];
        }
        id options = [NSClassFromString(@"SSConnectionOptions") defaultOptions];
        [options applyURLOptions:@{@"sharePasteboard": @"0", @"disableReconnect": @"1"}];
        if (![initialMode isEqualToString:@"default"] && ![initialMode isEqualToString:@"saved-observe"]) {
            [options applyURLOptions:@{@"control": ([initialMode isEqualToString:@"control"] || restoreObserve
                || restoreSavedControl || restoreSavedObserve) ? @"1" : @"0"}];
        }
        // All interoperability tests use plain URLs and the app's encryption
        // default. Reject query overrides rather than silently testing a workaround.
        NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:argv[1]]];
        if (![url.scheme isEqualToString:@"vnc"] || url.query != nil || url.fragment != nil) return 2;
        [options applyURLOptions:[NSClassFromString(@"SSAddress") optionsFromURL:url]];
        printf("minimumEncryptionLevel=%ld plainURL=1\n", (long)[options minimumEncryptionLevel]);
        if ([options minimumEncryptionLevel] != 2) return 2;
        BOOL expectedControl = !restoreObserve && !restoreSavedObserve && [options controlType] != 0;
        id view = [[viewClass alloc] initWithFrame:NSMakeRect(0, 0, 640, 480)];
        ProbeStartupDelegate *startup = [ProbeStartupDelegate new];
        startup.view = view;
        startup.restoreSavedMode = restoreSavedControl || restoreSavedObserve;
        startup.savedMode = restoreSavedControl ? 1 : 0;
        [(ProbeSessionView *)view setDelegate:startup];
        [view setShouldWarnUserForUnencryptedLegacyVNC:NO];
        [view setAllowsFileTransferToRemote:YES];
        [view setAllowsFileTransferFromRemote:YES];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 480)
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        window.contentView = view;
        id credentials = [NSClassFromString(@"SSPasswordCredentials") vncAuthenticationCredentialsWithPassword:@"testpass"];
        id appleCredentials = [NSClassFromString(@"SSUsernamePasswordCredentials")
            diffieHellmanCredentialsWithUsername:@"test" withPassword:@"testpass" label:nil];
        [view connectToURL:[NSString stringWithUTF8String:argv[1]] withPreferredCredentials:@[appleCredentials, credentials] options:options];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:4];
        while (deadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        BOOL initiallyControlling = [view isControlling];
        BOOL controlSupported = [view supportsControlMode];
        BOOL initialPixels = hasTestPixels(view);
        BOOL passed = [view isConnected] && controlSupported && [view sessionAllowsControl]
            && initiallyControlling == expectedControl && initialPixels && modeCallbacks <= 2
            && startup.ready && startup.finished && !startup.finishedBeforeReady;
        printf("readyBeforeFinished=%d restoredModeMatches=%d\n",
            startup.ready && startup.finished && !startup.finishedBeforeReady,
            !startup.restoreSavedMode || startup.savedMode == expectedControl);
        printf("modeMatchesSelection=%d startupModeCallbacks=%lu expectedControl=%d\n",
            initiallyControlling == expectedControl, (unsigned long)modeCallbacks, expectedControl);
        if (restoreObserve) {
            printf("restoredObserveBeforePixels=%d\n", restoredObserveBeforePixels);
            passed = passed && restoredObserveBeforePixels;
        }
        printf("initialPixels=%d\n", initialPixels);
        if (expectClientCursor) {
            // RichCursor is drawn by the viewer into its framebuffer. The
            // server's desktop has no red pixels; only the cursor is red.
            uint8_t pixel[4] = {0};
            BOOL received = readTestPixel(view, 0, 0, pixel)
                && pixel[0] == 255 && pixel[1] == 0 && pixel[2] == 0;
            printf("clientCursorReceived=%d\n", received);
            passed = passed && received;
        }
        if (fileTransfer) {
            id session = [view session];
            printf("displayLayoutVersion=%ld reliableDisplayState=%d onConsole=%d virtualDisplay=%d\n",
                (long)[session displayInfo2Version], [session hasReliableVirtualDisplayInfo],
                [session isOnConsole], [session isUsingVirtualDisplay]);
            passed = passed && [session displayInfo2Version] == 5
                && [session hasReliableVirtualDisplayInfo] && [session isOnConsole]
                && ![session isUsingVirtualDisplay];
        }
        printf("controlSupported=%d controlAllowed=%d initiallyControlling=%d\n",
            controlSupported, [view sessionAllowsControl], initiallyControlling);
        // Stay connected through many changing frames. A one-frame success or
        // a mode that happens to be Control when sampled is insufficient.
        NSUInteger callbacksBefore = modeCallbacks;
        int previousPhase = testPixelPhase(view), pixelChanges = 0;
        BOOL stableMode = YES, validPixels = YES;
        const char *streamDuration = getenv("MAC_VNC_NATIVE_STREAM_SECONDS");
        int streamSeconds = streamDuration ? atoi(streamDuration) : 6;
        if (streamSeconds < 6 || streamSeconds > 20) return 2;
        NSDate *streamDeadline = [NSDate dateWithTimeIntervalSinceNow:streamSeconds];
        while (streamDeadline.timeIntervalSinceNow > 0 && [view isConnected]) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            int phase = testPixelPhase(view);
            if (phase >= 0 && previousPhase >= 0 && phase != previousPhase) ++pixelChanges;
            previousPhase = phase;
            validPixels = validPixels && phase >= 0;
            stableMode = stableMode && [view isControlling] == expectedControl
                && [view supportsControlMode] && [view sessionAllowsControl];
        }
        BOOL streaming = [view isConnected] && validPixels && pixelChanges >= 6;
        printf("stableMode=%d unsolicitedModeCallbacks=%lu streamingPixels=%d pixelChanges=%d\n",
            stableMode, (unsigned long)(modeCallbacks - callbacksBefore), streaming, pixelChanges);
        passed = passed && stableMode && modeCallbacks == callbacksBefore && streaming;
        for (int cycle = 0; cycle < 2; ++cycle) {
            NSUInteger beforeSwitch = modeCallbacks;
            [view setControlMode:0];
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
            BOOL observing = ![view isControlling];
            BOOL canResumeControl = [view supportsControlMode] && [view sessionAllowsControl];
            // Respect the same permission gate as the toolbar/menu. Calling
            // setControlMode directly can bypass a disabled Control command.
            if (canResumeControl) [view setControlMode:1];
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
            BOOL resumedControl = [view isControlling];
            printf("observing=%d canResumeControl=%d resumedControl=%d\n",
                observing, canResumeControl, resumedControl);
            passed = passed && observing && canResumeControl && resumedControl
                && modeCallbacks - beforeSwitch <= 2;
        }
        // Feed only this isolated session's sender queue. Its server has mock
        // input; no NSEvent/CGEvent is posted to either desktop.
        Class keyboardClass = NSClassFromString(@"SSKeyboardEvent");
        if (!keyboardClass) return 2;
        [[view session] sendEvent:[keyboardClass keyboardEventWithKeyCode:0 withState:0 withEvent:nil]];
        [[view session] sendEvent:[keyboardClass keyboardEventWithKeyCode:0 withState:1 withEvent:nil]];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
        NSUInteger callbacksBeforeScaling = modeCallbacks;
        if (fileTransfer && [view isConnected]) {
            // Exercise SetServerScaling even when window sizing does not send
            // it automatically. Check the native decoder's actual pixel size.
            for (NSNumber *factor in @[@0.5, @0.75, @1.0, @1.0]) {
                // Keep the view's policy consistent with the requested factor.
                // At 100%, disable fit-to-window: the host's usable screen can
                // be smaller than this synthetic desktop, even for a hidden window.
                [view setShouldScaleScreen:factor.doubleValue < 1.0];
                [window setContentSize:NSMakeSize(1728 * factor.doubleValue, 1118 * factor.doubleValue)];
                [[view session] setScalingFactor:factor.doubleValue forced:YES];
                NativeFramebufferSize size = {0, 0};
                NSDate *scaleDeadline = [NSDate dateWithTimeIntervalSinceNow:5];
                NSDate *pixelsStableSince = nil;
                do {
                    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
                    size = [[[view session] frameBuffer] size];
                    if (size.width == lround(1728 * factor.doubleValue)
                        && size.height == lround(1118 * factor.doubleValue) && hasTestPixels(view)) {
                        if (!pixelsStableSince) pixelsStableSince = [NSDate date];
                    } else {
                        pixelsStableSince = nil;
                    }
                    // A repeated factor starts at the expected dimensions and
                    // pixels. Allow the asynchronous layout reset to run before
                    // accepting them, or this test can miss a later black frame.
                } while ([view isConnected] && scaleDeadline.timeIntervalSinceNow > 0
                    && (!pixelsStableSince || -pixelsStableSince.timeIntervalSinceNow < 0.35));
                printf("scaling=%.2f framebuffer=%ldx%ld actualFactor=%.2f\n", factor.doubleValue, size.width, size.height,
                    [[view session] scalingFactor]);
                passed = passed && [view isConnected]
                    && size.width == lround(1728 * factor.doubleValue)
                    && size.height == lround(1118 * factor.doubleValue) && hasTestPixels(view);
                printf("scaledPixels=%d\n", hasTestPixels(view));
            }
        }
        passed = passed && modeCallbacks == callbacksBeforeScaling && [view isControlling];
        id frame = [view frameBufferView];
        NSArray *types = [frame registeredDraggedTypes];
        passed = passed && [view isConnected] && [view isLegacyVNC] == !fileTransfer
            && [view supportsFileTransfer] == fileTransfer;
        if (fileTransfer) {
            passed = passed && [frame allowsDragAndDropFileCopyToRemote] && [frame allowsDragAndDropFileCopyFromRemote]
                && [types containsObject:@"NSFilenamesPboardType"]
                && [types containsObject:@"Apple files promise pasteboard type"];
        }
        printf("connected=%d legacy=%d files=%d toRemote=%d fromRemote=%d types=%s\n",
            [view isConnected], [view isLegacyVNC], [view supportsFileTransfer],
            [frame allowsDragAndDropFileCopyToRemote], [frame allowsDragAndDropFileCopyFromRemote],
            types.description.UTF8String);
        fflush(stdout);
        // Close the isolated client without scheduling private-framework UI.
        _exit(passed ? 0 : 1);
    }
}
