# Android TV Home Display

Android TV opens `CinemaTVHomeDisplay`. It renders a full-viewport local earth
bitmap, a minute clock/date, and at most three actual flight, parcel or next
destination summaries from the existing read-only Home Display feed. It creates
no WebView or WebGL renderer and uses no blur, screenshot readback, frame ticker
or decorative animation. The desktop implementation remains
`CinemaHomeDisplayPage` with its existing first-party website and native bridge.

The TV shell owns ten-minute inactivity detection, playback protection and
held-key suppression through key-up. The display's `onWake` callback is a
notification: pointer or standalone-key wake then pops the page. The shell's
early remote handler consumes the first waking key and repeats, restoring the
original page/focus without activating its focused action.

## Authorization and wire compatibility

`CinemaNASClient.call('homeDisplaySnapshot')` requires an already-active NAS
session. App startup owns saved-login restoration; an unattended screen does
not sign a user back in after explicit logout. It never launches a QR dialog.

Android prepares the existing encrypted current-user and machine GET proofs
and sends them only to the fixed HTTPS `/api/auth/nas/exchange` endpoint. The
exchange retains the deployed desktop wire profile (`UUID + PC-darwin`) solely
for protocol compatibility. Ordinary Android NAS identity is unchanged. The
website still verifies the encrypted requests and configured canonical NAS;
no backend authorization policy or deployment changes are introduced.

The response must contain the existing host-only, root-path Secure, HttpOnly,
SameSite=Strict authorization cookies. Their grant lasts at most approximately
five minutes. For TV these cookies remain inside
`CinemaHomeDisplaySnapshotSession` in app memory, rather than a WebView
CookieManager. The widget receives only read-only snapshot data. Cookie values,
NAS tokens and proof values never cross that widget-facing contract or logs.

The snapshot client reads only the fixed HTTPS `/api/display` endpoint,
rejects redirects and caps the response at 1 MiB. It refreshes a grant near
expiry and invalidates pending work on logout/account change. Late responses
cannot restore data under an expired session. Real NAS/server authorization
still requires device acceptance; local tests do not establish live access.

## Layout, visibility and fallback

A LayoutBuilder fills the route's actual width and height. Text sizing follows
both dimensions; the static bitmap uses cover fitting. The TV screen does not
inherit CSS, web loading state or desktop-sized native-view bounds.

Snapshot polling runs every sixty seconds; the clock updates once per minute.
Backgrounding cancels both timers and ignores stale in-flight completions.
Resuming refreshes the clock and requests a fresh snapshot. Disposal cancels
all page timers. The TV app owns immersive system bars.

Unavailable data leaves the full local globe and clock visible immediately.
Network failures retain a previous real snapshot with its synchronization time
and a stale/offline label. A NAS authorization failure clears that snapshot.
Demo data is rejected. Empty real data is reported as empty, without fabricated
flights or parcels. UTC flight times are explicitly labeled UTC. The NAS tab's
separate active-state protection prevents hidden retained tabs opening QR UI.

## Validation boundaries

Native widget tests check complete extents at 960×540, 1280×720 and 1280×360,
absence of WebView/texture/filter/effect widgets, real supplied record projection,
maximum item count, minute polling, background cancellation, stale completion
and wake behavior. Authorization/session tests cover response scope, expiry,
cookie validation, fixed endpoint, response bounds and logout races. The
existing desktop WebView rendering/exit tests remain separate.

Physical remote operation, real NAS authorization, actual Home Display records
and sustained performance on the target Huawei TV remain manual acceptance
items. Passing local tests does not count as those checks.
