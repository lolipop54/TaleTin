/// 排版参数：既是渲染依据，也是分页缓存键的来源（实现计划 4 / 5.8）。
///
/// 测量与绘制必须用这里给出的同一份 [TextStyle]、同一个内容宽度和**同一个
/// TextScaler 实例**：Android 14+ 的系统字号缩放是非线性的，折算成单一系数会
/// 让布局行数与渲染行数不一致，页尾出现整行空白（设计文档 6.4）。
library;

import 'package:flutter/painting.dart';

import '../../domain/models/book_document.dart';
import '../../domain/models/reading_settings.dart';

/// 标题相对正文的字号增量（按 h1–h6）
const List<double> _headingSizeDelta = [6, 4, 3, 2, 1, 1];

/// 标题行高倍数：标题不跟随正文字号的行高，2.2 倍行高放在标题上太散
const double _headingLineHeight = 1.35;

/// 脚注字号相对正文的减小量
const double _footnoteSizeDelta = 2;

class LayoutOptions {
  const LayoutOptions({
    required this.settings,
    required this.contentSize,
    required this.textScaler,
  });

  final ReadingSettings settings;

  /// 正文可用区域（已扣除页边距、顶部信息行、底部状态行与安全区）
  final Size contentSize;

  /// 与界面渲染使用的同一个实例（来自 `MediaQuery.textScalerOf`）
  final TextScaler textScaler;

  /// 引擎版本：分页规则变化时递增，让旧缓存自动失效
  static const int engineVersion = 3;

  double get contentWidth => contentSize.width;

  double get contentHeight => contentSize.height;

  /// 段后间距像素值
  double get paragraphGap => settings.paragraphGap;

  /// 首行缩进前缀。
  ///
  /// 用真实字符（两个全角空格）参与换行，而不是 padding：缩进会缩小首行可用宽度，
  /// 用 padding 会让测量与渲染差一行（实现计划 5.2）。
  String get indentPrefix => '\u3000\u3000';

  /// 块内容宽度：列表项左侧留 1em 缩进，其余块用满宽。
  double contentWidthFor(BlockKind kind) => kind == BlockKind.listItem
      ? contentWidth - settings.fontSize.toDouble()
      : contentWidth;

  /// 列表项绘制时的左侧偏移
  double insetFor(BlockKind kind) =>
      kind == BlockKind.listItem ? settings.fontSize.toDouble() : 0;

  /// 文本样式工厂：测量与绘制**只能**通过它取样式。
  TextStyle textStyleFor(
    BlockKind kind, {
    int? level,
    bool bold = false,
    bool italic = false,
  }) {
    final base = settings.fontSize.toDouble();
    final family = settings.fontFamily;
    final weight = FontWeight.values[settings.fontWeight ~/ 100 - 1];
    return switch (kind) {
      BlockKind.heading => TextStyle(
          fontSize: base + _headingSizeDelta[(level ?? 1).clamp(1, 6) - 1],
          fontWeight: settings.fontWeight == 700 ? FontWeight.w700 : FontWeight.w600,
          height: _headingLineHeight,
          fontFamily: family,
        ),
      BlockKind.footnote => TextStyle(
          fontSize: base - _footnoteSizeDelta,
          fontWeight: weight,
          height: settings.lineHeight,
          fontFamily: family,
        ),
      _ => TextStyle(
          fontSize: base,
          height: settings.lineHeight,
          fontWeight: bold && settings.fontWeight < 600 ? FontWeight.w600 : weight,
          fontStyle: italic ? FontStyle.italic : FontStyle.normal,
          fontFamily: family,
        ),
    };
  }

  /// 块前是否补段距：标题与其后紧跟的块之间用段距的一半做呼吸，正文块之间用整段距。
  double? gapBefore(BlockKind previous, BlockKind current) {
    if (previous == BlockKind.heading) return paragraphGap * 0.5;
    return paragraphGap;
  }

  /// 分页缓存键：内容版本、章节、字体、字号/行高/段距/缩进/页边距、内容区尺寸、
  /// TextScaler 与引擎版本全部在内；颜色主题不在键内（换主题不重排）。
  String get layoutSignature {
    final scaler = textScaler;
    // 采样几个字号点：既能区分线性倍数，也能区分非线性缩放曲线
    final scalerKey = [
      scaler.scale(10).toStringAsFixed(2),
      scaler.scale(20).toStringAsFixed(2),
      scaler.scale(40).toStringAsFixed(2),
    ].join(',');
    return [
      'v$engineVersion',
      'f${settings.fontFamily ?? 'system'}',
      's${settings.fontSize}',
      'weight${settings.fontWeight}|originalFont${settings.useOriginalFont}',
      'l${settings.lineHeight}',
      'g${settings.paragraphGapEm}',
      'p${settings.horizontalPadding}',
      'i${settings.indent ? 1 : 0}',
      'w${contentSize.width.toStringAsFixed(1)}',
      'h${contentSize.height.toStringAsFixed(1)}',
      'ts$scalerKey',
    ].join('|');
  }

  /// 该块能否被拆到两页（图片、分隔线不可拆）
  static bool isSplittable(BlockKind kind) => switch (kind) {
        BlockKind.image || BlockKind.divider => false,
        _ => true,
      };
}
