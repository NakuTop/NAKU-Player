# NAKU TV Lite 1.1.0 · build 2

This update targets the old Huawei TV reported during manual acceptance of
1.0.0: uneven playback, incorrect colors, crowded controls and a stalled,
partially filled Home Display. The TV application keeps its independent package
`com.nakutop.nakuplayer.tv` and existing Android release signing certificate so
an overwrite upgrade retains local data and NAS login.

## TV playback

TV playback uses native AndroidX Media3 1.11.1 ExoPlayer with a SurfaceView,
MediaCodec hardware video decoding and the platform audio output path. Video
stays outside Flutter's texture/color-compositing path. Unsupported software
video decoders are excluded on this TV path so a low-powered CPU does not
silently attempt heavy 4K decoding. Other platforms retain their existing
player implementation.

Local NAS URLs bypass the proxy; authenticated headers are retained. Compatible
original-file playback is preferred and automatically falls back to an available
compatible NAS profile or source when necessary. The player preserves episode,
position and pause intent when reopening media. Buffering and display frame
rate handling belong to the native player. Online subtitles, embedded subtitle
selection and automatic danmaku matching remain available through TV controls.

Dolby Vision, HDR and Dolby audio are capability-dependent. The TV/box,
particular media profile, Android codec implementation and connected audio
hardware must support them. The native path preserves platform handling; it
cannot add unsupported Dolby hardware or licensing. No universal Dolby/Atmos
acceptance is claimed. A compatible fallback may be SDR or a different audio
output; actual output, colors and smoothness require target-device testing.

## Flat, larger TV interface

The later user instruction removes all TV effects for performance. TV uses
larger hero/poster proportions and a reduced set of permanent actions, with
static remote-focus indication. Blur, neon decoding, CRT/lamp transitions,
poster animations and decorative TV motion are disabled. Existing artwork,
poster crops and non-TV designs remain separate from this TV performance mode.

The required destinations remain search, home, movies, series, NAS, mine and
screensaver. Search uses the system keyboard. Account synchronization, NAS
connection and software updates sit within their relevant pages. The player
keeps play/pause, timeline, episodes, subtitles and danmaku; it does not expose
manual audio, quality, source or proxy menus. Same-account phone-to-TV requests
still require a TV confirmation before replacing the current playback.

Android TV Home Display now uses a native full-viewport static globe, minute
clock and the actual authenticated read-only feed, not a browser/WebGL view.
The ten-minute idle rule, playback protection and first-key wake behavior remain.
See [ANDROID_TV_HOME_DISPLAY.md](ANDROID_TV_HOME_DISPLAY.md).

## Software updates

“Mine → Software update” reads the installed TV version/build, checks a dedicated
TV feed, downloads with progress/cancellation, validates SHA-256 and exact size,
and verifies package/version/signing certificate before starting the Android
installer. Unknown-source permission is handled through system settings and
continues with the verified APK after return. It does not require a browser.

The 1.0.0 build lacks this entry, so installing 1.1.0 is the bootstrap upgrade.
The implementation and deterministic feed preparation script are ready, but
future in-app distribution requires publishing a matching official TV release
and static feed after manual acceptance. No upload, push or public release is
implied by building this APK. See [ANDROID_TV_UPDATES.md](ANDROID_TV_UPDATES.md).

## Build and validate

```sh
flutter pub get
flutter analyze --no-pub lib/features/cinema lib/pages/index_module.dart lib/pages/init_page.dart test/features/cinema
flutter test --no-pub test/features/cinema test/bangumi_search_request_test.dart
flutter build apk --release --no-pub \
  --dart-define=NAKU_TV=true --build-name=1.1.0 --build-number=2
```

Use the existing private Android release signing configuration; do not put
keystores, passwords or local.properties in source archives. The release Java
compile hook removes only generated registrations for Flutter dev-only plugins
when the installed Flutter tool leaves a debug registrant in the release tree;
production plugin registrations remain.

Run `scripts/prepare_android_tv_update.py` on the signed APK to validate its TV
package, version, launcher and certificate, then generate the correct asset
name, SHA256SUMS and publication-ready feed. This script never publishes.

Local unit/widget tests and package checks do not establish actual hardware
video decoding, correct HDR/Dolby output, NAS throughput, live QR login,
cross-device casting, update-install permission or Home Display authorization.
Record automated results and those pending device checks separately for each
built APK; do not reuse 1.0.0 acceptance as 1.1.0 evidence.
