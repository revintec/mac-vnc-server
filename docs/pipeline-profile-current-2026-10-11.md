# Current client/server pipeline measurements — 2026-10-11

The default plaintext Zlib/zlib-ng path delivered **53 updates/s**, using **40–41% of one CPU core on the server** and **49–50% on the client** in two 30-second scrolling samples. Copied-frame readiness to the client framebuffer update was **18.7–19.3 ms median / 27.7–28.4 ms p95**. These are measurements on the local VM, not input-to-photon or remote-network latency.

The full results, process counters and source hashes are in [the measurement JSON](measurements/pipeline-current-2026-10-11.json). The [earlier report](pipeline-profile-2026-10-11.md) remains historical.

## Setup and identity

- Host: macOS 26.6.2 (25G83), VirtualMac2,1, eight logical CPUs, 24 GiB RAM.
- Server: release build of the working tree based on `9fbeb86`, including the interface/defaults, environment-password and image-format changes. The profiled source manifest matches the current source files.
- Client: a disposable copy of Screen Sharing 3.0, using Tahoe’s ScreenSharing.framework and a compatibility adapter for a method removed since macOS 13. The original app was not modified. This is not an untouched macOS 13 client.
- One 1728×1118 captured display, a deterministic 1200×1000 AppKit scrolling document with a 60 Hz animation timer, Actual Size, client cursor, automatic frame pacing. The viewer content area was 1462×946, scale 1, with horizontal scroll 0 and vertical scroll 1.
- All connections used `vnc://127.0.0.1:5911/`, with no URL overrides. Clipboard and file-transfer capabilities were enabled by default; no files were transferred in the timed intervals. The disposable server read its test credential through `VNC_PASSWORD`.
- Plaintext cases used default `--no-encryption`; the encrypted comparison used `--encryption`. zlib-ng used adaptive levels 2/3 and system zlib used 1/3.
- Viewer overlap, other desktop activity and existing server sessions were not isolated. The scrolling document ran continuously, so different cases did not encode identical pixel sequences.

## CPU, throughput and latency

CPU percentages use **100% = one logical core**. RFB MB/s uses decimal megabytes and excludes record framing and TCP overhead. Each table row is a separate 30-second sample. “Ready → client” starts when the copied frame is available to the server and ends after the client’s framebuffer-update callback for the last decoded rectangle.

| Case | Server CPU | Client CPU | Workload CPU | Updates/s | RFB MB/s | Ready → client median / p95 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| plaintext, sample 1 | 40.11% | 50.45% | 12.35% | 52.99 | 10.84 | 19.27 / 28.35 ms |
| plaintext, sample 2 | 40.89% | 49.43% | 12.50% | 53.00 | 11.06 | 18.70 / 27.74 ms |
| encrypted, sample 1 | 48.78% | 52.92% | 12.61% | 53.49 | 13.24 | 20.51 / 31.72 ms |
| encrypted, sample 2 | 47.25% | 54.97% | 12.72% | 52.89 | 12.94 | 20.25 / 31.87 ms |
| system-zlib, sample 1 | 63.97% | 51.38% | 12.87% | 52.49 | 11.76 | 22.89 / 39.38 ms |
| system-zlib, sample 2 | 62.38% | 50.53% | 12.42% | 53.26 | 11.66 | 22.51 / 37.49 ms |

With the workload idle, the plaintext server used 13.34% CPU and the client 20.92%, while small changing background regions still generated 53.57 updates/s and 0.17 MB/s. This was not a fully static desktop baseline.

The uninstrumented release server validation used **42.15% CPU**, with **48.21% client CPU** and **11.66% workload CPU** over 30 seconds. That is consistent with the instrumented process totals, but different content prevents a precise profiling-overhead estimate. The client adapter remained present. Its 753.7 framebuffer callbacks/s were rectangle callbacks, not frames; no frame rate is inferred for this validation.

All **9,545 scrolling updates** in the six instrumented intervals matched the client’s cumulative decompressed byte counts exactly. The idle sample matched another 536 updates. The system-zlib trace ends with an incomplete frame during shutdown, outside every measured interval; no sample has a mismatch or missing tail.

## Where time is spent

The following uses plaintext sample 2. Rectangle operations are summed per sent frame; capture and draw rows are per operation. CPU measures time charged to the thread. The rows overlap and run on different threads, so their medians must not be added to estimate total latency.

| Stage | Median wall | p95 wall | Median thread CPU |
| --- | ---: | ---: | ---: |
| Capture buffer lock, allocation, copy and store | 3.009 ms | 10.379 ms | 0.566 ms |
| FPS pacing wait | 11.458 ms | 17.614 ms | 0.019 ms |
| Snapshot, cursor and scale at Actual Size | 0.007 ms | 0.014 ms | 0.007 ms |
| Dirty-region comparison | 0.841 ms | 1.297 ms | 0.841 ms |
| BGRX pixel packing | 0.732 ms | 1.169 ms | 0.733 ms |
| Persistent zlib-ng compression | 4.600 ms | 7.402 ms | 4.593 ms |
| Plaintext batch assembly and writes | 0.088 ms | 0.176 ms | 0.088 ms |
| Client Zlib inflation | 1.488 ms | 2.430 ms | 1.480 ms |
| Client draw submission | 0.105 ms | 0.225 ms | 0.104 ms |

Compression consumed **235.1 ms of CPU per second**, about 57.5% of total server CPU. Dirty comparison used 46.8 ms/s, packing 39.4 ms/s and capture copy/store 35.9 ms/s. Client inflation used 75.1 ms/s, about 15.2% of its process CPU. The client’s remaining work includes protocol handling, memory/backing-store operations, AppKit/Core Animation, scheduling and the probes. The draw hook alone does not account for that cost.

System zlib took **7.49–7.82 ms median / 16.19–17.38 ms p95** to compress each frame, versus **4.46–4.60 / 7.18–7.40 ms** for plaintext zlib-ng. System zlib used more server CPU despite encoding fewer changed pixels in these samples. This supports retaining zlib-ng, but is not a byte-identical compressor benchmark; see the [controlled compression experiments](zlib-options-2026-10-11.md) for that comparison.

For encrypted sessions, the directly measured server AES record-sealing cost was **0.375–0.409 ms median per frame**, or **21.2–22.0 ms CPU/s** (about 2.1–2.2% of one core). The client crypto-update hook recorded 1.66–1.75 ms CPU/s, excluding other record handling. The whole 6–9 percentage-point server CPU difference cannot be assigned to encryption: the encrypted cases generated 12.94–13.24 MB/s of RFB data versus 10.84–11.06 MB/s in plaintext, with different pixel content and compression work.

## Latency boundaries and smoothness

| Boundary | Plaintext sample 1 median / p95 | Plaintext sample 2 median / p95 |
| --- | ---: | ---: |
| Capture-copy operation start → client framebuffer | 22.71 / 32.83 ms | 22.30 / 33.42 ms |
| Copied frame ready → client framebuffer | 19.27 / 28.35 ms | 18.70 / 27.74 ms |
| Capture presentation timestamp → client framebuffer | 17.43 / 28.84 ms | 17.31 / 28.96 ms |
| Server write complete → client framebuffer | 4.36 / 7.28 ms | 4.23 / 6.89 ms |
| Client framebuffer notification → next draw submission | 8.72 / 16.38 ms | 8.52 / 16.58 ms |

Capture delivery was about **56.8 frames/s**, with about **53 sent updates/s**. Plaintext client frame intervals were **17.73–17.79 ms median**, **32.55–34.35 ms p95**, and **50.49–58.99 ms maximum**. Smoothness therefore still has occasional gaps even when average throughput is close to 60 Hz. System zlib had 37.91–39.65 ms p95 intervals. One encrypted sample included a 252.6 ms gap; this shared VM run does not establish its cause.

Capture PTS is a presentation timestamp, not a trace of when capture processing began. Its difference from copied-frame readiness was sometimes negative (sample 2 median −1.46 ms). That is not negative processing time. The copy-start and readiness boundaries above are stronger measures of actual server/client processing; they still omit earlier application rendering and input delivery.

The next draw submission is only a scheduling observation. It does not prove that this exact frame appeared on a physical screen. No input-to-photon measurement or cross-machine one-way network timing was performed. Plaintext vector writes bypass the raw-write probe; their cost is measured by the enclosing write span, not zero.

The earlier report measured roughly 15 updates/s and 23.8% server CPU. This run captures and sends much more work per second and uses a newer source tree and different configuration. Neither the higher CPU nor the lower latency should be treated as an isolated regression or improvement percentage.

## Next optimization priorities

1. Keep zlib-ng and client-rendered cursors. Compression remains the largest server computation cost; client cursor motion already avoids framebuffer latency.
2. Investigate frame pacing and capture readiness together, targeting p95 frame intervals. The pacing wait precedes frame selection, so simply removing all waits is not justified by its wall time.
3. Reduce capture buffer synchronization/readback cost. Copy wall time was 3.01 ms median / 10.38 ms p95 while its CPU median was only 0.57 ms.
4. Cache unchanged rescaled snapshots when scaling is needed. Actual Size avoids that resampling in this run.
5. Add negotiated CopyRect only for clients that advertise it. Screen Sharing 3.0/macOS 13 and the tested Tahoe framework do not advertise encoding 1. Sending larger scroll rectangles cannot make unmodified Screen Sharing scroll offscreen application content locally. See [encoding and CopyRect research](encoding-compatibility.md).

## Reproduction and artifacts

The [profiler instructions](../scripts/pipeline-profile/README.md) describe building the disposable server/app copies, launching with `VNC_PASSWORD`, sampling process counters and matching frames. The measured command used `--bind 127.0.0.1 --port 5911 --display 1 --encoding zlib --transfer-directory <profile>/inbox --verbose`; only `--encryption` or `--zlib-backend system` varied between cases.

Local traces and CPU samples are retained under `.build/pipeline-profile-current/{plaintext,encrypted,system-zlib,release-validation}`. The accompanying JSON contains metadata and aggregate measurements, not screenshots or clipboard/file contents. All temporary benchmark server, viewer and workload processes were stopped. The existing port 5902 server was not restarted.
