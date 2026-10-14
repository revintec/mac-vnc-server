# mac-vnc-server

`mac-vnc-server` is a macOS-only VNC/RFB server written in Swift. It captures the local Mac screen, accepts keyboard and mouse input from a VNC client, and exposes the session on a configurable TCP port.

The default setup targets Apple Screen Sharing over the `utun4` interface:

- bind target: `utun4` (its first active IPv4 address at startup)
- listening port: `5900`
- authentication: macOS account username and password; `VNC_PASSWORD` is ignored
- FPS target: adaptive `60 -> 45 -> 30`
- scale: `1.0`
- encoding: `auto`
- session encryption: off; password authentication remains enabled
- clipboard sync and file transfer: on

Use `--bind 127.0.0.1` for loopback, `--bind en0` for another interface, or an explicit IPv4 address. An unavailable interface is an error; the server never falls back to listening on all interfaces.

The default account listener routes each authenticated client to an existing macOS
GUI session. Start it as root to serve multiple accounts or loginwindow; a
non-root listener serves only its own account. One worker per UID/audit session
owns capture and every connected client socket. Encoded frames, input, clipboard,
and file transfers flow directly between that worker and its clients, without a
listener relay. User sessions retain their capture, zlib-ng, RichCursor, clipboard,
and file-transfer features while off console.

Startup checks listener privileges before binding. Non-root startup warns about
the own-account restriction; root startup reports broader account access.

The VNC menu-bar icon includes **Switch to Login Window**, which uses Fast User
Switching to hide this desktop on the physical console while keeping its VNC
session and apps running. It is available while this user owns the console.

Use the actual `root` account password to select the current console owner:
loginwindow when it owns the console, or the logged-in user's desktop otherwise.
The root account must be enabled and the listener must already run as root.
A user desktop reuses that user's worker, including its clipboard, file transfer,
and input coordination. Account authentication does not create a new GUI session
or elevate a non-root listener. Each connection stays on the session selected at
login; reconnect as root to select a new console owner after a user switch.
See [account routing and process lifetimes](docs/account-session-listener.md).

Explicit `--session user` and [`--session console`](docs/console-session-backend.md)
retain the older shared-password endpoints for compatibility. The native
loginwindow capture implementation remains experimental on macOS versions other
than the tested Tahoe host.

## Requirements

- macOS 13 or newer
- Xcode / Swift toolchain compatible with `swift-tools-version: 6.3`
- Screen Recording permission
- Accessibility / Post Event permission for keyboard and mouse injection

The package links macOS-native frameworks:

- `ScreenCaptureKit` for screen capture
- `CoreGraphics` / `ApplicationServices` for input injection and permissions
- `AppKit` for clipboard integration
- `OpenDirectory` for macOS account authentication and account-policy checks
- `zlib` for compressed framebuffer encodings

## Build

```sh
swift build -c release
```

The binary is produced at:

```text
.build/release/mac-vnc-server-dev
```

For an explicit Apple Silicon build:

```sh
swift build -c release --arch arm64
```

Local SwiftPM builds use the `mac-vnc-server-dev` name. The release workflow stages the same product as `mac-vnc-server` after signing it.

## Versioning

Development builds always report:

```text
0.0.0-development
```

The release workflow replaces that value with the Git tag being released, stripping a leading `v`. For example, release tag `v1.2.3` builds a binary that reports `1.2.3`.

Show the version:

```sh
./.build/release/mac-vnc-server-dev version
./.build/release/mac-vnc-server-dev --help
```

Startup, connection, and recovery information is always shown. Periodic framebuffer-update logs are shown only when the server is started with `--verbose`. Warnings and errors are always written to stderr.

Update an installed release binary from the latest GitHub release:

```sh
mac-vnc-server update
```

The command downloads the exact release assets, verifies the binary's SHA-256 checksum, and atomically replaces the installed release executable. Development binaries refuse self-update; install or invoke the signed `mac-vnc-server` release binary instead.

## Permissions

Run this once:

```sh
./.build/release/mac-vnc-server-dev permissions
```

Then grant the requested permissions in macOS System Settings:

- Privacy & Security -> Screen Recording
- Privacy & Security -> Accessibility

Restart the server after granting permissions.

Check current status:

```sh
./.build/release/mac-vnc-server-dev diagnose
```

If ScreenCaptureKit reports no displays after the Mac turns the screen off, wake the display and start the server again:

```sh
./.build/release/mac-vnc-server-dev wakeup
```

## Run

Start an account listener for your own user:

```sh
./.build/release/mac-vnc-server-dev
```

Or start a root listener for account routing and loginwindow access:

```sh
sudo ./.build/release/mac-vnc-server-dev --bind utun4 --port 5900
```

No password is supplied in the command or environment. Enter the selected macOS
account's username and password in Screen Sharing.

Equivalent explicit command:

```sh
./.build/release/mac-vnc-server-dev run --bind utun4 --port 5900 --fps auto --scale 1 --encoding auto --no-encryption --clipboard-sync --file-transfer
```

Register an account listener as a per-user macOS service (no password environment needed):

```sh
./.build/release/mac-vnc-server-dev --service
```

This creates `~/Library/LaunchAgents/com.pablozaiden.mac-vnc-server.plist` and runs the
server in the logged-in user's Aqua UI session. The service starts again automatically
when that user logs in and is restarted by `launchd` if the process exits. The service
is classified as an interactive job so `launchd` does not apply background CPU and I/O
throttling to the frame-streaming workload. It uses the same server options, so options
can be combined with `--service`, for example:

```sh
mac-vnc-server --service --bind 0.0.0.0 --port 5900
```

Restart the registered service after replacing the binary:

```sh
mac-vnc-server --service-restart
```

Service output is written to:

```text
~/Library/Logs/mac-vnc-server/stdout.log
~/Library/Logs/mac-vnc-server/stderr.log
```

To remove the service:

```sh
launchctl bootout "gui/$(id -u)/com.pablozaiden.mac-vnc-server"
rm ~/Library/LaunchAgents/com.pablozaiden.mac-vnc-server.plist
```

The account listener opens exactly one port. By default each session worker serves
all displays in its own session. Use `--display 1` to select that session's first
display instead.

For loopback testing, start the server with `--bind 127.0.0.1`, then connect with Apple Screen Sharing:

```sh
open 'vnc://127.0.0.1:5900'
```

Authenticate with the selected macOS account username and password.

The advertised desktop name is the server's short system hostname (as shown by
`hostname -s`), for example `oker-vm` from `oker-vm.ip`. The server reads this
directly without resolving the Bonjour or reverse-DNS name. Screen Sharing uses
it in its window title; standard VNC viewers receive the same name. Reconnect
after a hostname change to receive it.

## Run on LAN

Bind all interfaces:

```sh
./.build/release/mac-vnc-server-dev --bind 0.0.0.0 --port 5900
```

Or bind a specific LAN IP:

```sh
./.build/release/mac-vnc-server-dev --bind 192.168.1.10 --port 5900
```

The server refuses unauthenticated non-loopback binds by default. To disable auth for clients that support unauthenticated VNC, you must opt in explicitly:

```sh
./.build/release/mac-vnc-server-dev --session user --bind 0.0.0.0 --no-password --insecure-allow-no-auth
```

Classic VNC password auth is weak and limited by the protocol. For untrusted networks, prefer an SSH tunnel:

```sh
ssh -L 5900:127.0.0.1:5900 user@mac-host
open 'vnc://127.0.0.1:5900'
```

## CLI

```text
mac-vnc-server [run] [options]
mac-vnc-server permissions
mac-vnc-server diagnose
mac-vnc-server wakeup
mac-vnc-server update
mac-vnc-server version
mac-vnc-server --help
```

`run` is optional when the first argument is a flag.
`wakeup` sends a short user-activity assertion with `caffeinate` to wake the display when ScreenCaptureKit cannot see any displays.

Options:

| Option | Default | Description |
| --- | --- | --- |
| `--bind <ipv4 or interface>` | `utun4` | Listen on an IPv4 address or the first active IPv4 address of an interface such as `utun4`, `en0`, or `lo0`. Resolved at startup; restart after an address change. |
| `--port <port>` / `-p <port>` | `5900` | The account listener TCP port. |
| `--session listener\|user\|console` | `listener` | Account routing, or explicit legacy shared-password user/console endpoints. |
| `VNC_PASSWORD` (environment) | ignored | Used only by explicit legacy `--session user` / `--session console`. |
| `--no-password` | off | Legacy `--session user` only; never bypasses account listener authentication. |
| `--insecure-allow-no-auth` | off | Required with `--no-password` on non-loopback binds. |
| `--fps <auto\|1...120>` | `auto` | Adaptive `60 -> 45 -> 30` target, or a fixed framebuffer update rate when an explicit number is provided. |
| `--scale <value>` | `1.0` | Base virtual framebuffer scale. Adaptive sessions may temporarily use `0.75` or `0.67` for compatible generic clients that advertise DesktopSize when encoding or network pressure persists. Apple Screen Sharing uses its own display/scaling negotiation and is excluded from these automatic scale changes. |
| `--encoding <auto\|zrle\|zlib\|raw>` | `auto` | Framebuffer encoding preference. |
| `--display <all\|number>` | `all` | All displays in the selected account session, or one 1-based display index. |
| `--service` | off | Install and start a per-user macOS LaunchAgent in the logged-in Aqua UI session. |
| `--service-restart` | — | Restart the registered per-user macOS LaunchAgent. |
| `--verbose` | off | Enable periodic framebuffer-update logs on stdout. |
| `--clipboard-sync` | on | Share text and images (PNG, TIFF, JPEG, GIF, BMP, WebP, HEIC/HEIF, AVIF, JPEG 2000) with Apple Screen Sharing; text with classic VNC. |
| `--cursor auto\|embedded` | `auto` | Send system cursor shapes to RichCursor viewers for local pointer motion. Fall back to embedded rendering when unavailable, for other viewers, and in Apple Observe mode. |
| `--no-encryption` | on | Disable session-record encryption for framebuffer, clipboard and files. Type-30 account logins still decode Apple's AES-wrapped keyboard/mouse events using the authentication key. With `--file-transfer`, suppress the native viewer's record-key exchange on a plain URL. |
| `--file-transfer` | on | Enable Apple file/folder drag and drop with persistent incoming staging and Apple authentication/encryption negotiation. |
| `--encryption` | off | Negotiate Apple encryption when file transfer is enabled. |
| `--no-clipboard-sync` | off | Disable clipboard sharing. |
| `--no-file-transfer` | off | Disable file transfer and its receiving panel. |
| `--file-drop-mode` | `staged` | `staged` offers real local files and a receiving panel; `native` keeps the original Finder/file-promise workflow. |
| `--transfer-directory` | `~/Library/Application Support/mac-vnc-server/Transfers` | Persistent storage for received copies. Supply an absolute path. |
| `--transfer-limit-gib` | 10 | Limit retained files plus active transfer storage reservations. |
| `--transfer-free-gib` | 1 | Minimum free disk space to preserve while receiving. |
| `--no-adaptive` | off | Disable adaptive FPS, compression, and automatic scale changes. |

### Password and storage

The default listener verifies macOS account credentials with OpenDirectory,
including account policies. It does not read `VNC_PASSWORD`, generate passwords,
write passwords to disk, or forward passwords to workers. Apple security type 30
protects the credential exchange; session encryption remains off by default.
This legacy authentication protocol does not authenticate the server to the client.
Use an authenticated VPN/SSH transport when the network is not trusted.

The listener needs a client supporting username/password authentication via ARD
security type 30. Classic password-only clients cannot use this endpoint; they can
still use an explicit legacy `--session user` server with `VNC_PASSWORD`.
Only those legacy services need the variable in the user launchd environment.
`--password` remains unsupported.

There is no runtime read/write code for `~/.mac-vnc-server`. Settings come from
CLI arguments. Each user worker resolves default transfer storage inside its own
home after dropping privileges. An explicit `--transfer-directory` must be owned
by the selected account; one shared directory cannot be used across accounts.

Other persistent data lives outside the old directory:

| Data | Location |
| --- | --- |
| Received files, partial data, manifests and process leases | `~/Library/Application Support/mac-vnc-server/Transfers` (or `--transfer-directory`) |
| Service executable and arguments | `~/Library/LaunchAgents/com.pablozaiden.mac-vnc-server.plist` |
| Service standard output | `~/Library/Logs/mac-vnc-server/stdout.log` |
| Service errors | `~/Library/Logs/mac-vnc-server/stderr.log` |

Clipboard snapshots and session encryption keys remain in memory.

### Display modes

The account listener serves all session displays on its single port by default.
Only the legacy `--session user` mode opens additional consecutive ports when
`--display` is omitted.

To keep a single listener with the combined desktop:

```sh
./.build/release/mac-vnc-server-dev --display all
```

To serve only one monitor on the selected port:

```sh
./.build/release/mac-vnc-server-dev --display 1 --port 5900
```

Use `diagnose` to list display numbers:

```sh
./.build/release/mac-vnc-server-dev diagnose
```

## How it works

### RFB/VNC protocol

The server implements the RFB handshake and core client messages:

- protocol negotiation
- `SecurityType None` and classic VNC auth
- `SetPixelFormat`
- `SetEncodings`
- `FramebufferUpdateRequest`
- `KeyEvent`
- `PointerEvent`
- `ClientCutText`

Apple Screen Sharing negotiates RFB 3.3 and requires VNC auth, so authentication is enabled by default.

### Capture pipeline

Screen capture uses `ScreenCaptureKit` with one stream per selected display. Captured frames are stored in BGRA format and composed into a virtual framebuffer. The virtual framebuffer supports multiple displays and maps VNC coordinates back to macOS global coordinates for mouse input.

Capture streams are rebuilt after screen wake, when the user session moves off or back onto the console, when an active `SCStream` reports `didStopWithError`, or when input arrives after a failed recovery. Fast User Switching can replace display IDs even when a stream reports no error. Recovery refreshes the shareable content and retries up to three times without closing the existing VNC session. A transition during recovery queues another rebuild so it cannot leave capture attached to obsolete displays.

When a client or network cannot consume updates quickly enough, the server keeps only the newest captured frame and drops stale frames before sending their RFB update header. Persistent Zlib/ZRLE state is transactional, so a dropped frame cannot desynchronize the stream. Client sockets use non-blocking writes with a three-second no-progress timeout; a connection that makes no write progress is closed instead of blocking the capture pipeline indefinitely. Adaptive sessions lower the output target from 60 to 45 to 30 FPS under sustained pressure and recover after sustained headroom; shared capture streams use the highest rate requested by their active clients.

Clients that advertise the standard `DesktopSize` pseudo-encoding can also enter a per-client scale ladder of `1.0 -> 0.75 -> 0.67` after sustained encoding or network pressure. Frames are resampled with Apple's Accelerate framework using high-quality filtering so the server reduces work and bandwidth only when needed. The session recovers one scale step after five healthy seconds. Clients without standard resize support remain at the configured scale and use FPS/backpressure adaptation instead.

### Encodings

`--encoding auto` chooses a compatible encoding based on the client:

- clients advertising Zlib: persistent Zlib encoding (`6`), including Apple Screen Sharing
- otherwise, clients advertising ZRLE: ZRLE (`16`)
- fallback: Raw (`0`)

Zlib is kept as a persistent stream per VNC connection, which is required for stable compressed updates with Apple Screen Sharing.
Adaptive compression prioritizes sender throughput: it starts at level 2 with zlib-ng (level 1 with system zlib) and uses at most level 3 when the network is the bottleneck. It does not automatically switch to high compression levels during video or animation.
ZRLE uses lossless solid-color, palette, packed-palette, and run-length tile modes, selecting the smallest representation for each changed tile. Dirty regions use smaller tiles when appropriate, and framebuffer update rectangles are batched into fewer socket writes.

Capture arrivals wake the sender, which uses monotonic frame deadlines and skips obsolete slots. A bounded capture-copy worker keeps at most one pending buffer, and unchanged scaled snapshots are cached. Generic clients receive updates only for pending requests or negotiated ContinuousUpdates; Fence acknowledgements bound automatic frames to three in flight when supported. Clients advertising CopyRect can reuse verified vertical scroll regions from their last delivered framebuffer. Apple Screen Sharing does not advertise CopyRect in the observed sessions and benefits from the capture, caching and pacing changes instead.

With `--cursor auto` (the default), the server reads the system cursor through AppKit and excludes it from ScreenCaptureKit frames. RichCursor viewers receive shape/hotspot updates and move the cursor locally, without waiting for a round trip or another compressed frame. If cursor sampling is unavailable at startup, the server uses embedded capture. Viewers without RichCursor and Apple Observe sessions receive a composited cursor. Use `--cursor embedded` to retain capture-based rendering throughout.

The BGRX pixel-copy path supports Screen Sharing's depth-32 format as well as depth 24. Large visible scroll updates are coalesced and sent in one framebuffer update. See [performance measurements and limitations](docs/performance.md) for the benchmark, encryption policy, and why offscreen application content cannot be prefetched through RFB.

See [encoding compatibility and smoother scrolling](docs/encoding-compatibility.md) for per-client support, fallback behavior and CopyRect limits.
The [ZRLE repair and scrolling measurements](docs/scrolling-upgrade-2026-10-12.md) document the corrected encoder, full-pixel validation and measured CPU/timing results. ZRLE now shares the zlib-ng backend and compression controls with Zlib. Apple viewers receive the [three-byte compact-pixel format](docs/apple-zrle-compatibility-2026-10-12.md) their ZRLE decoder expects despite advertising depth 32.

### Multiple clients

Up to 32 clients can connect to the same port simultaneously. Each client authenticates separately and has its own framebuffer encoding, update rate, and clipboard subscription. A new connection does not disconnect existing viewers, including clients that request exclusive access through the standard RFB shared flag. Protocol handshake work has a 5-second total read budget. Password-protected connections have a separate 2-minute window for entering credentials, shared across security-type selection and the authentication prompt. Waiting for the first byte of those responses pauses the handshake budget; partial authentication responses and initialization after authentication still use its remaining time. This applies to both classic VNC passwords and Apple's username/password authentication. An established viewer can remain idle.

Accepted connections use TCP keepalive after 3 seconds of inactivity, with probes 1 second apart and three unanswered probes before disconnection (roughly 6 seconds for an unreachable idle peer, subject to OS timer scheduling). TCP retransmissions for unacknowledged data also have a 6-second limit; the three-second write-stall timeout can close a blocked writer sooner. These short limits target cleanup within 10 seconds during normal operation; brief network outages may require reconnecting. No viewer-side extension is required. A healthy viewer can remain idle indefinitely, but once it sends a message type, the complete message must arrive within 5 seconds, including any clipboard payload. Partial progress does not reset that deadline. Timeout cleanup releases that viewer's held controls and client slot without disconnecting other viewers. TCP keepalive detects network loss; it cannot detect a frozen viewer application whose OS still answers probes.

All viewers share the logged-in Mac's desktop, keyboard, and system cursor. Pointer movement from any controlling viewer moves that cursor. Held keys and mouse buttons are tracked by client and stay pressed until their last remote owner releases them; disconnecting or switching an Apple viewer to observe mode releases only that viewer's controls. Click sequences reset when another client takes over the pointer. These rules also apply across the automatic display ports within one server process.

With `--clipboard-sync`, server clipboard changes reach every client with sharing enabled. Text or images copied by one Apple viewer can propagate to the others through the Mac's clipboard; the originating viewer is not notified of its own write, and identical content echoes do not produce another clipboard change. This is a shared desktop, not separate macOS login sessions. Concurrent screen encoding and network traffic grow with the number of viewers.

For an already logged-in user, the server stays attached to that user's desktop when Fast User Switching moves the physical console to loginwindow. Input targets the user's WindowServer session and capture follows its replacement displays. Start the server in that user's GUI session (the per-user service does this), then connect using the ordinary VNC URL. This does not provide the console loginwindow, log another account in, or create a GUI session before login. See [off-console session access](docs/off-console-session-access.md) for validation and remaining limitations.

### Input

Keyboard and mouse events are injected with `CGEvent` at `cgSessionEventTap`, matching Apple's ScreensharingAgent. Mouse movement, scrolling, modifiers, Unicode input, and disconnect releases all use the same destination. This keeps remote input in the server user's session when the physical console switches to loginwindow.

The server processes input on the read loop and streams framebuffer updates on a separate writer queue. This prevents keyboard/mouse events from getting stuck behind frame compression or socket writes.

For Apple Screen Sharing, `Alt_L` / `Alt_R` keysyms are remapped to macOS Command because the native client sends Command that way. This enables shortcuts such as `Cmd+C`, `Cmd+V`, `Cmd+W`, and `Cmd+Q`.

### Clipboard

Clipboard synchronization is enabled by default. Use `--no-clipboard-sync` to disable it. The explicit enabling option remains available:

```sh
./.build/release/mac-vnc-server-dev run --clipboard-sync
```

With `--clipboard-sync`, the server advertises Apple's RFB 3.889 dialect and negotiates an extended ServerInit with compatible viewers. Apple Screen Sharing uses native pasteboard notifications, fetches, and compressed text and image archives. Other viewers can negotiate RFB 3.3, 3.7, or 3.8 and continue using classic cut text messages. The configured password remains required in either mode.

On the client, enable **Edit → Use Shared Clipboard** after connecting. Screen Sharing owns this checkbox through its saved clipboard preference. Verbose logs report when clipboard sharing is available but disabled by the viewer. The implementation supports Unicode and multiline text, PNG, TIFF, JPEG, GIF, BMP, WebP, HEIC/HEIF, AVIF and JPEG 2000 images, clearing, and deferred clipboard requests in both directions. Image bytes are preserved, including GIF animation when the source app supplies the original GIF representation; a still-image copy cannot restore animation. The receiving app must support the supplied format. Apple clipboard archives are limited to 100 MiB; classic VNC text remains limited to 16 MiB. Rich-text preservation and macOS account authentication are not implemented. See [Apple clipboard implementation and validation](docs/apple-clipboard.md) for protocol details and validation results.

File/folder drag and drop is enabled by default. Use `--no-file-transfer` to disable it.
The default is the experimental plaintext Apple profile; `--encryption` enables
Apple encryption negotiation. Connect from the client with:

```sh
open -a "Screen Sharing" 'vnc://SERVER_IP:5900/'
```

Use control mode, then drag files or folders from local Finder into the remote
view. The server requests the files immediately and shows a Received Files
panel. Keep holding to let it attempt a drag with completed local files; if you
release first, drag the completed row from the panel into the target app.
Copies are stored under `~/Library/Application Support/mac-vnc-server/Transfers`;
used files remain until explicitly removed. Choose **Received Files…** from the remote-VNC menu-bar icon, or use
`mac-vnc-server transfers` to reopen them. See [staging, retention, and timing
verification](docs/staged-file-drops.md) for limits and remaining client tests.
`--file-drop-mode native` retains direct drops into Finder through file promises.
Drag a remote Finder item out of Screen Sharing into local Finder to copy in the
other direction. Existing destinations are preserved with numbered names.
The account listener always uses Apple Diffie–Hellman username/password
authentication, whether session encryption is on or off. Enter the selected
macOS account's actual credentials. With `--encryption`, the worker can negotiate
Apple AES records and encrypted input events. Default `--no-encryption` suppresses
the viewer's session-encryption key exchange on the same plain URL. This plaintext
file-transfer behavior uses undocumented Apple extensions; native client
interoperability must be checked for each macOS release.
All native interoperability tests use plain URLs and the app's encryption default.
See [plaintext validation and client limitations](docs/apple-file-transfer.md#plaintext-validation).
Control permission is available from startup;
Screen Sharing's selected mode is respected, including a saved Observe choice. This legacy protocol does not
authenticate the server's identity. Use SSH or a VPN for a trusted channel over
untrusted networks. The `--no-password` profile cannot negotiate Apple encryption.
Display negotiation prefers Apple's modern layout format (1105) with console
state and explicit scale, retaining format 1101 for older viewers.

The backend uses the system's private `SSFileCopySender` and
`SSFileCopyReceiver` executables as the logged-in user. Reverse-direction and
native-mode drags also use `SSDragHelper`; incoming staged drags use AppKit.
Tests cover native file/folder helpers, drag initialization and authorization,
completion staging, collision handling and cancellation. An unshown Tahoe native
Screen Sharing view also verifies that a real connection registers Finder drops
and enables both directions. Actual Finder gestures with the macOS 13.1 client
remain a manual interoperability check. Receiving symbolic links is unsupported.
See [Apple file transfers](docs/apple-file-transfer.md) for the protocol and limits.


Mouse clicks carry macOS click counts, using the server Mac's double-click interval and desktop-point coordinates. Apple RFB 3.889's right/middle button ordering is translated before posting events. Client cursor mode sends real system shapes, including I-beam and resize cursors; shape sampling runs at approximately 30 Hz, while pointer movement is local to the viewer. Cursor updates wait for a framebuffer request to preserve Screen Sharing's startup ordering. Embedded rendering hides any negotiated viewer overlay to prevent a duplicate cursor.

## GitHub Actions

This repository includes two workflows:

### CI

`.github/workflows/ci.yml`

Runs on pull requests and pushes to `main`:

- `swift test`
- `swift build -c release`

### Release

`.github/workflows/release.yml`

Runs when a GitHub Release is published:

- replaces `0.0.0-development` in `AppVersion.swift` with the release tag
- runs tests
- builds the `mac-vnc-server-dev` product for arm64
- stages it as `mac-vnc-server` and signs it with the persistent self-signed macOS certificate
- prepares the binary plus SHA-256 checksum
- uploads `mac-vnc-server` and `mac-vnc-server.sha256` to the GitHub Release

The workflow requires these repository secrets:

- `MAC_VNC_SERVER_MACOS_SIGNING_CERT_BASE64`
- `MAC_VNC_SERVER_MACOS_SIGNING_CERT_PASSWORD`

Generate the persistent certificate locally with:

```sh
./scripts/generate-macos-signing-cert.sh
```

Then load the certificate and password into GitHub without printing either secret:

```sh
base64 < .mac-vnc-server-signing/macos-signing.p12 | tr -d '\n' | \
  gh secret set MAC_VNC_SERVER_MACOS_SIGNING_CERT_BASE64 --repo PabloZaiden/mac-vnc-server
gh secret set MAC_VNC_SERVER_MACOS_SIGNING_CERT_PASSWORD \
  --repo PabloZaiden/mac-vnc-server < .mac-vnc-server-signing/macos-signing-password
```

The self-signed certificate provides a stable signing identity for macOS permissions; it does not provide notarization or Gatekeeper trust.

## Troubleshooting

### Apple Screen Sharing keeps asking for a password

Use the selected macOS account username and password. Confirm that its GUI session already exists. Root requires a root listener and an enabled root account; it selects the current console owner, whether loginwindow or a user desktop. Only explicit legacy endpoints use `VNC_PASSWORD`.

### Startup stops after the cursor message

A `SWIFT TASK CONTINUATION MISUSE` warning at startup can come from
ScreenCaptureKit discarding its callback when its connection to the macOS
capture service (`replayd`) fails. On Tahoe, this was reproduced with an older
instance still running from the same executable path. Restarting that instance
cleared the failure; Screen Recording permission was already granted.

The server now reports which capture operation failed instead of waiting
forever. Display enumeration allows 60 seconds for permission handling; stream
start/configuration allows 15 seconds, and stream stop allows 5 seconds.
Discarded callbacks fail immediately. Ctrl-C and SIGTERM request listener and
capture cleanup. Repeat the signal to force exit; a five-second deadline also
forces exit if cleanup stalls. Console workers owned by that process are
terminated on forced exit. After rebuilding, restart older
instances that still use that executable. For simultaneous comparison servers,
use separate executable copies: Tahoe's capture-service conflict can persist
with concurrent instances of the same path even when streams stop cleanly.
`diagnose` reports permission status.

To check the actual capture startup, including staged file drops and automatic
display ports, from a session with Screen Recording permission:

```sh
python3 scripts/smoke-capture-startup.py .build/release/mac-vnc-server-dev
```

This uses isolated loopback ports, receives real Zlib frames, and checks clean
shutdown without posting input or saving desktop images.

### Screen updates work, but input lags

Make sure you are running a build with the split reader/writer architecture. Rebuild:

```sh
swift build -c release
```

Then restart the server.

### Input works, but screen does not update

Use the default encoding first:

```sh
./.build/release/mac-vnc-server-dev --encoding auto
```

If the display slept while the server was running, wait briefly for the automatic ScreenCaptureKit recovery. If the display is still unavailable, the next keyboard or mouse event sends a `caffeinate` wake signal and triggers another asynchronous recovery attempt. The server logs `ScreenCaptureKit: capture recovered` when the streams are available again. If the server was started while the display was already asleep, run `mac-vnc-server wakeup` and start it again.

If testing a generic client, try:

```sh
./.build/release/mac-vnc-server-dev --encoding zrle
./.build/release/mac-vnc-server-dev --encoding zlib
./.build/release/mac-vnc-server-dev --encoding raw
```

### Port already in use

Use another port:

```sh
./.build/release/mac-vnc-server-dev --port 5903
open 'vnc://127.0.0.1:5903'
```

### Permissions are missing

Run:

```sh
./.build/release/mac-vnc-server-dev permissions
./.build/release/mac-vnc-server-dev diagnose
```

Then restart the server after granting permissions.
