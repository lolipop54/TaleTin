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
      title.contains(query) || chapters.any((entry) => entry.matches(query));
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

/// 按真实阅读顺序补齐原目录遗漏的章节，并保留分卷边界。
List<TocVolume> buildTocVolumes(List<TocNode> nodes, List<Chapter> chapters) {
  final ordered = [...chapters]..sort((a, b) => a.ordinal.compareTo(b.ordinal));
  final indexById = {for (var i = 0; i < ordered.length; i++) ordered[i].id: i};
  final chapterUseCount = <String, int>{};
  void countChapterUses(TocNode node) {
    if (node.chapterId case final id?) {
      chapterUseCount[id] = (chapterUseCount[id] ?? 0) + 1;
    }
    for (final child in node.children) {
      countChapterUses(child);
    }
  }

  for (final node in nodes) {
    countChapterUses(node);
  }
  if (chapterUseCount.values.any((count) => count > 1) ||
      nodes.any(
        (node) => node.children.any((child) => child.children.isNotEmpty),
      )) {
    return _buildAnchorVolumes(nodes, ordered, indexById);
  }
  final titles = <String, String>{};
  void collectTitles(TocNode node) {
    if (node.children.isEmpty) {
      if (node.chapterId case final id?) {
        final index = indexById[id];
        titles[id] =
            index != null &&
                (node.title.trim().isEmpty ||
                    node.title == '第 ${ordered[index].ordinal + 1} 章')
            ? ordered[index].title
            : node.title;
      }
    }
    for (final child in node.children) {
      collectTitles(child);
    }
  }

  for (final node in nodes) {
    collectTitles(node);
  }
  TocEntry entryAt(int index) {
    final chapter = ordered[index];
    return TocEntry(
      title: titles[chapter.id] ?? chapter.title,
      chapterId: chapter.id,
    );
  }

  int? anchorOf(TocNode node) {
    if (node.chapterId case final id?) {
      if (indexById[id] case final index?) return index;
    }
    for (final child in node.children) {
      if (anchorOf(child) case final index?) return index;
    }
    return null;
  }

  final roots = [
    for (final node in nodes)
      if (anchorOf(node) case final index?) (node: node, index: index),
  ]..sort((a, b) => a.index.compareTo(b.index));
  final volumes = <TocVolume>[];
  void addLoose(int start, int end) {
    if (start >= end) return;
    volumes.add(
      TocVolume(
        title: '全书',
        chapters: [
          for (var i = start; i < end; i++)
            if (entryAt(i).title.trim().isNotEmpty) entryAt(i),
        ],
        collapsible: false,
      ),
    );
  }

  var cursor = 0;
  for (var i = 0; i < roots.length; i++) {
    final root = roots[i];
    final rootTitle =
        root.node.title == '第 ${ordered[root.index].ordinal + 1} 章'
        ? ordered[root.index].title
        : root.node.title;
    if (root.index < cursor) continue;
    addLoose(cursor, root.index);
    final end = i + 1 < roots.length ? roots[i + 1].index : ordered.length;
    if (root.node.children.isEmpty && end == root.index + 1) {
      addLoose(root.index, root.index + 1);
      cursor = root.index + 1;
      continue;
    }
    final entries = [
      for (var j = root.index; j < end; j++)
        if (entryAt(j).title.trim().isNotEmpty) entryAt(j),
    ];
    if (entries.isEmpty) {
      cursor = end;
      continue;
    }
    if (rootTitle.trim().isEmpty ||
        (entries.length == 1 &&
            entries.single.title.trim() == rootTitle.trim())) {
      addLoose(root.index, end);
    } else {
      volumes.add(TocVolume(title: rootTitle, chapters: entries));
    }
    cursor = end;
  }
  addLoose(cursor, ordered.length);
  return volumes;
}

List<TocVolume> _buildAnchorVolumes(
  List<TocNode> nodes,
  List<Chapter> chapters,
  Map<String, int> indexById,
) {
  final volumes = <TocVolume>[];
  final represented = <String>{};
  final targets = <(String, String)>{};

  int startOf(TocNode node) =>
      indexById[node.chapterId] ??
      (node.children.isEmpty ? chapters.length : startOf(node.children.first));
  final roots = [...nodes]..sort((a, b) => startOf(a).compareTo(startOf(b)));
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
      represented.add(id);
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

  List<TocEntry> missing(int start, int end) => [
    for (var i = start; i < end; i++)
      if (!represented.contains(chapters[i].id) &&
          chapters[i].title.trim().isNotEmpty)
        TocEntry(title: chapters[i].title, chapterId: chapters[i].id),
  ];
  final before = missing(
    0,
    roots.isEmpty ? chapters.length : startOf(roots.first),
  );
  if (before.isNotEmpty) {
    volumes.add(TocVolume(title: '全书', chapters: before, collapsible: false));
  }
  for (var i = 0; i < roots.length; i++) {
    final node = roots[i];
    final entries = entriesOf(node, node.children.isEmpty ? 0 : -1).toList();
    final end = i + 1 < roots.length ? startOf(roots[i + 1]) : chapters.length;
    entries.addAll(missing(startOf(node), end));
    final originalOrder = {
      for (var index = 0; index < entries.length; index++)
        entries[index]: index,
    };
    entries.sort((a, b) {
      final byFile = indexById[a.chapterId]!.compareTo(indexById[b.chapterId]!);
      return byFile == 0
          ? originalOrder[a]!.compareTo(originalOrder[b]!)
          : byFile;
    });
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
