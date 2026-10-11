# Client support for CopyRect, pacing and capture delivery

Researched on 2026-10-11 for ordinary connections to mac-vnc-server, using
plain connection URLs and no client configuration changes. This does not cover
Apple's separate High Performance screen-sharing mode. Source inspection is
not a live interoperability or latency test.

CopyRect is negotiated by the client. Server frame pacing and capture delivery
are implementation choices that can benefit every client without adding a new
encoding. Update-request flow control is the part of pacing that differs across
clients.

## Support matrix

“Yes” in the last two columns means the optimization is compatible with the
client, not that an improvement has been measured or implemented. “Not
advertised” applies to the observed connection profile, not every possible mode
of that application.

| Client | CopyRect, encoding 1 | Client update-request / streaming support | Server pacing improvements | Faster server capture delivery |
| --- | --- | --- | --- | --- |
| Screen Sharing 3.0, macOS 13 | **Not advertised** in the user's traces | Apple `AutoFrameBufferUpdate`; observed with interval 0. This is Apple's push extension, not standard ContinuousUpdates. | Yes; preserve Apple's startup/layout ordering | Yes |
| Screen Sharing on Tahoe; installed app 6.1 (764.2) | **Not advertised** by the tested Tahoe framework | Apple `AutoFrameBufferUpdate`, observed with interval 0 in native framework probes | Yes; preserve Apple's startup/layout ordering | Yes |
| RealVNC Viewer on iOS | **Unverified for the user's installed version**; check encoding 1 in its SetEncodings | Standard framebuffer requests are the baseline. ContinuousUpdates/Fence support is unverified for this mobile build. | Yes; honor requests and apply backpressure | Yes |
| TigerVNC, current source | **Yes**, decoder and advertisement | Pipelined standard requests; negotiated ContinuousUpdates and Fence support | Yes; standard continuous mode could remove per-update requests | Yes |
| noVNC, current source | **Yes**, decoder and advertisement | Standard requests after updates; negotiated ContinuousUpdates and basic Fence replies; render-queue flushing before the next update | Yes; browser rendering remains another scheduling stage | Yes |
| UltraVNC Viewer, current Windows source | **Yes**, subject to selected encodings/options | Standard incremental/full requests. No TigerVNC-style ContinuousUpdates/Fence path identified in the inspected viewer/protocol files. | Yes; honor its request flow | Yes |
| Remmina VNC plugin, current source / LibVNCClient | **Yes**, present in the plugin's encoding presets and library decoder | Standard requests; the inspected LibVNCClient core requests the next update after processing the previous one | Yes; honor its request flow | Yes |
| Apache Guacamole VNC, current source / LibVNCClient | **Yes** on the gateway's RFB leg; copy operations are handled by Guacamole | Standard RFB requests through LibVNCClient, followed by Guacamole's separate render thread/browser delivery | Yes; gateway/browser scheduling also matters | Yes |

For Tahoe, the host is macOS 26.6.2 (25G83). Its framework was exercised through
native probes and an adapted copy of Screen Sharing 3.0. Checking the installed
6.1 app's version does **not** establish that its complete GUI was separately
tested. The macOS 13 evidence is the user's actual remote-client traces.

The RealVNC mobile application is closed source. Its public parameter reference
does not establish CopyRect or ContinuousUpdates support for the installed iOS
build. Desktop support or a successful Zlib connection cannot establish those
capabilities. The existing server logs the full encoding list, so no client-side
change is needed to resolve this row: look for `1` (CopyRect), `-313`
(ContinuousUpdates), and `-312` (Fence). Advertisement is necessary; the server
must still perform the extension-specific negotiation.

noVNC needs a WebSocket-to-RFB transport, and Guacamole uses guacd. Their RFB
capabilities do not imply that a browser connects directly to the server's TCP
port. These gateways are separate from capture on the macOS server.

## Implementation status, updated 2026-10-12

| Mechanism | Current status | Clients that could benefit |
| --- | --- | --- |
| CopyRect motion reuse | Implemented for verified vertical translations on incremental updates | Only clients advertising encoding 1; not the observed Apple sessions |
| FPS cap and adaptive pacing | Implemented; default `--fps auto` starts at 60, explicit values accept 1–120 | All |
| Capture-driven sender wakeups and monotonic pacing deadlines | Implemented; coalesced capture notifications, monotonic deadlines and skipped missed slots | All |
| Latest-frame storage | Implemented per display; queue depth 3, one in-flight copy and at most one pending buffer | All |
| Reduced capture buffer lock/copy delay | Empty-dirty frames skipped; no zero-fill before copy; work moved off the callback queue. Accepted buffers still require lock/copy | All |
| Apple automatic framebuffer updates | Implemented, including client region/interval and disabling/rearming around display metadata changes | Negotiating Apple viewers |
| Standard ContinuousUpdates and Fence | Implemented when advertised; up to three automatic frames awaiting Fence acknowledgements; SyncNext unsupported | TigerVNC/noVNC are confirmed candidates; other clients must be checked |
| Client display-vsync / presentation acknowledgement | No general mechanism implemented | Cannot promise physical presentation timing for any row |

The generic-client request defect identified in the original research is fixed:
ordinary requests are consumed after a response, while unchanged incremental
requests remain pending. Regions are merged without losing full-refresh intent.
Streaming without further requests requires explicit ContinuousUpdates negotiation;
Apple uses its separate automatic-update extension.

Relevant server locations:

- `RFBServer.swift`: `framebufferWriterLoop`, `sendFramebufferUpdate`,
  `throttleFrameRate`, `handleAppleAutoFramebufferUpdate`, and
  `handleClientMessage`.
- `StreamingScreenCapture.swift`: stream configuration, `StreamingFrameStore.update`,
  and `ScreenCaptureStreamOutput.stream`.

## Implications for smooth scrolling

1. **Capture freshness, pacing and backpressure have the widest reach.** Optimize
   frame readiness and deadlines, avoid queuing old work, and preserve client
   flow control. An FPS cap is not a guarantee of evenly spaced presentation.
2. **CopyRect is a bandwidth/encoding optimization for eligible clients.** It
   copies an already-received area and sends newly exposed pixels separately.
   It neither supplies an offscreen document nor gives the client local scroll
   physics. Use the last successfully sent per-client framebuffer as the
   baseline, and do not use CopyRect to fulfill a nonincremental refresh.
3. **ContinuousUpdates avoids a request for each update.** It can reduce request
   latency on longer-RTT links, but still needs bounded sending/backpressure.
   Fence can help with processing synchronization and measurements; it is not a
   physical-display presentation acknowledgement. noVNC's inspected Fence handler
   supports BlockBefore/BlockAfter responses and explicitly lacks SyncNext.
4. **ZRLE palette bugs are fixed and the encoder is replaced.** `auto` prefers
   Zlib when available, then ZRLE, then Raw. Current TigerVNC uses ZRLE because
   it does not implement encoding 6. The [new measurements](scrolling-upgrade-2026-10-12.md)
   include full-pixel checks and demonstrate workloads where ZRLE saves both
   CPU and bandwidth.

The existing local benchmark measured about **56.8 delivered captures/s** and
**53 sent updates/s**, with plaintext client frame intervals of **17.7–17.8 ms
median / 32.6–34.4 ms p95**. This supports investigating capture and pacing
together; it does not rank these clients. That benchmark used the adapted old
app with Tahoe's framework on the local VM, not an untouched macOS 13 client,
iOS device, or physical input-to-photon measurement. See the
[benchmark and its limits](pipeline-profile-current-2026-10-11.md).

## Evidence and sources

The source revisions below were inspected, not installed and benchmarked as
released clients. Raw source downloads used the configured system HTTP proxy.
Local research downloads are in `.build/client-support-research/`.

- [RFB protocol: CopyRect](https://github.com/rfbproto/rfbproto/blob/master/rfbproto.rst#copyrect-encoding),
  [ContinuousUpdates](https://github.com/rfbproto/rfbproto/blob/master/rfbproto.rst#enablecontinuousupdates),
  and [Fence](https://github.com/rfbproto/rfbproto/blob/master/rfbproto.rst#clientfence).
- [TigerVNC CConnection](https://github.com/TigerVNC/tigervnc/blob/8c5eb64cc522c3417fa50573da9174e327ed7d33/common/rfb/CConnection.cxx):
  request pipelining, `endOfContinuousUpdates`, `fence`, and encoding advertisement;
  [Decoder](https://github.com/TigerVNC/tigervnc/blob/8c5eb64cc522c3417fa50573da9174e327ed7d33/common/rfb/Decoder.cxx) confirms CopyRect.
- [noVNC RFB](https://github.com/novnc/noVNC/blob/b17d04c1a1a926a59f4a04bb866332b429f2ce37/core/rfb.js):
  `_sendEncodings`, `_normalMsg`, `_framebufferUpdate`, `_handleServerFenceMsg`;
  [CopyRect decoder](https://github.com/novnc/noVNC/blob/b17d04c1a1a926a59f4a04bb866332b429f2ce37/core/decoders/copyrect.js).
- [UltraVNC ClientConnection](https://github.com/ultravnc/UltraVNC/blob/0cd8b41aeb34e52e170b33e24411b3f805e303be/vncviewer/ClientConnection.cpp):
  CopyRect handling and `Internal_SendAppropriateFramebufferUpdateRequest`.
- [Remmina VNC plugin](https://github.com/FreeRDP/Remmina/blob/bb33690d870e9121379ad86e8dec019e06695c96/plugins/vnc/vnc_plugin.c):
  encoding presets;
  [LibVNCClient](https://github.com/LibVNC/libvncserver/blob/98aaee0560baa0332339b2ef464ea96ed9b9b28c/src/libvncclient/rfbclient.c):
  CopyRect decoding and `SendIncrementalFramebufferUpdateRequest` after an update.
- [Guacamole VNC display handling](https://github.com/apache/guacamole-server/blob/ae12b8e51aa6287d0eca7a50c6cac04af4a71590/src/protocols/vnc/display.c),
  [settings](https://github.com/apache/guacamole-server/blob/ae12b8e51aa6287d0eca7a50c6cac04af4a71590/src/protocols/vnc/settings.c),
  and [connection/render loop](https://github.com/apache/guacamole-server/blob/ae12b8e51aa6287d0eca7a50c6cac04af4a71590/src/protocols/vnc/vnc.c).
- [RealVNC Viewer parameter reference](https://help.realvnc.com/hc/en-us/articles/360002254618-RealVNC-Viewer-Parameter-Reference):
  distinguishes mobile configuration limits, but does not settle the iOS
  CopyRect/ContinuousUpdates questions.
- Apple's supplied macOS 13 trace and local `.build/native-encoding-tests.log`:
  macOS 13 advertises `[6,16,-239,1104,1100,-223,1101,1105,1107,1109]`;
  the Tahoe framework advertises
  `[1011,1002,6,16,-239,1104,1100,-223,1101,1105,1107,1109,1110]`.
  Neither includes CopyRect (1), Fence (-312), or ContinuousUpdates (-313).

The client capability evidence above remains source inspection or the stated
Apple traces. The implementation update adds these mechanisms and protocol
tests; it does not imply live validation of every client in the table.
