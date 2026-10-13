// Read-only console-session feasibility probe. No listener, input, or service.
// A later visual test found that inherited-bootstrap ScreenCaptureKit captured
// the user's desktop despite a root audit join. This probe's frame delivery
// does not prove capture ownership; the backend now uses direct display streams.
// --attach compares three disposable workers. Run while the physical console
// is at loginwindow; all screenshots stay in memory and are discarded.
// clang -fobjc-arc -framework AppKit -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo \
//   scripts/probe-console-session.m -o .build/console-session/probe-console
// sudo .build/console-session/probe-console --attach
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>
#import <libproc.h>
#import <pwd.h>
#import <grp.h>
#import <sys/stat.h>
#import <dlfcn.h>
#import <bsm/audit.h>
#import <mach/mach.h>
#import <spawn.h>
#import <sys/wait.h>

// Present in bsm/audit.h behind __APPLE_API_PRIVATE. These change only the
// disposable worker's membership, never the session shown on the monitor.
extern int audit_session_port(au_asid_t, mach_port_name_t *);
extern au_asid_t audit_session_join(mach_port_name_t);
extern char **environ;

static BOOL consoleStillOwnedBy(uid_t uid) {
    struct stat info;
    return !stat("/dev/console", &info) && info.st_uid == uid;
}

@interface ConsoleCaptureProbe : NSObject <SCStreamOutput>
@property SCStream *stream;
@property BOOL received;
@end
@implementation ConsoleCaptureProbe
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(SCStreamOutputType)type {
    CVPixelBufferRef buffer=CMSampleBufferGetImageBuffer(sample);
    if(!buffer || self.received)return;
    self.received=YES;
    printf("SCK_FRAME width=%zu height=%zu\n",CVPixelBufferGetWidth(buffer),CVPixelBufferGetHeight(buffer));fflush(stdout);
}
@end

static int inspectConsole(uid_t expectedUID, au_asid_t expectedAudit, BOOL requireConsole, BOOL identityOnly) {
    auditinfo_addr_t audit={0};
    int auditResult=getaudit_addr(&audit,sizeof(audit));
    printf("AUDIT pid=%d result=%d id=%d user=%u flags=0x%llx\n",getpid(),auditResult,audit.ai_asid,audit.ai_auid,audit.ai_flags);fflush(stdout);
    if (requireConsole && expectedAudit > 0 && audit.ai_asid != expectedAudit) {
        mach_port_name_t port = MACH_PORT_NULL;
        int status = audit_session_port(expectedAudit, &port);
        printf("AUDIT_PORT expected=%d status=%d errno=%d\n",expectedAudit,status,status?errno:0);
        if (status) return 3;
        au_asid_t joined = audit_session_join(port);
        int savedError = errno;
        mach_port_deallocate(mach_task_self(), port);
        printf("AUDIT_JOIN expected=%d actual=%d errno=%d\n",expectedAudit,joined,joined<0?savedError:0);
        if (joined != expectedAudit) return 3;
        auditResult=getaudit_addr(&audit,sizeof(audit));
    }
    // Drop root when the console belongs to an ordinary user, before creating
    // a WindowServer connection. launchctl bsexec supplies the audit/bootstrap.
    if(geteuid()==0 && expectedUID!=0) {
        struct passwd *account=getpwuid(expectedUID);
        if(!account || initgroups(account->pw_name,account->pw_gid) || setgid(account->pw_gid) || setuid(expectedUID)) {perror("drop privileges");return 2;}
    }
    NSDictionary *session=CFBridgingRelease(CGSessionCopyCurrentDictionary());
    BOOL onConsole=[session[@"kCGSSessionOnConsoleKey"] boolValue];
    printf("SESSION present=%d euid=%u uid=%u on_console=%d audit=%u\n",session!=nil,geteuid(),[session[@"kCGSSessionUserIDKey"] unsignedIntValue],onConsole,[session[@"kCGSSessionAuditIDKey"] unsignedIntValue]);fflush(stdout);
    if (requireConsole) {
        BOOL kernelIdentity = expectedAudit > 0 && !auditResult && audit.ai_asid == expectedAudit;
        BOOL graphicsIdentity = session && onConsole && [session[@"kCGSSessionUserIDKey"] unsignedIntValue]==expectedUID;
        // A nil graphics dictionary is a failed query, not a dictionary for
        // UID 0/session 0. Audit membership is an independent check. Record the
        // missing query explicitly before testing capture in this diagnostic.
        if (geteuid()!=expectedUID || !consoleStillOwnedBy(expectedUID) ||
            !kernelIdentity || (session && !graphicsIdentity)) {
            fprintf(stderr,"Console identity verification failed; no capture attempted.\n");return 3;
        }
        printf("IDENTITY kernel=verified graphics=%s\n",graphicsIdentity?"verified":"unavailable");
    } else if (!session) {
        fprintf(stderr,"Graphics session query unavailable.\n");return 3;
    }
    if (identityOnly) return 0;
    printf("ACCESS capture=%d input=%d\n",CGPreflightScreenCaptureAccess(),CGPreflightPostEventAccess());
    uint32_t count=0;CGDirectDisplayID ids[32];CGError err=CGGetActiveDisplayList(32,ids,&count);
    printf("DISPLAYS status=%d count=%u\n",err,count);
    CGImageRef(*capture)(CGDirectDisplayID)=dlsym(RTLD_DEFAULT,"CGDisplayCreateImage");
    for(unsigned i=0;i<count;i++) {
        CGImageRef image=capture?capture(ids[i]):NULL;
        printf("DIRECT_FRAME display=%u width=%zu height=%zu\n",ids[i],image?CGImageGetWidth(image):0,image?CGImageGetHeight(image):0);
        if(image)CGImageRelease(image);
    }
    NSArray *windows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID));
    NSUInteger loginWindows=0;for(NSDictionary *w in windows)if([w[(id)kCGWindowOwnerName] isEqualToString:@"loginwindow"])loginWindows++;
    printf("WINDOWS total=%lu loginwindow=%lu\n",windows.count,loginWindows);fflush(stdout);
    if (requireConsole && !consoleStillOwnedBy(expectedUID)) {fprintf(stderr,"Console changed during probe.\n");return 3;}
    ConsoleCaptureProbe *probe=[ConsoleCaptureProbe new];
    __block BOOL done=NO;
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:NO completionHandler:^(SCShareableContent *content,NSError *error){
        printf("SCK_ENUM count=%lu error=%s\n",content.displays.count,error?error.description.UTF8String:"none");fflush(stdout);
        SCDisplay *display=content.displays.firstObject;
        if(!display){done=YES;return;}
        SCStreamConfiguration *cfg=[SCStreamConfiguration new];cfg.width=display.width;cfg.height=display.height;cfg.minimumFrameInterval=CMTimeMake(1,5);
        probe.stream=[[SCStream alloc] initWithFilter:[[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]] configuration:cfg delegate:nil];
        NSError *addError=nil;[probe.stream addStreamOutput:probe type:SCStreamOutputTypeScreen sampleHandlerQueue:dispatch_get_main_queue() error:&addError];
        [probe.stream startCaptureWithCompletionHandler:^(NSError *startError){printf("SCK_START error=%s\n",startError?startError.description.UTF8String:"none");fflush(stdout);if(startError)done=YES;}];
    }];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:12];
    while(!done && !probe.received && deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
    printf("RESULT sck_received=%d\n",probe.received);fflush(stdout);
    if(probe.stream)[probe.stream stopCaptureWithCompletionHandler:^(NSError *error){}];
    return probe.received?0:4;
}

static int runWorker(NSArray<NSString *> *arguments, NSString *strategy) {
    printf("STRATEGY %s\n", strategy.UTF8String);fflush(stdout);
    NSUInteger count=arguments.count;
    char **argv=calloc(count+1,sizeof(char *));
    for(NSUInteger i=0;i<count;i++)argv[i]=strdup(arguments[i].UTF8String);
    pid_t child=0;
    int status=posix_spawn(&child,argv[0],NULL,NULL,argv,environ);
    for(NSUInteger i=0;i<count;i++)free(argv[i]);free(argv);
    if(status){printf("SPAWN error=%d\n",status);return 2;}
    // Bound synchronous framework calls too: the inner SCK deadline only
    // covers its asynchronous callbacks. Every attempt is a fresh process.
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:25];
    int result=0;
    for (;;) {
        pid_t waited=waitpid(child,&result,WNOHANG);
        if(waited==child)break;
        if(waited<0){if(errno==EINTR)continue;perror("waitpid");return 2;}
        if(deadline.timeIntervalSinceNow<=0){kill(child,SIGKILL);waitpid(child,&result,0);printf("WORKER timeout\n");return 4;}
        usleep(50000);
    }
    int code=WIFEXITED(result)?WEXITSTATUS(result):128+WTERMSIG(result);
    printf("WORKER strategy=%s exit=%d\n",strategy.UTF8String,code);fflush(stdout);
    return code;
}

int main(int argc,char **argv) {@autoreleasepool {
    setbuf(stdout,NULL);
    if(argc==4 && !strcmp(argv[1],"--worker")) {
        // Also exit if the supervising probe is interrupted or loses its
        // terminal while a framework call is waiting.
        alarm(25);
        return inspectConsole((uid_t)strtoul(argv[2],NULL,10),(au_asid_t)strtol(argv[3],NULL,10),YES,NO);
    }
    if(argc==2 && !strcmp(argv[1],"--identity"))return inspectConsole(geteuid(),0,NO,YES);
    if(argc==1)return inspectConsole(geteuid(),0,NO,NO);
    if(argc!=2 || strcmp(argv[1],"--attach")){fprintf(stderr,"Usage: probe-console [--identity|--attach]\n");return 2;}
    if(geteuid()!=0){fprintf(stderr,"--attach needs administrator privileges to enter loginwindow's context.\n");return 2;}
    struct stat st;if(stat("/dev/console",&st)){perror("console owner");return 2;}
    int capacity=proc_listallpids(NULL,0)+64;pid_t *pids=calloc(capacity,sizeof(pid_t));int count=proc_listallpids(pids,capacity*sizeof(pid_t));
    pid_t target=0;
    for(int i=0;i<count;i++) {
        struct proc_bsdinfo info;char path[PROC_PIDPATHINFO_MAXSIZE];
        if(proc_pidinfo(pids[i],PROC_PIDTBSDINFO,0,&info,sizeof(info))!=(int)sizeof(info) || info.pbi_uid!=st.st_uid)continue;
        if(proc_pidpath(pids[i],path,sizeof(path))>0 && !strcmp(path,"/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow")) {
            if(target){fprintf(stderr,"Ambiguous console loginwindow; refusing.\n");free(pids);return 2;}target=pids[i];
        }
    }
    free(pids);if(!target){fprintf(stderr,"No console loginwindow found.\n");return 2;}
    // logind/SkyLight's console metadata and the target process's kernel audit
    // identity are reported separately; a loginwindow can itself live outside
    // the graphics bootstrap namespace it manages.
    CFArrayRef(*copySessions)(void)=dlsym(RTLD_DEFAULT,"CGSCopySessionList");
    NSArray *sessions=copySessions?CFBridgingRelease(copySessions()):nil;
    au_asid_t expectedAudit=0;
    for(NSDictionary *session in sessions) {
        if([session[@"kCGSSessionOnConsoleKey"] boolValue] && [session[@"kCGSSessionUserIDKey"] unsignedIntValue]==st.st_uid)
            expectedAudit=[session[@"kCGSSessionAuditIDKey"] intValue];
    }
    auditpinfo_addr_t processAudit={.ap_pid=target};
    int query=auditon(A_GETPINFO_ADDR,&processAudit,sizeof(processAudit));
    printf("TARGET console_uid=%u loginwindow_pid=%d graphics_audit=%d process_audit=%d query=%d errno=%d\n",st.st_uid,target,expectedAudit,processAudit.ap_asid,query,query?errno:0);
    if(expectedAudit<=0 && !query)expectedAudit=processAudit.ap_asid;
    if(expectedAudit<=0){fprintf(stderr,"Cannot identify console audit session; no attachment attempted.\n");return 3;}
    NSString *executable=[NSString stringWithUTF8String:argv[0]].stringByStandardizingPath;
    if(!executable.isAbsolutePath)executable=[NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:executable];
    NSString *pid=[NSString stringWithFormat:@"%d",target], *uid=[NSString stringWithFormat:@"%u",st.st_uid], *asid=[NSString stringWithFormat:@"%d",expectedAudit];
    int result=runWorker(@[@"/bin/launchctl",@"bsexec",pid,executable,@"--worker",uid,asid],@"loginwindow-bootstrap+audit");
    if(!consoleStillOwnedBy(st.st_uid)){fprintf(stderr,"Console changed; remaining tests skipped.\n");return 3;}
    int asuser=runWorker(@[@"/bin/launchctl",@"asuser",uid,executable,@"--worker",uid,asid],@"user-bootstrap+audit");
    if(!consoleStillOwnedBy(st.st_uid)){fprintf(stderr,"Console changed; remaining tests skipped.\n");return 3;}
    int inherited=runWorker(@[executable,@"--worker",uid,asid],@"inherited-bootstrap+audit");
    return result==0 || asuser==0 || inherited==0 ? 0 : 4;
}}
