Upstream: Predidit/media-kit, commit 803c4a27912091db6f839d48d1b984a0d9f588c7, media_kit_video.

Local fix: MaterialDesktopVideoControlsTheme must notify dependents when either theme changes. The upstream inverted equality kept mounted toolbar controls disabled after loading and left speed labels stale. The Video controller and texture remain mounted. Regression: flutter test test/features/cinema/cinema_controls_theme_test.dart.

No global package cache modifications. Upstream LICENSE retained.

2.9.2: Keep the desktop toolbar mounted with `Visibility(maintainState: true)`
when it fades out. An open popup outlives its hover region; removing its
PopupMenuButton discarded its selected result because Flutter only calls
onSelected while the button is mounted. The regression uses the actual desktop
controls and selects a rate after the hover deadline. Hidden controls remain
offstage and cannot receive pointer input. While a modal menu is open, keep
its toolbar anchor visible so the popup cannot move or shrink; resume the idle
timer after the menu closes.
