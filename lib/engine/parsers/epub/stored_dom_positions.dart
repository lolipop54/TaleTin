import '../../../domain/models/book_document.dart';
import '../../../domain/models/locator.dart';
import '../../normalization/locator_mapper.dart';
import 'dom_text_map.dart';

/// 可落盘的精确位置资料：保留空白与软断字换算所需文字，不复制HTML、图片或DOM树。
class StoredDomPositions {
  StoredDomPositions(this.data, this.content, Locator identity)
    : mapper = LocatorMapper(
        bookId: identity.bookId,
        contentVersion: identity.contentVersion,
        chapterId: identity.chapterId,
      ) {
    for (final raw in data['rows'] as List) {
      final row = _TextPosition((raw as List).cast<dynamic>());
      if (row.block < 0 || row.block >= content.blocks.length) {
        throw const FormatException('位置表的正文块不存在');
      }
      byBlock.putIfAbsent(content.blocks[row.block].id, () => []).add(row);
      byPath[row.path.join('.')] = row;
    }
    images = [for (final p in data['images'] as List) (p as List).cast<int>()];
    imageBlocks = content.blocks
        .where((b) => b.kind == BlockKind.image)
        .toList();
    if (images.length != imageBlocks.length) {
      throw const FormatException('位置表图片数不符');
    }
  }
  final Map<String, dynamic> data;
  final ChapterContent content;
  final LocatorMapper mapper;
  final byBlock = <String, List<_TextPosition>>{};
  final byPath = <String, _TextPosition>{};
  late final List<List<int>> images;
  late final List<ContentBlock> imageBlocks;
  List<Map<String, Object>> get nodes => [
    for (final r in byPath.values) {'path': r.path, 'length': r.text.length},
  ];

  String? linkAt(Locator locator) => byBlock[locator.blockId]
      ?.where(
        (r) =>
            locator.utf16Offset >= r.offset &&
            locator.utf16Offset < r.offset + r.length,
      )
      .firstOrNull
      ?.link;

  Map<String, Object> point(Locator locator, {bool end = false}) {
    final rows = byBlock[locator.blockId] ?? const <_TextPosition>[];
    if (rows.isEmpty) throw StateError('听书位置没有对应的原书文字');
    final offset = locator.utf16Offset;
    final row = rows.firstWhere(
      (r) => end ? offset <= r.offset + r.length : offset < r.offset + r.length,
      orElse: () => rows.last,
    );
    var low = 0, high = row.text.length + 1;
    while (low < high) {
      final mid = (low + high) ~/ 2, value = row.at(mid);
      if (end ? value < offset : value <= offset) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return {
      'path': row.path,
      'offset': (end ? low : low - 1).clamp(0, row.text.length),
    };
  }

  Map<String, Object> displayPoint(Locator locator) {
    final index = imageBlocks.indexWhere((b) => b.id == locator.blockId);
    return index < 0
        ? point(locator)
        : {'path': images[index], 'element': true};
  }

  Locator locatorOf(Map<String, dynamic> point) {
    final path = (point['path'] as List).cast<int>().join('.');
    if (point['element'] == true) {
      final index = images.indexWhere((p) => p.join('.') == path);
      if (index < 0) throw StateError('图片位置不存在');
      return mapper.at(imageBlocks[index], 0);
    }
    final row = byPath[path];
    if (row == null) throw StateError('文字位置不存在');
    return mapper.at(content.blocks[row.block], row.at(point['offset'] as int));
  }

  late final Map<String, Object> progressMap = _progress();
  Map<String, Object> _progress() {
    final offsets = <int>[];
    var total = 0;
    for (final block in content.blocks) {
      offsets.add(total);
      total += blockTextOf(block).length + 1;
    }
    return {
      'total': total,
      'nodes': [
        for (final raw in data['rows'] as List)
          {
            'path': raw[1],
            'start': offsets[raw[0] as int] + (raw[3] as int),
            'hidden': raw[4],
            'length': raw[5],
            'absorbed': raw[6],
            'breaks': raw[7],
          },
        for (var i = 0; i < images.length; i++)
          {
            'path': images[i],
            'start': offsets[content.blocks.indexOf(imageBlocks[i])],
            'element': true,
          },
      ],
    };
  }
}

class _TextPosition {
  _TextPosition(this.row);
  final List<dynamic> row;
  int get block => row[0] as int;
  List<int> get path => (row[1] as List).cast<int>();
  String get text => row[2] as String;
  int get offset => row[3] as int;
  int get length => row[5] as int;
  String? get link => row[8] as String?;
  int at(int value) => mappedTextOffset(
    text,
    value,
    blockOffset: offset,
    hiddenLeading: row[4] as int,
    emittedLength: length,
    absorbedLeading: row[6] as bool,
    displayBreaks: (row[7] as List).cast<int>(),
  );
}
