# NAKU TV Lite 1.1.2 · build 4

This correction restores the original Home Display's real UTC-driven day/night
surface and original highest-resolution day/night assets. It keeps the native
rotating globe, flights-only content and absence of buttons/extra models from
1.1.1. Native Media3 playback, ratings, account synchronization, subtitles,
danmaku and future software-update behavior are unchanged by this correction.

## Geographic daylight and night emission

The original Home Display NOAA solar approximation is ported into the pure Java
`NakuTVSolar` helper. Absolute UTC time determines the subsolar direction. The
surface uses Earth-local normals so visual rotation does not change whether a
particular geographic location is in daylight. Daylight is not a fixed studio
lamp or a periodic cosmetic brightness change.

The original day map is converted from sRGB for lighting; the original night
map is sampled as raw VIIRS emission data. The surface retains the original
terminator, dusk tint, ocean glint and warm night-light constants, with the
Three/R3F ACES/sRGB display transform. Night lights appear only on the
astronomical night side. Their historical 2016 dataset does not represent live
electricity activity. No city lights or flight data are randomized.

## Original image assets and resource policy

Both committed app files are byte-identical to the original Home Display:

| Role | App asset | Dimensions | SHA-256 |
| --- | --- | --- | --- |
| Day | `assets/images/tv_earth_day_8k.webp` | 8192×4096 | `d4794d265d8cb88061cf0ded024ab84e5ce8bd6de0ea8a3c23d8a7ff1a8f5a99` |
| Night | `assets/images/tv_earth_night_8k.webp` | 8192×4096 | `1ae3487286e9ecedaecc8a0e1601c4fef7c005828019d2b7bb63a0b72ebae694` |

The highest safe complete pair is selected from 8192, 4096 and 2048 according
to the actual GPU limit, available RAM and bitmap heap budget. An allocation
failure discards both texture IDs and retries the lower pair. This preserves
both day and night rather than dropping the night map to keep a higher day-map
number. A missing/corrupt required asset uses the existing labeled render-error
fallback. Actual selected resolution is hardware-dependent; bundling an 8K
source is not a claim that every old television can upload it at 8K.

## Verification and its limits

The Java solar result was independently compared with the original equations
and basis conversion over 206 UTC cases, including leap day, equinoxes and
solstices. The maximum component difference was below `8e-16`. Both committed
images matched the original bytes and dimensions.

A temporary, isolated headless WebKit WebGL1 reference compiled the exact
native shader strings and used the actual 8192×4096 images. Two references at
2026-10-29 06:00 and 18:00 UTC used the same view/yaw. The resulting geography,
terminator and warm night lights were visually inspected, with no GL errors.
A black-mask comparison changed 27,960 significant pixels, including 27,780 on
the night side, and changed none of 9,056 strict-day pixels. This checks that
the emissive map is masked out of daylight.

Those images are labeled native-GLSL references, not television screenshots.
They validate the shader on a different GL implementation and do not establish
old-Huawei EGL compatibility, texture-memory acceptance, sustained frame rate,
actual screen colors or live NAS data. Final APK checks and target-device
manual acceptance remain separate.

## Build

```sh
flutter build apk --release --no-pub \
  --dart-define=NAKU_TV=true --build-name=1.1.2 --build-number=4
```

The app ID and release signer remain unchanged for an overwrite upgrade that
retains login and records. Building or generating the dedicated update feed
does not publish a release, activate a remote distribution channel or change
the website/NAS deployment.
