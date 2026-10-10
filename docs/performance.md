# Streaming performance

Screen Sharing's negotiated format is usually 32-bit little-endian BGRX with
8-bit red, green and blue components, but a declared depth of 32. The original
fast path compared the whole format against the server's depth-24 default. That
forced Screen Sharing through a per-pixel conversion loop despite identical
color packing. The fast path now matches the byte layout, handles padded source
rows, and clears the unused alpha byte for both depths. RGB565, big-endian and
other color layouts retain the general converter.

Single-display snapshots also retain their original row stride instead of
allocating and copying another full desktop when ScreenCaptureKit pads rows.
Compression statistics now count four raw bytes per BGRX pixel for Raw/Zlib;
the three-byte compact-pixel count is specific to ZRLE.

## Cursor

`--cursor auto` is the default. A shared AppKit sampler reads `NSCursor.currentSystem`
approximately 30 times per second. Capture omits the cursor and controlling
RichCursor viewers receive the actual shape, transparency mask and hotspot.
Only shape changes, format/scale changes, or renewed encoding negotiation send
a cursor rectangle. Moving the client's pointer does not require a framebuffer
update, so its movement no longer waits for capture, compression and the network.

Cursor updates are included with a requested framebuffer update. They never
arrive unsolicited during startup. This preserves the ready-before-finished
ordering required by Screen Sharing 3.0. A shape change can be sent even when
the captured desktop's sequence has not changed.

Apple Observe sessions and viewers without RichCursor get a cursor composited
at the host's actual pointer position, with alpha blending, clipping and display
scaling. This also invalidates the capture-only diff baseline so old cursor
pixels are erased. Controlling viewers with local cursors do not follow another
user's pointer movements. Use `--cursor embedded` when that behavior is needed.

AppKit's system cursor API is marked for future deprecation in the current SDK.
If sampling is unavailable at startup, capture retains the embedded cursor.
`--cursor embedded` also provides an explicit compatibility fallback. Standard
RichCursor has a one-bit transparency mask, so its edges may differ slightly
from the original cursor's antialiasing.

## Encryption

Without `--file-transfer`, desktop pixels, input and clipboard traffic already
use plaintext RFB. Password challenge/response authentication is retained.
`--no-encryption` makes plaintext session traffic an explicit policy. Combined
with `--file-transfer`, it enables an experimental server-side compatibility path
that uses a plain URL with the client's normal encryption setting.

Finder drag and drop uses Screen Sharing's native profile. The client checks
for SetEncryption before enabling that UI. That capability bit does not itself
enable encryption: the client separately decides whether to request it.
File-copy messages can run over plaintext RFB, but this does not establish
plaintext interoperability with Screen Sharing's app defaults.

The native capability bit remains advertised with `--no-encryption`. Valid
key-exchange requests are fully consumed but receive no encoding-1103 key reply.
The client continues in plaintext until keys arrive, so this avoids enabling
the record ciphers. Encrypted input and attempts to enable encrypted records
are still refused under this policy.
The server uses classic VNC password authentication (type 2) and omits the
encrypted-input capability. Keeping type 30 would cause Screen Sharing to
encrypt keystrokes without record encryption, regardless of that capability bit.
Authentication still uses a cryptographic challenge/response; "no encryption"
refers to session traffic, not eliminating authentication cryptography.
This does not change or satisfy the client's encryption preference. It deliberately
suppresses its key exchange, relying on undocumented client behavior, and is
enabled only by the explicit server option. The default continues to negotiate
encryption normally.

The copied Screen Sharing 3.0 app registers `encryptionLevel=2` by default.
The bare Tahoe framework's default is 0; a successful plain-URL framework probe
therefore does not prove that the macOS 13 app accepts that same connection.
All native tests now use plain URLs and register the app's default of 2, without
an encryption override. With native capabilities present, the client requests
encryption even after type 2 authentication. Refusing it disconnects before the
first frame, but consuming the request without sending keys allows plaintext
streaming, input, scaling and both file-drop directions to remain available.
The native plaintext probe exercises 20 seconds of changing frames before input
and scaling. Basic VNC remains plaintext but has no Finder drops.
Earlier helper tests verified plaintext file payloads; they did not prove this
app-default workflow. Actual Finder gestures on macOS 13 remain unverified. See
[the protocol evidence and reproduction steps](apple-file-transfer.md#plaintext-validation).

Encryption runs on the compressed payload, not the full BGRA desktop. In the
synthetic benchmark below, encrypting one compressed frame took about 0.27 ms,
compared with 41 ms spent packing and compressing that frame before the fix.

## Scrolling

RFB exposes the visible framebuffer; it does not expose an application's document,
offscreen scroll surface, or local scroll physics to the viewer. The server
cannot send a whole offscreen document for Screen Sharing to scroll locally.

The existing dirty-tile scan merges adjacent changes, including a large visible
scroll region. All rectangles for one captured frame are sent in one update.
The faster BGRX path reduces the cost of these large updates. The sender consumes
the latest capture rather than accumulating a queue of every intermediate frame.

CopyRect could reuse pixels already in a generic VNC viewer's framebuffer, but
the user's Screen Sharing 3.0 trace does not advertise encoding 1. Sending it
without negotiation would break that client. The server does not send CopyRect.
Frame rate and smoothness still depend on screen content, network throughput,
client decoding, resolution and capture rate.

## Reproducing measurements

The opt-in benchmark uses eight synthetic 1728×1118 document-like frames shifted
vertically, with 8 warm-up iterations and 32 measured iterations. It measures
packing, persistent level-1 Zlib, and Apple record encryption separately. It
does not capture the desktop or include network/client rendering latency.

On the Tahoe ARM64 host, comparing the pre-change `c00e105` code with this
working tree in release mode gave these median times:

| Operation | Before | After |
| --- | ---: | ---: |
| Pack Screen Sharing depth-32 pixels | 29.71 ms | 0.98 ms |
| Pack + Zlib, depth 32 | 41.35 ms | 12.46 ms |
| Encrypt one compressed frame | 0.27 ms | 0.28 ms |

Both versions produced 192,275 bytes per frame on average for the Zlib sequence.
This is about 3.3× faster packing plus compression with no payload-size change.
It is not an end-to-end frame-rate guarantee; timings vary with content and load.

```sh
MAC_VNC_BENCHMARK=1 swift test -c release \
  -Xswiftc -plugin-path \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing \
  --filter framebufferBenchmark
```

Native interoperability checks use a hidden Tahoe Screen Sharing view with
synthetic pixels, mock input and a private pasteboard. The client-cursor cases
verify that the native decoder receives a nonempty cursor, startup restores
Control before completion, streaming continues, Observe/Control switches work,
and the file-transfer profile still handles all-traffic encryption and scaling.
They do not replace a live test with Screen Sharing 3.0 on macOS 13.

```sh
xcrun clang -fobjc-arc -framework AppKit scripts/probe-native-screen-sharing.m \
  -o /tmp/mac-vnc-performance-native-probe
MAC_VNC_NATIVE_PROBE=/tmp/mac-vnc-performance-native-probe swift test \
  -Xswiftc -plugin-path \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing \
  --filter nativeScreenSharingStreamsWithClientCursor
```
