import '../../../domain/models/book_document.dart';
import '../../../domain/models/content_table.dart';
import 'dom_text_map.dart';

/// 图片解析结果：已落盘资源路径 + 尺寸。
class ResolvedImage {
  const ResolvedImage({
    required this.resourcePath,
    required this.width,
    required this.height,
  });

  final String resourcePath;
  final int width;
  final int height;
}

/// 解析一行内引用的图片；返回 null 表示该图片不可用（跳过）。
typedef ImageResolver = ResolvedImage? Function(String entryPath);

class XhtmlBlocks {
  const XhtmlBlocks({
    required this.blocks,
    required this.headingTitle,
    required this.warnings,
    this.textMap,
    this.tables = const [],
    this.statisticsLength,
    this.statisticsSingleImage,
  });

  final List<ContentBlock> blocks;
  final List<ContentTable> tables;
  final int? statisticsLength;
  final String? statisticsSingleImage;
  int get textLength =>
      statisticsLength ?? blocks.fold(0, (sum, b) => sum + b.textLength);
  String? get singleImagePath => statisticsLength != null
      ? statisticsSingleImage
      : (blocks.length == 1 && blocks.single.kind == BlockKind.image
            ? blocks.single.resourcePath
            : null);

  /// 第一个标题（或首段摘录），作为章节标题兜底
  final String? headingTitle;
  final Set<String> warnings;

  /// DOM 文本节点 ↔ 块内偏移的对照表（听书锚点定位用，见 `dom_text_map.dart`）。
  ///
  /// 与 [blocks] 来自同一次遍历，因此两者一定对应；没有正文时为 null。
  final DomTextMap? textMap;
}
