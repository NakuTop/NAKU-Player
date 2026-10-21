#include "flutter_window.h"
#include "fullscreen_utils.h"
#include "external_player_utils.h"
#include "shortcut_utils.h"
#include "naku_secure_bridge.h"
#include "naku_audio_capture.h"

#include <optional>
#include <stdexcept>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter/plugin_registrar_windows.h>
#include <windows.h>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Removed automatic window show to let window_manager plugin control visibility
  // This prevents window flashing during startup
  // flutter_controller_->engine()->SetNextFrameCallback([&]() {
  //   this->Show();
  // });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  // Register Intent MethodChannel
  RegisterIntentChannel();

  // Register Storage MethodChannel
  RegisterStorageChannel();

  // Register Shortcut MethodChannel
  RegisterShortcutChannel();
  RegisterSecureChannel();
  RegisterAudioCaptureChannel();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Let Windows hit-test and operate its real caption controls before plugin
  // delegates see them. This preserves DPI-aware button bounds and keeps the
  // Flutter drag area from consuming native minimize/maximize/close clicks.
  // WM_CLOSE still reaches window_manager below, including its exit dialog.
  const bool native_caption =
      (::GetWindowLongPtr(hwnd, GWL_STYLE) & WS_CAPTION) == WS_CAPTION;
  const auto caption_hit = [](LRESULT hit) {
    return hit == HTCAPTION || hit == HTSYSMENU || hit == HTMINBUTTON ||
           hit == HTMAXBUTTON || hit == HTCLOSE;
  };
  if (native_caption && message == WM_NCHITTEST) {
    const LRESULT hit = ::DefWindowProc(hwnd, message, wparam, lparam);
    if (caption_hit(hit)) return hit;
  }
  if (native_caption &&
      (message == WM_NCLBUTTONDOWN || message == WM_NCLBUTTONUP ||
       message == WM_NCLBUTTONDBLCLK) && caption_hit(static_cast<LRESULT>(wparam))) {
    return ::DefWindowProc(hwnd, message, wparam, lparam);
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

// Intent MethodChannel setup
void FlutterWindow::RegisterIntentChannel() {
  auto window_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "com.predidit.kazumi/intent",
          &flutter::StandardMethodCodec::GetInstance());

  window_channel->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "isFullscreen") {
      result->Success(flutter::EncodableValue(FullscreenUtils::IsFullscreen(GetHandle())));
    } else if (call.method_name() == "setFullscreen" ||
               call.method_name() == "enterFullscreen" ||
               call.method_name() == "exitFullscreen") {
      bool enter = call.method_name() == "enterFullscreen";
      if (call.method_name() == "setFullscreen") {
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        if (!args) { result->Error("fullscreen", "Missing fullscreen state"); return; }
        const auto value = args->find(flutter::EncodableValue("isFullScreen"));
        if (value == args->end() || !std::holds_alternative<bool>(value->second)) {
          result->Error("fullscreen", "Missing fullscreen state");
          return;
        }
        enter = std::get<bool>(value->second);
      }
      const bool okay = enter ? FullscreenUtils::EnterNativeFullscreen(GetHandle())
                              : FullscreenUtils::ExitNativeFullscreen(GetHandle());
      if (okay) result->Success();
      else result->Error("fullscreen", "Windows fullscreen transition failed");
    } else if (call.method_name().compare("openWithMime") == 0) {
      const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
      if (arguments) {
        auto url_it = arguments->find(flutter::EncodableValue("url"));
        if (url_it != arguments->end()) {
          const std::string& url = std::get<std::string>(url_it->second);
          ExternalPlayerUtils::OpenWithPlayer(url.c_str());
          result->Success();
        } else {
          result->Error("InvalidArguments", "Missing 'url' argument");
        }
      } else {
        result->Error("InvalidArguments", "Arguments are not a map");
      }
    } else {
      result->NotImplemented();
    }
  });
}

// Storage MethodChannel setup
void FlutterWindow::RegisterStorageChannel() {
  auto storage_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "com.predidit.kazumi/storage",
          &flutter::StandardMethodCodec::GetInstance());

  storage_channel->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name().compare("getAvailableStorage") == 0) {
      std::wstring path = L"C:\\";
      const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
      if (arguments) {
        auto path_it = arguments->find(flutter::EncodableValue("path"));
        if (path_it != arguments->end()) {
          const std::string& path_str = std::get<std::string>(path_it->second);
          // Extract drive root from path (e.g. "C:\Users\..." -> "C:\")
          if (path_str.length() >= 2 && path_str[1] == ':') {
            path = std::wstring(1, static_cast<wchar_t>(path_str[0])) + L":\\";
          }
        }
      }

      ULARGE_INTEGER free_bytes_available;
      if (GetDiskFreeSpaceExW(path.c_str(), &free_bytes_available, nullptr, nullptr)) {
        result->Success(flutter::EncodableValue(static_cast<int64_t>(free_bytes_available.QuadPart)));
      } else {
        result->Success(flutter::EncodableValue(static_cast<int64_t>(-1)));
      }
    } else {
      result->NotImplemented();
    }
  });
}

// Shortcut MethodChannel setup
void FlutterWindow::RegisterShortcutChannel() {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "com.predidit.kazumi/shortcut",
      &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() != "createDesktopShortcut") {
      result->NotImplemented();
      return;
    }

    bool success = ShortcutUtils::CreateDesktopShortcut(L"NAKU Player", L"NAKU Player");
    if (success) {
      result->Success(flutter::EncodableValue(true));
    } else {
      result->Error("Failed", "Failed to create desktop shortcut");
    }
  });
}

void FlutterWindow::RegisterAudioCaptureChannel() {
  auto capture = std::make_shared<NakuAudioCapture>();
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "naku/live_audio",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([capture](const auto& call, auto result) {
    if (call.method_name() == "start") { capture->Start(); result->Success(); }
    else if (call.method_name() == "stop") { capture->Stop(); result->Success(); }
    else if (call.method_name() == "clear") { capture->Clear(); result->Success(); }
    else if (call.method_name() == "pull") {
      auto chunk = capture->Pull();
      flutter::EncodableMap values;
      values[flutter::EncodableValue("pcm")] = flutter::EncodableValue(chunk.pcm);
      values[flutter::EncodableValue("active")] = flutter::EncodableValue(chunk.active);
      values[flutter::EncodableValue("error")] = flutter::EncodableValue(static_cast<int64_t>(chunk.error));
      result->Success(flutter::EncodableValue(values));
    } else result->NotImplemented();
  });
}

void FlutterWindow::RegisterSecureChannel() {
  auto bridge = std::make_shared<NakuSecureBridge>();
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "naku/secure",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([bridge](const auto& call, auto result) {
    try {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      const auto text = [args](const char* name) -> std::string {
        if (!args) throw std::runtime_error("Missing NAS argument");
        const auto entry = args->find(flutter::EncodableValue(name));
        if (entry == args->end() || !std::holds_alternative<std::string>(entry->second))
          throw std::runtime_error("Invalid NAS argument");
        return std::get<std::string>(entry->second);
      };
      const auto& method = call.method_name();
      if (method == "read") {
        const auto value = bridge->Read();
        result->Success(value ? flutter::EncodableValue(*value) : flutter::EncodableValue());
      } else if (method == "write") {
        bridge->Write(text("value"));
        result->Success();
      } else if (method == "delete") {
        bridge->Delete();
        result->Success();
      } else if (method == "rsa") {
        result->Success(flutter::EncodableValue(NakuSecureBridge::Rsa(text("text"), text("key"))));
      } else if (method == "seal") {
        result->Success(flutter::EncodableValue(NakuSecureBridge::Seal(text("text"), text("key"))));
      } else if (method == "open") {
        result->Success(flutter::EncodableValue(NakuSecureBridge::Open(text("text"), text("key"))));
      } else if (method == "qrKey") {
        result->Success(flutter::EncodableValue(bridge->QrKey()));
      } else if (method == "qrDecrypt") {
        result->Success(flutter::EncodableValue(bridge->QrDecrypt(text("text"))));
      } else if (method == "qrClear") {
        bridge->QrClear();
        result->Success();
      } else result->NotImplemented();
    } catch (const std::exception&) {
      result->Error("secure", "无法读取本机加密凭据或处理 NAS 加密数据，请重新登录。");
    }
  });
}
