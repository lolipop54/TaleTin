/// 屏幕相关的设备能力：窗口亮度与电量。
///
/// 亮度只改本应用窗口的属性，不动系统设置：离开阅读页把覆盖清掉，
/// 窗口就回到系统亮度（设计文档 2.3「关闭阅读器后恢复原窗口亮度」）。
/// 平台拿不到值时返回 null，界面按「不知道」处理，不猜。
library;

abstract interface class ScreenControls {
  /// 设置窗口亮度 0–1；传 null 表示恢复跟随系统
  Future<void> setWindowBrightness(double? value);

  /// 当前系统亮度 0–1；拿不到时返回 null
  Future<double?> systemBrightness();

  /// 电量百分比 0–100；拿不到时返回 null
  Future<int?> batteryLevel();
}
