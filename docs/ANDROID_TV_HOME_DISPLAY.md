# Android TV Home Display

Android TV opens `CinemaTVHomeDisplay` with `CinemaTVEarth` as its actual
full-viewport background. The normal presentation keeps the requested
high-definition, slowly rotating Earth using a native OpenGL ES renderer; it
is not a static-image replacement. A compact, noninteractive overlay contains
a minute clock/date and at most three actual flights from the authenticated
read-only Home Display feed. Parcels, next-destination cards, buttons, wake
hints, extra 3D models and decorative effects are omitted.

The native Earth uses the bundled high-definition globe texture, a bounded
sphere mesh and a controlled rendering cadence. It does not load the website,
create WebGL, capture screenshots or drive Flutter's animation ticker. A local
static globe is only the startup/render-failure fallback; render failures are
labeled on-screen rather than represented as successful rotation. The desktop
implementation remains `CinemaHomeDisplayPage` with its existing first-party
website and native bridge.

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
both dimensions. The native Earth is aspect-correct and framed toward the
right, leaving the left side for compact flight text. The TV screen does not
inherit CSS, web loading state or desktop-sized native-view bounds.

Only real origin/destination points marked drawable and containing valid
latitude/longitude can create route arcs. The UI passes at most eight normalized
routes to the renderer, without private flight notes, booking references or
invented endpoints. These arcs represent supplied flight routes. An optional
small 2D point uses an actual finite position only when the feed marks it live
or last-known and the flight is not a route preview. Estimated/interpolated
positions and decorative aircraft models are excluded.

Snapshot polling runs every sixty seconds; the clock updates once per minute.
Backgrounding cancels both timers, sets the native Earth inactive and ignores
stale in-flight completions. Resuming reactivates the Earth, refreshes the clock
and requests a fresh snapshot. Disposal cancels all page timers and releases
the native Earth view. The TV app owns immersive system bars.

Unavailable flight data does not block the locally rendered rotating Earth or
clock. No network connection is required to rotate the bundled globe.
Network failures retain a previous real snapshot with its synchronization time
and a stale/offline label. A NAS authorization failure clears that snapshot.
Demo data is rejected. Empty real data is reported as empty, without fabricated
flights. UTC flight times are explicitly labeled UTC. The NAS tab's
separate active-state protection prevents hidden retained tabs opening QR UI.

## Validation boundaries

Native widget tests check complete extents at 960×540, 1280×720 and 1280×360,
full-viewport native-Earth wiring with an injected rendering probe, absence of
buttons/filters/decorative effects, flights-only supplied-record projection,
verified route bounds, maximum item count, minute polling, background/native
active-state cancellation, stale completion and wake behavior. The rendering
probe is a widget-test substitute, not proof of real OpenGL output. Authorization/session tests cover response scope, expiry,
cookie validation, fixed endpoint, response bounds and logout races. The
existing desktop WebView rendering/exit tests remain separate.

Physical remote operation, real NAS authorization, actual Home Display records
high-definition Earth rotation, real route arcs and sustained GPU performance
on the target Huawei TV remain manual acceptance items. Passing local tests does not count as those checks.
