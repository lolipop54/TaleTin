import 'package:taletin/ui/core/widgets/gt_button.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/gt_tokens.dart';
import '../../../../core/widgets/frame_fade.dart';
import '../../../../core/widgets/gt_icon.dart';
import '../../view_models/reader_session_view_model.dart';
import '../../view_models/reader_view_model.dart';
import 'toc_rows.dart';
import 'toc_scrollbar.dart';
import '../../../../../domain/services/toc_entry_index.dart';
import 'toc_tree.dart';
import '../../../../../domain/models/book_document.dart';
import '../../view_models/toc_presentation_provider.dart';

/// 目录页签：真实目录、搜索和打开时当前章置顶，跳转返回提示显示在正文中。
class TocTab extends ConsumerStatefulWidget {
  const TocTab({
    super.key,
    required this.bookId,
    required this.query,
    this.leadingAction,
    this.descending,
    this.onOrderChanged,
  });

  final String bookId;
  final String query;
  final Widget? leadingAction;
  final bool? descending;
  final VoidCallback? onOrderChanged;

  @override
  ConsumerState<TocTab> createState() => _TocTabState();
}

class _TocTabState extends ConsumerState<TocTab> {
  Set<int>? _expanded;
  List<TocVolume>? _shownVolumes, _defaultVolumes;
  Set<int> _defaultExpanded = {}, _shownExpanded = {};
  TocRowsResult? _shownRows;
  bool _shownDescending = false, _rowsReady = false;
  String _shownQuery = '';
  ScrollController? _listController;
  bool _localDescending = false;
  bool get _descending => widget.descending ?? _localDescending;
  double? _pendingScrollOffset;

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
    final tree = ref.watch(
      tocVolumesProvider((
        tocAsync.value ?? const <TocNode>[],
        session?.book.format.code == 'pdf' && (tocAsync.value?.isEmpty ?? true)
            ? const <Chapter>[]
            : session?.chapters ?? const <Chapter>[],
      )),
    );
    if (tree.hasValue) _shownVolumes = tree.requireValue;
    final volumes = _shownVolumes ?? const <TocVolume>[];
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
    if (!identical(_defaultVolumes, volumes)) {
      _defaultVolumes = volumes;
      _defaultExpanded = {for (var i = 0; i < volumes.length; i++) i};
    }
    final requestedExpanded = _expanded ?? _defaultExpanded;
    final prepared = ref.watch(
      tocRowsProvider((volumes, requestedExpanded, query, _descending)),
    );
    _rowsReady = tree.hasValue && prepared.hasValue;
    if (_rowsReady) {
      _shownRows = prepared.requireValue;
      _shownExpanded = requestedExpanded;
      _shownDescending = _descending;
      _shownQuery = query;
    }
    final expanded = _shownExpanded;
    final searching = _shownQuery.isNotEmpty;
    final visible = _shownRows?.visible ?? const <int>[];
    final rows = _shownRows?.rows ?? const <TocRow>[];
    final metrics = TocRowMetrics.resolve(context, colors);
    final extents = [for (final row in rows) metrics.extentOf(row)];

    if (session == null ||
        _shownRows == null ||
        (tocAsync.isLoading && !tocAsync.hasValue)) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: GtSpacing.s8),
        child: Center(
          child: SizedBox(width: 40, height: 40, child: SizedBox.shrink()),
        ),
      );
    }
    final chapterCount = _shownRows!.count;
    return FrameFade(
      revision: _shownDescending,
      // 淡化旧画面时必须有不透明底色，防止新旧文字透叠在一起。
      child: ColoredBox(
        color: colors.surface,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _orderBar(context, chapterCount),
            Flexible(
              // 列表边界拉伸只在列表内部绘制，不覆盖上方统计和排序按钮。
              child: ClipRect(
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
            ),
          ],
        ),
      ),
    );
  }

  Widget _orderBar(BuildContext context, int chapterCount) {
    final colors = context.gtColors;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        GtSpacing.s5,
        widget.leadingAction == null ? 0 : GtSpacing.s2,
        GtSpacing.s3,
        GtSpacing.s1,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              sessionIsPdf ? '共$chapterCount项' : '共$chapterCount章',
              style: GtText.caption(colors.textMuted).copyWith(fontSize: 12),
            ),
          ),
          if (widget.leadingAction != null) widget.leadingAction!,
          GtButton(
            key: const Key('toc-order-button'),
            style: GtButton.compactStyle,
            onPressed:
                widget.onOrderChanged ??
                () => setState(() {
                  _localDescending = !_descending;
                  // 换序后的第一帧直接从新顺序的顶部显示，由 FrameFade 保留旧画面。
                  _pendingScrollOffset = 0;
                }),
            child: Text(
              _descending ? '倒序' : '正序',
              style: GtText.caption(colors.actionPrimary)
                  .copyWith(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  bool get sessionIsPdf =>
      ref.read(readerSessionProvider(widget.bookId)).value?.book.format.code ==
      'pdf';

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
        if (_listController == null ||
            (_rowsReady && _pendingScrollOffset != null)) {
          final previousController = _listController;
          var offset = _pendingScrollOffset ?? 0.0;
          if (_pendingScrollOffset == null) {
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
          }
          _pendingScrollOffset = null;
          _listController = ScrollController(
            keepScrollOffset: false,
            initialScrollOffset: offset.clamp(
              0.0,
              math.max(0.0, contentHeight - available),
            ),
          );
          // 旧列表本帧卸载后再释放；切换期间不让两个列表共用同一个控制器。
          if (previousController != null) {
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => previousController.dispose(),
            );
          }
        }
        return SizedBox(
          height: available,
          child: TocScrollbar(
            key: ObjectKey(_listController),
            controller: _listController!,
            child: ListView.builder(
              controller: _listController,
              // 末项底部就是滚动边界，不为“末章置顶”补出一屏空白。
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.only(
                left: GtSpacing.s4,
                right: TocScrollbar.gutter,
              ),
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
      onPressed: () => _toggleVolume(volume, index, expanded),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: volumeHeaderVerticalPadding,
        ),
        child: Row(
          children: [
            RotatedBox(
              quarterTurns: open && _shownDescending ? 2 : 0,
              child: GtIcon(
                open ? GtIcons.chevronDown : GtIcons.chevronRight,
                size: 22,
                color: colors.textPrimary,
              ),
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

  void _toggleVolume(TocVolume volume, int index, Set<int> expanded) {
    final current = _expanded ?? expanded;
    final open = current.contains(index);
    final controller = _listController;
    setState(() {
      _expanded = open ? ({...current}..remove(index)) : {...current, index};
      if (_descending &&
          widget.query.trim().isEmpty &&
          controller?.hasClients == true) {
        // 倒序时章节插在卷头上方；同帧补偿新增／移除的高度，让卷头留在手指附近。
        final metrics = TocRowMetrics.resolve(context, context.gtColors);
        final change = volume.chapters.length * metrics.chapter;
        _pendingScrollOffset = controller!.offset + (open ? -change : change);
      }
    });
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
