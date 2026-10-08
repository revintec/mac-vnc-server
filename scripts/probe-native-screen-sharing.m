// Opt-in interoperability probe, used by MultiClientTests. No window is shown;
// the test server supplies synthetic pixels and a private test pasteboard.
// Build: xcrun clang -fobjc-arc -framework AppKit scripts/probe-native-screen-sharing.m -o /tmp/mac-vnc-native-drag-probe
// Run tests with MAC_VNC_NATIVE_PROBE=/tmp/mac-vnc-native-drag-probe.
#import <AppKit/AppKit.h>
#import <dlfcn.h>

typedef struct { NSInteger width, height; } NativeFramebufferSize;
@interface ProbeFramebuffer : NSObject
- (NativeFramebufferSize)size;
@end

@interface NSObject (NativeScreenSharingProbe)
+ (id)defaultOptions;
+ (NSDictionary *)optionsFromURL:(NSURL *)url;
+ (id)vncAuthenticationCredentialsWithPassword:(NSString *)password;
- (void)applyURLOptions:(NSDictionary *)options;
- (NSInteger)minimumEncryptionLevel;
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
- (void)setControlMode:(NSInteger)mode;
- (id)session;
- (void)setScalingFactor:(double)factor forced:(BOOL)forced;
- (double)scalingFactor;
- (ProbeFramebuffer *)frameBuffer;
- (id)frameBufferView;
- (BOOL)allowsDragAndDropFileCopyToRemote;
- (BOOL)allowsDragAndDropFileCopyFromRemote;
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 4) return 2;
        BOOL fileTransfer = atoi(argv[2]) != 0;
        BOOL startControlling = atoi(argv[3]) != 0;
        if (!dlopen("/System/Library/PrivateFrameworks/ScreenSharing.framework/Versions/A/ScreenSharing", RTLD_LAZY | RTLD_LOCAL)) return 2;
        Class viewClass = NSClassFromString(@"SSSessionView");
        if (!viewClass) return 2;
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        id options = [NSClassFromString(@"SSConnectionOptions") defaultOptions];
        [options applyURLOptions:@{@"control": startControlling ? @"1" : @"0",
                                  @"sharePasteboard": @"0", @"disableReconnect": @"1"}];
        // Exercise the supplied URL, rather than forcing plaintext through an
        // independent options override that could hide a URL parsing failure.
        NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:argv[1]]];
        [options applyURLOptions:[NSClassFromString(@"SSAddress") optionsFromURL:url]];
        if ([options minimumEncryptionLevel] != 0) return 2;
        id view = [[viewClass alloc] initWithFrame:NSMakeRect(0, 0, 640, 480)];
        [view setShouldWarnUserForUnencryptedLegacyVNC:NO];
        [view setAllowsFileTransferToRemote:YES];
        [view setAllowsFileTransferFromRemote:YES];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 480)
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        window.contentView = view;
        id credentials = [NSClassFromString(@"SSPasswordCredentials") vncAuthenticationCredentialsWithPassword:@"testpass"];
        [view connectToURL:[NSString stringWithUTF8String:argv[1]] withPreferredCredentials:@[credentials] options:options];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:4];
        while (deadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        BOOL initiallyControlling = [view isControlling];
        BOOL controlSupported = [view supportsControlMode];
        BOOL passed = [view isConnected] && controlSupported && [view sessionAllowsControl]
            && initiallyControlling == startControlling;
        printf("controlSupported=%d controlAllowed=%d initiallyControlling=%d\n",
            controlSupported, [view sessionAllowsControl], initiallyControlling);
        for (int cycle = 0; cycle < 2; ++cycle) {
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
            passed = passed && observing && canResumeControl && resumedControl;
        }
        if (fileTransfer && [view isConnected]) {
            // Exercise SetServerScaling even when window sizing does not send
            // it automatically. Check the native decoder's actual pixel size.
            for (NSNumber *factor in @[@0.5, @0.75, @1.0, @1.0]) {
                [window setContentSize:NSMakeSize(1728 * factor.doubleValue, 1118 * factor.doubleValue)];
                [[view session] setScalingFactor:factor.doubleValue forced:YES];
                NativeFramebufferSize size = {0, 0};
                NSDate *scaleDeadline = [NSDate dateWithTimeIntervalSinceNow:5];
                do {
                    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
                    size = [[[view session] frameBuffer] size];
                } while ([view isConnected] && scaleDeadline.timeIntervalSinceNow > 0
                    && (size.width != lround(1728 * factor.doubleValue)
                        || size.height != lround(1118 * factor.doubleValue)));
                printf("scaling=%.2f framebuffer=%ldx%ld actualFactor=%.2f\n", factor.doubleValue, size.width, size.height,
                    [[view session] scalingFactor]);
                passed = passed && [view isConnected]
                    && size.width == lround(1728 * factor.doubleValue)
                    && size.height == lround(1118 * factor.doubleValue);
            }
        }
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
