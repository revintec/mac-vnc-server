# Staged file drops

Implemented 2026-10-11. `--file-transfer` now uses persistent staging for
client-to-server drops. Connect using a plain URL such as
`vnc://oker-vm.ip:5902/`; no client settings or URL parameters are required by
this change. The existing server encryption policy is unchanged.

## Using it

1. Drag files or folders from local Finder into the Screen Sharing desktop.
   The server requests their bytes as soon as the drag archive arrives.
2. Keep holding the mouse button while the Received Files panel shows progress.
   When **all** selected items finish, the server attempts an AppKit drag
   containing their actual local file URLs at the current remote pointer.
   Continue moving to the intended target, then release.
3. If you release first, leave the remote view, cancel, disconnect, or switch to
   Observe, completion cannot start a new drag. Finished copies remain in the
   panel. Drag their completed row into the target app in a second gesture.
4. The **VNC Files** menu-bar item reopens the panel. Select a row for Reveal in
   Finder, Save a Copy, or Remove. Multiple completed rows can be dragged
   together. If a batch partly fails, explicitly enable “Use completed items
   from a failed transfer” to use its successful items after reception ends.
   With no row selected, Reveal in Finder opens the transfer storage folder.

The panel's Cancel button stops transfers owned by this server process. A
separate `mac-vnc-server transfers` process can reopen the same completed
copies, but cannot cancel another process's active native receivers.

Use `--file-drop-mode native` with `--file-transfer` to keep the previous native
file-promise workflow, which delivers directly into a Finder destination.
The staged path avoids dependence on the target app implementing file promises;
it does not force an app to accept an otherwise unsupported file type.
Server-to-client drops still use Apple's native helper and the client's own
drag implementation. That direction is unchanged.

## Storage and lifetime

Default location, under the **server user's** home directory:

```text
~/Library/Application Support/mac-vnc-server/Transfers/
  <batch-UUID>/
    manifest.json
    .owner
    .incoming/<item-UUID>/<original-name>
    files/<completed-name>
```

The root and containing directories are mode `0700`. The manifest records item
states, names, transferred byte counts, storage reservations, timestamps, and
whether the batch has been used. FileCopy sessions are authorized against the
specific connection's selected batch; another viewer cannot request its files
or redirect its receive destination.

Each native receiver writes into its private `.incoming` item directory.
Publication uses an exclusive atomic rename on the same volume, with numbered
names for collisions. Incomplete files are never offered as drag URLs. Filename
and native entry validation continues to reject traversal and symlinks.
Client originals remain untouched. Edits to staged files do **not** sync back.

Cancelling in the panel or dragging back out of the remote view stops reception.
Releasing over the remote view allows reception to finish for a second drag.
Cancel/failure removes partial data only after the native writer exits.
Per-batch process leases prevent another server or panel process from recovering
an active batch. Recovery also waits for recorded native writer processes to
exit if the owning server crashed. Unrecognized/corrupt manifests are left
alone rather than used as authority to delete paths.

Unused completed copies become eligible for cleanup after 24 hours. Cleanup
runs on startup, on new batches, and periodically while the panel is running.
A batch used in a drag, revealed, or saved is retained until explicitly removed.
Neither drag-end, disconnect, nor restart deletes delivered files. Remove warns
that apps may still refer to their paths.

Limits are shared across processes using the same root:

| Server option | Default | Behavior |
| --- | --- | --- |
| `--transfer-directory /absolute/path` | Application Support path above | Choose persistent storage. |
| `--transfer-limit-gib N` | 10 | Stop accepting file data when retained copies plus active reservations exceed this limit. |
| `--transfer-free-gib N` | 1 | Keep this much disk space available when accepting file data. |

Data is streamed through bounded native-helper pipes. Quota accounting charges
uncompressed payload lengths before passing them to the receiver, reserves
space for entry metadata, and rechecks retained file sizes during housekeeping
so growth from later edits is counted. Metadata reservations make the quota
conservative. Storage limits can stop a transfer; used files are never silently
evicted to make room. As with other disk checks, unrelated applications can
consume free space between checks.

To reopen the inbox without starting a VNC listener:

```sh
./.build/release/mac-vnc-server-dev transfers
# For a custom root, supply the same --transfer-directory as the server.
```

## Timing and verification

The native framework sends a nonempty DropEvent archive (`0x20`) from its
**drag-enter** path, before the drop concludes. Previously, the server waited
for `SSDragHelper` to return a destination after the promised-file drop.
The staged path sends TransferRequest (`0x1e`) immediately with its own private
destination. It does not start `SSDragHelper` for an incoming staged drag.

Read-only inspection of Tahoe's ScreenSharing framework found:

- `SSFrameBufferView.draggingEntered:` creates `SSDragEvent` type 0.
- `SSSession.sendStartDragToRemote:` records local file paths and posts the
  drag archive before `stSendConcludeDragToRemote:` sends mouse-up.
- `handleFileRequest:` checks the pasteboard session ID and expiry and invokes
  the normal local-to-remote file copy path; it does not test for mouse-up.

The native interoperability probe exercises those actual framework paths. It
uses a private file/pasteboard, synthetic server pixels and mock input, and runs
`NSEventTrackingRunLoopMode` while withholding drag conclusion. It checks all
received bytes **before** sending the type-1 conclude event.

Final measurement on Tahoe 26.6.2, loopback, 2,000,000 bytes:

| Server encryption policy | Complete bytes before conclude | Elapsed from drag-enter dispatch |
| --- | --- | --- |
| `--no-encryption` | Yes | 420.4 ms |
| Default encryption negotiation | Yes | 319.8 ms |

Both connections used plain URLs and the Screen Sharing 3.0 app's registered
encryption default (`2`). This final run kept the framework's normal transfer
progress window implementation enabled. Earlier probes suppressed that window
and measured 135–339 ms; those establish wire timing only. These are feasibility
measurements, not network throughput or latency
guarantees. A large file or slow link can outlast the user's held gesture.

Tests also pause an actual native sender before its first file payload, then
exercise both held-button and early-release cases. A released/cancelled gesture
cannot call the drag-start closure; a held gesture may start it exactly once.
Ordinary pointer input resumes after release. Other tests cover authorization,
cancellation racing a queued item, partial batches, collision-safe names,
quotas/free space, leases, recovery, and retained-copy expiry.

The receiving panel was launched with a disposable local fixture. Its ready
row and drag icon were visually inspected, and starting a row drag persisted
its retained state. The UI automation did not complete a drop into another app;
that is **not** a target-app compatibility result.

**Remaining validation:** a complete held gesture from Screen Sharing 3.0 on
macOS 13.1, through AppKit handoff on the server, into Finder and other apps.
The copied 3.0 application cannot run unmodified against Tahoe's private
framework. The framework probe proves early byte transfer on Tahoe; it does not
prove an end-to-end Ventura gesture or compatibility with every target app.
The two-stage panel workflow remains available when handoff is not successful.

Reproduce the protocol timing probe:

```sh
xcrun clang -fobjc-arc -framework AppKit scripts/probe-native-screen-sharing.m \
  -o /tmp/mac-vnc-early-transfer-probe
MAC_VNC_NATIVE_PROBE=/tmp/mac-vnc-early-transfer-probe \
  swift test -Xswiftc -plugin-path \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing \
  --filter nativeScreenSharingTransfersBeforeMouseRelease
```

The full suite passed **179 tests**; the opt-in native timing test additionally
passed with both encryption policies. The arm64 release build and CLI help/version
checks passed. Measurements and source hashes are recorded in
[the validation record](measurements/staged-file-drops-2026-10-11.json).

Useful server verbose lines:

- `Apple staged transfer requested before mouse-up`: archive accepted and bytes requested.
- `Apple file receive completed`: one item atomically published.
- `Apple staged drag ready: ... continued=true/false elapsed_ms=...`: whether the
  main-thread source was armed while the original gesture was still held.
- `Apple staged drag tracking: ... input=appkit`: local AppKit tracking started.
- `Apple staged drag ended: ... operation=1`: AppKit completed a copy drop.
  Operation `0` means cancellation or a target that did not accept the drop.

### Mouse-release handoff

The drag source receives movement, release, and cancellation directly through
its owning AppKit application's event queue. It also keeps the shared input
bridge's held-button state synchronized: CoreDrag observes this state and can
finish a drag early if macOS thinks the button is already up. A source window
created during a remote gesture cannot rely on ordinary HID events being routed
back to it. Waiting for its `mouseDown` prevented the handoff from starting on
the reported system; relying only on HID mouse-up could leave an accepting
target without a drop.

The RFB reader consumes the staged gesture's packets and sends a matching local
AppKit event as well as updating the shared input bridge. It clears the gesture
on release, so a late source-end callback cannot release a newer click. Cancel
queues Escape to the source and releases its synthetic button. Finished files
stay in the inbox. Completion cannot start a drag after an early release.

The regression probe now exercises the actual server process and its newly
created source window, using a separate receiving application. Its visible
Begin/Release controls invoke Tahoe's native ScreenSharing sender over a plain
loopback VNC URL; they avoid creating a second OS drag in the same desktop
session as the server's drag. With a completed file and the button held, the
receiver stayed orange for more than 20 seconds. Only after explicit release
did it receive the matching file contents (`original_held=0`); the server
reported operation `1`. A separate cancellation run reported `target exited`
and server operation `0`, without `performDragOperation`.

Build/run instructions are in `scripts/probe-staged-drag-release.m`. Use a
separate server executable copy and an isolated transfer directory. The local
AppKit-only probe used for the previous change missed the new-window routing
failure and has been replaced. A physical cross-machine gesture from Screen
Sharing 3.0 on macOS 13 into ChatGPT or Finder remains a separate verification.
Unit tests cover the source event stream, one-time cancellation, held-button
state, early release, and cleanup racing a newer click. The release build and
all 187 tests passed. Native sender/receiver timestamps are saved in the
[validation record](measurements/staged-drag-release-2026-10-11.json).

Capture startup was subsequently tested with real ScreenCaptureKit frames. A
Tahoe capture-service failure could discard a callback and suspend startup; the
server now bounds these operations and stops capture on SIGINT/SIGTERM. The
updated suite passes 185 tests. See the [capture startup follow-up](measurements/capture-startup-2026-10-11.json)
for real-frame results, fault injection, and the remaining limitation when
comparison servers share one executable path.
