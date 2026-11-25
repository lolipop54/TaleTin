import '../../engine/parsers/txt/txt_chapter_rule.dart';
import '../models/book_document.dart';
import 'txt_chapter_sections.dart';

/// 只查看到批量阈值就停止，不能为了决定是否后台计算先在界面遍历完整大目录。
bool largeToc(List<TocNode> nodes, int chapterCount, int limit) {
  if (chapterCount + nodes.length >= limit) return true;
  final pending = [...nodes];
  var seen = chapterCount;
  while (pending.isNotEmpty) {
    final node = pending.removeLast();
    seen++;
    if (seen + pending.length + node.children.length >= limit) return true;
    pending.addAll(node.children);
  }
  return false;
}

/// 目录展示结构：一卷及其下章节。
class TocVolume {
  const TocVolume({
    required this.title,
    required this.chapters,
    this.collapsible = true,
  });

  final String title;
  final List<TocEntry> chapters;
  final bool collapsible;

  bool matches(String query) =>
      (collapsible && title.contains(query)) ||
      chapters.any((entry) => entry.matches(query));
}

/// 目录列表里的一行章节。
class TocEntry {
  const TocEntry({
    required this.title,
    required this.chapterId,
    this.anchorId,
    this.depth = 0,
    this.sections = const [],
  });

  final int depth;
  final String title;
  final String chapterId;
  final String? anchorId;
  final List<TocEntry> sections;

  bool matches(String query) =>
      title.contains(query) ||
      sections.any((section) => section.title.contains(query));
}

/// 平铺目录只补两个明确章号之间能逐章核对的缺口。
/// 分卷、章内锚点、交错存放的合集仍按原书目录显示。
List<TocNode> completeFlatToc(List<TocNode> nodes, List<Chapter> chapters) {
  if (nodes.length < 2 || nodes.length >= chapters.length) return nodes;
  final ordinalById = {
    for (final chapter in chapters) chapter.id: chapter.ordinal,
  };
  final byOrdinal = {for (final chapter in chapters) chapter.ordinal: chapter};
  final result = <TocNode>[];
  var previousOrdinal = -1;
  ({int number, String unit})? previousNumber;
  for (final node in nodes) {
    final ordinal = ordinalById[node.chapterId];
    if (node.children.isNotEmpty ||
        node.fragment?.isNotEmpty == true ||
        ordinal == null ||
        ordinal <= previousOrdinal) {
      return nodes;
    }
    final number = _tocChapterNumber(node.title);
    final gap = ordinal - previousOrdinal;
    if (gap > 1 &&
        number != null &&
        previousNumber != null &&
        previousNumber.unit == number.unit &&
        number.number - previousNumber.number == gap) {
      final missing = <TocNode>[];
      for (var i = 1; i < gap; i++) {
        final chapter = byOrdinal[previousOrdinal + i];
        final expected = (number: previousNumber.number + i, unit: number.unit);
        if (chapter == null ||
            chapter.textLength == 0 ||
            _tocChapterNumber(chapter.title) != expected) {
          break;
        }
        missing.add(TocNode(title: chapter.title, chapterId: chapter.id));
      }
      // 章号和文件顺序必须连续吻合，避免把版权、脚注及续段当作缺章。
      if (missing.length == gap - 1) result.addAll(missing);
    }
    result.add(node);
    previousOrdinal = ordinal;
    previousNumber = number;
  }
  return result.length == nodes.length ? nodes : result;
}

final _leadingChapterNumber = RegExp(
  r'^(章|chapter\s+)([0-9０-９]+)(?=$|[\s:：·、.．—-])',
  caseSensitive: false,
);

({int number, String unit})? _tocChapterNumber(String title) {
  final text = title.trim();
  final match = _leadingChapterNumber.firstMatch(text);
  if (match != null) {
    final number = TxtChapterRule.parseNumber(match[2]!);
    if (number != null) {
      return (number: number, unit: match[1]!.trim().toLowerCase());
    }
  }
  final chapter = TxtChapterRule.numberedChapter(text);
  if (chapter == null ||
      !TxtChapterRule.separated(text.substring(chapter.end))) {
    return null;
  }
  return (number: chapter.number, unit: chapter.unit);
}

List<TocVolume> buildTocVolumes(
  List<TocNode> nodes,
  List<Chapter> chapters, {
  Map<String, List<TxtTocSection>> txtSections = const {},
  bool fillNumberedGaps = true,
}) {
  final ordered = [...chapters]..sort((a, b) => a.ordinal.compareTo(b.ordinal));
  if (nodes.isEmpty) {
    return [
      TocVolume(
        title: '全书',
        collapsible: false,
        chapters: [
          for (final c in ordered)
            if (c.title.trim().isNotEmpty)
              TocEntry(
                title: c.title,
                chapterId: c.id,
                sections: _sectionEntries(c.id, 1, txtSections[c.id]),
              ),
        ],
      ),
    ];
  }
  if (fillNumberedGaps) nodes = completeFlatToc(nodes, ordered);
  final ids = {for (final n in nodes) ...n.chapterIds};
  final represented = ordered.where((c) => ids.contains(c.id)).toList();
  return _buildAnchorVolumes(nodes, represented, {
    for (var i = 0; i < represented.length; i++) represented[i].id: i,
  }, txtSections);
}

List<TocVolume> _buildAnchorVolumes(
  List<TocNode> nodes,
  List<Chapter> chapters,
  Map<String, int> indexById,
  Map<String, List<TxtTocSection>> txtSections,
) {
  final volumes = <TocVolume>[];
  final targets = <(String, String)>{};
  final sectionParents = <String>{};
  Iterable<TocEntry> entriesOf(TocNode node, int depth) sync* {
    final id = node.chapterId;
    final target = node.fragment?.isNotEmpty == true
        ? node.fragment!
        : node.title;
    if (id != null &&
        indexById.containsKey(id) &&
        node.title.trim().isNotEmpty &&
        !node.children.any(
          (child) =>
              child.chapterId == id &&
              (child.fragment ?? '') == (node.fragment ?? ''),
        ) &&
        targets.add((id, target))) {
      yield TocEntry(
        title: node.title,
        chapterId: id,
        anchorId: node.fragment,
        depth: depth < 0 ? 0 : depth,
        sections: txtSections.containsKey(id) && sectionParents.add(id)
            ? _sectionEntries(id, depth < 0 ? 1 : depth + 1, txtSections[id])
            : const [],
      );
    }
    for (final child in node.children) {
      yield* entriesOf(child, depth + 1);
    }
  }

  // 正式目录本身定义阅读顺序。合集的正文文件可能交错，不能再按文件号重排。
  for (final node in nodes) {
    final entries = entriesOf(node, node.children.isEmpty ? 0 : -1).toList();
    if (entries.isEmpty) continue;
    volumes.add(
      TocVolume(
        title: node.title,
        chapters: entries,
        collapsible:
            node.children.isNotEmpty &&
            !(entries.length == 1 && entries.single.title == node.title),
      ),
    );
  }
  return volumes;
}

List<TocEntry> _sectionEntries(
  String chapterId,
  int depth,
  List<TxtTocSection>? sections,
) => sections == null
    ? const []
    : [
        for (final (index, section) in sections.indexed)
          TocEntry(
            title: '第${index + 1}节',
            chapterId: chapterId,
            anchorId: TxtChapterSections.anchorFor(section.blockId),
            depth: depth,
          ),
      ];
