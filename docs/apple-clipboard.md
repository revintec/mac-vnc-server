# Apple Screen Sharing clipboard

Enable with the existing `--clipboard-sync` option. Reconnect after switching
binaries: the Apple capabilities are negotiated at connection startup. On the
viewer, select Edit → Use Shared Clipboard. This is a client-owned preference
(`autoClipboard` / `shouldSharePasteboard`). The native client retains its value
when Control becomes available. No server message has been identified that
selects it or starts the client's local clipboard monitoring. The server honors
AutoPasteboard start/stop and logs a single verbose diagnostic when a connected
Control session leaves sharing off; it does not send unsolicited clipboard data
to bypass that choice.

## Scope

This implements Apple's native text and image pasteboard exchange as an optional RFB
3.889 profile. The server continues to support standard RFB 3.3/3.7/3.8 clients.
Password authentication remains required when configured: security type 2 for
the clipboard profile, or Apple type 30 with `--file-transfer`.
None is advertised only when authentication has explicitly been disabled.

The profile supports UTF-8 text, newlines, empty pasteboards, PNG, TIFF and JPEG
representations, multiple image items, unsupported-flavor skipping, and deferred
promises. Image bytes are preserved without transcoding. Compressed and expanded
Apple archives are each limited to 100 MiB; classic text remains limited to 16 MiB.
Malformed sizes, counts and compressed streams are rejected. Rich text, Apple
account authentication, virtual displays and private framebuffer
codecs remain unsupported. The separate `--file-transfer` profile enables Finder
drag negotiation plus Apple's authentication and encrypted records;
see [Apple file transfers](apple-file-transfer.md).

## Wire exchange

- Advertise `RFB 003.889\n` when clipboard sharing is enabled.
- With Apple's dialect, the viewer implicitly accepts the single classic
  security type: it reads the VNC challenge without sending a selector byte.
  Standard 3.7/3.8 clients still send the selector. The native viewer opens a
  discovery connection, closes it to prompt for a password, then reconnects.
- A viewer selecting 3.889 and setting ClientInit bit `0x80` receives Apple's
  extended ServerInit. Its name field is `u16(0)`, `u32(0x12)`, a 16-byte
  supported-client-message bitmap (MSB first), then the UTF-8 name.
- The native viewer sends ClientInit `0xc1`. Its optional session-selection
  request (`0x40`) is declined by keeping server flag `0x04` clear.
- Accept AutoFrameBufferUpdate (`0x09`): version 1, a u32 interval in
  microseconds and a rectangle. Pushes respect the server's FPS limit and
  pause at interval `0xffffffff`; clipboard monitoring remains active.
- Accept ViewerInfo (`0x21`), SetMode (`0x0a`, observe/control), AutoPasteboard
  (`0x15`, start/stop), clipboard fetch (`0x0b`), and ClipboardSend (`0x1f`).
- When monitoring is enabled and the viewer supports the messages, emit
  MiscStatus (`0x14`) command 2 on a local change. Answer the subsequent fetch
  with ClipboardSend, echoing its request ID.
- Starting monitoring sends an initial notification. Repeating start while
  already monitoring does not announce a change or invalidate saved promises.
  A stop followed by start still sends an initial notification.
- A promises-only fetch returns the flavor with no data; the later full fetch
  retrieves the saved content. For incoming promised text or images, MiscStatus command 3
  requests the full contents before applying them to NSPasteboard.
- Each ClipboardSend has a 16-byte header and its own zlib stream, flushed with
  `Z_SYNC_FLUSH`. It never shares a compressor with framebuffer encoding.
- Archives contain a sequence of items, not an outer item count. Each item
  contains a u32 flavor count. Each flavor has a counted UTI, reserved u32,
  u32 tag count, counted key/value tags, and counted data. All counts are BE u32.
  Supported UTIs are `public.utf8-plain-text`, `public.png`, `public.tiff` and `public.jpeg`. An item with zero flavors
  clears the pasteboard; a text flavor with zero data promises future contents.
- A header with both archive sizes zero also clears the pasteboard. It contains
  no zlib stream. Zero compressed bytes with a nonzero expanded size remain an
  error; an empty payload is not an image promise.

Each connection has its own framebuffer writer, compressors, negotiated
capabilities and clipboard change cursor. Up to 32 connections can run on each
listening port; incomplete handshakes expire after 5 seconds. Standard RFB
exclusive ClientInit requests do not evict other viewers. Apple's SetMode still
supports control and observe only, not exclusive control.

Choosing Observe keeps the client's permission to resume control. MiscStatus 9
and 10 report control permission, not the selected mode. Like Apple's native
server, this server advertises permission in ServerInit and does not send either
status in response to SetMode. Repeated mode requests are idempotent; there is no
timed permission revoke/grant cycle or forced override of an Observe preference.

TCP keepalive probes start after 3 idle seconds, retry at one-second intervals,
and drop an unreachable peer after three unanswered probes (roughly 6 seconds,
subject to OS timer scheduling). Brief network outages may require reconnecting.
Unacknowledged TCP data has a 6-second retransmission limit, and writes that make no progress time
out after three seconds. These transport settings also apply to classic viewers.
Healthy idle viewers have no application inactivity deadline. Each started client
message normally has a total 5-second read deadline. Apple clipboard headers
retain that deadline; the body has a fixed allowance of 5 seconds plus one second
per MiB of compressed data. Partial progress does not extend this deadline.
Timeouts take the same session cleanup path as an ordinary disconnect.

All post-handshake writes go through that connection's framebuffer writer. It wakes
every 100 ms even without framebuffer requests, services queued clipboard
requests between complete frames, and suppresses notifications for remote
pasteboard writes to their originating connection. Other connected viewers can
receive those changes. Pasteboard access is serialized across the process, with
an independent change cursor per viewer and suppression of identical text/image echoes.
Disconnect cleanup waits for the connection's writer to stop, releases only its
owned controls, and removes only its capture-rate subscription.
Verbose clipboard logging records message types, sizes, request IDs, the socket
descriptor and a Unix timestamp in seconds. It distinguishes initial notifications
from local pasteboard changes, repeat start commands from state transitions, and
fetches served from a saved promise from reads of the current pasteboard. It never
records clipboard text or authentication credentials.

## Investigating a client screenshot being replaced

Incoming PNG/TIFF/JPEG promises now request their full contents using MiscStatus
command 3. Fetches arriving while those bytes are pending are deferred, so they
cannot reply with the old server clipboard. Clipboard application and fetch replies
share the writer queue. An explicit clear supersedes the pending image. A newer
server copy also supersedes the requested image response. Automatic responses use
request ID zero, so the protocol cannot unambiguously correlate several overlapping
client generations; the next new promise begins a new exchange.

Socket tests reproduced an unnecessary change notification on a repeated
`AutoPasteboard(start)`. That case is now suppressed. Whether Screen Sharing 3.0
on macOS 13.1 sends a repeated start, a stop/start pair, or a fetch when regaining
focus after a screenshot has not been established. A client pasteboard trace
showing the screenshot followed by old text does not distinguish those cases.

On 2026-10-09, the user supplied server logs immediately after taking a screenshot
on the macOS 13.1 client. They show an unsupported clipboard archive, followed by
`invalid Apple clipboard compressed archive size`, a disconnect and new handshake,
and then promised and full replies carrying 26 bytes of server text. Reconnection
provides a concrete path for the old server clipboard to replace the screenshot;
the trace does not require a focus-triggered repeat start to explain that replay.

In the decoder used for that trace, the header's earlier size checks mean this
error identifies a message with zero compressed bytes. The uncompressed size was
not logged. The known empty-pasteboard form (both sizes zero) was incorrectly
rejected; it is now accepted as a remote clear without disconnecting or echoing a
notification. A regression test sends an image promise, this empty header, and a
fetch on one socket, checking that the old promised text is invalidated and the
session continues. The reverse-engineered reference implementation linked below
also tests this empty-header form. The user subsequently confirmed that the
screenshot-copy behavior was fixed on Screen Sharing 3.0/macOS 13.1. That check
predates the new image-transfer implementation.

Reproduce with the rebuilt server and `--verbose --clipboard-sync`, then inspect
the clipboard events around the screenshot:

- `AutoPasteboard` with `state_changed=false` is a repeated command; it does not
  cause an initial notification. A real stop/start still can.
- `MiscStatus: pasteboard changed` records `initial` and `local_change` separately.
- `ClipboardSend received` followed by `no supported flavor` establishes
  that an unsupported archive reached the server; it was not applied.
- `ClipboardFetch received` followed by `ClipboardSend sent` identifies a viewer
  request and shows whether its reply used `saved-promise` or `current-pasteboard`.

Image-transfer logs record `images=true` and payload sizes without logging image
contents. Check a screenshot in both directions after rebuilding and reconnecting;
packet receipt alone does not prove that the viewer applied the image.

## Validation

Run `swift test`. With the installed Swift 6.4 command-line tools, a missing
TestingMacros plugin was resolved by supplying its installed directory:

```sh
swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
swift build -c release --build-system native
```

The tests include byte-layout fixtures, independent compression streams,
malformed and oversized archives, socket-level authenticated Apple setup,
bidirectional text and clearing, deferred requests, stopped monitoring,
capability gating, clipboard delivery without framebuffer requests, serialized
framebuffer/clipboard replies, generic RFB fallback, and rejection of an
authentication downgrade.

The suite includes repeated clipboard start commands, unsupported archives,
header-only empty pasteboards, image promise/full exchanges, named pasteboard image
round trips, multi-client image forwarding with classic clients present, a 17 MiB
image archive, deferred fetches, superseding clears/local copies, and rejection of
missing data for nonempty archives. Real loopback TCP tests run
two authenticated viewers on one listener with independent pixel formats and
zlib streams, Apple/Apple and Apple/classic clipboard forwarding, echo
suppression, observe-mode input cleanup, client limits, failed authentication,
handshake expiry, and server shutdown. Timeout tests verify the configured TCP
options, incomplete message expiry, total deadlines across fields, healthy idle
viewers across multiple keepalive probes, fragmented messages, input release,
and reuse of expired client slots.
A real silent network drop has not yet been tested. Input tests verify shared key/button
ownership, Apple/classic modifier aliases, and click-sequence separation.

On 2026-10-05, Screen Sharing **6.1 on macOS 26.6.2** connected to a loopback
probe using the production RFB session implementation, a synthetic framebuffer,
and an in-memory clipboard. The VNC password handshake succeeded, Use Shared
Clipboard was enabled, and the native viewer fetched both promised and full
archives. The server's `Apple clipboard probe ✓ 中文` text was pasted into a
client-side text field using the system Paste command. Copying
`Native client clipboard ✓` on the client then delivered a 27-byte UTF-8
ClipboardSend to the probe. The probe restored the original system pasteboard
after the test.

Protocol details were cross-checked against remotex's reverse-engineered
[Apple RFB notes](https://github.com/andrewtheguy/remotex/blob/e9b01fd10e2671c3696453b7d5be72c36c3ffdb8/docs/apple-vnc-889.md)
and [clipboard implementation](https://github.com/andrewtheguy/remotex/blob/e9b01fd10e2671c3696453b7d5be72c36c3ffdb8/src/vnc_apple_clipboard.rs).
Those reference measurements and the local native test concern macOS 26 and
are not an Apple protocol guarantee. Clipboard synchronization in both
directions was also confirmed by the user with Screen Sharing 3.0 on macOS 13.1.

## Mouse follow-up

The target client exposed two missing pieces in the original input/capture
implementation: Quartz mouse events had no click-count metadata, and
ScreenCaptureKit omitted the cursor without supplying a cursor image to the
viewer. Mouse button events now set `mouseEventClickState`, using
`NSEvent.doubleClickInterval`, a four-point movement tolerance, and a sequence
that resets after a drag, timeout, button change or disconnect. Matching releases
carry the same count. Apple 3.889's left/right/middle bits are translated to the
input bridge's standard RFB left/middle/right order.

ScreenCaptureKit now includes the actual cursor in its frames. The RFB writer
sends a zero-sized RichCursor or XCursor only if the viewer advertised it and the
capture source includes the cursor. That prevents duplicate client overlays and
preserves system cursor shapes without private cursor APIs. Pointer movement is
visible at the stream's frame rate. Tests verify AppKit's interpretation of a
double-click, timing/drag resets, button mapping, disconnect releases, and cursor
message framing/capability gating. These follow-up changes still need a check in
the user's live remote session after restarting the rebuilt server.

For the target client, verify an enabled Use Shared Clipboard menu, then paste
ASCII, Unicode and multiline text in both directions, test stop/start and
reconnection, and confirm that the server logs `clipboard=apple`,
`Apple AutoPasteboard: started`, and ClipboardSend activity. Packet receipt
alone does not prove that the client applied the pasteboard.
