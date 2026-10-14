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
`--session console` supervisor, raw-frame IPC transport and alternate capture
backends have been removed.

## Process structure

```text
root account listener
  ├─ user account worker (one per UID/audit session)
  │    ├─ ScreenCaptureKit → encoder → client TCP sockets
  │    ├─ shared input coordinator → session CGEvent posting
  │    └─ clipboard, file transfers, menu UI
  └─ loginwindow account worker (UID 0/audit session)
       ├─ ScreenCaptureKit → encoder → client TCP sockets
       └─ shared input coordinator → verified IOHIDPostEvent adapter

launchd
  └─ isolated root replayd (Apple's capture service, managed by the listener)
```

The listener transfers an authenticated socket once, using `SCM_RIGHTS`; it does
not relay frames or input. Workers attach and exec before initializing graphics,
so framework connections and caches belong to the target session. There is no
separate capture-manager process. Short-lived launchctl commands manage the root
capture service, and a helper entry point execs Apple's signed replayd binary.

## Shared capture and input

Both workers use `StreamingScreenCapture`: ScreenCaptureKit streams, RichCursor,
dirty-region hints, a bounded queue retaining the newest pending capture,
capture-driven wakeups, adaptive frame rates, and the same RFB encoders and flow
control. Loginwindow additionally verifies UID/audit/console ownership and
requires ScreenCaptureKit display IDs and geometry to agree with CoreGraphics.
A mismatch fails closed instead of substituting a user's desktop. Clipboard,
file transfer, Received Files and menu UI are disabled for UID 0.

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

Only a UID 0 loginwindow worker needs the auxiliary root replayd service. Its
lifecycle belongs to the listener. An ordinary user worker uses that user's
existing macOS capture service.

The listener creates a root-owned mode-0700 directory under
`/private/var/run/mac-vnc-console.XXXXXX/`. Its mode-0600 `capture.plist` contains
the executable path, audit ID, owner PID, unique job label and Mach service names.
It contains no credentials or pixels. No permanent LaunchDaemon or user-home
configuration is installed.

The listener holds an exclusive lock and recovers abandoned owned jobs before
registration. A live owner or unrelated root capture service prevents a new
registration. Per-user bootstrap lookup queries user 0 without changing the
listener's own graphics session. Launchctl children inherit neither account
credentials nor client sockets. The root-owned zero-byte mode-0600 file
`/private/var/run/mac-vnc-console-capture.lock` stays until reboot so concurrent
opens cannot obtain locks on different inodes.

Worker teardown, startup failures and graceful shutdown attempt to boot out the
uniquely named job and remove its metadata. Each launchctl operation has a
four-second deadline and one cleanup retry. Forced exit can interrupt cleanup;
retained metadata lets the next root startup retry before registering a service.
Startup recovery also runs when no loginwindow worker is immediately needed.

Recovery validates directory ownership/mode, the regular plist, generated label
and fields, and an owner PID that no longer exists (or this listener's own failed
cleanup). Symlinks, malformed metadata, live/reused PIDs and unrelated jobs are
left alone. Failed bootout retains the metadata and reports the job. There is no
blanket termination or replacement of replayd services.

## Validation and limitations

Unit/socket tests cover identity matching, capture geometry, blank-frame handling,
newest-frame coalescing, shared input ownership, encrypted input, account routing
and descriptor handoff. Optional checks are:

```sh
python3 scripts/test-account-listener.py /absolute/path/mac-vnc-server-dev
python3 scripts/test-account-attachment.py
python3 scripts/test-session-capture.py /absolute/path/mac-vnc-server-dev
```

The listener smoke check submits no credentials and starts no capture. Attachment
checks use no input/capture. The capture check starts a temporary attached worker,
passes a fixture admission over a private socket, and decodes a complete Zlib
frame plus RichCursor. It saves no screenshot and sends no input. Its `--root`
variant requires loginwindow and an already-running root capture service; it does
not create or restart that service. Existing VNC endpoints are untouched.

Session attachment, root replayd registration and direct HID delivery use private
or deprecated macOS interfaces. Results on this Tahoe host do not establish
support on every macOS release. The earlier persistent-process rebinding probes
are not part of this architecture. Physical transitions and real root-password
connections require separate operator validation.
