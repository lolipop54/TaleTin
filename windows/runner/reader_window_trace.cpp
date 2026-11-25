#include "reader_window_trace.h"

#include <commctrl.h>
#include <windowsx.h>
#include <chrono>
#include <fstream>

ReaderWindowTrace::ReaderWindowTrace(HWND window, HWND view,
                                     flutter::BinaryMessenger* messenger)
    : window_(window), view_(view),
      channel_(messenger, "gtreader/windows_reader_trace",
               &flutter::StandardMethodCodec::GetInstance()) {
  channel_.SetMethodCallHandler([this](const auto& call, auto result) {
    const auto* path = std::get_if<std::string>(call.arguments());
    if (call.method_name() != "start" || !path || path->empty()) {
      result->NotImplemented();
      return;
    }
    file_ = std::filesystem::u8path(*path);
    const auto data = reinterpret_cast<DWORD_PTR>(this);
    if (!SetWindowSubclass(window_, Observe, 1, data) ||
        !SetWindowSubclass(view_, Observe, 1, data)) {
      result->Error("subclass_failed", "Cannot observe the reading window");
      return;
    }
    Write("watch", window_, 0);
    result->Success();
  });
}

ReaderWindowTrace::~ReaderWindowTrace() {
  channel_.SetMethodCallHandler(nullptr);
  if (!file_.empty()) {
    RemoveWindowSubclass(view_, Observe, 1);
    RemoveWindowSubclass(window_, Observe, 1);
  }
}

LRESULT CALLBACK ReaderWindowTrace::Observe(HWND hwnd, UINT msg, WPARAM wparam,
                                            LPARAM lparam, UINT_PTR id,
                                            DWORD_PTR data) {
  auto* trace = reinterpret_cast<ReaderWindowTrace*>(data);
  if (msg == WM_NCDESTROY) RemoveWindowSubclass(hwnd, Observe, id);
  if (msg == WM_MOUSEWHEEL || msg == WM_MOUSEHWHEEL) {
    // Wheel messages use screen coordinates. Store only the client position
    // so the event can be compared with Flutter's scaled pointer coordinates.
    POINT point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
    ScreenToClient(hwnd, &point);
    trace->Write(msg == WM_MOUSEWHEEL ? "wheel.vertical" : "wheel.horizontal",
                 hwnd, wparam, &point);
  } else if (hwnd == trace->view_ && msg == WM_LBUTTONDOWN) {
    trace->Write("mouse.down", hwnd, 0);
  } else if (hwnd == trace->window_) {
    if (msg == WM_NCLBUTTONDBLCLK) trace->Write("border.doubleClick", hwnd, wparam);
    if (msg == WM_SIZE) {
      trace->Write("size.begin", hwnd, wparam);
      const auto result = DefSubclassProc(hwnd, msg, wparam, lparam);
      trace->Write("size.end", hwnd, wparam);
      return result;
    }
  }
  return DefSubclassProc(hwnd, msg, wparam, lparam);
}

void ReaderWindowTrace::Write(const char* event, HWND hwnd, WPARAM detail,
                              const POINT* wheel_position) {
  RECT rect{};
  GetClientRect(hwnd, &rect);
  std::error_code ec;
  const auto bytes = std::filesystem::file_size(file_, ec);
  if (!ec && bytes >= 131072) {
    auto previous = file_;
    previous.replace_extension(".previous.jsonl");
    if (!MoveFileExW(file_.c_str(), previous.c_str(), MOVEFILE_REPLACE_EXISTING)) return;
  }
  const auto now = std::chrono::system_clock::now().time_since_epoch();
  std::ofstream out(file_, std::ios::app);
  out << "{\"kind\":\"windowsReaderWindow\",\"event\":\"" << event
      << "\",\"epochMs\":" << std::chrono::duration_cast<std::chrono::milliseconds>(now).count()
      << ",\"pid\":" << GetCurrentProcessId() << ",\"detail\":" << detail
      << ",\"width\":" << rect.right << ",\"height\":" << rect.bottom;
  if (wheel_position) {
    out << ",\"target\":\"" << (hwnd == view_ ? "view" : "window") << "\""
        << ",\"messageMs\":" << static_cast<DWORD>(GetMessageTime())
        << ",\"delta\":" << GET_WHEEL_DELTA_WPARAM(detail)
        << ",\"keys\":" << GET_KEYSTATE_WPARAM(detail)
        << ",\"x\":" << wheel_position->x << ",\"y\":" << wheel_position->y
        << ",\"foreground\":" << (GetForegroundWindow() == window_)
        << ",\"viewFocus\":" << (GetFocus() == view_);
  }
  out << "}\n";
}
