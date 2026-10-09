import 'package:taletin/ui/core/widgets/gt_button.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/gt_tokens.dart';
import '../../../../core/widgets/gt_icon.dart';
import '../../view_models/reader_session_view_model.dart';
import '../../view_models/reader_view_model.dart';
import 'toc_rows.dart';
import '../../../../../domain/services/toc_entry_index.dart';
import 'toc_tree.dart';

/// 目录页签：真实目录、搜索和打开时当前章置顶，跳转返回提示显示在正文中。
class TocTab extends ConsumerStatefulWidget {
  const TocTab({super.key, required this.bookId, required this.query});

  final String bookId;
  final String query;

  @override
  ConsumerState<TocTab> createState() => _TocTabState();
}

class _TocTabState extends ConsumerState<TocTab> {
  Set<int>? _expanded;
  ScrollController? _listController;

  @override
  void dispose() {
    _listController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    final tocAsync = ref.watch(bookTocProvider(widget.bookId));
    final session = ref.watch(readerSessionProvider(widget.bookId)).value;
    final notifier = ref.read(readerSessionProvider(widget.bookId).notifier);
    final query = widget.query.trim();
    final currentChapterId = session?.chapter.id;
    final volumes = buildTocVolumes(
      tocAsync.value ?? const [],
      session?.chapters ?? const [],
    );
    final entries =
        ref.watch(progressTitlesProvider(widget.bookId)).value ?? [];
    var currentEntry = session == null || entries.isEmpty
        ? null
        : entries[tocEntryIndexAt(
            entries,
            position: session.contentProgress,
            chapterId: session.chapter.id,
          )];
    if (currentEntry != null &&
        !volumes.any(
          (v) => v.chapters.any(
            (e) =>
                e.chapterId == currentEntry!.chapterId &&
                e.anchorId == currentEntry.anchorId &&
                e.title == currentEntry.title,
          ),
        )) {
      currentEntry = null;
    }
    final currentTocTitle =
        currentEntry?.title ?? currentTocTitleOf(session, volumes);
    final currentAnchorId = currentEntry?.anchorId;
    final expanded = _expanded ?? {for (var i = 0; i < volumes.length; i++) i};
    final searching = query.isNotEmpty;
    final visible = [
      for (var i = 0; i < volumes.length; i++)
        if (!searching || volumes[i].matches(query)) i,
    ];
    final rows = flattenTocRows(
      volumes,
      visible,
      expanded,
      query,
      searching: searching,
    );
    final metrics = TocRowMetrics.resolve(context, colors);
    final extents = [for (final row in rows) metrics.extentOf(row)];

    if (tocAsync.isLoading && !tocAsync.hasValue) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: GtSpacing.s8),
        child: Center(
          child: SizedBox(width: 40, height: 40, child: SizedBox.shrink()),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: visible.isEmpty
              ? _emptyState(context, searching)
              : _rowList(
                  context,
                  notifier,
                  rows,
                  extents,
                  expanded: expanded,
                  currentChapterId: currentChapterId,
                  currentTocTitle: currentTocTitle,
                  currentAnchorId: currentAnchorId,
                  colors: colors,
                ),
        ),
      ],
    );
  }

  /// 首帧直接把当前章放在第一行，不先显示顶部再跳到当前章。
  Widget _rowList(
    BuildContext context,
    ReaderSessionNotifier notifier,
    List<TocRow> rows,
    List<double> extents, {
    required Set<int> expanded,
    required String? currentChapterId,
    required String? currentTocTitle,
    required String? currentAnchorId,
    required GtColors colors,
  }) {
    final contentHeight = extents.fold<double>(
      0,
      (sum, height) => sum + height,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : contentHeight;
        if (_listController == null) {
          var offset = 0.0;
          for (var i = 0; i < rows.length; i++) {
            final row = rows[i];
            if (row is ChapterListRow &&
                row.chapter.chapterId == currentChapterId &&
                (currentAnchorId != null
                    ? row.chapter.anchorId == currentAnchorId
                    : currentTocTitle == null ||
                          row.chapter.title == currentTocTitle)) {
              break;
            }
            offset += extents[i];
          }
          if (offset >= contentHeight || widget.query.trim().isNotEmpty) {
            offset = 0;
          }
          _listController = ScrollController(
            keepScrollOffset: false,
            initialScrollOffset: offset.clamp(
              0.0,
              math.max(0.0, contentHeight - available),
            ),
          );
        }
        return SizedBox(
          height: available,
          child: ListView.builder(
            controller: _listController,
            // 末项底部就是滚动边界，不为“末章置顶”补出一屏空白。
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: GtSpacing.s4),
            itemCount: rows.length,
            itemExtentBuilder: (index, _) => extents[index],
            itemBuilder: (context, index) => switch (rows[index]) {
              VolumeHeaderRow(:final volumeIndex, :final volume) =>
                _volumeHeader(context, volume, volumeIndex, expanded),
              ChapterListRow(:final chapter) => _chapterRow(
                context,
                notifier,
                chapter,
                isCurrent:
                    chapter.chapterId == currentChapterId &&
                    (currentAnchorId != null
                        ? chapter.anchorId == currentAnchorId
                        : currentTocTitle == null ||
                              chapter.title == currentTocTitle),
                colors: colors,
              ),
            },
          ),
        );
      },
    );
  }

  Widget _volumeHeader(
    BuildContext context,
    TocVolume volume,
    int index,
    Set<int> expanded,
  ) {
    final colors = context.gtColors;
    final open = expanded.contains(index);
    return GtButton.raw(
      onPressed: () => setState(() {
        final current = _expanded ?? expanded;
        _expanded = current.contains(index)
            ? ({...current}..remove(index))
            : {...current, index};
      }),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: volumeHeaderVerticalPadding,
        ),
        child: Row(
          children: [
            GtIcon(
              open ? GtIcons.chevronDown : GtIcons.chevronRight,
              size: 22,
              color: colors.textPrimary,
            ),
            const SizedBox(width: GtSpacing.s2),
            Expanded(
              child: Text(
                volume.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GtText.sectionTitle(colors.textPrimary)
                    .copyWith(fontSize: volumeHeaderFontSize),
              ),
            ),
            Text(
              '${volume.chapters.length} 章',
              style: GtText.caption(colors.textMuted).copyWith(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chapterRow(
    BuildContext context,
    ReaderSessionNotifier notifier,
    TocEntry chapter, {
    required bool isCurrent,
    required GtColors colors,
  }) {
    return GtButton.raw(
      onPressed: () async {
        ref.read(readerProvider.notifier).closePanel(collapseControls: true);
        await notifier.goToChapterFromToc(
          chapter.chapterId,
          title: chapter.title,
          anchorId: chapter.anchorId,
        );
      },
      child: Container(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: colors.borderSubtle)),
        ),
        padding: EdgeInsets.only(
          left: (isCurrent ? 0 : _chapterRowLead) + chapter.depth * 16,
          top: chapterRowVerticalPadding,
          bottom: chapterRowVerticalPadding,
        ),
        child: Row(
          children: [
            if (isCurrent)
              Container(
                width: _currentBarWidth,
                height: 20,
                color: colors.actionPrimary,
              ),
            SizedBox(
              width: isCurrent
                  ? _chapterTitleInset - _currentBarWidth
                  : GtSpacing.s4,
            ),
            Expanded(
              child: Text(
                chapter.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    GtText.body(
                      isCurrent ? colors.actionPrimary : colors.textSecondary,
                    ).copyWith(
                      fontSize: chapterFontSize,
                      fontWeight: FontWeight.w400,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState(BuildContext context, bool searching) {
    final colors = context.gtColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: GtSpacing.s8),
      child: Center(
        child: Text(
          searching ? '没有匹配的章节' : '这本书没有可用的目录',
          style: GtText.body(colors.textMuted).copyWith(fontSize: 14),
        ),
      ),
    );
  }
}

const double _chapterRowLead = GtSpacing.s3;
const double _currentBarWidth = 3;
const double _chapterTitleInset = _chapterRowLead + GtSpacing.s4;
