**VNC request/response pipeline measurements — 2026-10-11 (Asia/Shanghai)**

The largest server computation cost is persistent Zlib compression. The largest
latency contributors are capture availability and frame pacing. In the final
30-second scrolling run, the current server used **23.8% of one CPU core**, the
instrumented Screen Sharing client used **24.9%**, and **447 framebuffer updates**
reached the client, or **14.9 updates/second**. Capture presentation timestamp to
client framebuffer notification was **64.6 ms median / 98.5 ms p95**. These are
local measurements on this VM, not a LAN or physical-display latency guarantee.

**Build and client identity**

- Server: release build of the current working tree, including its uncommitted
  changes, based on commit `c00e105`. The latest unmodified binary was built at
  02:47 and its SHA-256 was
  `d1174cabe9dec1b0dd7dc448a494966273129b6d93a7554050e00f4444daeb0e`.
- A separate release build of a copied source tree added timing probes. The
  final source manifest was compared against every current Swift source file:
  no differences remained. No production source was edited for this profiling task.
- Client: `/Users/revin/code/Screen Sharing.app`, **version 3.0**, ARM64e.
  The host is **macOS 26.6.2 (25G83)**, `VirtualMac2,1`, eight virtual CPUs and
  24 GiB RAM. The copied app dynamically loads the host's newer
  `ScreenSharing.framework`; this is not the macOS 13 framework.
- The original 3.0 app authenticated, then failed during initialization because
  it calls a framework method removed from this OS. Measurements therefore used
  a disposable, ad-hoc signed copy with a compatibility adapter for
  `connectionOptionsWithOptions:urlOptions:` and timing probes. Its saved
  session files were redirected into the profiling directory. The original
  application bundle was left untouched.
- Session: loopback, one 1728×1118 display, Actual Size, Zlib, adaptive FPS,
  automatic client cursor, Apple file-transfer profile, negotiated encrypted
  records, clipboard sync disabled. No files were transferred.

**What the pipeline actually does**

The client negotiates RFB 3.889, authentication type 30, BGRX with depth 32,
Zlib encoding 6, RichCursor, and Apple's display information extensions. It
then sends `FramebufferUpdateRequest` and enables `AutoFrameBufferUpdate` with
`interval_us=0`. Subsequent frames are server-pushed: steady-state streaming
is not one client request followed by one response per frame.

Input takes a separate reader path through encrypted-input decoding and
`applyPointerEvent` / `applyKeyEvent` into macOS event posting. The application
and WindowServer produce the changed desktop. ScreenCaptureKit delivers a
pixel buffer; the capture callback locks it, allocates and copies BGRA bytes,
and updates the latest-frame store. The framebuffer writer applies FPS pacing,
snapshots that store, optionally rescales/composites a cursor, finds dirty
rectangles, packs pixels, compresses each rectangle using the persistent Zlib
stream, encrypts the records, and writes them to the socket. The client reads
and decrypts records, inflates rectangles, updates its framebuffer, and schedules
AppKit/Core Animation drawing.

**Final current-source run: time and CPU cost**

The workload was a disposable AppKit window containing a scrolling synthetic
code document, with a 60 Hz animation timer, while capturing the real desktop.
The window occupies 1200×1000 of the 1728×1118 desktop. The remaining desktop,
viewer visibility, VM scheduling and other existing server sessions were not
isolated. There were typically 26 rectangles and 638,976 changed pixels per
sent update. RFB payload throughput averaged **4.99 MB/s (39.9 Mbit/s)** before
record framing/TCP overhead.

| Stage | Median wall time | p95 wall time | Median thread CPU | Unit / interpretation |
| --- | ---: | ---: | ---: | --- |
| Capture PTS → copied frame available | 23.77 ms | 39.49 ms | — | Per delivered frame; includes OS delivery and the next row |
| Capture buffer lock, allocation, copy and store | 8.55 ms | 13.05 ms | 0.686 ms | Per accepted capture; mostly waiting |
| FPS pacing | 36.73 ms | 38.58 ms | 0.017 ms | Writer iteration that sends an update; actual sleep, including overshoot |
| Snapshot / cursor / scale at Actual Size | 0.007 ms | 0.015 ms | 0.007 ms | Per sent frame; no resampling at scale 1 |
| Dirty-region comparison | 1.04 ms | 1.70 ms | 1.02 ms | Per sent frame |
| BGRX pixel packing | 1.01 ms | 1.65 ms | 1.00 ms | Sum of all rectangles in a frame |
| Persistent Zlib compression | 14.19 ms | 22.13 ms | 13.97 ms | Sum of all rectangles in a frame |
| Apple encrypted-record sealing | 0.677 ms | 1.288 ms | 0.678 ms | Sum of records in a frame |
| Socket writes | 0.198 ms | 0.444 ms | 0.195 ms | Bytes accepted by the local kernel; not remote acknowledgement |
| Record assembly + encryption + writes | 0.976 ms | 1.931 ms | 0.964 ms | Includes the preceding encryption/write rows |
| Client Zlib inflation | 2.43 ms | 4.03 ms | 2.39 ms | Sum of inflation calls for that frame |
| Client `drawRect:` submission | 0.120 ms | 0.299 ms | 0.119 ms | Per draw call; excludes other compositor work and scanout |

The measurements overlap and run on different threads; **do not add these
medians** to estimate end-to-end latency. FPS sleep begins before the writer
chooses a captured frame, while capture runs independently. CPU is time actually
charged to the measured thread, not elapsed waiting time. Small differences
between median CPU and wall times reflect clock resolution and aggregation.

Across the complete sample, Zlib consumed **166 ms of CPU per second**, about
**70% of the server's total process CPU**. Dirty comparison used 15.7 ms/s,
pixel packing 12.4 ms/s, capture lock/copy/store 11.0 ms/s, and record sealing
8.4 ms/s. Client inflation consumed 28.7 ms/s. Its remaining process CPU includes
protocol handling, AppKit/Core Animation, backing-store work, scheduling and
instrumentation; the tiny `drawRect:` measurement does not account for all of
that work. The client cipher-update hook consumed approximately 0.6 ms/s but
does not include all record authentication/parsing.

A five-second stack sample supports the capture finding: 381 sampled stacks
inside the capture update were in `CVPixelBufferLockBaseAddress` →
`IOSurfaceClientLock` → an IOKit trap, versus 12 in the pixel copy and 8 in
zero-fill. These are sampled stacks, not CPU percentages. This VM's surface
readback/synchronization is a significant source of elapsed delay.

**Measured latency boundaries**

| Boundary | Median | p95 |
| --- | ---: | ---: |
| Capture presentation timestamp → client framebuffer notification | **64.62 ms** | **98.48 ms** |
| Copied source frame available → client framebuffer notification | 38.75 ms | 62.36 ms |
| Server write completed → client framebuffer notification | 5.32 ms | 9.59 ms |
| Client framebuffer notification → next observed draw submission | 12.90 ms | 26.26 ms |

The last row describes the next draw call. It does not prove that the entire
corresponding frame was physically displayed. No optical input-to-photon test,
GPU timing, display scanout measurement, or real-network one-way latency was
performed. In particular, the 64.6 ms boundary starts at the captured frame's
presentation timestamp, not at the user's key press.

The reader/input measurements were separate from the scrolling interval.
In the earlier trace of the same input code, 236 pointer-injection calls took
**0.040 ms median / 0.182 ms p95**. Ten framebuffer request-body read/parse calls
took **0.046 ms median / 0.577 ms p95**; those include any wait for the remaining
message bytes, so they are not a pure parsing benchmark. These boundaries do
not include client event generation, inbound network latency, event delivery to
the target application, or application rendering. The final client also sent
real native scroll/pointer input and the current server's injection probes fired.
Only two key-injection samples existed, too few for a useful distribution.

**Scaling comparison**

A preceding paired run used the same streaming implementation and the same
scrolling document. The intervening source changes affected plaintext-encryption
policy and diagnostic text, outside this encrypted session's path.

| Measurement | Actual Size, 1728×1118 | Zoom to Fit, 1462×946 |
| --- | ---: | ---: |
| Server process CPU, one core = 100% | 28.4% | 43.8% |
| Client process CPU, instrumented | 27.1% | 28.8% |
| Snapshot/cursor/rescale, median per frame | 0.007 ms | 5.08 ms |
| Zlib compression, median per frame | 14.23 ms | 16.69 ms |
| Delivered updates/sec | 14.5 | 14.0 |
| RFB throughput | 6.29 MB/s | 8.36 MB/s |

Fractional resampling added CPU and produced a less compressible representation
of this text workload, despite reducing its dimensions. This is content-specific.
At scale 1, the single-display snapshot can retain the existing pixel array;
at a fractional scale, `vImageScale_ARGB8888` processes the framebuffer.

There is also avoidable repeated work: resampling occurs in
`captureClientFramebuffer` before `prepareFramebufferUpdate` checks whether the
frame sequence is unchanged. An automatic-update loop can resample a duplicate
frame and then decide there is nothing to send. Cursor state and resize state
must be included if caching or skipping this work is implemented.

The separate latest **unmodified** release-binary validation run used 23.6%
server CPU and 25.2% traced-client CPU for 20 seconds, consistent with the final
current-source trace. This was a validation run, not a controlled estimate of
instrumentation overhead. The temporary profiling server/viewer/workload have
been stopped; pre-existing server sessions were preserved.

**Where to investigate next**

1. Capture delivery and surface locking: observed accepted capture rate was
   about 15 Hz even though the configured/adaptive targets were higher. Check
   the VM compositor/readback behavior and capture queueing before attributing
   the whole FPS gap to compression.
2. Avoid resampling unchanged sequences, and cache scaled frames with correct
   cursor/scale invalidation. This directly addresses the measured 5 ms work
   on each scaled candidate.
3. Zlib is the main CPU target. Compare compatible compression implementations,
   dirty-rectangle grouping and byte movement while preserving Screen Sharing's
   persistent-stream requirement. Disabling encryption would save less than
   1 ms per typical frame here.
4. Add explicit capture-age, pacing and client-side boundaries to any permanent
   telemetry. Existing `frame_ms` begins **after** `throttleFrameRate`, and
   `capture_ms` measures a store snapshot/rescale, not the asynchronous
   ScreenCaptureKit callback. `write_ms` means local socket acceptance and also
   includes encryption. Those logs alone cannot describe the full pipeline.

Relevant code: `RFBServer.swift` lines 978, 996, 1208, 1375, 1516 and 1737;
`StreamingScreenCapture.swift` lines 308 and 599; `ZlibEncoding.swift` lines 141
and 157; `FramebufferResampling.swift` line 53; `Socket.swift` lines 162 and 214.
Screen Sharing did not advertise CopyRect, so it cannot be assumed as a compatible
way to make scrolling local to this client.

**Evidence and reproduction**

- [Machine-readable results and source hashes](measurements/pipeline-2026-10-11.json)
- [Profiling helpers and instructions](../scripts/pipeline-profile/README.md)
- Raw metadata traces, stack samples, build logs and JSON summaries are retained
  under `.build/pipeline-profile-2026-10-11/` (ignored build artifacts). CSV traces
  are gzip compressed. No framebuffer pixels or user clipboard contents are
  included in those traces.

Wall-clock probes use `CLOCK_UPTIME_RAW`; computation probes use
`CLOCK_THREAD_CPUTIME_ID`. Process CPU uses `proc_pid_rusage` with the host's
125/3 Mach timebase conversion. Server responses were matched to client
inflation by the exact cumulative uncompressed byte count across rectangles,
then to the framebuffer-updated callback. **All 447 nonempty responses in the
final timed interval matched**, with no stream-boundary mismatch. An incomplete
response at process shutdown falls outside that interval and is recorded
separately as an incomplete trace tail. All helpers compiled, both release
builds completed, and the original and current-source runs both authenticated
and streamed using the specified client copy.
