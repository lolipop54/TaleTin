import 'package:flutter/material.dart';

import '../../../domain/models/annotation.dart';
import 'gt_tokens.dart';

/// 阅读主题：独立于 App 主题，不随系统深色自动覆盖单书选择。
/// 值来源：设计文档 9.2 阅读主题表。
enum ReadingTheme {
  paper('纸白', Color(0xFFF1EDE7), Color(0xFF232425), Color(0xFF636669)),
  white('明亮', Color(0xFFFCFBFA), Color(0xFF232425), Color(0xFF636669)),
  green('护眼', Color(0xFFE5EDDF), Color(0xFF283429), Color(0xFF586650)),
  night('夜间', Color(0xFF121314), Color(0xFFEFEBE6), Color(0xFF9EA1A4));

  const ReadingTheme(this.label, this.background, this.primary, this.secondary);

  /// 全局设置与书内面板共用展示顺序，枚举顺序不参与持久化变更。
  static const displayOrder = [white, paper, green, night];

  /// 面板里的展示名（明亮/柔和/护眼/夜间按参考图，柔和=paper）
  final String label;
  final Color background;
  final Color primary;
  final Color secondary;

  Color get speechHighlight => this == ReadingTheme.night
      ? const Color(0xFF55461F)
      : const Color(0xFFF5DF8B);

  /// 阅读页脚手架状态栏图标的亮度
  Brightness get overlayBrightness =>
      this == ReadingTheme.night ? Brightness.dark : Brightness.light;

  /// 面板与正文共用底色和文字色，输入区、边界保留必要的明暗区别。
  GtColors get controlsColors => _controlPalettes[this]!;
}

// 四套固定颜色只生成一次，供 Material、Forui 和正文中的浮动菜单共用。
final _controlPalettes = {
  for (final theme in ReadingTheme.values)
    theme: (theme == ReadingTheme.night ? GtColors.dark : GtColors.light)
        .copyWith(
          canvas: theme.background,
          surface: theme.background,
          subtle: Color.lerp(theme.background, theme.primary, .07),
          textPrimary: theme.primary,
          textSecondary: theme.secondary,
          textMuted: theme.secondary,
          borderSubtle: Color.lerp(theme.background, theme.primary, .18),
          borderControl: Color.lerp(theme.background, theme.primary, .55),
        ),
};

/// 阅读页 UI 参考图中的默认主题是「柔和」（纸色）。
const ReadingTheme kDefaultReadingTheme = ReadingTheme.paper;

/// 笔记高亮底色（浅色模式建议值，深色 #55461F 暂随 App 主题后续接入）。
const Color kHighlightYellow = Color(0xFFF5DF8B);
const Color kHighlightBlue = Color(0xFFB7C9F0);
const Color kHighlightGreen = Color(0xFFC9E4C5);

/// 没有底色的「文字笔记」用的淡灰标签底色
const Color kHighlightGray = Color(0xFFEBECED);

/// 标注保存的颜色名 → 底色。
///
/// 数据库里存的是名字（yellow/blue/green），深浅主题各自映射，
/// 编辑器色板与笔记列表都用这一份，避免两处色值走偏。
Color highlightColorOf(AnnotationColor? color) => switch (color) {
  AnnotationColor.yellow => kHighlightYellow,
  AnnotationColor.blue => kHighlightBlue,
  AnnotationColor.green => kHighlightGreen,
  null => kHighlightGray,
};

/// 持久高亮铺在正文下面时的底色：色板同源、加透明度。
///
/// 文字要能压在上面看清，所以不用色板的不透明色；深色主题下正文底色本来就深，
/// 半透明的高亮仍然看得见（设计文档 9.6 的颜色按名字存、随主题映射）。
Color pageHighlightColorOf(AnnotationColor? color) =>
    highlightColorOf(color).withValues(alpha: 0.45);

/// 正文里链接的颜色（设计文档 9.2 的 color.action.primary，浅/深两套）。
///
/// 原书排版模式把它注入 WebView 覆盖原书的链接色——夜间主题下仍要看得清。
Color readingLinkColor(ReadingTheme theme) => theme == ReadingTheme.night
    ? GtColors.dark.actionPrimary
    : GtColors.light.actionPrimary;

/// `#RRGGBB` 形式的颜色值（注入 WebView 的 CSS 用）。
String hexOf(Color color) =>
    '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
