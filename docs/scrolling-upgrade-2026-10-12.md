# ZRLE repair and scrolling improvements — 2026-10-12

**Follow-up Apple compatibility fix:** the later real-desktop ZRLE failure was
traced to Apple's three-byte compact pixels despite its declared depth 32.
The [Apple-specific fix](apple-zrle-compatibility-2026-10-12.md) now passes the
expanded native image, streaming and scaling checks. The measurements below
predate that format adjustment.

ZRLE now produces valid pixels across the full test corpus and encodes the
scrolling-text fixture in **3.78–3.89 ms**, compared with **27.40–28.39 ms** for
the old, invalid output. The capture/scheduling changes increased live local
Screen Sharing delivery from about **53 to 57 updates/s**. In Control mode,
median capture-ready-to-send delay fell from **14.8–15.0 to 6.3–6.7 ms**.
Delivering more changed pixels increased CPU and bandwidth; this is a freshness
and pacing improvement, not a claim that every workload uses less CPU.

## Implementation

### ZRLE

The old encoder could select an incomplete palette after palette overflow and
could emit palette-RLE runs without the required high-bit run marker. Both are
fixed by replacing its tile builder with an original MIT-licensed C encoder.
It uses fixed scratch arrays, one palette/run census, explicit cost comparisons,
and one output pass. It supports raw, solid, packed palettes (2–16 colors),
plain RLE, and palette RLE (2–127 colors), including partial edge tiles and
per-row bit padding. Tests cover 8/16/32-bit true-color, both endian orders and
compact pixels whose unused byte is at either end of the pixel.

TigerVNC and LibVNCServer's maintained implementations were inspected, but their
GPL encoder code was not copied into this MIT project. The compression backend
is the existing maintained **zlib-ng 2.3.3**, with optional macOS system zlib.
ZRLE now shares Zlib's stable-address, persistent compression streams,
transactional discard/commit logic, level changes and fixed-level controls.
This avoids resetting or corrupting the stream when an obsolete frame is dropped.

`--zlib-backend` and `--zlib-level` now apply to both codecs. `--encoding auto`
prefers Zlib when advertised, then corrected ZRLE, then Raw. TigerVNC can use
ZRLE even though its current implementation does not support encoding 6.
An explicit `--encoding zrle` is useful to compare bandwidth on document-like
content. It is not universally faster than Zlib.

### Capture and pacing

- Capture notifications wake the sender. Deadlines use a monotonic clock,
  preserve cadence and skip missed slots instead of sending a catch-up burst.
  Empty capture checks do not consume an FPS slot.
- ScreenCaptureKit callbacks hand buffers to a copy worker with one in-flight
  copy and at most one pending buffer. Newer pending work replaces obsolete
  work and invalidates its dirty hints. Queue depth remains 3.
- Known empty-dirty frames skip buffer readback, unless a previously skipped
  changed frame requires a complete refresh. Accepted images initialize their
  byte array by copying, without a preceding full-image zero-fill.
- Capture acceptance uses accumulated deadlines, so a 45 FPS target on a 60 Hz
  input accepts 45 frames rather than accidentally rounding down to 30.
- Resampling is cached by capture sequence, layout, dimensions, scale, rounding
  mode and composited cursor. Unknown sequences bypass the cache; sequence IDs
  survive capture recovery to prevent reuse of stale images.

These changes retain Apple's display-initialization, cursor and automatic-update
ordering. Existing client-rendered cursors remain the default where negotiated.
A buffer still needs CPU readback/copy; this is not a zero-copy capture pipeline.

### Request flow and scrolling reuse

Ordinary generic-client requests are consumed after a response; unchanged
incremental requests remain pending. Requests merge regions and preserve any
outstanding nonincremental refresh. This fixes the earlier accidental reuse of
an ordinary request as an indefinite streaming subscription.

Standard ContinuousUpdates and Fence are now implemented when advertised.
Continuous mode respects its requested region and can be disabled. With Fence,
at most three automatic updates await processing acknowledgements. Basic
BlockBefore/BlockAfter fences are supported, with an ordered writer and reader
barrier where required. SyncNext is not supported. A Fence acknowledgement is
not a physical-display presentation acknowledgement. Apple retains its separate
private automatic-update extension.

CopyRect is now used for negotiated incremental updates when a vertical
translation of up to 256 pixels can be verified. Samples propose an offset;
every reused pixel is checked against the last successfully delivered client
baseline. Copies are ordered to preserve overlapping sources, then changed
regions are repainted. Partial requests keep conservative coverage so pixels
that were never delivered cannot become copy sources. Full refreshes never use
CopyRect. Fractional motion, overlays and uncertain regions fall back to pixels.

The observed macOS 13 and Tahoe Apple profiles do not advertise CopyRect,
ContinuousUpdates or Fence. Those clients benefit from capture, caching, codec
and pacing improvements, but cannot be sent unadvertised encodings. See the
[client matrix](client-streaming-support-2026-10-11.md). RFB still exposes only
the visible framebuffer; these changes do not provide an offscreen document or
client-local scroll physics.

## Encoder comparison

Same fixtures and independent full-frame decoder as the
[pre-fix comparison](zrle-vs-zlib-2026-10-11.md): 1024×768 depth-32 BGRX,
twelve 1024×64 bands, four warmups and twenty measured frames per pass, two
passes in reverse codec order. Both codecs use zlib-ng level 2. Ranges below
are the two median encoder wall times, not percentile ranges. CPU time closely
tracked wall time. Payloads include compressed-length prefixes but exclude RFB
rectangle headers. Capture, diff, networking and client decode are excluded.

| Fixture | Zlib time | ZRLE time | Zlib bytes/frame | ZRLE bytes/frame |
| --- | ---: | ---: | ---: | ---: |
| Solid | 1.12–1.26 ms | 1.31 ms | 15,555 | 156 |
| Two-color | 2.63–2.90 ms | 2.13 ms | 120,306 | 4,067 |
| Palette runs | 3.15–3.34 ms | 1.62–1.76 ms | 174,887 | 2,476 |
| 32 colors | 1.28–1.35 ms | 3.34–3.45 ms | 25,620 | 12,470 |
| Scrolling text | 3.98–3.99 ms | 3.78–3.89 ms | 208,920 | 92,466 |

**Every pixel matched: ZRLE 240/240 frames; Zlib 240/240 frames.** The scrolling
text result is about 7.3× faster than the old ZRLE implementation and uses 56%
fewer bytes than current Zlib. The 32-color fixture demonstrates why ZRLE is
not an unconditional CPU win. The very small solid result comes from tile
coding rather than stronger DEFLATE levels.

## Live capture/sender comparison

The before version is the working source snapshot immediately before this
upgrade, including earlier uncommitted changes, rather than clean commit
`9fbeb86`. Both instrumented release versions ran on the same Tahoe virtual Mac
(1728×1118 display), using real ScreenCaptureKit, a disposable AppKit scrolling
window and a hidden native ScreenSharing.framework client on loopback. Zlib,
Actual Size, automatic FPS and the server's default plaintext policy were used.

Each mode used before/after/after/before order, with a 15-second measurement
window per run after connection warmup. All connections used a plain URL and
registered the app's normal encryption preference of 2. Control mode was
selected through the probe view after connecting, without changing saved client
preferences or adding URL parameters. This does not test initial-mode selection
in the full Screen Sharing application.

| Control-mode metric | Before | After |
| --- | ---: | ---: |
| Delivered captures/s | 56.9–57.1 | 57.2–57.6 |
| Sent pixel updates/s | 52.7–53.0 | 57.2–57.5 |
| Median send interval | 18.7–18.8 ms | 17.2 ms |
| p95 send interval | 22.9–23.2 ms | 20.5–20.7 ms |
| Median capture-ready → write-complete | 14.8–15.0 ms | 6.3–6.7 ms |
| p95 capture-ready → write-complete | 22.8–23.2 ms | 9.8–11.8 ms |
| Median capture lock/copy span | 1.11–1.13 ms | 0.85–0.86 ms |
| Server CPU, 100% = one logical core | 35.3–40.2% | 42.6–45.1% |
| Client CPU, same convention | 62.4–72.3% | 73.6–80.3% |
| RFB traffic | 12.7–12.9 MB/s | 14.9–15.0 MB/s |

Observe mode also improved: about 53.0 → 57.4–57.6 updates/s and p95 send
intervals of 22.7–23.2 → 20.1–20.3 ms. Its server CPU rose from 37.7–40.7% to
46.2–50.2%; client CPU was 67.6–70.6% before and 68.8–74.6% after. That mode
composites the cursor, removing capture-sequence identity, so capture-to-send
matching is omitted rather than inferred.

These are instrumented pipeline measurements. The newer sender delivers more
fresh changed content, explaining some of the CPU/bandwidth increase; the test
does not isolate a fixed-throughput CPU saving. It neither measures physical
presentation nor ranks remote clients. One after run still had a 74 ms capture
span and a 92 ms send interval outlier, consistent with scheduling/readback
stalls that pacing cannot eliminate. Capture itself remains near 57 FPS in this
VM. No iOS, unmodified remote macOS 13, TigerVNC or noVNC GUI was benchmarked.

## Validation and reproduction

The final release test run passed **208 tests in 11 suites**. The executable was
installed atomically at `.build/release/mac-vnc-server-dev` (the same destination
as `.build/out/Products/Release/mac-vnc-server-dev`) and its code signature and
help output were verified. Existing port 5902 PID 52581 was not restarted and
still needs a restart to use the new code.

The test suite covers all tile modes, 300 combinations of palette/run/format
and edge geometry, persistent streams, transaction rollback, capture cadence,
cache invalidation, and exact reconstruction of overlapping CopyRect moves
with changed overlays. Protocol peers test ordinary request consumption,
partial/full refresh behavior, continuous negotiation, three-frame Fence
backpressure, resume after acknowledgement and disable/barrier ordering.

The native plain-URL tests passed for Raw, Zlib and ZRLE, and for cursor streaming
with both basic and encrypted file-transfer profiles. They check initial and
changing pixels, Control/Observe transitions and scaling through the installed
Tahoe framework; they complement the full-pixel decoder rather than replacing it.

```sh
swift test --scratch-path .build/scrolling-upgrade/build -c release \
  -Xswiftc -plugin-path \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing

python3 scripts/pipeline-profile/compare-codecs.py .build/new-codec-comparison

xcrun clang -fobjc-arc -framework AppKit scripts/probe-native-screen-sharing.m \
  -o /tmp/mac-vnc-native-probe
MAC_VNC_NATIVE_PROBE=/tmp/mac-vnc-native-probe swift test \
  --scratch-path .build/scrolling-upgrade/build -c release --skip-build \
  --filter 'nativeScreenSharingDecodesEachSupportedEncoding|nativeScreenSharingStreamsWithClientCursor'
```

[Machine-readable measurements](measurements/scrolling-upgrade-2026-10-12.json)
retain per-run CPU and timing summaries and source-manifest digests. Detailed
local artifacts are under `.build/scrolling-upgrade/`: `before/`, `codecs-new/`,
`profile-before/`, `profile-after/`, `capture-{before,after}-{1,2}/`,
`capture-control-{before,after}-{1,2}/`, `native-tests.log`, and `final-tests.log`.
The capture driver and its disposable native client are retained there as
`run-capture-benchmark.py`, `run-capture-control-benchmark.py` and `capture-client.m`.
The instrumenter in `scripts/pipeline-profile/` supports both source layouts.
