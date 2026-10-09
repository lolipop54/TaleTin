part of 'original_body.dart';

class OriginalChapter {
  const OriginalChapter({
    required this.session,
    required this.ordinal,
    this.fontSizePx,
    this.lineHeight,
    this.paragraphGapEm,
    this.columnMarginPx = 0,
    this.indent = true,
    this.fontFamily = '',
    this.bold = false,
    this.initialFraction,
    this.themeColors,
    this.information,
    this.onHostEvent,
    this.onControllerReady,
    this.prepare,
    this.preparationRevision,
  });

  final EpubSourceSession session;
  final Future<void> Function(OriginalHostController)? prepare;
  final Object? preparationRevision;

  /// 当前章（spine 序）；变化时重新加载文档
  final int ordinal;

  /// 正文字号（像素）；变化时热更新并保持位置
  final double? fontSizePx;

  /// 行高倍数与段后间距，分页和滚动共用同一套正文覆盖。
  final double? lineHeight;
  final double? paragraphGapEm;

  /// 一页左右各留的边距（像素）：由宿主页做在列间距里，
  /// 这样翻页/拖动时「页面连同左右边距」一起滑（与简化模式同一种手感）
  final double columnMarginPx;

  /// 首行缩进开关；关闭时由宿主页覆盖原书的正文缩进。
  final bool indent;

  /// 空串保留书内字体；非空值来自阅读器的字体选项。
  final String fontFamily;
  final bool bold;

  /// 这个文档首次显示前要落到的章内比例（相邻章预览槽用：
  /// 下一章落章首 0、上一章落章末 1）；null 表示不额外定位
  final double? initialFraction;

  /// 阅读主题取色（bg / text / link）；变化时热更新
  final Map<String, String>? themeColors;
  final Map<String, Object?>? information;

  /// 宿主页上报的事件（ready / paginated / relocate / boundary / error）
  final ValueChanged<Map<String, Object?>>? onHostEvent;

  /// 控制器就绪（拿到后可以下发翻页命令）
  final ValueChanged<OriginalHostController>? onControllerReady;
}
