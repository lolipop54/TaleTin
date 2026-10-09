import 'package:flutter/material.dart';

import 'gt_tokens.dart';
import 'reading_theme.dart';

/// 文字 Token（设计文档 9.3）。
///
/// 普通界面文字继承应用主题字体；预览与专用字体由调用方明确指定。
abstract final class GtFonts {
  /// 系统衬线（Android 上解析为 Noto Serif / 思源宋体一类）
  static const String serif = 'serif';

  /// 系统默认无衬线
  static const String? sans = null;
}

/// 页面文字样式工厂。颜色由调用方传入，保持 Token 不绑定主题。
abstract final class GtText {
  /// 本地导入列表主文件名；按参考图采用比普通列表更大的字号。
  static TextStyle importFileName(Color c) => TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w600,
    height: 1.35,
    color: c,
  );

  /// text.pageTitle 21 / w600 / 1.25（对照参考图比例下调）
  static TextStyle pageTitle(Color c, {String? family}) => TextStyle(
    fontSize: 21,
    fontWeight: FontWeight.w600,
    height: 1.25,
    color: c,
    fontFamily: family,
  );

  /// text.sectionTitle 15 / w600 / 1.35
  static TextStyle sectionTitle(Color c, {String? family}) => TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    height: 1.35,
    color: c,
    fontFamily: family,
  );

  /// text.body 15 / w400 / 1.5
  static TextStyle body(Color c, {String? family, FontWeight? weight}) =>
      TextStyle(
        fontSize: 15,
        fontWeight: weight ?? FontWeight.w400,
        height: 1.5,
        color: c,
        fontFamily: family,
      );

  /// text.caption 11 / w400 / 1.4 —— 时间、进度等辅助信息
  static TextStyle caption(Color c, {String? family}) => TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w400,
    height: 1.4,
    color: c,
    fontFamily: family,
  );

  /// text.bookTitle 13 / w500 / 1.4，最多两行
  static TextStyle bookTitle(Color c, {String? family}) => TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w500,
    height: 1.4,
    color: c,
    fontFamily: family,
  );

  /// text.metric 26 / w600 / 1.15 —— 阅读时长等数据
  static TextStyle metric(Color c, {String? family}) => TextStyle(
    fontSize: 26,
    fontWeight: FontWeight.w600,
    height: 1.15,
    color: c,
    fontFamily: family,
  );

  /// 无衬线小号行内说明（分组标签、chip 等）
  static TextStyle chipLabel(Color c) => TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    height: 1.4,
    color: c,
  );
}

/// 应用主题：Material 3 基础控件 + 自定义 Token 覆盖。
abstract final class GtTheme {
  static ThemeData light({String? fontFamily}) =>
      _build(Brightness.light, GtColors.light, fontFamily);
  static ThemeData dark({String? fontFamily}) =>
      _build(Brightness.dark, GtColors.dark, fontFamily);

  static ThemeData reading(ReadingTheme theme, {String? fontFamily}) =>
      _build(theme.overlayBrightness, theme.controlsColors, fontFamily);

  static ThemeData _build(
    Brightness brightness,
    GtColors c,
    String? fontFamily,
  ) {
    final colorScheme = ColorScheme(
      brightness: brightness,
      primary: c.actionPrimary,
      onPrimary: c.onPrimary,
      secondary: c.actionPrimary,
      onSecondary: c.onPrimary,
      error: c.danger,
      onError: Colors.white,
      surface: c.surface,
      onSurface: c.textPrimary,
      surfaceContainerHighest: c.subtle,
      outline: c.borderControl,
      outlineVariant: c.borderSubtle,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: c.canvas,
      // 字体文件已在首帧前准备；null 使用 Flutter 的系统默认字体。
      fontFamily: fontFamily,
    );

    return base.copyWith(
      extensions: [c, GtMotion.light],
      splashFactory: NoSplash.splashFactory,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      dialogTheme: const DialogThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(GtRadius.dialog)),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: c.canvas,
        foregroundColor: c.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        titleTextStyle: GtText.sectionTitle(c.textPrimary, family: fontFamily),
      ),
      dividerTheme: DividerThemeData(
        color: c.borderSubtle,
        thickness: 1,
        space: 1,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? c.onPrimary : c.surface,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? c.actionPrimary
              : c.borderSubtle,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.transparent
              : c.borderControl,
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: c.actionPrimary,
        inactiveTrackColor: c.borderSubtle,
        thumbColor: c.actionPrimary,
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
        overlayColor: c.actionPrimary.withValues(alpha: 0.12),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: c.actionPrimary,
      ),
    );
  }
}
