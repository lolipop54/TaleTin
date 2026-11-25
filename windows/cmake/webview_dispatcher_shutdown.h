#pragma once

#include <windows.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.System.h>

// A queue on the UI thread can complete shutdown only while that thread still
// dispatches messages. DLL static destruction runs after its message loop exits.
template <class Controller>
void TaleTinShutdownDispatcher(const Controller& controller) noexcept {
  try {
    auto queue = controller.template as<winrt::Windows::System::DispatcherQueueController>();
    auto shutdown = queue.ShutdownQueueAsync();
    winrt::handle finished{CreateEventW(nullptr, TRUE, FALSE, nullptr)};
    winrt::check_bool(static_cast<bool>(finished));
    const HANDLE event = finished.get();
    shutdown.Completed([event](auto const&, auto) { SetEvent(event); });
    bool quit = false;
    int exit_code = 0;
    while (MsgWaitForMultipleObjectsEx(1, &event, INFINITE, QS_ALLINPUT,
                                       MWMO_INPUTAVAILABLE) == WAIT_OBJECT_0 + 1) {
      MSG message;
      while (PeekMessage(&message, nullptr, 0, 0, PM_REMOVE)) {
        if (message.message == WM_QUIT) {
          quit = true;
          exit_code = static_cast<int>(message.wParam);
        } else {
          TranslateMessage(&message);
          DispatchMessage(&message);
        }
      }
    }
    if (quit) PostQuitMessage(exit_code);
  } catch (const winrt::hresult_error&) {
    // A system-initiated teardown can already have disconnected the dispatcher.
  }
}
