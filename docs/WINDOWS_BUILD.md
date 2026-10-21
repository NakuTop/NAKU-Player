# Windows build

This local Windows port is based on NakuTop/NAKU-Player main at
`b182453de114c97ba853a46d2fdd59daf2f482ff`. The Windows revision is
2.8.4+58; its installer version is 2.8.4.58. Revision 52 passed user acceptance
on Windows on 2026-10-20.

Requirements: Windows x64, Flutter 3.47.6 / Dart 3.13.5, Visual Studio 2022 C++
Build Tools with recommended desktop C++ components and Windows SDK, Developer
Mode for Flutter plugin links, and Inno Setup 6.

Run `scripts/build_windows_installer.ps1`, passing `-Flutter` if flutter.bat is
not on PATH. `-OutputDirectory` selects where the installer is saved.

The installer uses the current user's local Programs folder, creates a Start
menu shortcut and offers an optional desktop shortcut. It includes the x64
MSVC runtime DLLs. Uninstall does not remove application data.

## NAS and window controls

Windows and Android share the existing Dart NAS protocol implementation. Windows
implements `naku/secure` with CNG RSA PKCS#1 v1.5, AES-GCM and current-user DPAPI.
The QR public-key wire representation matches the existing macOS/Android
implementation. QR private keys are temporary and cleared on cancellation;
session identity checks and TLS validation remain enabled. No NAS address,
account, token or password is embedded in the public source or installer.

Encrypted saved credentials live at
`%APPDATA%/NakuTop/NAKU Player/security/nas-credentials.dpapi` and can only be
decrypted under the same Windows user/machine context. Uninstall retains them
along with other app data; use the NAS page's forget-account action to remove
the saved login.

Windows always uses its native caption buttons, regardless of a saved preference
to hide the title bar. Caption hit tests and mouse events are handled by Win32
before Flutter plugin delegates. The default merged UI/platform thread is used.
WM_CLOSE still reaches the existing confirmation and tray/quit preference.

Revision 52 routes cinema, NAS and anime fullscreen through the same Win32
interface. It removes the entire non-client frame, fills rcMonitor (rather than
the taskbar-excluding work area), and restores WINDOWPLACEMENT and window styles.
Windows completes synchronously and never waits for AppKit animation events.
The video widget subtree is retained across window/fullscreen/PiP layout changes.
The Windows theme uses an opaque base and gradient panels without live backdrop
filters; its update page does not poll the macOS Sparkle bridge.

Revision 52 checks: 41 focused playback/appearance/update tests passed. Native
crypto and fullscreen tests passed. Ten native fullscreen enter/exit cycles took
106 ms in the isolated test window; this is not a video-frame-rate benchmark.
The user completed manual acceptance and confirmed that fullscreen works
correctly and playback/window transitions are smooth.

## Validation

Revision 55 validates the actual subtitle load/display chain, not just the
download. ASS and other timed text are normalized into UTF-8 SRT; drawing and
font/layout overrides are removed while bilingual text and times are retained.
The loader confirms MPV's current external filename and numeric subtitle ID.
An independent, coalesced Flutter subtitle layer follows playback time and
subtitle delay; native text-event delivery is not required for external text.
The real MPV test uses the publicly retrieved S10E02 bilingual ASS as a local,
opt-in fixture, loads it at 62.4 seconds and confirms Chinese output. The subtitle
file itself and its dialogue are not included in the repository or source ZIP.

Live ASR now consumes approximately one second at a time with four seconds of
rolling context, polls every 250 ms, and discards queued old audio. A one-second
synthetic speech excerpt was recognized in 428 ms by the persistent local
engine. Native first capture was about 1.7 seconds including speech fixture
startup. These are controlled stage measurements, not a promise of movie
caption latency or accuracy. Real playback still needs manual acceptance.

Windows prioritizes D3D11VA and retains software fallback. The total configured
cache budget is now shared: the 128 MiB default allows 96 MiB forward and
32 MiB backward instead of 128 MiB for each. This describes buffer limits,
not total process RAM. Software decoder concurrency is bounded to four threads.
Repeated dimensions/completion events and unchanged history saves are skipped.

The optional naku_video_decode_benchmark target generates its own 1080p H.264
fixture using Windows Media Foundation and renders to a hidden test window.
It verified actual d3d11va activation and zero decoder drops. Software decode
also had zero drops on this short simple fixture; no general CPU/FPS improvement
percentage is claimed. It uses no private videos and does not control the app.

Reference inspected: KeyRotate/LibreTV-App's js/player.js uses worker-based HLS
processing, bounded forward buffers and explicit old-player cleanup:
https://github.com/KeyRotate/LibreTV-App/blob/main/js/player.js
That Tauri/web player uses a different decoder stack. NAKU retains its native
MPV/D3D11 pipeline and applies the relevant buffer/lifecycle principles.

Revision 55 focused regressions: 64 Dart checks; real subtitle loading,
time-based overlay, real ASR service and all native test groups passed.

Revision 54 adds one-click verified subtitle aggregation and Windows local
original-language captions. The real aggregate test found four usable Chinese
S10E02 subtitle files, including simplified/traditional Chinese-English ASS.
Candidates requiring interactive verification or returning invalid data are
filtered; results are downloadable and decoded before they appear. Archive
contents are read through Windows tar to stdout, with output/time limits and
only subtitle entries allowed; other attachments are never extracted.

Live captions use Windows process loopback (Windows 11 / build 20348+) and a
separate whisper.cpp CPU process bound to loopback with a random request path.
They process this app's audio only, do not capture a microphone, and do not
translate. Audio, recognition text and private NAS URLs are never uploaded.
Five seconds of synthetic speech captured from the native test process were
recognized correctly in about 0.6 seconds on this machine. The service test
also verifies original text output, seek invalidation, and stopping the engine.
53 focused Dart regressions and all three native test groups passed.
Actual in-video subtitle display and ASR accuracy remain for manual acceptance.

The installer build calls scripts/prepare_windows_asr.ps1. It verifies SHA-256
checksums for the pinned whisper.cpp b5454 Windows CPU distribution and the
147951465-byte multilingual base model, and bundles them with their MIT
licenses. No Python, GPU toolkit or separate model installation is required.
Model/runtime binaries live in ignored build/ directories and are not committed
to Git. The source archive includes the reproducible preparation script.

Revision 53 fixes online subtitle context, season/episode parsing, cross-type
catalog fallback, language filtering and subtitle download validation. The
subtitle client now follows app proxy settings with certificate validation.
48 focused subtitle/playback/appearance/update regressions passed. The opt-in
live test found American Horror Story S10E02 using its Chinese title, fetched
62 resources and downloaded a valid English subtitle. This provider returned
no Chinese subtitles for that episode at the time of testing. Revision 53
still requires manual acceptance of subtitle display during real playback.

Run the live check explicitly (requires internet access):

```powershell
flutter test --no-pub --dart-define=NAKU_LIVE_SUBTITLE_TEST=true test/features/cinema/cinema_online_subtitles_live_test.dart
```

Windows 11 x64, Flutter 3.47.6, Dart 3.13.5 and MSVC 19.44:

- Release build and Inno Setup compilation passed.
- The 66 NAS protocol/media/page and desktop close/control regression tests passed.
- Static analysis of the eight affected application files reported no issues.
- Native tests passed for DPAPI save/read/replace/delete, AES-GCM known-answer
  and tamper-rejection cases, RSA SPKI/PKCS#1 import, and QR key disposal.
- The user confirmed a real NAS QR login, visible movie library, and working
  minimize, maximize/restore and close buttons. UI automation could read the
  controls but did not provide reliable click geometry; real button acceptance
  was performed by the user.
- Online NAS video playback and a complete installer install/uninstall cycle
  were not separately exercised. The earlier broad home-startup suite has two
  known failing cases documented in the initial local build report; this change
  does not claim that the entire repository test suite passes.

Run the focused Dart checks with:

```powershell
flutter test --no-pub test/features/cinema/cinema_android_nas_test.dart test/features/cinema/cinema_nas_test.dart test/features/cinema/cinema_nas_media_test.dart test/desktop_window_close_test.dart test/desktop_window_controls_test.dart
```

Run native tests with CMake available on PATH:

```powershell
cmake -S windows/tests -B build/windows-native-tests -G "Visual Studio 17 2022" -A x64
cmake --build build/windows-native-tests --config Release
ctest --test-dir build/windows-native-tests -C Release --output-on-failure
```

The patched ech_http 0.2.1 package is retained in third_party with its license.
Its CA bundle is split into per-certificate strings to avoid MSVC C2026; HTTPS
certificate validation remains enabled. The media-kit fork already provides
verified native MPV binaries through its Dart build hook.

macOS-only Sparkle updates, AppKit blur and global hide hotkeys do not apply on
Windows. The current cinema embedded website page has no Windows InAppWebView
implementation and displays its existing unsupported-platform message; anime
uses the retained Windows WebView implementation. This port is not signed with
a commercial Windows code-signing certificate.

## Revision 56 verification (2026-10-21, Asia/Shanghai)

The former global `demuxer-lavf-format=hls` also affected external subtitle
inputs. The native regression reproduces rejected `sub-add` with that option,
then loads the same SRT after restoring independent input probing. Production
playback no longer forces that option. A live English S10E02 download also
passes the real MPV load and caption-state check.

History entry navigation now refreshes the source catalogue, resolves the saved
media by URL/unique route-and-name, and passes explicit episode and time. A UI
test clicks the actual history entry after an episode reorder and confirms the
saved episode and 777-second resume point reach the player page.

Assrt search/detail endpoints returned 502 during verification while the public
archive CDN download remained available. A metadata-only fallback catalogue
currently covers AHS S10E02 simplified/traditional FIX bilingual ASS. It contains
links and filenames, not dialogue. Both candidates are downloaded, extracted
and checked before display on every search; this is a narrow recovery catalogue,
not a claim of universal provider availability. Background web search continues.

Reference: https://github.com/KeyRotate/LibreTV-App/blob/main/js/player.js
(explicit episode index and saved position restoration). LibreTV-App uses a
Tauri/HLS.js stack; NAKU retains MPV and independent media/subtitle probing.

Focused validation: 50 Dart regressions, 1 history navigation widget test,
4 native MPV tests (including extensionless HLS plus subtitles), and 2 live subtitle network tests passed. Analysis of 9
modified Dart files passed. Wider exploratory checks also found 3 existing
failures: two startup assertions reproduce with the unchanged HEAD home page
and test file, and a Windows backup-path comparison test compares mixed slash
forms. These unrelated checks are not counted as passing revision-56 coverage.
## Revision 57: subtitle timing and LibreTV review

Default search now only includes Chinese and English with independent candidate
budgets and Chinese-first ordering. Release markers are compared locally, never
uploaded. Actual timed dialogue determines Chinese/bilingual labels; Windows
GBK/GB18030 uses strict MultiByteToWideChar conversion. Live S10E02 default search
returned two bilingual Chinese files (747 Chinese cues) and seven English files.
This remains narrow evidence for S10E02, not universal episode coverage.

External timing maps subtitle time to media time as source * scale + offset.
The UI offers a single dialogue anchor for fixed shifts, +/-0.5 second nudges,
explicit offsets up to six hours, and two anchors for linear FPS drift. Closing
the sheet retains the first anchor. Up to 64 calibrated media/content pairs are
saved under two SHA256 hashes with scale/offset only; no private reference or
dialogue is persisted. Writes are serialized per CinemaStore. Re-selecting the
same external track restores the custom caption layer and calibration.

Comparing identical English cues across public S10E02 subtitle cuts found
roughly 11-second HULU and 22-second AMZN shifts relative to FIX; HDTV had drift.
These are differences between subtitle files, not an inferred offset for the
user's private film. Real-video alignment needs the user's dialogue anchor.

LibreTV reference audit covered player-shell, recovery, db, prefetch/cache,
search, source switching/health, focus and persistence at commit
9d86ec2568895b2a8b52da47fc9bfea6c74f8378. Adopted background prefetch cancellation
on buffering and interactive-control keyboard ownership. Preserve NAKU's MPV
session cancellation, media identity and bounded cache. No evidence was found
for LibreTV external subtitle aggregation or audio-based automatic subtitle
alignment; do not claim those as inherited capabilities.

Focused verification: 76 related regression cases passed. Native verification
also checks fresh Chinese aggregate-download-load, English download-load,
extensionless HLS plus captions, track off/on restoration, and the old global
HLS failure reproduction. These checks validate rendering and loading, not
actual private-film dialogue synchronisation. See revision 56 notes for the
three pre-existing wider-suite failures excluded from passing coverage.
## Revision 58: production-only failures reproduced

The installed 2.8.4+57 binary was reproduced with caption Close and Alt-F4 both
failing. Windows Flutter consumes initial WM_CLOSE and sends
System.requestAppExit before window_manager receives its re-dispatched close.
Marking the first request as explicit Quit set isQuitting, so the later close
handler ignored the event while native close remained prevented. Windows exit
requests now use the existing window-close choice path and return cancel to
consume the duplicate; macOS explicit Quit stays separate. Actual rebuilt
Windows UI passed Close -> confirmation -> Escape -> Alt-F4 -> Exit -> process
termination, in addition to 21 close/window-control regressions.

The Chinese discrepancy was also reproduced: production default client plus
current WinINET/system-proxy state returned Chinese 0 / English 7, whereas
previous live tests installed a DIRECT adapter and returned Chinese 2. The
system-proxy TLS connection to assrt failed; matching production headers in
DIRECT mode succeeded, so UA/Accept were excluded. Windows tar from the installed
working directory, hidden process and minimal environment also extracted the
112203-byte Unicode-entry subtitle successfully, excluding the suspected
packaging/codepage issue.

Only anonymous HTTPS GETs to an explicit public subtitle host list can recover
from automatic Windows proxy connection/gateway failures using verified HTTPS
DIRECT. Explicit application proxies, credential-bearing requests, non-GETs,
private hosts and cancelled requests do not enter that path. NAS/media traffic
and certificate verification are untouched. UI reports real failure categories
and recovered-source routing. Live tests now include production default proxy
configuration and an injected system-proxy TLS outage followed by real archive
download, extraction and Chinese dialogue verification. Both returned Chinese
2 / English 7. These tests replace the prior DIRECT-only evidence for this bug.

Subtitle calibration now permits pausing after hearing a few words. Replay the
preceding three seconds at 0.75x, adjust its candidate start by 250ms, then align
the chosen subtitle to that start. Audition ends paused and restores the prior
rate. A widget test pauses at 90s, auditions from 87.25s, then proves the cue's
anchor uses 87.25s rather than the late 90s click time. Nine replay-controller
tests and a real MPV replay/rate-restoration test passed. No audio is uploaded.

Revision 58 focused regression: 110 cases passed; modified Dart analysis passed.
Prior wider-suite failures remain documented separately above and are not
counted as passing. Build output is Windows 2.8.4+58 / installer 2.8.4.58.

## Revision 59: season continuation and pause ownership

A successfully applied online selection can enable a hashed work + season
profile for that episode and later episodes. Store public query and subtitle
metadata, language, script/bilingual preference, scale and offset only. Each
episode aggregates and validates its own exact matching file. A missing language
never silently becomes English. Per-media/content timing takes precedence over
the season fallback. Calibration captures profile ownership synchronously and
season reads flush pending writes, including an immediate episode switch.

Automatic requests belong to one playback. Explicit subtitle UI cancels them;
native external loading checks cancellation between asynchronous conversion,
file IO and track operations. Only the same normalized subtitle family may load
early; the complete validated candidate set supplies other best matches.

Manual search pauses before the panel opens and before every search/apply. It
never automatically resumes on dismissal. Automatic episode search temporarily
pauses then restores the original play intent only while the same playback,
manual-interaction revision and window visibility still permit it.

Public archive 645218 supplies exact S10E01-E10 entries, with E08 REPACK.
Production-default network tests downloaded/extracted all 10 entries with more
than 100 Chinese and English cues each. E03 aggregate returned one Chinese
resource with 811 Chinese cues. Its E02 normalized dialogue and timestamps match
the existing 675334 FIX E02 resource. These checks do not prove universal
private-video synchronization; episodes with different edits can be adjusted.

Revision 59 verification: 153 focused regression cases passed, including a
real player-page E03 -> E04 switch. A real Native MPV test (no apply injection)
checks exact E03 loading, season offset +2.5 seconds, caption boundary
[2.5, 6.5) and preservation of an originally paused player. Two production
network tests cover all ten real archive entries and E03 aggregate/download.
Modified production Dart analysis passed. Windows Release 2.8.4+59 and Inno
2.8.4.59 compilation succeeded. Prior unrelated wider-suite failures remain
separately documented and are not counted as passing.
