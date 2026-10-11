# AppKit file-promise compatibility

Investigation: 2026-10-11, macOS Tahoe 26.6.2 (25G83).

**Use completed local files as the default delivery format. A pure AppKit file
promise is not a generally compatible replacement for Finder file drops.**
The evidence is strongest for the inspected Terminal, iTerm2, Chromium, and
Java/AWT paths. Lark-specific and standalone ChatGPT behavior still need real
application tests.

Here, a *pure promise* means `NSFilePromiseProvider` plus an asynchronous
`writePromiseToURL:completionHandler:` callback. It supplies neither a real
`public.file-url` nor inline PNG/text bytes. Success requires the receiver to
request the file, wait for completion, and consume its bytes. A copy cursor,
filename, or nonexistent path does not establish compatibility.

## Application matrix

| Application / target | Pure AppKit promise assessment | Evidence and limits | Delivery to plan for |
| --- | --- | --- | --- |
| Terminal 2.15 (470.2), terminal input view | Rejected by the inspected type gate | Installed binary: `TTView.draggingEntered:` accepts filenames, file URLs, strings, or colors. A pure provider has none of those types. No live Terminal test: the computer-use tool blocks Terminal interaction. | Stage the file, then drag a file URL; normal terminal behavior inserts a path. |
| iTerm2, normal terminal input view | Not supported by the inspected source path | Upstream `PTYTextView` registers file URLs, strings, PNG, and TIFF. Its normal drop handler reads file paths or text, without requesting promised files. iTerm2 is not installed here. | Stage then drag a file URL. Kitty-protocol handling and remote-upload options are separate features. |
| Chrome web content: DOM drop zone / file input | Pure provider has no usable file on the inspected Chromium path | The view registers ordinary URLs/text/HTML/RTF and Chromium types. Conversion reads real files or bytes already on the pasteboard; it does not call `NSFilePromiseReceiver`. Chrome 154.0.8037.98 has no receiver class/selector references in its framework. Automated cross-app gestures did not complete; this is static evidence, not a live Chrome rejection. | Stage then drag file URLs. Inline image data is a separate optimization to test. |
| Lark message attachment composer | Not established; expect the file-URL fallback | Installed Lark Framework 147.0.7727.149 is Chromium-based. No receiver class, `receivePromisedFilesAtDestination`, or legacy `namesOfPromisedFilesDroppedAtDestination` references were found there. This does not prove the behavior of every Lark-native view. No composer transfer was completed. | Stage then drag file URLs. Test file and image attachment surfaces separately. |
| Installed app displayed as ChatGPT, `com.openai.codex`, 26.1002.52244 (13536) | Not established; expect the file-URL fallback | This is a Codex shell with Chromium framework 155.0.8059.27, not an independently identified standalone ChatGPT installation. Its framework has no promise-receiver references. No attachment transfer was completed. | Stage then drag file URLs, subject to the composer's restrictions. |
| Standalone ChatGPT macOS app | Unknown | No separate `com.openai.chat` installation was found. Do not infer a native app's behavior from the installed Chromium shell. | Keep the file-URL fallback; test the actual app/version before enabling promises. |
| IntelliJ IDEA, standard editor/project targets | No usable file-list promise path found in standard JBR/AWT | JBR registers `NSFilesPromisePboardType`, but copies raw pasteboard data. Its file-list mapping is `CF_FILE` → `NSFilenamesPboardType`; Java `isFileFormat` accepts only `CF_FILE`. No fulfillment call was found. IDEA is not installed here; plugins and embedded JCEF views may differ. | Stage then drag file URLs. Test editor open, project-tree import, and terminal separately. |
| Finder / desktop | Existing native helper works according to the user; replacement helper still needs testing | Existing server uses Apple's legacy helper. That success does not automatically validate a new `NSFilePromiseProvider` source. | Retain the working native path while evaluating a replacement. |
| Probe's own `NSFilePromiseReceiver` view | One real TXT drag fulfilled and read successfully | Recorded filename request → write request → delayed completion → receiver callback. All 58 text bytes were checked. This is a reference test, not app compatibility. | Reference for source-helper validation. |

## Why apparent promise support is misleading

**Chromium's “promised file contents” path is not the AppKit file receiver
protocol.** `PopulateDropDataFromPasteboard` looks up
`kPasteboardTypeFilePromiseContent`, then requests bytes under the content UTI.
If the bytes are already available, it can create web drop data. A pure
`NSFilePromiseProvider` offers metadata and needs a destination/write callback;
it does not provide those bytes. Adding an inline image flavor could help image
cases, but that is a different implementation and needs target-app testing.

**Java registration is not fulfillment.** JBR's `CDropTarget.m` includes the
legacy promise type in a broad registration list. `copyDraggingData:` simply
calls `dataForType:`. Its data transfer code maps file lists to existing
filenames. Registration alone does not give IDEA a usable `javaFileListFlavor`.

**Terminal has unrelated outgoing promises.** Profile/workspace settings
controllers export promised files. Those symbols do not mean the terminal input
view accepts them; that view has its own explicit acceptance gate.

## Probe and validation

[`probe-appkit-file-promises.m`](../scripts/probe-appkit-file-promises.m) provides
promised TXT/PNG and existing local TXT/PNG cards. The promise writer waits
800 ms before completing. Its reference view uses `NSFilePromiseReceiver`.
Only synthetic content is created in a private temporary directory; the general
clipboard is not changed. Delegates stay alive for delayed requests, and files
remain available after a drag for targets that read them later.

Captured drag pasteboards confirm `has_file_urls=false` for pure promises.
Ordinary file cards have `has_file_urls=true`, with `public.file-url` and legacy
filename flavors. Logs include actual types, filename/write requests, write
completion, and drag result.

Build and run locally:

```sh
xcrun clang -fobjc-arc -Wall -Wextra -Wno-unused-parameter -framework AppKit \
  scripts/probe-appkit-file-promises.m -o /tmp/vnc-file-promise-probe
/tmp/vnc-file-promise-probe
```

The executable prints its scratch directory and saves `events.jsonl` there.
This is a manual test tool, not an automated app test. The
[local browser fixture](../scripts/file-promise-drop-target.html) contains a DOM
drop zone and native file input. It displays readable file size/content, makes
no uploads, and disables network connections through its content policy.

The [recorded trace](measurements/appkit-file-promises-2026-10-11.jsonl) separates
the successful reference TXT run from later incomplete/cancelled gestures.
The receiver got and verified these exact 58 bytes, including the final newline:

```text
mac-vnc-server synthetic file-promise compatibility test.
```

Cross-window automation did not reliably finish. Later reference gestures were
also incomplete; those attempts cannot establish rejection by Chrome or any
other app. A private-pasteboard-only experiment constructed receivers and
requested filenames but did not fulfill without a real drag; it was discarded.
No completed PNG transfer or live common-app matrix is claimed. The source
compiles cleanly with the warning flags above.

For the manual matrix, compare promised TXT/PNG with the matching local-file
control in the same app surface. Confirm actual content can be opened or
attached after completion. Attachments may upload before a message is sent;
use only synthetic fixtures in a disposable draft/self-test destination. Then
test slow transfers, cancellation, multiple files, and folders.

## Consequence for mac-vnc-server

Keep transfer and destination drag separate: receive selected files into an
authorized staging directory, wait for successful publication, and then offer
real file URLs through an AppKit source. This fits the inspected
terminal/Java/Chromium paths without relying on file-promise receivers. Actual
app validation and a retention policy remain necessary.

A promise source can remain an optimization for a known accepting receiver,
including Finder after a replacement-helper test. Do not select it merely from
a bundle ID or promise symbol. Switching representations after release cannot
be assumed to preserve the original gesture.

These checks concern the server-side destination helper. Reverse-direction
drops remain owned by the client's Screen Sharing app. Neither the plain-URL
requirement nor encryption policy changes.

## Source evidence

These are inspected upstream snapshots, not assumed matches for every installed
release. Git blob IDs identify retrieved content. Subsequent curl requests used
the macOS HTTPS system proxy `http://127.0.0.1:7999` as requested. Commit-history
requests through it returned HTTP 403; no commit hashes are inferred.

- [iTerm2 PTYTextView.m](https://github.com/gnachman/iTerm2/blob/master/sources/TerminalView/PTYTextView.m),
  blob `18dc15d17998fb013e89e60ef1f3bc9dc58a5f97`: registration near line 299,
  `performDragOperation:` near line 5349.
- [Chromium WebContentsViewCocoa](https://github.com/chromium/chromium/blob/main/content/app_shim_remote_cocoa/web_contents_view_cocoa.mm),
  blob `d58fc9c26fc11de46d7fa909389af8eadec532fc`: registration near line 208.
- [Chromium WebDragDest](https://github.com/chromium/chromium/blob/main/content/browser/web_contents/web_drag_dest_mac.mm),
  blob `dc7558a3162eba8a680905d71e7347dc7c895a13`: drop conversion near line 787,
  real files/inline contents near lines 837–858.
- [JBR CDropTarget.m](https://github.com/JetBrains/JetBrainsRuntime/blob/main/src/java.desktop/macosx/native/libawt_lwawt/awt/CDropTarget.m),
  blob `2777dc1e261027628ef32123623871c0d521e04c`: registration near line 126,
  raw-data copying near line 275.
- [JBR CDataTransferer.m](https://github.com/JetBrains/JetBrainsRuntime/blob/main/src/java.desktop/macosx/native/libawt_lwawt/awt/CDataTransferer.m),
  blob `7b40de5d1357b39f71ff6c60302208713c251697`: file mapping near line 40.
- [JBR CDataTransferer.java](https://github.com/JetBrains/JetBrainsRuntime/blob/main/src/java.desktop/macosx/classes/sun/lwawt/macosx/CDataTransferer.java):
  `isFileFormat` near line 114.
- Installed Terminal arm64e: `TTView.draggingEntered:` at `0x10006072c`,
  `performDragOperation:` at `0x100060930`, and
  `readSelectionFromPasteboard:isDragAndDrop:isCommand:sender:` at `0x10005dea4`.
  The unrelated promise-export methods are at `0x100069ab8` and `0x10006a414`.
