import 'dart:isolate';

import 'package:html/dom.dart';

import '../../../domain/models/book_document.dart';
import '../../../domain/models/locator.dart';
import '../../normalization/locator_mapper.dart';
import 'anchor_locator.dart';
import 'epub_archive.dart';
import 'epub_dom.dart';
import 'stored_dom_positions.dart';

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
  Locator locator, {
  bool prepareProgressMap = false,
  bool prepareStored = false,
}) => Isolate.run(() {
  final result = LocatorDomMap.parse(html, href, content, locator);
  if (prepareStored) {
    final stored = LocatorDomMap.fromPrepared(
      result.preparedData,
      href,
      content,
      locator,
    );
    if (prepareProgressMap) stored.progressMap;
    return stored;
  }
  // 位置映射随目标网页并行准备；不能回到主线程才遍历全章生成发送数据。
  if (prepareProgressMap) result.progressMap;
  return result;
});

/// 每个净化资源只解析一次；路径相对 body，框架节点不得插入正文之前。
class LocatorDomMap {
  LocatorDomMap._(this._map, this.content, this.href) : _stored = null;
  LocatorDomMap.fromPrepared(
    Map<String, dynamic> data,
    this.href,
    this.content,
    Locator identity,
  ) : _map = null,
      _stored = StoredDomPositions(data, content, identity);
  final ChapterAnchorMap? _map;
  final StoredDomPositions? _stored;
  ChapterAnchorMap get map => _map!;

  /// 缓存表不保留DOM树，但选句、跨页扩选仍需要同一份文字位置换算器。
  LocatorMapper get mapper => _stored?.mapper ?? map.mapper;
  final ChapterContent content;
  final String href;
  late final _preparedIndices = {
    for (final (index, block) in map.blocks.indexed) block.id: index,
  };

  late final Map<String, dynamic> preparedData =
      _stored?.data ??
      {
        'rows': [
          for (final s in map.textMap.segments)
            [
              _preparedIndices[s.blockId]!,
              _path(s.node),
              s.node.text,
              s.blockOffset,
              s.hiddenLeading,
              s.emittedLength,
              s.absorbedLeading,
              s.displayBreaks,
              _linkOf(s.node),
            ],
        ],
        'images': imagePaths,
      };

  String? _linkOf(Node node) {
    for (var e = node.parent; e != null; e = e.parent) {
      if (e.localName == 'a') return e.attributes['href'];
    }
    return null;
  }

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
    if (_stored != null) return _stored.linkAt(locator);
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
    if (_stored != null) return _stored.point(locator, end: end);
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
    if (_stored != null) return _stored.displayPoint(locator);
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
  List<Map<String, Object>> get nodes =>
      _stored?.nodes ??
      [
        for (final segment in map.textMap.segments)
          {'path': _path(segment.node), 'length': segment.rawLength},
      ];

  /// 滚动宿主沿用正文图片顺序，包含 SVG image，排除未计入正文的内联图片。
  List<List<int>> get imagePaths =>
      _stored?.images ?? [for (final image in _images) _path(image)];

  /// 发给网页的内容坐标表，只含路径、累计长度和既有空白折叠参数。
  /// 网页按同一规则算信息行进度，不能拿临时已知页数当作全章页数。
  late final Map<String, Object> progressMap =
      _stored?.progressMap ?? _buildProgressMap();

  Map<String, Object> _buildProgressMap() {
    final offsets = <String, int>{};
    var total = 0;
    for (final block in content.blocks) {
      offsets[block.id] = total;
      total += blockTextOf(block).length + 1;
    }
    // 历史块号可能与本次 DOM 解析的块号不同；沿用已验证的块序对应关系。
    final mappedOffsets = {
      for (var i = 0; i < map.blocks.length; i++)
        map.blocks[i].id: offsets[content.blocks[i].id]!,
    };
    final images = content.blocks
        .where((b) => b.kind == BlockKind.image)
        .toList();
    return {
      'total': total,
      'nodes': [
        for (final s in map.textMap.segments)
          {
            'path': _path(s.node),
            'start': mappedOffsets[s.blockId]! + s.blockOffset,
            'hidden': s.hiddenLeading,
            'length': s.emittedLength,
            'absorbed': s.absorbedLeading,
            'breaks': s.displayBreaks,
          },
        for (final (index, image) in _images.indexed)
          {
            'path': _path(image),
            'start': offsets[images[index].id]!,
            'element': true,
          },
      ],
    };
  }

  Locator locatorOf(Map<String, dynamic> point) {
    if (_stored != null) return _stored.locatorOf(point);
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
