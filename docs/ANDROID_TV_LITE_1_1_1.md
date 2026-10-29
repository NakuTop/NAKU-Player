# NAKU TV Lite 1.1.1 · build 3

This correction restores the user's required high-definition rotating Earth.
The 1.1.0 static-only presentation did not satisfy that requirement. The normal
TV screensaver now renders a slowly rotating native OpenGL ES sphere using the
bundled high-definition Earth texture. It keeps the lightweight TV shell and
native media playback changes from 1.1.0.

The Home Display overlay is flights-only: a noninteractive clock/date and up
to three actual authenticated flight summaries. Parcel/destination cards,
buttons, wake hints, decorative models and unrelated display layers are removed.
At most eight verified origin/destination coordinate pairs from those real
records may be passed to the native globe as route arcs. An optional small 2D
point retains only actual live/last-known, non-preview coordinates. Estimated
and interpolated positions are excluded; there are no aircraft models. Missing
endpoints never borrow an arbitrary city or fabricated position.

The Earth fills the route viewport, stays aspect-correct and is framed right
of the flight text. Native rendering avoids the website's WebGL/runtime cost.
The controlled GPU rendering cadence is separate from the minute clock and
sixty-second authenticated data polling. Backgrounding stops page polling and
sets the Earth inactive; disposal releases its native view. The root still owns
ten-minute idle detection, playback protection and first-key/repeat swallowing.

The local static globe is retained only until native startup or if native
rendering fails. Failures are labeled honestly. Offline flight data does not
turn the normal rotating globe into a static-only screen and does not generate
demo flight records. NAS authorization and the website remain unchanged.

The application ID and release signer remain the same so 1.1.1 can overwrite
1.0.0/1.1.0 while retaining login and records. Build with:

```sh
flutter build apk --release --no-pub \
  --dart-define=NAKU_TV=true --build-name=1.1.1 --build-number=3
```

Widget tests use an injected Earth probe to check viewport, routes, flight-only
content and native active-state handoff. Such probes do not prove real GL
rendering, sharpness, rotation smoothness or old-Huawei GPU behavior. Native
compilation and APK checks are recorded separately; full-screen Earth rotation,
real NAS authorization/flight data and remote wake require physical-device
acceptance. This correction does not publish a release or activate the future
software-update feed.
