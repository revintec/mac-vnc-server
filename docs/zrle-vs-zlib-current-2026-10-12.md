# Current ZRLE versus Zlib: CPU, latency and native compatibility

The repaired ZRLE encoder is competitive on CPU and substantially smaller on
several desktop fixtures. The live decoding failures recorded below were fixed
later on 2026-10-12 by matching Apple's three-byte compact-pixel convention for
its declared depth-32 BGRX format. See the
[compatibility fix and expanded native checks](apple-zrle-compatibility-2026-10-12.md).
The historical failure measurements are retained; this report does not remeasure
the new Apple-specific wire format.

## Implementation comparison

Both codecs use zlib-ng 2.3.3 by default and share the persistent DEFLATE stream,
transaction handling, adaptive levels 2/3, and fixed `--zlib-level` control.
Neither adds a separate frame queue. Capture delivery, scheduling, scaling,
request flow and negotiated CopyRect are shared server mechanisms.

Zlib packs the requested pixel format and compresses those bytes. Its BGRX fast
path avoids per-pixel color conversion. ZRLE first examines 64×64 tiles and
chooses raw, solid, packed-palette, plain-run or palette-run coding, then
compresses that representation. The extra tile work can cost CPU, but can also
remove enough data to reduce total encoding work and network traffic.

## Encoder CPU and latency

These are the current encoder measurements from the validated corpus: 1024×768
BGRX, depth 32, twelve 1024×64 bands, persistent streams, both codecs at zlib-ng
level 2. Two passes reverse codec order, each with four warmup and twenty timed
frames. The fixed-level encoding code matches the current release; the only
subsequent change to the ZRLE wrapper forwards adaptive compression decisions.

CPU values are the range of two median thread-CPU measurements, not total
server CPU percentages. Output sizes are mean compressed payload bytes,
including length prefixes and excluding RFB headers. Decimal kB are used.

| Fixture | Zlib CPU/frame | ZRLE CPU/frame | Zlib payload | ZRLE payload |
| --- | ---: | ---: | ---: | ---: |
| Solid | 1.12–1.26 ms | 1.31 ms | 15.56 kB | 0.156 kB |
| Two-color | 2.63–2.80 ms | 2.13 ms | 120.31 kB | 4.07 kB |
| Palette runs | 3.15–3.32 ms | 1.62–1.75 ms | 174.89 kB | 2.48 kB |
| 32-color pattern | 1.28–1.35 ms | 3.34–3.45 ms | 25.62 kB | 12.47 kB |
| Scrolling text | 3.98–3.99 ms | 3.77–3.89 ms | 208.92 kB | 92.47 kB |

Wall time closely follows CPU time. On scrolling text, median encode latency
is **3.98–3.99 ms for Zlib versus 3.78–3.89 ms for ZRLE**; p95 is
**4.77–5.03 ms versus 4.33–4.63 ms**. Both passed 240/240 full-pixel frame checks.
These are encode-stage results, excluding capture, dirty detection, network,
client decoding and display presentation.

For that text fixture, ZRLE's main gain is 56% fewer bytes, with a small encoding
CPU gain. On palette runs it roughly halves encoding CPU and greatly reduces
output. On the 32-color fixture, Zlib uses about 60% less encoding CPU.
Photo/video workloads were not included, so this corpus cannot rank them.

For perspective, at an effective 100 Mbit/s the text payload alone takes about
16.7 ms to serialize with Zlib and 7.4 ms with ZRLE. At 1 Gbit/s those estimates
are 1.67 and 0.74 ms. These are arithmetic bandwidth estimates, not measured
end-to-end latency; buffering, RTT and client decoding still matter.

## New live comparison and its failure

A disposable instrumented release build was made from the current source.
The test used real ScreenCaptureKit capture at 1728×1118, a scrolling AppKit
window, and a hidden Tahoe ScreenSharing.framework view over loopback. It used
plain URLs, registered the app's default encryption preference of 2, retained
the server's default plaintext policy and fixed both codecs to zlib-ng level 2.
Actual Size and Control were selected in the disposable client after connection.
The existing port 5902 server was untouched.

Attempt order was Zlib, ZRLE, ZRLE, Zlib. Both ZRLE attempts disconnected after
the first framebuffer update, before the 15-second CPU sampling window:

```text
Unknown ZRLE tile subencoding 24.  Closing connection.
Unknown ZRLE tile subencoding 129.  Closing connection.
```

Those messages identified a real native decoding failure. Follow-up testing
traced it to a four-byte-versus-three-byte compact-pixel mismatch for Apple
clients, now fixed. The failed runs must not be treated as successful fast/low-CPU
samples. **There are no valid live ZRLE client CPU or pipeline-latency numbers
from this comparison.** An independent valid test corpus and an advertised
encoding are insufficient to declare this client interoperable.

The two Zlib attempts remained connected but had different capture throughput:

| Diagnostic measurement | Zlib attempt 1 | Zlib attempt 2 |
| --- | ---: | ---: |
| Capture frames/s | 57.58 | 22.59 |
| Sent updates/s | 57.65 | 22.53 |
| Server CPU, 100% = one logical core | 38.13% | 11.65% |
| Client CPU, same convention | 69.87% | 35.79% |
| Median capture-ready → send-complete | 5.69 ms | 2.53 ms |
| p95 capture-ready → send-complete | 7.32 ms | 8.34 ms |
| Median capture lock/copy span | 0.95 ms | 5.75 ms |
| p95 capture lock/copy span | 2.09 ms | 32.34 ms |
| Traffic | 14.78 MB/s | 1.77 MB/s |

Attempt 2 had much slower capture lock/copy and delivered fewer frames; its
lower process CPU does not mean it was more efficient. Its shorter ready-to-send
median also does not include the longer preceding readback. No aggregate live
codec comparison is inferred from these runs. The hidden native view does not
measure physical presentation or an untouched remote macOS 13/iOS client.

`auto` continues to prefer Zlib. ZRLE has a demonstrated bandwidth/CPU benefit
on parts of the independent corpus and is needed by clients such as TigerVNC
that lack encoding 6. After the follow-up Apple compatibility fix, detailed
native image, streaming and scaling checks pass; this report has no new live
CPU/latency comparison for that revised path.

[Per-run measurements](measurements/zrle-vs-zlib-current-2026-10-12.json) retain
all results, including failures. Local artifacts, source hashes, logs and the
comparison driver are in `.build/zrle-zlib-live-2026-10-12/`. The earlier
[scrolling report](scrolling-upgrade-2026-10-12.md) measures before/after server
optimizations using Zlib; its 6.3–6.7 ms median is not a ZRLE measurement.
