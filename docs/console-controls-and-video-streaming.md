# Console menu controls and RealVNC video streaming

## Menu actions

A user worker connected to a root listener offers two actions when its session
checks confirm that it is off console:

- **Bring This Session to Console** asks macOS to move that user's desktop onto
  the physical display. Existing VNC clients remain attached.
- **View Console Session** shows the current physical console, including
  loginwindow or another user's desktop, through each viewer's existing RFB
  connection. It does not switch the physical display or require a reconnect.

All viewers attached to the originating account worker share the selection.
Viewers connecting during a console visit also see the console. Keyboard and
mouse input follow the displayed desktop. The original canvas size stays fixed:
large console desktops scale down, smaller desktops are centered with black
borders, and pointer coordinates map into the fitted image. Clicks in the border
are ignored. Clipboard and file transfer pause during the visit; active transfers
are cancelled, and fresh transfers can start after returning home.

**Return to Account Session** is available on the original desktop. On a user
console desktop, **Return Remote Viewers to Their Accounts** sends visiting
viewers home while keeping their external connections open. Loginwindow has no
menu; a change of console owner or closure of the private desktop connection
returns viewers automatically. A failed initial console capture leaves the
original desktop selected.

## Connection and privilege handling

The original worker retains each external socket, authenticated identity,
encryption keys, persistent Zlib/ZRLE stream and negotiated viewer features. The
root listener creates an anonymous Unix socket pair and passes one endpoint to
the selected console worker. The other endpoint reaches the originating worker
through a descriptor reply. This private RFB connection carries raw pixels at
up to 30 FPS, separate cursor shapes/positions, and immediate input messages;
clipboard and file-transfer protocols are disabled on it. Internal
connections always use the target worker's native desktop, avoiding routing
cycles. The listener handles the setup only, not desktop traffic.

At a switch, the router releases held keys/buttons, cancels account file drags,
invalidates cached frame coverage, and refreshes the cursor and pixels. Input
from an existing viewer waits until its first frame for the new desktop is sent.
Compression transactions allow an encoded but obsolete frame to be discarded
without corrupting either generic or Apple viewer streams. Since 1.7.5, the
console cursor uses the same client-rendered RichCursor path as the user desktop
when available. Observe viewers and clients without RichCursor receive a cursor
composited at the reported host position. Explicit embedded capture also remains
supported. The account cursor is refreshed when returning home.

Requests contain only an action, with no caller-selected UID, audit session or
graphics ID. The parent binds requests to its child and revalidates root
privileges, the child's login generation, and the current console owner. The
target worker rejects stale console admissions and ends internal visits when
console ownership changes. User workers retain their permanent privilege drop.
Non-root listeners do not expose these actions. A console visit uses the root
listener's authority and does not ask for the console owner's password.

Bringing a desktop to console resolves `kCGSSessionIDKey` from a fresh session
list using both UID and audit ID. The dynamically resolved
`CGSSwitchConsoleToSession` entry point takes the graphics ID, not the audit ID.
Its implementation was inspected on macOS 27.2.1 (26B131); after calling it, the
listener waits up to ten seconds for verified console ownership. An API return
alone is not treated as success. The user subsequently confirmed that **Bring
This Session to Console** works on macOS 13.7.8.

## Ventura loginwindow startup failure and 1.7.2 diagnostics

On macOS 13.7.8, the user reports that **View Console Session** leaves the
original account desktop visible and eventually reports `socket error: client
disconnected`. The physical display is at loginwindow. In the supplied trace,
the root capture service registers, the UID 0/audit 101098 worker starts as PID
24527, and it reaches `ScreenCaptureKit: enumerating displays`. The original
viewer and user worker remain usable. The trace does not include the target
worker's failure or exit reason, so it does not yet establish why capture fails.

Version 1.7.2 forwards capture/input startup errors to the requesting worker
over the private RFB connection, including the target identity and failed
initialization stage. This detail is restricted to the already-authorized
internal connection; network authentication retains its existing generic errors.
A failed target worker is retired so a retry can start with fresh framework
connections and capture service state. The original viewer stays connected.
Abrupt worker exits now log the UID, audit session, PID and exit code or signal.
The menu labels a pending switch and clears its in-progress flag before showing
the error dialog.

These changes improve failure recovery and diagnosis; they do **not** establish
that Ventura loginwindow capture works. Successful initialization is logged as
`Console desktop first image ready` followed by `Console view installed`.

The subsequent 1.7.2 trace identifies the failing operation. At
2026-11-23 16:49:40.704 UTC, the UID 0/audit 101105 worker begins display
enumeration. At 16:50:40.710, it reports that ScreenCaptureKit enumeration timed
out after 60 seconds, forwards that error to the source worker, and exits with
status 1. The listener releases its root capture service, while the original
UID 501/audit 100005 desktop continues streaming. This is a handled startup
failure, not evidence of a worker crash, viewer freeze, or failed RFB handoff.

In 1.7.2, `Console capture service ready` means only that `launchctl bootstrap`
accepted the temporary job in `user/0`. It does not confirm that the helper
successfully execed `/usr/libexec/replayd`, that replayd stayed alive, or that it
answered the worker. The job does not capture the helper's stderr. The timeout's
generic suggestions about older instances and Screen Recording permission are
not established causes of this failure.

The service-state snapshot was collected on the affected Ventura Mac **while
View Console Session was waiting**, before the target worker and job were cleaned
up, using these read-only commands:

```sh
sudo /bin/sh -c '
for p in /private/var/run/mac-vnc-console.*/capture.plist; do
  [ -f "$p" ] || continue
  label=$(/usr/libexec/PlistBuddy -c "Print :Label" "$p")
  /bin/launchctl print "user/0/$label"
done
/usr/bin/plutil -p /System/Library/LaunchAgents/com.apple.replayd.plist
/usr/bin/pgrep -lf replayd
'
```

The owned job was `spawn scheduled`, with `last exit reason =
OS_REASON_CODESIGNING`, one run, and all three endpoints inactive. The separately
listed replayd PID did not prove this owned job was running. The deployed server
passed `codesign --verify --strict --verbose=4`. The kernel then supplied the
decisive error, repeatedly naming `/usr/libexec/replayd`:

```text
AMFI: Launch Constraint Violation (enforcing), error info: c[1]p[1]m[1]e[1],
(Constraint not matched) ... /usr/libexec/replayd, launch type 0
```

Ventura was rejecting the helper's `exec` of Apple's capture daemon. This
establishes a launch-constraint failure, not an invalid server signature or a
Screen Recording permission diagnosis.

The 1.7.2 validation passed 304 tests in 23 suites, including failed capture,
retry on the same original viewer, startup EOF/timeouts, and bounded error
messages. Two disposable workers with an invalid display selection returned the
specific capture error before closing their private sockets, then exited for a
fresh retry. Normal live capture, overlapping viewers, idle teardown and listener
cleanup also passed. These checks ran on the development Mac, not Ventura.

## Direct capture-service launch in 1.7.3

Version 1.7.3's temporary job named `/usr/libexec/replayd` directly in `ProgramArguments`,
so launchd starts Apple's signed image. No wrapper execs that image, and no
signature, entitlement, or macOS security setting is changed. The worker still
attaches to and verifies the selected loginwindow audit session before capture
and input; the daemon uses the root service domain's normal audit context.
Worker identity and captured display geometry remain mandatory checks. A full
Ventura loginwindow capture/input test is still required for this direct launch
configuration.

A short-lived check in root's bootstrap queries the owned job's PID and verifies
that it is root's `/usr/libexec/replayd`, parented by launchd, across two samples.
It waits at most ten seconds, with an outer twelve-second process deadline.
Missing or malformed job information fails closed. `process ready` confirms the
daemon process, not successful frame delivery. Failure prints the owned launchd
job's status and aborts before the worker starts its 60-second capture request.

Versioned ownership metadata preserves strict recovery of both the old helper
jobs and the new direct jobs. Cleanup briefly waits for its retained Mach
endpoint to die before releasing the ownership lock, covering the race where
bootout returns before replayd finishes exiting. The external viewer remains
in the source worker throughout a switch or failure.

The 1.7.3 version of `scripts/test-console-capture-service.py` compiled the production
lifecycle code with a synthetic console identity, starts and verifies the real
Apple daemon twice, and checks immediate retry and cleanup. It starts no screen
capture and sends no input. It skips existing console-service metadata and
retains the production refusal to replace unrelated capture services. This
passed on the development Mac; it does not establish Ventura session routing.

The completed 1.7.3 validation passed **308 tests in 24 suites**. The signed arm64
release (minimum macOS 13.0) also passed live user-session capture, overlapping
viewers, idle teardown, failed-handshake cleanup, parent-channel shutdown and
the account-listener smoke check. The stable executable is
`.build/release-latest/mac-vnc-server`.

The user's subsequent Ventura 1.7.3 test at 2026-11-23 17:21 UTC still fails.
The job directly names `/usr/libexec/replayd`, but launchd reports `not running`,
`last exit reason = OS_REASON_CODESIGNING`, one run, and all endpoints inactive.
The readiness check stops the attempt after about eleven seconds, before a
loginwindow worker starts, and the original account desktop continues streaming.
Thus direct execution from the custom job does **not** resolve Ventura's
code-signing termination. The local lifecycle test did not reproduce Ventura's
launch policy.

The isolated check of Apple's original
`/System/Library/LaunchAgents/com.apple.replayd.plist` in `user/0` also returned
`Bootstrap failed: 5: Input/output error` on Ventura. No successful job startup
was established. Ventura's supplied stock plist has no session-type restriction;
the development Mac's stock plist limits loading to LoginWindow/Aqua. Error 5
alone does not prove why either bootstrap failed. This path was not adopted.

## Capture-service audit attachment in 1.7.4

The user also reproduced failure on the development Mac (macOS 27.2.1, 26B131):
loginwindow audit 101855 returned `Failed to find any windows to capture`.
This is not a Ventura-only problem. The 1.7.3 direct-launch job ran replayd in
root's background audit session while the worker joined loginwindow. A process
readiness check and matching display geometry were insufficient to detect that
the capture daemon was attached to the wrong desktop.

A real-loginwindow comparison restored the earlier audit-attaching helper and
used the same 1.7.3 worker executable. It captured 1728×1117 loginwindow frames,
decoded full Zlib updates plus RichCursor, and passed overlapping viewers,
capture stop/restart, failed-handshake cleanup and parent-channel shutdown.
The temporary service was removed and the user's listener/viewer remained live.

Version 1.7.4 restores attachment before execing replayd and verifies the daemon's
actual audit ID via `auditon(A_GETPINFO_ADDR)`, in addition to its PID, UID, parent
and executable. The helper runs before normal AppKit/shutdown initialization.
Readiness rejects a wrong-audit daemon before starting a target worker. Current
schema-3 metadata still recognizes exact earlier helper and direct-job schemas
for owned orphan cleanup. Viewer sockets, authentication and encoder state remain
in the source worker; the switch installs a bridge only after its first frame.

The live service test now uses real loginwindow ownership. It deliberately omits
attachment for one negative fixture, then exercises the production service twice
with optional private-worker capture. Synthetic console identity is no longer
used to claim that this capture path works.

The signed 1.7.4 arm64 release passed **309 tests in 24 suites**. Its live
regression fixture rejected background audit 100021 when loginwindow audit
101855 was required. Two production-service cycles then captured 1728×1117
loginwindow frames. Four forced root-worker startup failures forwarded the
specific invalid-display error and retired for fresh retry. Ordinary user
capture and the listener smoke check also passed. The existing listener and
user worker stayed running, and every probe-owned root service was removed.

This 1.7.4 correction does not resolve Ventura's separate AMFI launch-constraint
rejection. An experimental public CGDisplayStream path produced frames in an
ordinary user desktop here, but failed to create a stream in the attached root
loginwindow. Its wrapper mapped that failure to EACCES; the mapping does not
establish a Screen Recording permission diagnosis. That experiment was not
shipped in 1.7.4; the later awake-screen Ventura probe is recorded below.

### Ventura 1.7.4 retest

The user's 2026-11-24 02:28–02:30 Asia/Shanghai trace confirms that **View
Console Session still fails on macOS 13.7.8 with 1.7.4**. All three attempts
register their uniquely owned job, wait about 10–11 seconds, and report
`state = not running`, `runs = 1`, `last exit reason = OS_REASON_CODESIGNING`,
and inactive capture endpoints. There is no ready loginwindow worker and no
`verified_audit` message. The readiness timeout is a consequence of failed
service startup; increasing it would not address the recorded termination.
The earlier kernel trace identified an AMFI launch-constraint violation for
replayd. This retest is consistent with that unresolved problem, though its
launchd snapshot alone does not identify which image was rejected this time.

The first two targets were loginwindow audit 101113. Bringing UID 501/audit
100005 to the physical console succeeded at 02:29:44, and requesting Fast User
Switching selected a fresh loginwindow audit 101117 for the third attempt.
It failed identically. Thus the failure also reproduces after a real session
transition and is not explained by reusing just the first audit identity.
The job's printed `asid = 100004` is its launchd domain context, not an
observation of the helper's audit membership after attachment.

Each failed attempt reports owned-service release. The same viewer client ID
stays connected throughout all three failures and the successful bring-to-console
operation, accumulating 533 updates before its reader reports a disconnect at
02:30:47, about 30 seconds after the last failed switch. The user-worker capture
rebuilds report recovery during physical transitions; these messages are not
evidence of loginwindow capture. This trace confirms failure recovery and retry
remain usable, while the requested Ventura console view remains unavailable.
The user subsequently confirmed that console viewing works on this VM, while
reporting cursor movement lag relative to the user desktop. Verification on
other macOS versions is pending; the isolated checks are recorded separately above.

## Console cursor latency in 1.7.5

The earlier private bridge requested only Raw/DesktopSize rectangles, causing
the target worker to composite its cursor into pixels and the source worker to
hide the viewer's cursor. Visible pointer movement consequently waited for
host cursor sampling, the private framebuffer update and the external update.
This differed from the user desktop's client-rendered cursor.

The private bridge now requests RichCursor and PointerPos. It relays cursor
shapes, transparency masks, hotspots and host positions separately from screen
pixels. Cursor-only changes wake the source worker without advancing the screen
pixel sequence. The router applies the same scale and letterbox placement as
the console image. The external controlling viewer receives RichCursor shapes
and moves its own overlay immediately; delayed PointerPos messages are confined
to the private bridge. This retains host-cursor tracking for Observe mode and
viewers that require compositing, without pushing delayed positions onto the
controlling viewer.

Tests cover cursor replacement/restoration over one viewer connection, position
and shape updates on static pixels, transparent masks, scaling/hotspots,
letterboxing, Observe/non-RichCursor fallback with old-position erasure,
maximum configured scale, and malformed cursor rectangles. A real disposable
loginwindow worker served 1728×1117 frames plus RichCursor and PointerPos through
the private bridge protocol. The user's existing capture service remained
registered; no input was sent. These checks verify the protocol and rendering
behavior; perceived latency still requires the user's viewer test.

The final 1.7.5 validation passed **314 tests in 24 suites**. The signed arm64
release (minimum macOS 13.0) passed live private-bridge cursor/frame delivery,
ordinary user capture, overlapping viewers, idle cleanup, failed-handshake
cleanup and the listener smoke check. `.build/release-latest/mac-vnc-server`
is the stable executable path. The running server was not restarted.

The separate Ventura startup failure was unchanged in 1.7.5. A standalone diagnostic at
`scripts/probe-console-display-stream.m` tests Ventura's public CGDisplayStream
API in a freshly attached loginwindow process, without registering replayd jobs.
See [probe instructions](console-session-backend.md#standalone-ventura-capture-probe).

## Ventura CoreGraphics capture in 1.7.6

The user repeated the standalone probe on macOS 13.7.8 after turning on the
physical display. It verified UID 0/audit 101117 with no root replayd registered
and received a valid 160×100 BGRA frame, with 48/64 nonzero RGB samples and a
successful stop. The earlier no-frame result occurred before this awake-screen
retest; the user desktop's awake virtual display did not prove the physical
display was awake.

Version 1.7.6 selects the public `CGDisplayStream` API only for UID 0 on macOS 13.
The listener skips its auxiliary replayd job, avoiding Ventura's recorded AMFI
rejection. The worker attaches and verifies the same loginwindow identity,
requests wake if a selected display reports asleep, and requires complete
frames from all selected displays before installing the console view. Blank
callbacks clear old pixels; identity or display-geometry changes end capture.
Borrowed IOSurface pixels are copied before the callback returns.

The existing RFB connection, adaptive pacing/encoding, separate cursor path
from 1.7.5, and verified root HID input adapter remain in use. User sessions and
loginwindow on macOS 14+ continue using ScreenCaptureKit. The affected Ventura
host has verified native frame delivery while awake; the complete 1.7.6 menu
switch, input and automatic wake still need a host retest.

Local validation passed **324 tests in 25 suites**, plus all 10 CoreGraphics
tests after tightening the complete-frame startup check for a display that goes
blank. Two native CGDisplayStream start/stop cycles delivered frames and released
callback storage exactly once. The final signed arm64 release (minimum macOS
13.0) passed live user Zlib/RichCursor and loginwindow Raw/RichCursor/PointerPos
checks, including overlapping viewers, two capture restart cycles, handshake
failure and parent-channel cleanup. The listener smoke check also passed.
These live server checks ran on macOS 27.2.1 using its ScreenCaptureKit backend;
they do not substitute for the pending Ventura server retest. The existing
server and its root capture service remained running.

## Physical loginwindow transition status in 1.7.7

On this macOS 27.2.1 VM, the user reported that **Switch to Login Window** after
**Bring This Session to Console** appeared to need viewer disconnection. The
system log shows the user worker's request was accepted at 2026-11-24
03:29:50.689 Asia/Shanghai, and the new loginwindow session was created by
03:29:51.181. Its login UI did not signal readiness until 03:30:22.852; the
WindowServer console switch followed at 03:30:23.070. A second attempt took a
similar 32 seconds. SecurityAgent logged two roughly 15-second pauses around
video-decoder initialization and a login-UI window preparation timeout. These
logs locate the delay in macOS login UI startup; they do not establish that VNC
capture caused it.

The user then kept the viewer connected for 45 seconds and confirmed that the
physical console switched by itself. Viewer disconnection is not required.
Version 1.7.7 keeps **Switching to Login Window…** pending after the native API
acknowledges, until verified graphics-console ownership belongs to loginwindow.
It logs the completed audit identity and elapsed wait. Unknown ownership does
not count as success; source-session loss, another user taking the console, or
a 60-second confirmation timeout reports the specific outcome. Menu controls
are restored before any error dialog. The external viewer remains connected
and continues to show its own account desktop. This status fix does not shorten
macOS's login-UI startup time.

Validation passed **330 tests in 26 suites**, including delayed completion,
unavailable/invalid ownership, confirmation timeout, another user taking the
console, source-session loss and cancellation. The signed arm64 release
(minimum macOS 13.0) passed the account-listener smoke check. Physical switching
was observed in the user's existing 1.7.6 session; the 1.7.7 status change was
tested with controlled ownership observations without initiating another
physical transition or restarting the running server.

### Follow-up audit: shared VM decoder attachment exhaustion

The user's recollection that switching was faster is confirmed by retained
system logs. All times below are 2026-11-24 Asia/Shanghai, measured from
`SACSwitchToLoginWindow` to the login UI shown notification:

| Request | Caller | Elapsed |
| --- | --- | --- |
| 01:49:57.808 | mac-vnc-server | 2.397 s |
| 01:51:02.460 | mac-vnc-server | 1.902 s |
| 01:52:10.816 | mac-vnc-server | 1.765 s |
| 03:29:50.689 | mac-vnc-server | 32.047 s |
| 03:46:22.955 | macOS Control Center | 31.771 s |

Both fast and slow requests created fresh loginwindow sessions, so reuse of an
already prepared loginwindow does not explain this difference. In the fast
01:52 attempt, SecurityAgent initialized the paravirtualized HEVC decoder within
about 24 ms of creating its tile-decompression session. In the slow 03:29
attempt, the kernel logged `stalling for detach from
AppleVideoToolboxParavirtualizationDriver` at 03:29:52.215 on SecurityAgent's
main thread. About 15 seconds later, SecurityAgent started VTDecoderXPCService;
that process hit the same kernel stall at 03:30:07.318. It continued after
another 15 seconds, and the login UI appeared. The native Control Center
attempt has the same two stalls, at 03:46:24.505 and 03:46:39.560.

Read-only IORegistry snapshots found exactly **1,020** attached
`AppleVideoToolboxParavirtualizationUserClient` objects, with no creator fields
even when read as root. Apple's published XNU
[`IOService::attach`](https://github.com/apple-oss-distributions/xnu/blob/main/iokit/Kernel/IOService.cpp)
logs this message when the provider has more than `kIOServiceBusyMax - 4`
children and waits for a detach with a **15-second deadline**.
[`kIOServiceBusyMax` is 1023](https://github.com/apple-oss-distributions/xnu/blob/main/iokit/Kernel/IOServicePrivate.h).
The published source is explanatory, not a verified source match for this
VM's installed XNU build. The observed count, exact kernel messages and two
15-second waits strongly identify shared decoder attachment exhaustion as the
immediate cause of the delay.

This does not identify who accumulated those objects. The VNC changes and live
diagnostics did temporarily register root replayd jobs and start/stop capture
streams between the fast and slow attempts. The audit found no remaining root
capture job, root replayd endpoints, or owned capture plist. It found no direct
VideoToolbox decoder calls or persistent macOS preference changes in the
inspected server and diagnostic sources. Other processes used the decoder
during the interval, but their activity does not establish responsibility
either. An indirect effect of VNC capture or its diagnostics remains unproven
and has not been ruled out.

The 1.7.7 status change was built after the slow attempts, and the running server
was still 1.7.6. A VM restart is expected to clear accumulated kernel objects;
testing native switching before starting VNC, then after console capture, would
help establish whether this work reproduces the buildup. No restart, service
shutdown, or physical session switch was performed during this audit. Raw
evidence is retained locally under `.build/investigation/`, including
`loginwindow-fast-0152.log`, `loginwindow-slow-0329.log`,
`videotoolbox-driver-timeline.log`, `native-switch-driver-stalls.log`, and
`videotoolbox-driver-root-ioreg.plist`.

The [subsequent driver lifecycle investigation](vm-videotoolbox-driver-leak-2026-11-24.md)
found 1,010 attached objects with no live process connection, traced the installed
driver's missing termination/detachment in `clientClose()`, verified the installed
kernel's threshold, and reproduced a 15.002-second failure with a standalone
connection probe. It also records independent reports and a Chromium/Electron
mitigation. Attribution of the historical orphaned objects remains incomplete.

## RealVNC iPad freeze

The supplied 1.7.0 trace identifies an RFB 3.8 viewer advertising
`[6,24,22,21,16,15,5,2,0,1,-314,-239,-223]` and using 32-bit little-endian Zlib
pixels. Updates initially flow normally. FPS drops to 45 and then 30, followed
by `adaptive scale changed to 0.75` at `2026-11-23T15:24:25.036Z`. The connection
ends about four seconds later with 92 updates and zero network stalls. The user
reports that mouse input continued and macOS Screen Sharing on the same desktop
kept streaming throughout the freeze.

This evidence strongly points to the generic viewer's automatic resolution
change, rather than a shared capture stall. Version 1.7.1 removes load-driven
scale changes for all viewers. It retains adaptive FPS/compression, genuine
display-resize handling and explicit Apple scaling requests. The configured
`--scale` therefore stays constant during video or network pressure. Version
1.7.0's fixed native ScreenCaptureKit FPS ceiling is retained; client rate
adaptation happens before copying pixels and when sending frames.

After testing 1.7.1, the user confirmed that RealVNC now works correctly. This
confirms the reported freeze is resolved on the affected setup; bandwidth during
full-screen video has not yet been measured.

## Validation

Automated coverage includes Raw/Zlib/ZRLE console round trips over a single
viewer connection, an encrypted Apple round trip without rekeying, cursor
hide/restore, letterboxing and input ownership, clipboard suspension, transfer
cancellation/recovery, and descriptor delivery through the control reply.
The overload regression test uses the iPad's exact advertised capabilities and
pixel format and requires constant dimensions with a valid persistent Zlib
stream throughout.

The full suite passed 299 tests in 23 suites. After the final transfer
cancellation guard, all 33 focused file-transfer and console-switch tests passed,
including the added suspension/resume case. The arm64 release passed strict
ad-hoc signature verification. Live animation ran for 30 seconds in each mode:
the iPad capability profile received 321 fresh frames; continuous mode received
329 frames with 328 fence acknowledgements. Both decoded successfully with zero
resizes. The listener's privilege report, type-30 challenge, absence of capture
before authentication, and Ctrl-C cleanup checks passed.
Two live capture/reconnect cycles at 1728×1117 also passed, including RichCursor,
overlapping viewers, idle teardown, failed-handshake cleanup and parent-channel
shutdown with a connected viewer.

Release validation uses the Xcode toolchain and these disposable local checks:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --scratch-path .build/xcode-validation --no-parallel
python3 scripts/test-video-streaming.py .build/release-latest/mac-vnc-server --seconds 30
python3 scripts/test-video-streaming.py .build/release-latest/mac-vnc-server --seconds 30 --continuous
python3 scripts/test-session-capture.py .build/release-latest/mac-vnc-server --cycles 2
python3 scripts/test-account-listener.py .build/release-latest/mac-vnc-server
```

The animated capture check negotiates the iPad's capabilities, decodes the
persistent Zlib stream and CopyRect updates, checks fresh pixels, and requires
zero resizes under a slow reader. It creates only a temporary window and worker,
saves no screenshots and does not restart an existing server. The automated
checks use synthetic RFB clients; validation of the actual RealVNC app comes
from the user's confirmation above. The 1.7.6 loginwindow path on the Ventura host
still needs end-to-end verification, as described above; viewing another user's console desktop
has not yet been confirmed there.
