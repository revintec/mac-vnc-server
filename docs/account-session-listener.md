# Account session listener

The default `--session listener` opens one TCP port and authenticates macOS
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

There is one session worker per UID/audit session **per listener**. A fresh exec
attaches it to the target bootstrap/audit session and drops credentials for an
ordinary account before AppKit or capture initializes. Additional clients reuse
the existing worker. Workers stay alive between client connections until logout,
worker failure, or listener shutdown. Separate independently started listeners
do not share a worker registry.

The listener transfers the authenticated TCP descriptor using `SCM_RIGHTS` over
an inherited anonymous Unix socket. Its metadata contains only the selected
session identity, negotiated RFB version, and credential-exchange wrapping key.
The worker sends SecurityResult, reads ClientInit, sends ServerInit, and runs the
same RFB engine used by the existing user backend. The listener closes its copy
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
decodes these input envelopes without enabling record ciphers. A type-2 legacy
connection has no wrapping key and still rejects encrypted input. ARD does not establish a
trusted server identity, so protect untrusted-network access with VPN/SSH.

`root` means the actual root account, not an administrator alias. The account
must be enabled by the operator. Successful authentication authorizes existing
root privileges; it cannot elevate a listener started as a normal user. The
listener checks the authenticated account's UID before choosing the target, so a
non-root listener rejects root even when its own user currently owns the console.

User sessions must already exist. Authenticating does not log a user into macOS,
unlock their physical screen, create a virtual login session, or switch the
console. Locked/off-console user sessions continue using their ordinary capture,
input, RichCursor, zlib-ng, clipboard, and file-transfer paths.

Each root login selects the physical console owner after password verification.
If loginwindow owns the console, the target is its UID 0/audit session. If a user
owns it, the target is that user's UID/audit session and uses the same worker as
connections authenticated with the user's own credentials. The user worker runs
as that user, with all ordinary capture, input, clipboard, file-transfer,
RichCursor, zlib-ng, and menu features; no additional root capture service is
started for this route.

Connections remain attached to their selected session. A selected user desktop
can continue off console. A selected loginwindow worker ends when its console
identity changes. Reconnect as root to select the new console owner. The legacy
`--session console` follows console identities using the older architecture and
remains available separately.

If the console cannot be resolved during a transition, authentication reports
that the password was accepted but the physical console is temporarily
unavailable, and advises reconnecting after the Mac finishes switching users.
It does not guess a target user. Post-authentication availability errors are
logged and included in RFB 3.8's failure message. Apple's 3.889 authentication
dialog uses fixed client-side messages rather than the RFB 3.8 reason field, so
its dialog remains generic; consult the listener log for the specific cause.
Incorrect passwords and account-policy failures remain generic.

## Menu and storage

Each user worker owns an adaptive template remote-display icon. While VNC clients
are connected and that user's desktop is visible on the physical console, the
icon becomes a blinking red eye. It returns to the template icon at loginwindow,
on another user's desktop, or when no clients remain. Unknown visibility is
reported explicitly. Clicking opens a menu showing physical-display state,
connected-client count, **Switch to Login Window**, and **Received Files…**. The
files item is disabled when staged receiving is disabled.

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

The console-owner routing update passed 62 tests across the account-routing,
Apple-encryption, and multi-client suites. A regression first reproduced the
old rejection when the console belonged to a user. Tests now cover selecting
loginwindow or either of two user identities, rejecting root on an unprivileged
listener before target lookup, and sharing one user worker between root and user
logins with independent frame delivery for RFB 3.889, 3.8, and 3.7. The release
build and strict code-signature verification passed. This update was prepared as
a separate binary without restarting running servers; live root-password and
capture validation was not performed.

The status-icon/session-error update passed 61 tests across the account-routing,
Apple-encryption, and multi-client suites. A native `NSStatusBarButton` rendering
probe reproduced the missing red tint and verified red pixels at both 100% and
40% opacity after the fix. The updated release was installed on port 5902; its
user worker reported a visible physical desktop, one connected client, and the
blinking-red-eye state while continuing framebuffer and input delivery. A full
physical-console lock/unlock cycle was not repeated for this change.

`AccountSessionTests` exercises credential parsing, rejected logins before worker
creation, protocol handoff for RFB 3.889, 3.8 and 3.7, simultaneous admissions reusing
one worker, client independence, malformed descriptor messages, descriptor
survival after the listener closes its copy, and full-duplex descriptor use from
a real child process. It uses synthetic frames and a test account verifier, not
real account passwords or capture/input injection. Existing encoding, clipboard,
file-transfer, shared-input and streaming tests cover the reused RFB engine.

A 237-test regression run passed serially before the startup privilege reporting
change. All eleven account-routing tests passed after the input fix, including
own-account restrictions, rejection of mixed real/effective credentials,
availability of the switching action only for the console's user session, and
type-30 keyboard/mouse input with plaintext framebuffer traffic. The
eight interrupt tests also passed in the earlier regression validation.
`scripts/test-account-attachment.py --root` verified fresh exec into
both the existing off-console user session (UID 501) and loginwindow (UID 0),
with matching audit identity, inherited IPC, and cleared setugid state. The
non-root own-session check passed separately. These attachment checks performed
no capture or input injection.

This host's Command Line Tools required an explicit test macro plugin:

```sh
swift test --no-parallel \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

The parallel run exhausted short socket-fixture deadlines; the serial run passed.

The account-input regression reproduced a disconnect on the first type-30 input
message when `--no-encryption` was set. The corrected handler requires the
authenticated wrapping key but does not enable record encryption. It delivers
combined keyboard/pointer events, preserves Apple's button mapping, and continues
to suppress input in Observe mode. The related serial run reported 79 tests across
account routing, Apple encryption, file transfer, and multi-client protocol suites;
it passed, with native Screen Sharing UI tests skipped.

On 2026-10-14, the user reconnected to the non-root account listener with the plain
`vnc://oker-vm.ip:5902/` URL and confirmed that both mouse and keyboard worked after
the input fix. The physical console was at loginwindow. This validates the native
user-account connection and interactive worker path; it does not validate a root
account connection or every clipboard/file-transfer feature in the new path.
Root-account native operation and the menu's appearance across physical
lock/unlock transitions still need validation. The earlier same-process rebinding
probes are not used by this implementation.
The login-window switching symbol and its dedicated Fast User Switching request
were inspected on this host without invoking it. A live menu click/transition
remains untested because the console was already at loginwindow during the change.

The isolated release build is staged at
`.build/account-session/mac-vnc-server-dev`; validation metadata and its SHA-256
are saved beside it in `validation.json`. Before the menu addition, the built listener was smoke-tested as
UID 501 and UID 0: each printed the correct startup privilege report and offered
security type 30 without starting a worker or capture before authentication.
Ctrl-C closed the pending login and exited in
approximately 1.1 seconds. Those smoke tests did not restart existing endpoints.
For the input fix, the idle session worker on port 5902 was retired so the next
authenticated connection loaded the new binary; its listener remained running.
