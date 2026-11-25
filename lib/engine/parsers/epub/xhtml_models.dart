import '../../../domain/models/book_document.dart';
import '../../../domain/models/content_table.dart';
import 'dom_text_map.dart';

/// 图片解析结果：已落盘资源路径 + 尺寸。
class ResolvedImage {
  const ResolvedImage({
    required this.resourcePath,
    required this.width,
    required this.height,
    this.svgRatioOnly,
  });

  final String resourcePath;
  final int width;
  final int height;
  final bool? svgRatioOnly;

  factory ResolvedImage.fromIndex(String path, List<int> dimensions) =>
      ResolvedImage(
        resourcePath: path,
        width: dimensions[0],
        height: dimensions[1],
        svgRatioOnly: dimensions.length > 2 ? dimensions[2] == 1 : null,
      );

  List<int> toIndex() => [
    width,
    height,
    if (svgRatioOnly != null) svgRatioOnly! ? 1 : 0,
  ];
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
    this.stylesJson,
    this.displaySourceJson,
    this.cssTrace,
  });

  final List<ContentBlock> blocks;
  final List<ContentTable> tables;
  final int? statisticsLength;
  final String? statisticsSingleImage;

  /// Rust 转换时算出的章内样式表（批次 C）；统计与旧路径可能为空。
  final Map<String, Object?>? stylesJson;

  /// S1 显示来源索引：元素父子、顺序、块范围和表格引用；旧路径为空。
  final Map<String, Object?>? displaySourceJson;
  final Map<String, Object?>? cssTrace;
  int get textLength =>
      statisticsLength ?? blocks.fold(0, (sum, b) => sum + b.textLength);
  String? get singleImagePath => statisticsLength != null
      ? statisticsSingleImage
      : (blocks.length == 1 && blocks.single.kind == BlockKind.image
            ? blocks.single.resourcePath
            : null);

  /// 只传递原书的封面线索。是否只有一张可见图片，要等本次 CSS 生效后判断。
  Map<String, Object?>? displayWithCover(
    List<String> entries,
    String path, {
    required bool first,
    String? title,
  }) {
    final source = displaySourceJson;
    if (source == null) return null;
    final named =
        first &&
        (RegExp(
              r'^(cover|封面)$',
              caseSensitive: false,
            ).hasMatch(title?.trim() ?? '') ||
            RegExp(
              r'(^|/)(cover|封面)\.x?html?$',
              caseSensitive: false,
            ).hasMatch(path));
    if (named || entries.contains(path)) return {...source, 'coverPage': true};
    for (final block in blocks) {
      if (block.kind == BlockKind.image &&
          entries.any((entry) => block.resourcePath == 'res/$entry')) {
        return {...source, 'coverImage': block.resourcePath};
      }
    }
    // 单图的旧逐章文件只需补查一次封面身份；普通章节沿用原索引。
    return singleImagePath != null || first ? {...source, 'coverPage': false} : source;
  }

  /// 第一个标题（或首段摘录），作为章节标题兜底
  final String? headingTitle;
  final Set<String> warnings;

  /// DOM 文本节点 ↔ 块内偏移的对照表（听书锚点定位用，见 `dom_text_map.dart`）。
  ///
  /// 与 [blocks] 来自同一次遍历，因此两者一定对应；没有正文时为 null。
  final DomTextMap? textMap;
}
