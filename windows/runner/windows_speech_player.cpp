#include "windows_speech_player.h"

#include <systemmediatransportcontrolsinterop.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Media.Audio.h>
#include <winrt/Windows.Media.Core.h>
#include <winrt/Windows.Media.Devices.h>
#include <winrt/Windows.Media.Playback.h>
#include <winrt/Windows.Media.SpeechSynthesis.h>
#include <winrt/Windows.Storage.Streams.h>
#include <algorithm>
#include <atomic>
#include <vector>

using namespace winrt;
using namespace Windows::Foundation;
using namespace Windows::Media;
using namespace Windows::Media::Core;
using namespace Windows::Media::Devices;
using namespace Windows::Media::Playback;
using namespace Windows::Media::SpeechSynthesis;
using Value = WindowsSpeechPlayer::Value;
using Args = WindowsSpeechPlayer::Args;

namespace {
int64_t Now() { return static_cast<int64_t>(GetTickCount64()); }
const std::string& Text(const Value& v) { return std::get<std::string>(v); }

struct SpeechWord { int64_t time; int32_t start; int32_t end; };
struct Clip {
  std::string text;
  SpeechSynthesizer synth{nullptr};
  IAsyncOperation<SpeechSynthesisStream> task{nullptr};
  ~Clip() {
    // Cancellation is best effort. Only the current clip can reach the output device.
    try { if (task && task.Status() == AsyncStatus::Started) task.Cancel(); }
    catch (const hresult_error&) {}
  }
};

struct PlaybackEvents {
  std::atomic<bool> ended{false};
  std::atomic<bool> failed{false};
};
}  // namespace

struct WindowsSpeechPlayer::State {
  HWND window;
  Emit emit;
  VoiceInformation voice{nullptr};
  double rate = 1;
  std::unique_ptr<Clip> current, next;
  std::string id;
  MediaPlayer player{nullptr};
  Windows::Storage::Streams::IRandomAccessStream stream{nullptr};
  std::vector<SpeechWord> words;
  size_t word = 0;
  bool started = false, held = false, expired = false;
  bool awake = false, interrupted = false;
  std::shared_ptr<PlaybackEvents> events;
  SoundLevel last_level = SoundLevel::Full;
  std::string failure_kind = "synthesis";
  int64_t deadline = 0, timer_version = 0;
  SystemMediaTransportControls controls{nullptr};
  event_token buttons{};
  MediaDevice::DefaultAudioRenderDeviceChanged_revoker device_subscription;
  std::shared_ptr<std::atomic<bool>> device_changed = std::make_shared<std::atomic<bool>>(false);
  hstring device_id;

  State(HWND hwnd, Emit output) : window(hwnd), emit(std::move(output)) {}

  void Awake(bool enabled) {
    if (awake == enabled) return;
    SetThreadExecutionState(enabled ? ES_CONTINUOUS | ES_SYSTEM_REQUIRED : ES_CONTINUOUS);
    awake = enabled;
  }

  void ClosePlayer() {
    if (player) {
      try { player.Close(); } catch (const hresult_error&) {}
      player = nullptr;
    }
    stream = nullptr;
    events.reset();
    words.clear();
    word = 0;
    started = false;
    last_level = SoundLevel::Full;
  }

  void Stop() {
    ClosePlayer();
    current.reset();
    next.reset();
    id.clear();
    held = false;
    Awake(false);
  }

  void Reset() {
    Stop();
    deadline = 0;
    expired = false;
    interrupted = false;
    if (controls) {
      controls.ButtonPressed(buttons);
      controls.IsEnabled(false);
      controls = nullptr;
    }
    device_subscription.revoke();
    voice = nullptr;
    rate = 1;
  }

  bool CheckDeadline() {
    if (deadline && Now() >= deadline) {
      deadline = 0;
      expired = true;
      Stop();
      emit("deadline", {Value(timer_version)});
    }
    return expired;
  }

  void Interrupt() {
    if (!awake) return;
    // A queued next sentence must wait for Dart to acknowledge the pause.
    interrupted = true;
    Stop();
    emit("command", {Value("pause")});
  }

  std::unique_ptr<Clip> Synthesize(const std::string& text) {
    auto clip = std::make_unique<Clip>();
    clip->text = text;
    clip->synth = SpeechSynthesizer();
    if (voice) clip->synth.Voice(voice);
    auto options = clip->synth.Options();
    options.SpeakingRate(rate);
    options.IncludeWordBoundaryMetadata(true);
    clip->task = clip->synth.SynthesizeTextToStreamAsync(to_hstring(text));
    return clip;
  }

  void WatchDevice() {
    if (device_subscription) return;
    device_id = MediaDevice::GetDefaultAudioRenderId(AudioDeviceRole::Default);
    device_subscription = MediaDevice::DefaultAudioRenderDeviceChanged(auto_revoke,
        [flag = device_changed](auto const&, auto const& args) {
          if (args.Role() == AudioDeviceRole::Default) flag->store(true);
        });
  }

  void Speak(const std::string& utterance, const std::string& text) {
    if (CheckDeadline() || interrupted) return;
    ClosePlayer();
    failure_kind = "synthesis";
    current = next && next->text == text ? std::move(next) : Synthesize(text);
    next.reset();
    id = utterance;
    held = false;
    WatchDevice();
    Awake(true);
  }

  void ReadWords(const SpeechSynthesisStream& speech_stream) {
    for (auto const& track : speech_stream.TimedMetadataTracks()) {
      if (track.Id() != L"SpeechWord") continue;
      for (auto const& cue : track.Cues()) {
        const auto speech = cue.try_as<SpeechCue>();
        if (!speech) continue;
        const auto start = speech.StartPositionInInput();
        const auto end = speech.EndPositionInInput();
        if (start && end) {
          // Windows reports an inclusive UTF-16 end. Dart uses a half-open range.
          words.push_back({cue.StartTime().count(), start.Value(), end.Value() + 1});
        }
      }
    }
  }

  void OpenOutput() {
    auto speech = current->task.GetResults();
    ReadWords(speech);
    stream = speech;
    failure_kind = "output";
    player = MediaPlayer();
    player.CommandManager().IsEnabled(false);
    player.AudioCategory(MediaPlayerAudioCategory::Media);
    events = std::make_shared<PlaybackEvents>();
    player.MediaEnded([signal = events](auto const&, auto const&) { signal->ended = true; });
    player.MediaFailed([signal = events](auto const&, auto const&) { signal->failed = true; });
    player.Source(MediaSource::CreateFromStream(stream, speech.ContentType()));
    if (!held) player.Play();
  }

  void Tick() {
    if (CheckDeadline()) return;
    if (device_changed->exchange(false)) {
      auto device = MediaDevice::GetDefaultAudioRenderId(AudioDeviceRole::Default);
      if (device != device_id) {
        device_id = device;
        Interrupt();
      }
    }
    if (!current) return;
    if (!player) {
      if (current->task.Status() == AsyncStatus::Started) return;
      OpenOutput();
    }
    if (events->failed) throw hresult_error(E_FAIL, L"Windows audio playback failed");
    // A new player has its own completion flags. A late callback for the previous
    // sentence cannot advance the new sentence or restart cancelled playback.
    auto session = player.PlaybackSession();
    auto level = player.AudioStateMonitor().SoundLevel();
    if (level != last_level) {
      const auto previous = last_level;
      last_level = level;
      if (level == SoundLevel::Muted) { Interrupt(); return; }
      if (level == SoundLevel::Low) {
        player.Pause();
        held = true;
        emit("command", {Value("hold")});
      } else if (previous == SoundLevel::Low) {
        emit("command", {Value("resumeHeld")});
      }
    }
    if (held) return;
    const auto position = session.Position().count();
    const bool ended = events->ended;
    if (!started && (ended || (position > 0 &&
        session.PlaybackState() == MediaPlaybackState::Playing))) {
      started = true;
      emit("started", {Value(id)});
    }
    while (started && word < words.size() && words[word].time <= position) {
      const auto& cue = words[word++];
      emit("range", {Value(id), Value(cue.start), Value(cue.end)});
    }
    if (ended) {
      auto finished = std::move(id);
      ClosePlayer();
      current.reset();
      emit("done", {Value(finished)});
      // Keep the system awake while Dart prepares the next chapter. Its terminal
      // paths explicitly issue stop, including the end of the last chapter.
    }
  }

  void Media(const Args& args) {
    const auto status = Text(args.at(0));
    if (status == "closed" && !controls) return;
    if (!controls) {
      auto interop = get_activation_factory<SystemMediaTransportControls,
                                             ISystemMediaTransportControlsInterop>();
      check_hresult(interop->GetForWindow(window, guid_of<SystemMediaTransportControls>(),
                                          put_abi(controls)));
      controls.IsPlayEnabled(true);
      controls.IsPauseEnabled(true);
      controls.IsStopEnabled(true);
      controls.IsNextEnabled(true);
      controls.IsPreviousEnabled(true);
      buttons = controls.ButtonPressed([output = emit](auto const&, auto const& event) {
        const char* command = nullptr;
        switch (event.Button()) {
          case SystemMediaTransportControlsButton::Play: command = "play"; break;
          case SystemMediaTransportControlsButton::Pause: command = "pause"; break;
          case SystemMediaTransportControlsButton::Stop: command = "stop"; break;
          case SystemMediaTransportControlsButton::Next: command = "next"; break;
          case SystemMediaTransportControlsButton::Previous: command = "previous"; break;
          default: return;
        }
        output("command", {Value(command)});
      });
    }
    auto info = controls.DisplayUpdater();
    if (status == "closed") {
      controls.PlaybackStatus(MediaPlaybackStatus::Closed);
      controls.IsEnabled(false);
      info.ClearAll();
    } else {
      info.Type(MediaPlaybackType::Music);
      info.MusicProperties().Title(to_hstring(Text(args.at(2))));
      info.MusicProperties().AlbumTitle(to_hstring(Text(args.at(1))));
      info.MusicProperties().Artist(to_hstring(Text(args.at(1))));
      controls.PlaybackStatus(status == "playing" ? MediaPlaybackStatus::Playing :
                                                    MediaPlaybackStatus::Paused);
      controls.IsEnabled(true);
    }
    info.Update();
  }
};

WindowsSpeechPlayer::WindowsSpeechPlayer(HWND window, Emit emit)
    : state_(std::make_unique<State>(window, std::move(emit))) {}

WindowsSpeechPlayer::~WindowsSpeechPlayer() {
  try { state_->Reset(); } catch (const hresult_error&) {}
}

Value WindowsSpeechPlayer::Command(const std::string& method, const Args& args) {
  auto& s = *state_;
  if (method == "now") return Value(Now());
  if (method == "arm") {
    s.timer_version = args.at(0).LongValue();
    s.deadline = args.at(1).IsNull() ? 0 : args.at(1).LongValue();
    s.expired = false;
    s.CheckDeadline();
  } else if (method == "voices") {
    Args result;
    for (auto const& v : SpeechSynthesizer::AllVoices()) {
      result.emplace_back(Args{Value(to_string(v.Id())), Value(to_string(v.DisplayName())),
                               Value(to_string(v.Language()))});
    }
    return Value(result);
  } else if (method == "initialize") {
    try {
      if (!s.voice) s.voice = SpeechSynthesizer::DefaultVoice();
    } catch (const hresult_error& e) {
      if (static_cast<uint32_t>(e.code().value) != 0x800455a0u) throw;
      throw hresult_error(e.code(), L"Windows 无法初始化系统语音。请在系统设置中检查音色；从工程目录运行时可改用安装版重试。");
    }
  } else if (method == "voice") {
    for (auto const& v : SpeechSynthesizer::AllVoices()) {
      if (to_string(v.Id()) == Text(args.at(0)) &&
          (args.at(1).IsNull() || to_string(v.Language()) == Text(args.at(1)))) {
        if (!s.voice || v.Id() != s.voice.Id()) s.next.reset();
        s.voice = v;
        return Value(true);
      }
    }
    return Value(false);
  } else if (method == "rate") {
    auto rate = std::get<double>(args.at(0));
    if (rate != s.rate) s.next.reset();
    s.rate = rate;
  } else if (method == "prepare") {
    if (s.current && !s.CheckDeadline()) s.next = s.Synthesize(Text(args.at(0)));
  } else if (method == "speak") {
    s.Speak(Text(args.at(0)), Text(args.at(1)));
  } else if (method == "stop") {
    s.Stop();
    s.interrupted = false;
  } else if (method == "hold") {
    s.held = true;
    if (s.player) s.player.Pause();
  } else if (method == "resume") {
    if (s.held && !s.CheckDeadline()) {
      s.held = false;
      if (s.player) s.player.Play();
    }
  } else if (method == "media") {
    s.Media(args);
  } else if (method == "suspend") {
    s.Interrupt();
  } else if (method == "shutdown") {
    s.Reset();
  } else {
    throw hresult_invalid_argument();
  }
  return Value();
}

void WindowsSpeechPlayer::Tick() {
  try {
    state_->Tick();
  } catch (...) {
    const auto message = to_string(to_message());
    const auto id = state_->id;
    state_->Stop();
    if (!id.empty()) state_->emit("error", {Value(id), Value(state_->failure_kind), Value(message)});
  }
}

int WindowsSpeechPlayer::NextWakeMs() const {
  if (state_->current) return 25;
  if (state_->deadline) return static_cast<int>(
      std::clamp<int64_t>(state_->deadline - Now(), 0, INT_MAX));
  return -1;
}
