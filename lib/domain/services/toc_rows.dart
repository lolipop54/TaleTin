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
}) {
  final rows = <TocRow>[];
  for (final index in visible) {
    final volume = volumes[index];
    if (volume.collapsible) {
      rows.add(VolumeHeaderRow(volumeIndex: index, volume: volume));
    }
    final open = searching || !volume.collapsible || expanded.contains(index);
    if (!open) continue;
    for (final chapter in volume.chapters) {
      if (!searching || chapter.matches(query)) {
        rows.add(ChapterListRow(chapter));
      }
    }
  }
  // 反转完整的可见顺序，卷、各级子目录及父项一起反转；保留条目自身的缩进和锚点。
  // 只反转卷或叶子章节会让父项仍留在上方，无法向上展开。
  return descending ? rows.reversed.toList() : rows;
}
