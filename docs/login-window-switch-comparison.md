# Login Window switching and display wake investigation

## Report and scope

The affected computer runs mac-vnc-server 1.6.1 on macOS 27.0.1. A root
loginwindow worker failed with `ScreenCaptureKit displays do not match the
attached console` until `mac-vnc-server wakeup` was run. The same log contained
MainActor warnings from `SessionActivity` in `AccountSessionWorker.swift`.

Separately, an unnamed app showed a screen-lock warning after the VNC menu's
**Switch to Login Window** action, but not after the built-in Fast User Switching
**Login Window…** action. The user clarified that this was a lock-related warning,
not a crash or a screen-capture/remote-control warning. The app and warning text
are private and are not needed to document the implementation comparison.

This investigation ran on a different computer, reporting macOS **27.2.1**, build
**26B131**. It did not execute a physical session switch, restart an existing VNC
endpoint, or reproduce the unnamed app's behavior on 27.0.1.

## Comparison with the installed Control Center

The production server loads `/System/Library/PrivateFrameworks/login.framework/login`
and calls `SACSwitchToLoginWindow()` from a detached task. It verifies that the
non-root worker belongs to the current console user's audit session and checks
console ownership again immediately before the call. There is no call to
`SACLockScreenImmediate`, logout, or a lock-screen fallback.

Read-only disassembly of
`/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter`
(arm64e slice) found:

| Address | Evidence |
| --- | --- |
| `0x1000f5a18` | The menu action logs `switch to login window`. |
| `0x1000f5aa4` | That action calls the helper at `0x100474244`. |
| `0x100474320`–`0x100474330` | The helper places the function at `0x100474424` into its dispatched closure. |
| `0x1004743cc` | The helper submits that closure through `DispatchQueue.async`. |
| `0x100474424` | The closure tail-calls the imported `SACSwitchToLoginWindow` symbol. |

The inspected universal executable's SHA-256 is
`78e729cc88503073c448a3ba8e832416aecd791e99971c514e4ce5b4043a868d`.
These addresses describe this binary only. They establish the same underlying
request and asynchronous dispatch, not an identical caller, process environment,
or sequence of app-visible lock notifications. They do not establish what the
27.0.1 Control Center or login framework does.

The server's menu action itself does not modify lock state or choose a different
switch mode. Its normal capture observers rebuild streams after either a session
resign or become-active notification, regardless of which menu initiated the
switch. There is no evidence here that replacing this API with another private
switch or a lock command would resolve the reported warning. Version 1.6.2 keeps
the switching request unchanged. The 27.0.1 lock-warning difference remains
unresolved; use the built-in action that the user has confirmed works on that Mac.

For a future comparison on the affected Mac, version 1.6.2's `--verbose` menu
status logs include the worker's on-console and screen-lock flags as well as
the worker and console identities. These are collected after either menu's
session transitions and require no app name or warning text. Compare both actions
with the same viewer connected and the same initial unlocked session. `Unknown`
means macOS did not provide that flag; it must not be interpreted as unlocked.
These snapshots can distinguish persistent session states but may miss brief
lock notifications. They do not establish what the unnamed app observes.

## Display startup and main thread fixes

`caffeinate -i` holds an idle-system-sleep assertion. It does not hold a
display-sleep assertion or declare user activity. The `wakeup` command uses
`caffeinate -u -t 5` to declare user activity, which can light the monitor without
unlocking the desktop or switching sessions.

Previously, startup made one shareable-content request and immediately rejected
an empty list or console-display mismatch. Input-triggered recovery could not
help a connection that had not finished capture startup. Version 1.6.2 wakes once
and retries display discovery up to three times for these specific failures,
including ScreenCaptureKit's native `noDisplayList` error. Each attempt uses a
new snapshot. It preserves session verification, strict console display-ID
matching and geometry limits. It does not retry permissions or invalid geometry.
Persistent mismatches now include the offered and active IDs in the error.

Root workers used `dispatchMain()` while user workers used AppKit's main loop.
A delayed callback probe on the investigation host showed both the main dispatch
queue and a MainActor task executing with `pthread_main_np() == 0` under the old
root path. Using `CFRunLoopRun()` kept both on the actual main thread. Version
1.6.2 uses that run loop for processes without AppKit UI. This directly addresses
the reported callback-thread violation, independently of the display mismatch.
The shutdown regression fixture checks delayed main-queue/MainActor callbacks
and real interrupt handling with the production run-loop helper.

## Validation

- Xcode's Swift 6.3.3 toolchain: **288 tests in 22 suites passed** with
  `swift test --scratch-path .build/xcode-validation --no-parallel` (the successful
  run used `--skip-build` after compilation). The default concurrent run had
  socket-fixture timeouts; the same suite passed with parallel execution disabled.
- All nine display-discovery regression tests passed, covering successful capture
  without wake, delayed discovery, the native no-display error, persistent wrong
  desktops, permissions/geometry failures, console replacement, cancellation,
  and wake-command failure.
- `scripts/test-interrupt.py`: eight real-signal cases passed, each requiring
  delayed main-queue and MainActor callbacks on the OS main thread.
- The arm64 release executable passed version, code-signature and live listener
  checks. It uses a local ad-hoc signature.
- `scripts/test-session-capture.py`: two debug reconnect cycles and one release
  cycle passed with complete **1728×1117** Zlib frames and RichCursor, overlapping
  viewers, idle teardown, failed-handshake cleanup and parent-channel shutdown.
  These checks exercised the current user's session, not the other Mac's sleeping
  loginwindow session.

The Command Line Tools Swift 6.4 installation could not load Swift Testing through
its default build engine and could not locate the Testing module through its
native engine. Validation therefore used Xcode through a per-command
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` setting, without changing
the machine's selected developer directory.
