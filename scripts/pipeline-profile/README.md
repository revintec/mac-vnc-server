**Local pipeline profiler**

These helpers support the [current-source measurements](../../docs/pipeline-profile-current-2026-10-11.md)
and the [earlier 2026-10-11 measurements](../../docs/pipeline-profile-2026-10-11.md).
They instrument a disposable source copy and a disposable copy of the user's
Screen Sharing 3.0 application. They do not install a service or modify the
production checkout, original application, or existing server sessions.

`compare-codecs.py OUTPUT_DIRECTORY` builds a disposable copy with the Swift
encoder comparison harness and invokes `analyze-codecs.py` to check every pixel
with an independent RFC 6143 decoder. It does not launch a listener or UI.
The [Zlib/ZRLE comparison](../../docs/zrle-vs-zlib-2026-10-11.md) reports both
timing and correctness; malformed output must not count as a compression win.
Use a new output directory outside the repository or inside `.build`.

`benchmark-zlib.c` is a separate synthetic compression benchmark. It compares
levels, strategies, scratch-buffer sizes and zlib-compatible libraries, with
persistent-stream round trips through Apple's system decoder. See the
[zlib optimization report](../../docs/zlib-options-2026-10-11.md) for results,
limitations and reproduction commands.

`instrument-server.py SOURCE DESTINATION` copies the checkout (excluding Git and
build directories), records source hashes, and adds monotonic wall/thread-CPU
probes to the copy. The script checks each insertion point and fails if the
source layout has changed. Build that copy in release mode. Each instrumented worker writes
`worker-PID.csv` beside the disposable source directory. The output path is
embedded only in that disposable build because workers intentionally do not
inherit arbitrary listener environment variables. Use an own-user listener and
one client for these measurements.

```sh
profile_dir=$(mktemp -d /tmp/mac-vnc-pipeline.XXXXXX)
python3 scripts/pipeline-profile/instrument-server.py "$PWD" "$profile_dir/server"
swift build -c release --package-path "$profile_dir/server"
"$profile_dir/server/.build/release/mac-vnc-server-dev" \
  --bind 127.0.0.1 --port 5911 --display 1 --encoding zlib \
  --file-transfer --verbose
```

The server stays in the foreground. Use a separate terminal for subsequent
commands. Authenticate with the current macOS account; no fixture password is accepted by the production listener.

`client-trace.m` times native Zlib inflation, cipher updates, framebuffer-update
notifications and draw submission. It also contains socket hooks, but they did
not observe the framework's receive path on the measured host; the report does
not treat their absence as zero network time. It restores one removed framework
method used by the old application's ready callback. Consequently these results
are for the 3.0 app with the **host OS framework and adapter**, not an untouched
macOS 13 installation.

```sh
xcrun clang -arch arm64e -fobjc-arc -O2 -dynamiclib -framework AppKit -lz \
  scripts/pipeline-profile/client-trace.m -o "$profile_dir/client-trace.dylib"
ditto '/Users/revin/code/Screen Sharing.app' "$profile_dir/Screen Sharing Pipeline.app"
plutil -replace CFBundleIdentifier -string local.mac-vnc.PipelineScreenSharing \
  "$profile_dir/Screen Sharing Pipeline.app/Contents/Info.plist"
codesign --force --deep --sign - "$profile_dir/Screen Sharing Pipeline.app"
MAC_VNC_CLIENT_PROFILE="$profile_dir/client.csv" \
DYLD_INSERT_LIBRARIES="$profile_dir/client-trace.dylib" \
  "$profile_dir/Screen Sharing Pipeline.app/Contents/MacOS/Screen Sharing"
```

Connect through the application's UI to `127.0.0.1:5911`, use your macOS account credentials, leave Remember Password unchecked, and choose Actual Size. Relaunch
through the command above for each separate session: launching the copied app
normally omits the injected compatibility adapter. Keep the test document
visible in the captured desktop. Viewer overlap changes the workload.

`workload.m` implements a disposable 1200×1000 AppKit scrolling document. It
accepts the profiling directory as its sole argument, reads `workload-mode`
(`idle` or `scroll`), and writes `workload-retry.csv`. It handles ordinary native
scroll events. It creates its own window and does not inject input into other
applications. Compile with `xcrun clang -fobjc-arc -O2 -framework AppKit` and,
for normal app discovery, place the executable in an `.app` with a unique
bundle identifier. The initial measured workload rebuilt font attributes on
each draw and later encountered a font lookup failure; the delivered helper
caches attributes and has a fallback. The final current-source run used this
corrected helper. The colored marker was experimental; no reported latency
uses marker matching or assumes that it proves display scanout.

Use verified process IDs with the sampler; it rejects missing processes and
limits samples to 60 seconds. Choose a measurement interval after negotiation
and scaling have settled.

```sh
python3 scripts/pipeline-profile/sample-cpu.py scrolling 30 \
  WORKER_PID CLIENT_PID WORKLOAD_PID > "$profile_dir/scroll-cpu.json"
python3 scripts/pipeline-profile/analyze.py "$profile_dir" client.csv
```

Disconnect the viewer to flush the worker's buffered trace, then copy its
`worker-PID.csv` to `server.csv` before the final analysis. The client flushes once per second. Close only the temporary processes
you launched. `analyze.py` produces `summary.json`, distinguishes an incomplete
shutdown tail from a byte-count mismatch, and reports per-interval matching
counts. Verify that every nonempty response in each timed interval matched.
For the encrypted Zlib/BGRX profile, it combines per-rectangle and per-record
measurements into per-frame totals. The analyzer assumes one client session per
input client trace and no interleaved clients in its server trace.

The analyzer reports capture-copy start, copied-frame readiness and capture PTS
as separate latency boundaries. PTS is a presentation timestamp and can occur
after readiness; a negative PTS-to-ready value is not negative processing time.
It also reports capture delivery rate and intervals between matched client
framebuffer notifications. Plaintext vector writes bypass `socket_write_raw`;
use the enclosing `encrypt_and_write` span for their write cost.

The native app and framework remain closed source. Draw submission, framebuffer
notification, and kernel socket acceptance are distinct boundaries; neither a
successful socket write nor a draw call proves that pixels reached a physical
display. Process totals also include work outside the individual probes. The
profiling calls and buffered logging add overhead, so compare repeated runs and
validate against the unmodified release binary as in the report.
