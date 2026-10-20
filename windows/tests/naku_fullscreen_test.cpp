#include "../runner/fullscreen_utils.h"
#include <chrono>
#include <iostream>
#include <stdexcept>
#include <string>

void Check(bool value, int line) { if (!value) throw std::runtime_error("fullscreen assertion failed at line " + std::to_string(line)); }
#define Require(value) Check((value) != 0, __LINE__)
bool Same(const RECT& a, const RECT& b) {
  return a.left == b.left && a.top == b.top && a.right == b.right && a.bottom == b.bottom;
}
void VerifyFull(HWND window) {
  Require(FullscreenUtils::IsFullscreen(window));
  Require((GetWindowLongPtr(window, GWL_STYLE) & WS_OVERLAPPEDWINDOW) == 0);
  MONITORINFO monitor{};
  monitor.cbSize = sizeof(monitor);
  Require(GetMonitorInfo(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &monitor));
  RECT frame{}, client{};
  Require(GetWindowRect(window, &frame) && GetClientRect(window, &client));
  Require(Same(frame, monitor.rcMonitor));
  Require(client.right == frame.right - frame.left && client.bottom == frame.bottom - frame.top);
}
int main() {
  HWND window = nullptr;
  try {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    WNDCLASSW type{};
    type.lpfnWndProc = DefWindowProcW;
    type.hInstance = GetModuleHandle(nullptr);
    type.lpszClassName = L"NAKU_FULLSCREEN_UNIT_TEST";
    Require(RegisterClassW(&type) != 0);
    window = CreateWindowExW(WS_EX_WINDOWEDGE, type.lpszClassName, L"NAKU fullscreen test",
        WS_OVERLAPPEDWINDOW, 100, 100, 800, 600, nullptr, nullptr, type.hInstance, nullptr);
    Require(window != nullptr);
    ShowWindow(window, SW_SHOWNOACTIVATE);
    const auto style = GetWindowLongPtr(window, GWL_STYLE);
    const auto ex_style = GetWindowLongPtr(window, GWL_EXSTYLE);
    RECT before{};
    GetWindowRect(window, &before);
    const auto start = std::chrono::steady_clock::now();
    for (int i = 0; i < 10; ++i) {
      Require(FullscreenUtils::EnterNativeFullscreen(window));
      VerifyFull(window);
      Require(FullscreenUtils::EnterNativeFullscreen(window));
      Require(FullscreenUtils::ExitNativeFullscreen(window));
      Require(!FullscreenUtils::IsFullscreen(window));
      RECT restored{};
      GetWindowRect(window, &restored);
      Require(Same(before, restored));
      Require(GetWindowLongPtr(window, GWL_STYLE) == style);
      Require(GetWindowLongPtr(window, GWL_EXSTYLE) == ex_style);
    }
    std::cout << "PASS: ten immediate full-display transitions restore exact bounds/styles\n";
    std::cout << "Native loop milliseconds: " << std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - start).count() << '\n';
    ShowWindow(window, SW_MAXIMIZE);
    Require(IsZoomed(window));
    WINDOWPLACEMENT before_max{};
    before_max.length = sizeof(before_max);
    GetWindowPlacement(window, &before_max);
    Require(FullscreenUtils::EnterNativeFullscreen(window));
    VerifyFull(window);
    Require(FullscreenUtils::ExitNativeFullscreen(window));
    Require(IsZoomed(window));
    WINDOWPLACEMENT after_max{};
    after_max.length = sizeof(after_max);
    GetWindowPlacement(window, &after_max);
    Require(Same(before_max.rcNormalPosition, after_max.rcNormalPosition));
    std::cout << "PASS: maximized entry has no title bar; exit restores maximized placement\n";
    DestroyWindow(window);
    return 0;
  } catch (const std::exception& error) {
    if (window) DestroyWindow(window);
    std::cerr << error.what() << '\n';
    return 1;
  }
}
