import 'toc_presentation.dart';

/// 目录列表里的一行：卷头或章节。
/// 行与行之间不再插入留白行——那种行自己画不出内容，却按固定高度占地方，
/// 只在列表末尾留下一段空白，和列表顶部的间距对不上。
sealed class TocRow {
  const TocRow();
}

class VolumeHeaderRow extends TocRow {
  const VolumeHeaderRow({required this.volumeIndex, required this.volume});

  final int volumeIndex;
  final TocVolume volume;
}

class ChapterListRow extends TocRow {
  const ChapterListRow(this.chapter);

  final TocEntry chapter;
}

/// 把分卷、展开状态与搜索结果拍平，供 `ListView.builder` 按需构建。
List<TocRow> flattenTocRows(
  List<TocVolume> volumes,
  List<int> visible,
  Set<int> expanded,
  String query, {
  required bool searching,
  bool descending = false,
  Set<String> expandedSections = const {},
}) {
  final rows = <TocRow>[];
  for (final index in visible) {
    final volume = volumes[index];
    if (volume.collapsible) {
      rows.add(VolumeHeaderRow(volumeIndex: index, volume: volume));
    }
    final open = !volume.collapsible || expanded.contains(index);
    if (!open) continue;
    // 只有卷名匹配时，允许用户手动展开查看全部章节；只要卷内也有匹配，
    // 就只列匹配章节，不能因为卷名同时命中而混入未匹配项。
    final wholeVolume =
        volume.collapsible &&
        volume.title.contains(query) &&
        !volume.chapters.any((entry) => entry.matches(query));
    for (final chapter in volume.chapters) {
      if (!searching || wholeVolume || chapter.matches(query)) {
        rows.add(ChapterListRow(chapter));
        if (expandedSections.contains(chapter.chapterId)) {
          rows.addAll(
            visibleTxtSections(chapter, query).map(ChapterListRow.new),
          );
        }
      }
    }
  }
  // 反转完整的可见顺序，卷、各级子目录及父项一起反转；保留条目自身的缩进和锚点。
  // 只反转卷或叶子章节会让父项仍留在上方，无法向上展开。
  return descending ? rows.reversed.toList() : rows;
}

/// 搜索命中某一节时只显示命中的节；只命中章名时展开可看到该章全部小节。
List<TocEntry> visibleTxtSections(TocEntry chapter, String query) {
  if (query.isEmpty) return chapter.sections;
  final matches = chapter.sections
      .where((section) => section.matches(query))
      .toList();
  return matches.isEmpty ? chapter.sections : matches;
}
