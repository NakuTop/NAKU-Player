// Based on media_kit's MIT-licensed Win32 fullscreen utility.
// Copyright 2021 onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
#include "fullscreen_utils.h"

bool FullscreenUtils::IsFullscreen(HWND window) {
  return fullscreen_ && window_ == window && ::IsWindow(window);
}

bool FullscreenUtils::EnterNativeFullscreen(HWND window) {
  if (IsFullscreen(window)) return true;
  if (!::IsWindow(window) || fullscreen_) return false;
  MONITORINFO monitor{};
  monitor.cbSize = sizeof(monitor);
  WINDOWPLACEMENT placement{};
  placement.length = sizeof(placement);
  if (!::GetWindowPlacement(window, &placement) ||
      !::GetMonitorInfo(::MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &monitor))
    return false;
  placement_ = placement;
  style_ = ::GetWindowLongPtr(window, GWL_STYLE);
  ex_style_ = ::GetWindowLongPtr(window, GWL_EXSTYLE);
  window_ = window;
  fullscreen_ = true;
  // A maximized window also needs its caption removed, not only resize borders.
  ::SetWindowLongPtr(window, GWL_STYLE,
      (style_ & ~(WS_OVERLAPPEDWINDOW | WS_MAXIMIZE | WS_MINIMIZE)) | WS_POPUP);
  ::SetWindowLongPtr(window, GWL_EXSTYLE,
      ex_style_ & ~(WS_EX_WINDOWEDGE | WS_EX_CLIENTEDGE | WS_EX_DLGMODALFRAME));
  const auto& rect = monitor.rcMonitor;
  if (::SetWindowPos(window, HWND_TOP, rect.left, rect.top,
      rect.right - rect.left, rect.bottom - rect.top,
      SWP_NOOWNERZORDER | SWP_FRAMECHANGED)) return true;
  ::SetWindowLongPtr(window, GWL_STYLE, style_);
  ::SetWindowLongPtr(window, GWL_EXSTYLE, ex_style_);
  ::SetWindowPlacement(window, &placement_);
  fullscreen_ = false;
  window_ = nullptr;
  return false;
}

bool FullscreenUtils::ExitNativeFullscreen(HWND window) {
  if (!IsFullscreen(window)) return !fullscreen_;
  fullscreen_ = false;
  ::SetWindowLongPtr(window, GWL_STYLE, style_);
  ::SetWindowLongPtr(window, GWL_EXSTYLE, ex_style_);
  // Placement preserves maximization and workspace-relative normal bounds.
  const bool placed = ::SetWindowPlacement(window, &placement_) != FALSE;
  const bool framed = ::SetWindowPos(window, nullptr, 0, 0, 0, 0,
      SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
      SWP_NOOWNERZORDER | SWP_FRAMECHANGED) != FALSE;
  window_ = nullptr;
  return placed && framed;
}

bool FullscreenUtils::fullscreen_ = false;
HWND FullscreenUtils::window_ = nullptr;
LONG_PTR FullscreenUtils::style_ = 0;
LONG_PTR FullscreenUtils::ex_style_ = 0;
WINDOWPLACEMENT FullscreenUtils::placement_{};
