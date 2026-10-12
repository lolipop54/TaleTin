import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/gt_tokens.dart';
import 'toc_tree.dart';

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

/// 章节行的上下内边距。列表用 `itemExtentBuilder` 按 [TocRowMetrics] 强制每行高度，
/// 所以行高不是行内容自己撑出来的：改这里会同时改变行的内边距和行高，两边不会走散。
const double chapterRowVerticalPadding = 10;

/// 卷头行的上下内边距，和 [chapterRowVerticalPadding] 同理。
const double volumeHeaderVerticalPadding = GtSpacing.s3;

/// 章节行文字字号。行高按它算，行本身也用同一个值，改一处两边一起变。
const double chapterFontSize = 14;

/// 卷头行文字字号，和 [chapterFontSize] 同理。
const double volumeHeaderFontSize = 15;

/// 目录列表行高；计算值必须与真实渲染高度一致。
class TocRowMetrics {
  const TocRowMetrics({required this.chapter, required this.header});

  final double chapter;
  final double header;

  double extentOf(TocRow row) => switch (row) {
    VolumeHeaderRow() => header,
    ChapterListRow() => chapter,
  };

  /// 按当前 UI 字体和系统字号缩放计算，避免大字号压扁目录行。
  static TocRowMetrics resolve(BuildContext context, GtColors colors) {
    final scaler = MediaQuery.textScalerOf(context);
    double textHeight(TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(
          text: '中',
          style: DefaultTextStyle.of(context).style.merge(style),
        ),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout();
      final height = painter.height;
      painter.dispose();
      return height;
    }

    final title = textHeight(
      GtText.body(colors.textSecondary).copyWith(fontSize: chapterFontSize),
    );
    // 20 是当前章节左侧竖条的高度；+1 是行底部的 1dp 分隔线。
    final chapter = math.max(20.0, title) + chapterRowVerticalPadding * 2 + 1;
    final header =
        math.max(
          22.0,
          textHeight(
            GtText.sectionTitle(colors.textPrimary)
                .copyWith(fontSize: volumeHeaderFontSize),
          ),
        ) +
        volumeHeaderVerticalPadding * 2;
    return TocRowMetrics(chapter: chapter, header: header);
  }
}
