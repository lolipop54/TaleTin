import 'package:flutter/material.dart';

/// 全局设计 Token（值来源：docs/设计文档.md 9.2–9.5 节）。
///
/// 颜色与动效通过 ThemeExtension 挂到 ThemeData 上，
/// Widget 里用 `context.gtColors` / `context.gtMotion` 读取，禁止散落硬编码色值。

/// 共用配色按用途命名，调整色值时不必随具体色相更改名称。
/// 深色主题单独提供主色和已读标签色；其它界面颜色见下方 GtColors。
abstract final class GtPalette {
  /// 浅色／深色主题的主操作、选中和焦点色。
  static const primary = Color(0xff3a5ca1);
  // 新主色与白色各占一半，深色背景上的文字、勾号和焦点使用这套浅色。
  static const primaryDark = Color(0xff9daed0);

  /// 浅色页面底色，以及底部导航与系统底部安全区的底色。
  static const background = Color(0xfff6f6f6);
  static const navigationBackground = Color(0xffffffff);

  /// 深底提示区的文字和背景；背景也用于书签阴影。
  static const inverseText = Color(0xffded6cb);
  static const inverseBackground = Color(0xff3b3d3f);

  /// 备用辅色，当前界面未引用。
  static const secondary = Color(0xff04453d);

  /// 已读角标和列表标签；Dark 对应深色主题。
  static const completed = Color(0xff52736b);
  // 同样由已读基色调亮，保留其偏蓝绿色相。
  static const completedDark = Color(0xffa9b9b5);

  /// 备用第三配色，当前界面未引用。
  static const tertiary = Color(0xff4d522e);

  /// 危险操作、错误强调与书签条带共用。
  static const danger = Color(0xff9f342a);
}

/// 语义颜色 Token。
class GtColors extends ThemeExtension<GtColors> {
  const GtColors({
    required this.canvas,
    required this.surface,
    required this.subtle,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.borderSubtle,
    required this.borderControl,
    required this.actionPrimary,
    required this.onPrimary,
    required this.success,
    required this.warning,
    required this.danger,
    required this.focus,
    required this.scrim,
  });

  /// 页面底色 color.bg.canvas
  final Color canvas;

  /// 卡片、面板 color.bg.surface
  final Color surface;

  /// 分组标签、输入背景 color.bg.subtle
  final Color subtle;

  /// 标题、主文字
  final Color textPrimary;

  /// 次要说明
  final Color textSecondary;

  /// 可阅读的辅助信息
  final Color textMuted;

  /// 装饰分隔
  final Color borderSubtle;

  /// 必须可识别的输入/控件边界
  final Color borderControl;

  /// 主按钮/链接/选中状态
  final Color actionPrimary;

  /// 主按钮文字
  final Color onPrimary;

  /// 成功状态
  final Color success;

  /// 兼容性提示
  final Color warning;

  /// 删除、失败
  final Color danger;

  /// 输入控件焦点
  final Color focus;

  /// 模态遮罩
  final Color scrim;

  static const light = GtColors(
    canvas: GtPalette.background,
    surface: Color(0xFFFCFBFA),
    subtle: Color(0xFFEBECED),
    textPrimary: Color(0xFF232425),
    textSecondary: Color(0xFF4F5254),
    textMuted: Color(0xFF636669),
    borderSubtle: Color(0xFFD7D9DA),
    borderControl: Color(0xFF74787C),
    actionPrimary: GtPalette.primary,
    onPrimary: Color(0xFFFCFBFA),
    success: Color(0xFF297A70),
    warning: Color(0xFF723731),
    danger: GtPalette.danger,
    focus: GtPalette.primary,
    scrim: Color(0x66141415),
  );

  static const dark = GtColors(
    canvas: Color(0xFF121314),
    surface: Color(0xFF1E1F20),
    subtle: Color(0xFF2A2B2D),
    textPrimary: Color(0xFFEFEBE6),
    textSecondary: Color(0xFFC1BBB3),
    textMuted: Color(0xFF9EA1A4),
    borderSubtle: Color(0xFF3E4042),
    borderControl: Color(0xFF8B8F92),
    actionPrimary: GtPalette.primaryDark,
    onPrimary: Color(0xFF121314),
    success: Color(0xFFA4D6D0),
    warning: Color(0xFFDA9B95),
    danger: Color(0xFFEAA19A),
    focus: GtPalette.primaryDark,
    scrim: Color(0x990A0A0B),
  );

  @override
  GtColors copyWith({
    Color? canvas,
    Color? surface,
    Color? subtle,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? borderSubtle,
    Color? borderControl,
    Color? actionPrimary,
    Color? onPrimary,
    Color? success,
    Color? warning,
    Color? danger,
    Color? focus,
    Color? scrim,
  }) {
    return GtColors(
      canvas: canvas ?? this.canvas,
      surface: surface ?? this.surface,
      subtle: subtle ?? this.subtle,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
      borderSubtle: borderSubtle ?? this.borderSubtle,
      borderControl: borderControl ?? this.borderControl,
      actionPrimary: actionPrimary ?? this.actionPrimary,
      onPrimary: onPrimary ?? this.onPrimary,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
      focus: focus ?? this.focus,
      scrim: scrim ?? this.scrim,
    );
  }

  @override
  GtColors lerp(GtColors? other, double t) {
    if (other == null) return this;
    return GtColors(
      canvas: Color.lerp(canvas, other.canvas, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      subtle: Color.lerp(subtle, other.subtle, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      borderSubtle: Color.lerp(borderSubtle, other.borderSubtle, t)!,
      borderControl: Color.lerp(borderControl, other.borderControl, t)!,
      actionPrimary: Color.lerp(actionPrimary, other.actionPrimary, t)!,
      onPrimary: Color.lerp(onPrimary, other.onPrimary, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      focus: Color.lerp(focus, other.focus, t)!,
      scrim: Color.lerp(scrim, other.scrim, t)!,
    );
  }
}

/// 动效 Token（motion.fast/normal/panel 与曲线）。
class GtMotion extends ThemeExtension<GtMotion> {
  const GtMotion({
    this.fast = const Duration(milliseconds: 120),
    this.normal = const Duration(milliseconds: 220),
    this.panelIn = const Duration(milliseconds: 300),
    this.panelExit = const Duration(milliseconds: 220),
    this.curveStandard = Curves.easeInOutCubic,
    this.curveEnter = Curves.easeOutCubic,
  });

  /// 按压、选中反馈
  final Duration fast;

  /// 控制栏显隐、主题淡入
  final Duration normal;

  /// 底部面板进入
  final Duration panelIn;

  /// 底部面板退出
  final Duration panelExit;

  /// 常规过渡
  final Curve curveStandard;

  /// 入场
  final Curve curveEnter;

  @override
  GtMotion copyWith({
    Duration? fast,
    Duration? normal,
    Duration? panelIn,
    Duration? panelExit,
    Curve? curveStandard,
    Curve? curveEnter,
  }) {
    return GtMotion(
      fast: fast ?? this.fast,
      normal: normal ?? this.normal,
      panelIn: panelIn ?? this.panelIn,
      panelExit: panelExit ?? this.panelExit,
      curveStandard: curveStandard ?? this.curveStandard,
      curveEnter: curveEnter ?? this.curveEnter,
    );
  }

  @override
  GtMotion lerp(GtMotion? other, double t) {
    if (other == null) return this;
    double ms(Duration a, Duration b) =>
        a.inMilliseconds + (b.inMilliseconds - a.inMilliseconds) * t;
    return GtMotion(
      fast: Duration(milliseconds: ms(fast, other.fast).round()),
      normal: Duration(milliseconds: ms(normal, other.normal).round()),
      panelIn: Duration(milliseconds: ms(panelIn, other.panelIn).round()),
      panelExit: Duration(milliseconds: ms(panelExit, other.panelExit).round()),
    );
  }

  static const light = GtMotion();
}

/// 间距 Token：space.1/2/3/4/5/6/8/12。
abstract final class GtSpacing {
  static const double s0 = 2;
  static const double s1 = 4;
  static const double s2 = 8;
  static const double s3 = 12;
  static const double s4 = 16;
  static const double s5 = 20;
  static const double s6 = 24;
  static const double s8 = 32;
  static const double s12 = 48;
}

/// 圆角 Token。
abstract final class GtRadius {
  static const double cover = 4;
  static const double control = 10;
  static const double card = 16;
  static const double dialog = 8;
  static const double sheet = 24;
  static const double pill = 999;
}

abstract final class GtSliderSize {
  static const double thumbRadiusSmall = 16;
  static const double trackThicknessSmall = 24;
  static const double thumbRadiusLarge = 20;
  static const double trackThicknessLarge = 36;
}

/// 组件尺寸 Token。
abstract final class GtSize {
  /// 图标
  static const double iconSmall = 18;
  static const double iconNormal = 24;

  /// 最小触摸目标
  static const double touchMin = 48;

  /// 导航
  static const double appBarHeight = 56;
  static const double bottomNavHeight = 64;

  /// 封面宽高比：按 UI 参考图实测校准为 0.71（接近 1:√2），比 2:3 略矮
  static const double coverAspectRatio = 0.71;

  /// 书架网格
  static const double shelfMinItemWidth = 86;
  static const double shelfColumnGap = 16;
  static const double shelfRowGap = 24;
  static const double shelfPagePadding = 20;

  /// 阅读正文最大宽度
  static const double readingMaxWidth = 720;
}

/// 阅读页点击分区（设计文档 2.4）：左右翻页、中间唤出控制栏。
///
/// 简化排版与「原书排版」两套阅读区共用这份口径，避免两边各写一套比例后走偏。
/// 左侧 35% 上一页，中间 30% 控制面板，右侧 35% 下一页。
abstract final class GtReadingTapZones {
  /// 小于这个比例 → 上一页
  static const double previousEdge = 0.35;

  /// 大于这个比例 → 下一页；两者之间 → 唤出控制栏
  static const double nextEdge = 0.65;
}

extension GtColorsContext on BuildContext {
  GtColors get gtColors =>
      Theme.of(this).extension<GtColors>() ?? GtColors.light;
  GtMotion get gtMotion =>
      Theme.of(this).extension<GtMotion>() ?? GtMotion.light;
}
