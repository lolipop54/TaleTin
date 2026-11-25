#include <flutter/dart_project.h>
#include <flutter/flutter_engine.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {
int RunReaderWindow() {
  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  if (command_line_arguments.size() == 3 &&
      command_line_arguments.front() == "--book-page-worker") {
    command_line_arguments.erase(command_line_arguments.begin());
    project.set_dart_entrypoint_arguments(std::move(command_line_arguments));
    ::SetPriorityClass(::GetCurrentProcess(), BELOW_NORMAL_PRIORITY_CLASS);
    flutter::FlutterEngine engine(project);
    if (!engine.Run("bookPageWorker")) return EXIT_FAILURE;
    MSG event;
    while (::GetMessage(&event, nullptr, 0, 0) > 0) {
      ::TranslateMessage(&event);
      ::DispatchMessage(&event);
      engine.ProcessMessages();
    }
    return EXIT_SUCCESS;
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"TaleTin", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  return EXIT_SUCCESS;
}
}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  const int result = RunReaderWindow();
  // Release the window and its plugins before tearing down their COM apartment.
  ::CoUninitialize();
  return result;
}
