// Interactive regression probe: native ScreenSharing sender -> real server ->
// an AppKit receiving app. Input is triggered by the visible Begin/Release buttons.
// Build: xcrun clang -fobjc-arc -framework AppKit scripts/probe-staged-drag-release.m -o /tmp/staged-drag-release
// Use a separate server on loopback with --password testpass --file-transfer.
// Run: /tmp/staged-drag-release vnc://127.0.0.1:5906/
// Wait after Begin: the target must stay orange, with no "target perform" log.
// Release: expect content_matches=1 original_held=0, and server operation=1.
// PROBE_CANCEL=1 changes Release into Cancel: expect target exited, no perform,
// and server operation=0. This exercises Tahoe's framework; it does not emulate
// the complete macOS 13 Screen Sharing UI. Use an isolated transfer directory.
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
+ (id)dragEventWithDragType:(int)type dragPasteboardName:(NSString *)name draggingFilePromisesFromServer:(BOOL)promises withEvent:(id)event;
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

typedef struct { NSInteger x,y; } NativePoint;
@interface NSObject (DragRouting)
- (void)sendStartDragToRemote:(id)event;
+ (id)mouseEventWithCoordinates:(NativePoint)point withEvent:(id)event;
+ (id)mouseButtonEventWithCoordinates:(NativePoint)point withButton:(NSInteger)button withState:(int)state withClickCount:(NSInteger)clickCount withEvent:(id)event;
@end
static id nativeView;
static NSURL *fixture;
static BOOL originalHeld;
static void record(NSString *message) { fprintf(stderr,"%.3f %s\n",NSDate.timeIntervalSinceReferenceDate,message.UTF8String);fflush(stderr); }
@interface Driver : NSView
@property BOOL active;
@property NSPasteboard *board;
@end
@implementation Driver
- (void)drawRect:(NSRect)r {
    [NSColor.windowBackgroundColor setFill]; NSRectFill(self.bounds);
    [@"Begin, wait for orange, then release." drawAtPoint:NSMakePoint(20,50)
        withAttributes:@{NSForegroundColorAttributeName:NSColor.labelColor}];
}
- (NativePoint)coordinates {
    NSPoint p=[self.window convertPointToScreen:NSMakePoint(500,100)];
    return (NativePoint){lround(p.x),lround(p.y)};
}
- (void)begin:(id)sender {
    if (self.active || ![nativeView isControlling]) return;
    self.active=YES; originalHeld=YES;
    self.board=[NSPasteboard pasteboardWithUniqueName];[self.board writeObjects:@[fixture]];
    id session=[nativeView session];
    // Use the native viewer's sender; input originates only in this UI handler.
    [session sendEvent:[NSClassFromString(@"SSMouseEvent") mouseEventWithCoordinates:[self coordinates] withEvent:nil]];
    [session sendStartDragToRemote:[NSClassFromString(@"SSDragEvent") dragEventWithDragType:0 dragPasteboardName:self.board.name draggingFilePromisesFromServer:NO withEvent:nil]];
    [session sendEvent:[NSClassFromString(@"SSMouseButtonEvent") mouseButtonEventWithCoordinates:[self coordinates] withButton:0 withState:0 withClickCount:1 withEvent:nil]];
    record(@"driver enter");
}
- (void)drop:(id)sender {
    if (!self.active) return;
    self.active=NO; originalHeld=NO; record(@"driver mouse released");
    [[nativeView session] sendEvent:[NSClassFromString(@"SSMouseEvent") mouseEventWithCoordinates:[self coordinates] withEvent:nil]];
    [[nativeView session] sendEvent:[NSClassFromString(@"SSDragEvent") dragEventWithDragType:getenv("PROBE_CANCEL")?2:1 dragPasteboardName:self.board.name draggingFilePromisesFromServer:NO withEvent:nil]];
    record(getenv("PROBE_CANCEL")?@"driver cancel":@"driver conclude");
}
@end
@interface Target : NSView
@property BOOL accepting;
@property BOOL received;
@end
@implementation Target
- (void)drawRect:(NSRect)r { [(self.received?NSColor.systemGreenColor:self.accepting?NSColor.systemOrangeColor:NSColor.controlBackgroundColor) setFill];NSRectFill(self.bounds);[(self.received?@"DROP RECEIVED":self.accepting?@"ACCEPTING DRAG":@"DROP TARGET") drawAtPoint:NSMakePoint(30,70) withAttributes:@{NSFontAttributeName:[NSFont boldSystemFontOfSize:20],NSForegroundColorAttributeName:NSColor.labelColor}]; }
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)s { record(@"target entered");self.accepting=YES;[self setNeedsDisplay:YES];return NSDragOperationCopy; }
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)s { return NSDragOperationCopy; }
- (void)draggingExited:(id<NSDraggingInfo>)s { record(@"target exited");self.accepting=NO;[self setNeedsDisplay:YES]; }
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)s { record(@"target prepare");return YES; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)s {
    NSArray<NSURL *> *urls=[s.draggingPasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}];
    self.received=urls.count==1 && [[[NSString alloc] initWithContentsOfURL:urls.firstObject encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"routed drag fixture\n"];
    self.accepting=NO;[self setNeedsDisplay:YES];record([NSString stringWithFormat:@"target perform urls=%lu content_matches=%d original_held=%d",urls.count,self.received,originalHeld]);return self.received;
}
@end
int main(int argc,char **argv) { @autoreleasepool {
    if(argc!=2)return 2;
    NSURL *url=[NSURL URLWithString:[NSString stringWithUTF8String:argv[1]]];
    if(![url.scheme isEqualToString:@"vnc"] || ![url.host isEqualToString:@"127.0.0.1"] || url.query || url.fragment)return 2;
    if(!dlopen("/System/Library/PrivateFrameworks/ScreenSharing.framework/Versions/A/ScreenSharing",RTLD_LAZY|RTLD_LOCAL))return 2;
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSUserDefaults.standardUserDefaults registerDefaults:@{@"encryptionLevel":@2}];
    fixture=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"mac-vnc-drag-%@.txt",NSUUID.UUID.UUIDString]]];[@"routed drag fixture\n" writeToURL:fixture atomically:YES encoding:NSUTF8StringEncoding error:nil];
    id options=[NSClassFromString(@"SSConnectionOptions") defaultOptions];
    [options applyURLOptions:@{@"sharePasteboard":@"0",@"disableReconnect":@"1",@"control":@"1"}];
    [options applyURLOptions:[NSClassFromString(@"SSAddress") optionsFromURL:url]];
    nativeView=[[NSClassFromString(@"SSSessionView") alloc] initWithFrame:NSMakeRect(0,0,640,480)];
    ProbeStartupDelegate *startup=[ProbeStartupDelegate new];startup.view=nativeView;[(ProbeSessionView *)nativeView setDelegate:startup];
    [nativeView setShouldWarnUserForUnencryptedLegacyVNC:NO];[nativeView setAllowsFileTransferToRemote:YES];[nativeView setAllowsFileTransferFromRemote:YES];[nativeView setShouldScaleScreen:NO];
    NSWindow *hidden=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,640,480) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];hidden.contentView=nativeView;
    id credentials=[NSClassFromString(@"SSPasswordCredentials") vncAuthenticationCredentialsWithPassword:@"testpass"];
    [nativeView connectToURL:url.absoluteString withPreferredCredentials:@[credentials] options:options];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:5];while(deadline.timeIntervalSinceNow>0 && !startup.finished)[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    record([NSString stringWithFormat:@"connected=%d control=%d files=%d",[nativeView isConnected],[nativeView isControlling],[nativeView supportsFileTransfer]]);
    NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(350,650,700,250) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];window.releasedWhenClosed=NO;window.title=@"Routed VNC Drag Test";
    Driver *driver=[[Driver alloc] initWithFrame:NSMakeRect(0,0,700,250)];window.contentView=driver;
    Target *target=[[Target alloc] initWithFrame:NSMakeRect(360,20,300,200)];[target registerForDraggedTypes:@[NSPasteboardTypeFileURL]];[driver addSubview:target];
    NSButton *begin=[NSButton buttonWithTitle:@"Begin held drag" target:driver action:@selector(begin:)];begin.frame=NSMakeRect(20,170,220,35);[driver addSubview:begin];
    NSButton *drop=[NSButton buttonWithTitle:getenv("PROBE_CANCEL")?@"Cancel drag":@"Release to drop" target:driver action:@selector(drop:)];drop.frame=NSMakeRect(20,120,220,35);[driver addSubview:drop];
    [window makeKeyAndOrderFront:nil];
    [NSApp run];
    [NSFileManager.defaultManager removeItemAtURL:fixture error:nil];
}}
