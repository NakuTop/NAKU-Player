# Home Display

The macOS home header and compact navigation place Home Display immediately
after NAS. It opens `https://between-us-home.pages.dev/display` in a live native
WKWebView. Website data polling, globe interactions, weather and animation remain
website-owned; the player does not add another polling loop or use a video-site
resolver, image blocker, custom user agent, forced page scale or static page copy.

The current website requests display-quality textures up to 8192 pixels on
supported desktop GPUs. WebKit retains native display scaling and the website's
adaptive rendering budget. Actual supported resolution depends on viewport,
hardware and successful asset delivery; the player does not claim that an 8K
texture was delivered merely because a setting is enabled.

## Loading and lifecycle

The page uses CinemaNeonDecode, the detail-page rounded pixel reveal. A native
platform view cannot be filtered by Flutter's child shader, so a bounded series
of in-memory native snapshots supplies the temporary reveal. WKWebView stays
mounted underneath. The snapshots and their decoded image-cache entries are
released after the reveal, on failure, on a new navigation and on disposal.
At most 24 periodic captures are attempted per document, no faster than 900 ms;
there are no steady-state captures.

Network progress 100 and document load completion do not end the reveal. The
document-start observation bridge waits for the display API, fonts/visible
images, a texture upload matching the website's loaded 2K/4K/8K Earth profile,
an actual default-framebuffer globe draw and two animation frames. Tiny
placeholder uploads do not complete the reveal; a valid base profile can finish
before an optional higher-resolution upgrade. Upload observations do not consume GPU errors or
read pixels. The bridge creates no GL context, forces no quality preference,
and never reads response bodies, credentials or personal trip fields.

Hidden time does not exhaust the native loading deadline. Returning to the
foreground retires the previous document, revalidates NAS access, then creates a
fresh document after cookie installation. This resets temporary camera/selection
state and prevents an expired-cookie response or stopped website hook from
surviving the refresh. Hidden and retired-document bridge messages are ignored.
Leaving releases the native WebView and its WebGL/polling resources.

## NAS authorization

The approved scope is every authenticated account on the configured household
NAS, with read-only Home Display access. The native `homeDisplayAuthorize`
method posts NAS session proof to the fixed website HTTPS endpoint. The website
validates the account and canonical NAS serial, then returns a five-minute
display-only HttpOnly cookie. Native code installs and reads it back in WebKit;
Dart and page JavaScript receive no NAS credential or website cookie.

The website server is trusted with credential-equivalent UGOS session proof
during exchange. The implementation uses only two fixed read endpoints and
does not persist proof. This is not a NAS-issued, audience-limited assertion.

A second HttpOnly context marker prevents an expired display credential from
falling back to an existing website owner session. Every renewal revalidates
the NAS. Native NAS logout and failed authorization remove only the display
credential; the non-authorizing context marker remains until explicit website
display logout or the WebKit session ends. Overlapping native renewals share one
exchange, and explicit NAS logout/forget callbacks wait for credential removal.
Website private APIs remain
unavailable to the display credential.

## Verification status (2026-10-26)

- Final cinema and Bangumi request regression suite: 1132 passed, 47 conditional skips.
- Native page lifecycle/readiness tests: 12 passed, including expired-credential
  resume, stale bridge responses, failed resume and hidden authorization.
- JavaScript bridge harness: 15 contracts passed, including placeholder rejection
  and independently supported 2K/4K/8K base profiles. Focused Dart analysis passed.
- Website auth/gateway regressions: 61 passed; protected-route Node tests: 11 passed;
  TypeScript check passed.
- Native proof transport and rejection fixtures passed.
- macOS Release project build passed; arm64 and x86_64 binary, strict deep
  code-signature verification passed.

Website code was deployed using the existing guarded release script with
`--keep-vars`; the configured Worker version is now
`64298fe1-51a0-4f24-9a16-1122072610b7`.
All 23 production protection/resource checks passed. Every one of the 73 client
assets retained its pre-deployment SHA-256. Existing website configuration and
private bindings were retained.

The fixed NAS origin, canonical serial SHA-256, signing secret and session
version are configured as server-only secrets. The device serial was supplied
by the user from UGOS About. Production now rejects invalid proof with the
expected generic 401, rather than reporting an unconfigured service. All 23
production protection/resource checks also passed after configuration.

A standalone native probe could not use the installed app's saved Keychain
credentials without additional authentication, so it was stopped without
exporting credentials or changing the installed player. A separate temporary
verification app accepts manual native NAS login with no credential persistence
and an isolated nonpersistent WebKit store. Live NAS proof, canonical serial
matching and HttpOnly cookie delivery passed. The user confirmed visible Home
Display with both administrator and ordinary NAS accounts. The live probe
observed 8192 by 4096 texture uploads, device pixel ratio 2 and a 2560 by 1374
canvas; private/write requests returned 403 and context-only access returned
401. This live probe preceded the final placeholder-readiness regression fix,
which is covered by the focused bridge harness.

The 3.0.1+77 source tag and formal GitHub release are published. All seven public
assets passed complete anonymous download/SHA-256 verification, and the final
ZIP signature and unchanged legacy update key were independently verified. The
signed appcast activates 3.0.1 while retaining previous versions. Installation
and final local application state are recorded separately from the live NAS
verification.

## Focused checks

```sh
flutter test --no-pub test/features/cinema/cinema_home_display_page_test.dart
node scripts/test_home_display_bridge.mjs
python3 scripts/test_nas_home_display_native.py
```
