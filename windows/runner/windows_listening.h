#ifndef RUNNER_WINDOWS_LISTENING_H_
#define RUNNER_WINDOWS_LISTENING_H_

#include <windows.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <condition_variable>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>

class WindowsListening {
 public:
  WindowsListening(HWND window, flutter::BinaryMessenger* messenger);
  ~WindowsListening();
  static constexpr UINT kDispatch = WM_APP + 152;
  static constexpr UINT kClosed = WM_APP + 154;
  void Dispatch();
  void FinishClose();
  void Suspend();

 private:
  using Value = flutter::EncodableValue;
  using Reply = std::shared_ptr<flutter::MethodResult<Value>>;
  struct Request { std::string method; flutter::EncodableList args; Reply reply; };
  struct Mailbox;
  void Run();
  void Submit(Request request);

  HWND window_;
  flutter::MethodChannel<Value> channel_;
  std::shared_ptr<Mailbox> mailbox_;
  std::mutex mutex_;
  std::condition_variable changed_;
  std::deque<Request> requests_;
  bool closing_ = false;
  bool notify_closed_ = false;
  std::thread worker_;
};

#endif
