#include "windows_listening.h"

#include <flutter/standard_method_codec.h>
#include <winrt/base.h>
#include "windows_speech_player.h"

using Value = flutter::EncodableValue;
using Args = flutter::EncodableList;

// Audio callbacks may outlive their source. Closing this mailbox prevents posting to a
// destroyed HWND or messenger; Flutter replies are always made on its platform thread.
struct WindowsListening::Mailbox {
  explicit Mailbox(HWND owner) : window(owner) {}
  HWND window;
  std::mutex mutex;
  std::deque<std::function<void()>> tasks;
  void Post(std::function<void()> action) {
    std::lock_guard<std::mutex> lock(mutex);
    if (!window) return;
    tasks.push_back(std::move(action));
    PostMessage(window, kDispatch, 0, 0);
  }
};

WindowsListening::WindowsListening(HWND window, flutter::BinaryMessenger* messenger)
    : window_(window), channel_(messenger, "taletin/windows_listening",
          &flutter::StandardMethodCodec::GetInstance()),
      mailbox_(std::make_shared<Mailbox>(window)) {
  channel_.SetMethodCallHandler([this](const auto& call, auto result) {
    const auto* args = call.arguments() ? std::get_if<Args>(call.arguments()) : nullptr;
    Submit({call.method_name(), args ? *args : Args{}, std::move(result)});
  });
}

void WindowsListening::Submit(Request request) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (closing_) return;
    requests_.push_back(std::move(request));
    if (!worker_.joinable()) worker_ = std::thread([this] { Run(); });
  }
  changed_.notify_one();
}

void WindowsListening::Suspend() {
  // Do not start a speech worker just because an idle computer is sleeping.
  if (worker_.joinable()) Submit({"suspend", {}, nullptr});
}

void WindowsListening::FinishClose() {
  // Releasing system media controls can call back onto the HWND thread.
  // Keep its message pump running until the speech apartment has shut down.
  std::lock_guard<std::mutex> lock(mutex_);
  closing_ = true;
  if (!worker_.joinable()) {
    PostMessage(window_, kClosed, 0, 0);
    return;
  }
  notify_closed_ = true;
  changed_.notify_one();
}

WindowsListening::~WindowsListening() {
  channel_.SetMethodCallHandler(nullptr);
  {
    std::lock_guard<std::mutex> lock(mailbox_->mutex);
    mailbox_->window = nullptr;
    mailbox_->tasks.clear();
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    closing_ = true;
  }
  changed_.notify_one();
  if (worker_.joinable()) worker_.join();
}

void WindowsListening::Dispatch() {
  std::deque<std::function<void()>> tasks;
  {
    std::lock_guard<std::mutex> lock(mailbox_->mutex);
    tasks.swap(mailbox_->tasks);
  }
  for (const auto& action : tasks) action();
}

void WindowsListening::Run() {
  winrt::init_apartment(winrt::apartment_type::multi_threaded);
  {
    auto* channel = &channel_;
    WindowsSpeechPlayer player(window_, [box = mailbox_, channel](std::string event, Args args) {
      box->Post([channel, event = std::move(event), args = std::move(args)] {
        channel->InvokeMethod(event, std::make_unique<Value>(args));
      });
    });
    for (;;) {
      Request request;
      {
        std::unique_lock<std::mutex> lock(mutex_);
        auto ready = [this] { return closing_ || !requests_.empty(); };
        const int delay = player.NextWakeMs();
        if (delay < 0) changed_.wait(lock, ready);
        else changed_.wait_for(lock, std::chrono::milliseconds(delay), ready);
        if (closing_) break;
        if (!requests_.empty()) {
          request = std::move(requests_.front());
          requests_.pop_front();
        }
      }
      if (!request.method.empty()) {
        auto reply = request.reply;
        try {
          auto value = player.Command(request.method, request.args);
          if (reply) mailbox_->Post([reply, value = std::move(value)] { reply->Success(value); });
        } catch (...) {
          auto message = winrt::to_string(winrt::to_message());
          if (reply) mailbox_->Post([reply, message] { reply->Error("windows_speech", message); });
        }
      }
      player.Tick();
    }
  }
  winrt::uninit_apartment();
  std::lock_guard<std::mutex> lock(mutex_);
  if (notify_closed_) PostMessage(window_, kClosed, 0, 0);
}
