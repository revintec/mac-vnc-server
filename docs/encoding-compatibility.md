# Encoding compatibility and scrolling

Updated on 2026-10-12. The server implements Raw (0), Zlib (6), and ZRLE
(16). These are framebuffer encodings, independent of clipboard formats, file
transfer and session encryption. zlib-ng is a server compressor implementation;
it produces the same Zlib encoding understood by existing clients.

See the [client streaming support matrix](client-streaming-support-2026-10-11.md)
for CopyRect, update flow control, frame pacing and capture delivery across
Apple, RealVNC iOS, TigerVNC, noVNC, UltraVNC, Remmina and Guacamole.

## Current selection and compatibility

**Apple Screen Sharing:** its depth-32 BGRX format needs three-byte ZRLE compact
pixels. That compatibility exception is now implemented only for Apple clients;
other clients retain standard depth handling. Detailed native image, streaming
and scaling checks pass. See the [fix and validation](apple-zrle-compatibility-2026-10-12.md).

| Option | Behavior | Compatibility and tradeoff |
| --- | --- | --- |
| `auto` | Prefer Zlib, then ZRLE, then Raw for every viewer. | Uses negotiated capabilities; keeps Zlib as the default for compatible viewers. |
| `zlib` | Encoding 6 if advertised, otherwise Raw. | Apple Screen Sharing and current noVNC advertise it. Current TigerVNC does not implement encoding 6, despite using zlib internally for other codecs. |
| `zrle` | Encoding 16 if advertised, otherwise Raw. | Apple Screen Sharing, TigerVNC and current noVNC support it. Tile/palette/run-length coding can help desktop content; performance depends on content. Uses zlib-ng by default, with a system-zlib fallback. |
| `raw` | Encoding 0. | RFC 6143 permits Raw even when omitted from SetEncodings. Minimal compression work but very high bandwidth for scrolling/full frames. |

Explicit `zlib` or `zrle` is a preference, not a requirement: an unsupported
choice falls directly back to Raw, not the other compressed encoding. The
verbose `updates=... encoding=...` line shows the encoding actually sent.
`--zlib-backend` and `--zlib-level` affect both Zlib and ZRLE.

The two palette defects found in the [original comparison](zrle-vs-zlib-2026-10-11.md)
are fixed. The replacement C tile encoder passed full-pixel validation on all
240 benchmark frames and a broader corpus of formats and edge tiles. ZRLE is
useful for TigerVNC compatibility and bandwidth-sensitive desktop content;
which codec is faster depends on the image. See the
[repair and measurements](scrolling-upgrade-2026-10-12.md).

The supplied Screen Sharing 3.0/macOS 13 trace advertises
`[6,16,-239,1104,1100,-223,1101,1105,1107,1109]`. IDs such as 1105 are display
metadata extensions, not general alternatives to Zlib/ZRLE pixel encoding.
A fresh native Tahoe framework probe successfully decoded each of Raw, Zlib
and ZRLE over a plain URL, with the app's normal encryption preference and the
server's plaintext policy. It checked initial/changing pixels, cursor,
Observe/Control transitions and scaling. This tests the host framework, not a
new remote macOS 13 session. The expanded native probe checks the detailed image outside its animated patch,
with separate checks for animation, cursor and scaling. It is complemented by
independent full-frame decoder tests. Latest native codec log:
`.build/apple-zrle-2026-10-12/native-after.log`.

## CopyRect

CopyRect (encoding 1) tells the client to copy pixels already in its framebuffer.
Its payload is just a source X/Y pair; the normal rectangle header identifies
the destination and size. A vertical scroll can reuse the unchanged area and
send only newly exposed strips. It cannot provide the rest of an offscreen
document, and it does not implement local scrolling physics.

| Client | Evidence for CopyRect |
| --- | --- |
| Screen Sharing 3.0 on macOS 13 | Not advertised in the supplied traces. Do not send it in these sessions. |
| Tahoe ScreenSharing.framework | Not advertised in the fresh native-profile probes. Decoder capability cannot be inferred from unadvertised private code. |
| TigerVNC, current source | Explicit decoder support for encoding 1. |
| noVNC, current source | Explicit decoder and encoding-1 advertisement. |

The server now detects vertical translations up to 256 pixels against the
client's last delivered framebuffer. It verifies every reused pixel, orders
copies to preserve overlapping sources, and then repaints uncovered/changed
areas. Only negotiated incremental updates use CopyRect. Full refreshes and
unverified regions use pixel encoding. Partial updates retain a conservative
coverage map so unseen pixels are never used as sources.

## Ways to improve scrolling

1. Capture arrivals now wake the sender; monotonic deadlines avoid drift and
   skip missed slots. A dedicated copy worker replaces pending stale buffers
   instead of accumulating capture callbacks. Empty-dirty frames avoid readback.
2. Generic requests are consumed after a response. Negotiated ContinuousUpdates
   removes the per-update request; Fence bounds automatic frames to three in
   flight when advertised. Apple retains its separate automatic-update path.
3. Scaled snapshots are cached by capture sequence, layout, scale and cursor,
   avoiding resampling unchanged images. Actual Size still avoids scaling cost
   when frames change.
4. CopyRect reduces pixel encoding for eligible viewers. ZRLE can also reduce
   bandwidth for document-like content. Resolution, network capacity and client
   rendering still determine whether an improvement is visible. See the
   [current benchmark and limits](scrolling-upgrade-2026-10-12.md).
5. Video/Tight/JPEG paths are alternatives for clients that advertise them, with
   implementation effort and possible image-quality tradeoffs. This server does
   not implement those encodings, and the supplied Apple trace does not offer
   them. A standard encoding cannot be forced onto an unwilling client.
6. Offscreen prefetch or predictive local scrolling requires a custom client and
   knowledge of application content. Generic RFB capture plus an unmodified
   Screen Sharing client does not expose either facility.

## Sources

- [RFC 6143, SetEncodings](https://www.rfc-editor.org/rfc/rfc6143.html#section-7.5.2): allowed encodings and unconditional Raw fallback.
- [RFC 6143, CopyRect](https://www.rfc-editor.org/rfc/rfc6143.html#section-7.7.2): wire layout, use for scrolling, source ordering.
- [RFC 6143, FramebufferUpdateRequest](https://www.rfc-editor.org/rfc/rfc6143.html#section-7.5.3): nonincremental refresh semantics.
- [TigerVNC decoder implementation](https://github.com/TigerVNC/tigervnc/blob/master/common/rfb/Decoder.cxx): supported/createDecoder switch, inspected 2026-10-11.
- [noVNC RFB implementation](https://github.com/novnc/noVNC/blob/master/core/rfb.js): decoder registration and `_sendEncodings`, inspected 2026-10-11.
- Local `RFBServer.swift`, `selectedEncodingLocked`, plus supplied client traces and `.build/native-encoding-tests.log`.
