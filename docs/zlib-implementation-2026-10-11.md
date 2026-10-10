**Zlib optimization implementation — 2026-10-11**

RFB Zlib encoding 6 now defaults to the vendored **zlib-ng 2.3.3** encoder at
**level 2**. In the integrated synthetic benchmark, packing pixels, compressing
26 rectangles and constructing their payloads took **4.62 ms** at BGRX depth 32,
versus **14.69 ms** using system zlib level 1, with 7.5% smaller payloads.
The depth-24 run measured 4.49 ms versus 12.88 ms. These are roughly 3× faster
encoder results, not measurements of end-to-end display latency.

**Behavior and options**

- Automatic compression selects levels 2/3 for zlib-ng and 1/3 for system zlib,
  retaining the existing encode-versus-write adaptation policy.
- `--zlib-backend zlib-ng|system` selects the backend for a new connection.
  The default is `zlib-ng`. There is no automatic runtime fallback. System zlib
  remains selectable for controlled comparisons and manual rollback; the server
  already needs it for ZRLE, clipboard and file-transfer code.
- `--zlib-level auto|0...9` selects automatic adaptation or a fixed level.
  An explicit level is honored even while FPS/scaling adaptation remains on.
  Level 0 sends stored DEFLATE blocks through the same continuous stream.
- `--no-adaptive` keeps the backend's initial compression level and retains its
  existing effects on FPS and scaling. The options affect encoding 6 only;
  `--encoding zlib` can be used to request this encoding explicitly.
- Startup logs report the backend, library version, initial level and whether
  compression adaptation is enabled. Service installation and automatic
  per-display configuration copies preserve both new options.

The C adapter uses zlib-ng's native `zng_*` symbols. Apple libz symbols remain
separate, and no runtime zlib-ng installation is required. Upstream sources and
the license are vendored with a pinned archive hash and a reproduction/verification
script. ARM64 enables NEON and available CRC32 intrinsics with upstream runtime
detection; Intel uses generic C implementations.

Each stream has a stable heap address. Buffer pointers are borrowed only during
a call. Level changes retain all bytes emitted by `deflateParams`, and retry
when its output buffer fills. Transactions copy the compressor and its pending
output, preserve rollback, and install committed state only after a successful
clone. The length-prefixed payload is now built directly in one array, removing
the former full compressed-array copy used only to prepend its length.

The existing pipeline profiler was updated for the shared encode path. It records
backend and level with compression spans, and includes the C sources and package
configuration in its source-hash manifest.

**Validation**

- ARM64 release binary built successfully.
- All **168 tests in 8 suites passed**, including parameterized tests for both
  backends. New coverage verifies continuous decoding with Apple zlib through
  level 0/1/2/3/9 changes, output spanning multiple scratch buffers, discarded and
  committed transactions, transaction ownership, fixed-level overrides, and CLI
  parsing/service arguments.
- The native Screen Sharing framework probe passed with encrypted records,
  streaming pixel checks, observe/control transitions, and scale changes to
  0.5, 0.75 and 1.0. It uses synthetic server pixels and mock input; this run
  tests the host framework, not a separate launch of the Screen Sharing 3.0 app.
- The C backend cross-compiled for x86_64. No Intel runtime measurement was made.
- All 78 vendored upstream files match the pinned source archive. The profiler
  creates its instrumented copy successfully and its modified encoder parses.
- The integrated release benchmark passed. Each case has eight warmups and 32
  measured frames; the input is the same synthetic 1728×1118 document pattern
  used in the earlier investigation. The table includes the four-byte length
  for every rectangle, but excludes the outer RFB rectangle headers.

| Pixel depth / rectangles | Backend / level | Median ms | p95 ms | Mean payload bytes |
| --- | --- | ---: | ---: | ---: |
| 24 / 1 | zlib-ng / 2 | 4.470 | 5.479 | 177,779 |
| 24 / 1 | system / 1 | 13.439 | 15.303 | 192,275 |
| 24 / 26 | zlib-ng / 2 | 4.490 | 5.058 | 178,722 |
| 24 / 26 | system / 1 | 12.884 | 13.567 | 193,269 |
| 32 / 1 | zlib-ng / 2 | 4.390 | 5.010 | 177,779 |
| 32 / 1 | system / 1 | 12.803 | 13.968 | 192,275 |
| 32 / 26 | zlib-ng / 2 | 4.621 | 5.748 | 178,722 |
| 32 / 26 | system / 1 | 14.688 | 19.971 | 193,269 |

The host was not fully isolated; differences between equivalent depth-24 and
depth-32 pixel data reflect run-to-run timing variation. The earlier standalone
benchmark is [recorded separately](zlib-options-2026-10-11.md).

**Build and reproduction**

The validated release executable is:

```text
.build/zlib-optimization/out/Products/Release/mac-vnc-server-dev
SHA-256: 9c7eef42dd2af86ea3ba0969204b09980faf77b9a2b225937036af935a76d27f
```

Running server processes were not restarted. Builds used task-specific scratch
directories to avoid another session's normal build output. Existing README and
file-transfer/session-design edits from that session were preserved.

On this Command Line Tools installation, the default build engine omits the
Swift Testing macro plugin search path for release tests. Validation supplied it
explicitly without modifying global toolchain settings:

```sh
swift test --scratch-path .build/zlib-optimization -c release \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
MAC_VNC_BENCHMARK=1 swift test --scratch-path .build/zlib-optimization \
  -c release --skip-build --filter framebufferBenchmark
xcrun clang -fobjc-arc -framework AppKit scripts/probe-native-screen-sharing.m \
  -o /tmp/mac-vnc-zlib-options-20261011/native-probe
MAC_VNC_NATIVE_PROBE=/tmp/mac-vnc-zlib-options-20261011/native-probe \
  swift test --scratch-path .build/zlib-optimization -c release --skip-build \
  --filter nativeScreenSharingNegotiatesEncryptionWithAppDefaults
```

Evidence: [integrated benchmark CSV](measurements/zlib-integrated-2026-10-11.csv),
[release and source hashes](measurements/zlib-implementation-2026-10-11.json),
[adapter and dependency notes](../Sources/CVNCZlib/README.md).

This change implements the compatible compressor replacement, fixed-level
controls, backend-aware adaptation and one payload-copy reduction. Automatic
content classification, compression/write overlap, and further dirty-region
changes remain separate optimization candidates requiring their own live
measurements.
