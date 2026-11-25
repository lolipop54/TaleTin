#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "win32_window.h"
#include "windows_listening.h"

class FileDropTarget;
class ReaderWindowTrace;

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  FileDropTarget* file_drop_target_ = nullptr;
  std::unique_ptr<WindowsListening> listening_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> close_channel_;
  bool close_ready_ = false;
  bool close_pending_ = false;
  std::unique_ptr<ReaderWindowTrace> reader_window_trace_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
