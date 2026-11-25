#ifndef RUNNER_WINDOWS_SPEECH_PLAYER_H_
#define RUNNER_WINDOWS_SPEECH_PLAYER_H_

#include <windows.h>
#include <flutter/encodable_value.h>
#include <functional>
#include <memory>
#include <string>

// All calls run on the listening worker. Callbacks only post to Flutter's platform thread.
class WindowsSpeechPlayer {
 public:
  using Value = flutter::EncodableValue;
  using Args = flutter::EncodableList;
  using Emit = std::function<void(std::string, Args)>;
  WindowsSpeechPlayer(HWND window, Emit emit);
  ~WindowsSpeechPlayer();
  Value Command(const std::string& method, const Args& args);
  void Tick();
  int NextWakeMs() const;
 private:
  struct State;
  std::unique_ptr<State> state_;
};

#endif
