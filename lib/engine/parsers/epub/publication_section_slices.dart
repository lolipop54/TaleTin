import '../../../domain/models/book_document.dart';
import '../../../domain/models/display_source_index.dart';
import '../../../domain/services/chapter_sections.dart';
import '../../styles/chapter_styler.dart';
import '../../styles/style_box_value.dart';

const publicationSectionMinText = 48 * 1024;
const publicationSectionMinHtml = 256 * 1024;
const publicationSectionTarget = 12 * 1024;

/// 先按完整 XHTML 的上下文计算正文和样式，再切分这些结果。
/// 这样条件 CSS、链接、编号、表格与原文位置沿用同一个来源。
List<int> publicationSectionBoundaries(
  ChapterContent content, {
  int target = publicationSectionTarget,
}) {
  final json = content.displaySourceJson;
  final source = DisplaySourceIndex.fromJson(json);
  final blocks = content.blocks;
  if (source == null ||
      json?['coverPage'] == true ||
      blocks.length < 2 ||
      source.blockOwners.length != blocks.length ||
      source.blockElements.length != blocks.length) {
    return const [];
  }
  var lastId = 0;
  for (final block in blocks) {
    final id = sectionBlockNumber(block.id);
    if (id <= lastId) return const [];
    lastId = id;
  }

  final blocked = List<int>.filled(blocks.length + 1, 0);
  final styles = ChapterStyler.layoutTableOf(content);
  void keepTogether(int first, int last) {
    if (last <= first) return;
    blocked[first + 1]++;
    blocked[last + 1]--;
  }

  for (final node in source.elements) {
    // 老 MOBI 的换页标记常没有结束标签，HTML 树可能把后续几回当成它的子节点。
    // 标记只在它本来的位置换页，不把后面的正文视为需要整体保留的盒子。
    if (node.role == 'root' ||
        node.tag == 'html' ||
        node.tag == 'body' ||
        node.tag == 'mbp:pagebreak') {
      continue;
    }
    if (node.tag == 'div' || node.tag == 'section' || node.tag == 'article') {
      final style = styles[node.styleId ?? 0];
      final flow = style.block;
      if (style.box.isEmpty &&
          !style.size.hasDimensions &&
          flow.margin == null &&
          flow.float == null &&
          flow.position == null &&
          flow.breakInside == null &&
          (flow.display == null || flow.display == DisplaySpec.block)) {
        continue;
      }
    }
    final first = node.firstBlock, last = node.lastBlock;
    if (first != null && last != null) keepTogether(first, last);
  }
  final byId = {for (var i = 0; i < blocks.length; i++) blocks[i].id: i};
  for (final table in content.tables) {
    final members = table.blockIds.map((id) => byId[id]!).toList()..sort();
    if (members.isNotEmpty) keepTogether(members.first, members.last);
  }

  final starts = <int>[0];
  var length = 0, active = 0;
  for (var i = 0; i < blocks.length; i++) {
    active += blocked[i];
    if (i > 0 && active == 0 && length >= target) {
      final before = blocks[i - 1].kind;
      final after = blocks[i].kind;
      if (before != BlockKind.heading &&
          before != BlockKind.image &&
          after != BlockKind.image &&
          after != BlockKind.heading &&
          after != BlockKind.caption) {
        starts.add(i);
        length = 0;
      }
    }
    length += blocks[i].textLength;
  }
  return starts.length > 1 ? [...starts, blocks.length] : const [];
}

Iterable<ChapterContent> slicePublication(
  ChapterContent content,
  List<int> cuts,
) sync* {
  final slicer = PublicationSectionSlicer(content, cuts);
  for (var i = 0; i < cuts.length - 1; i++) {
    yield slicer.read(i);
  }
}

/// 按目标小节构造正文。共用的元素范围索引只遍历原树一次。
class PublicationSectionSlicer {
  PublicationSectionSlicer(this._content, this._cuts);

  final ChapterContent _content;
  final List<int> _cuts;
  late final _source = DisplaySourceIndex.fromJson(_content.displaySourceJson)!;
  late final _windows = _assignElements();

  ChapterContent read(int index) => _slice(
    _content,
    _source,
    _cuts[index],
    _cuts[index + 1],
    _windows[index],
  );

  List<Set<int>> _assignElements() {
    final count = _cuts.length - 1;
    final windows = List.generate(count, (_) => <int>{});
    int window(int block) => sectionIndexAt(count, block, (i) => _cuts[i]);
    for (final element in _source.elements) {
      final firstBlock = element.firstBlock, lastBlock = element.lastBlock;
      final hasRange = firstBlock != null && lastBlock != null;
      if (!hasRange && (element.anchor < 0 || element.anchor >= _cuts.last)) {
        continue;
      }
      final first = window(hasRange ? firstBlock : element.anchor);
      final last = window(hasRange ? lastBlock : element.anchor);
      for (var i = first; i <= last; i++) {
        DisplayElement? ancestor = element;
        while (ancestor != null && windows[i].add(ancestor.id)) {
          final parent = ancestor.parent;
          ancestor = parent == null ? null : _source.element(parent);
        }
      }
    }
    return windows;
  }
}

ChapterContent _slice(
  ChapterContent content,
  DisplaySourceIndex source,
  int start,
  int end,
  Set<int> keep,
) {
  final json = content.displaySourceJson!;
  bool inside(int i) => i >= start && i < end;
  int local(int i) => (i - start).clamp(0, end - start - 1);

  final ids = keep.toList()..sort();
  final remap = {for (var i = 0; i < ids.length; i++) ids[i]: i};
  final blocks = content.blocks.sublist(start, end);
  final blockIds = blocks.map((b) => b.id).toSet();
  final tableIds = [
    for (var i = 0; i < content.tables.length; i++)
      if (content.tables[i].blockIds.any(blockIds.contains)) i,
  ];
  final tables = {for (var i = 0; i < tableIds.length; i++) tableIds[i]: i};

  final part = <String, Object?>{
    ...json,
    'elements': [
      for (final id in ids)
        (() {
          final e = source.elements[id];
          return <String, Object?>{
            ...e.toJson(),
            'id': remap[id],
            'p': remap[e.parent],
            'at': e.tag == 'mbp:pagebreak' && !inside(e.anchor)
                ? end - start
                : local(e.anchor),
            'b': e.firstBlock == null ? null : local(e.firstBlock!),
            'e': e.lastBlock == null ? null : local(e.lastBlock!),
            'c': [
              for (final child in e.children)
                if (keep.contains(child)) remap[child],
            ],
            'ranges': [
              for (final r in e.ranges)
                if (inside(r.block)) [local(r.block), r.start, r.end],
            ],
            if (e.table != null) 't': tables[e.table],
          };
        })(),
    ],
    'blocks': [
      for (final id in source.blockOwners.sublist(start, end)) remap[id] ?? -1,
    ],
    'blockElements': [
      for (final id in source.blockElements.sublist(start, end))
        remap[id] ?? -1,
    ],
    for (final key in [
      'codeLines',
      'spaces',
      'wideSpaces',
      'nonBreakingSpaces',
    ])
      key: [
        for (final row in json[key] as List? ?? const [])
          if (inside(row[0] as int)) [local(row[0] as int), ...row.skip(1)],
      ],
    for (final key in ['cellSpaces', 'emptyGrids'])
      key: {
        for (final e in (json[key] as Map? ?? const {}).entries)
          if (remap[int.parse(e.key as String)] case final id?) '$id': e.value,
      },
    'compactLists': [
      for (final id in json['compactLists'] as List? ?? const []) ?remap[id],
    ],
    'spreadChapters': [
      for (final range in json['spreadChapters'] as List? ?? const [])
        if (inside(range.first as int))
          [local(range.first as int), local(range.last as int)],
    ],
    if (json['tocSpreadStarts'] case final List starts)
      'tocSpreadStarts': [
        for (final i in starts.cast<int>())
          if (inside(i)) local(i),
      ],
    if (start > 0) 'coverPage': false,
  };
  return ChapterContent(
    chapterId: content.chapterId,
    blocks: blocks,
    tables: [for (final id in tableIds) content.tables[id]],
    epubDetailsRevision: content.epubDetailsRevision,
    stylesJson: content.stylesJson,
    displaySourceJson: part,
  );
}
