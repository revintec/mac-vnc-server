# macOS 13 server compatibility

Verification date: 2026-10-15. Production source: commit `8512344`.

The server builds for macOS 13.0 on Apple Silicon and Intel. All required imports
in both resulting binaries also link against macOS 13.3 SDK stubs. These are
source, deployment, and link checks; no macOS 13 machine was available to run the
server. Actual Ventura capture, input, account attachment, and file transfers
remain unverified. Earlier Screen Sharing 3.0/macOS 13 client tests used a newer
server OS and do not establish Ventura server compatibility.

## Results

| Check | Result |
| --- | --- |
| Package deployment target | macOS 13.0 |
| Apple Silicon release build | Passed, explicit `arm64-apple-macosx13.0` target |
| Intel release build | Passed, explicit `x86_64-apple-macosx13.0` target |
| Public API availability | Both builds passed; C/Objective-C additionally used `-Werror=unguarded-availability-new` |
| Universal binary deployment metadata | Both slices report minimum OS 13.0, build SDK 27.0 |
| Required imports against Ventura SDK | Passed: 969 arm64 imports and 968 x86_64 imports, using 41 SDK library/framework stubs |
| Optional import | `_swift_willThrowTypedImpl` is weak-imported in both binaries and was excluded from the required-symbol check |
| Private symbols resolved dynamically | All nine names listed below appear in the 13.3 SDK export stubs |
| Binary signing | Universal binary passed strict ad-hoc signature verification |
| Executable smoke check | `version` and `--help` passed on the macOS 26.6.2 build host |
| macOS 13 execution | Not run; no local VM or remote host available |
| Intel execution | Not run; the build host is Apple Silicon |

There were no missing required imports in the SDK link check. It constructs a
small assembly object referencing every strong import from the finished binary,
then links that object against the Ventura SDK. It does not run the generated
object or prove Objective-C selector behavior, permissions, service availability,
or function semantics. The SDK is 13.3; early Ventura releases still require
their own runtime test even though the deployment/availability target is 13.0.

The Intel build warned that this host's optional `libswiftCompatibilityPacks.a`
has no x86_64 slice. Linking the server succeeded, and its complete set of strong
imports separately passed the Ventura SDK check. This warning is retained in the
build log rather than treated as evidence of Intel runtime validation.

## Feature assessment

| Feature | Evidence and remaining runtime check |
| --- | --- |
| Listener and account authentication | OpenDirectory, descriptor passing, and required Security functions are available at the deployment target. Verify actual credentials and admission on Ventura. |
| User-session capture | Used ScreenCaptureKit stream/configuration/frame-metadata APIs are present in the Ventura headers; the core capture APIs date to 12.3. Verify real frames and recovery on Ventura. |
| Encoding and pacing | Zlib/ZRLE compile into the binary, including bundled zlib-ng; all required system imports resolve. No additional installed compression library is needed. |
| Cursor and input | AppKit cursor and CoreGraphics event APIs pass availability checks. Verify permission grants and delivery to foreground/off-console apps. |
| Clipboard and outgoing drag | Uses AppKit APIs available on Ventura. Verify real clipboard representations and AppKit drag completion. |
| Native file contents and Finder Move | Sender/receiver executables and CoreDrag behavior remain runtime dependencies. Their behavior is not established by public API compilation. |
| Session attachment and off-console access | Session-list/audit/bootstrap exports are present. Verify fresh attachment, GUI identity, capture, and input on Ventura. |
| Loginwindow capture/input | Highest remaining uncertainty: isolated root `replayd` launch, Mach service registration, correct display capture, and permitted IOHID delivery. Export presence alone does not validate this backend. |
| Menu and Switch to Login Window | AppKit calls compile; the private login-framework entry point is exported. Verify menu rendering and Fast User Switching on Ventura. |

The dynamically resolved symbols checked were `CGSCopySessionList`,
`bootstrap_look_up_per_user`, `SecDHCreate`, `SecDHGenerateKeypair`,
`SecDHComputeKey`, `SecDHDestroy`, `SACSwitchToLoginWindow`,
`CoreDragSetAllowableActions`, and `CoreDragCancelDrag`.
Their availability does not promise unchanged private ABI or behavior.

File transfers check for these executable paths at runtime:

```text
/System/Library/CoreServices/RemoteManagement/screensharingd.bundle/Contents/Support/SSFileCopySender.bundle/Contents/MacOS/SSFileCopySender
/System/Library/CoreServices/RemoteManagement/screensharingd.bundle/Contents/Support/SSFileCopyReceiver.bundle/Contents/MacOS/SSFileCopyReceiver
```

Loginwindow's isolated service executes `/usr/libexec/replayd` and registers the
existing `com.apple.replayd`, `com.apple.replayd-cache-delete`, and
`com.apple.replaykit.sharingsession` service names. This was exercised on Tahoe;
the Ventura SDK cannot establish its runtime behavior.

## Build versus run requirements

`Package.swift` requires Swift 6.1 or newer. The runtime minimum and the compiler
version are different requirements. Ventura's Xcode 14/Swift 5.x toolchain cannot
build the unchanged package. Build with a supported modern toolchain/SDK and
deploy the resulting binary to the target Mac; no Swift compiler or SDK is
required there. All binary load dependencies are system frameworks/libraries.

The builds above used Swift 6.4 and SDK 27.0 on macOS 26.6.2, with explicit
macOS 13.0 triples. A supplementary attempt to compile directly with the 13.3 SDK
failed inside its Swift 5.8 Accelerate interface: the current compiler rejects
that SDK/toolchain pairing (`Accelerate.vecLib.BNNS` could not be imported).
That attempt is not counted as a successful old-SDK build. The separate link
check uses the 13.3 export stubs without those incompatible Swift interfaces.

The SDK archive used for the link checks came from
[the macosx-sdks 13.3 release](https://github.com/joseluisq/macosx-sdks/releases/tag/13.3).
Its SHA-256 matched the release checksum:
`518e35eae6039b3f64e8025f4525c1c43786cc5cf39459d609852faf091e34be`.

Local evidence and the universal binary are under
`.build/macos13-compat-20261015/`. The binary contains all production changes
through `8512344`, including Finder drag fixes and disconnect diagnostics.
The source manifest, build logs, import-check commands/results, and binary hash
are retained there. No running server was restarted or replaced.

## Runtime validation still required

When a Ventura host is available, test a normal account connection using a plain
`vnc://HOST:PORT/` URI, then exercise capture, Zlib/ZRLE, RichCursor, keyboard/mouse,
clipboard, and file transfers in both directions. Test off-console user access
and root/loginwindow separately with the necessary permissions. Use an available
interface/address: the default `utun4` need not exist on another Mac.

The RealVNC iOS startup delay is resolved according to the user. Persistent
single-process rebinding across different sessions is no longer a requirement.
Neither is an open blocker for this compatibility check.

## Subsequent Ventura startup report

On 2026-10-15, a user reported that the ARM64 server started on macOS 13 and
accepted connections, but launching a session after authentication failed with
`posix_spawn(): 2: No such file or directory`. The binary had been relocated and
invoked by command name through `sudo`/`PATH`. Worker launch incorrectly resolved
`argv[0]` against the listener's working directory. The worker, attached re-exec,
and root capture helper now obtain their executable path from dyld instead.
The new `scripts/test-executable-path.py` regression test covers relocated
binaries, bare command names, wrappers, symlinks, spaces, direct spawn/re-exec,
and (with `--root`) `launchctl asuser` without starting capture or a VNC server.
This establishes the cause of that launch failure, not completion of Ventura
capture/input/file-transfer runtime validation.

## Ventura capture and session findings

The Mac mini's subsequent tests establish that account authentication and a
fresh UID 501/audit 100005 worker start successfully. Screen Sharing 3.0
negotiates RFB 003.889, Control, DisplayInfo and Zlib. That is not yet evidence
of a usable off-console desktop.

The 2026-10-15 06:36 UTC trace shows ScreenCaptureKit supplying a 1920x1080
`complete` image from display 3, with `cg_asleep=false` and zero nonzero RGB
values at the 64 sampled points. Two full frames each compressed to about
8 KiB; no further changing frames arrived. Thus the sampled black image exists
before RFB encoding. A 64-point sample is not an exhaustive pixel scan.

The user confirmed that both physical display wake and the server's `wakeup`
command restore a picture, but that picture is **loginwindow**. Keyboard input
received while the picture was black also reached **loginwindow's password
field**, not an application in the user's desktop. Selecting **Switch to Login
Window** from our VNC menu likewise leaves VNC showing loginwindow. These
observations do not establish working off-console capture or user input.
`CGDisplayIsAsleep=false` does not rule out this observed wake dependency.

An independent state snapshot, taken later than that capture trace, reports:

| Observation | Result |
| --- | --- |
| `/dev/console` owner | root, UID 0 |
| `State:/Users/ConsoleUser` top-level owner | loginwindow, UID 0 |
| SystemConfiguration root session row | audit 100154, CG session 259, OnConsole false |
| SystemConfiguration user session row | UID 501, audit 100005, CG session 257, OnConsole true |
| IORegistry `IOConsoleUsers` | UID 501/audit 100005, OnConsole true |

The SystemConfiguration snapshot itself contains an ownership/graphics-flag
disagreement. Device ownership does not independently prove which graphics
session contains the displayed loginwindow. Nor does the worker's matching
Unix UID/audit metadata prove that its capture and input reach the desired
desktop. The next probe resolved this distinction: the displayed loginwindow belongs
to the user's existing session, as detailed below.

### Corrections in the current source

- **Executable location:** dyld-based lookup fixes spawning after moving the
  binary or invoking it through `PATH`, as described above.
- **Capture state handling:** valid `started` images are accepted as full
  updates. `blank`, `suspended` and `stopped` retain input-triggered recovery
  through idle samples. The first resumed image bypasses stale dirty hints and
  the previous frame-throttle timestamp. Verbose status/geometry diagnostics
  include the OS sleep flag and sampled nonzero-RGB count. These changes do not
  explain or cure the complete-black-frame trace by themselves.
- **Ownership reporting and routing:** status resolves the top-level
  SystemConfiguration UID against `/dev/console` and a unique UID/audit row.
  This lets the menu report the device-owner candidate despite contradictory
  graphics flags. Missing/ambiguous identities and device-owner changes fail
  explicitly. Root capture/input selection additionally requires matching
  OnConsole flags from IORegistry's `IOConsoleUsers`; the reported Ventura contradiction remains unavailable for
  that route instead of silently overriding the graphics evidence. Ordinary
  user attachment is unchanged, and the menu remains a red eye while visibility
  is unconfirmed.

Connecting a client does not request a display wake. The manual `wakeup` command
and existing input-triggered recovery still use `caffeinate -u -t 5` when invoked;
that action can light the monitor without unlocking or switching sessions.

The isolated ARM64 investigation build was produced at
`.build/ventura-capture-check/arm64-apple-macosx/release/mac-vnc-server-dev`.
These corrections are included in the 1.0 source. The investigation directory
contains earlier build manifests as well; it is not the release artifact record.
No running server was restarted or replaced.

### Subsequent Tahoe console-selection regression

After using the VNC menu's **Switch to Login Window**, the local Tahoe listener
rejected a valid root password because version 1.0 checked the nested
SystemConfiguration `SessionInfo` console flags. `/dev/console` and the
top-level state correctly selected root/audit 100907, while the nested rows still
marked root off-console and UID 501/audit 100021 on-console. IORegistry already
reported root on-console and the user off-console. This was a stale configd
snapshot after the switch, not proof that loginwindow was unavailable.

The resolver now checks the device-owner candidate against IORegistry's current
UID/audit/OnConsole metadata. A metadata-only probe reproduced the old resolver's
`ESTALE` result and verified the corrected root/audit selection as both the user
and root, without capture, input, session changes, or service management. Tests
cover stale configd flags in both switch directions and continue to reject the
earlier Ventura case, where IORegistry itself still identifies the user's
graphics session. The error message no longer assumes every verification failure
is temporary. This correction does not establish Ventura off-console capture.

### User-session attachment result

The Mac mini ran the standalone diagnostic through the production
`launchctl asuser` → audit/credential preparation → exec → verification path.
The same ownership/graphics-state combination appeared before and after it.

| Process / observation | Ventura result |
| --- | --- |
| Worker probe PID 11761 | UID 501, audit 100005, setugid 0, verification passed |
| Current session | UID 501, audit 100005, OnConsole true, locked true |
| Finder PID 4244 and Dock PID 4240 | UID 501, audit 100005 |
| loginwindow PID 152 | UID 501, audit 100005 |
| Visible loginwindow windows | PID 152, layers 2004 and 2001; sizes 1920×1080 and 30000×30000 |
| User display | ID 3, 1920×1080, asleep false |
| Separate root session | audit 100154, CG session 259, OnConsole false; no root loginwindow process listed |

This resolves the fresh-worker attachment question for that test. The worker,
Finder, Dock and the displayed loginwindow all belong to the same existing user
session. Loginwindow covers that desktop; the session has not been moved off
console. Changing the child's Unix UID or bootstrap route does not address this
observed state. Filtering loginwindow out of the image would not establish an
unlocked off-console session or correct app input.

The user additionally reports that **Ventura's built-in VNC can access an
off-screen user desktop while another regular user occupies the physical
monitor**. This establishes a native capability in that different state; it
must not be described as Ventura lacking off-console support. Our server still
needs the equivalent second-user comparison. No result for our server in that
condition has been reported yet.

The menu now explicitly reports a session that is still locked on console. It
retains the red eye; a root device owner is not enough to declare the user
hidden. A newly started user worker logs a corresponding warning when both
OnConsole and locked are reported. Account authentication does not itself
unlock or detach that graphical session.

### Remaining work

1. Compare our server with native VNC under the same condition: another regular
   user owns the physical monitor while the target account remains signed in.
2. Establish a verified session transition that leaves a login screen on the
   physical monitor while detaching the desired user desktop. The existing
   `SACSwitchToLoginWindow` request has not achieved that on the tested Ventura
   Mac mini, despite selecting **Switch to Login Window** rather than Lock Screen.
3. Validate input and capture after that transition, preserving the physical
   console's authentication and the selected account.

Read-only inspection of Tahoe's installed native service shows a separate
session-creation path (`CGSSessionCreateSessionIDWithOptions` for its LockScreen
helper) and `CGSCreateLoginSessionWithDataAndVisibility` for new login sessions.
The inspected `CGSCreateLoginSession` wrapper also requests a new loginwindow
session. These are private lifecycle operations, not a drop-in replacement for
selecting a different ScreenCaptureKit display. Ventura behavior and permission
requirements remain untested, so no automatic private session-creation call has
been added to the server.

The standalone numeric metadata probe remains outside production targets at
`.build/ventura-session-diagnostics/vnc-session-diagnostic`. It does not capture
images, post events, wake the display, alter login state, or manage services.
Its user-attachment path has now passed on both Tahoe and the Ventura Mac mini.
An exploratory Finder `bsexec` route could not complete account lookup on Tahoe
and is not included in the delivered probe or the server. No running server was
restarted or replaced during this investigation.
