# Account session listener

The listener opens one TCP port and authenticates macOS
usernames/passwords through OpenDirectory. `VNC_PASSWORD` is neither required nor
read. Account-policy failures and incorrect credentials fail authentication.
Passwords never enter worker options, child environments, logs, files, or IPC.

Before binding the port, the listener checks its real and effective UID. Root
startup reports account-routing capability; non-root startup prints a warning
that only its own existing user session is available and that other accounts or
root/console access require starting with `sudo`. Non-root listeners remain usable.
Mixed real/effective UIDs are rejected; use a normal invocation or `sudo`, not a
setuid executable. Authentication enforces the same account scope as startup.

```text
listener (root for multiple accounts; otherwise current user only)
  ├─ RFB authentication: version → security type 30 → account verification
  ├─ worker for revin's UID + GUI audit session
  │    ├─ one shared capture source and input ownership coordinator
  │    ├─ VNC client A socket → per-client encoder / protocol state
  │    ├─ VNC client B socket → per-client encoder / protocol state
  │    └─ AppKit menu, clipboard subscriptions, received-file store and helpers
  └─ worker for root's current loginwindow audit session
       └─ client sockets, console capture, coordinated HID input

Root listener also owns lifecycle/cleanup of the isolated root replayd service.
```

Both worker identities use `StreamingScreenCapture`, including RichCursor,
dirty-region hints, a bounded newest-frame copy queue, capture-driven wakeups,
and adaptive SCStream frame rates. The loginwindow source additionally checks
its console identity and requires ScreenCaptureKit's display IDs to match
CoreGraphics, with valid bounds in that session. A mismatch or session change fails closed;
it never substitutes the invoking user's display. Clipboard, file transfer and
menu UI stay disabled for UID 0.

The common `MacInputController` and `SharedInputController` still build and
coordinate events. The final posting operation differs: loginwindow uses the
verified HID adapter. On 2026-10-15, a bounded probe in the correct UID 0/audit
session obtained a system cursor and complete ScreenCaptureKit frames, but
mouse events posted to either `cgSessionEventTap` or `cghidEventTap`, using both
`combinedSessionState` and the default mouse-event source, left the pointer unchanged. Keeping HID preserves working input; successful capture or
permission preflight does not establish event delivery.

There is one session worker per UID/audit session **per listener**. A fresh exec
attaches it to the target bootstrap/audit session and drops credentials for an
ordinary account before AppKit or capture initializes. Additional clients reuse
the existing worker. Workers stay alive between client connections until logout,
worker failure, or listener shutdown. Separate independently started listeners
do not share a worker registry.

For a root listener, `launchctl asuser` establishes the child's per-user Mach
bootstrap environment. It replaces itself with the executable rather than
remaining as an extra parent. The worker then selects/verifies its GUI audit
session and drops UID/GID before its final exec. `setuid` alone changes Unix
credentials without selecting the desktop's service namespace. A listener
already running as its own user starts that user's worker directly.

Separately, loginwindow's auxiliary capture service uses `launchctl bootstrap`
and `bootout` to register/remove the isolated root job and its Mach services.
These calls manage the service's lifetime; ordinary ScreenCaptureKit stream
start/stop and frame delivery do not invoke launchctl. Replacing these commands
would require equivalent launchd/bootstrap integration, not just starting a
process with UID 0.

The listener transfers the authenticated TCP descriptor using `SCM_RIGHTS` over
an inherited anonymous Unix socket. Its metadata contains only the selected
session identity, negotiated RFB version, and credential-exchange wrapping key.
The worker sends SecurityResult, reads ClientInit, sends ServerInit, and runs the
shared RFB engine. The listener closes its copy
without calling `shutdown`, which would also disconnect the worker's socket.
No framebuffer, input, clipboard, or file-transfer payload is relayed through the
listener. Each client retains independent encoders, encryption state, flow
control, and clipboard subscriptions. Capture, aggregate input ownership, and
received-file management belong to the session worker.

## Starting it

```sh
# Existing own-user GUI session only:
./.build/release/mac-vnc-server-dev --bind utun4 --port 5900

# Multiple existing user sessions and root/loginwindow:
sudo ./.build/release/mac-vnc-server-dev --bind utun4 --port 5902 --verbose
```

Connect using a plain `vnc://HOST:PORT/` URL. Use the real account username and
password. The listener requires ARD security type 30, supported by Apple Screen
Sharing. There is no password-only/None fallback on this endpoint. The credential
exchange uses the existing Apple DH/AES implementation; framebuffer, clipboard,
and file-transfer traffic remain plaintext by default. After type-30 login,
Screen Sharing wraps keyboard/mouse events in individual AES blocks using the
authentication key, even with session-record encryption disabled. The worker
decodes these input envelopes without enabling record ciphers. ARD does not establish a
trusted server identity, so protect untrusted-network access with VPN/SSH.

`root` means the actual root account, not an administrator alias. The account
must be enabled by the operator. Successful authentication authorizes existing
root privileges; it cannot elevate a listener started as a normal user. The
listener checks the authenticated account's UID before choosing the target, so a
non-root listener rejects root even when its own user currently owns the console.

User sessions must already exist. Authenticating does not log a user into macOS,
unlock their physical screen, create a virtual login session, or switch the
console. Locked/off-console user sessions continue using their ordinary capture,
input, RichCursor, zlib-ng, clipboard, and file-transfer paths. Existing-user
off-console capture/input have been verified on Tahoe; [the Ventura Mac mini
case](macos13-server-compatibility.md#ventura-capture-and-session-findings) still
shows loginwindow and remains unresolved.

Each root login selects the physical console owner after password verification.
If loginwindow owns the console, the target is its UID 0/audit session. If a user
owns it, the target is that user's UID/audit session and uses the same worker as
connections authenticated with the user's own credentials. The user worker runs
as that user, with all ordinary capture, input, clipboard, file-transfer,
RichCursor, zlib-ng, and menu features; no additional root capture service is
started for this route.

Connections remain attached to their selected session. A selected user desktop
can continue off console. A selected loginwindow worker ends when its console
identity changes. Reconnect as root to select the new console owner. There is no separate console-following endpoint or raw-frame relay.

If the console cannot be resolved during a transition, authentication reports
that the password was accepted but the physical console is temporarily
unavailable, and advises reconnecting after the Mac finishes switching users.
It does not guess a target user. Post-authentication availability errors are
logged and included in RFB 3.8's failure message. Apple's 3.889 authentication
dialog uses fixed client-side messages rather than the RFB 3.8 reason field, so
its dialog remains generic; consult the listener log for the specific cause.
Incorrect passwords and account-policy failures remain generic.

## Menu and storage

Each user worker owns a remote-display icon. The normal template icon appears
only after verified, consistent observations show that this worker is off console
and loginwindow or another user owns the physical console. Confirmation requires
matching samples at least half a second apart. Visible, unknown, conflicting and
transitional states all show the blinking red eye, even with zero VNC clients.
A screen-lock flag alone does not confirm that the desktop is hidden.

Session/wake notifications immediately discard earlier hidden-state confirmation.
The half-second timer and opening the menu both refresh the observations. The
indicator reflects the latest checks; it is not an atomic guarantee across a
physical-console transition between samples.

Clicking the icon opens a menu with physical-display state, connected-client
count, **Session Details**, **Switch to Login Window**, and **Received Files…**.
Session Details shows the worker account/PID/UID, worker and console audit-session
identities, the reported on-console and lock flags (including unavailable values),
and the reason for the indicator. The files item is disabled when receiving is
disabled.

Device-owner reporting uses `State:/Users/ConsoleUser` and `/dev/console`, with
a unique matching UID/audit row. It is separate from capture authorization:
root routing also requires the session's OnConsole flags to agree. Ventura can
report root device ownership while keeping the user marked OnConsole; the
Ventura probe found loginwindow in that same locked user session. The menu
shows the device-owner candidate, reports when the session remains locked on
console, and retains the red eye for this disagreement. A newly started user
worker also warns about a locked/on-console session.
The account worker's user-session selection is not changed by that status query.

The two red eye images contain their own color rather than relying on status-bar
template tinting, which Tahoe can ignore. They are cached and alternate every
half-second between full and 40% opacity. Verbose logs report changes in physical
visibility, client count, and selected icon style.

**Switch to Login Window** requests Fast User Switching on the physical console,
leaving the user's apps and VNC worker running. It calls the login framework's
`SACSwitchToLoginWindow` entry point, not Lock Screen. The item is enabled only
while this user's session owns the console (including a locked own-user session);
it is disabled if loginwindow or another user already owns the display. Ownership
is checked again when clicked and immediately before the request. The synchronous
system request runs off the AppKit thread. If the private entry point is absent
or macOS rejects the request, an error is shown; there is no lock-screen fallback.

Default files are stored under the selected user's
`~/Library/Application Support/mac-vnc-server/Transfers`, resolved after the
worker changes credentials and execs. The listener creates no file-transfer
directory. An explicit transfer directory must be owned by the selected account.
Root/loginwindow has no clipboard, transfer storage, or menu-bar helper.

## Bounds and cleanup

The listener admits up to 16 concurrent authentication/startup operations. Human
password entry retains the 120-second budget; partial protocol messages retain
the short handshake deadline. There are at most 32 workers per listener and 32
clients per worker. Worker startup has a 40-second readiness deadline. Concurrent
worker creation is serialized to avoid duplicate desktop owners.

Worker loss is detected/reaped and a subsequent authenticated connection can
create a replacement. Parent-channel closure stops a worker and its client
sockets. Session identity changes stop the corresponding worker. SIGINT/SIGTERM
cancel the listener, close pending authentication sockets, stop owned workers,
and attempt root capture-service cleanup; the existing forced-exit deadline and
next-start recovery remain available.

## Validation

`AccountSessionTests` exercises credential parsing, rejected logins before worker
creation, root/own-account restrictions, mixed real/effective UID rejection,
console-owner selection, and handoff for RFB 3.889, 3.8 and 3.7. Tests verify
concurrent admissions reusing one worker, independent frame delivery, malformed
descriptor rejection, descriptor survival after the listener closes its copy,
and full-duplex use from a real child. Fixture credentials are verified by a
test verifier; real macOS passwords are not used.

The shared engine tests cover codecs, frame scheduling, encrypted input with
plaintext frames, Control/Observe gating, clipboard and staged file transfers.
Optional native ScreenSharing.framework probes use plain URLs and fixture
account credentials. They execute the host framework, not a remote Ventura app.

On 2026-10-14 the user confirmed working keyboard and mouse after reconnecting
with the plain `vnc://oker-vm.ip:5902/` URL to an off-console user session. Earlier
root/user attachment checks verified matching audit identity, inherited IPC and
cleared setugid state without input or capture injection. Native menu rendering
checks verified red pixels at both eye-animation opacities. These earlier results
do not substitute for testing a new binary or a full physical-console transition.

See [loginwindow validation](console-session-backend.md#validation-and-limitations)
for isolated listener, attachment and capture checks. All temporary checks must
leave existing servers and capture services running unchanged.

This host's Command Line Tools require an explicit test macro plugin:

```sh
swift test --no-parallel \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

Use serial execution for socket fixtures with short timing deadlines.
