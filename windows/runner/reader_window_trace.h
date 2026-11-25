#ifndef RUNNER_READER_WINDOW_TRACE_H_
#define RUNNER_READER_WINDOW_TRACE_H_

#include <windows.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <filesystem>

// Only the diagnostic build starts this observer. Native events remain on disk
// even if Dart stops drawing frames or dispatching pointer events.
class ReaderWindowTrace {
 public:
  ReaderWindowTrace(HWND window, HWND view, flutter::BinaryMessenger* messenger);
  ~ReaderWindowTrace();

 private:
  static LRESULT CALLBACK Observe(HWND hwnd, UINT msg, WPARAM wparam,
                                  LPARAM lparam, UINT_PTR id, DWORD_PTR data);
  void Write(const char* event, HWND hwnd, WPARAM detail,
             const POINT* wheel_position = nullptr);
  HWND window_;
  HWND view_;
  std::filesystem::path file_;
  flutter::MethodChannel<flutter::EncodableValue> channel_;
};
#endif
