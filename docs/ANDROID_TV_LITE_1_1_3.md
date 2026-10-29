# NAKU TV Lite 1.1.3 · build 5 — static stars and playback scheduling

The Home Display star background is restored while keeping the existing
high-definition rotating Earth, real UTC daylight/night lights and flights-only
presentation. There are no screensaver buttons, interactive effects, extra
models or new network/data layers. This build also reduces playback-side background traffic and redundant state
work while keeping the native media output path and existing features.

`NakuTVStars` freezes the original Home Display seed and spatial/color style:
soft cool-blue/warm-white points and quiet central/left regions. It omits flow,
twinkle, entrance animation, pointer/remote/drag parallax, spin response and
streaks. Positions and brightness do not depend on time, user input, Earth yaw
or solar direction.

The production helper evaluates at most 960 candidates once when the viewport
changes and uploads only visible points to a STATIC_DRAW VBO; 696 points remain
at 1280×720. The draw uses one GL_POINTS call and no per-frame geometry uploads.
It reuses the existing Earth frame cadence rather than starting another ticker.
Stars are in clip space and draw before the Earth without depth writes. The
opaque Earth then covers them completely, including its night hemisphere.

The day/night Earth material shaders are unchanged from 1.1.2, as are both exact
8192×4096 original image assets and the UTC solar helper. No new image assets,
licenses, website changes or NAS deployment are required for the starfield.

Validation:

- `python3 scripts/test_tv_stars_native.py` passes production Java geometry
  checks, including determinism, bounds, viewport/aspect handling and quiet
  text-side brightness, plus static shader/state/order checks.
- A temporary isolated WebKit WebGL1 reference uses the actual production Java
  geometry and extracted native GLSL. Changing UTC and Earth yaw changed zero
  background pixels outside the globe. Stars contributed 2,374 visible
  background pixels; toggling them for reference QA changed zero inside-globe
  pixels. No GL errors occurred.
- Reference images are explicitly labeled as references, not TV screenshots.
  Target-TV point appearance, EGL behavior and sustained rendering performance
  remain device acceptance items. Native build/package checks are separate.

Build:

```sh
flutter build apk --release --no-pub \
  --dart-define=NAKU_TV=true --build-name=1.1.3 --build-number=5
```

The TV package and release signer remain unchanged for an overwrite upgrade
that retains login and records. Building this APK does not publish or activate
a remote update release.

## Playback work scheduling and state delivery

TV post-ready route comparisons, optional quality upgrades, next-episode
warmup and speculative cache prefetch wait for at least 30 seconds of actual
wall-clock buffer reserve and eight seconds of stable playback progress.
Buffering, pause, seeking, an auxiliary sheet and backgrounding withdraw this
permission and cancel only optional work. Initial stream resolution, original
NAS playback, initial HLS selection, foreground segment reads and failure
recovery are not gated. A high-bitrate stream with a bounded byte cache may
never meet the optional-work threshold; this deliberately keeps bandwidth for
the current stream rather than lowering its picture quality.

The cache's permission is separate from its buffering state. A pending segment
already promoted to foreground playback is protected. A cancelled speculative
request can still fall through to a fresh successful foreground read. Real HTTP
regressions cover both orderings of this cancellation race.

Hidden optional-probe progress no longer rebuilds the native video surface.
TV history is saved periodically at fifteen seconds and immediately on pause
and exit. Native IDLE errors retain the user's authoritative play/pause intent
for recovery, including an explicit pause made just before an error.

Native Media3 sends changed state fields only and Dart applies a single coherent
state update per changed packet. The playing clock stays at 250 ms for caption
progress; intentful buffering updates at one second. Paused, stopped, hidden,
background and unsubscribed sessions stop polling, while seek, completion,
first-frame, cues and error callbacks remain immediate. Resume/reattach/relisten
replays full state, selected tracks and captions. A deterministic sixty-second
fixture reduced serialized state fields from 2,160 to 487; that is a message-work
measurement, not an observed TV frame-rate improvement.

Video remains hardware MediaCodec to a true SurfaceView with Android's HDR,
Dolby/audio capability handling and seamless-only frame-rate strategy. This
change does not force decoder queue modes, tunneling or display mode switches.
Actual color accuracy, motion cadence, playback stalls and device-specific
behavior still require testing on the Huawei screen.
