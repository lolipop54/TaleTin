import 'package:win32/win32.dart';

enum WheelModifier { none, control, other }

/// 切回窗口后，Flutter 的修饰键状态可能要等下一个键盘事件才同步。
WheelModifier readWindowsWheelModifier() {
  bool pressed(VIRTUAL_KEY key) => GetAsyncKeyState(key) & 0x8000 != 0;

  if (pressed(VK_SHIFT) ||
      pressed(VK_MENU) ||
      pressed(VK_LWIN) ||
      pressed(VK_RWIN)) {
    return WheelModifier.other;
  }
  return pressed(VK_CONTROL) ? WheelModifier.control : WheelModifier.none;
}
