# Retained Screen Sharing 3.0 protocol fixes

These behaviors remain after removal of the old server endpoints and capture
implementations. They support the user's Screen Sharing 3.0/macOS 13.1 client and
current native clients. They are separate from general capture/encoding speedups.

| Area | Fix and effect |
| --- | --- |
| ZRLE pixel format | Screen Sharing advertises depth 32 for BGRX but consumes three-byte ZRLE compact pixels. Use that packing only for the observed Apple format, preserving Raw, Zlib, cursor and non-Apple layouts. Fixes blocky colors and tile-parser misalignment. |
| Display layout | Prefer negotiated DisplayInfo2 (1105), retaining 1101 for clients that request it. Handle SetServerScaling (message 8), preserve logical pointer coordinates and give each viewer its own scaling state. |
| Startup/resize ordering | A layout reply invalidates prior framebuffer requests and the old diff baseline. Wait for a new ordinary/automatic request, then send a full image even when pixels are unchanged. Cursor updates also wait for valid framebuffer demand. Prevents bitmap-reset races and stale/black displays. |
| Control/Observe | Advertise Control permission in extended ServerInit. Accept SetMode without artificial MiscStatus 9/10 acknowledgments or timed permission changes. Repeated requests are idempotent; Observe releases held input. The client can still restore Observe from saved state. |
| Encrypted input | Parse Apple's EncryptedInputEvent (message 16) independently of record encryption. Decode its key/pointer fields using the authentication or rekeyed session key, including with plaintext frames. Prevents the unsupported-message disconnect and lost input after type-30 login. |
| Clipboard | Accept zero-length empty-pasteboard headers without inflating nonexistent data. Fetch promised text/image contents, suppress duplicate notifications/echoes, and defer fetches while a new image is pending instead of replaying stale text. Preserve supplied image formats, including GIF. |
| File-transfer capabilities | Screen Sharing can omit the FileCopy capability bit while implementing transfers. Gate on negotiated drag/request capabilities and Control, then require authorized sources or staging batches for actual transfers. Handle native file-copy messages and optional AES records on plain URLs. |
| Mouse and keyboard mapping | Translate Apple's right/middle button order to standard RFB order and map the Apple client's Alt keysyms to macOS Command. |
| Authentication timing | Keep the short handshake/message deadline while allowing up to 120 seconds for security selection and human password entry. Partial responses do not extend the long wait indefinitely. |
| Desktop identity | Send the kernel's short hostname in ServerInit, rather than the common `mac-vnc-server` label or Foundation's Bonjour-resolved name. This fixes the title; existing Keychain conflicts still need client-side resolution. |

All current connections use macOS username/password verification with ARD
security type 30. The old type-2 shared-password and unauthenticated endpoints
have been removed. `--no-encryption` controls session records; it does not remove
the credential exchange or Apple's separately wrapped input messages.

The Observe-mode work does not force Control, enable Shared Clipboard, or erase
saved client preferences. Screen Sharing owns those choices. The hostname change
does not repair a duplicate Keychain item automatically; the user's earlier log
reported `SecKeychainAddInternetPassword: -25299` (duplicate item).

Socket tests cover the individual wire behaviors. Native probes additionally
exercise complete pixel decoding, mode restoration, scaling, RichCursor and
transfer negotiation through Tahoe's installed ScreenSharing.framework. Running
a copied 3.0 application on Tahoe still uses Tahoe's framework and does not replace
a remote macOS 13.1 test. User confirmations and limitations are recorded in the
linked investigations below.

- [ZRLE packing and full-image validation](apple-zrle-compatibility-2026-10-12.md)
- [Apple display, mode, input and file protocol investigation](apple-file-transfer.md)
- [Clipboard messages and user verification](apple-clipboard.md)
- [Current account listener](account-session-listener.md)
