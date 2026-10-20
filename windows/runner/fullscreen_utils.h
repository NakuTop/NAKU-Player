// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#ifndef FULLSCREEN_UTILS_H_
#define FULLSCREEN_UTILS_H_

#include <cstdint>

#include <Windows.h>

class FullscreenUtils {
 public:
  static bool EnterNativeFullscreen(HWND window);

  static bool ExitNativeFullscreen(HWND window);
  static bool IsFullscreen(HWND window);

 private:
  static bool fullscreen_;
  static HWND window_;
  static LONG_PTR style_, ex_style_;
  static WINDOWPLACEMENT placement_;
};

#endif  // FULLSCREEN_UTILS_H_
