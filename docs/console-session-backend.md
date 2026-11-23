# Loginwindow session backend

Loginwindow is served by the same account-worker architecture as user desktops.
Start a root listener, then authenticate from Screen Sharing using the enabled
macOS root account and its actual password:

```sh
sudo /absolute/path/mac-vnc-server-dev --bind utun4 --port 5902 --verbose
```

Connect with a plain `vnc://HOST:5902/` URL. The listener does not read
`VNC_PASSWORD`. Root authentication selects the physical console owner at that
moment: UID 0 at loginwindow, or the current user's session when a user owns the
console. A user target reuses that user's worker, with its normal features.

Each connection remains attached to its selected session. A user worker can stay
off console; a loginwindow worker ends when its verified console identity
changes. Reconnect as root to select the new console owner. The former
`--session console` supervisor and its raw-frame IPC transport have been removed.

## Process structure

```text
root account listener
  ├─ user account worker (one per UID/audit session)
  │    ├─ ScreenCaptureKit → encoder → client TCP sockets
  │    ├─ shared input coordinator → session CGEvent posting
  │    └─ clipboard, file transfers, menu UI
  └─ loginwindow account worker (UID 0/audit session)
       ├─ CoreGraphics (macOS 13) / ScreenCaptureKit (14+) → encoder → client TCP sockets
       └─ shared input coordinator → verified IOHIDPostEvent adapter

launchd
  └─ isolated root replayd on macOS 14+ (Apple's capture service, managed by the listener)
```

The listener transfers an authenticated socket once, using `SCM_RIGHTS`; it does
not relay frames or input. Workers attach and exec before initializing graphics,
so framework connections and caches belong to the target session. There is no
separate capture-manager process. On macOS 14+, short-lived launchctl commands manage the root
capture service. The owned helper joins loginwindow's audit session before
executing Apple's signed replayd binary. Both daemon and worker must belong to
the selected audit session. Version 1.7.3 incorrectly launched the daemon in
root's background session; version 1.7.4 restores attachment and checks it.

## Shared capture and input

User workers and macOS 14+ loginwindow workers use `StreamingScreenCapture`:
ScreenCaptureKit streams, RichCursor, dirty-region hints, and a bounded queue
retaining the newest pending capture. All backends share capture-driven wakeups,
adaptive frame acceptance, RFB encoders and flow control. Loginwindow additionally verifies UID/audit/console ownership and
requires ScreenCaptureKit display IDs and geometry to agree with CoreGraphics.
A missing display list or display-ID mismatch sends one display wake signal and
retries discovery up to three times with fresh ScreenCaptureKit snapshots.
Console ownership is rechecked before discovery, before wake, and after discovery;
a changed identity aborts startup. Permissions and invalid geometry do not
trigger wake/retry. A persistent mismatch reports both offered and active display
IDs and fails closed instead of substituting a user's desktop. Clipboard,
file transfer, Received Files and menu UI are disabled for UID 0.

Since 1.7.6, UID 0 on macOS 13 uses `CoreGraphicsConsoleCapture` and the public
`CGDisplayStream` API within the attached worker. No auxiliary replayd job is
registered. The stream copies borrowed BGRA IOSurfaces synchronously into the
shared frame store, uses the same separate-cursor path when available, and clears
pixels on blank callbacks. Startup requests a wake if the selected physical
display reports asleep and requires a complete frame from every selected display
within five seconds after the streams start. A missing frame reports display
sleep status; it does not install the console view. Identity or display geometry
changes invalidate capture. Remote input can request another wake for a blank
or sleeping display. Native streams remain at the configured FPS ceiling while
frame acceptance adapts before copying pixels.

`MacInputController` builds mouse, keyboard, modifier, scroll and release events;
`SharedInputController` coordinates ownership between clients. User workers post
CGEvents to their attached session. Loginwindow's final posting adapter translates
those events to `IOHIDPostEvent`, guarded by console identity checks before
injection, including cleanup releases. A posting failure closes the worker;
permission preflight alone is not treated as successful delivery.

“Verified HID adapter” is this project's wrapper, not an Apple API name. Root
attachment, console identity and posting results are checked. On the tested
Tahoe host, fresh attached root probes could capture loginwindow but posting
pointer movement at either `cgSessionEventTap` or `cghidEventTap` left the pointer
unchanged. Both default and combined-session event sources were tried. The
working direct HID path is retained. Creating a CGEvent event tap observes or
filters events; it is not itself a replacement injection mechanism.

## Temporary root capture service

Only a UID 0 loginwindow worker on macOS 14+ needs the auxiliary root replayd service. Its
lifecycle belongs to the listener. An ordinary user worker uses that user's
existing macOS capture service.

The listener creates a root-owned mode-0700 directory under
`/private/var/run/mac-vnc-console.XXXXXX/`. Its mode-0600 `capture.plist` contains
the executable path, audit ID, owner PID, unique job label and Mach service names.
Version 1.7.4 stores ownership in schema version 3 of `MacVNCServerOwnership`;
the job command is this executable's `--console-capture-service` helper, which
attaches before executing `/usr/libexec/replayd`.
It contains no credentials or pixels. No permanent LaunchDaemon or user-home
configuration is installed.

The listener holds an exclusive lock and recovers abandoned owned jobs before
registration. A live owner or unrelated root capture service prevents a new
registration. Per-user bootstrap lookup queries user 0 without changing the
listener's own graphics session. Launchctl children inherit neither account
credentials nor client sockets. The root-owned zero-byte mode-0600 file
`/private/var/run/mac-vnc-console-capture.lock` stays until reboot so concurrent
opens cannot obtain locks on different inodes.

A bounded helper in root's bootstrap verifies the owned job's PID, UID, parent,
executable and actual audit ID across two samples before worker startup. A live
daemon in the wrong audit session is rejected. This proves process attachment,
not frame delivery. The worker independently attaches to and validates the
selected loginwindow session and requires matching display geometry.
Ventura has rejected both helper and direct custom-job launches with an AMFI
launch-constraint violation. Apple's original plist also failed to bootstrap in
the isolated Ventura check (error 5). Version 1.7.6 avoids that launch path on
Ventura by selecting CoreGraphics for its loginwindow worker.

Worker teardown, startup failures and graceful shutdown attempt to boot out the
uniquely named job and remove its metadata. Registration/cleanup launchctl calls
have a four-second deadline and cleanup has one retry. The readiness helper has
a ten-second deadline inside a twelve-second process deadline. After bootout,
cleanup waits up to two seconds for its retained Mach endpoint to die before
releasing the ownership lock. Forced exit can interrupt cleanup;
retained metadata lets the next root startup retry before registering a service.
Startup recovery also runs when no loginwindow worker is immediately needed.

Recovery validates directory ownership/mode, the regular plist, generated label
and fields, and an owner PID that no longer exists (or this listener's own failed
cleanup). Symlinks, malformed metadata, live/reused PIDs and unrelated jobs are
left alone. The exact old helper, 1.7.3 direct-launch, and current helper schemas
are recognized. Failed bootout retains the metadata and reports the job. There is no
blanket termination or replacement of replayd services.

## Validation and limitations

Unit/socket tests cover identity matching, capture geometry, blank-frame handling,
newest-frame coalescing, shared input ownership, encrypted input, account routing
and descriptor handoff. Optional checks are:

```sh
python3 scripts/test-account-listener.py /absolute/path/mac-vnc-server-dev
python3 scripts/test-account-attachment.py
python3 scripts/test-session-capture.py /absolute/path/mac-vnc-server-dev
python3 scripts/test-console-capture-service.py /absolute/path/mac-vnc-server-dev --capture --startup-failure
```

The listener smoke check submits no credentials and starts no capture. Attachment
checks use no input/capture. The capture check starts a temporary attached worker,
passes a fixture admission over a private socket, and decodes a complete Zlib
frame plus RichCursor. It saves no screenshot and sends no input. Its `--root`
variant requires loginwindow and, on macOS 14+, an already-running root capture
service; it does not create or restart that service. On Ventura it uses
CoreGraphics and may request display wake during startup. Existing VNC endpoints
are untouched. Add `--console-bridge` to check Raw/RichCursor/PointerPos delivery.

The capture-service check requires real loginwindow ownership and refuses any
existing root capture service. It verifies that a deliberately misattached
daemon is rejected, then starts the production attached service twice and
checks immediate retry and owned cleanup. With `--capture`, each attempt also
decodes real loginwindow frames using disposable workers. It sends no input and
does not switch physical sessions. Unlike the old synthetic-identity lifecycle
fixture, it exercises the daemon and worker in the same real audit session.
The `--startup-failure` option also forces invalid-display errors in disposable
root workers to check error forwarding, worker retirement and fresh retry.

Session attachment, root replayd registration and direct HID delivery use private
or deprecated macOS interfaces. Results on this Tahoe host do not establish
support on every macOS release. The earlier persistent-process rebinding probes
are not part of this architecture. Physical transitions and real root-password
connections require separate operator validation.

## Standalone Ventura capture probe

`scripts/probe-console-display-stream.m` tests the public CGDisplayStream API
without an auxiliary root replayd job. This diagnostic established the API choice
for the Ventura backend in 1.7.6. It does not change the physical session, inject input, save images,
request Screen Recording permission, manage services, or open a VNC listener.
Its root mode refuses an existing root replayd registration; it never removes
or replaces it. Run it after a failed console-view attempt has finished cleaning
up and while loginwindow owns the physical display:

```sh
sudo /absolute/path/mac-vnc-console-probe --root
```

It attaches through the production audit-session preparation and fresh-exec
path, verifies the console identity, reports preflight permission as information,
and attempts one 160×100 BGRA stream. It prints dimensions and a count of nonzero
RGB samples, never pixels. A native create failure is reported as NULL without
inventing a permission error. Frame delivery is bounded to five seconds after
startup, stream stop to two seconds, and each process stage to 35 seconds.
`--user` exercises the same stream code in the caller's existing user desktop.

The universal diagnostic (Intel and Apple Silicon, minimum macOS 13.0) is built
at `.build/ventura-console-probe/mac-vnc-console-probe` with:

```sh
mkdir -p .build/ventura-console-probe
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun clang \
  -fobjc-arc -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 \
  scripts/probe-console-display-stream.m Sources/CVNCSession/ConsoleSession.c \
  -I Sources/CVNCSession/include -framework CoreGraphics -framework CoreVideo \
  -framework IOSurface -framework Foundation -framework IOKit \
  -framework SystemConfiguration -lbsm \
  -o .build/ventura-console-probe/mac-vnc-console-probe
codesign --force --sign - --identifier com.pablozaiden.mac-vnc-console-probe \
  .build/ventura-console-probe/mac-vnc-console-probe
```

The local ordinary-user run delivered a valid frame and stopped cleanly. Root
mode correctly skipped the existing service owned by the user's running server.
The first Ventura root result verified UID 0/audit 101117, no registered root
replayd, display 2 and preflight=1. Stream creation/start and stop succeeded,
but no complete frame arrived in five seconds (`frame_received=0`, exit 7).
Revision 1's `valid=1` meant only that no invalid frame was observed; it did not
mean a valid frame arrived. Display power was not recorded in that revision.
The user's off-console ScreenCaptureKit display 45
being awake does not establish that physical display 2 was awake.

After turning on the physical screen, the user repeated the probe on Ventura
13.7.8 and received a valid 160×100 BGRA loginwindow frame, with 48/64 nonzero RGB
samples, `frame_received=1`, and a successful stop. UID 0/audit 101117 was verified
and no root replayd was registered. This confirms native loginwindow frame
delivery under that condition. The complete 1.7.6 server/menu/input path still
requires verification on that host.

Revision 2 reports active/online/asleep state, complete/idle/blank callback
counts, and `frame_valid=0` when no frame arrives. It still does not wake the
display. The successful awake-loginwindow retest used revision 1.
