# Console-session backend

Status, 2026-10-14: experimental. **Loginwindow capture, pointer movement, clicks,
and keyboard input are verified on the Tahoe test host.** Capture includes a full
1728×1118 frame decoded by an authenticated VNC client. A production-worker test
opened and dismissed the input-source menu, then entered and erased a test
character in the secure password field without submitting a login. The actual
login/unlock transition still needs validation. The existing user backend and
its Aqua LaunchAgent retain their behavior.

## Running the endpoint

From a terminal in an existing GUI session, with `VNC_PASSWORD` already exported:

```sh
sudo --preserve-env=VNC_PASSWORD /absolute/path/mac-vnc-server-dev \
  --session console --bind utun4 --port 5902 --display all --verbose
```

Choose a free port distinct from the user server's ports, then use the plain
`vnc://HOST:5902/` URL. The VNC password authorizes the console endpoint; the macOS
password at loginwindow is separate. Passwords come only from `VNC_PASSWORD`.
They are not passed to workers, written to disk, or included in process arguments.
Console workers suppress key-event trace logging even with `--verbose` because
input at loginwindow can contain macOS credentials.

The supervisor binds its port before launching capture workers, then starts
listening after the first verified frame. A port conflict fails immediately.
Rebuilding a binary does not replace an existing process or change which backend
it serves. Startup logs include the supervisor PID, capture backend, and worker
UID/audit ID.

Ctrl-C, SIGTERM, and (in console mode) SIGHUP request cleanup. Repeating a signal
forces exit immediately, and a five-second watchdog forces exit if cleanup stalls.
Signal handling runs outside MainActor. Only owned worker processes are killed.
The main process makes a bounded attempt to remove its capture-service job; an
interrupted or failed cleanup is retried on a later startup.

Without `--session console`, the current user backend is unchanged. Console mode
creates one listener: `--display all` automatically selects a console display,
and `--display N` selects one by index. It does not create the user backend's
additional per-display listeners. Console mode uses an embedded cursor and disables
clipboard/file transfer, including the Received Files panel. Explicit enable flags
for these features are rejected. The existing user endpoint still provides them.

## Why the earlier versions failed

Joining the root audit/graphics session was insufficient to select the capture
service. In the first implementation, ScreenCaptureKit connected to the invoking
user's `replayd` through the inherited bootstrap namespace. It returned that user's
off-console desktop (display 30) even though the worker reported UID 0. Supplying
ScreenCaptureKit's dimensions only made the wrong desktop visible.

The next version requested console display 1 through `CGDisplayStream`, but its
factory returned NULL. The wrapper incorrectly reported a synthetic `ENXIO` (6)
as if it were a macOS stream error. Diagnostics now distinguish a factory failure
(no error code supplied) from a `CGDisplayStreamStart` failure (actual CGError).

A debugger trace showed the installed legacy CG display-stream API proxying through
ScreenCaptureKit and failing with an internal invalid-connection result. The API
name did not imply direct access to the physical framebuffer. The inherited
bootstrap still selected the wrong capture-service namespace.

The current implementation launches root workers through `launchctl asuser 0` and
provides a separate root-session capture service. A small entry point joins the
verified loginwindow audit session and execs Apple's original `/usr/libexec/replayd`.
It uses its original signature and normal macOS permissions; this project adds no
private capture entitlements. The service runs in `user/0`, with its launchd session
type set to Background, and owns the normal replayd Mach service names there. The
logged-in user's `replayd` remains in its own namespace.

With this service routing, the CG display stream and two diagnostic native snapshot
calls produced loginwindow frames. The integrated VNC result was also visually
checked. Permission preflights alone are not evidence of successful input: they
returned true while the keyboard/pointer tests had no visible effect. After the
macOS consent dialog was resolved, both CoreGraphics event taps still failed to
move the loginwindow pointer. `IOHIDPostEvent` delivered physical-console input
successfully with the existing Post Event permission. The UID 0 worker now uses
that route. This is separate from capture-service routing.

## Isolation and lifecycle

- The root supervisor owns the authenticated RFB listener. A separate worker
  captures and injects input in the current physical-console session. Switching
  workers preserves the VNC connection, encoder, and authentication.
- Each worker adopts the chosen user's bootstrap namespace and audit session
  before creating capture/input objects. Logged-in user workers permanently drop
  root privileges. Every worker then execs a fresh image, preserving audit/bootstrap
  membership and its anonymous stdin IPC socket. This clears credential-change
  taint before AppKit initialization.
- Identity validation checks UID, audit ID, matching real/effective credentials,
  `issetugid() == 0`, the graphics session's on-console flag, and `/dev/console`
  ownership. Checks run before input and around captured frames. Contradictory or
  missing identity stops the worker.
- Capture geometry and input coordinates use the worker's CoreGraphics displays.
  Missing/empty bounds reject startup. Stream callbacks copy IOSurface pixels
  before returning. Shutdown disables and drains callbacks before releasing their
  Swift context. Blank-display events clear the cached image.
- Session changes and worker failures invalidate the generation, blank the cached
  frame, and close the old worker channel. Late frames cannot overwrite the new
  generation. Held keys/buttons must be released before they become presses in a
  new session. The old worker releases its own input during shutdown.
- Repeated failures back off through 0.5, 1, 2, 4, and 8 seconds. A new session starts
  without inheriting that delay. Ten seconds of verified frames resets the failure
  history; one frame does not.
- IPC is an anonymous Unix socket pair with bounded metadata and raw pixel messages.
  Capture coalesces while IPC is busy; it does not queue old frames. No password,
  screenshot, or `.mac-vnc-server` directory is written.

## Loginwindow input

Only the verified UID 0 worker opens an `IOHIDSystem` connection. It checks Post
Event permission without prompting and reports device/API failures. The existing
key/button mapping remains in `MacInputController`; its CGEvents are converted to
NX keyboard, mouse, and scroll records. Physical key codes, per-event modifier
flags, click counts, pointer coordinates, and pixel scroll deltas are preserved.
Keys without a Unicode string are translated through the session's current
keyboard layout, including shifted letters/punctuation. Explicit single-unit
Unicode is preserved; multi-unit Unicode is rejected rather than truncated.

HID input follows the physical console. The bridge therefore verifies the root
worker's UID/audit/on-console identity immediately before every event, including
releases during shutdown. It does not request global modifier-flag overrides.
Key-event contents are never logged. Posting failures stop input and cause worker
replacement rather than silently dropping an entire session's input.

Logged-in console workers and the default user backend retain the CoreGraphics
session tap, which is required for off-console user access. They never open this
HID connection. `IOHIDPostEvent` is deprecated but remains exported on the tested
system; future macOS support needs validation. It still requires normal macOS
Post Event/Accessibility authorization.

## Temporary root capture service

At loginwindow the endpoint uses three persistent processes: the root supervisor,
the root capture/input worker, and Apple's root `replayd` service. The supervisor
manages capture-service lifetime in process; there is no separate manager process
or manager lifeline socket. `launchctl` commands are short-lived. For a logged-in
console session, only the supervisor and user worker are needed alongside the
user's existing macOS capture service.

Only a UID 0 loginwindow worker requires the auxiliary service. The supervisor
creates `/private/var/run/mac-vnc-console.XXXXXX/` with root-only permissions. Its
mode-0600 `capture.plist` contains the executable path, audit ID, supervisor PID,
unique job label, and Mach service names. It contains no credentials or captured
pixels. No permanent LaunchDaemon or user-home configuration is installed.

The supervisor holds an exclusive lock, recovers its abandoned jobs, then checks
for an existing root capture service. The per-user bootstrap lookup explicitly
queries user 0 without changing the supervisor's bootstrap or graphics session.
A live owner or unrelated service prevents registration. Short-lived launchctl
commands inherit neither VNC_PASSWORD nor the supervisor's open sockets/lock.
The zero-byte root-owned mode-0600 lock file,
`/private/var/run/mac-vnc-console-capture.lock`, stays until reboot; keeping the
same inode prevents simultaneous opens from taking different locks.

Normal worker teardown, session changes, startup errors, and graceful shutdown
attempt to boot out the uniquely named job and remove its metadata. Each launchctl
operation has a four-second deadline, with one cleanup retry. The overall shutdown
watchdog can end the process sooner. SIGKILL cannot run cleanup. In either case,
the retained plist lets the next startup retry removal before registering a new
service. This startup cleanup also runs when an ordinary user owns the console
and no new root capture service is needed.

Recovery verifies the root-owned mode-0700 directory, mode-0600 regular plist,
exact generated label and job fields, and an owner PID that no longer exists.
It can also retry cleanup left by this same supervisor after reacquiring the lock.
The plist format remains compatible with the older standalone manager. Symlinks,
malformed metadata, other live/reused PIDs, and unrelated jobs are left alone.
Recovery removes only the verified unique job and its metadata. If bootout fails
twice, startup reports the target and retains the plist for another attempt or
administrator cleanup. No blanket replayd termination is used.

## Validation and remaining limits

Focused tests cover CLI isolation, real socket conflicts/deferred listening, IPC
bounds, generation changes, blanking, held-input suppression, disconnection,
worker exec stages, and retry backoff. Capture tests cover geometry, scaled mouse
coordinates, full-size console frame validation, and capture error domains.
Input regressions cover root-only access checks, modifier/Unicode conversion,
button coordinates, click counts, and preservation of pixel scroll deltas.

Useful opt-in checks:

- `VNC_TEST_CONSOLE_CAPTURE=1 swift test ...` enables real display-stream capture
  in the test user's session, without input, listeners, or saved images.
- `python3 scripts/test-interrupt.py` exercises the production signal controller,
  including initialization, stuck cleanup, repeated signals, deadlines, and owned
  child termination.
- `python3 scripts/test-console-worker-exec.py` checks the production exec bridge:
  PID, UID/GID, audit ID, options, and bidirectional stdin IPC survive exec.
- `python3 scripts/smoke-capture-startup.py --interrupt BINARY` checks four real
  loopback user-session startups, complete decoded frames, and SIGINT cleanup.
- `sudo python3 scripts/test-console-root.py BINARY` requires loginwindow to be
  the physical console. It authenticates disposable loopback endpoints with a fixed
  test-only environment credential, decodes full frames, verifies the three-process
  structure, and checks SIGINT/SIGTERM/SIGHUP cleanup, next-startup recovery after
  supervisor SIGKILL, and preservation of live or unverified metadata and unrelated
  root services. It does not send input
  or save screenshot data.
- `scripts/probe-console-capture.m` compares display-stream and native snapshot
  availability in a verified session. It does not save pixels or send input.

A live login/unlock transition remains unverified; successful capture, input,
and synthetic worker-transition tests do not establish that transition.
User-session capture was separately tested while the physical console showed
loginwindow; the pre-existing port 5900 server and user capture service were preserved.

This foreground backend currently assumes an existing GUI launch context. It does
not create user sessions, authenticate macOS accounts, or operate before FileVault
unlock. `--service` remains the per-user Aqua LaunchAgent and is rejected with
`--session console`. Launching from a daemon without a GUI context, fully logging
out the invoking user, and older macOS versions remain unvalidated. Session APIs
include dynamically resolved private interfaces; unsupported contexts fail instead
of intentionally substituting a different user's desktop.

The console path adds a raw-frame copy over local IPC before normal RFB encoding.
It preserves Zlib/ZRLE and frame pacing, but its extra CPU and latency cost has not
been benchmarked. These copies are absent from the default user backend.
