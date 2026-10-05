# Apple Screen Sharing text clipboard

Enable with the existing `--clipboard-sync` option. Reconnect after switching
binaries: the Apple capabilities are negotiated at connection startup. On the
viewer, select Edit → Use Shared Clipboard.

## Scope

This implements Apple's native text pasteboard exchange as an optional RFB
3.889 profile. The server continues to support standard RFB 3.3/3.7/3.8 clients.
Password authentication (security type 2) remains required when configured;
None is advertised only when authentication has explicitly been disabled.

The profile supports UTF-8 text, newlines, empty pasteboards, multiple-item
incoming archives, unsupported-flavor skipping, and deferred text promises.
It does not advertise Apple account authentication (type 30), encrypted records,
virtual displays, private framebuffer codecs, or file transfer. Rich text and
images are not preserved. Compressed and expanded clipboard archives are each
limited to 16 MiB; malformed sizes, counts and compressed streams are rejected.

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
- A promises-only fetch returns the flavor with no data; the later full fetch
  retrieves the saved text. For incoming promised text, MiscStatus command 3
  requests the full contents before applying them to NSPasteboard.
- Each ClipboardSend has a 16-byte header and its own zlib stream, flushed with
  `Z_SYNC_FLUSH`. It never shares a compressor with framebuffer encoding.
- Archives contain a sequence of items, not an outer item count. Each item
  contains a u32 flavor count. Each flavor has a counted UTI, reserved u32,
  u32 tag count, counted key/value tags, and counted data. All counts are BE u32.
  The text UTI is `public.utf8-plain-text` (22 bytes). An item with zero flavors
  clears the pasteboard; a text flavor with zero data promises future contents.

All post-handshake writes go through the existing framebuffer writer. It wakes
every 100 ms even without framebuffer requests, services queued clipboard
requests between complete frames, and suppresses notifications for remote
pasteboard writes. Verbose logging records message types, sizes and request IDs,
but never the clipboard text or authentication credentials.

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
