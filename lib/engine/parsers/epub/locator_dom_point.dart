import 'dart:isolate';

import 'package:html/dom.dart';

import '../../../domain/models/book_document.dart';
import '../../../domain/models/locator.dart';
import '../../normalization/locator_mapper.dart';
import 'anchor_locator.dart';
import 'epub_archive.dart';
import 'epub_dom.dart';

/// 用块序和源节点路径定位，重复句不参与搜索，旧书无需重新导入。
Map<String, Object> locatorDomPoint(
  String html,
  String href,
  ChapterContent content,
  Locator locator,
) => LocatorDomMap.parse(html, href, content, locator).point(locator);

/// 独立函数只捕获可发送的正文参数，避免把控制器的 Future 缓存带入 isolate。
Future<LocatorDomMap> parseLocatorDomMap(
  String html,
  String href,
  ChapterContent content,
  Locator locator,
) => Isolate.run(() => LocatorDomMap.parse(html, href, content, locator));

/// 每个净化资源只解析一次；路径相对 body，框架节点不得插入正文之前。
class LocatorDomMap {
  LocatorDomMap._(this.map, this.content, this.href);
  final ChapterAnchorMap map;
  final ChapterContent content;
  final String href;

  late final _availableImages = {
    for (final block in map.blocks)
      if (block.kind == BlockKind.image) block.resourcePath,
  };

  // 不把导入时跳过的 data: 脚注图计入插图序号，后续真实插图仍能双向定位。
  late final _images = map.document.querySelectorAll('img,image').where((
    element,
  ) {
    final src =
        domAttribute(element, 'src') ??
        domAttribute(element, 'xlink:href') ??
        domAttribute(element, 'href');
    final path = src == null ? null : resolveEntryPath(href, src);
    return path != null && _availableImages.contains(path);
  }).toList();

  /// 旧书也从原文节点取链接，不改正文块号或重新导入。
  String? linkAt(Locator locator) {
    final index = content.blocks.indexWhere((b) => b.id == locator.blockId);
    if (index < 0) return null;
    final segment = map.textMap
        .segmentsOfBlock(map.blocks[index].id)
        .where(
          (s) =>
              locator.utf16Offset >= s.blockOffset &&
              locator.utf16Offset < s.blockOffset + s.emittedLength,
        )
        .firstOrNull;
    for (
      var element = segment?.node.parent;
      element != null;
      element = element.parent
    ) {
      if (element.localName == 'a') return element.attributes['href'];
    }
    return null;
  }

  static LocatorDomMap parse(
    String html,
    String href,
    ChapterContent content,
    Locator locator,
  ) {
    final map = ChapterAnchorMap.parse(
      sanitizedHtml: html,
      resourceHref: href,
      bookId: locator.bookId,
      contentVersion: locator.contentVersion,
      chapterId: locator.chapterId,
      // 正文已按归档实际条目确认图片；不存在或大小写写错的引用不能凭空加块。
      availableImages: {
        for (final block in content.blocks)
          if (block.kind == BlockKind.image && block.resourcePath != null)
            block.resourcePath!.startsWith('res/')
                ? block.resourcePath!.substring(4)
                : block.resourcePath!,
      },
    );
    if (map.blocks.length != content.blocks.length ||
        map.blocks.indexed.any(
          (item) =>
              blockTextOf(item.$2) != blockTextOf(content.blocks[item.$1]),
        )) {
      throw StateError('原书文字与听书位置不一致');
    }
    return LocatorDomMap._(map, content, href);
  }

  /// 范围终点取最早边界，起点越过折叠空白；避免末尾空白越入下一节点。
  Map<String, Object> point(Locator locator, {bool end = false}) {
    final index = content.blocks.indexWhere((b) => b.id == locator.blockId);
    if (index < 0) throw StateError('听书位置的正文块不存在');
    final segments = map.textMap.segmentsOfBlock(map.blocks[index].id);
    if (segments.isEmpty) throw StateError('听书位置没有对应的原书文字');
    final offset = locator.utf16Offset;
    final segment = segments.firstWhere(
      (s) => end
          ? offset <= s.blockOffset + s.emittedLength
          : offset < s.blockOffset + s.emittedLength,
      orElse: () => segments.last,
    );
    // 找最后一个仍映射到目标偏移的位置，越过被裁剪/折叠的空白。
    var low = 0;
    var high = segment.rawLength + 1;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      final value = map.textMap.blockOffsetOf(segment.node, mid)!;
      if (end ? value < offset : value <= offset) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return {
      'path': _path(segment.node),
      'offset': (end ? low : low - 1).clamp(0, segment.rawLength),
    };
  }

  /// 阅读定位也可能落在封面或插图；图片没有文字节点，直接定位对应元素。
  Map<String, Object> displayPoint(Locator locator) {
    final images = content.blocks
        .where((b) => b.kind == BlockKind.image)
        .toList();
    final index = images.indexWhere((b) => b.id == locator.blockId);
    if (index < 0) return point(locator);
    final elements = _images;
    return {'path': _path(elements[index]), 'element': true};
  }

  final _paths = <Node, List<int>>{};
  List<int> _path(Node node) => _paths.putIfAbsent(node, () {
    final path = <int>[];
    while (node != map.document.body) {
      final parent = node.parentNode;
      if (parent == null) throw StateError('听书文字不在正文内');
      path.add(parent.nodes.indexOf(node));
      node = parent;
    }
    return path.reversed.toList();
  });

  /// 发给宿主的已知文本节点；每个文档只解析一次，之后复用节点引用。
  List<Map<String, Object>> get nodes => [
    for (final segment in map.textMap.segments)
      {'path': _path(segment.node), 'length': segment.rawLength},
  ];

  /// 滚动宿主沿用正文图片顺序，包含 SVG image，排除未计入正文的内联图片。
  List<List<int>> get imagePaths => [for (final image in _images) _path(image)];

  Locator locatorOf(Map<String, dynamic> point) {
    Node node = map.document.body!;
    for (final index in point['path'] as List) {
      node = node.nodes[index as int];
    }
    if (point['element'] == true) {
      final index = _images.indexOf(node as Element);
      final images = content.blocks
          .where((b) => b.kind == BlockKind.image)
          .toList();
      if (index < 0 || index >= images.length) throw StateError('图片位置不存在');
      return map.mapper.at(images[index], 0);
    }
    final text = node as Text;
    final segment = map.textMap.segmentOf(text)!;
    final index = map.blocks.indexWhere((b) => b.id == segment.blockId);
    return map.mapper.at(
      content.blocks[index],
      map.textMap.blockOffsetOf(text, point['offset'] as int)!,
    );
  }
}
