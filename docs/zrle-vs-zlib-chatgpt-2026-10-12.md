# ZRLE versus Zlib while scrolling the ChatGPT conversation

The current ZRLE implementation is not better in every measure. In this real-app scrolling test it reduced bandwidth, but did not improve update throughput, and its server processing and capture-ready-to-send latency were higher. Zlib remains a reasonable default for a fast connection; ZRLE is useful when reducing traffic matters more.

The user scrolled this ChatGPT app's conversation up and down during four runs in Zlib → ZRLE → ZRLE → Zlib order on 2026-10-12. Each run measured 12 seconds after connection and warmup, for approximately 24 measured seconds per codec. The workload was the actual visible desktop, not a generated text fixture. The app automation tool cannot drive this application, so scrolling was manual.

Both codecs used an isolated instrumented release built from the current source, including the Apple three-byte compact-pixel compatibility fix. The source hash manifest matched the checkout at build verification. The installed production binary SHA-256 was `ef7c5a0a8eb11bbe91bde60b25983442fc204d9f5c38f5811c1543ba3b4c2488`; it was not replaced by the benchmark.

Settings: Apple M1 Pro (Virtual), macOS 26.6.2; real ScreenCaptureKit capture at 1728×1118; fixed 60 FPS cap; zlib-ng 2.3.3 at fixed level 2; client-rendered cursor; hidden Tahoe ScreenSharing.framework view at Actual Size over the plain URL `vnc://127.0.0.1:5911/`; server default plaintext policy. Clipboard sync was disabled for the benchmark. The native client did not advertise CopyRect, so it was not used. Framebuffer size stayed constant, and the logs reported no network stalls or stale-frame retries. All four clients stayed connected through their sampling interval.

The table pools both runs for each codec. CPU percentages are time-weighted process CPU; 100% is one logical core. Latency percentiles are calculated from all sampled updates, not averages of per-run percentiles.

| Measurement | Zlib | ZRLE |
|---|---:|---:|
| Updates per second | 51.4 | 51.5 |
| Server CPU, % of one core | 21.4 | 24.2 |
| Native client process CPU, % of one core | 51.2 | 53.3 |
| RFB traffic, MB/s | 3.93 | 3.27 |
| Changed pixels, million/s | 20.87 | 22.07 |
| Bytes per changed pixel | 0.188 | 0.148 |
| Server CPU, ms per million changed pixels | 10.26 | 10.97 |
| Client CPU, ms per million changed pixels | 24.54 | 24.14 |
| Capture-ready → server write complete, median ms | 3.81 | 4.47 |
| Capture-ready → server write complete, p95 ms | 9.86 | 14.59 |
| Update interval, median ms | 17.25 | 17.25 |
| Update interval, p95 ms | 36.99 | 39.64 |

ZRLE sent 16.7% less traffic per second while processing 5.8% more changed pixels. Expressed per changed pixel, its output was 21.3% smaller. Server CPU per million changed pixels was 6.9% higher; client CPU per million changed pixels differed by only 1.6%, which is too small to interpret as a reliable advantage in this manual test. An update is not a physical display refresh, so approximately 51 updates/s is not a measured client presentation rate.

Manual scroll rate and content differed across runs. A comparison restricted to larger updates (524,288–1,048,575 changed pixels) gives much closer damage sizes and excludes most small UI animation updates:

| Larger scrolling updates | Zlib | ZRLE |
|---|---:|---:|
| Number of updates | 744 | 782 |
| Mean changed pixels/update | 652,233 | 647,812 |
| Bytes per changed pixel | 0.186 | 0.148 |
| Frame-processing thread CPU, median ms/update | 4.04 | 4.66 |
| Capture-ready → server write complete, median ms | 4.24 | 4.83 |
| Capture-ready → server write complete, p95 ms | 10.88 | 15.82 |

Here ZRLE sends 20.6% fewer bytes per changed pixel while the server's frame-processing thread uses 15.6% more median CPU time per update. This thread metric covers preparing/sending the response, including dirty detection and encoding; it is not an encoder-only timing and excludes the separate capture worker. Similar area does not guarantee identical content complexity. The result supports a bandwidth-versus-processing tradeoff, not a universal performance ranking.

Both codecs had approximately 17.25 ms median send intervals. ZRLE's p95 interval was slightly longer (39.64 versus 36.99 ms), so this test provides no evidence of smoother delivery from switching to ZRLE. Frame pacing, capture delivery, cursor handling and CopyRect negotiation are common server mechanisms, not ZRLE-specific benefits.

| Run | Server CPU % | Client CPU % | Updates/s | Changed Mpixels/s | MB/s | Ready → send median / p95 ms |
|---|---:|---:|---:|---:|---:|---:|
| zlib 1 | 16.9 | 36.0 | 48.1 | 13.15 | 2.54 | 1.55 / 5.32 |
| zrle 1 | 24.8 | 52.7 | 52.2 | 24.00 | 3.58 | 4.46 / 15.01 |
| zrle 2 | 23.6 | 53.8 | 50.9 | 20.15 | 2.96 | 4.48 / 14.49 |
| zlib 2 | 26.0 | 66.4 | 54.7 | 28.60 | 5.32 | 4.16 / 10.80 |

These measurements do not include end-to-end input-to-display latency. Capture-ready is after ScreenCaptureKit buffer publication; the reported interval excludes the preceding capture/readback, network transit, client decoding and physical presentation. The hidden native view tests the Tahoe client pipeline, not an untouched remote macOS 13 Screen Sharing 3.0 or iOS client. A bandwidth-limited remote connection may benefit more from ZRLE's smaller output than this loopback test does. Neither fresh screenshots nor a full-pixel correctness comparison were collected in this benchmark; the separate [Apple compatibility validation](apple-zrle-compatibility-2026-10-12.md) records the earlier pixel checks.

The preliminary non-scrolling samples remain in the raw artifact directory but are superseded by this scrolling comparison for the current question. Expected socket closure/reset messages and a pre-existing MainActor warning occurred when the driver stopped its child processes after measurement. No client failed during sampling. The benchmark server has stopped; existing user servers and production sources were not changed.

[Machine-readable results](measurements/zrle-vs-zlib-chatgpt-2026-10-12.json) include metadata, per-run process CPU counters, pooled distributions and limitations. Timing CSVs, source hashes, per-frame metadata, logs, the driver and analyzer are in `.build/chatgpt-scroll-2026-10-12/`. The driver samples four user-scrolled sessions; it does not automate the application or save screen images.
