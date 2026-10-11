# Apple ZRLE compact-pixel compatibility — 2026-10-12

Screen Sharing requests 32 bits per pixel and depth 32, with RGB channel maxima
of 255 and shifts 16/8/0. Its actual colors occupy 24 bits. The server followed
the declared depth and emitted four-byte ZRLE compact pixels, while Apple's
viewer consumed three-byte BGR pixels. Subsequent bytes could become colors,
palette indices or tile headers at the wrong offset. This explains the blocky
colors reported on Screen Sharing 3.0 and the Tahoe decoder's earlier
`Unknown ZRLE tile subencoding` disconnects.

A disposable server that compacted this format to three bytes connected and
streamed the real desktop successfully. The production fix is deliberately
limited to Apple clients with the observed little-endian 32-bit BGRX format.
`PixelFormat.zrleFormat(forAppleClient:)` creates a depth-24 encoding view for
ZRLE; it does not change the negotiated pixel format. Raw, Zlib and cursor
encoding retain their original byte layout. Non-Apple clients retain the RFC
compact-pixel rules, including four bytes for depth 32. The user's working
RealVNC iOS path is therefore preserved.

`RFBServer.prepareFramebufferUpdate` snapshots this encoding format with the
client capabilities, uses it for both direct and transactional ZRLE encoding,
and counts the correct compact-pixel size in its verbose statistics. The
`auto` encoding preference remains Zlib, then ZRLE, then Raw.

## Regression coverage

The earlier native probe sampled one pixel inside a solid animated patch. That
could pass even while other tiles were decoded incorrectly. The encoding probe
now includes mixed tiles with 1/2/3/5/16/17/32/127/128/4096 colors, short and long
runs, raw tiles and partial edge tiles. It reads the native decoded image and
checks every pixel outside the small animated/cursor patch (1,927,808 pixels),
with a three-level RGB tolerance for the image conversion. The patch separately
checks ongoing animation; cursor, mode switching and scaling checks remain.

The detailed pre-fix run showed zero image mismatches for Raw and Zlib, while
ZRLE failed to produce the expected image and disconnected. The expanded test
also exposed a probe-only sampling bug at half scale; the animation sample was
moved farther inside the patch so it remains inside the patch when scaled.

After the fix, all three native codec cases (Raw, Zlib and ZRLE) passed with
zero detailed-image mismatches, continuing animation, Control/Observe changes,
RichCursor, and scaling through 0.5, 0.75 and back to 1.0. The separate real
ScreenCaptureKit desktop probe also connected and streamed with compact pixels.

The full release suite passed **210 tests in 11 suites**. Protocol tests verify
the bytes sent to Apple and ordinary RFB clients at the
same declared depth, and unit tests keep the compatibility rule from affecting
other pixel layouts. The existing independent 300-combination ZRLE corpus still
uses standard non-Apple format semantics.

All native connections use plain VNC URLs and the normal client encryption
preference. These local checks use Tahoe's installed ScreenSharing.framework;
the unmodified Screen Sharing 3.0 application on the remote macOS 13 client is
not executed by this test harness.

Artifacts: `.build/apple-zrle-2026-10-12/native-before.log`, `native-after.log`,
`compact-pixel-probe-2.log` and the final release verification record. The
[earlier CPU comparison](zrle-vs-zlib-current-2026-10-12.md) records failures before
this compatibility fix; its depth-32 generic encoder measurements remain valid,
but are not a measurement of Apple's newly compacted wire format.

The verified executable was installed atomically at
`.build/release/mac-vnc-server-dev`; the [verification record](measurements/apple-zrle-compatibility-2026-10-12.json)
contains its hash and test results. Existing server processes were not restarted.
