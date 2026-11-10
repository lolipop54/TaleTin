import '../models/book_document.dart';

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
  });

  final int depth;
  final String title;
  final String chapterId;
  final String? anchorId;

  bool matches(String query) => title.contains(query);
}

/// 已有目录只展示书里明确列出的目标；读取分段、版权段和脚注不是新目录。
/// 需要从封面恢复的合集章节由解析器确认后写入目录，不在界面再次猜测。
List<TocVolume> buildTocVolumes(List<TocNode> nodes, List<Chapter> chapters) {
  final ordered = [...chapters]..sort((a, b) => a.ordinal.compareTo(b.ordinal));
  if (nodes.isEmpty) {
    return [
      TocVolume(
        title: '全书',
        collapsible: false,
        chapters: [
          for (final c in ordered)
            if (c.title.trim().isNotEmpty)
              TocEntry(title: c.title, chapterId: c.id),
        ],
      ),
    ];
  }
  final ids = {for (final n in nodes) ...n.chapterIds};
  final represented = ordered.where((c) => ids.contains(c.id)).toList();
  return _buildAnchorVolumes(nodes, represented, {
    for (var i = 0; i < represented.length; i++) represented[i].id: i,
  });
}

List<TocVolume> _buildAnchorVolumes(
  List<TocNode> nodes,
  List<Chapter> chapters,
  Map<String, int> indexById,
) {
  final volumes = <TocVolume>[];
  final targets = <(String, String)>{};
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
