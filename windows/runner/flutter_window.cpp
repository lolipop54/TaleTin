#include "flutter_window.h"

#include <commctrl.h>
#include <flutter/standard_method_codec.h>
#include <optional>

#include "file_drop_target.h"
#include "reader_window_trace.h"
#include "flutter/generated_plugin_registrant.h"

namespace {
constexpr UINT kSavedClose = WM_APP + 153;
LRESULT CALLBACK FilterMouseMove(HWND view, UINT message, WPARAM buttons,
                                 LPARAM position, UINT_PTR id, DWORD_PTR) {
  // Flutter captures this HWND on a client left-button down. After a title-bar
  // double click, resizing can move the client under the still-held button.
  // Forward that move as a hover, so it cannot start a tap without a matching up.
  if (message == WM_MOUSEMOVE && (buttons & MK_LBUTTON) && GetCapture() != view) {
    buttons &= ~static_cast<WPARAM>(MK_LBUTTON);
  } else if (message == WM_NCDESTROY) {
    RemoveWindowSubclass(view, FilterMouseMove, id);
  }
  return DefSubclassProc(view, message, buttons, position);
}
}  // namespace

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
  close_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "taletin/window_close",
      &flutter::StandardMethodCodec::GetInstance());
  close_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "ready") {
      close_ready_ = true;
    } else if (call.method_name() == "saved") {
      if (close_pending_) PostMessage(GetHandle(), kSavedClose, 0, 0);
    } else if (call.method_name() == "cancel") {
      close_pending_ = false;
    } else {
      result->NotImplemented();
      return;
    }
    result->Success();
  });
  listening_ = std::make_unique<WindowsListening>(
      GetHandle(), flutter_controller_->engine()->messenger());
  const HWND view = flutter_controller_->view()->GetNativeWindow();
  SetWindowSubclass(view, FilterMouseMove, 1, 0);
  SetChildContent(view);
  reader_window_trace_ = std::make_unique<ReaderWindowTrace>(
      GetHandle(), view, flutter_controller_->engine()->messenger());
  file_drop_target_ = FileDropTarget::Register(
      flutter_controller_->view()->GetNativeWindow(),
      flutter_controller_->engine()->messenger());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (close_channel_) {
    close_channel_->SetMethodCallHandler(nullptr);
    close_channel_.reset();
  }
  listening_.reset();
  reader_window_trace_.reset();
  if (file_drop_target_) {
    file_drop_target_->Detach();
    file_drop_target_ = nullptr;
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // MediaPlayer creates other top-level HWNDs. Flutter's last-window check
  // may consequently omit the exit request for our actual reader window.
  if (message == WM_CLOSE && close_ready_) {
    if (!close_pending_) {
      close_pending_ = true;
      close_channel_->InvokeMethod("save", nullptr);
    }
    return 0;
  }
  if (message == kSavedClose && close_pending_) {
    listening_->FinishClose();
    return 0;
  }
  if (message == WindowsListening::kClosed && close_pending_) {
    DestroyWindow(hwnd);
    PostQuitMessage(0);
    return 0;
  }
  if (listening_ && message == WindowsListening::kDispatch) {
    listening_->Dispatch();
    return 0;
  }
  if (listening_ && message == WM_POWERBROADCAST && wparam == PBT_APMSUSPEND) {
    listening_->Suspend();
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
