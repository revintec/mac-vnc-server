# ZRLE versus Zlib in this server — 2026-10-11

**Historical result:** the defects below were fixed on 2026-10-12. See the
[replacement encoder and new measurements](scrolling-upgrade-2026-10-12.md).
The rest of this report describes the pre-fix implementation.

Use **Zlib** with the current server. Its default zlib-ng implementation encoded
the synthetic scrolling-text frames in **3.73–3.99 ms**, while current ZRLE took
**27.40–28.39 ms** and failed full pixel validation. ZRLE has two reproducible
palette bugs; its smaller output for that workload is not a valid compression
win. No production codec or default was changed during this comparison.

## What each encoding does

| Property | Zlib, encoding 6 | ZRLE, encoding 16 |
| --- | --- | --- |
| Pipeline | Pack pixel bytes, then DEFLATE | Split into 64×64 tiles; choose raw, solid, packed palette, or runs; then DEFLATE |
| Image quality by design | Lossless | Lossless; the current implementation has correctness defects described below |
| Compressor here | zlib-ng by default; optional system zlib | System zlib |
| Fast level here | zlib-ng 2, system 1 | 1 |
| Desktop bandwidth | Repeated bytes compress well | Palettes and runs can greatly reduce bytes before compression |
| CPU here | Optimized BGRX copying and zlib-ng | Per-pixel palette lookup, temporary arrays and multiple tile candidates add substantial work |
| Stream state | Persistent across rectangles | Persistent across rectangles |
| Screen Sharing 3.0 | Advertises support | Advertises support; negotiation alone does not prove pixel correctness |
| Current TigerVNC | Does not implement encoding 6 | Supports ZRLE |
| Current noVNC | Supports Zlib | Supports ZRLE |

Both operate on the dirty rectangles selected by the server. Neither is
CopyRect, neither knows the document outside the visible screen, and neither
provides local scrolling physics. `--encoding auto` currently prefers Zlib for
Apple viewers and ZRLE for generic viewers that advertise it. Until the ZRLE
defects are fixed, that generic-client preference can also expose the bugs.
`--zlib-backend` and `--zlib-level` affect encoding 6 only.

## Controlled encoder comparison

The test used a release build on macOS 26.6.2 / VirtualMac2,1, with eight logical
CPUs and 24 GiB RAM. Both codecs received exactly the same generated source
frames: 1024×768 BGRX, depth 32, divided into twelve 1024×64 rectangles. Four
fixture frames were repeated through a persistent stream, with four warmups and
twenty measured frames in each pass. Codec order was reversed for the second
pass. Zlib used zlib-ng level 2; ZRLE used system zlib level 1.

The table gives the range of the two median encoding times and mean payload
sizes. Encoding includes pixel packing or tile construction, compression and
payload allocation. Capture, dirty detection, disk IO, networking and client
decoding are excluded. Thread CPU closely matched wall time in these runs.
Payload sizes include four-byte compressed-length prefixes, excluding RFB
rectangle headers.

| Source content | Zlib median time | ZRLE median time | Zlib kB/frame | ZRLE kB/frame | Exact pixel validation |
| --- | ---: | ---: | ---: | ---: | --- |
| Solid color | 1.10–1.16 ms | 12.20–12.60 ms | 15.56 | 0.156 | Both pass |
| Two-color pattern | 2.70–2.78 ms | 20.46–20.95 ms | 120.31 | 3.21 | Both pass |
| Four-color runs | 3.14–3.30 ms | 20.69–20.72 ms | 174.89 | 2.35* | ZRLE malformed |
| 32-color pattern | 1.21–1.37 ms | 37.36–37.74 ms | 25.62 | 7.72* | ZRLE loses colors |
| Antialiased scrolling text | 3.73–3.99 ms | 27.40–28.39 ms | 208.92 | 42.77* | ZRLE malformed / incorrect |

`*` Invalid output: these sizes must not be used as compression-ratio wins.
Zlib passed **240/240 complete frames**. ZRLE passed **96/240**, covering the
solid and two-color cases; all 144 frames in the other three cases failed.

The valid two-color case illustrates the intended tradeoff: ZRLE used about
**37.5× fewer bytes**, but about **7.5× more encoding time** in this implementation.
Using the midpoint medians, the 117 kB saving offsets the extra 18 ms of encoding
at about **6.5 MB/s (52 Mbit/s)** in a simple serial encode-plus-transmit model.
This is an illustration for that fixture, not a measured network crossover:
client decoding, queueing, pipelining and real content can change the result.
The current ZRLE document path is not suitable for a valid live-client latency
comparison until correctness is repaired.

## Confirmed correctness defects

1. **Palette overflow loses colors.** `ZRLEEncoding.swift` caps its palette at
   16 entries but still permits packed-palette encoding when later pixels contain
   additional colors. Missing palette entries become index zero. In a 32-color
   fixture, 32,768 of the 65,536 pixels in the first rectangle changed color
   after decoding. The palette candidates must be rejected unless they cover
   every pixel in the tile.
2. **Palette runs omit the high-bit marker.** The encoder writes an ordinary
   palette index followed by a length for every run. RFC 6143 requires the top
   bit to be set for a multi-pixel run; a single pixel has no length byte. A
   compliant decoder consequently interprets length bytes as new palette
   indices. The four-color fixture failed with index 9 in a four-entry palette.

The independent decoder implements the RFC's tile rules and was checked against
raw, solid, packed-palette, plain-RLE and palette-RLE reference vectors. The
palette-run rule was also cross-checked against noVNC's decoder. Existing server
tests inspect some inflated headers and small examples; the earlier native
probe checks selected pixels and negotiation. Those checks did not establish
full pixel preservation for arbitrary tiles.

## Practical choice

- **Screen Sharing on a fast LAN/VPN:** retain `--encoding zlib` or `auto`.
  Both formats are advertised, but Zlib is substantially cheaper in the current
  implementation and passed the full-image checks.
- **Bandwidth-limited desktop use:** a corrected, optimized ZRLE encoder is
  worth investigating. Its solid/palette reductions are useful, but the current
  implementation needs correctness fixes before realistic bandwidth testing.
- **TigerVNC:** encoding 6 is not supported by current upstream TigerVNC. An
  explicit `--encoding zlib` therefore falls back to Raw in this server; it does
  not magically give TigerVNC Zlib. Fixing ZRLE matters for this client.

The [live Zlib benchmark](pipeline-profile-current-2026-10-11.md) measured about
53 updates/s, 40–41% of a core on the server, 49–50% on the adapted Screen
Sharing client, and about 19 ms median / 28 ms p95 from copied-frame readiness
to client framebuffer update. This comparison does **not** supply equivalent
live-client CPU or latency numbers for ZRLE. Encoder timings must not be
presented as end-to-end latency or used to infer actual delivered FPS.

## Reproduction and evidence

```sh
python3 scripts/pipeline-profile/compare-codecs.py /tmp/mac-vnc-codec-comparison
```

The output directory must be new. The script builds a disposable source copy,
runs without opening a listener or UI, and uses an independent Python decoder
to compare every pixel. The original checkout and running server remain intact.
Local fixture bytes and compressed streams from this run are retained in
`.build/codec-comparison/results`; they contain only generated graphics/text.
[Measurements, samples and source hashes](measurements/zrle-vs-zlib-2026-10-11.json)
are included alongside this report.

- [RFC 6143 §7.7.5–7.7.6](https://www.rfc-editor.org/rfc/rfc6143.html#section-7.7.5): palette/run rules and ZRLE tiles.
- [noVNC ZRLE decoder](https://github.com/novnc/noVNC/blob/master/core/decoders/zrle.js): palette-run marker interpretation, inspected 2026-10-11.
- [Client encoding compatibility](encoding-compatibility.md): negotiated support and fallback behavior.
