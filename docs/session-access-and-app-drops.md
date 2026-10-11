# Locked-console access and drops into applications

Investigation: 2026-10-11, macOS 26.6.2 (25G83), repository baseline
`03af263`. This document describes findings and proposed work. It does not add
an off-console session backend or a new drag implementation.

## Session access: distinguish the required behavior

These are different features, with different macOS requirements:

| Behavior | Current implementation / required work |
| --- | --- |
| Keep the process running when an already logged-in user locks the screen | The per-user LaunchAgent has `KeepAlive` and is loaded in `gui/UID`. Remaining alive does not guarantee that capture or input works while locked. |
| Show the console lock screen and let the remote user unlock it | Requires capture and input to remain attached to the console/loginwindow across transitions. Current ScreenCaptureKit/input behavior has not been verified for this case. |
| Use the existing user's desktop remotely while the monitor stays at loginwindow or locked | Requires an off-console session backend, including a rendering surface and input routing for that session. The current server does not implement it. |
| Log in before any user GUI session exists, or select another user | Requires a system listener, macOS account authentication, and creation/attachment of a GUI session. The current per-user service cannot supply this. |
| Connect before FileVault has unlocked the startup volume | Outside a server running in macOS; the operating system and its services have not started. |

Locking the current console and switching away from a logged-in user through
Fast User Switching are also separate test cases. A virtual display added to the
current desktop is not, by itself, an independently accessible login session.

### What this server currently does

- `LaunchAgentService.swift` installs an Aqua LaunchAgent in `gui/UID`; it is not
  a boot-time system daemon.
- `StreamingScreenCapture.swift` gets displays from `SCShareableContent` and
  creates one `SCStream` per selected display. Startup waits for initial frames
  before starting the RFB listener. Recovery covers screen wake, stream failure,
  and input following a failed recovery; it does not manage login sessions.
- `MacInputController.swift` posts to `cghidEventTap`. There is no explicit
  routing to a separately selected GUI session.
- `RFBServer.swift` shares one capture/input desktop among viewers. Its handshake
  declines Apple's optional session-selection request.
- Apple security type 30 checks the configured **server password**. Its username
  is not authenticated as a macOS account. It cannot authorize entry to a user's
  login session without a separate account-authentication design.
- `VirtualDisplayLayout.swift` lays out existing displays. It does not create
  a macOS virtual display or a login session.

Changing a capability bit, increasing the first-frame timeout, running the same
capture loop as root, or changing the event tap alone does not implement the
missing session lifecycle.

### Evidence from the installed native service

Read-only inspection of the installed arm64e binaries found:

- `screensharingd` calls `CGSCreateLoginSessionWithDataAndVisibility` inside a
  path identified as `CreateOffConsoleLoginWindowSession`. The call at
  `0x10000f20c` passes visibility `0` and obtains a session ID.
- Its `HideCurrentSession` path calls
  `CGSSessionCreateSessionIDWithOptions` at `0x100041134`, using Apple's
  `LockScreen` helper. This is distinct from simply covering a display with a
  black window.
- `ScreensharingAgent` contains per-session check-in and console-connect/
  console-disconnect handling, references `CGSReleaseSession`, and uses
  `SLVirtualDisplay` objects.
- Its signature includes private entitlements for `logind.spi`,
  `SkyLight.virtualdisplay`, `SkyLight.displaycontrol`,
  `SkyLight.screencapturedirect`, and `screencapturekit.systemRecording`.
- The public `CGSession.h` exposes inspection of the current session. The
  public ScreenCaptureKit display filters do not expose an equivalent
  create/attach/off-console-login operation.

These observations establish that native support involves more than an RFB
initialization sequence. They do **not** prove that every possible third-party
implementation is impossible, or identify which private calls enforce which
entitlements. Copying entitlement names into this project's signature would
not grant Apple's privileges.

### Implementation choices

**Use the native service for session management.** Investigate letting Apple's
enabled Screen Sharing/Remote Management service own authentication and the
off-console session. A whole-connection TCP handoff/proxy can preserve its
protocol behavior, but then Apple also owns capture, encoding, encryption, and
drag behavior for that connection. It is not an extension of this server's
current streaming backend. This requires explicit system configuration and a
separate listening port; no system settings were changed during this research.
Resuming the same existing user desktop while keeping the console locked must
be demonstrated before claiming it works through a proxy.

**Build a dedicated session backend.** A system broker would authenticate actual
macOS accounts, locate/create the appropriate GUI session, and start a capture,
input, clipboard, and drag worker inside it. The broker would keep the console
state separate and hand authenticated RFB connections to the correct worker.
Session identity must be established before creating WindowServer connections;
changing only the worker's Unix UID is insufficient. Public API coverage and
private entitlement enforcement are feasibility gates. Do not advertise session
selection until capture, input isolation, reconnect, and teardown work.

Suggested first milestone: a disposable test account/VM with a moving test
window, showing fresh remote frames and input delivered to that window while
the physical console remains locked. Do this before changing the production
listener or client negotiation. Budget several days for this feasibility work;
a reliable custom backend is a multi-week project if that milestone succeeds.
These are engineering estimates, not verified delivery dates.

Acceptance cases: locked current user; switched-out current user; no user logged
in; disconnect/reconnect; screen sleep/wake; console login/logout during a
connection; wrong-account credentials; two viewers. All viewer connections must
use plain URLs such as `vnc://HOST:5902/`, with no encryption or mode query
overrides.

## Drops into applications other than Finder

Implementation follow-up: [staged file drops](staged-file-drops.md) adds persistent
reception and real-file drag sources. The proposals and estimates below are the
earlier design discussion; consult the follow-up for measured timing and limits.

Follow-up: [AppKit file-promise compatibility](appkit-file-promise-compatibility.md)
checks Terminal, iTerm2, Chrome, Lark, the installed ChatGPT-branded shell, and
IntelliJ's Java bridge. The findings support staging real files as the default;
a pure promise source does not cover the inspected common application paths.

### Why the current path favors Finder

For a client-to-server drag, `MacFileTransfer.startDrag` validates file URLs in
the archive and passes it to Apple's `SSDragHelper`. The native helper turns
file URLs into promised-file representations, starts a CoreDrag operation, and
extracts a drop destination. Its output command 10 supplies a **directory**.
`readDrag` validates/authorizes that directory and sends the viewer transfer
request `0x1e`; FileCopy then receives the items into it.

The helper disassembly contains `PasteboardSetPromiseKeeper`,
`CoreDragGetDropLocation`, `ExtractDropPath`, and the conversion to
`com.apple.pasteboard.promised-file-url`. This explains the dependency on a
destination that participates in file-promise delivery. There is no explicit
Finder bundle-ID restriction in our Swift code. Other apps that accept the
same promises may already work; no non-Finder compatibility matrix has been
measured. Apps that demand an existing local file URL cannot use a path naming
a file that exists only on the other Mac.

### Proposed paths

| Approach | Behavior | Tradeoff / approximate effort |
| --- | --- | --- |
| AppKit file-promise drag source | A server-side GUI helper supplies `NSFilePromiseProvider` items. When an app requests them, transfer into its destination, publish completed files, then complete the promise. | Good fit for promise-aware apps. Must correctly advertise content types, support cancellation, and bridge asynchronous FileCopy completion. About 3–5 engineering days for a prototype, then compatibility testing. |
| Transfer first, then drag real local files | Receive into a per-drag staging directory, then create an AppKit drag containing real `public.file-url` items. | Broadest prospective compatibility with file-URL targets. Files must be complete before the app consumes them; large transfers introduce a wait or a second drag. About 1–2 weeks for a robust prototype and initial app testing. |
| Receive, then open/import explicitly | Receive files and offer an explicit Open With action, file clipboard paste, or a documented app-specific import action. | Smallest fallback, but opening a document does not reproduce dropping it into a message, document, or browser upload area. About 1–3 days for a basic workflow. |

Estimates assume reuse of the existing FileCopy transport and are not additive
commitments. None of these guarantees acceptance by arbitrary applications.

The recommended direction is **staging plus a real-file drag**, with a
file-promise path for apps that support it. Separate transfer from drag UI:

1. Keep the existing native wire protocol, file validation, and bounded transfer
   machinery. Add a completion/error callback carrying the final staged URLs.
2. Receive only the items selected for the active drag into a private staging
   directory. Use the existing authorization checks; do not authorize arbitrary
   paths sent by a viewer.
3. Prototype a dedicated AppKit drag-source helper. `CGEvent` mouse movement
   alone cannot create a drag pasteboard. A genuine source view/window and
   `NSDraggingSession` must offer the data and report the accepted operation.
4. Establish whether Screen Sharing lets the server request files early enough
   to finish while the mouse is held. Test a small file and a deliberately slow
   transfer. Do not assume a remote drop can be paused indefinitely or replayed
   after release without disturbing the target app.
5. If the original gesture cannot be preserved, use an explicit two-stage
   receive-then-drag workflow. Offer a drag handle for the received files instead
   of silently synthesizing a late drop into whatever app is now under the
   pointer.
6. Retain completed files long enough for apps that open them lazily. A drag-ended
   callback is not proof that the target finished reading. Use documented
   retention/cleanup behavior and deterministic cleanup for partial transfers.

First targets to test: a document editor, an image editor, a mail attachment
area, a browser file input/drop zone, and a folder in Finder. Include multiple
items, a folder, Unicode names, name collisions, a large/slow transfer,
cancellation, Observe mode, and disconnection. Sandbox access needs testing
with a genuine drag; sending a path string through Accessibility or AppleScript
does not provide equivalent file access.

### The reverse direction has a different owner

For server-to-client drops, the destination is on the client and Apple's Screen
Sharing app owns the local drag. A new helper installed only on the server
cannot force that client drag to advertise different pasteboard types or make
an arbitrary local app accept it. Test existing promise-aware client apps;
the reliable fallback is transfer into local Finder and drag the resulting
local files into the app. Universal custom delivery in this direction may need
a client companion or custom viewer, which is outside the current server-only
constraint.

Neither proposal depends on disabling encryption. The requirement remains a
plain connection URL; encryption policy is a separate server configuration.

## Validation performed

This investigation inspected the repository, public SDK headers, native symbol
imports, code signatures, and disassembly. It did not lock/log out this host,
create a GUI session, change system services, restart port 5900/5902, or inject
a drag into a user's app. No runtime support is claimed from the static checks.

Native binary SHA-256 values, for reproducing the static findings:

```text
screensharingd:
a4ca4dac4e54891b760580e4e58cce3ec77e0e4e1d9dd6c72060959ceb223b44
ScreensharingAgent:
d1d38dc66e4d8a917201bf04816a6dc34cb34e0de77ba36885586f3f944e0791
SSDragHelper:
cee0c02ed13886e460955dbb9c63e5b3bc8577d400afa5031e9cee39281c59cb
```
