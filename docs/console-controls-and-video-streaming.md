# Console menu controls and RealVNC video streaming in 1.7.1

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
through a descriptor reply. This private RFB connection carries raw pixels and
input at up to 30 FPS; clipboard and file-transfer protocols are disabled on it. Internal
connections always use the target worker's native desktop, avoiding routing
cycles. The listener handles the setup only, not desktop traffic.

At a switch, the router releases held keys/buttons, cancels account file drags,
invalidates cached frame coverage, and refreshes the cursor and pixels. Input
from an existing viewer waits until its first frame for the new desktop is sent.
Compression transactions allow an encoded but obsolete frame to be discarded
without corrupting either generic or Apple viewer streams. The console cursor
is embedded in its pixels; the external cursor overlay hides during the visit
and returns with the account desktop.

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
alone is not treated as success. Actual physical switching and older macOS
versions still require runtime checks.

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
from the user's confirmation above. Cross-account switching on a live root
listener remains to be exercised on the target Mac.
