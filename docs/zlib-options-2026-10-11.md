**Zlib optimization measurements — 2026-10-11**

The zlib-ng backend is now implemented as the default for RFB Zlib encoding 6.
See [implementation details and validation](zlib-implementation-2026-10-11.md)
and the [C adapter documentation](../Sources/CVNCZlib/README.md). The measurements
and source observations below describe the earlier standalone investigation.

The first implementation candidate is **zlib-ng 2.3.3 at level 2**. In a
synthetic scrolling-document benchmark, it compressed a 1728×1118 BGRX frame
split into 26 rectangles in **3.71 ms**, versus **11.97 ms** for system zlib
at level 1, and produced **7.5% fewer bytes**. Three alternating repeat runs
gave 3.68–3.79 ms versus 12.14–12.61 ms. These measure compressor performance,
not live Screen Sharing throughput or end-to-end latency.

The [previous live pipeline profile](pipeline-profile-2026-10-11.md) measured
14.19 ms median compression time per update and attributed about 70% of server
CPU to zlib. That makes the compressor the main computation target. Capture
availability and pacing remain separate latency limits.

**What the server already does**

- `ZlibEncoding.swift` initializes at `Z_BEST_SPEED`, which is **level 1**.
  Going lower means level 0: stored DEFLATE blocks with effectively no
  compression. There is no intermediate fractional compression level.
- `RFBServer.adaptStreaming` selects level 1 when encoding dominates a slow
  frame, or level 3 when writing dominates. A new backend needs its own level
  mapping; retaining those numbers blindly is inappropriate.
- The encoder maintains one zlib stream per connection and flushes each
  rectangle with `Z_SYNC_FLUSH`. Its output scratch buffer is 16 KiB.
- Raw packing already reuses a buffer and zeros the unused BGRX byte. Dirty
  region detection already merges adjacent tile runs. Apple sessions already
  skip transactional `deflateCopy`, so removing it will not improve this path.
- Each compressed result is copied into a length-prefixed payload, then into
  an encoded rectangle. The writer prepares all rectangles before sending them.

**Measured alternatives**

Each document case processes 7,727,616 input bytes per frame. The table is the
median wall time for compression plus scratch-output copying and the mean
compressed bytes per frame, including zlib flush overhead. It excludes RFB
headers, raw pixel packing, capture, encryption, network I/O and decompression.
Decimal kB are used below.

| Library / setting | Median ms | Output kB/frame | Interpretation |
| --- | ---: | ---: | --- |
| System zlib, level 0 | 1.39 | 7,728.9 | Low CPU, almost the entire input on the wire |
| System zlib, level 1 | 11.97 | 193.2 | Current fast setting |
| System zlib, level 2 | 11.75 | 140.5 | Similar measured time, 27% fewer bytes |
| System zlib, level 3 | 12.17 | 135.6 | Similar measured time, 30% fewer bytes |
| zlib-ng, level 1 | 5.86 | 458.5 | Faster, but much larger than system level 1 |
| **zlib-ng, level 2** | **3.71** | **178.6** | **3.23× faster and 7.5% smaller than system level 1** |
| zlib-ng, level 3 | 5.48 | 163.8 | More CPU for a modest size reduction |

Compression levels are not comparable across implementations. With its default
new strategies enabled, zlib-ng level 1 uses `deflate_quick`; level 2 uses
`deflate_fast` with the traditional zlib level-1 search parameters. Level 2
outperformed level 1 on this document. A lower number does not guarantee less
elapsed time on every input.

Three alternating runs of system level 1 and zlib-ng level 2 retained identical
output sizes and reproduced the speed difference:

| Pass | System level 1, ms | zlib-ng level 2, ms |
| --- | ---: | ---: |
| 1 | 12.61 | 3.79 |
| 2 | 12.14 | 3.68 |
| 3 | 12.54 | 3.72 |

Every rectangle was inflated and compared byte-for-byte outside the timed
section. The zlib-ng matrix and alternating repeats explicitly loaded Apple's
`/usr/lib/libz.1.dylib` for decoding; they did not decode using zlib-ng itself.
All comparisons passed. Live Screen Sharing integration, changes of compression
level within a stream, and transaction copying with the replacement backend
have not been tested by this standalone benchmark.

**Content-aware compression matters**

The random-RGB workload (unused fourth byte zero, one rectangle per frame)
shows why choosing a library alone is insufficient:

| Library / setting | Median ms | Output MB/frame |
| --- | ---: | ---: |
| System level 0 | 1.50 | 7.729 |
| System level 1 | 197.03 | 6.697 |
| zlib-ng level 0 | 0.90 | 7.729 |
| zlib-ng level 1 | 87.76 | 8.041 |
| zlib-ng level 2 | 114.77 | 6.609 |

This is a synthetic incompressible-content stress case, not a video benchmark.
It demonstrates both expensive small savings and possible expansion. For such
content, level 0 can be appropriate when the connection has enough bandwidth.

At the update rate and changed-pixel count of the previous live run, uncompressed
BGRX would require approximately **29.17 MB/s (233 Mbit/s)** instead of the
observed **4.99 MB/s**, about **5.84× more data**, before transport overhead.
This is an estimate for the same updates, not a measured level-0 live run.
Higher delivery FPS would increase that requirement. Encryption and copying
also have to process those extra bytes.

Choose the setting using measured compression time, output size and available
throughput. A first approximation to response service time is:

```text
compression time + encryption/copy time(bytes) + bytes / effective throughput
```

Include write-queue delay, client decode behavior and the frame deadline when
evaluating the full result. The current socket-write timer measures local
kernel acceptance, so a quick buffered write is not proof of a fast network.
Use rolling statistics and hysteresis rather than switching on one slow frame.
Content classification can combine recent regional compression ratios with
cheap samples of repetition; byte entropy alone can miss spatial redundancy.
Use occasional bounded probes to recover when content changes.

Select a bypass **before advancing the live compressor**. If a trial compressed
rectangle is discarded and Raw is sent instead, the compressor and viewer
dictionaries diverge. A trial must use isolated state or a correct transaction.
Level 0 inside the same zlib stream can preserve protocol continuity; changes
through `deflateParams` must retain all emitted bytes. Raw encoding is another
choice to validate with the client, keeping the zlib stream untouched during
Raw rectangles and continuing it correctly afterward.

**Other knobs and structural changes**

- **Strategies:** At system level 1, `Z_RLE` and `Z_HUFFMAN_ONLY` took about
  58 ms and produced 4.12 MB on the document, versus 12 ms and 0.193 MB with
  the default strategy. They sacrifice repeated-string matching that is useful
  for desktop pixels. They were faster on noise, but still far more expensive
  than level 0. `Z_FIXED` did not improve time and increased document output.
- **Memory and match searching:** Changing `memLevel` from 8 to 7 or 9 did
  not improve this sample. A tested `deflateTune` setting with `max_chain=1`
  also regressed time and size. These are workload-dependent knobs, not general
  speed fixes. Retain the defaults until representative measurements support
  a change.
- **Flushes and rectangles:** On the same full-frame document bytes, system
  level 1 took 11.42 ms with one rectangle and 11.97 ms with 26. Avoiding 25
  flushes saved only about 0.55 ms here. Cost-aware coalescing is worth testing,
  but joining disjoint dirty areas also adds unchanged pixels. Keep each
  transmitted rectangle decodable at its boundary; removing required flushes
  is not a substitute for coalescing rectangles.
- **Less input:** Tighten dirty bounds where the comparison overhead is lower
  than the saved compression work, and select the newest available frame before
  compression. Stale compressed output cannot simply be dropped after advancing
  the live stream. A negotiated ZRLE path is worth benchmarking on text/palette
  screens, but palette/RLE preparation adds CPU and ZRLE still uses zlib.
  CopyRect was not advertised by the measured Screen Sharing client.
- **Copies and allocation:** Reuse compressed storage, reserve room for the RFB
  length/header, and compress directly into final response storage where buffer
  ownership permits. Merely increasing the scratch buffer to 64 or 256 KiB did
  not help this benchmark. Removing copies is a secondary optimization compared
  with replacing the compressor.
- **Overlap:** A bounded ordered writer can send completed rectangles while
  later rectangles compress, once the update's rectangle count is known. This
  can reduce completion latency on slower links but does not reduce compression
  CPU. Preserve encrypted-record order and prevent stale response queues.
- **Parallelism:** One persistent zlib stream is serial. Independent compressor
  streams per rectangle are not compatible with the existing encoding-6
  stream. Parallelize independent clients or pixel/diff preparation first.
  Parallel DEFLATE with carefully managed dictionaries and block assembly is
  substantially more complex than using a compatible faster library.

`libdeflate` is designed for whole-buffer compression and is not a direct
replacement for this streaming API. Apple's Compression framework also requires
checking wrapper, flush and continuation semantics; its algorithm name alone
does not establish compatibility. LZ4 or Zstd would require a mutually supported
RFB encoding rather than changing the bytes inside Zlib encoding 6.

**Implementation order**

1. Add a selectable zlib-ng backend behind a small C wrapper, preferably using
   its native namespaced API to avoid symbol collisions. Keep the system
   backend for comparison. Start with zlib-ng level 2 and map adaptive settings
   separately for each backend. Preserve stream lifetime, flush boundaries,
   parameter-change output and transaction behavior. The compatibility-mode
   build used here isolates the library comparison; it is not yet this wrapper.
2. Validate with the actual Screen Sharing 3.0 setup from the pipeline report:
   scrolling text, image/video content and resize transitions. Compare p50/p95
   encode time, CPU, bytes, client inflate time and capture-to-client latency
   with the same pacing/scaling settings. Exercise level changes and any Raw
   fallback explicitly.
3. Add a bandwidth-aware level-0 policy for poorly compressible regions and
   rolling metrics to support it. Retain an explicit level override for
   reproducible measurement. System levels 2–3 are also worth a live comparison
   when a dependency change is undesirable.
4. Then measure copy removal, tighter dirty regions and cost-aware coalescing.
   Explore compression/write overlap if real-link measurements show that
   transmission remains a substantial part of update completion time.

If the synthetic speed ratio transferred to the live workload, 14.2 ms of
compression would fall to roughly 4–5 ms. That is an estimate requiring live
validation. It does not imply a 3× end-to-end improvement or establish 60 FPS;
the prior 64.6 ms capture-to-client median also included capture and pacing.

**Reproduction and evidence**

Measured host: macOS 26.6.2 (25G83), ARM64 VM, 8 virtual CPUs, 24 GiB RAM;
Apple clang 21.0.0. Server source inspected at commit
`03af263819771230b06b33755d48a165c6dad044`. The benchmark runs independently of
the server binary and does not modify its dependencies or install a library.

System zlib reports 1.2.12. The latest release returned by the GitHub release API
on the measurement date was [zlib-ng 2.3.3](https://github.com/zlib-ng/zlib-ng/releases/tag/2.3.3),
published 2026-02-03. Its compatibility version reports `1.3.1.zlib-ng`.
The downloaded source archive SHA-256 was
`92c0dd38b1548debf6c4b2d7b5aa16e4416ce5df6ddd405fa96431eb7aaa4a09`.
The library was built with `./configure --zlib-compat --static` and `make -j4`,
using its default optimization settings and ARM acceleration/runtime detection.

The harness uses eight vertically shifted document patterns, or eight
deterministic random-RGB frames, each 1728×1118 with a zero fourth byte.
A stream persists across four warmups plus 24 timed document frames, or four
warmups plus eight timed noise frames. One rectangle or 26 horizontal stripes
cover exactly the same pixels in the same order. This intentionally isolates
compression and flush behavior; it does not replay the actual dirty rectangles
from the live pipeline. Other host workloads were not fully isolated.

Compile on macOS from the repository root. Keep downloaded dependencies and
binaries outside source control; point `zlib_bench_ng` to the built release:

```sh
zlib_bench_dir=$(mktemp -d /tmp/mac-vnc-zlib-bench.XXXXXX)
zlib_bench_ng=/absolute/path/to/zlib-ng-2.3.3
clang -O3 -Wall -Wextra scripts/pipeline-profile/benchmark-zlib.c \
  -lz -o "$zlib_bench_dir/bench-system"
clang -O3 -Wall -Wextra -I"$zlib_bench_ng" \
  scripts/pipeline-profile/benchmark-zlib.c "$zlib_bench_ng/libz.a" \
  -o "$zlib_bench_dir/bench-ng"
"$zlib_bench_dir/bench-system" > "$zlib_bench_dir/system.csv" \
  2> "$zlib_bench_dir/system-verify.log"
"$zlib_bench_dir/bench-ng" > "$zlib_bench_dir/ng.csv" \
  2> "$zlib_bench_dir/ng-verify.log"
```

Use `BENCH_WORKLOAD=document BENCH_CASE=level2 BENCH_RECTS=26` before an
invocation to select one case. With no filters, noise runs only level 0,
level 1, RLE and Huffman with one rectangle; use an explicit level-2 filter
to reproduce the extra noise measurement. CSV times are per-frame sums of
per-rectangle calls. `median_ms` is the sorted upper middle sample and
`p95_ms` uses index `floor(n * 0.95)`. Thread CPU is measured separately with
`CLOCK_THREAD_CPUTIME_ID`; wall time uses `CLOCK_UPTIME_RAW`. With only eight
noise samples, the reported p95 is the maximum sample and is not a reliable
tail estimate.

- [Benchmark source](../scripts/pipeline-profile/benchmark-zlib.c)
- [System-zlib matrix](measurements/zlib-options-2026-10-11-system.csv)
- [zlib-ng matrix](measurements/zlib-options-2026-10-11-ng.csv)
- [Alternating repeats and extra noise case](measurements/zlib-options-2026-10-11-repeat.csv)
- [Apple-decoder verification log for repeats](measurements/zlib-options-2026-10-11-verify.log)
