// Timing-only probes for a disposable, ad-hoc-signed copy of Screen Sharing 3.0.
// Logs metadata only. Requires the host ScreenSharing.framework; see report caveat.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <unistd.h>
#import <pthread.h>
#import <time.h>
#import <zlib.h>
#import <CommonCrypto/CommonCryptor.h>

static FILE *out;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static uint64_t cpu(void) { return clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID); }
static void event(const char *name,uint64_t start,uint64_t wall,uint64_t cost,long n) {
    if (!out) return;
    pthread_mutex_lock(&lock);
    fprintf(out,"%s,%llu,%llu,%llu,%u,%ld\n",name,start,wall,cost,pthread_mach_thread_np(pthread_self()),n);
    pthread_mutex_unlock(&lock);
}
static BOOL profiledSocket(int fd) {
    struct sockaddr_in a; socklen_t n=sizeof(a);
    return getpeername(fd,(struct sockaddr*)&a,&n)==0 && a.sin_family==AF_INET &&
        (ntohs(a.sin_port)==5910 || ntohs(a.sin_port)==5911);
}
#define INTERPOSE(replacement, replacee) __attribute__((used)) static struct {const void *a,*b;} interpose_##replacee __attribute__((section("__DATA,__interpose"))) = {(const void *)&replacement,(const void *)&replacee};
static int trace_inflate(z_streamp s,int f) {uint64_t t=now(),c=cpu();uLong before=s->total_out;int r=inflate(s,f);event("client_inflate",t,now()-t,cpu()-c,s->total_out-before);return r;}
INTERPOSE(trace_inflate,inflate)
static ssize_t trace_read(int f,void*b,size_t n) {BOOL yes=profiledSocket(f);uint64_t t=now(),c=cpu();ssize_t r=read(f,b,n);if(yes)event("client_read_including_wait",t,now()-t,cpu()-c,r);return r;}
INTERPOSE(trace_read,read)
static ssize_t trace_recv(int f,void*b,size_t n,int flags) {BOOL yes=profiledSocket(f);uint64_t t=now(),c=cpu();ssize_t r=recv(f,b,n,flags);if(yes)event("client_recv_including_wait",t,now()-t,cpu()-c,r);return r;}
INTERPOSE(trace_recv,recv)
static ssize_t trace_write(int f,const void*b,size_t n) {BOOL yes=profiledSocket(f);uint64_t t=now(),c=cpu();ssize_t r=write(f,b,n);if(yes)event("client_write",t,now()-t,cpu()-c,r);return r;}
INTERPOSE(trace_write,write)
static CCCryptorStatus trace_crypto(CCCryptorRef ref,const void *in,size_t n,void *output,size_t cap,size_t *used) {
 uint64_t t=now(),c=cpu();CCCryptorStatus r=CCCryptorUpdate(ref,in,n,output,cap,used);event("client_crypto_update",t,now()-t,cpu()-c,n);return r;
}
INTERPOSE(trace_crypto,CCCryptorUpdate)

@interface NSObject (ProfileAPI)
+ (id)defaultOptions;
- (void)applyURLOptions:(id)options;
@end

__attribute__((constructor)) static void install(void) { @autoreleasepool {
    const char *path=getenv("MAC_VNC_CLIENT_PROFILE");
    if(path) {out=fopen(path,"w"); if(out)setvbuf(out,NULL,_IOFBF,1024*1024);}
    Class view=NSClassFromString(@"SSSessionView");
    // 3.0 calls this method during ready; macOS 26 removed it. Adapter only in clone.
    SEL merge=NSSelectorFromString(@"connectionOptionsWithOptions:urlOptions:");
    if(![view respondsToSelector:merge]) {
        class_addMethod(object_getClass(view),merge,imp_implementationWithBlock(^id(id self,id options,id urlOptions){
            if(!options) options=[NSClassFromString(@"SSConnectionOptions") defaultOptions];
            [options applyURLOptions:urlOptions]; return options;
        }),"@@:@@");
        event("compatibility_adapter_installed",now(),0,0,1);
    }
    Class controller=NSClassFromString(@"SessionWindowController");
    NSString *statePath=[NSString stringWithFormat:@"%s.vncloc",path ?: "/tmp/mac-vnc-pipeline-state"];
    Method state=class_getInstanceMethod(controller,NSSelectorFromString(@"proxyIconFilepath"));
    if(state)method_setImplementation(state,imp_implementationWithBlock(^id(id self){return statePath;}));
    Method write=class_getInstanceMethod(controller,NSSelectorFromString(@"writeVNCFileToPath:"));
    if(write){SEL sel=method_getName(write);void(*original)(id,SEL,id)=(void*)method_getImplementation(write);
        method_setImplementation(write,imp_implementationWithBlock(^(id self,id path){original(self,sel,statePath);}));}
    Method update=class_getInstanceMethod(NSClassFromString(@"SSSession"),NSSelectorFromString(@"handleFrameBufferUpdate:"));
    if(update){SEL sel=method_getName(update);void(*original)(id,SEL,void*)=(void*)method_getImplementation(update);
        method_setImplementation(update,imp_implementationWithBlock(^(id self,void *rect){uint64_t t=now(),c=cpu();original(self,sel,rect);event("client_framebuffer_updated",t,now()-t,cpu()-c,0);}));}
    Method draw=class_getInstanceMethod(NSClassFromString(@"SSFrameBufferRenderView"),@selector(drawRect:));
    if(draw){void(*original)(id,SEL,NSRect)=(void*)method_getImplementation(draw);
        method_setImplementation(draw,imp_implementationWithBlock(^(id self,NSRect rect){uint64_t t=now(),c=cpu();original(self,@selector(drawRect:),rect);event("client_draw_submit",t,now()-t,cpu()-c,0);}));}
    // Periodic flushing does not run in the decoder's critical section.
    dispatch_source_t timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_global_queue(0,0));
    dispatch_source_set_timer(timer,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),NSEC_PER_SEC,10000000);
    dispatch_source_set_event_handler(timer,^{pthread_mutex_lock(&lock);if(out)fflush(out);pthread_mutex_unlock(&lock);});
    dispatch_resume(timer);
    static dispatch_source_t retainedTimer; retainedTimer=timer;
    event("client_trace_installed",now(),0,0,getpid());
}}
