**Framebuffer Zlib backend**

This SwiftPM C target contains zlib-ng **2.3.3** in its native `zng_*` namespace,
alongside a separate adapter for macOS system zlib. Only `include/CVNCZlib.h` is
exposed to Swift. The adapters deliberately compile in different translation
units: zlib-ng and zlib have incompatible public stream types and must not share
headers or replace each other's symbols. Other server users of system zlib
(ZRLE, clipboard and file-transfer archives) continue to link to macOS libz.

`vendor/` contains unmodified upstream C sources, private headers, and the
license, with public native headers copied from the upstream `.h.in` templates.
The gzip file API, test programs, build systems and unrelated architectures are
omitted. The source archive is pinned by SHA-256 in
`scripts/vendor-zlib-ng.py`; run that script with the downloaded archive to
reproduce/verify the vendored tree. No network access, CMake or generated binary
dependency is needed during `swift build`.

`CVNCZlibConfig.h` supplies the build configuration. SwiftPM force-includes it
because some upstream files check architecture macros before including headers.
Selection uses compiler target macros, not the host architecture. ARM64 enables
NEON and available CRC32 intrinsics with upstream runtime detection. Intel uses
the generic C implementations. The full generic fallback set and upstream new
compression strategies are enabled. Gzip file operations are disabled. The
default framebuffer level is 2 (zlib-ng's `deflate_fast`), with level 3 used by
the existing bandwidth adaptation. System zlib's fast level remains 1.

The adapter allocates every stream at a stable address, releases borrowed input
and output pointers after every operation, and preserves independent state in
`deflateCopy`. Swift retains all output from `deflateParams` and handles output
buffer exhaustion before a level change completes. Rectangles end with
`Z_SYNC_FLUSH`; the stream persists across rectangles and updates. The encoder
builds the compressed length and payload in one array.

Use `--zlib-backend system` for comparison/fallback, and `--zlib-level 0...9`
to hold the selected level fixed. `--zlib-level auto` restores adaptation.
These options affect RFB Zlib encoding 6 only; they do not change which encoding
is negotiated. Use `--encoding zlib` to request it explicitly. Level 0 still
uses the same continuous zlib stream and can greatly increase network traffic.

Validation: `swift test --scratch-path .build/zlib-optimization -c release`.
The backend tests decode with Apple's zlib through level 0/1/2/3/9 changes,
multiple output chunks, and committed/discarded transactions. For the integrated
encoder benchmark (including pixel packing and payload creation):

```sh
MAC_VNC_BENCHMARK=1 swift test --scratch-path .build/zlib-optimization \
  -c release --filter framebufferBenchmark
```

On the measured Command Line Tools 21 installation, release test builds require
`-Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib`
because the default build engine omits the Swift Testing macro plugin path.
After a successful test build, `--skip-build` can be used for the benchmark or
native interoperability probe. No global toolchain settings need to change.

Upstream: https://github.com/zlib-ng/zlib-ng/releases/tag/2.3.3
License: [zlib license](vendor/LICENSE.md).
