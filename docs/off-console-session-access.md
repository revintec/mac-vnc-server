# Existing user session access while the console shows loginwindow

Implementation and platform validation: 2026-10-12, macOS Tahoe 26.6.2
(25G83). This covers a user who is already logged in, with the server running
in that user's GUI session.

## Behavior

The physical monitor can show loginwindow after Fast User Switching while VNC
continues to show the server user's desktop. Remote keyboard and pointer input
goes to that desktop. The physical console stays at loginwindow until someone
logs in there. Use the ordinary `vnc://HOST:PORT/` URL; there is no new client
option or server flag.

The server's `VNC_PASSWORD` authenticates access to that existing desktop. It
does not authenticate a macOS account or unlock the physical console. An Aqua
LaunchAgent runs in the correct user session; a system daemon or an arbitrary
SSH process is not equivalent.

## What changed

- All `MacInputController` events use `cgSessionEventTap`, including modifiers,
  Unicode fallback, scrolling, dragging, and held-input releases. Previously
  they used `cghidEventTap`, which follows physical-console input.
- Capture observes `NSWorkspace.sessionDidResignActiveNotification` and
  `sessionDidBecomeActiveNotification` as well as screen wake and stream errors.
  It re-enumerates ScreenCaptureKit displays and reconstructs the layout/streams.
- Recovery requests are coalesced. If the session changes again while a rebuild
  is running, it performs another pass rather than discarding that transition.

No login broker, virtual-display creation, private entitlement, or system
configuration change is needed for the tested existing-session path.

## Runtime evidence

The test used an animated AppKit window with click/key counters in the server
user's GUI session. Session state was read from `CGSessionCopyCurrentDictionary`.
The user switched the physical console to loginwindow and logged back in there.

- The user also confirmed seeing the test colors continue blinking through VNC
  while locked. Seeing the user desktop in a screenshot alone would not have
  established that it was live.
- During one transition the on-console display ID `1` became off-console ID
  `24`. A newly enumerated ScreenCaptureKit stream started successfully while
  `kCGSSessionOnConsoleKey` was false and delivered new frames. It returned to
  display `1` on console login. An earlier stream on a temporary virtual display
  had stopped delivering without recovering on its own.
- In the controlled input test, Accessibility hit testing verified that the
  target point belonged to the floating test window. Both combined-session and
  private event sources, posted at `cgSessionEventTap`, delivered mouse clicks
  and F18 key events while off-console. The first successful off-console click
  arrived before the probe's explicit application-activation step.
- An earlier input run was inconclusive because the window could be covered by
  another application. Missing counters in that run are not evidence that the
  session tap is blocked.
- Installed `ScreensharingAgent` disassembly independently shows `CGEventPost`
  calls with tap value `1` (`kCGSessionEventTap`).

The input regression test checks every event category and disconnect releases
use the session tap. ScreenCaptureKit recovery still uses its bounded callback
and first-frame handling, retaining the shared frame-change hub across restarts.
The release build passed 22 focused tests and four live loopback VNC startup
checks (staged/native drag entry points, automatic/single display, and capture
only), decoding full 1728×1118 Zlib frames. The off-console platform probe and
these server checks are separate: the existing user's running server must be
restarted before testing this build through Screen Sharing while locked.

## Limits

This is access to the same existing user desktop, not native Screen Sharing's
account-selection service. It does not create sessions, log in another account,
show the physical loginwindow, or operate before FileVault unlock. A simple lock
that keeps a lock overlay inside the same GUI session can differ from moving
the user off-console; separate macOS versions and lock configurations still
need validation. Clipboard and application drag/drop while off-console have
not been independently verified.

Creating Apple's private type-4 virtual display while already off-console was
rejected in a separate feasibility test. It is unnecessary for the successful
path above and is not part of the implementation.
