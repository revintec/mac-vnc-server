# Apple Screen Sharing file transfers

`--file-transfer` enables file/folder drag and drop using an experimental
Apple compatibility profile with encryption negotiation. The file option independently selects
Apple RFB 3.889; classic VNC viewers continue to work without file transfer.
`--clipboard-sync` separately enables text and image clipboard sharing.

## Connecting

Restart the updated server with `--file-transfer`, disconnect any existing
Screen Sharing connection, and open this URL on the client:

```sh
open -a "Screen Sharing" 'vnc://SERVER_IP:5900/'
```

Replace the address and port. In control mode, drag local Finder items into
remote Finder/the remote desktop, or remote Finder items out into local Finder.
Shared Clipboard is a separate feature and is not required for file transfer.
Files are copied; the originals are retained. With a configured password and
encryption allowed (the default), Apple viewers use security type 30 (Diffie–Hellman), which initializes the wrapping key
needed by Apple's record encryption. Enter any username and the existing server
password in Screen Sharing's login dialog. The username is a label; this server
does not authenticate macOS accounts. Standard VNC viewers retain security type 2.

Earlier versions refused SetEncryption and depended on a client URL override. Simply
implementing the record cipher with type 2 still fails in the native viewer:
that authentication path leaves its wrapping cipher uninitialized. The type 30
exchange fixes this prerequisite, and the server now handles SetEncryption
without a URL override. Native Tahoe tests use a plain URL and register the
Screen Sharing 3.0 app's encryption default, which requests encrypted records.
The macOS 13.1 client needs a manual retest with the plain URL.

Apple's legacy protocol does not authenticate the server's identity. Encryption
is selected by the viewer, not forced by this option. SSH or a VPN supplies a
trusted channel over untrusted networks. `--no-password` continues to offer None
authentication and cannot negotiate Apple's record encryption.

`--file-transfer --no-encryption` selects an experimental plaintext server mode
using the same plain URL. It retains native capabilities and classic VNC password
authentication. The client still requests encryption, but the server consumes
that request without sending encryption keys or enabling encrypted records.
Tahoe's native viewer continues in plaintext, including key input and file-drop
registration. This behavior is undocumented and has not been verified with real
Finder gestures on macOS 13. The normal mode honors encryption requests; the
explicit plaintext mode does not satisfy the client's encryption preference.
With file transfer disabled, framebuffer traffic is already unencrypted, including
with text/image clipboard sharing. See [performance measurements](performance.md).

Use Shared Clipboard remains a client preference. Advertising Control permission
does not select it. See [clipboard behavior](apple-clipboard.md).

Another captured failure with the same client ended with `unsupported client
message 8`, sometimes after streaming frames. This is `SetServerScaling`, not an
authentication or encryption failure. The server now consumes its ten-byte
request (type, padding, big-endian double) and handles finite factors in `(0, 1]`.
It sends DisplayInfo with the new pixel dimensions even when the viewer has not
requested a frame. The viewer then requests pixels after setting up its bitmap.
Logical desktop dimensions and pointer coordinates remain unscaled, and each
connection has its own scale.
The native viewer can send this message without checking its capability bit.

Repeated DisplayInfo replies can clear Screen Sharing's bitmap even when the
dimensions are unchanged. Sending pixels immediately after the layout can race
that reset; comparing subsequent frames against the old image can then leave a
static desktop black. Every layout reply now discards earlier frame requests
and automatic-update arming, as Apple's server does. A fresh ordinary or automatic
request receives a full image, including unchanged pixels. Layout changes are
detected before encoding so an unsent frame cannot advance the compression stream.
Verbose logs show the first eight ordinary framebuffer requests and updates,
full-refresh requests, pixel formats, and when a layout is awaiting a new request.
The reported intermittent black screen on macOS 13.1 still needs a client retest;
its supplied trace alone does not establish whether a frame request followed
the final layout reply.

Control permission is advertised in extended ServerInit (flags `0x12`). The
server accepts the viewer's SetMode choice without sending a permission reply.
Repeated requests leave the state unchanged. Switching to Observe releases held
input and cancels transfers; Control remains available in the viewer's menu.
An initial or restored Observe preference is respected.

The previous startup workaround sent MiscStatus 10 to revoke Control, followed
by a timed MiscStatus 9 grant, and echoed status 9 for each SetMode(control).
Those replies could trigger more asynchronous mode callbacks and requests.
They have been removed. Inspection of Tahoe's native daemon confirms that
SetMode updates the chosen mode without sending those statuses. Native
ViewerInfo sends status 10 only under actual session restrictions, and a
framebuffer request sends status 9 only when lifting a temporary restriction.
An unrestricted session must not manufacture that transition.

A subsequent macOS 13.1 crash report identified a second independent disconnect:
`unsupported client message 16` immediately after encryption negotiation.
That message is Apple's EncryptedInputEvent (`0x10`), a separate per-event AES
block, not a CBC record header. The server now decodes it using the current
session key and applies the same mode checks as ordinary keyboard/mouse input.

The opt-in native probe covers defaults, explicit modes, a saved Observe
preference, and restoring Observe before the first image, with file transfer
enabled and disabled. Its batching wrapper exercises coalesced startup replies:

```sh
xcrun clang -fobjc-arc -framework AppKit scripts/probe-native-screen-sharing.m -o /tmp/mac-vnc-native-control-probe
MAC_VNC_NATIVE_PROBE="$PWD/scripts/probe-native-screen-sharing-batched.py" swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing --filter nativeScreenSharing
```

These native checks use Tahoe's installed framework. Screen Sharing 3.0 on
macOS 13.1 still requires a manual retest of the rebuilt server; passing the
Tahoe probe does not establish that the older client no longer crashes.

## Native-client negotiation

A user test with Screen Sharing 3.0/macOS 13.1 produced no drag logs when a local
Finder file was dragged into the remote desktop, even with `--file-transfer` on.
Inspection of Tahoe's native ScreenSharing framework identified a prerequisite
missed by the helper-only tests:

- The client marks its screen configuration as legacy VNC when the server does
  not advertise `SetEncryption` (`0x12`).
- In that mode, the framebuffer view registers text drag types, omitting Finder
  file types. FileCopy (`0x22`) and DropEvent (`0x20`) capabilities alone do not
  enable the file-drop target.
- The client separately checks its minimum encryption preference before asking
  for encrypted records. Screen Sharing 3.0's app default requests encryption.

### Plaintext validation

All further interoperability work uses plain `vnc://HOST:PORT/` URLs and the
app's normal encryption setting. No URL query or equivalent encryption override
is used to make a test pass. The native probe rejects URLs with query parameters
and no longer accepts an encryption override argument.

The user-provided Screen Sharing 3.0 build 585.1 registers app default
`encryptionLevel=2` in `registerAppDefaults` (ARM64 `0x10000bf18`–`0x10000bf30`).
The probe registers that same default in its disposable process without writing
persistent preferences. This is different from the bare framework's default of 0.
The framework requests SetEncryption level 1 when the configured minimum is 2
and command `0x12` is supported. `_RFBSetEncryptionLevel` offers only AES method 1
on this path; no plaintext cipher is offered. However, the client does not begin
using encrypted records until it receives the server's encoding-1103 key reply.

The plain-URL native tests compare three outcomes:

| Server profile | Result with app defaults |
| --- | --- |
| Basic profile, no encryption capability | Desktop and input work; legacy VNC mode has no Finder file drops. |
| Native file-transfer profile, encryption allowed | Encrypted streaming, key input, scaling, and both file-drop directions are enabled. |
| Native file-transfer profile, encryption request explicitly rejected | The viewer requests encryption even with type 2 authentication; rejection disconnects the session before a frame. |
| Native file-transfer profile, key reply suppressed | The viewer requests encryption, but continues streaming, input, scaling and file-drop registration in plaintext when no keys are sent. |

The last case was first tested in a disposable server copy. It showed that
disconnecting on an encryption request was our server's policy, not proof that
the viewer enforces encrypted traffic. The `--no-encryption` implementation now
fully parses valid SetEncryption command-1 messages and leaves them unanswered.
It logs that the session remains plaintext, never initializes the AES session key
or either record cipher, and rejects attempts to enable encrypted records or send
encrypted input. Repeated key requests must not desynchronize subsequent messages.
This is an explicit, undocumented compatibility mode, not a negotiated null cipher.

Earlier tests used a URL override or the bare framework's plaintext default.
They established that file-copy payloads and native drop registration do not
inherently require encrypted records, but did not meet the unchanged-app/plain-URL
requirement. Helper tests also copied and verified contents over plaintext
sockets in both directions; they substitute the desktop drag helper and therefore
do not validate real Finder gestures. Those results must not be cited as evidence
that the app's default plain-URL session supports plaintext file drops.

Type 30 authentication additionally encrypts keystrokes independently of record
encryption; removing the EncryptedInputEvent capability does not prevent that.
Selecting type 2 avoids that input cipher but does not stop the app's default
request for record encryption; suppressing the key reply is also necessary.
The native plaintext test exercises 20 seconds of changing pixels before keyboard
input and scaling, with the original encryption default still set to 2.
The copied app cannot run unmodified against Tahoe's private
framework, as described below, so actual Finder gestures on macOS 13.1 remain a
manual interoperability check. The native tests use Tahoe's framework and a hidden
view, synthetic pixels, private pasteboards and mock input.

Reproduce the native-view comparison:

```sh
xcrun clang -fobjc-arc -framework AppKit scripts/probe-native-screen-sharing.m -o /tmp/mac-vnc-plain-url-probe
MAC_VNC_NATIVE_PROBE=/tmp/mac-vnc-plain-url-probe swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing --filter 'nativeScreenSharingNegotiatesEncryptionWithAppDefaults|nativeScreenSharingUsesPlaintextWithAppDefaults|nativeScreenSharingStreamsWithClientCursor'
```

Reproduce the plaintext/encrypted file-copy and policy tests with the same
`swift test` compiler options and `--filter 'negotiatedDragAuthorizesNativeFileCopy|plaintextPolicy'`.

### Display negotiation

The opt-in file-transfer profile advertises and implements `0x12` to enter the
native UI path. The viewer then waits for display metadata before completing
session setup. Native macOS prefers DisplayInfo2 (encoding 1105) when the viewer
offers it, regardless of encoding order or duplicates; encoding 1101 is the
fallback. The server follows that selection for startup, resizing and scaling.
One logical screen describes the framebuffer selected by the listening port.

DisplayInfo2 version 5 carries a 20-byte header and one 56-byte display record.
Its two-byte length counts only the following payload. This server reports one
main screen at density 1, the selected port's unscaled desktop bounds, the actual
scaled pixel bounds, and the requested server scale. Session flag `0x04` reports
the console session; virtual-display and curtain capabilities are not advertised.

The supplied macOS 13.1 traces show the old port 5900 client keeping Control,
while the native-profile connection on 5902 initially requests Control and then
requests Observe after the first legacy DisplayInfo, before any pixels. Both
servers advertise the same Control privilege (`0x12`). The old server does not
enter the native display-configuration path. Sending only 1101 despite the
viewer's 1105 offer was a mismatch with native macOS. The Tahoe probe previously
reported `displayInfo2Version=-1`, unreliable display state and `onConsole=0`;
the modern reply must decode as version 5 with reliable state and `onConsole=1`.
The subsequent macOS 13 retest confirms receipt of encoding 1105 but still
shows Control followed by Observe before the first frame. The metadata change
does not fix that mode fallback. There is no intervening server permission
revocation in the trace.

Tahoe's `SSSessionView.ssSessionReady:` reapplies
`connectionOptions.controlType`, separately from the initial protocol SetMode.
The Screen Sharing app can restore that option during startup. A controlled
probe against the same server demonstrates that restoring an Observe option
before this callback ends in Observe, while restoring it after the callback can
leave the view in Control. This isolates a possible ordering mechanism; it does
not establish the option value or callback order in the macOS 13 application.
A normal-mode startup test with an explicit Control option does not cover the
app's preference restoration, and must not be treated as proof of plain-URL
default Control.

### Screen Sharing 3.0 connection-state restoration

The subsequent macOS 13 client log reports `supportsControlMode=1`, followed by
`set control mode 0`. The user's read-only defaults check found no persisted
`com.apple.ScreenSharing controlType` key. That excludes a persisted value for
that key, but does not exclude per-connection restoration or registered defaults.

Inspection of the supplied Screen Sharing 3.0 (585.1, macOS 13.1) executable
identifies a separate restoration path. In the x86_64 slice:

- `SessionWindowController.sessionIsReady` calls
  `restoreSavedSessionStateOptions` at `0x10000a4bc`, then reapplies URL options.
  Opening a plain URL does not bypass restoration.
- `restoreSavedSessionStateOptions`, at `0x100009fed`, reads the connection's
  `.vncloc` file and its `restorationAttributes` dictionary. If either is absent,
  it returns without changing the initial connection options.
- At `0x10000a288`, it uses `restorationAttributes.controlMode` when present;
  otherwise it reads `NSUserDefaults.integerForKey("controlType")`. Unlike the
  Tahoe app, the saved mode does not require `isReconnecting` to be true.
- `proxyIconFilepath`, at `0x100006b21`, uses the display name, an optional
  embedded username for a native connection, and a non-default port suffix.
  Thus ports 5900 and 5902 do not necessarily restore the same state. The usual
  5902 filename is `mac-vnc-server 5902.vncloc` under the app container's
  `Library/Application Support/Screen Sharing` directory.
- The `writeVNCFileToPath:` branch using `savedWindowRestorationState` explicitly
  removes `controlMode` at `0x100002ed4`. A connection file can therefore have
  restoration attributes while lacking that mode key.

A read-only inspection of this Tahoe machine's 5902 connection file found
`restorationAttributes` with no `controlMode` and with `autoClipboard=false`.
This was local evidence, not a read of the remote macOS 13 client's file, and
must not be used to attribute the client's earlier fallback to a missing key.
The user subsequently supplied the actual macOS 13 file: it contained
`controlMode=1` and `autoClipboard=true`, both while the app was open and after
it closed. The next plain-URL connection to 5902 correctly started in Control,
with no additional server code change. A later quit/reconnect returned to
Observe and saved `controlMode=0`, `autoClipboard=false`. The single successful
reconnect did not establish a fix. In particular, the file can record a startup
reset rather than cause it.

A hidden Tahoe-framework probe transcribing just the 3.0 mode-restoration branch
into the real `sessionIsReady` delegate callback produced these results against
both running servers. Each connection started with option 1, matching the user's
initial wire request. The scenarios used synthetic state in memory, with no
preference writes, shared clipboard, or desktop input:

| State supplied to the callback | Old server, port 5900 | Current server, port 5902 |
| --- | --- | --- |
| No restoration dictionary | Control | Control |
| Dictionary with no mode, global integer resolves to 0 | Observe | Observe |
| Dictionary with `controlMode=1` | Control | Control |

This demonstrates that the same restoration condition can reproduce Observe
with either server; it does not prove the macOS 13 client's earlier saved state.

The unmodified copied 3.0 app launches on Tahoe but cannot complete a native session there:
it calls the removed private method
`+[SSSessionView connectionOptionsWithOptions:urlOptions:]` from `sessionIsReady`,
raising an unrecognized-selector exception. The UI then reports the generic
viewer/server incompatibility error. Copying only the app does not bring its
macOS 13 ScreenSharing framework, so that run cannot validate Ventura protocol
compatibility. The local test used synthetic pixels and mock input; it was
stopped without changing either live server.

### Premature cursor update and restoration reset

A disposable, instrumented copy of 3.0 reproduced the reset against synthetic
test servers. Its connection-file reads and writes were redirected to a private
temporary file. A compatibility adapter supplied the removed Tahoe method above,
which runs after `restoreSavedSessionStateOptions`; it does not reproduce
Ventura's URL-merging implementation. Both native and legacy server profiles
could produce this sequence:

1. The server sends an empty cursor framebuffer update after `SetEncodings`,
   before the viewer has requested any pixels.
2. `sessionDidFinishConnecting` runs while the controller is not ready and the
   view still reports Observe and clipboard off. A window frame notification
   calls `writeVNCFileToPath:` and overwrites the saved Control value with 0.
3. `sessionIsReady` calls `restoreSavedSessionStateOptions`, which reads that
   overwritten value and changes `connectionOptions.controlType` from 1 to 0.

The server now retains the pending cursor until a framebuffer request is being
served. Display metadata and encryption negotiation still proceed independently.
With this change, the copied app restored its options and entered Control before
the first window-state write. Two saved-Control starts and a normal Quit followed
by reconnect without reseeding the test file all entered Control. The latter
also exercised the app's missing-mode fallback after Quit removed the mode key.
The saved clipboard flag survived until restoration; the test URL deliberately
disabled clipboard sharing afterward to avoid using the general pasteboard.
Actual clipboard selection and the complete Ventura framework still need a
macOS 13 retest.

The opt-in native probe now checks that readiness precedes connection completion
and models the app's save/restore callbacks with in-memory Control and Observe
values. Wire tests require cursor updates to wait for a framebuffer request,
including repeated capability negotiation and both cursor encodings. This fixes
the demonstrated startup overwrite; it does not override an existing saved
Observe choice. A connection file already containing 0 can still restore it.

An unshown Tahoe Screen Sharing view connected to the test server verifies that
this combination registers file URLs, filenames and file promises as drag types,
and enables both transfer directions after repeated observe/control transitions.
The probe verifies the decoded layout version and console state, checks that the selected mode stays unchanged, counts unsolicited
mode callbacks, and requires multiple changes in decoded synthetic pixels over
six seconds. It tests explicit Observe/Control switches and fails on native
warnings. It also sends a synthetic key down/up through the native sender into
mock server input, exercises scaling and restores a 1728×1118 desktop, checking
decoded pixels after repeated scaling requests. It uses no real desktop input,
general pasteboard, or persistent client preference changes.
Actual Finder gestures on macOS 13.1 remain a manual interoperability test.

Both the reported macOS 13.1 connection and the Tahoe native probe omit the
ViewerInfo FileCopy bit (`viewer_file_copy=false`), even when the native view
enables file drag types. The transfer gate therefore uses the advertised drag
and transfer-request messages, rather than that absent bit. Control mode and
`--file-transfer` are still required. Each file-copy request must follow the
connection's own source/destination drag authorization; an unselected path is
rejected before a file helper starts. Actual Finder gestures on macOS 13.1 still
need manual validation.

Verbose logs now record DragEvent and DropEvent before capability filtering,
along with the negotiated per-direction capabilities. This distinguishes a
client that never sends a drag from one whose message is rejected by the server.

## Implementation

### Authentication and encrypted records

Apple viewers with a configured password and encryption allowed are offered only
type 30 for this profile. Offering type 2 alongside it lets saved VNC credentials select a path
that cannot initialize Apple's record keys. The server sends RFC 3526 group 14,
generator 2, and a fresh 2048-bit public key. macOS Security's SecDH functions
generate the private key and validate/compute the peer exchange; these exported
functions are resolved at runtime and fail closed if unavailable. Their C ABI
is described in Apple's [SecDH header](https://github.com/apple-oss-distributions/Security/blob/main/OSX/sec/Security/SecDH.h).

The full-width shared secret's MD5 digest is the protocol-required AES-128
wrapping key. The client sends a 128-byte AES-ECB credential block followed by
its public key. Both credential fields must terminate within their 64-byte
slots. The entire configured password is compared; credentials are never logged.

SetEncryption command 1 carries a level and supported cipher methods. Method 1
selects AES. Encoding 1103 returns a method word and fresh key/IV, wrapped under
the authentication key (or preceding session key on rekey). Command 2 switches
incoming records. Level 1 enables outgoing records; level 0 exchanges keys while
leaving outgoing messages in cleartext. Rekey replies use the previous transport,
then restart CBC and independent sequence counters for each direction.

Each record is a big-endian u16 ciphertext length, then AES-128-CBC of a u16
payload length, payload, filler and SHA1(sequence || preceding plaintext).
CBC chains across records; the maximum ciphertext length is 65,520 bytes.
Socket reads join messages split across records, and writes split large clipboard,
framebuffer and file payloads. Malformed lengths, integrity failures and invalid
mode switches terminate the session. Partial records have bounded deadlines.

EncryptedInputEvent (`0x10`) is 18 bytes: type, flags and one AES-ECB block.
Decrypted byte 0 is a key marker and byte 10 a pointer marker; each must be 0 or
`0xff`. A key event carries the down flag at byte 1 and BE keysym at bytes 2–5.
A pointer event carries its button mask at byte 11 and BE x/y at bytes 12–15.
Both markers may be set (key then pointer); two zero markers form an empty event.
The initial key comes from authentication;
encoding 1103 rekey replaces it along with the record ciphers. This envelope can
arrive before SetEncryption command 2 or within an encrypted record. No input is
applied in Observe mode. Invalid markers or missing keys terminate the session.

Tests cover independent OpenSSL record and event vectors, encrypted key/pointer
input before and after repeated rekeying, Observe input gating, split/combined messages,
large clipboard uploads/downloads, chunked writes, invalid keys and credentials,
tampering/replay, malformed negotiation and actual partial-record disconnection.
Both directions of negotiated native file-copy tests pass through plaintext and
encrypted test sockets and compare received file contents. These tests substitute
the desktop drag helper, while retaining the native file send/receive helpers.
The hidden native view verifies sustained decoded pixels, stable modes,
key input, scaling and file-drop registration with encryption enabled and no
encryption URL override.

### File messages

Apple file drag and drop uses three client message types, distinct from ClipboardSend:

| Type | Layout and purpose |
| --- | --- |
| `0x0e` DragEvent | 8 bytes: type/padding, BE u32 session; request the current server drag |
| `0x20` DropEvent | 16-byte header: type/padding, BE u32 session, archive size and compressed size; archive follows |
| `0x22` FileCopy | type, pad, BE u32 body size; body begins with BE u16 version, u16 command, u32 session |

The server sends a drag archive with `0x20`. A successful incoming drop produces
`0x1e`, followed by the session, UTF-8 path byte count, and selected destination
path. The viewer then coordinates FileCopy sessions for the dropped items.

FileCopy commands 1 and 2 start sending and receiving. Version 1 receives into a
directory and uses the source item's name; version 2 supplies a separate destination
name. Commands 3/4 pause/continue a sender; 5 cancels. Commands 100–104 carry item
information, items, raw/compressed file contents and completion. Command 200 reports
a receive result and final filename; 201 is progress.

These layouts were derived from the native Tahoe RemoteManagement executables and
checked with temporary-file probes. They are private protocols, not Apple API
compatibility guarantees.

`MacFileTransfer` runs the installed system helpers as the server's user:

- `SSDragHelper` negotiates Finder drag promises and the drop destination.
- `SSFileCopySender` reads files/folders and produces native transfer records.
- `SSFileCopyReceiver` restores contents and macOS metadata into a private staging
  directory under the selected destination.

Sender stdin is native u16 command 1, u32 session, u16 UTF-8 path length, then path.
Its stdout is a native u32 record length, u16 helper command, and record body.
Command 1 carries a complete network FileCopy message; 2 completes; 3 is local
progress. Receiver stdin replaces the network outer header with native u16 helper
command 2 and u32 body length; common fields use host endian and item data retains
network byte order. Its stdout uses native u16 command 1 for a 1,284-byte final
status/name record, or command 2 for an eight-byte progress record.

The drag helper reads native u32 session, compressed size and archive size, then
the archive. A zero compressed size requests the existing local drag. Output codes
15/20 initialize/acknowledge an incoming drag, 10 requests a file transfer to a
destination, 11 supplies a drag archive, 12/13 request mouse-up/drag, and 14 finishes.
The RFB reader waits for code 15 before accepting later pointer packets. Incoming
drags post a fresh mouse-down and acknowledge with 20. Synthetic buttons pass
through the connection's shared input controller, so a quick drop, cancellation
or disconnect releases the button while preserving other viewers' button state.

## Bounds and lifecycle

Only control-mode Apple viewers with the required capabilities can transfer files.
Each connection tracks its selected source paths, accepted drop directories, and
up to eight active transfers. A viewer cannot request an unselected source file or
a destination outside its own drop negotiation. Only one native drag helper can
own the shared desktop at a time. Changing to observe mode, disconnecting, or
cancelling terminates that connection's helpers and removes partial staging.

Drag archives are capped at 5 MiB and FileCopy bodies at 1 MiB. The helper stream
uses bounded pipe reads, and the framebuffer writer applies backpressure to
outgoing file records. Incoming regular-file/folder records are validated before
being passed to the receiver. Symbolic-link items are rejected. Images in a drag
archive are separate from general clipboard images.

Completion publishes the staged root item using an atomic exclusive rename.
Existing destination items remain intact; collisions get a numbered filename.
The feature copies files and folders and does not delete source files.

## Validation and remaining manual checks

Automated tests use real system sender/receiver helpers with temporary files.
They cover nested folders, a 2 MB binary payload, Unicode names, empty files,
version 1/2 receive framing, collisions, cancellation cleanup, malformed records,
capability opt-in and rejection of an unrelated connection's file request.
Additional tests replace only the desktop drag helper with bounded socket pairs
and verify readiness ordering, button release, and negotiated source/destination
authorization before transferring contents through the real file-copy helpers.
These tests do not interact with Finder, move the pointer, or alter the general
pasteboard.

The native-client control and registration test is opt-in because it loads a private AppKit
framework. Build `scripts/probe-native-screen-sharing.m` as described at its top,
then run `swift test` with `MAC_VNC_NATIVE_PROBE` pointing to that executable.
It connects to a loopback test server with synthetic pixels and a named
pasteboard; its window is never shown.

Manual checks with Screen Sharing 3.0/macOS 13.1 after rebuilding and reconnecting
with the plain VNC URL:

1. Drag a small file from local Finder into the remote desktop; compare contents.
2. Drag a remote Finder file out of the Screen Sharing window into local Finder.
3. Repeat with multiple files, a nested folder and an existing destination name.
4. Cancel a large transfer, disconnect during it, and toggle observe/control mode.
5. Copy a screenshot in each direction with Use Shared Clipboard enabled.

Helper presence is checked at runtime. New macOS releases can change these private
interfaces; failures are logged and this implementation has not been validated on
other server OS versions or with non-Finder drag sources such as promised downloads.
