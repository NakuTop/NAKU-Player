# Android TV Home Display

Android TV opens `CinemaTVHomeDisplay` with `CinemaTVEarth` as its actual
full-viewport background. The normal presentation keeps the requested
high-definition, slowly rotating Earth using a native OpenGL ES renderer; it
is not a static-image replacement. A compact, noninteractive overlay contains
a minute clock/date and at most three actual flights from the authenticated
read-only Home Display feed. Parcels, next-destination cards, buttons, wake
hints, extra 3D models and interactive effects are omitted.

The native Earth uses the exact original 8192×4096 day and historical-night
textures, a bounded sphere mesh and a controlled rendering cadence. It selects
the highest complete day/night tier that fits the GPU texture limit, current
available memory and bitmap heap budget; allocation failure retries both maps
together at 4096 then 2048, rather than retaining only a day map. It does not load the website,
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

## Fixed sky with bounded twinkle (1.1.6)

The original Home Display starfield keeps its deterministic spatial distribution,
cool/warm palette and soft point cores. Since 1.1.6 the points are larger and
brighter and gently vary between 60% and 100% of their base light, with periods
of about 7–20 seconds. Their positions never move with the Earth or input. The
original entrance, pointer displacement, interaction spin and streaks remain
omitted. The text side is quieter for readability.

At most 960 candidates are evaluated once per viewport/context change, with
696 visible points at 1280×720. A static VBO is uploaded only then. A single
GL_POINTS pass runs behind the opaque globe, restores depth/blend/cull state,
and receives only viewport point scale and a bounded twinkle phase. The phase
uses the existing monotonic active-frame delta and a seamless two-minute loop;
there is no extra timer, buffer upload, geometry generation or network work
per frame. Backgrounding stops the existing at-most-24fps render loop.

## Atmosphere, clouds and old-TV rendering budget (1.1.6)

A thin blue atmosphere follows the solar direction, with a softer warm edge
near the terminator. It is one four-vertex analytic pass, not another sphere,
ray marching, bloom or a blur render target. The surface computes its ocean
mask in the original sRGB texel space, before the dark blue values collapse
in linear light, and uses a restrained solar glint.

The other clients' original `clouds-2048.jpg` is bundled unchanged as
`assets/images/tv_earth_clouds_2k.jpg` (2048×1024, SHA-256
`daddaad84d7a33bbbc86cdda3f591099f57cee8607b7bcf3b67eb7e4f7a1c793`).
It is an historical texture, not live weather. Coverage is composited into the
existing sphere shader without another rotating model or animation loop. The
optional cloud texture needs about 20 MiB during upload; failure leaves
the original required day/night pair intact. Supported anisotropic filtering
is capped at 4×.

Only the screensaver framebuffer is capped at 1920×1080 on low-RAM devices or
heaps of at most 256 MiB; it still fills the entire actual TV view. The separate
Media3 video SurfaceView and its resolution/HDR path are unaffected. Original
8K day/night sources and their adaptive paired allocation policy are retained.

## Real UTC day/night surface

`NakuTVSolar` ports the original Home Display NOAA approximation and calculates
the Earth-fixed solar direction from absolute UTC time. It does not use the
television's display timezone, camera angle or rotation counter as a substitute
for solar time. The native geographic basis is the original site's basis
rotated by minus ninety degrees around Y; both use the same latitude/longitude
and texture geography.

The surface shader computes daylight from the unrotated local geographic
normal. View rotation therefore changes which continent is visible without
moving the real day/night boundary relative to that continent. The transformed
world normal and sun are used only for view-dependent ocean glint and the limb.

The day texture is decoded from sRGB before lighting. The night texture remains
raw data: its red channel supplies the original historical 2016 VIIRS light
mask, with warm emission only on the astronomical night side. The original
surface's terminator softness, dim night tint, twilight and light-mask
constants are retained, with the restrained ocean changes above, followed by the Three/R3F ACES display transform and
sRGB output. City emission is a historical image, not a live report of a city's
power supply. Atmosphere and cloud appearance use the bounded passes above;
controls and unrelated data layers remain omitted from this flights-only TV surface.

Both texture resources are required for normal initialization. Missing or
invalid resources produce the existing explicitly labeled render-failure
fallback; the app does not claim a working day/night pair while silently using
only the day map. APK checks must verify both original image files.

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
probe is a widget-test substitute, not proof of real OpenGL output.
Authorization/session tests cover response scope, expiry, cookie validation,
fixed endpoint, response bounds and logout races. The existing desktop WebView
rendering/exit tests remain separate.

Independent UTC comparison checks the Java solar helper against the original
Home Display equations and coordinate conversion. A separate temporary WebGL1
reference can compile the exact native vertex/fragment shaders and original
8K maps to inspect two UTC times at the same view angle. This validates shader
logic and geography in a different GL implementation; its output is explicitly
a reference, not an Android TV screenshot or performance acceptance.

The production Java star helper has JVM checks for deterministic bounded
geometry, viewport handling and text-side brightness. Wiring checks permit only
point scale and the bounded twinkle phase, rejecting input/Earth-matrix uniforms
and per-frame generation/upload. The exact production shaders and geometry
are also exercised in a temporary WebGL1 reference at two UTC times and
different twinkle phases. This is not proof of Android driver behavior or FPS.

Physical remote operation, real NAS authorization, actual Home Display records,
high-definition Earth rotation/day-night output, atmosphere/clouds/twinkling-star appearance,
real route arcs and sustained
GPU performance on the target Huawei TV remain manual acceptance items. Passing
local tests or offscreen reference checks does not count as those checks.
