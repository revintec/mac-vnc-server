// clang -fobjc-arc -framework AppKit scripts/probe-appkit-file-promises.m -o /tmp/file-promise-probe
// A local drag source. It never posts input, uploads files, or touches the general pasteboard.
// Drag one of the four cards into an application. JSON lines record promise fulfillment.
#import <AppKit/AppKit.h>

static NSURL *scratch;
static NSOperationQueue *writerQueue;
static NSMutableArray *retainedSources;
static FILE *eventLog;
static void record(NSString *event, NSDictionary *fields) {
    NSMutableDictionary *entry = [fields mutableCopy];
    entry[@"event"] = event;
    entry[@"time"] = @([[NSDate date] timeIntervalSince1970]);
    NSData *data = [NSJSONSerialization dataWithJSONObject:entry options:0 error:nil];
    @synchronized (NSProcessInfo.processInfo) {
        fwrite(data.bytes, 1, data.length, stdout);
        fputc('\n', stdout);
        fflush(stdout);
        if (eventLog) {
            fwrite(data.bytes, 1, data.length, eventLog);
            fputc('\n', eventLog);
            fflush(eventLog);
        }
    }
}

@interface ProbeItem : NSObject <NSFilePromiseProviderDelegate>
@property NSString *identifier;
@property NSString *filename;
@property NSData *payload;
@end
@implementation ProbeItem
- (NSString *)filePromiseProvider:(NSFilePromiseProvider *)provider fileNameForType:(NSString *)type {
    record(@"filename_requested", @{@"id":self.identifier, @"type":type});
    return self.filename;
}
- (NSOperationQueue *)operationQueueForFilePromiseProvider:(NSFilePromiseProvider *)provider {
    return writerQueue;
}
- (void)filePromiseProvider:(NSFilePromiseProvider *)provider writePromiseToURL:(NSURL *)url
         completionHandler:(void (^)(NSError *))completionHandler {
    record(@"write_requested", @{@"id":self.identifier, @"destination":url.path});
    // Deliberately asynchronous, like receiving a file over the network.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 800 * NSEC_PER_MSEC),
                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BOOL ok = [self.payload writeToURL:url options:NSDataWritingAtomic error:&error];
        record(@"write_completed", @{@"id":self.identifier, @"ok":@(ok),
            @"bytes":@(self.payload.length), @"error":error.localizedDescription ?: @""});
        completionHandler(error);
    });
}
@end

static NSData *payload(BOOL png) {
    if (!png) return [@"mac-vnc-server synthetic file-promise compatibility test.\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:48
        pixelsHigh:48 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    for (NSInteger y = 0; y < 48; y++) for (NSInteger x = 0; x < 48; x++) {
        NSUInteger rgba[] = {40, (NSUInteger)(70 + y * 3), (NSUInteger)(90 + x * 3), 255};
        [bitmap setPixel:rgba atX:x y:y];
    }
    return [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

@interface ProbeView : NSView <NSDraggingSource, NSDraggingDestination>
@property NSString *activeIdentifier;
@property NSPoint pressedPoint;
@end
@implementation ProbeView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    [NSColor.windowBackgroundColor setFill]; NSRectFill(self.bounds);
    [@"Drag a card into a target app (synthetic files only)" drawAtPoint:NSMakePoint(12, 12)
      withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:13]}];
    NSArray *names = @[@"Promise TXT", @"Promise PNG", @"Local TXT", @"Local PNG"];
    for (NSInteger i=0; i<4; i++) {
        NSRect rect=NSMakeRect(12+i*112, 42, 104, 74);
        [(i<2 ? NSColor.systemBlueColor : NSColor.systemGreenColor) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:8 yRadius:8] fill];
        [names[i] drawAtPoint:NSMakePoint(rect.origin.x+8,rect.origin.y+29)
          withAttributes:@{NSFontAttributeName:[NSFont boldSystemFontOfSize:12], NSForegroundColorAttributeName:NSColor.whiteColor}];
    }
    [[NSColor quaternaryLabelColor] setFill];
    NSRectFill(NSMakeRect(12, 132, 440, 50));
    [@"Reference receiver: drop here to verify the probe" drawAtPoint:NSMakePoint(22, 150)
      withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:13]}];
}
- (void)mouseDown:(NSEvent *)event { self.pressedPoint = [self convertPoint:event.locationInWindow fromView:nil]; }
- (void)mouseDragged:(NSEvent *)event {
    NSPoint point = self.pressedPoint;
    if (point.y < 42 || point.y > 116 || point.x < 12 || point.x >= 460) return;
    NSInteger slot = (NSInteger)((point.x-12)/112);
    BOOL png=slot%2, promise=slot<2;
    ProbeItem *item=[ProbeItem new];
    item.identifier=NSUUID.UUID.UUIDString;
    item.filename=[NSString stringWithFormat:@"vnc-probe-%@.%@",item.identifier,png?@"png":@"txt"];
    item.payload=payload(png);
    [retainedSources addObject:item];
    id<NSPasteboardWriting> writer;
    if (promise) {
        writer=[[NSFilePromiseProvider alloc] initWithFileType:png?@"public.png":@"public.plain-text" delegate:item];
    } else {
        NSURL *url=[scratch URLByAppendingPathComponent:item.filename];
        NSError *error=nil;
        if (![item.payload writeToURL:url options:NSDataWritingAtomic error:&error]) {
            record(@"local_write_error", @{@"error":error.localizedDescription}); return;
        }
        writer=url;
    }
    NSDraggingItem *drag=[[NSDraggingItem alloc] initWithPasteboardWriter:writer];
    NSImage *icon=[NSImage imageWithSystemSymbolName:png?@"photo":@"doc.text" accessibilityDescription:item.filename];
    [drag setDraggingFrame:NSMakeRect(point.x-16,point.y-16,32,32) contents:icon];
    self.activeIdentifier=item.identifier;
    record(@"drag_started", @{@"id":item.identifier, @"promise":@(promise), @"extension":png?@"png":@"txt",
        @"types":[writer writableTypesForPasteboard:[NSPasteboard pasteboardWithName:NSPasteboardNameDrag]]});
    [self beginDraggingSessionWithItems:@[drag] event:event source:self];
}
- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    return NSDragOperationCopy;
}
- (void)draggingSession:(NSDraggingSession *)session willBeginAtPoint:(NSPoint)point {
    record(@"pasteboard_ready", @{@"id":self.activeIdentifier ?: @"",
        @"types":session.draggingPasteboard.types,
        @"has_file_urls":@([session.draggingPasteboard canReadObjectForClasses:@[NSURL.class]
            options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}])});
}
- (void)draggingSession:(NSDraggingSession *)session endedAtPoint:(NSPoint)point operation:(NSDragOperation)operation {
    record(@"drag_ended", @{@"id":self.activeIdentifier ?: @"", @"operation":@(operation), @"x":@(point.x), @"y":@(point.y)});
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    return [self draggingUpdated:sender];
}
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    return [self convertPoint:sender.draggingLocation fromView:nil].y >= 132 ? NSDragOperationCopy : NSDragOperationNone;
}
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSArray<NSFilePromiseReceiver *> *promises=[sender.draggingPasteboard readObjectsForClasses:@[NSFilePromiseReceiver.class] options:@{}];
    if (promises.count) {
        NSURL *destination=[scratch URLByAppendingPathComponent:@"reference-receiver" isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:destination withIntermediateDirectories:YES attributes:nil error:nil];
        for (NSFilePromiseReceiver *receiver in promises) {
            [receiver receivePromisedFilesAtDestination:destination options:@{} operationQueue:writerQueue
                reader:^(NSURL *url,NSError *error) {
                    NSData *received=[NSData dataWithContentsOfURL:url];
                    record(@"reference_received", @{@"url":url.path ?: @"", @"bytes":@(received.length),
                        @"error":error.localizedDescription ?: @""});
                }];
        }
        return YES;
    }
    NSArray<NSURL *> *urls=[sender.draggingPasteboard readObjectsForClasses:@[NSURL.class]
        options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}];
    record(@"reference_local_urls", @{@"count":@(urls.count)});
    return urls.count>0;
}
@end

@interface ProbeDelegate : NSObject <NSApplicationDelegate>
@property NSWindow *window;
@end
@implementation ProbeDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSMenu *menu=[NSMenu new]; NSMenuItem *appMenu=[NSMenuItem new];
    [menu addItem:appMenu]; appMenu.submenu=[NSMenu new];
    [appMenu.submenu addItemWithTitle:@"Quit File Promise Probe" action:@selector(terminate:) keyEquivalent:@"q"];
    NSApp.mainMenu=menu;
    NSRect screen = NSScreen.mainScreen.visibleFrame;
    self.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(24,NSMaxY(screen)-270,468,196)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    self.window.title=@"File Promise Probe";
    self.window.level=NSFloatingWindowLevel;
    ProbeView *view=[[ProbeView alloc] initWithFrame:NSMakeRect(0,0,468,196)];
    [view registerForDraggedTypes:[NSFilePromiseReceiver.readableDraggedTypes arrayByAddingObject:NSPasteboardTypeFileURL]];
    self.window.contentView=view;
    [self.window makeKeyAndOrderFront:nil];
    record(@"window", @{@"frame":NSStringFromRect(self.window.frame),
        @"screen":NSStringFromRect(self.window.screen.frame),
        @"visible":NSStringFromRect(self.window.screen.visibleFrame)});
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
@end

int main(void) {
    @autoreleasepool {
        scratch=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
            [@"mac-vnc-file-promises-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:scratch withIntermediateDirectories:YES
            attributes:@{NSFilePosixPermissions:@0700} error:nil];
        writerQueue=[NSOperationQueue new]; writerQueue.maxConcurrentOperationCount=4;
        retainedSources=[NSMutableArray new];
        eventLog=fopen([[scratch URLByAppendingPathComponent:@"events.jsonl"].path fileSystemRepresentation], "a");
        record(@"probe_started", @{@"scratch":scratch.path});
        NSApplication *app=NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        ProbeDelegate *delegate=[ProbeDelegate new]; app.delegate=delegate;
        [app run];
    }
    return 0;
}
