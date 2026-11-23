# VM VideoToolbox connection leak and loginwindow stalls

The immediate loginwindow delay is confirmed: the guest's
`AppleVideoToolboxParavirtualizationDriver` has exhausted its attached-client
capacity. Inspection of the installed driver strongly identifies a cleanup
defect: its `clientClose()` unregisters guest UUIDs but does not terminate or
detach the user-client service. Process death uses this same close path.
Closed connections can therefore leave attached kernel objects behind.

This is a guest driver lifecycle problem. It does not establish which past
applications contributed each orphaned object. No server restart, service
shutdown, physical session switch, or VM restart was performed in this audit.

## Environment and evidence

- Guest: macOS 27.2.1, build 26B131; arm64 Virtualization.framework VM.
- Kernel: `xnu-13432.41.4~25/RELEASE_ARM64_VMAPPLE`.
- Loaded driver: `com.apple.driver.AppleVideoToolboxParavirtualization`, version
  15.0.0, UUID `801F4EE5-B9B4-38B2-9F03-A6DC92B14537`.
- Guest boot time reported by `kern.boottime`: 2026-11-17; investigation:
  2026-11-24, Asia/Shanghai.

IORegistry held **1,020** attached user-client objects. A diagnostic enumerated
Mach port metadata in **908 readable processes**, using `task_read_for_pid`,
`mach_port_space_info`, and `mach_port_kobject_description`. It found only **10**
unique live connections to this driver. Their registry IDs exactly matched the
10 objects with retain count 5. The other **1,010** objects all had retain count
4 and no live process connection was found for them. No process was wholly
unreadable; 1,654 individual port metadata queries failed, so this is not an
atomic, perfectly exhaustive port snapshot. The exact agreement between live
connection IDs and the extra-reference objects corroborates orphaned objects.

The live connections belonged to WebKit GPU, VTEncoderXPCService,
VTDecoderXPCService, VirtualBuddyGuest, mediaanalysisd, photolibraryd,
PhotosReliveWidget, avconferenced, ControlCenter, and storagekitd. Neither the
running VNC user worker nor user replayd held a connection to this driver.
Live ownership does not identify who created the orphaned objects.

`ioclasscount AppleVideoToolboxParavirtualizationUserClient` reported **1,056**
allocated instances in a later snapshot. This counts instances beyond the
1,020 attached objects and must not be used as the exact attachment threshold.
Only the attachment count controls this particular stall.

The requested seven-day log query retained 246 successful decoder creation
events and 246 finalization events, with usable records starting November 23.
It is not a complete history since boot. Matching decoder finalizations do not
imply that the underlying per-process IOKit connection object was detached.
The earliest retained attachment stall was at 03:29:07.829 on November 24.

## Installed binary cleanup path

The driver was inspected from a read-only copy of this VM's boot kernelcache.
Its UUID matches `kmutil showloaded`. No installed binary was modified.

The decoded kernelcache SHA-256 is
`b9dd1cdf46a499b43fbd2a304ee0da2a2311bfbde5f7bc7bd1cf1e3b9c4b8142`.
Local evidence, including disassembly and vtable mappings, is saved under
`.build/investigation/decoder-leak-*`.

`AppleVideoToolboxParavirtualizationUserClient::clientClose()` at unslid address
`0xfffffe0008a44b98` has the following effective control flow:

```cpp
auto *driver = OSRequiredCast(AppleVideoToolboxParavirtualizationDriver,
                             getProvider());
return driver->deregisterAllGuestUUIDsForUserClient(this);
```

The virtual call was resolved against the installed vtable: offset `0x6b0`
is `IOService::getProvider()`, not a termination operation. The cast resolves
through the `OSMetaClassBase::requiredMetaCast` import. The final branch enters
`deregisterAllGuestUUIDsForUserClient` at `0xfffffe0008a47654`.

That method runs a work-loop block which removes the client's UUID records,
notifies the host to forget those UUIDs, frees temporary bookkeeping, and
returns success. The inspected path has no call to the client's `terminate()`
or `detach()` methods. The inherited `IOUserClient::clientDied()` at
`0xfffffe000a777254` dispatches to the same `clientClose()` method. Exiting the
application therefore does not provide a separate detach path.

The generic IOKit open path attaches the user-client service to the driver.
The generic close path calls the subclass's `clientClose()`; it does not
automatically replace the missing service termination. These semantics are
also visible in Apple's published
[IOService.cpp](https://github.com/apple-oss-distributions/xnu/blob/main/iokit/Kernel/IOService.cpp)
and [IOUserClient.cpp](https://github.com/apple-oss-distributions/xnu/blob/main/iokit/Kernel/IOUserClient.cpp).

This is strong static and live-state evidence of a missing cleanup operation.
A successful, isolated open/close reproduction on a fresh guest remains to be
performed locally; the current guest is already full and rejects new opens.

## Why the delay is 15 seconds per attempt

The installed kernel's `IOService::attach()` at `0xfffffe000a6e8440` compares the
provider's child count with `0x3fb` (1019). When there are more children, it logs
`stalling for detach`, then waits with a deadline computed as 15 times the timer
frequency. Thus 1,020 attached children make a new open wait for a detach.
This threshold was verified in the installed kernel binary, in addition to the
published XNU source checked in the earlier investigation.

The observed loginwindow request hits this twice: SecurityAgent tries to open
the decoder, then its fallback VTDecoderXPCService tries again. Each waits about
15 seconds. Normal UI initialization plus these waits explains the roughly
32-second console transition. macOS Control Center encounters the same path.

An unprivileged standalone probe, PID 27561, reproduced the exhaustion without
VNC, capture, video decoding, or session switching in the probe:

```text
uid=501 attached_before=1020
open_result=0xe00002c7 description=(iokit/common) unsupported function elapsed_s=15.002
attached_after_open=1020
attached_after_close=1020 delta=0
```

The last label is the probe's common end-of-attempt snapshot; no close was
needed because the open failed. A separate snapshot after the probe exited
still reported 1,020 attachments. The running VNC server was left untouched.

## Independent reports and mitigation

Two public reports describe the same accumulation in Virtualization.framework
guests and mitigation in Chromium/Electron test workloads:

- [PwrAgent PR 1168](https://github.com/pwrdrvr/PwrAgent/pull/1168) reports growth
  of 176 instances in a suite run, reduced to 3 by disabling accelerated video
  decode and encode. Disabling GPU rendering alone did not reduce the growth.
- [PwrSnap PR 366](https://github.com/pwrdrvr/PwrSnap/pull/366) reports growth of
  143 instances in its control run, zero in its mitigated run, and stable counts
  across ten subsequent suite runs.

These are third-party measurements, not local verification or an Apple
acknowledgement. Their symptoms and connection-lifecycle explanation agree with
the local binary inspection and orphan counts. They do not identify which
applications produced this VM's old objects.

For Chromium/Electron automation, the reported mitigation is to pass both:

```text
--disable-accelerated-video-decode
--disable-accelerated-video-encode
```

Those flags reduce new driver use in those processes. They do not reclaim
existing objects, apply to all macOS applications, or repair the driver. This
Swift VNC server has no Chromium/Electron launch site to which they can be
applied. Its capture output and RFB compression do not directly initialize a
VideoToolbox decoder. The evidence does not establish that earlier capture
testing had no indirect contribution through other system processes.

A guest restart should clear accumulated kernel objects. Testing a single
open/close after a future restart would verify this driver lifecycle defect
locally without running a workload to exhaustion. A driver fix is needed for
complete prevention; this investigation has not verified a fixed OS version.

### Release status checked on 2026-11-24

[Apple's release listing](https://support.apple.com/en-us/100100) identifies
macOS 27.2.1 as the latest public release. The
[Apple update catalog](https://gdmf.apple.com/v2/pmv) includes this guest's exact
27.2.1 / 26B131 build. `softwareupdate --list --product-types macOS` offered no
newer macOS version; its only listed update was Command Line Tools for Xcode
27.2. The affected guest is therefore already on the latest public macOS release
applicable to it. The installed-driver evidence above confirms that the problem
persists here.

[macOS 27.3 Beta 2 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-27_3-release-notes)
do not document a fix for this leak. That omission does not prove the beta is
affected: its driver binary and runtime behavior have not been tested.

For current-version mitigation, restart the guest itself to reset the kernel;
suspend/resume preserves its state. Apply both codec-disable switches to
frequently relaunched Chromium/Electron processes, and reuse browser processes
in automation when practical. Software decoding/encoding can increase CPU use
and reduce video performance. Other applications can still open the driver:
[a later PwrAgent report](https://github.com/pwrdrvr/PwrAgent/pull/1827) observed
19 more instances across two full test lanes despite the codec switches.
These switches reduce growth; they do not guarantee zero growth system-wide.

The default invocation of the probe below gives the attached count without
opening a driver connection. A conservative operational warning level such as
800 attachments leaves room below the verified 1,020 limit; it is a suggested
maintenance margin, not another driver threshold. Do not use `--open-close` as
a monitoring command. The latest count-only check still showed 1,020 attached
objects. No updates, reboots, or application launch settings were applied.

## Small reproduction tool

Source: [`scripts/probe-videotoolbox-lifecycle.c`](../scripts/probe-videotoolbox-lifecycle.c).
The default invocation only counts attached objects. `--open-close` opens and
closes exactly one connection, submits no media or driver methods, then waits
two seconds for asynchronous cleanup. It reports any new IDs still attached.
Concurrent application activity can also change the count, so compare the IDs.
There is no need to run hundreds of iterations.

```sh
mkdir -p .build/videotoolbox-probe
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun clang -O2 -Wall -Wextra -framework IOKit -framework CoreFoundation \
  scripts/probe-videotoolbox-lifecycle.c \
  -o .build/videotoolbox-probe/probe-videotoolbox-lifecycle

# Read-only count, also useful after the probe exits:
.build/videotoolbox-probe/probe-videotoolbox-lifecycle

# One connection lifecycle test; on the exhausted guest this takes ~15 seconds:
.build/videotoolbox-probe/probe-videotoolbox-lifecycle --open-close
```

The diagnostic built without warnings. Its one attempted open reproduced the
15-second failure; the default read-only count also passed. This is a diagnostic
binary, not a new VNC release, and does not change `.build/release-latest`.
