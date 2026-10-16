/// 目录锚点 → 标准化 Locator（离线听书实现计划 6.2）。
///
/// 目录条目写的是 `href#fragment`。原书模式靠 WebView 找元素并滚动过去；
/// 听书在后台换章时没有活跃 WebView，所以这里在 Dart 侧把锚点算成 Locator：
/// 取**净化后的 DOM**（WebView 看到的就是它，脚本与事件属性已经剥掉）→
/// 找到锚点元素 → 取它之后的第一段正文文字 → 换算成块 + UTF-16 偏移。
///
/// 为什么要用净化后的文档，而不是重新解析原始 XHTML：WebView 显示的是净化产物，
/// 锚点必须落在用户真正看到的那个 DOM 上（实现计划 6.2）。
library;

import 'package:html/dom.dart';

import '../../../domain/models/book_document.dart';
import '../../../domain/models/locator.dart';
import '../../normalization/locator_mapper.dart';
import 'dom_text_map.dart';
import 'xhtml_blocks.dart';

/// 锚点映射口径版本。
///
/// 空白折叠、块切分口径变化时递增，让按它缓存过的锚点映射失效并重建
/// （实现计划 6.2 的旁路缓存键：bookId + contentVersion + resourceHref + 本版本号）。
const int kAnchorMappingVersion = 1;

/// 一个正文文件的锚点对照表。
class ChapterAnchorMap {
  ChapterAnchorMap._({
    required this.blocks,
    required this.textMap,
    required this.document,
    required this.documentOrder,
    required this.mapper,
  });

  /// 解析净化后的章节文档，建立锚点对照表。
  ///
  /// [resourceHref] 是这一章在归档里的路径（如 `OEBPS/Text/ch1.xhtml`）。
  /// 它只用于解析图片等相对引用：图片用占位尺寸登记，**块的数量与顺序必须和
  /// 导入时一致**，否则块 ID 会整体错位、锚点就对不上了。
  factory ChapterAnchorMap.parse({
    required String sanitizedHtml,
    required String resourceHref,
    required String bookId,
    required int contentVersion,
    required String chapterId,
    Set<String>? availableImages,
  }) {
    final builder = XhtmlBlockBuilder(
      basePath: resourceHref,
      resolveImage: (entryPath) =>
          availableImages != null && !availableImages.contains(entryPath)
          ? null
          : ResolvedImage(
              // 尺寸不参与位置换算，这里不读文件
              resourcePath: entryPath,
              width: 0,
              height: 0,
            ),
    );
    final result = builder.convert(sanitizedHtml);
    return ChapterAnchorMap._(
      blocks: result.blocks,
      textMap: result.textMap ?? DomTextMap.empty,
      document: builder.document!,
      documentOrder: _documentOrder(builder.document!),
      mapper: LocatorMapper(
        bookId: bookId,
        contentVersion: contentVersion,
        chapterId: chapterId,
      ),
    );
  }

  /// 这一章解析出来的块，顺序与导入时存下的正文一致
  final List<ContentBlock> blocks;

  /// DOM 文本节点 → 块内偏移的对照表
  final DomTextMap textMap;

  /// 净化后的 DOM（与 [blocks] 同一趟解析）
  final Document document;

  /// 文档顺序（父节点在前）的全部节点，锚点按它往后找第一段文字
  final List<Node> documentOrder;

  /// 生成 Locator 的换算器
  final LocatorMapper mapper;

  final Map<String, ContentBlock> _blocksById = {};
  Map<Node, int>? _indexOf;

  /// [fragment]（目录里的 `#` 后面那段）在这一章里的标准化位置。
  ///
  /// 锚点元素是空容器或挂在标题前面的包装元素时，取它后面的第一段正文文字，
  /// 与原书模式滚到该元素的效果一致。找不到锚点、或锚点之后没有文字时返回 null
  /// （调用方据此报“这一条定位失败”，不能拿同名标题顶替）。
  Locator? locatorOfAnchor(String fragment) {
    if (fragment.isEmpty) return null;
    final element = _findAnchorElement(fragment);
    if (element == null) return null;
    final start = (_indexOf ??= _indexNodes(documentOrder))[element];
    if (start == null) return null;

    for (var i = start; i < documentOrder.length; i++) {
      final node = documentOrder[i];
      if (node is! Text) continue;
      final segment = textMap.segmentOf(node);
      if (segment == null) continue; // 纯空白节点，没有正文可落
      final block = _blockOf(segment.blockId);
      if (block == null) return null;
      return mapper.at(block, segment.blockOffset);
    }
    return null;
  }

  /// 某个块（按 ID）；找不到返回 null。
  ContentBlock? _blockOf(String blockId) {
    if (_blocksById.isEmpty) {
      for (final block in blocks) {
        _blocksById[block.id] = block;
      }
    }
    return _blocksById[blockId];
  }

  /// 锚点元素：优先 `id`，其次 `<a name>`（EPUB2 里的老写法）。
  Element? _findAnchorElement(String fragment) {
    // html 包的 getElementById 实际使用 CSS 选择器；合法的 id 中也可能有
    // 百分号、冒号或点号。按属性原值比较，不能把书内 id 当选择器解释。
    final elements = document.querySelectorAll('[id],a[name]');
    Element? find(String value) {
      Element? named;
      for (final element in elements) {
        if (element.id == value) return element;
        if (element.attributes['name'] == value) named ??= element;
      }
      return named;
    }

    final raw = find(fragment);
    if (raw != null) return raw;
    // 原样优先，兼容旧书库保存的编码片段，不需要重新导入。
    if (fragment.contains('%')) {
      try {
        return find(Uri.decodeComponent(fragment));
      } on FormatException {
        // 外部书籍的坏转义不是有效锚点，继续返回未找到。
      } on ArgumentError {
        // Uri.decodeComponent 对不完整的百分号转义抛 ArgumentError。
      }
    }
    return null;
  }
}

/// 文档顺序（父节点在前）的全部节点。
///
/// 根节点是 `Document` 而不是 `Element`，所以不能只对 `Element` 递归；
/// 叶子节点（文本）的 [Node.nodes] 是空表，直接遍历即可。
List<Node> _documentOrder(Node root) {
  final order = <Node>[];
  void visit(Node node) {
    order.add(node);
    for (final child in node.nodes) {
      visit(child);
    }
  }

  visit(root);
  return order;
}

/// 节点 → 它在文档顺序里的下标。
Map<Node, int> _indexNodes(List<Node> order) {
  final index = <Node, int>{};
  for (var i = 0; i < order.length; i++) {
    index[order[i]] = i;
  }
  return index;
}
