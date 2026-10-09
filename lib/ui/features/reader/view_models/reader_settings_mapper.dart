/// 界面阅读设置 ↔ 引擎排版设置的换算。
///
/// 界面上的字号、行高、页边距就是排版参数本身；这里放三处口径对齐：
/// 字体三选 ↔ 系统 font family、阅读主题 id ↔ 主题枚举、段落间距的像素 ↔ em。
library;

import '../../../core/theme/reading_theme.dart';

/// 字体三选（阶段 1 用系统字体近似，真实字体包后续接入）
enum ReadingFont { system, song, kai }

/// 面板字体 → 系统 font family。
/// 具体字体文件后续随包提供，这里先用系统字体近似。
String? readingFontFamily(ReadingFont font) => switch (font) {
      ReadingFont.system => null,
      ReadingFont.song => 'serif',
      ReadingFont.kai => 'KaiTi',
    };

/// font family → 面板字体（读回持久化设置时用）
ReadingFont readingFontOf(String? family) => switch (family) {
      'serif' => ReadingFont.song,
      'KaiTi' => ReadingFont.kai,
      _ => ReadingFont.system,
    };

/// 主题 id → 阅读主题；没存过或名字对不上时用内置默认主题
ReadingTheme readingThemeOf(String? id) =>
    id == null ? kDefaultReadingTheme : ReadingTheme.values.asNameMap()[id] ?? kDefaultReadingTheme;
