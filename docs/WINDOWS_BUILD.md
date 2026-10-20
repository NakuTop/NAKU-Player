# Windows build

This local Windows port is based on NakuTop/NAKU-Player main at
`b182453de114c97ba853a46d2fdd59daf2f482ff`. The Windows revision is
2.8.4+51; its installer version is 2.8.4.51.

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

## Validation

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
