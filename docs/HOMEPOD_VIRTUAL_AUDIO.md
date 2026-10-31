# HomePod system audio output

The macOS setting is off on every launch. Opening the settings does not install
software, search the LAN, or route audio. Explicit enable reuses a compatible,
authorized NAKU driver. A missing or incompatible driver opens the bundled macOS
Installer; the installer owns the administrator prompt and restarts CoreAudio
to load the output-only HAL plugin and local audio broker. If only the player's
signing requirement changed, a separate script-only authorization package
updates the root-owned authorization without replacing the driver or restarting
CoreAudio.

The driver has one stereo Float32 output at 48 kHz and no input stream. It writes
mixed output to a bounded shared-memory ring. The player converts this to
44.1 kHz PCM and sends authenticated AirPlay realtime RTP to the selected
HomePod. The setting's 120 ms value is the requested receiver buffer, not a
measured acoustic delay. Audio is not written to disk. No system recording,
microphone, process tap, or ScreenCaptureKit API is used by this feature.

The root broker has no arbitrary command service. It authorizes the driver host
against the exact Apple-signed coreaudiod and isolated driver-host requirements
and the reader against the installed player's designated requirement plus the
installing console user's UID. Security checks use the XPC message's audit
token. The authorization file is owned by root and cannot be changed by the
player. An ad hoc signed local update can require refreshing this authorization.
Local builds can use an approved existing Apple Development certificate.
`macos/sign-local-player.sh` accepts that identity through
`NAKU_LOCAL_SIGN_IDENTITY`; it exports no private key and preserves the app's
sandbox entitlements. A stable certificate-based designated requirement allows
subsequent local updates signed by the same identity to reuse authorization.

The network sender is connected before changing system output. The broker is
armed with the previous output identifiers first; closing the reader connection
restores a still-owned virtual route. The player also restores on stop/error/
normal quit and keeps a recovery record for interrupted sessions. Manual output
changes take precedence. Backgrounding NAKU keeps an explicitly enabled stream
running. The separate “检查声卡” action uses a short signal in memory to verify
nonzero PCM and restoration without needing an online HomePod.

An explicitly enabled session holds a
`ProcessInfo.userInitiatedAllowingIdleSystemSleep` activity from the start of
connection until OFF, error, or quit. This keeps a covered or hidden window's
handshake and forwarding work eligible to run without preventing ordinary
system idle sleep. See Apple's [app-level activity guidance](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/PrioritizeWorkAtTheAppLevel.html).

The movie player's mpv output is explicitly switched to the NAKU device only
after the native bridge confirms that system routing is active. This handles
an already-open CoreAudio output that would otherwise retain its previous
device. Turning the feature off restores the movie player's preceding device;
its media volume, mute state, and selected audio track are preserved.

HomePod receiver volume is separate from Mac and movie-player volume. The
settings panel reads the receiver's initial level and provides an explicit
HomePod volume slider. Confirmed changes use the encrypted AirPlay control
session and are persisted only after a user volume change. Connecting alone
does not force the receiver to maximum volume.

Unisson's private driver/helper are not used or copied. REA observed its native
352-frame paced sending function (0x10010c880), timing/synchronization and
adaptive queue diagnostics. Its installed output-only driver's broker restricts
the reader to Unisson's signature, and its cleanup daemon removes the driver
after the app is deleted. NAKU's sender is an independent implementation based
on the MIT pyatv protocol reference; BigInt's MIT license is included. The NAKU
driver/broker are independently implemented against Apple's HAL/XPC APIs.

Relevant REA evidence: ev_d82202760fd464cc42770b10d2512aa0a6bfa6af1fde396efca1259d5ff6be7f
(sender), ev_c13d3b91c11c83a4a6e970a38fa40ff094a93e6089bc5b5a4733b20a776356da
(reader restriction), ev_beecfb75aa668f73d30d96d8adf2b9523931facdf2d0ba44cefaa237e5b45901
(diagnostics and installer/cleanup). Static decompilation establishes these code
paths, not acoustic latency.

Native checks (no installation or routing):

```sh
python3 scripts/test_homepod_pcm_native.py
python3 scripts/test_homepod_sender_native.py
python3 scripts/test_homepod_virtual_driver.py
```

The Xcode build phase packages `macos/AudioDriver` into the app's sealed
`NAKUAudio.pkg` and `NAKUAudioAuthorization.pkg` resources. No legacy driver should be removed until the installed
NAKU driver, system routing/restoration, and actual HomePod playback pass device
acceptance. Automated fixtures alone do not establish that acceptance.

Local verification on 2026-10-31 used macOS 26.7.2, HomePod mini with software
27.2, NAKU 3.0.17 (97), and NAKU Audio driver 1.0.2:

- The installed app executable and both installer resources match the signed
  build. Strict recursive signature validation passes.
- The driver reports no input stream. No audio-capture or microphone usage
  declaration is present in the installed app.
- The installed “检查声卡” action receives nonzero PCM and confirms restoration
  of both preceding default output identifiers.
- OFF and normal app quit restore the built-in MacBook speakers. The next
  launch stays OFF. Explicit reconnect reuses the installed authorization.
- A movie supplies continuous nonzero PCM for over five minutes; the control
  connection remains responsive. A separate browser supplies the three-pulse
  fixture while NAKU is in the background.
- The user heard an earlier three-pulse system-output fixture from the bedroom
  HomePod and subsequently confirmed normal movie loudness and continuous
  playback. No acoustic delay measurement has been made.
- After that acceptance, Unisson's app, HAL driver, broker and cleanup services,
  plus BlackHole 16ch and its installer receipt, were removed from this Mac.
  CoreAudio still enumerates NAKU Audio, and its installed self-check passes
  after the audio service restarts.
- The final build stays connected with the app's system `Hidden` flag true;
  RTP packet counts advance and HomePod timing/control replies continue.

The local Flutter regression run completed with 1,554 passing and 47 skipped
visible test cases (plus 238 successful loading/setup events). Native PCM,
sender, and driver/client contract checks also pass. These
results do not replace the listening acceptance above.
