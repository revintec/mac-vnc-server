# Apple Screen Sharing file transfers

`--file-transfer` enables file/folder drag and drop using an experimental
plaintext Apple compatibility profile. The file option independently selects
Apple RFB 3.889; classic VNC viewers continue to work without file transfer.
`--clipboard-sync` separately enables text and image clipboard sharing.

## Connecting

Restart the updated server with `--file-transfer`, disconnect any existing
Screen Sharing connection, and open this URL on the client:

```sh
open -a "Screen Sharing" 'vnc://SERVER_IP:5900/?encrypt=none'
```

Replace the address and port. In control mode, drag local Finder items into
remote Finder/the remote desktop, or remote Finder items out into local Finder.
Shared Clipboard is a separate feature and is not required for file transfer.
Files are copied; the originals are retained. The session remains unencrypted
after VNC password authentication. Requests to enable Apple record encryption
are rejected with an actionable log, never silently treated as plaintext.

Screen Sharing 3.0 on macOS 13.1 has also been reported to fail intermittently
with "viewer and server are incompatible" when retrying the same `encrypt=none`
URL, then succeed on a later attempt. In the captured failure, VNC authentication
completed and the viewer sent `SetEncryption` after `ViewerInfo`. That request
is unsupported by this plaintext profile. The reason the viewer requests it
despite the URL option has not been confirmed; quitting Screen Sharing and
opening the full URL in a fresh process is a troubleshooting step, not a verified
fix. Logs include the encryption command, level/methods or enable flag so that
different attempts can be compared. Command 1 at level 0 still requests keys;
only command 2 with an enable flag of 0 is accepted as a plaintext no-op.

Another captured failure with the same client ended with `unsupported client
message 8`, sometimes after streaming frames. This is `SetServerScaling`, not an
authentication or encryption failure. The server now consumes its ten-byte
request (type, padding, big-endian double) and handles finite factors in `(0, 1]`.
It sends DisplayInfo with the new pixel dimensions before the scaled image,
including when the viewer has not requested a frame. Logical desktop dimensions
and pointer coordinates remain unscaled, and each connection has its own scale.
The native viewer can send this message without checking its capability bit.

A connection that starts in Observe but can switch to Control is not locked out.
The viewer selects its initial mode; `&control=1` can be appended to the URL to
request Control on connection. Voluntary Observe requests remain respected.

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
  for encrypted records. The `encrypt=none` URL option suppresses that request.

The opt-in file-transfer profile advertises `0x12` to enter the native UI path
but implements only plaintext operation. This is an intentional compatibility
workaround, not an implementation of Apple's encryption protocol. The server
also sends DisplayInfo (encoding 1101) when SetEncodings requests it; without
this metadata the client waits for its native display configuration. One logical
screen describes the framebuffer selected by the listening port. A resize sends
updated display metadata too.

An unshown Tahoe Screen Sharing view connected to the test server verifies that
this combination registers file URLs, filenames and file promises as drag types,
and enables both transfer directions after repeated observe/control transitions.
The probe checks that Control remains available when connecting in observation
mode, with file transfer enabled and disabled. It also exercises scaling and
restoring a 1728×1118 synthetic desktop and checks the native decoder's dimensions.
The macOS 13.1 client itself has not been
inspected, so actual Finder gestures there remain a manual interoperability test.

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
with `?encrypt=none`:

1. Drag a small file from local Finder into the remote desktop; compare contents.
2. Drag a remote Finder file out of the Screen Sharing window into local Finder.
3. Repeat with multiple files, a nested folder and an existing destination name.
4. Cancel a large transfer, disconnect during it, and toggle observe/control mode.
5. Copy a screenshot in each direction with Use Shared Clipboard enabled.

Helper presence is checked at runtime. New macOS releases can change these private
interfaces; failures are logged and this implementation has not been validated on
other server OS versions or with non-Finder drag sources such as promised downloads.
