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
4. Choose **Received Files…** from the remote-VNC menu-bar icon to reopen the panel. Select a row for Reveal in
   Finder, Save a Copy, or Remove. Multiple completed rows can be dragged
   together. If a batch partly fails, explicitly enable “Use completed items
   from a failed transfer” to use its successful items after reception ends.
   With no row selected, Reveal in Finder opens the transfer storage folder.

The panel's Cancel button stops transfers owned by this server process. A
separate `mac-vnc-server transfers` process can reopen the same completed
copies, but cannot cancel another process's active native receivers.

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
    partial/<original-name>.partial/<native-receiver-output>
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
**Cancel in Received Files keeps data already written.** The server first records
that choice, stops the native receiver, waits for it to exit, then moves its
unfinished output into a clearly named `.partial` container. The row shows
“Incomplete kept”; **Reveal in Finder** exposes that container without needing
the completed-items checkbox. Incomplete files can be truncated, sparse, or
missing folder entries. They are not offered for dragging or Save a Copy, and
there is no resume support. They remain until explicitly removed and continue
to count toward the storage limit, including after restart.

Leaving the remote view, connection failures, and other receive failures still
remove unfinished data after the writer exits unless panel cancellation already
requested retention. Completed files are retained as before.
Per-batch process leases prevent another server or panel process from recovering
an active batch. Recovery also waits for recorded native writer processes to
exit if the owning server crashed. Unrecognized/corrupt manifests are left
alone rather than used as authority to delete paths.

Unused completed copies become eligible for cleanup after 24 hours. Cleanup
runs on startup, on new batches, and periodically while the panel is running.
A batch used in a drag, revealed, or saved is retained until explicitly removed.
Finder drops **move the server's staged files** into the chosen Finder location,
including when dragging a completed row from this panel. Other apps are offered
Copy, and their received sources remain available here. The footer explains the
difference before a drop; row/status notices report an accepted move and then
“Moved to Finder”. Client originals are never removed.

Finder performs the move. The server never deletes source files merely because
a drag finished: it waits until Finder has actually removed each source before
marking it moved and releasing its storage reservation. If Finder leaves a
source in place (for example after cancelling a collision dialog), the panel
makes that copy available again after five minutes and reports that it is still
here. It continues watching for a slower move to finish. Removing the transfer
record afterwards does not remove the file at its Finder destination.

Disconnect and restart do not delete retained files. Remove warns
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

### Cancel retention and Finder moves (2026-10-11)

Finder detection uses the window under the drag point, including inactive
Finder windows and the desktop, rather than the frontmost app. AppKit snapshots
the source operation masks at drag creation, before a valid location is set.
The source therefore updates the native drag's allowed actions before movement
and mouse-up, using `CoreDragSetAllowableActions` and the session's `dragRef`.
For handoff starting directly over Finder, it also supplies Move in AppKit's
initial operation snapshot, so releasing without moving still moves the files.
This is a private macOS bridge; the symbol, selector, argument count, and return
encoding are checked before use. Cancellation uses `CoreDragCancelDrag` on the
main thread **before** releasing the shared input button, so an accepting
Finder target cannot complete a move while Escape is queued. The gesture lock
is released before waiting for that main-thread cancellation; incoming pointer
packets are consumed until cancellation finishes. Both native symbols must be
available to enable Move. If unavailable, the source keeps Copy and the
panel explicitly reports that Finder copied the files. No Finder automation
permission, client setting, or URL option is needed.

The regression probe's **Switch target** control moves a held drag between its
app receiver and a Finder location, and **Begin received row** exercises a panel
row through ordinary remote pointer input. A real native receiver test cancels
after the first file-data chunk and verifies preserved contents, writer exit,
and unchanged client bytes. Storage tests cover empty cancellations, completed
items racing Cancel, recovery, quota, delayed Finder completion, and destination
survival when an inbox record is removed.

Local verification passed for a stationary handoff into Finder, retargeting a
held drag from Finder to an AppKit receiver (copy with matching bytes), and a
completed-row drag into Finder. Finder destinations contained the expected
bytes and moved sources disappeared from staging; the panel displayed “Moved
to Finder”. A cancelled Finder drag produced operation `0`, retained its
staged source, and created no destination. The partial-data fixture's Reveal in
Finder selected its `.partial` container with the completed-items checkbox off.
These are Tahoe loopback/server-side checks using plain VNC URLs, not a claim
of a new cross-machine test with Screen Sharing 3.0 on macOS 13. See the
[verification record](measurements/cancel-retention-finder-moves-2026-10-11.json).
