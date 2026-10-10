// Deterministic AppKit scrolling workload; renders only its own disposable window.
#import <AppKit/AppKit.h>
#import <time.h>
static NSString *root;
static FILE *trace;
static uint64_t now(void){return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);}
@interface WorkloadView : NSView
@property unsigned int sequence;
@property CGFloat offset;
@property NSString *mode;
@property NSTimer *timer;
@property NSDictionary *attributes;
@end
@implementation WorkloadView
- (BOOL)isFlipped{return YES;}
- (BOOL)acceptsFirstResponder{return YES;}
- (void)advance {
 NSString *mode=[[NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"workload-mode"] encoding:NSUTF8StringEncoding error:NULL] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
 if(![mode isEqualToString:self.mode]){self.mode=mode;fprintf(trace,"mode,%llu,%s\n",now(),mode.UTF8String);fflush(trace);self.needsDisplay=YES;}
 if([mode isEqualToString:@"scroll"]){self.offset+=13;self.sequence++;self.needsDisplay=YES;}
}
- (void)scrollWheel:(NSEvent*)e {self.offset+=e.scrollingDeltaY*8;self.sequence++;fprintf(trace,"scroll_input,%llu,%u\n",now(),self.sequence);fflush(trace);self.needsDisplay=YES;}
- (void)drawRect:(NSRect)dirty {
 uint64_t t=now();
 [[NSColor colorWithWhite:0.96 alpha:1]setFill];NSRectFill(self.bounds);
 if(!self.attributes){NSFont *font=[NSFont monospacedSystemFontOfSize:16 weight:NSFontWeightRegular] ?: [NSFont systemFontOfSize:16];
 self.attributes=font ? @{NSFontAttributeName:font,NSForegroundColorAttributeName:NSColor.darkGrayColor} : @{};}
 NSDictionary *attrs=self.attributes;
 int first=(int)self.offset/26;
 for(int line=0;line<44;line++){
  CGFloat y=140+line*26-fmod(self.offset,26);
  NSString *s=[NSString stringWithFormat:@"%05d  func pipeline_%03d(frame: Framebuffer) -> Response { return encode(frame) }",first+line,(first+line)%997];
  [s drawAtPoint:NSMakePoint(28,y) withAttributes:attrs];
 }
 [[NSColor colorWithRed:0.1 green:0.2 blue:0.8 alpha:1]setFill];NSRectFill(NSMakeRect(32,64,16,16));
 for(int bit=0;bit<24;bit++){
  BOOL on=(self.sequence>>bit)&1;
  [[NSColor colorWithRed:on?0.1:0.8 green:on?0.8:0.1 blue:0.1 alpha:1]setFill];NSRectFill(NSMakeRect(48+bit*16,64,16,16));
 }
 [@"VNC pipeline measurement — synthetic document" drawAtPoint:NSMakePoint(28,100) withAttributes:attrs];
 fprintf(trace,"scene_draw,%llu,%u,%llu\n",t,self.sequence,now()-t);
}
@end
int main(int argc,char**argv){@autoreleasepool{
 if(argc!=2)return 2;root=[NSString stringWithUTF8String:argv[1]];trace=fopen([[root stringByAppendingPathComponent:@"workload-retry.csv"]fileSystemRepresentation],"w");
 [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
 NSWindow *w=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,118,1200,1000) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
 w.title=@"VNC Pipeline Workload";WorkloadView *v=[[WorkloadView alloc]initWithFrame:NSMakeRect(0,0,1200,1000)];w.contentView=v;[w makeKeyAndOrderFront:nil];
 v.timer=[NSTimer scheduledTimerWithTimeInterval:1.0/60 target:v selector:@selector(advance) userInfo:nil repeats:YES];
 [NSApp run];
}}
